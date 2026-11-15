local M = {}
local registry = require("straps.registry")
local trusted_setup_allowed = registry.trusted_setup_allowed
local captured_loop, install_context_operations
local management = require("straps.context_management")
local sessions, schedule = {}, nil

local function status(bufnr, phase, reason)
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.b[bufnr].straps_context_control = { status = phase, reason = tostring(reason or "") }
  end
end

local function session(bufnr)
  if sessions[bufnr] then return sessions[bufnr] end
  local entry = {}
  local facade = { bufnr = bufnr }
  for _, name in ipairs({ "await", "emit", "on_cancel", "cancelled" }) do
    facade[name] = function(...)
      local current = assert(entry.current, "context control has no active scheduler context")
      return current[name](...)
    end
  end
  entry.facade = facade
  sessions[bufnr] = entry
  return entry
end

function M.cancel(bufnr)
  local entry = sessions[bufnr]
  if not entry then return end
  entry.report = nil
  local cancel = entry.cancel
  entry.cancel = nil
  if cancel then cancel() end
  status(bufnr, "cancelled", "context control cancelled")
end

local function capture_schedule(run) schedule = run end

function M.capture()
  local loop = require("straps.loop")
  if loop ~= captured_loop then
    assert(trusted_setup_allowed(), "context UI capture requires trusted setup")
    captured_loop, install_context_operations = loop, loop.install_context_operations
  end
  install_context_operations(capture_schedule)
end

function M.setup()
  M.capture()
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = vim.api.nvim_create_augroup("StrapsContextControls", { clear = true }),
    callback = function(ev)
      if sessions[ev.buf] then M.cancel(ev.buf); sessions[ev.buf] = nil end
    end,
  })
end

local function inputs(ctx)
  local tools = registry.call("fn.build_tools")
  local ok, note = pcall(registry.try_call, "fn.model_note", ctx)
  if not ok or type(note) ~= "string" or note == "" then note = nil end
  return tools, note
end

local function perform(bufnr, fn)
  if not management.enabled(bufnr) then
    status(bufnr, "refused", "context management is disabled")
    vim.notify("straps: context management is disabled", vim.log.levels.WARN)
    return false
  end
  if not schedule then
    vim.notify("straps: context controls were not captured during trusted setup", vim.log.levels.ERROR)
    return false
  end
  local entry = session(bufnr)
  local finished = false
  local accepted, cancel = schedule(bufnr, function(ctx)
    entry.current = ctx
    local ok, err = pcall(fn, entry, entry.facade)
    entry.current, entry.cancel = nil, nil
    finished = true
    if not ok then
      entry.report = nil
      status(bufnr, ctx.cancelled() and "cancelled" or "refused", err)
      vim.notify("straps: " .. tostring(err), vim.log.levels.WARN)
    end
  end)
  if not accepted then
    status(bufnr, "refused", cancel)
    vim.notify("straps: " .. tostring(cancel), vim.log.levels.WARN)
  elseif not finished then
    entry.cancel = cancel
  end
  return accepted
end

local function value(v) return v == nil and "unknown" or tostring(v) end

local function display(bufnr, entry, report)
  local metrics = vim.b[bufnr].straps_context_compaction or {}
  local before, after = metrics.before or {}, metrics.after or {}
  local rows = { "Context preview", "Status: " .. (report.needs_generation and "needs generation" or "prepared"),
    "Count source: " .. value(before.source), "Count exact: " .. value(before.exact),
    "Input tokens: " .. value(before.tokens), "Input allowance: " .. value(before.limit),
    "Output reservation: " .. value(before.output_reserve), "After tokens: " .. value(after.tokens),
    "Removed blocks: " .. value(metrics.first_block) .. ".." .. value(metrics.last_block),
    "Earliest changed transcript line: " .. value(metrics.earliest_line),
    "Archive references: pending apply", "Cache observed: " .. value(before.cache and before.cache.observed),
    "Cache expiry: " .. value(before.cache and before.cache.expiry), "", "Proposed transcript", "" }
  vim.list_extend(rows, report.lines or {})
  local buffer = entry.preview
  if not buffer or not vim.api.nvim_buf_is_valid(buffer) then
    buffer = vim.api.nvim_create_buf(false, true)
    entry.preview = buffer
    vim.bo[buffer].buftype, vim.bo[buffer].bufhidden, vim.bo[buffer].swapfile = "nofile", "wipe", false
    vim.api.nvim_create_autocmd("BufWipeout", { buffer = buffer, once = true, callback = function()
      if entry.preview == buffer then entry.preview = nil; M.cancel(bufnr) end
    end })
    vim.cmd("botright split")
    vim.api.nvim_win_set_buf(0, buffer)
  end
  vim.bo[buffer].readonly, vim.bo[buffer].modifiable = false, true
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, rows)
  vim.bo[buffer].modifiable, vim.bo[buffer].readonly = false, true
end

function M.preview(bufnr, opts)
  opts = opts or {}
  if opts.args ~= nil and opts.args ~= "" and opts.args ~= "summary" then
    vim.notify("straps: expected :StrapsContextPreview[!] [summary]", vim.log.levels.WARN)
    return false
  end
  local override = vim.b[bufnr].straps_context_management
  local cfg = vim.tbl_deep_extend("force", require("straps").config.context_management or {}, type(override) == "table" and override or {})
  if opts.args == "summary" and cfg.mode ~= "summary" then
    vim.notify("straps: summary preview requires configured summary mode", vim.log.levels.WARN)
    return false
  end
  return perform(bufnr, function(entry, ctx)
    entry.report = nil
    if entry.preview and vim.api.nvim_buf_is_valid(entry.preview) then
      local old = entry.preview
      entry.preview = nil
      vim.api.nvim_buf_delete(old, { force = true })
    end
    local tools, note = inputs(ctx)
    status(bufnr, "preparing")
    display(bufnr, entry, { needs_generation = opts.bang == true, lines = { "Preparing context preview; close this buffer or use :StrapsStop to cancel." } })
    local report = management.preview(bufnr, ctx, { tools = tools, note = note, generate = opts.bang == true })
    assert(not ctx.cancelled(), "context management: cancelled")
    entry.report, entry.tools, entry.note = report, vim.deepcopy(tools), note
    status(bufnr, report.needs_generation and "needs_generation" or "prepared")
    display(bufnr, entry, report)
  end)
end

function M.apply(bufnr)
  return perform(bufnr, function(entry, ctx)
    local report = assert(entry.report, "context management: no prepared preview")
    entry.report = nil
    local tools, note = inputs(ctx)
    assert(vim.deep_equal(tools, entry.tools) and note == entry.note, "context management: request inputs changed")
    management.apply(bufnr, ctx, report, tools, note)
    local metrics = vim.b[bufnr].straps_context_compaction or {}
    status(bufnr, metrics.status or "unknown", metrics.reason)
    vim.notify("straps: context " .. value(metrics.status) .. ": " .. value(metrics.reason))
  end)
end

function M.pin(bufnr, first_line, last_line)
  return perform(bufnr, function(entry)
    local first, last
    for i, block in ipairs(require("straps.state").list_blocks(bufnr)) do
      if block.marker_lnum <= last_line and block.last_lnum >= first_line then first, last = first or i, i end
    end
    assert(first, "context management: range contains no transcript blocks")
    management.pin(bufnr, first, last)
    entry.report = nil
    status(bufnr, "pinned", "blocks " .. first .. ".." .. last)
  end)
end

function M.unpin(bufnr)
  return perform(bufnr, function(entry)
    management.unpin(bufnr)
    entry.report = nil
    status(bufnr, "unpinned")
  end)
end

return M
