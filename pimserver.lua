-- ============================================================
-- PIM MARKET SERVER + АДМИН-ПАНЕЛЬ (объединённый)
-- Версия: 2.0 с полным функционалом
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
local term = require("term")

-- ===== НАСТРОЙКИ =====
local TIMEZONE_OFFSET = 3 * 3600   -- UTC+3 (Москва)
local ACCESS_PASSWORD = "admin"    -- пароль для регистрации терминалов
local SERVER_PORT = 0xffef         -- порт для связи с терминалами

local modem = component.modem
modem.open(SERVER_PORT)
modem.open(0xfffe)                 -- резервный порт

-- Отключаем прерывания (чтобы нельзя было выйти Ctrl+C)
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
    admins = {"ZoziDo"}   -- первый админ по умолчанию
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
local SESSION_TIMEOUT = 31536000   -- 1 год
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

-- Цветовая схема
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
    title = 0x00CCFF,
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

-- ===== МЕНЮ =====
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
local currentScreen = "menu"  -- menu, players, feedbacks, journal, stats, admins, reports, additem
local currentList = {}
local listScroll = 1
local listSelected = 1
local editMode = false
local editInput = ""
local editField = ""
local editData = {}  -- для хранения редактируемых данных

-- ===== ОТРИСОВКА ГЛАВНОГО МЕНЮ =====
local function drawHeader(title)
    box(1, 1, WIDTH, 3, C.accent, C.bg)
    write(2, 1, " PIM MARKET SERVER", C.accent, C.bg)
    local status = (marketConnected and "АКТИВЕН" or "ОЖИДАНИЕ")
    if shopPaused then status = status .. " [ПАУЗА]" end
    write(WIDTH - unicode.len(status) - 2, 1, status, shopPaused and C.yellow or C.green, C.bg)
    write(2, 2, title or "Администрирование", C.gray, C.bg)
    write(WIDTH - 25, 2, "Время: " .. getRealTimeString(), C.gray, C.bg)
end

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
    write(2, HEIGHT - 1, "Esc - выход | ↑↓ выбор | Enter - выбрать", C.gray, C.bg)
end

-- ===== РАЗДЕЛ "ИГРОКИ" =====
local function drawPlayers()
    clear()
    drawHeader("ИГРОКИ")
    
    local list = {}
    for name, data in pairs(players) do
        table.insert(list, {name = name, data = data})
    end
    table.sort(list, function(a, b) return a.name < b.name end)

    -- Заголовки
    write(2, 4, "Имя", C.gray, C.bg)
    write(22, 4, "Coin", C.gray, C.bg)
    write(35, 4, "ЭМЫ", C.gray, C.bg)
    write(48, 4, "Транз.", C.gray, C.bg)
    write(58, 4, "Статус", C.gray, C.bg)
    write(70, 4, "Админ", C.gray, C.bg)

    local maxScroll = math.max(1, #list - 15)
    listScroll = math.max(1, math.min(listScroll, maxScroll))

    for i = 1, 15 do
        local idx = listScroll + i - 1
        local item = list[idx]
        if item then
            local y = 5 + i
            local bg = (idx == listSelected) and C.selected or C.bg
            write(2, y, string.rep(" ", 76), C.bg, bg)
            write(3, y, unicode.sub(item.name, 1, 18), C.white, bg)
            write(22, y, string.format("%.2f", item.data.balance or 0), C.green, bg)
            write(35, y, string.format("%.2f", item.data.emaBalance or 0), C.yellow, bg)
            write(48, y, string.format("%d", item.data.transactions or 0), C.white, bg)
            local status = item.data.banned and "ЗАБАНЕН" or "АКТИВЕН"
            write(58, y, status, item.data.banned and C.red or C.green, bg)
            write(70, y, isAdmin(item.name) and "ДА" or "НЕТ", isAdmin(item.name) and C.accent or C.gray, bg)
        end
    end

    write(2, HEIGHT - 3, "B - бан/разбан | E - редактировать баланс | A - админ/снять", C.gray, C.bg)
    write(2, HEIGHT - 2, "↑↓ выбор | Esc - назад", C.gray, C.bg)

    if editMode then
        box(18, 10, 44, 7, C.accent, C.bg)
        write(20, 11, "Редактирование баланса", C.white, C.bg)
        write(20, 12, editField, C.white, C.bg)
        write(20, 13, editInput .. "_", C.white, C.bg)
        write(20, 15, "Enter - подтвердить | Esc - отмена", C.gray, C.bg)
    end
end

local function handlePlayers(key, char)
    if editMode then
        if key == 1 then -- Esc
            editMode = false
            editInput = ""
            editField = ""
            drawPlayers()
            return true
        elseif key == 28 then -- Enter
            local amount = tonumber(editInput)
            if amount and editField == "balance" then
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
            elseif editField == "ema" then
                local amount = tonumber(editInput)
                if amount then
                    local list = {}
                    for name, data in pairs(players) do
                        table.insert(list, {name = name, data = data})
                    end
                    table.sort(list, function(a, b) return a.name < b.name end)
                    local item = list[listSelected]
                    if item then
                        players[item.name].emaBalance = amount
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
    elseif char == 109 then -- m (для редактирования ЭМЫ)
        local list = {}
        for name, data in pairs(players) do
            table.insert(list, {name = name, data = data})
        end
        table.sort(list, function(a, b) return a.name < b.name end)
        local item = list[listSelected]
        if item then
            editMode = true
            editInput = tostring(item.data.emaBalance or 0)
            editField = "ema"
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

-- ===== РАЗДЕЛ "ОТЗЫВЫ" =====
local function drawFeedbacks()
    clear()
    drawHeader("ОТЗЫВЫ")
    
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

    write(2, 4, "Имя", C.gray, C.bg)
    write(18, 4, "Дата", C.gray, C.bg)
    write(40, 4, "Текст", C.gray, C.bg)

    local maxScroll = math.max(1, #feedbacks - 14)
    listScroll = math.max(1, math.min(listScroll, maxScroll))

    for i = 1, 14 do
        local idx = listScroll + i - 1
        local fb = feedbacks[idx]
        if fb then
            local y = 5 + i
            local bg = (idx == listSelected) and C.selected or C.bg
            write(2, y, string.rep(" ", 76), C.bg, bg)
            write(3, y, unicode.sub(fb.name or "?", 1, 14), C.accent, bg)
            write(18, y, unicode.sub(fb.time or "", 1, 20), C.gray, bg)
            write(40, y, unicode.sub(fb.text or "", 1, 37), C.white, bg)
        end
    end

    write(2, HEIGHT - 3, "D - удалить отзыв | ↑↓ выбор | Esc - назад", C.gray, C.bg)
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

-- ===== РАЗДЕЛ "ЖУРНАЛ" =====
local function drawJournal()
    clear()
    drawHeader("ЖУРНАЛ СОБЫТИЙ")
    
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

local function handleJournal(key, char)
    if key == 1 then
        currentScreen = "menu"
        drawMenu()
        return true
    end
    return false
end

-- ===== РАЗДЕЛ "СТАТИСТИКА" =====
local function drawStats()
    clear()
    drawHeader("СТАТИСТИКА")
    
    local totalPlayers = 0
    for _ in pairs(players) do totalPlayers = totalPlayers + 1 end

    local statsData = {
        {"Всего репортов:", tostring(globalStats.totalReports or 0)},
        {"Всего покупок:",  tostring(globalStats.totalBuys or 0)},
        {"Всего продаж:",   tostring(globalStats.totalSells or 0)},
        {"Всего игроков:",  tostring(totalPlayers)},
        {"Активных сессий:", tostring(#sessions)},
        {"Подключённых терминалов:", tostring(#markets)},
        {"Администраторов:", tostring(#admins)},
    }

    for i, stat in ipairs(statsData) do
        local y = 6 + i * 2
        write(10, y, stat[1], C.gray, C.bg)
        write(35, y, stat[2], C.white, C.bg)
    end

    write(2, HEIGHT - 2, "Esc - назад", C.gray, C.bg)
end

local function handleStats(key, char)
    if key == 1 then
        currentScreen = "menu"
        drawMenu()
        return true
    end
    return false
end

-- ===== РАЗДЕЛ "АДМИНИСТРАТОРЫ" =====
local function drawAdmins()
    clear()
    drawHeader("АДМИНИСТРАТОРЫ")
    
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

-- ===== РАЗДЕЛ "РЕПОРТЫ" =====
local function drawReports()
    clear()
    drawHeader("РЕПОРТЫ")
    
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

-- ===== РАЗДЕЛ "ДОБАВИТЬ ПРЕДМЕТ" =====
local addItemFields = {
    { id = "internal", label = "Internal Name:", value = "" },
    { id = "display",  label = "Display Name:",  value = "" },
    { id = "price_coin", label = "Price Coin:", value = "1" },
    { id = "price_ema", label = "Price Ema:",   value = "0" },
    { id = "damage",   label = "Damage:",       value = "0" },
}
local addItemSelected = 1

local function drawAddItem()
    clear()
    drawHeader("ДОБАВИТЬ ПРЕДМЕТ В КАТАЛОГ ПОКУПОК")
    
    for i, f in ipairs(addItemFields) do
        local y = 5 + i * 2
        local bg = (i == addItemSelected) and C.selected or C.bg
        write(4, y, string.rep(" ", 72), C.bg, bg)
        write(5, y, f.label, C.gray, bg)
        write(25, y, string.rep(" ", 40), C.bg, C.input)
        write(26, y, f.value, C.white, C.input)
        if i == addItemSelected then
            write(25, y, ">", C.accent, bg)
        end
    end

    write(2, HEIGHT - 4, "↑↓ выбор поля | Enter - редактировать | S - отправить", C.gray, C.bg)
    write(2, HEIGHT - 3, "Esc - назад", C.gray, C.bg)

    if editMode then
        box(20, 12, 40, 5, C.accent, C.bg)
        write(22, 13, "Введите значение:", C.white, C.bg)
        write(22, 14, editInput .. "_", C.white, C.bg)
        write(22, 15, "Enter - подтвердить | Esc - отмена", C.gray, C.bg)
    end
end

local function handleAddItem(key, char)
    if editMode then
        if key == 1 then -- Esc
            editMode = false
            editInput = ""
            drawAddItem()
            return true
        elseif key == 28 then -- Enter
            local field = addItemFields[addItemSelected]
            if field then
                field.value = editInput
            end
            editMode = false
            editInput = ""
            drawAddItem()
            return true
        elseif char == 8 then -- Backspace
            editInput = unicode.sub(editInput, 1, -2)
            drawAddItem()
            return true
        elseif char >= 32 then
            editInput = editInput .. unicode.char(char)
            drawAddItem()
            return true
        end
        return true
    end

    if key == 1 then -- Esc
        currentScreen = "menu"
        drawMenu()
        return true
    elseif key == 200 then -- Up
        addItemSelected = math.max(1, addItemSelected - 1)
        drawAddItem()
        return true
    elseif key == 208 then -- Down
        addItemSelected = math.min(#addItemFields, addItemSelected + 1)
        drawAddItem()
        return true
    elseif key == 28 then -- Enter (редактировать поле)
        local field = addItemFields[addItemSelected]
        if field then
            editMode = true
            editInput = field.value
            drawAddItem()
        end
        return true
    elseif char == 115 then -- s (отправить)
        -- Сбор данных
        local internal = addItemFields[1].value
        local display = addItemFields[2].value
        local price_coin = tonumber(addItemFields[3].value) or 0
        local price_ema = tonumber(addItemFields[4].value) or 0
        local damage = tonumber(addItemFields[5].value) or 0
        if internal == "" or display == "" then
            printLog("Ошибка: Internal Name и Display Name обязательны")
            drawAddItem()
            return true
        end
        if price_coin <= 0 and price_ema <= 0 then
            printLog("Ошибка: цена должна быть больше 0 хотя бы в одной валюте")
            drawAddItem()
            return true
        end

        local data = {
            op = "add_buy_item",
            internalName = internal,
            displayName = display,
            price_coin = price_coin,
            price_ema = price_ema,
            damage = damage
        }

        if next(markets) == nil then
            printLog("Нет подключённых терминалов!")
        else
            local sent = 0
            for addr, _ in pairs(markets) do
                modem.send(addr, SERVER_PORT, serialization.serialize(data))
                sent = sent + 1
            end
            printLog("Предмет отправлен на " .. sent .. " терминал(ов): " .. display)
            -- Также отправляем команду перезагрузки
            for addr, _ in pairs(markets) do
                modem.send(addr, SERVER_PORT, serialization.serialize({op = "reload_buy_items"}))
            end
        end
        drawAddItem()
        return true
    end
    return false
end

-- ===== ОБРАБОТКА ПАУЗЫ =====
local function handlePause()
    shopPaused = not shopPaused
    printLog("Магазин " .. (shopPaused and "приостановлен" or "возобновлён"))
    -- Оповещаем терминалы
    for addr, _ in pairs(markets) do
        modem.send(addr, SERVER_PORT, serialization.serialize({op = "pause_status", paused = shopPaused}))
    end
    currentScreen = "menu"
    drawMenu()
end

-- ===== ОСНОВНОЙ ЦИКЛ СЕРВЕРА =====
printLog("Сервер запущен. Администраторы: " .. table.concat(admins, ", "))
drawMenu()

while true do
    local ev = {event.pull(0.5)}
    local etype = ev[1]

    -- ===== ОБРАБОТКА МОДЕМНЫХ СООБЩЕНИЙ =====
    if etype == "modem_message" then
        local from = ev[3]
        local raw = ev[6]
        local success, msg = pcall(serialization.unserialize, raw)
        if not success or not msg or type(msg) ~= "table" then
            goto continue
        end

        -- Регистрация терминала
        if msg.op == "register" then
            if msg.password ~= ACCESS_PASSWORD then
                modem.send(from, SERVER_PORT, serialization.serialize({op="error", message="Неверный пароль"}))
                printLog("Попытка подключения с неверным паролем от " .. from)
                goto continue
            end
            marketConnected = true
            if not owner then owner = from end
            if not markets[from] then
                markets[from] = true
                printLog("Терминал добавлен: " .. from)
            end
            modem.send(from, SERVER_PORT, serialization.serialize({op="welcome", owner=(from==owner), shopPaused=shopPaused}))
            if currentScreen == "menu" then drawMenu() end
            goto continue
        end

        -- Вход игрока
        if msg.op == "enter" then
            if shopPaused then
                modem.send(from, SERVER_PORT, serialization.serialize({op="error", message="Магазин на паузе"}))
                goto continue
            end
            local playerName = msg.name
            if not playerName or playerName == "" then
                printLog("Вход без имени от " .. from)
                goto continue
            end
            local player = getOrCreatePlayer(playerName)
            if player.banned then
                modem.send(from, SERVER_PORT, serialization.serialize({op="error", message="Вы забанены"}))
                goto continue
            end

            local existingSession = sessions[playerName]
            local token
            if existingSession and os.time() - (existingSession.lastAction or 0) < SESSION_TIMEOUT then
                token = existingSession.token
                existingSession.lastAction = os.time()
                printLog(playerName .. " продлил сессию")
            else
                token = tostring(math.floor(math.random() * 900000000 + 100000000))
                sessions[playerName] = {token = token, lastAction = os.time()}
                printLog(playerName .. " вошёл в систему")
            end

            modem.send(from, SERVER_PORT, serialization.serialize({
                op="welcome", status="ok", token=token,
                balance=player.balance or 0.0,
                transactions=player.transactions,
                regDate=player.regDate,
                agreed = player.agreed or false,
                shopPaused = shopPaused
            }))
            if currentScreen == "menu" then drawMenu() end
            goto continue
        end

        -- Получение аккаунта
        if msg.op == "getAccount" then
            if not validateSession(msg.name, msg.token) then
                modem.send(from, SERVER_PORT, serialization.serialize({op="accountData", error = true, message = "Токен устарел"}))
                goto continue
            end
            local player = players[msg.name]
            if not player then goto continue end
            sessions[msg.name].lastAction = os.time()
            modem.send(from, SERVER_PORT, serialization.serialize({
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
        end

        -- Продажа (пополнение)
        if msg.op == "sell" then
            if shopPaused then
                modem.send(from, SERVER_PORT, serialization.serialize({op="error", message="Магазин на паузе"}))
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
        end

        -- Покупка (списание)
        if msg.op == "buy" then
            if shopPaused then
                modem.send(from, SERVER_PORT, serialization.serialize({op="error", message="Магазин на паузе"}))
                goto continue
            end
            if not validateSession(msg.name, msg.token) then
                printLog("Неверный токен для buy")
                goto continue
            end
            local player = players[msg.name]
            if not player or player.banned then goto continue end
            local value = tonumber(msg.value) or 0

            if player.balance < value then
                modem.send(from, SERVER_PORT, serialization.serialize({op="error", message="Недостаточно средств"}))
                goto continue
            end

            player.balance = player.balance - value
            player.transactions = (player.transactions or 0) + 1
            sessions[msg.name].lastAction = os.time()

            globalStats.totalBuys = (globalStats.totalBuys or 0) + 1
            saveGlobalStats()
            saveDB()
            printLog(string.format("🛒 %s купил %s x%d за %.2f", msg.name, msg.item, msg.qty, value))
            if currentScreen == "menu" then drawMenu() end
            goto continue
        end

        -- Репорт
        if msg.op == "report" then
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
            else
                printLog("Не удалось открыть reports.log")
            end
            if currentScreen == "menu" then drawMenu() end
            goto continue
        end

        -- Соглашение
        if msg.op == "agree" then
            if not validateSession(msg.name, msg.token) then
                modem.send(from, SERVER_PORT, serialization.serialize({ op="agree", error = true, message = "Токен устарел" }))
                goto continue
            end
            local player = players[msg.name]
            if player then
                player.agreed = true
                saveDB()
                sessions[msg.name].lastAction = os.time()
                printLog("📝 " .. msg.name .. " принял пользовательское соглашение")
                modem.send(from, SERVER_PORT, serialization.serialize({ op = "agree", success = true, agreed = true }))
            else
                modem.send(from, SERVER_PORT, serialization.serialize({ op = "agree", error = true, message = "Игрок не найден" }))
            end
            if currentScreen == "menu" then drawMenu() end
            goto continue
        end

        -- Получение отзывов
        if msg.op == "get_feedbacks" then
            if not validateSession(msg.name, msg.token) then
                modem.send(from, SERVER_PORT, serialization.serialize({op="feedbacks_list", error="Токен устарел"}))
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
            modem.send(from, SERVER_PORT, serialization.serialize({
                op = "feedbacks_list",
                feedbacks = feedbacks,
                hasFeedback = player and player.hasFeedback or false
            }))
            if currentScreen == "menu" then drawMenu() end
            goto continue
        end

        -- Добавление отзыва
        if msg.op == "add_feedback" then
            if not validateSession(msg.name, msg.token) then
                modem.send(from, SERVER_PORT, serialization.serialize({op="add_feedback_response", success=false, error="Токен устарел"}))
                goto continue
            end
            local player = players[msg.name]
            if not player then
                modem.send(from, SERVER_PORT, serialization.serialize({op="add_feedback_response", success=false, error="Игрок не найден"}))
                goto continue
            end
            if player.hasFeedback then
                modem.send(from, SERVER_PORT, serialization.serialize({op="add_feedback_response", success=false, error="Вы уже оставляли отзыв"}))
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
            modem.send(from, SERVER_PORT, serialization.serialize({op="add_feedback_response", success=true}))
            printLog("📝 Новый отзыв от " .. msg.name)
            if currentScreen == "menu" then drawMenu() end
            goto continue
        end

        -- Добавление предмета (от терминала)
        if msg.op == "add_buy_item_response" then
            -- Ничего не делаем, просто логируем
            printLog("Ответ от терминала о добавлении предмета: " .. (msg.success and "успешно" or "ошибка"))
            goto continue
        end

        ::continue::
    end

    -- ===== ОБРАБОТКА КЛАВИАТУРЫ И МЫШИ =====
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
                local id = menuItems[selected].id
                if id == "pause" then
                    handlePause()
                else
                    currentScreen = id
                    listScroll = 1
                    listSelected = 1
                    if id == "players" then drawPlayers()
                    elseif id == "feedbacks" then drawFeedbacks()
                    elseif id == "journal" then drawJournal()
                    elseif id == "stats" then drawStats()
                    elseif id == "admins" then drawAdmins()
                    elseif id == "reports" then drawReports()
                    elseif id == "additem" then drawAddItem()
                    end
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

    -- Обработка кликов мыши (для удобства)
    if etype == "touch" then
        local x, y = ev[3], ev[4]
        if currentScreen == "menu" then
            if y >= 5 and y <= 5 + #menuItems - 1 then
                local idx = y - 5 + 1
                if idx >= 1 and idx <= #menuItems then
                    selected = idx
                    drawMenu()
                    -- Автоматически переходим в выбранный раздел (как Enter)
                    local id = menuItems[selected].id
                    if id == "pause" then
                        handlePause()
                    else
                        currentScreen = id
                        listScroll = 1
                        listSelected = 1
                        if id == "players" then drawPlayers()
                        elseif id == "feedbacks" then drawFeedbacks()
                        elseif id == "journal" then drawJournal()
                        elseif id == "stats" then drawStats()
                        elseif id == "admins" then drawAdmins()
                        elseif id == "reports" then drawReports()
                        elseif id == "additem" then drawAddItem()
                        end
                    end
                end
            end
        elseif currentScreen == "players" then
            -- Клик по списку игроков (выбор)
            if y >= 5 and y <= 19 then
                local idx = listScroll + (y - 5)
                local list = {}
                for name, data in pairs(players) do
                    table.insert(list, {name = name, data = data})
                end
                table.sort(list, function(a, b) return a.name < b.name end)
                if idx >= 1 and idx <= #list then
                    listSelected = idx
                    drawPlayers()
                end
            end
        elseif currentScreen == "feedbacks" then
            -- аналогично для отзывов
        elseif currentScreen == "reports" then
            -- аналогично
        end
    end

    -- Обновление интерфейса при изменении состояния
    if etype == "modem_message" and currentScreen == "menu" then
        drawMenu()
    end
end

printLog("Сервер остановлен")
term.clear()
