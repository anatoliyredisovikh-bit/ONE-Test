local component = require("component")
local event = require("event")
local serialization = require("serialization")
local filesystem = require("filesystem")
local gpu = component.gpu
local math = require("math")
local os = require("os")
local unicode = require("unicode")
local computer = require("computer")
local TIMEZONE_OFFSET = 3 * 3600

local modem = component.modem
modem.open(0xffef)
modem.open(0xfffe)

event.ignore("interrupted", function() end)
event.ignore("terminate", function() end)

local tmpfs = component.proxy(computer.tmpAddress())
local function getRealTimestamp()
    local handle = tmpfs.open("/time", "w")
    tmpfs.write(handle, "time")
    tmpfs.close(handle)
    return tmpfs.lastModified("/time") / 1000 + TIMEZONE_OFFSET
end

local function getRealTimeString()
    return os.date("%H:%M:%S", getRealTimestamp())
end

local function getRealDateTimeString()
    return os.date("%d.%m.%Y %H:%M:%S", getRealTimestamp())
end

-- Упрощённый вывод (без ANSI, для надёжности)
local function printLog(msg)
    print("[" .. getRealTimeString() .. "] " .. msg)
end

local ACCESS_PASSWORD = "admin"

local DB_PATH = "/home/players.db"
local players = {}
if filesystem.exists(DB_PATH) then
    local file = io.open(DB_PATH, "r")
    local raw = file:read("*a")
    file:close()
    if raw and #raw > 0 then
        local success, data = pcall(serialization.unserialize, raw)
        if success and data then players = data end
    end
end

local function saveDB()
    local file = io.open(DB_PATH, "w")
    file:write(serialization.serialize(players))
    file:close()
end

local STATS_PATH = "/home/global_stats.db"
local globalStats = { totalReports = 0, totalBuys = 0, totalSells = 0 }
if filesystem.exists(STATS_PATH) then
    local file = io.open(STATS_PATH, "r")
    local raw = file:read("*a")
    file:close()
    if raw and #raw > 0 then
        local success, data = pcall(serialization.unserialize, raw)
        if success and data then
            globalStats.totalReports = data.totalReports or 0
            globalStats.totalBuys = data.totalBuys or 0
            globalStats.totalSells = data.totalSells or 0
        end
    end
end

local function saveGlobalStats()
    local file = io.open(STATS_PATH, "w")
    file:write(serialization.serialize(globalStats))
    file:close()
end

local owner = nil
local sessions = {}
local markets = {}
local SESSION_TIMEOUT = 31536000
local marketConnected = false
local shopPaused = false
local ADMIN_NAME = "Kalleront"

local function getOrCreatePlayer(name)
    if not players[name] then
        players[name] = {
            balance = 0.0,
            transactions = 0,
            regDate = getRealDateTimeString(),
            agreed = false,
            banned = false,
            hasFeedback = false
        }
        saveDB()
        printLog("Создан игрок " .. name)
    end
    return players[name]
end

local function validateSession(name, token)
    local s = sessions[name]
    return s and s.token == token and os.time() - (s.lastAction or 0) < SESSION_TIMEOUT
end

printLog("Сервер запущен. Ожидание терминалов...")

while true do
    local ev = {event.pull(0.5)}
    local etype = ev[1]

    if etype == "modem_message" then
        local from = ev[3]
        local raw = ev[6]
        local success, msg = pcall(serialization.unserialize, raw)
        if not success or not msg or type(msg) ~= "table" then
            goto continue
        end

        if msg.op == "register" then
            if msg.password ~= ACCESS_PASSWORD then
                modem.send(from, 0xffef, serialization.serialize({op="error", message="Неверный пароль"}))
                printLog("Попытка подключения с неверным паролем от " .. from)
                goto continue
            end
            marketConnected = true
            if not owner then
                owner = from
                printLog("АДМИН ЗАРЕГИСТРИРОВАН: " .. from)
            end
            if not markets[from] then
                markets[from] = true
                printLog("Терминал добавлен: " .. from)
            end
            modem.send(from, 0xffef, serialization.serialize({op="welcome", owner=(from==owner), shopPaused=shopPaused}))
            goto continue
        elseif msg.op == "enter" then
            if shopPaused then
                modem.send(from, 0xffef, serialization.serialize({op="error", message="Магазин на паузе"}))
                goto continue
            end
            local playerName = msg.name
            if not playerName or playerName == "" then
                printLog("Вход без имени от " .. from)
                goto continue
            end
            local player = getOrCreatePlayer(playerName)
            if player.banned then
                modem.send(from, 0xffef, serialization.serialize({op="error", message="Вы забанены"}))
                goto continue
            end

            local existingSession = sessions[playerName]
            local token
            if existingSession and os.time() - (existingSession.lastAction or 0) < SESSION_TIMEOUT then
                token = existingSession.token
                existingSession.lastAction = os.time()
                printLog(playerName .. " продлил сессию. Токен: " .. token)
            else
                token = tostring(math.floor(math.random() * 900000000 + 100000000))
                sessions[playerName] = {token = token, lastAction = os.time()}
                printLog(playerName .. " вошёл. Токен: " .. token)
            end

            modem.send(from, 0xffef, serialization.serialize({
                op="welcome", status="ok", token=token,
                balance=player.balance or 0.0,
                transactions=player.transactions,
                regDate=player.regDate,
                agreed = player.agreed or false,
                shopPaused = shopPaused
            }))
            goto continue
        elseif msg.op == "getAccount" then
            if not validateSession(msg.name, msg.token) then
                modem.send(from, 0xffef, serialization.serialize({op="accountData", error = true, message = "Токен устарел"}))
                goto continue
            end
            local player = players[msg.name]
            if not player then goto continue end
            sessions[msg.name].lastAction = os.time()
            modem.send(from, 0xffef, serialization.serialize({
                op="accountData",
                data = {
                    balance = player.balance,
                    transactions = player.transactions,
                    regDate = player.regDate,
                    agreed = player.agreed,
                    shopPaused = shopPaused
                }
            }))
            printLog("Аккаунт отправлен для " .. msg.name)
            goto continue
        elseif msg.op == "sell" then
            if shopPaused then
                modem.send(from, 0xffef, serialization.serialize({op="error", message="Магазин на паузе"}))
                goto continue
            end
            if not validateSession(msg.name, msg.token) then
                printLog("Неверный токен для sell")
                goto continue
            end
            local player = players[msg.name]
            if not player or player.banned then goto continue end
            local qty = tonumber(msg.qty) or 0
            local value = tonumber(msg.value) or 0

            player.balance = (player.balance or 0) + value
            player.transactions = (player.transactions or 0) + 1
            sessions[msg.name].lastAction = os.time()

            globalStats.totalSells = (globalStats.totalSells or 0) + 1
            saveGlobalStats()
            saveDB()
            printLog(string.format("💰 %s пополнил баланс: предмет '%s' x%d на сумму %.2f", msg.name, msg.item, qty, value))
            goto continue
        elseif msg.op == "buy" then
            if shopPaused then
                modem.send(from, 0xffef, serialization.serialize({op="error", message="Магазин на паузе"}))
                goto continue
            end
            if not validateSession(msg.name, msg.token) then
                printLog("Неверный токен для buy")
                goto continue
            end
            local player = players[msg.name]
            if not player or player.banned then goto continue end
            local value = tonumber(msg.value) or 0

            player.balance = (player.balance or 0) - value
            player.transactions = (player.transactions or 0) + 1
            sessions[msg.name].lastAction = os.time()

            globalStats.totalBuys = (globalStats.totalBuys or 0) + 1
            saveGlobalStats()
            saveDB()
            printLog(string.format("🛒 %s купил %s x%d за %.2f", msg.name, msg.item, msg.qty, value))
            goto continue
        elseif msg.op == "report" then
            if not validateSession(msg.name, msg.token) then
                printLog("Неверный токен для report")
                goto continue
            end
            globalStats.totalReports = (globalStats.totalReports or 0) + 1
            saveGlobalStats()
            printLog("📩 Репорт от " .. msg.name .. " (" .. msg.time .. ")")
            printLog("   Текст: " .. (msg.text or ""))
            local file = io.open("/home/reports.log", "a")
            if file then
                file:write("[" .. msg.time .. "] " .. msg.name .. ": " .. msg.text .. "\n")
                file:close()
                printLog("Сохранено в reports.log")
            else
                printLog("Не удалось открыть reports.log")
            end
            goto continue
        elseif msg.op == "agree" then
            if not validateSession(msg.name, msg.token) then
                modem.send(from, 0xffef, serialization.serialize({ op="agree", error = true, message = "Токен устарел" }))
                goto continue
            end
            local player = players[msg.name]
            if player then
                player.agreed = true
                saveDB()
                sessions[msg.name].lastAction = os.time()
                printLog("📝 " .. msg.name .. " принял пользовательское соглашение")
                modem.send(from, 0xffef, serialization.serialize({ op = "agree", success = true, agreed = true }))
            else
                modem.send(from, 0xffef, serialization.serialize({ op = "agree", error = true, message = "Игрок не найден" }))
            end
            goto continue
        elseif msg.op == "get_feedbacks" then
            if not validateSession(msg.name, msg.token) then
                modem.send(from, 0xffef, serialization.serialize({op="feedbacks_list", error="Токен устарел"}))
                goto continue
            end
            local player = players[msg.name]
            local feedbacks = {}
            if filesystem.exists("/home/feedbacks.db") then
                local file = io.open("/home/feedbacks.db", "r")
                local data = file:read("*a")
                file:close()
                if data and #data > 0 then
                    local ok, result = pcall(serialization.unserialize, data)
                    if ok and type(result) == "table" then
                        feedbacks = result
                    end
                end
            end
            modem.send(from, 0xffef, serialization.serialize({
                op = "feedbacks_list",
                feedbacks = feedbacks,
                hasFeedback = player and player.hasFeedback or false
            }))
            goto continue
        elseif msg.op == "add_feedback" then
            if not validateSession(msg.name, msg.token) then
                modem.send(from, 0xffef, serialization.serialize({op="add_feedback_response", success=false, error="Токен устарел"}))
                goto continue
            end
            local player = players[msg.name]
            if not player then
                modem.send(from, 0xffef, serialization.serialize({op="add_feedback_response", success=false, error="Игрок не найден"}))
                goto continue
            end
            if player.hasFeedback then
                modem.send(from, 0xffef, serialization.serialize({op="add_feedback_response", success=false, error="Вы уже оставляли отзыв"}))
                goto continue
            end
            local feedbacks = {}
            if filesystem.exists("/home/feedbacks.db") then
                local file = io.open("/home/feedbacks.db", "r")
                local data = file:read("*a")
                file:close()
                if data and #data > 0 then
                    local ok, result = pcall(serialization.unserialize, data)
                    if ok and type(result) == "table" then
                        feedbacks = result
                    end
                end
            end
            table.insert(feedbacks, 1, {name = msg.name, text = msg.text, time = msg.time})
            local file = io.open("/home/feedbacks.db", "w")
            file:write(serialization.serialize(feedbacks))
            file:close()
            player.hasFeedback = true
            saveDB()
            modem.send(from, 0xffef, serialization.serialize({op="add_feedback_response", success=true}))
            printLog("📝 Новый отзыв от " .. msg.name .. ": " .. msg.text)
            goto continue
        end
    end
    ::continue::
end
