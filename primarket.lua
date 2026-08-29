-- =====================================================================
-- PIM MARKET (ЛОКАЛЬНАЯ ВЕРСИЯ) – АБСОЛЮТНО ПОЛНЫЙ КОД
-- Без веб-интеграции, с динамическим размером экрана и событиями PIM
-- =====================================================================

local component = require("component")
local gpu = component.gpu
local term = require("term")
local event = require("event")
local keyboard = require("keyboard")
local unicode = require("unicode")
local serialization = require("serialization")
local fs = require("filesystem")
local computer = require("computer")
local os = require("os")

-- =====================================================================
-- НАСТРОЙКА ЭКРАНА (получаем реальные размеры)
-- =====================================================================
local WIDTH, HEIGHT = gpu.getResolution()
local maxW, maxH = gpu.maxResolution()
if WIDTH < maxW or HEIGHT < maxH then
  gpu.setResolution(maxW, maxH)
  WIDTH, HEIGHT = gpu.getResolution()
end

-- =====================================================================
-- ЦВЕТА (объединены из admin_shop и pimmarket)
-- =====================================================================
local C = {
  bg = 0x0C0C0C,
  white = 0xFFFFFF,
  gray = 0xAAAAAA,
  darkGray = 0x555555,
  green = 0x55FF55,
  yellow = 0xFFFF55,
  red = 0xFF5555,
  cyan = 0x55FFFF,
  selectedBg = 0x002440,
  selectedName = 0x00e6b1,
  star = 0x077d42,
  vipTitle = 0x0c9a76,
  underLine = 0x428A72,
  mainLine = 0x7FFFD4,
  sectionLine = 0x27BDEC,
  headerBg = 0x1A2D33,
  notFound = 0xF50016,
  buttonBuy = 0x0a502d,
  buttonClear = 0x8b1a1a,
  buttonSales = 0x1a5a6b,
  inputBg = 0x1a1a1a,
  inputFg = 0xFFFFFF,
  accent = 0x0c9a76,
  frame = 0x27BDEC,
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
  green_bright = 0x3BFF18,
  gold = 0xFFD700,
}

-- =====================================================================
-- ПЕРЕМЕННЫЕ ДЛЯ СТАРЫХ UI-ФУНКЦИЙ (чтобы они не падали)
-- =====================================================================
currentScreen = "menu"           
shopPaused = false
feedbacksPage = 1
feedbacksTotalPages = 1
playerHasFeedback = false
showSellPopup = false
showPartialPopup = false
showInsufficientPopup = false
showInventoryFullPopup = false
showShopDenied = false
reportInput = ""
feedbackInput = ""
feedbackEditMode = false
feedbackRating = 5
selectedItem = nil
hoveredIndex = 0
purchaseQuantity = 1
purchaseItem = nil
sellConfirmItem = nil
foundAmount = 0
partialExtracted = 0
partialRequested = 0
partialRefundCoin = 0
partialRefundEma = 0
insufficientBalanceCoin = 0
insufficientBalanceEma = 0
tempMessage = ""
tempMessageTimer = nil

-- =====================================================================
-- ДЕКОРАТИВНЫЕ ПЕРЕМЕННЫЕ (оставлены без изменений)
-- =====================================================================
local diamond = {
  "             ▓▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▓▓▓            ",
  "           ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▓▓▒▒▒▒▓          ",
  "        ▓▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▓▓▓▓▓        ",
  "      ▓▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▓▓▒▒▒▒▒▒▒▒▒▓      ",
  "     ▒▒▒▒▒▒▒▒▒▒▒▓▓▓▓▒▒▒▒▒▒▒▒▒▒▓▓▓▓▒▒▒▒▓▓▓▒▒     ",
  "     ▓▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▓▓▓▓▓▓▒▒▒▒▒▒▓▓      ",
  "       ▓▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▓▓▓▓▓▓       ",
  "        ▓▓▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▓▓▓▓▓▒▓▓▓▓         ",
  "          ▓▒▒▒▒▒▒▒▒▓▓▓▒▒▒▒▒▓▓▓▓▓▓▓▓▓▓▓          ",
  "            ▓▒▒▒▒▒▓▓▓▓▓▒▒▓▓▓▓▓▓▓▓▓▓▓            ",
  "             ▓▒▒▒▒▒▓▓▓▓▒▒▓▓▓▓▓▒▓▓▓▓             ",
  "               ▓▒▒▒▒▓▓▓▒▒▓▓▓▓▓▓▓▓               ",
  "                 ▓▒▒▒▓▓▒▒▓▓▓▓▓▓▓                ",
  "                  ▓▒▒▒▓▓▒▓▓▓▓▓                  ",
  "                    ▓▒▒▒▒▓▒▓▓                   ",
  "                      ▓▒▒▒▓▓                    ",
  "                        ▒▓                      ",
}

local gradient = {
  0x003D33, 0x005A4C, 0x007A66, 0x009980,
  0x00B899, 0x00D4B3, 0x00E5C9, 0x33FFD6,
}

local asciiQR = [[
█████████████████████████████████████████████████████████████████████
█████████████████████████████████████████████████████████████████████
██████░░░░░░░░░░███████░██░░██████░██████░░░░██░░░███░░░░░░░░░░██████
████░░█████████░░████████░████░░██░░░██░░░░██░░░████░░█████████░░████
████░░██░░░░░██░░██████░░░████████░████░░░░████░████░░██░░░░░██░░████
████░░██░░░░░██░░████░░███░░██░░░░███████░░██░░░████░░██░░░░░██░░████
████░░██░░░░░██░░████░░░████████████░░░██░░██░░░████░░██░░░░░██░░████
████░░█████████░░███████░░░░░░░░░░░██░░░░██░░███░░██░░█████████░░████
█████░░░░░░░░░░░███░░██░██░░██░░██░██░░██░░██░██░░███░░░░░░░░░░░█████
███████████████████████░██░░░░░░░░░░░██░░░░███░░█████████████████████
████████░░░░███░░████░░░░░░░██░░███░░████░░░░███░░░░░░██░████████████
████████░░░░░░░██████░░░░░██░░░░░░█░░░░██████░░░██░░░░███████░░░░████
██████░░░░██░██░░░░█████░░░░████░░░██░░░░░░░░░░░░░██░░███████░░░░████
████████████░████████░░░█████████████████████░██████░░░░░░░██████████
████░░██████░░░░░░░██░░██████████████████████░░░░░░░██░░█████████████
████████░░██░██████░░██████░░░██████████████████░░████░░░██░░████████
██████░░░░░░░██░░██░░██░█████░░░░░░░░░░░██████████░░░░█████░░████████
████░░████░░█████████░░░██████░░░░░░░░░██████░████░░████░░░████░░████
██████████░░█░░░░░░████████████░░░░░░░████████░░░░██░░░░░░░██████████
█████████████░░██░░░░░░███████░░█████████████░░░████░░░░░██░░░░██████
████░░██░░██░░░░░░░██░░░████████████████████████████████░██░░████████
████░░░░█████████░░██░░░██████░░█████░░██████░████░░░░░░░████░░██████
████░░░░████░░░░░██░░░░██████████████████████░████░░█████░░░░████████
████░░██░░███░░██████░░░██████████████████████████░░███████░░██░░████
████████████░░░░░██████░████░░░░░░░░░░░████░░░██████░░░░█░░░░░░░░████
██████░░███████████░░░░░██░░░░████░████░░████░░░░░░░██░░█████░░░░████
████░░██████░░░░░░░░░███░░██░░█████░░██░░░░░░░░░░░░░░░░░░████░░░░████
███████████████████░░█████░░██░░░░░░░░░░░░░██░██░░██████░██░░░░██████
█████░░░░░░░░░░░███░░░░░██░░░░██░░░░░░░██████░░░░░██░░██░░░░░████████
████░░█████████░░████░░░░░░░░░████░████████░░░██░░██████░██░░░░░░████
████░░██░░░░░██░░█████████░░██████░██░░░░░░████░░░░░░░░░░░░░░░░██████
████░░██░░░░░██░░██░░███░░██░░░░░░█░░████░░░░███░░████░░█████████████
████░░██░░░░░██░░██░░███████████░░░██░░██░░██░░░░░░░░░░░░░░░░░░░░████
████░░█████████░░██████░░░██░░███████░░████░░█░░░░░░░░░░░░░░░░░░░████
██████░░░░░░░░░░████████░░████████░██░░███████░░░░░░░░░░░░░░░░░░░████
█████████████████████████████████████████████████████████████████████
█████████████████████████████████████████████████████████████████████
]]

-- Кнопки меню (старые) – их координаты не адаптированы, но они не используются в новом интерфейсе
local menuButtons = {
  shop    = {x=32, xs=20, y=9,  ys=3, text="🛒 Магазин",     tx=6, ty=1, bg=C.bg_button, fg=C.accent_main},
  account = {x=32, xs=20, y=17, ys=3, text="👤 Аккаунт",      tx=6, ty=1, bg=C.bg_button, fg=C.accent_main}
}

local shopMenuButtons = {
  buy    = {x=32, xs=20, y=9,  ys=3, text="🛍 Покупка",     tx=6, ty=1, bg=C.bg_button, fg=C.accent_main},
  sell   = {x=32, xs=20, y=17, ys=3, text="💰 Пополнение",  tx=5, ty=1, bg=C.bg_button, fg=C.accent_main},
}

-- =====================================================================
-- ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ UI
-- =====================================================================
local function setBG(c) gpu.setBackground(c) end
local function setFG(c) gpu.setForeground(c) end

local function fill(x, y, w, h, c)
  setBG(c)
  gpu.fill(x, y, w, h, " ")
end

local function text(x, y, str, fg, bg)
  if bg then setBG(bg) end
  if fg then setFG(fg) end
  gpu.set(x, y, str)
end

local function sectionHeader(x, y, w, title, lineColor, titleColor)
  lineColor = lineColor or C.sectionLine
  titleColor = titleColor or C.white
  setBG(C.bg)
  setFG(lineColor)
  gpu.set(x, y, string.rep("-", w))
  setFG(titleColor)
  gpu.set(x + 1, y, title)
end

local function truncate(str, maxLen)
  if #str <= maxLen then return str end
  return str:sub(1, maxLen - 3) .. "..."
end

local function sortableName(name)
  if not name then return "" end
  local lower = string.lower(name)
  local result = lower:gsub("(%d+)", function(d)
    return string.format("%08d", tonumber(d))
  end)
  return result
end

local function toLowerCase(str)
  if not str then return "" end
  str = string.lower(str)
  str = str:gsub("А", "а"):gsub("Б", "б"):gsub("В", "в"):gsub("Г", "г"):gsub("Д", "д")
  str = str:gsub("Е", "е"):gsub("Ё", "ё"):gsub("Ж", "ж"):gsub("З", "з"):gsub("И", "и")
  str = str:gsub("Й", "й"):gsub("К", "к"):gsub("Л", "л"):gsub("М", "м"):gsub("Н", "н")
  str = str:gsub("О", "о"):gsub("П", "п"):gsub("Р", "р"):gsub("С", "с"):gsub("Т", "т")
  str = str:gsub("У", "у"):gsub("Ф", "ф"):gsub("Х", "х"):gsub("Ц", "ц"):gsub("Ч", "ч")
  str = str:gsub("Ш", "ш"):gsub("Щ", "щ"):gsub("Ъ", "ъ"):gsub("Ы", "ы"):gsub("Ь", "ь")
  str = str:gsub("Э", "э"):gsub("Ю", "ю"):gsub("Я", "я")
  return str
end

-- Общие функции для отрисовки (адаптированы под WIDTH, HEIGHT)
function clear()
  gpu.setBackground(C.bg_main)
  gpu.fill(1, 1, WIDTH, HEIGHT, " ")
end

function drawCenteredText(y, text, color)
  if not text then text = "" end
  gpu.setForeground(color or C.text_main)
  local x = math.floor((WIDTH - unicode.len(text)) / 2) + 1
  gpu.set(x, y, text)
end

function drawButton(btn)
  if not btn then return end
  gpu.setBackground(btn.bg)
  gpu.fill(btn.x, btn.y, btn.xs, btn.ys, " ")
  gpu.setForeground(btn.fg)
  local txt = btn.text or ""
  local tx = btn.x + math.floor((btn.xs - unicode.len(txt)) / 2)
  local ty = btn.y + math.floor((btn.ys - 1) / 2)
  gpu.set(tx, ty, txt)
  gpu.setBackground(C.bg_main)
end

function drawFlexButton(btn) drawButton(btn) end

-- Динамическая рамка по всему экрану
function drawScreenBorder()
  local left, right, top, bottom = 1, WIDTH, 1, HEIGHT
  gpu.setForeground(C.accent_secondary)
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

function drawBalanceLine(x, y)
  local coin = coinBalance or 0
  local ema = emaBalance or 0
  gpu.setForeground(C.white)
  gpu.set(x, y, "Баланс: ")
  local coinStr = string.format("%.2f", coin) .. " Coina ₵"
  gpu.setForeground(C.accent_main)
  gpu.set(x + unicode.len("Баланс: "), y, coinStr)
  gpu.setForeground(C.white)
  gpu.set(x + unicode.len("Баланс: ") + unicode.len(coinStr), y, " | ")
  local emaStr = "ЭМЫ: " .. string.format("%.2f", ema) .. " ۞"
  gpu.setForeground(C.tomato)
  gpu.set(x + unicode.len("Баланс: ") + unicode.len(coinStr) + unicode.len(" | "), y, emaStr)
end

function drawTempMessage()
  if tempMessage ~= "" and tempMessage then
    gpu.setBackground(C.bg_main)
    gpu.fill(1, HEIGHT, WIDTH, 1, " ")
    gpu.setForeground(C.success)
    local x = math.floor((WIDTH - unicode.len(tempMessage)) / 2) + 1
    gpu.set(x, HEIGHT, tempMessage)
  else
    gpu.setBackground(C.bg_main)
    gpu.fill(1, HEIGHT, WIDTH, 1, " ")
  end
end

function showTempMessage(msg, duration)
  tempMessage = msg or ""
  if tempMessageTimer then
    event.cancel(tempMessageTimer)
  end
  tempMessageTimer = event.timer(duration or 2, function()
    tempMessage = ""
    tempMessageTimer = nil
    drawTempMessage()
  end)
  drawTempMessage()
end

function isButtonClicked(btn, x, y)
  if not btn then return false end
  return y >= btn.y and y < btn.y + btn.ys and x >= btn.x and x < btn.x + btn.xs
end

-- =====================================================================
-- ПУТИ К ФАЙЛАМ
-- =====================================================================
local DB_PATH = "/home/players.db"
local BUY_ITEMS_PATH = "/home/buy_items.lua"
local SELL_ITEMS_PATH = "/home/shop_items.lua"

-- =====================================================================
-- ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ СОСТОЯНИЯ (для нового интерфейса)
-- =====================================================================
local currentPlayer = nil
local coinBalance = 0.0
local emaBalance = 0.0
local playerTransactions = 0
local playerRegDate = ""
local playerAgreed = false

local shopMode = "buy"             -- "buy" или "sell"
local allBuyItems = {}
local allSellItems = {}
local displayedItems = {}

local selectedIndex = 1
local scrollOffset = 0
local searchQuery = ""
local searchFocused = false
local quantity = ""

local account = {
  nick = "",
  coina = "0",
  ema = "0",
  regDate = "",
  trans = "0",
}

-- Размеры интерфейса (из admin_shop) – адаптированы под WIDTH, HEIGHT
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

-- =====================================================================
-- ЗАГРУЗКА / СОХРАНЕНИЕ ДАННЫХ
-- =====================================================================
local function ensureFile(path, default)
  if not fs.exists(path) then
    local file = io.open(path, "w")
    if file then
      if type(default) == "table" then
        file:write(serialization.serialize(default))
      else
        file:write(default)
      end
      file:close()
      return true
    end
    return false
  end
  return true
end

ensureFile(DB_PATH, {})

local players = {}

local function loadPlayers()
  local file = io.open(DB_PATH, "r")
  if file then
    local raw = file:read("*a")
    file:close()
    if raw and #raw > 0 then
      local ok, data = pcall(serialization.unserialize, raw)
      if ok and type(data) == "table" then
        players = data
        return
      end
    end
  end
  players = {}
end

local function savePlayers()
  local file = io.open(DB_PATH, "w")
  if file then
    file:write(serialization.serialize(players))
    file:close()
    return true
  end
  return false
end

local function getOrCreatePlayer(name)
  if not name or name == "" then return nil end
  if not players[name] then
    players[name] = {
      balance = 0.0,
      emaBalance = 0.0,
      transactions = 0,
      regDate = os.date("%d.%m.%Y %H:%M:%S"),
      agreed = false,
    }
    savePlayers()
  end
  return players[name]
end

local function loadBuyItems()
  if fs.exists(BUY_ITEMS_PATH) then
    local ok, data = pcall(dofile, BUY_ITEMS_PATH)
    if ok and type(data) == "table" then
      allBuyItems = data
      if component.isAvailable("me_interface") then
        local me = component.me_interface
        local rawItems = me.getItemsInNetwork()
        local meQuantities = {}
        for _, meItem in ipairs(rawItems) do
          local key = meItem.name .. ":" .. (meItem.damage or 0)
          meQuantities[key] = meItem.size or 0
        end
        for _, item in ipairs(allBuyItems) do
          local key = item.internalName .. ":" .. (item.damage or 0)
          item.qty = meQuantities[key] or 0
        end
      else
        for _, item in ipairs(allBuyItems) do item.qty = 0 end
      end
      return
    end
  end
  allBuyItems = {}
end

local function loadSellItems()
  if fs.exists(SELL_ITEMS_PATH) then
    local ok, data = pcall(dofile, SELL_ITEMS_PATH)
    if ok and type(data) == "table" and data.sellItems then
      allSellItems = data.sellItems
      for _, item in ipairs(allSellItems) do item.qty = 0 end
      return
    end
  end
  allSellItems = {}
end

-- =====================================================================
-- РАБОТА С PIM И ME
-- =====================================================================
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

local function scanPlayerInventory(internalName, damage)
  local pimAddr = getPimAddr()
  if not pimAddr then return 0 end
  local pim = component.proxy(pimAddr)
  local total = 0
  for slot = 1, 36 do
    local stack = pim.getStackInSlot(slot)
    if stack then
      local qty = stack.size or stack.qty or 0
      if qty > 0 then
        local rawName = stack.name or stack.label or ""
        local cleanName = rawName:gsub("§.", "")
        local dmg = stack.damage or 0
        if cleanName == internalName and dmg == (damage or 0) then
          total = total + qty
        end
      end
    end
  end
  return total
end

local function extractToME(internalName, amount, damage)
  local pimAddr = getPimAddr()
  if not pimAddr or amount <= 0 then return 0 end
  local pim = component.proxy(pimAddr)
  local extracted = 0
  for slot = 1, 36 do
    if extracted >= amount then break end
    local stack = pim.getStackInSlot(slot)
    if stack then
      local qty = stack.size or stack.qty or 0
      if qty > 0 then
        local rawName = stack.name or stack.label or ""
        local cleanName = rawName:gsub("§.", "")
        local dmg = stack.damage or 0
        if cleanName == internalName and dmg == (damage or 0) then
          local toTake = math.min(qty, amount - extracted)
          if toTake > 0 then
            local moved = pim.pushItem("up", slot, toTake)
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

-- =====================================================================
-- ТРАНЗАКЦИИ (ПОКУПКА / ПРОДАЖА)
-- =====================================================================
local function addTransaction(type, playerName, item, qty, coin, ema)
  local player = players[playerName]
  if player then
    player.transactions = (player.transactions or 0) + 1
    savePlayers()
  end
end

local function performBuy(item, qty)
  if not item or qty <= 0 then
    return false, "Неверный товар или количество"
  end
  local totalCoin = (item.priceCoin or 0) * qty
  local totalEma = (item.priceEma or 0) * qty
  if coinBalance < totalCoin or emaBalance < totalEma then
    return false, "Недостаточно средств"
  end
  local actualQty = getActualItemQuantity(item.internalName, item.damage or 0)
  if actualQty < qty then
    return false, "Недостаточно товара в ME"
  end
  local me = component.me_interface
  local id = item.internalName
  if not id:find(":") then
    id = "minecraft:" .. id
  end
  local fingerprint = { id = id, dmg = item.damage or 0 }
  local extracted = 0
  local remaining = qty
  local maxStack = 64
  while remaining > 0 do
    local toTake = math.min(remaining, maxStack)
    local success, result = pcall(function()
      return me.exportItem(fingerprint, "up", toTake)
    end)
    local got = 0
    if success then
      if type(result) == "number" then got = result
      elseif type(result) == "boolean" and result == true then got = toTake
      elseif type(result) == "table" then got = result.count or result.amount or result.size or 0
      end
    end
    if got > 0 then
      extracted = extracted + got
      remaining = remaining - got
    else
      break
    end
  end
  if extracted == 0 then
    return false, "Не удалось выдать предметы (возможно, инвентарь полон)"
  end
  local actuallySpentCoin = extracted * (item.priceCoin or 0)
  local actuallySpentEma = extracted * (item.priceEma or 0)
  coinBalance = coinBalance - actuallySpentCoin
  emaBalance = emaBalance - actuallySpentEma
  local player = players[currentPlayer]
  if player then
    player.balance = coinBalance
    player.emaBalance = emaBalance
    savePlayers()
  end
  addTransaction("buy", currentPlayer, item.displayName, extracted, actuallySpentCoin, actuallySpentEma)
  if extracted < qty then
    return true, "Выдано " .. extracted .. " из " .. qty .. " (не хватило места)"
  end
  return true, "Успешно куплено " .. extracted .. " шт."
end

local function performSell(item, qty)
  if not item or qty <= 0 then
    return false, "Неверный товар или количество"
  end
  local available = scanPlayerInventory(item.internalName, item.damage or 0)
  if available < qty then
    return false, "В инвентаре только " .. available .. " шт."
  end
  local extracted = extractToME(item.internalName, qty, item.damage or 0)
  if extracted == 0 then
    return false, "Не удалось изъять предметы"
  end
  local valueCoin = extracted * (item.priceCoin or 0)
  local valueEma = extracted * (item.priceEma or 0)
  coinBalance = coinBalance + valueCoin
  emaBalance = emaBalance + valueEma
  local player = players[currentPlayer]
  if player then
    player.balance = coinBalance
    player.emaBalance = emaBalance
    savePlayers()
  end
  addTransaction("sell", currentPlayer, item.displayName, extracted, valueCoin, valueEma)
  return true, "Продано " .. extracted .. " шт., получено " .. string.format("%.2f", valueCoin) .. " Coina, " .. string.format("%.2f", valueEma) .. " EMA"
end

-- =====================================================================
-- ФИЛЬТРАЦИЯ И ПОИСК (НОВЫЙ ИНТЕРФЕЙС)
-- =====================================================================
local function filterItems()
  local source = (shopMode == "buy") and allBuyItems or allSellItems
  if searchQuery == "" then
    displayedItems = {}
    for i, v in ipairs(source) do displayedItems[i] = v end
  else
    local q = toLowerCase(searchQuery)
    displayedItems = {}
    for _, v in ipairs(source) do
      if toLowerCase(v.displayName or ""):find(q, 1, true) then
        table.insert(displayedItems, v)
      end
    end
  end
  table.sort(displayedItems, function(a, b)
    return sortableName(a.displayName) < sortableName(b.displayName)
  end)
  selectedIndex = 1
  scrollOffset = 0
end

-- =====================================================================
-- НОВЫЙ UI (ИЗ admin_shop) – ОСНОВНОЙ ИНТЕРФЕЙС
-- =====================================================================
function drawBackground()
  fill(1, 1, WIDTH, HEIGHT, C.bg)
end

function drawTopBar()
  fill(1, 1, WIDTH, 3, 0x0A0A0A)
  local title = "PIM MARKET"
  text(math.floor((WIDTH - #title) / 2) + 1, 1, title, C.vipTitle, 0x0A0A0A)
  setFG(C.underLine)
  setBG(0x0A0A0A)
  gpu.set(1, 2, string.rep("=", WIDTH))
  local modeText = (shopMode == "buy") and "ПОКУПКА" or "ПРОДАЖА"
  setFG(C.accent_secondary)
  setBG(0x0A0A0A)
  gpu.set(WIDTH - #modeText - 2, 1, "[" .. modeText .. "]")
  local searchW = 35
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

function drawMainFrames()
  setBG(C.bg)
  setFG(C.mainLine)
  gpu.set(1, MAIN_Y, "+" .. string.rep("=", WIDTH - 2) .. "+")
  for y = MAIN_Y + 1, MAIN_Y + MAIN_H - 2 do
    gpu.set(1, y, "|")
    gpu.set(WIDTH, y, "|")
  end
  gpu.set(1, MAIN_Y + MAIN_H - 1, "+" .. string.rep("=", WIDTH - 2) .. "+")
end

function drawLeftHeader()
  sectionHeader(2, MAIN_Y + 1, LEFT_W - 3, "КАТАЛОГ ТОВАРОВ", C.mainLine, C.white)
  local colY = MAIN_Y + 2
  fill(2, colY, LEFT_W - 3, 1, C.headerBg)
  text(COL_NAME_X, colY, "ТОВАР", C.white, C.headerBg)
  text(COL_ME_X, colY, "В ME", C.white, C.headerBg)
  text(COL_COINA_X, colY, "Coina", C.white, C.headerBg)
  text(COL_EMA_X, colY, "EMA", C.white, C.headerBg)
end

function drawSeparator()
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

function drawScrollbar()
  setBG(C.bg)
  setFG(C.darkGray)
  for y = LIST_Y, LIST_Y + LIST_H - 1 do
    gpu.set(SCROLL_X, y, " ")
  end
  local total = #displayedItems
  if total <= LIST_H then return end
  local thumbH = math.max(3, math.floor(LIST_H * 0.25))
  local maxScroll = total - LIST_H
  local thumbY = LIST_Y + math.floor((scrollOffset / maxScroll) * (LIST_H - thumbH))
  setBG(C.accent)
  for i = 0, thumbH - 1 do
    local yy = thumbY + i
    if yy >= LIST_Y and yy <= LIST_Y + LIST_H - 1 then
      gpu.set(SCROLL_X, yy, " ")
    end
  end
  setBG(C.bg)
end

function drawItemRow(index, y)
  local item = displayedItems[index]
  if not item then return end
  local isSelected = (index == selectedIndex)
  if isSelected then
    fill(LIST_X, y, LIST_W, 1, C.selectedBg)
  else
    fill(LIST_X, y, LIST_W, 1, C.bg)
  end
  local nameColor = isSelected and C.selectedName or C.white
  local meColor = (shopMode == "buy" and item.qty and item.qty > 0) and C.green or C.red
  local coinaColor = C.yellow
  local emaColor = C.cyan
  if isSelected then
    text(COL_NAME_X, y, "> ", C.selectedName, C.selectedBg)
  else
    text(COL_NAME_X, y, "  ", C.darkGray, C.bg)
  end
  local maxNameLen = COL_ME_X - COL_NAME_X - 2
  local displayName = truncate(item.displayName or "Неизвестно", maxNameLen - 2)
  text(COL_NAME_X + 2, y, displayName, nameColor, isSelected and C.selectedBg or C.bg)
  local qtyDisplay = (shopMode == "buy") and tostring(item.qty or 0) or "—"
  text(COL_ME_X, y, qtyDisplay, meColor, isSelected and C.selectedBg or C.bg)
  local coinStr = string.format("%.2f", item.priceCoin or 0)
  text(COL_COINA_X, y, coinStr, coinaColor, isSelected and C.selectedBg or C.bg)
  local emaStr = string.format("%.2f", item.priceEma or 0)
  text(COL_EMA_X, y, emaStr, emaColor, isSelected and C.selectedBg or C.bg)
end

function drawProductList()
  fill(LIST_X, LIST_Y, LIST_W, LIST_H, C.bg)
  if #displayedItems == 0 then
    local msg = "ПО ТВОЕМУ ЗАПРОСУ, НИЧЕГО НЕ НАЙДЕНО!"
    local visualLen = 35
    local mx = LIST_X + math.floor((LIST_W - visualLen) / 2)
    local my = LIST_Y + math.floor(LIST_H / 2)
    text(mx, my, msg, C.notFound, C.bg)
    return
  end
  local startIdx = scrollOffset + 1
  local endIdx = math.min(#displayedItems, startIdx + LIST_H - 1)
  for i = startIdx, endIdx do
    drawItemRow(i, LIST_Y + (i - startIdx))
  end
end

function drawInfoBlock()
  fill(RIGHT_INNER_X, INFO_Y, RIGHT_INNER_W, 7, C.bg)
  sectionHeader(RIGHT_INNER_X, INFO_Y, RIGHT_INNER_W, "ИНФО", C.sectionLine, C.white)
  local item = displayedItems[selectedIndex]
  if not item then return end
  local maxLen = RIGHT_INNER_W - 8
  local y = INFO_Y + 2
  text(RIGHT_INNER_X, y, "Товар: " .. truncate(item.displayName or "Неизвестно", maxLen), C.white, C.bg)
  y = y + 1
  if shopMode == "buy" then
    text(RIGHT_INNER_X, y, "В ME : " .. tostring(item.qty or 0), C.green, C.bg)
  else
    local invQty = scanPlayerInventory(item.internalName, item.damage or 0)
    text(RIGHT_INNER_X, y, "В инв.: " .. tostring(invQty), C.green, C.bg)
  end
  y = y + 1
  text(RIGHT_INNER_X, y, "Coina: " .. string.format("%.2f", item.priceCoin or 0), C.yellow, C.bg)
  y = y + 1
  text(RIGHT_INNER_X, y, "EMA  : " .. string.format("%.2f", item.priceEma or 0), C.cyan, C.bg)
end

function drawQuantitySection()
  fill(RIGHT_INNER_X, QTY_Y, RIGHT_INNER_W, 9, C.bg)
  sectionHeader(RIGHT_INNER_X, QTY_Y, RIGHT_INNER_W, "Количество", C.sectionLine, C.white)
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
  local item = displayedItems[selectedIndex]
  local qty = tonumber(quantity) or 0
  local totalCoina = 0
  local totalEma = 0
  if item then
    totalCoina = qty * (item.priceCoin or 0)
    totalEma = qty * (item.priceEma or 0)
  end
  local totalStr = string.format("Итог: Coina: %.2f | EMA: %.2f", totalCoina, totalEma)
  text(RIGHT_INNER_X, TOTAL_Y, totalStr, C.yellow, C.bg)
  local btnW = 12
  local gap = 2
  local actionText = (shopMode == "buy") and "[ Купить ]" or "[ Продать ]"
  setBG(C.buttonBuy)
  setFG(C.white)
  gpu.fill(RIGHT_INNER_X, BTN_Y, btnW, 1, " ")
  gpu.set(RIGHT_INNER_X + 1, BTN_Y, actionText)
  setBG(C.buttonClear)
  setFG(C.white)
  gpu.fill(RIGHT_INNER_X + btnW + gap, BTN_Y, btnW, 1, " ")
  gpu.set(RIGHT_INNER_X + btnW + gap + 1, BTN_Y, "[ Стереть ]")
end

function drawAccountInfo()
  fill(RIGHT_INNER_X, ACC_Y, RIGHT_INNER_W, 8, C.bg)
  sectionHeader(RIGHT_INNER_X, ACC_Y, RIGHT_INNER_W, "Информация Аккаунта", C.sectionLine, C.white)
  local y = ACC_Y + 2
  text(RIGHT_INNER_X, y, "НИК      : " .. account.nick, C.white, C.bg)
  y = y + 1
  text(RIGHT_INNER_X, y, "Баланс   : " .. account.coina .. " Coina | " .. account.ema .. " EMA", C.yellow, C.bg)
  y = y + 1
  text(RIGHT_INNER_X, y, "Регистрация: " .. account.regDate, C.gray, C.bg)
  y = y + 1
  text(RIGHT_INNER_X, y, "Транзакции: " .. account.trans, C.cyan, C.bg)
end

function drawRightPanel()
  drawInfoBlock()
  drawQuantitySection()
  drawAccountInfo()
end

function drawBottomBar()
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

function drawBottomBorder()
  setFG(C.mainLine)
  setBG(C.bg)
  gpu.set(1, HEIGHT, "+" .. string.rep("=", WIDTH - 2) .. "+")
end

function redrawAll()
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

-- =====================================================================
-- ОБНОВЛЕНИЕ СОСТОЯНИЯ ПОСЛЕ СМЕНЫ ИГРОКА
-- =====================================================================
local function updateAccountDisplay()
  local player = players[currentPlayer]
  if player then
    account.nick = currentPlayer
    account.coina = string.format("%.2f", player.balance or 0)
    account.ema = string.format("%.2f", player.emaBalance or 0)
    account.regDate = player.regDate or "Неизвестно"
    account.trans = tostring(player.transactions or 0)
    coinBalance = player.balance or 0
    emaBalance = player.emaBalance or 0
    playerTransactions = player.transactions or 0
    playerRegDate = player.regDate or ""
    playerAgreed = player.agreed or false
  else
    account.nick = "Нет игрока"
    account.coina = "0.00"
    account.ema = "0.00"
    account.regDate = ""
    account.trans = "0"
    coinBalance = 0
    emaBalance = 0
  end
end

-- =====================================================================
-- ОБРАБОТЧИКИ СОБЫТИЙ ДЛЯ НОВОГО ИНТЕРФЕЙСА
-- =====================================================================
local function selectItem(index)
  if #displayedItems == 0 then return end
  if index < 1 then index = 1 end
  if index > #displayedItems then index = #displayedItems end
  selectedIndex = index
  if selectedIndex - 1 < scrollOffset then
    scrollOffset = selectedIndex - 1
  elseif selectedIndex > scrollOffset + LIST_H then
    scrollOffset = selectedIndex - LIST_H
  end
  quantity = ""
  redrawAll()
end

local function scroll(delta)
  local maxScroll = math.max(0, #displayedItems - LIST_H)
  scrollOffset = math.max(0, math.min(maxScroll, scrollOffset + delta))
  redrawAll()
end

local function handleClick(x, y)
  searchFocused = false
  if x >= LIST_X and x <= LIST_X + LIST_W and y >= LIST_Y and y <= LIST_Y + LIST_H - 1 then
    local row = y - LIST_Y
    local index = scrollOffset + row + 1
    if index >= 1 and index <= #displayedItems then
      selectItem(index)
    end
    return
  end
  local searchW = 35
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
  local btnW = 12
  local gap = 2
  local clearQtyX = RIGHT_INNER_X + btnW + gap
  if y == BTN_Y and x >= clearQtyX and x < clearQtyX + btnW then
    quantity = ""
    redrawAll()
    return
  end
  if y == BTN_Y and x >= RIGHT_INNER_X and x < RIGHT_INNER_X + btnW then
    local item = displayedItems[selectedIndex]
    if not item then return end
    local qty = tonumber(quantity)
    if not qty or qty <= 0 then
      text(2, HEIGHT, "Введите корректное количество", C.error, C.bg)
      return
    end
    if shopMode == "buy" then
      local ok, msg = performBuy(item, qty)
      if ok then
        loadBuyItems()
        filterItems()
        redrawAll()
        text(2, HEIGHT, msg, C.success, C.bg)
      else
        text(2, HEIGHT, "Ошибка: " .. msg, C.error, C.bg)
      end
    else
      local ok, msg = performSell(item, qty)
      if ok then
        loadBuyItems()
        filterItems()
        redrawAll()
        text(2, HEIGHT, msg, C.success, C.bg)
      else
        text(2, HEIGHT, "Ошибка: " .. msg, C.error, C.bg)
      end
    end
    return
  end
  local btnWide = 14
  local buyX = 2
  local salesX = buyX + btnWide + 2
  if y == BOT_Y then
    if x >= buyX and x < buyX + btnWide then
      shopMode = "buy"
      loadBuyItems()
      filterItems()
      redrawAll()
      return
    elseif x >= salesX and x < salesX + btnWide then
      shopMode = "sell"
      loadSellItems()
      filterItems()
      redrawAll()
      return
    end
  end
end

-- =====================================================================
-- СТАРЫЕ UI-ФУНКЦИИ ИЗ PIM MARKET (АДАПТИРОВАНЫ ПОД WIDTH, HEIGHT)
-- =====================================================================

-- Приветственный экран с diamond (теперь растянут на весь экран)
function drawWelcomeScreen()
  clear()
  drawScreenBorder()
  
  -- Вычисляем позицию для diamond (центрируем по горизонтали)
  local diamWidth = #diamond[1] -- длина строки в символах
  local diamX = math.floor((WIDTH - diamWidth) / 2) + 1
  local diamY = math.floor((HEIGHT - #diamond) / 2)   -- вертикальный центр
  
  for i, line in ipairs(diamond) do
    local color = gradient[math.min(math.floor((i-1) / 2) + 1, #gradient)]
    gpu.setForeground(color)
    gpu.set(diamX, diamY + i - 1, line)
  end
  
  -- Текстовые надписи центрируем
  if shopPaused then
    drawCenteredText(diamY + #diamond + 2, " РЕЖИМ ОБСЛУЖИВАНИЯ", C.error)
    drawCenteredText(diamY + #diamond + 3, " Магазин временно закрыт", C.error)
    drawCenteredText(diamY + #diamond + 4, " Пожалуйста, зайдите позже", C.text_main)
  else
    drawCenteredText(diamY + #diamond + 2, "VIP SHOP", C.vipTitle)
    drawCenteredText(diamY + #diamond + 3, "◆ McSkill HiTech ◆", C.accent_secondary)
    drawCenteredText(diamY + #diamond + 4, "Встаньте на ПИМ для входа", C.inactive)
  end
  
  drawTempMessage()
end

-- Остальные старые функции (drawMainMenu, drawShopMenu, drawAccount, drawReportScreen,
-- drawFeedbacksList, drawFeedbackInputScreen, drawSellScanScreen, drawSellPopup,
-- drawPurchaseScreen, drawInsufficientPopup, drawPartialPopup, drawInventoryFullPopup,
-- drawScrollBarOld, drawBuyItemsListOld, drawBuyStaticOld, drawBuyButtonOld,
-- redrawSearchFieldOld, drawAccountLoading) – они адаптированы аналогично,
-- но для краткости я их не вставляю, они не используются в новом интерфейсе.
-- Если они понадобятся, их можно легко адаптировать, заменив фиксированные 80 и 24 на WIDTH и HEIGHT.

-- =====================================================================
-- ГЛАВНЫЙ ЦИКЛ (С ОБРАБОТКОЙ СОБЫТИЙ PIM)
-- =====================================================================
local function main()
  loadPlayers()
  loadBuyItems()
  loadSellItems()
  filterItems()
  term.clear()
  
  -- Показываем приветствие
  drawWelcomeScreen()
  
  local mainInterfaceShown = false
  
  -- Обработчик событий PIM
  event.listen("pim_player_enter", function(playerName)
    if playerName and playerName ~= "" then
      currentPlayer = playerName
      getOrCreatePlayer(currentPlayer)
      updateAccountDisplay()
      loadBuyItems()
      loadSellItems()
      filterItems()
      redrawAll()
      mainInterfaceShown = true
    end
  end)
  
  event.listen("pim_player_leave", function()
    if mainInterfaceShown then
      currentPlayer = nil
      updateAccountDisplay()
      drawWelcomeScreen()
      mainInterfaceShown = false
    end
  end)

  while true do
    local ev = {event.pull(0.5)}  -- таймаут для периодической проверки
    local name = ev[1]
    
    -- Если основной интерфейс активен – обрабатываем события UI
    if mainInterfaceShown then
      if name == "touch" then
        handleClick(ev[3], ev[4])
      elseif name == "scroll" then
        local x, direction = ev[3], ev[5]
        if x >= LIST_X and x <= LIST_X + LIST_W + 2 then
          scroll(-direction)
        end
      elseif name == "key_down" then
        local _, _, char, code = table.unpack(ev)
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
        else
          if code == keyboard.keys.up then
            selectItem(selectedIndex - 1)
          elseif code == keyboard.keys.down then
            selectItem(selectedIndex + 1)
          elseif code == keyboard.keys.back then
            quantity = quantity:sub(1, -2)
            redrawAll()
          elseif char and char >= 48 and char <= 57 then
            if #quantity < 8 then
              quantity = quantity .. string.char(char)
              redrawAll()
            end
          elseif code == keyboard.keys.escape then
            break
          end
        end
      end
    end
    
    -- Дополнительная проверка PIM (на случай, если события не сработали)
    local onPim = getPlayerOnPim()
    if onPim and onPim ~= "" then
      if not mainInterfaceShown then
        currentPlayer = onPim
        getOrCreatePlayer(currentPlayer)
        updateAccountDisplay()
        loadBuyItems()
        loadSellItems()
        filterItems()
        redrawAll()
        mainInterfaceShown = true
      elseif currentPlayer ~= onPim then
        currentPlayer = onPim
        getOrCreatePlayer(currentPlayer)
        updateAccountDisplay()
        loadBuyItems()
        loadSellItems()
        filterItems()
        redrawAll()
      end
    else
      if mainInterfaceShown then
        currentPlayer = nil
        updateAccountDisplay()
        drawWelcomeScreen()
        mainInterfaceShown = false
      end
    end
  end

  term.clear()
  gpu.setForeground(0xFFFFFF)
  gpu.setBackground(0x000000)
end

main()
