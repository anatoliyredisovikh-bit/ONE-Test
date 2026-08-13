local component = require("component")
local event = require("event")
local serialization = require("serialization")
local filesystem = require("filesystem")
local gpu = component.gpu
local math = require("math")
local os = require("os")
local unicode = require("unicode")
local computer = require("computer")
local term = require("term")

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

-- ===== СТАТИСТИКА =====
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

-- ===== ГРАФИЧЕСКАЯ АДМИН-ПАНЕЛЬ =====
local WIDTH, HEIGHT = 80, 25
gpu.setResolution(WIDTH, HEIGHT)

local C = {
    bg = 0x0A0A0A,
    panel = 0x1A1A2E,
    accent = 0x4A90E2,
    green = 0x00FF88,
    red = 0xFF5555,
    yellow = 0xFFAA00,
    white = 0xFFFFFF,
    gray = 0x888888,
    selected = 0x2A3A5A,
    border = 0x3A4A6A,
    input = 0x1A1A1A,
    danger = 0x8B1A1A,
}

local function clear()
    gpu.setBackground(C.bg)
    gpu.fill(1, 1, WIDTH, HEIGHT, " ")
end

local function write(x, y, text, fg, bg)
    if y < 1 or y > HEIGHT or x > WIDTH then return end
    text = tostring(text or "")
    if x < 1 then
        text = unicode.sub(text, 2 - x)
        x = 1
    end
    if text == "" then return end
    gpu.setForeground(fg or C.white)
    gpu.setBackground(bg or C.bg)
    gpu.set(x, y, unicode.sub(text, 1, WIDTH - x + 1))
end

local function center(y, text, fg, bg)
    local x = math.floor((WIDTH - unicode.len(text)) / 2) + 1
    write(x, y, text, fg, bg)
end

local function box(x, y, w, h, fg, bg)
    if w < 2 or h < 2 then return end
    fg = fg or C.border
    bg = bg or C.bg
    write(x, y, "┌" .. string.rep("─", w - 2) .. "┐", fg, bg)
    for r = y + 1, y + h - 2 do
        write(x, r, "│", fg, bg)
        write(x + w - 1, r, "│", fg, bg)
    end
    write(x, y + h - 1, "└" .. string.rep("─", w - 2) .. "┘", fg, bg)
end

local function drawHeader()
    box(1, 1, WIDTH, 3, C.accent, C.bg)
    write(2, 1, " PIM MARKET SERVER", C.accent, C.bg)
    local status = (marketConnected and "АКТИВЕН" or "ОЖИДАНИЕ")
    if shopPaused then status = status .. " [ПАУЗА]" end
    write(WIDTH - unicode.len(status) - 2, 1, status, shopPaused and C.yellow or C.green, C.bg)
    write(2, 2, "Администрирование", C.gray, C.bg)
    write(WIDTH - 25, 2, "Время: " .. getRealTimeString(), C.gray, C.bg)
end

local menuItems = {
    { id = "players",   label = "👥 ИГРОКИ",          desc = "Балансы, блокировки, транзакции" },
    { id = "feedbacks", label = "📝 ОТЗЫВЫ",          desc = "Чтение и удаление отзывов" },
    { id = "journal",   label = "📋 ЖУРНАЛ",          desc = "Только важные события" },
    { id = "stats",     label = "📊 СТАТИСТИКА",      desc = "Покупки, продажи, оборот" },
    { id = "admins",    label = "🔑 АДМИНИСТРАТОРЫ",  desc = "Добавить или удалить админа" },
    { id = "pause",     label = "⏸ ПРИОСТАНОВИТЬ МАГАЗИН", desc = "Управление доступностью терминалов" },
    { id = "reports",   label = "🚨 РЕПОРТЫ",        desc = "Чтение и удаление жалоб" },
    { id = "additem",   label = "📦 ДОБАВИТЬ ПРЕДМЕТ", desc = "Отправить предмет в каталог" },
}

local selected = 1
local currentScreen = "menu" -- menu, players, feedbacks, journal, stats, admins, reports, additem
local currentList = {}
local listScroll = 1
local listSelected = 1
local editMode = false
local editInput = ""
local editField = ""

local function drawMenu()
    clear()
    drawHeader()
    local y = 5
    for i, item in ipairs(menuItems) do
        local bg = (i == selected) and C.selected or C.bg
        local fg = (i == selected) and C.white or C.gray
        write(2, y, string.rep(" ", 76), C.bg, bg)
        write(4, y, item.label, fg, bg)
        write(50, y, item.desc, fg, bg)
        y = y + 1
    end
    write(2, HEIGHT - 1, "Esc - назад | ↑↓ выбор | Enter - выбрать", C.gray, C.bg)
end

local function drawPlayers()
    clear()
    drawHeader()
    write(2, 4, "ИГРОКИ", C.accent, C.bg)
    write(2, 5, "Имя", C.gray, C.bg)
    write(25, 5, "Coin", C.gray, C.bg)
    write(38, 5, "Транз.", C.gray, C.bg)
    write(50, 5, "Статус", C.gray, C.bg)
    write(65, 5, "Админ", C.gray, C.bg)

    local list = {}
    for name, data in pairs(players) do
        table.insert(list, {name = name, data = data})
    end
    table.sort(list, function(a, b) return a.name < b.name end)

    local maxScroll = math.max(1, #list - 15)
    listScroll = math.max(1, math.min(listScroll, maxScroll))

    for i = 1, 15 do
        local idx = listScroll + i - 1
        local item = list[idx]
        if item then
            local y = 6 + i
            local bg = (idx == listSelected) and C.selected or C.bg
            write(2, y, string.rep(" ", 76), C.bg, bg)
            write(3, y, unicode.sub(item.name, 1, 18), C.white, bg)
            write(25, y, string.format("%.2f", item.data.balance or 0), C.green, bg)
            write(38, y, string.format("%d", item.data.transactions or 0), C.white, bg)
            local status = item.data.banned and "ЗАБАНЕН" or "АКТИВЕН"
            write(50, y, status, item.data.banned and C.red or C.green, bg)
            write(65, y, isAdmin(item.name) and "ДА" or "НЕТ", isAdmin(item.name) and C.accent or C.gray, bg)
        end
    end

    write(2, HEIGHT - 3, "B - бан/разбан | E - редактировать баланс | A - админ/снять", C.gray, C.bg)
    write(2, HEIGHT - 2, "↑↓ выбор | Esc - назад", C.gray, C.bg)

    if editMode then
        box(20, 10, 40, 6, C.accent, C.bg)
        write(22, 11, editField, C.white, C.bg)
        write(22, 12, editInput .. "_", C.white, C.bg)
        write(22, 14, "Enter - подтвердить | Esc - отмена", C.gray, C.bg)
    end
end

local function drawFeedbacks()
    clear()
    drawHeader()
    write(2, 4, "ОТЗЫВЫ", C.accent, C.bg)

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

    local maxScroll = math.max(1, #feedbacks - 14)
    listScroll = math.max(1, math.min(listScroll, maxScroll))

    for i = 1, 14 do
        local idx = listScroll + i - 1
        local fb = feedbacks[idx]
        if fb then
            local y = 5 + i
            local bg = (idx == listSelected) and C.selected or C.bg
            write(2, y, string.rep(" ", 76), C.bg, bg)
            write(3, y, unicode.sub(fb.name or "?", 1, 15), C.accent, bg)
            write(20, y, unicode.sub(fb.time or "", 1, 20), C.gray, bg)
            write(42, y, unicode.sub(fb.text or "", 1, 35), C.white, bg)
        end
    end

    write(2, HEIGHT - 3, "D - удалить отзыв | ↑↓ выбор | Esc - назад", C.gray, C.bg)
end

local function drawJournal()
    clear()
    drawHeader()
    write(2, 4, "ЖУРНАЛ СОБЫТИЙ", C.accent, C.bg)

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

    local maxScroll = math.max(1, #lines - 16)
    listScroll = math.max(1, math.min(listScroll, maxScroll))

    for i = 1, 16 do
        local idx = #lines - listScroll - i + 2
        if idx >= 1 and idx <= #lines then
            local y = 5 + i
            write(2, y, unicode.sub(lines[idx], 1, 76), C.white, C.bg)
        end
    end

    write(2, HEIGHT - 2, "Esc - назад", C.gray, C.bg)
end

local function drawStats()
    clear()
    drawHeader()
    write(2, 4, "СТАТИСТИКА", C.accent, C.bg)
    write(10, 7, "Всего репортов:", C.gray, C.bg)
    write(30, 7, tostring(globalStats.totalReports or 0), C.white, C.bg)
    write(10, 9, "Всего покупок:", C.gray, C.bg)
    write(30, 9, tostring(globalStats.totalBuys or 0), C.white, C.bg)
    write(10, 11, "Всего продаж:", C.gray, C.bg)
    write(30, 11, tostring(globalStats.totalSells or 0), C.white, C.bg)

    local totalPlayers = 0
    for _ in pairs(players) do totalPlayers = totalPlayers + 1 end
    write(10, 13, "Всего игроков:", C.gray, C.bg)
    write(30, 13, tostring(totalPlayers), C.white, C.bg)

    write(2, HEIGHT - 2, "Esc - назад", C.gray, C.bg)
end

local function drawAdmins()
    clear()
    drawHeader()
    write(2, 4, "АДМИНИСТРАТОРЫ", C.accent, C.bg)

    for i, name in ipairs(admins) do
        local y = 5 + i
        write(3, y, tostring(i) .. ". " .. name, C.white, C.bg)
    end

    write(2, HEIGHT - 4, "A - добавить администратора", C.gray, C.bg)
    write(2, HEIGHT - 3, "D - удалить выбранного администратора", C.gray, C.bg)
    write(2, HEIGHT - 2, "Esc - назад", C.gray, C.bg)

    if editMode then
        box(20, 10, 40, 5, C.accent, C.bg)
        write(22, 11, "Введите ник:", C.white, C.bg)
        write(22, 12, editInput .. "_", C.white, C.bg)
        write(22, 13, "Enter - добавить | Esc - отмена", C.gray, C.bg)
    end
end

local function drawReports()
    clear()
    drawHeader()
    write(2, 4, "РЕПОРТЫ", C.accent, C.bg)

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

    local maxScroll = math.max(1, #reports - 14)
    listScroll = math.max(1, math.min(listScroll, maxScroll))

    for i = 1, 14 do
        local idx = listScroll + i - 1
        if idx <= #reports then
            local y = 5 + i
            local bg = (idx == listSelected) and C.selected or C.bg
            write(2, y, string.rep(" ", 76), C.bg, bg)
            write(3, y, unicode.sub(reports[idx], 1, 74), C.white, bg)
        end
    end

    write(2, HEIGHT - 3, "D - удалить репорт | ↑↓ выбор | Esc - назад", C.gray, C.bg)
end

local function drawAddItem()
    clear()
    drawHeader()
    write(2, 4, "ДОБАВИТЬ ПРЕДМЕТ В КАТАЛОГ ПОКУПОК", C.accent, C.bg)

    local fields = {
        { id = "internal", label = "Internal Name:", value = "" },
        { id = "display", label = "Display Name:", value = "" },
        { id = "price_coin", label = "Price Coin:", value = "0" },
        { id = "price_ema", label = "Price Ema:", value = "0" },
        { id = "damage", label = "Damage:", value = "0" },
    }

    for i, f in ipairs(fields) do
        local y = 6 + i * 2
        write(5, y, f.label, C.gray, C.bg)
        write(25, y, string.rep(" ", 30), C.bg, C.input)
        write(26, y, f.value, C.white, C.input)
    end

    write(2, HEIGHT - 3, "↑↓ выбор поля | Enter - редактировать | Esc - назад", C.gray, C.bg)
    write(2, HEIGHT - 2, "S - отправить предмет на терминалы", C.gray, C.bg)
end

-- ===== ОБРАБОТЧИКИ РАЗДЕЛОВ =====
local function handlePlayers(key, char)
    if editMode then
        if key == 1 then -- Esc
            editMode = false
            editInput = ""
            editField = ""
            drawPlayers()
            return true
        elseif key == 28 then -- Enter
            if editField == "balance" then
                local amount = tonumber(editInput)
                if amount then
                    local list = {}
                    for name, data in pairs(players) do
                        table.insert(list, {name = name, data = data})
                    end
                    table.sort(list, function(a, b) return a.name < b.name end)
                    local item = list[listSelected]
                    if item then
                        players[item.name].balance = amount
                        saveDB()
                    end
                end
            end
            editMode = false
            editInput = ""
            editField = ""
            drawPlayers()
            return true
        elseif char == 8 then -- Backspace
            editInput = unicode.sub(editInput, 1, -2)
            drawPlayers()
            return true
        elseif char >= 32 then
            editInput = editInput .. unicode.char(char)
            drawPlayers()
            return true
        end
        return true
    end

    if key == 1 then -- Esc
        currentScreen = "menu"
        drawMenu()
        return true
    elseif key == 200 then -- Up
        listSelected = math.max(1, listSelected - 1)
        if listSelected < listScroll then listScroll = listSelected end
        drawPlayers()
        return true
    elseif key == 208 then -- Down
        local list = {}
        for name, data in pairs(players) do
            table.insert(list, {name = name, data = data})
        end
        listSelected = math.min(#list, listSelected + 1)
        if listSelected > listScroll + 14 then listScroll = listSelected - 14 end
        drawPlayers()
        return true
    elseif char == 98 then -- b
        local list = {}
        for name, data in pairs(players) do
            table.insert(list, {name = name, data = data})
        end
        table.sort(list, function(a, b) return a.name < b.name end)
        local item = list[listSelected]
        if item then
            players[item.name].banned = not players[item.name].banned
            saveDB()
            drawPlayers()
        end
        return true
    elseif char == 101 then -- e
        local list = {}
        for name, data in pairs(players) do
            table.insert(list, {name = name, data = data})
        end
        table.sort(list, function(a, b) return a.name < b.name end)
        local item = list[listSelected]
        if item then
            editMode = true
            editInput = tostring(item.data.balance or 0)
            editField = "balance"
            drawPlayers()
        end
        return true
    elseif char == 97 then -- a
        local list = {}
        for name, data in pairs(players) do
            table.insert(list, {name = name, data = data})
        end
        table.sort(list, function(a, b) return a.name < b.name end)
        local item = list[listSelected]
        if item then
            if isAdmin(item.name) then
                removeAdmin(item.name)
            else
                addAdmin(item.name)
            end
            drawPlayers()
        end
        return true
    end
    return false
end

local function handleFeedbacks(key, char)
    if key == 1 then
        currentScreen = "menu"
        drawMenu()
        return true
    elseif key == 200 then
        listSelected = math.max(1, listSelected - 1)
        if listSelected < listScroll then listScroll = listSelected end
        drawFeedbacks()
        return true
    elseif key == 208 then
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
        listSelected = math.min(#feedbacks, listSelected + 1)
        if listSelected > listScroll + 13 then listScroll = listSelected - 13 end
        drawFeedbacks()
        return true
    elseif char == 100 then -- d
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
        if listSelected <= #feedbacks then
            table.remove(feedbacks, listSelected)
            local file = io.open("/home/feedbacks.db", "w")
            if file then
                file:write(serialization.serialize(feedbacks))
                file:close()
            end
            drawFeedbacks()
        end
        return true
    end
    return false
end

local function handleJournal(key, char)
    if key == 1 then
        currentScreen = "menu"
        drawMenu()
        return true
    end
    return false
end

local function handleStats(key, char)
    if key == 1 then
        currentScreen = "menu"
        drawMenu()
        return true
    end
    return false
end

local function handleAdmins(key, char)
    if editMode then
        if key == 1 then -- Esc
            editMode = false
            editInput = ""
            drawAdmins()
            return true
        elseif key == 28 then -- Enter
            if editInput ~= "" then
                addAdmin(editInput)
            end
            editMode = false
            editInput = ""
            drawAdmins()
            return true
        elseif char == 8 then -- Backspace
            editInput = unicode.sub(editInput, 1, -2)
            drawAdmins()
            return true
        elseif char >= 32 then
            editInput = editInput .. unicode.char(char)
            drawAdmins()
            return true
        end
        return true
    end

    if key == 1 then
        currentScreen = "menu"
        drawMenu()
        return true
    elseif char == 97 then -- a
        editMode = true
        editInput = ""
        drawAdmins()
        return true
    elseif char == 100 then -- d
        if #admins > 1 then
            removeAdmin(admins[#admins])
            drawAdmins()
        end
        return true
    end
    return false
end

local function handleReports(key, char)
    if key == 1 then
        currentScreen = "menu"
        drawMenu()
        return true
    elseif key == 200 then
        listSelected = math.max(1, listSelected - 1)
        if listSelected < listScroll then listScroll = listSelected end
        drawReports()
        return true
    elseif key == 208 then
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
        listSelected = math.min(#reports, listSelected + 1)
        if listSelected > listScroll + 13 then listScroll = listSelected - 13 end
        drawReports()
        return true
    elseif char == 100 then -- d
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
        if listSelected <= #reports then
            table.remove(reports, listSelected)
            local file = io.open("/home/reports.log", "w")
            if file then
                for _, line in ipairs(reports) do
                    file:write(line .. "\n")
                end
                file:close()
            end
            drawReports()
        end
        return true
    end
    return false
end

local function handleAddItem(key, char)
    if key == 1 then
        currentScreen = "menu"
        drawMenu()
        return true
    elseif char == 115 then -- s
        -- Отправка предмета на терминалы
        printLog("Отправка предмета на терминалы...")
        if next(markets) == nil then
            printLog("Нет подключённых терминалов!")
        else
            local data = {
                op = "add_buy_item",
                internalName = "test_item",
                displayName = "Тестовый предмет",
                price_coin = 1,
                price_ema = 0,
                damage = 0
            }
            for addr, _ in pairs(markets) do
                modem.send(addr, 0xffef, serialization.serialize(data))
            end
            printLog("Предмет отправлен на " .. #markets .. " терминалов")
        end
        drawAddItem()
        return true
    end
    return false
end

-- ===== ОСНОВНОЙ ЦИКЛ СЕРВЕРА С АДМИН-ПАНЕЛЬЮ =====
printLog("Сервер запущен. Администраторы: " .. table.concat(admins, ", "))
drawMenu()

while true do
    local ev = {event.pull(0.5)}
    local etype = ev[1]

    -- Обработка модемных сообщений (серверная логика)
    if etype == "modem_message" then
        local from = ev[3]
        local raw = ev[6]
        local success, msg = pcall(serialization.unserialize, raw)
        if not success or not msg or type(msg) ~= "table" then
            goto continue
        end

        if msg.op == "register" then
            if msg.password ~= "admin" then
                modem.send(from, 0xffef, serialization.serialize({op="error", message="Неверный пароль"}))
                printLog("Попытка подключения с неверным паролем от " .. from)
                goto continue
            end
            marketConnected = true
            if not owner then owner = from end
            if not markets[from] then
                markets[from] = true
                printLog("Терминал добавлен: " .. from)
            end
            modem.send(from, 0xffef, serialization.serialize({op="welcome", owner=(from==owner), shopPaused=shopPaused}))
            if currentScreen == "menu" then drawMenu() end
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
            if currentScreen == "menu" then drawMenu() end
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
            if currentScreen == "menu" then drawMenu() end
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
            if currentScreen == "menu" then drawMenu() end
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
            if currentScreen == "menu" then drawMenu() end
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
            if currentScreen == "menu" then drawMenu() end
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
            if currentScreen == "menu" then drawMenu() end
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
            if currentScreen == "menu" then drawMenu() end
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
            if currentScreen == "menu" then drawMenu() end
            goto continue
        end
        ::continue::
    end

    -- Обработка ввода для админ-панели
    if etype == "key_down" then
        local key = ev[4]
        local char = ev[3]

        if currentScreen == "menu" then
            if key == 1 then -- Esc
                break
            elseif key == 200 then -- Up
                selected = math.max(1, selected - 1)
                drawMenu()
            elseif key == 208 then -- Down
                selected = math.min(#menuItems, selected + 1)
                drawMenu()
            elseif key == 28 then -- Enter
                currentScreen = menuItems[selected].id
                listScroll = 1
                listSelected = 1
                if currentScreen == "players" then drawPlayers()
                elseif currentScreen == "feedbacks" then drawFeedbacks()
                elseif currentScreen == "journal" then drawJournal()
                elseif currentScreen == "stats" then drawStats()
                elseif currentScreen == "admins" then drawAdmins()
                elseif currentScreen == "reports" then drawReports()
                elseif currentScreen == "additem" then drawAddItem()
                elseif currentScreen == "pause" then
                    shopPaused = not shopPaused
                    printLog("Магазин " .. (shopPaused and "приостановлен" or "возобновлён"))
                    currentScreen = "menu"
                    drawMenu()
                end
            end
        elseif currentScreen == "players" then
            handlePlayers(key, char)
        elseif currentScreen == "feedbacks" then
            handleFeedbacks(key, char)
        elseif currentScreen == "journal" then
            handleJournal(key, char)
        elseif currentScreen == "stats" then
            handleStats(key, char)
        elseif currentScreen == "admins" then
            handleAdmins(key, char)
        elseif currentScreen == "reports" then
            handleReports(key, char)
        elseif currentScreen == "additem" then
            handleAddItem(key, char)
        end
    end

    -- Обновление интерфейса при изменении данных
    if etype == "modem_message" and currentScreen == "menu" then
        drawMenu()
    end
end

printLog("Сервер остановлен")
term.clear()
