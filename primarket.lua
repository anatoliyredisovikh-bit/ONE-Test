-- ============================================================
-- VIPCLIENT – клиент для VIP-SHOP MODEM SERVER
-- Версия 5.1 (с фиксированным адресом сервера)
-- Полный файл, готовый к запуску
-- ============================================================

local component = require("component")
local gpu = component.gpu
local term = require("term")
local event = require("event")
local keyboard = require("keyboard")
local unicode = require("unicode")
local computer = require("computer")
local serialization = require("serialization")
local fs = require("filesystem")

if not component.isAvailable("modem") then error("Модем не найден",0) end
if not component.isAvailable("gpu") then error("Видеокарта не найдена",0) end

local modem = component.modem
local gpu = component.gpu

-- ============================================================
--  АДРЕС СЕРВЕРА (фиксированный из старых файлов)
-- ============================================================
local SERVER_ADDRESS = "592322fc-e0b7-4406-8d04-22d4e8be95b6"
-- Можно переопределить через файл /home/server_address.dat
if fs.exists("/home/server_address.dat") then
    local file = io.open("/home/server_address.dat", "r")
    if file then
        local addr = file:read("*a")
        file:close()
        if addr and addr ~= "" then
            SERVER_ADDRESS = addr:gsub("%s+", "")
        end
    end
end

local PROTOCOL = "VIPSHOP-MODEM-1"
local NETWORK_KEY = "VIPSHOP_ZOZIDO_REALM9_SECRET_2026"
local SERVER_PORT = 3410
local CLIENT_PORT = 3411
local CHUNK_SIZE = 6000

local serverAddress = SERVER_ADDRESS  -- используем фиксированный адрес
local pendingRequests = {}

local function writeDebugLog(msg)
    pcall(function()
        local file = io.open("/home/vipclient_debug.log", "a")
        if file then
            file:write("[" .. os.date("%H:%M:%S") .. "] " .. tostring(msg) .. "\n")
            file:close()
        end
    end)
end

-- Поиск сервера не требуется, адрес известен
local function discoverServer()
    return true
end

local function sendRequest(action, payload, callback)
    if not serverAddress then
        if callback then callback({status="error", message="Адрес сервера не задан"}) end
        return
    end

    local requestId = tostring(os.time()) .. tostring(math.random(1000, 9999))
    payload.action = action
    payload.terminalId = "VIPCLIENT-" .. tostring(computer.address():sub(1,8))

    local data = serialization.serialize(payload)

    pendingRequests[requestId] = {
        chunks = {},
        total = 0,
        received = 0,
        callback = callback,
        completed = false,
        timer = nil
    }

    local timer = event.timer(5, function()
        local req = pendingRequests[requestId]
        if req and not req.completed then
            req.completed = true
            pendingRequests[requestId] = nil
            if req.callback then
                req.callback({status="error", message="Таймаут ответа сервера"})
            end
        end
    end)
    pendingRequests[requestId].timer = timer

    modem.send(serverAddress, SERVER_PORT, PROTOCOL, "request", NETWORK_KEY, requestId, CLIENT_PORT, data)
    writeDebugLog("📤 Запрос " .. action .. " (ID=" .. requestId .. ") отправлен на " .. serverAddress)
end

local function processChunk(requestId, chunk, total, index)
    local req = pendingRequests[requestId]
    if not req or req.completed then return end

    req.chunks[index] = chunk
    req.total = total
    req.received = req.received + 1

    if req.received == total then
        local full = table.concat(req.chunks)
        local ok, response = pcall(serialization.unserialize, full)
        req.completed = true
        pendingRequests[requestId] = nil
        if req.timer then event.cancel(req.timer) end

        if ok and type(response) == "table" then
            if req.callback then req.callback(response) end
        else
            if req.callback then req.callback({status="error", message="Повреждённый ответ"}) end
        end
    end
end

modem.open(CLIENT_PORT)

local function handlePush(action, data)
    writeDebugLog("📩 Push: " .. tostring(action))
    if action == "user_updated" then
        if data.player == currentPlayer then
            local user = data.user or {}
            coinBalance = user.balanceCoin or coinBalance
            emaBalance = user.balanceEma or emaBalance
            playerTransactions = user.transactions or playerTransactions
            playerAgreed = user.agreed or playerAgreed
            playerBanned = user.banned or false
            banReason = user.banReason or nil
            if currentScreen == "shop" then
                drawAccountInfo()
                drawBalanceLine(3,1)
            end
        end
    elseif action == "catalog_updated" then
        if data.catalog == "buy" or data.catalog == "sell" then
            loadCatalog(data.catalog, true)
        end
    elseif action == "maintenance_changed" then
        shopPaused = data.maintenance == true
        if shopPaused then
            showTempMessage("Магазин закрыт на техобслуживание", 3)
            currentScreen = "menu"
            drawMainMenu()
        end
    end
end

local function sendRequestSync(action, payload, timeout)
    timeout = timeout or 5
    local done = false
    local result = nil

    sendRequest(action, payload, function(response)
        result = response
        done = true
    end)

    local start = computer.uptime()
    while not done and computer.uptime() - start < timeout do
        event.pull(0.05)
    end

    if not done then
        return {status="error", message="Таймаут ожидания ответа"}
    end
    return result or {status="error", message="Нет ответа"}
end

-- ============================================================
--  ОСНОВНЫЕ ФУНКЦИИ КЛИЕНТА
-- ============================================================

local currentPlayer = nil
local coinBalance = 0.0
local emaBalance = 0.0
local playerTransactions = 0
local playerRegDate = ""
local playerAgreed = false
local playerBanned = false
local banReason = ""
local shopPaused = false

-- Каталоги
local buyCatalog = {}
local sellCatalog = {}
local catalogMode = "buy"
local buyVersion = 0
local sellVersion = 0

-- UI
local WIDTH, HEIGHT = gpu.getResolution()
local maxW, maxH = gpu.maxResolution()
if WIDTH < maxW or HEIGHT < maxH then
    gpu.setResolution(maxW, maxH)
    WIDTH, HEIGHT = gpu.getResolution()
end

local C = {
    bg = 0x0C0C0C, white = 0xFFFFFF, gray = 0xAAAAAA, darkGray = 0x555555,
    green = 0x55FF55, yellow = 0xFFFF55, red = 0xFF5555, cyan = 0x55FFFF,
    selectedBg = 0x002440, selectedName = 0x00e6b1, star = 0x077d42,
    vipTitle = 0x0c9a76, underLine = 0x428A72, mainLine = 0x7FFFD4,
    sectionLine = 0x27BDEC, headerBg = 0x1A2D33, notFound = 0xF50016,
    buttonBuy = 0x0a502d, buttonClear = 0x8b1a1a, buttonSales = 0x1a5a6b,
    inputBg = 0x1a1a1a, inputFg = 0xFFFFFF, accent = 0x0c9a76, frame = 0x27BDEC,
}

local function setBG(c) gpu.setBackground(c) end
local function setFG(c) gpu.setForeground(c) end
local function fill(x, y, w, h, c) setBG(c) gpu.fill(x, y, w, h, " ") end
local function text(x, y, str, fg, bg)
    if bg then setBG(bg) end
    if fg then setFG(fg) end
    gpu.set(x, y, str)
end
local function sectionHeader(x, y, w, title, lineColor, titleColor)
    lineColor = lineColor or C.sectionLine
    titleColor = titleColor or C.white
    setBG(C.bg) setFG(lineColor)
    gpu.set(x, y, string.rep("-", w))
    setFG(titleColor)
    gpu.set(x + 1, y, title)
end
local function truncate(str, maxLen)
    if #str <= maxLen then return str end
    return str:sub(1, maxLen - 3) .. "..."
end
local function lowerText(str)
    str = tostring(str or "")
    if unicode.lower then return unicode.lower(str) end
    return string.lower(str)
end
local function trimNumber(value, decimals)
    local n = tonumber(value) or 0
    if n == math.floor(n) then return tostring(math.floor(n)) end
    local result = string.format("%." .. tostring(decimals or 4) .. "f", n)
    result = result:gsub("0+$", ""):gsub("%.$", "")
    return result
end
local function formatQuantity(value)
    local n = tonumber(value) or 0
    if n >= 1000000000 then return trimNumber(n / 1000000000, 1) .. "b" end
    if n >= 1000000 then return trimNumber(n / 1000000, 1) .. "m" end
    if n >= 1000 then return trimNumber(n / 1000, 1) .. "k" end
    return tostring(math.floor(n))
end
local function sortableName(name)
    if not name then return "" end
    local lower = string.lower(name)
    local result = lower:gsub("(%d+)", function(d) return string.format("%08d", tonumber(d)) end)
    return result
end

-- Разметка UI
local TOP_H = 3
local BOT_H = 3
local MAIN_Y = 4
local MAIN_H = HEIGHT - TOP_H - BOT_H
local LEFT_W = math.floor(WIDTH * 0.60)
local SCROLL_X = LEFT_W - 2
local SEPARATOR1 = LEFT_W
local SEPARATOR2 = LEFT_W + 1
local LIST_X = 2
local LIST_Y = MAIN_Y + 3
local LIST_H = MAIN_H - 4
local LIST_W = SCROLL_X - 3
local COL_NAME_X = 3
local COL_ME_X = SCROLL_X - 26
local COL_COINA_X = SCROLL_X - 16
local COL_EMA_X = SCROLL_X - 7
local RIGHT_INNER_X = LEFT_W + 3
local RIGHT_INNER_W = WIDTH - RIGHT_INNER_X - 1
local INFO_Y = MAIN_Y + 1
local QTY_Y = INFO_Y + 8
local TOTAL_Y = QTY_Y + 5
local BTN_Y = TOTAL_Y + 2
local ACC_Y = BTN_Y + 3
local BOT_Y = HEIGHT - 2

local allItems = {}
local items = {}
local selectedIndex = 1
local scrollOffset = 0
local quantity = ""
local searchQuery = ""
local searchFocused = false
local qtyFocused = false

-- PIM и ME функции
local function getPimAddr()
    for addr in component.list("pim") do return addr end
    return nil
end

local function getMeAddr()
    for addr in component.list("me_interface") do return addr end
    return nil
end

local function getPimProxy()
    local addr = getPimAddr()
    if not addr then return nil end
    local ok, proxy = pcall(component.proxy, addr)
    if ok then return proxy end
    return nil
end

local function getPlayerOnPim()
    local pim = getPimProxy()
    if not pim then return nil end
    local methods = {"getPlayer", "getPlayerName", "getUsername"}
    for _, method in ipairs(methods) do
        if type(pim[method]) == "function" then
            local ok, name = pcall(pim[method], pim)
            if ok and name and name ~= "" then return name end
        end
    end
    return nil
end

local function isPlayerOnPim()
    local pim = getPimProxy()
    if not pim then return false end
    if type(pim.getInventorySize) == "function" then
        local ok, size = pcall(pim.getInventorySize, pim)
        if ok and tonumber(size) and tonumber(size) > 0 then return true end
    end
    return getPlayerOnPim() ~= nil
end

local function scanPlayerInventory(targetName, targetDamage)
    local pim = getPimProxy()
    if not pim then return 0 end
    targetDamage = tonumber(targetDamage) or 0
    local total = 0
    for slot = 1, 36 do
        local stack = nil
        if type(pim.getStackInSlot) == "function" then
            local ok, st = pcall(pim.getStackInSlot, pim, slot)
            if ok then stack = st end
        end
        if stack then
            local qty = tonumber(stack.size or stack.qty or 0) or 0
            if qty > 0 then
                local name = stack.name or stack.id or ""
                local damage = tonumber(stack.damage or stack.dmg or 0) or 0
                if name:lower() == targetName:lower() and damage == targetDamage then
                    total = total + qty
                end
            end
        end
    end
    return total
end

local function extractToME(targetName, amount, targetDamage)
    local pim = getPimProxy()
    if not pim or amount <= 0 then return 0 end
    targetDamage = tonumber(targetDamage) or 0
    local extracted = 0
    for slot = 1, 36 do
        if extracted >= amount then break end
        local stack = nil
        if type(pim.getStackInSlot) == "function" then
            local ok, st = pcall(pim.getStackInSlot, pim, slot)
            if ok then stack = st end
        end
        if stack then
            local qty = tonumber(stack.size or stack.qty or 0) or 0
            if qty > 0 then
                local name = stack.name or stack.id or ""
                local damage = tonumber(stack.damage or stack.dmg or 0) or 0
                if name:lower() == targetName:lower() and damage == targetDamage then
                    local toTake = math.min(qty, amount - extracted)
                    if toTake > 0 and type(pim.pushItem) == "function" then
                        local ok, moved = pcall(pim.pushItem, pim, "down", slot, toTake)
                        if ok and tonumber(moved) and tonumber(moved) > 0 then
                            extracted = extracted + tonumber(moved)
                        end
                    end
                end
            end
        end
    end
    return extracted
end

local function getMEQuantity(internalName, damage)
    local me = getMeAddr()
    if not me then return 0 end
    local ok, items = pcall(component.invoke, me, "getItemsInNetwork")
    if not ok or type(items) ~= "table" then return 0 end
    damage = tonumber(damage) or 0
    local total = 0
    for _, item in ipairs(items) do
        if item.name == internalName and (tonumber(item.damage) or 0) == damage then
            total = total + (tonumber(item.size) or 0)
        end
    end
    return total
end

-- Загрузка каталога
local function loadCatalog(mode, callback)
    local action = "get_catalog"
    local payload = { catalog = mode }
    sendRequest(action, payload, function(response)
        if response.status == "ok" then
            local data = response.data
            if mode == "buy" then
                buyCatalog = data.catalog or {}
                buyVersion = data.version or 0
                if catalogMode == "buy" then
                    allItems = buyCatalog
                    filterItems()
                    if currentScreen == "shop" then redrawAll() end
                end
            else
                sellCatalog = data.sellItems or {}
                sellVersion = data.version or 0
                if catalogMode == "sell" then
                    allItems = sellCatalog
                    filterItems()
                    if currentScreen == "shop" then redrawAll() end
                end
            end
            if callback then callback(true) end
        else
            if callback then callback(false, response.message) end
        end
    end)
end

local function openSession(playerName)
    local payload = { name = playerName }
    local response = sendRequestSync("session_open", payload, 5)
    if response.status == "ok" then
        local data = response.data
        local user = data.user or {}
        currentPlayer = user.name or playerName
        coinBalance = user.balanceCoin or 0
        emaBalance = user.balanceEma or 0
        playerTransactions = user.transactions or 0
        playerRegDate = user.regDate or ""
        playerAgreed = user.agreed or false
        playerBanned = user.banned or false
        banReason = user.banReason or ""
        shopPaused = data.maintenance or false
        return true
    else
        return false, response.message
    end
end

-- Покупка/продажа
local function performPurchase(item, qty)
    if not currentPlayer or qty <= 0 then return false, "Некорректные данные" end
    if playerBanned then return false, "Вы забанены" end
    if shopPaused then return false, "Магазин на паузе" end

    local stock = getMEQuantity(item.internalName, item.damage)
    if stock < qty then return false, "Недостаточно товара на складе (в ME)" end

    local txid = "BUY-" .. tostring(os.time()) .. tostring(math.random(1000,9999))
    local payload = {
        name = currentPlayer,
        transactionId = txid,
        item = item.internalName,
        damage = tonumber(item.damage) or 0,
        qty = qty
    }
    local response = sendRequestSync("purchase", payload, 5)
    if response.status ~= "ok" then
        return false, response.message or "Ошибка покупки"
    end

    local data = response.data
    local meAddr = getMeAddr()
    if not meAddr then
        sendRequestSync("adjust_purchase", { transactionId = txid, deliveredQty = 0 }, 3)
        return false, "ME-интерфейс не найден"
    end

    local id = item.internalName
    if not id:find(":") then id = "minecraft:" .. id end
    local fingerprint = { id = id, dmg = tonumber(item.damage) or 0 }
    local maxStack = 64
    local ok, detail = pcall(component.invoke, meAddr, "getItemDetail", item.internalName, item.damage)
    if ok and detail and detail.maxSize then maxStack = detail.maxSize end

    local remaining = qty
    local delivered = 0
    while remaining > 0 do
        local toTake = math.min(remaining, maxStack)
        local success, result = pcall(component.invoke, meAddr, "exportItem", fingerprint, "up", toTake)
        local got = 0
        if success then
            if type(result) == "number" then got = result
            elseif type(result) == "boolean" and result == true then got = toTake
            elseif type(result) == "table" then
                got = tonumber(result.size or result.count or result.amount) or 0
            end
        end
        if got > 0 then
            delivered = delivered + got
            remaining = remaining - got
        else
            break
        end
    end

    if delivered < qty then
        local adjResponse = sendRequestSync("adjust_purchase", { transactionId = txid, deliveredQty = delivered }, 3)
        if adjResponse.status == "ok" then
            coinBalance = adjResponse.data.balanceCoin or coinBalance
            emaBalance = adjResponse.data.balanceEma or emaBalance
            playerTransactions = adjResponse.data.transactions or playerTransactions
            return true, "Выдано частично: " .. delivered .. " из " .. qty
        else
            return false, "Ошибка корректировки: " .. (adjResponse.message or "неизвестно")
        end
    else
        coinBalance = data.balanceCoin or coinBalance
        emaBalance = data.balanceEma or emaBalance
        playerTransactions = data.transactions or playerTransactions
        sendRequest("finalize_purchase", { transactionId = txid }, function() end)
        return true, "Успешно"
    end
end

local function performSell(item, qty)
    if not currentPlayer or qty <= 0 then return false, "Некорректные данные" end
    if playerBanned then return false, "Вы забанены" end
    if shopPaused then return false, "Магазин на паузе" end

    local inventoryQty = scanPlayerInventory(item.internalName, item.damage)
    if inventoryQty < qty then return false, "Недостаточно предметов в инвентаре" end

    local extracted = extractToME(item.internalName, qty, item.damage)
    if extracted == 0 then return false, "Не удалось изъять предметы" end

    local txid = "SELL-" .. tostring(os.time()) .. tostring(math.random(1000,9999))
    local payload = {
        name = currentPlayer,
        transactionId = txid,
        item = item.internalName,
        damage = tonumber(item.damage) or 0,
        qty = extracted
    }
    local response = sendRequestSync("sell", payload, 5)
    if response.status == "ok" then
        local data = response.data
        coinBalance = data.balanceCoin or coinBalance
        emaBalance = data.balanceEma or emaBalance
        playerTransactions = data.transactions or playerTransactions
        return true, "Успешно"
    else
        return false, response.message or "Ошибка продажи"
    end
end

-- UI функции
local function filterItems()
    items = {}
    if searchQuery == "" then
        for i, v in ipairs(allItems) do items[i] = v end
    else
        local q = lowerText(searchQuery)
        for _, v in ipairs(allItems) do
            if lowerText(v.displayName or v.name or ""):find(q, 1, true) then
                items[#items + 1] = v
            end
        end
    end
    selectedIndex = 1
    scrollOffset = 0
end

local function drawBackground()
    fill(1, 1, WIDTH, HEIGHT, C.bg)
end

local function drawTopBar()
    fill(1, 1, WIDTH, 3, 0x0A0A0A)
    local title = "VIP-SHOP"
    text(math.floor((WIDTH - #title) / 2) + 1, 1, title, C.vipTitle, 0x0A0A0A)
    setFG(C.underLine)
    setBG(0x0A0A0A)
    gpu.set(1, 2, string.rep("=", WIDTH))
    local searchW = 40
    local searchX = 2
    local searchY = 3
    setFG(C.frame)
    setBG(C.bg)
    gpu.set(searchX - 1, searchY, "[" .. string.rep(" ", searchW) .. "]")
    fill(searchX, searchY, searchW, 1, C.inputBg)
    if searchQuery == "" and not searchFocused then
        text(searchX + 1, searchY, "Поиск...", C.darkGray, C.inputBg)
    else
        text(searchX + 1, searchY, searchQuery, C.inputFg, C.inputBg)
    end
    local clearX = searchX + searchW + 2
    setBG(C.buttonClear)
    setFG(C.white)
    gpu.fill(clearX, searchY, 11, 1, " ")
    gpu.set(clearX + 1, searchY, "[ Стереть ]")
end

local function drawMainFrames()
    setBG(C.bg)
    setFG(C.mainLine)
    gpu.set(1, MAIN_Y, "+" .. string.rep("=", WIDTH - 2) .. "+")
    for y = MAIN_Y + 1, MAIN_Y + MAIN_H - 2 do
        gpu.set(1, y, "|")
        gpu.set(WIDTH, y, "|")
    end
    gpu.set(1, MAIN_Y + MAIN_H - 1, "+" .. string.rep("=", WIDTH - 2) .. "+")
end

local function drawLeftHeader()
    sectionHeader(2, MAIN_Y + 1, LEFT_W - 3, "КАТАЛОГ ТОВАРОВ", C.mainLine, C.white)
    local colY = MAIN_Y + 2
    fill(2, colY, LEFT_W - 3, 1, C.headerBg)
    text(COL_NAME_X, colY, "ТОВАР", C.white, C.headerBg)
    text(COL_ME_X, colY, "В ME", C.white, C.headerBg)
    text(COL_COINA_X, colY, "COINA", C.white, C.headerBg)
    text(COL_EMA_X, colY, "EMA", C.white, C.headerBg)
end

local function drawSeparator()
    setBG(C.bg)
    setFG(C.mainLine)
    for y = MAIN_Y + 1, MAIN_Y + MAIN_H - 2 do
        gpu.set(SEPARATOR1, y, "|")
        gpu.set(SEPARATOR2, y, "|")
    end
    gpu.set(SEPARATOR1, MAIN_Y, "+")
    gpu.set(SEPARATOR2, MAIN_Y, "+")
    gpu.set(SEPARATOR1, MAIN_Y + MAIN_H - 1, "+")
    gpu.set(SEPARATOR2, MAIN_Y + MAIN_H - 1, "+")
end

local function drawScrollbar()
    setBG(C.bg)
    setFG(C.darkGray)
    for y = LIST_Y, LIST_Y + LIST_H - 1 do
        gpu.set(SCROLL_X, y, " ")
    end
    local maxScroll = math.max(0, #items - LIST_H)
    local thumbH = math.max(3, math.floor(LIST_H * 0.25))
    local thumbY = LIST_Y
    if maxScroll > 0 then
        thumbY = LIST_Y + math.floor((scrollOffset / maxScroll) * (LIST_H - thumbH))
    end
    setBG(C.accent)
    for i = 0, thumbH - 1 do
        local yy = thumbY + i
        if yy >= LIST_Y and yy <= LIST_Y + LIST_H - 1 then
            gpu.set(SCROLL_X, yy, " ")
        end
    end
    setBG(C.bg)
end

local function drawItemRow(index, y)
    local item = items[index]
    if not item then return end
    local isSelected = (index == selectedIndex)
    if isSelected then
        fill(LIST_X, y, LIST_W, 1, C.selectedBg)
    else
        fill(LIST_X, y, LIST_W, 1, C.bg)
    end
    local nameColor = isSelected and C.selectedName or C.white
    local meColor = item.star and C.green or C.red
    local coinaColor = C.yellow
    local emaColor = C.cyan
    if isSelected then
        text(COL_NAME_X, y, "> ", C.selectedName, C.selectedBg)
    else
        if item.star then
            text(COL_NAME_X, y, "* ", C.star, C.bg)
        else
            text(COL_NAME_X, y, "- ", C.darkGray, C.bg)
        end
    end
    local maxNameLen = COL_ME_X - COL_NAME_X - 2
    local displayName = truncate(item.displayName or item.name or "", maxNameLen - 2)
    text(COL_NAME_X + 2, y, displayName, nameColor, isSelected and C.selectedBg or C.bg)
    local meQty = getMEQuantity(item.internalName, item.damage)
    text(COL_ME_X, y, tostring(meQty), meColor, isSelected and C.selectedBg or C.bg)
    text(COL_COINA_X, y, trimNumber(item.priceCoin or 0, 2), coinaColor, isSelected and C.selectedBg or C.bg)
    text(COL_EMA_X, y, trimNumber(item.priceEma or 0, 2), emaColor, isSelected and C.selectedBg or C.bg)
end

local function drawProductList()
    fill(LIST_X, LIST_Y, LIST_W, LIST_H, C.bg)
    if #items == 0 then
        local msg = "ПО ТВОЕМУ ЗАПРОСУ, НИЧЕГО НЕ НАЙДЕНО!"
        local visualLen = 35
        local mx = LIST_X + math.floor((LIST_W - visualLen) / 2)
        local my = LIST_Y + math.floor(LIST_H / 2)
        text(mx, my, msg, C.notFound, C.bg)
        return
    end
    local startIdx = scrollOffset + 1
    local endIdx = math.min(#items, startIdx + LIST_H - 1)
    for i = startIdx, endIdx do
        drawItemRow(i, LIST_Y + (i - startIdx))
    end
end

local function drawInfoBlock()
    fill(RIGHT_INNER_X, INFO_Y, RIGHT_INNER_W, 7, C.bg)
    sectionHeader(RIGHT_INNER_X, INFO_Y, RIGHT_INNER_W, "ИНФО", C.sectionLine, C.white)
    local item = items[selectedIndex]
    if not item then return end
    local maxLen = RIGHT_INNER_W - 8
    local y = INFO_Y + 2
    text(RIGHT_INNER_X, y, "Товар: " .. truncate(item.displayName or item.name or "", maxLen), C.white, C.bg)
    y = y + 1
    local meQty = getMEQuantity(item.internalName, item.damage)
    text(RIGHT_INNER_X, y, "В ME : " .. meQty, C.green, C.bg)
    y = y + 1
    text(RIGHT_INNER_X, y, "COINA: " .. trimNumber(item.priceCoin or 0, 2), C.yellow, C.bg)
    y = y + 1
    text(RIGHT_INNER_X, y, "EMA  : " .. trimNumber(item.priceEma or 0, 2), C.cyan, C.bg)
end

local function drawQuantitySection()
    fill(RIGHT_INNER_X, QTY_Y, RIGHT_INNER_W, 9, C.bg)
    sectionHeader(RIGHT_INNER_X, QTY_Y, RIGHT_INNER_W, "Поле для количества", C.sectionLine, C.white)
    local fieldY = QTY_Y + 2
    setFG(C.frame)
    setBG(C.bg)
    gpu.set(RIGHT_INNER_X, fieldY, "[" .. string.rep(" ", RIGHT_INNER_W - 2) .. "]")
    fill(RIGHT_INNER_X + 1, fieldY, RIGHT_INNER_W - 2, 1, C.inputBg)
    if quantity == "" then
        text(RIGHT_INNER_X + 2, fieldY, "Введите количество...", C.darkGray, C.inputBg)
    else
        text(RIGHT_INNER_X + 2, fieldY, quantity, C.inputFg, C.inputBg)
    end
    local item = items[selectedIndex]
    local qty = tonumber(quantity) or 0
    local totalCoina = 0
    local totalEma = 0
    if item then
        totalCoina = qty * (tonumber(item.priceCoin) or 0)
        totalEma = qty * (tonumber(item.priceEma) or 0)
    end
    text(RIGHT_INNER_X, TOTAL_Y, string.format("Итог: COINA: %s | EMA: %s", trimNumber(totalCoina, 2), trimNumber(totalEma, 2)), C.yellow, C.bg)
    local btnW = 12
    local gap = 2
    setBG(C.buttonBuy)
    setFG(C.white)
    gpu.fill(RIGHT_INNER_X, BTN_Y, btnW, 1, " ")
    gpu.set(RIGHT_INNER_X + 1, BTN_Y, "[ Купить ]")
    setBG(C.buttonClear)
    setFG(C.white)
    gpu.fill(RIGHT_INNER_X + btnW + gap, BTN_Y, btnW, 1, " ")
    gpu.set(RIGHT_INNER_X + btnW + gap + 1, BTN_Y, "[ Стереть ]")
end

local function drawAccountInfo()
    fill(RIGHT_INNER_X, ACC_Y, RIGHT_INNER_W, 8, C.bg)
    sectionHeader(RIGHT_INNER_X, ACC_Y, RIGHT_INNER_W, "Информация Аккаунта", C.sectionLine, C.white)
    local y = ACC_Y + 2
    text(RIGHT_INNER_X, y, "НИК      : " .. (currentPlayer or "Неизвестно"), C.white, C.bg)
    y = y + 1
    text(RIGHT_INNER_X, y, "Баланс   : " .. trimNumber(coinBalance, 2) .. " COINA | " .. trimNumber(emaBalance, 2) .. " EMA", C.yellow, C.bg)
    y = y + 1
    text(RIGHT_INNER_X, y, "Регистрация: " .. playerRegDate, C.gray, C.bg)
    y = y + 1
    text(RIGHT_INNER_X, y, "Транзакции: " .. playerTransactions, C.cyan, C.bg)
end

local function drawRightPanel()
    drawInfoBlock()
    drawQuantitySection()
    drawAccountInfo()
end

local function drawBottomBar()
    fill(1, BOT_Y, WIDTH, 2, 0x0A0A0A)
    setFG(C.mainLine)
    setBG(C.bg)
    gpu.set(1, BOT_Y - 1, "+" .. string.rep("=", WIDTH - 2) .. "+")
    local btnW = 14
    local gap = 2
    local leftMargin = 2
    local buyX = leftMargin
    local salesX = buyX + btnW + gap
    setBG(C.buttonBuy)
    setFG(C.white)
    gpu.fill(buyX, BOT_Y, btnW, 1, " ")
    gpu.set(buyX + 2, BOT_Y, "[ Покупки ]")
    setBG(C.buttonSales)
    setFG(C.white)
    gpu.fill(salesX, BOT_Y, btnW, 1, " ")
    gpu.set(salesX + 2, BOT_Y, "[ Продажи ]")
end

local function drawBottomBorder()
    setFG(C.mainLine)
    setBG(C.bg)
    gpu.set(1, HEIGHT, "+" .. string.rep("=", WIDTH - 2) .. "+")
end

local function redrawAll()
    drawBackground()
    drawTopBar()
    drawMainFrames()
    drawLeftHeader()
    drawProductList()
    drawScrollbar()
    drawRightPanel()
    drawBottomBar()
    drawBottomBorder()
    drawSeparator()
end

local function selectItem(index)
    if #items == 0 then return end
    if index < 1 then index = 1 end
    if index > #items then index = #items end
    selectedIndex = index
    if selectedIndex - 1 < scrollOffset then
        scrollOffset = selectedIndex - 1
    elseif selectedIndex > scrollOffset + LIST_H then
        scrollOffset = selectedIndex - LIST_H
    end
    quantity = ""
    drawProductList()
    drawScrollbar()
    drawRightPanel()
end

local function scroll(delta)
    local maxScroll = math.max(0, #items - LIST_H)
    scrollOffset = math.max(0, math.min(maxScroll, scrollOffset + delta))
    drawProductList()
    drawScrollbar()
end

-- ============================================================
--  ОБРАБОТЧИКИ СОБЫТИЙ
-- ============================================================

local function handleClick(x, y)
    searchFocused = false
    qtyFocused = false
    if x >= LIST_X and x <= LIST_X + LIST_W and y >= LIST_Y and y <= LIST_Y + LIST_H - 1 then
        local row = y - LIST_Y
        local index = scrollOffset + row + 1
        if index >= 1 and index <= #items then
            selectItem(index)
        end
        return
    end
    local searchW = 40
    local clearX = 2 + searchW + 2
    if y == 3 and x >= clearX and x < clearX + 11 then
        searchQuery = ""
        filterItems()
        redrawAll()
        return
    end
    if y == 3 and x >= 2 and x <= 2 + searchW then
        searchFocused = true
        return
    end
    local fieldY = QTY_Y + 2
    if y == fieldY and x >= RIGHT_INNER_X and x <= RIGHT_INNER_X + RIGHT_INNER_W then
        qtyFocused = true
        return
    end
    local btnW = 12
    local gap = 2
    local clearQtyX = RIGHT_INNER_X + btnW + gap
    if y == BTN_Y and x >= clearQtyX and x < clearQtyX + btnW then
        quantity = ""
        drawQuantitySection()
        return
    end
    -- Кнопка покупки/продажи
    if y == BTN_Y and x >= RIGHT_INNER_X and x < RIGHT_INNER_X + btnW then
        local item = items[selectedIndex]
        if not item then return
        local qty = tonumber(quantity) or 0
        if qty <= 0 then
            text(RIGHT_INNER_X, BTN_Y+2, "Введите количество!", C.red, C.bg)
            return
        end
        local ok, msg
        if catalogMode == "sell" then
            ok, msg = performSell(item, qty)
        else
            ok, msg = performPurchase(item, qty)
        end
        if ok then
            text(RIGHT_INNER_X, BTN_Y+2, "Операция успешна!", C.green, C.bg)
            redrawAll()
        else
            text(RIGHT_INNER_X, BTN_Y+2, "Ошибка: " .. msg, C.red, C.bg)
        end
        return
    end
    -- Переключение режимов внизу
    if y == BOT_Y then
        if x >= buyX and x < buyX + btnW then
            catalogMode = "buy"
            allItems = buyCatalog
            filterItems()
            redrawAll()
        elseif x >= salesX and x < salesX + btnW then
            catalogMode = "sell"
            allItems = sellCatalog
            filterItems()
            redrawAll()
        end
    end
end

-- ============================================================
--  ОСНОВНОЙ ЦИКЛ
-- ============================================================

local currentScreen = "login"
local loginName = ""

local function drawLoginScreen()
    clear()
    setBG(C.bg)
    setFG(C.white)
    local title = "VIP-SHOP КЛИЕНТ"
    local titleX = math.floor((WIDTH - #title) / 2) + 1
    text(titleX, 8, title, C.vipTitle)
    text(math.floor((WIDTH - 15) / 2) + 1, 12, "Введите имя игрока:", C.white)
    setBG(C.inputBg)
    setFG(C.white)
    gpu.fill(20, 14, 40, 1, " ")
    text(21, 14, loginName, C.inputFg, C.inputBg)
    setFG(C.gray)
    text(math.floor((WIDTH - 25) / 2) + 1, 18, "Нажмите Enter для входа", C.gray)
end

local function handleLoginKey(char, code)
    if code == keyboard.keys.enter then
        if loginName == "" then return end
        local ok, err = openSession(loginName)
        if ok then
            currentScreen = "shop"
            loadCatalog("buy", function()
                loadCatalog("sell", function()
                    allItems = buyCatalog
                    catalogMode = "buy"
                    filterItems()
                    redrawAll()
                end)
            end)
        else
            text(20, 20, "Ошибка: " .. (err or "неизвестно"), C.red, C.bg)
        end
    elseif code == keyboard.keys.back then
        loginName = loginName:sub(1, -2)
        drawLoginScreen()
    elseif char and char >= 32 then
        loginName = loginName .. unicode.char(char)
        drawLoginScreen()
    end
end

-- ============================================================
--  ЗАПУСК
-- ============================================================
gpu.setResolution(80, 25)
gpu.setBackground(C.bg)

if not serverAddress then
    print("Ошибка: адрес сервера не задан")
    return
end

currentScreen = "login"
drawLoginScreen()

while true do
    local ev = { event.pull(0.5) }
    local name = ev[1]

    if name == "modem_message" then
        local _, _, port, protocol, kind, key, requestId, chunkIndex, total, chunk = table.unpack(ev)
        if port == SERVER_PORT and protocol == PROTOCOL and key == NETWORK_KEY then
            if kind == "chunk" then
                processChunk(requestId, chunk, total, chunkIndex)
            elseif kind == "push" then
                local action = ev[9]
                local dataStr = ev[10] or "{}"
                local ok, data = pcall(serialization.unserialize, dataStr)
                if ok and type(data) == "table" then
                    handlePush(action, data)
                end
            end
        end
    elseif name == "touch" then
        if currentScreen == "shop" then
            handleClick(ev[3], ev[4])
        end
    elseif name == "scroll" then
        if currentScreen == "shop" then
            local x, direction = ev[3], ev[5]
            if x >= LIST_X and x <= LIST_X + LIST_W + 2 then
                scroll(-direction)
            end
        end
    elseif name == "key_down" then
        local char, code = ev[3], ev[4]
        if currentScreen == "login" then
            handleLoginKey(char, code)
        elseif currentScreen == "shop" then
            if searchFocused then
                if code == keyboard.keys.enter or code == keyboard.keys.tab then
                    searchFocused = false
                elseif code == keyboard.keys.back then
                    searchQuery = searchQuery:sub(1, -2)
                    filterItems()
                    redrawAll()
                elseif char and char >= 32 then
                    if #searchQuery < 30 then
                        searchQuery = searchQuery .. unicode.char(char)
                        filterItems()
                        redrawAll()
                    end
                end
            elseif qtyFocused then
                if code == keyboard.keys.enter or code == keyboard.keys.tab then
                    qtyFocused = false
                elseif code == keyboard.keys.back then
                    quantity = quantity:sub(1, -2)
                    drawQuantitySection()
                elseif char and char >= 48 and char <= 57 then
                    if #quantity < 8 then
                        quantity = quantity .. string.char(char)
                        drawQuantitySection()
                    end
                end
            else
                if code == keyboard.keys.up then
                    selectItem(selectedIndex - 1)
                elseif code == keyboard.keys.down then
                    selectItem(selectedIndex + 1)
                elseif code == keyboard.keys.back then
                    quantity = quantity:sub(1, -2)
                    drawQuantitySection()
                elseif char and char >= 48 and char <= 57 then
                    if #quantity < 8 then
                        quantity = quantity .. string.char(char)
                        drawQuantitySection()
                    end
                elseif code == keyboard.keys.escape then
                    break
                end
            end
        end
    elseif name == "interrupted" then
        term.clear()
        print("Клиент закрыт")
        break
    end
end
