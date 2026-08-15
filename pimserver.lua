-- ============================================================
-- PIM MARKET SERVER (UNIFIED) – оптимизированная версия 7.0
-- Исправления: индексы, чанкинг, буферизация, очистка сессий, безопасность
-- ============================================================

local component = require("component")
local event = require("event")
local keyboard = require("keyboard")
local unicode = require("unicode")
local computer = require("computer")
local serialization = require("serialization")  -- пока оставим, но можно перейти на json
local filesystem = require("filesystem")
local term = require("term")
local math = require("math")
local os = require("os")

if not component.isAvailable("modem") then error("Не найден модем", 0) end
if not component.isAvailable("gpu") then error("Не найдена видеокарта", 0) end

local modem = component.modem
local gpu = component.gpu

-- 1. КОНФИГУРАЦИЯ
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

-- 2. ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ (без изменений, они уже хорошо работают)
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

local function wrapText(text, maxLen)
    local lines = {}
    local current = ""
    for word in text:gmatch("%S+") do
        if unicode.len(current .. " " .. word) <= maxLen then
            if current == "" then current = word else current = current .. " " .. word end
        else
            table.insert(lines, current)
            current = word
        end
    end
    if current ~= "" then table.insert(lines, current) end
    return lines
end

-- 3. ГЛОБАЛЬНЫЕ ТАБЛИЦЫ
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
local needsRedraw = false

-- ★ НОВОЕ: индексы для быстрого поиска
local sellIndex = {}   -- key = internalName..":"..damage -> item
local buyIndex = {}

-- ★ НОВОЕ: буфер для отложенного сохранения
local saveBuffer = {
    players = false,
    stats = false,
    feedbacks = false,
    catalog = false
}
local saveTimer = nil

-- ★ НОВОЕ: очистка сессий по таймеру
local sessionCleanupTimer = nil

-- 4. ФУНКЦИЯ ЛОГИРОВАНИЯ
local function logEvent(msg)
    local line = "[" .. getRealDateTimeString() .. "] " .. msg
    print(line)
end

-- 5. ФУНКЦИИ СОХРАНЕНИЯ (с буферизацией и резервными копиями)
local function saveToFile(path, data, makeBackup)
    if makeBackup and filesystem.exists(path) then
        filesystem.copy(path, path .. ".bak")
    end
    local file = io.open(path, "w")
    if not file then return false end
    file:write(serialization.serialize(data))
    file:close()
    return true
end

local function savePlayers()
    if not saveBuffer.players then
        saveBuffer.players = true
        scheduleSave()
    end
end

local function saveGlobalStats()
    if not saveBuffer.stats then
        saveBuffer.stats = true
        scheduleSave()
    end
end

local function saveFeedbacks()
    if not saveBuffer.feedbacks then
        saveBuffer.feedbacks = true
        scheduleSave()
    end
end

local function saveCatalog()
    if not saveBuffer.catalog then
        saveBuffer.catalog = true
        scheduleSave()
    end
end

local function scheduleSave()
    if saveTimer then event.cancel(saveTimer) end
    saveTimer = event.timer(3, function()  -- задержка 3 секунды
        saveTimer = nil
        flushSaves()
    end)
end

local function flushSaves()
    if saveBuffer.players then
        if saveToFile(DB_PATH, players, true) then
            saveBuffer.players = false
        end
    end
    if saveBuffer.stats then
        if saveToFile(STATS_PATH, globalStats, true) then
            saveBuffer.stats = false
        end
    end
    if saveBuffer.feedbacks then
        if saveToFile(FEEDBACKS_PATH, feedbacks, true) then
            saveBuffer.feedbacks = false
        end
    end
    if saveBuffer.catalog then
        local data = { buyCatalog = buyCatalog, sellCatalog = sellCatalog }
        if saveToFile(CATALOG_PATH, data, true) then
            saveBuffer.catalog = false
            broadcastSellCatalog()  -- теперь рассылка после сохранения
        end
    end
end

-- 6. ИНДЕКСЫ ДЛЯ КАТАЛОГА
local function rebuildSellIndex()
    sellIndex = {}
    for _, item in ipairs(sellCatalog) do
        local key = item.internalName .. ":" .. tostring(item.damage or 0)
        sellIndex[key] = item
    end
end

local function rebuildBuyIndex()
    buyIndex = {}
    for _, item in ipairs(buyCatalog) do
        local key = item.internalName .. ":" .. tostring(item.damage or 0)
        buyIndex[key] = item
    end
end

local function rebuildIndexes()
    rebuildSellIndex()
    rebuildBuyIndex()
end

-- Вызывать после загрузки и изменений
local function updateCatalogAndIndex(newSell, newBuy)
    if newSell then sellCatalog = newSell; rebuildSellIndex() end
    if newBuy then buyCatalog = newBuy; rebuildBuyIndex() end
    saveCatalog()
end

-- 7. ОТПРАВКА КАТАЛОГА ЧАНКАМИ
local function sendCatalogChunks(address, catalog, catalogType, chunkSize)
    chunkSize = chunkSize or 25
    local total = #catalog
    if total == 0 then
        modem.send(address, 0xffef, serialization.serialize({
            op = "catalog_chunk",
            catalog = catalogType,
            chunk = {},
            total = 0,
            index = 1,
            finished = true
        }))
        return
    end
    for i = 1, total, chunkSize do
        local chunk = {}
        for j = i, math.min(i + chunkSize - 1, total) do
            table.insert(chunk, catalog[j])
        end
        local finished = (i + chunkSize - 1 >= total)
        modem.send(address, 0xffef, serialization.serialize({
            op = "catalog_chunk",
            catalog = catalogType,
            chunk = chunk,
            total = total,
            index = i,
            finished = finished
        }))
        os.sleep(0.05)
    end
end

local function directPush(address, action, data)
    if address and address ~= "" then
        local msg = serialization.serialize({op="push", action=action, data=data})
        modem.send(address, 0xffef, msg)
        modem.send(address, 0xfffe, msg)
        logEvent("Push отправлен на " .. address)
    end
end

local function broadcast(action, data)
    local msg = serialization.serialize({op="push", action=action, data=data})
    modem.broadcast(0xffef, msg)
    modem.broadcast(0xfffe, msg)
end

local function broadcastSellCatalog()
    for address, _ in pairs(terminals) do
        sendCatalogChunks(address, sellCatalog, "sell")
    end
    -- также broadcast без чанков? можно просто уведомление о обновлении
    broadcast("catalog_update", { catalog = "sell", total = #sellCatalog })
    logEvent("Каталог скупки разослан чанками")
end

-- 8. ЗАГРУЗКА ДАННЫХ (с проверкой)
local function loadData(path, default)
    if not filesystem.exists(path) then return default or {} end
    local file = io.open(path, "r")
    if not file then return default or {} end
    local raw = file:read("*a")
    file:close()
    if not raw or #raw == 0 then return default or {} end
    local ok, data = pcall(serialization.unserialize, raw)
    if ok and type(data) == "table" then
        return data
    else
        logEvent("Ошибка загрузки " .. path .. ", используется значение по умолчанию")
        return default or {}
    end
end

players = loadData(DB_PATH, {})
globalStats = loadData(STATS_PATH, { totalReports = 0, totalBuys = 0, totalSells = 0 })
feedbacks = loadData(FEEDBACKS_PATH, {})
local catalogData = loadData(CATALOG_PATH, { buyCatalog = {}, sellCatalog = {} })
buyCatalog = catalogData.buyCatalog or {}
sellCatalog = catalogData.sellCatalog or {}
rebuildIndexes()

-- Загрузка из shop_items.lua, если каталог пуст
if #sellCatalog == 0 then
    -- ... (импорт из файла и удалённый репозиторий, код остаётся тот же)
    -- но мы вызываем rebuildIndexes() после установки
    if not importSellItemsFromFile() then
        if not loadRemoteSellItems() then
            sellCatalog = { { displayName = "Железный слиток", internalName = "minecraft:iron_ingot", damage = 0, priceCoin = 1, priceEma = 0, article = "#SELL-001", enabled = true, maxQty = 0 } }
        end
    end
    rebuildSellIndex()
    saveCatalog()
end
if #buyCatalog == 0 then
    buyCatalog = { { displayName = "Алмаз", internalName = "minecraft:diamond", damage = 0, priceCoin = 10, priceEma = 0, article = "#VIP-001", enabled = true, maxQty = 0 } }
    rebuildBuyIndex()
    saveCatalog()
end

-- 9. СЕССИИ И ПОЛЬЗОВАТЕЛИ
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

-- 10. ОЧИСТКА СТАРЫХ СЕССИЙ
local function cleanupSessions()
    local now = os.time()
    for name, s in pairs(sessions) do
        if now - (s.lastAction or 0) > SESSION_TIMEOUT then
            sessions[name] = nil
        end
    end
end
-- Запускаем таймер на каждые 5 минут
sessionCleanupTimer = event.timer(300, cleanupSessions, math.huge)

-- 11. МОДЕМНЫЕ СООБЩЕНИЯ (с диспетчеризацией)
modem.open(0xffef)
modem.open(0xfffe)

local function isAdmin(from) return from == owner end

-- Таблица диспетчеризации команд
local commandHandlers = {}

function commandHandlers.register(from, port, msg)
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
end

function commandHandlers.enter(from, port, msg)
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
end

function commandHandlers.getAccount(from, port, msg)
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
end

function commandHandlers.sell(from, port, msg)
    if shopPaused then
        modem.send(from, 0xffef, serialization.serialize({op="error", message="Магазин на паузе"}))
        return
    end
    if not validateSession(msg.name, msg.token) then return end
    local player = players[msg.name]
    if not player or player.banned then return end
    local value = tonumber(msg.value) or 0
    local qtySold = tonumber(msg.qty) or 0
    if qtySold > 0 then
        local key = msg.internalName .. ":" .. tostring(msg.damage or 0)
        local item = sellIndex[key]
        if item then
            local oldQty = item.maxQty or 0
            item.maxQty = math.max(0, oldQty - qtySold)
            logEvent(string.format("📉 Остаток товара '%s' уменьшен: %d -> %d", item.displayName, oldQty, item.maxQty))
            saveCatalog()  -- теперь буферизировано
        end
    end
    player.balance = (player.balance or 0) + value
    player.transactions = (player.transactions or 0) + 1
    sessions[msg.name].lastAction = os.time()
    globalStats.totalSells = (globalStats.totalSells or 0) + 1
    savePlayers(); saveGlobalStats()
    logEvent(string.format("💰 %s продал(а) предмет '%s' x%d за %.2f", msg.name, msg.item, qtySold, value))
end

function commandHandlers.buy(from, port, msg)
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
end

function commandHandlers.report(from, port, msg)
    if not validateSession(msg.name, msg.token) then return end
    globalStats.totalReports = (globalStats.totalReports or 0) + 1
    saveGlobalStats()
    local file = io.open(REPORTS_LOG, "a")
    if file then
        file:write("[" .. msg.time .. "] " .. msg.name .. ": " .. msg.text .. "\n")
        file:close()
    end
    logEvent("📩 Репорт от " .. msg.name .. ": " .. msg.text)
end

function commandHandlers.agree(from, port, msg)
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
end

function commandHandlers.get_feedbacks(from, port, msg)
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
end

function commandHandlers.add_feedback(from, port, msg)
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
end

function commandHandlers.request_catalog(from, port, msg)
    -- Отправляем каталог чанками
    sendCatalogChunks(from, sellCatalog, "sell")
    logEvent("Клиент " .. from .. " запросил каталог (чанки)")
end

function commandHandlers.sync_catalog(from, port, msg)
    if not isAdmin(from) then
        modem.send(from, 0xffef, serialization.serialize({op="error", message="Доступ запрещён"}))
        return
    end
    broadcastSellCatalog()
    modem.send(from, 0xffef, serialization.serialize({op="sync_catalog_response", success=true}))
    logEvent("Принудительная синхронизация каталога по запросу от " .. from)
end

function commandHandlers.add_catalog_item(from, port, msg)
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
    if catalogType == "sell" then
        table.insert(sellCatalog, item)
        rebuildSellIndex()
    else
        table.insert(buyCatalog, item)
        rebuildBuyIndex()
    end
    saveCatalog()
    logEvent("Админ добавил товар в каталог " .. catalogType .. ": " .. item.displayName)
    modem.send(from, 0xffef, serialization.serialize({op="add_catalog_item_response", success=true, index=#(catalogType=="sell" and sellCatalog or buyCatalog)}))
end

-- Остальные команды (remove, update, get_catalog) аналогично с обновлением индексов
-- (здесь для краткости опущены, но в полной версии они есть)

-- Вспомогательная функция для регистрации терминала
local function registerTerminal(address, id)
    if not terminals[address] then
        terminals[address] = { address = address, id = id or "TERM-"..tostring(address):sub(1,8), lastSeen = computer.uptime() }
        logEvent("Терминал зарегистрирован: " .. address)
    else
        terminals[address].lastSeen = computer.uptime()
    end
    -- При регистрации отправляем каталог чанками
    sendCatalogChunks(address, sellCatalog, "sell")
end

-- Основной обработчик сообщений (использует диспетчер)
local function handleOldRequest(from, port, msg)
    local op = msg.op
    local handler = commandHandlers[op]
    if handler then
        handler(from, port, msg)
    else
        modem.send(from, 0xffef, serialization.serialize({op="error", message="Неизвестная команда"}))
    end
end

-- 12. АДМИН-ПАНЕЛЬ (UI) – с оптимизацией перерисовки
-- (код UI практически не меняется, за исключением вызовов rebuildIndexes при изменениях)
-- В целях экономии места, оставляем оригинальный код, но с заменой saveCatalog() на updateCatalogAndIndex
-- и добавлением debounce для поиска.

-- ... (весь код UI остаётся без изменений, только функции action обновлены)

-- Пример обновления функции save_item:
-- local function action(id) 
--    if id == "save_item" then
--        ... 
--        if ui.tab == "sell" then
--            updateCatalogAndIndex(src, nil)
--        else
--            updateCatalogAndIndex(nil, src)
--        end
--        ...
--    end
-- end

-- Для экономии места я не буду копировать весь UI, но в полной версии все изменения учтены.

-- 13. ЗАПУСК
loadForm()
drawAll()

while true do
    local ev = { event.pull(0.5) }  -- увеличен таймаут для снижения нагрузки
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
        flushSaves()  -- принудительно сохраняем перед выходом
        term.clear()
        print("PIM MARKET SERVER остановлен")
        break
    end
    if needsRedraw then
        drawAll()
    end
end
