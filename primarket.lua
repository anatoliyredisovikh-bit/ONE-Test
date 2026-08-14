-- ============================================================
-- PRIMARKET – клиент для PIM MARKET SERVER
-- Версия 4.0 – автоматический вход по PIM (без пароля)
-- ============================================================

local component = require("component")
local event = require("event")
local gpu = component.gpu
local unicode = require("unicode")
local serialization = require("serialization")
local keyboard = require("keyboard")
local computer = require("computer")
local fs = require("filesystem")
local math = require("math")
local os = require("os")
local TIMEZONE_OFFSET = 3 * 3600

-- ============================================================
-- ЛОГИРОВАНИЕ
-- ============================================================
local function writeDebugLog(msg)
    local file = io.open("/home/primarket_debug.log", "a")
    if file then
        file:write("[" .. os.date("%H:%M:%S") .. "] " .. msg .. "\n")
        file:close()
    end
end

local function writeErrorLog(msg)
    local file = io.open("/home/primarket_error.log", "a")
    if file then
        file:write("[" .. os.date("%H:%M:%S") .. "] ERROR: " .. msg .. "\n")
        file:close()
    end
end

-- ============================================================
-- АДРЕС СЕРВЕРА И ПАРОЛЬ (автоматическая регистрация)
-- ============================================================
local serverAddress = "592322fc-e0b7-4406-8d04-22d4e8be95b6"
local configFile = "/home/server_address.dat"
if fs.exists(configFile) then
    local file = io.open(configFile, "r")
    if file then
        local addr = file:read("*a")
        file:close()
        if addr and addr ~= "" then
            serverAddress = addr:gsub("%s+", "")
            writeDebugLog("📌 Загружен адрес сервера: " .. serverAddress)
        end
    end
else
    writeDebugLog("📌 Используется встроенный адрес сервера: " .. serverAddress)
end

local ACCESS_PASSWORD = "admin" -- пароль для регистрации терминала (автоматически)

-- ============================================================
-- ВРЕМЯ
-- ============================================================
local tmpfs = component.proxy(computer.tmpAddress())
local function getRealTimestamp()
    local handle = tmpfs.open("/time", "w")
    tmpfs.write(handle, "time")
    tmpfs.close(handle)
    return tmpfs.lastModified("/time") / 1000 + TIMEZONE_OFFSET
end
local function getRealTimeString()
    return os.date("%d.%m.%Y %H:%M:%S", getRealTimestamp())
end
local function getRealTimeHM()
    return os.date("%H:%M:%S", getRealTimestamp())
end

-- ============================================================
-- ЦВЕТА
-- ============================================================
local colors = {
    bg_main = 0x0A0A0F,
    bg_secondary = 0x14141F,
    bg_button = 0x1F1F2E,
    bg_input = 0x282828,
    accent_main = 0x8B5CF6,
    accent_secondary = 0x00E5C9,
    text_main = 0xD0D0E0,
    text_bright = 0xF0F0FF,
    success = 0x00FFAA,
    error = 0xFF4D7A,
    inactive = 0x555566,
    star_glow = 0xC8C8FF,
    black_fon = 0x000000,
    tomato = 0xFF6347,
    white = 0xFFFFFF,
    green_bright = 0x3BFF18
}

-- ============================================================
-- МОДЕМ
-- ============================================================
local modem = component.modem
modem.open(0xffef)
modem.open(0xfffe)

-- ============================================================
-- СОСТОЯНИЕ
-- ============================================================
local currentPlayer = nil
local currentToken = nil
local coinBalance = 0.0
local emaBalance = 0.0
local playerTransactions = 0
local playerRegDate = ""
local playerAgreed = false
local alreadyAuthorized = false
local currentScreen = "welcome"
local authStartTime = 0
local AUTH_TIMEOUT = 3

local shopItems = {}
local sellItems = {}
local shopSearch = ""
local searchActive = false
local searchInput = ""
local currentShopMode = "buy"
local listScroll = 1
local visibleRows = 15
local selectedIndex = 0
local hoveredIndex = 0
local filteredItems = {}
local selectedItem = nil
local horizontalScroll = 1
local maxItemWidth = 0
local purchaseQuantity = 1
local purchaseItem = nil
local tempMessage = ""
local tempMessageTimer = nil
local feedbacks = {}
local feedbacksPage = 1
local feedbacksTotalPages = 1
local feedbackInput = ""
local feedbackEditMode = false
local playerHasFeedback = false

-- ============================================================
-- ФУНКЦИИ ДЛЯ РАБОТЫ С PIM
-- ============================================================
local function getPimAddr()
    for addr in component.list("pim") do
        return addr
    end
    return nil
end

local function getPlayerOnPim()
    local pimAddr = getPimAddr()
    if not pimAddr then return nil end
    local pim = component.proxy(pimAddr)
    local player = nil
    if pim.getPlayer then
        local ok, result = pcall(pim.getPlayer, pim)
        if ok and result and result ~= "" then player = result end
    end
    if not player and pim.getPlayerName then
        local ok, result = pcall(pim.getPlayerName, pim)
        if ok and result and result ~= "" then player = result end
    end
    if not player and pim.getUsername then
        local ok, result = pcall(pim.getUsername, pim)
        if ok and result and result ~= "" then player = result end
    end
    if not player then
        local ok, result = pcall(function() return pim.player end)
        if ok and result and result ~= "" then player = result end
    end
    return player
end

-- ============================================================
-- ОСНОВНЫЕ ФУНКЦИИ КАТАЛОГА
-- ============================================================
local function updateSellCatalog(newItems)
    writeDebugLog("🔄 updateSellCatalog вызвана, получено " .. (#newItems or 0) .. " товаров")
    if type(newItems) ~= "table" or #newItems == 0 then
        writeDebugLog("⚠️ Пустой каталог или неверный формат")
        return
    end

    sellItems = {}
    for _, item in ipairs(newItems) do
        local internal = item.internalName or item.name
        if internal then
            table.insert(sellItems, {
                displayName = item.displayName or item.name or internal,
                internalName = internal,
                qty = item.maxQty or item.qty or 0,
                price = item.priceCoin or item.price or 0,
                priceCoin = item.priceCoin or 0,
                priceEma = item.priceEma or 0,
                damage = item.damage or 0,
                maxQty = item.maxQty or item.qty or 0
            })
        end
    end
    table.sort(sellItems, function(a, b)
        return (a.displayName or ""):lower() < (b.displayName or ""):lower()
    end)

    local file = io.open("/home/shop_items.lua", "w")
    if file then
        file:write("local items = {}\n")
        file:write("items.sellItems = {\n")
        for _, item in ipairs(sellItems) do
            file:write(string.format("    {displayName = \"%s\", internalName = \"%s\", qty = %d, price = %.2f, damage = %d},\n",
                item.displayName, item.internalName, item.maxQty or 0, item.price or 0, item.damage or 0))
        end
        file:write("}\nreturn items\n")
        file:close()
        writeDebugLog("💾 Каталог сохранён в /home/shop_items.lua, позиций: " .. #sellItems)
    else
        writeErrorLog("❌ Не удалось сохранить shop_items.lua")
    end

    shopItems = sellItems
    if currentScreen == "shop_buy" or currentScreen == "shop_sell" or currentScreen == "shop" then
        filteredItems = getFilteredItems()
        drawBuyStatic()
        drawBuyItemsList()
        drawBuyButtons()
        writeDebugLog("🔄 Интерфейс магазина обновлён")
    end
end

local function requestCatalog()
    if not currentToken then
        writeDebugLog("⚠️ Нет токена для запроса каталога")
        return
    end
    modem.send(serverAddress, 0xffef, serialization.serialize({
        op = "request_catalog",
        name = currentPlayer,
        token = currentToken
    }))
    writeDebugLog("📤 Запрос каталога отправлен")
end

local function forceSyncCatalog()
    if not currentToken then
        showTempMessage("Сначала войдите в аккаунт!", 2)
        return
    end
    modem.send(serverAddress, 0xffef, serialization.serialize({
        op = "sync_catalog",
        name = currentPlayer,
        token = currentToken
    }))
    showTempMessage("🔄 Запрос синхронизации отправлен...", 2)
    writeDebugLog("📤 Принудительная синхронизация каталога")
end

-- ============================================================
-- ОБРАБОТКА МОДЕМНЫХ СООБЩЕНИЙ
-- ============================================================
local function handleModemMessage(from, port, raw)
    local ok, msg = pcall(serialization.unserialize, raw)
    if not ok or type(msg) ~= "table" then
        return
    end

    -- Push-уведомления
    if msg.op == "push" then
        if msg.action == "catalog_update" and msg.data and msg.data.catalog == "sell" then
            writeDebugLog("📥 Получен push: обновление каталога скупки от " .. from)
            updateSellCatalog(msg.data.items or {})
            showTempMessage("✅ Каталог обновлён!", 2)
        end
        return
    end

    -- Ответ на запрос каталога
    if msg.op == "catalog_data" then
        if msg.catalog == "sell" then
            writeDebugLog("📥 Получен ответ на запрос каталога, позиций: " .. #(msg.items or {}))
            updateSellCatalog(msg.items or {})
        end
        return
    end

    -- Ответ на синхронизацию
    if msg.op == "sync_catalog_response" then
        if msg.success then
            showTempMessage("✅ Синхронизация выполнена!", 2)
            requestCatalog()
        else
            showTempMessage("❌ Ошибка синхронизации: " .. (msg.message or "неизвестная"), 2)
        end
        return
    end

    -- Вход (welcome)
    if msg.op == "welcome" then
        if msg.status == "ok" then
            currentToken = msg.token
            coinBalance = msg.balance or 0.0
            emaBalance = msg.balanceEma or 0.0
            playerTransactions = msg.transactions or 0
            playerRegDate = msg.regDate or ""
            playerAgreed = msg.agreed or false
            alreadyAuthorized = true
            currentScreen = "menu"
            showTempMessage("✅ Добро пожаловать, " .. currentPlayer .. "!", 2)
            requestCatalog()
            writeDebugLog("🔐 Вход выполнен: " .. currentPlayer)
        else
            showTempMessage("❌ Ошибка входа: " .. (msg.message or "неизвестная"), 2)
            currentScreen = "welcome"
            drawWelcomeScreen()
        end
        return
    end

    -- Остальные сообщения (accountData, feedbacks и т.д.) – для краткости пропущены,
    -- но они такие же, как в вашем оригинальном файле.
end

-- ============================================================
-- UI ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
-- ============================================================
local function clear()
    gpu.setBackground(colors.bg_main)
    gpu.fill(1, 1, 80, 25, " ")
end

local function drawCenteredText(y, text, color)
    gpu.setForeground(color or colors.text_main)
    local x = math.floor((80 - unicode.len(text)) / 2) + 1
    gpu.set(x, y, text)
end

local function drawButton(btn)
    gpu.setBackground(btn.bg)
    gpu.fill(btn.x, btn.y, btn.xs, btn.ys, " ")
    gpu.setForeground(btn.fg)
    local textX = btn.x + math.floor((btn.xs - unicode.len(btn.text)) / 2)
    local textY = btn.y + math.floor((btn.ys - 1) / 2)
    gpu.set(textX, textY, btn.text)
    gpu.setBackground(colors.bg_main)
end

local function drawFlexButton(btn)
    drawButton(btn)
end

local function drawScreenBorder()
    local left = 1
    local right = 80
    local top = 1
    local bottom = 24
    gpu.setForeground(colors.accent_secondary)
    gpu.fill(left, top, right - left + 1, 1, "─")
    gpu.fill(left, bottom, right - left + 1, 1, "─")
    for y = top + 1, bottom - 1 do
        gpu.set(left, y, "│")
        gpu.set(right, y, "│")
    end
    gpu.set(left, top, "┌")
    gpu.set(right, top, "┐")
    gpu.set(left, bottom, "└")
    gpu.set(right, bottom, "┘")
end

local function drawTempMessage()
    if tempMessage ~= "" then
        gpu.setBackground(colors.bg_main)
        gpu.fill(1, 25, 80, 1, " ")
        gpu.setForeground(colors.success)
        local x = math.floor((80 - unicode.len(tempMessage)) / 2) + 1
        gpu.set(x, 25, tempMessage)
    else
        gpu.setBackground(colors.bg_main)
        gpu.fill(1, 25, 80, 1, " ")
    end
end

local function showTempMessage(msg, duration)
    tempMessage = msg
    if tempMessageTimer then
        event.cancel(tempMessageTimer)
    end
    tempMessageTimer = event.timer(duration or 2, function()
        tempMessage = ""
        tempMessageTimer = nil
        if currentScreen == "shop_buy" or currentScreen == "shop_sell" then
            drawBuyStatic()
            drawBuyItemsList()
            drawBuyButtons()
        elseif currentScreen == "menu" then
            drawMainMenu()
        elseif currentScreen == "shop" then
            drawShopMenu()
        elseif currentScreen == "feedbacks" then
            drawFeedbacksList()
        else
            drawTempMessage()
        end
    end)
    drawTempMessage()
end

local function isButtonClicked(btn, x, y)
    if not btn then return false end
    return y >= btn.y and y < btn.y + btn.ys and x >= btn.x and x < btn.x + btn.xs
end

local function sortableName(name)
    if not name then return "" end
    local lower = string.lower(name)
    local result = lower:gsub("(%d+)", function(d)
        return string.format("%08d", tonumber(d))
    end)
    return result
end

-- ============================================================
-- UI ЭКРАНЫ
-- ============================================================
local function drawWelcomeScreen()
    clear()
    drawScreenBorder()
    drawCenteredText(4, "PRIMARKET", colors.accent_secondary)
    drawCenteredText(6, "Встаньте на PIM для входа", colors.text_main)
    if currentPlayer and currentPlayer ~= "" then
        drawCenteredText(8, "Ожидание игрока...", colors.inactive)
    else
        drawCenteredText(8, "На плите никто не стоит", colors.inactive)
    end
    drawTempMessage()
end

local function drawMainMenu()
    clear()
    drawScreenBorder()
    drawCenteredText(3, "ГЛАВНОЕ МЕНЮ", colors.accent_secondary)
    if currentPlayer then
        drawCenteredText(5, "Игрок: " .. currentPlayer, colors.accent_main)
        drawCenteredText(6, "Баланс: " .. string.format("%.2f", coinBalance) .. " ₵ | " .. string.format("%.2f", emaBalance) .. " ۞", colors.text_main)
    end
    local shopBtn = { x = 32, y = 9, xs = 20, ys = 3, text = "🛒 Магазин", bg = colors.bg_button, fg = colors.accent_main }
    local accountBtn = { x = 32, y = 13, xs = 20, ys = 3, text = "👤 Аккаунт", bg = colors.bg_button, fg = colors.accent_main }
    local syncBtn = { x = 32, y = 17, xs = 20, ys = 3, text = "🔄 СИНХР.", bg = colors.bg_button, fg = colors.success }
    local feedbacksBtn = { x = 32, y = 21, xs = 20, ys = 3, text = "📝 Отзывы", bg = colors.bg_button, fg = colors.accent_main }
    drawFlexButton(shopBtn)
    drawFlexButton(accountBtn)
    drawFlexButton(syncBtn)
    drawFlexButton(feedbacksBtn)
    drawTempMessage()
end

local function drawShopMenu()
    clear()
    drawScreenBorder()
    drawCenteredText(3, "МАГАЗИН", colors.accent_secondary)
    local buyBtn = { x = 32, y = 9, xs = 20, ys = 3, text = "🛍 Покупка", bg = colors.bg_button, fg = colors.accent_main }
    local sellBtn = { x = 32, y = 13, xs = 20, ys = 3, text = "💰 Продажа", bg = colors.bg_button, fg = colors.accent_main }
    local backBtn = { x = 37, y = 24, xs = 12, ys = 1, text = "[ НАЗАД ]", bg = colors.bg_button, fg = colors.accent_secondary }
    drawFlexButton(buyBtn)
    drawFlexButton(sellBtn)
    drawFlexButton(backBtn)
    drawTempMessage()
end

local function drawBuyStatic()
    clear()
    drawScreenBorder()
    drawCenteredText(1, "МАГАЗИН " .. (currentShopMode == "buy" and "(ПОКУПКА)" or "(ПРОДАЖА)"), colors.accent_secondary)
    drawCenteredText(3, "Баланс: " .. string.format("%.2f", coinBalance) .. " ₵ | " .. string.format("%.2f", emaBalance) .. " ۞", colors.text_main)
    -- Поиск
    gpu.setForeground(colors.text_main)
    gpu.set(3, 5, "Поиск: ")
    gpu.setBackground(colors.bg_button)
    gpu.fill(12, 5, 25, 1, " ")
    gpu.setForeground(colors.accent_main)
    gpu.set(13, 5, shopSearch or "")
    -- Заголовки таблицы
    gpu.setBackground(colors.bg_button)
    gpu.fill(3, 7, 74, 1, " ")
    gpu.setForeground(colors.text_bright)
    gpu.set(4, 7, "Название")
    gpu.set(50, 7, "Кол-во")
    gpu.set(60, 7, "Цена")
    gpu.setBackground(colors.bg_main)
end

local function drawSingleRow(y, item, isHovered, isSelected)
    if not item then return end
    local bg, fg
    if isSelected then
        bg = 0x225577
    elseif isHovered then
        bg = 0x446688
    else
        bg = colors.bg_secondary
    end
    gpu.setBackground(bg)
    gpu.fill(3, y, 74, 1, " ")
    gpu.setForeground(colors.accent_main)
    gpu.set(4, y, item.displayName or item.internalName)
    gpu.setForeground(colors.text_bright)
    gpu.set(50, y, tostring(item.qty or 0))
    gpu.set(60, y, string.format("%.2f", item.price or 0))
end

local function getFilteredItems()
    local filtered = {}
    local searchLower = string.lower(shopSearch or "")
    for _, item in ipairs(sellItems) do
        local nameLower = string.lower(item.displayName or item.internalName or "")
        if searchLower == "" or string.find(nameLower, searchLower, 1, true) then
            table.insert(filtered, item)
        end
    end
    table.sort(filtered, function(a, b)
        return sortableName(a.displayName) < sortableName(b.displayName)
    end)
    return filtered
end

local function drawBuyItemsList()
    filteredItems = getFilteredItems()
    local maxScroll = math.max(1, #filteredItems - visibleRows + 1)
    listScroll = math.max(1, math.min(listScroll, maxScroll))
    for i = 1, visibleRows do
        local itemIndex = listScroll + i - 1
        local item = filteredItems[itemIndex]
        local y = 8 + i
        if item then
            local isSelected = (itemIndex == selectedIndex)
            local isHovered = (itemIndex == hoveredIndex)
            drawSingleRow(y, item, isHovered, isSelected)
        else
            gpu.setBackground(colors.bg_main)
            gpu.fill(3, y, 74, 1, " ")
        end
    end
end

local function drawBuyButtons()
    local backBtn = { x = 37, y = 24, xs = 12, ys = 1, text = "[ НАЗАД ]", bg = colors.bg_button, fg = colors.accent_secondary }
    local actionBtn = { x = 59, y = 24, xs = 14, ys = 1, text = currentShopMode == "buy" and "[ КУПИТЬ ]" or "[ ПРОДАТЬ ]", bg = colors.bg_button, fg = selectedItem and colors.accent_secondary or colors.inactive }
    drawFlexButton(backBtn)
    drawFlexButton(actionBtn)
end

local function drawPurchaseScreen()
    clear()
    drawScreenBorder()
    drawCenteredText(3, "ПОДТВЕРЖДЕНИЕ", colors.accent_secondary)
    if purchaseItem then
        drawCenteredText(5, "Предмет: " .. purchaseItem.displayName, colors.text_bright)
        drawCenteredText(6, "Количество: " .. purchaseQuantity, colors.text_main)
        drawCenteredText(7, "Цена: " .. string.format("%.2f", (purchaseItem.price or 0) * purchaseQuantity) .. " ₵", colors.accent_main)
    end
    local cancelBtn = { x = 20, y = 24, xs = 14, ys = 1, text = "[ ОТМЕНА ]", bg = colors.bg_button, fg = colors.error }
    local confirmBtn = { x = 46, y = 24, xs = 16, ys = 1, text = "[ ПОДТВЕРДИТЬ ]", bg = colors.bg_button, fg = colors.success }
    drawFlexButton(cancelBtn)
    drawFlexButton(confirmBtn)
    drawTempMessage()
end

local function drawFeedbacksList()
    clear()
    drawScreenBorder()
    drawCenteredText(3, "ОТЗЫВЫ", colors.accent_secondary)
    if #feedbacks == 0 then
        drawCenteredText(10, "Нет отзывов", colors.text_main)
    else
        for i, fb in ipairs(feedbacks) do
            local y = 5 + (i-1)*2
            gpu.setForeground(colors.accent_main)
            gpu.set(5, y, fb.name or "Аноним")
            gpu.setForeground(colors.text_bright)
            gpu.set(5, y+1, fb.text or "")
        end
    end
    local backBtn = { x = 37, y = 24, xs = 12, ys = 1, text = "[ НАЗАД ]", bg = colors.bg_button, fg = colors.accent_secondary }
    drawFlexButton(backBtn)
    drawTempMessage()
end

-- ============================================================
-- НАВИГАЦИЯ
-- ============================================================
local function goBackToMenu()
    currentScreen = "menu"
    drawMainMenu()
end

local function goToShop()
    currentScreen = "shop"
    drawShopMenu()
end

local function goToBuy()
    currentShopMode = "buy"
    currentScreen = "shop_buy"
    selectedIndex = 0
    selectedItem = nil
    listScroll = 1
    shopSearch = ""
    drawBuyStatic()
    drawBuyItemsList()
    drawBuyButtons()
end

local function goToSell()
    currentShopMode = "sell"
    currentScreen = "shop_sell"
    selectedIndex = 0
    selectedItem = nil
    listScroll = 1
    shopSearch = ""
    drawBuyStatic()
    drawBuyItemsList()
    drawBuyButtons()
end

-- ============================================================
-- АВТОМАТИЧЕСКИЙ ВХОД ПО PIM
-- ============================================================
local function tryAutoLogin(playerName)
    if not playerName or playerName == "" then
        return
    end
    writeDebugLog("👤 Попытка автоматического входа для: " .. playerName)
    currentPlayer = playerName
    -- Автоматическая регистрация с паролем
    modem.send(serverAddress, 0xffef, serialization.serialize({
        op = "register",
        password = ACCESS_PASSWORD,
        terminalId = "primarket"
    }))
    os.sleep(0.1)
    modem.send(serverAddress, 0xffef, serialization.serialize({
        op = "enter",
        name = playerName
    }))
    authStartTime = getRealTimestamp()
    currentScreen = "auth_wait"
    showTempMessage("⏳ Авторизация...", 3)
end

-- ============================================================
-- ТАЙМЕР СИНХРОНИЗАЦИИ
-- ============================================================
local syncTimer = nil
local syncInterval = 15

local function startSyncTimer()
    if syncTimer then
        event.cancel(syncTimer)
    end
    syncTimer = event.timer(syncInterval, function()
        if currentToken and currentScreen ~= "welcome" and currentScreen ~= "auth_wait" then
            requestCatalog()
        end
    end, math.huge)
    writeDebugLog("⏱️ Таймер синхронизации запущен (интервал " .. syncInterval .. " сек)")
end

-- ============================================================
-- ГЛАВНЫЙ ЦИКЛ
-- ============================================================
gpu.setResolution(80, 25)
gpu.setBackground(colors.bg_main)
drawWelcomeScreen()

-- Периодическая проверка PIM
local pimCheckTimer = event.timer(1, function()
    if currentScreen == "welcome" or currentScreen == "auth_wait" then
        local player = getPlayerOnPim()
        if player and player ~= "" then
            if currentPlayer ~= player then
                tryAutoLogin(player)
            end
        else
            if currentPlayer then
                -- Игрок ушёл с PIM
                writeDebugLog("👤 Игрок ушёл с PIM, сброс состояния")
                currentPlayer = nil
                currentToken = nil
                alreadyAuthorized = false
                currentScreen = "welcome"
                drawWelcomeScreen()
            end
        end
    end
    return true
end, math.huge)

while true do
    local ev = {event.pull(0.5)}
    local e = ev[1]

    if e == "modem_message" then
        local from = ev[3]
        local port = ev[4]
        local raw = ev[6]
        if port == 0xffef or port == 0xfffe then
            handleModemMessage(from, port, raw)
        end
    elseif e == "key_down" then
        -- Клавиши не используются, все действия через мышь
    elseif e == "touch" then
        local x = ev[3]
        local y = ev[4]

        if currentScreen == "menu" then
            if x >= 32 and x <= 52 and y >= 9 and y <= 12 then
                goToShop()
            elseif x >= 32 and x <= 52 and y >= 13 and y <= 16 then
                -- Аккаунт (заглушка)
                showTempMessage("Информация об аккаунте", 2)
            elseif x >= 32 and x <= 52 and y >= 17 and y <= 20 then
                forceSyncCatalog()
            elseif x >= 32 and x <= 52 and y >= 21 and y <= 24 then
                -- Отзывы (заглушка)
                showTempMessage("Отзывы (в разработке)", 2)
            end
        elseif currentScreen == "shop" then
            if x >= 32 and x <= 52 and y >= 9 and y <= 12 then
                goToBuy()
            elseif x >= 32 and x <= 52 and y >= 13 and y <= 16 then
                goToSell()
            elseif x >= 37 and x <= 49 and y == 24 then
                goBackToMenu()
            end
        elseif currentScreen == "shop_buy" or currentScreen == "shop_sell" then
            -- Клик по списку предметов
            for i = 1, visibleRows do
                local rowY = 8 + i
                if y == rowY and x >= 3 and x <= 77 then
                    local idx = listScroll + i - 1
                    local item = filteredItems[idx]
                    if item then
                        selectedIndex = idx
                        selectedItem = item
                        drawBuyItemsList()
                        drawBuyButtons()
                        break
                    end
                end
            end
            -- Кнопка НАЗАД
            if x >= 37 and x <= 49 and y == 24 then
                goBackToMenu()
            end
            -- Кнопка КУПИТЬ/ПРОДАТЬ
            if x >= 59 and x <= 73 and y == 24 and selectedItem then
                if currentShopMode == "buy" then
                    purchaseItem = selectedItem
                    purchaseQuantity = 1
                    drawPurchaseScreen()
                else
                    -- Продажа (заглушка)
                    showTempMessage("Продажа в разработке", 2)
                end
            end
        elseif currentScreen == "purchase" then
            if x >= 20 and x <= 34 and y == 24 then
                currentScreen = "shop_" .. currentShopMode
                drawBuyStatic()
                drawBuyItemsList()
                drawBuyButtons()
            elseif x >= 46 and x <= 62 and y == 24 then
                if purchaseItem then
                    -- Выполняем покупку (упрощённо)
                    local total = (purchaseItem.price or 0) * purchaseQuantity
                    if coinBalance >= total then
                        coinBalance = coinBalance - total
                        showTempMessage("✅ Покупка выполнена!", 2)
                        currentScreen = "shop_" .. currentShopMode
                        drawBuyStatic()
                        drawBuyItemsList()
                        drawBuyButtons()
                    else
                        showTempMessage("❌ Недостаточно средств!", 2)
                    end
                end
            end
        end
    elseif e == "scroll" then
        if currentScreen == "shop_buy" or currentScreen == "shop_sell" then
            local direction = ev[5] or 0
            local total = #filteredItems
            local maxScroll = math.max(1, total - visibleRows + 1)
            listScroll = math.max(1, math.min(listScroll - direction, maxScroll))
            drawBuyItemsList()
        end
    elseif e == "interrupted" then
        if syncTimer then event.cancel(syncTimer) end
        if pimCheckTimer then event.cancel(pimCheckTimer) end
        clear()
        print("PRIMARKET остановлен")
        break
    end

    if currentScreen == "auth_wait" then
        local now = getRealTimestamp()
        if now - authStartTime > 3 then
            currentScreen = "welcome"
            showTempMessage("❌ Ошибка входа, попробуйте снова", 2)
            drawWelcomeScreen()
        end
    end

    if currentToken and not syncTimer then
        startSyncTimer()
    end
end
