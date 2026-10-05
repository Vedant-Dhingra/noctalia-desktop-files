--!nonstrict
-- Icon slot model. Each item owns one cell: { page, col, row, ox, oy }, all
-- 1-based except the pixel offsets (ox, oy), which only apply with snap off.
-- New items fill the first free cell column-major (top-left, downward), like
-- GNOME/Nautilus desktops.

local M = {}

local VERSION = 1

local function key(page, col, row)
  return page .. ":" .. col .. ":" .. row
end
M.key = key

function M.load(path)
  local raw = noctalia.readFile(path)
  if raw ~= nil then
    local data = noctalia.json.decode(raw)
    if type(data) == "table" and data.version == VERSION and type(data.items) == "table" then
      return data.items
    end
  end
  return {}
end

function M.save(path, items)
  local encoded = noctalia.json.encode({ version = VERSION, items = items }, true)
  if encoded == nil then
    return false
  end
  local ok, err = noctalia.writeFile(path, encoded)
  if not ok then
    noctalia.log("desktop-files: failed to save layout: " .. tostring(err))
  end
  return ok
end

-- "p:c:r" -> name
function M.index(items)
  local idx = {}
  for name, slot in pairs(items) do
    idx[key(slot.page, slot.col, slot.row)] = name
  end
  return idx
end

function M.pageCount(items)
  local count = 1
  for _, slot in pairs(items) do
    if slot.page > count then
      count = slot.page
    end
  end
  return count
end

local function firstFree(idx, cols, rows, fromPage)
  local page = fromPage or 1
  while true do
    for col = 1, cols do
      for row = 1, rows do
        if idx[key(page, col, row)] == nil then
          return page, col, row
        end
      end
    end
    page += 1
  end
end

local function validSlot(slot, cols, rows)
  return type(slot) == "table"
    and type(slot.page) == "number" and slot.page >= 1
    and type(slot.col) == "number" and slot.col >= 1 and slot.col <= cols
    and type(slot.row) == "number" and slot.row >= 1 and slot.row <= rows
end

-- Brings `items` in line with the current file list (`ordered`, an array of
-- names in placement order) and grid size. Returns true when anything changed.
function M.reconcile(items, ordered, cols, rows)
  local changed = false
  local present = {}
  for _, name in ipairs(ordered) do
    present[name] = true
  end

  for name in pairs(items) do
    if not present[name] then
      items[name] = nil
      changed = true
    end
  end

  -- Keep valid, non-colliding slots; collect the rest for re-placement.
  local idx = {}
  local homeless = {}
  for _, name in ipairs(ordered) do
    local slot = items[name]
    if slot ~= nil then
      local k = validSlot(slot, cols, rows) and key(slot.page, slot.col, slot.row) or nil
      if k ~= nil and idx[k] == nil then
        idx[k] = name
      else
        table.insert(homeless, name)
      end
    else
      table.insert(homeless, name)
    end
  end

  for _, name in ipairs(homeless) do
    local old = items[name]
    local fromPage = (type(old) == "table" and type(old.page) == "number" and old.page >= 1) and old.page or 1
    local page, col, row = firstFree(idx, cols, rows, fromPage)
    items[name] = { page = page, col = col, row = row, ox = 0, oy = 0 }
    idx[key(page, col, row)] = name
    changed = true
  end

  -- Drop empty pages between occupied ones so paging never shows blank pages.
  local used = {}
  for _, slot in pairs(items) do
    used[slot.page] = true
  end
  local remap, nextPage = {}, 1
  for page = 1, M.pageCount(items) do
    if used[page] then
      remap[page] = nextPage
      nextPage += 1
    end
  end
  for _, slot in pairs(items) do
    local target = remap[slot.page]
    if target ~= slot.page then
      slot.page = target
      changed = true
    end
  end

  return changed
end

-- Moves `name` to a cell, swapping with the current occupant.
function M.move(items, name, page, col, row, ox, oy)
  local slot = items[name]
  if slot == nil then
    return
  end
  local idx = M.index(items)
  local other = idx[key(page, col, row)]
  if other ~= nil and other ~= name then
    local o = items[other]
    o.page, o.col, o.row = slot.page, slot.col, slot.row
  end
  slot.page, slot.col, slot.row = page, col, row
  slot.ox, slot.oy = ox or 0, oy or 0
end

return M
