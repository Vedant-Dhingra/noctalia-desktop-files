--!nonstrict
-- Color helpers: settings hold either a palette role ("primary") or a hex value
-- ("#62a0ea"). ui.* props take both directly, but generated SVGs need literal
-- hex, so roles are resolved through noctalia.getColor.

local M = {}

local function isHex(value)
  return type(value) == "string" and string.match(value, "^#%x%x%x%x%x%x") ~= nil
end

-- Setting value -> "#rrggbb" (lowercase), or the fallback when unresolvable.
function M.toHex(value, fallback)
  if isHex(value) then
    return string.lower(string.sub(value, 1, 7))
  end
  if type(value) == "string" and value ~= "" then
    local hex = noctalia.getColor(value)
    if hex ~= nil then
      return string.lower(hex)
    end
  end
  return fallback
end

-- Setting value + opacity -> a ui.* color string. Roles keep the "/alpha"
-- suffix so they keep tracking the live palette; hex gets an alpha byte.
function M.withAlpha(value, alpha)
  alpha = math.clamp(alpha or 1, 0, 1)
  if isHex(value) then
    return string.sub(value, 1, 7) .. string.format("%02x", math.floor(alpha * 255 + 0.5))
  end
  if type(value) ~= "string" or value == "" then
    value = "surface"
  end
  return string.format("%s/%.3f", value, alpha)
end

local function parse(hex)
  return tonumber(string.sub(hex, 2, 3), 16), tonumber(string.sub(hex, 4, 5), 16), tonumber(string.sub(hex, 6, 7), 16)
end

-- Mixes toward white (t > 0) or black (t < 0) by |t|.
function M.shade(hex, t)
  local r, g, b = parse(hex)
  local target = t > 0 and 255 or 0
  local k = math.abs(t)
  local function mix(c)
    return math.floor(c + (target - c) * k + 0.5)
  end
  return string.format("#%02x%02x%02x", mix(r), mix(g), mix(b))
end

return M
