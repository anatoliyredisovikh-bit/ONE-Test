-- ============================================================
-- PRIMARKET – клиент для PIM MARKET SERVER
-- Версия 2.3 – исправлена ошибка с gpu.sync
-- ============================================================

local component = require("component")
local event = require("event")
local gpu = component.gpu
local unicode = require("unicode")
local serialization = require("serialization")
local keyboard = require("keyboard")
local computer = require("computer")
local fs = require("filesystem")

local TIMEZONE_OFFSET = 3 * 3600

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
    return os.date("%d.%m.%Y %H:%M:%S", getRealTimestamp())
end

local function getRealTimeHM()
    return os.date("%H:%M:%S", getRealTimestamp())
end

local DEBUG_LOG_PATH = "/home/primarket_debug.log"
local function writeDebugLog(message)
    pcall(function()
        local file = io.open(DEBUG_LOG_PATH, "a")
        if not file then return end
        file:write("[" .. getRealTimeString() .. "] " .. tostring(message) .. "\n")
        file:close()
    end)
end

local function safeEventPull(timeout)
    local result = {pcall(event.pull, timeout)}
    if not result[1] then
        writeDebugLog("⚠️ Попытка прервать скрипт: " .. tostring(result[2]))
        return {}
    end
    table.remove(result, 1)
    return result
end

-- ================================================================
-- КОНФИГУРАЦИЯ
-- ================================================================
local serverAddress = "592322fc-e0b7-4406-8d04-22d4e8be95b6"  -- Адрес сервера
local ACCESS_PASSWORD = "admin"

local colors = {
    bg_main = 0x0A0A0F,
    bg_secondary = 0x14141F,
    bg_button = 0x1F1F2E,
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
    white = 0xFFFFFF
}

-- ================================================================
-- ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
-- ================================================================
local function clear()
    gpu.setBackground(colors.bg_main)
    gpu.fill(1, 1, 80, 25, " ")
end

local function drawCenteredText(y, text, color)
    gpu.setForeground(color or colors.text_main)
    local x = math.floor((80 - unicode.len(text)) / 2) + 1 + 1
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
    gpu.setBackground(btn.bg)
    gpu.fill(btn.x, btn.y, btn.xs, btn.ys, " ")
    gpu.setForeground(btn.fg)
    local textX = btn.x + math.floor((btn.xs - unicode.len(btn.text)) / 2)
    local textY = btn.y + math.floor((btn.ys - 1) / 2)
    gpu.set(textX, textY, btn.text)
    gpu.setBackground(colors.bg_main)
end

local function safeDoFile(path)
    if not fs.exists(path) then
        print("Файл не найден, создаём: " .. path)
        return {}
    end
    local ok, result = pcall(dofile, path)
    if not ok then
        print("Ошибка загрузки файла " .. path .. ": " .. tostring(result))
        return {}
    end
    return result
end

local function sortableName(name)
    if not name then return "" end
    local lower = string.lower(name)
    local result = lower:gsub("(%d+)", function(d)
        return string.format("%08d", tonumber(d))
    end)
    return result
end

-- ================================================================
-- ОТЗЫВЫ
-- ================================================================
local feedbacks = {}
local feedbacksPage = 1
local feedbacksTotalPages = 1
local feedbackInput = ""
local feedbackEditMode = false
local playerHasFeedback = false

local function drawPopupBorder(x, y, w, h, color)
    gpu.setForeground(color or colors.accent_secondary)
    gpu.fill(x, y, w, 1, "─")
    gpu.fill(x, y + h - 1, w, 1, "─")
    for i = 1, h - 2 do
        gpu.set(x, y + i, "│")
        gpu.set(x + w - 1, y + i, "│")
    end
    gpu.set(x, y, "┌")
    gpu.set(x + w - 1, y, "┐")
    gpu.set(x, y + h - 1, "└")
    gpu.set(x + w - 1, y + h - 1, "┘")
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

-- ================================================================
-- ЗАГРУЗКА КАТАЛОГА
-- ================================================================
local shopData = safeDoFile("/home/shop_items.lua")
local sellItems = shopData.sellItems or {}
local vanillaItems = shopData.vanillaItems or {}
local buyItemsData = safeDoFile("/home/buy_items.lua")
local buyItemMap = {}
for _, item in ipairs(buyItemsData) do
    local dmg = item.damage or 0
    local key = item.internalName .. ":" .. dmg
    buyItemMap[key] = item
end

local drawAgreementScreen = safeDoFile("/home/agreement.lua")

-- ================================================================
-- МОДЕМ
-- ================================================================
local modem = component.modem

local function getPimAddr()
    for addr in component.list("pim") do
        return addr
    end
    return nil
end

local PUSH_DIRECTION = "down"
local PULL_DIRECTION = "up"

local function normalizeName(name)
    if not name then return "" end
    local lastColon = name:match(".*:([^:]+)$")
    return lastColon or name
end

local function namesMatch(name1, name2)
    if not name1 or not name2 then return false end
    if name1 == name2 then return true end
    local short1 = normalizeName(name1)
    local short2 = normalizeName(name2)
    return short1 == short2
end

local selector = nil
for addr in component.list("openperipheral_selector") do
    selector = component.proxy(addr)
    break
end
if not selector then
    for addr in component.list("item_selector") do
        selector = component.proxy(addr)
        break
    end
end

local function safeSelectorSetSlot(slot, stack)
    if not selector then return false end
    local ok, result = pcall(function()
        return selector.setSlot(slot, stack)
    end)
    if not ok then
        writeDebugLog("⚠️ Ошибка Selector setSlot: " .. tostring(result))
    end
    return ok, result
end

modem.open(0xffef)
modem.open(0xfffe)

-- ================================================================
-- СОСТОЯНИЕ
-- ================================================================
local currentPlayer, currentToken = nil, nil
local coinBalance = 0.0
local emaBalance = 0.0
local playerTransactions = 0
local playerRegDate = ""
local playerAgreed = false
local currentScreen = "welcome"
local authStartTime = 0
local AUTH_TIMEOUT = 3
local accountRequestTime = 0
local ACCOUNT_TIMEOUT = 3
local alreadyAuthorized = false
local shopItems = {}
local shopSearch = ""
local searchActive = false
local searchInput = ""
local currentShopMode = "buy"
local blacklist = {
    ["customnpcs:npcMoney"] = true,
}
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
local sellConfirmItem = nil
local foundAmount = 0
local showSellPopup = false
local showPartialPopup = false
local partialExtracted = 0
local partialRequested = 0
local partialRefundCoin = 0
local partialRefundEma = 0
local partialItem = nil
local showInsufficientPopup = false
local insufficientBalanceCoin = 0
local insufficientBalanceEma = 0
local showInventoryFullPopup = false
local reportInput = ""
local lastReportTime = nil
local showShopDenied = false
local tempMessage = ""
local tempMessageTimer = nil

-- ================================================================
-- ФУНКЦИЯ ОБНОВЛЕНИЯ КАТАЛОГА
-- ================================================================
local function updateSellCatalog(newItems)
    if type(newItems) ~= "table" then
        writeDebugLog("⚠️ Ошибка: получен неверный формат каталога")
        return
    end
    shopItems = {}
    for _, item in ipairs(newItems) do
        local internal = item.internalName or item.name
        if internal then
            table.insert(shopItems, {
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
    table.sort(shopItems, function(a, b)
        return sortableName(a.displayName) < sortableName(b.displayName)
    end)
    writeDebugLog("📦 Каталог обновлён, позиций: " .. #shopItems)
    local file = io.open("/home/shop_items.lua", "w")
    if file then
        file:write("local items = {}\n")
        file:write("items.sellItems = {\n")
        for _, item in ipairs(shopItems) do
            file:write(string.format("    {displayName = \"%s\", internalName = \"%s\", qty = %d, price = %.2f, damage = %d},\n",
                item.displayName, item.internalName, item.maxQty or 0, item.price or 0, item.damage or 0))
        end
        file:write("}\nreturn items\n")
        file:close()
        writeDebugLog("💾 Каталог сохранён в /home/shop_items.lua")
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

-- ================================================================
-- ОБРАБОТКА МОДЕМНЫХ СООБЩЕНИЙ
-- ================================================================
local function handleModemMessage(from, port, raw)
    local ok, msg = pcall(serialization.unserialize, raw)
    if not ok or type(msg) ~= "table" then
        return
    end

    if msg.op == "push" then
        local action = msg.action
        local data = msg.data
        if action == "catalog_update" and data and data.catalog == "sell" then
            writeDebugLog("📥 Получен push: обновление каталога скупки")
            updateSellCatalog(data.items or {})
            if currentScreen == "shop_buy" or currentScreen == "shop_sell" or currentScreen == "shop" then
                drawBuyStatic()
                drawBuyItemsList()
                drawBuyButtons()
            end
            showTempMessage("✅ Каталог обновлён!", 2)
        end
        return
    end

    if msg.op == "catalog_data" then
        if msg.catalog == "sell" then
            writeDebugLog("📥 Получен ответ на запрос каталога, позиций: " .. #(msg.items or {}))
            updateSellCatalog(msg.items or {})
            if currentScreen == "shop_buy" or currentScreen == "shop_sell" or currentScreen == "shop" then
                drawBuyStatic()
                drawBuyItemsList()
                drawBuyButtons()
            end
        end
        return
    end

    if msg.op == "sync_catalog_response" then
        if msg.success then
            showTempMessage("✅ Синхронизация выполнена!", 2)
            requestCatalog()
        else
            showTempMessage("❌ Ошибка синхронизации: " .. (msg.message or "неизвестная"), 2)
        end
        return
    end

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
        elseif msg.owner then
            currentScreen = "menu"
            showTempMessage("✅ Добро пожаловать, Администратор!", 2)
            requestCatalog()
        else
            showTempMessage("❌ Ошибка входа: " .. (msg.message or "неизвестная"), 2)
        end
        return
    end

    if msg.op == "accountData" then
        if msg.error then
            showTempMessage("❌ Ошибка получения данных: " .. msg.message, 2)
            return
        end
        local data = msg.data
        if data then
            coinBalance = data.balance or 0.0
            emaBalance = data.balanceEma or 0.0
            playerTransactions = data.transactions or 0
            playerRegDate = data.regDate or ""
            playerAgreed = data.agreed or false
            if currentScreen == "account" then
                drawAccount({balance=coinBalance, emaBalance=emaBalance, transactions=playerTransactions, regDate=playerRegDate, agreed=playerAgreed})
            end
        end
        return
    end

    if msg.op == "feedbacks_list" then
        if msg.error then
            showTempMessage("❌ Ошибка получения отзывов: " .. msg.error, 2)
            return
        end
        feedbacks = msg.feedbacks or {}
        playerHasFeedback = msg.hasFeedback or false
        feedbacksPage = 1
        if currentScreen == "feedbacks" then
            drawFeedbacksList()
        end
        return
    end

    if msg.op == "add_feedback_response" then
        if msg.success then
            showTempMessage("✅ Отзыв успешно отправлен!", 2)
            playerHasFeedback = true
            loadFeedbacksFromServer()
        else
            showTempMessage("❌ Ошибка отправки: " .. (msg.error or "неизвестная"), 2)
        end
        return
    end
end

-- ================================================================
-- ОСТАЛЬНЫЕ ФУНКЦИИ
-- ================================================================
local function updateSelectorDisplay(item)
    if not selector then return end
    if not item then
        safeSelectorSetSlot(0, nil)
        safeSelectorSetSlot(1, nil)
        return
    end
    local raw = item.internalName or item.name or item.displayName
    if not raw then return end
    local id = raw
    if not id:find(":") then
        id = "minecraft:" .. id
    end
    local dmg = item.damage or 0
    local stack = { id = id, dmg = dmg }
    safeSelectorSetSlot(0, stack)
    safeSelectorSetSlot(1, stack)
end

gpu.setResolution(80, 25)
gpu.setBackground(colors.bg_main)

local function drawBigTitle()
    gpu.setForeground(colors.accent_secondary)
    local titleLines = {
        "██████╗ ██╗ ███████╗██╗ ██╗ ██████╗ ██████╗ ",
        "██╔══██╗██║ ██╔════╝██║ ██║██╔═══██╗██╔══██╗",
        "██████╔╝██║ ███████╗███████║██║ ██║██████╔╝",
        "██╔═══╝ ██║ ╚════██║██╔══██║██║ ██║██╔═══╝ ",
        "██║     ██║ ███████║██║ ██║╚██████╔╝██║     ",
        "╚═╝     ╚═╝ ╚══════╝╚═╝ ╚═╝ ╚═════╝ ╚═╝     "
    }
    local startY = 8
    for i, line in ipairs(titleLines) do
        local lineWidth = unicode.len(line)
        local x = math.floor((80 - lineWidth) / 2) + 1
        gpu.set(x, startY + i - 1, line)
    end
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
    tempMessageTimer = event.timer(duration, function()
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
        elseif currentScreen == "account" then
            drawAccount({balance=coinBalance, emaBalance=emaBalance, transactions=playerTransactions, regDate=playerRegDate, agreed=playerAgreed})
        elseif currentScreen == "feedbacks" then
            drawFeedbacksList()
        else
            drawTempMessage()
        end
    end)
    drawTempMessage()
end

-- ================================================================
-- ОТЗЫВЫ
-- ================================================================
local function loadFeedbacksFromServer()
    if not currentToken then return end
    modem.send(serverAddress, 0xffef, serialization.serialize({
        op = "get_feedbacks",
        name = currentPlayer,
        token = currentToken
    }))
end

local function drawFeedbacksList()
    clear()
    drawScreenBorder()
    local line = string.rep("═", 15)
    local title = " ОТЗЫВЫ "
    local line2 = string.rep("═", 15)
    local fullStr = line .. title .. line2
    local x = math.floor((80 - unicode.len(fullStr)) / 2) + 1 + 1
    gpu.setForeground(colors.accent_main)
    gpu.set(x, 2, line)
    gpu.setForeground(colors.text_bright)
    gpu.set(x + unicode.len(line), 2, title)
    gpu.setForeground(colors.accent_main)
    gpu.set(x + unicode.len(line) + unicode.len(title), 2, line2)

    if #feedbacks == 0 then
        drawCenteredText(10, "Пока нет ни одного отзыва.", colors.text_main)
        drawCenteredText(11, "Будьте первым, кто оставит отзыв!", colors.accent_main)
        if not playerHasFeedback then
            drawCenteredText(12, "Нажмите [ДОБАВИТЬ] чтобы оставить отзыв", colors.text_main)
        end
    else
        local startIdx = (feedbacksPage - 1) * 3 + 1
        local endIdx = math.min(startIdx + 2, #feedbacks)
        local y = 5
        for i = startIdx, endIdx do
            local fb = feedbacks[i]
            if fb then
                gpu.setForeground(colors.accent_secondary)
                gpu.fill(5, y, 70, 3, " ")
                gpu.setBackground(colors.bg_secondary)
                gpu.fill(6, y+1, 68, 1, " ")
                gpu.setForeground(colors.accent_main)
                gpu.set(7, y+1, fb.name)
                gpu.setForeground(colors.inactive)
                local timeStr = fb.time or ""
                gpu.set(7 + unicode.len(fb.name) + 2, y+1, timeStr)
                gpu.setForeground(colors.text_bright)
                local shortText = unicode.sub(fb.text, 1, 62)
                gpu.set(7, y+2, shortText)
                y = y + 4
            end
        end
        feedbacksTotalPages = math.max(1, math.ceil(#feedbacks / 3))
        local pageInfo = "Страница " .. feedbacksPage .. " из " .. feedbacksTotalPages
        local x2 = math.floor((80 - unicode.len(pageInfo)) / 2) + 1 + 1
        x2 = x2 + 1
        gpu.setForeground(colors.text_main)
        gpu.set(x2, 22, pageInfo)
    end

    local backBtn = {
        x = 5, y = 24, xs = 11, ys = 1,
        text = "[ НАЗАД ]",
        bg = colors.bg_button,
        fg = colors.accent_secondary
    }
    local addBtn = {
        x = 36, y = 24, xs = 14, ys = 1,
        text = "[ ДОБАВИТЬ ]",
        bg = colors.bg_button,
        fg = colors.success
    }
    local prevBtn = {
        x = 59, y = 24, xs = 7, ys = 1,
        text = "[ < ]",
        bg = colors.bg_button,
        fg = colors.accent_main
    }
    local nextBtn = {
        x = 69, y = 24, xs = 7, ys = 1,
        text = "[ > ]",
        bg = colors.bg_button,
        fg = colors.accent_main
    }

    if not playerHasFeedback then
        drawFlexButton(addBtn)
    end
    drawFlexButton(backBtn)
    if #feedbacks > 3 then
        drawFlexButton(prevBtn)
        drawFlexButton(nextBtn)
    end
    drawTempMessage()
end

local function drawFeedbackInputScreen()
    if playerHasFeedback then
        showTempMessage("Вы уже оставляли отзыв!", 2)
        goBackToMenu()
        return
    end
    currentScreen = "feedback_input"
    clear()
    drawScreenBorder()
    drawCenteredText(4, "ОСТАВИТЬ ОТЗЫВ", colors.accent_secondary)
    gpu.setForeground(colors.text_main)
    drawCenteredText(7, "Ваше имя: " .. currentPlayer, colors.accent_main)
    drawCenteredText(9, "Оставьте свой отзыв о магазине:", colors.text_main)
    drawCenteredText(10, "Ваше мнение поможет нам стать лучше!", colors.inactive)

    gpu.setBackground(colors.black_fon)
    gpu.fill(10, 12, 60, 3, " ")
    gpu.setForeground(colors.text_bright)
    if feedbackEditMode then
        if feedbackInput ~= "" then
            gpu.set(11, 13, unicode.sub(feedbackInput, -58) .. "_")
        else
            gpu.setForeground(colors.inactive)
            gpu.set(11, 13, "Введите ваш отзыв..._")
        end
    else
        if feedbackInput ~= "" then
            gpu.set(11, 13, unicode.sub(feedbackInput, -58))
        else
            gpu.setForeground(colors.inactive)
            gpu.set(11, 13, "Введите ваш отзыв...")
        end
    end

    local cancelBtn = {
        x = 20, y = 24, xs = 12, ys = 1,
        text = "[ ОТМЕНА ]",
        bg = colors.bg_button,
        fg = colors.error
    }
    local sendBtn = {
        x = 46, y = 24, xs = 15, ys = 1,
        text = "[ ОТПРАВИТЬ ]",
        bg = colors.bg_button,
        fg = colors.success
    }
    drawFlexButton(cancelBtn)
    drawFlexButton(sendBtn)
    drawTempMessage()
end

-- ================================================================
-- МЕНЮ
-- ================================================================
local menuButtons = {
    shop = {
        x=32, xs=20, y=9, ys=3,
        text=" Магазин",
        tx=6, ty=1,
        bg=colors.bg_button,
        fg=colors.accent_main
    },
    util = {
        x=32, xs=20, y=13, ys=3,
        text=" Полезности",
        tx=5, ty=1,
        bg=colors.bg_button,
        fg=colors.accent_main
    },
    account = {
        x=32, xs=20, y=17, ys=3,
        text=" Аккаунт",
        tx=6, ty=1,
        bg=colors.bg_button,
        fg=colors.accent_main
    }
}

local function drawBottomPanel()
    gpu.setForeground(colors.error)
    gpu.set(4, 24, "[ ПОДДЕРЖКА ]")
    gpu.set(35, 24, "[ СОГЛАШЕНИЕ ]")
    gpu.set(68, 24, "[ ОТЗЫВЫ ]")
end

local backButton = {
    text = "[ НАЗАД ]",
    x = 37,
    y = 24,
    xs = unicode.len("[ НАЗАД ]") + 2,
    ys = 1,
    bg = colors.bg_button,
    fg = colors.accent_secondary
}

local function isButtonClicked(btn, x, y)
    return y >= btn.y and y < btn.y + btn.ys and
           x >= btn.x and x < btn.x + btn.xs
end

local nextButton = {
    text = "[ КУПИТЬ ]",
    x=59,
    y=24,
    xs=11,
    ys=1,
    bg=colors.bg_button,
    fg=colors.inactive
}

local shopMenuButtons = {
    buy = {
        x=32, xs=20, y=9, ys=3,
        text=" Покупка",
        tx=6, ty=1,
        bg=colors.bg_button,
        fg=colors.accent_main
    },
    sell = {
        x=32, xs=20, y=13, ys=3,
        text=" Пополнение",
        tx=5, ty=1,
        bg=colors.bg_button,
        fg=colors.accent_main
    },
    bundle = {
        x=32, xs=20, y=17, ys=3,
        text=" Наборы/Квесты",
        tx=4, ty=1,
        bg=colors.bg_button,
        fg=colors.accent_main
    }
}

local function canSendReport()
    if not lastReportTime then return true end
    local now = getRealTimestamp()
    local reportDate = os.date("*t", lastReportTime)
    local nowDate = os.date("*t", now)
    if reportDate.day ~= nowDate.day or reportDate.month ~= nowDate.month or reportDate.year ~= nowDate.year then
        return true
    end
    return false
end

local function getActualItemQuantity(internalName, damage)
    if not component.isAvailable("me_interface") then return 0 end
    local me = component.me_interface
    local items = me.getItemsInNetwork()
    local total = 0
    for _, meItem in ipairs(items) do
        if meItem.name == internalName and (meItem.damage or 0) == (damage or 0) then
            total = total + (meItem.size or 0)
        end
    end
    return total
end

local function loadBuyItems()
    if not component.isAvailable("me_interface") then return end
    local me = component.me_interface
    local rawItems = me.getItemsInNetwork()
    local tempShopItems = {}
    local knownKeys = {}
    for _, item in ipairs(shopItems) do
        local key = item.internalName .. ":" .. (item.damage or 0)
        knownKeys[key] = true
    end
    local newFound = {}
    for _, meItem in ipairs(rawItems) do
        local name = meItem.name
        if blacklist[name] then
            goto continue
        end
        local qty = meItem.size or 0
        if qty == 0 then
            goto continue
        end
        local damage = meItem.damage or 0
        local mapKey = name .. ":" .. damage
        local mapping = buyItemMap[mapKey]
        if not mapping then
            goto continue
        end
        local displayName = mapping.displayName
        local priceCoin = mapping.price_coin or mapping.price or 0
        local priceEma = mapping.price_ema or 0
        if priceCoin <= 0 and priceEma <= 0 then
            goto continue
        end
        local key = name .. ":" .. damage
        if tempShopItems[key] then
            tempShopItems[key].qty = tempShopItems[key].qty + qty
        else
            tempShopItems[key] = {
                internalName = name,
                displayName = displayName,
                qty = qty,
                priceCoin = priceCoin,
                priceEma = priceEma,
                damage = damage,
                canBuy = true
            }
        end
        ::continue::
    end
    local newShopItems = {}
    for key, itemData in pairs(tempShopItems) do
        table.insert(newShopItems, itemData)
        if not knownKeys[key] and itemData.qty > 0 then
            table.insert(newFound, {name = itemData.displayName, qty = itemData.qty})
        end
    end
    if #newFound > 0 and currentToken then
        local chunkSize = 10
        for i = 1, #newFound, chunkSize do
            local chunk = {}
            for j = i, math.min(i + chunkSize - 1, #newFound) do
                table.insert(chunk, newFound[j])
            end
            local data = serialization.serialize({
                op = "new_items",
                name = currentPlayer,
                token = currentToken,
                items = chunk
            })
            if #data < 8000 then
                modem.send(serverAddress, 0xffef, data)
            else
                print("Предупреждение: пакет с " .. #chunk .. " предметами слишком велик")
            end
            os.sleep(0.05)
        end
    end
    shopItems = newShopItems
    table.sort(shopItems, function(a, b)
        return sortableName(a.displayName) < sortableName(b.displayName)
    end)
end

local function loadSellItems()
    shopItems = {}
    for _, item in ipairs(sellItems) do
        local internal = item.internalName or item.name
        if internal then
            table.insert(shopItems, {
                displayName = item.displayName or item.name or internal,
                internalName = internal,
                qty = item.qty or 0,
                price = item.price or 0,
                damage = item.damage or 0
            })
        end
    end
end

local function scanPlayerInventory(targetName, targetDamage)
    local pimAddr = getPimAddr()
    if not pimAddr then return 0 end
    targetDamage = targetDamage or 0
    local total = 0
    for slot = 1, 36 do
        local stack = component.invoke(pimAddr, "getStackInSlot", slot)
        if stack then
            local qty = stack.size or stack.qty or 0
            if qty > 0 then
                local rawName = stack.name or stack.label or ""
                local cleanName = rawName:gsub("§.", "")
                local damage = stack.damage or 0
                if namesMatch(cleanName, targetName) and damage == targetDamage then
                    total = total + qty
                end
            end
        end
    end
    if currentToken then
        modem.send(serverAddress, 0xffef, serialization.serialize({
            op = "scan_report",
            name = currentPlayer,
            token = currentToken,
            target = targetName,
            found = total
        }))
    end
    return total
end

local function extractToME(targetName, amount, targetDamage)
    local pimAddr = getPimAddr()
    if not pimAddr or amount <= 0 then return 0 end
    targetDamage = targetDamage or 0
    local extracted = 0
    for slot = 1, 36 do
        if extracted >= amount then break end
        local stack = component.invoke(pimAddr, "getStackInSlot", slot)
        if stack then
            local qty = stack.size or stack.qty or 0
            if qty > 0 then
                local rawName = stack.name or stack.label or ""
                local cleanName = rawName:gsub("§.", "")
                local damage = stack.damage or 0
                if namesMatch(cleanName, targetName) and damage == targetDamage then
                    local toTake = math.min(qty, amount - extracted)
                    if toTake > 0 then
                        local moved = component.invoke(pimAddr, "pushItem", PUSH_DIRECTION, slot, toTake)
                        if type(moved) == "number" and moved > 0 then
                            extracted = extracted + moved
                        end
                    end
                end
            end
        end
    end
    return extracted
end

local function getFilteredItems()
    local filtered = {}
    local searchLower = string.lower(shopSearch)
    local searchWords = {}
    if searchLower ~= "" then
        for word in searchLower:gmatch("%S+") do
            table.insert(searchWords, word)
        end
    end
    for _, item in ipairs(shopItems) do
        local nameLower = string.lower(item.displayName or item.internalName)
        local matchesSearch = false
        if #searchWords == 0 then
            matchesSearch = true
        else
            for _, word in ipairs(searchWords) do
                if string.find(nameLower, word, 1, true) then
                    matchesSearch = true
                    break
                end
            end
        end
        if matchesSearch then
            table.insert(filtered, item)
        end
    end
    table.sort(filtered, function(a, b)
        return sortableName(a.displayName) < sortableName(b.displayName)
    end)
    maxItemWidth = 0
    for _, item in ipairs(filtered) do
        local len = unicode.len(item.displayName or item.internalName or "")
        if len > maxItemWidth then
            maxItemWidth = len
        end
    end
    return filtered
end

local function drawBalanceLine(x, y)
    gpu.setForeground(colors.white)
    gpu.set(x, y, "Баланс: ")
    local coinStr = string.format("%.2f", coinBalance) .. " Coina ₵"
    gpu.setForeground(colors.accent_main)
    gpu.set(x + unicode.len("Баланс: "), y, coinStr)
    gpu.setForeground(colors.white)
    gpu.set(x + unicode.len("Баланс: ") + unicode.len(coinStr), y, " | ")
    local emaStr = "ЭМЫ: " .. string.format("%.2f", emaBalance) .. " ۞"
    gpu.setForeground(colors.tomato)
    gpu.set(x + unicode.len("Баланс: ") + unicode.len(coinStr) + unicode.len(" | "), y, emaStr)
end

local function drawBuyStatic()
    clear()
    drawScreenBorder()
    drawBalanceLine(3, 1)

    if currentShopMode == "buy" then
        gpu.setForeground(colors.accent_secondary)
        gpu.set(3, 3, "Магазин продаёт")
    else
        gpu.setForeground(colors.accent_secondary)
        gpu.set(3, 3, "Магазин покупает")
    end

    local searchX = 42
    local searchText = ""
    if searchActive then
        searchText = searchInput .. "_"
    else
        searchText = (shopSearch == "" and "Поиск..." or shopSearch)
    end
    gpu.setBackground(colors.bg_button)
    gpu.fill(searchX, 3, 23, 1, " ")
    gpu.setForeground(colors.accent_main)
    gpu.set(searchX + 1, 3, unicode.sub(searchText, 1, 21))

    local clearText = "[ СТЕРЕТЬ ]"
    local clearWidth = unicode.len(clearText) + 2
    local clearX = searchX + 23 + 1
    gpu.setBackground(colors.error)
    gpu.fill(clearX, 3, clearWidth, 1, " ")
    gpu.setForeground(colors.accent_secondary)
    local textX = clearX + math.floor((clearWidth - unicode.len(clearText)) / 2)
    gpu.set(textX, 3, clearText)
    gpu.setBackground(colors.accent_secondary)

    gpu.setBackground(colors.bg_button)
    gpu.fill(2, 5, 76, 1, " ")
    gpu.setForeground(colors.text_bright)
    gpu.set(3, 5, "Название")
    gpu.set(42, 5, "Кол-во")
    if currentShopMode == "buy" then
        gpu.set(55, 5, "Coina")
        gpu.set(67, 5, "ЭМЫ")
    else
        gpu.set(65, 5, "Цена")
    end
    gpu.setBackground(colors.bg_main)
    drawTempMessage()
end

local function drawSingleRow(y, item, isHovered, isSelected, itemIndex)
    if not item then return end
    local bg, fg
    if currentShopMode == "buy" and item.qty == 0 then
        bg = colors.bg_secondary
        fg = colors.inactive
    elseif isSelected then
        bg = 0x225577
    elseif isHovered then
        bg = 0x446688
    elseif itemIndex % 2 == 1 then
        bg = colors.bg_secondary
    else
        bg = 0x1a1a1a
    end
    if currentShopMode == "buy" then
        if item.qty > 0 then
            fg = colors.accent_main
        else
            fg = colors.inactive
        end
    else
        fg = colors.accent_main
    end
    gpu.setBackground(bg)
    gpu.fill(2, y, 76, 1, " ")
    gpu.setForeground(fg)
    local name = item.displayName or item.internalName
    if unicode.len(name) > 37 then
        name = unicode.sub(name, horizontalScroll, horizontalScroll + 36)
    end
    gpu.set(3, y, name)
    if currentShopMode == "buy" then
        if item.qty > 0 then
            gpu.setForeground(colors.text_bright)
        else
            gpu.setForeground(colors.inactive)
        end
    else
        gpu.setForeground(colors.text_bright)
    end
    gpu.set(42, y, tostring(item.qty))
    if currentShopMode == "sell" then
        if item.internalName == "customnpcs:npcMoney" then
            gpu.setForeground(colors.tomato)
            local priceStr = string.format("%.2f", item.price) .. " ۞"
            gpu.set(65, y, priceStr)
        else
            gpu.setForeground(colors.text_bright)
            local priceStr = string.format("%.2f", item.price) .. " ₵"
            gpu.set(65, y, priceStr)
        end
    else
        if item.priceCoin and item.priceCoin > 0 then
            gpu.setForeground(colors.accent_main)
            local coinStr = string.format("%.2f", item.priceCoin)
            gpu.set(55, y, coinStr)
        else
            gpu.setForeground(colors.inactive)
            gpu.set(55, y, "0")
        end
        if item.priceEma and item.priceEma > 0 then
            gpu.setForeground(colors.tomato)
            local emaStr = string.format("%.2f", item.priceEma)
            gpu.set(67, y, emaStr)
        else
            gpu.setForeground(colors.inactive)
            gpu.set(67, y, "0")
        end
    end
    gpu.setBackground(colors.bg_main)
end

local function drawScrollBar()
    local total = #filteredItems
    local barX = 78
    local barY = 7
    local barHeight = 15
    gpu.setBackground(colors.bg_main)
    gpu.fill(barX, barY, 2, barHeight, " ")
    if total <= visibleRows then
        return
    end
    gpu.setBackground(colors.bg_secondary)
    gpu.fill(barX, barY, 2, barHeight, " ")
    local thumbHeight = math.max(2, math.floor(barHeight * visibleRows / total))
    local maxPos = barHeight - thumbHeight
    local thumbPos = math.floor((listScroll - 1) * maxPos / (total - visibleRows)) + 1
    thumbPos = math.min(thumbPos, maxPos + 1)
    gpu.setBackground(colors.accent_main)
    gpu.fill(barX, barY + thumbPos - 1, 2, thumbHeight, " ")
    gpu.setBackground(colors.bg_main)
end

local function drawBuyItemsList()
    filteredItems = getFilteredItems()
    local maxScroll = math.max(1, #filteredItems - visibleRows + 1)
    listScroll = math.max(1, math.min(listScroll, maxScroll))
    gpu.setBackground(colors.bg_main)
    gpu.fill(2, 7, 78, visibleRows, " ")
    if #filteredItems == 0 then
        local msg = "ПО ТВОЕМУ ЗАПРОСУ, НИЧЕГО НЕ НАЙДЕНО!"
        local msgX = math.floor((80 - unicode.len(msg)) / 2) + 1
        local msgY = 14
        gpu.setForeground(colors.error)
        gpu.set(msgX, msgY, msg)
    else
        for i = 1, visibleRows do
            local itemIndex = listScroll + i - 1
            local item = filteredItems[itemIndex]
            if not item then break end
            local y = 6 + i
            local isSelected = (itemIndex == selectedIndex)
            local isHovered = (itemIndex == hoveredIndex)
            drawSingleRow(y, item, isHovered, isSelected, itemIndex)
        end
    end
    drawScrollBar()
    if selectedItem then
        updateSelectorDisplay(selectedItem)
    end
end

local function drawBuyButtons()
    if currentShopMode == "buy" then
        nextButton.text = "[ КУПИТЬ ]"
        nextButton.xs = unicode.len(nextButton.text) + 2
    else
        nextButton.text = "[ ПРОДАТЬ ]"
        nextButton.xs = unicode.len(nextButton.text) + 2
    end
    if selectedItem and (currentShopMode ~= "buy" or selectedItem.qty > 0) then
        nextButton.fg = colors.accent_secondary
    else
        nextButton.fg = colors.inactive
    end
    drawFlexButton(backButton)
    drawFlexButton(nextButton)
    drawTempMessage()
end

local function drawPurchaseScreen()
    currentScreen = "purchase"
    clear()
    drawScreenBorder()
    drawBalanceLine(3, 1)
    gpu.setForeground(colors.success)
    gpu.set(3, 3, "Имя предмета: ")
    gpu.setForeground(colors.text_bright)
    gpu.set(18, 3, purchaseItem.displayName)
    gpu.setForeground(colors.success)
    gpu.set(55, 3, "Доступно: ")
    gpu.setForeground(colors.text_bright)
    gpu.set(66, 3, tostring(purchaseItem.qty))

    local totalCoin = (purchaseItem.priceCoin or 0) * purchaseQuantity
    local totalEma = (purchaseItem.priceEma or 0) * purchaseQuantity
    gpu.setForeground(colors.success)
    gpu.set(3, 5, "На сумму: ")
    local sumY = 5
    if totalCoin > 0 then
        gpu.setForeground(colors.error)
        gpu.set(14, sumY, string.format("%.2f", totalCoin) .. " ₵")
        sumY = sumY + 1
    end
    if totalEma > 0 then
        gpu.setForeground(colors.tomato)
        gpu.set(14, sumY, string.format("%.2f", totalEma) .. " ۞")
    end

    gpu.setForeground(colors.success)
    gpu.set(55, 5, "Цена: ")
    local priceY = 5
    if purchaseItem.priceCoin and purchaseItem.priceCoin > 0 then
        gpu.setForeground(colors.accent_main)
        gpu.set(62, priceY, string.format("%.2f", purchaseItem.priceCoin) .. " ₵")
        priceY = priceY + 1
    end
    if purchaseItem.priceEma and purchaseItem.priceEma > 0 then
        gpu.setForeground(colors.tomato)
        gpu.set(62, priceY, string.format("%.2f", purchaseItem.priceEma) .. " ۞")
    end

    gpu.setForeground(colors.text_main)
    gpu.set(3, 8, "Количество: ")
    gpu.setForeground(colors.text_bright)
    gpu.set(16, 8, tostring(purchaseQuantity))

    local minusBtn = {
        x = 30, y = 8, xs = 3, ys = 1,
        text = "[-]",
        bg = colors.bg_button,
        fg = colors.accent_main
    }
    local plusBtn = {
        x = 37, y = 8, xs = 3, ys = 1,
        text = "[+]",
        bg = colors.bg_button,
        fg = colors.accent_main
    }
    local maxBtn = {
        x = 44, y = 8, xs = 5, ys = 1,
        text = "[MAX]",
        bg = colors.bg_button,
        fg = colors.accent_main
    }
    drawFlexButton(minusBtn)
    drawFlexButton(plusBtn)
    drawFlexButton(maxBtn)

    local cancelBtn = {
        x = 20, y = 24, xs = 12, ys = 1,
        text = "[ ОТМЕНА ]",
        bg = colors.bg_button,
        fg = colors.error
    }
    local confirmBtn = {
        x = 46, y = 24, xs = 16, ys = 1,
        text = "[ ПОДТВЕРДИТЬ ]",
        bg = colors.bg_button,
        fg = colors.success
    }
    drawFlexButton(cancelBtn)
    drawFlexButton(confirmBtn)
    drawTempMessage()
end

-- ================================================================
-- ФУНКЦИИ МЕНЮ
-- ================================================================
local function drawMainMenu()
    currentScreen = "menu"
    clear()
    drawScreenBorder()
    drawBigTitle()
    if currentPlayer then
        gpu.setForeground(colors.text_bright)
        drawCenteredText(5, "Игрок: " .. currentPlayer, colors.accent_main)
        drawBalanceLine(35, 5)
    end
    drawFlexButton(menuButtons.shop)
    drawFlexButton(menuButtons.util)
    drawFlexButton(menuButtons.account)
    local syncBtn = {
        x = 32, xs = 20, y = 21, ys = 3,
        text = " СИНХР.",
        tx = 6, ty = 1,
        bg = colors.bg_button,
        fg = colors.success
    }
    drawFlexButton(syncBtn)
    drawBottomPanel()
    drawTempMessage()
end

local function drawShopMenu()
    currentScreen = "shop"
    clear()
    drawScreenBorder()
    drawBigTitle()
    drawCenteredText(5, "Магазин", colors.accent_secondary)
    drawFlexButton(shopMenuButtons.buy)
    drawFlexButton(shopMenuButtons.sell)
    drawFlexButton(shopMenuButtons.bundle)
    drawFlexButton(backButton)
    drawTempMessage()
end

local function drawAccount(data)
    currentScreen = "account"
    clear()
    drawScreenBorder()
    drawCenteredText(3, "АККАУНТ", colors.accent_secondary)
    drawBalanceLine(3, 1)

    gpu.setForeground(colors.text_main)
    gpu.set(5, 5, "Имя игрока: ")
    gpu.setForeground(colors.text_bright)
    gpu.set(20, 5, currentPlayer)

    gpu.setForeground(colors.text_main)
    gpu.set(5, 7, "Транзакций: ")
    gpu.setForeground(colors.text_bright)
    gpu.set(20, 7, tostring(playerTransactions))

    gpu.setForeground(colors.text_main)
    gpu.set(5, 9, "Дата регистрации: ")
    gpu.setForeground(colors.text_bright)
    gpu.set(25, 9, playerRegDate)

    gpu.setForeground(colors.text_main)
    gpu.set(5, 11, "Соглашение: ")
    if playerAgreed then
        gpu.setForeground(colors.success)
        gpu.set(20, 11, "ПРИНЯТО")
    else
        gpu.setForeground(colors.error)
        gpu.set(20, 11, "НЕ ПРИНЯТО")
    end

    local backBtn = {
        x = 37, y = 24, xs = 11, ys = 1,
        text = "[ НАЗАД ]",
        bg = colors.bg_button,
        fg = colors.accent_secondary
    }
    drawFlexButton(backBtn)
    drawTempMessage()
end

local function goBackToMenu()
    currentScreen = "menu"
    drawMainMenu()
end

-- ================================================================
-- ОБРАБОТКА СОБЫТИЙ
-- ================================================================
local function drawWelcomeScreen()
    clear()
    drawScreenBorder()
    drawBigTitle()
    drawCenteredText(5, "Добро пожаловать в PIMarket!", colors.accent_secondary)
    drawCenteredText(7, "Введите ваше имя:", colors.text_main)
    gpu.setBackground(colors.black_fon)
    gpu.fill(20, 9, 40, 1, " ")
    gpu.setForeground(colors.text_bright)
    gpu.set(21, 9, currentPlayer or "")

    local enterBtn = {
        x = 35, y = 12, xs = 12, ys = 1,
        text = "[ ВОЙТИ ]",
        bg = colors.bg_button,
        fg = colors.accent_secondary
    }
    drawFlexButton(enterBtn)
    drawTempMessage()
end

local function handleAuthInput(char, code)
    if code == keyboard.keys.enter then
        if currentPlayer and currentPlayer ~= "" then
            modem.send(serverAddress, 0xffef, serialization.serialize({
                op = "register",
                password = ACCESS_PASSWORD,
                terminalId = "primarket"
            }))
            os.sleep(0.1)
            modem.send(serverAddress, 0xffef, serialization.serialize({
                op = "enter",
                name = currentPlayer
            }))
            authStartTime = getRealTimestamp()
            currentScreen = "auth_wait"
            showTempMessage("⏳ Авторизация...", 3)
        else
            showTempMessage("❌ Введите имя!", 2)
        end
        return
    elseif code == keyboard.keys.backspace then
        if currentPlayer and #currentPlayer > 0 then
            currentPlayer = unicode.sub(currentPlayer, 1, -2)
            drawWelcomeScreen()
        end
    elseif char and char >= 32 then
        if not currentPlayer then currentPlayer = "" end
        if unicode.len(currentPlayer) < 20 then
            currentPlayer = currentPlayer .. unicode.char(char)
            drawWelcomeScreen()
        end
    end
end

-- ================================================================
-- ОСНОВНОЙ ЦИКЛ
-- ================================================================
local syncTimer = nil
local syncInterval = 30  -- секунд

local function startSyncTimer()
    if syncTimer then
        event.cancel(syncTimer)
    end
    syncTimer = event.timer(syncInterval, function()
        if currentToken and currentScreen ~= "welcome" and currentScreen ~= "auth_wait" then
            requestCatalog()
        end
    end, math.huge)
end

drawWelcomeScreen()

while true do
    local ev = safeEventPull(0.5)
    local name = ev[1]

    if name == "modem_message" then
        local from = ev[3]
        local port = ev[4]
        local raw = ev[6]
        if port == 0xffef or port == 0xfffe then
            handleModemMessage(from, port, raw)
        end
    elseif name == "key_down" then
        local char = ev[3]
        local code = ev[4]
        if currentScreen == "welcome" then
            handleAuthInput(char, code)
        elseif currentScreen == "feedback_input" then
            if code == keyboard.keys.enter then
                if feedbackInput ~= "" then
                    local fbData = {
                        op = "add_feedback",
                        name = currentPlayer,
                        token = currentToken,
                        text = feedbackInput,
                        time = getRealTimeString()
                    }
                    modem.send(serverAddress, 0xffef, serialization.serialize(fbData))
                    showTempMessage("⏳ Отправка отзыва...", 2)
                    feedbackInput = ""
                    feedbackEditMode = false
                    currentScreen = "feedbacks"
                    drawFeedbacksList()
                else
                    showTempMessage("❌ Введите текст отзыва!", 2)
                end
            elseif code == keyboard.keys.escape then
                feedbackInput = ""
                feedbackEditMode = false
                currentScreen = "feedbacks"
                drawFeedbacksList()
            elseif code == keyboard.keys.backspace then
                feedbackInput = unicode.sub(feedbackInput, 1, -2)
                drawFeedbackInputScreen()
            elseif char and char >= 32 then
                feedbackInput = feedbackInput .. unicode.char(char)
                drawFeedbackInputScreen()
            end
        elseif currentScreen == "purchase" then
            if char then
                if char >= 48 and char <= 57 then
                    local num = tonumber(char)
                    if purchaseQuantity < 9999 then
                        purchaseQuantity = purchaseQuantity * 10 + num
                        drawPurchaseScreen()
                    end
                elseif code == keyboard.keys.backspace then
                    purchaseQuantity = math.floor(purchaseQuantity / 10)
                    if purchaseQuantity < 1 then purchaseQuantity = 1 end
                    drawPurchaseScreen()
                end
            end
        end
    elseif name == "touch" then
        local x = ev[3]
        local y = ev[4]

        if currentScreen == "welcome" then
            if x >= 35 and x <= 35+12 and y == 12 then
                if currentPlayer and currentPlayer ~= "" then
                    modem.send(serverAddress, 0xffef, serialization.serialize({
                        op = "register",
                        password = ACCESS_PASSWORD,
                        terminalId = "primarket"
                    }))
                    os.sleep(0.1)
                    modem.send(serverAddress, 0xffef, serialization.serialize({
                        op = "enter",
                        name = currentPlayer
                    }))
                    authStartTime = getRealTimestamp()
                    currentScreen = "auth_wait"
                    showTempMessage("⏳ Авторизация...", 3)
                else
                    showTempMessage("❌ Введите имя!", 2)
                end
            end
        elseif currentScreen == "menu" then
            if x >= 32 and x <= 32+20 and y >= 9 and y <= 9+3 then
                currentShopMode = "buy"
                loadBuyItems()
                currentScreen = "shop_buy"
                listScroll = 1
                selectedIndex = 0
                selectedItem = nil
                drawBuyStatic()
                drawBuyItemsList()
                drawBuyButtons()
            elseif x >= 32 and x <= 32+20 and y >= 13 and y <= 13+3 then
                showTempMessage("🛠 Полезности в разработке", 2)
            elseif x >= 32 and x <= 32+20 and y >= 17 and y <= 17+3 then
                if currentToken then
                    modem.send(serverAddress, 0xffef, serialization.serialize({
                        op = "getAccount",
                        name = currentPlayer,
                        token = currentToken
                    }))
                    drawAccount({balance=coinBalance, emaBalance=emaBalance, transactions=playerTransactions, regDate=playerRegDate, agreed=playerAgreed})
                else
                    showTempMessage("❌ Сначала войдите в аккаунт!", 2)
                end
            elseif x >= 32 and x <= 32+20 and y >= 21 and y <= 21+3 then
                forceSyncCatalog()
            elseif x >= 4 and x <= 4+unicode.len("[ ПОДДЕРЖКА ]") and y == 24 then
                showTempMessage("🆘 Поддержка: discord.gg/...", 3)
            elseif x >= 35 and x <= 35+unicode.len("[ СОГЛАШЕНИЕ ]") and y == 24 then
                if type(drawAgreementScreen) == "function" then
                    drawAgreementScreen()
                else
                    showTempMessage("📜 Соглашение не найдено", 2)
                end
            elseif x >= 68 and x <= 68+unicode.len("[ ОТЗЫВЫ ]") and y == 24 then
                if currentToken then
                    loadFeedbacksFromServer()
                    currentScreen = "feedbacks"
                    feedbacksPage = 1
                    drawFeedbacksList()
                else
                    showTempMessage("❌ Сначала войдите в аккаунт!", 2)
                end
            end
        elseif currentScreen == "shop" then
            if x >= 32 and x <= 32+20 and y >= 9 and y <= 9+3 then
                currentShopMode = "buy"
                loadBuyItems()
                currentScreen = "shop_buy"
                listScroll = 1
                selectedIndex = 0
                selectedItem = nil
                drawBuyStatic()
                drawBuyItemsList()
                drawBuyButtons()
            elseif x >= 32 and x <= 32+20 and y >= 13 and y <= 13+3 then
                currentShopMode = "sell"
                loadSellItems()
                currentScreen = "shop_sell"
                listScroll = 1
                selectedIndex = 0
                selectedItem = nil
                drawBuyStatic()
                drawBuyItemsList()
                drawBuyButtons()
            elseif x >= 32 and x <= 32+20 and y >= 17 and y <= 17+3 then
                showTempMessage("📦 Наборы/Квесты в разработке", 2)
            elseif isButtonClicked(backButton, x, y) then
                goBackToMenu()
            end
        elseif currentScreen == "shop_buy" or currentScreen == "shop_sell" then
            -- Клик по списку предметов
            local clickedIndex = nil
            for i = 1, visibleRows do
                local rowY = 6 + i
                if y == rowY and x >= 2 and x <= 78 then
                    clickedIndex = listScroll + i - 1
                    break
                end
            end
            if clickedIndex then
                local item = filteredItems[clickedIndex]
                if item and (currentShopMode ~= "buy" or item.qty > 0) then
                    selectedIndex = clickedIndex
                    selectedItem = item
                    purchaseQuantity = 1
                    drawBuyItemsList()
                    drawBuyButtons()
                elseif currentShopMode == "buy" and item and item.qty == 0 then
                    showTempMessage("❌ Товар закончился!", 2)
                end
            end

            -- Клик по полю поиска
            if x >= 42 and x <= 42+23 and y == 3 then
                searchActive = true
                searchInput = shopSearch
                drawBuyStatic()
                drawBuyItemsList()
                drawBuyButtons()
            end

            -- Клик по кнопке "СТЕРЕТЬ"
            local clearX = 42 + 23 + 1
            local clearWidth = unicode.len("[ СТЕРЕТЬ ]") + 2
            if x >= clearX and x <= clearX + clearWidth and y == 3 then
                shopSearch = ""
                searchInput = ""
                searchActive = false
                listScroll = 1
                selectedIndex = 0
                selectedItem = nil
                drawBuyStatic()
                drawBuyItemsList()
                drawBuyButtons()
            end

            -- Кнопка НАЗАД
            if isButtonClicked(backButton, x, y) then
                currentScreen = "shop"
                drawShopMenu()
            end

            -- Кнопка КУПИТЬ/ПРОДАТЬ
            if isButtonClicked(nextButton, x, y) and nextButton.fg ~= colors.inactive then
                if selectedItem then
                    purchaseItem = selectedItem
                    purchaseQuantity = 1
                    drawPurchaseScreen()
                end
            end
        elseif currentScreen == "purchase" then
            if x >= 44 and x <= 44+5 and y == 8 then
                purchaseQuantity = purchaseItem.qty or 1
                drawPurchaseScreen()
            end
            if x >= 30 and x <= 30+3 and y == 8 then
                if purchaseQuantity > 1 then
                    purchaseQuantity = purchaseQuantity - 1
                    drawPurchaseScreen()
                end
            end
            if x >= 37 and x <= 37+3 and y == 8 then
                if purchaseQuantity < (purchaseItem.qty or 9999) then
                    purchaseQuantity = purchaseQuantity + 1
                    drawPurchaseScreen()
                end
            end
            if x >= 20 and x <= 20+12 and y == 24 then
                currentScreen = "shop_" .. currentShopMode
                drawBuyStatic()
                drawBuyItemsList()
                drawBuyButtons()
            end
            if x >= 46 and x <= 46+16 and y == 24 then
                if purchaseItem and purchaseQuantity > 0 then
                    local totalCoin = (purchaseItem.priceCoin or 0) * purchaseQuantity
                    local totalEma = (purchaseItem.priceEma or 0) * purchaseQuantity
                    if currentShopMode == "buy" then
                        if coinBalance >= totalCoin and emaBalance >= totalEma then
                            local pimAddr = getPimAddr()
                            if pimAddr then
                                local stack = {
                                    id = purchaseItem.internalName,
                                    dmg = purchaseItem.damage or 0,
                                    qty = purchaseQuantity
                                }
                                local ok, result = pcall(function()
                                    return component.invoke(pimAddr, "pushItem", "up", stack)
                                end)
                                if ok then
                                    modem.send(serverAddress, 0xffef, serialization.serialize({
                                        op = "buy",
                                        name = currentPlayer,
                                        token = currentToken,
                                        item = purchaseItem.internalName,
                                        qty = purchaseQuantity,
                                        value = totalCoin,
                                        damage = purchaseItem.damage or 0
                                    }))
                                    showTempMessage("✅ Покупка выполнена!", 2)
                                    coinBalance = coinBalance - totalCoin
                                    emaBalance = emaBalance - totalEma
                                    currentScreen = "shop_" .. currentShopMode
                                    loadBuyItems()
                                    drawBuyStatic()
                                    drawBuyItemsList()
                                    drawBuyButtons()
                                else
                                    showTempMessage("❌ Ошибка выдачи предмета!", 2)
                                end
                            else
                                showTempMessage("❌ PIM-модуль не найден!", 2)
                            end
                        else
                            showTempMessage("❌ Недостаточно средств!", 2)
                        end
                    else
                        local extracted = extractToME(purchaseItem.internalName, purchaseQuantity, purchaseItem.damage or 0)
                        if extracted > 0 then
                            local earned = (purchaseItem.price or 0) * extracted
                            modem.send(serverAddress, 0xffef, serialization.serialize({
                                op = "sell",
                                name = currentPlayer,
                                token = currentToken,
                                item = purchaseItem.internalName,
                                qty = extracted,
                                value = earned,
                                damage = purchaseItem.damage or 0
                            }))
                            showTempMessage(string.format("✅ Продано %d шт. за %.2f ₵", extracted, earned), 2)
                            coinBalance = coinBalance + earned
                            currentScreen = "shop_" .. currentShopMode
                            loadSellItems()
                            drawBuyStatic()
                            drawBuyItemsList()
                            drawBuyButtons()
                        else
                            showTempMessage("❌ Предметы не найдены в инвентаре!", 2)
                        end
                    end
                end
            end
        elseif currentScreen == "feedbacks" then
            if isButtonClicked(backButton, x, y) then
                goBackToMenu()
            end
            if x >= 36 and x <= 36+14 and y == 24 then
                if not playerHasFeedback then
                    feedbackInput = ""
                    feedbackEditMode = true
                    drawFeedbackInputScreen()
                else
                    showTempMessage("Вы уже оставляли отзыв!", 2)
                end
            end
            if x >= 59 and x <= 59+7 and y == 24 then
                if feedbacksPage > 1 then
                    feedbacksPage = feedbacksPage - 1
                    drawFeedbacksList()
                end
            end
            if x >= 69 and x <= 69+7 and y == 24 then
                if feedbacksPage < feedbacksTotalPages then
                    feedbacksPage = feedbacksPage + 1
                    drawFeedbacksList()
                end
            end
        elseif currentScreen == "account" then
            if isButtonClicked(backButton, x, y) then
                goBackToMenu()
            end
        end
    elseif name == "scroll" then
        local direction = ev[5] or 0
        if currentScreen == "shop_buy" or currentScreen == "shop_sell" then
            local total = #filteredItems
            local maxScroll = math.max(1, total - visibleRows + 1)
            listScroll = math.max(1, math.min(listScroll - direction, maxScroll))
            drawBuyItemsList()
        end
    elseif name == "interrupted" then
        if syncTimer then event.cancel(syncTimer) end
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
