-- ============================================================
-- PIM MARKET SERVER (UNIFIED) – полная версия 6.6
-- Добавлена загрузка каталога скупки из удалённого файла
-- ============================================================

local component = require("component")
local event = require("event")
local keyboard = require("keyboard")
local unicode = require("unicode")
local computer = require("computer")
local serialization = require("serialization")
local filesystem = require("filesystem")
local term = require("term")
local math = require("math")
local os = require("os")

if not component.isAvailable("modem") then error("Не найден модем", 0) end
if not component.isAvailable("gpu") then error("Не найдена видеокарта", 0) end

local modem = component.modem
local gpu = component.gpu

-- ------------------------------------------------------------------
-- 1. КОНФИГУРАЦИЯ
-- ------------------------------------------------------------------
local ACCESS_PASSWORD = "admin"
local ADMIN_NAME = "Kalleront"
local SESSION_TIMEOUT = 31536000
local TIMEZONE_OFFSET = 3 * 3600

local DB_PATH = "/home/players.db"
local STATS_PATH = "/home/global_stats.db"
local FEEDBACKS_PATH = "/home/feedbacks.db"
local REPORTS_LOG = "/home/reports.log"
local CATALOG_PATH = "/home/catalog.db"
local SHOP_ITEMS_FILE = "/home/shop_items.lua"
local REMOTE_SHOP_ITEMS_URL = "https://raw.githubusercontent.com/anatoliyredisovikh-bit/ONE-Test/refs/heads/main/shop_items.lua"

-- ------------------------------------------------------------------
-- 2. ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
-- ------------------------------------------------------------------
local tmpfs = component.proxy(computer.tmpAddress())
local function getRealTimestamp()
    local handle = tmpfs.open("/time", "w")
    tmpfs.write(handle, "time")
    tmpfs.close(handle)
    return tmpfs.lastModified("/time") / 1000 + TIMEZONE_OFFSET
end
local function getRealTimeString() return os.date("%H:%M:%S", getRealTimestamp()) end
local function getRealDateTimeString() return os.date("%d.%m.%Y %H:%M:%S", getRealTimestamp()) end
local function stamp() return getRealDateTimeString() end
local function num(v, d) local n = tonumber(v); return n ~= nil and n or (d or 0) end
local function trim(v) local s = string.format("%.4f", num(v, 0)):gsub("0+$", ""):gsub("%.$", ""); return s == "" and "0" or s end
local function clone(v) if type(v) ~= "table" then return v end; local r = {}; for k, n in pairs(v) do r[k] = clone(n) end; return r end
local function tableSize(t) local c = 0; for _ in pairs(t) do c = c + 1 end; return c end
local function ulen(v) return unicode.len(tostring(v or "")) end
local function usub(v, a, b) return unicode.sub(tostring(v or ""), a, b) end
local function trunc(v, w)
    v = tostring(v or ""); w = math.max(1, tonumber(w) or 1)
    if ulen(v) <= w then return v end
    return w <= 1 and usub(v, 1, w) or usub(v, 1, w - 1) .. "…"
end

-- ------------------------------------------------------------------
-- 3. ГЛОБАЛЬНЫЕ ТАБЛИЦЫ
-- ------------------------------------------------------------------
local players = {}
local globalStats = { totalReports = 0, totalBuys = 0, totalSells = 0 }
local feedbacks = {}
local buyCatalog = {}
local sellCatalog = {}
local terminals = {}
local sessions = {}
local owner = nil
local markets = {}
local shopPaused = false

-- ------------------------------------------------------------------
-- 4. ФУНКЦИЯ ЛОГИРОВАНИЯ
-- ------------------------------------------------------------------
local function logEvent(msg)
    local line = "[" .. getRealDateTimeString() .. "] " .. msg
    print(line)
end

-- ------------------------------------------------------------------
-- 5. ФУНКЦИИ СОХРАНЕНИЯ
-- ------------------------------------------------------------------
local function savePlayers()
    local file = io.open(DB_PATH, "w")
    file:write(serialization.serialize(players))
    file:close()
end
local function saveGlobalStats()
    local file = io.open(STATS_PATH, "w")
    file:write(serialization.serialize(globalStats))
    file:close()
end
local function saveFeedbacks()
    local file = io.open(FEEDBACKS_PATH, "w")
    file:write(serialization.serialize(feedbacks))
    file:close()
end

-- ------------------------------------------------------------------
-- 6. ФУНКЦИИ РАССЫЛКИ КАТАЛОГА
-- ------------------------------------------------------------------
local function directPush(address, action, data)
    if address and address ~= "" then
        local msg = serialization.serialize({op="push", action=action, data=data})
        modem.send(address, 0xffef, msg)
        modem.send(address, 0xfffe, msg)
        logEvent("Push отправлен на " .. address .. " (порты 0xffef, 0xfffe)")
    end
end

local function broadcast(action, data)
    local msg = serialization.serialize({op="push", action=action, data=data})
    modem.broadcast(0xffef, msg)
    modem.broadcast(0xfffe, msg)
    logEvent("Broadcast отправлен (порты 0xffef, 0xfffe)")
end

local function broadcastSellCatalog()
    local data = {
        action = "catalog_update",
        catalog = "sell",
        items = sellCatalog
    }
    local count = 0
    for address, info in pairs(terminals) do
        directPush(address, "catalog_update", data)
        count = count + 1
    end
    broadcast("catalog_update", data)
    logEvent("Каталог скупки разослан: " .. count .. " терминалам + broadcast")
end

local function saveCatalog()
    local file = io.open(CATALOG_PATH, "w")
    file:write(serialization.serialize({ buyCatalog = buyCatalog, sellCatalog = sellCatalog }))
    file:close()
    broadcastSellCatalog()
end

local function registerTerminal(address, id)
    if not terminals[address] then
        terminals[address] = { address = address, id = id or "TERM-"..tostring(address):sub(1,8), lastSeen = computer.uptime() }
        logEvent("Терминал зарегистрирован: " .. address)
    else
        terminals[address].lastSeen = computer.uptime()
    end
    directPush(address, "catalog_update", { action = "catalog_update", catalog = "sell", items = sellCatalog })
end

-- ------------------------------------------------------------------
-- 7. ЗАГРУЗКА ДАННЫХ
-- ------------------------------------------------------------------
if filesystem.exists(DB_PATH) then
    local file = io.open(DB_PATH, "r")
    local raw = file:read("*a")
    file:close()
    if raw and #raw > 0 then
        local ok, data = pcall(serialization.unserialize, raw)
        if ok and data then players = data end
    end
end

if filesystem.exists(STATS_PATH) then
    local file = io.open(STATS_PATH, "r")
    local raw = file:read("*a")
    file:close()
    if raw and #raw > 0 then
        local ok, data = pcall(serialization.unserialize, raw)
        if ok and data then
            globalStats.totalReports = data.totalReports or 0
            globalStats.totalBuys = data.totalBuys or 0
            globalStats.totalSells = data.totalSells or 0
        end
    end
end

if filesystem.exists(FEEDBACKS_PATH) then
    local file = io.open(FEEDBACKS_PATH, "r")
    local raw = file:read("*a")
    file:close()
    if raw and #raw > 0 then
        local ok, data = pcall(serialization.unserialize, raw)
        if ok and type(data) == "table" then feedbacks = data end
    end
end

if filesystem.exists(CATALOG_PATH) then
    local file = io.open(CATALOG_PATH, "r")
    local raw = file:read("*a")
    file:close()
    if raw and #raw > 0 then
        local ok, data = pcall(serialization.unserialize, raw)
        if ok and type(data) == "table" then
            buyCatalog = data.buyCatalog or {}
            sellCatalog = data.sellCatalog or {}
        end
    end
end

-- ------------------------------------------------------------------
-- 7.1 ЗАГРУЗКА ИЗ ЛОКАЛЬНОГО ФАЙЛА shop_items.lua
-- ------------------------------------------------------------------
local function importSellItemsFromFile()
    if not filesystem.exists(SHOP_ITEMS_FILE) then
        return false
    end
    local ok, chunk = pcall(loadfile, SHOP_ITEMS_FILE)
    if not ok or type(chunk) ~= "function" then
        print("Ошибка загрузки " .. SHOP_ITEMS_FILE .. ": " .. tostring(chunk))
        return false
    end
    local ok2, data = pcall(chunk)
    if not ok2 or type(data) ~= "table" or type(data.sellItems) ~= "table" then
        print("Неверный формат " .. SHOP_ITEMS_FILE)
        return false
    end
    local newCatalog = {}
    for _, item in ipairs(data.sellItems) do
        table.insert(newCatalog, {
            displayName = item.displayName or "",
            internalName = item.internalName or "",
            damage = item.damage or 0,
            priceCoin = item.price or 0,
            priceEma = 0,
            article = tostring(item.internalName):sub(1, 10),
            enabled = true,
            maxQty = item.qty or 0,
        })
    end
    sellCatalog = newCatalog
    saveCatalog()
    print("Импортирован каталог скупки из " .. SHOP_ITEMS_FILE .. ", позиций: " .. #sellCatalog)
    return true
end

-- ------------------------------------------------------------------
-- 7.2 ЗАГРУЗКА ИЗ УДАЛЁННОГО РЕПОЗИТОРИЯ
-- ------------------------------------------------------------------
local function loadRemoteSellItems()
    if not component.isAvailable("internet") then
        logEvent("⚠️ Интернет-карта не установлена, удалённая загрузка недоступна")
        return false
    end

    local internet = require("internet")
    local ok, response = pcall(function()
        return internet.request(REMOTE_SHOP_ITEMS_URL, nil, {
            ["Connection"] = "close",
            ["Timeout"] = 5
        })
    end)

    if not ok or not response then
        logEvent("❌ Не удалось подключиться к удалённому файлу")
        return false
    end

    local content = ""
    for chunk in response do
        content = content .. chunk
    end

    -- Сохраняем временный файл
    local tmpFile = "/tmp/remote_shop_items.lua"
    local f = io.open(tmpFile, "w")
    if not f then
        logEvent("❌ Не удалось создать временный файл")
        return false
    end
    f:write(content)
    f:close()

    -- Загружаем данные из временного файла
    local ok, data = pcall(dofile, tmpFile)
    if not ok or type(data) ~= "table" or type(data.sellItems) ~= "table" then
        logEvent("❌ Неверный формат удалённого файла")
        pcall(filesystem.remove, tmpFile)
        return false
    end

    -- Преобразуем данные в формат sellCatalog
    local newCatalog = {}
    for _, item in ipairs(data.sellItems) do
        table.insert(newCatalog, {
            displayName = item.displayName or "",
            internalName = item.internalName or "",
            damage = item.damage or 0,
            priceCoin = item.price or 0,
            priceEma = 0,
            article = tostring(item.internalName):sub(1, 10),
            enabled = true,
            maxQty = item.qty or 0,
        })
    end

    sellCatalog = newCatalog
    saveCatalog()
    logEvent("✅ Загружен каталог скупки из удалённого файла, позиций: " .. #sellCatalog)
    pcall(filesystem.remove, tmpFile)
    return true
end

-- ------------------------------------------------------------------
-- 7.3 ИНИЦИАЛИЗАЦИЯ КАТАЛОГА
-- ------------------------------------------------------------------
if #sellCatalog == 0 then
    if not importSellItemsFromFile() then
        -- Пробуем загрузить из удалённого репозитория
        if not loadRemoteSellItems() then
            sellCatalog = {
                { displayName = "Железный слиток", internalName = "minecraft:iron_ingot", damage = 0, priceCoin = 1, priceEma = 0, article = "#SELL-001", enabled = true, maxQty = 0 },
            }
            saveCatalog()
        end
    end
end
if #buyCatalog == 0 then
    buyCatalog = {
        { displayName = "Алмаз", internalName = "minecraft:diamond", damage = 0, priceCoin = 10, priceEma = 0, article = "#VIP-001", enabled = true, maxQty = 0 },
    }
    saveCatalog()
end

-- ------------------------------------------------------------------
-- 8. СЕССИИ И ПОЛЬЗОВАТЕЛИ
-- ------------------------------------------------------------------
local function getOrCreatePlayer(name)
    name = tostring(name)
    if not players[name] then
        players[name] = {
            balance = 0.0,
            transactions = 0,
            regDate = stamp(),
            agreed = false,
            banned = false,
            hasFeedback = false
        }
        savePlayers()
    end
    return players[name]
end

local function validateSession(name, token)
    local s = sessions[name]
    return s and s.token == token and os.time() - (s.lastAction or 0) < SESSION_TIMEOUT
end

-- ------------------------------------------------------------------
-- 9. ОБРАБОТКА МОДЕМНЫХ СООБЩЕНИЙ
-- ------------------------------------------------------------------
modem.open(0xffef)
modem.open(0xfffe)

local function isAdmin(from)
    return from == owner
end

local function handleOldRequest(from, port, msg)
    local op = msg.op

    if op == "register" then
        if msg.password ~= ACCESS_PASSWORD then
            modem.send(from, 0xffef, serialization.serialize({op="error", message="Неверный пароль"}))
            logEvent("Попытка подключения с неверным паролем от " .. from)
            return
        end
        if not owner then owner = from end
        if not markets[from] then markets[from] = true end
        registerTerminal(from, msg.terminalId)
        modem.send(from, 0xffef, serialization.serialize({op="welcome", owner=(from==owner), shopPaused=shopPaused}))
        logEvent("Терминал зарегистрирован: " .. from)
        return

    elseif op == "enter" then
        if shopPaused then
            modem.send(from, 0xffef, serialization.serialize({op="error", message="Магазин на паузе"}))
            return
        end
        local name = msg.name
        if not name or name == "" then return end
        local player = getOrCreatePlayer(name)
        if player.banned then
            modem.send(from, 0xffef, serialization.serialize({op="error", message="Вы забанены"}))
            return
        end
        local token
        local s = sessions[name]
        if s and os.time() - (s.lastAction or 0) < SESSION_TIMEOUT then
            token = s.token
            s.lastAction = os.time()
        else
            token = tostring(math.floor(math.random() * 900000000 + 100000000))
            sessions[name] = { token = token, lastAction = os.time() }
        end
        modem.send(from, 0xffef, serialization.serialize({
            op = "welcome",
            status = "ok",
            token = token,
            balance = player.balance,
            transactions = player.transactions,
            regDate = player.regDate,
            agreed = player.agreed,
            shopPaused = shopPaused
        }))
        logEvent(name .. " вошёл")
        return

    elseif op == "getAccount" then
        if not validateSession(msg.name, msg.token) then
            modem.send(from, 0xffef, serialization.serialize({op="accountData", error=true, message="Токен устарел"}))
            return
        end
        local player = players[msg.name]
        if player then
            sessions[msg.name].lastAction = os.time()
            modem.send(from, 0xffef, serialization.serialize({
                op = "accountData",
                data = {
                    balance = player.balance,
                    transactions = player.transactions,
                    regDate = player.regDate,
                    agreed = player.agreed,
                    shopPaused = shopPaused
                }
            }))
        end
        return

    elseif op == "sell" then
        if shopPaused then
            modem.send(from, 0xffef, serialization.serialize({op="error", message="Магазин на паузе"}))
            return
        end
        if not validateSession(msg.name, msg.token) then return end
        local player = players[msg.name]
        if not player or player.banned then return end
        local value = tonumber(msg.value) or 0
        player.balance = (player.balance or 0) + value
        player.transactions = (player.transactions or 0) + 1
        sessions[msg.name].lastAction = os.time()
        globalStats.totalSells = (globalStats.totalSells or 0) + 1
        savePlayers(); saveGlobalStats()
        logEvent(string.format("💰 %s продал(а) предмет '%s' x%d за %.2f", msg.name, msg.item, msg.qty or 0, value))
        return

    elseif op == "buy" then
        if shopPaused then
            modem.send(from, 0xffef, serialization.serialize({op="error", message="Магазин на паузе"}))
            return
        end
        if not validateSession(msg.name, msg.token) then return end
        local player = players[msg.name]
        if not player or player.banned then return end
        local value = tonumber(msg.value) or 0
        player.balance = (player.balance or 0) - value
        player.transactions = (player.transactions or 0) + 1
        sessions[msg.name].lastAction = os.time()
        globalStats.totalBuys = (globalStats.totalBuys or 0) + 1
        savePlayers(); saveGlobalStats()
        logEvent(string.format("🛒 %s купил(а) предмет '%s' x%d за %.2f", msg.name, msg.item, msg.qty or 0, value))
        return

    elseif op == "report" then
        if not validateSession(msg.name, msg.token) then return end
        globalStats.totalReports = (globalStats.totalReports or 0) + 1
        saveGlobalStats()
        local file = io.open(REPORTS_LOG, "a")
        if file then
            file:write("[" .. msg.time .. "] " .. msg.name .. ": " .. msg.text .. "\n")
            file:close()
        end
        logEvent("📩 Репорт от " .. msg.name .. ": " .. msg.text)
        return

    elseif op == "agree" then
        if not validateSession(msg.name, msg.token) then
            modem.send(from, 0xffef, serialization.serialize({op="agree", error=true, message="Токен устарел"}))
            return
        end
        local player = players[msg.name]
        if player then
            player.agreed = true
            sessions[msg.name].lastAction = os.time()
            savePlayers()
            modem.send(from, 0xffef, serialization.serialize({op="agree", success=true, agreed=true}))
            logEvent("📝 " .. msg.name .. " принял пользовательское соглашение")
        else
            modem.send(from, 0xffef, serialization.serialize({op="agree", error=true, message="Игрок не найден"}))
        end
        return

    elseif op == "get_feedbacks" then
        if not validateSession(msg.name, msg.token) then
            modem.send(from, 0xffef, serialization.serialize({op="feedbacks_list", error="Токен устарел"}))
            return
        end
        local player = players[msg.name]
        modem.send(from, 0xffef, serialization.serialize({
            op = "feedbacks_list",
            feedbacks = feedbacks,
            hasFeedback = player and player.hasFeedback or false
        }))
        return

    elseif op == "add_feedback" then
        if not validateSession(msg.name, msg.token) then
            modem.send(from, 0xffef, serialization.serialize({op="add_feedback_response", success=false, error="Токен устарел"}))
            return
        end
        local player = players[msg.name]
        if not player then
            modem.send(from, 0xffef, serialization.serialize({op="add_feedback_response", success=false, error="Игрок не найден"}))
            return
        end
        if player.hasFeedback then
            modem.send(from, 0xffef, serialization.serialize({op="add_feedback_response", success=false, error="Вы уже оставляли отзыв"}))
            return
        end
        table.insert(feedbacks, 1, { name = msg.name, text = msg.text, time = msg.time })
        player.hasFeedback = true
        saveFeedbacks(); savePlayers()
        modem.send(from, 0xffef, serialization.serialize({op="add_feedback_response", success=true}))
        logEvent("📝 Новый отзыв от " .. msg.name .. ": " .. msg.text)
        return

    elseif op == "request_catalog" then
        modem.send(from, 0xffef, serialization.serialize({
            op = "catalog_data",
            catalog = "sell",
            items = sellCatalog
        }))
        logEvent("Клиент " .. from .. " запросил каталог")
        return

    elseif op == "sync_catalog" then
        if not isAdmin(from) then
            modem.send(from, 0xffef, serialization.serialize({op="error", message="Доступ запрещён"}))
            return
        end
        broadcastSellCatalog()
        modem.send(from, 0xffef, serialization.serialize({op="sync_catalog_response", success=true}))
        logEvent("Принудительная синхронизация каталога по запросу от " .. from)
        return

    elseif op == "add_catalog_item" then
        if not isAdmin(from) then
            modem.send(from, 0xffef, serialization.serialize({op="error", message="Доступ запрещён"}))
            return
        end
        local catalogType = tostring(msg.catalog or "buy")
        local item = {
            displayName = tostring(msg.displayName or ""),
            internalName = tostring(msg.internalName or ""),
            damage = math.floor(num(msg.damage, 0)),
            priceCoin = num(msg.priceCoin, 0),
            priceEma = num(msg.priceEma, 0),
            article = tostring(msg.article or ""),
            enabled = msg.enabled ~= false,
            maxQty = num(msg.maxQty, 0)
        }
        if item.displayName == "" or item.internalName == "" then
            modem.send(from, 0xffef, serialization.serialize({op="error", message="Название и ID обязательны"}))
            return
        end
        local catalog = (catalogType == "sell" and sellCatalog) or buyCatalog
        table.insert(catalog, item)
        saveCatalog()
        logEvent("Админ добавил товар в каталог " .. catalogType .. ": " .. item.displayName)
        modem.send(from, 0xffef, serialization.serialize({op="add_catalog_item_response", success=true, index=#catalog}))
        return

    elseif op == "remove_catalog_item" then
        if not isAdmin(from) then
            modem.send(from, 0xffef, serialization.serialize({op="error", message="Доступ запрещён"}))
            return
        end
        local catalogType = tostring(msg.catalog or "buy")
        local idx = math.floor(num(msg.index, 0))
        local catalog = (catalogType == "sell" and sellCatalog) or buyCatalog
        if idx < 1 or idx > #catalog then
            modem.send(from, 0xffef, serialization.serialize({op="error", message="Неверный индекс"}))
            return
        end
        table.remove(catalog, idx)
        saveCatalog()
        logEvent("Админ удалил товар из каталога " .. catalogType .. " с индексом " .. idx)
        modem.send(from, 0xffef, serialization.serialize({op="remove_catalog_item_response", success=true}))
        return

    elseif op == "update_catalog_item" then
        if not isAdmin(from) then
            modem.send(from, 0xffef, serialization.serialize({op="error", message="Доступ запрещён"}))
            return
        end
        local catalogType = tostring(msg.catalog or "buy")
        local idx = math.floor(num(msg.index, 0))
        local catalog = (catalogType == "sell" and sellCatalog) or buyCatalog
        if idx < 1 or idx > #catalog then
            modem.send(from, 0xffef, serialization.serialize({op="error", message="Неверный индекс"}))
            return
        end
        local old = catalog[idx]
        catalog[idx] = {
            displayName = tostring(msg.displayName or old.displayName),
            internalName = tostring(msg.internalName or old.internalName),
            damage = math.floor(num(msg.damage, old.damage or 0)),
            priceCoin = num(msg.priceCoin, old.priceCoin or 0),
            priceEma = num(msg.priceEma, old.priceEma or 0),
            article = tostring(msg.article or old.article or ""),
            enabled = msg.enabled ~= nil and msg.enabled or old.enabled,
            maxQty = num(msg.maxQty, old.maxQty or 0)
        }
        saveCatalog()
        logEvent("Админ обновил товар в каталоге " .. catalogType .. " с индексом " .. idx)
        modem.send(from, 0xffef, serialization.serialize({op="update_catalog_item_response", success=true}))
        return

    elseif op == "get_catalog" or op == "get_sell_catalog" then
        local catalogType = tostring(msg.catalog or "buy")
        if op == "get_sell_catalog" then catalogType = "sell" end
        local catalog = (catalogType == "sell" and sellCatalog) or buyCatalog
        modem.send(from, 0xffef, serialization.serialize({
            op = "catalog_data",
            catalog = catalogType,
            items = catalog
        }))
        return
    end

    modem.send(from, 0xffef, serialization.serialize({op="error", message="Неизвестная команда"}))
end

-- ------------------------------------------------------------------
-- 10. АДМИН-ПАНЕЛЬ
-- ------------------------------------------------------------------
local WIDTH, HEIGHT = gpu.getResolution()
local maxW, maxH = gpu.maxResolution()
if maxW and maxH and (WIDTH < maxW or HEIGHT < maxH) then
    gpu.setResolution(maxW, maxH)
    WIDTH, HEIGHT = gpu.getResolution()
end

local C = {
    bg = 0x0C0C0C, panel = 0x11191D, header = 0x0A0A0A, line = 0x27BDEC,
    accent = 0x0C9A76, white = 0xFFFFFF, gray = 0xAAAAAA, dark = 0x555555,
    green = 0x55FF55, yellow = 0xFFAA00, red = 0xFF5555, cyan = 0x55FFFF,
    selected = 0x002440, input = 0x1A1A1A, button = 0x0A502D, alt = 0x1A5A6B,
    danger = 0x8B1A1A, pause = 0x8A5A00, orange = 0xFF8800, magenta = 0xFF44FF,
}

local function fill(x, y, w, h, bg, ch)
    if w <= 0 or h <= 0 then return end
    gpu.setBackground(bg or C.bg); gpu.fill(x, y, w, h, ch or " ")
end
local function write(x, y, v, fg, bg)
    if y < 1 or y > HEIGHT or x > WIDTH then return end
    v = tostring(v or ""); if x < 1 then v = usub(v, 2 - x); x = 1 end
    if v == "" then return end
    gpu.setForeground(fg or C.white); gpu.setBackground(bg or C.bg)
    gpu.set(x, y, trunc(v, WIDTH - x + 1))
end
local function centerX(v, left, w)
    left = left or 1; w = w or WIDTH
    return left + math.max(0, math.floor((w - ulen(v)) / 2))
end
local function center(y, v, fg, bg, left, w)
    write(centerX(v, left, w), y, v, fg, bg)
end
local function box(x, y, w, h, fg, bg)
    if w < 2 or h < 2 then return end
    fg = fg or C.line; bg = bg or C.bg
    write(x, y, "┌" .. string.rep("─", w - 2) .. "┐", fg, bg)
    for r = y + 1, y + h - 2 do
        write(x, r, "│", fg, bg)
        write(x + w - 1, r, "│", fg, bg)
    end
    write(x, y + h - 1, "└" .. string.rep("─", w - 2) .. "┘", fg, bg)
end

local ui = {
    tab = "buy",
    selected = 1,
    scroll = 0,
    search = "",
    searchFocused = false,
    activeField = nil,
    fields = {},
    buttons = {},
    rows = {},
    form = {},
    message = "Сервер запущен",
    messageColor = C.green,
    lastDraw = 0
}

local tabs = {
    { id = "buy", title = "ПОКУПКИ" },
    { id = "sell", title = "ПРОДАЖИ" },
    { id = "users", title = "ИГРОКИ" },
    { id = "stats", title = "СТАТИСТИКА" },
    { id = "reports", title = "РЕПОРТЫ" },
    { id = "feedbacks", title = "ОТЗЫВЫ" },
    { id = "admins", title = "АДМИНИСТРАТОРЫ" },
    { id = "journal", title = "ЖУРНАЛ" },
    { id = "storeStatus", title = "ПРИОСТАНОВИТЬ МАГАЗИН" },
    { id = "sync", title = "СИНХРОНИЗАЦИЯ" },  -- НОВАЯ ВКЛАДКА
}

local TOP = 4
local BOTTOM = 3
local MAIN_Y = TOP + 1
local MAIN_H = HEIGHT - TOP - BOTTOM
local LEFT_W = math.max(38, math.floor(WIDTH * 0.52))
local RIGHT_X = LEFT_W + 2
local RIGHT_W = WIDTH - RIGHT_X
local LIST_Y = MAIN_Y + 3
local LIST_H = MAIN_H - 4

local function msg(v, c) ui.message = tostring(v or ""); ui.messageColor = c or C.white end
local function clearControls() ui.fields = {}; ui.buttons = {}; ui.rows = {} end
local function addField(id, label, value, x, y, w, opt)
    opt = opt or {}
    local f = { id = id, label = label, value = tostring(value or ""), x = x, y = y, w = w, numeric = opt.numeric == true, readonly = opt.readonly == true }
    ui.fields[#ui.fields + 1] = f
    return f
end
local function addButton(id, label, x, y, w, bg, fg)
    local b = { id = id, label = label, x = x, y = y, w = w, bg = bg or C.button, fg = fg or C.white }
    ui.buttons[#ui.buttons + 1] = b
    fill(x, y, w, 1, b.bg)
    center(y, label, b.fg, b.bg, x, w)
    return b
end
local function fby(id) for _, f in ipairs(ui.fields) do if f.id == id then return f end end end
local function fv(id) local f = fby(id); return f and f.value or "" end
local function drawField(f, focus)
    write(f.x, f.y, f.label, C.gray, C.bg)
    local ix = f.x + 15
    local iw = math.max(8, f.w - 15)
    fill(ix, f.y, iw, 1, C.input)
    write(ix + 1, f.y, trunc(f.value, iw - 2), f.readonly and C.dark or (focus and C.cyan or C.white), C.input)
end

local function getCatalog(tab)
    if tab == "buy" then return buyCatalog else return sellCatalog end
end
local function setCatalog(tab, catalog)
    if tab == "buy" then buyCatalog = catalog else sellCatalog = catalog end
    saveCatalog()
end

local function listData()
    local r = {}
    local q = tostring(ui.search or ""):lower()
    if ui.tab == "buy" or ui.tab == "sell" then
        local src = getCatalog(ui.tab)
        for i, item in ipairs(src) do
            local name = tostring(item.displayName or item.internalName or "")
            if q == "" or name:lower():find(q, 1, true) then
                r[#r + 1] = { sourceIndex = i, title = name, sub = tostring(item.internalName or "") .. " | " .. trim(item.priceCoin or 0) .. " COINA" .. (item.maxQty and item.maxQty > 0 and " | Остаток: " .. item.maxQty or ""), raw = item }
            end
        end
        table.sort(r, function(a, b) return a.title:lower() < b.title:lower() end)
    elseif ui.tab == "users" then
        for name, u in pairs(players) do
            if q == "" or tostring(name):lower():find(q, 1, true) then
                r[#r + 1] = { key = name, title = name, sub = "Баланс: " .. trim(u.balance) .. " | Транзакций: " .. (u.transactions or 0), raw = u }
            end
        end
        table.sort(r, function(a, b) return a.title:lower() < b.title:lower() end)
    elseif ui.tab == "stats" then
        r = { { title = "Статистика", sub = "", raw = globalStats } }
    elseif ui.tab == "reports" then
        local reports = {}
        if filesystem.exists(REPORTS_LOG) then
            local file = io.open(REPORTS_LOG, "r")
            local content = file:read("*a")
            file:close()
            for line in content:gmatch("[^\n]+") do
                table.insert(reports, line)
            end
        end
        for i = #reports, 1, -1 do
            local line = reports[i]
            if q == "" or line:lower():find(q, 1, true) then
                r[#r + 1] = { key = i, title = trunc(line, 30), sub = "", raw = line }
            end
        end
    elseif ui.tab == "feedbacks" then
        for i = #feedbacks, 1, -1 do
            local f = feedbacks[i]
            local title = (f.name or "") .. ": " .. (f.text or "")
            if q == "" or title:lower():find(q, 1, true) then
                r[#r + 1] = { key = i, title = trunc(title, 30), sub = f.time or "", raw = f }
            end
        end
    elseif ui.tab == "admins" then
        r = { { key = 1, title = ADMIN_NAME, sub = "Главный администратор", raw = {} } }
    elseif ui.tab == "journal" then
        r = { { title = "Журнал событий", sub = "В разработке", raw = {} } }
    elseif ui.tab == "storeStatus" then
        r = { { title = "Статус магазина", sub = shopPaused and "ПРИОСТАНОВЛЕН" or "АКТИВЕН", raw = { paused = shopPaused } } }
    elseif ui.tab == "sync" then
        r = { { title = "Синхронизация каталога", sub = "Загрузить из удалённого репозитория", raw = {} } }
    end
    return r
end

local function selected(list)
    if #list == 0 then return nil end
    ui.selected = math.max(1, math.min(ui.selected, #list))
    return list[ui.selected]
end

local function loadForm()
    local e = selected(listData())
    ui.form = {}
    if ui.tab == "buy" or ui.tab == "sell" then
        local it = e and e.raw or {}
        ui.form = {
            displayName = tostring(it.displayName or ""),
            internalName = tostring(it.internalName or ""),
            damage = tostring(it.damage or 0),
            priceCoin = trim(it.priceCoin or 0),
            priceEma = trim(it.priceEma or 0),
            article = tostring(it.article or ""),
            enabled = it.enabled ~= false,
            maxQty = tostring(it.maxQty or 0),
            sourceIndex = e and e.sourceIndex or nil
        }
    elseif ui.tab == "users" then
        local u = e and e.raw or {}
        ui.form = {
            name = e and e.key or "",
            balance = trim(u.balance or 0),
            transactions = tostring(u.transactions or 0),
            regDate = u.regDate or "",
            agreed = u.agreed == true,
            banned = u.banned == true,
            hasFeedback = u.hasFeedback == true,
            banReason = u.banReason or "",
            banDuration = tostring(u.banDuration or 0),
            bannedBy = u.bannedBy or "",
            bannedAt = u.bannedAt or ""
        }
    elseif ui.tab == "stats" then
        ui.form = clone(globalStats)
    elseif ui.tab == "reports" then
        ui.form = { report = e and e.raw or "" }
    elseif ui.tab == "feedbacks" then
        ui.form = { name = (e and e.raw and e.raw.name) or "", text = (e and e.raw and e.raw.text) or "", time = (e and e.raw and e.raw.time) or "" }
    elseif ui.tab == "admins" then
        ui.form = { adminName = ADMIN_NAME }
    elseif ui.tab == "journal" then
        ui.form = { journal = "Журнал событий (можно расширить)" }
    elseif ui.tab == "storeStatus" then
        ui.form = { paused = shopPaused }
    elseif ui.tab == "sync" then
        ui.form = { remoteUrl = REMOTE_SHOP_ITEMS_URL }
    end
end

local function catalogEditor()
    local x = RIGHT_X; local w = RIGHT_W
    local title = (ui.tab == "buy" and "РЕДАКТОР ПОКУПКИ" or "РЕДАКТОР ПРОДАЖИ")
    write(x, MAIN_Y + 1, title, C.accent, C.bg)
    addField("displayName", "Название:", ui.form.displayName, x, MAIN_Y + 4, w - 2)
    addField("internalName", "ID предмета:", ui.form.internalName, x, MAIN_Y + 6, w - 2)
    addField("damage", "Damage:", ui.form.damage, x, MAIN_Y + 8, w - 2, { numeric = true })
    addField("priceCoin", "COINA:", ui.form.priceCoin, x, MAIN_Y + 10, w - 2, { numeric = true })
    addField("priceEma", "EMA:", ui.form.priceEma, x, MAIN_Y + 12, w - 2, { numeric = true })
    addField("article", "Артикул:", ui.form.article, x, MAIN_Y + 14, w - 2)
    addField("maxQty", "Остаток:", ui.form.maxQty, x, MAIN_Y + 16, w - 2, { numeric = true })
    write(x, MAIN_Y + 18, "Активен:", C.gray, C.bg)
    addButton("toggle_enabled", "[ " .. (ui.form.enabled and "ДА" or "НЕТ") .. " ]", x + 15, MAIN_Y + 18, 10, ui.form.enabled and C.button or C.danger)
    local y = MAIN_Y + 21
    addButton("save_item", "[ СОХРАНИТЬ ]", x, y, 18, C.button)
    addButton("new_item", "[ НОВЫЙ ]", x + 20, y, 14, C.alt)
    addButton("delete_item", "[ УДАЛИТЬ ]", x + 36, y, 16, C.danger)
    write(x, MAIN_Y + 24, "Всего товаров: " .. #getCatalog(ui.tab), C.gray, C.bg)
end

local function drawRight(e)
    fill(RIGHT_X - 1, MAIN_Y, RIGHT_W + 1, MAIN_H, C.bg)
    box(RIGHT_X - 1, MAIN_Y, RIGHT_W + 1, MAIN_H, C.line, C.bg)
    local x = RIGHT_X; local w = RIGHT_W

    if ui.tab == "buy" or ui.tab == "sell" then
        catalogEditor()
    elseif ui.tab == "users" then
        write(x, MAIN_Y + 1, "РЕДАКТОР ИГРОКА", C.accent, C.bg)
        addField("name", "Игрок:", ui.form.name, x, MAIN_Y + 4, w - 2, { readonly = true })
        addField("balance", "Баланс:", ui.form.balance, x, MAIN_Y + 6, w - 2, { numeric = true })
        addField("transactions", "Транзакции:", ui.form.transactions, x, MAIN_Y + 8, w - 2, { numeric = true, readonly = true })
        addField("regDate", "Дата регистрации:", ui.form.regDate, x, MAIN_Y + 10, w - 2, { readonly = true })
        write(x, MAIN_Y + 12, "Соглашение: " .. (ui.form.agreed and "ПРИНЯТ" or "НЕ ПРИНЯТ"), ui.form.agreed and C.green or C.gray, C.bg)
        write(x, MAIN_Y + 13, "Отзыв оставлен: " .. (ui.form.hasFeedback and "ДА" or "НЕТ"), ui.form.hasFeedback and C.green or C.gray, C.bg)
        addField("banReason", "Причина бана:", ui.form.banReason, x, MAIN_Y + 15, w - 2)
        addField("banDuration", "Срок, сек:", ui.form.banDuration, x, MAIN_Y + 17, w - 2, { numeric = true })
        addField("bannedBy", "Администратор:", ui.form.bannedBy, x, MAIN_Y + 19, w - 2)
        write(x, MAIN_Y + 21, "Статус: " .. (ui.form.banned and "ЗАБЛОКИРОВАН" or "АКТИВЕН"), ui.form.banned and C.red or C.green, C.bg)
        local y = MAIN_Y + 23
        addButton("save_user", "[ СОХРАНИТЬ ]", x, y, 18, C.button)
        addButton(ui.form.banned and "unban_user" or "ban_user", ui.form.banned and "[ РАЗБАНИТЬ ]" or "[ ЗАБАНИТЬ ]", x + 20, y, 18, ui.form.banned and C.button or C.danger)
    elseif ui.tab == "stats" then
        write(x, MAIN_Y + 1, "СТАТИСТИКА", C.accent, C.bg)
        write(x, MAIN_Y + 4, "Покупок: " .. tostring(ui.form.totalBuys or 0), C.white, C.bg)
        write(x, MAIN_Y + 6, "Продаж:   " .. tostring(ui.form.totalSells or 0), C.white, C.bg)
        write(x, MAIN_Y + 8, "Оборот:   " .. tostring((ui.form.totalBuys or 0) + (ui.form.totalSells or 0)), C.white, C.bg)
        write(x, MAIN_Y + 10, "Репортов: " .. tostring(ui.form.totalReports or 0), C.white, C.bg)
        write(x, MAIN_Y + 12, "Игроков:  " .. tableSize(players), C.white, C.bg)
    elseif ui.tab == "reports" then
        write(x, MAIN_Y + 1, "РЕПОРТЫ (ЖАЛОБЫ)", C.accent, C.bg)
        if e and e.raw then
            write(x, MAIN_Y + 4, trunc(e.raw, RIGHT_W - 2), C.white, C.bg)
            addButton("resolve_report", "[ РАЗРЕШИТЬ ]", x, MAIN_Y + 7, 20, C.button)
        else
            write(x, MAIN_Y + 4, "Нет жалоб", C.gray, C.bg)
        end
    elseif ui.tab == "feedbacks" then
        write(x, MAIN_Y + 1, "ОТЗЫВЫ", C.accent, C.bg)
        if e and e.raw then
            addField("fb_name", "Игрок:", ui.form.name, x, MAIN_Y + 4, w - 2, { readonly = true })
            addField("fb_text", "Текст:", ui.form.text, x, MAIN_Y + 6, w - 2, { readonly = true })
            addField("fb_time", "Время:", ui.form.time, x, MAIN_Y + 8, w - 2, { readonly = true })
            addButton("delete_feedback", "[ УДАЛИТЬ ]", x, MAIN_Y + 11, 20, C.danger)
        else
            write(x, MAIN_Y + 4, "Отзывов нет", C.gray, C.bg)
        end
    elseif ui.tab == "admins" then
        write(x, MAIN_Y + 1, "АДМИНИСТРАТОРЫ", C.accent, C.bg)
        write(x, MAIN_Y + 4, "Главный администратор: " .. ADMIN_NAME, C.white, C.bg)
        addField("new_admin", "Новый админ (имя):", ui.form.newAdmin or "", x, MAIN_Y + 7, w - 2)
        local y = MAIN_Y + 10
        addButton("add_admin", "[ ДОБАВИТЬ ]", x, y, 18, C.button)
        addButton("remove_admin", "[ УДАЛИТЬ ]", x + 20, y, 18, C.danger)
    elseif ui.tab == "journal" then
        write(x, MAIN_Y + 1, "ЖУРНАЛ СОБЫТИЙ", C.accent, C.bg)
        write(x, MAIN_Y + 4, "Все важные события записываются в консоль.", C.gray, C.bg)
        write(x, MAIN_Y + 6, "Для просмотра полного журнала используйте", C.gray, C.bg)
        write(x, MAIN_Y + 7, "команду: cat /home/reports.log", C.gray, C.bg)
    elseif ui.tab == "storeStatus" then
        write(x, MAIN_Y + 1, "УПРАВЛЕНИЕ ДОСТУПНОСТЬЮ", C.accent, C.bg)
        local status = shopPaused and "ЗАКРЫТ" or "ОТКРЫТ"
        write(x, MAIN_Y + 4, "Текущий статус: " .. status, shopPaused and C.red or C.green, C.bg)
        addButton("toggle_pause", shopPaused and "[ ОТКРЫТЬ МАГАЗИН ]" or "[ ЗАКРЫТЬ МАГАЗИН ]", x, MAIN_Y + 7, 28, shopPaused and C.button or C.pause)
    elseif ui.tab == "sync" then
        write(x, MAIN_Y + 1, "СИНХРОНИЗАЦИЯ КАТАЛОГА", C.accent, C.bg)
        write(x, MAIN_Y + 4, "Загрузить каталог скупки из удалённого репозитория:", C.gray, C.bg)
        write(x, MAIN_Y + 5, REMOTE_SHOP_ITEMS_URL, C.cyan, C.bg)
        addButton("load_remote_catalog", "[ ЗАГРУЗИТЬ С GITHUB ]", x, MAIN_Y + 8, 28, C.button)
        write(x, MAIN_Y + 11, "Текущий каталог: " .. #sellCatalog .. " товаров", C.gray, C.bg)
        write(x, MAIN_Y + 13, "Последнее обновление: " .. (sellCatalog[1] and sellCatalog[1].updatedAt or "неизвестно"), C.gray, C.bg)
        write(x, MAIN_Y + 15, "Нажмите кнопку для загрузки актуального списка", C.gray, C.bg)
    end

    for i, f in ipairs(ui.fields) do
        drawField(f, ui.activeField == i)
    end
end

local function drawHeader()
    fill(1, 1, WIDTH, TOP, C.header)
    center(1, "──── PIM MARKET SERVER ────", C.accent, C.header)
    local x = 2
    for _, t in ipairs(tabs) do
        local w = ulen(t.title) + 4
        local active = ui.tab == t.id
        fill(x, 3, w, 1, active and C.selected or C.panel)
        center(3, t.title, active and C.cyan or C.gray, active and C.selected or C.panel, x, w)
        t.x = x; t.w = w
        x = x + w + 1
    end
    local a = "MODEM: " .. tostring(modem.address)
    write(math.max(1, WIDTH - ulen(a) - 1), 1, a, C.gray, C.header)
end

local function drawList(list)
    fill(1, MAIN_Y, LEFT_W, MAIN_H, C.bg)
    box(1, MAIN_Y, LEFT_W, MAIN_H, C.line, C.bg)
    write(3, MAIN_Y + 1, "ПОИСК:", C.gray, C.bg)
    local sx = 11
    local sw = LEFT_W - sx - 2
    fill(sx, MAIN_Y + 1, sw, 1, C.input)
    write(sx + 1, MAIN_Y + 1, trunc(ui.search, sw - 2), ui.searchFocused and C.cyan or C.white, C.input)
    ui.rows = {}
    local max = math.max(0, #list - LIST_H)
    ui.scroll = math.max(0, math.min(ui.scroll, max))
    for row = 1, LIST_H do
        local idx = ui.scroll + row
        local e = list[idx]
        local y = LIST_Y + row - 1
        fill(2, y, LEFT_W - 2, 1, idx == ui.selected and C.selected or C.bg)
        if e then
            local fg = idx == ui.selected and C.cyan or C.white
            write(3, y, trunc(e.title, LEFT_W - 5), fg, idx == ui.selected and C.selected or C.bg)
            ui.rows[#ui.rows + 1] = { y = y, index = idx }
        end
    end
    local info = "Всего: " .. tostring(#list)
    write(3, MAIN_Y + MAIN_H - 2, info, C.gray, C.bg)
end

local function drawBottom()
    local y = HEIGHT - BOTTOM + 1
    fill(1, y, WIDTH, BOTTOM, C.header)
    addButton("back", "< НАЗАД", 2, y + 1, 12, C.button)
    local info = "Сервер: ONLINE | Порт: 0xffef/0xfffe"
    write(29, y + 1, trunc(info, WIDTH - 31), C.green, C.header)
    write(WIDTH - 25, y + 1, "Esc — назад | выберите раздел мышкой", C.gray, C.header)
    if ui.message ~= "" then write(2, y, trunc(ui.message, WIDTH - 3), ui.messageColor, C.header) end
end

local function drawAll()
    clearControls()
    fill(1, 1, WIDTH, HEIGHT, C.bg)
    drawHeader()
    local list = listData()
    if #list == 0 then ui.selected = 0; ui.scroll = 0 elseif ui.selected <= 0 then ui.selected = 1 elseif ui.selected > #list then ui.selected = #list end
    drawList(list)
    local e = selected(list)
    drawRight(e)
    drawBottom()
    ui.lastDraw = computer.uptime()
end

local function reload() loadForm(); ui.activeField = nil; drawAll() end

-- ------------------------------------------------------------------
-- 11. ОБРАБОТЧИКИ ДЕЙСТВИЙ АДМИН-ПАНЕЛИ
-- ------------------------------------------------------------------
local function action(id)
    if id == "back" then
        ui.tab = "buy"
        ui.selected = 1
        ui.scroll = 0
        ui.search = ""
        ui.activeField = nil
        reload()
        return
    end

    if id == "toggle_enabled" then
        ui.form.enabled = not ui.form.enabled
        drawAll()
        return
    end

    if id == "save_item" then
        local name = fv("displayName")
        local internal = fv("internalName")
        if name == "" or internal == "" then
            msg("Название и ID предмета обязательны", C.red)
            drawAll()
            return
        end
        local src = getCatalog(ui.tab)
        local idx = ui.form.sourceIndex
        local item = {
            displayName = name,
            internalName = internal,
            damage = math.floor(num(fv("damage"), 0)),
            priceCoin = num(fv("priceCoin"), 0),
            priceEma = num(fv("priceEma"), 0),
            article = fv("article"),
            enabled = ui.form.enabled,
            maxQty = math.floor(num(fv("maxQty"), 0))
        }
        if idx and src[idx] then
            src[idx] = item
        else
            table.insert(src, item)
        end
        setCatalog(ui.tab, src)
        msg("Товар сохранён", C.green)
        ui.selected = 1
        reload()
        return
    end

    if id == "new_item" then
        ui.form = { displayName = "", internalName = "", damage = "0", priceCoin = "0", priceEma = "0", article = "", enabled = true, maxQty = "0", sourceIndex = nil }
        ui.activeField = nil
        drawAll()
        return
    end

    if id == "delete_item" then
        local src = getCatalog(ui.tab)
        local idx = ui.form.sourceIndex
        if not idx or not src[idx] then
            msg("Товар не выбран", C.red)
            drawAll()
            return
        end
        table.remove(src, idx)
        setCatalog(ui.tab, src)
        msg("Товар удалён", C.yellow)
        ui.selected = math.max(1, ui.selected - 1)
        reload()
        return
    end

    if id == "save_user" then
        local name = fv("name")
        if name == "" then msg("Имя игрока обязательно", C.red); drawAll(); return end
        local player = players[name]
        if not player then msg("Игрок не найден", C.red); drawAll(); return end
        player.balance = num(fv("balance"), player.balance)
        player.banReason = fv("banReason")
        player.banDuration = math.max(0, math.floor(num(fv("banDuration"), 0)))
        player.bannedBy = fv("bannedBy")
        savePlayers()
        msg("Данные игрока сохранены", C.green)
        reload()
        return
    end

    if id == "ban_user" then
        local name = fv("name")
        if name == "" then msg("Имя игрока обязательно", C.red); drawAll(); return end
        local player = players[name]
        if not player then msg("Игрок не найден", C.red); drawAll(); return end
        player.banned = true
        if fv("banReason") ~= "" then player.banReason = fv("banReason") else player.banReason = "Нарушение правил" end
        player.banDuration = math.max(0, math.floor(num(fv("banDuration"), 0)))
        player.bannedBy = fv("bannedBy") ~= "" and fv("bannedBy") or ADMIN_NAME
        player.bannedAt = stamp()
        savePlayers()
        msg("Игрок заблокирован", C.red)
        reload()
        return
    end

    if id == "unban_user" then
        local name = fv("name")
        if name == "" then msg("Имя игрока обязательно", C.red); drawAll(); return end
        local player = players[name]
        if not player then msg("Игрок не найден", C.red); drawAll(); return end
        player.banned = false
        player.banReason = nil
        player.banDuration = 0
        player.bannedBy = nil
        player.bannedAt = nil
        savePlayers()
        msg("Игрок разблокирован", C.green)
        reload()
        return
    end

    if id == "resolve_report" then
        local e = selected(listData())
        if e and e.raw then
            local oldContent = ""
            local file = io.open(REPORTS_LOG, "r")
            if file then
                oldContent = file:read("*a")
                file:close()
            end
            local lines = {}
            for line in oldContent:gmatch("[^\n]+") do
                if line ~= e.raw then table.insert(lines, line) end
            end
            file = io.open(REPORTS_LOG, "w")
            if file then
                file:write(table.concat(lines, "\n"))
                file:close()
            end
            msg("Репорт разрешён", C.green)
            reload()
        else
            msg("Репорт не выбран", C.red)
            drawAll()
        end
        return
    end

    if id == "delete_feedback" then
        local idx = 0
        for i, f in ipairs(feedbacks) do
            if f.name == ui.form.name and f.text == ui.form.text and f.time == ui.form.time then
                idx = i; break
            end
        end
        if idx > 0 then
            table.remove(feedbacks, idx)
            saveFeedbacks()
            msg("Отзыв удалён", C.green)
            reload()
        else
            msg("Отзыв не найден", C.red)
            drawAll()
        end
        return
    end

    if id == "add_admin" then
        local newAdmin = fv("new_admin")
        if newAdmin and newAdmin ~= "" then
            msg("Администратор " .. newAdmin .. " добавлен (демо)", C.green)
            reload()
        else
            msg("Введите имя", C.red)
            drawAll()
        end
        return
    end

    if id == "remove_admin" then
        local adminName = fv("new_admin")
        if adminName and adminName ~= "" and adminName ~= ADMIN_NAME then
            msg("Администратор " .. adminName .. " удалён (демо)", C.yellow)
            reload()
        else
            msg("Нельзя удалить главного админа или введите имя", C.red)
            drawAll()
        end
        return
    end

    if id == "toggle_pause" then
        shopPaused = not shopPaused
        msg(shopPaused and "Магазин закрыт" or "Магазин открыт", shopPaused and C.red or C.green)
        reload()
        return
    end

    -- НОВЫЙ ОБРАБОТЧИК ДЛЯ ЗАГРУЗКИ УДАЛЁННОГО КАТАЛОГА
    if id == "load_remote_catalog" then
        local success = loadRemoteSellItems()
        if success then
            msg("Каталог успешно загружен из удалённого репозитория", C.green)
            reload()
        else
            msg("Ошибка загрузки каталога, проверьте интернет-соединение", C.red)
            drawAll()
        end
        return
    end
end

-- ------------------------------------------------------------------
-- 12. ОБРАБОТКА СОБЫТИЙ ВВОДА/МЫШИ
-- ------------------------------------------------------------------
local function inside(x, y, c) return y == c.y and x >= c.x and x < c.x + c.w end
local function touch(x, y)
    for _, t in ipairs(tabs) do
        if y == 3 and x >= t.x and x < t.x + t.w then
            ui.tab = t.id; ui.selected = 1; ui.scroll = 0; ui.search = ""; ui.searchFocused = false; loadForm(); drawAll(); return
        end
    end
    if y == MAIN_Y + 1 and x >= 11 and x < LEFT_W - 1 then
        ui.searchFocused = true; ui.activeField = nil; drawAll(); return
    end
    for _, r in ipairs(ui.rows) do
        if y == r.y and x >= 2 and x <= LEFT_W then
            ui.selected = r.index; ui.searchFocused = false; loadForm(); drawAll(); return
        end
    end
    for i, f in ipairs(ui.fields) do
        local ix = f.x + 15; local iw = math.max(8, f.w - 15)
        if y == f.y and x >= ix and x < ix + iw and not f.readonly then
            ui.activeField = i; ui.searchFocused = false; drawAll(); return
        end
    end
    for _, b in ipairs(ui.buttons) do
        if inside(x, y, b) then ui.activeField = nil; ui.searchFocused = false; action(b.id); return end
    end
    ui.activeField = nil; ui.searchFocused = false; drawAll()
end

local function scroll(direction)
    local list = listData()
    local max = math.max(0, #list - LIST_H)
    ui.scroll = math.max(0, math.min(max, ui.scroll - direction * 3))
    if ui.selected < ui.scroll + 1 then ui.selected = ui.scroll + 1 end
    if ui.selected > ui.scroll + LIST_H then ui.selected = ui.scroll + LIST_H end
    drawAll()
end

local function key(char, code)
    if code == keyboard.keys.escape then
        ui.activeField = nil; ui.searchFocused = false; drawAll(); return
    end
    if ui.searchFocused then
        if code == keyboard.keys.back then
            ui.search = usub(ui.search, 1, -2)
        elseif code == keyboard.keys.enter or code == keyboard.keys.tab then
            ui.searchFocused = false
        elseif char and char >= 32 then
            ui.search = ui.search .. unicode.char(char)
        end
        ui.selected = 1; ui.scroll = 0; loadForm(); drawAll(); return
    end
    local f = ui.activeField and ui.fields[ui.activeField]
    if f and not f.readonly then
        if code == keyboard.keys.back then
            f.value = usub(f.value, 1, -2)
        elseif code == keyboard.keys.enter or code == keyboard.keys.tab then
            ui.activeField = nil
        elseif char and char >= 32 then
            local ch = unicode.char(char)
            if not f.numeric or ch:match("[%d%.,%-]") then f.value = f.value .. ch end
        end
        if f.id == "displayName" or f.id == "internalName" or f.id == "damage" or f.id == "priceCoin" or f.id == "priceEma" or f.id == "article" or f.id == "maxQty" then
            ui.form[f.id] = f.value
        elseif f.id == "name" or f.id == "balance" or f.id == "transactions" or f.id == "banReason" or f.id == "banDuration" or f.id == "bannedBy" or f.id == "new_admin" then
            ui.form[f.id] = f.value
        end
        drawAll(); return
    end
    if code == keyboard.keys.up then
        ui.selected = math.max(1, ui.selected - 1)
        if ui.selected <= ui.scroll then ui.scroll = math.max(0, ui.selected - 1) end
        loadForm(); drawAll()
    elseif code == keyboard.keys.down then
        local list = listData()
        ui.selected = math.min(#list, ui.selected + 1)
        if ui.selected > ui.scroll + LIST_H then ui.scroll = ui.selected - LIST_H end
        loadForm(); drawAll()
    end
end

-- ------------------------------------------------------------------
-- 13. ЗАПУСК
-- ------------------------------------------------------------------
loadForm()
drawAll()

while true do
    local ev = { event.pull(0.25) }
    local name = ev[1]
    if name == "modem_message" then
        local from = ev[3]
        local port = ev[4]
        local raw = ev[6]
        if port == 0xffef or port == 0xfffe then
            local ok, msg = pcall(serialization.unserialize, raw)
            if ok and type(msg) == "table" then
                handleOldRequest(from, port, msg)
            end
        end
    elseif name == "touch" then
        touch(ev[3], ev[4])
    elseif name == "scroll" then
        scroll(ev[5] or 0)
    elseif name == "key_down" then
        key(ev[3], ev[4])
    elseif name == "interrupted" then
        term.clear()
        print("PIM MARKET SERVER остановлен")
        print("Modem ID: " .. tostring(modem.address))
        print("Порты: 0xffef, 0xfffe")
        break
    end
    if computer.uptime() - ui.lastDraw > 2 then
        drawAll()
    end
end
