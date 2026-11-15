local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(here, ":p:h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
local registry, loop, ui, state, management, straps, buf, human, context, resolve
local seen, contexts, reports, applied, generates, original_preview, original_apply
local assertion, assertion_failure = 0, nil
local fsync = vim.uv.fs_fsync
local persist_checked
local saved_paths = {}
local function check(value)
  assertion = assertion + 1
  if tonumber(vim.env.STRAPS_CONTEXT_UI_ASSERTION) == assertion then value = not value end
  if not value then assertion_failure = "context UI assertion " .. assertion end
  assert(value, "context UI assertion " .. assertion)
end
local function define(name, source) registry.define({ name = name, kind = "fn", source = source }) end
local function drain() vim.wait(50, function() return false end, 5) end
before_each(function()
  assertion_failure = nil
  for _, name in ipairs({ "straps.registry", "straps.loop", "straps.context_ui", "straps.context_management", "straps.provider" }) do package.loaded[name] = nil end
  registry = require("straps.registry")
  straps = require("straps")
  straps.config.context_management = { enabled = true, mode = "mechanical", input_limit = 100000, reserve_tokens = 1000,
    trigger = 0.001, target = 0.95, minimum_savings = 20 }
  straps.config.session_dir = vim.fn.tempname()
  state, loop, management = require("straps.state"), require("straps.loop"), require("straps.context_management")
  require("straps.provider").register()
  ui = require("straps.context_ui")
  ui.setup()
  loop.install_human_operations(function(fn) human = fn end)
  seen, contexts, reports, applied, generates = {}, {}, {}, {}, 0
  _G.context_ui_seen = seen
  define("fn.build_tools", "return function() _G.context_ui_seen.scope = require('straps.registry').active_scope(); return {{name='actual-tool'}} end")
  define("fn.model_note", "return function() return 'actual note' end")
  define("fn.provider", "return function() error('unexpected paid provider') end")
  original_preview, original_apply = management.preview, management.apply
  persist_checked = management.persist_checked
  management.preview = function(b, ctx, opts)
    contexts[#contexts + 1] = ctx
    seen.tools, seen.note = opts.tools, opts.note
    if opts.generate then generates = generates + 1 end
    if seen.suspend then ctx.await(function(done) resolve = done end) end
    assert(not ctx.cancelled(), "cancelled")
    local report = { lines = { "proposed" }, needs_generation = straps.config.context_management.mode == "summary" and not opts.generate }
    reports[#reports + 1] = report
    vim.b[b].straps_context_compaction = { status = "preview", before = { tokens = 100, limit = 1000, source = "fake count", exact = false } }
    return report
  end
  management.apply = function(b, ctx, report, tools, note)
    contexts[#contexts + 1] = ctx
    assert(report == reports[#reports], "exact report required")
    assert(vim.deep_equal(tools, seen.tools) and note == seen.note, "request inputs changed")
    applied[#applied + 1] = report
    vim.b[b].straps_context_compaction = { status = "applied", reason = "explicit apply" }
  end
  buf = vim.api.nvim_create_buf(false, true)
  state.append(buf, "user", nil, "request")
end)
after_each(function()
  vim.uv.fs_fsync = fsync
  management.preview, management.apply = original_preview, original_apply
  management.persist_checked = persist_checked
  ui.cancel(buf)
  drain()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if b ~= buf and vim.bo[b].buftype == "nofile" then pcall(vim.api.nvim_buf_delete, b, { force = true }) end
  end
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
  for _, path in ipairs(saved_paths) do vim.fn.delete(path) end
  saved_paths = {}
  assert(not assertion_failure, assertion_failure)
end)
for _, replacement in ipairs({ "installer", "loop" }) do
  it("keeps the private UI consumer from a replacement " .. replacement .. " after setup seals", function()
    registry.ensure_scope(buf)
    local calls, stolen, overwritten = 0, nil, false
    local original = loop.install_context_operations
    local function substitute(consumer)
      calls, stolen = calls + 1, consumer
      original(consumer)
      consumer(function() overwritten = true; return true end)
    end
    if replacement == "installer" then loop.install_context_operations = substitute
    else package.loaded["straps.loop"] = { install_context_operations = substitute } end
    local allowed = registry.trusted_setup_allowed
    registry.trusted_setup_allowed = function() return true end
    local captured, configured = pcall(ui.capture), pcall(ui.setup)
    registry.trusted_setup_allowed = allowed
    check(captured == (replacement == "installer") and configured == (replacement == "installer"))
    check(calls == 0)
    check(stolen == nil)
    ui.preview(buf, {})
    check(not overwritten and #reports == 1)
  end)
end
it("reattaches the same trusted consumer without replacing its scheduler", function()
  package.loaded["straps.loop"] = nil
  loop = require("straps.loop")
  local first, second, captures = nil, nil, 0
  local function consumer(run)
    captures = captures + 1
    if not first then first = run else second = run end
  end
  loop.install_context_operations(consumer)
  registry.ensure_scope(buf)
  loop.install_context_operations(consumer)
  check(captures == 2)
  check(type(first) == "function" and second == first)
  local hijacked = false
  check(not pcall(loop.install_context_operations, function() hijacked = true end))
  check(not hijacked)
end)
it("refuses a different consumer before trusted setup seals", function()
  local hijacked = false
  check(registry.trusted_setup_allowed())
  check(not pcall(loop.install_context_operations, function() hijacked = true end))
  check(not hijacked)
end)
it("reconnects the existing UI consumer to a fresh trusted loop", function()
  package.loaded["straps.loop"] = nil
  loop = require("straps.loop")
  ui.setup()
  check(ui.preview(buf, {}))
  check(#reports == 1)
  seen.suspend = true
  ui.preview(buf, {})
  loop.user_stop(buf)
  resolve()
  drain()
  check(#reports == 1)
end)
it("refuses a fresh loop capture after trusted setup seals", function()
  registry.ensure_scope(buf)
  package.loaded["straps.loop"] = nil
  loop = require("straps.loop")
  check(not pcall(ui.setup))
end)
it("refuses a replacement UI consumer after trusted setup seals", function()
  registry.ensure_scope(buf)
  package.loaded["straps.context_ui"] = nil
  check(not pcall(require("straps.context_ui").setup))
end)
it("repeats public setup after sessions exist without enabling context management", function()
  straps.config.context_management.enabled = false
  registry.ensure_scope(buf)
  straps.setup({})
  straps.setup({})
  check(not straps.config.context_management.enabled)
  check(not ui.preview(buf, {}))
end)
it("captures current target inputs and keeps one exact report and stable facade", function()
  check(ui.preview(buf, {}))
  local display = vim.api.nvim_get_current_buf()
  check(vim.bo[display].readonly and not vim.bo[display].modifiable and vim.bo[display].buftype == "nofile")
  check(seen.scope == buf and seen.tools[1].name == "actual-tool" and seen.note == "actual note")
  check(ui.apply(buf))
  check(contexts[1] == contexts[2] and #applied == 1 and generates == 0)
  ui.apply(buf)
  check(#applied == 1 and vim.b[buf].straps_context_control.status == "refused")
end)
it("never enables disabled sessions or generates without bang", function()
  straps.config.context_management.enabled = false
  check(not ui.preview(buf, { bang = true }))
  check(#reports == 0 and generates == 0)
  straps.config.context_management.enabled, straps.config.context_management.mode = true, "summary"
  ui.preview(buf, { args = "summary" })
  check(reports[1].needs_generation and generates == 0)
  ui.preview(buf, { args = "summary", bang = true })
  check(generates == 1)
end)
it("reserves the whole asynchronous preview against runs and human operations", function()
  seen.suspend = true
  ui.preview(buf, { bang = true })
  check(type(resolve) == "function")
  check(not human(buf, function() error("must not run") end))
  loop.start(buf)
  check(not loop.running(buf))
  resolve()
  drain()
  check(human(buf, function() seen.human = true end))
  check(seen.human == true)
end)
it("refuses context scheduling after an ordinary asynchronous human operation", function()
  local release
  human(buf, function(ctx) ctx.await(function(done) release = done end) end)
  check(not ui.preview(buf, {}))
  check(#reports == 0)
  release()
  drain()
  check(ui.preview(buf, {}))
end)
it("cancels by preview closure and releases the reservation", function()
  seen.suspend = true
  ui.preview(buf, { bang = true })
  vim.api.nvim_buf_delete(vim.api.nvim_get_current_buf(), { force = true })
  drain()
  check(human(buf, function() seen.released = true end))
  check(seen.released and #reports == 0)
end)
it("cancels with Stop without adopting a late summary", function()
  seen.suspend = true
  ui.preview(buf, { bang = true })
  loop.user_stop(buf)
  drain()
  resolve()
  drain()
  check(#reports == 0 and #applied == 0)
  check(human(buf, function() end))
end)
it("cancels session wipe and ignores late completions", function()
  seen.suspend = true
  ui.preview(buf, { bang = true })
  local complete = resolve
  vim.api.nvim_buf_delete(buf, { force = true })
  drain()
  complete()
  drain()
  check(#reports == 0 and #applied == 0)
end)
it("keeps ordinary human concurrency unchanged without a context reservation", function()
  local finish
  check(human(buf, function(ctx) ctx.await(function(done) finish = done end) end))
  check(human(buf, function() seen.concurrent = true end))
  check(seen.concurrent == true)
  finish()
  drain()
end)
it("refuses context operations while a provider run is suspended", function()
  straps.config.context_management.enabled = false
  _G.context_ui_provider = function(_, ctx)
    return ctx.await(function(done) resolve = done end)
  end
  define("fn.provider", "return function(req, ctx) return _G.context_ui_provider(req, ctx) end")
  loop.start(buf)
  check(loop.running(buf))
  straps.config.context_management.enabled = true
  check(not ui.preview(buf, {}))
  check(#reports == 0)
  loop.stop(buf)
  resolve({ stop_reason = "end_turn", content = {} })
  drain()
end)
it("maps marker-inclusive transcript lines to block indices", function()
  state.append(buf, "assistant", nil, "answer")
  local block = state.list_blocks(buf)[2]
  local pin = management.pin
  local first, last
  management.pin = function(_, a, b) first, last = a, b end
  ui.pin(buf, block.marker_lnum, block.marker_lnum)
  management.pin = pin
  check(first == 2 and last == 2)
  ui.unpin(buf)
  check(vim.b[buf].straps_context_control.status == "unpinned")
end)
it("refuses changed current tools at exact application", function()
  ui.preview(buf, {})
  define("fn.build_tools", "return function() return {{name='changed'}} end")
  ui.apply(buf)
  check(#applied == 0 and vim.b[buf].straps_context_control.status == "refused")
end)
for _, dimension in ipairs({ "source", "tools", "note", "removed note" }) do
  it("uses real management freshness checks for " .. dimension, function()
    management.preview, management.apply = original_preview, original_apply
    state.append(buf, "assistant", nil, "older response")
    for i = 1, 4 do
      state.append(buf, "tool_use", { id = tostring(i), name = "read_file" }, "{}")
      state.append(buf, "tool_result", { id = tostring(i) }, string.rep("evidence", 1400))
    end
    state.append(buf, "user", nil, "continue")
    ui.preview(buf, {})
    check(vim.b[buf].straps_context_control.status == "prepared")
    if dimension == "source" then state.append(buf, "user", nil, "changed") end
    if dimension == "tools" then define("fn.build_tools", "return function() return {{name='changed'}} end") end
    if dimension == "note" then define("fn.model_note", "return function() return 'changed' end") end
    if dimension == "removed note" then define("fn.model_note", "return function() return nil end") end
    local original = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    ui.apply(buf)
    check(vim.b[buf].straps_context_control.status == "refused")
    check(vim.deep_equal(original, vim.api.nvim_buf_get_lines(buf, 0, -1, false)))
  end)
end
it("applies real management report through the same facade without generation", function()
  management.preview, management.apply = original_preview, original_apply
  for i = 1, 4 do
    state.append(buf, "assistant", nil, "claim " .. i)
    state.append(buf, "tool_use", { id = tostring(i), name = "read_file" }, "{}")
    state.append(buf, "tool_result", { id = tostring(i) }, string.rep("evidence", 1400))
  end
  state.append(buf, "user", nil, "continue")
  ui.preview(buf, {})
  check(vim.b[buf].straps_context_control.status == "prepared")
  ui.apply(buf)
  check(vim.b[buf].straps_context_control.status == "applied")
  check(vim.b[buf].straps_context_compaction.after.tokens < vim.b[buf].straps_context_compaction.before.tokens)
end)
for _, failure in ipairs({ "conflict", "ambiguous" }) do
  it("fences real " .. failure .. " transactions caught by asynchronous context UI", function()
    management.preview, management.apply = original_preview, original_apply
    for i = 1, 4 do
      state.append(buf, "assistant", nil, "claim " .. i)
      state.append(buf, "tool_use", { id = tostring(i), name = "read_file" }, "{}")
      state.append(buf, "tool_result", { id = tostring(i) }, string.rep("evidence", 1400))
    end
    state.append(buf, "user", nil, "continue")
    local path = vim.fn.tempname()
    saved_paths[#saved_paths + 1] = path
    vim.bo[buf].buftype = ""
    vim.api.nvim_buf_set_name(buf, path)
    vim.api.nvim_buf_call(buf, function() vim.cmd("silent noautocmd write") end)
    local initial = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local complete, cancelled
    local function suspend(ctx)
      ctx.await(function(done) complete = done end)
      ctx.on_cancel(function() cancelled = true end)
      ctx.emit({ type = "text_delta", text = "must not flush" })
    end
    if failure == "conflict" then
      management.preview = function(b, ctx, opts)
        suspend(ctx)
        return original_preview(b, ctx, opts)
      end
      ui.preview(buf, {})
      vim.fn.writefile({ "external saved source" }, path)
    else
      ui.preview(buf, {})
      check(vim.b[buf].straps_context_control.status == "prepared")
      management.apply = function(b, ctx, report, tools, note)
        suspend(ctx)
        return original_apply(b, ctx, report, tools, note)
      end
      management.persist_checked = function(...)
        vim.uv.fs_fsync = function() return nil, "injected durability failure" end
        local result = { persist_checked(...) }
        vim.uv.fs_fsync = fsync
        return unpack(result, 1, 3)
      end
      ui.apply(buf)
    end
    check(type(complete) == "function")
    complete()
    drain()
    vim.uv.fs_fsync = fsync
    local terminal = management.transaction_status(buf)
    check(terminal and terminal.terminal and terminal.status == failure)
    check(vim.b[buf].straps_context_control.status == "refused")
    check(cancelled == true)
    check(vim.deep_equal(initial, vim.api.nvim_buf_get_lines(buf, 0, -1, false)))
    local disk_after = vim.fn.readfile(path)
    if failure == "conflict" then check(vim.deep_equal(disk_after, { "external saved source" })) end
    local accepted, reason = human(buf, function() seen.escaped = true end)
    check(not accepted and reason == "context transaction requires reconciliation" and not seen.escaped)
    loop.start(buf)
    check(not loop.running(buf))
    check(not ui.preview(buf, {}))
    drain()
    check(vim.deep_equal(disk_after, vim.fn.readfile(path)))
  end)
end
it("shows unknown accounting fields without claiming exact counts", function()
  ui.preview(buf, {})
  local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  check(text:find("Count exact: false", 1, true) ~= nil)
  check(text:find("Cache expiry: unknown", 1, true) ~= nil)
  check(text:find("After tokens: unknown", 1, true) ~= nil)
end)
