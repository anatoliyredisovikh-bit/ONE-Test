-- =============================================================================
-- PIM MARKET SERVER - АДМИН-ПАНЕЛЬ (OpenComputers)
-- Версия 1.0
-- Только стандартные API, без внешних библиотек.
-- Интерфейс: терминальный стиль с цветными рамками, сетка меню 3x3.
-- =============================================================================

-- =============================================================================
-- БЛОК КОНФИГУРАЦИИ (изменяйте здесь размеры, цвета, отступы)
-- =============================================================================
local CONFIG = {
    -- Размеры экрана (можно изменить под свой монитор)
    screenWidth  = 80,
    screenHeight = 25,

    -- Цвета рамок (шестнадцатеричные, как в OpenComputers)
    colors = {
        players    = 0xAA44FF,  -- фиолетовый
        stats      = 0x44FF44,  -- зелёный
        reports    = 0xFF4444,  -- красный
        reviews    = 0x44FFFF,  -- бирюзовый
        admins     = 0xFF8800,  -- оранжевый
        additem    = 0x4488FF,  -- голубой
        journal    = 0xFFFF44,  -- жёлтый
        pause      = 0xD2B48C,  -- бежевый / светло-коричневый
        highlight  = 0xFFFFFF,  -- цвет подсветки при наведении
        text       = 0xFFFFFF,  -- цвет текста
        bg         = 0x000000,  -- чёрный фон
        headerBg   = 0x111111,
        footerBg   = 0x111111,
    },

    -- Позиции сетки меню (в символах)
    grid = {
        startX = 4,
        startY = 6,
        width  = 22,   -- ширина каждого блока
        height = 5,    -- высота каждого блока
        gapX   = 4,    -- отступ между блоками по X
        gapY   = 2,    -- отступ между блоками по Y
        cols   = 3,
        rows   = 3,
    },

    -- Заголовок и статус
    header = {
        title      = "PIM MARKET SERVER",
        statusText = "MARKET ONLINE",
    },

    -- Нижняя панель
    footer = {
        backLabel  = "< НАЗАД",
        hintText   = "Esc — назад | выберите раздел мышкой",
    }
}

-- =============================================================================
-- СЕРВЕРНАЯ ЧАСТЬ (backend) – хранение и управление данными
-- =============================================================================

-- ---- Инициализация данных (заглушки, чтобы интерфейс не был пустым) ----
local data = {
    -- Игроки: имя -> { balance, blocked, transactions, ... }
    players = {
        ["ZoziDo"] = { balance = 1500.0, blocked = false, transactions = 42, regDate = "01.01.2024" },
        ["Kalleront"] = { balance = 320.5, blocked = false, transactions = 12, regDate = "15.02.2024" },
        ["TestPlayer"] = { balance = 0.0, blocked = true, transactions = 3, regDate = "20.03.2024" },
    },
    -- Отзывы: массив { name, text, date }
    reviews = {
        { name = "ZoziDo", text = "Отличный магазин!", date = "10.01.2024" },
        { name = "Kalleront", text = "Быстро и удобно.", date = "20.02.2024" },
    },
    -- Жалобы (репорты): массив { name, text, date, resolved = false }
    reports = {
        { name = "TestPlayer", text = "Цена на алмазы завышена!", date = "01.03.2024", resolved = false },
    },
    -- Журнал событий: массив строк (только важные)
    journal = {
        "[01.01.2024] Сервер запущен",
        "[10.01.2024] ZoziDo пополнил баланс на 1000",
        "[20.02.2024] Kalleront купил алмаз",
    },
    -- Статистика
    stats = {
        totalBuys     = 125,
        totalSells    = 80,
        totalTurnover = 4520.75,
    },
    -- Администраторы (список имён)
    admins = { "ZoziDo", "Kalleront" },
    -- Каталог предметов (для добавления)
    catalog = {},
    -- Статус магазина (доступность терминалов)
    storePaused = false,
}

-- ---- Вспомогательные функции для работы с данными ----

-- Добавление тестовых данных (имитация активности рынка)
local function simulateMarketActivity()
    -- Генерируем случайные транзакции, отзывы, жалобы
    if math.random(1, 10) > 7 then
        local names = {"ZoziDo", "Kalleront", "TestPlayer", "Newbie"}
        local name = names[math.random(#names)]
        local amount = math.random(10, 200)
        if data.players[name] then
            if math.random() > 0.5 then
                data.players[name].balance = data.players[name].balance + amount
                table.insert(data.journal, string.format("[%s] %s пополнил баланс на %.2f", os.date("%d.%m.%Y"), name, amount))
                data.stats.totalSells = data.stats.totalSells + 1
            else
                if data.players[name].balance >= amount then
                    data.players[name].balance = data.players[name].balance - amount
                    table.insert(data.journal, string.format("[%s] %s совершил покупку на %.2f", os.date("%d.%m.%Y"), name, amount))
                    data.stats.totalBuys = data.stats.totalBuys + 1
                end
            end
        end
    end
    if math.random(1, 20) == 1 then
        table.insert(data.reviews, { name = "Guest", text = "Отличный сервис!", date = os.date("%d.%m.%Y") })
    end
    if math.random(1, 30) == 1 then
        table.insert(data.reports, { name = "Guest", text = "Баг в магазине!", date = os.date("%d.%m.%Y"), resolved = false })
    end
end

-- ---- Методы для управления данными (API для интерфейса) ----

-- Players
local function getPlayers()
    return data.players
end

local function setBalance(name, amount)
    if data.players[name] then
        data.players[name].balance = amount
        return true
    end
    return false
end

local function blockPlayer(name, blocked)
    if data.players[name] then
        data.players[name].blocked = blocked
        return true
    end
    return false
end

-- Reviews
local function getReviews()
    return data.reviews
end

local function deleteReview(index)
    if data.reviews[index] then
        table.remove(data.reviews, index)
        return true
    end
    return false
end

-- Journal
local function getJournal()
    return data.journal
end

local function logEvent(msg)
    table.insert(data.journal, string.format("[%s] %s", os.date("%d.%m.%Y %H:%M"), msg))
end

-- Statistics
local function getStats()
    return data.stats
end

local function recordSale(amount)
    data.stats.totalSells = data.stats.totalSells + 1
    data.stats.totalTurnover = data.stats.totalTurnover + amount
end

local function recordPurchase(amount)
    data.stats.totalBuys = data.stats.totalBuys + 1
    data.stats.totalTurnover = data.stats.totalTurnover + amount
end

-- Administrators
local function getAdmins()
    return data.admins
end

local function addAdmin(name)
    if not name or name == "" then return false end
    for _, a in ipairs(data.admins) do
        if a == name then return false end
    end
    table.insert(data.admins, name)
    return true
end

local function removeAdmin(name)
    for i, a in ipairs(data.admins) do
        if a == name then
            table.remove(data.admins, i)
            return true
        end
    end
    return false
end

-- Reports
local function getReports()
    return data.reports
end

local function resolveReport(index)
    if data.reports[index] then
        data.reports[index].resolved = true
        return true
    end
    return false
end

local function deleteReport(index)
    if data.reports[index] then
        table.remove(data.reports, index)
        return true
    end
    return false
end

-- Items (каталог)
local function addToCatalog(itemName, price)
    if itemName and price then
        table.insert(data.catalog, { name = itemName, price = price })
        return true
    end
    return false
end

-- Store status
local function getStoreStatus()
    return data.storePaused
end

local function toggleStoreStatus()
    data.storePaused = not data.storePaused
    return data.storePaused
end

-- =============================================================================
-- КЛИЕНТСКАЯ ЧАСТЬ (frontend) – отрисовка и взаимодействие
-- =============================================================================

-- ---- Подключение стандартных API ----
local component = require("component")
local term = require("term")
local event = require("event")
local os = require("os")
local math = require("math")
local table = require("table")
local string = require("string")

-- Проверка наличия GPU
local gpu = component.gpu
if not gpu then
    error("Видеокарта (GPU) не найдена!")
end

-- Устанавливаем разрешение экрана (если возможно)
local w, h = gpu.getResolution()
if w < CONFIG.screenWidth or h < CONFIG.screenHeight then
    gpu.setResolution(CONFIG.screenWidth, CONFIG.screenHeight)
    w, h = gpu.getResolution()
    -- Если не удалось установить нужное разрешение, используем текущее
    CONFIG.screenWidth = w
    CONFIG.screenHeight = h
end

-- ---- Вспомогательные функции отрисовки ----

-- Установка цвета (обёртка для gpu)
local function setColor(fg, bg)
    if fg then gpu.setForeground(fg) end
    if bg then gpu.setBackground(bg) end
end

-- Очистка экрана
local function clearScreen()
    gpu.setBackground(CONFIG.colors.bg)
    gpu.fill(1, 1, CONFIG.screenWidth, CONFIG.screenHeight, " ")
end

-- Рисование рамки вокруг прямоугольной области
local function drawFrame(x, y, width, height, color, fillColor)
    -- Верхняя и нижняя границы
    setColor(color, fillColor or CONFIG.colors.bg)
    gpu.fill(x, y, width, 1, "─")
    gpu.fill(x, y + height - 1, width, 1, "─")
    -- Вертикальные линии
    for row = y + 1, y + height - 2 do
        gpu.set(x, row, "│")
        gpu.set(x + width - 1, row, "│")
    end
    -- Углы
    gpu.set(x, y, "┌")
    gpu.set(x + width - 1, y, "┐")
    gpu.set(x, y + height - 1, "└")
    gpu.set(x + width - 1, y + height - 1, "┘")
    -- Если задан fillColor, заливаем внутреннюю область
    if fillColor then
        gpu.setBackground(fillColor)
        gpu.fill(x + 1, y + 1, width - 2, height - 2, " ")
    end
end

-- Рисование текста по центру в заданной области
local function drawCenteredTextInRect(x, y, width, height, text, fg, bg)
    local len = #text
    local tx = x + math.floor((width - len) / 2)
    local ty = y + math.floor((height - 1) / 2)
    setColor(fg, bg or CONFIG.colors.bg)
    gpu.set(tx, ty, text)
end

-- ---- Отрисовка интерфейса ----

-- Текущее состояние интерфейса
local state = {
    currentScreen = "main",  -- "main" или название раздела
    selectedIndex = nil,     -- индекс выбранного блока в сетке (1..9)
    hoverIndex = nil,        -- индекс блока под мышью
    detailData = nil,        -- данные для отображения в центральной области
    backCallback = nil,      -- функция для возврата в главное меню
}

-- Определение блоков сетки (8 блоков, 9-й можно оставить пустым или использовать для доп. инфо)
local gridBlocks = {
    { id = "players",   label = "ИГРОКИ",        sub = "Балансы, блокировки, транзакции",   color = CONFIG.colors.players },
    { id = "stats",     label = "СТАТИСТИКА",    sub = "Покупки, продажи, оборот",           color = CONFIG.colors.stats },
    { id = "reports",   label = "РЕПОРТЫ",       sub = "Чтение и удаление жалоб",            color = CONFIG.colors.reports },
    { id = "reviews",   label = "ОТЗЫВЫ",        sub = "Чтение и удаление отзывов",          color = CONFIG.colors.reviews },
    { id = "admins",    label = "АДМИНИСТРАТОРЫ", sub = "Добавить или удалить админа",       color = CONFIG.colors.admins },
    { id = "additem",   label = "ДОБАВИТЬ ПРЕДМЕТ", sub = "Отправить предмет в каталог",     color = CONFIG.colors.additem },
    { id = "journal",   label = "ЖУРНАЛ",        sub = "Только важные события",              color = CONFIG.colors.journal },
    { id = "pause",     label = "ПРИОСТАНОВИТЬ МАГАЗИН", sub = "Управление доступностью терминалов", color = CONFIG.colors.pause },
    -- 9-й блок можно сделать пустым или дополнительным
    { id = nil, label = "", sub = "", color = 0x555555 },
}

-- Вычисление координат блоков сетки
local function getBlockPosition(index)
    local cfg = CONFIG.grid
    local row = math.floor((index - 1) / cfg.cols)
    local col = (index - 1) % cfg.cols
    local x = cfg.startX + col * (cfg.width + cfg.gapX)
    local y = cfg.startY + row * (cfg.height + cfg.gapY)
    return x, y
end

-- Рисование верхней панели (заголовок, статус, время)
local function drawHeader()
    local title = CONFIG.header.title
    local status = CONFIG.header.statusText
    local timeStr = os.date("%H:%M:%S")

    -- Фон панели
    gpu.setBackground(CONFIG.colors.headerBg)
    gpu.fill(1, 1, CONFIG.screenWidth, 2, " ")

    -- Заголовок (слева)
    setColor(CONFIG.colors.text, CONFIG.colors.headerBg)
    gpu.set(2, 1, title)

    -- Статус и время (справа)
    local statusLine = status .. " | " .. timeStr
    local rightX = CONFIG.screenWidth - #statusLine - 1
    setColor(CONFIG.colors.text, CONFIG.colors.headerBg)
    gpu.set(rightX, 1, statusLine)
end

-- Рисование сетки меню (блоки)
local function drawMenuGrid(hoverIndex)
    for i = 1, #gridBlocks do
        local block = gridBlocks[i]
        if block.id then
            local x, y = getBlockPosition(i)
            local color = block.color
            -- Если блок под мышью, меняем цвет рамки на подсветку
            local frameColor = (hoverIndex == i) and CONFIG.colors.highlight or color
            local fillColor = CONFIG.colors.bg

            -- Рисуем рамку
            drawFrame(x, y, CONFIG.grid.width, CONFIG.grid.height, frameColor, fillColor)

            -- Рисуем текст (название и подзаголовок)
            local label = block.label
            local sub = block.sub
            setColor(CONFIG.colors.text, CONFIG.colors.bg)
            -- Название по центру выше
            local labelY = y + 1
            drawCenteredTextInRect(x, labelY, CONFIG.grid.width, 2, label, CONFIG.colors.text, CONFIG.colors.bg)
            -- Подзаголовок чуть ниже
            local subY = y + 3
            if #sub > CONFIG.grid.width - 2 then
                sub = sub:sub(1, CONFIG.grid.width - 5) .. "…"
            end
            drawCenteredTextInRect(x, subY, CONFIG.grid.width, 1, sub, 0x888888, CONFIG.colors.bg)
        else
            -- Пустой блок (просто фон)
            local x, y = getBlockPosition(i)
            gpu.setBackground(CONFIG.colors.bg)
            gpu.fill(x, y, CONFIG.grid.width, CONFIG.grid.height, " ")
        end
    end
end

-- Рисование центральной области (для деталей раздела)
local function drawCentralArea(contentLines, actions)
    -- Очищаем центральную область (под сеткой)
    local startY = CONFIG.grid.startY + CONFIG.grid.rows * (CONFIG.grid.height + CONFIG.grid.gapY) + 1
    local height = CONFIG.screenHeight - startY - 3 -- оставляем место для футера
    gpu.setBackground(CONFIG.colors.bg)
    gpu.fill(2, startY, CONFIG.screenWidth - 3, height, " ")

    if not contentLines or #contentLines == 0 then
        setColor(0x888888, CONFIG.colors.bg)
        gpu.set(4, startY + 2, "Нет данных")
        return
    end

    -- Выводим содержимое
    for i, line in ipairs(contentLines) do
        if i > height - 2 then break end
        setColor(CONFIG.colors.text, CONFIG.colors.bg)
        gpu.set(4, startY + i, line)
    end

    -- Если есть действия (кнопки), рисуем их внизу центральной области
    if actions then
        -- Просто пример: можно рисовать кнопки, но для простоты оставим как есть
    end
end

-- Рисование нижней панели (кнопка назад, подсказка)
local function drawFooter()
    local y = CONFIG.screenHeight
    gpu.setBackground(CONFIG.colors.footerBg)
    gpu.fill(1, y, CONFIG.screenWidth, 1, " ")

    -- Кнопка "< НАЗАД"
    setColor(CONFIG.colors.text, CONFIG.colors.footerBg)
    gpu.set(2, y, CONFIG.footer.backLabel)

    -- Подсказка справа
    local hint = CONFIG.footer.hintText
    local hintX = CONFIG.screenWidth - #hint - 1
    gpu.set(hintX, y, hint)
end

-- ---- Обработчики разделов ----

-- Функция для отображения раздела "ИГРОКИ"
local function showPlayers()
    local players = getPlayers()
    local lines = {}
    for name, info in pairs(players) do
        local status = info.blocked and "ЗАБЛОКИРОВАН" or "АКТИВЕН"
        local line = string.format("%-12s | Coin: %8.2f | Транз: %3d | %s", name, info.balance, info.transactions, status)
        table.insert(lines, line)
    end
    state.detailData = { lines = lines }
    state.currentScreen = "players"
end

local function showStats()
    local stats = getStats()
    local lines = {
        string.format("Покупок: %d", stats.totalBuys),
        string.format("Продаж: %d", stats.totalSells),
        string.format("Оборот: %.2f", stats.totalTurnover),
    }
    state.detailData = { lines = lines }
    state.currentScreen = "stats"
end

local function showReports()
    local reports = getReports()
    local lines = {}
    for i, r in ipairs(reports) do
        local status = r.resolved and "[РЕШЕНА]" or "[ОТКРЫТА]"
        table.insert(lines, string.format("%d. %s | %s | %s", i, r.name, r.text, status))
    end
    state.detailData = { lines = lines }
    state.currentScreen = "reports"
end

local function showReviews()
    local reviews = getReviews()
    local lines = {}
    for i, r in ipairs(reviews) do
        table.insert(lines, string.format("%d. %s | %s", i, r.name, r.text))
    end
    state.detailData = { lines = lines }
    state.currentScreen = "reviews"
end

local function showAdmins()
    local admins = getAdmins()
    local lines = {}
    for i, name in ipairs(admins) do
        table.insert(lines, string.format("%d. %s", i, name))
    end
    state.detailData = { lines = lines }
    state.currentScreen = "admins"
end

local function showAddItem()
    -- Простая форма для добавления предмета (заглушка)
    local lines = {
        "Введите название предмета и цену через пробел",
        "Пример: \"Алмаз 100\"",
        "Пока это демонстрация, данные не сохраняются."
    }
    state.detailData = { lines = lines }
    state.currentScreen = "additem"
end

local function showJournal()
    local journal = getJournal()
    local lines = {}
    for i, entry in ipairs(journal) do
        table.insert(lines, entry)
    end
    state.detailData = { lines = lines }
    state.currentScreen = "journal"
end

local function showPause()
    local paused = getStoreStatus()
    local status = paused and "ПРИОСТАНОВЛЕН" or "РАБОТАЕТ"
    local lines = {
        string.format("Текущий статус: %s", status),
        "Нажмите любую клавишу для переключения (или кликните мышью)",
    }
    state.detailData = { lines = lines }
    state.currentScreen = "pause"
end

-- Функция перехода в главное меню
local function goToMain()
    state.currentScreen = "main"
    state.detailData = nil
    state.selectedIndex = nil
    state.hoverIndex = nil
    renderMain()
end

-- ---- Отрисовка главного экрана ----
function renderMain()
    clearScreen()
    drawHeader()
    drawMenuGrid(state.hoverIndex)
    -- Центральная область (пустая или с заглушкой)
    local startY = CONFIG.grid.startY + CONFIG.grid.rows * (CONFIG.grid.height + CONFIG.grid.gapY) + 1
    gpu.setBackground(CONFIG.colors.bg)
    gpu.fill(2, startY, CONFIG.screenWidth - 3, CONFIG.screenHeight - startY - 3, " ")
    setColor(0x666666, CONFIG.colors.bg)
    gpu.set(4, startY + 2, "Выберите раздел из меню")
    drawFooter()
end

-- ---- Отрисовка экрана раздела ----
function renderSection()
    clearScreen()
    drawHeader()
    -- Сетка меню не рисуется, только центральная область с данными
    -- Но мы можем оставить заголовок раздела и данные
    local startY = CONFIG.grid.startY  -- используем ту же область
    gpu.setBackground(CONFIG.colors.bg)
    gpu.fill(2, startY, CONFIG.screenWidth - 3, CONFIG.screenHeight - startY - 3, " ")

    if state.detailData and state.detailData.lines then
        for i, line in ipairs(state.detailData.lines) do
            if i > 20 then break end
            setColor(CONFIG.colors.text, CONFIG.colors.bg)
            gpu.set(4, startY + i, line)
        end
    else
        setColor(0x888888, CONFIG.colors.bg)
        gpu.set(4, startY + 2, "Нет данных")
    end

    drawFooter()
end

-- ---- Основной цикл обработки событий ----
local function mainLoop()
    while true do
        -- Обработка событий с таймаутом, чтобы обновлять время
        local ev = { event.pull(0.5) }
        local etype = ev[1]

        -- Обновление времени в заголовке (каждые полсекунды)
        if state.currentScreen == "main" then
            renderMain()
        else
            renderSection()
        end

        if etype == "mouse_move" then
            local _, _, x, y = table.unpack(ev)
            if state.currentScreen == "main" then
                -- Проверяем, находится ли мышь над каким-либо блоком сетки
                local hover = nil
                for i = 1, #gridBlocks do
                    if gridBlocks[i].id then
                        local bx, by = getBlockPosition(i)
                        if x >= bx and x <= bx + CONFIG.grid.width - 1 and
                           y >= by and y <= by + CONFIG.grid.height - 1 then
                            hover = i
                            break
                        end
                    end
                end
                if hover ~= state.hoverIndex then
                    state.hoverIndex = hover
                    renderMain()
                end
            end

        elseif etype == "touch" then
            local _, _, x, y = table.unpack(ev)
            if state.currentScreen == "main" then
                -- Клик по сетке
                for i = 1, #gridBlocks do
                    if gridBlocks[i].id then
                        local bx, by = getBlockPosition(i)
                        if x >= bx and x <= bx + CONFIG.grid.width - 1 and
                           y >= by and y <= by + CONFIG.grid.height - 1 then
                            -- Выбран раздел
                            state.selectedIndex = i
                            local id = gridBlocks[i].id
                            if id == "players" then showPlayers()
                            elseif id == "stats" then showStats()
                            elseif id == "reports" then showReports()
                            elseif id == "reviews" then showReviews()
                            elseif id == "admins" then showAdmins()
                            elseif id == "additem" then showAddItem()
                            elseif id == "journal" then showJournal()
                            elseif id == "pause" then showPause()
                            end
                            renderSection()
                            break
                        end
                    end
                end
                -- Клик по кнопке "< НАЗАД" в футере (если мы в главном меню, то ничего не делаем)
                if y == CONFIG.screenHeight and x >= 2 and x <= 2 + #CONFIG.footer.backLabel then
                    -- Игнорируем, так как мы уже в главном меню
                end
            else
                -- В режиме раздела: клик на "< НАЗАД" возвращает в главное меню
                if y == CONFIG.screenHeight and x >= 2 and x <= 2 + #CONFIG.footer.backLabel then
                    goToMain()
                end
                -- Для раздела PAUSE: клик переключает статус
                if state.currentScreen == "pause" then
                    local newStatus = toggleStoreStatus()
                    logEvent("Статус магазина изменён: " .. (newStatus and "ПРИОСТАНОВЛЕН" or "РАБОТАЕТ"))
                    showPause()
                    renderSection()
                end
            end

        elseif etype == "key_down" then
            local _, _, char, code = table.unpack(ev)
            if code == 1 then -- Esc
                if state.currentScreen ~= "main" then
                    goToMain()
                else
                    -- В главном меню Esc ничего не делает (можно выйти, но не требуется)
                end
            end
            -- Дополнительно: для раздела PAUSE любая клавиша переключает
            if state.currentScreen == "pause" and code ~= 1 then
                local newStatus = toggleStoreStatus()
                logEvent("Статус магазина изменён: " .. (newStatus and "ПРИОСТАНОВЛЕН" or "РАБОТАЕТ"))
                showPause()
                renderSection()
            end
        end

        -- Имитация активности (генерация тестовых данных) каждые 30 секунд
        if math.random(1, 6) == 1 then
            simulateMarketActivity()
        end
    end
end

-- =============================================================================
-- ЗАПУСК
-- =============================================================================

-- Обработка ошибок при запуске
local ok, err = pcall(function()
    -- Проверка наличия необходимых компонентов
    if not gpu then
        error("Видеокарта не найдена")
    end
    -- Устанавливаем разрешение
    gpu.setResolution(CONFIG.screenWidth, CONFIG.screenHeight)

    -- Инициализация: генерируем немного тестовых данных при старте
    for _ = 1, 5 do
        simulateMarketActivity()
    end

    -- Переходим в главное меню
    state.currentScreen = "main"
    renderMain()

    -- Запускаем основной цикл
    mainLoop()
end)

if not ok then
    -- Если ошибка, выводим её и ждём нажатия
    term.clear()
    term.write("Ошибка: " .. tostring(err) .. "\nНажмите любую клавишу для выхода.")
    event.pull("key_down")
end
