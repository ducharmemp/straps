local M = {}
local uv = vim.uv
local sessions = {}
local MAX_RECORD = 16 * 1024 * 1024

local function checked(value, err)
  if value == nil or value == false then error(tostring(err or "archive operation failed"), 0) end
  return value
end

local function valid_id(id)
  return type(id) == "string" and #id == 32 and id:match("^[0-9a-f]+$") ~= nil
end

local function directory(path, create)
  local st, err, code = uv.fs_lstat(path)
  if not st then
    if code ~= "ENOENT" then error(tostring(err), 0) end
    if not create then return path end
    checked(uv.fs_mkdir(path, 448))
    st = checked(uv.fs_lstat(path))
  end
  if st.type ~= "directory" or st.mode % 512 ~= 448 then error("archive directory must be private: " .. path, 0) end
  return path
end

local function sync_dir(path)
  local fd = checked(uv.fs_open(path, "r", 0))
  local ok, err = uv.fs_fsync(fd)
  local closed, cerr = uv.fs_close(fd)
  checked(ok, err)
  checked(closed, cerr)
end

local function storage(create)
  local base = checked(require("straps.state").session_dir(), "session storage unavailable")
  local root = directory(base .. "/.context-archive", create)
  local records, grants = directory(root .. "/records", create), directory(root .. "/grants", create)
  if create then
    for _, path in ipairs({ records, grants, root, base }) do
      local ok, err = pcall(sync_dir, path)
      if not ok then error("archive directory durability uncertain after synchronization failure at " .. path .. ": " .. tostring(err), 0) end
    end
  end
  return records, grants
end

local function write_new(path, text, opened)
  local fd = checked(uv.fs_open(path, "wx", 384))
  if opened then opened() end
  local ok, err = pcall(function()
    local offset = 0
    while offset < #text do
      local n = checked(uv.fs_write(fd, text:sub(offset + 1), offset))
      if n == 0 then error("archive write made no progress", 0) end
      offset = offset + n
    end
    checked(uv.fs_fsync(fd))
  end)
  local closed, cerr = uv.fs_close(fd)
  if not ok then error(err, 0) end
  checked(closed, cerr)
end

local function read_json(path)
  local st = checked(uv.fs_lstat(path))
  if st.type ~= "file" or st.mode % 512 ~= 384 or st.size > MAX_RECORD then
    error("invalid private archive file: " .. path, 0)
  end
  local fd = checked(uv.fs_open(path, "r", 0))
  local text, err = uv.fs_read(fd, st.size, 0)
  local closed, cerr = uv.fs_close(fd)
  checked(text, err)
  checked(closed, cerr)
  if #text ~= st.size then error("incomplete archive read", 0) end
  return vim.json.decode(text)
end

local function identity(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then error("invalid archive session", 0) end
  local name = vim.api.nvim_buf_get_name(bufnr)
  if vim.bo[bufnr].buftype == "" and name ~= "" then
    return "file:" .. vim.fn.fnamemodify(name, ":p")
  end
  local token = vim.b[bufnr].straps_archive_identity
  if not token then
    token = checked(uv.random(16)):gsub(".", function(c) return ("%02x"):format(c:byte()) end)
    vim.b[bufnr].straps_archive_identity = token
  end
  return "ephemeral:" .. token
end

local function grant_path(bufnr, create)
  local _, dir = storage(create)
  local key = identity(bufnr)
  if key:sub(1, 5) ~= "file:" then return nil, key end
  return dir .. "/" .. vim.fn.sha256(key) .. ".json", key
end

local function read_grants(path, key)
  local refs = {}
  if not path then return refs end
  local st, err, code = uv.fs_lstat(path)
  if not st then
    if code == "ENOENT" then return refs end
    error(tostring(err), 0)
  end
  local data = read_json(path)
  if type(data) ~= "table" or data.version ~= 1 or data.session ~= key or type(data.refs) ~= "table" then
    error("invalid archive grants", 0)
  end
  local count = 0
  for index, id in pairs(data.refs) do
    if type(index) ~= "number" or index < 1 or index % 1 ~= 0 or not valid_id(id) then
      error("invalid archive grant ID", 0)
    end
    count = count + 1
    refs[id] = true
  end
  if count ~= #data.refs then error("invalid archive grants", 0) end
  return refs
end

local function load_grants(bufnr)
  local key = identity(bufnr)
  local saved = sessions[bufnr]
  if saved and saved.key == key then return saved end
  local path = grant_path(bufnr)
  saved = { key = key, refs = read_grants(path, key) }
  sessions[bufnr] = saved
  return saved
end

local function save_grants(bufnr, refs)
  local path, key = grant_path(bufnr, true)
  local merged = vim.deepcopy(refs)
  if path then
    local lock = path .. ".lock"
    local fd, err = uv.fs_open(lock, "wx", 384)
    if not fd then error("archive grants lock unavailable: " .. tostring(err), 0) end
    local tmp, owned_tmp, renamed
    local ok, failure = pcall(function()
      merged = read_grants(path, key)
      for id in pairs(refs) do merged[id] = true end
      local ids = vim.tbl_keys(merged)
      table.sort(ids)
      tmp = path .. "." .. checked(uv.random(16)):gsub(".", function(c) return ("%02x"):format(c:byte()) end)
      write_new(tmp, vim.json.encode({ version = 1, session = key, refs = ids }), function() owned_tmp = true end)
      checked(uv.fs_rename(tmp, path))
      owned_tmp, renamed = false, true
      sync_dir(vim.fn.fnamemodify(path, ":h"))
    end)
    local failures = {}
    if not ok then failures[#failures + 1] = tostring(failure) end
    local function cleanup(fn, value)
      local clean, reason = pcall(function() checked(fn(value)) end)
      if not clean then failures[#failures + 1] = "archive grants cleanup failed: " .. tostring(reason) end
    end
    if owned_tmp then cleanup(uv.fs_unlink, tmp) end
    cleanup(uv.fs_close, fd)
    cleanup(uv.fs_unlink, lock)
    if #failures > 0 then
      local prefix = renamed and "archive grants durability uncertain after rename: " or ""
      error(prefix .. table.concat(failures, "; "), 0)
    end
  end
  sessions[bufnr] = { key = key, refs = merged }
  return true
end

local function record(id)
  if not valid_id(id) then error("invalid archive ID", 0) end
  local dir = storage()
  local value = read_json(dir .. "/" .. id .. ".json")
  if type(value) ~= "table" or value.version ~= 1 or value.id ~= id or type(value.sources) ~= "table"
    or type(value.children) ~= "table" then error("invalid archive record", 0) end
  for _, source in ipairs(value.sources) do
    if type(source) ~= "table" or type(source.kind) ~= "string" or type(source.text) ~= "string" then
      error("invalid archive source", 0)
    end
  end
  for _, child in ipairs(value.children) do
    if not valid_id(child) then error("invalid archive child", 0) end
  end
  return value
end

local function authorized(bufnr, wanted)
  if not valid_id(wanted) then error("invalid archive ID", 0) end
  local refs = load_grants(bufnr).refs
  if refs[wanted] then return true end
  local seen, count = {}, 0
  local function visit(id, depth)
    if seen[id] then return false end
    count = count + 1
    if depth > 32 or count > 4096 then error("archive ancestry exceeds traversal limit", 0) end
    seen[id] = true
    for _, child in ipairs(record(id).children) do
      if child == wanted or visit(child, depth + 1) then return true end
    end
    return false
  end
  for id in pairs(refs) do if visit(id, 0) then return true end end
  error("archive is not authorized for this session", 0)
end

local function safe(fn)
  return function(...)
    local ok, value = pcall(fn, ...)
    if ok then return value end
    return nil, tostring(value)
  end
end

local function integer(value, default, maximum)
  value = value == nil and default or value
  if type(value) ~= "number" or value ~= value or value < 1 or value % 1 ~= 0 or value > maximum then
    error("invalid archive pagination", 0)
  end
  return value
end

M.receipt = function(id)
  if not valid_id(id) then error("invalid archive ID", 0) end
  return "[straps-context:" .. id .. "]"
end

M.persist = safe(function(bufnr) return save_grants(bufnr, load_grants(bufnr).refs) end)
M.restore = safe(function(bufnr)
  if identity(bufnr):sub(1, 5) == "file:" then sessions[bufnr] = nil end
  load_grants(bufnr)
  return true
end)

M.create = safe(function(bufnr, input)
  local refs = vim.deepcopy(load_grants(bufnr).refs)
  if type(input) ~= "table" or type(input.sources) ~= "table" or #input.sources == 0 then
    error("archive requires original sources", 0)
  end
  local value = vim.deepcopy(input)
  value.children = value.children or {}
  if type(value.children) ~= "table" then error("invalid archive children", 0) end
  for _, source in ipairs(value.sources) do
    if type(source) ~= "table" or type(source.kind) ~= "string" or type(source.text) ~= "string" then
      error("archive sources require kind and text", 0)
    end
  end
  for _, child in ipairs(value.children) do authorized(bufnr, child) end
  value.version = 1
  value.id = checked(uv.random(16)):gsub(".", function(c) return ("%02x"):format(c:byte()) end)
  local text = vim.json.encode(value)
  if #text > MAX_RECORD then error("archive record exceeds size limit", 0) end
  local dir = storage(true)
  write_new(dir .. "/" .. value.id .. ".json", text)
  sync_dir(dir)
  refs[value.id] = true
  save_grants(bufnr, refs)
  return value.id
end)

M.get = safe(function(bufnr, id)
  authorized(bufnr, id)
  return record(id)
end)

local function source_metadata(source)
  local out = {}
  if #source.kind > 64 then error("archive source role exceeds metadata limit", 0) end
  out.kind = source.kind
  if source.attrs ~= nil then
    if type(source.attrs) ~= "table" then error("invalid archive source attributes", 0) end
    local attrs = {}
    for _, key in ipairs({ "name", "id" }) do
      local value = source.attrs[key]
      if value ~= nil then
        if type(value) ~= "string" or #value > 256 then error("invalid archive tool identity", 0) end
        attrs[key] = value
      end
    end
    if source.attrs.is_error ~= nil then
      if type(source.attrs.is_error) ~= "boolean" then error("invalid archive error status", 0) end
      attrs.is_error = source.attrs.is_error
    end
    if next(attrs) then out.attrs = attrs end
  end
  for _, key in ipairs({ "first_block", "last_block" }) do
    local value = source[key]
    if value ~= nil then out[key] = integer(value, nil, 9007199254740991) end
  end
  if #vim.json.encode(out) > 2048 then error("archive source metadata exceeds limit", 0) end
  return out
end

M.list = safe(function(bufnr, id, offset, limit)
  authorized(bufnr, id)
  offset, limit = integer(offset, 1, MAX_RECORD), integer(limit, 20, 100)
  local value, out, children = record(id), {}, {}
  local total = #value.sources + #value.children
  local last = math.min(total, offset + limit - 1)
  for i = offset, last do
    if i <= #value.sources then
      local source = value.sources[i]
      local metadata = source_metadata(source)
      metadata.index, metadata.bytes = i, #source.text
      out[#out + 1] = metadata
    else
      children[#children + 1] = value.children[i - #value.sources]
    end
  end
  return { id = id, sources = out, children = children, offset = offset,
    next_offset = last < total and last + 1 or nil, total = total }
end)

M.retrieve = safe(function(bufnr, id, source_index, offset, limit)
  authorized(bufnr, id)
  source_index = integer(source_index, 1, MAX_RECORD)
  offset, limit = integer(offset, 1, MAX_RECORD), integer(limit, 4096, 16384)
  local source = record(id).sources[source_index]
  if not source then error("archive source does not exist", 0) end
  local first = source.text:byte(offset)
  if first and first >= 128 and first < 192 then error("archive offset splits a UTF-8 character", 0) end
  local finish = math.min(#source.text, offset + limit - 1)
  while finish < #source.text do
    local following = source.text:byte(finish + 1)
    if following < 128 or following >= 192 then break end
    finish = finish - 1
  end
  if finish < offset and offset <= #source.text then error("archive limit cannot fit the next UTF-8 character", 0) end
  local text = source.text:sub(offset, finish)
  local next_offset = offset + #text
  local metadata = source_metadata(source)
  metadata.id, metadata.source_index, metadata.text = id, source_index, text
  metadata.offset, metadata.next_offset = offset, next_offset <= #source.text and next_offset or nil
  metadata.total, metadata.continued = #source.text, offset > 1 or next_offset <= #source.text
  return metadata
end)

local function referenced(parent, cutoff)
  local blocks = require("straps.state").list_blocks(parent)
  cutoff = cutoff == nil and #blocks or cutoff
  if type(cutoff) ~= "number" or cutoff < 0 or cutoff % 1 ~= 0 or cutoff > #blocks then
    error("invalid archive fork cutoff", 0)
  end
  local ids, seen = {}, {}
  for i = 1, cutoff do
    local b = blocks[i]
    local first = vim.api.nvim_buf_get_lines(parent, b.first_lnum - 1, b.first_lnum, false)[1] or ""
    local id
    if b.kind == "tool_result" then
      id = first:match("^%[straps%-context:([^%]]+)%] archived tool evidence; tool=.-; bytes=%d+$")
    elseif b.kind == "assistant" then
      id = first:match("^Assistant summary of archived assistant claims and tool evidence %[straps%-context:([^%]]+)%]$")
    end
    if id and not seen[id] then
      authorized(parent, id)
      record(id)
      ids[#ids + 1], seen[id] = id, true
    end
  end
  return ids
end

M.referenced = safe(referenced)

M.inherit = safe(function(parent, child, cutoff)
  local ids = referenced(parent, cutoff)
  local refs = vim.deepcopy(load_grants(child).refs)
  for _, id in ipairs(ids) do refs[id] = true end
  return save_grants(child, refs)
end)

return M
