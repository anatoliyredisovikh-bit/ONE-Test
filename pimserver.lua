-- ============================================================
-- PIM MARKET SERVER + АДМИН-ПАНЕЛЬ (с библиотекой forms)
-- ============================================================

local component = require("component")
local event = require("event")
local serialization = require("serialization")
local filesystem = require("filesystem")
local gpu = component.gpu
local math = require("math")
local os = require("os")
local unicode = require("unicode")
local computer = require("computer")
local process = require("process")
local forms = require("forms")  -- подключаем библиотеку

local TIMEZONE_OFFSET = 3 * 3600

local modem = component.modem
modem.open(0xffef)
modem.open(0xfffe)

event.ignore("interrupted", function() end)
event.ignore("terminate", function() end)

-- ===== ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ =====
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

local function printLog(msg)
    print("[" .. getRealTimeString() .. "] " .. msg)
end

-- ===== СИСТЕМА АДМИНИСТРАТОРОВ =====
local ADMINS_PATH = "/home/admins.db"
local admins = {}
if filesystem.exists(ADMINS_PATH) then
    local file = io.open(ADMINS_PATH, "r")
    if file then
        local raw = file:read("*a")
        file:close()
        if raw and #raw > 0 then
            local success, data = pcall(serialization.unserialize, raw)
            if success and type(data) == "table" then
                admins = data
            end
        end
    end
end
if #admins == 0 then
    admins = {"ZoziDo"}
    local file = io.open(ADMINS_PATH, "w")
    if file then
        file:write(serialization.serialize(admins))
        file:close()
    end
end

local function isAdmin(playerName)
    if not playerName then return false end
    for _, name in ipairs(admins) do
        if name == playerName then return true end
    end
    return false
end

local function addAdmin(playerName)
    if not playerName or playerName == "" or isAdmin(playerName) then return false end
    table.insert(admins, playerName)
    local file = io.open(ADMINS_PATH, "w")
    if file then
        file:write(serialization.serialize(admins))
        file:close()
        return true
    end
    return false
end

local function removeAdmin(playerName)
    if not playerName or playerName == "" or #admins <= 1 then return false end
    for i, name in ipairs(admins) do
        if name == playerName then
            table.remove(admins, i)
            local file = io.open(ADMINS_PATH, "w")
            if file then
                file:write(serialization.serialize(admins))
                file:close()
                return true
            end
        end
    end
    return false
end

-- ===== БАЗА ДАННЫХ ИГРОКОВ =====
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

-- ===== ГЛОБАЛЬНАЯ СТАТИСТИКА =====
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

-- ===== ПЕРЕМЕННЫЕ СЕРВЕРА =====
local owner = nil
local sessions = {}
local markets = {}
local SESSION_TIMEOUT = 31536000
local marketConnected = false
local shopPaused = false
local ADMIN_NAME = "Kalleront"  -- для совместимости, но мы используем admins

-- ===== ФУНКЦИИ СЕРВЕРА =====
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

-- ============================================================
-- АДМИН-ПАНЕЛЬ (на основе библиотеки forms)
-- ============================================================

local function showPlayersList()
    local playersForm = forms.newForm("ИГРОКИ", 1, 1, 80, 25)
    playersForm:addLabel(2, 1, "# ИГРОКИ", 0xFFFFFF)

    -- Список игроков
    local list = playersForm:addListBox(2, 3, 60, 15)
    for name, data in pairs(players) do
        local status = data.banned and "❌" or "✅"
        local text = string.format("%-15s | Coin: %8.2f | Транз: %4d %s", name, data.balance, data.transactions, status)
        list:addItem(text)
    end

    -- Кнопка "Назад"
    local backBtn = playersForm:addButton(2, 20, 12, 1, "НАЗАД", 0xFFFFFF, 0x4A90E2)
    backBtn.onClick = function()
        playersForm:close()
        showMainMenu()
    end

    forms.setActiveForm(playersForm)
    forms.run()
end

local function showFeedbacks()
    local fbForm = forms.newForm("ОТЗЫВЫ", 1, 1, 80, 25)
    fbForm:addLabel(2, 1, "# ОТЗЫВЫ", 0xFFFFFF)

    local feedbacks = {}
    if filesystem.exists("/home/feedbacks.db") then
        local file = io.open("/home/feedbacks.db", "r")
        if file then
            local data = file:read("*a")
            file:close()
            if data and #data > 0 then
                local ok, result = pcall(serialization.unserialize, data)
                if ok and type(result) == "table" then
                    feedbacks = result
                end
            end
        end
    end

    local list = fbForm:addListBox(2, 3, 60, 15)
    for i, fb in ipairs(feedbacks) do
        local text = string.format("%-15s | %s | %s", fb.name or "?", fb.time or "", fb.text or "")
        list:addItem(text)
    end

    local backBtn = fbForm:addButton(2, 20, 12, 1, "НАЗАД", 0xFFFFFF, 0x4A90E2)
    backBtn.onClick = function()
        fbForm:close()
        showMainMenu()
    end

    forms.setActiveForm(fbForm)
    forms.run()
end

local function showJournal()
    local journalForm = forms.newForm("ЖУРНАЛ СОБЫТИЙ", 1, 1, 80, 25)
    journalForm:addLabel(2, 1, "# ЖУРНАЛ", 0xFFFFFF)

    local lines = {}
    if filesystem.exists("/home/server_events.log") then
        local file = io.open("/home/server_events.log", "r")
        if file then
            for line in file:lines() do
                table.insert(lines, line)
            end
            file:close()
        end
    end

    local list = journalForm:addListBox(2, 3, 76, 15)
    for _, line in ipairs(lines) do
        list:addItem(line)
    end

    local backBtn = journalForm:addButton(2, 20, 12, 1, "НАЗАД", 0xFFFFFF, 0x4A90E2)
    backBtn.onClick = function()
        journalForm:close()
        showMainMenu()
    end

    forms.setActiveForm(journalForm)
    forms.run()
end

local function showStats()
    local statsForm = forms.newForm("СТАТИСТИКА", 1, 1, 80, 25)
    statsForm:addLabel(2, 1, "# СТАТИСТИКА", 0xFFFFFF)

    local totalPlayers = 0
    for _ in pairs(players) do totalPlayers = totalPlayers + 1 end

    local y = 4
    statsForm:addLabel(4, y, "Всего репортов:", 0x888888)
    statsForm:addLabel(25, y, tostring(globalStats.totalReports or 0), 0xFFFFFF)
    y = y + 1
    statsForm:addLabel(4, y, "Всего покупок:", 0x888888)
    statsForm:addLabel(25, y, tostring(globalStats.totalBuys or 0), 0xFFFFFF)
    y = y + 1
    statsForm:addLabel(4, y, "Всего продаж:", 0x888888)
    statsForm:addLabel(25, y, tostring(globalStats.totalSells or 0), 0xFFFFFF)
    y = y + 1
    statsForm:addLabel(4, y, "Всего игроков:", 0x888888)
    statsForm:addLabel(25, y, tostring(totalPlayers), 0xFFFFFF)
    y = y + 1
    statsForm:addLabel(4, y, "Активных сессий:", 0x888888)
    local activeSessions = 0
    for _, s in pairs(sessions) do
        if s.token then activeSessions = activeSessions + 1 end
    end
    statsForm:addLabel(25, y, tostring(activeSessions), 0xFFFFFF)
    y = y + 1
    statsForm:addLabel(4, y, "Подключённых терминалов:", 0x888888)
    statsForm:addLabel(25, y, tostring(#markets), 0xFFFFFF)
    y = y + 1
    statsForm:addLabel(4, y, "Администраторов:", 0x888888)
    statsForm:addLabel(25, y, tostring(#admins), 0xFFFFFF)

    local backBtn = statsForm:addButton(2, 20, 12, 1, "НАЗАД", 0xFFFFFF, 0x4A90E2)
    backBtn.onClick = function()
        statsForm:close()
        showMainMenu()
    end

    forms.setActiveForm(statsForm)
    forms.run()
end

local function showAdminsList()
    local admForm = forms.newForm("АДМИНИСТРАТОРЫ", 1, 1, 80, 25)
    admForm:addLabel(2, 1, "# АДМИНИСТРАТОРЫ", 0xFFFFFF)

    local list = admForm:addListBox(2, 3, 30, 10)
    for i, name in ipairs(admins) do
        list:addItem(string.format("%d. %s", i, name))
    end

    -- Поле для добавления админа
    admForm:addLabel(2, 15, "Добавить администратора:", 0x888888)
    local edit = admForm:addEdit(2, 16, 20, 1)
    local addBtn = admForm:addButton(24, 16, 8, 1, "ДОБАВИТЬ", 0xFFFFFF, 0x00AA00)
    addBtn.onClick = function()
        local name = edit:getText()
        if name ~= "" then
            if addAdmin(name) then
                printLog("Администратор добавлен: " .. name)
                admForm:close()
                showAdminsList()
            else
                printLog("Ошибка добавления админа")
            end
        end
    end

    local backBtn = admForm:addButton(2, 20, 12, 1, "НАЗАД", 0xFFFFFF, 0x4A90E2)
    backBtn.onClick = function()
        admForm:close()
        showMainMenu()
    end

    forms.setActiveForm(admForm)
    forms.run()
end

local function showReports()
    local repForm = forms.newForm("РЕПОРТЫ", 1, 1, 80, 25)
    repForm:addLabel(2, 1, "# РЕПОРТЫ", 0xFFFFFF)

    local reports = {}
    if filesystem.exists("/home/reports.log") then
        local file = io.open("/home/reports.log", "r")
        if file then
            for line in file:lines() do
                table.insert(reports, line)
            end
            file:close()
        end
    end

    local list = repForm:addListBox(2, 3, 76, 15)
    for _, line in ipairs(reports) do
        list:addItem(line)
    end

    local backBtn = repForm:addButton(2, 20, 12, 1, "НАЗАД", 0xFFFFFF, 0x4A90E2)
    backBtn.onClick = function()
        repForm:close()
        showMainMenu()
    end

    forms.setActiveForm(repForm)
    forms.run()
end

local function showAddItem()
    local addForm = forms.newForm("ДОБАВИТЬ ПРЕДМЕТ", 1, 1, 80, 25)
    addForm:addLabel(2, 1, "# ДОБАВИТЬ ПРЕДМЕТ", 0xFFFFFF)

    addForm:addLabel(4, 4, "Internal Name:", 0x888888)
    local internalEdit = addForm:addEdit(20, 4, 30, 1)

    addForm:addLabel(4, 6, "Display Name:", 0x888888)
    local displayEdit = addForm:addEdit(20, 6, 30, 1)

    addForm:addLabel(4, 8, "Price:", 0x888888)
    local priceEdit = addForm:addEdit(20, 8, 10, 1)

    addForm:addLabel(4, 10, "Damage:", 0x888888)
    local damageEdit = addForm:addEdit(20, 10, 10, 1)

    local sendBtn = addForm:addButton(20, 14, 12, 1, "ОТПРАВИТЬ", 0xFFFFFF, 0x00AA00)
    sendBtn.onClick = function()
        local internal = internalEdit:getText()
        local display = displayEdit:getText()
        local price = tonumber(priceEdit:getText()) or 0
        local damage = tonumber(damageEdit:getText()) or 0
        if internal == "" or display == "" then
            printLog("Ошибка: Internal Name и Display Name обязательны")
            return
        end
        if price <= 0 then
            printLog("Ошибка: цена должна быть >0")
            return
        end

        local data = {
            op = "add_buy_item",
            internalName = internal,
            displayName = display,
            price = price,
            damage = damage
        }

        if next(markets) == nil then
            printLog("Нет подключённых терминалов!")
        else
            local sent = 0
            for addr, _ in pairs(markets) do
                modem.send(addr, 0xffef, serialization.serialize(data))
                sent = sent + 1
            end
            printLog("Предмет отправлен на " .. sent .. " терминалов: " .. display)
            -- также отправляем команду перезагрузки
            for addr, _ in pairs(markets) do
                modem.send(addr, 0xffef, serialization.serialize({op = "reload_buy_items"}))
            end
        end
        addForm:close()
        showMainMenu()
    end

    local backBtn = addForm:addButton(2, 20, 12, 1, "НАЗАД", 0xFFFFFF, 0x4A90E2)
    backBtn.onClick = function()
        addForm:close()
        showMainMenu()
    end

    forms.setActiveForm(addForm)
    forms.run()
end

local function togglePause()
    shopPaused = not shopPaused
    printLog("Магазин " .. (shopPaused and "приостановлен" or "возобновлён"))
    for addr, _ in pairs(markets) do
        modem.send(addr, 0xffef, serialization.serialize({op = "pause_status", paused = shopPaused}))
    end
    showMainMenu()
end

-- ===== ГЛАВНОЕ МЕНЮ =====
local function showMainMenu()
    local mainForm = forms.newForm("PTM MARKET SERVER", 1, 1, 80, 25)

    -- Заголовок
    mainForm:addLabel(2, 1, "# PTM MARKET SERVER", 0xFFFFFF)
    mainForm:addLabel(2, 2, "Администрирование", 0x888888)

    -- Кнопки с именами разделов
    local y = 4
    local btnWidth = 28
    local descX = 32

    local playersBtn = mainForm:addButton(2, y, btnWidth, 1, "## ИГРОВИ", 0xFFFFFF, 0x1A2A4A)
    mainForm:addLabel(descX, y, "Балансы, блокировки, транзакции", 0xAAAAAA)

    local feedbacksBtn = mainForm:addButton(2, y+1, btnWidth, 1, "## ОТЗЫВЫ", 0x888888, 0x0A0A0A)
    mainForm:addLabel(descX, y+1, "Чтение и удаление отзывов", 0x555555)

    local journalBtn = mainForm:addButton(2, y+2, btnWidth, 1, "## ЖУРНАЛ", 0x888888, 0x0A0A0A)
    mainForm:addLabel(descX, y+2, "Только важные события", 0x555555)

    local statsBtn = mainForm:addButton(2, y+3, btnWidth, 1, "## СТАТИСТИКА", 0x888888, 0x0A0A0A)
    mainForm:addLabel(descX, y+3, "Покупки, продажи, оборот", 0x555555)

    local adminsBtn = mainForm:addButton(2, y+4, btnWidth, 1, "## АДМИНИСТРАТОРЫ", 0x888888, 0x0A0A0A)
    mainForm:addLabel(descX, y+4, "Добавить или удалить админа", 0x555555)

    local pauseBtn = mainForm:addButton(2, y+5, btnWidth, 1, "## ПРИОСТАНОВИТЬ МАГАЗИН", 0x888888, 0x0A0A0A)
    mainForm:addLabel(descX, y+5, "Управление доступностью терминалов", 0x555555)

    local reportsBtn = mainForm:addButton(2, y+6, btnWidth, 1, "## РЕПОРТЫ", 0x888888, 0x0A0A0A)
    mainForm:addLabel(descX, y+6, "Чтение и удаление жалоб", 0x555555)

    local addItemBtn = mainForm:addButton(2, y+7, btnWidth, 1, "## ДОБАВИТЬ ПРЕДМЕТ", 0x888888, 0x0A0A0A)
    mainForm:addLabel(descX, y+7, "Отправить предмет в каталог", 0x555555)

    local backBtn = mainForm:addButton(2, y+8, btnWidth, 1, "< НАЗАД >", 0x888888, 0x0A0A0A)
    -- для < НАЗАД > описания нет

    -- Нижняя строка
    mainForm:addLabel(2, 24, "Esc – назад | выберите раздел мышью или стрелками", 0x666666)

    -- Обработчики кликов
    playersBtn.onClick = function()
        mainForm:close()
        showPlayersList()
    end

    feedbacksBtn.onClick = function()
        mainForm:close()
        showFeedbacks()
    end

    journalBtn.onClick = function()
        mainForm:close()
        showJournal()
    end

    statsBtn.onClick = function()
        mainForm:close()
        showStats()
    end

    adminsBtn.onClick = function()
        mainForm:close()
        showAdminsList()
    end

    pauseBtn.onClick = function()
        mainForm:close()
        togglePause()
    end

    reportsBtn.onClick = function()
        mainForm:close()
        showReports()
    end

    addItemBtn.onClick = function()
        mainForm:close()
        showAddItem()
    end

    backBtn.onClick = function()
        mainForm:close()
        -- Выход из админ-панели (просто завершаем поток)
        os.exit()
    end

    forms.setActiveForm(mainForm)
    forms.run()
end

-- ============================================================
-- ЗАПУСК АДМИН-ПАНЕЛИ В ОТДЕЛЬНОМ ПОТОКЕ
-- ============================================================

local function adminThread()
    -- Небольшая задержка, чтобы сервер успел запуститься
    os.sleep(1)
    showMainMenu()
end

-- Запускаем админ-панель в отдельном потоке
process.load(adminThread)

-- ============================================================
-- ОСНОВНОЙ ЦИКЛ СЕРВЕРА
-- ============================================================

printLog("Сервер запущен. Администраторы: " .. table.concat(admins, ", "))
printLog("Админ-панель запущена в фоновом потоке.")

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
