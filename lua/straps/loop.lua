-- straps.loop: the coroutine-driven agent loop.
-- Owns the run lifecycle per buffer (start/stop/running), the ctx handed to
-- provider/tools/hooks (await/emit/on_cancel/cancelled), and the turn loop:
-- parse buffer -> provider -> tool_use blocks -> tool_results -> repeat.

local M = {}

local unpack = unpack or table.unpack

-- Captured once: the gate every tool call passes must not be swappable by
-- a later package.loaded / require substitution made from inside a run.
local registry = require("straps.registry")
local preflight_tool_input = registry.preflight_tool_input
local rejected_tool_inputs = setmetatable({}, { __mode = "k" })

-- bufnr -> { cancelled, cancel_fns, await_seq, done }
local runs = {}
local operations, owned_contexts = {}, setmetatable({}, { __mode = "k" })
local contextual, human_installed
local operation, replay
local replay_serial = 0
local replay_reservations = {}
local transaction_faults = {}
local context_reservations, context_consumer, context_schedule = {}, nil, nil

local function transaction_fault(bufnr, run, status)
  transaction_faults[bufnr] = status
  local main = runs[bufnr]
  local affected, handlers = { [run] = true }, {}
  if main then affected[main] = true end
  for active in pairs(operations[bufnr] or {}) do affected[active] = true end
  for active in pairs(affected) do
    active.transaction_terminal = true
    active.pending_emissions = nil
    active.done, active.cancelled = true, true
    active.await_seq = active.await_seq + 1
    for _, fn in ipairs(active.cancel_fns) do handlers[#handlers + 1] = fn end
    active.cancel_fns = {}
    if active.ctx then owned_contexts[active.ctx] = nil end
  end
  runs[bufnr], operations[bufnr], replay_reservations[bufnr], context_reservations[bufnr] = nil, nil, nil, nil
  for active in pairs(affected) do
    if active.diag_teardown then pcall(active.diag_teardown) end
    if active.family then
      local family = active.family
      active.family = nil
      pcall(contextual.finish, family)
    end
  end
  for _, fn in ipairs(handlers) do pcall(fn) end
  if main then pcall(function() require("straps.attention").finish(bufnr, main, "error") end) end
  pcall(function() require("straps.ui").progress(bufnr, { type = "done" }) end)
  pcall(function()
    vim.b[bufnr].straps_status = "idle"
    vim.b[bufnr].straps_run_reason = "error"
  end)
  error("straps: context transaction stopped: " .. tostring(status.error or status.status), 0)
end

local function checked_transaction(bufnr, run, fn, ...)
  local ok, status = pcall(fn, ...)
  if not ok or type(status) ~= "table" or (status.status ~= "committed_live" and status.status ~= "error")
    or type(status.terminal) ~= "boolean" then
    status = { terminal = true, status = "ambiguous", error = tostring(status) }
  end
  if status.terminal then transaction_fault(bufnr, run, status) end
  return status
end

function M.install_contextual(adapter)
  assert(not contextual and registry.trusted_setup_allowed(), "contextual loop setup sealed")
  local captured = {}
  for _, name in ipairs({ "begin", "bind", "finish", "stop", "close" }) do
    assert(type(adapter[name]) == "function", "missing contextual loop callback: " .. name)
    captured[name] = adapter[name]
  end
  contextual = captured
end

function M.install_human_operations(consumer)
  assert(not human_installed and registry.trusted_setup_allowed(), "human operation setup sealed")
  assert(type(consumer) == "function", "human operation consumer required")
  human_installed = true
  consumer(function(...) return operation(...) end, function(...) return replay(...) end)
end

function M.install_context_operations(consumer)
  assert(type(consumer) == "function", "context operation consumer required")
  if consumer ~= context_consumer then
    assert(not context_consumer and registry.trusted_setup_allowed(), "context operation setup sealed")
    context_consumer = consumer
    context_schedule = function(bufnr, fn) return operation(bufnr, fn, false, true) end
  end
  consumer(context_schedule)
end

local function finish_family(run)
  if run.family then
    local family = run.family
    run.family = nil
    contextual.finish(family)
  end
end

-- Config is read lazily per run so tests can run without init.lua/setup().
local function get_config()
  local ok, straps = pcall(require, "straps")
  local cfg = (ok and type(straps) == "table" and rawget(straps, "config")) or {}
  return {
    max_turns = cfg.max_turns or 128,
    -- Soft stop: end the run after this many CONSECUTIVE stalled turns (a turn
    -- is stalled when every tool call in it errored, or it repeats a
    -- (tool,input) call already made this run). This is the real
    -- spinning-catcher; max_turns is only the hard backstop, so it can be
    -- generous. 0 disables the detector (max_turns alone bounds the run).
    stall_limit = cfg.stall_limit or 6,
    -- A turn that ends (no tool_use) with no visible text after a tool call is
    -- the "runs a command then goes silent" symptom. Nudge the model up to
    -- this many times per run to report/continue before ending the run loudly
    -- with reason "blank". 0 disables the nudge (still ends loudly on the
    -- first blank turn). max_tokens with no text always ends loudly, no nudge.
    blank_nudge_limit = cfg.blank_nudge_limit or 1,
    max_tool_result_bytes = cfg.max_tool_result_bytes or 100000,
    -- Auto-compaction thresholds (both nil = off). Prefer auto_compact_tokens:
    -- with prompt caching on, a stable transcript is already cheap (cache
    -- reads), so compaction is a context-WINDOW tool, not a cost tool — set it
    -- near the model's limit. auto_compact_bytes stays for back-compat.
    auto_compact_tokens = cfg.auto_compact_tokens,
    auto_compact_bytes = cfg.auto_compact_bytes,
  }
end

local islist = vim.islist or vim.tbl_islist

-- vim.json.encode is compact-only; tool_use blocks want readable input.
local function pretty_json(v, ind)
  ind = ind or ""
  if type(v) ~= "table" then
    return vim.json.encode(v)
  end
  local nested = ind .. "  "
  if islist(v) and #v > 0 then
    local parts = {}
    for _, item in ipairs(v) do
      parts[#parts + 1] = nested .. pretty_json(item, nested)
    end
    return "[\n" .. table.concat(parts, ",\n") .. "\n" .. ind .. "]"
  end
  local keys = {}
  for k in pairs(v) do
    keys[#keys + 1] = k
  end
  if #keys == 0 then
    return "{}"
  end
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)
  local parts = {}
  for _, k in ipairs(keys) do
    parts[#parts + 1] = nested .. vim.json.encode(tostring(k)) .. ": " .. pretty_json(v[k], nested)
  end
  return "{\n" .. table.concat(parts, ",\n") .. "\n" .. ind .. "}"
end

local function pack(...)
  return { n = select("#", ...), ... }
end

-- Progress must never break a run: hook errors are swallowed, and the phase
-- mirror (vim.b straps_phase) is best-effort. phase == nil means "no change".
local function progress(bufnr, ctx, ev, phase)
  if transaction_faults[bufnr] then return end
  pcall(registry.try_call, "hook.on_progress", ev, ctx)
  if phase ~= nil then
    pcall(function() vim.b[bufnr].straps_phase = phase end)
  end
  -- The agents buffer (straps://agents) re-renders on any session's progress.
  -- This is mechanism, not policy, so it lives here beside the phase mirror
  -- rather than in the redefinable hook.on_progress. No-ops without an agents
  -- buffer open; always runs on the main loop.
  pcall(function() require("straps.ui").agents_refresh() end)
end

-- fn.log is optional and must never break a run: pcall'd try_call. The
-- buffer is stamped onto every event here so call sites stay terse.
local function log(bufnr, ev)
  ev.buf = bufnr
  pcall(registry.try_call, "fn.log", ev)
end

local function finish_events(bufnr, reason, run)
  if transaction_faults[bufnr] then return end
  require("straps.attention").finish(bufnr, run, reason)
  pcall(function() vim.b[bufnr].straps_status = "idle" end)
  pcall(function() vim.b[bufnr].straps_run_reason = reason end)
  pcall(vim.api.nvim_exec_autocmds, "User",
    { pattern = "StrapsStatusChanged", data = { bufnr = bufnr, status = "idle" } })
  pcall(vim.api.nvim_exec_autocmds, "User", { pattern = "StrapsRunEnd",
    data = { bufnr = bufnr, reason = reason, turns = run.turns, cancelled = run.cancelled == true } })
end

local pair_turn

local function crashed(bufnr, run, err)
  if run and run.fail then return run.fail(err) end
  if run then
    run.done = true
    finish_family(run)
    if run.ctx then owned_contexts[run.ctx] = nil end
  end
  runs[bufnr] = nil
  if run then pcall(pair_turn, bufnr, run) end
  finish_events(bufnr, "error", run or {})
  vim.notify("straps: run crashed: " .. tostring(err), vim.log.levels.ERROR)
end

local function flush_emissions(bufnr, run)
  local pending = run.pending_emissions
  run.pending_emissions = nil
  if transaction_faults[bufnr] or run.cancelled or not vim.api.nvim_buf_is_valid(bufnr) then return end
  for _, text in ipairs(pending or {}) do require("straps.state").append_text(bufnr, text) end
end

local function new_ctx(bufnr, run)
  local ctx
  ctx = {
    bufnr = bufnr,

    -- start(resolve) begins async work; await yields the coroutine and
    -- resolve(...) resumes it. The driver wraps resume in vim.schedule so
    -- resolve is safe from any callback context; resolve is honored exactly
    -- once (later calls, and calls belonging to a previous await, are no-ops).
    await = function(start)
      local co = assert(coroutine.running(), "straps: ctx.await outside the run coroutine")
      run.await_seq = run.await_seq + 1
      local seq = run.await_seq
      local resolved = false
      start(function(...)
        if resolved then
          return
        end
        resolved = true
        local args = pack(...)
        vim.schedule(function()
          if run.done or run.await_seq ~= seq or coroutine.status(co) ~= "suspended" then
            return
          end
          -- Every synchronous segment of the run executes with this
          -- buffer's registry scope active, so all lookups (and defines)
          -- inside the run resolve through the session's scope chain.
          local prev_scope = registry.set_active_scope(bufnr)
          local ok, err = coroutine.resume(co, unpack(args, 1, args.n))
          registry.set_active_scope(prev_scope)
          if not ok then
            crashed(bufnr, run, err)
          end
        end)
      end)
      local ret = pack(coroutine.yield())
      run.cancel_fns = {} -- handlers are cleared after each await completes
      if transaction_faults[bufnr] then error("straps: context transaction stopped", 0) end
      return unpack(ret, 1, ret.n)
    end,

    -- Provider streaming events. text_delta is appended to the current
    -- (assistant) block; buffer mutation is scheduled onto the main loop.
    -- vim.schedule is FIFO, so deltas emitted before resolve land first.
    emit = function(ev)
      if run.done or run.cancelled or transaction_faults[bufnr] then return end
      if type(ev) == "table" then run.provider_emitted = true end
      if type(ev) == "table" and ev.type == "text_delta" and ev.text and ev.text ~= "" then
        run.pending_emissions = run.pending_emissions or {}
        run.pending_emissions[#run.pending_emissions + 1] = ev.text
        vim.schedule(function() flush_emissions(bufnr, run) end)
      end
    end,

    on_cancel = function(fn)
      if run.cancelled then
        pcall(fn)
        return
      end
      run.cancel_fns[#run.cancel_fns + 1] = fn
    end,

    cancelled = function()
      return run.cancelled
    end,

    forget_call = function(name, input)
      run.seen_calls[tostring(name) .. "\0" .. pretty_json(input or {})] = nil
    end,

    -- Stream liveness heartbeat: the provider calls this from its stdout
    -- callback on every received chunk (the same signal the watchdog resets
    -- on). Records a last-byte time the default progress UI reads to show
    -- "receiving" vs "silent Ns". Pure table write via ui.note_activity; never
    -- touches the buffer, so it is safe from the fast callback context. The
    -- pcall keeps a redefined/absent progress hook from breaking the stream.
    activity = function()
      pcall(function() require("straps.ui").note_activity(bufnr) end)
    end,
  }
  return ctx
end

-- The model-origin gate: hook.confirm, then the before_tool fan-out. Passed
-- to registry.gate_tool as opts.confirm so it runs AFTER the before-guards.
local function confirm_then_before_tool(name, input, ctx)
  local allowed, reason, source = registry.call("hook.confirm", name, input, ctx)
  if not allowed then
    return false, reason, source
  end
  registry.call_hooks("hook.before_tool", name, input, ctx)
  return true
end

-- Stage 1 of a tool_use block: before-guards -> confirm -> before_tool.
-- Returns allowed, reason, run (run executes the gated entry exactly once).
local function gate_tool(ctx, block)
  if rejected_tool_inputs[block] then return false, rejected_tool_inputs[block] end
  return registry.gate_tool(block.name, block.input or {}, ctx, { confirm = confirm_then_before_tool })
end

local function normalize_result(ok, result)
  if ok then
    if result == nil then
      return "ok"
    elseif type(result) == "table" then
      return vim.json.encode(result)
    end
  end
  return tostring(result)
end

local function post_tool(ctx, block, cfg, ok, result)
  local name, input = block.name, block.input or {}
  if #result > cfg.max_tool_result_bytes then
    -- Back the cut up to a UTF-8 character boundary so we never emit a byte
    -- sequence split mid-character into the transcript / API payload.
    local cut = cfg.max_tool_result_bytes
    while cut > 0 do
      local b = result:byte(cut + 1)
      if not b or b < 0x80 or b >= 0xC0 then break end -- next byte is not a continuation byte
      cut = cut - 1
    end
    result = result:sub(1, cut)
      .. ("\n[straps: result truncated at %d bytes]"):format(cfg.max_tool_result_bytes)
  end

  -- Fold hook.after_tool subscribers in registration order: each one receives
  -- the CURRENT result (so subscriber N sees subscriber N-1's transformation)
  -- and a non-nil return replaces `result` for the next subscriber; a raising
  -- subscriber is skipped so it can never break the ones after it.
  for _, entry in ipairs(registry.hook_entries("hook.after_tool")) do
    local hok, ret = pcall(registry.call, entry.name, name, input, result, ok, ctx)
    if hok and ret ~= nil then
      result = ret
    end
  end

  -- The after-guards run last, on exactly the bytes the model will see.
  result, ok = registry.after_guards(name, input, tostring(result), ok, ctx)
  return ok, tostring(result)
end

-- Stage 2: run -> normalize -> post_tool.
local function finish_tool(ctx, block, cfg, run)
  local ok, result = run(ctx)
  return post_tool(ctx, block, cfg, ok, normalize_result(ok, result))
end

local function append_tool_result(bufnr, block, ok, result, run)
  if transaction_faults[bufnr] then return end
  local management = require("straps.context_management")
  if block.name == "context_retrieve" then
    if ok then
      local called, status = pcall(management.append_result, bufnr,
        { id = block.id, is_error = false }, tostring(result), run and run.ctx)
      if not called or type(status) ~= "table" or (status.status ~= "committed_live" and status.status ~= "error"
        and status.status ~= "conflict" and status.status ~= "ambiguous") or type(status.terminal) ~= "boolean" then
        status = { terminal = true, status = "ambiguous", error = tostring(status) }
      end
      if status.appended and run and run.turn_appended then run.turn_appended[block] = true end
      if status.terminal or status.status == "conflict" or status.status == "ambiguous" then transaction_fault(bufnr, run, status) end
      if status.status == "committed_live" and status.appended == true then return end
      if status.status == "committed_live" then
        transaction_fault(bufnr, run, { status = "ambiguous", error = "retrieval append was not confirmed", terminal = true })
      end
      ok, result = false, status.error or "retrieval result could not be persisted"
    end
    management.release(bufnr)
  end
  require("straps.state").append(bufnr, "tool_result",
    { id = block.id, is_error = not ok }, tostring(result))
  if run and run.turn_appended then run.turn_appended[block] = true end
end

pair_turn = function(bufnr, run)
  if run.diag_teardown then pcall(run.diag_teardown) end
  if run.ctx then run.ctx.batch_preview = nil end
  if transaction_faults[bufnr] then return end
  local blocks = run.turn_blocks
  run.turn_blocks = nil
  if not blocks then return end
  for _, block in ipairs(blocks) do
    if not run.turn_appended[block] then
      local item = run.turn_items[block]
      local text = "run interrupted before this tool finished"
      if item and item.executed then
        text = "run interrupted after this tool ran; its result was not processed"
      elseif item and item.final then
        text = item.final
      end
      pcall(append_tool_result, bufnr, block, false, text, run)
    end
  end
end

local function cancel_operation(run)
  if run.done or run.cancelled then return end
  run.cancelled = true
  finish_family(run)
  local handlers = run.cancel_fns
  run.cancel_fns = {}
  for _, fn in ipairs(handlers) do pcall(fn) end
  vim.schedule(function()
    if run.done or coroutine.status(run.co) ~= "suspended" then return end
    run.await_seq = run.await_seq + 1
    local previous = registry.set_active_scope(run.ctx.bufnr)
    local ok, err = coroutine.resume(run.co)
    registry.set_active_scope(previous)
    if not ok then run.fail(err) end
  end)
end

operation = function(bufnr, fn, reserve_replay, reserve_context)
  if context_reservations[bufnr] then return false, "a context operation is active" end
  if reserve_context and (runs[bufnr] or operations[bufnr] or replay_reservations[bufnr]) then
    return false, "context controls require an idle session with no human operations"
  end
  if transaction_faults[bufnr] then return false, "context transaction requires reconciliation" end
  if type(fn) ~= "function" or not vim.api.nvim_buf_is_valid(bufnr) then return false, "invalid human operation" end
  registry.ensure_scope(bufnr)
  registry.freeze_guards()
  local run = { cancelled = false, cancel_fns = {}, await_seq = 0, done = false, seen_calls = {} }
  local ctx = new_ctx(bufnr, run)
  run.ctx = ctx
  operations[bufnr] = operations[bufnr] or {}
  operations[bufnr][run] = true
  owned_contexts[ctx] = run
  if reserve_replay then replay_reservations[bufnr] = run end
  if reserve_context then context_reservations[bufnr] = run end
  local function done(err)
    if run.done then return end
    if reserve_context then
      local status = require("straps.context_management").transaction_status(bufnr)
      if status and status.terminal then transaction_fault(bufnr, run, status) end
    end
    flush_emissions(bufnr, run)
    run.done = true
    finish_family(run)
    owned_contexts[ctx] = nil
    if replay_reservations[bufnr] == run then replay_reservations[bufnr] = nil end
    if context_reservations[bufnr] == run then context_reservations[bufnr] = nil end
    local active = operations[bufnr]
    if active then
      active[run] = nil
      if not next(active) then operations[bufnr] = nil end
    end
    if err then
      pcall(pair_turn, bufnr, run)
      vim.notify("straps: human operation failed: " .. tostring(err), vim.log.levels.ERROR)
    end
  end
  run.fail = done
  run.co = coroutine.create(function()
    if contextual then run.family = contextual.begin(ctx) end
    fn(ctx)
    done()
  end)
  local previous = registry.set_active_scope(bufnr)
  local ok, err = coroutine.resume(run.co)
  registry.set_active_scope(previous)
  if not ok then done(err) end
  return true, function() cancel_operation(run) end
end

replay = function(description, current_ctx, fresh_gate)
  if current_ctx and (runs[current_ctx.bufnr] or replay_reservations[current_ctx.bufnr]) then
    return false, "replay requires an idle actor"
  end
  local owner = owned_contexts[current_ctx]
  if not owner or owner.done or owner.cancelled or type(description) ~= "table"
    or description.terminal ~= true or description.execution_started ~= false
    or type(description.binding) ~= "table" or description.binding.session ~= current_ctx.bufnr
    or type(fresh_gate) ~= "function" then return false, "invalid replay context or decision" end
  local binding = vim.deepcopy(description.binding)
  local name = binding.definition and binding.definition.name
  if type(name) ~= "string" or name:sub(1, 5) ~= "tool." then return false, "invalid replay tool" end
  replay_serial = replay_serial + 1
  local block = { id = "straps-replay-" .. current_ctx.bufnr .. "-" .. replay_serial,
    name = name:sub(6), input = binding.input or {} }
  return operation(current_ctx.bufnr, function(ctx)
    local run = owned_contexts[ctx]
    ctx.await(function(resolve) resolve() end)
    if run.cancelled or owner.cancelled or runs[ctx.bufnr]
      or replay_reservations[ctx.bufnr] ~= run or not vim.api.nvim_buf_is_valid(ctx.bufnr) then return end
    require("straps.state").append(ctx.bufnr, "tool_use", { id = block.id, name = block.name }, pretty_json(block.input))
    run.turn_blocks, run.turn_items, run.turn_appended = { block }, {}, {}
    local allowed, reason, execute = fresh_gate(confirm_then_before_tool, ctx)
    local ok, result = false, reason or "replay denied"
    if allowed and not run.cancelled then
      ok, result = finish_tool(ctx, block, get_config(), execute)
      run.turn_items[block] = { executed = true }
    elseif run.cancelled then result = "replay cancelled before execution" end
    append_tool_result(ctx.bufnr, block, ok, result, run)
    run.turn_blocks = nil
  end, true)
end

-- Builtin read-only tools whose effects are safe to overlap when the model
-- sends a batch. Writes and user-interaction/presentation tools stay serial.
local PARALLEL_READONLY = {
  read_file = true, glob = true, tree = true, path_info = true, grep = true,
  registry_list = true, registry_get = true, skill = true,
  diagnostics = true, diagnostic_at = true, diagnostic_next = true,
  lsp_status = true,
  declaration = true, definition = true, type_definition = true,
  implementation = true, references = true,
  symbols = true, read_symbol = true, tree_sitter_status = true, node_at = true,
  read_node = true, hover = true, workspace_symbols = true,
  context = true, help_search = true, agents = true, models = true,
}

local function all_parallel_readonly(blocks)
  if #blocks < 2 then return false end
  for _, block in ipairs(blocks) do
    if not PARALLEL_READONLY[block.name] then return false end
  end
  return true
end

local function child_ctx(parent_ctx, bufnr, finish, run)
  local ctx = {
    bufnr = bufnr,
    emit = parent_ctx.emit,
    on_cancel = parent_ctx.on_cancel,
    cancelled = parent_ctx.cancelled,
    activity = parent_ctx.activity,
    forget_call = parent_ctx.forget_call,
  }
  ctx.await = function(start)
    local co = assert(coroutine.running(), "straps: child ctx.await outside coroutine")
    ctx._await_seq = (ctx._await_seq or 0) + 1
    local seq = ctx._await_seq
    local resolved = false
    start(function(...)
      if resolved then return end
      resolved = true
      local args = pack(...)
      vim.schedule(function()
        if ctx._await_seq ~= seq or coroutine.status(co) ~= "suspended" then return end
        -- A resolve arriving after the run was cancelled or finished must not
        -- resume the job: its stub result has already been appended.
        if run and (run.cancelled or run.done) then return end
        local prev_scope = registry.set_active_scope(bufnr)
        local ok, err = coroutine.resume(co, unpack(args, 1, args.n))
        registry.set_active_scope(prev_scope)
        if not ok then finish(false, tostring(err)) end
      end)
    end)
    return coroutine.yield()
  end
  return ctx
end

local CANCELLED_TEXT = "run cancelled before this tool executed"
local PREVIEW_TOOLS = { write_file = true, edit_file = true, patch_file = true }

local function ends_gate_run(block)
  local ok, cap = pcall(registry.try_call, "fn.capability", block.name, block.input or {})
  return not ok or cap == "define" or cap == "lua" or cap == "agent_tool"
end

local function starts_segment(block)
  local ok, v = pcall(registry.try_call, "fn.starts_segment", block.name, block.input or {})
  return ok and v == true
end

local function begin_diagnostics(ctx, run, bufnr)
  local state = require("straps.state")
  local records, order, aug = {}, {}, nil
  local d = { current = nil }
  local function teardown()
    if aug then pcall(vim.api.nvim_del_augroup_by_id, aug) end
    aug = nil
    ctx.defer_diagnostics = nil
    run.diag_teardown = nil
  end
  run.diag_teardown = teardown
  ctx.defer_diagnostics = function(path)
    local buf = state.find_buf(path)
    if not buf then return false end
    local r = records[buf]
    if not r then
      r = { bufnr = buf, blocks = {} }
      records[buf] = r
      order[#order + 1] = r
      if not aug then
        aug = vim.api.nvim_create_augroup("straps_batch_diagnostics_" .. bufnr, { clear = true })
        vim.api.nvim_create_autocmd("DiagnosticChanged", {
          group = aug,
          callback = function(args)
            local rec = records[args.buf]
            if rec then rec.last_event = vim.uv.hrtime() end
          end,
        })
      end
    end
    r.path = path
    r.last_write = vim.uv.hrtime()
    if d.current then r.blocks[#r.blocks + 1] = d.current end
    return true
  end
  function d.finish(items)
    local texts = {}
    if #order == 0 or run.cancelled then teardown() return texts end
    local ok, by_buf = pcall(registry.call, "fn.write_diagnostics", order, ctx)
    teardown()
    if not ok then
      log(bufnr, { ev = "diagnostics_error", err = tostring(by_buf) })
      return texts
    end
    for _, r in ipairs(order) do
      local text = type(by_buf) == "table" and by_buf[r.bufnr] or nil
      if type(text) == "string" and text ~= "" then
        for j = #r.blocks, 1, -1 do
          local item = items[r.blocks[j]]
          if item and item.executed and item.ok == true then
            texts[r.blocks[j]] = texts[r.blocks[j]] and (texts[r.blocks[j]] .. "\n" .. text) or text
            break
          end
        end
      end
    end
    return texts
  end
  return d
end

local function run_segments(bufnr, ctx, run, cfg, blocks)
  local state = require("straps.state")
  local out = { n_calls = 0, n_errors = 0 }
  local items = run.turn_items
  local function record(block, ok, text, ms)
    append_tool_result(bufnr, block, ok, text, run)
    if not ok then
      out.n_errors = out.n_errors + 1
      out.last_error = text
    end
    log(bufnr, { ev = "tool", name = block.name, ms = ms or 0, is_error = not ok })
    progress(bufnr, ctx, { type = "tool_done", name = block.name, is_error = not ok })
  end
  local i = 1
  while i <= #blocks and not run.cancelled do
    local seg, preview = {}, {}
    ctx.batch_preview = function(path)
      return preview[state.path_key(path)]
    end
    while i <= #blocks and not run.cancelled do
      local block = blocks[i]
      if #seg > 0 and starts_segment(block) then break end
      local item = {}
      items[block] = item
      seg[#seg + 1] = block
      i = i + 1
      out.n_calls = out.n_calls + 1
      local key = tostring(block.name) .. "\0" .. pretty_json(block.input or {})
      if run.seen_calls[key] then out.any_repeat = true else out.any_new = true end
      run.seen_calls[key] = true
      progress(bufnr, ctx, { type = "gate", name = block.name }, "gate: " .. tostring(block.name))
      local t0 = vim.uv.hrtime()
      local allowed, reason, gated = gate_tool(ctx, block)
      if transaction_faults[bufnr] then error("straps: context transaction stopped", 0) end
      log(bufnr, { ev = "gate", name = block.name, ms = math.floor((vim.uv.hrtime() - t0) / 1e6), allowed = allowed })
      if allowed then
        item.run = gated
        local input = block.input or {}
        if PREVIEW_TOOLS[block.name] and type(input.path) == "string" then
          pcall(function()
            local k = state.path_key(input.path)
            local base = preview[k] or state.file_text(input.path)
            preview[k] = state.simulate_edit(block.name, input, base) or base
          end)
        end
      else
        item.final = reason
      end
      if ends_gate_run(block) then break end
    end
    ctx.batch_preview = nil

    local diag = begin_diagnostics(ctx, run, bufnr)
    for _, block in ipairs(seg) do
      local item = items[block]
      if item.run and run.cancelled then
        item.final = CANCELLED_TEXT
      elseif item.run then
        progress(bufnr, ctx, { type = "tool", name = block.name }, "tool: " .. tostring(block.name))
        diag.current = block
        local t0 = vim.uv.hrtime()
        item.ok, item.raw = item.run(ctx)
        item.executed = true
        item.ms = math.floor((vim.uv.hrtime() - t0) / 1e6)
        diag.current = nil
      end
    end
    local texts = diag.finish(items)

    for _, block in ipairs(seg) do
      local item = items[block]
      if item.executed then
        local ok, text = item.ok, nil
        local nok, s = pcall(normalize_result, item.ok, item.raw)
        if nok then
          text = s
        else
          ok, text = false, "straps: could not encode the tool result: " .. tostring(s)
        end
        if texts[block] then text = text .. "\n" .. texts[block] end
        ok, text = post_tool(ctx, block, cfg, ok, text)
        record(block, ok, text, item.ms)
      else
        record(block, false, item.final or CANCELLED_TEXT, 0)
      end
    end
  end
  for j = i, #blocks do
    out.n_calls = out.n_calls + 1
    record(blocks[j], false, CANCELLED_TEXT, 0)
  end
  run.turn_blocks, run.turn_items, run.turn_appended = nil, nil, nil
  out.cancelled = run.cancelled
  return out
end

--- A steering queue entry as (text, source). Entries are { text, source }
--- tables; a legacy plain string is the user's.
function M.steering_entry(entry)
  if type(entry) == "string" then return entry, "user" end
  if type(entry) == "table" and type(entry.text) == "string" then
    return entry.text, entry.source or "user"
  end
  return nil, nil
end

--- User activity on a session re-arms watch wakes: the wake count returns to
--- zero and a :StrapsStop pause is lifted.
function M.note_user_activity(bufnr)
  if transaction_faults[bufnr] then return end
  pcall(function()
    vim.b[bufnr].straps_watch_wakes = 0
    vim.b[bufnr].straps_watch_paused = nil
  end)
end

--- The user's stop: cancel the run and pause watch wakes for the session
--- until the user sends to it again. Cascaded and timeout stops call M.stop.
function M.user_stop(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if transaction_faults[bufnr] then return end
  pcall(function() require("straps.context_ui").cancel(bufnr) end)
  pcall(function() vim.b[bufnr].straps_watch_paused = true end)
  return M.stop(bufnr)
end

-- Drain the steering queue (vim.b straps_steering): append each queued entry's
-- text as an ordinary user block and clear the queue. Returns true if anything
-- was drained. The buffer IS the request, so the next parse picks these up.
local function drain_steering(bufnr)
  local state = require("straps.state")
  local queue = vim.b[bufnr].straps_steering
  if type(queue) ~= "table" or #queue == 0 then
    return false
  end
  for _, entry in ipairs(queue) do
    local text, source = M.steering_entry(entry)
    if text then
      state.append(bufnr, "user", nil, text)
      if source == "user" then M.note_user_activity(bufnr) end
    end
  end
  vim.b[bufnr].straps_steering = nil
  return true
end

local function harness_note(bufnr, text)
  require("straps.state").append(bufnr, "user", nil, "[straps] " .. text)
end

local function nothing_to_send(bufnr)
  local state = require("straps.state")
  local trailing = state.last_user_text(bufnr)
  if trailing ~= nil and vim.trim(trailing) == "" then
    return "type your request under the trailing %%[straps:user]%% marker"
  end
  local messages = state.parse(bufnr).messages
  if #messages == 0 then
    return "type your request under the trailing %%[straps:user]%% marker"
  end
  if messages[#messages].role ~= "user" then
    return "the transcript ends with an assistant message;"
      .. " type your request under the trailing %%[straps:user]%% marker"
  end
end

-- Returns the run's ending reason:
-- "ok" | "cancelled" | "max_turns" | "stalled" | "blank".
local function run_turns(bufnr, ctx, run)
  local state = require("straps.state")
  local cfg = get_config()

  local function cancelled_note()
    harness_note(bufnr, "run cancelled (:StrapsStop)")
    return "cancelled"
  end

  progress(bufnr, ctx, { type = "start" }, "starting")
  log(bufnr, { ev = "run_start" })
  registry.call_hooks("hook.on_run_start", ctx)

  -- Per-buffer override (subagents get their own, usually tighter, budget).
  local max_turns = cfg.max_turns
  pcall(function()
    max_turns = vim.b[bufnr].straps_max_turns or max_turns
  end)

  -- Stall detection state: run.stall counts CONSECUTIVE stalled turns (reset
  -- by any productive turn); seen_calls records (tool.name .. input) of every
  -- tool call so far, so a repeat is a stall signal. A turn is stalled when it
  -- issued tool calls AND every one errored, OR any was an exact repeat.
  run.stall = 0
  run.seen_calls = {}
  local stall_limit = cfg.stall_limit or 0
  -- Blank-turn nudges used so far this run (a model that ends its turn with no
  -- visible text after a tool call gets nudged, bounded by blank_nudge_limit).
  run.blank_nudges = 0
  local blank_nudge_limit = cfg.blank_nudge_limit or 0

  for turn = 1, max_turns do
    run.turns = turn
    run.provider_emitted = false
    drain_steering(bufnr) -- queued steering becomes user blocks before parse
    -- Per-turn seam, before the parse that builds this turn's request: the
    -- default notice tells the agent which model/effort it is running on and
    -- re-announces a mid-run switch (the pickers write vim.b between turns).
    registry.call_hooks("hook.on_turn_start", ctx, turn)
    -- Auto-compaction (off unless a threshold is set): the loop is about to
    -- read the whole buffer anyway, so the size check is cheap. Every compaction
    -- rewrites old message blocks, which invalidates the messages cache tier
    -- from the first edit onward (tools+system survive) — so it must be COARSE:
    -- a growth guard stops it re-firing every turn (which would blow the cache
    -- every turn) when keep_turns content alone already sits above the limit.
    if not require("straps.context_management").enabled(bufnr)
      and not require("straps.context_management").has_pending(bufnr)
      and (type(cfg.auto_compact_tokens) == "number" or type(cfg.auto_compact_bytes) == "number") then
      local bytes = vim.api.nvim_buf_get_offset(bufnr, vim.api.nvim_buf_line_count(bufnr))
      -- Prefer the REAL context fill the API reported last turn (input_tokens
      -- is the whole replayed prompt the model just saw) over a byte guess.
      -- Only fall back to bytes/3.5 before the first response, when there is
      -- no usage yet. Users tune the threshold, so the divisor need only be in
      -- the ballpark.
      local real = run.usage and tonumber(run.usage.input_billed)
      local est_tokens = real or math.floor(bytes / 3.5)
      local over = (type(cfg.auto_compact_tokens) == "number" and est_tokens > cfg.auto_compact_tokens)
        or (type(cfg.auto_compact_bytes) == "number" and bytes > cfg.auto_compact_bytes)
      -- Coarseness guard: after a compaction, require ~20% growth before the
      -- next one, so a session that stays near the limit doesn't thrash the
      -- cache. (Post-compaction size is smaller, so this naturally spaces them.)
      local grown = (not run.last_compact_bytes) or (bytes > run.last_compact_bytes * 1.2)
      if over and grown then
        local ok_c, summary = pcall(registry.try_call, "fn.compact", bufnr)
        run.last_compact_bytes =
          vim.api.nvim_buf_get_offset(bufnr, vim.api.nvim_buf_line_count(bufnr))
        log(bufnr, { ev = "compact", est_tokens = est_tokens,
          summary = (ok_c and type(summary) == "string") and summary or nil })
      end
    end
    local parsed = state.parse(bufnr)
    -- Newer models (including the default) reject a request that ends on an
    -- assistant message — assistant prefill is unsupported — so fail here,
    -- not with an opaque HTTP 400 after a round trip.
    if #parsed.messages == 0 or parsed.messages[#parsed.messages].role ~= "user" then
      if turn > 1 then
        -- Mid-run an assistant-role tail means the finished turn appended no
        -- user-role content for the model to answer.
        error("the last turn added nothing to respond to — the model claimed"
          .. ' stop_reason "tool_use" but requested no tools, or steering was blank', 0)
      end
      error("nothing to send — " .. (nothing_to_send(bufnr) or "empty transcript"), 0)
    end
    log(bufnr, { ev = "turn", turn = turn, messages = #parsed.messages })
    local tools = registry.call("fn.build_tools")

    -- Model awareness rides in the REQUEST's system text, never the
    -- transcript: parse merges same-role messages, so a user-role notice
    -- would concatenate with the user's own words (harness text wearing the
    -- user's voice). fn.model_note re-resolves per request, so a mid-run
    -- :StrapsModel / :StrapsEffort switch is named on the very next turn.
    -- parsed is a fresh table each turn; appending here never touches the
    -- buffer. pcall so a broken redefinition degrades to no note, not a
    -- failed run.
    local ok_note, note = pcall(registry.try_call, "fn.model_note", ctx)
    local system = parsed.system
    if ok_note and type(note) == "string" and note ~= "" then
      system = (system and system ~= "") and (system .. "\n\n" .. note) or note
    end

    -- Empty assistant marker first: the provider streams text_delta events
    -- into it via ctx.emit/state.append_text. Empty text is dropped by parse.
    local request = { system = system, messages = parsed.messages, tools = tools }
    local allowance = {}
    if require("straps.context_management").enabled(bufnr) then
      local manager = require("straps.context_management")
      local ok_boundary, result = pcall(manager.boundary, bufnr, ctx, run, tools, note, allowance)
      local terminal = manager.transaction_status(bufnr)
      if terminal then transaction_fault(bufnr, run, terminal) end
      if not ok_boundary then error(result, 0) end
      request = result
    end
    local management = require("straps.context_management")
    local captured_ok, capture, capture_status = true, nil, nil
    if management.has_pending(bufnr) then
      captured_ok, capture, capture_status = pcall(management.snapshot_pending, bufnr)
    end
    if not captured_ok then
      transaction_fault(bufnr, run, { status = "ambiguous", error = tostring(capture), terminal = true })
    end
    if capture_status then
      if capture_status.terminal then transaction_fault(bufnr, run, capture_status) end
      error(capture_status.error or "could not capture pending retrieval", 0)
    end
    state.append(bufnr, "assistant", nil, "")
    local recovery
    if management.enabled(bufnr) then
      recovery = management.capture_recovery(bufnr, ctx, tools, note, allowance)
    end
    progress(bufnr, ctx, { type = "thinking", turn = turn, max = max_turns }, "thinking")
    local dispatched, resp = pcall(registry.call, "fn.provider", request, ctx)
    if not dispatched and recovery and not run.cancelled and not run.provider_emitted
      and type(resp) == "table" and rawget(resp, "kind") == "context_overflow"
      and rawget(resp, "rejected") == true and rawget(resp, "response_started") == false
      and type(rawget(resp, "provider")) == "string" and type(rawget(resp, "route")) == "string"
      and rawget(resp, "status") == 400 and type(rawget(resp, "code")) == "string"
      and type(rawget(resp, "message")) == "string" then
      local recovered, result, validate_retry = pcall(management.recover, recovery, ctx)
      local terminal = management.transaction_status(bufnr)
      if terminal then transaction_fault(bufnr, run, terminal) end
      if not recovered then error(result, 0) end
      request = result
      capture, capture_status = management.snapshot_pending(bufnr)
      if capture_status then
        if capture_status.terminal then transaction_fault(bufnr, run, capture_status) end
        error(capture_status.error or "could not recapture pending retrieval", 0)
      end
      validate_retry()
      if run.provider_emitted then error("context management: output appeared during overflow recovery", 0) end
      dispatched, resp = pcall(registry.call, "fn.provider", request, ctx)
    end
    if not dispatched then error(resp, 0) end
    if run.cancelled then
      return cancelled_note()
    end
    assert(type(resp) == "table", "straps: fn.provider must return a table")
    if capture and resp.complete ~= false and (resp.stop_reason == "end_turn" or resp.stop_reason == "tool_use") then
      checked_transaction(bufnr, run, management.consume_pending, capture, ctx)
    end

    -- Thread token usage back into buffer state. The provider captures it per
    -- response; accumulate it on the run and mirror it to vim.b so the winbar
    -- and auto-compaction can read a REAL context-fill number instead of a
    -- bytes/token guess. `input_tokens` is the size of the prompt the model
    -- just saw (the whole replayed transcript), so it — not a running sum — is
    -- the current context fill; cache_read/creation are the caching split.
    if type(resp.usage) == "table" then
      local u = resp.usage
      local acc = run.usage or { requests = 0, output_total = 0 }
      acc.requests = acc.requests + 1
      acc.input = tonumber(u.input_tokens) or acc.input
      acc.cache_read = tonumber(u.cache_read_input_tokens) or 0
      acc.cache_creation = tonumber(u.cache_creation_input_tokens) or 0
      acc.output = tonumber(u.output_tokens) or 0
      acc.output_total = acc.output_total + (tonumber(u.output_tokens) or 0)
      -- The billed input side = fresh input + both cache tiers; the ratio of
      -- cache_read to that total is the cache hit rate the winbar shows.
      acc.input_billed = (acc.input or 0) + acc.cache_read + acc.cache_creation
      run.usage = acc
      pcall(function() vim.b[bufnr].straps_usage = acc end)
      pcall(function() require("straps.ui").redraw_status(true) end)
    end

    -- Two phases: append EVERY tool_use marker first, THEN run the batch
    -- (run_segments, or the parallel read-only path) and append the results
    -- in tool_use order. The transcript then replays as ONE assistant
    -- message carrying the whole batch of tool_use blocks followed by one
    -- user message with all the results (parse merges adjacent same-role
    -- blocks) — the exact shape the model sent. Interleaving use/result
    -- pairs would rewrite a batched turn into single-call turns, teaching
    -- the model by its own example never to batch.
    local tool_blocks = {}
    run.turn_blocks, run.turn_items, run.turn_appended = tool_blocks, {}, {}
    for _, block in ipairs(resp.content or {}) do
      if block.type == "tool_use" then
        local bounded, reason = preflight_tool_input(block.input or {})
        if not bounded then
          block = { type = "tool_use", id = block.id, name = block.name, input = {} }
          rejected_tool_inputs[block] = reason
        end
        state.append(bufnr, "tool_use",
          { id = block.id, name = block.name }, pretty_json(block.input or {}))
        tool_blocks[#tool_blocks + 1] = block
      end
    end
    -- Per-turn stall signals, folded in as each tool runs. any_new tracks
    -- whether the turn made at least one call never seen before, so a turn
    -- that mixes fresh work with an idempotent re-read (a legitimate pattern)
    -- is not mistaken for spinning.
    local n_calls, n_errors, any_repeat, any_new, last_error = 0, 0, false, false, nil
    if all_parallel_readonly(tool_blocks) then
      local jobs = {}
      -- Gate every block first, on the run coroutine (a before-guard may
      -- await), so no job starts until the whole batch has passed the gate.
      for i, block in ipairs(tool_blocks) do
        progress(bufnr, ctx, { type = "tool", name = block.name }, "tool: " .. tostring(block.name))
        local key = tostring(block.name) .. "\0" .. pretty_json(block.input or {})
        if run.seen_calls[key] then any_repeat = true else any_new = true end
        run.seen_calls[key] = true
        n_calls = n_calls + 1
        if run.cancelled then
          jobs[i] = { done = true, ok = false, result = "run cancelled before this tool executed", ms = 0 }
        else
          local allowed, reason, gated_run = gate_tool(ctx, block)
          if not allowed then
            jobs[i] = { done = true, ok = false, result = reason, ms = 0 }
          else
            jobs[i] = { done = false, block = block, run = gated_run }
          end
        end
      end
      if run.cancelled then
        for _, job in ipairs(jobs) do
          if not job.done then
            job.done, job.ok, job.result, job.ms = true, false, "run cancelled before this tool executed", 0
          end
        end
      end
      for i, block in ipairs(tool_blocks) do
        local job = jobs[i]
        if not job.done then
          job.started = vim.uv.hrtime()
          local function finish(ok, result)
            if job.done then return end
            job.done = true
            job.ok = ok
            job.result = tostring(result)
            job.ms = math.floor((vim.uv.hrtime() - job.started) / 1e6)
          end
          local co = coroutine.create(function()
            local cctx = child_ctx(ctx, bufnr, finish, run)
            if run.family then contextual.bind(run.family, cctx) end
            finish(finish_tool(cctx, block, cfg, job.run))
            if run.turn_items then run.turn_items[block] = { executed = true } end
          end)
          local prev_scope = registry.set_active_scope(bufnr)
          local ok_resume, err = coroutine.resume(co)
          registry.set_active_scope(prev_scope)
          if not ok_resume then finish(false, err) end
        end
      end
      ctx.await(function(resolve)
        local function poll()
          local pending = false
          for _, job in ipairs(jobs) do
            if not job.done then pending = true break end
          end
          if pending and not run.cancelled then
            vim.defer_fn(poll, 20)
          else
            resolve()
          end
        end
        poll()
      end)
      for i, block in ipairs(tool_blocks) do
        local job = jobs[i]
        local ok, result = job.ok == true, job.result or ""
        if run.cancelled and not job.done then
          ok, result = false, "run cancelled before this tool executed"
        end
        append_tool_result(bufnr, block, ok, result, run)
        if not ok then
          n_errors = n_errors + 1
          last_error = result
        end
        log(bufnr, { ev = "tool", name = block.name, ms = job.ms or 0, is_error = not ok })
        progress(bufnr, ctx, { type = "tool_done", name = block.name, is_error = not ok })
      end
      run.turn_blocks, run.turn_items, run.turn_appended = nil, nil, nil
      if run.cancelled then return cancelled_note() end
    else
      local outcome = run_segments(bufnr, ctx, run, cfg, tool_blocks)
      n_calls, n_errors, last_error = outcome.n_calls, outcome.n_errors, outcome.last_error
      if outcome.any_repeat then any_repeat = true end
      if outcome.any_new then any_new = true end
      if outcome.cancelled then return cancelled_note() end
    end

    -- Classify the turn for the stall detector. A turn with no tool calls is
    -- never a stall (it is either the final answer or steering). A turn that
    -- did work is stalled when every call errored, or when every call was an
    -- exact repeat of an earlier one (no new distinct call this turn) — a
    -- turn that also made progress on something new is not spinning.
    -- Consecutive stalls accumulate; a productive turn resets.
    if stall_limit > 0 and n_calls > 0 then
      local stalled = (n_errors == n_calls) or (any_repeat and not any_new)
      run.stall = stalled and (run.stall + 1) or 0
      if run.stall >= stall_limit then
        local why = last_error and (" Last error: " .. require("straps.state").utf8_cut((last_error:gsub("%s+", " ")), 200))
          or " (repeated tool calls with no new progress)"
        harness_note(bufnr,
          ("stopped after %d consecutive turns with no apparent progress"
            .. " (config.stall_limit=%d).%s — send a message to steer, or raise"
            .. " config.stall_limit"):format(run.stall, stall_limit, why))
        log(bufnr, { ev = "stall", turn = turn, consecutive = run.stall })
        return "stalled"
      end
    end

    if resp.stop_reason ~= "tool_use" then
      -- Blank final turn: the model ended (no tool_use) but produced no
      -- visible text — the "runs a command then returns silence" symptom. A
      -- normal end_turn carries an answer; an empty one is an anomaly, not a
      -- clean success, so it must not read as one. Two causes, handled apart:
      --   * max_tokens with nothing visible: the response budget (often the
      --     thinking budget under load) was consumed before any answer — a
      --     loud, distinct ending, never a silent "ok".
      --   * blank end_turn: the model just trailed off. Nudge it once (a
      --     synthetic user turn) to report or continue; only escalate to the
      --     loud ending if it stays blank past config.blank_nudge_limit.
      -- A turn that ran tools THIS turn is not silent — it did visible work,
      -- even if the model reported end_turn without prose. Only a turn with no
      -- tool calls AND no visible text is the "returns silence" symptom.
      local has_text = false
      for _, block in ipairs(resp.content or {}) do
        local t = (block.type == "text" and block.text)
          or ((block.type == "thinking" or block.type == "redacted_thinking") and block.thinking)
        if type(t) == "string" and t:match("%S") then
          has_text = true
          break
        end
      end
      if n_calls == 0 and not has_text then
        if resp.stop_reason == "max_tokens" then
          harness_note(bufnr,
            "the model hit max_tokens without producing a visible answer"
              .. " — the response budget (likely the thinking budget) was consumed"
              .. " before any text. Set config.max_tokens (a higher explicit cap)"
              .. " or lower the effort, then send a message to continue.")
          log(bufnr, { ev = "blank_end", cause = "max_tokens", turn = turn })
          return "blank"
        end
        -- Blank end_turn: nudge, bounded by config.blank_nudge_limit.
        if run.blank_nudges < blank_nudge_limit then
          run.blank_nudges = run.blank_nudges + 1
          state.append(bufnr, "user", nil,
            "[straps] Your last turn produced no text after the tool call."
              .. " Report the result of what you just ran, or continue the task.")
          log(bufnr, { ev = "blank_nudge", turn = turn, attempt = run.blank_nudges })
          -- fall through to the continue below (do NOT return)
        else
          harness_note(bufnr,
            ("the model returned no text after %d nudge(s) — it keeps"
              .. " ending its turn silently. Send a message to steer, or raise"
              .. " config.blank_nudge_limit."):format(run.blank_nudges))
          log(bufnr, { ev = "blank_end", cause = "end_turn", turn = turn })
          return "blank"
        end
      elseif not drain_steering(bufnr) then
        -- A steering message typed while the model streamed its final answer
        -- still gets acted on: drain, and if anything arrived, keep looping.
        return "ok"
      end
    end
    if run.cancelled then
      return cancelled_note()
    end
  end

  -- Exhaustion must be loud: a silent end reads as "the agent died".
  harness_note(bufnr,
    ("stopped after %d turns (config.max_turns) — send a message to continue"):format(max_turns))
  return "max_turns"
end

--- Start a run for bufnr (default: current buffer). One active run per buffer.
--- opts.source names who started it ("user" by default, "harness" for a
--- watch wake); a user start re-arms watch wakes.
function M.start(bufnr, opts)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if transaction_faults[bufnr] then
    vim.notify("straps: context transaction requires reconciliation", vim.log.levels.ERROR)
    return
  end
  if context_reservations[bufnr] then
    vim.notify("straps: a context operation is active for this buffer", vim.log.levels.WARN)
    return
  end
  local source = type(opts) == "table" and opts.source or "user"
  if replay_reservations[bufnr] then
    vim.notify("straps: a replay operation is active for this buffer", vim.log.levels.WARN)
    return
  end
  if runs[bufnr] then
    vim.notify("straps: a run is already active for this buffer", vim.log.levels.WARN)
    return
  end
  local queued = vim.b[bufnr].straps_steering
  local unsendable = not (type(queued) == "table" and #queued > 0) and nothing_to_send(bufnr)
  if unsendable then
    vim.notify("straps: nothing to send — " .. unsendable, vim.log.levels.WARN)
    return
  end
  -- Every session owns its scope (so no peer can create one under itself),
  -- and the guard chain is frozen before anything registry-resolved runs.
  registry.ensure_scope(bufnr)
  registry.freeze_guards()
  local state = require("straps.state")

  pcall(function() vim.b[bufnr].straps_run_reason = nil end)
  if source == "user" then M.note_user_activity(bufnr) end

  local run = { cancelled = false, cancel_fns = {}, await_seq = 0, done = false, turns = 0 }
  runs[bufnr] = run
  local ctx = new_ctx(bufnr, run)
  run.ctx = ctx
  owned_contexts[ctx] = run
  if contextual then
    local previous = registry.set_active_scope(bufnr)
    local ok, family = pcall(contextual.begin, ctx)
    registry.set_active_scope(previous)
    if not ok then crashed(bufnr, run, family); return end
    run.family = family
  end
  require("straps.attention").start(bufnr, run)
  pcall(function() vim.b[bufnr].straps_status = "running" end)
  pcall(vim.api.nvim_exec_autocmds, "User", { pattern = "StrapsRunStart", data = { bufnr = bufnr } })
  pcall(vim.api.nvim_exec_autocmds, "User",
    { pattern = "StrapsStatusChanged", data = { bufnr = bufnr, status = "running" } })
  -- all windows: a subagent run changes the parent's agent count
  pcall(function() require("straps.ui").redraw_status(true) end)

  local co = coroutine.create(function()
    local ok, ret = pcall(run_turns, bufnr, ctx, run)
    flush_emissions(bufnr, run)
    run.done = true
    finish_family(run)
    owned_contexts[ctx] = nil
    if transaction_faults[bufnr] then
      if run.diag_teardown then pcall(run.diag_teardown) end
      runs[bufnr] = nil
      log(bufnr, { ev = "context_transaction_failure", err = tostring(ret) })
      vim.notify("straps: " .. tostring(ret), vim.log.levels.ERROR)
      return
    end
    if not ok then
      pcall(pair_turn, bufnr, run)
      pcall(state.append, bufnr, "assistant", nil, "straps: run error: " .. tostring(ret))
    end
    -- done fires on every exit; run_turns names its own ending
    -- ("ok" | "cancelled" | "max_turns" | "stalled" | "blank"), crash = "error".
    local reason = ok and (ret or "ok") or "error"
    log(bufnr, { ev = "run_end", reason = reason, turns = run.turns })
    progress(bufnr, ctx, { type = "done", reason = reason }, "")
    -- Subscribers receive the ending reason, like the log and progress events
    -- above. The pcall covers RESOLUTION (hook_entries / the seq sort), which
    -- sits outside call_hooks' per-subscriber pcall: a raise there would skip
    -- the cleanup below, leaving the session stamped "running" with no
    -- trailing user block to type in.
    local ok_hooks, results, errors = pcall(registry.call_hooks, "hook.on_run_end", ctx, reason)
    if not ok_hooks then
      log(bufnr, { ev = "run_end_hook_error", err = tostring(results) })
    elseif type(errors) == "table" then
      for _, e in ipairs(errors) do
        log(bufnr, { ev = "run_end_hook_error", hook = e.name, err = e.err })
      end
    end
    pcall(state.ensure_trailing_user, bufnr)
    runs[bufnr] = nil
    finish_events(bufnr, reason, run)
    -- all windows: subagent finishing updates the parent's count
    pcall(function() require("straps.ui").redraw_status(true) end)
  end)
  run.co = co -- M.stop's backstop force-resumes this if a tool never resolves

  -- Initial resume under this buffer's registry scope (see ctx.await for
  -- the matching per-resume scoping).
  local prev_scope = registry.set_active_scope(bufnr)
  local ok, err = coroutine.resume(co)
  registry.set_active_scope(prev_scope)
  if not ok then
    crashed(bufnr, run, err)
    error(err)
  end
end

--- Request cancel: flip the flag and invoke registered cancel handlers.
--- The run notices between turns / tool calls and ends with a note.
function M.stop(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if transaction_faults[bufnr] then return end
  local run = runs[bufnr]
  local pending = operations[bufnr]
  if contextual then contextual.stop(bufnr) end
  if pending then
    local snapshot = {}
    for active in pairs(pending) do snapshot[#snapshot + 1] = active end
    for _, active in ipairs(snapshot) do cancel_operation(active) end
  end
  if not run then
    if pending then return true end
    vim.notify("straps: no active run for this buffer", vim.log.levels.WARN)
    return
  end
  local first_stop = not run.cancelled
  run.cancelled = true
  local fns = run.cancel_fns
  run.cancel_fns = {}
  for _, fn in ipairs(fns) do
    pcall(fn)
  end

  -- Cascade to running subagents. spawn's ctx.on_cancel handler covers only
  -- the window until the parent's next await completes (cancel_fns are
  -- cleared then), so a child launched two turns ago would otherwise outlive
  -- a stopped parent. straps_parent forms a tree; recursion reaches every
  -- descendant, and a repeat stop of an already-cancelled run does not
  -- descend again (which also bounds a straps_parent cycle).
  if first_stop then
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if b ~= bufnr and runs[b] and not runs[b].cancelled then
        local parent
        pcall(function() parent = vim.b[b].straps_parent end)
        if parent == bufnr then M.stop(b) end
      end
    end
  end

  -- Backstop for a tool that never resolves its await: a missing/failing
  -- ctx.on_cancel handler (or one that kills a process leader whose surviving
  -- grandchildren keep vim.system's stdout pipe open, so on_exit never fires)
  -- leaves the run coroutine suspended in ctx.await forever — run.cancelled is
  -- flipped but nothing resumes the coroutine to observe it. After
  -- stop_backstop_ms we force a resume with NO values. The awaiting tool then
  -- receives nil, errors on it, gate_tool's run pcall catches that as a tool
  -- error, and the loop's run.cancelled checks end the run with the
  -- cancellation note — the clean path. A forced resume that lands in a
  -- provider (or hook.confirm) await instead escapes as an error into
  -- run_turns' pcall (M.start), which appends "straps: run error: ..." and
  -- cleans up — less pretty, still ended. The parallel-readonly tool path needs
  -- no backstop: its poll loop already resolves on run.cancelled within ~20ms.
  -- stop_backstop_ms is the delay before the forced resume fires (default 4000).
  local ok, straps = pcall(require, "straps")
  local cfg = (ok and type(straps) == "table" and rawget(straps, "config")) or {}
  local delay = cfg.stop_backstop_ms or 4000
  local seq = run.await_seq
  vim.defer_fn(function()
    if runs[bufnr] ~= run or run.done or run.await_seq ~= seq
      or not run.co or coroutine.status(run.co) ~= "suspended" then
      return
    end
    -- Invalidate the pending await's real resolve: its scheduled callback
    -- checks run.await_seq ~= seq and drops itself (see ctx.await, ~line 115),
    -- so a late resolution after this cannot double-resume the coroutine.
    run.await_seq = run.await_seq + 1
    -- Force-resume under this buffer's registry scope, mirroring ctx.await's
    -- driver (~lines 121-127).
    local prev_scope = registry.set_active_scope(bufnr)
    local resumed, err = coroutine.resume(run.co)
    registry.set_active_scope(prev_scope)
    if not resumed then
      crashed(bufnr, run, err)
    end
  end, delay)
end

-- Exit cleanup: a Unix child whose parent dies is reparented, not killed, so
-- a command still running at :qa would outlive Neovim (and its in-process
-- timeout timer dies with us — the orphan would run unbounded). Fire every
-- active run's registered cancel fns synchronously on VimLeavePre; for the
-- shell tools each fn group-SIGKILLs its detached process tree. No backstop,
-- no note: the event loop is ending, only the kills matter.
vim.api.nvim_create_autocmd("VimLeavePre", {
  group = vim.api.nvim_create_augroup("straps_loop_exit", { clear = true }),
  callback = function()
    require("straps.attention").shutdown()
    local buffers = {}
    for bufnr in pairs(runs) do buffers[bufnr] = true end
    for bufnr in pairs(operations) do buffers[bufnr] = true end
    for bufnr in pairs(buffers) do if contextual then contextual.stop(bufnr) end end
    for _, pending in pairs(operations) do
      for run in pairs(pending) do
        run.cancelled = true
        finish_family(run)
        for _, fn in ipairs(run.cancel_fns) do pcall(fn) end
        run.cancel_fns = {}
      end
    end
    for _, run in pairs(runs) do
      run.cancelled = true
      finish_family(run)
      for _, fn in ipairs(run.cancel_fns) do
        pcall(fn)
      end
      run.cancel_fns = {}
    end
  end,
})

--- Queue a mid-run user message ("steering"). Returns true if queued, false
--- if no run is active (callers fall back to M.start) — so the return value
--- is also the atomic "is a run active" test, with no window between the check
--- and the enqueue. The queue lives in vim.b straps_steering as { text, source }
--- entries; vim.b tables are snapshots, so copy-modify-write. opts is
--- { quiet, source }: source is "user" (default), "harness" or "agent", and
--- quiet suppresses only the user-facing toast. A legacy boolean opts is
--- quiet, and a quiet legacy caller is the harness.
function M.steer(bufnr, text, opts)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if transaction_faults[bufnr] then return false end
  local quiet, source
  if type(opts) == "table" then
    quiet, source = opts.quiet, opts.source or "user"
  else
    quiet, source = opts, opts and "harness" or "user"
  end
  local run = runs[bufnr]
  if not run then
    return false
  end
  local queue = vim.b[bufnr].straps_steering
  if type(queue) ~= "table" then
    queue = {}
  end
  queue[#queue + 1] = { text = text, source = source }
  vim.b[bufnr].straps_steering = queue
  if source == "user" then M.note_user_activity(bufnr) end
  progress(bufnr, run.ctx, { type = "steer_queued" })
  if not quiet then
    vim.notify("straps: steering queued", vim.log.levels.INFO)
  end
  return true
end

function M.running(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  return runs[bufnr] ~= nil
end

--- Bufnrs of every session with an active run, newest-started first.
--- The authoritative "who is working right now" list — the agents picker
--- and statusline component read it. Stale/invalid buffers are skipped.
function M.running_sessions()
  local out = {}
  for bufnr in pairs(runs) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      out[#out + 1] = bufnr
    end
  end
  table.sort(out)
  return out
end

vim.api.nvim_create_autocmd("BufWipeout", {
  group = vim.api.nvim_create_augroup("straps_loop_close", { clear = true }),
  callback = function(event)
    if runs[event.buf] or operations[event.buf] then M.stop(event.buf) end
    if contextual then contextual.close(event.buf) end
  end,
})

return M
