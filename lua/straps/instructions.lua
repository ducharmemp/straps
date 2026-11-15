local M = {}

local function digest(parts)
  local framed = {}
  for i, part in ipairs(parts) do
    framed[i] = #part .. ":" .. part
  end
  return vim.fn.sha256(table.concat(framed))
end

local function unavailable(path)
  local stat = vim.uv.fs_stat(path)
  if not stat then return "missing" end
  local parts = { stat.type, tostring(stat.size), tostring(stat.mode) }
  for _, key in ipairs({ "mtime", "ctime" }) do
    local value = stat[key] or {}
    parts[#parts + 1] = tostring(value.sec)
    parts[#parts + 1] = tostring(value.nsec)
  end
  return digest(parts)
end

function M.discover(config)
  if config == nil then
    local ok, straps = pcall(require, "straps")
    config = (ok and type(straps) == "table" and rawget(straps, "config")) or {}
  end
  local cwd = vim.fn.getcwd()
  local cfg = vim.fn.stdpath("config")
  local home = vim.loop.os_homedir()
  local names = { "AGENTS.md", "CLAUDE.md" }
  local paths, seen = {}, {}
  local function add(path)
    if type(path) ~= "string" or path == "" then return end
    local abs = vim.fn.fnamemodify(path, ":p")
    if not seen[abs] then
      seen[abs] = true
      paths[#paths + 1] = abs
    end
  end
  local globals = {}
  if type(cfg) == "string" and cfg ~= "" then globals[#globals + 1] = cfg .. "/straps" end
  if type(home) == "string" and home ~= "" then globals[#globals + 1] = home end
  for _, dir in ipairs(globals) do
    for _, name in ipairs(names) do add(dir .. "/" .. name) end
  end
  for _, name in ipairs(names) do
    local found = vim.fs.find(name, { upward = true, path = cwd, type = "file", limit = math.huge })
    for i = #found, 1, -1 do add(found[i]) end
  end
  local config_parts = { cwd, type(cfg) == "string" and cfg or "", type(home) == "string" and home or "" }
  local extras = type(config.instructions_files) == "table" and config.instructions_files or {}
  for _, path in ipairs(extras) do
    config_parts[#config_parts + 1] = type(path)
    config_parts[#config_parts + 1] = type(path) == "string" and path or ""
    add(path)
  end
  local config_hash = digest(config_parts)
  local snapshot_parts = { config_hash }
  local sources, sections = {}, {}
  for _, path in ipairs(paths) do
    local canonical = vim.uv.fs_realpath(path) or path
    local file = io.open(path, "r")
    local text
    if file then
      text = file:read("*a")
      file:close()
    end
    snapshot_parts[#snapshot_parts + 1] = path
    snapshot_parts[#snapshot_parts + 1] = canonical
    snapshot_parts[#snapshot_parts + 1] = type(text) == "string" and "readable" or "unreadable"
    snapshot_parts[#snapshot_parts + 1] = type(text) == "string" and text or unavailable(path)
    if type(text) == "string" and text ~= "" then
      local hash = vim.fn.sha256(text)
      sources[#sources + 1] = {
        id = digest({ path, canonical, hash }), path = path, canonical_path = canonical,
        precedence = #sources + 1, hash = hash, text = text,
      }
      sections[#sections + 1] = "## " .. path .. "\n" .. text
    end
  end
  return { id = digest(snapshot_parts), config_hash = config_hash, sources = sources, presentation = table.concat(sections, "\n\n") }
end

return M
