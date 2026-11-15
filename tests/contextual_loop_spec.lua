local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(here, ":p:h:h")
vim.opt.runtimepath:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local registry, state, loop, controller, operation, replay, events, contexts, calls
local function define(name, kind, source)
  registry.define({ name = name, kind = kind, source = source })
end
local function session()
  local buf = state.new_session()
  state.append_text(buf, "local task")
  return buf
end
local function wait_for(fn) assert(vim.wait(3000, fn, 5), "condition timed out") end
local function text(buf) return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n") end
local function provider(blocks)
  calls = 0
  _G.contextual_loop_provider = function(_, ctx)
    calls = calls + 1
    if calls == 1 then return { stop_reason = "tool_use", content = blocks } end
    ctx.emit({ type = "text_delta", text = "done" })
    return { stop_reason = "end_turn", content = { { type = "text", text = "done" } } }
  end
  define("fn.provider", "fn", "return function(...) return _G.contextual_loop_provider(...) end")
end
local function block(name, id) return { type = "tool_use", name = name, id = id, input = {} } end
before_each(function()
  for _, name in ipairs({ "loop", "registry", "state", "contextual", "authorization", "consent" }) do
    package.loaded["straps." .. name] = nil
  end
  registry, state = require("straps.registry"), require("straps.state")
  local source = table.concat(vim.fn.readfile(root .. "/lua/straps/loop.lua"), "\n")
  local changes = {
    bind = { "if run.family then contextual.bind(run.family, cctx) end", "" },
    finish = { "contextual.finish(family)", "" },
    stop = { "if contextual then contextual.stop(bufnr) end", "" },
    owned = { "local owner = owned_contexts[current_ctx]", "local owner = { done = false, cancelled = false }" },
    confirm = { "fresh_gate(confirm_then_before_tool, ctx)", "fresh_gate(function() return true end, ctx)" },
    reserve = { "if reserve_replay then replay_reservations[bufnr] = run end", "" },
    actor_start = { "if replay_reservations[bufnr] then", "if false then" },
    stale_emit = { "if run.done or run.cancelled then return end", "" },
    flush = { "local ok, ret = pcall(run_turns, bufnr, ctx, run)\n    flush_emissions(bufnr, run)", "local ok, ret = pcall(run_turns, bufnr, ctx, run)" },
    replay_check = { "if run.cancelled or owner.cancelled or runs[ctx.bufnr]", "if false" },
  }
  local mutation = vim.env.STRAPS_LOOP_MUTANT
  if mutation and mutation ~= "" then
    local change = assert(changes[mutation])
    local first, last = assert(source:find(change[1], 1, true))
    source = source:sub(1, first - 1) .. change[2] .. source:sub(last + 1)
  end
  loop = assert(loadstring(source, "@" .. root .. "/lua/straps/loop.lua"))()
  package.loaded["straps.loop"] = loop
  require("straps").config.session_dir = vim.fn.tempname()
  events, contexts = {}, {}
  controller = registry.setup_authorization({
    assess = function() return { decision = "allow" } end,
    execution_stamp = function() return { revision = 1 } end,
    validate_stamp = function() return true end,
  })
  loop.install_contextual({
    begin = function(ctx)
      contexts[#contexts + 1] = ctx
      local family = controller.begin_family(ctx)
      events[#events + 1] = { "begin", ctx.bufnr, family }
      return family
    end,
    bind = controller.bind_context,
    finish = function(family) events[#events + 1] = { "finish", family }; controller.cancel_family(family) end,
    stop = function(buf)
      events[#events + 1] = { "stop", buf }
      for _, event in ipairs(events) do if event[1] == "begin" and event[2] == buf then controller.cancel_family(event[3]) end end
    end,
    close = function(buf) events[#events + 1] = { "close", buf } end,
  })
  loop.install_human_operations(function(a, b) operation, replay = a, b end)
  define("hook.confirm", "hook", "return function() return true end")
  define("fn.build_tools", "fn", "return function() return {} end")
  define("tool.sample", "tool", "return function() return 'sample result' end")
end)

it("seals setup and keeps runtime operations private", function()
  assert.is_nil(loop.operation)
  assert.is_nil(loop.replay)
  assert.has_error(function() loop.install_human_operations(function() end) end)
  assert.has_error(function() loop.install_contextual({}) end)
end)

it("begins before public hooks and invalidates the actor family at completion", function()
  local buf = session()
  controller.install_ceiling(buf, {})
  provider({ block("sample", "serial") })
  _G.contextual_loop_hook = function(ctx)
    local allowed = registry.gate_tool("sample", {}, ctx)
    assert(allowed, "public start hook had no family")
  end
  define("hook.on_run_start", "hook", "return function(ctx) _G.contextual_loop_hook(ctx) end")
  loop.start(buf, { source = "user" })
  wait_for(function() return not loop.running(buf) end)
  assert.equals(2, calls)
  assert.matches("sample result", text(buf), 1, true)
  assert.is_false(registry.gate_tool("sample", {}, contexts[1]))
  assert.equals("finish", events[#events][1])
end)

it("binds actual parallel contexts and preserves inherited nested registry calls", function()
  local buf = session()
  controller.install_ceiling(buf, {})
  _G.contextual_loop_children = {}
  for _, name in ipairs({ "read_file", "glob" }) do
    define("tool." .. name, "tool", [[return function(_, ctx)
      _G.contextual_loop_children[#_G.contextual_loop_children + 1] = ctx
      local registry = require('straps.registry')
      local allowed, reason, run = registry.gate_tool('sample', {}, ctx)
      if not allowed then return 'nested denied: ' .. tostring(reason) end
      local ok, result = run(ctx)
      assert(ok, result)
      return result
    end]])
  end
  provider({ block("read_file", "parallel-a"), block("glob", "parallel-b") })
  loop.start(buf)
  wait_for(function() return not loop.running(buf) end)
  assert.equals(2, #_G.contextual_loop_children)
  assert.are_not.equal(_G.contextual_loop_children[1], contexts[1])
  assert.are_not.equal(_G.contextual_loop_children[1], _G.contextual_loop_children[2])
  assert.is_nil(text(buf):find("nested denied", 1, true))
  assert.is_false(registry.gate_tool("sample", {}, _G.contextual_loop_children[1]))
end)

it("runs human operations while an actor tool awaits and isolates their errors", function()
  local buf = session()
  controller.install_ceiling(buf, {})
  local release, actor_ctx, operation_ctx
  _G.contextual_loop_wait = function(ctx)
    actor_ctx = ctx
    return ctx.await(function(resolve) release = resolve end)
  end
  define("tool.wait", "tool", "return function(_, ctx) return _G.contextual_loop_wait(ctx) end")
  provider({ block("wait", "awaiting") })
  loop.start(buf)
  assert.is_true(loop.running(buf))
  assert.is_true(operation(buf, function(ctx)
    operation_ctx = ctx
    assert.is_true(registry.any_tool_executing())
    error("operation failure")
  end))
  assert.are_not.equal(actor_ctx, operation_ctx)
  assert.is_true(loop.running(buf))
  assert.is_true(registry.gate_tool("sample", {}, actor_ctx))
  release("released")
  wait_for(function() return not loop.running(buf) end)
  assert.matches("released", text(buf), 1, true)
end)

it("invalidates operations-only sessions before cancellation handlers and drops late resolves", function()
  local buf = session()
  controller.install_ceiling(buf, {})
  local resolve, ctx, cancelled, after, cancellation_gate = nil, nil, false, false, nil
  operation(buf, function(current)
    ctx = current
    current.on_cancel(function()
      cancelled = true
      cancellation_gate = registry.gate_tool("sample", {}, current)
    end)
    current.await(function(done) resolve = done end)
    after = true
  end)
  assert.is_false(loop.running(buf))
  loop.stop(buf)
  assert.is_true(cancelled)
  assert.is_false(cancellation_gate)
  resolve("late")
  wait_for(function() return after end)
  assert.is_true(ctx.cancelled())
  assert.is_false(registry.gate_tool("sample", {}, ctx))
end)

it("replays only owned contexts through fresh ordinary confirmation and paired new IDs", function()
  local buf = session()
  controller.install_ceiling(buf, {})
  local desc = { terminal = true, execution_started = false,
    binding = { session = buf, definition = { name = "tool.sample" }, input = {} } }
  local confirmed, posts, executed = 0, 0, 0
  _G.contextual_loop_confirm = function() confirmed = confirmed + 1 return false, "ordinary denied" end
  define("hook.confirm", "hook", "return function() return _G.contextual_loop_confirm() end")
  assert.is_false(replay(desc, { bufnr = buf }, function() error("forged replay") end))
  local stale
  operation(buf, function(ctx)
    stale = ctx
    local ok = replay(desc, ctx, function(confirm, replayctx)
      assert.are_not.equal(ctx, replayctx)
      return registry.gate_tool("sample", {}, replayctx, { confirm = confirm })
    end)
    assert.is_true(ok)
  end)
  local drained = false
  vim.schedule(function() drained = true end)
  wait_for(function() return drained end)
  assert.equals(1, confirmed)
  assert.matches("ordinary denied", text(buf), 1, true)
  assert.is_false(replay(desc, stale, function() end))
  _G.contextual_loop_confirm = function() confirmed = confirmed + 1 return true end
  _G.contextual_loop_post = function() posts = posts + 1 end
  _G.contextual_loop_execute = function() executed = executed + 1 return "new result" end
  define("hook.after_tool", "hook", "return function() _G.contextual_loop_post() end")
  define("tool.sample", "tool", "return function() return _G.contextual_loop_execute() end")
  operation(buf, function(ctx)
    assert.is_true(replay(desc, ctx, function(confirm, replayctx)
      return registry.gate_tool("sample", {}, replayctx, { confirm = confirm })
    end))
  end)
  wait_for(function() return posts == 1 end)
  assert.equals(1, executed)
  assert.equals(1, posts)
  assert.equals(2, confirmed)
  local ids, results = {}, {}
  for _, message in ipairs(state.parse(buf).messages) do
    for _, part in ipairs(message.content) do
      if part.type == "tool_use" then ids[#ids + 1] = part.id end
      if part.type == "tool_result" then results[#results + 1] = part.tool_use_id end
    end
  end
  assert.equals(2, #ids)
  assert.are_not.equal(ids[1], ids[2])
  assert.same(ids, results)
end)

it("rejects replay while a provider streams without appending replay markers", function()
  local buf = session()
  controller.install_ceiling(buf, {})
  local release, provider_ctx
  _G.contextual_loop_provider = function(_, ctx)
    provider_ctx = ctx
    ctx.await(function(resolve) release = resolve end)
    ctx.emit({ type = "text_delta", text = "actor answer" })
    return { stop_reason = "end_turn", content = { { type = "text", text = "actor answer" } } }
  end
  define("fn.provider", "fn", "return function(...) return _G.contextual_loop_provider(...) end")
  loop.start(buf)
  local accepted, why, gated = nil, nil, 0
  local desc = { terminal = true, execution_started = false,
    binding = { session = buf, definition = { name = "tool.sample" }, input = {} } }
  local before = text(buf)
  operation(buf, function(ctx)
    accepted, why = replay(desc, ctx, function() gated = gated + 1 end)
  end)
  assert.is_false(accepted)
  assert.equals("replay requires an idle actor", why)
  assert.equals(0, gated)
  assert.equals(before, text(buf))
  assert.is_false(replay(desc, provider_ctx, function() gated = gated + 1 end))
  release()
  wait_for(function() return not loop.running(buf) end)
  assert.matches("actor answer", text(buf), 1, true)
  assert.is_nil(text(buf):find("straps-replay-", 1, true))
end)

it("reserves replay before family callbacks and excludes actor starts and concurrent replay", function()
  local buf = session()
  controller.install_ceiling(buf, {})
  local desc = { terminal = true, execution_started = false,
    binding = { session = buf, definition = { name = "tool.sample" }, input = {} } }
  local provider_calls, gated, release, rejected = 0, 0
  _G.contextual_loop_provider = function() provider_calls = provider_calls + 1; return { stop_reason = "end_turn", content = {} } end
  define("fn.provider", "fn", "return function(...) return _G.contextual_loop_provider(...) end")
  local original_begin = controller.begin_family
  controller.begin_family = function(ctx)
    if gated == -1 then gated = -2; loop.start(buf) end
    return original_begin(ctx)
  end
  operation(buf, function(ctx)
    gated = -1
    assert.is_true(replay(desc, ctx, function(_, replayctx)
      gated = 1
      replayctx.await(function(resolve) release = resolve end)
      return false, "reserved denial"
    end))
    rejected = replay(desc, ctx, function() error("concurrent replay gated") end)
    loop.start(buf)
  end)
  assert.is_false(rejected)
  assert.equals(0, provider_calls)
  wait_for(function() return gated == 1 end)
  loop.start(buf)
  assert.equals(0, provider_calls)
  release()
  wait_for(function() return text(buf):find("reserved denial", 1, true) end)
  assert.equals(0, provider_calls)
end)

it("flushes the final actor delta before idle replay and suppresses late actor emissions", function()
  local buf = session()
  controller.install_ceiling(buf, {})
  local actor_ctx
  _G.contextual_loop_provider = function(_, ctx)
    actor_ctx = ctx
    ctx.emit({ type = "text_delta", text = "final actor answer" })
    return { stop_reason = "end_turn", content = { { type = "text", text = "final actor answer" } } }
  end
  define("fn.provider", "fn", "return function(...) return _G.contextual_loop_provider(...) end")
  loop.start(buf)
  assert.is_false(loop.running(buf))
  local answer
  for _, message in ipairs(state.parse(buf).messages) do
    if message.role == "assistant" then
      for _, part in ipairs(message.content) do if part.type == "text" then answer = part.text end end
    end
  end
  assert.equals("final actor answer", answer)
  local desc = { terminal = true, execution_started = false,
    binding = { session = buf, definition = { name = "tool.sample" }, input = {} } }
  local gated = false
  operation(buf, function(ctx)
    assert.is_true(replay(desc, ctx, function()
      gated = true
      return false, "replay result"
    end))
  end)
  actor_ctx.emit({ type = "text_delta", text = "stale actor bytes" })
  wait_for(function() return gated end)
  assert.is_nil(text(buf):find("stale actor bytes", 1, true))
  local final = text(buf)
  assert.is_true(final:find("final actor answer", 1, true) < final:find("straps-replay-", 1, true))
end)

it("cancels reserved replay before its scheduled gate and permits a later actor start", function()
  local buf = session()
  controller.install_ceiling(buf, {})
  local gated = 0
  local desc = { terminal = true, execution_started = false,
    binding = { session = buf, definition = { name = "tool.sample" }, input = {} } }
  operation(buf, function(ctx)
    assert.is_true(replay(desc, ctx, function() gated = gated + 1 end))
  end)
  loop.stop(buf)
  local drained = false
  vim.schedule(function() drained = true end)
  wait_for(function() return drained end)
  assert.equals(0, gated)
  assert.is_nil(text(buf):find("straps-replay-", 1, true))
  provider({})
  loop.start(buf)
  wait_for(function() return not loop.running(buf) end)
  assert.equals(2, calls)
end)

it("invalidates the actor before operation cancellation handlers run", function()
  local buf = session()
  controller.install_ceiling(buf, {})
  local actor, observed
  _G.contextual_loop_wait = function(ctx)
    actor = ctx
    return ctx.await(function(resolve) ctx.on_cancel(function() resolve("cancelled") end) end)
  end
  define("tool.wait", "tool", "return function(_, ctx) return _G.contextual_loop_wait(ctx) end")
  provider({ block("wait", "actor-stop") })
  loop.start(buf)
  operation(buf, function(ctx)
    ctx.on_cancel(function() observed = registry.gate_tool("sample", {}, actor) end)
    ctx.await(function() end)
  end)
  loop.stop(buf)
  assert.is_false(observed)
  wait_for(function() return not loop.running(buf) end)
end)

local function real_coordinator()
  for _, name in ipairs({ "registry", "loop", "contextual", "authorization", "consent" }) do package.loaded["straps." .. name] = nil end
  registry, loop = require("straps.registry"), require("straps.loop")
  local contextual = require("straps.contextual")
  local lifecycle_mutant = vim.env.STRAPS_LIFECYCLE_MUTANT
  if lifecycle_mutant == "stop_guard" or lifecycle_mutant == "close_guard" then
    local source = table.concat(vim.fn.readfile(root .. "/lua/straps/contextual.lua"), "\n")
    local name = lifecycle_mutant == "stop_guard" and "stop" or "close"
    local start = assert(source:find("  function loop." .. name .. "(bufnr)", 1, true))
    local first, last = assert(source:find('    if not snapshot or snapshot.status == "closed" then return end', start, true))
    contextual = assert(loadstring(source:sub(1, first - 1) .. source:sub(last + 1)))()
  elseif lifecycle_mutant == "close_first" then
    local source = table.concat(vim.fn.readfile(root .. "/lua/straps/loop.lua"), "\n")
    local old = "    if runs[event.buf] or operations[event.buf] then M.stop(event.buf) end\n    if contextual then contextual.close(event.buf) end"
    local first, last = assert(source:find(old, 1, true))
    loop = assert(loadstring(source:sub(1, first - 1)
      .. "    if contextual then contextual.close(event.buf) end\n    if runs[event.buf] or operations[event.buf] then M.stop(event.buf) end"
      .. source:sub(last + 1)))()
    package.loaded["straps.loop"] = loop
  end
  local human, schedule, replay_call, accept
  loop.install_human_operations(function(a, b) schedule, replay_call = a, b end)
  local fields = { "outcome", "mode", "targets", "effects", "constraints", "reserved_decisions", "latitude", "unresolved_scope" }
  contextual.setup({ enabled = true, limits = { max_bytes = 1048576, max_depth = 40, max_items = 10000 }, run_human = schedule, replay = replay_call,
    disclosure = { approved = true }, receipts = {
      identity = function() return "fixture" end,
      validate = function() return true end,
      prepare_adoption = function() return { transcript = "local task" }, {} end,
      adopt = function(_, validate_current) return validate_current() end,
    },
    discover = function() return { id = "standing", config_hash = "fixture", sources = {} } end,
    adopt = function(_, answer) accept = answer end,
    resolve_targets = function() return { known = {}, unresolved = {}, checks = {} } end,
    validate_targets = function() return true end,
    assessor_factory = function()
      return {
        synthesize = function(snapshot)
          local spec = { schema_version = 1, task_id = snapshot.task_id, instruction_revision = snapshot.epoch }
          for _, field in ipairs(fields) do spec[field] = { value = {}, sources = { snapshot.adopted[1] } } end
          spec.outcome.value, spec.mode.value = "local task", "implementation"
          return spec, { unsupported_authority = false, untrusted_authority = false, omitted_constraint = false,
            expanded_scope = false, lost_authorization = false, hidden_ambiguity = false }
        end,
        assess = function() return { decision = "allow", reasons = {}, effects = {}, source_ids = {} } end,
      }
    end,
    install = { loop = loop.install_contextual, human = function(adapter) human = adapter end },
  })
  define("hook.confirm", "hook", "return function() return true end")
  define("fn.build_tools", "fn", "return function() return {} end")
  for _, name in ipairs({ "sample", "read_file", "glob" }) do
    define("tool." .. name, "tool", "return function() return 'linked result' end")
  end
  local errors = {}
  for _, autocmd in ipairs(vim.api.nvim_get_autocmds({ group = "straps_loop_close", event = "BufWipeout" })) do
    vim.api.nvim_del_autocmd(autocmd.id)
    vim.api.nvim_create_autocmd("BufWipeout", { group = autocmd.group, callback = function(event)
      local ok, err = pcall(autocmd.callback, event)
      if not ok then errors[#errors + 1] = tostring(err) end
    end })
  end
  return human, schedule, function() return accept end, errors
end

local function active_real_session()
  local human, schedule, acceptance, errors = real_coordinator()
  local buf = session()
  human.create(buf)
  local enqueued = 0
  human.submit(buf, "local task", function() enqueued = enqueued + 1 end)
  wait_for(function() return acceptance() ~= nil end)
  acceptance()(true)
  wait_for(function() return enqueued == 1 end)
  assert.equals("active", require("straps.authorization").snapshot(buf).status)
  return buf, schedule, errors
end

it("wipes unrelated buffers without contextual lifecycle errors", function()
  local _, _, _, errors = real_coordinator()
  local buf = vim.api.nvim_create_buf(false, true)
  local ok, err = pcall(vim.api.nvim_buf_delete, buf, { force = true })
  assert.is_true(ok, tostring(err))
  assert.same({}, errors)
end)

it("cancels real actor and human operations once before closing a wiped session", function()
  local buf, schedule, errors = active_real_session()
  local actor, human, release_actor, release_human
  local cancelled = { actor = 0, human = 0 }
  local allowed, status = {}, {}
  _G.contextual_loop_provider = function(_, ctx)
    actor = ctx
    ctx.await(function(resolve)
      release_actor = resolve
      ctx.on_cancel(function()
        cancelled.actor = cancelled.actor + 1
        allowed.actor = registry.gate_tool("sample", {}, ctx)
        status.actor = require("straps.authorization").snapshot(buf).status
        resolve()
      end)
    end)
    return { stop_reason = "end_turn", content = {} }
  end
  define("fn.provider", "fn", "return function(...) return _G.contextual_loop_provider(...) end")
  loop.start(buf)
  wait_for(function() return release_actor ~= nil end)
  assert.is_true(schedule(buf, function(ctx)
    human = ctx
    ctx.await(function(resolve)
      release_human = resolve
      ctx.on_cancel(function()
        cancelled.human = cancelled.human + 1
        allowed.human = registry.gate_tool("sample", {}, ctx)
        status.human = require("straps.authorization").snapshot(buf).status
        resolve()
      end)
    end)
  end))
  assert.is_not_nil(release_human)
  local ok, err = pcall(vim.api.nvim_buf_delete, buf, { force = true })
  local again, repeat_err = pcall(loop.stop, buf)
  release_actor()
  release_human()
  wait_for(function() return not loop.running(buf) end)
  assert.same({ actor = 1, human = 1 }, cancelled)
  assert.is_true(ok, tostring(err))
  assert.is_true(again, tostring(repeat_err))
  assert.same({}, errors)
  assert.same({ actor = false, human = false }, allowed)
  assert.same({ actor = "active", human = "active" }, status)
  assert.is_true(actor.cancelled())
  assert.is_true(human.cancelled())
  assert.equals("closed", require("straps.authorization").snapshot(buf).status)
end)

it("links the actual contextual coordinator to serial and parallel actor execution", function()
  local human, _, acceptance = real_coordinator()
  local buf = session()
  human.create(buf)
  local enqueued = 0
  human.submit(buf, "local task", function() enqueued = enqueued + 1 end)
  assert.equals(0, enqueued)
  wait_for(function() return acceptance() ~= nil end)
  acceptance()(true)
  wait_for(function() return enqueued == 1 end)
  assert.equals(1, enqueued)
  assert.equals("active", require("straps.contextual").status(buf).status)
  provider({ block("sample", "linked-serial") })
  loop.start(buf)
  wait_for(function() return not loop.running(buf) end)
  assert.matches("linked result", text(buf), 1, true)
  state.append_text(buf, "continue")
  provider({ block("read_file", "linked-a"), block("glob", "linked-b") })
  loop.start(buf)
  wait_for(function() return not loop.running(buf) end)
  assert.equals(2, calls)
  assert.is_nil(text(buf):find("trusted execution family", 1, true))
end)

it("closes contextual state on buffer destruction", function()
  local buf = session()
  vim.api.nvim_buf_delete(buf, { force = true })
  assert.same({ "close", buf }, events[#events])
end)
