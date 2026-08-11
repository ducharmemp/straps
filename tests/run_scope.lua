-- tests/run_scope.lua — registry scoping + subagents (tool.spawn).
--   nvim --headless -l tests/run_scope.lua
-- No network: fn.provider is scripted per case. Covers: session-scoped
-- defines shadowing global without mutating it; seq stability under
-- shadowing (cache order); parent-chain resolution; define_default staying
-- global; BufWipeout dropping a scope; registry_define defaulting to session
-- scope (and scope="global" opting out); build_tools honoring the child tool
-- filter and hiding spawn at the depth limit; per-buffer max_turns; a full
-- spawn round trip through the loop; the readonly child confirm; and the
-- spawn depth guard.

local script = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(vim.fn.fnamemodify(script, ":p"), ":h:h")
vim.opt.runtimepath:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local straps = require("straps").setup({})
straps.config.session_dir = vim.fn.tempname()

local registry = require("straps.registry")
local state = require("straps.state")
local loop = require("straps.loop")

-- Capture the pristine default hook.confirm source before any case shadows it
-- with allow_all(), so the cap:-grant case can restore real default behavior.
local DEFAULT_CONFIRM = registry.get("hook.confirm").source

local failed = false
local function case(name, fn)
  local ok, err = pcall(fn)
  if ok then
    print("PASS  " .. name)
  else
    failed = true
    print("FAIL  " .. name .. ": " .. tostring(err))
  end
end

local function define(name, kind, doc, source)
  registry.define({ name = name, kind = kind, doc = doc, source = source }, { scope = "global" })
end

local function buf_text(bufnr)
  return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
end

local function wait_done(bufnr, ms)
  assert(vim.wait(ms or 15000, function() return not loop.running(bufnr) end, 10),
    "run did not finish in time")
end

local function allow_all()
  define("hook.confirm", "hook", "test: allow everything", "return function() return true end")
end

local unpack = unpack or table.unpack
local function pack(...) return { n = select("#", ...), ... } end
local function drive(thunk, timeout_ms)
  local out, finished, co
  local ctx
  ctx = {
    bufnr = 0,
    await = function(start)
      local resolved = false
      start(function(...)
        if resolved then return end
        resolved = true
        local a = pack(...)
        vim.schedule(function()
          if coroutine.status(co) == "suspended" then
            local ok, e = coroutine.resume(co, unpack(a, 1, a.n))
            if not ok then finished = true; error(e) end
          end
        end)
      end)
      return coroutine.yield()
    end,
  }
  co = coroutine.create(function()
    out = thunk(ctx)
    finished = true
  end)
  local ok, err = coroutine.resume(co)
  if not ok then error(err) end
  vim.wait(timeout_ms or 20000, function() return finished end, 20)
  assert(finished, "drive: thunk did not finish within timeout")
  return out
end

-- ------------------------------------------------------------ scoped defines

case("session define shadows for the scope chain; global stays untouched", function()
  define("tool.shadow_me", "tool", "global v1", [[return function() return "global" end]])
  local buf = vim.api.nvim_create_buf(true, false)

  local prev = registry.set_active_scope(buf)
  local ok, err = pcall(function()
    registry.define({ name = "tool.shadow_me", kind = "tool", doc = "scoped v2",
      source = [[return function() return "scoped" end]] })
    assert(registry.call("tool.shadow_me") == "scoped", "scoped call should hit the shadow")
    local e = registry.get("tool.shadow_me")
    assert(e.scope == buf, "entry should record its owning scope")
    assert(e.version == 2, "shadow should build on the shadowed version, got " .. e.version)
  end)
  registry.set_active_scope(prev)
  assert(ok, err)

  assert(registry.call("tool.shadow_me") == "global", "global entry was polluted")
  assert(registry.get("tool.shadow_me").scope == nil, "global entry gained a scope")
end)

case("shadowing reuses the shadowed seq; new scoped entries append", function()
  define("tool.order_a", "tool", "a", [[return function() return "a" end]])
  define("tool.order_b", "tool", "b", [[return function() return "b" end]])
  local buf = vim.api.nvim_create_buf(true, false)

  local function positions()
    local names = registry.names_by_seq("tool")
    local pos = {}
    for i, n in ipairs(names) do pos[n] = i end
    return pos, names
  end
  local before = positions()

  local prev = registry.set_active_scope(buf)
  local ok, err = pcall(function()
    registry.define({ name = "tool.order_a", kind = "tool", doc = "a shadowed",
      source = [[return function() return "a2" end]] })
    registry.define({ name = "tool.order_new", kind = "tool", doc = "new",
      source = [[return function() return "new" end]] })
    local after, names = positions()
    assert(after["tool.order_a"] == before["tool.order_a"],
      "shadowing moved tool.order_a in seq order")
    assert(after["tool.order_b"] == before["tool.order_b"],
      "shadowing moved an unrelated tool")
    assert(names[#names] == "tool.order_new", "new scoped entry should append last")
  end)
  registry.set_active_scope(prev)
  assert(ok, err)

  local pos = positions()
  assert(pos["tool.order_new"] == nil, "scoped entry visible without its scope")
end)

case("child scope resolves through its parent's scope", function()
  local parent = vim.api.nvim_create_buf(true, false)
  local child = vim.api.nvim_create_buf(true, false)
  registry.ensure_scope(parent)
  registry.ensure_scope(child, parent)

  local prev = registry.set_active_scope(parent)
  registry.define({ name = "tool.parent_tool", kind = "tool", doc = "parent's",
    source = [[return function() return "from-parent" end]] })
  registry.set_active_scope(child)
  local ok, err = pcall(function()
    assert(registry.call("tool.parent_tool") == "from-parent",
      "child should see the parent's session tools")
    registry.define({ name = "tool.child_tool", kind = "tool", doc = "child's",
      source = [[return function() return "from-child" end]] })
  end)
  registry.set_active_scope(parent)
  local parent_sees_child = registry.get("tool.child_tool")
  registry.set_active_scope(prev)
  assert(ok, err)
  assert(parent_sees_child == nil, "child definitions must not leak up to the parent")
  assert(registry.get("tool.parent_tool") == nil, "parent's session tool leaked to global")
end)

case("define_default stays global even while a scope is active", function()
  local buf = vim.api.nvim_create_buf(true, false)
  local prev = registry.set_active_scope(buf)
  local ok, err = pcall(function()
    registry.define_default({ name = "tool.default_probe", kind = "tool", doc = "d",
      source = [[return function() return "d" end]] })
  end)
  registry.set_active_scope(prev)
  assert(ok, err)
  local e = registry.get("tool.default_probe")
  assert(e and e.scope == nil, "define_default should land in the global scope")
end)

case("BufWipeout drops the buffer's scope", function()
  local buf = vim.api.nvim_create_buf(true, false)
  local prev = registry.set_active_scope(buf)
  registry.define({ name = "tool.doomed", kind = "tool", doc = "d",
    source = [[return function() return "d" end]] })
  registry.set_active_scope(prev)
  assert(registry.scopes[buf], "scope should exist after a scoped define")
  vim.cmd("bwipeout! " .. buf)
  assert(registry.scopes[buf] == nil, "scope should be dropped on BufWipeout")
end)

-- -------------------------------------------------- registry_define the tool

case("tool.registry_define defaults to session scope; scope='global' opts out", function()
  local buf = vim.api.nvim_create_buf(true, false)
  local prev = registry.set_active_scope(buf)
  local ok, err = pcall(function()
    local out = registry.call("tool.registry_define", {
      name = "tool.rd_session", kind = "tool",
      source = [[return function() return "s" end]],
    }, { bufnr = buf })
    assert(out:find("session scope", 1, true), "result should say session scope: " .. out)
    out = registry.call("tool.registry_define", {
      name = "tool.rd_global", kind = "tool", scope = "global",
      source = [[return function() return "g" end]],
    }, { bufnr = buf })
    assert(out:find("global scope", 1, true), "result should say global scope: " .. out)
  end)
  registry.set_active_scope(prev)
  assert(ok, err)
  assert(registry.get("tool.rd_session") == nil, "session-scoped tool visible globally")
  assert(registry.get("tool.rd_global") ~= nil, "scope='global' tool missing globally")
end)

case("tool.registry_define warns on blocking waits in tool sources", function()
  local buf = vim.api.nvim_create_buf(true, false)
  local prev = registry.set_active_scope(buf)
  local ok, err = pcall(function()
    -- vim.system():wait() blocks the main loop; the define succeeds but warns.
    local out = registry.call("tool.registry_define", {
      name = "tool.rd_blocking", kind = "tool",
      source = [[return function() return vim.system({ "true" }):wait().code end]],
    }, { bufnr = buf })
    assert(out:find("defined tool.rd_blocking", 1, true), "define should succeed: " .. out)
    assert(out:find("warning:", 1, true) and out:find("ctx.await", 1, true),
      "blocking tool source should carry a warning: " .. out)
    -- A ctx.await-based source gets no warning.
    out = registry.call("tool.registry_define", {
      name = "tool.rd_nonblocking", kind = "tool",
      source = [[return function(_, ctx) return ctx.await(function(r) r("ok") end) end]],
    }, { bufnr = buf })
    assert(not out:find("warning:", 1, true), "non-blocking source wrongly warned: " .. out)
    -- Non-tool kinds are exempt (hooks may legitimately vim.wait outside a run).
    out = registry.call("tool.registry_define", {
      name = "hook.rd_hook", kind = "hook",
      source = [[return function() vim.wait(1) end]],
    }, { bufnr = buf })
    assert(not out:find("warning:", 1, true), "hook source wrongly warned: " .. out)
  end)
  registry.set_active_scope(prev)
  assert(ok, err)
end)

-- --------------------------------------------------------- build_tools shaping

case("build_tools honors the child tool filter and hides spawn at depth limit", function()
  local buf = vim.api.nvim_create_buf(true, false)
  registry.ensure_scope(buf)
  vim.b[buf].straps_tool_filter = { "read_file", "grep" }
  local prev = registry.set_active_scope(buf)
  local ok, err = pcall(function()
    local tools = registry.call("fn.build_tools")
    local names = {}
    for _, t in ipairs(tools) do names[#names + 1] = t.name end
    table.sort(names)
    assert(table.concat(names, ",") == "grep,read_file",
      "filter not applied: " .. table.concat(names, ","))

    vim.b[buf].straps_tool_filter = nil
    vim.b[buf].straps_spawn_depth = 1
    tools = registry.call("fn.build_tools")
    for _, t in ipairs(tools) do
      assert(t.name ~= "spawn", "spawn should be hidden at the depth limit")
    end
    assert(#tools > 10, "hiding spawn should not drop other tools")
  end)
  registry.set_active_scope(prev)
  assert(ok, err)
end)

-- ------------------------------------------------------- loop-integrated scope

case("an agent's mid-run registry_define is session-scoped end to end", function()
  allow_all()
  _G.straps_scope_calls = 0
  define("fn.provider", "fn", "test: define a tool then finish", [==[
return function(req, ctx)
  _G.straps_scope_calls = _G.straps_scope_calls + 1
  local n = _G.straps_scope_calls
  ctx.await(function(resolve) vim.defer_fn(resolve, 5) end)
  if n == 1 then
    return { stop_reason = "tool_use", content = {
      { type = "tool_use", id = "d1", name = "registry_define",
        input = { name = "tool.run_temp", kind = "tool",
          source = 'return function() return "temp-ran" end' } },
    } }
  end
  return { stop_reason = "end_turn", content = { { type = "text", text = "defined it" } } }
end
]==])

  local bufnr = state.new_session()
  state.append_text(bufnr, "make a temp tool")
  loop.start(bufnr)
  wait_done(bufnr)

  assert(buf_text(bufnr):find("session scope", 1, true),
    "registry_define result should say session scope")
  assert(registry.get("tool.run_temp") == nil, "mid-run define leaked to global")
  local prev = registry.set_active_scope(bufnr)
  local e = registry.get("tool.run_temp")
  registry.set_active_scope(prev)
  assert(e and e.scope == bufnr, "tool.run_temp missing from the session scope")
end)

-- ------------------------------------------------------------------- spawning

case("spawn round trip: child session runs and its answer returns to the parent", function()
  allow_all()
  -- The parent spawns (fire-and-return, gets a buffer handle), then in a later
  -- turn calls spawn_wait on that handle to collect the child's answer. The
  -- provider recovers the child bufnr by scanning the spawn tool_result text.
  define("fn.provider", "fn", "test: parent spawns, waits, child answers", [==[
return function(req, ctx)
  local first_user, last_result
  for _, m in ipairs(req.messages) do
    if m.role == "user" then
      for _, p in ipairs(m.content) do
        if p.type == "text" and not first_user then first_user = p.text end
        if p.type == "tool_result" then last_result = p.content end
      end
    end
  end
  local is_child = first_user and first_user:find("CHILD-TASK", 1, true)
  -- Final text must be STREAMED via ctx.emit (like the real SSE provider);
  -- the loop never copies returned text blocks into the buffer.
  ctx.await(function(resolve)
    vim.defer_fn(function()
      if is_child then
        ctx.emit({ type = "text_delta", text = "CHILD-ANSWER-XYZ" })
      elseif last_result and last_result:find("## subagent", 1, true) then
        ctx.emit({ type = "text_delta", text = "PARENT-DONE" })
      end
      resolve()
    end, 5)
  end)
  if is_child then
    return { stop_reason = "end_turn",
      content = { { type = "text", text = "CHILD-ANSWER-XYZ" } } }
  end
  if #req.messages == 1 then
    return { stop_reason = "tool_use", content = {
      { type = "tool_use", id = "s1", name = "spawn",
        input = { task = "CHILD-TASK: report the magic string." } },
    } }
  end
  -- Second turn: the spawn result named a child buffer. Wait on it.
  local child = last_result and tonumber(last_result:match("buffer (%d+)"))
  if child and not last_result:find("## subagent", 1, true) then
    return { stop_reason = "tool_use", content = {
      { type = "tool_use", id = "w1", name = "spawn_wait",
        input = { buffers = { child } } },
    } }
  end
  return { stop_reason = "end_turn", content = { { type = "text", text = "PARENT-DONE" } } }
end
]==])

  local parent = state.new_session()
  state.append_text(parent, "please use a subagent")
  loop.start(parent)
  wait_done(parent)

  local text = buf_text(parent)
  assert(text:find("subagent started", 1, true), "spawn start header missing:\n" .. text:sub(-400))
  assert(text:find("subagent (buffer", 1, true), "spawn_wait result header missing:\n" .. text:sub(-400))
  assert(text:find("CHILD-ANSWER-XYZ", 1, true), "child's answer missing from parent transcript")
  assert(text:find("PARENT-DONE", 1, true), "parent did not continue after the spawn")

  -- The child is a real session buffer, chained under the parent.
  local child
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if b ~= parent and vim.api.nvim_buf_is_loaded(b)
      and buf_text(b):find("CHILD-TASK", 1, true) then
      child = b
    end
  end
  assert(child, "child session buffer not found")
  assert(registry.scopes[child] and registry.scopes[child].parent == parent,
    "child scope should chain under the parent")
  assert(vim.b[child].straps_spawn_depth == 1, "child depth not stamped")
end)

case("spawn fires and returns; spawn_wait collects N children run concurrently", function()
  allow_all()
  -- Two children each sleep ~300ms before answering. Started via two spawn
  -- calls (fire-and-return), then a single spawn_wait over both. If they ran
  -- concurrently the wait is ~300ms, not ~600ms; we assert well under the sum.
  define("fn.provider", "fn", "test: slow children answer their tag", [==[
return function(req, ctx)
  local first_user
  for _, m in ipairs(req.messages) do
    if m.role == "user" then
      for _, p in ipairs(m.content) do
        if p.type == "text" then first_user = p.text; break end
      end
      break
    end
  end
  local tag = first_user and first_user:match("PAR%-(%u)")
  ctx.await(function(resolve) vim.defer_fn(resolve, 500) end)
  ctx.emit({ type = "text_delta", text = "ANS-" .. (tag or "?") })
  -- Let the scheduled delta flush into the assistant block before the run ends
  -- (the real SSE provider streams throughout; a single end-of-run emit would
  -- otherwise race the trailing-user marker).
  ctx.await(function(resolve) vim.defer_fn(resolve, 10) end)
  return { stop_reason = "end_turn", content = { { type = "text", text = "ANS-" .. (tag or "?") } } }
end
]==])

  local parent = vim.api.nvim_create_buf(true, false)
  local t0 = vim.uv.hrtime()
  local out = drive(function(ctx)
    ctx.bufnr = parent
    local a = registry.call("tool.spawn", { task = "PAR-A: answer" }, ctx)
    local b = registry.call("tool.spawn", { task = "PAR-B: answer" }, ctx)
    -- Both children are already running here; spawn returned immediately.
    local ba = tonumber(a:match("buffer (%d+)"))
    local bb = tonumber(b:match("buffer (%d+)"))
    return registry.call("tool.spawn_wait", { buffers = { ba, bb } }, ctx)
  end)
  local ms = (vim.uv.hrtime() - t0) / 1e6
  assert(out:find("ANS-A", 1, true), "child A answer missing:\n" .. out)
  assert(out:find("ANS-B", 1, true), "child B answer missing:\n" .. out)
  assert(select(2, out:gsub("## subagent", "")) == 2, "expected two subagent sections:\n" .. out)
  -- Concurrent: ~500ms (slowest child) + ~100ms poll granularity + 200ms
  -- settle ≈ 800ms. Sequential would be ~2x the child time (1200ms+). The
  -- generous 950ms ceiling still cleanly separates the two regimes.
  assert(ms < 950, "children did not run concurrently (" .. math.floor(ms) .. "ms for 2x500ms)")
end)

case("spawn_wait skips buffers that are not this session's children", function()
  allow_all()
  local parent = vim.api.nvim_create_buf(true, false)
  local stranger = vim.api.nvim_create_buf(true, false) -- no straps_parent == parent
  local out = drive(function(ctx)
    ctx.bufnr = parent
    return registry.call("tool.spawn_wait", { buffers = { stranger } }, ctx)
  end)
  assert(out:find("not a subagent of this session", 1, true),
    "stranger buffer should be reported as skipped: " .. out)
end)


-- then return the child buffer. Identifying the child by scanning transcripts
-- is unreliable (the parent transcript also holds the spawn tool_use input, and
-- the child buffer may unload after its run), so record the child bufnr
-- deterministically: the child is the run whose buffer has a straps_parent set.
local function run_spawn_with(extra_input_lua)
  allow_all()
  _G.__spawn_child = nil
  define("hook.on_run_start", "hook", "test: capture the child bufnr", [[
return function(ctx)
  local ok, parent = pcall(function() return vim.b[ctx.bufnr].straps_parent end)
  if ok and parent then _G.__spawn_child = ctx.bufnr end
end
]])
  define("fn.provider", "fn", "test: parent spawns with extra input", ([==[
return function(req, ctx)
  local first_user
  for _, m in ipairs(req.messages) do
    if m.role == "user" then
      for _, p in ipairs(m.content) do
        if p.type == "text" then first_user = p.text; break end
      end
      break
    end
  end
  local is_child = first_user and first_user:find("KID-TASK", 1, true)
  ctx.await(function(resolve) vim.defer_fn(resolve, 5) end)
  if is_child then
    return { stop_reason = "end_turn", content = { { type = "text", text = "kid-done" } } }
  end
  if #req.messages == 1 then
    local input = { task = "KID-TASK: do a thing." }
    %s
    return { stop_reason = "tool_use", content = {
      { type = "tool_use", id = "s1", name = "spawn", input = input },
    } }
  end
  return { stop_reason = "end_turn", content = { { type = "text", text = "parent-done" } } }
end
]==]):format(extra_input_lua))

  local parent = state.new_session()
  state.append_text(parent, "spawn please")
  loop.start(parent)
  wait_done(parent)
  define("hook.on_run_start", "hook", "test: noop", "return function() end")
  return _G.__spawn_child, parent
end

case("spawn propagates explicit model/effort to the child buffer", function()
  local child = run_spawn_with([[
    input.model = "claude-fable-5"
    input.effort = "high"
  ]])
  assert(child, "child buffer not captured")
  assert(vim.b[child].straps_model == "claude-fable-5",
    "child model not set from spawn arg: " .. tostring(vim.b[child].straps_model))
  assert(vim.b[child].straps_effort == "high",
    "child effort not set from spawn arg: " .. tostring(vim.b[child].straps_effort))
end)

case("spawn inherits the parent's per-buffer model/effort when the arg is unset", function()
  -- The parent's per-buffer override is read inside tool.spawn; a spawn with no
  -- model/effort arg should copy it onto the child. Stamp the parent via a
  -- one-shot hook.on_run_start layered over the capture hook.
  allow_all()
  _G.__spawn_child = nil
  define("hook.on_run_start", "hook", "test: stamp parent + capture child", [[
return function(ctx)
  local parent = vim.b[ctx.bufnr].straps_parent
  if parent then
    _G.__spawn_child = ctx.bufnr
  else
    -- top-level (parent) run: give it a per-buffer override to inherit
    vim.b[ctx.bufnr].straps_model = "claude-opus-4-8"
    vim.b[ctx.bufnr].straps_effort = "medium"
  end
end
]])
  define("fn.provider", "fn", "test: parent spawns (no model arg)", [==[
return function(req, ctx)
  local first_user
  for _, m in ipairs(req.messages) do
    if m.role == "user" then
      for _, p in ipairs(m.content) do
        if p.type == "text" then first_user = p.text; break end
      end
      break
    end
  end
  local is_child = first_user and first_user:find("KID-TASK", 1, true)
  ctx.await(function(resolve) vim.defer_fn(resolve, 5) end)
  if is_child then
    return { stop_reason = "end_turn", content = { { type = "text", text = "kid-done" } } }
  end
  if #req.messages == 1 then
    return { stop_reason = "tool_use", content = {
      { type = "tool_use", id = "s1", name = "spawn", input = { task = "KID-TASK: inherit." } },
    } }
  end
  return { stop_reason = "end_turn", content = { { type = "text", text = "parent-done" } } }
end
]==])
  local parent = state.new_session()
  state.append_text(parent, "spawn please")
  loop.start(parent)
  wait_done(parent)
  define("hook.on_run_start", "hook", "test: noop", "return function() end")

  local child = _G.__spawn_child
  assert(child, "child buffer not captured")
  assert(vim.b[child].straps_model == "claude-opus-4-8",
    "child did not inherit parent model: " .. tostring(vim.b[child].straps_model))
  assert(vim.b[child].straps_effort == "medium",
    "child did not inherit parent effort: " .. tostring(vim.b[child].straps_effort))
end)

case("readonly child: writes are denied by the child-scope confirm", function()
  allow_all() -- parent-side confirm allows spawn; the CHILD scope must deny
  define("fn.provider", "fn", "test: readonly child tries to write", [==[
return function(req, ctx)
  local first_user
  for _, m in ipairs(req.messages) do
    if m.role == "user" then
      for _, p in ipairs(m.content) do
        if p.type == "text" then first_user = p.text; break end
      end
      break
    end
  end
  if not (first_user and first_user:find("RCHILD-TASK", 1, true)) then
    error("unexpected non-child request in readonly test")
  end
  local final = #req.messages > 1
  ctx.await(function(resolve)
    vim.defer_fn(function()
      if final then ctx.emit({ type = "text_delta", text = "rchild-done" }) end
      resolve()
    end, 5)
  end)
  if not final then
    return { stop_reason = "tool_use", content = {
      { type = "tool_use", id = "w1", name = "write_file",
        input = { path = "/tmp/should-not-exist.txt", content = "nope" } },
    } }
  end
  return { stop_reason = "end_turn", content = { { type = "text", text = "rchild-done" } } }
end
]==])

  local parent = vim.api.nvim_create_buf(true, false)
  local out = drive(function(ctx)
    ctx.bufnr = parent
    local started = registry.call("tool.spawn",
      { task = "RCHILD-TASK: write a file.", readonly = true }, ctx)
    local child = tonumber(started:match("buffer (%d+)"))
    return registry.call("tool.spawn_wait", { buffers = { child } }, ctx)
  end)
  assert(out:find("rchild-done", 1, true), "child did not finish: " .. out)

  local child
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and buf_text(b):find("RCHILD-TASK", 1, true)
      and vim.b[b].straps_session then
      child = b
    end
  end
  assert(child, "readonly child buffer not found")
  local ctext = buf_text(child)
  assert(ctext:find("readonly subagent: write_file is not allowed", 1, true),
    "write should be denied by the child-scope confirm:\n" .. ctext:sub(-400))
  -- The child's system block is composed for its shape: subagent section in,
  -- readonly note in, parent-only # Subagents guidance out.
  assert(ctext:find("# You are a subagent", 1, true),
    "child system block missing the subagent section")
  assert(ctext:find("READ%-ONLY"), "child system block missing the readonly note")
  assert(not ctext:find("\n# Subagents\n", 1, true),
    "child system block should drop the parent # Subagents section")
  assert(vim.fn.filereadable("/tmp/should-not-exist.txt") == 0, "denied write happened anyway")
end)

case("fn.readonly_policy is the single source of truth for read-only calls", function()
  local policy = function(name, input)
    return registry.try_call("fn.readonly_policy", name, input)
  end
  -- Presentation / help / interaction tools that had drifted out of spawn's
  -- readonly copy are read-only.
  for _, n in ipairs({
    "read_file", "grep", "show_user", "show_diff", "show_buffer",
    "set_findings", "ask_user", "help_search", "definition", "references",
  }) do
    assert(policy(n) == true, n .. " should be read-only")
  end
  -- Writes are not.
  for _, n in ipairs({ "write_file", "edit_file", "patch_file", "bash" }) do
    assert(policy(n) ~= true, n .. " should not be read-only")
  end
  -- List-mode exceptions.
  assert(policy("code_action", {}) == true, "code_action list mode is read-only")
  assert(policy("code_action", { index = 0 }) ~= true, "applying a code_action is a write")
  assert(policy("undo_edit", { history = true }) == true, "undo history is read-only")
  assert(policy("undo_edit", { to_seq = 3 }) ~= true, "undoing is a write")
end)

case("spawn depth guard refuses a child spawning a grandchild", function()
  local buf = vim.api.nvim_create_buf(true, false)
  vim.b[buf].straps_spawn_depth = 1
  local out = drive(function(ctx)
    ctx.bufnr = buf
    return registry.call("tool.spawn", { task = "grandchild task" }, ctx)
  end)
  assert(out:find("refused", 1, true) and out:find("depth", 1, true),
    "depth guard did not trip: " .. out)
end)

case("two concurrent runs keep their session scopes isolated", function()
  allow_all()
  define("fn.provider", "fn", "test: two interleaved sessions defining tools", [==[
return function(req, ctx)
  local first_user
  for _, m in ipairs(req.messages) do
    if m.role == "user" then
      for _, p in ipairs(m.content) do
        if p.type == "text" then first_user = p.text; break end
      end
      break
    end
  end
  local tag = first_user:match("SESS%-(%u)")
  -- Different delays force the two runs' awaits to interleave.
  local delay = tag == "A" and 40 or 15
  local final = #req.messages > 1
  ctx.await(function(resolve)
    vim.defer_fn(function()
      if final then ctx.emit({ type = "text_delta", text = tag .. "-DONE" }) end
      resolve()
    end, delay)
  end)
  if not final then
    return { stop_reason = "tool_use", content = {
      { type = "tool_use", id = "d" .. tag, name = "registry_define",
        input = { name = "tool.conc_" .. tag:lower(), kind = "tool",
          source = 'return function() return "conc" end' } },
    } }
  end
  return { stop_reason = "end_turn", content = { { type = "text", text = tag .. "-DONE" } } }
end
]==])

  local a = state.new_session()
  local b = state.new_session()
  state.append_text(a, "SESS-A define your tool")
  state.append_text(b, "SESS-B define your tool")
  loop.start(a)
  loop.start(b)
  wait_done(a)
  wait_done(b)

  assert(buf_text(a):find("A-DONE", 1, true), "session A did not finish")
  assert(buf_text(b):find("B-DONE", 1, true), "session B did not finish")
  assert(registry.get("tool.conc_a") == nil and registry.get("tool.conc_b") == nil,
    "concurrent runs leaked defines to global")

  local prev = registry.set_active_scope(a)
  local a_own, a_cross = registry.get("tool.conc_a"), registry.get("tool.conc_b")
  registry.set_active_scope(b)
  local b_own, b_cross = registry.get("tool.conc_b"), registry.get("tool.conc_a")
  registry.set_active_scope(prev)
  assert(a_own and a_own.scope == a, "session A missing its own tool")
  assert(b_own and b_own.scope == b, "session B missing its own tool")
  assert(a_cross == nil and b_cross == nil,
    "interleaved resumes cross-contaminated the scopes")
end)

case("a crashing child's error comes back to the parent, no hang", function()
  allow_all()
  define("fn.provider", "fn", "test: child provider explodes", [==[
return function(req, ctx)
  local first_user
  for _, m in ipairs(req.messages) do
    if m.role == "user" then
      for _, p in ipairs(m.content) do
        if p.type == "text" then first_user = p.text; break end
      end
      break
    end
  end
  if first_user and first_user:find("CRASH-TASK", 1, true) then
    error("child exploded spectacularly")
  end
  error("unexpected non-child request in crash test")
end
]==])
  local parent = vim.api.nvim_create_buf(true, false)
  local out = drive(function(ctx)
    ctx.bufnr = parent
    local started = registry.call("tool.spawn", { task = "CRASH-TASK: boom" }, ctx)
    local child = tonumber(started:match("buffer (%d+)"))
    return registry.call("tool.spawn_wait", { buffers = { child } }, ctx)
  end)
  assert(out:find("subagent (buffer", 1, true), "spawn_wait should return, not hang: " .. out)
  assert(out:find("child exploded spectacularly", 1, true),
    "child's error should surface in the parent's result: " .. out)
end)

case("a hanging child hits the spawn timeout and is stopped", function()
  allow_all()
  define("fn.provider", "fn", "test: child hangs until cancelled", [==[
return function(req, ctx)
  ctx.await(function(resolve)
    ctx.on_cancel(function() resolve() end)
    -- never resolves on its own
  end)
  return { content = {}, stop_reason = "cancelled" }
end
]==])
  local parent = vim.api.nvim_create_buf(true, false)
  local t0 = vim.uv.hrtime()
  local out = drive(function(ctx)
    ctx.bufnr = parent
    local started = registry.call("tool.spawn",
      { task = "HANG-TASK: never answer", timeout_ms = 400 }, ctx)
    local child = tonumber(started:match("buffer (%d+)"))
    return registry.call("tool.spawn_wait", { buffers = { child } }, ctx)
  end)
  local ms = (vim.uv.hrtime() - t0) / 1e6
  assert(out:find("timed out (stopped)", 1, true), "timeout status missing: " .. out)
  assert(ms < 5000, "spawn_wait timeout too slow: " .. math.floor(ms) .. "ms")
end)

case("cancelling the parent stops a spawned child mid-flight", function()
  allow_all()
  _G.straps_hang_child = nil
  define("fn.provider", "fn", "test: parent spawns a hanging child then waits", [==[
return function(req, ctx)
  local first_user, last_result
  for _, m in ipairs(req.messages) do
    if m.role == "user" then
      for _, p in ipairs(m.content) do
        if p.type == "text" and not first_user then first_user = p.text end
        if p.type == "tool_result" then last_result = p.content end
      end
    end
  end
  if first_user and first_user:find("HANG2-TASK", 1, true) then
    _G.straps_hang_child = ctx.bufnr
    ctx.await(function(resolve)
      ctx.on_cancel(function() resolve() end)
    end)
    return { content = {}, stop_reason = "cancelled" }
  end
  ctx.await(function(resolve) vim.defer_fn(resolve, 5) end)
  if #req.messages == 1 then
    return { stop_reason = "tool_use", content = {
      { type = "tool_use", id = "s9", name = "spawn",
        input = { task = "HANG2-TASK: hang forever" } },
    } }
  end
  -- Parent blocks in spawn_wait on the hanging child until it is cancelled.
  local child = last_result and tonumber(last_result:match("buffer (%d+)"))
  if child then
    return { stop_reason = "tool_use", content = {
      { type = "tool_use", id = "w9", name = "spawn_wait",
        input = { buffers = { child } } },
    } }
  end
  return { stop_reason = "end_turn", content = { { type = "text", text = "unreachable" } } }
end
]==])

  local parent = state.new_session()
  state.append_text(parent, "spawn something that hangs")
  -- Cancel only once the parent is actually inside spawn_wait, else the run's
  -- post-provider cancel check returns before the tool (and its child-stopping
  -- on_cancel handler) ever runs.
  _G.straps_parent_waiting = false
  define("hook.before_tool", "hook", "test: note spawn_wait entry", [[
return function(name) if name == "spawn_wait" then _G.straps_parent_waiting = true end end
]])
  loop.start(parent)
  assert(vim.wait(8000, function() return _G.straps_hang_child ~= nil end, 20),
    "child never started")
  local child = _G.straps_hang_child
  assert(loop.running(child), "child should be mid-run")
  assert(vim.wait(8000, function() return _G.straps_parent_waiting end, 20),
    "parent never reached spawn_wait")

  loop.stop(parent)
  wait_done(parent)
  define("hook.before_tool", "hook", "test: noop", "return function() end")
  assert(vim.wait(4000, function() return not loop.running(child) end, 20),
    "cancelling the parent did not stop the child")
  assert(buf_text(parent):find("[straps: run cancelled]", 1, true),
    "parent missing its cancellation note")
end)

case("a hand-mangled transcript (deleted tool_result) fails loudly, not forever", function()
  allow_all()
  -- Simulate the real API's rejection of an unpaired tool_use: the scripted
  -- provider validates pairing like the server would and raises.
  define("fn.provider", "fn", "test: rejects unpaired tool_use like the API", [==[
return function(req, ctx)
  ctx.await(function(resolve) vim.defer_fn(resolve, 5) end)
  for i, m in ipairs(req.messages) do
    if m.role == "assistant" then
      for _, p in ipairs(m.content) do
        if p.type == "tool_use" then
          local nxt = req.messages[i + 1]
          local paired = false
          if nxt and nxt.role == "user" then
            for _, q in ipairs(nxt.content) do
              if q.type == "tool_result" and q.tool_use_id == p.id then paired = true end
            end
          end
          if not paired then
            error("simulated API 400: unpaired tool_use " .. tostring(p.id))
          end
        end
      end
    end
  end
  return { stop_reason = "end_turn", content = { { type = "text", text = "clean" } } }
end
]==])

  local bufnr = state.new_session()
  state.append(bufnr, "user", nil, "please run a tool")
  state.append(bufnr, "assistant", nil, "running it")
  state.append(bufnr, "tool_use", { id = "t9", name = "ping" }, "{}")
  -- ...and the user hand-deleted the tool_result block. Send another message.
  state.append(bufnr, "user", nil, "and now continue")

  loop.start(bufnr)
  wait_done(bufnr)

  local text = buf_text(bufnr)
  assert(text:find("run error", 1, true), "mangled transcript should end in a visible run error")
  assert(text:find("unpaired tool_use t9", 1, true),
    "the API-style explanation should reach the transcript")
  assert(not loop.running(bufnr), "run must end, not spin")
  -- The buffer stays usable: a trailing user marker is restored.
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local last_marker
  for i = #lines, 1, -1 do
    if lines[i]:find("%%[straps:", 1, true) == 1 then last_marker = lines[i]; break end
  end
  assert(last_marker and last_marker:find("user", 1, true),
    "no trailing user block after the failure")
end)

case("per-buffer max_turns override bounds a run", function()
  allow_all()
  define("tool.ping", "tool", "ping", [[return function() return "pong" end]])
  _G.straps_scope_calls = 0
  define("fn.provider", "fn", "test: tools forever", [==[
return function(req, ctx)
  _G.straps_scope_calls = _G.straps_scope_calls + 1
  ctx.await(function(resolve) vim.defer_fn(resolve, 5) end)
  return { stop_reason = "tool_use", content = {
    { type = "tool_use", id = "p" .. _G.straps_scope_calls, name = "ping",
      input = vim.empty_dict() },
  } }
end
]==])
  local bufnr = state.new_session()
  vim.b[bufnr].straps_max_turns = 2
  state.append_text(bufnr, "ping forever")
  loop.start(bufnr)
  wait_done(bufnr)
  assert(_G.straps_scope_calls == 2,
    "provider called " .. _G.straps_scope_calls .. " times, want 2 (vim.b override)")
  assert(buf_text(bufnr):find("stopped after 2 turns", 1, true), "exhaustion note missing")
end)

-- --------------------------------------------------- auto mode / capabilities

case("fn.capability classifies every category and its input-split arms", function()
  local cap = function(name, input)
    return registry.try_call("fn.capability", name, input)
  end
  assert(cap("read_file") == "read", "read_file -> read")
  assert(cap("write_file") == "edit", "write_file -> edit")
  assert(cap("delete_file") == "delete", "delete_file -> delete")
  assert(cap("bash") == "exec", "bash -> exec")
  assert(cap("eval_lua") == "lua", "eval_lua -> lua")
  assert(cap("fetch_url") == "net", "fetch_url -> net")
  assert(cap("registry_define") == "define", "registry_define -> define")
  assert(cap("spawn") == "spawn", "spawn -> spawn")
  assert(cap("some_unknown_tool") == "other", "unknown -> other")
  -- input-split tools, both arms each.
  assert(cap("code_action", {}) == "read", "code_action list -> read")
  assert(cap("code_action", { index = 1 }) == "edit", "code_action apply -> edit")
  assert(cap("fix_diagnostic", {}) == "read", "fix_diagnostic list -> read")
  assert(cap("fix_diagnostic", { index = 2 }) == "edit", "fix_diagnostic apply -> edit")
  assert(cap("undo_edit", { history = true }) == "read", "undo history -> read")
  assert(cap("undo_edit", { steps = 1 }) == "edit", "undo -> edit")
  -- no-arg: exactly the grantable list, in order.
  local grantable = registry.try_call("fn.capability")
  assert(type(grantable) == "table", "no-arg should return a list")
  local want = { "edit", "delete", "exec", "lua", "net", "spawn" }
  assert(#grantable == #want, "grantable list wrong length: " .. #grantable)
  for i, c in ipairs(want) do
    assert(grantable[i] == c, "grantable[" .. i .. "] = " .. tostring(grantable[i]) .. ", want " .. c)
  end
end)

case("spawn allow={edit} grants writes without prompting; ungranted denied", function()
  allow_all() -- parent-side confirm allows spawn; child scope enforces the grants
  local orig_confirm = vim.fn.confirm
  vim.fn.confirm = function() error("confirm prompt reached — grant did not bypass") end
  local target = vim.fn.tempname()
  _G.__auto_target = target
  define("fn.provider", "fn", "test: allow=edit child writes then runs bash", [==[
return function(req, ctx)
  local first_user
  for _, m in ipairs(req.messages) do
    if m.role == "user" then
      for _, p in ipairs(m.content) do
        if p.type == "text" then first_user = p.text; break end
      end
      break
    end
  end
  if not (first_user and first_user:find("ACHILD-TASK", 1, true)) then
    error("unexpected non-child request in allow test")
  end
  local n = #req.messages
  ctx.await(function(resolve)
    vim.defer_fn(function()
      if n >= 5 then ctx.emit({ type = "text_delta", text = "achild-done" }) end
      resolve()
    end, 5)
  end)
  if n == 1 then
    return { stop_reason = "tool_use", content = {
      { type = "tool_use", id = "w1", name = "write_file",
        input = { path = _G.__auto_target, content = "granted-write" } },
    } }
  elseif n == 3 then
    return { stop_reason = "tool_use", content = {
      { type = "tool_use", id = "b1", name = "bash", input = { command = "echo hi" } },
    } }
  end
  return { stop_reason = "end_turn", content = { { type = "text", text = "achild-done" } } }
end
]==])

  local parent = vim.api.nvim_create_buf(true, false)
  local ok, out = pcall(function()
    return drive(function(ctx)
      ctx.bufnr = parent
      local started = registry.call("tool.spawn",
        { task = "ACHILD-TASK: write then bash.", allow = { "edit" } }, ctx)
      local child = tonumber(started:match("buffer (%d+)"))
      return registry.call("tool.spawn_wait", { buffers = { child } }, ctx)
    end)
  end)
  vim.fn.confirm = orig_confirm
  assert(ok, "drive errored (confirm prompt reached?): " .. tostring(out))
  assert(out:find("achild-done", 1, true), "child did not finish: " .. out)

  -- The write ran (grant returned true before any prompt).
  assert(vim.fn.filereadable(target) == 1, "granted write did not happen")
  assert(table.concat(vim.fn.readfile(target), "\n") == "granted-write",
    "granted write has wrong content")

  -- bash was NOT granted: its tool_result is a coverage error.
  local child
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and buf_text(b):find("ACHILD-TASK", 1, true)
      and vim.b[b].straps_session then
      child = b
    end
  end
  assert(child, "allow child buffer not found")
  local ctext = buf_text(child)
  assert(ctext:find("is not covered by this child's grants", 1, true),
    "bash should be denied as not covered:\n" .. ctext:sub(-400))
end)

case("spawn allow validation rejects bad entries and readonly+allow", function()
  allow_all()
  local parent = vim.api.nvim_create_buf(true, false)
  local function try(input)
    local ok, err = pcall(function()
      drive(function(ctx)
        ctx.bufnr = parent
        return registry.call("tool.spawn", input, ctx)
      end)
    end)
    return ok, tostring(err)
  end
  local ok, err = try({ task = "T", allow = { "define" } })
  assert(not ok and err:find("not a grantable category", 1, true),
    "allow=define should error as not grantable: " .. err)
  ok, err = try({ task = "T", allow = { "nope" } })
  assert(not ok and err:find("nope", 1, true), "allow=nope should name the bad entry: " .. err)
  -- registry_define EXISTS as a tool, so it passes the tool-name check; the
  -- define-category ceiling must still reject it (a define grant would let
  -- the child shadow its own hook.confirm).
  ok, err = try({ task = "T", allow = { "registry_define" } })
  assert(not ok and err:find("define category", 1, true),
    "allow=registry_define should error via the define-category ceiling: " .. err)
  ok, err = try({ task = "T", readonly = true, allow = { "edit" } })
  assert(not ok and err:find("mutually exclusive", 1, true),
    "readonly+allow should error mutually exclusive: " .. err)
end)

case("default hook.confirm honors cap: grants and prompts without them", function()
  local buf = vim.api.nvim_create_buf(true, false)
  -- Restore the default hook.confirm (allow_all shadowed it globally).
  define("hook.confirm", "hook", "default", DEFAULT_CONFIRM)
  local hookc = registry.get("hook.confirm")
  assert(hookc, "hook.confirm missing")
  -- With cap:exec granted, bash is allowed without any prompt.
  vim.b[buf].straps_allowed = { ["cap:exec"] = true }
  local orig = vim.fn.confirm
  vim.fn.confirm = function() error("prompt reached despite cap:exec grant") end
  local ok, allowed = pcall(function()
    return registry.call("hook.confirm", "bash", { command = "x" }, { bufnr = buf })
  end)
  vim.fn.confirm = orig
  assert(ok and allowed == true, "cap:exec grant should allow bash: " .. tostring(allowed))
  -- Empty allow-set: falls through to the prompt, which we stub to No (2).
  vim.b[buf].straps_allowed = {}
  orig = vim.fn.confirm
  vim.fn.confirm = function() return 2 end
  local denied = registry.call("hook.confirm", "bash", { command = "x" }, { bufnr = buf })
  vim.fn.confirm = orig
  assert(denied ~= true, "empty allow-set should not auto-allow bash")
end)

case("ui.auto grants, validates, clears and refuses non-session buffers", function()
  local ui = require("straps.ui")
  local notes = {}
  local orig_notify = vim.notify
  vim.notify = function(msg) notes[#notes + 1] = tostring(msg) end

  -- Real session buffer, made current.
  local sess = state.new_session()
  vim.api.nvim_set_current_buf(sess)
  assert(vim.b.straps_session == true, "session buffer not current")

  ui.auto("edit,exec")
  local set = vim.b[sess].straps_allowed
  assert(type(set) == "table" and set["cap:edit"] and set["cap:exec"],
    "auto('edit,exec') did not set cap keys")

  -- A bogus token changes nothing and notifies an error.
  local before = vim.inspect(vim.b[sess].straps_allowed)
  notes = {}
  ui.auto("bogus")
  assert(vim.inspect(vim.b[sess].straps_allowed) == before, "bogus token mutated the grants")
  assert(#notes > 0 and notes[#notes]:find("bogus", 1, true), "bogus token should notify an error")

  -- off clears cap: keys but leaves a pre-existing non-cap key intact.
  local seed = {}
  for k, v in pairs(vim.b[sess].straps_allowed) do seed[k] = v end
  seed["editdir:/x"] = true
  vim.b[sess].straps_allowed = seed
  ui.auto("off")
  local after = vim.b[sess].straps_allowed
  assert(after["editdir:/x"] == true, "off cleared a non-cap key")
  for k in pairs(after) do
    assert(not k:match("^cap:"), "off left a cap key: " .. k)
  end

  -- Non-session buffer: notify error, set nothing.
  local plain = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(plain)
  notes = {}
  ui.auto("edit")
  assert(vim.b[plain].straps_allowed == nil, "auto set grants on a non-session buffer")
  assert(#notes > 0 and notes[#notes]:find("not a straps session", 1, true),
    "non-session auto should notify")

  vim.notify = orig_notify
end)

print(failed and "FAILED" or "ALL PASS")
print(failed and "FAILED" or "ALL PASS")
os.exit(failed and 1 or 0)
