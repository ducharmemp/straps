-- tests/tool_guard_spec.lua — the hook.guard.* chain and the tool pipeline.
--   busted tests/tool_guard_spec.lua
-- Covers: before/after/define/remove ops, fail-closed on raise, seq-order
-- fold with every guard running, async guards on both loop paths, the
-- gate-all-then-run-all parallel path and its cancel, the freeze, subagent
-- scope shadows, info.executing, reentrancy vs composition, guard log events,
-- and the zero-guard identity.

local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(vim.fn.fnamemodify(here, ":p"), ":h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local tmp = assert(vim.uv.fs_realpath((function()
  local t = vim.fn.tempname(); vim.fn.mkdir(t, "p"); return t
end)()))
vim.env.XDG_DATA_HOME = tmp .. "/xdg"
assert(vim.fn.stdpath("data"):find(tmp, 1, true) == 1, "stdpath('data') did not follow XDG_DATA_HOME")


local straps = require("straps").setup({})
straps.config.session_dir = vim.fn.tempname()
straps.config.max_tool_result_bytes = 100000
local registry = require("straps.registry")
local state = require("straps.state")
local loop = require("straps.loop")
require("straps.provider").register()

local function define(name, kind, doc, source, opts)
  return registry.define({ name = name, kind = kind, doc = doc, source = source }, opts)
end

-- ------------------------------------------------------------- guard setup
-- Every guard is installed BEFORE the first loop.start (the freeze) and
-- steered through _G.G so cases can turn behaviors on and off.
_G.G = { calls = {} }
local function reset()
  _G.G = { calls = {} }
end

define("hook.guard.a", "hook", "test guard a", [==[
return function(op, ...)
  local G = _G.G
  local name, input, x3, x4, x5, x6 = ...
  G.calls[#G.calls + 1] = { guard = "a", op = op, name = type(name) == "table" and name.name or name }
  if op == "before" then
    local ctx, info = x3, x4
    G.last_info = info
    if G.a_record_exec then G.exec_seen = G.exec_seen or {}; table.insert(G.exec_seen, { v = info.executing }) end
    if G.a_async and ctx then
      ctx.await(function(resolve) vim.defer_fn(function()
        G.a_resolved_at = vim.uv.hrtime()
        G.gate_resolves = G.gate_resolves or {}
        table.insert(G.gate_resolves, G.a_resolved_at)
        resolve()
      end, G.a_async_ms or 30) end)
    end
    if G.a_hold and ctx then
      ctx.await(function(resolve) G.release = G.release or {}; table.insert(G.release, resolve) end)
    end
    if G.a_async_stop and ctx then
      ctx.await(function(resolve)
        vim.defer_fn(function() require("straps.loop").stop(ctx.bufnr); resolve() end, 10)
      end)
    end
    if G.a_raise then error("guard a exploded") end
    if G.a_block and (G.a_block == true or G.a_block == name or (type(input) == "table" and input.path == G.a_block)) then
      return false, G.a_reason
    end
    if G.a_reenter then require("straps.registry").define{ name = "fn.reenter", kind = "fn", source = "return function() end" } end
    return G.a_verdict
  elseif op == "after" then
    local result, ok, ctx, info = x3, x4, x5, x6
    G.after_seen = result
    G.after_ok = ok
    if G.a_after_async and ctx then
      ctx.await(function(resolve) vim.defer_fn(resolve, 20) end)
    end
    if G.a_after_block then return false, "after says no" end
    if G.a_after_replace then return G.a_after_replace end
  elseif op == "define" then
    local spec, opts, info = name, input, x3
    if G.define_block and spec.name:match(G.define_block) then return false, "no evil defines" end
    if G.record_define_exec then G.define_exec = info.executing end
  elseif op == "remove" then
    local rname = name
    if G.remove_block and rname == G.remove_block then return false, "keep it" end
  end
end
]==])
define("hook.guard.b", "hook", "test guard b", [==[
return function(op, name, ...)
  local G = _G.G
  G.calls[#G.calls + 1] = { guard = "b", op = op, name = type(name) == "table" and name.name or name }
  if op == "before" and G.b_block then return false, "b says no" end
end
]==])

define("tool.ping", "tool", "ping", [[return function() _G.G.ping_ran = (_G.G.ping_ran or 0) + 1; return "pong" end]])
define("tool.big", "tool", "oversized result", [[return function() return string.rep("x", 500) end]])
define("tool.evil", "tool", "test: defines from inside", [[
return function(input, ctx)
  local reg = require("straps.registry")
  if input.define then
    local ok, err = pcall(reg.define, { name = input.define, kind = "fn", source = "return function() end" })
    _G.G.evil_define = { ok = ok, err = tostring(err) }
  end
  if input.schedule_define then
    vim.schedule(function()
      pcall(reg.define, { name = input.schedule_define, kind = "fn", source = "return function() end" })
      _G.G.scheduled_done = true
    end)
  end
  return "evil"
end
]])
-- Shadow read_file (a PARALLEL_READONLY name) with a recording stub so the
-- parallel path is exercised without touching the filesystem.
define("tool.read_file", "tool", "test stub", [[
return function(input, ctx)
  local G = _G.G
  G.rf_starts = G.rf_starts or {}
  table.insert(G.rf_starts, { path = input.path, at = vim.uv.hrtime() })
  if input.slow then ctx.await(function(resolve) vim.defer_fn(resolve, 40) end) end
  return "contents of " .. tostring(input.path)
end
]])

-- Recording confirm stub.
_G.confirm_calls = 0
define("hook.confirm", "hook", "test: record + allow", [[
return function() _G.confirm_calls = _G.confirm_calls + 1; return true end
]])

-- Log capture.
_G.log_events = {}
define("fn.log", "fn", "test: capture", [[return function(ev) table.insert(_G.log_events, ev) end]])

-- ---------------------------------------------------------------- helpers
local function scripted(blocks)
  _G.script_blocks = blocks
  _G.script_calls = 0
  define("fn.provider", "fn", "test: one tool turn then text", [==[
return function(req, ctx)
  _G.script_calls = _G.script_calls + 1
  local n = _G.script_calls
  ctx.await(function(resolve) vim.defer_fn(resolve, 5) end)
  if n == 1 then
    local content = {}
    for i, b in ipairs(_G.script_blocks) do
      content[i] = { type = "tool_use", id = "t" .. i, name = b.name, input = b.input or vim.empty_dict() }
    end
    return { stop_reason = "tool_use", content = content }
  end
  ctx.emit({ type = "text_delta", text = "done" })
  return { stop_reason = "end_turn", content = { { type = "text", text = "done" } } }
end
]==])
end

local function run(blocks, buf)
  scripted(blocks)
  buf = buf or state.new_session()
  state.append_text(buf, "go")
  _G.confirm_calls = 0
  _G.log_events = {}
  loop.start(buf)
  assert(vim.wait(5000, function() return not loop.running(buf) end, 10), "run did not finish within 5s")
  return buf, table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

local function results(buf)
  local out = {}
  for _, m in ipairs(state.parse(buf).messages) do
    for _, part in ipairs(m.content) do
      if part.type == "tool_result" then out[#out + 1] = part end
    end
  end
  return out
end

local function guard_events(op)
  local out = {}
  for _, ev in ipairs(_G.log_events) do
    if ev.ev == "guard" and (op == nil or ev.op == op) then out[#out + 1] = ev end
  end
  return out
end

-- ------------------------------------------------------------------ cases

it("pre-freeze: guards define, remove and re-define; scoped define is refused", function()
  assert(not registry.guards_frozen(), "must not be frozen before the first run")
  define("hook.guard.tmp", "hook", "t", "return function() end")
  assert(registry.get("hook.guard.tmp"), "guard should be visible through get()")
  assert(registry.get("hook.guard.tmp").fn == nil, "guard view must not expose fn")
  assert(registry.remove("hook.guard.tmp") == true, "remove should report removal")
  assert(registry.get("hook.guard.tmp") == nil, "removed")
  local buf = vim.api.nvim_create_buf(true, false)
  local ok, err = pcall(define, "hook.guard.scoped", "hook", "t", "return function() end", { scope = buf })
  assert(not ok and tostring(err):find("global%-only"), "scoped guard must be refused: " .. tostring(err))
  -- names/names_by_seq/dump/render all see the chain and do not raise.
  assert(vim.tbl_contains(registry.names("hook"), "hook.guard.a"), "names(hook) should include guards")
  assert(vim.tbl_contains(registry.names_by_seq("hook"), "hook.guard.b"), "names_by_seq should include guards")
  assert(registry.render("hook.guard.a"):find("hook.guard.a", 1, true), "render works for guards")
  assert(registry.dump():find('name = "hook.guard.a"', 1, true), "dump includes guards")
  assert(#registry.guard_entries() == 2 and registry.guard_entries()[1].name == "hook.guard.a", "guard_entries in seq order")
end)

it("hook.on_define never sees a guard define", function()
  _G.on_define_names = {}
  define("hook.on_define", "hook", "t", [[return function(e) table.insert(_G.on_define_names, e.name) end]])
  define("hook.guard.silent", "hook", "t", "return function() end")
  define("fn.loud", "fn", "t", "return function() end")
  assert(not vim.tbl_contains(_G.on_define_names, "hook.guard.silent"), "on_define saw a guard")
  assert(vim.tbl_contains(_G.on_define_names, "fn.loud"), "on_define should still see ordinary defines")
  registry.remove("hook.guard.silent")
  registry.remove("hook.on_define")
end)

it("before/block: tool not run, confirm not called, distinct block text", function()
  reset(); _G.G.a_block = true; _G.G.a_reason = "nope"
  local buf = run({ { name = "ping" } })
  local r = results(buf)
  assert(#r == 1 and r[1].is_error, "expected one error result")
  assert(r[1].content == "blocked by hook.guard.a: nope", "block text: " .. tostring(r[1].content))
  assert(not _G.G.ping_ran, "tool must not run")
  assert(_G.confirm_calls == 0, "confirm must not be called after a block")
end)

it("before/pass (true) and abstain (nil): confirm runs once, tool runs", function()
  for _, verdict in ipairs({ true, "nil" }) do
    reset(); _G.G.a_verdict = verdict == true and true or nil
    local buf = run({ { name = "ping" } })
    local r = results(buf)
    assert(#r == 1 and not r[1].is_error and r[1].content == "pong", "expected pong: " .. vim.inspect(r))
    assert(_G.confirm_calls == 1, "confirm should run exactly once (verdict " .. tostring(verdict) .. ")")
    assert(_G.G.ping_ran == 1, "tool should run once")
  end
end)

it("mixed: a passes, b blocks → blocked; both guards ran, in seq order", function()
  reset(); _G.G.b_block = true
  local buf = run({ { name = "ping" } })
  local r = results(buf)
  assert(r[1].is_error and r[1].content:find("blocked by hook.guard.b: b says no", 1, true), tostring(r[1].content))
  local before = {}
  for _, c in ipairs(_G.G.calls) do if c.op == "before" then before[#before + 1] = c.guard end end
  assert(vim.deep_equal(before, { "a", "b" }), "both guards must run in seq order: " .. vim.inspect(before))
  -- No short-circuit: when the FIRST guard blocks, the second still runs and
  -- the first block wins the reason.
  reset(); _G.G.a_block = true; _G.G.a_reason = "a first"; _G.G.b_block = true
  buf = run({ { name = "ping" } })
  r = results(buf)
  assert(r[1].content == "blocked by hook.guard.a: a first", "first block's reason wins: " .. tostring(r[1].content))
  before = {}
  for _, c in ipairs(_G.G.calls) do if c.op == "before" then before[#before + 1] = c.guard end end
  assert(vim.deep_equal(before, { "a", "b" }), "b must still run after a's block: " .. vim.inspect(before))
end)

it("a raising guard fails closed", function()
  reset(); _G.G.a_raise = true
  local buf = run({ { name = "ping" } })
  local r = results(buf)
  assert(r[1].is_error and r[1].content:find("guard hook.guard.a raised: ", 1, true)
    and r[1].content:find("guard a exploded", 1, true), tostring(r[1].content))
  assert(not _G.G.ping_ran, "tool must not run")
end)

it("an async before-guard (ctx.await) still blocks", function()
  reset(); _G.G.a_async = true; _G.G.a_block = true; _G.G.a_reason = "late no"
  local buf = run({ { name = "ping" } })
  local r = results(buf)
  assert(r[1].is_error and r[1].content:find("late no", 1, true), tostring(r[1].content))
  assert(_G.G.a_resolved_at, "guard await must have resolved")
end)

it("after: replace, block, order after hook.after_tool, truncated input", function()
  reset(); _G.G.a_after_replace = "REPLACED"
  define("hook.after_tool.x", "hook", "t", [[return function(name, input, result) return result .. "+x" end]])
  local buf = run({ { name = "ping" } })
  local r = results(buf)
  assert(r[1].content == "REPLACED" and not r[1].is_error, "replace: " .. vim.inspect(r[1]))
  assert(_G.G.after_seen == "pong+x", "after-guard must see after_tool's output: " .. tostring(_G.G.after_seen))
  reset(); _G.G.a_after_block = true
  buf = run({ { name = "ping" } })
  r = results(buf)
  assert(r[1].is_error and r[1].content == "blocked by hook.guard.a: after says no", vim.inspect(r[1]))
  -- Truncation happens before the after-guards.
  reset()
  local prev = straps.config.max_tool_result_bytes
  straps.config.max_tool_result_bytes = 50
  local ok_case, err_case = pcall(function()
    run({ { name = "big" } })
    assert(_G.G.after_seen:find("result truncated at 50 bytes", 1, true), "after-guard must see the truncated result")
  end)
  straps.config.max_tool_result_bytes = prev
  assert(ok_case, err_case)
  -- An after-block on an already-failed result keeps the original.
  reset(); _G.G.a_after_block = true
  define("tool.boom", "tool", "t", [[return function() error("kaboom") end]])
  buf = run({ { name = "boom" } })
  r = results(buf)
  assert(r[1].is_error and r[1].content:find("tool had already failed: ", 1, true) and r[1].content:find("kaboom", 1, true),
    vim.inspect(r[1]))
  registry.remove("hook.after_tool.x", { scope = "global" })
end)

it("parallel path: gate-all-then-run-all, async before-guard blocks one, async after-guard replaces", function()
  reset(); _G.G.a_async = true; _G.G.a_block = "/blocked"; _G.G.a_reason = "path no"; _G.G.a_after_async = true
  _G.G.a_after_replace = "PAR"
  local buf = run({ { name = "read_file", input = { path = "/blocked" } }, { name = "read_file", input = { path = "/ok" } } })
  local r = results(buf)
  assert(#r == 2, "two results")
  assert(r[1].is_error and r[1].content:find("path no", 1, true), "first blocked: " .. vim.inspect(r[1]))
  assert(r[2].content == "PAR" and not r[2].is_error, "second replaced by the async after-guard: " .. vim.inspect(r[2]))
  assert(#_G.G.rf_starts == 1 and _G.G.rf_starts[1].path == "/ok", "only the allowed block ran: " .. vim.inspect(_G.G.rf_starts))
  -- Ordering witness: with BOTH blocks allowed and both gates awaiting, no job
  -- may start before the LAST gate resolved.
  reset(); _G.G.a_async = true
  run({ { name = "read_file", input = { path = "/p" } }, { name = "read_file", input = { path = "/q" } } })
  assert(#_G.G.gate_resolves == 2 and #_G.G.rf_starts == 2, "two gates, two jobs: " .. vim.inspect(_G.G))
  local last_gate = math.max(unpack(_G.G.gate_resolves))
  for _, s in ipairs(_G.G.rf_starts) do
    assert(s.at > last_gate, "a job started before the last gate resolved: " .. vim.inspect(_G.G))
  end
end)

it("parallel path: cancel during an awaiting gate stubs every block; no job runs", function()
  reset(); _G.G.a_async_stop = true
  local prev = straps.config.stop_backstop_ms
  straps.config.stop_backstop_ms = 300
  local ok_case, err_case = pcall(function()
    -- The stop defer (10ms) fires well before the second block's gate would
    -- complete, so the cancel lands mid-gate regardless of timer ordering.
    local buf = run({ { name = "read_file", input = { path = "/a", slow = true } }, { name = "read_file", input = { path = "/b" } } })
    local r = results(buf)
    assert(#r == 2, "both tool_use blocks must get a result")
    for _, x in ipairs(r) do
      assert(x.is_error and x.content:find("cancelled", 1, true), "expected a cancel stub: " .. vim.inspect(x))
    end
    -- Let any late resolve land; the stub must still never have run.
    vim.wait(150, function() return false end)
    assert(_G.G.rf_starts == nil, "no job may run after cancel: " .. vim.inspect(_G.G.rf_starts))
  end)
  straps.config.stop_backstop_ms = prev
  assert(ok_case, err_case)
end)

it("parallel path: a job's late resolve after loop.stop does not resume it", function()
  -- The stub's ctx.await is in flight in a job coroutine when the run is
  -- stopped from outside. Its resolve is held in _G.G.release and fired by the
  -- test AFTER the run has ended; the job must stay dead.
  reset()
  define("tool.read_file", "tool", "test stub, resolve held by the test", [[
return function(input, ctx)
  local G = _G.G
  G.rf_starts = G.rf_starts or {}
  table.insert(G.rf_starts, { path = input.path, at = vim.uv.hrtime() })
  G.job_started = true
  ctx.await(function(resolve) G.release = G.release or {}; table.insert(G.release, resolve) end)
  G.job_resumed = (G.job_resumed or 0) + 1
  return "contents of " .. tostring(input.path)
end
]])
  local prev = straps.config.stop_backstop_ms
  straps.config.stop_backstop_ms = 300
  local ok_case, err_case = pcall(function()
    scripted({ { name = "read_file", input = { path = "/a" } }, { name = "read_file", input = { path = "/b" } } })
    local buf = state.new_session()
    state.append_text(buf, "go")
    loop.start(buf)
    assert(vim.wait(2000, function() return _G.G.job_started end, 5), "job never started")
    loop.stop(buf)
    assert(vim.wait(3000, function() return not loop.running(buf) end, 10), "run did not end")
    local r = results(buf)
    assert(#r == 2, "both blocks stubbed")
    for _, x in ipairs(r) do assert(x.is_error and x.content:find("cancelled", 1, true), vim.inspect(x)) end
    assert(_G.G.release and #_G.G.release == 2, "both jobs should be parked in their await")
    for _, release in ipairs(_G.G.release) do release() end
    vim.wait(100, function() return false end)
    assert(_G.G.job_resumed == nil, "a job must not resume after the run ended: " .. tostring(_G.G.job_resumed))
  end)
  straps.config.stop_backstop_ms = prev
  define("tool.read_file", "tool", "test stub", [[
return function(input, ctx)
  local G = _G.G
  G.rf_starts = G.rf_starts or {}
  table.insert(G.rf_starts, { path = input.path, at = vim.uv.hrtime() })
  if input.slow then ctx.await(function(resolve) vim.defer_fn(resolve, 40) end) end
  return "contents of " .. tostring(input.path)
end
]])
  assert(ok_case, err_case)
end)

it("subagent-style scope shadow: guards still block; a pass still runs the child's confirm", function()
  reset(); _G.G.a_block = true; _G.G.a_reason = "child no"
  local child = state.new_session()
  registry.ensure_scope(child)
  _G.child_confirm = 0
  define("hook.confirm", "hook", "child shadow", [[return function() _G.child_confirm = _G.child_confirm + 1; return true end]],
    { scope = child })
  local buf = run({ { name = "ping" } }, child)
  assert(results(buf)[1].content:find("child no", 1, true), "guard must block inside the child")
  assert(_G.child_confirm == 0, "confirm must not run after a block")
  reset(); _G.G.a_verdict = true
  run({ { name = "ping" } }, child)
  assert(_G.child_confirm == 1, "a true verdict must still run the child's confirm shadow")
end)

it("define op: blocked from registry.define, tool.registry_define, and a trusted project file", function()
  reset(); _G.G.define_block = "^fn%.evil"
  local ok, err = pcall(define, "fn.evil1", "fn", "t", "return function() end")
  assert(not ok and tostring(err) == "blocked by hook.guard.a: no evil defines", tostring(err))
  assert(registry.get("fn.evil1") == nil, "entry must be absent")
  -- Through the agent's tool (inside a run).
  define("tool.rd_wrap", "tool", "t", [[
return function(input, ctx)
  local ok, err = pcall(require("straps.registry").call, "tool.registry_define",
    { name = "fn.evil2", kind = "fn", source = "return function() end" }, ctx)
  _G.G.rd = { ok = ok, err = tostring(err) }
  return "x"
end
]])
  run({ { name = "rd_wrap" } })
  assert(_G.G.rd and not _G.G.rd.ok and _G.G.rd.err:find("no evil defines", 1, true), vim.inspect(_G.G.rd))
  assert(registry.get("fn.evil2") == nil, "entry must be absent")
  -- Through a project file: the guarded define raises inside the chunk, so
  -- the loader reports an error and the entry is absent.
  local proj = tmp .. "/proj"
  vim.fn.mkdir(proj, "p")
  local f = assert(io.open(proj .. "/.straps.lua", "w"))
  f:write('require("straps.registry").define{ name = "fn.evil3", kind = "fn", source = "return function() end" }\n')
  f:close()
  local cwd = vim.fn.getcwd()
  vim.cmd("cd " .. vim.fn.fnameescape(proj))
  local notes = {}
  local orig_notify = vim.notify
  vim.notify = function(m) notes[#notes + 1] = tostring(m) end
  local loaded, info = straps.load_project_registry({ trust_all = true })
  vim.notify = orig_notify
  vim.cmd("cd " .. vim.fn.fnameescape(cwd))
  assert(loaded == false and info:find("no evil defines", 1, true), "project load must fail on the guarded define: " .. tostring(info))
  assert(registry.get("fn.evil3") == nil, "entry must be absent")
end)

it("remove op: a guard keeps hook.confirm in place", function()
  reset(); _G.G.remove_block = "hook.confirm"
  local ok, err = pcall(registry.remove, "hook.confirm", { scope = "global" })
  assert(not ok and tostring(err):find("keep it", 1, true), tostring(err))
  assert(registry.get("hook.confirm"), "hook.confirm must survive")
end)

it("info.executing names the tool whose body is running; nil from a scheduled callback", function()
  reset(); _G.G.record_define_exec = true
  run({ { name = "evil", input = { define = "fn.from_evil" } } })
  assert(_G.G.evil_define and _G.G.evil_define.ok, "define from a tool body should succeed: " .. vim.inspect(_G.G.evil_define))
  assert(_G.G.define_exec == "evil", "info.executing should be 'evil', got " .. tostring(_G.G.define_exec))
  reset(); _G.G.record_define_exec = true
  run({ { name = "evil", input = { schedule_define = "fn.from_sched" } } })
  assert(vim.wait(1000, function() return _G.G.scheduled_done end, 10), "scheduled define never ran")
  assert(registry.get("fn.from_sched"), "the scheduled define must have landed (else the guard was never consulted)")
  assert(_G.G.define_exec == nil, "a scheduled callback has no executing tool, got " .. tostring(_G.G.define_exec))
end)

it("info.executing is per-coroutine: overlapping parallel jobs see their own name", function()
  reset(); _G.G.a_record_exec = true
  -- Two slow read_file jobs overlap; a third gate happens while none is executing
  -- on the run coroutine, so every before-guard sees executing == nil.
  run({ { name = "read_file", input = { path = "/1", slow = true } }, { name = "read_file", input = { path = "/2", slow = true } } })
  assert(#_G.G.exec_seen == 2, "both gates must have run the guard: " .. vim.inspect(_G.G.exec_seen))
  for _, x in ipairs(_G.G.exec_seen) do assert(x.v == nil, "gate on the run coroutine must not inherit a job's executing") end
  -- Inside a job, a nested direct call sees the job's own tool name.
  define("tool.nest", "tool", "t", [[
return function(input, ctx)
  local reg = require("straps.registry")
  reg.define{ name = "fn.nested_probe", kind = "fn", source = "return function() end" }
  return "n"
end
]])
  reset(); _G.G.record_define_exec = true
  run({ { name = "nest" } })
  assert(_G.G.define_exec == "nest", "nested define inside tool.nest should see executing == nest, got " .. tostring(_G.G.define_exec))
end)

it("reentrancy: a guard calling define blocks the outer op; composition is not reentrancy", function()
  reset(); _G.G.a_reenter = true
  local buf = run({ { name = "ping" } })
  local r = results(buf)
  assert(r[1].is_error and r[1].content:find("reentrancy", 1, true), "outer op must block: " .. vim.inspect(r[1]))
  assert(registry.get("fn.reenter") == nil, "the nested define must not land")
  assert(registry.active_scope() == nil, "a raising gate must restore the active scope, got " .. tostring(registry.active_scope()))
  -- Direct path: the raise propagates and the scope is still restored.
  local ok, err = pcall(registry.call, "tool.ping", {}, { bufnr = buf })
  assert(not ok and tostring(err):find("reentrancy", 1, true), tostring(err))
  assert(registry.active_scope() == nil, "direct-path raise must restore the active scope")
  -- A raising confirm callback propagates out of gate_tool; the scope must
  -- still be restored on that path.
  reset()
  local ok2, err2 = pcall(registry.gate_tool, "ping", {}, { bufnr = buf }, { confirm = function() error("confirm broke", 0) end })
  assert(not ok2 and err2 == "confirm broke", "confirm raise must propagate: " .. tostring(err2))
  assert(registry.active_scope() == nil, "a raising confirm must restore the active scope, got " .. tostring(registry.active_scope()))
  -- The reentrancy flag is per coroutine: a guard suspended in ctx.await on
  -- one session must not make every other session's gate raise meanwhile.
  -- The suspended guard's resolve is held in G.release until the check ran.
  reset(); _G.G.a_hold = true
  scripted({ { name = "ping" } })
  local slow = state.new_session()
  state.append_text(slow, "go")
  loop.start(slow)
  assert(vim.wait(1000, function() return _G.G.release ~= nil end, 5), "guard never parked")
  _G.G.a_hold = false
  assert(registry.call("tool.ping", {}, nil) == "pong", "a gate on another coroutine must pass while a guard is suspended elsewhere")
  _G.G.release[1]()
  assert(vim.wait(3000, function() return not loop.running(slow) end, 10), "slow run did not finish")
  -- Composition: an after_tool hook calling a tool runs that tool's own guards.
  reset()
  define("hook.after_tool.compose", "hook", "t", [[
return function(name, input, result, ok, ctx)
  if name == "ping" then
    return result .. "|" .. require("straps.registry").call("tool.read_file", { path = "/inner" }, ctx)
  end
end
]])
  buf = run({ { name = "ping" } })
  r = results(buf)
  assert(r[1].content == "pong|contents of /inner", "composition result: " .. vim.inspect(r[1]))
  local befores = guard_events("before")
  local names = {}
  for _, ev in ipairs(befores) do names[ev.name] = (names[ev.name] or 0) + 1 end
  assert(names.ping == 2 and names.read_file == 2, "each guard must run once per tool call: " .. vim.inspect(names))
  registry.remove("hook.after_tool.compose", { scope = "global" })
end)

it("guard log events: one per guard per op, with verdicts", function()
  reset(); _G.G.b_block = true
  run({ { name = "ping" } })
  local ev = guard_events("before")
  assert(#ev == 2, "two before events: " .. vim.inspect(ev))
  assert(ev[1].guard == "hook.guard.a" and ev[1].verdict == "pass", vim.inspect(ev[1]))
  assert(ev[2].guard == "hook.guard.b" and ev[2].verdict == "block", vim.inspect(ev[2]))
  assert(type(ev[1].ms) == "number", "ms stamped")
end)

it("frozen after the first run: define/remove refused; loaders and registry_define surface the message", function()
  assert(registry.guards_frozen(), "runs have happened; must be frozen")
  local ok, err = pcall(define, "hook.guard.late", "hook", "t", "return function() end")
  assert(not ok and tostring(err):find("guards are frozen", 1, true), tostring(err))
  ok, err = pcall(registry.remove, "hook.guard.a")
  assert(not ok and tostring(err):find("guards are frozen", 1, true), tostring(err))
  assert(registry.get("hook.guard.a"), "guard a must survive")
  local gpath = tmp .. "/late_corpus.lua"
  local f = assert(io.open(gpath, "w"))
  f:write('require("straps.registry").define{ name = "hook.guard.late2", kind = "hook", source = "return function() end" }\n')
  f:close()
  local orig_notify = vim.notify
  vim.notify = function() end
  local loaded, info = straps.load_global_registry({ path = gpath })
  vim.notify = orig_notify
  assert(loaded == false and info:find("guards are frozen", 1, true), "loader must report the freeze: " .. tostring(info))
  assert(registry.get("hook.guard.late2") == nil)
  reset()
  local res = registry.call("tool.registry_get", { name = "hook.guard.a" })
  assert(res:find("hook.guard.a", 1, true) and res:find("test guard a", 1, true), "registry_get renders guards normally")
  ok, err = pcall(registry.call, "tool.registry_define",
    { name = "hook.guard.late3", kind = "hook", source = "return function() end" }, { bufnr = 0 })
  assert(not ok and tostring(err):find("guards are frozen", 1, true), "registry_define must surface the freeze: " .. tostring(err))
end)

it("inert guards: a pass-through chain changes nothing (confirm once, tool runs, four pass verdicts)", function()
  -- Cannot remove frozen guards; make them inert instead and check the fold
  -- itself is invisible in the transcript.
  reset()
  local buf, text = run({ { name = "ping" } })
  local r = results(buf)
  assert(r[1].content == "pong" and not r[1].is_error, vim.inspect(r[1]))
  assert(_G.confirm_calls == 1, "confirm once")
  for _, x in ipairs(r) do assert(not x.content:find("blocked by", 1, true), "no block in any result") end
  assert(#guard_events() == 4, "two guards x before+after, all passes: " .. vim.inspect(guard_events()))
  for _, ev in ipairs(guard_events()) do assert(ev.verdict == "pass", vim.inspect(ev)) end
end)

it("gate edges: run() twice raises; unknown tool is an error result; try_call on a blocked tool raises; guards unreachable via call/bind/call_hooks", function()
  reset()
  local allowed, _, run_once = registry.gate_tool("ping", {}, nil)
  assert(allowed and run_once, "gate should pass")
  assert(select(2, run_once(nil)) == "pong", "first run works")
  local ok, err = pcall(run_once, nil)
  assert(not ok and tostring(err):find("already used", 1, true), "second run must raise: " .. tostring(err))
  local buf = run({ { name = "no_such_tool_xyz" } })
  local r = results(buf)
  assert(#r == 1 and r[1].is_error and r[1].content:find("no entry named", 1, true), vim.inspect(r))
  reset(); _G.G.a_block = true; _G.G.a_reason = "tc"
  ok, err = pcall(registry.try_call, "tool.ping", {}, nil)
  assert(not ok and tostring(err) == "blocked by hook.guard.a: tc", "try_call on a blocked tool must raise, not return nil: " .. tostring(err))
  reset()
  ok, err = pcall(registry.call, "hook.guard.a", "before", "ping", {}, nil, {})
  assert(not ok and tostring(err):find("only inside the gate", 1, true), "call must not invoke a guard: " .. tostring(err))
  ok, err = pcall(registry.bind, "hook.guard.a")
  assert(not ok, "bind must not hand out a guard fn")
  assert(#registry.hook_entries("hook.guard") == 0, "hook_entries must not list guards")
  local res = registry.call_hooks("hook.guard", "before", "ping", {}, nil, {})
  assert(#res == 0 and #_G.G.calls == 0, "call_hooks must not fan out to guards: " .. vim.inspect(_G.G.calls))
end)
