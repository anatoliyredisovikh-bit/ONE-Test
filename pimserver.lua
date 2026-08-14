-- ============================================================
-- PIM MARKET SERVER – Центральный сервер экономики + админ-панель.
-- Версия 2.0 (на базе VIP‑SHOP, с отзывами, репортами и журналом)
-- Интернет-карта не используется.
-- ============================================================

local component = require("component")
local event = require("event")
local keyboard = require("keyboard")
local unicode = require("unicode")
local computer = require("computer")
local serialization = require("serialization")
local filesystem = require("filesystem")
local term = require("term")

if not component.isAvailable("modem") then error("Не найден модем", 0) end
if not component.isAvailable("gpu") then error("Не найдена видеокарта", 0) end

local modem = component.modem
local gpu = component.gpu

-- Конфигурация
local PROTOCOL = "PIM-MODEM-1"
local NETWORK_KEY = "PIM_SHOP_SECRET_2026"
local SERVER_PORT = 3410
local CLIENT_PORT = 3411
local CHUNK_SIZE = 6000
local OFFLINE_AFTER = 45

local DATA_DIR = "/home/pim_data"
local STATE_FILE = DATA_DIR .. "/state.db"
local BACKUP_FILE = DATA_DIR .. "/state.backup.db"
local MAX_TRANSACTIONS = 10000
local MAX_OPERATIONS = 20000

modem.open(SERVER_PORT)

-- Настройки экрана
local WIDTH, HEIGHT = gpu.getResolution()
local maxW, maxH = gpu.maxResolution()
if maxW and maxH and (WIDTH < maxW or HEIGHT < maxH) then
    gpu.setResolution(maxW, maxH)
    WIDTH, HEIGHT = gpu.getResolution()
end

-- Цветовая палитра
local C = {
    bg = 0x0C0C0C,
    panel = 0x11191D,
    header = 0x0A0A0A,
    line = 0x27BDEC,
    accent = 0x0C9A76,
    white = 0xFFFFFF,
    gray = 0xAAAAAA,
    dark = 0x555555,
    green = 0x55FF55,
    yellow = 0xFFAA00,
    red = 0xFF5555,
    cyan = 0x55FFFF,
    selected = 0x002440,
    input = 0x1A1A1A,
    button = 0x0A502D,
    alt = 0x1A5A6B,
    danger = 0x8B1A1A,
    pause = 0x8A5A00,
    orange = 0xFF8800,
    magenta = 0xFF44FF,
}

-- Вспомогательные функции
local function ulen(v) return unicode.len(tostring(v or "")) end
local function usub(v, a, b) return unicode.sub(tostring(v or ""), a, b) end
local function trunc(v, w) v = tostring(v or ""); w = math.max(1, tonumber(w) or 1); if ulen(v) <= w then return v end; return w <= 1 and usub(v, 1, w) or usub(v, 1, w - 1) .. "…" end
local function fill(x, y, w, h, bg, ch) if w <= 0 or h <= 0 then return end; gpu.setBackground(bg or C.bg); gpu.fill(x, y, w, h, ch or " ") end
local function write(x, y, v, fg, bg) if y < 1 or y > HEIGHT or x > WIDTH then return end; v = tostring(v or ""); if x < 1 then v = usub(v, 2 - x); x = 1 end; if v == "" then return end; gpu.setForeground(fg or C.white); gpu.setBackground(bg or C.bg); gpu.set(x, y, trunc(v, WIDTH - x + 1)) end
local function centerX(v, left, w) left = left or 1; w = w or WIDTH; return left + math.max(0, math.floor((w - ulen(v)) / 2)) end
local function center(y, v, fg, bg, left, w) write(centerX(v, left, w), y, v, fg, bg) end
local function box(x, y, w, h, fg, bg) if w < 2 or h < 2 then return end; fg = fg or C.line; bg = bg or C.bg; write(x, y, "┌" .. string.rep("─", w - 2) .. "┐", fg, bg); for r = y + 1, y + h - 2 do write(x, r, "│", fg, bg); write(x + w - 1, r, "│", fg, bg) end; write(x, y + h - 1, "└" .. string.rep("─", w - 2) .. "┘", fg, bg) end
local function num(v, d) local n = tonumber(v); if n == nil then return d or 0 end; return n end
local function trim(v) local s = string.format("%.4f", num(v, 0)):gsub("0+$", ""):gsub("%.$", ""); return s == "" and "0" or s end
local function stamp() return os and os.date and os.date("%d.%m.%Y %H:%M:%S") or tostring(math.floor(computer.uptime())) end
local function clone(v) if type(v) ~= "table" then return v end; local r = {}; for k, n in pairs(v) do r[k] = clone(n) end; return r end

-- Работа с файлами
if not filesystem.exists(DATA_DIR) then filesystem.makeDirectory(DATA_DIR) end
local function readTable(path) if not filesystem.exists(path) then return nil end; local f = io.open(path, "r"); if not f then return nil end; local raw = f:read("*a"); f:close(); local ok, v = pcall(serialization.unserialize, raw or ""); if ok and type(v) == "table" then return v end; return nil end
local function atomicSave(path, value) local raw = serialization.serialize(value); local tmp = path .. ".tmp"; local f = io.open(tmp, "w"); if not f then return false, "Не открыть временный файл" end; f:write(raw); f:close(); if filesystem.exists(path) then pcall(filesystem.remove, BACKUP_FILE); pcall(filesystem.rename, path, BACKUP_FILE) end; local ok = pcall(filesystem.rename, tmp, path); if ok and filesystem.exists(path) then return true end; local out = io.open(path, "w"); if not out then return false, "Не сохранить state.db" end; out:write(raw); out:close(); pcall(filesystem.remove, tmp); return true end

-- Структура состояния
local function defaultState()
    return {
        version = 1,
        maintenance = false,
        buyVersion = 1,
        sellVersion = 1,
        nextTransaction = 1,
        nextId = 1, -- для feedbacks, reports, journal
        buyCatalog = {
            { displayName = "Алмаз", internalName = "minecraft:diamond", damage = 0, priceCoin = 10, priceEma = 0, article = "#VIP-001", enabled = true }
        },
        sellCatalog = {
            { displayName = "Железный слиток", internalName = "minecraft:iron_ingot", damage = 0, priceCoin = 1, priceEma = 0, article = "#SELL-001", enabled = true }
        },
        users = {},
        transactions = {},
        operations = {},
        terminals = {},
        feedbacks = {}, -- { id, player, text, time, status? }
        reports = {},   -- { id, player, reason, time, resolved }
        journal = {},   -- { id, event, time }
        globalStats = { totalReports = 0, totalBuys = 0, totalSells = 0 },
        updatedAt = stamp()
    }
end

local state = readTable(STATE_FILE) or defaultState()
state.buyCatalog = type(state.buyCatalog) == "table" and state.buyCatalog or {}
state.sellCatalog = type(state.sellCatalog) == "table" and state.sellCatalog or {}
state.users = type(state.users) == "table" and state.users or {}
state.transactions = type(state.transactions) == "table" and state.transactions or {}
state.operations = type(state.operations) == "table" and state.operations or {}
state.terminals = type(state.terminals) == "table" and state.terminals or {}
state.feedbacks = type(state.feedbacks) == "table" and state.feedbacks or {}
state.reports = type(state.reports) == "table" and state.reports or {}
state.journal = type(state.journal) == "table" and state.journal or {}
state.globalStats = type(state.globalStats) == "table" and state.globalStats or { totalReports = 0, totalBuys = 0, totalSells = 0 }
state.nextTransaction = math.max(1, math.floor(num(state.nextTransaction, 1)))
state.nextId = math.max(1, math.floor(num(state.nextId, 1)))
state.buyVersion = num(state.buyVersion, 1)
state.sellVersion = num(state.sellVersion, 1)
state.maintenance = state.maintenance == true

-- Обрезка и сохранение
local function prune()
    while #state.transactions > MAX_TRANSACTIONS do table.remove(state.transactions, 1) end
    local count = 0; for _ in pairs(state.operations) do count = count + 1 end
    if count > MAX_OPERATIONS then
        local arr = {}; for id, op in pairs(state.operations) do arr[#arr + 1] = { id = id, t = num(op.createdAtUptime, 0) } end
        table.sort(arr, function(a, b) return a.t < b.t end)
        for i = 1, count - MAX_OPERATIONS do state.operations[arr[i].id] = nil end
    end
    while #state.feedbacks > 500 do table.remove(state.feedbacks, 1) end
    while #state.reports > 500 do table.remove(state.reports, 1) end
    while #state.journal > 1000 do table.remove(state.journal, 1) end
end
local function saveState() prune(); state.updatedAt = stamp(); return atomicSave(STATE_FILE, state) end
saveState()

-- Индексы каталога
local buyIndex, sellIndex = {}, {}
local function ikey(id, dmg) return tostring(id or "") .. ":" .. tostring(math.floor(num(dmg, 0))) end
local function rebuild()
    buyIndex = {}; sellIndex = {}
    for i, item in ipairs(state.buyCatalog) do if type(item) == "table" and item.internalName then buyIndex[ikey(item.internalName, item.damage)] = { index = i, item = item } end end
    for i, item in ipairs(state.sellCatalog) do if type(item) == "table" and item.internalName then sellIndex[ikey(item.internalName, item.damage)] = { index = i, item = item } end end
end
rebuild()

-- Пользователи
local function findUser(name) name = tostring(name or ""); for stored in pairs(state.users) do if tostring(stored):lower() == name:lower() then return stored end end; return nil end
local function ensureUser(name)
    name = tostring(name or ""); local stored = findUser(name) or name; if stored == "" then return nil, nil end
    if type(state.users[stored]) ~= "table" then
        state.users[stored] = { balanceCoin = 0, balanceEma = 0, transactions = 0, regDate = stamp(), agreed = true, banned = false, banDuration = 0, hasFeedback = false }
        saveState()
    end
    return stored, state.users[stored]
end
local function publicUser(name, u)
    return {
        found = type(u) == "table",
        name = name,
        balanceCoin = num(u and u.balanceCoin, 0),
        balanceEma = num(u and u.balanceEma, 0),
        transactions = math.floor(num(u and u.transactions, 0)),
        regDate = u and u.regDate or nil,
        agreed = u and u.agreed == true,
        banned = u and u.banned == true,
        banReason = u and u.banReason or nil,
        banDuration = math.floor(num(u and u.banDuration, 0)),
        bannedBy = u and u.bannedBy or nil,
        bannedAt = u and u.bannedAt or nil,
        hasFeedback = u and u.hasFeedback == true
    }
end
local function nextTx() local n = state.nextTransaction; state.nextTransaction = n + 1; return n end
local function nextId() local n = state.nextId; state.nextId = n + 1; return n end

-- Журнал
local function logEvent(eventText)
    table.insert(state.journal, { id = nextId(), event = tostring(eventText), time = stamp() })
    saveState()
end

-- Терминалы
local function registerTerminal(address, id)
    id = tostring(id or ""); if id == "" then id = "TERM-" .. tostring(address):sub(1, 8) end
    local t = state.terminals[id]
    if type(t) ~= "table" then
        t = { id = id, address = address, name = id, paused = false, lastSeen = computer.uptime(), createdAt = stamp() }
        state.terminals[id] = t
    end
    t.address = address; t.lastSeen = computer.uptime(); t.online = true
    saveState()
    return t
end

-- Отправка чанков
local function sendChunks(address, port, requestId, response)
    local raw = serialization.serialize(response)
    local total = math.max(1, math.ceil(#raw / CHUNK_SIZE))
    for i = 1, total do
        local first = (i - 1) * CHUNK_SIZE + 1
        local chunk = raw:sub(first, first + CHUNK_SIZE - 1)
        modem.send(address, port, PROTOCOL, "chunk", NETWORK_KEY, requestId, i, total, chunk)
        if total > 1 then os.sleep(0.02) end
    end
end
local function broadcast(action, data)
    modem.broadcast(CLIENT_PORT, PROTOCOL, "push", NETWORK_KEY, action, serialization.serialize(data or {}))
end
local function directPush(address, action, data)
    if address and address ~= "" then modem.send(address, CLIENT_PORT, PROTOCOL, "push", NETWORK_KEY, action, serialization.serialize(data or {})) end
end

-- Обработка запросов
local function allowed(address, payload)
    if type(payload) ~= "table" then return false, "Пустой запрос" end
    local action = tostring(payload.action or "")
    if action == "discover" then return true end
    local terminal = registerTerminal(address, payload.terminalId)
    if terminal.paused and action ~= "hello" and action ~= "heartbeat" and action ~= "get_state" and action ~= "session_close" then
        return false, "Терминал поставлен на паузу"
    end
    return true, terminal
end
local function sameOwner(op, name) return tostring(op.player or ""):lower() == tostring(name or ""):lower() end

-- Покупка
local function doPurchase(payload, terminal)
    local player = tostring(payload.name or payload.player or "")
    local txid = tostring(payload.transactionId or "")
    local id = tostring(payload.item or payload.internalName or "")
    local dmg = math.floor(num(payload.damage, 0))
    local qty = math.floor(num(payload.qty, 0))
    if txid == "" or player == "" or id == "" or qty <= 0 then return { status = "error", message = "Некорректные данные покупки" } end
    local old = state.operations[txid]
    if type(old) == "table" then
        if old.type ~= "buy" then return { status = "error", message = "ID занят продажей" } end
        if not sameOwner(old, player) then return { status = "error", message = "ID принадлежит другому игроку" } end
        return { status = "ok", duplicate = true, data = clone(old.response or {}) }
    end
    if state.maintenance then return { status = "error", message = "Магазин на техработах" } end
    if terminal and terminal.paused then return { status = "error", message = "Терминал на паузе" } end
    local stored, u = ensureUser(player)
    if not u then return { status = "error", message = "Игрок не найден" } end
    if u.banned then return { status = "error", message = "Доступ игрока заблокирован" } end
    local found = buyIndex[ikey(id, dmg)]
    local item = found and found.item
    if not item or item.enabled == false then return { status = "error", message = "Товар отсутствует в покупках" } end
    local uc, ue = num(item.priceCoin, 0), num(item.priceEma, 0)
    local totalC, totalE = uc * qty, ue * qty
    local beforeC, beforeE = num(u.balanceCoin, 0), num(u.balanceEma, 0)
    if beforeC < totalC or beforeE < totalE then return { status = "error", message = "Недостаточно средств", data = { balanceCoin = beforeC, balanceEma = beforeE, requiredCoin = totalC, requiredEma = totalE } } end
    local txnum = nextTx()
    local oldTrans = num(u.transactions, 0)
    u.balanceCoin = beforeC - totalC
    u.balanceEma = beforeE - totalE
    u.transactions = math.floor(oldTrans) + 1
    local transaction = { id = txnum, transactionId = txid, player = stored, type = "buy", item = tostring(item.displayName or id), internalName = id, damage = dmg, qty = qty, coin = totalC, ema = totalE, date = stamp() }
    state.transactions[#state.transactions + 1] = transaction
    local response = { transactionId = txid, transaction = txnum, beforeCoin = beforeC, beforeEma = beforeE, balanceCoin = u.balanceCoin, balanceEma = u.balanceEma, transactions = u.transactions, qty = qty, unitCoin = uc, unitEma = ue, totalCoin = totalC, totalEma = totalE }
    state.operations[txid] = { type = "buy", status = "charged", player = stored, requestedQty = qty, unitCoin = uc, unitEma = ue, transactionIndex = #state.transactions, response = clone(response), createdAt = stamp(), createdAtUptime = computer.uptime() }
    local ok, err = saveState()
    if not ok then
        state.operations[txid] = nil; table.remove(state.transactions); state.nextTransaction = txnum; u.balanceCoin = beforeC; u.balanceEma = beforeE; u.transactions = oldTrans
        return { status = "error", message = err or "Ошибка сохранения" }
    end
    state.globalStats.totalBuys = (state.globalStats.totalBuys or 0) + 1
    saveState()
    logEvent("Покупка: " .. stored .. " купил " .. item.displayName .. " x" .. qty .. " за " .. totalC .. " COINA")
    broadcast("user_updated", { player = stored, user = publicUser(stored, u) })
    return { status = "ok", data = response }
end

-- Корректировка покупки
local function adjustPurchase(payload)
    local txid = tostring(payload.transactionId or "")
    local delivered = math.max(0, math.floor(num(payload.deliveredQty, 0)))
    local op = state.operations[txid]
    if type(op) ~= "table" or op.type ~= "buy" then return { status = "error", message = "Покупка не найдена" } end
    if op.status == "adjusted" then return { status = "ok", duplicate = true, data = clone(op.adjustResponse or {}) } end
    local requested = math.max(0, math.floor(num(op.requestedQty, 0)))
    delivered = math.min(requested, delivered)
    local missing = requested - delivered
    local refundC, refundE = num(op.unitCoin, 0) * missing, num(op.unitEma, 0) * missing
    local stored = findUser(op.player)
    local u = stored and state.users[stored]
    if not u then return { status = "error", message = "Игрок операции не найден" } end
    u.balanceCoin = num(u.balanceCoin, 0) + refundC
    u.balanceEma = num(u.balanceEma, 0) + refundE
    if delivered == 0 then u.transactions = math.max(0, math.floor(num(u.transactions, 0)) - 1) end
    local tx = state.transactions[op.transactionIndex]
    if type(tx) == "table" then tx.qty = delivered; tx.coin = num(op.unitCoin, 0) * delivered; tx.ema = num(op.unitEma, 0) * delivered; tx.adjusted = true; tx.refundedQty = missing end
    local response = { transactionId = txid, deliveredQty = delivered, refundedQty = missing, refundCoin = refundC, refundEma = refundE, balanceCoin = u.balanceCoin, balanceEma = u.balanceEma, transactions = u.transactions }
    op.status = "adjusted"; op.deliveredQty = delivered; op.adjustResponse = clone(response); op.updatedAt = stamp()
    saveState()
    broadcast("user_updated", { player = stored, user = publicUser(stored, u) })
    return { status = "ok", data = response }
end
local function finalizePurchase(payload)
    local txid = tostring(payload.transactionId or "")
    local op = state.operations[txid]
    if type(op) ~= "table" or op.type ~= "buy" then return { status = "error", message = "Покупка не найдена" } end
    if op.status ~= "adjusted" then op.status = "completed"; op.deliveredQty = op.requestedQty; op.completedAt = stamp(); saveState() end
    return { status = "ok", data = { transactionId = txid, status = op.status } }
end

-- Продажа
local function doSale(payload, terminal)
    local player = tostring(payload.name or payload.player or "")
    local txid = tostring(payload.transactionId or "")
    local id = tostring(payload.item or payload.internalName or "")
    local dmg = math.floor(num(payload.damage, 0))
    local qty = math.floor(num(payload.qty, 0))
    if txid == "" or player == "" or id == "" or qty <= 0 then return { status = "error", message = "Некорректные данные продажи" } end
    local old = state.operations[txid]
    if type(old) == "table" then
        if old.type ~= "sell" then return { status = "error", message = "ID занят покупкой" } end
        if not sameOwner(old, player) then return { status = "error", message = "ID принадлежит другому игроку" } end
        return { status = "ok", duplicate = true, data = clone(old.response or {}) }
    end
    if state.maintenance then return { status = "error", message = "Магазин на техработах" } end
    if terminal and terminal.paused then return { status = "error", message = "Терминал на паузе" } end
    local stored, u = ensureUser(player)
    if not u then return { status = "error", message = "Игрок не найден" } end
    if u.banned then return { status = "error", message = "Доступ игрока заблокирован" } end
    local found = sellIndex[ikey(id, dmg)]
    local item = found and found.item
    if not item or item.enabled == false then return { status = "error", message = "Товар отсутствует в продажах" } end
    local uc, ue = num(item.priceCoin, 0), num(item.priceEma, 0)
    local earnedC, earnedE = uc * qty, ue * qty
    local beforeC, beforeE = num(u.balanceCoin, 0), num(u.balanceEma, 0)
    local oldTrans = num(u.transactions, 0)
    local txnum = nextTx()
    u.balanceCoin = beforeC + earnedC
    u.balanceEma = beforeE + earnedE
    u.transactions = math.floor(oldTrans) + 1
    local tx = { id = txnum, transactionId = txid, player = stored, type = "sell", item = tostring(item.displayName or id), internalName = id, damage = dmg, qty = qty, coin = earnedC, ema = earnedE, date = stamp() }
    state.transactions[#state.transactions + 1] = tx
    local response = { transactionId = txid, transaction = txnum, beforeCoin = beforeC, beforeEma = beforeE, balanceCoin = u.balanceCoin, balanceEma = u.balanceEma, transactions = u.transactions, qty = qty, unitCoin = uc, unitEma = ue, earnedCoin = earnedC, earnedEma = earnedE }
    state.operations[txid] = { type = "sell", status = "completed", player = stored, qty = qty, response = clone(response), createdAt = stamp(), createdAtUptime = computer.uptime() }
    local ok, err = saveState()
    if not ok then
        state.operations[txid] = nil; table.remove(state.transactions); state.nextTransaction = txnum; u.balanceCoin = beforeC; u.balanceEma = beforeE; u.transactions = oldTrans
        return { status = "error", message = err or "Ошибка сохранения" }
    end
    state.globalStats.totalSells = (state.globalStats.totalSells or 0) + 1
    saveState()
    logEvent("Продажа: " .. stored .. " продал " .. item.displayName .. " x" .. qty .. " за " .. earnedC .. " COINA")
    broadcast("user_updated", { player = stored, user = publicUser(stored, u) })
    return { status = "ok", data = response }
end

-- Отзывы
local function addFeedback(payload)
    local player = tostring(payload.name or payload.player or "")
    local text = tostring(payload.text or "")
    local time = tostring(payload.time or stamp())
    if player == "" or text == "" then return { status = "error", message = "Не указан игрок или текст отзыва" } end
    local stored, u = ensureUser(player)
    if not u then return { status = "error", message = "Игрок не найден" } end
    if u.hasFeedback then return { status = "error", message = "Вы уже оставляли отзыв" } end
    local id = nextId()
    table.insert(state.feedbacks, { id = id, player = stored, text = text, time = time })
    u.hasFeedback = true
    saveState()
    logEvent("Новый отзыв от " .. stored .. ": " .. text)
    return { status = "ok", data = { id = id } }
end

local function deleteFeedback(payload)
    local id = math.floor(num(payload.id, 0))
    for i, f in ipairs(state.feedbacks) do
        if f.id == id then
            table.remove(state.feedbacks, i)
            -- сбросим hasFeedback у игрока, если он больше не оставлял отзывов (просто для чистоты)
            local stored = findUser(f.player)
            if stored and state.users[stored] then
                local found = false
                for _, ff in ipairs(state.feedbacks) do if ff.player == stored then found = true; break end end
                if not found then state.users[stored].hasFeedback = false end
            end
            saveState()
            logEvent("Отзыв #" .. id .. " удалён")
            return { status = "ok", data = { deleted = true } }
        end
    end
    return { status = "error", message = "Отзыв не найден" }
end

-- Репорты
local function addReport(payload)
    local player = tostring(payload.name or payload.player or "")
    local reason = tostring(payload.reason or "")
    local time = tostring(payload.time or stamp())
    if player == "" or reason == "" then return { status = "error", message = "Не указан игрок или причина" } end
    local stored, u = ensureUser(player)
    if not u then return { status = "error", message = "Игрок не найден" } end
    local id = nextId()
    table.insert(state.reports, { id = id, player = stored, reason = reason, time = time, resolved = false })
    state.globalStats.totalReports = (state.globalStats.totalReports or 0) + 1
    saveState()
    logEvent("Новый репорт от " .. stored .. ": " .. reason)
    return { status = "ok", data = { id = id } }
end

local function resolveReport(payload)
    local id = math.floor(num(payload.id, 0))
    for _, r in ipairs(state.reports) do
        if r.id == id and not r.resolved then
            r.resolved = true
            saveState()
            logEvent("Репорт #" .. id .. " разрешён")
            return { status = "ok", data = { resolved = true } }
        end
    end
    return { status = "error", message = "Репорт не найден или уже разрешён" }
end

-- Главный обработчик
local function handle(address, payload)
    local ok, terminal = allowed(address, payload)
    if not ok then return { status = "error", message = terminal } end
    local action = tostring(payload.action or "")
    if action == "hello" or action == "heartbeat" then
        return { status = "ok", data = { serverAddress = modem.address, maintenance = state.maintenance, terminalPaused = terminal.paused == true, buyVersion = state.buyVersion, sellVersion = state.sellVersion } }
    elseif action == "get_state" then
        return { status = "ok", data = { maintenance = state.maintenance, terminalPaused = terminal.paused == true, buyVersion = state.buyVersion, sellVersion = state.sellVersion } }
    elseif action == "session_open" then
        local stored, u = ensureUser(payload.name or payload.player)
        return { status = "ok", data = { maintenance = state.maintenance, terminalPaused = terminal.paused == true, buyVersion = state.buyVersion, sellVersion = state.sellVersion, user = publicUser(stored or payload.name, u) } }
    elseif action == "session_close" then
        return { status = "ok", data = { closed = true } }
    elseif action == "get_catalog" then
        if tostring(payload.catalog or "buy") == "sell" then return { status = "ok", data = { version = state.sellVersion, sellItems = clone(state.sellCatalog) } } end
        return { status = "ok", data = { version = state.buyVersion, catalog = clone(state.buyCatalog) } }
    elseif action == "get_balance" then
        local stored = findUser(payload.name or payload.player)
        local u = stored and state.users[stored]
        return { status = "ok", data = publicUser(stored or payload.name, u) }
    elseif action == "check_ban" then
        local stored = findUser(payload.name or payload.player)
        local u = stored and state.users[stored]
        return { status = "ok", data = { banned = u and u.banned == true or false, reason = u and u.banReason or nil, duration = u and u.banDuration or 0, admin = u and u.bannedBy or nil, date = u and u.bannedAt or nil } }
    elseif action == "update_balance" then
        local stored, u = ensureUser(payload.name or payload.player)
        if not u then return { status = "error", message = "Имя игрока обязательно" } end
        if payload.coin ~= nil then u.balanceCoin = num(payload.coin, u.balanceCoin) end
        if payload.ema ~= nil then u.balanceEma = num(payload.ema, u.balanceEma) end
        if payload.transactions ~= nil then u.transactions = math.max(0, math.floor(num(payload.transactions, u.transactions))) end
        if payload.agreed ~= nil then u.agreed = payload.agreed == true end
        if payload.regDate then u.regDate = tostring(payload.regDate) end
        saveState()
        broadcast("user_updated", { player = stored, user = publicUser(stored, u) })
        return { status = "ok", data = publicUser(stored, u) }
    elseif action == "purchase" then
        return doPurchase(payload, terminal)
    elseif action == "adjust_purchase" or action == "refund_purchase" then
        return adjustPurchase(payload)
    elseif action == "finalize_purchase" then
        return finalizePurchase(payload)
    elseif action == "sell" then
        return doSale(payload, terminal)
    elseif action == "get_operation" then
        local op = state.operations[tostring(payload.transactionId or "")]
        return { status = "ok", data = { found = type(op) == "table", operation = type(op) == "table" and clone(op) or nil } }
    elseif action == "add_feedback" then
        return addFeedback(payload)
    elseif action == "delete_feedback" then
        return deleteFeedback(payload)
    elseif action == "add_report" then
        return addReport(payload)
    elseif action == "resolve_report" then
        return resolveReport(payload)
    elseif action == "get_stats" then
        return { status = "ok", data = clone(state.globalStats) }
    end
    return { status = "error", message = "Неизвестное действие: " .. action }
end

-- ================= ADMIN GUI =================
local ui = { tab = "buy", selected = 1, scroll = 0, search = "", searchFocused = false, activeField = nil, fields = {}, buttons = {}, rows = {}, form = {}, message = "Сервер запущен", messageColor = C.green, lastDraw = 0 }
local tabs = {
    { id = "buy", title = "ПОКУПКИ" },
    { id = "sell", title = "ПРОДАЖИ" },
    { id = "users", title = "ПОЛЬЗОВАТЕЛИ" },
    { id = "transactions", title = "ТРАНЗАКЦИИ" },
    { id = "terminals", title = "ТЕРМИНАЛЫ" },
    { id = "feedbacks", title = "ОТЗЫВЫ" },
    { id = "reports", title = "РЕПОРТЫ" },
    { id = "journal", title = "ЖУРНАЛ" },
    { id = "stats", title = "СТАТИСТИКА" },
}
local TOP = 4
local BOTTOM = 3
local MAIN_Y = TOP + 1
local MAIN_H = HEIGHT - TOP - BOTTOM
local LEFT_W = math.max(38, math.floor(WIDTH * 0.52))
local RIGHT_X = LEFT_W + 2
local RIGHT_W = WIDTH - RIGHT_X
local LIST_Y = MAIN_Y + 3
local LIST_H = MAIN_H - 4

local function msg(v, c) ui.message = tostring(v or ""); ui.messageColor = c or C.white end
local function clearControls() ui.fields = {}; ui.buttons = {}; ui.rows = {} end
local function addField(id, label, value, x, y, w, opt) opt = opt or {}; local f = { id = id, label = label, value = tostring(value or ""), x = x, y = y, w = w, numeric = opt.numeric == true, readonly = opt.readonly == true }; ui.fields[#ui.fields + 1] = f; return f end
local function addButton(id, label, x, y, w, bg, fg) local b = { id = id, label = label, x = x, y = y, w = w, bg = bg or C.button, fg = fg or C.white }; ui.buttons[#ui.buttons + 1] = b; fill(x, y, w, 1, b.bg); center(y, label, b.fg, b.bg, x, w); return b end
local function fby(id) for _, f in ipairs(ui.fields) do if f.id == id then return f end end end
local function fv(id) local f = fby(id); return f and f.value or "" end
local function drawField(f, focus) write(f.x, f.y, f.label, C.gray, C.bg); local ix = f.x + 15; local iw = math.max(8, f.w - 15); fill(ix, f.y, iw, 1, C.input); write(ix + 1, f.y, trunc(f.value, iw - 2), f.readonly and C.dark or (focus and C.cyan or C.white), C.input) end

local function listData()
    local r = {}
    local q = tostring(ui.search or ""):lower()
    if ui.tab == "buy" or ui.tab == "sell" then
        local src = ui.tab == "buy" and state.buyCatalog or state.sellCatalog
        for i, it in ipairs(src) do
            local name = tostring(it.displayName or it.internalName or "")
            if q == "" or name:lower():find(q, 1, true) then
                r[#r + 1] = { sourceIndex = i, title = name, sub = tostring(it.internalName or ""), raw = it }
            end
        end
        table.sort(r, function(a, b) return a.title:lower() < b.title:lower() end)
    elseif ui.tab == "users" then
        for name, u in pairs(state.users) do
            if q == "" or tostring(name):lower():find(q, 1, true) then
                r[#r + 1] = { key = name, title = name, sub = "COINA " .. trim(u.balanceCoin) .. " | EMA " .. trim(u.balanceEma), raw = u }
            end
        end
        table.sort(r, function(a, b) return a.title:lower() < b.title:lower() end)
    elseif ui.tab == "transactions" then
        for i = #state.transactions, 1, -1 do
            local t = state.transactions[i]
            local title = "#" .. tostring(t.id or i) .. " " .. tostring(t.player or "?")
            local full = title .. " " .. tostring(t.item or "")
            if q == "" or full:lower():find(q, 1, true) then
                r[#r + 1] = { sourceIndex = i, title = title, sub = tostring(t.type or "") .. " | " .. tostring(t.item or "") .. " ×" .. tostring(t.qty or 0), raw = t }
            end
        end
    elseif ui.tab == "terminals" then
        for id, t in pairs(state.terminals) do
            local title = tostring(t.name or id)
            if q == "" or title:lower():find(q, 1, true) then
                r[#r + 1] = { key = id, title = title, sub = t.online and "ONLINE" or "OFFLINE", raw = t }
            end
        end
        table.sort(r, function(a, b) return a.title:lower() < b.title:lower() end)
    elseif ui.tab == "feedbacks" then
        for i = #state.feedbacks, 1, -1 do
            local f = state.feedbacks[i]
            local title = "#" .. tostring(f.id) .. " " .. tostring(f.player or "?")
            if q == "" or title:lower():find(q, 1, true) or (f.text and tostring(f.text):lower():find(q, 1, true)) then
                r[#r + 1] = { key = i, title = title, sub = tostring(f.text or ""), raw = f }
            end
        end
    elseif ui.tab == "reports" then
        for i = #state.reports, 1, -1 do
            local rep = state.reports[i]
            local title = "#" .. tostring(rep.id) .. " " .. tostring(rep.player or "?")
            if q == "" or title:lower():find(q, 1, true) or (rep.reason and tostring(rep.reason):lower():find(q, 1, true)) then
                r[#r + 1] = { key = i, title = title, sub = (rep.resolved and "✅ " or "⏳ ") .. tostring(rep.reason or ""), raw = rep }
            end
        end
    elseif ui.tab == "journal" then
        for i = #state.journal, 1, -1 do
            local j = state.journal[i]
            local title = tostring(j.event or "")
            if q == "" or title:lower():find(q, 1, true) then
                r[#r + 1] = { key = i, title = title, sub = tostring(j.time or ""), raw = j }
            end
        end
    elseif ui.tab == "stats" then
        -- статистика не требует списка, просто показываем цифры
        r = { { title = "Статистика", sub = "", raw = state.globalStats } }
    end
    return r
end

local function selected(list)
    if #list == 0 then return nil end
    ui.selected = math.max(1, math.min(ui.selected, #list))
    return list[ui.selected]
end

local function loadForm()
    local e = selected(listData())
    ui.form = {}
    if ui.tab == "buy" or ui.tab == "sell" then
        local it = e and e.raw or {}
        ui.form = {
            displayName = tostring(it.displayName or ""),
            internalName = tostring(it.internalName or ""),
            damage = tostring(it.damage or 0),
            priceCoin = trim(it.priceCoin or 0),
            priceEma = trim(it.priceEma or 0),
            article = tostring(it.article or ""),
            enabled = it.enabled ~= false,
            sourceIndex = e and e.sourceIndex or nil
        }
    elseif ui.tab == "users" then
        local u = e and e.raw or {}
        ui.form = {
            name = e and e.key or "",
            balanceCoin = trim(u.balanceCoin or 0),
            balanceEma = trim(u.balanceEma or 0),
            transactions = tostring(u.transactions or 0),
            reason = tostring(u.banReason or ""),
            duration = tostring(u.banDuration or 0),
            admin = tostring(u.bannedBy or "Admin"),
            banned = u.banned == true,
            hasFeedback = u.hasFeedback == true
        }
    elseif ui.tab == "terminals" then
        local t = e and e.raw or {}
        ui.form = { id = e and e.key or "", name = tostring(t.name or (e and e.key) or ""), address = tostring(t.address or ""), paused = t.paused == true, online = t.online == true }
    elseif ui.tab == "feedbacks" then
        local f = e and e.raw or {}
        ui.form = { id = f.id or 0, player = f.player or "", text = f.text or "", time = f.time or "" }
    elseif ui.tab == "reports" then
        local rep = e and e.raw or {}
        ui.form = { id = rep.id or 0, player = rep.player or "", reason = rep.reason or "", time = rep.time or "", resolved = rep.resolved == true }
    elseif ui.tab == "journal" then
        local j = e and e.raw or {}
        ui.form = { id = j.id or 0, event = j.event or "", time = j.time or "" }
    elseif ui.tab == "stats" then
        ui.form = clone(state.globalStats)
    end
end

local function drawHeader()
    fill(1, 1, WIDTH, TOP, C.header)
    center(1, "──── PIM MARKET SERVER ────", C.accent, C.header)
    local x = 2
    for _, t in ipairs(tabs) do
        local w = ulen(t.title) + 4
        local active = ui.tab == t.id
        fill(x, 3, w, 1, active and C.selected or C.panel)
        center(3, t.title, active and C.cyan or C.gray, active and C.selected or C.panel, x, w)
        t.x = x; t.w = w
        x = x + w + 1
    end
    local a = "MODEM: " .. tostring(modem.address)
    write(math.max(1, WIDTH - ulen(a) - 1), 1, a, C.gray, C.header)
end

local function drawList(list)
    fill(1, MAIN_Y, LEFT_W, MAIN_H, C.bg)
    box(1, MAIN_Y, LEFT_W, MAIN_H, C.line, C.bg)
    write(3, MAIN_Y + 1, "ПОИСК:", C.gray, C.bg)
    local sx = 11
    local sw = LEFT_W - sx - 2
    fill(sx, MAIN_Y + 1, sw, 1, C.input)
    write(sx + 1, MAIN_Y + 1, trunc(ui.search, sw - 2), ui.searchFocused and C.cyan or C.white, C.input)
    ui.rows = {}
    local max = math.max(0, #list - LIST_H)
    ui.scroll = math.max(0, math.min(ui.scroll, max))
    for row = 1, LIST_H do
        local idx = ui.scroll + row
        local e = list[idx]
        local y = LIST_Y + row - 1
        fill(2, y, LEFT_W - 2, 1, idx == ui.selected and C.selected or C.bg)
        if e then
            local fg = idx == ui.selected and C.cyan or C.white
            if ui.tab == "reports" and e.raw and e.raw.resolved then fg = C.green end
            if ui.tab == "journal" then fg = C.gray end
            write(3, y, trunc(e.title, LEFT_W - 5), fg, idx == ui.selected and C.selected or C.bg)
            ui.rows[#ui.rows + 1] = { y = y, index = idx }
        end
    end
    local info = "Всего: " .. tostring(#list)
    if ui.tab == "stats" then info = "Оборот, репорты и т.д." end
    write(3, MAIN_Y + MAIN_H - 2, info, C.gray, C.bg)
end

local function catalogEditor()
    local x = RIGHT_X; local w = RIGHT_W
    write(x, MAIN_Y + 1, ui.tab == "buy" and "РЕДАКТОР ПОКУПКИ" or "РЕДАКТОР ПРОДАЖИ", C.accent, C.bg)
    addField("displayName", "Название:", ui.form.displayName, x, MAIN_Y + 4, w - 2)
    addField("internalName", "ID предмета:", ui.form.internalName, x, MAIN_Y + 6, w - 2)
    addField("damage", "Damage:", ui.form.damage, x, MAIN_Y + 8, w - 2, { numeric = true })
    addField("priceCoin", "COINA:", ui.form.priceCoin, x, MAIN_Y + 10, w - 2, { numeric = true })
    addField("priceEma", "EMA:", ui.form.priceEma, x, MAIN_Y + 12, w - 2, { numeric = true })
    addField("article", "Артикул:", ui.form.article, x, MAIN_Y + 14, w - 2)
    write(x, MAIN_Y + 16, "Активен:", C.gray, C.bg)
    addButton("toggle_enabled", "[ " .. (ui.form.enabled and "ДА" or "НЕТ") .. " ]", x + 15, MAIN_Y + 16, 10, ui.form.enabled and C.button or C.danger)
    local y = MAIN_Y + 19
    addButton("save_item", "[ СОХРАНИТЬ ]", x, y, 18, C.button)
    addButton("new_item", "[ НОВЫЙ ]", x + 20, y, 14, C.alt)
    addButton("delete_item", "[ УДАЛИТЬ ]", x + 36, y, 16, C.danger)
    write(x, MAIN_Y + 22, "Версия: " .. tostring(ui.tab == "buy" and state.buyVersion or state.sellVersion), C.gray, C.bg)
end

local function userEditor()
    local x = RIGHT_X; local w = RIGHT_W
    write(x, MAIN_Y + 1, "РЕДАКТОР ПОЛЬЗОВАТЕЛЯ", C.accent, C.bg)
    addField("name", "Игрок:", ui.form.name, x, MAIN_Y + 4, w - 2)
    addField("balanceCoin", "COINA:", ui.form.balanceCoin, x, MAIN_Y + 6, w - 2, { numeric = true })
    addField("balanceEma", "EMA:", ui.form.balanceEma, x, MAIN_Y + 8, w - 2, { numeric = true })
    addField("transactions", "Транзакции:", ui.form.transactions, x, MAIN_Y + 10, w - 2, { numeric = true })
    addField("reason", "Причина бана:", ui.form.reason, x, MAIN_Y + 13, w - 2)
    addField("duration", "Срок, сек:", ui.form.duration, x, MAIN_Y + 15, w - 2, { numeric = true })
    addField("admin", "Администратор:", ui.form.admin, x, MAIN_Y + 17, w - 2)
    write(x, MAIN_Y + 19, "Отзыв оставлен: " .. (ui.form.hasFeedback and "ДА" or "НЕТ"), ui.form.hasFeedback and C.green or C.gray, C.bg)
    local y = MAIN_Y + 21
    addButton("save_user", "[ СОХРАНИТЬ ]", x, y, 18, C.button)
    addButton("new_user", "[ НОВЫЙ ]", x + 20, y, 14, C.alt)
    addButton(ui.form.banned and "unban_user" or "ban_user", ui.form.banned and "[ РАЗБАНИТЬ ]" or "[ ЗАБАНИТЬ ]", x + 36, y, 18, ui.form.banned and C.button or C.danger)
    write(x, MAIN_Y + 24, ui.form.banned and "СТАТУС: ЗАБЛОКИРОВАН" or "СТАТУС: ДОСТУП РАЗРЕШЁН", ui.form.banned and C.red or C.green, C.bg)
end

local function transactionEditor(e)
    local x = RIGHT_X
    write(x, MAIN_Y + 1, "ТРАНЗАКЦИЯ", C.accent, C.bg)
    if not e then write(x, MAIN_Y + 4, "Транзакции отсутствуют", C.gray, C.bg); return end
    local t = e.raw
    local lines = {
        "Номер: #" .. tostring(t.id or "?"),
        "Игрок: " .. tostring(t.player or "?"),
        "Тип: " .. tostring(t.type or "?"),
        "Товар: " .. tostring(t.item or "?"),
        "ID: " .. tostring(t.internalName or "?"),
        "Количество: " .. tostring(t.qty or 0),
        "COINA: " .. trim(t.coin or 0),
        "EMA: " .. trim(t.ema or 0),
        "Дата: " .. tostring(t.date or "?"),
        "Operation ID: " .. tostring(t.transactionId or "?")
    }
    for i, l in ipairs(lines) do
        write(x, MAIN_Y + 3 + i, trunc(l, RIGHT_W - 2), i == 3 and C.cyan or C.white, C.bg)
    end
end

local function terminalEditor(e)
    local x = RIGHT_X; local w = RIGHT_W
    write(x, MAIN_Y + 1, "ТЕРМИНАЛ", C.accent, C.bg)
    if not e then write(x, MAIN_Y + 4, "Терминалы ещё не подключались", C.gray, C.bg); return end
    addField("terminal_name", "Название:", ui.form.name, x, MAIN_Y + 4, w - 2)
    addField("terminal_id", "Terminal ID:", ui.form.id, x, MAIN_Y + 6, w - 2, { readonly = true })
    addField("terminal_address", "Modem ID:", ui.form.address, x, MAIN_Y + 8, w - 2, { readonly = true })
    write(x, MAIN_Y + 11, "Статус: " .. (ui.form.online and "ONLINE" or "OFFLINE"), ui.form.online and C.green or C.red, C.bg)
    write(x, MAIN_Y + 12, "Пауза: " .. (ui.form.paused and "ВКЛЮЧЕНА" or "ВЫКЛЮЧЕНА"), ui.form.paused and C.yellow or C.green, C.bg)
    local y = MAIN_Y + 15
    addButton("save_terminal", "[ СОХРАНИТЬ ИМЯ ]", x, y, 22, C.button)
    addButton(ui.form.paused and "resume_terminal" or "pause_terminal", ui.form.paused and "[ СНЯТЬ С ПАУЗЫ ]" or "[ ПОСТАВИТЬ НА ПАУЗУ ]", x + 24, y, ui.form.paused and 22 or 26, ui.form.paused and C.button or C.pause)
end

local function feedbackEditor(e)
    local x = RIGHT_X; local w = RIGHT_W
    write(x, MAIN_Y + 1, "ОТЗЫВ", C.accent, C.bg)
    if not e then write(x, MAIN_Y + 4, "Отзывов нет", C.gray, C.bg); return end
    addField("fb_player", "Игрок:", ui.form.player, x, MAIN_Y + 4, w - 2, { readonly = true })
    addField("fb_text", "Текст:", ui.form.text, x, MAIN_Y + 6, w - 2, { readonly = true })
    addField("fb_time", "Время:", ui.form.time, x, MAIN_Y + 8, w - 2, { readonly = true })
    addButton("delete_feedback", "[ УДАЛИТЬ ОТЗЫВ ]", x, MAIN_Y + 12, 24, C.danger)
end

local function reportEditor(e)
    local x = RIGHT_X; local w = RIGHT_W
    write(x, MAIN_Y + 1, "РЕПОРТ (ЖАЛОБА)", C.accent, C.bg)
    if not e then write(x, MAIN_Y + 4, "Репортов нет", C.gray, C.bg); return end
    addField("rep_player", "Игрок:", ui.form.player, x, MAIN_Y + 4, w - 2, { readonly = true })
    addField("rep_reason", "Причина:", ui.form.reason, x, MAIN_Y + 6, w - 2, { readonly = true })
    addField("rep_time", "Время:", ui.form.time, x, MAIN_Y + 8, w - 2, { readonly = true })
    write(x, MAIN_Y + 11, "Статус: " .. (ui.form.resolved and "РАЗРЕШЁН" or "ОЖИДАЕТ"), ui.form.resolved and C.green or C.yellow, C.bg)
    if not ui.form.resolved then
        addButton("resolve_report", "[ РАЗРЕШИТЬ ]", x, MAIN_Y + 14, 20, C.button)
    end
end

local function journalEditor(e)
    local x = RIGHT_X; local w = RIGHT_W
    write(x, MAIN_Y + 1, "ЖУРНАЛ СОБЫТИЙ", C.accent, C.bg)
    if not e then write(x, MAIN_Y + 4, "Журнал пуст", C.gray, C.bg); return end
    addField("jevent", "Событие:", ui.form.event, x, MAIN_Y + 4, w - 2, { readonly = true })
    addField("jtime", "Время:", ui.form.time, x, MAIN_Y + 6, w - 2, { readonly = true })
end

local function statsEditor()
    local x = RIGHT_X; local w = RIGHT_W
    write(x, MAIN_Y + 1, "СТАТИСТИКА", C.accent, C.bg)
    local s = ui.form
    write(x, MAIN_Y + 4, "Покупок: " .. tostring(s.totalBuys or 0), C.white, C.bg)
    write(x, MAIN_Y + 6, "Продаж:   " .. tostring(s.totalSells or 0), C.white, C.bg)
    write(x, MAIN_Y + 8, "Оборот:   " .. tostring((s.totalBuys or 0) + (s.totalSells or 0)), C.white, C.bg)
    write(x, MAIN_Y + 10, "Репортов: " .. tostring(s.totalReports or 0), C.white, C.bg)
    write(x, MAIN_Y + 12, "Пользователей: " .. tostring(tableSize(state.users)), C.white, C.bg)
    write(x, MAIN_Y + 14, "Транзакций: " .. tostring(#state.transactions), C.white, C.bg)
end

local function tableSize(t) local c = 0; for _ in pairs(t) do c = c + 1 end; return c end

local function drawRight(e)
    fill(RIGHT_X - 1, MAIN_Y, RIGHT_W + 1, MAIN_H, C.bg)
    box(RIGHT_X - 1, MAIN_Y, RIGHT_W + 1, MAIN_H, C.line, C.bg)
    if ui.tab == "buy" or ui.tab == "sell" then
        catalogEditor()
    elseif ui.tab == "users" then
        userEditor()
    elseif ui.tab == "transactions" then
        transactionEditor(e)
    elseif ui.tab == "terminals" then
        terminalEditor(e)
    elseif ui.tab == "feedbacks" then
        feedbackEditor(e)
    elseif ui.tab == "reports" then
        reportEditor(e)
    elseif ui.tab == "journal" then
        journalEditor(e)
    elseif ui.tab == "stats" then
        statsEditor()
    end
    for i, f in ipairs(ui.fields) do
        drawField(f, ui.activeField == i)
    end
end

local function onlineCount()
    local c = 0; local now = computer.uptime()
    for _, t in pairs(state.terminals) do t.online = now - num(t.lastSeen, 0) <= OFFLINE_AFTER; if t.online then c = c + 1 end end
    return c
end

local function drawBottom()
    local y = HEIGHT - BOTTOM + 1
    fill(1, y, WIDTH, BOTTOM, C.header)
    addButton("toggle_maintenance", state.maintenance and "[ ТЕХ.РАБОТЫ: ВКЛ ]" or "[ ТЕХ.РАБОТЫ: ВЫКЛ ]", 2, y + 1, 24, state.maintenance and C.danger or C.button)
    local info = "Сервер: ONLINE | Терминалов: " .. onlineCount() .. " | Порт: " .. SERVER_PORT
    write(29, y + 1, trunc(info, WIDTH - 31), C.green, C.header)
    if ui.message ~= "" then write(2, y, trunc(ui.message, WIDTH - 3), ui.messageColor, C.header) end
end

local function drawAll()
    clearControls()
    fill(1, 1, WIDTH, HEIGHT, C.bg)
    drawHeader()
    local list = listData()
    if #list == 0 then ui.selected = 0; ui.scroll = 0 elseif ui.selected <= 0 then ui.selected = 1 elseif ui.selected > #list then ui.selected = #list end
    drawList(list)
    local e = selected(list)
    drawRight(e)
    drawBottom()
    ui.lastDraw = computer.uptime()
end

local function reload() loadForm(); ui.activeField = nil; drawAll() end

-- Действия (сохранение, удаление, баны и т.д.)
local function saveItem()
    local name, id = fv("displayName"), fv("internalName")
    if name == "" or id == "" then msg("Название и ID обязательны", C.red); drawAll(); return end
    local src = ui.tab == "buy" and state.buyCatalog or state.sellCatalog
    local idx = ui.form.sourceIndex
    local it = { displayName = name, internalName = id, damage = math.floor(num(fv("damage"), 0)), priceCoin = num(fv("priceCoin"), 0), priceEma = num(fv("priceEma"), 0), article = fv("article"), enabled = ui.form.enabled ~= false }
    if idx and src[idx] then src[idx] = it else src[#src + 1] = it end
    if ui.tab == "buy" then state.buyVersion = state.buyVersion + 1 else state.sellVersion = state.sellVersion + 1 end
    rebuild(); saveState()
    broadcast("catalog_updated", { catalog = ui.tab, version = ui.tab == "buy" and state.buyVersion or state.sellVersion })
    msg("Товар сохранён и отправлен терминалам", C.green); ui.selected = 1; reload()
end
local function deleteItem()
    local src = ui.tab == "buy" and state.buyCatalog or state.sellCatalog
    local idx = ui.form.sourceIndex
    if not idx or not src[idx] then msg("Товар не выбран", C.red); drawAll(); return end
    table.remove(src, idx)
    if ui.tab == "buy" then state.buyVersion = state.buyVersion + 1 else state.sellVersion = state.sellVersion + 1 end
    rebuild(); saveState()
    broadcast("catalog_updated", { catalog = ui.tab, version = ui.tab == "buy" and state.buyVersion or state.sellVersion })
    msg("Товар удалён", C.yellow); ui.selected = math.max(1, ui.selected - 1); reload()
end
local function saveUser()
    local name = fv("name")
    if name == "" then msg("Укажите имя игрока", C.red); drawAll(); return end
    local stored, u = ensureUser(name)
    u.balanceCoin = num(fv("balanceCoin"), u.balanceCoin)
    u.balanceEma = num(fv("balanceEma"), u.balanceEma)
    u.transactions = math.max(0, math.floor(num(fv("transactions"), u.transactions)))
    saveState()
    broadcast("user_updated", { player = stored, user = publicUser(stored, u) })
    msg("Баланс игрока сохранён", C.green); reload()
end
local function banUser(value)
    local name = fv("name")
    local stored, u = ensureUser(name)
    if not u then msg("Игрок не выбран", C.red); drawAll(); return end
    u.banned = value == true
    if u.banned then
        u.banReason = fv("reason") ~= "" and fv("reason") or "Нарушение правил магазина"
        u.banDuration = math.max(0, math.floor(num(fv("duration"), 0)))
        u.bannedBy = fv("admin") ~= "" and fv("admin") or "Admin"
        u.bannedAt = stamp()
    else
        u.banReason = nil; u.banDuration = 0; u.bannedBy = nil; u.bannedAt = nil
    end
    saveState()
    broadcast(u.banned and "user_banned" or "user_unbanned", { player = stored, user = publicUser(stored, u), reason = u.banReason, duration = u.banDuration, admin = u.bannedBy, date = u.bannedAt })
    msg(u.banned and "Игрок заблокирован" or "Игрок разблокирован", u.banned and C.red or C.green); reload()
end
local function saveTerminal()
    local id = ui.form.id
    local t = id and state.terminals[id]
    if not t then return end
    t.name = fv("terminal_name") ~= "" and fv("terminal_name") or id
    saveState(); msg("Название терминала сохранено", C.green); reload()
end
local function pauseTerminal(value)
    local id = ui.form.id
    local t = id and state.terminals[id]
    if not t then return end
    t.paused = value == true
    saveState()
    directPush(t.address, t.paused and "terminal_paused" or "terminal_resumed", { terminalId = id, paused = t.paused })
    msg(t.paused and "Терминал поставлен на паузу" or "Пауза снята", t.paused and C.yellow or C.green); reload()
end
local function deleteFeedbackAction()
    local id = ui.form.id
    if not id or id == 0 then msg("Отзыв не выбран", C.red); drawAll(); return end
    for i, f in ipairs(state.feedbacks) do
        if f.id == id then
            local stored = f.player
            table.remove(state.feedbacks, i)
            -- сброс hasFeedback
            if stored then
                local found = false
                for _, ff in ipairs(state.feedbacks) do if ff.player == stored then found = true; break end end
                if not found and state.users[stored] then state.users[stored].hasFeedback = false end
            end
            saveState()
            logEvent("Отзыв #" .. id .. " удалён через админку")
            msg("Отзыв удалён", C.green); reload()
            return
        end
    end
    msg("Отзыв не найден", C.red); drawAll()
end
local function resolveReportAction()
    local id = ui.form.id
    if not id or id == 0 then msg("Репорт не выбран", C.red); drawAll(); return end
    for _, r in ipairs(state.reports) do
        if r.id == id and not r.resolved then
            r.resolved = true
            saveState()
            logEvent("Репорт #" .. id .. " разрешён через админку")
            msg("Репорт разрешён", C.green); reload()
            return
        end
    end
    msg("Репорт не найден или уже разрешён", C.red); drawAll()
end

local function action(id)
    if id == "toggle_enabled" then
        ui.form.enabled = not ui.form.enabled; drawAll()
    elseif id == "save_item" then
        saveItem()
    elseif id == "new_item" then
        ui.form = { displayName = "", internalName = "", damage = "0", priceCoin = "0", priceEma = "0", article = "", enabled = true }
        ui.activeField = nil; drawAll()
    elseif id == "delete_item" then
        deleteItem()
    elseif id == "save_user" then
        saveUser()
    elseif id == "new_user" then
        ui.form = { name = "", balanceCoin = "0", balanceEma = "0", transactions = "0", reason = "", duration = "0", admin = "Admin", banned = false, hasFeedback = false }
        ui.activeField = nil; drawAll()
    elseif id == "ban_user" then
        banUser(true)
    elseif id == "unban_user" then
        banUser(false)
    elseif id == "save_terminal" then
        saveTerminal()
    elseif id == "pause_terminal" then
        pauseTerminal(true)
    elseif id == "resume_terminal" then
        pauseTerminal(false)
    elseif id == "toggle_maintenance" then
        state.maintenance = not state.maintenance
        saveState()
        broadcast("maintenance_changed", { maintenance = state.maintenance })
        msg(state.maintenance and "Техработы включены" or "Техработы выключены", state.maintenance and C.red or C.green)
        drawAll()
    elseif id == "delete_feedback" then
        deleteFeedbackAction()
    elseif id == "resolve_report" then
        resolveReportAction()
    end
end

local function inside(x, y, c) return y == c.y and x >= c.x and x < c.x + c.w end
local function touch(x, y)
    for _, t in ipairs(tabs) do
        if y == 3 and x >= t.x and x < t.x + t.w then
            ui.tab = t.id; ui.selected = 1; ui.scroll = 0; ui.search = ""; ui.searchFocused = false; loadForm(); drawAll(); return
        end
    end
    if y == MAIN_Y + 1 and x >= 11 and x < LEFT_W - 1 then
        ui.searchFocused = true; ui.activeField = nil; drawAll(); return
    end
    for _, r in ipairs(ui.rows) do
        if y == r.y and x >= 2 and x <= LEFT_W then
            ui.selected = r.index; ui.searchFocused = false; loadForm(); drawAll(); return
        end
    end
    for i, f in ipairs(ui.fields) do
        local ix = f.x + 15; local iw = math.max(8, f.w - 15)
        if y == f.y and x >= ix and x < ix + iw and not f.readonly then
            ui.activeField = i; ui.searchFocused = false; drawAll(); return
        end
    end
    for _, b in ipairs(ui.buttons) do
        if inside(x, y, b) then ui.activeField = nil; ui.searchFocused = false; action(b.id); return end
    end
    ui.activeField = nil; ui.searchFocused = false; drawAll()
end

local function scroll(direction)
    local list = listData()
    local max = math.max(0, #list - LIST_H)
    ui.scroll = math.max(0, math.min(max, ui.scroll - direction * 3))
    if ui.selected < ui.scroll + 1 then ui.selected = ui.scroll + 1 end
    if ui.selected > ui.scroll + LIST_H then ui.selected = ui.scroll + LIST_H end
    drawAll()
end

local function key(char, code)
    if code == keyboard.keys.escape then ui.activeField = nil; ui.searchFocused = false; drawAll(); return end
    if ui.searchFocused then
        if code == keyboard.keys.back then
            ui.search = usub(ui.search, 1, -2)
        elseif code == keyboard.keys.enter or code == keyboard.keys.tab then
            ui.searchFocused = false
        elseif char and char >= 32 then
            ui.search = ui.search .. unicode.char(char)
        end
        ui.selected = 1; ui.scroll = 0; loadForm(); drawAll(); return
    end
    local f = ui.activeField and ui.fields[ui.activeField]
    if f and not f.readonly then
        if code == keyboard.keys.back then
            f.value = usub(f.value, 1, -2)
        elseif code == keyboard.keys.enter or code == keyboard.keys.tab then
            ui.activeField = nil
        elseif char and char >= 32 then
            local ch = unicode.char(char)
            if not f.numeric or ch:match("[%d%.,%-]") then f.value = f.value .. ch end
        end
        if f.id == "terminal_name" then ui.form.name = f.value else ui.form[f.id] = f.value end
        drawAll(); return
    end
    if code == keyboard.keys.up then
        ui.selected = math.max(1, ui.selected - 1)
        if ui.selected <= ui.scroll then ui.scroll = math.max(0, ui.selected - 1) end
        loadForm(); drawAll()
    elseif code == keyboard.keys.down then
        local list = listData()
        ui.selected = math.min(#list, ui.selected + 1)
        if ui.selected > ui.scroll + LIST_H then ui.scroll = ui.selected - LIST_H end
        loadForm(); drawAll()
    end
end

-- Симуляция активности (генерация тестовых данных)
local function simulateMarketActivity()
    if state.maintenance then return end  -- не генерируем во время техработ
    local players = { "Alice", "Bob", "Charlie", "Dave", "Eve", "Frank", "Grace", "Helen" }
    local now = computer.uptime()
    -- Транзакции
    for _, p in ipairs(players) do
        if math.random() < 0.1 then
            local stored, u = ensureUser(p)
            if u and not u.banned then
                local amount = math.random(10, 50)
                local type = math.random() < 0.5 and "buy" or "sell"
                if type == "buy" then
                    -- имитация покупки (просто изменение баланса)
                    u.balanceCoin = num(u.balanceCoin, 0) - amount
                    u.transactions = (u.transactions or 0) + 1
                    state.globalStats.totalBuys = (state.globalStats.totalBuys or 0) + 1
                    logEvent("Тест: " .. stored .. " купил товар за " .. amount .. " COINA")
                else
                    u.balanceCoin = num(u.balanceCoin, 0) + amount
                    u.transactions = (u.transactions or 0) + 1
                    state.globalStats.totalSells = (state.globalStats.totalSells or 0) + 1
                    logEvent("Тест: " .. stored .. " продал товар за " .. amount .. " COINA")
                end
                if u.balanceCoin < 0 then u.balanceCoin = 0 end
                saveState()
            end
        end
    end
    -- Отзывы
    if math.random() < 0.05 then
        local player = players[math.random(#players)]
        local stored, u = ensureUser(player)
        if u and not u.banned and not u.hasFeedback then
            local texts = { "Отличный магазин!", "Хороший сервис.", "Можно лучше.", "Супер!", "Не доволен." }
            local id = nextId()
            table.insert(state.feedbacks, { id = id, player = stored, text = texts[math.random(#texts)], time = stamp() })
            u.hasFeedback = true
            saveState()
            logEvent("Тест: новый отзыв от " .. stored)
        end
    end
    -- Репорты
    if math.random() < 0.03 then
        local player = players[math.random(#players)]
        local stored, u = ensureUser(player)
        if u and not u.banned then
            local reasons = { "Мошенничество", "Не тот товар", "Задержка доставки", "Грубость" }
            local id = nextId()
            table.insert(state.reports, { id = id, player = stored, reason = reasons[math.random(#reasons)], time = stamp(), resolved = false })
            state.globalStats.totalReports = (state.globalStats.totalReports or 0) + 1
            saveState()
            logEvent("Тест: новый репорт от " .. stored)
        end
    end
end

loadForm()
drawAll()

-- Таймер для симуляции (каждые 15 секунд)
local simTimer = event.timer(15, function()
    simulateMarketActivity()
    -- Обновляем интерфейс, если он не в режиме редактирования
    if ui.activeField == nil and not ui.searchFocused then
        drawAll()
    end
end, math.huge)

-- Главный цикл
while true do
    local ev = { event.pull(0.25) }
    local name = ev[1]
    if name == "modem_message" then
        local address, port, protocol, kind, keyValue = ev[3], ev[4], ev[6], ev[7], ev[8]
        if port == SERVER_PORT and protocol == PROTOCOL and keyValue == NETWORK_KEY then
            if kind == "discover" then
                modem.send(address, num(ev[10], CLIENT_PORT), PROTOCOL, "discover_reply", NETWORK_KEY, tostring(ev[9] or ""), modem.address, SERVER_PORT, CLIENT_PORT)
            elseif kind == "request" then
                local requestId = tostring(ev[9] or "")
                local replyPort = math.floor(num(ev[10], CLIENT_PORT))
                local ok, payload = pcall(serialization.unserialize, tostring(ev[11] or ""))
                local response
                if not ok or type(payload) ~= "table" then
                    response = { status = "error", message = "Повреждённый запрос" }
                else
                    local handled, result = pcall(handle, address, payload)
                    response = handled and result or { status = "error", message = "Ошибка сервера: " .. tostring(result) }
                end
                sendChunks(address, replyPort, requestId, response)
            end
        end
    elseif name == "touch" then
        touch(ev[3], ev[4])
    elseif name == "scroll" then
        scroll(ev[5] or 0)
    elseif name == "key_down" then
        key(ev[3], ev[4])
    elseif name == "interrupted" then
        term.clear()
        print("PIM MARKET SERVER остановлен")
        print("Modem ID: " .. tostring(modem.address))
        print("Порт: " .. SERVER_PORT)
        event.cancel(simTimer)
        break
    end
    -- Обновление статуса терминалов и перерисовка
    local changed = false
    local now = computer.uptime()
    for _, t in pairs(state.terminals) do
        local online = now - num(t.lastSeen, 0) <= OFFLINE_AFTER
        if t.online ~= online then t.online = online; changed = true end
    end
    if changed or now - ui.lastDraw > 2 then
        drawAll()
    end
end
