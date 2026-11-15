local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(here, ":p:h:h")
vim.opt.runtimepath:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local registry, state, loop, management, buf, original, events, calls, completions, operation, replay
local function define(name, kind, source)
  registry.define({ name = name, kind = kind, source = source })
end
local function text() return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n") end
local function wait_done()
  assert(vim.wait(3000, function() return not loop.running(buf) end, 5), "run did not finish")
  local drained = false
  vim.schedule(function() drained = true end)
  assert(vim.wait(3000, function() return drained end, 5), "scheduled work did not finish")
end
local assertion, failed_assertion = 0, nil
local function check(value)
  assertion = assertion + 1
  if tonumber(vim.env.STRAPS_PENDING_ASSERTION) == assertion then value = not value end
  if not value and not failed_assertion then failed_assertion = "pending loop assertion " .. assertion end
  assert(value, "pending loop assertion " .. assertion)
end
local function tool(name, id) return { type = "tool_use", name = name, id = id, input = {} } end
local function response(ctx)
  completions = completions + 1
  ctx.emit({ type = "text_delta", text = "answer" })
  return { stop_reason = "end_turn", complete = true, content = { { type = "text", text = "answer" } } }
end
local function pending(id)
  state.append(buf, "tool_use", { id = id, name = "context_retrieve" }, "{}")
  local status = management.append_result(buf, { id = id, is_error = false }, "archived detail")
  assert.equals("committed_live", status.status)
end
local function watch_fault(fn)
  local after, writes, hooks, at_fault = false, 0, 0
  local append, append_text, trailing, persist = state.append, state.append_text, state.ensure_trailing_user, state.persist
  local set_lines = vim.api.nvim_buf_set_lines
  state.append = function(...) if after then writes = writes + 1 end; return append(...) end
  state.append_text = function(...) if after then writes = writes + 1 end; return append_text(...) end
  state.ensure_trailing_user = function(...) if after then writes = writes + 1 end; return trailing(...) end
  state.persist = function(...) if after then writes = writes + 1 end; return persist(...) end
  vim.api.nvim_buf_set_lines = function(...) if after then writes = writes + 1 end; return set_lines(...) end
  _G.pending_hook = function() if after then hooks = hooks + 1 end end
  for _, name in ipairs({ "hook.on_progress", "hook.on_run_end" }) do
    define(name, "hook", "return function() _G.pending_hook() end")
  end
  local group = vim.api.nvim_create_augroup("pending_loop_fault", { clear = true })
  vim.api.nvim_create_autocmd("User", { group = group, pattern = { "StrapsStatusChanged", "StrapsRunEnd" },
    callback = function() if after then hooks = hooks + 1 end end })
  local ok, err = pcall(fn, function() at_fault = text(); after = true end)
  state.append, state.append_text, state.ensure_trailing_user, state.persist = append, append_text, trailing, persist
  vim.api.nvim_buf_set_lines = set_lines
  vim.api.nvim_del_augroup_by_id(group)
  assert(ok, err)
  check(writes == 0)
  check(hooks == 0)
  check(text() == at_fault)
end

before_each(function()
  for _, name in ipairs({ "loop", "registry", "state", "context_management" }) do package.loaded["straps." .. name] = nil end
  registry, state = require("straps.registry"), require("straps.state")
  loop, management = require("straps.loop"), require("straps.context_management")
  local cfg = require("straps").config
  cfg.session_dir = vim.fn.tempname()
  cfg.context_management = { enabled = false }
  cfg.auto_compact_bytes, cfg.auto_compact_tokens = nil, nil
  cfg.max_turns, cfg.stall_limit, cfg.blank_nudge_limit = 4, 0, 0
  events, calls, completions = {}, 0, 0
  original = {}
  for _, name in ipairs({ "append_result", "consume_pending", "snapshot_pending", "release", "boundary" }) do original[name] = management[name] end
  buf = state.new_session()
  state.append_text(buf, "retrieve source")
  loop.install_human_operations(function(a, b) operation, replay = a, b end)
  define("hook.confirm", "hook", "return function() return true end")
  define("fn.context_plan", "fn", [[return function(input)
    local selections = {}
    for _, interval in ipairs(input.eligible) do selections[#selections + 1] = interval.index end
    return { version = 1, snapshot_id = input.snapshot_id, selections = selections }
  end]])
  define("fn.build_tools", "fn", "return function() return {} end")
  define("tool.context_retrieve", "tool", "return function(_, ctx) require('straps.context_management').protect(ctx.bufnr); return 'archived detail' end")
  define("tool.sample", "tool", "return function() return 'sample result' end")
  define("fn.provider", "fn", "return function(req, ctx) return _G.pending_provider(req, ctx) end")
  _G.pending_provider = function(_, ctx) calls = calls + 1; return response(ctx) end
end)

after_each(function()
  for name, fn in pairs(original) do management[name] = fn end
  if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end
  assert(not failed_assertion, failed_assertion)
end)

it("appends checked retrieval results in tool order and captures the final continuation", function()
  local checked, captured, ordinary = 0, 0, 0
  local append = state.append
  state.append = function(b, kind, attrs, body)
    if vim.env.STRAPS_PENDING_TRACE then print("append", kind, attrs and attrs.id) end
    if kind == "tool_result" and attrs.id == "retrieve" then ordinary = ordinary + 1 end
    return append(b, kind, attrs, body)
  end
  management.append_result = function(...)
    checked = checked + 1
    return original.append_result(...)
  end
  management.snapshot_pending = function(...)
    local capture, status = original.snapshot_pending(...)
    if capture and #capture.pending > 0 then captured = captured + 1 end
    return capture, status
  end
  _G.pending_provider = function(req, ctx)
    calls = calls + 1
    if calls == 1 then return { stop_reason = "tool_use", content = { tool("context_retrieve", "retrieve"), tool("sample", "sample") } } end
    check(management.has_pending(buf))
    check(vim.json.encode(req.messages):find("archived detail", 1, true) ~= nil)
    return response(ctx)
  end
  loop.start(buf); wait_done()
  state.append = append
  check(calls == 2)
  check(completions == 1)
  check(checked == 1)
  check(ordinary == 0)
  check(captured == 1)
  check(not management.has_pending(buf))
  local blocks = state.list_blocks(buf)
  local ids = {}
  for _, block in ipairs(blocks) do if block.kind == "tool_result" then ids[#ids + 1] = block.attrs.id end end
  check(vim.deep_equal(ids, { "retrieve", "sample" }))
  check(text():find("answer", 1, true) ~= nil)
end)

it("keeps disabled legacy compaction from rewriting pending retrievals", function()
  pending("saved")
  require("straps").config.auto_compact_bytes = 1
  local compacted = 0
  _G.pending_compact = function() compacted = compacted + 1 end
  define("fn.compact", "fn", "return function() _G.pending_compact() end")
  loop.start(buf); wait_done()
  check(completions == 1)
  check(compacted == 0)
  check(not management.has_pending(buf))
end)

it("captures after the enabled boundary and consumes after appended response text", function()
  require("straps").config.context_management.enabled = true
  local boundary, consumed_tail = false, false
  management.boundary = function(b)
    pending("boundary")
    boundary = true
    local parsed = state.parse(b)
    return { system = parsed.system, messages = parsed.messages, tools = {} }
  end
  management.snapshot_pending = function(...)
    check(boundary)
    return original.snapshot_pending(...)
  end
  management.consume_pending = function(capture, ctx)
    consumed_tail = text():find("response tail", 1, true) ~= nil
    return original.consume_pending(capture, ctx)
  end
  _G.pending_provider = function(_, ctx)
    state.append_text(buf, "response tail")
    return response(ctx)
  end
  loop.start(buf); wait_done()
  check(completions == 1)
  check(consumed_tail)
  check(not management.has_pending(buf))
end)

it("retains pending on provider failure and on cancelled response", function()
  pending("failure")
  _G.pending_provider = function() error("provider failure") end
  loop.start(buf); wait_done()
  check(completions == 0)
  check(management.has_pending(buf))
  state.append_text(buf, "continue")
  _G.pending_provider = function(_, ctx)
    loop.stop(buf)
    return response(ctx)
  end
  loop.start(buf); wait_done()
  check(completions == 1)
  check(management.has_pending(buf))
  local path = vim.api.nvim_buf_get_name(buf)
  check(table.concat(vim.fn.readfile(path), "\n"):find('"context_pending":true', 1, true) ~= nil)
end)

it("releases failed and afterguard-rejected retrieval staging", function()
  local released = 0
  management.release = function(...) released = released + 1; return original.release(...) end
  define("tool.context_retrieve", "tool", "return function(_, ctx) require('straps.context_management').protect(ctx.bufnr); error('retrieval failure') end")
  _G.pending_provider = function(_, ctx)
    calls = calls + 1
    if calls == 1 then return { stop_reason = "tool_use", content = { tool("context_retrieve", "failed") } } end
    return response(ctx)
  end
  loop.start(buf); wait_done()
  check(calls == 2 and completions == 1)
  check(released == 1)
  check(not management.has_pending(buf))
end)

it("releases retrieval staging after an after-guard rejects its output", function()
  local released, appended = 0, 0
  management.release = function(...) released = released + 1; return original.release(...) end
  management.append_result = function(...) appended = appended + 1; return original.append_result(...) end
  define("hook.guard.reject", "hook", "return function(op) if op == 'after' then return false, 'rejected evidence' end end")
  _G.pending_provider = function(_, ctx)
    calls = calls + 1
    if calls == 1 then return { stop_reason = "tool_use", content = { tool("context_retrieve", "rejected") } } end
    return response(ctx)
  end
  loop.start(buf); wait_done()
  check(calls == 2 and completions == 1)
  check(released == 1)
  check(appended == 0)
  check(not management.has_pending(buf))
  check(text():find("rejected evidence", 1, true) ~= nil)
end)

it("retains pending on partial response", function()
  pending("partial")
  _G.pending_provider = function(_, ctx)
    calls = calls + 1
    ctx.emit({ type = "text_delta", text = "partial response" })
    return { stop_reason = "max_tokens", content = { { type = "text", text = "partial response" } } }
  end
  loop.start(buf); wait_done()
  check(calls == 1 and completions == 0)
  check(management.has_pending(buf))
end)

it("retains pending when a terminal-looking response is explicitly incomplete", function()
  pending("incomplete")
  _G.pending_provider = function(_, ctx)
    local result = response(ctx)
    result.complete = false
    return result
  end
  loop.start(buf); wait_done()
  check(completions == 1)
  check(management.has_pending(buf))
end)

it("pairs a verified prewrite error through ordinary failed-result fallback", function()
  management.append_result = function() return { status = "error", terminal = false, appended = false, error = "verified unchanged" } end
  _G.pending_provider = function(_, ctx)
    calls = calls + 1
    if calls == 1 then return { stop_reason = "tool_use", content = { tool("context_retrieve", "fallback") } } end
    return response(ctx)
  end
  loop.start(buf); wait_done()
  local result
  for _, block in ipairs(state.list_blocks(buf)) do if block.kind == "tool_result" then result = block end end
  check(result and result.attrs.is_error == true)
  check(text():find("verified unchanged", 1, true) ~= nil)
  check(calls == 2 and completions == 1)
end)

it("suppresses queued deltas, pair repair, trailing markers and callbacks after append ambiguity", function()
  local release, family_finished, human_ctx, main_ctx, cancel = nil, 0
  local human_cancelled, main_cancelled, all_cancelled, resumed = 0, 0, true, false
  local send, attention_state, timer = vim.api.nvim_ui_send, nil, nil
  vim.api.nvim_ui_send = function(payload)
    if not payload:find(":id=", 1, true) then attention_state = payload:match(":state=(%a+)") end
  end
  loop.install_contextual({ begin = function() return {} end, bind = function() end,
    finish = function() family_finished = family_finished + 1 end, stop = function() end, close = function() end })
  local started
  started, cancel = operation(buf, function(ctx)
    human_ctx = ctx
    ctx.await(function(resolve)
      release = resolve
      ctx.on_cancel(function()
        human_cancelled = human_cancelled + 1
        all_cancelled = all_cancelled and human_ctx.cancelled() and main_ctx.cancelled()
        ctx.emit({ type = "text_delta", text = "cancelled human delta" })
        resolve()
      end)
    end)
    resumed = true
    state.append_text(buf, "human completion")
  end)
  check(started)
  watch_fault(function(fault)
    management.append_result = function(b, attrs, body, ctx)
      main_ctx = ctx
      ctx.on_cancel(function()
        main_cancelled = main_cancelled + 1
        all_cancelled = all_cancelled and human_ctx.cancelled() and main_ctx.cancelled()
        ctx.emit({ type = "text_delta", text = "cancelled main delta" })
      end)
      local new_timer = vim.uv.new_timer
      vim.uv.new_timer = function(...) timer = new_timer(...); return timer end
      require("straps.ui").progress(buf, { type = "thinking" })
      vim.uv.new_timer = new_timer
      check(timer and timer:is_active())
      check(attention_state == "working")
      ctx.emit({ type = "text_delta", text = "queued tool delta" })
      original.append_result(b, attrs, body, ctx)
      fault()
      return { status = "ambiguous", terminal = true, appended = true, error = "uncertain write" }
    end
    _G.pending_provider = function()
      calls = calls + 1
      return { stop_reason = "tool_use", content = { tool("context_retrieve", "uncertain"), tool("sample", "unpaired") } }
    end
    loop.start(buf); wait_done()
    release(); wait_done()
    loop.stop(buf); cancel(); wait_done()
  end)
  vim.api.nvim_ui_send = send
  check(human_cancelled == 1)
  check(main_cancelled == 1)
  check(all_cancelled)
  check(not resumed)
  check(attention_state == "idle")
  check(timer:is_closing())
  check(vim.b[buf].straps_status == "idle")
  check(vim.b[buf].straps_run_reason == "error")
  check(family_finished == 2)
  check(calls == 1)
  check(management.has_pending(buf))
  check(not operation(buf, function() error("must not run") end))
end)

it("suppresses response emission and completion writes after consume conflict", function()
  pending("captured")
  watch_fault(function(fault)
    management.consume_pending = function()
      fault()
      return { status = "conflict", terminal = true, appended = false, error = "external edit" }
    end
    loop.start(buf); wait_done()
  end)
  check(management.has_pending(buf))
end)

local function boundary_fixture()
  require("straps").config.context_management = { enabled = true, mode = "mechanical", input_limit = 100000,
    reserve_tokens = 1000, trigger = 0.001, target = 0.95, minimum_savings = 20, keep_turns = 1 }
  define("fn.context_budget", "fn", "return function(prepared, ctx) return require('straps.context_management').account(prepared, ctx) end")
  for i = 1, 4 do
    state.append(buf, "assistant", nil, "history " .. i)
    state.append(buf, "tool_use", { id = "history-" .. i, name = "read_file" }, "{}")
    state.append(buf, "tool_result", { id = "history-" .. i }, string.rep("old evidence ", 1000))
  end
  state.append(buf, "user", nil, "continue")
end

it("stops real enabled boundary conflicts without overwriting external disk bytes or live history", function()
  boundary_fixture()
  local path, before, boundary_calls = vim.api.nvim_buf_get_name(buf), nil, 0
  _G.pending_external_change = function()
    before = text()
    vim.fn.writefile({ "external boundary change" }, path)
  end
  define("hook.on_turn_start", "hook", "return function() _G.pending_external_change() end")
  watch_fault(function(fault)
    management.boundary = function(...)
      boundary_calls = boundary_calls + 1
      local ok, result = pcall(original.boundary, ...)
      fault()
      check(not ok)
      error(result, 0)
    end
    loop.start(buf); wait_done()
  end)
  check(boundary_calls == 1)
  check(calls == 0)
  local status = management.transaction_status(buf)
  check(status and status.terminal == true and status.status == "conflict")
  check(text() == before)
  check(table.concat(vim.fn.readfile(path, "b"), "\n") == "external boundary change\n")
  check(not operation(buf, function() error("must not run after boundary conflict") end))
end)

it("stops real enabled boundary postwrite ambiguity without ordinary teardown writes", function()
  boundary_fixture()
  local path, before = vim.api.nvim_buf_get_name(buf), text()
  local fsync, syncs, boundary_calls, written = vim.uv.fs_fsync, 0, 0, nil
  watch_fault(function(fault)
    management.boundary = function(...)
      boundary_calls = boundary_calls + 1
      vim.uv.fs_fsync = function(handle)
        local target = vim.uv.fs_readlink("/proc/self/fd/" .. handle)
        if target == path then
          syncs = syncs + 1
          written = table.concat(vim.fn.readfile(path, "b"), "\n")
          return nil, "injected transcript fsync failure"
        end
        return fsync(handle)
      end
      local ok, result = pcall(original.boundary, ...)
      vim.uv.fs_fsync = fsync
      fault()
      check(not ok)
      error(result, 0)
    end
    loop.start(buf); wait_done()
  end)
  check(boundary_calls == 1)
  check(syncs == 1)
  check(calls == 0)
  local status = management.transaction_status(buf)
  check(status and status.terminal == true and status.status == "ambiguous")
  check(status.error:find("injected transcript fsync failure", 1, true) ~= nil)
  check(text() == before)
  check(written and written:find("[straps-context:", 1, true) ~= nil)
  check(table.concat(vim.fn.readfile(path, "b"), "\n") == written)
  check(written ~= before .. "\n")
  check(not operation(buf, function() error("must not run after boundary ambiguity") end))
end)

it("fails closed when new transaction callbacks raise", function()
  pending("snapshot")
  watch_fault(function(fault)
    management.snapshot_pending = function() fault(); error("snapshot unavailable") end
    loop.start(buf); wait_done()
  end)
  check(calls == 0)
  check(management.has_pending(buf))
  if vim.env.STRAPS_PENDING_TRACE then print("pending loop assertions", assertion) end
end)
