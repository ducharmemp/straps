local M = {}
local records = {}
local enabled = true
local stopped = false
local serial = 0
local nonce = tostring(vim.uv.os_getpid()) .. "-" .. tostring(vim.uv.hrtime())

local function send(record, state, kind)
  if type(vim.api.nvim_ui_send) ~= "function" then return end
  local payload = "\27]7501;app=straps:id=" .. record.id .. ":state=" .. state
  if kind then payload = payload .. ":kind=" .. kind end
  local ok = pcall(vim.api.nvim_ui_send, payload .. "\27\\")
  if ok then record.published = state ~= "clear" end
end

local function publish(record)
  if not enabled or stopped then return end
  local last
  for token in pairs(record.waits) do
    if not last or token.seq > last.seq then last = token end
  end
  send(record, last and "blocked" or record.state, last and last.kind or record.kind)
end

local function clear(key)
  local record = records[key]
  if not record then return end
  if record.published then send(record, "clear") end
  records[key] = nil
end

function M.start(bufnr, run)
  if stopped then return end
  local record = records[bufnr]
  if not record then
    record = { id = "straps/" .. nonce .. "/" .. bufnr }
    records[bufnr] = record
  end
  record.run, record.state, record.waits = run, "working", {}
  publish(record)
end

function M.finish(bufnr, run, reason)
  local record = records[bufnr]
  if not record or record.run ~= run then return end
  record.run, record.waits = nil, {}
  record.state = (run.cancelled or reason == "cancelled") and "idle" or reason == "ok" and "done" or "error"
  publish(record)
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
  return function()
    if records[key] ~= record or record.run ~= run or not record.waits[token] then return end
    record.waits[token] = nil
    publish(record)
  end
end

function M.prompt(ctx, kind, fn, ...)
  local release
  if ctx then
    release = M.wait(ctx, kind)
  elseif enabled and not stopped then
    serial = serial + 1
    local key = "prompt/" .. serial
    local record = { id = "straps/" .. nonce .. "/" .. key, state = "blocked", kind = kind, waits = {} }
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

function M.shutdown()
  stopped = true
  for key in pairs(records) do clear(key) end
end

function M.setup(value)
  if value == false then
    for _, record in pairs(records) do
      if record.published then send(record, "clear") end
    end
  end
  enabled = value ~= false
  local group = vim.api.nvim_create_augroup("straps_terminal_status", { clear = true })
  vim.api.nvim_create_autocmd("VimLeavePre", { group = group, callback = M.shutdown })
  vim.api.nvim_create_autocmd("BufUnload", { group = group, callback = function(args) clear(args.buf) end })
  vim.api.nvim_create_autocmd("UIEnter", { group = group, callback = function()
    for _, record in pairs(records) do
      if record.waits then publish(record) end
    end
  end })
  if enabled then
    for _, record in pairs(records) do
      if record.waits then publish(record) end
    end
  end
end

return M
