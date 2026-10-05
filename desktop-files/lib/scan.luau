--!nonstrict
-- Desktop folder scanning: directory listing, mime detection, .desktop parsing.

local M = {}

local MIME_BATCH = 128

local EXT_MIMES = {
  png = "image/png",
  jpg = "image/jpeg",
  jpeg = "image/jpeg",
  webp = "image/webp",
  gif = "image/gif",
  bmp = "image/bmp",
  svg = "image/svg+xml",
  jxl = "image/jxl",
  pdf = "application/pdf",
  txt = "text/plain",
  md = "text/markdown",
  zip = "application/zip",
  gz = "application/gzip",
  xz = "application/x-xz",
  tar = "application/x-tar",
  mp3 = "audio/mpeg",
  flac = "audio/flac",
  ogg = "audio/ogg",
  wav = "audio/x-wav",
  mp4 = "video/mp4",
  mkv = "video/x-matroska",
  webm = "video/webm",
  desktop = "application/x-desktop",
}

local hasFile = nil

-- Returns name -> { name, path, isDir, mtime } or nil when the folder is
-- missing or unreadable.
function M.list(dir, showHidden)
  local names = noctalia.listDir(dir)
  if names == nil then
    return nil
  end
  local entries = {}
  for _, name in ipairs(names) do
    if showHidden or string.sub(name, 1, 1) ~= "." then
      local path = dir .. "/" .. name
      local info = noctalia.fileInfo(path)
      if info ~= nil then
        entries[name] = { name = name, path = path, isDir = info.isDir == true, mtime = info.mtime or 0 }
      end
    end
  end
  return entries
end

function M.mimeFromExtension(name)
  local ext = string.match(name, "%.([^./]+)$")
  if ext == nil then
    return nil
  end
  return EXT_MIMES[string.lower(ext)]
end

-- Detects mime types for `paths` (array) and calls cb(path -> mime) once per
-- batch. Falls back to the extension map when `file` is unavailable.
function M.detectMimes(paths, cb)
  if #paths == 0 then
    return
  end
  if hasFile == nil then
    hasFile = noctalia.commandExists("file")
  end
  if not hasFile then
    local result = {}
    for _, path in ipairs(paths) do
      result[path] = M.mimeFromExtension(path)
    end
    cb(result)
    return
  end

  for start = 1, #paths, MIME_BATCH do
    local batch = {}
    local argv = { "file", "-L", "-b", "--mime-type", "--" }
    for i = start, math.min(start + MIME_BATCH - 1, #paths) do
      table.insert(batch, paths[i])
      table.insert(argv, paths[i])
    end
    local accepted = noctalia.runAsync(argv, function(res)
      local result = {}
      local i = 1
      for line in string.gmatch(res.stdout or "", "[^\n]+") do
        local path = batch[i]
        if path == nil then
          break
        end
        local mime = noctalia.string.trim(line)
        if not string.match(mime, "^[%w%-%.+]+/[%w%-%.+]+$") then
          mime = M.mimeFromExtension(path)
        end
        result[path] = mime
        i += 1
      end
      for j = i, #batch do
        result[batch[j]] = M.mimeFromExtension(batch[j])
      end
      cb(result)
    end)
    if not accepted then
      local result = {}
      for _, path in ipairs(batch) do
        result[path] = M.mimeFromExtension(path)
      end
      cb(result)
    end
  end
end

-- Parses the [Desktop Entry] group of a .desktop file.
function M.parseDesktopEntry(path)
  local raw = noctalia.readFile(path)
  if raw == nil then
    return nil
  end
  local entry = { name = nil, icon = nil, hidden = false }
  local inGroup = false
  for line in string.gmatch(raw, "[^\r\n]+") do
    local group = string.match(line, "^%[(.+)%]%s*$")
    if group ~= nil then
      inGroup = group == "Desktop Entry"
    elseif inGroup then
      local key, value = string.match(line, "^([%w%-]+)%s*=%s*(.-)%s*$")
      if key == "Name" then
        entry.name = value
      elseif key == "Icon" then
        entry.icon = value
      elseif key == "NoDisplay" or key == "Hidden" then
        entry.hidden = entry.hidden or value == "true"
      end
    end
  end
  return entry
end

return M
