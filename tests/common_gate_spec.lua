local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(here, ":p:h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local straps = require("straps").setup({})
local registry = require("straps.registry")
local state = require("straps.state")
local loop = require("straps.loop")
local directory = vim.fn.tempname()
straps.config.session_dir = directory
straps.config.max_spawn_depth = 8
local parent, child, fixture, buffers
local checks = 0
local function expect(actual, expected)
  checks = checks + 1
  if tonumber(vim.env.STRAPS_COMMON_COUNTERFACTUAL) == checks then
    assert.are_not.same(expected, actual, "counterfactual " .. checks)
  else
    assert.same(expected, actual)
  end
end
local function define(name, source, capability)
  return registry.define({ name = name, kind = name:match("^([^.]+)"), source = source, capability = capability })
end
local counter_source = [[return function()
  _G.common_gate_fixture.count = _G.common_gate_fixture.count + 1
  return "counted"
end]]
local function context(buf)
  local status = { cancelled = false }
  return { bufnr = buf, cancelled = function() return status.cancelled end, on_cancel = function() end,
    await = function(start)
      local done, result = false, nil
      start(function(value) done, result = true, value end)
      assert(vim.wait(2000, function() return done end, 1), "fixture await timeout")
      return result
    end }
end
local function spawn(buf, allow)
  local previous = loop.start
  loop.start = function() end
  local ok, result = pcall(registry.call, "tool.spawn", { task = "harmless common gate fixture", allow = allow }, context(buf))
  loop.start = previous
  assert.is_true(ok, tostring(result))
  local found
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.b[b].straps_parent == buf and not buffers[b] then found = b end
  end
  assert.is_number(found, tostring(result))
  buffers[found] = true
  assert.equals(buf, registry.scope_parent(found))
  return found
end
local function invoke(buf, path, mode)
  local ctx = context(buf)
  return pcall(registry.call, path == "direct" and "tool.common_counter" or "tool.common_outer",
    { path = path, mode = mode }, ctx)
end

before_each(function()
  registry.set_active_scope(nil)
  fixture = { count = 0, confirmations = 0 }
  _G.common_gate_fixture = fixture
  buffers = {}
  parent = state.new_session()
  buffers[parent] = true
  registry.ensure_scope(parent)
  fixture.parent = parent
  define("tool.common_counter", counter_source, "exec")
  define("hook.common_nested", [[return function(input, ctx)
    return require("straps.registry").call("tool.common_counter", {}, ctx)
  end]])
  define("tool.common_outer", [[return function(input, ctx)
    local reg = require("straps.registry")
    if input.mode == "missing" then ctx = nil end
    if input.mode == "forged" then ctx = { bufnr = _G.common_gate_fixture.parent } end
    local run = function()
      if input.path == "hook" then return reg.call("hook.common_nested", {}, ctx) end
      return reg.call("tool.common_counter", {}, ctx)
    end
    if input.path == "wrap" then return coroutine.wrap(run)() end
    return run()
  end]], "read")
  child = spawn(parent, {})
end)

after_each(function()
  registry.set_active_scope(nil)
  if registry.get("hook.guard.common_nested") then registry.remove("hook.guard.common_nested") end
  for b in pairs(buffers) do
    if loop.running(b) then loop.stop(b) end
    if vim.api.nvim_buf_is_valid(b) then vim.api.nvim_buf_delete(b, { force = true }) end
  end
  _G.common_gate_fixture = nil
end)

teardown(function()
  vim.fn.delete(directory, "rf")
  if vim.env.STRAPS_COMMON_COUNT == "1" then print("COMMON_GATE_ASSERTIONS=" .. checks) end
end)

for _, path in ipairs({ "direct", "nested", "hook", "wrap" }) do
  it("denies a readonly spawned child's " .. path .. " write", function()
    local ok = invoke(child, path)
    expect(ok, false)
    expect(fixture.count, 0)
  end)
end

for _, path in ipairs({ "nested", "hook", "wrap" }) do
  for _, mode in ipairs({ "missing", "forged" }) do
    it("keeps the spawned child's ceiling for " .. path .. " " .. mode .. " context", function()
      local ok = invoke(child, path, mode)
      expect(ok, false)
      expect(fixture.count, 0)
    end)
  end
end

for _, path in ipairs({ "direct", "nested", "hook", "wrap" }) do
  it("permits a granted child's " .. path .. " write", function()
    registry.grant(child, "cap:exec")
    local ok, result = invoke(child, path)
    expect(ok, true)
    expect(result, "counted")
    expect(fixture.count, 1)
  end)
end

it("inherits an omitted nested context without rejecting a granted child", function()
  registry.grant(child, "cap:exec")
  expect(invoke(child, "wrap", "missing"), true)
  expect(fixture.count, 1)
end)

it("rejects mismatched nested context even when both sessions permit the tool", function()
  registry.grant(child, "cap:exec")
  expect(invoke(child, "nested", "forged"), false)
  expect(fixture.count, 0)
end)

it("resolves a context-free call through an active readonly child scope", function()
  registry.set_active_scope(child)
  local ok = pcall(registry.call, "tool.common_counter", {})
  registry.set_active_scope(nil)
  expect(ok, false)
  expect(fixture.count, 0)
end)

it("retains ungated context-free direct calls", function()
  expect(pcall(registry.call, "tool.common_counter", {}), true)
  expect(fixture.count, 1)
end)

it("retains the gated marker when clearing every grant", function()
  registry.grant(child, "cap:exec")
  registry.clear_grants(child, "")
  expect(registry.granted(child)["spawn:gated"], true)
  expect(registry.granted(child)["cap:exec"], nil)
  expect(invoke(child, "direct"), false)
  expect(fixture.count, 0)
end)

it("rechecks a granted child's permissions between gate and execution", function()
  registry.grant(child, "cap:exec")
  local ctx = context(child)
  local allowed, _, run = registry.gate_tool("common_counter", {}, ctx)
  expect(allowed, true)
  registry.clear_grants(child, "cap:exec")
  expect(run(ctx), false)
  expect(fixture.count, 0)
end)

it("rejects descendant grants above the parent's ceiling", function()
  registry.grant(child, "cap:spawn")
  local ok = pcall(registry.call, "tool.spawn", { task = "must not spawn", allow = { "exec" } }, context(child))
  expect(ok, false)
  expect(fixture.count, 0)
end)

it("defaults descendants to readonly after grants are cleared and the marker is retained", function()
  registry.grant(child, "cap:exec")
  registry.clear_grants(child, "")
  registry.grant(child, "cap:spawn")
  local descendant = spawn(child)
  expect(registry.granted(descendant)["spawn:gated"], true)
  expect(invoke(descendant, "direct"), false)
  expect(fixture.count, 0)
end)

for _, mutation in ipairs({ "cancelled", "cancel_function", "session", "definition", "cwd", "scope" }) do
  it("rejects ordinary execution after yielding confirmation changes " .. mutation, function()
    local ctx = context(parent)
    local cancelled = false
    ctx.cancelled = function() return cancelled end
    local co = coroutine.create(function()
      local allowed, reason, run = registry.gate_tool("common_counter", {}, ctx, {
        confirm = function() coroutine.yield("pending") return true end,
      })
      if not allowed then return false, reason end
      return run(ctx)
    end)
    local started, pending = coroutine.resume(co)
    expect(started, true)
    expect(pending, "pending")
    local cwd = vim.fn.getcwd()
    if mutation == "cancelled" then cancelled = true end
    if mutation == "cancel_function" then ctx.cancelled = function() return false end end
    if mutation == "session" then ctx.bufnr = child end
    if mutation == "definition" then define("tool.common_counter", counter_source, "exec") end
    if mutation == "cwd" then vim.fn.mkdir(directory, "p") vim.cmd.cd(directory) end
    if mutation == "scope" then registry.ensure_scope(parent).parent = child end
    local resumed, allowed = coroutine.resume(co)
    vim.cmd.cd(cwd)
    expect(resumed, true)
    expect(allowed, false)
    expect(fixture.count, 0)
  end)
end

it("rejects an execution context with a replaced cancellation function", function()
  local ctx = context(parent)
  local allowed, _, run = registry.gate_tool("common_counter", {}, ctx)
  expect(allowed, true)
  expect(run(context(parent)), false)
  expect(fixture.count, 0)
end)

it("binds pending execution to its original scope despite an alternate active scope", function()
  registry.set_active_scope(parent)
  define("tool.common_counter", counter_source, "exec")
  local alternate = state.new_session()
  buffers[alternate] = true
  registry.ensure_scope(alternate)
  registry.set_active_scope(alternate)
  define("tool.common_counter", [[return function() _G.common_gate_fixture.count = 99 return "wrong scope" end]], "exec")
  registry.set_active_scope(parent)
  local version = registry.get("tool.common_counter").version
  local ctx = context(parent)
  local allowed, _, run = registry.gate_tool("common_counter", {}, ctx)
  registry.set_active_scope(alternate)
  expect(registry.get("tool.common_counter").version, version)
  expect(allowed, true)
  local ok, result = run(ctx)
  expect(ok, true)
  expect(result, "counted")
  expect(fixture.count, 1)
end)

it("binds context-free nested calls throughout yielding confirmation", function()
  local ctx = context(child)
  local co = coroutine.create(function()
    return registry.gate_tool("common_outer", {}, ctx, { confirm = function()
      coroutine.yield("pending")
      return pcall(registry.call, "tool.common_counter", {})
    end })
  end)
  expect(coroutine.resume(co), true)
  registry.set_active_scope(parent)
  local resumed, allowed = coroutine.resume(co)
  expect(resumed, true)
  expect(allowed, false)
  expect(fixture.count, 0)
end)

it("rejects a write attempted by a readonly child's guard", function()
  define("hook.guard.common_nested", [[return function(op, name)
    if op == "before" and name == "common_outer" then
      require("straps.registry").call("tool.common_counter", {})
    end
  end]])
  expect(invoke(child, "nested"), false)
  expect(fixture.count, 0)
end)

it("rejects context-free wrapped calls when two same-session executions are pending", function()
  registry.grant(child, "cap:exec")
  local function pending()
    local ctx = context(child)
    return coroutine.create(function()
      return registry.gate_tool("common_outer", {}, ctx, { confirm = function()
        coroutine.yield("pending")
        return true
      end })
    end)
  end
  local first, second = pending(), pending()
  local ok_first, wait_first = coroutine.resume(first)
  expect(ok_first, true)
  expect(wait_first, "pending")
  registry.set_active_scope(nil)
  local ok_second, wait_second = coroutine.resume(second)
  expect(ok_second, true)
  expect(wait_second, "pending")
  registry.set_active_scope(child)
  expect(pcall(coroutine.wrap(function() return registry.call("tool.common_counter", {}) end)), false)
  expect(fixture.count, 0)
  expect(coroutine.resume(second), true)
  expect(coroutine.resume(first), true)
end)

it("rejects a parent gate closure invoked from a readonly child body", function()
  local ctx = context(parent)
  local allowed, _, run = registry.gate_tool("common_counter", {}, ctx)
  expect(allowed, true)
  fixture.run = function() return run(ctx) end
  define("tool.common_outer", [[return function() return _G.common_gate_fixture.run() end]], "read")
  local ok, result = invoke(child, "nested")
  expect(ok, true)
  expect(result, false)
  expect(fixture.count, 0)
end)

it("inherits the accepted replacement run context in nested context-free calls", function()
  local first = context(parent)
  local second = { bufnr = parent, cancelled = first.cancelled, marker = "replacement" }
  define("tool.common_counter", [[return function(_, ctx) return ctx.marker end]], "exec")
  local allowed, _, run = registry.gate_tool("common_outer", { mode = "missing" }, first)
  expect(allowed, true)
  local ok, result = run(second)
  expect(ok, true)
  expect(result, "replacement")
end)

it("rejects forged wrapped context when the outer body runs in a coroutine", function()
  registry.grant(child, "cap:exec")
  local co = coroutine.create(function() return invoke(child, "wrap", "forged") end)
  local resumed, ok = coroutine.resume(co)
  expect(resumed, true)
  expect(ok, false)
  expect(fixture.count, 0)
end)

it("runs the real parallel readonly loop without admitting nested writes", function()
  fixture.parallel_entries, fixture.turn = 0, 0
  local source = [[return function()
    _G.common_gate_fixture.parallel_entries = _G.common_gate_fixture.parallel_entries + 1
    return require("straps.registry").call("tool.common_counter", {})
  end]]
  registry.set_active_scope(child)
  define("tool.read_file", source, "read")
  define("tool.glob", source, "read")
  define("fn.provider", [[return function()
    local f = _G.common_gate_fixture
    f.turn = f.turn + 1
    if f.turn == 1 then
      return { stop_reason = "tool_use", content = {
        { type = "tool_use", id = "common-a", name = "read_file", input = {} },
        { type = "tool_use", id = "common-b", name = "glob", input = {} },
      } }
    end
    return { stop_reason = "end_turn", content = { { type = "text", text = "done" } } }
  end]])
  registry.set_active_scope(nil)
  state.append_text(child, "run harmless parallel fixture")
  loop.start(child)
  expect(vim.wait(5000, function() return not loop.running(child) end, 10), true)
  expect(fixture.parallel_entries, 2)
  expect(fixture.count, 0)
  expect(fixture.turn, 2)
end)
