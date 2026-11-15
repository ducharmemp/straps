local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(here, ":p:h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local registry, bridge, state, parent, controller, ctx, allocated, attached, started, committed, last_child, fail_attach, discarded, cancelled_plans
local directory, previous_directory
local function mutate(source, name, before, after)
  if vim.env.STRAPS_CHILD_MUTANT ~= name then return source end
  local first, last = assert(source:find(before, 1, true))
  return source:sub(1, first - 1) .. after .. source:sub(last + 1)
end
before_each(function()
  for _, name in ipairs({ "registry", "ceilings", "contextual_children", "state" }) do package.loaded["straps." .. name] = nil end
  if vim.env.STRAPS_CHILD_MUTANT == "global_revision" then
    local source = table.concat(vim.fn.readfile(root .. "/lua/straps/ceilings.lua"), "\n")
    source = mutate(source, "global_revision", 'out[#out + 1] = record.revision', 'out[#out + 1] = revision')
    package.loaded["straps.ceilings"] = assert(loadstring(source))()
  end
  registry = require("straps.registry")
  directory = vim.fn.tempname()
  previous_directory = require("straps").config.session_dir
  require("straps").config.session_dir = directory
  require("straps.layers.agents").register_spawn()
  registry.define({ name = "fn.system_prompt", kind = "fn", source = 'return function() return "PROMPT" end' })
  registry.define({ name = "fn.spawn_depth_limit", kind = "fn", source = 'return function() return 4 end' })
  registry.define({ name = "fn.capability", kind = "fn", source = 'return function(name) if name then return "edit" end return {"edit","spawn"} end' })
  registry.define({ name = "tool.write", kind = "tool", source = 'return function() _G.child_write_body = (_G.child_write_body or 0) + 1 end' })
  controller = registry.setup_authorization({ assess = function() return { decision = "allow" } end,
    execution_stamp = function(b) return { session = b } end, validate_stamp = function() return true end })
  controller.classify_ceiling(registry.get("tool.spawn").identity, "spawn")
  controller.classify_ceiling(registry.get("tool.write").identity, "edit")
  local source = table.concat(vim.fn.readfile(root .. "/lua/straps/contextual_children.lua"), "\n")
  source = mutate(source, "attach", 'else adapter.attach(plan, child, vim.deepcopy(options.delegation), token) end', 'else attached = true end')
  source = mutate(source, "normalize", 'normalized.readonly = normalized.readonly and true or nil', '')
  source = mutate(source, "rollback", 'if child then\n      local cleaned', 'if false then\n      local cleaned')
  source = mutate(source, "cancel_success", 'if ok and not child and adapter.cancel then pcall(adapter.cancel, plan) end', '')
  source = mutate(source, "cancel", 'if adapter.cancel then pcall(adapter.cancel, plan) end', '')
  source = mutate(source, "discard", 'if token and receipts.discard_construction then pcall(receipts.discard_construction, token) end', '')
  bridge = assert(loadstring(source))()
  package.loaded["straps.contextual_children"] = bridge
  state = require("straps.state")
  allocated, attached, started, committed, fail_attach, discarded, cancelled_plans = 0, 0, 0, 0, false, 0, 0
  bridge.install({ prepare = controller.prepare_child, attach = function(plan, child, subset, token)
    controller.attach_child(plan, child)
    if fail_attach then error("injected attachment failure") end
    assert.equals("receipt", token)
    assert.same(_G.child_delegation, subset)
    local previous = registry.set_active_scope(child)
    assert.equals("scoped", registry.try_call("fn.parent_marker"))
    registry.set_active_scope(previous)
    committed = committed + 1
    attached = attached + 1
  end, rollback = function() end, cancel = function() cancelled_plans = cancelled_plans + 1 end }, { receipts = { construct = function(options, scope)
    assert.equals(parent, scope)
    assert.is_true(options.subagent)
    allocated = allocated + 1
    last_child = state.new_session(options)
    assert.equals(vim.uv.fs_realpath(directory), vim.fn.fnamemodify(vim.api.nvim_buf_get_name(last_child), ":h"))
    return last_child, "receipt"
  end, discard_construction = function(token) assert.equals("receipt", token); discarded = discarded + 1 end } })
  parent = state.new_session()
  assert.equals(vim.uv.fs_realpath(directory), vim.fn.fnamemodify(vim.api.nvim_buf_get_name(parent), ":h"))
  registry.ensure_scope(parent)
  registry.define({ name = "fn.parent_marker", kind = "fn", source = 'return function() return "scoped" end' }, { scope = parent })
  controller.install_ceiling(parent, {})
  package.loaded["straps.loop"] = { start = function(child)
    assert.equals(allocated, attached)
    assert.equals(allocated, committed)
    assert.equals(parent, vim.b[child].straps_parent)
    started = started + 1
  end }
  ctx = { bufnr = parent }
  controller.begin_family(ctx)
  _G.child_delegation, _G.child_write_body = nil, 0
end)
after_each(function()
  local canonical = vim.uv.fs_realpath(directory)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":h") == canonical then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
  end
  require("straps").config.session_dir = previous_directory
  vim.fn.delete(directory, "rf")
end)
local function run(input)
  local allowed, reason, body = registry.gate_tool("spawn", input or { task = "work", readonly = true }, ctx)
  assert.is_true(allowed, reason)
  return body(ctx)
end

it("attaches exact approved child scope and ceiling before start", function()
  assert.is_true(run())
  assert.equals(1, allocated)
  assert.equals(1, started)
  local childctx = { bufnr = last_child }
  controller.begin_family(childctx)
  local allowed = registry.gate_tool("write", {}, childctx)
  assert.is_false(allowed)
  assert.equals(0, _G.child_write_body)
end)

it("executes two pre-gated shipped spawns without invalidating the second call", function()
  local first_allowed, _, first = registry.gate_tool("spawn", { task = "first", readonly = true }, ctx)
  local second_allowed, _, second = registry.gate_tool("spawn", { task = "second", readonly = true }, ctx)
  assert.is_true(first_allowed)
  assert.is_true(second_allowed)
  assert.is_true(first(ctx))
  local first_child = last_child
  assert.is_true(second(ctx))
  assert.equals(2, allocated)
  assert.equals(2, started)
  assert.is_not.equals(first_child, last_child)
  for _, child in ipairs({ first_child, last_child }) do
    local childctx = { bufnr = child }
    controller.begin_family(childctx)
    assert.is_false(registry.gate_tool("write", {}, childctx))
  end
  assert.equals(0, _G.child_write_body)
end)

it("passes only explicit delegation to attachment", function()
  _G.child_delegation = { targets = {}, effects = {}, capabilities = {}, sources = { "event" } }
  assert.is_true(run({ task = "work", delegation = _G.child_delegation }))
  assert.equals(1, committed)
end)

it("rejects forged family and different exact call before allocation", function()
  assert.has_error(function() bridge.spawn({ task = "work" }, { bufnr = parent }, function() allocated = allocated + 1 end) end)
  registry.define({ name = "tool.spawn", kind = "tool", source = [[return function(input, ctx)
    return require("straps.contextual_children").spawn({ task = "changed" }, ctx, function() error("body executed") end)
  end]] })
  assert.is_false(run({ task = "work" }))
  assert.equals(0, allocated)
end)

it("removes allocated child when attachment fails", function()
  fail_attach = true
  local ok, reason = run()
  assert.is_false(ok)
  assert.matches("injected attachment failure", reason)
  assert.equals(0, started)
  assert.equals(1, discarded)
  assert.equals(1, cancelled_plans)
  assert.is_false(vim.api.nvim_buf_is_valid(last_child))
end)

for _, fails in ipairs({ false, true }) do
  it("cancels a child plan exactly once when no child is allocated and failure is " .. tostring(fails), function()
    _G.child_noallocation = function(input, context)
      return bridge.spawn(input, context, function()
        if fails then error("before construction") end
        return "depth refusal"
      end)
    end
    registry.define({ name = "tool.spawn", kind = "tool", source = "return function(input, context) return _G.child_noallocation(input, context) end" })
    local ok, result = run()
    assert.equals(not fails, ok)
    assert.matches(fails and "before construction" or "depth refusal", result)
    assert.equals(1, cancelled_plans)
    assert.equals(0, discarded)
    assert.equals(0, allocated)
    assert.equals(0, started)
    _G.child_noallocation = nil
  end)
end

it("normalizes an explicit false readonly option without changing delegation", function()
  assert.is_true(run({ task = "work", readonly = false }))
  assert.equals(1, committed)
end)

it("seals trusted installation after first install", function()
  assert.has_error(function() bridge.install({}, {}) end)
end)
