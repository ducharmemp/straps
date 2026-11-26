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

function M.wait_label(bufnr, dock)
  local workbench = package.loaded["straps.workbench"]
  local edit = workbench and workbench.pending(bufnr)
  local label = require("straps").config.render ~= false and "%#StrapsPermit#◆ waiting%*" or "waiting"
  if edit then return label .. " — Permission pending (gy / :StrapsInspect / :StrapsPermission)  " end
  if dock then return label .. " — Permission pending (gy / :StrapsPermission)  " end
  return M.permission_wait(bufnr) and label .. "  " or ""
end

local function redraw_permission(kind)
  if kind == "permission" or kind == "consent" or kind == "question" then
    pcall(vim.cmd, "redrawstatus!")
    pcall(vim.cmd, "redrawtabline")
  end
end

local wait_totals = {}
local wait_cleanup = false

local function now_ms()
  return vim.uv.hrtime() / 1e6
end

local function open_total(bufnr)
  if type(bufnr) ~= "number" then return end
  if not wait_cleanup then
    wait_cleanup = true
    vim.api.nvim_create_autocmd("BufWipeout", {
      group = vim.api.nvim_create_augroup("straps_wait_totals", { clear = true }),
      callback = function(args) wait_totals[args.buf] = nil end,
    })
  end
  local total = wait_totals[bufnr]
  if not total then
    total = { count = 0, closed_ms = 0 }
    wait_totals[bufnr] = total
  end
  total.count = total.count + 1
  if total.count == 1 then total.open_start = now_ms() end
  return total
end

local function close_total(total)
  if not total then return end
  total.count = total.count - 1
  if total.count == 0 then
    total.closed_ms = total.closed_ms + (now_ms() - total.open_start)
    total.open_start = nil
  end
end

function M.wait_ms(bufnr)
  local total = wait_totals[bufnr]
  if not total then return 0 end
  return total.closed_ms + (total.open_start and now_ms() - total.open_start or 0)
end

function M.waiting(bufnr)
  local total = wait_totals[bufnr]
  local loop = package.loaded["straps.loop"]
  return total ~= nil and total.count > 0 and loop ~= nil and loop.running(bufnr)
end

function M.wait(ctx, kind)
  local key = ctx and ctx.bufnr
  local total = open_total(key)
  local released = false
  local record = records[key]
  if not record or not record.run or record.run.ctx ~= ctx or stopped then
    if total then redraw_permission(kind) end
    return function()
      if released then return end
      released = true
      close_total(total)
      if total then redraw_permission(kind) end
    end
  end
  local run = record.run
  serial = serial + 1
  local token = { kind = kind, seq = serial }
  record.waits[token] = true
  publish(record)
  redraw_permission(kind)
  return function()
    if released then return end
    released = true
    close_total(total)
    if records[key] == record and record.run == run and record.waits[token] then
      record.waits[token] = nil
      publish(record)
    end
    redraw_permission(kind)
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
