--!nonstrict
-- Desktop Files — desktop widget entry.
--
-- Mirrors the Desktop folder as a paginated icon grid.
--   Normal mode:  click selects, double-click opens.
--   Arrange mode (lock button / IPC): click picks an icon up, click drops it.
--     Hovering the left/right edge while carrying flips pages after
--     edge_flip_delay_ms; hovering a page dot jumps to that page. Dropping on an
--     occupied cell swaps the two icons. With snap off, the drop position inside
--     the cell follows the pointer.
--
-- IPC (noctalia msg plugin vedantd/desktop-files:desktop focused <event> [arg]):
--   next | prev           wrap around at the ends
--   page <n>              1-based, clamped to the existing pages
--   first | last
--   arrange [on|off|toggle]
--   cancel                drop nothing, end the current carry
--   rescan

local scan = require("./lib/scan.luau")
local layoutLib = require("./lib/layout.luau")
local icons = require("./lib/icons.luau")
local view = require("./lib/view.luau")

local SCAN_INTERVAL_MS = 2000
local IDLE_TICK_MS = 1000
local DWELL_TICK_MS = 50

local function cfgString(key, fallback)
  local v = noctalia.getConfig(key)
  if type(v) ~= "string" then
    return fallback
  end
  return v
end

local function cfgNumber(key, fallback)
  local v = noctalia.getConfig(key)
  if type(v) ~= "number" then
    return fallback
  end
  return v
end

local function cfgBool(key, fallback)
  local v = noctalia.getConfig(key)
  if type(v) ~= "boolean" then
    return fallback
  end
  return v
end

local function expandOptional(path)
  path = noctalia.string.trim(path or "")
  if path == "" then
    return ""
  end
  return noctalia.expandPath(path)
end

local cfg = {
  columns = math.floor(cfgNumber("columns", 8)),
  rows = math.floor(cfgNumber("rows", 5)),
  gridSize = math.floor(cfgNumber("grid_size", 96)),
  iconSize = math.floor(cfgNumber("icon_size", 48)),
  snapToGrid = cfgBool("snap_to_grid", true),
  edgeFlipDelayMs = cfgNumber("edge_flip_delay_ms", 600),
  doubleClickMs = cfgNumber("double_click_ms", 400),
  showHidden = cfgBool("show_hidden", false),
  backgroundColor = cfgString("background_color", "surface"),
  backgroundOpacity = cfgNumber("background_opacity", 0.35),
  folderColor = cfgString("folder_color", "primary"),
  fileIconColor = cfgString("file_icon_color", "secondary"),
  labelColor = cfgString("label_color", "on_surface"),
  customFolderIcon = expandOptional(cfgString("custom_folder_icon", "")),
  customFileIcon = expandOptional(cfgString("custom_file_icon", "")),
  showThumbnails = cfgBool("show_thumbnails", true),
  themedTypeIcons = cfgBool("themed_type_icons", true),
}
if cfg.labelColor == "" then
  cfg.labelColor = "on_surface"
end

-- ── Desktop folder ──────────────────────────────────────────────────────────

-- XDG_DESKTOP_DIR from user-dirs.dirs, else ~/Desktop.
local function xdgDesktopDir()
  local home = noctalia.getenv("HOME") or noctalia.expandPath("~")
  local configHome = noctalia.getenv("XDG_CONFIG_HOME")
  if configHome == nil or configHome == "" then
    configHome = home .. "/.config"
  end
  local raw = noctalia.readFile(configHome .. "/user-dirs.dirs")
  if raw ~= nil then
    local value = string.match(raw, "\nXDG_DESKTOP_DIR=\"([^\"]*)\"") or string.match(raw, "^XDG_DESKTOP_DIR=\"([^\"]*)\"")
    if value ~= nil and value ~= "" then
      value = string.gsub(value, "^%$HOME", home)
      return value
    end
  end
  return home .. "/Desktop"
end

local desktopDir = expandOptional(cfgString("desktop_path", ""))
if desktopDir == "" then
  desktopDir = xdgDesktopDir()
end
desktopDir = string.gsub(desktopDir, "/+$", "")

local layoutId = string.gsub(cfgString("layout_id", "default"), "[^%w%-_]", "_")
if layoutId == "" then
  layoutId = "default"
end
local layoutPath = nil
do
  local dataDir = noctalia.pluginDataDir()
  if dataDir ~= nil then
    layoutPath = dataDir .. "/layout-" .. layoutId .. ".json"
  end
end

-- ── State ───────────────────────────────────────────────────────────────────

local items = {} -- name -> { name, path, isDir, mtime, mime, desktopEntry, label }
local slots = layoutPath and layoutLib.load(layoutPath) or {}
local missing = false
local page = 1
local arrange = false
local carry = nil -- name of the carried item
local target = nil -- { page, col, row, ox, oy } under the pointer while carrying
local selected = nil
local edge = nil -- { side, since } while dwelling on an edge
local lastClick = { name = nil, t = 0 }
local lastScan = 0
local folderHex, fileHex = icons.defaultColors(cfg)
local metrics = view.metrics(cfg)

local function realPageCount()
  return layoutLib.pageCount(slots)
end

-- While carrying, one extra empty page is available as a drop target.
local function pageCount()
  return realPageCount() + (carry ~= nil and 1 or 0)
end

local function save()
  if layoutPath ~= nil then
    layoutLib.save(layoutPath, slots)
  end
end

local function setTickRate()
  noctalia.setUpdateInterval(edge ~= nil and DWELL_TICK_MS or IDLE_TICK_MS)
end

-- ── Rendering ───────────────────────────────────────────────────────────────

local render -- forward

local ctx = {
  cfg = cfg,
  iconFor = function(item)
    return icons.resolve(item, cfg)
  end,
}

local function goToPage(n)
  local count = pageCount()
  n = math.clamp(math.floor(n), 1, count)
  if n ~= page then
    page = n
    target = nil
    render()
  end
end

local function stepPage(delta)
  local count = pageCount()
  if count <= 1 then
    return
  end
  page = ((page - 1 + delta) % count) + 1
  target = nil
  render()
end

local function endCarry()
  carry = nil
  target = nil
  edge = nil
  setTickRate()
  page = math.clamp(page, 1, pageCount())
end

local function setArrange(on)
  arrange = on
  if not on then
    endCarry()
  end
  render()
end

local function openItem(name)
  local item = items[name]
  if item == nil then
    return
  end
  local argv
  if item.desktopEntry ~= nil and noctalia.commandExists("gio") then
    argv = { "gio", "launch", item.path }
  else
    argv = { "xdg-open", item.path }
  end
  if not noctalia.runAsync(argv) then
    noctalia.notifyError("Desktop Files", "Could not open " .. name)
  end
end

local function drop(cell)
  local name = carry
  local slot = slots[name]
  local ox, oy = 0, 0
  if not cfg.snapToGrid then
    if target ~= nil and target.page == cell.page and target.col == cell.col and target.row == cell.row then
      ox, oy = target.ox, target.oy
    elseif slot.page == cell.page and slot.col == cell.col and slot.row == cell.row then
      ox, oy = slot.ox, slot.oy
    end
  end
  layoutLib.move(slots, name, cell.page, cell.col, cell.row, ox, oy)
  endCarry()
  -- Moving the last icon off a page compacts the pages; follow the icon.
  local names = {}
  for n in pairs(slots) do
    table.insert(names, n)
  end
  layoutLib.reconcile(slots, names, cfg.columns, cfg.rows)
  page = slots[name].page
  selected = name
  save()
  render()
end

function ctx.onCellClick(cell)
  local idx = layoutLib.index(slots)
  local name = idx[layoutLib.key(cell.page, cell.col, cell.row)]
  local now = noctalia.nowMs()

  -- The carried icon keeps its slot until dropped, so a quick second click on
  -- its home cell is a double-click: open it and cancel the carry.
  if name ~= nil and lastClick.name == name and now - lastClick.t <= cfg.doubleClickMs then
    lastClick = { name = nil, t = 0 }
    if carry ~= nil then
      endCarry()
    end
    selected = name
    render()
    openItem(name)
    return
  end
  lastClick = { name = name, t = now }

  if carry ~= nil then
    drop(cell)
    return
  end
  if arrange and name ~= nil then
    carry = name
    selected = name
    local slot = slots[name]
    target = { page = slot.page, col = slot.col, row = slot.row, ox = slot.ox or 0, oy = slot.oy or 0 }
    render()
    return
  end
  -- Clicking the selected icon again (outside the double-click window) deselects it.
  if selected == name then
    selected = nil
  else
    selected = name
  end
  render()
end

function ctx.onCellHover(cell, entered)
  if carry == nil or not entered then
    return
  end
  if target ~= nil and target.page == cell.page and target.col == cell.col and target.row == cell.row then
    return
  end
  -- Occupied cells swap and snapped cells center, so the offset starts at 0;
  -- free placement refines it from the tracking graphs.
  target = { page = cell.page, col = cell.col, row = cell.row, ox = 0, oy = 0 }
  render()
end

function ctx.onCellPointer(cell, x, y)
  if carry == nil then
    return
  end
  local ox, oy = view.offsetFor(metrics, x, y)
  if target ~= nil and target.page == cell.page and target.col == cell.col and target.row == cell.row
    and target.ox == ox and target.oy == oy then
    return
  end
  target = { page = cell.page, col = cell.col, row = cell.row, ox = ox, oy = oy }
  render()
end

function ctx.onEdgeHover(side, entered)
  if entered and carry ~= nil then
    edge = { side = side, since = noctalia.nowMs() }
  elseif not entered and edge ~= nil and edge.side == side then
    edge = nil
  else
    return
  end
  setTickRate()
  render()
end

function ctx.onEdgeClick(side)
  stepPage(side == "left" and -1 or 1)
end

function ctx.onDotClick(n)
  goToPage(n)
end

function ctx.onDotHover(n, entered)
  if entered and carry ~= nil then
    goToPage(n)
  end
end

function ctx.onPrev()
  stepPage(-1)
end

function ctx.onNext()
  stepPage(1)
end

function ctx.onToggleArrange()
  setArrange(not arrange)
end

render = function()
  page = math.clamp(page, 1, pageCount())
  ctx.items = items
  ctx.slots = slots
  ctx.page = page
  ctx.pageCount = pageCount()
  ctx.realPageCount = realPageCount()
  ctx.arrange = arrange
  ctx.carry = carry
  ctx.target = target
  ctx.selected = selected
  ctx.edge = edge
  if missing then
    ctx.message = noctalia.tr("missing", { path = desktopDir })
  elseif next(items) == nil then
    ctx.message = noctalia.tr("empty")
  else
    ctx.message = nil
  end
  desktopWidget.render(view.build(ctx))
end

-- ── Scanning ────────────────────────────────────────────────────────────────

local function placementOrder()
  local names = {}
  for name in pairs(items) do
    table.insert(names, name)
  end
  table.sort(names, function(a, b)
    local ia, ib = items[a], items[b]
    if ia.isDir ~= ib.isDir then
      return ia.isDir
    end
    local la, lb = string.lower(a), string.lower(b)
    if la ~= lb then
      return la < lb
    end
    return a < b
  end)
  return names
end

local function rescan()
  lastScan = noctalia.nowMs()
  local listed = scan.list(desktopDir, cfg.showHidden)
  if listed == nil then
    -- Keep saved positions: the folder may only be temporarily unavailable.
    local changed = not missing or next(items) ~= nil
    missing = true
    items = {}
    if carry ~= nil then
      endCarry()
    end
    if changed then
      render()
    end
    return
  end

  local changed = missing
  missing = false
  local needMime = {}

  for name, entry in pairs(listed) do
    local old = items[name]
    if old == nil or old.mtime ~= entry.mtime or old.isDir ~= entry.isDir then
      changed = true
      if not entry.isDir then
        entry.mime = scan.mimeFromExtension(name)
        if string.match(name, "%.desktop$") then
          local de = scan.parseDesktopEntry(entry.path)
          if de ~= nil then
            entry.desktopEntry = de
            entry.label = de.name
          end
        end
        table.insert(needMime, entry.path)
      end
      items[name] = entry
    end
  end
  for name in pairs(items) do
    if listed[name] == nil then
      items[name] = nil
      changed = true
      if selected == name then
        selected = nil
      end
      if carry == name then
        endCarry()
      end
    end
  end

  if changed then
    if layoutLib.reconcile(slots, placementOrder(), cfg.columns, cfg.rows) then
      save()
    end
    render()
  end

  if #needMime > 0 then
    local byPath = {}
    for _, item in pairs(items) do
      byPath[item.path] = item
    end
    scan.detectMimes(needMime, function(result)
      local dirty = false
      for path, mime in pairs(result) do
        local item = byPath[path]
        if item ~= nil and items[item.name] == item and mime ~= nil and item.mime ~= mime then
          item.mime = mime
          dirty = true
        end
      end
      if dirty then
        render()
      end
    end)
  end
end

-- ── Host callbacks ──────────────────────────────────────────────────────────

function update()
  local now = noctalia.nowMs()

  if edge ~= nil and carry ~= nil and now - edge.since >= cfg.edgeFlipDelayMs then
    edge.since = now -- keep flipping while the pointer stays on the edge
    stepPage(edge.side == "left" and -1 or 1)
  end

  if now - lastScan >= SCAN_INTERVAL_MS then
    rescan()
    -- Theme switches change role colors; regenerate the default icons.
    local f, fi = icons.defaultColors(cfg)
    if f ~= folderHex or fi ~= fileHex then
      folderHex, fileHex = f, fi
      render()
    end
  end
end

function onIpc(event, payload)
  local arg = noctalia.string.trim(payload or "")
  if event == "next" then
    stepPage(1)
  elseif event == "prev" or event == "previous" then
    stepPage(-1)
  elseif event == "page" or event == "goto" then
    local n = tonumber(arg)
    if n == nil then
      noctalia.log("desktop-files: 'page' needs a number, got '" .. arg .. "'")
      return
    end
    goToPage(n)
  elseif event == "first" then
    goToPage(1)
  elseif event == "last" then
    goToPage(realPageCount())
  elseif event == "arrange" then
    if arg == "on" then
      setArrange(true)
    elseif arg == "off" then
      setArrange(false)
    else
      setArrange(not arrange)
    end
  elseif event == "cancel" then
    if carry ~= nil then
      endCarry()
      render()
    end
  elseif event == "rescan" then
    rescan()
    render()
  else
    noctalia.log("desktop-files: unknown IPC event '" .. tostring(event) .. "'")
  end
end

setTickRate()
rescan()
render()
