--!nonstrict
-- Icon resolution. First match wins:
--   1. image thumbnail (the file itself)
--   2. .desktop launcher icon
--   3. icon-theme icon for the mime type (not recolorable)
--   4. custom folder/file image, else the recolored Adwaita folder/file SVG
--
-- ui.image has no tint, so the default icons are SVG templates with color
-- placeholders, written to the plugin data dir once per color. The color is in
-- the filename, so a theme change produces a new path and the image reloads.

local color = require("./color.luau")

local M = {}

local THUMB_MIMES = {
  ["image/png"] = true,
  ["image/jpeg"] = true,
  ["image/webp"] = true,
  ["image/gif"] = true,
  ["image/bmp"] = true,
  ["image/svg+xml"] = true,
  ["image/jxl"] = true,
}

-- Generic mimes would resolve to the theme's plain document icon; they use the
-- recolorable default instead.
local GENERIC_MIMES = {
  ["text/plain"] = true,
  ["application/octet-stream"] = true,
  ["inode/x-empty"] = true,
  ["application/x-empty"] = true,
}

local FALLBACK_FOLDER = "#62a0ea"
local FALLBACK_FILE = "#9a9996"

local templates = {}
local generated = {} -- "<kind>-<hex>" -> path
local themed = {} -- "<name>@<size>" -> path or false

local function template(kind)
  if templates[kind] == nil then
    templates[kind] = noctalia.readFile("assets/" .. kind .. ".svg.tmpl") or ""
  end
  return templates[kind]
end

local function iconDir()
  local base = noctalia.pluginDataDir()
  if base == nil then
    return nil
  end
  local dir = base .. "/icons"
  noctalia.mkdirAll(dir)
  return dir
end

local function fill(svg, vars)
  return (string.gsub(svg, "{{(%w+)}}", function(name)
    return vars[name] or "#ff00ff"
  end))
end

local function recolored(kind, hex)
  local id = kind .. "-" .. string.sub(hex, 2)
  if generated[id] ~= nil then
    return generated[id]
  end
  local dir = iconDir()
  if dir == nil then
    return nil
  end
  local path = dir .. "/" .. id .. ".svg"
  if not noctalia.fileExists(path) then
    local vars
    if kind == "folder" then
      -- Offsets measured from Adwaita's #62a0ea folder palette.
      vars = {
        base = hex,
        back = color.shade(hex, -0.12),
        top = color.shade(hex, 0.45),
        hi1 = color.shade(hex, 0.5),
        hi2 = color.shade(hex, 0.55),
      }
    else
      vars = { paper = color.shade(hex, 0.88), lines = color.shade(hex, 0.45) }
    end
    local ok = noctalia.writeFile(path, fill(template(kind), vars))
    if not ok then
      return nil
    end
  end
  generated[id] = path
  return path
end

local function themedIcon(name, size)
  if name == nil or name == "" then
    return nil
  end
  local id = name .. "@" .. size
  if themed[id] == nil then
    themed[id] = noctalia.appIconPath(name, size) or false
  end
  return themed[id] or nil
end

-- Hex colors of the two default icons, for change detection on theme switch.
function M.defaultColors(cfg)
  return color.toHex(cfg.folderColor, FALLBACK_FOLDER), color.toHex(cfg.fileIconColor, FALLBACK_FILE)
end

-- Returns { path = string, thumb = bool } for an item.
function M.resolve(item, cfg)
  local size = cfg.iconSize

  if not item.isDir then
    if cfg.showThumbnails and item.mime ~= nil and THUMB_MIMES[item.mime] then
      return { path = item.path, thumb = true }
    end

    if item.desktopEntry ~= nil then
      local icon = item.desktopEntry.icon
      if icon ~= nil and string.sub(icon, 1, 1) == "/" and noctalia.fileExists(icon) then
        return { path = icon, thumb = false }
      end
      local path = themedIcon(icon, size)
      if path ~= nil then
        return { path = path, thumb = false }
      end
    end

    if cfg.themedTypeIcons and item.mime ~= nil and not GENERIC_MIMES[item.mime] then
      local name = string.gsub(item.mime, "/", "-")
      local path = themedIcon(name, size)
      if path == nil then
        local major = string.match(item.mime, "^([^/]+)/")
        if major ~= nil and major ~= "text" and major ~= "application" then
          path = themedIcon(major .. "-x-generic", size)
        end
      end
      if path ~= nil then
        return { path = path, thumb = false }
      end
    end
  end

  if item.isDir then
    if cfg.customFolderIcon ~= "" then
      return { path = cfg.customFolderIcon, thumb = false }
    end
    return { path = recolored("folder", color.toHex(cfg.folderColor, FALLBACK_FOLDER)) or "", thumb = false }
  end
  if cfg.customFileIcon ~= "" then
    return { path = cfg.customFileIcon, thumb = false }
  end
  return { path = recolored("file", color.toHex(cfg.fileIconColor, FALLBACK_FILE)) or "", thumb = false }
end

return M
