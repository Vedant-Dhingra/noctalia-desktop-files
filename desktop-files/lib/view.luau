--!nonstrict
-- ui.* tree builder.
--
--   column (background)
--     row: [left edge] [grid] [right edge]
--     row: pager  (‹  • • •  ›        arrange)
--
-- Desktop widgets have no stacking or absolute positioning, so placement is
-- built from flex rows/columns with explicit sizes (flex children without one
-- collapse on desktop widgets). Free placement inside a cell uses leading
-- spacer boxes. Sub-cell pointer position comes from transparent ui.graph
-- regions: ui.graph is the only node that reports pointer coordinates, and its
-- input wrapper does not accept clicks, so clicks still reach the cell.

local color = require("./color.luau")
local layoutLib = require("./layout.luau")

local M = {}

local EDGE = 16
local PAD = 8
local PAGER_H = 36
local DOT = 10
local DOT_HIT = 22
local STEP = 4 -- free-placement quantum (px)

-- Geometry shared by rendering and pointer math.
function M.metrics(cfg)
  local g = cfg.gridSize
  local icon = math.min(cfg.iconSize, g - 8)
  local fontSize = math.clamp(math.floor(g / 8 + 0.5), 10, 14)
  local tileW = math.min(g - 4, math.max(icon + 24, 64))
  local tileH = math.min(g - 4, icon + 8 + fontSize * 2 + 8)
  return {
    grid = g,
    icon = icon,
    fontSize = fontSize,
    tileW = tileW,
    tileH = tileH,
    maxOx = g - tileW,
    maxOy = g - tileH,
  }
end

-- Pointer position in a cell -> quantized offset of the tile's top-left corner.
function M.offsetFor(m, cellX, cellY)
  local function q(v, max)
    v = math.clamp(v, 0, max)
    return math.clamp(math.floor(v / STEP + 0.5) * STEP, 0, max)
  end
  return q(cellX - m.tileW / 2, m.maxOx), q(cellY - m.tileH / 2, m.maxOy)
end

local function tile(ctx, m, item, opts)
  local res = ctx.iconFor(item)
  local labelText = item.label or item.name
  return ui.column({
    key = opts.key,
    width = m.tileW,
    height = m.tileH,
    gap = 4,
    paddingV = 4,
    align = "center",
    radius = 8,
    fill = opts.selected and "primary/0.25" or nil,
    opacity = opts.opacity,
  }, {
    ui.image({
      path = res.path,
      width = m.icon,
      height = m.icon,
      fit = res.thumb and "cover" or "contain",
      radius = res.thumb and 6 or 0,
    }),
    ui.label({
      text = labelText,
      fontSize = m.fontSize,
      color = ctx.cfg.labelColor,
      maxWidth = m.tileW - 4,
      maxLines = 2,
      textAlign = "center",
    }),
  })
end

-- A tile placed at (ox, oy) inside a grid×grid cell via spacer boxes.
local function placed(m, child, ox, oy)
  ox = math.clamp(ox or 0, 0, math.max(m.maxOx, 0))
  oy = math.clamp(oy or 0, 0, math.max(m.maxOy, 0))
  local rowChildren = {}
  if ox > 0 then
    table.insert(rowChildren, ui.box({ width = ox, height = m.tileH }))
  end
  table.insert(rowChildren, child)
  local colChildren = {}
  if oy > 0 then
    table.insert(colChildren, ui.box({ width = m.grid, height = oy }))
  end
  table.insert(colChildren, ui.row({ width = m.grid, height = m.tileH, align = "start" }, rowChildren))
  return colChildren
end

-- Transparent pointer-tracking region covering (x, y, w, h) of the cell.
local function tracker(ctx, cell, x, y, w, h)
  return ui.graph({
    width = w,
    height = h,
    values = { 0, 0 },
    color = "#00000000",
    lineWidth = 0,
    fillOpacity = 0,
    onPointerMove = function(nx, ny)
      ctx.onCellPointer(cell, x + tonumber(nx) * w, y + tonumber(ny) * h)
    end,
  })
end

-- Hovered empty cell during a free-placement carry: the footprint marker sits at
-- the target offset and tracking regions fill the rest of the cell, so the
-- pointer is always over some graph (the marker contains one too).
local function trackedTarget(ctx, m, cell, ox, oy)
  local g = m.grid
  local children = {}
  if oy > 0 then
    table.insert(children, tracker(ctx, cell, 0, 0, g, oy))
  end
  local mid = {}
  if ox > 0 then
    table.insert(mid, tracker(ctx, cell, 0, oy, ox, m.tileH))
  end
  table.insert(mid, ui.column({ width = m.tileW, height = m.tileH, fill = "primary/0.3", radius = 8,
                                border = "primary", borderWidth = 1 }, {
    tracker(ctx, cell, ox, oy, m.tileW, m.tileH),
  }))
  local right = g - ox - m.tileW
  if right > 0 then
    table.insert(mid, tracker(ctx, cell, ox + m.tileW, oy, right, m.tileH))
  end
  table.insert(children, ui.row({ width = g, height = m.tileH }, mid))
  local bottom = g - oy - m.tileH
  if bottom > 0 then
    table.insert(children, tracker(ctx, cell, 0, oy + m.tileH, g, bottom))
  end
  return children
end

local function cellNode(ctx, m, idx, page, col, row)
  local cfg = ctx.cfg
  local cell = { page = page, col = col, row = row }
  local name = idx[layoutLib.key(page, col, row)]
  local item = name and ctx.items[name] or nil
  local carry = ctx.carry
  local target = ctx.target
  local isTarget = carry ~= nil and target ~= nil and target.page == page and target.col == col and target.row == row
  local freeCarry = carry ~= nil and not cfg.snapToGrid

  local props = {
    key = "cell:" .. layoutLib.key(page, col, row),
    width = m.grid,
    height = m.grid,
    radius = 10,
    onClick = function() ctx.onCellClick(cell) end,
  }
  if carry ~= nil then
    props.onHover = function(state) ctx.onCellHover(cell, state == "true") end
  end

  local children
  if item ~= nil and name ~= carry then
    local slot = ctx.slots[name]
    local t = tile(ctx, m, item, { key = "tile:" .. name, selected = ctx.selected == name })
    if cfg.snapToGrid then
      props.align, props.justify = "center", "center"
      children = { t }
    else
      props.align = "start"
      children = placed(m, t, slot.ox, slot.oy)
    end
    if isTarget then
      props.fill = "primary/0.18" -- dropping here swaps
      props.border, props.borderWidth = "primary", 1
    end
  elseif item ~= nil then
    -- The carried item's home cell.
    if isTarget and freeCarry then
      props.align = "start"
      children = trackedTarget(ctx, m, cell, target.ox, target.oy)
    else
      local slot = ctx.slots[name]
      local t = tile(ctx, m, item, { key = "tile:" .. name, opacity = isTarget and 0.6 or 0.3 })
      if cfg.snapToGrid then
        props.align, props.justify = "center", "center"
        children = { t }
      else
        props.align = "start"
        children = freeCarry and { tracker(ctx, cell, 0, 0, m.grid, m.grid) } or placed(m, t, slot.ox, slot.oy)
      end
    end
  elseif carry ~= nil then
    -- Empty cell while carrying.
    if freeCarry then
      props.align = "start"
      if isTarget then
        children = trackedTarget(ctx, m, cell, target.ox, target.oy)
      else
        children = { tracker(ctx, cell, 0, 0, m.grid, m.grid) }
      end
    elseif isTarget then
      props.align, props.justify = "center", "center"
      children = { tile(ctx, m, ctx.items[carry], { key = "ghost", opacity = 0.6 }) }
    else
      children = {}
    end
  else
    children = {}
  end

  return ui.column(props, children)
end

local function gridNode(ctx, m)
  local cfg = ctx.cfg
  local w, h = cfg.columns * m.grid, cfg.rows * m.grid
  if ctx.message ~= nil then
    return ui.column({ width = w, height = h, align = "center", justify = "center" }, {
      ui.label({ text = ctx.message, fontSize = 14, color = cfg.labelColor, maxWidth = w - 32, textAlign = "center" }),
    })
  end
  local idx = layoutLib.index(ctx.slots)
  local rows = {}
  for row = 1, cfg.rows do
    local cells = {}
    for col = 1, cfg.columns do
      table.insert(cells, cellNode(ctx, m, idx, ctx.page, col, row))
    end
    table.insert(rows, ui.row({ key = "row:" .. row, width = w, height = m.grid }, cells))
  end
  return ui.column({ width = w, height = h }, rows)
end

local function edgeNode(ctx, side, height)
  local active = ctx.carry ~= nil
  local dwelling = ctx.edge ~= nil and ctx.edge.side == side
  return ui.column({
    key = "edge:" .. side,
    width = EDGE,
    height = height,
    radius = 6,
    fill = dwelling and "primary/0.45" or (active and "primary/0.15" or nil),
    onHover = function(state) ctx.onEdgeHover(side, state == "true") end,
    onClick = function() ctx.onEdgeClick(side) end,
  }, {})
end

local function pagerNode(ctx, width)
  local dots = {}
  for n = 1, ctx.pageCount do
    local current = n == ctx.page
    local spare = n > ctx.realPageCount -- the extra drop-target page while carrying
    table.insert(dots, ui.column({
      key = "dot:" .. n,
      width = DOT_HIT,
      height = DOT_HIT,
      align = "center",
      justify = "center",
      onClick = function() ctx.onDotClick(n) end,
      onHover = function(state) ctx.onDotHover(n, state == "true") end,
    }, {
      ui.box({
        width = DOT,
        height = DOT,
        radius = DOT / 2,
        fill = current and "primary" or (spare and "#00000000" or "on_surface/0.35"),
        border = spare and "primary" or nil,
        borderWidth = spare and 1 or nil,
      }),
    }))
  end

  local navEnabled = ctx.pageCount > 1
  return ui.row({ width = width, height = PAGER_H, align = "center", gap = 4 }, {
    ui.box({ width = 36, height = 1 }), -- balances the arrange button
    ui.spacer({ flexGrow = 1 }),
    ui.button({
      glyph = "chevron-left", variant = "ghost", controlSize = "sm", enabled = navEnabled,
      width = 32, height = 28, onClick = ctx.onPrev,
    }),
    ui.row({ height = DOT_HIT, align = "center" }, dots),
    ui.button({
      glyph = "chevron-right", variant = "ghost", controlSize = "sm", enabled = navEnabled,
      width = 32, height = 28, onClick = ctx.onNext,
    }),
    ui.spacer({ flexGrow = 1 }),
    ui.button({
      glyph = ctx.arrange and "lock-open" or "lock",
      variant = ctx.arrange and "primary" or "ghost",
      selected = ctx.arrange,
      controlSize = "sm",
      width = 36, height = 28,
      onClick = ctx.onToggleArrange,
    }),
  })
end

-- Natural content size; the host scales it into the user-placed box.
function M.size(cfg)
  local m = M.metrics(cfg)
  return cfg.columns * m.grid + 2 * EDGE + 2 * PAD, cfg.rows * m.grid + PAGER_H + 2 * PAD
end

function M.build(ctx)
  local cfg = ctx.cfg
  local m = M.metrics(cfg)
  local gridW, gridH = cfg.columns * m.grid, cfg.rows * m.grid
  local innerW = gridW + 2 * EDGE
  local width, height = M.size(cfg)

  return ui.column({
    width = width,
    height = height,
    padding = PAD,
    radius = 16,
    fill = color.withAlpha(cfg.backgroundColor, cfg.backgroundOpacity),
  }, {
    ui.row({ width = innerW, height = gridH }, {
      edgeNode(ctx, "left", gridH),
      gridNode(ctx, m),
      edgeNode(ctx, "right", gridH),
    }),
    pagerNode(ctx, innerW),
  })
end

return M
