-- ============================================================
-- PIM MARKET SERVER + АДМИН-ПАНЕЛЬ (эталонная отрисовка)
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
local TIMEZONE_OFFSET = 3 * 3600
local ACCESS_PASSWORD = "admin"
local SERVER_PORT = 0xffef

local modem = component.modem
modem.open(SERVER_PORT)
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

-- ===== ФУНКЦИИ СЕРВЕРА =====
local function getOrCreatePlayer(name)
    if not players[name] then
        players[name] = {
            balance = 0.0,
            emaBalance = 0.0,
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

local function clear()
    gpu.setBackground(0x000000)
    gpu.fill(1, 1, WIDTH, HEIGHT, " ")
end

local function write(x, y, text, fg)
    if y < 1 or y > HEIGHT or x > WIDTH then return end
    text = tostring(text or "")
    if x < 1 then
        text = unicode.sub(text, 2 - x)
        x = 1
    end
    if text == "" then return end
    gpu.setForeground(fg or 0xFFFFFF)
    gpu.setBackground(0x000000)
    gpu.set(x, y, unicode.sub(text, 1, WIDTH - x + 1))
end

-- ===== МЕНЮ =====
local menuItems = {
    { id = "players",   label = "ИГРОКИ",          desc = "Балансы, блокировки, транзакции" },
    { id = "feedbacks", label = "ОТЗЫВЫ",          desc = "Чтение и удаление отзывов" },
    { id = "journal",   label = "ЖУРНАЛ",          desc = "Только важные события" },
    { id = "stats",     label = "СТАТИСТИКА",      desc = "Покупки, продажи, оборот" },
    { id = "admins",    label = "АДМИНИСТРАТОРЫ",  desc = "Добавить или удалить админа" },
    { id = "pause",     label = "ПРИОСТАНОВИТЬ МАГАЗИН", desc = "Управление доступностью терминалов" },
    { id = "reports",   label = "РЕПОРТЫ",        desc = "Чтение и удаление жалоб" },
    { id = "additem",   label = "ДОБАВИТЬ ПРЕДМЕТ", desc = "Отправить предмет в каталог" },
    { id = "back",      label = "< НАЗАД >",       desc = "" },
}

local selected = 1
local currentScreen = "menu"
local listScroll = 1
local listSelected = 1
local editMode = false
local editInput = ""
local editField = ""

-- ===== ОТРИСОВКА ГЛАВНОГО МЕНЮ =====
local function drawHeader(title)
    write(1, 1, "# " .. (title or "PTM MARKET SERVER"), 0xFFFFFF)
    write(1, 2, "Администрирование", 0x888888)
end

local function drawMenu()
    clear()
    drawHeader()
    local y = 4
    for i, item in ipairs(menuItems) do
        local isSelected = (i == selected)
        local fg = isSelected and 0xFFFFFF or 0x888888
        local descFg = isSelected and 0xAAAAAA or 0x555555

        local labelPart
        if item.id == "back" then
            labelPart = "< НАЗАД >"
        else
            labelPart = "## " .. item.label
        end

        write(2, y, labelPart, fg)
        if item.desc and item.desc ~= "" then
            write(32, y, item.desc, descFg)
        end
        y = y + 1
    end
    write(2, HEIGHT - 1, "Esc – назад | выберите раздел мыльной", 0x666666)
end

-- ===== РАЗДЕЛ "ИГРОКИ" =====
local function drawPlayers()
    clear()
    drawHeader("ИГРОКИ")
    write(1, 4, "Имя", 0x888888)
    write(22, 4, "Coin", 0x888888)
    write(35, 4, "ЭМЫ", 0x888888)
    write(48, 4, "Транз.", 0x888888)
    write(58, 4, "Статус", 0x888888)
    write(70, 4, "Админ", 0x888888)

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
            local y = 5 + i
            local fg = (idx == listSelected) and 0xFFFFFF or 0xAAAAAA
            write(2, y, unicode.sub(item.name, 1, 18), fg)
            write(22, y, string.format("%.2f", item.data.balance or 0), fg)
            write(35, y, string.format("%.2f", item.data.emaBalance or 0), fg)
            write(48, y, string.format("%d", item.data.transactions or 0), fg)
            local status = item.data.banned and "ЗАБАНЕН" or "АКТИВЕН"
            write(58, y, status, fg)
            write(70, y, isAdmin(item.name) and "ДА" or "НЕТ", fg)
        end
    end

    write(1, HEIGHT - 3, "B - бан/разбан | E - редактировать Coin | M - редактировать ЭМЫ | A - админ/снять", 0x888888)
    write(1, HEIGHT - 2, "↑↓ выбор | Esc - назад", 0x888888)

    if editMode then
        write(20, 12, "┌──────────────────────────────────────────┐", 0x666666)
        write(20, 13, "│  Редактирование баланса                  │", 0x666666)
        write(20, 14, "│  " .. editField .. ": " .. editInput .. "_" .. string.rep(" ", 30 - unicode.len(editField) - unicode.len(editInput)), 0xFFFFFF)
        write(20, 15, "│  Enter - подтвердить | Esc - отмена     │", 0x888888)
        write(20, 16, "└──────────────────────────────────────────┘", 0x666666)
    end
end

local function handlePlayers(key, char)
    if editMode then
        if key == 1 then
            editMode = false; editInput = ""; editField = ""; drawPlayers(); return true
        elseif key == 28 then
            local amount = tonumber(editInput)
            if amount and editField == "Coin" then
                local list = {}
                for name, data in pairs(players) do table.insert(list, {name=name, data=data}) end
                table.sort(list, function(a,b) return a.name < b.name end)
                local item = list[listSelected]
                if item then players[item.name].balance = amount; saveDB() end
            elseif editField == "ЭМЫ" then
                local amount = tonumber(editInput)
                if amount then
                    local list = {}
                    for name, data in pairs(players) do table.insert(list, {name=name, data=data}) end
                    table.sort(list, function(a,b) return a.name < b.name end)
                    local item = list[listSelected]
                    if item then players[item.name].emaBalance = amount; saveDB() end
                end
            end
            editMode = false; editInput = ""; editField = ""; drawPlayers(); return true
        elseif char == 8 then
            editInput = unicode.sub(editInput, 1, -2); drawPlayers(); return true
        elseif char >= 32 then
            editInput = editInput .. unicode.char(char); drawPlayers(); return true
        end
        return true
    end

    if key == 1 then currentScreen = "menu"; drawMenu(); return true
    elseif key == 200 then
        listSelected = math.max(1, listSelected - 1)
        if listSelected < listScroll then listScroll = listSelected end
        drawPlayers(); return true
    elseif key == 208 then
        local list = {}
        for name, data in pairs(players) do table.insert(list, {name=name, data=data}) end
        listSelected = math.min(#list, listSelected + 1)
        if listSelected > listScroll + 14 then listScroll = listSelected - 14 end
        drawPlayers(); return true
    elseif char == 98 then -- b
        local list = {}
        for name, data in pairs(players) do table.insert(list, {name=name, data=data}) end
        table.sort(list, function(a,b) return a.name < b.name end)
        local item = list[listSelected]
        if item then players[item.name].banned = not players[item.name].banned; saveDB(); drawPlayers() end
        return true
    elseif char == 101 then -- e
        local list = {}
        for name, data in pairs(players) do table.insert(list, {name=name, data=data}) end
        table.sort(list, function(a,b) return a.name < b.name end)
        local item = list[listSelected]
        if item then editMode = true; editInput = tostring(item.data.balance or 0); editField = "Coin"; drawPlayers() end
        return true
    elseif char == 109 then -- m
        local list = {}
        for name, data in pairs(players) do table.insert(list, {name=name, data=data}) end
        table.sort(list, function(a,b) return a.name < b.name end)
        local item = list[listSelected]
        if item then editMode = true; editInput = tostring(item.data.emaBalance or 0); editField = "ЭМЫ"; drawPlayers() end
        return true
    elseif char == 97 then -- a
        local list = {}
        for name, data in pairs(players) do table.insert(list, {name=name, data=data}) end
        table.sort(list, function(a,b) return a.name < b.name end)
        local item = list[listSelected]
        if item then
            if isAdmin(item.name) then removeAdmin(item.name) else addAdmin(item.name) end
            drawPlayers()
        end
        return true
    end
    return false
end

-- ===== РАЗДЕЛ "ОТЗЫВЫ" =====
local function drawFeedbacks()
    clear(); drawHeader("ОТЗЫВЫ")
    write(1, 4, "Имя", 0x888888)
    write(18, 4, "Дата", 0x888888)
    write(40, 4, "Текст", 0x888888)

    local feedbacks = {}
    if filesystem.exists("/home/feedbacks.db") then
        local file = io.open("/home/feedbacks.db", "r")
        if file then
            local data = file:read("*a")
            file:close()
            if data and #data > 0 then
                local ok, result = pcall(serialization.unserialize, data)
                if ok and type(result) == "table" then feedbacks = result end
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
            local fg = (idx == listSelected) and 0xFFFFFF or 0xAAAAAA
            write(2, y, unicode.sub(fb.name or "?", 1, 15), fg)
            write(18, y, unicode.sub(fb.time or "", 1, 20), 0x888888)
            write(40, y, unicode.sub(fb.text or "", 1, 37), fg)
        end
    end

    write(1, HEIGHT - 3, "D - удалить отзыв | ↑↓ выбор | Esc - назад", 0x888888)
end

local function handleFeedbacks(key, char)
    if key == 1 then currentScreen = "menu"; drawMenu(); return true
    elseif key == 200 then
        listSelected = math.max(1, listSelected - 1)
        if listSelected < listScroll then listScroll = listSelected end
        drawFeedbacks(); return true
    elseif key == 208 then
        local feedbacks = {}
        if filesystem.exists("/home/feedbacks.db") then
            local file = io.open("/home/feedbacks.db", "r")
            if file then
                local data = file:read("*a")
                file:close()
                if data and #data > 0 then
                    local ok, result = pcall(serialization.unserialize, data)
                    if ok and type(result) == "table" then feedbacks = result end
                end
            end
        end
        listSelected = math.min(#feedbacks, listSelected + 1)
        if listSelected > listScroll + 13 then listScroll = listSelected - 13 end
        drawFeedbacks(); return true
    elseif char == 100 then
        local feedbacks = {}
        if filesystem.exists("/home/feedbacks.db") then
            local file = io.open("/home/feedbacks.db", "r")
            if file then
                local data = file:read("*a")
                file:close()
                if data and #data > 0 then
                    local ok, result = pcall(serialization.unserialize, data)
                    if ok and type(result) == "table" then feedbacks = result end
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
    clear(); drawHeader("ЖУРНАЛ СОБЫТИЙ")
    local lines = {}
    if filesystem.exists("/home/server_events.log") then
        local file = io.open("/home/server_events.log", "r")
        if file then
            for line in file:lines() do table.insert(lines, line) end
            file:close()
        end
    end
    local maxScroll = math.max(1, #lines - 16)
    listScroll = math.max(1, math.min(listScroll, maxScroll))
    for i = 1, 16 do
        local idx = #lines - listScroll - i + 2
        if idx >= 1 and idx <= #lines then
            write(2, 5 + i, unicode.sub(lines[idx], 1, 76), 0xAAAAAA)
        end
    end
    write(1, HEIGHT - 2, "Esc - назад", 0x888888)
end

local function handleJournal(key, char)
    if key == 1 then currentScreen = "menu"; drawMenu(); return true end
    return false
end

-- ===== РАЗДЕЛ "СТАТИСТИКА" =====
local function drawStats()
    clear(); drawHeader("СТАТИСТИКА")
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
        write(10, 5 + i*2, stat[1], 0x888888)
        write(35, 5 + i*2, stat[2], 0xFFFFFF)
    end
    write(1, HEIGHT - 2, "Esc - назад", 0x888888)
end

local function handleStats(key, char)
    if key == 1 then currentScreen = "menu"; drawMenu(); return true end
    return false
end

-- ===== РАЗДЕЛ "АДМИНИСТРАТОРЫ" =====
local function drawAdmins()
    clear(); drawHeader("АДМИНИСТРАТОРЫ")
    for i, name in ipairs(admins) do
        write(3, 5 + i, tostring(i) .. ". " .. name, 0xFFFFFF)
    end
    write(1, HEIGHT - 4, "A - добавить администратора", 0x888888)
    write(1, HEIGHT - 3, "D - удалить последнего", 0x888888)
    write(1, HEIGHT - 2, "Esc - назад", 0x888888)
    if editMode then
        write(20, 12, "┌──────────────────────────────────────────┐", 0x666666)
        write(20, 13, "│  Введите ник:                             │", 0x666666)
        write(20, 14, "│  " .. editInput .. "_" .. string.rep(" ", 40 - unicode.len(editInput)), 0xFFFFFF)
        write(20, 15, "│  Enter - добавить | Esc - отмена        │", 0x888888)
        write(20, 16, "└──────────────────────────────────────────┘", 0x666666)
    end
end

local function handleAdmins(key, char)
    if editMode then
        if key == 1 then editMode = false; editInput = ""; drawAdmins(); return true
        elseif key == 28 then
            if editInput ~= "" then addAdmin(editInput) end
            editMode = false; editInput = ""; drawAdmins(); return true
        elseif char == 8 then
            editInput = unicode.sub(editInput, 1, -2); drawAdmins(); return true
        elseif char >= 32 then
            editInput = editInput .. unicode.char(char); drawAdmins(); return true
        end
        return true
    end
    if key == 1 then currentScreen = "menu"; drawMenu(); return true
    elseif char == 97 then editMode = true; editInput = ""; drawAdmins(); return true
    elseif char == 100 then
        if #admins > 1 then removeAdmin(admins[#admins]); drawAdmins() end
        return true
    end
    return false
end

-- ===== РАЗДЕЛ "РЕПОРТЫ" =====
local function drawReports()
    clear(); drawHeader("РЕПОРТЫ")
    local reports = {}
    if filesystem.exists("/home/reports.log") then
        local file = io.open("/home/reports.log", "r")
        if file then
            for line in file:lines() do table.insert(reports, line) end
            file:close()
        end
    end
    local maxScroll = math.max(1, #reports - 14)
    listScroll = math.max(1, math.min(listScroll, maxScroll))
    for i = 1, 14 do
        local idx = listScroll + i - 1
        if idx <= #reports then
            local y = 5 + i
            write(2, y, unicode.sub(reports[idx], 1, 74), (idx == listSelected) and 0xFFFFFF or 0xAAAAAA)
        end
    end
    write(1, HEIGHT - 3, "D - удалить репорт | ↑↓ выбор | Esc - назад", 0x888888)
end

local function handleReports(key, char)
    if key == 1 then currentScreen = "menu"; drawMenu(); return true
    elseif key == 200 then
        listSelected = math.max(1, listSelected - 1)
        if listSelected < listScroll then listScroll = listSelected end
        drawReports(); return true
    elseif key == 208 then
        local reports = {}
        if filesystem.exists("/home/reports.log") then
            local file = io.open("/home/reports.log", "r")
            if file then
                for line in file:lines() do table.insert(reports, line) end
                file:close()
            end
        end
        listSelected = math.min(#reports, listSelected + 1)
        if listSelected > listScroll + 13 then listScroll = listSelected - 13 end
        drawReports(); return true
    elseif char == 100 then
        local reports = {}
        if filesystem.exists("/home/reports.log") then
            local file = io.open("/home/reports.log", "r")
            if file then
                for line in file:lines() do table.insert(reports, line) end
                file:close()
            end
        end
        if listSelected <= #reports then
            table.remove(reports, listSelected)
            local file = io.open("/home/reports.log", "w")
            if file then
                for _, line in ipairs(reports) do file:write(line .. "\n") end
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
    clear(); drawHeader("ДОБАВИТЬ ПРЕДМЕТ В КАТАЛОГ ПОКУПОК")
    for i, f in ipairs(addItemFields) do
        local y = 5 + i * 2
        local prefix = (i == addItemSelected) and ">" or " "
        local fg = (i == addItemSelected) and 0xFFFFFF or 0x888888
        write(4, y, prefix .. " " .. f.label, fg)
        write(30, y, f.value, fg)
    end
    write(1, HEIGHT - 4, "↑↓ выбор поля | Enter - редактировать | S - отправить", 0x888888)
    write(1, HEIGHT - 3, "Esc - назад", 0x888888)
    if editMode then
        write(20, 12, "┌──────────────────────────────────────────┐", 0x666666)
        write(20, 13, "│  Введите значение:                       │", 0x666666)
        write(20, 14, "│  " .. editInput .. "_" .. string.rep(" ", 40 - unicode.len(editInput)), 0xFFFFFF)
        write(20, 15, "│  Enter - подтвердить | Esc - отмена     │", 0x888888)
        write(20, 16, "└──────────────────────────────────────────┘", 0x666666)
    end
end

local function handleAddItem(key, char)
    if editMode then
        if key == 1 then editMode = false; editInput = ""; drawAddItem(); return true
        elseif key == 28 then
            local field = addItemFields[addItemSelected]
            if field then field.value = editInput end
            editMode = false; editInput = ""; drawAddItem(); return true
        elseif char == 8 then
            editInput = unicode.sub(editInput, 1, -2); drawAddItem(); return true
        elseif char >= 32 then
            editInput = editInput .. unicode.char(char); drawAddItem(); return true
        end
        return true
    end

    if key == 1 then currentScreen = "menu"; drawMenu(); return true
    elseif key == 200 then
        addItemSelected = math.max(1, addItemSelected - 1); drawAddItem(); return true
    elseif key == 208 then
        addItemSelected = math.min(#addItemFields, addItemSelected + 1); drawAddItem(); return true
    elseif key == 28 then
        local field = addItemFields[addItemSelected]
        if field then editMode = true; editInput = field.value; drawAddItem() end
        return true
    elseif char == 115 then -- s
        local internal = addItemFields[1].value
        local display = addItemFields[2].value
        local price_coin = tonumber(addItemFields[3].value) or 0
        local price_ema = tonumber(addItemFields[4].value) or 0
        local damage = tonumber(addItemFields[5].value) or 0
        if internal == "" or display == "" then
            printLog("Ошибка: Internal Name и Display Name обязательны")
            drawAddItem(); return true
        end
        if price_coin <= 0 and price_ema <= 0 then
            printLog("Ошибка: цена должна быть >0")
            drawAddItem(); return true
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
            printLog("Предмет отправлен на " .. sent .. " терминалов: " .. display)
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
    for addr, _ in pairs(markets) do
        modem.send(addr, SERVER_PORT, serialization.serialize({op = "pause_status", paused = shopPaused}))
    end
    currentScreen = "menu"
    drawMenu()
end

-- ===== ОСНОВНОЙ ЦИКЛ =====
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
        if not success or not msg or type(msg) ~= "table" then goto continue end

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
        elseif msg.op == "enter" then
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
                printLog(playerName .. " вошёл")
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
        elseif msg.op == "getAccount" then
            if not validateSession(msg.name, msg.token) then
                modem.send(from, SERVER_PORT, serialization.serialize({op="accountData", error=true, message="Токен устарел"}))
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
        elseif msg.op == "sell" then
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
            saveGlobalStats(); saveDB()
            printLog(string.format("💰 %s пополнил баланс: %s x%d на %.2f", msg.name, msg.item, qty, value))
            if currentScreen == "menu" then drawMenu() end
            goto continue
        elseif msg.op == "buy" then
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
            saveGlobalStats(); saveDB()
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
            else
                printLog("Не удалось открыть reports.log")
            end
            if currentScreen == "menu" then drawMenu() end
            goto continue
        elseif msg.op == "agree" then
            if not validateSession(msg.name, msg.token) then
                modem.send(from, SERVER_PORT, serialization.serialize({ op="agree", error=true, message="Токен устарел" }))
                goto continue
            end
            local player = players[msg.name]
            if player then
                player.agreed = true
                saveDB()
                sessions[msg.name].lastAction = os.time()
                printLog("📝 " .. msg.name .. " принял соглашение")
                modem.send(from, SERVER_PORT, serialization.serialize({ op="agree", success=true, agreed=true }))
            else
                modem.send(from, SERVER_PORT, serialization.serialize({ op="agree", error=true, message="Игрок не найден" }))
            end
            if currentScreen == "menu" then drawMenu() end
            goto continue
        elseif msg.op == "get_feedbacks" then
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
                    if ok and type(result) == "table" then feedbacks = result end
                end
            end
            modem.send(from, SERVER_PORT, serialization.serialize({
                op="feedbacks_list",
                feedbacks = feedbacks,
                hasFeedback = player and player.hasFeedback or false
            }))
            if currentScreen == "menu" then drawMenu() end
            goto continue
        elseif msg.op == "add_feedback" then
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
                    if ok and type(result) == "table" then feedbacks = result end
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
        ::continue::
    end

    -- ===== ОБРАБОТКА КЛАВИАТУРЫ =====
    if etype == "key_down" then
        local key = ev[4]
        local char = ev[3]

        if currentScreen == "menu" then
            if key == 1 then
                break
            elseif key == 200 then
                selected = math.max(1, selected - 1)
                drawMenu()
            elseif key == 208 then
                selected = math.min(#menuItems, selected + 1)
                drawMenu()
            elseif key == 28 then
                local id = menuItems[selected].id
                if id == "pause" then
                    handlePause()
                elseif id == "back" then
                    break
                else
                    currentScreen = id
                    listScroll = 1; listSelected = 1
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

    -- ===== ОБРАБОТКА КЛИКОВ МЫШИ =====
    if etype == "touch" then
        local x, y = ev[3], ev[4]
        if currentScreen == "menu" then
            if y >= 4 and y <= 4 + #menuItems - 1 then
                local idx = y - 4 + 1
                if idx >= 1 and idx <= #menuItems then
                    selected = idx
                    drawMenu()
                    local id = menuItems[selected].id
                    if id == "pause" then
                        handlePause()
                    elseif id == "back" then
                        break
                    else
                        currentScreen = id
                        listScroll = 1; listSelected = 1
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
            if y >= 5 and y <= 19 then
                local idx = listScroll + (y - 5)
                local list = {}
                for name, data in pairs(players) do table.insert(list, {name=name, data=data}) end
                table.sort(list, function(a,b) return a.name < b.name end)
                if idx >= 1 and idx <= #list then
                    listSelected = idx
                    drawPlayers()
                end
            end
        end
    end
end

printLog("Сервер остановлен")
term.clear()
