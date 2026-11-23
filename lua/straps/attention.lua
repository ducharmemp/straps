local M = {}
local records = {}
local root = {}
local enabled = true
local stopped = false
local serial = 0
local nonce = tostring(vim.uv.os_getpid()) .. "-" .. tostring(vim.uv.hrtime())

local function send(record, state, kind)
  if type(vim.api.nvim_ui_send) ~= "function" then return end
  local payload = "\27]7501;app=straps" .. (record.id and (":id=" .. record.id) or "") .. ":state=" .. state
  if kind then payload = payload .. ":kind=" .. kind end
  local ok = pcall(vim.api.nvim_ui_send, payload .. "\27\\")
  if ok then record.published = state ~= "clear" end
end

local function waiting(record)
  local last
  for token in pairs(record.waits) do
    if not last or token.seq > last.seq then last = token end
  end
  return last
end

local function publish_root()
  if not enabled or stopped then return end
  local wait, completed, active
  for _, record in pairs(records) do
    if record.run or record.kind then
      active = true
      local token = waiting(record) or (record.kind and record)
      if token and (not wait or token.seq > wait.seq) then wait = token end
    elseif record.finished and (not completed or record.finished > completed.finished) then
      completed = record
    end
  end
  if wait then
    send(root, "blocked", wait.kind)
  elseif active then
    send(root, "working")
  elseif completed then
    send(root, completed.state)
  elseif root.published then
    send(root, "clear")
  end
end

local function publish(record)
  if not enabled or stopped then return end
  if record.run or record.kind then
    local last = waiting(record)
    send(record, last and "blocked" or record.state, last and last.kind or record.kind)
  elseif record.published then
    send(record, "clear")
  end
  publish_root()
end

local function clear(key)
  local record = records[key]
  if not record then return end
  if record.published then send(record, "clear") end
  records[key] = nil
  publish_root()
end

function M.start(bufnr, run)
  if stopped then return end
  local record = records[bufnr]
  if not record then
    record = { id = "straps/" .. nonce .. "/" .. bufnr }
    records[bufnr] = record
  end
  record.run, record.state, record.waits, record.finished = run, "working", {}, nil
  publish(record)
end

function M.finish(bufnr, run, reason)
  local record = records[bufnr]
  if not record or record.run ~= run then return end
  record.run, record.waits = nil, {}
  serial = serial + 1
  record.finished = serial
  record.state = (run.cancelled or reason == "cancelled") and "idle" or reason == "ok" and "done" or "error"
  publish(record)
end

function M.permission_wait(bufnr)
  local record = records[bufnr]
  if not record or not record.run then return end
  for token in pairs(record.waits) do
    if token.kind == "permission" or token.kind == "consent" then return true end
  end
  return false
end

local function redraw_permission(kind, bufnr)
  if kind == "permission" or kind == "consent" then
    pcall(function() require("straps.turn_decoration").redraw(bufnr) end)
  end
end

function M.wait(ctx, kind)
  local key = ctx and ctx.bufnr
  local record = records[key]
  if not record or not record.run or record.run.ctx ~= ctx or stopped then return function() end end
  local run = record.run
  serial = serial + 1
  local token = { kind = kind, seq = serial }
  record.waits[token] = true
  publish(record)
  redraw_permission(kind, key)
  return function()
    if records[key] ~= record or record.run ~= run or not record.waits[token] then return end
    record.waits[token] = nil
    publish(record)
    redraw_permission(kind, key)
  end
end

function M.prompt(ctx, kind, fn, ...)
  local release
  if ctx then
    release = M.wait(ctx, kind)
  elseif enabled and not stopped then
    serial = serial + 1
    local key = "prompt/" .. serial
    local record = { id = "straps/" .. nonce .. "/" .. key, state = "blocked", kind = kind, seq = serial, waits = {} }
    records[key] = record
    publish(record)
    release = function() clear(key) end
  else
    release = function() end
  end
  local result = { pcall(fn, ...) }
  release()
  if not result[1] then error(result[2], 0) end
  return unpack(result, 2)
end

local function clear_published()
  for _, record in pairs(records) do
    if record.published then send(record, "clear") end
  end
  if root.published then send(root, "clear") end
end

local function replay()
  if not enabled or stopped then return end
  publish_root()
  for _, record in pairs(records) do
    if record.run or record.kind then
      local last = waiting(record)
      send(record, last and "blocked" or record.state, last and last.kind or record.kind)
    end
  end
end

function M.shutdown()
  stopped = true
  clear_published()
  records = {}
end

function M.setup(value)
  if value == false then clear_published() end
  enabled = value ~= false
  local group = vim.api.nvim_create_augroup("straps_terminal_status", { clear = true })
  vim.api.nvim_create_autocmd("VimLeavePre", { group = group, callback = M.shutdown })
  vim.api.nvim_create_autocmd("BufUnload", { group = group, callback = function(args) clear(args.buf) end })
  vim.api.nvim_create_autocmd("UIEnter", { group = group, callback = replay })
  replay()
end

return M
