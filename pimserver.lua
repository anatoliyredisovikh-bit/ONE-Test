--[[
    ========================================================================
    PIM MARKET SERVER – Админ-панель с серверной логикой
    Версия 6.0 – ФИНАЛЬНАЯ (с ручным определением getCurrentScript)
    ========================================================================
]]

-- =====================================================================
--  ПОДКЛЮЧЕНИЕ СИСТЕМНЫХ МОДУЛЕЙ
-- =====================================================================
local component = require("component")
local event = require("event")
local filesystem = require("filesystem")
local computer = require("computer")
local term = require("term")
local gpu = component.gpu
local os = require("os")
local math = require("math")

-- =====================================================================
--  АВТОМАТИЧЕСКАЯ УСТАНОВКА ВСЕХ ЗАВИСИМОСТЕЙ (ЧЕРЕЗ wget)
-- =====================================================================
local function ensureAllDependencies()
    local deps = {
        { name = "GUI",            url = "http://raw.githubusercontent.com/IgorTimofeev/GUI/master/GUI.lua" },
        { name = "doubleBuffering",url = "http://raw.githubusercontent.com/IgorTimofeev/GUI/master/doubleBuffering.lua" },
        { name = "color",          url = "http://raw.githubusercontent.com/IgorTimofeev/color/master/color.lua" },
        { name = "advancedLua",    url = "http://raw.githubusercontent.com/IgorTimofeev/advancedLua/master/advancedLua.lua" },
        { name = "image",          url = "http://raw.githubusercontent.com/IgorTimofeev/image/master/image.lua" },
        { name = "OCIF",           url = "http://raw.githubusercontent.com/IgorTimofeev/OCIF/master/OCIF.lua" },
    }

    if not filesystem.exists("/lib") then
        print("📁 Создаю папку /lib...")
        filesystem.makeDirectory("/lib")
    end

    local missing = {}
    for _, dep in ipairs(deps) do
        local path = "/lib/" .. dep.name .. ".lua"
        if not filesystem.exists(path) then
            table.insert(missing, dep)
        end
    end

    if #missing == 0 then
        print("✅ Все зависимости уже установлены.")
        return true
    end

    print("⚠️ Обнаружены отсутствующие зависимости. Начинаю загрузку...")
    local success = true
    for _, dep in ipairs(missing) do
        print("⬇️ Загрузка " .. dep.name .. " ...")
        local command = "wget -f " .. dep.url .. " /lib/" .. dep.name .. ".lua"
        local result = os.execute(command)
        if not result then
            print("❌ Не удалось загрузить " .. dep.name)
            print("   Попробуйте вручную: " .. command)
            success = false
        else
            print("✅ " .. dep.name .. " установлен.")
        end
    end

    if success then
        print("🎉 Все зависимости успешно установлены!")
        return true
    else
        print("❌ Некоторые зависимости не установлены. Скрипт не может продолжить работу.")
        return false
    end
end

if not ensureAllDependencies() then
    print("Нажмите любую клавишу для выхода...")
    computer.pullEvent("key_down")
    os.exit()
end

-- =====================================================================
--  КРИТИЧЕСКИЙ ФИКС: определяем getCurrentScript вручную (если отсутствует)
-- =====================================================================
if not getCurrentScript then
    -- Загружаем advancedLua, чтобы получить его функции (если получится)
    local ok, adv = pcall(require, "advancedLua")
    if ok and adv and adv.getCurrentScript then
        getCurrentScript = adv.getCurrentScript
        print("✅ getCurrentScript получен из advancedLua")
    else
        -- Создаём заглушку, которая возвращает путь к текущему скрипту
        getCurrentScript = function()
            return debug and debug.getinfo(2).source or "/home/pinserver"
        end
        print("⚠️ getCurrentScript определён как заглушка (работает корректно)")
    end
end

-- Теперь подключаем GUI (он уже должен видеть getCurrentScript)
local GUI = require("GUI")
local buffer = require("doubleBuffering")
local serialization = require("serialization")

-- =====================================================================
--  КОНФИГУРАЦИЯ
-- =====================================================================
local CONFIG = {
    colors = {
        players    = 0x9B59B6,
        stats      = 0x2ECC71,
        reports    = 0xE74C3C,
        reviews    = 0x1ABC9C,
        admins     = 0xE67E22,
        addItem    = 0x3498DB,
        journal    = 0xF1C40F,
        storeStatus = 0xBDC3C7,
    },
    windowWidth = 80,
    windowHeight = 25,
    dbPath = "/home/players.db",
    statsPath = "/home/global_stats.db",
    feedbacksPath = "/home/feedbacks.db",
    reportsLog = "/home/reports.log",
    password = "admin",
    adminName = "Kalleront",
    timezoneOffset = 3 * 3600,
}

-- =====================================================================
--  ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ (время)
-- =====================================================================
local tmpfs = component.proxy(computer.tmpAddress())
local function getRealTimestamp()
    local handle = tmpfs.open("/time", "w")
    tmpfs.write(handle, "time")
    tmpfs.close(handle)
    return tmpfs.lastModified("/time") / 1000 + CONFIG.timezoneOffset
end

local function getRealDateTimeString()
    return os.date("%d.%m.%Y %H:%M:%S", getRealTimestamp())
end

-- =====================================================================
--  СЕРВЕРНАЯ ЛОГИКА (BACKEND)
-- =====================================================================
local Server = {}
Server.__index = Server

function Server.new()
    local self = setmetatable({}, Server)
    self.players = {}
    self.globalStats = { totalReports = 0, totalBuys = 0, totalSells = 0 }
    self.sessions = {}
    self.feedbacks = {}
    self.markets = {}
    self.owner = nil
    self.marketConnected = false
    self.shopPaused = false
    self.adminName = CONFIG.adminName
    self.password = CONFIG.password
    self.SESSION_TIMEOUT = 31536000
    self.modem = component.modem
    self.modem.open(0xffef)
    self.modem.open(0xfffe)
    self:loadData()
    return self
end

function Server:loadData()
    if filesystem.exists(CONFIG.dbPath) then
        local file = io.open(CONFIG.dbPath, "r")
        local raw = file:read("*a")
        file:close()
        if raw and #raw > 0 then
            local success, data = pcall(serialization.unserialize, raw)
            if success and data then self.players = data end
        end
    end
    if filesystem.exists(CONFIG.statsPath) then
        local file = io.open(CONFIG.statsPath, "r")
        local raw = file:read("*a")
        file:close()
        if raw and #raw > 0 then
            local success, data = pcall(serialization.unserialize, raw)
            if success and data then
                self.globalStats.totalReports = data.totalReports or 0
                self.globalStats.totalBuys = data.totalBuys or 0
                self.globalStats.totalSells = data.totalSells or 0
            end
        end
    end
    if filesystem.exists(CONFIG.feedbacksPath) then
        local file = io.open(CONFIG.feedbacksPath, "r")
        local raw = file:read("*a")
        file:close()
        if raw and #raw > 0 then
            local success, data = pcall(serialization.unserialize, raw)
            if success and type(data) == "table" then
                self.feedbacks = data
            end
        end
    end
end

function Server:savePlayers()
    local file = io.open(CONFIG.dbPath, "w")
    file:write(serialization.serialize(self.players))
    file:close()
end

function Server:saveGlobalStats()
    local file = io.open(CONFIG.statsPath, "w")
    file:write(serialization.serialize(self.globalStats))
    file:close()
end

function Server:saveFeedbacks()
    local file = io.open(CONFIG.feedbacksPath, "w")
    file:write(serialization.serialize(self.feedbacks))
    file:close()
end

function Server:getOrCreatePlayer(name)
    if not self.players[name] then
        self.players[name] = {
            balance = 0.0,
            transactions = 0,
            regDate = getRealDateTimeString(),
            agreed = false,
            banned = false,
            hasFeedback = false
        }
        self:savePlayers()
        self:log("Создан игрок " .. name)
    end
    return self.players[name]
end

function Server:validateSession(name, token)
    local s = self.sessions[name]
    return s and s.token == token and os.time() - (s.lastAction or 0) < self.SESSION_TIMEOUT
end

function Server:log(msg)
    local line = "[" .. getRealDateTimeString() .. "] " .. msg
    print(line)
end

function Server:handleMessage(from, port, raw)
    local success, msg = pcall(serialization.unserialize, raw)
    if not success or not msg or type(msg) ~= "table" then
        return
    end

    local op = msg.op
    local responsePort = 0xffef

    if op == "register" then
        if msg.password ~= self.password then
            self.modem.send(from, responsePort, serialization.serialize({op="error", message="Неверный пароль"}))
            self:log("Попытка подключения с неверным паролем от " .. from)
            return
        end
        self.marketConnected = true
        if not self.owner then
            self.owner = from
            self:log("АДМИН ЗАРЕГИСТРИРОВАН: " .. from)
        end
        if not self.markets[from] then
            self.markets[from] = true
            self:log("Терминал добавлен: " .. from)
        end
        self.modem.send(from, responsePort, serialization.serialize({
            op="welcome", owner=(from==self.owner), shopPaused=self.shopPaused
        }))
        return
    end

    if op == "enter" then
        if self.shopPaused then
            self.modem.send(from, responsePort, serialization.serialize({op="error", message="Магазин на паузе"}))
            return
        end
        local playerName = msg.name
        if not playerName or playerName == "" then
            self:log("Вход без имени от " .. from)
            return
        end
        local player = self:getOrCreatePlayer(playerName)
        if player.banned then
            self.modem.send(from, responsePort, serialization.serialize({op="error", message="Вы забанены"}))
            return
        end

        local existingSession = self.sessions[playerName]
        local token
        if existingSession and os.time() - (existingSession.lastAction or 0) < self.SESSION_TIMEOUT then
            token = existingSession.token
            existingSession.lastAction = os.time()
            self:log(playerName .. " продлил сессию")
        else
            token = tostring(math.floor(math.random() * 900000000 + 100000000))
            self.sessions[playerName] = {token = token, lastAction = os.time()}
            self:log(playerName .. " вошёл")
        end

        self.modem.send(from, responsePort, serialization.serialize({
            op="welcome", status="ok", token=token,
            balance=player.balance or 0.0,
            transactions=player.transactions,
            regDate=player.regDate,
            agreed = player.agreed or false,
            shopPaused = self.shopPaused
        }))
        return
    end

    if op == "getAccount" then
        if not self:validateSession(msg.name, msg.token) then
            self.modem.send(from, responsePort, serialization.serialize({op="accountData", error=true, message="Токен устарел"}))
            return
        end
        local player = self.players[msg.name]
        if not player then return end
        self.sessions[msg.name].lastAction = os.time()
        self.modem.send(from, responsePort, serialization.serialize({
            op="accountData",
            data = {
                balance = player.balance,
                transactions = player.transactions,
                regDate = player.regDate,
                agreed = player.agreed,
                shopPaused = self.shopPaused
            }
        }))
        return
    end

    if op == "sell" then
        if self.shopPaused then
            self.modem.send(from, responsePort, serialization.serialize({op="error", message="Магазин на паузе"}))
            return
        end
        if not self:validateSession(msg.name, msg.token) then
            self:log("Неверный токен для sell")
            return
        end
        local player = self.players[msg.name]
        if not player or player.banned then return end
        local qty = tonumber(msg.qty) or 0
        local value = tonumber(msg.value) or 0

        player.balance = (player.balance or 0) + value
        player.transactions = (player.transactions or 0) + 1
        self.sessions[msg.name].lastAction = os.time()

        self.globalStats.totalSells = (self.globalStats.totalSells or 0) + 1
        self:saveGlobalStats()
        self:savePlayers()
        self:log(string.format("💰 %s пополнил баланс: предмет '%s' x%d на сумму %.2f", msg.name, msg.item, qty, value))
        return
    end

    if op == "buy" then
        if self.shopPaused then
            self.modem.send(from, responsePort, serialization.serialize({op="error", message="Магазин на паузе"}))
            return
        end
        if not self:validateSession(msg.name, msg.token) then
            self:log("Неверный токен для buy")
            return
        end
        local player = self.players[msg.name]
        if not player or player.banned then return end
        local value = tonumber(msg.value) or 0

        player.balance = (player.balance or 0) - value
        player.transactions = (player.transactions or 0) + 1
        self.sessions[msg.name].lastAction = os.time()

        self.globalStats.totalBuys = (self.globalStats.totalBuys or 0) + 1
        self:saveGlobalStats()
        self:savePlayers()
        self:log(string.format("🛒 %s купил %s x%d за %.2f", msg.name, msg.item, msg.qty, value))
        return
    end

    if op == "report" then
        if not self:validateSession(msg.name, msg.token) then
            self:log("Неверный токен для report")
            return
        end
        self.globalStats.totalReports = (self.globalStats.totalReports or 0) + 1
        self:saveGlobalStats()
        self:log("📩 Репорт от " .. msg.name .. " (" .. msg.time .. ")")
        self:log("   Текст: " .. (msg.text or ""))
        local file = io.open(CONFIG.reportsLog, "a")
        if file then
            file:write("[" .. msg.time .. "] " .. msg.name .. ": " .. msg.text .. "\n")
            file:close()
        end
        return
    end

    if op == "agree" then
        if not self:validateSession(msg.name, msg.token) then
            self.modem.send(from, responsePort, serialization.serialize({op="agree", error=true, message="Токен устарел"}))
            return
        end
        local player = self.players[msg.name]
        if player then
            player.agreed = true
            self:savePlayers()
            self.sessions[msg.name].lastAction = os.time()
            self:log("📝 " .. msg.name .. " принял пользовательское соглашение")
            self.modem.send(from, responsePort, serialization.serialize({op="agree", success=true, agreed=true}))
        else
            self.modem.send(from, responsePort, serialization.serialize({op="agree", error=true, message="Игрок не найден"}))
        end
        return
    end

    if op == "get_feedbacks" then
        if not self:validateSession(msg.name, msg.token) then
            self.modem.send(from, responsePort, serialization.serialize({op="feedbacks_list", error="Токен устарел"}))
            return
        end
        local player = self.players[msg.name]
        self.modem.send(from, responsePort, serialization.serialize({
            op = "feedbacks_list",
            feedbacks = self.feedbacks,
            hasFeedback = player and player.hasFeedback or false
        }))
        return
    end

    if op == "add_feedback" then
        if not self:validateSession(msg.name, msg.token) then
            self.modem.send(from, responsePort, serialization.serialize({op="add_feedback_response", success=false, error="Токен устарел"}))
            return
        end
        local player = self.players[msg.name]
        if not player then
            self.modem.send(from, responsePort, serialization.serialize({op="add_feedback_response", success=false, error="Игрок не найден"}))
            return
        end
        if player.hasFeedback then
            self.modem.send(from, responsePort, serialization.serialize({op="add_feedback_response", success=false, error="Вы уже оставляли отзыв"}))
            return
        end
        table.insert(self.feedbacks, 1, {name = msg.name, text = msg.text, time = msg.time})
        self:saveFeedbacks()
        player.hasFeedback = true
        self:savePlayers()
        self.modem.send(from, responsePort, serialization.serialize({op="add_feedback_response", success=true}))
        self:log("📝 Новый отзыв от " .. msg.name .. ": " .. msg.text)
        return
    end
end

-- =====================================================================
--  GUI-ПРИЛОЖЕНИЕ (АДМИН-ПАНЕЛЬ)
-- =====================================================================

local server = Server.new()

local app = GUI.application()
app:addChild(GUI.panel(1, 1, app.width, app.height, 0x000000))

local topPanel = app:addChild(GUI.panel(1, 1, app.width, 1, 0x000000))
local titleLabel = topPanel:addChild(GUI.label(1, 1, 20, 1, 0xFFFFFF, "PIM MARKET SERVER"))
local statusLabel = topPanel:addChild(GUI.label(app.width - 30, 1, 30, 1, 0xFFFFFF, ""))

local function updateStatus()
    local status = server.shopPaused and "MARKET OFFLINE" or "MARKET ONLINE"
    local color = server.shopPaused and 0xE74C3C or 0x2ECC71
    statusLabel.text = status .. " " .. os.date("%Y-%m-%d %H:%M:%S")
    statusLabel.color = color
end

local menuContainer = app:addChild(GUI.container(1, 3, app.width, 14))

local menuData = {
    { id = "players",    label = "ИГРОКИ",           sublabel = "Балансы, блокировки, транзакции", color = CONFIG.colors.players },
    { id = "stats",      label = "СТАТИСТИКА",       sublabel = "Покупки, продажи, оборот",        color = CONFIG.colors.stats },
    { id = "reports",    label = "РЕПОРТЫ",          sublabel = "Чтение и удаление жалоб",         color = CONFIG.colors.reports },
    { id = "reviews",    label = "ОТЗЫВЫ",           sublabel = "Чтение и удаление отзывов",       color = CONFIG.colors.reviews },
    { id = "admins",     label = "АДМИНИСТРАТОРЫ",   sublabel = "Добавить или удалить админа",    color = CONFIG.colors.admins },
    { id = "addItem",    label = "ДОБАВИТЬ ПРЕДМЕТ", sublabel = "Отправить предмет в каталог",    color = CONFIG.colors.addItem },
    { id = "journal",    label = "ЖУРНАЛ",           sublabel = "Только важные события",           color = CONFIG.colors.journal },
    { id = "storeStatus",label = "ПРИОСТАНОВИТЬ МАГАЗИН", sublabel = "Управление доступностью терминалов", color = CONFIG.colors.storeStatus },
}

local cols, rows = 3, 3
local blockW, blockH = 24, 4
local gapX, gapY = 4, 2
local totalWidth = blockW * cols + gapX * (cols - 1)
local startX = math.floor((app.width - totalWidth) / 2)
local startY = 1

local function createMenuBlock(x, y, w, h, color, label, sublabel, sectionId)
    local panel = menuContainer:addChild(GUI.panel(x, y, w, h, 0x000000))
    panel.borderColor = color
    panel.borderSize = 1
    panel.draw = function(self)
        GUI.panel.draw(self)
        local fg = 0xFFFFFF
        local bg = 0x000000
        local labelX = x + math.floor((w - #label) / 2)
        local subX   = x + math.floor((w - #sublabel) / 2)
        buffer.text(labelX, y + 1, fg, bg, label)
        buffer.text(subX, y + 2, fg, bg, sublabel)
    end
    panel.onTouch = function()
        showSection(sectionId)
    end
    panel.onMouseEnter = function()
        panel.borderColor = math.min(color + 0x444444, 0xFFFFFF)
        app:draw()
        buffer.draw()
    end
    panel.onMouseLeave = function()
        panel.borderColor = color
        app:draw()
        buffer.draw()
    end
    return panel
end

for i, data in ipairs(menuData) do
    local row = math.floor((i - 1) / cols)
    local col = (i - 1) % cols
    local x = startX + col * (blockW + gapX)
    local y = startY + row * (blockH + gapY)
    createMenuBlock(x, y, blockW, blockH, data.color, data.label, data.sublabel, data.id)
end

local contentContainer = app:addChild(GUI.container(1, 18, app.width, app.height - 20))

local function showSection(sectionId)
    contentContainer:deleteChildren()
    local panel = contentContainer:addChild(GUI.panel(1, 1, contentContainer.width, contentContainer.height, 0x000000))
    panel.draw = function(self)
        GUI.panel.draw(self)
        local y = 2
        local fg = 0xFFFFFF
        local bg = 0x000000

        if sectionId == "players" then
            buffer.text(2, y, fg, bg, "=== ИГРОКИ ===")
            y = y + 1
            for name, data in pairs(server.players) do
                local line = name .. " | Баланс: " .. data.balance .. " | Заблокирован: " .. tostring(data.banned)
                buffer.text(2, y, fg, bg, line)
                local btnBlock = panel:addChild(GUI.button(50, y, 12, 1, 0xE74C3C, 0xFFFFFF, 0xC0392B, 0xFFFFFF, data.banned and "Разблок." or "Заблок."))
                btnBlock.onTouch = function()
                    data.banned = not data.banned
                    server:savePlayers()
                    showSection(sectionId)
                end
                local btnAdd = panel:addChild(GUI.button(65, y, 12, 1, 0x2ECC71, 0xFFFFFF, 0x27AE60, 0xFFFFFF, "+ Баланс"))
                btnAdd.onTouch = function()
                    local input = GUI.inputBox(app, "Пополнение баланса", "Введите сумму:", "", true)
                    if input and tonumber(input) then
                        data.balance = (data.balance or 0) + tonumber(input)
                        server:savePlayers()
                        showSection(sectionId)
                    end
                end
                y = y + 1
                local tcount = data.transactions or 0
                if tcount > 0 then
                    buffer.text(4, y, fg, bg, "Транзакций: " .. tcount)
                    y = y + 1
                end
                y = y + 1
            end
        elseif sectionId == "stats" then
            buffer.text(2, y, fg, bg, "=== СТАТИСТИКА ===")
            y = y + 1
            buffer.text(2, y, fg, bg, "Покупок: " .. server.globalStats.totalBuys)
            y = y + 1
            buffer.text(2, y, fg, bg, "Продаж:   " .. server.globalStats.totalSells)
            y = y + 1
            buffer.text(2, y, fg, bg, "Оборот:   " .. (server.globalStats.totalBuys + server.globalStats.totalSells))
            y = y + 1
            buffer.text(2, y, fg, bg, "Репортов: " .. server.globalStats.totalReports)
        elseif sectionId == "reports" then
            buffer.text(2, y, fg, bg, "=== РЕПОРТЫ (ЖАЛОБЫ) ===")
            y = y + 1
            local reports = {}
            if filesystem.exists(CONFIG.reportsLog) then
                local file = io.open(CONFIG.reportsLog, "r")
                local content = file:read("*a")
                file:close()
                for line in content:gmatch("[^\n]+") do
                    table.insert(reports, line)
                end
            end
            if #reports == 0 then
                buffer.text(2, y, fg, bg, "Нет жалоб.")
            else
                for i, line in ipairs(reports) do
                    buffer.text(2, y, fg, bg, line)
                    local btn = panel:addChild(GUI.button(60, y, 12, 1, 0x2ECC71, 0xFFFFFF, 0x27AE60, 0xFFFFFF, "Разрешить"))
                    btn.onTouch = function()
                        local newContent = ""
                        for j, l in ipairs(reports) do
                            if j ~= i then newContent = newContent .. l .. "\n" end
                        end
                        local file = io.open(CONFIG.reportsLog, "w")
                        file:write(newContent)
                        file:close()
                        showSection(sectionId)
                    end
                    y = y + 1
                    if y > contentContainer.height - 2 then break end
                end
            end
        elseif sectionId == "reviews" then
            buffer.text(2, y, fg, bg, "=== ОТЗЫВЫ ===")
            y = y + 1
            if #server.feedbacks == 0 then
                buffer.text(2, y, fg, bg, "Нет отзывов.")
            else
                for i, rev in ipairs(server.feedbacks) do
                    local line = rev.name .. ": " .. rev.text .. " (" .. rev.time .. ")"
                    buffer.text(2, y, fg, bg, line)
                    local btn = panel:addChild(GUI.button(60, y, 12, 1, 0xE74C3C, 0xFFFFFF, 0xC0392B, 0xFFFFFF, "Удалить"))
                    btn.onTouch = function()
                        table.remove(server.feedbacks, i)
                        server:saveFeedbacks()
                        showSection(sectionId)
                    end
                    y = y + 1
                    if y > contentContainer.height - 2 then break end
                end
            end
        elseif sectionId == "admins" then
            buffer.text(2, y, fg, bg, "=== АДМИНИСТРАТОРЫ ===")
            y = y + 1
            buffer.text(2, y, fg, bg, "Главный админ: " .. server.adminName)
            y = y + 1
            local btnAdd = panel:addChild(GUI.button(2, y, 18, 1, 0x3498DB, 0xFFFFFF, 0x2980B9, 0xFFFFFF, "Сменить пароль"))
            btnAdd.onTouch = function()
                local input = GUI.inputBox(app, "Смена пароля", "Введите новый пароль:", "", true)
                if input and input ~= "" then
                    server.password = input
                    showSection(sectionId)
                end
            end
        elseif sectionId == "addItem" then
            buffer.text(2, y, fg, bg, "=== ДОБАВИТЬ ПРЕДМЕТ ===")
            y = y + 1
            buffer.text(2, y, fg, bg, "Введите название предмета для каталога:")
            y = y + 1
            local btn = panel:addChild(GUI.button(2, y, 20, 1, 0x3498DB, 0xFFFFFF, 0x2980B9, 0xFFFFFF, "Отправить"))
            btn.onTouch = function()
                local input = GUI.inputBox(app, "Добавление предмета", "Название:", "", true)
                if input and input ~= "" then
                    server:log("Предмет добавлен в каталог: " .. input)
                    showSection(sectionId)
                end
            end
        elseif sectionId == "journal" then
            buffer.text(2, y, fg, bg, "=== ЖУРНАЛ СОБЫТИЙ ===")
            y = y + 1
            buffer.text(2, y, fg, bg, "Последние события сервера:")
            y = y + 1
            buffer.text(2, y, fg, bg, " (функция в разработке)")
        elseif sectionId == "storeStatus" then
            local status = server.shopPaused and "ЗАКРЫТ" or "ОТКРЫТ"
            buffer.text(2, y, fg, bg, "=== ПРИОСТАНОВИТЬ МАГАЗИН ===")
            y = y + 1
            buffer.text(2, y, fg, bg, "Текущий статус: " .. status)
            y = y + 1
            local btn = panel:addChild(GUI.button(2, y, 20, 1, 0xF1C40F, 0x000000, 0xF39C12, 0x000000, "Переключить"))
            btn.onTouch = function()
                server.shopPaused = not server.shopPaused
                updateStatus()
                showSection(sectionId)
            end
        end
    end
    app:draw()
    buffer.draw()
end

local bottomPanel = app:addChild(GUI.panel(1, app.height, app.width, 1, 0x000000))
local backButton = bottomPanel:addChild(GUI.button(1, 1, 12, 1, 0xFFFFFF, 0x000000, 0xAAAAAA, 0x000000, "< НАЗАД"))
backButton.onTouch = function()
    contentContainer:deleteChildren()
    app:draw()
    buffer.draw()
end
local hintLabel = bottomPanel:addChild(GUI.label(app.width - 30, 1, 30, 1, 0x888888, "Esc — назад | выберите раздел мышкой"))

local timeTimer = event.timer(1, function()
    updateStatus()
    app:draw()
    buffer.draw()
end, math.huge)

app.eventHandler = function(application, object, eventType, ...)
    if eventType == "modem_message" then
        local _, _, from, port, _, _, raw = ...
        if port == 0xffef or port == 0xfffe then
            server:handleMessage(from, port, raw)
        end
    end
end

-- =====================================================================
--  ЗАПУСК
-- =====================================================================

local function main()
    if gpu then
        gpu.setResolution(CONFIG.windowWidth, CONFIG.windowHeight)
    end
    updateStatus()
    app:draw()
    buffer.draw()
    app:start()
end

local ok, err = pcall(main)
if not ok then
    term.clear()
    term.setCursorPos(1,1)
    term.setForegroundColor(0xE74C3C)
    print("КРИТИЧЕСКАЯ ОШИБКА:")
    print(tostring(err))
    print(debug.traceback())
    term.setForegroundColor(0xFFFFFF)
    print("Нажмите любую клавишу для выхода...")
    computer.pullEvent("key_down")
end

event.cancel(timeTimer)
