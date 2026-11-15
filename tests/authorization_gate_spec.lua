local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(here, ":p:h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. package.path

local registry, controller, ctx, family, epoch, assessed, invalidated, consumed
local function define(name, source)
  return registry.define({ name = "tool." .. name, kind = "tool", input_schema = { nested = { value = 1 } },
    source = source or "return function(input) return input.value end" })
end
local function setup(assess, consume)
  controller = registry.setup_authorization({
    execution_stamp = function(session) return { session = session, epoch = epoch } end,
    validate_stamp = function(session, stamp) return stamp.session == session and stamp.epoch == epoch, "stale authorization" end,
    assess = assess or function() assessed = assessed + 1 return { decision = "allow" } end,
    invalidate = function() invalidated = invalidated + 1 end,
    consume = consume or function() consumed = consumed + 1 return true end,
  })
  controller.install_ceiling(1, {})
  ctx = { bufnr = 1 }
  family = controller.begin_family(ctx)
end
local function gate(name, input, options)
  return registry.gate_tool(name or "sample", input or { value = 7 }, ctx, options)
end
local function denied_run(run, pattern)
  local ok, reason = run(ctx)
  assert.is_false(ok)
  assert.matches(pattern, reason)
end
local function fresh_registry()
  local source = table.concat(vim.fn.readfile(root .. "/lua/straps/registry.lua"), "\n")
  local changes = {
    resume_cancel = { 'if not current_call then return true, "execution family cancelled" end', '' },
    family_retirement = { 'calls[call_handle] = nil', '' },
    false_consume = { 'if not consumed then used = true invalidate(why) return false, why or "consent unavailable" end', '' },
    failed_retirement = { 'if handle then calls[handle] = nil end', '' },
    success_retirement = { 'calls[handle] = nil', 'local retained_handle = handle' },
    once = { 'if used then error("straps.registry: gate result already used", 0) end', 'if false then error("straps.registry: gate result already used", 0) end' },
    guard = { 'if block then return true, block end', '' },
    ceiling = { 'if not ceiling_ok then return false, why end', '' },
  }
  local change = changes[vim.env.STRAPS_GATE_MUTANT]
  if change then
    local first, last = assert(source:find(change[1], 1, true))
    if vim.env.STRAPS_GATE_MUTANT == "success_retirement" then
      first, last = assert(source:find(change[1], last + 1, true))
    end
    source = source:sub(1, first - 1) .. change[2] .. source:sub(last + 1)
  end
  if vim.env.STRAPS_GATE_MUTANT == "family" then
    local before, after = 'families[ctx] ~= family_handle or ', ''
    local first, last = assert(source:find(before, 1, true))
    source = source:sub(1, first - 1) .. after .. source:sub(last + 1)
  end
  registry = assert(loadstring(source, "@registry-test"))()
  if vim.env.STRAPS_GATE_MUTANT == "narrow" then
    local ceiling_source = table.concat(vim.fn.readfile(root .. "/lua/straps/ceilings.lua"), "\n")
    local before = 'old.identities[key] or (type(category) == "string" and old.allow[category])'
    local first, last = assert(ceiling_source:find(before, 1, true))
    ceiling_source = ceiling_source:sub(1, first - 1) .. 'old.identities[key]' .. ceiling_source:sub(last + 1)
    package.loaded["straps.ceilings"] = assert(loadstring(ceiling_source, "@ceilings-test"))()
  end
  return registry
end
before_each(function()
  local ceiling_mutant = vim.env.STRAPS_CEILING_MUTANT
  if ceiling_mutant and ceiling_mutant ~= "" then
    local source = table.concat(vim.fn.readfile(root .. "/lua/straps/ceilings.lua"), "\n")
    local changes = {
      subset = { 'if not record.allow[category] then return false end', 'if false then return false end' },
      identity = { 'if not vim.deep_equal(candidate, parent_candidate) then return false end', 'if false then return false end' },
      revision = { 'out[#out + 1] = record.revision', 'out[#out + 1] = 0' },
      global_revision = { 'out[#out + 1] = record.revision', 'out[#out + 1] = revision' },
      retirement = { 'if not permits(record, definition, category, input) then', 'if not record.closed and not permits(record, definition, category, input) then' },
      reclaim = { 'records[bufnr] = nil', 'records[bufnr] = record' },
      closed = { 'if not records[bufnr] or records[bufnr].closed then return nil end', 'if not records[bufnr] then return nil end' },
    }
    local change = assert(changes[ceiling_mutant])
    local first, last = assert(source:find(change[1], 1, true))
    package.loaded["straps.ceilings"] = assert(loadstring(source:sub(1, first - 1) .. change[2] .. source:sub(last + 1)))()
  else package.loaded["straps.ceilings"] = nil end
  registry = fresh_registry()
  epoch, assessed, invalidated, consumed = 1, 0, 0, 0
  ctx, controller = nil, nil
  define("sample")
end)

it("checks capability delegation against both ancestor chains and exact tool resolution", function()
  setup()
  controller.classify_ceiling(registry.get("tool.sample").identity, "edit")
  controller.install_ceiling(2, { parent = 1, allow = { "edit" } })
  controller.install_ceiling(3, { parent = 2, allow = { "sample" } })
  assert.is_true(controller.subset_ceiling(2, 3, { "sample" }))
  assert.is_false(controller.subset_ceiling(2, 3, { "edit" }))
  assert.is_false(controller.subset_ceiling(2, 3, { "exec" }))
  assert.is_false(controller.subset_ceiling(1, 3, { "sample" }))
  controller.narrow_ceiling(2, { allow = {} })
  assert.is_false(controller.subset_ceiling(2, 3, { "sample" }))
  registry.ensure_scope(3)
  local previous = registry.set_active_scope(3)
  define("sample")
  registry.set_active_scope(previous)
  assert.is_false(controller.subset_ceiling(2, 3, { "sample" }))
  controller.install_ceiling(4, { parent = 1 })
  registry.ensure_scope(4)
  previous = registry.set_active_scope(4)
  define("sample")
  registry.set_active_scope(previous)
  assert.is_false(controller.subset_ceiling(1, 4, { "sample" }))
end)

it("copies public metadata and never reuses definition identity", function()
  local old = registry.get("tool.sample")
  old.input_schema.nested.value = 9
  assert.equals(1, registry.get("tool.sample").input_schema.nested.value)
  registry.remove("tool.sample")
  local new = define("sample")
  assert.is_true(new.identity > old.identity)
end)

it("freezes legacy execution input and rejects non-data inputs", function()
  local input = { value = 7 }
  local allowed, _, run = registry.gate_tool("sample", input)
  assert.is_true(allowed)
  input.value = 9
  local ok, result = run()
  assert.is_true(ok)
  assert.equals(7, result)
  for _, value in ipairs({ { value = function() end }, setmetatable({}, {}), { value = 0 / 0 } }) do
    assert.is_false(registry.gate_tool("sample", value))
  end
  local cyclic = {} cyclic.self = cyclic
  assert.is_false(registry.gate_tool("sample", cyclic))
  assert.has_error(function() run() end, "straps.registry: gate result already used")
end)

it("rejects detached guard and confirmation mutations", function()
  registry.define({ name = "hook.guard.mutate", kind = "hook", source = [[return function(op, name, input)
    if op == "before" then input.value = 8 end
  end]] })
  assert.is_false(gate())
  registry.remove("hook.guard.mutate")
  assert.is_false(gate(nil, nil, { confirm = function(_, input) input.value = 8 return true end }))
end)

it("retires failed consumption handles and never runs their body", function()
  local handle, bodies = nil, 0
  _G.authorization_consume_body = function() bodies = bodies + 1 end
  define("sample", "return function() return _G.authorization_consume_body() end")
  setup(function(call) handle = call; return { decision = "allow" } end,
    function() consumed = consumed + 1; return false, "receipt rejected" end)
  local allowed, _, run = gate()
  assert.is_true(allowed)
  assert.is_table(controller.describe(handle))
  denied_run(run, "receipt rejected")
  assert.equals(0, bodies)
  assert.equals(1, consumed)
  assert.equals(1, invalidated)
  assert.is_nil(controller.describe(handle))
  assert.has_error(function() run(ctx) end, "straps.registry: gate result already used")
  _G.authorization_consume_body = nil
end)

it("returns denial when a yielding assessment resumes after family cancellation", function()
  local handle
  setup(function(call)
    handle = call
    coroutine.yield("assessment pending")
    return { decision = "allow" }
  end)
  local co = coroutine.create(function() return gate() end)
  local ok, result = coroutine.resume(co)
  assert.is_true(ok)
  assert.equals("assessment pending", result)
  assert.is_table(controller.describe(handle))
  controller.cancel_family(family)
  assert.is_nil(controller.describe(handle))
  local reason
  ok, result, reason = coroutine.resume(co)
  assert.is_true(ok, tostring(result))
  assert.is_false(result)
  assert.is_string(reason)
  assert.equals("dead", coroutine.status(co))
  assert.equals(0, consumed)
end)

it("retires an unexecuted gate handle when its family finishes", function()
  local handle
  setup(function(call) handle = call; return { decision = "allow" } end)
  local allowed, _, run = gate()
  assert.is_true(allowed)
  assert.is_table(controller.describe(handle))
  controller.cancel_family(family)
  assert.is_nil(controller.describe(handle))
  assert.equals(1, invalidated)
  denied_run(run, "cancelled")
  assert.equals(0, consumed)
end)

it("retires successful handles before their closure can execute again", function()
  local handle
  setup(function(call) handle = call; return { decision = "allow" } end)
  local allowed, _, run = gate()
  assert.is_true(allowed)
  assert.is_table(controller.describe(handle))
  assert.same({ true, 7 }, { run(ctx) })
  assert.is_nil(controller.describe(handle))
  assert.has_error(function() run(ctx) end, "straps.registry: gate result already used")
  assert.equals(1, consumed)
end)

it("assesses direct tools independently of confirmation", function()
  setup()
  local allowed, _, run = gate()
  assert.is_true(allowed)
  local ok, result = run(ctx)
  assert.is_true(ok)
  assert.equals(7, result)
  assert.equals(1, assessed)
  assert.equals(1, consumed)
  assert.is_false(registry.gate_tool("sample", {}, { bufnr = 1 }))
end)

it("assesses nested calls and permits registered parallel contexts", function()
  _G.authorization_test_registry = registry
  define("nested", [[return function(input)
    return _G.authorization_test_registry.call("tool.sample", input)
  end]])
  setup()
  local parallel = { bufnr = 1 }
  controller.bind_context(family, parallel)
  local allowed, _, run = registry.gate_tool("nested", { value = 11 }, parallel)
  assert.is_true(allowed)
  local ok, result = run(parallel)
  assert.is_true(ok)
  assert.equals(11, result)
  assert.equals(2, assessed)
  _G.authorization_test_registry = nil
end)

it("rejects revision changes and invalidates the call", function()
  setup()
  local _, _, run = gate()
  epoch = epoch + 1
  denied_run(run, "stale authorization")
  assert.equals(0, consumed)
  assert.equals(1, invalidated)
end)

it("rejects cancellation and changed run contexts", function()
  setup()
  local _, _, run = gate()
  controller.cancel_family(family)
  denied_run(run, "cancelled")
  family = controller.begin_family(ctx)
  local _, _, changed = gate()
  local ok, reason = changed({ bufnr = 1 })
  assert.is_false(ok)
  assert.matches("context changed", reason)
end)

it("rejects original context family reassignment when run omits its argument", function()
  for _, rebind in ipairs({ false, true }) do
    registry = fresh_registry()
    define("sample", "return function() _G.authorization_family_body = true end")
    setup()
    local _, _, run = gate()
    if rebind then
      local other = controller.begin_family({ bufnr = 1 })
      controller.bind_context(other, ctx)
    else
      controller.begin_family(ctx)
    end
    _G.authorization_family_body = false
    local ok, reason = run()
    assert.is_false(ok)
    assert.matches("context changed", reason)
    assert.equals(0, consumed)
    assert.is_false(_G.authorization_family_body)
  end
  _G.authorization_family_body = nil
end)

it("rejects definition replacement and scope shadowing", function()
  setup()
  local _, _, run = gate()
  define("sample")
  denied_run(run, "definition changed")
  local _, _, shadowed = gate()
  registry.define({ name = "tool.sample", kind = "tool", source = "return function() return 99 end" }, { scope = 1 })
  denied_run(shadowed, "definition changed")
end)

it("invalidates assessor mutation", function()
  setup(function(_, description) description.input.value = 9 return { decision = "allow" } end)
  assert.is_false(gate())
  assert.equals(1, invalidated)
end)

it("keeps confirmation additive and consumes only at execution", function()
  setup()
  assert.is_false(gate(nil, nil, { confirm = function() return false, "veto", "hook" end }))
  assert.equals(1, invalidated)
  assert.equals(0, consumed)
  local allowed, _, run = gate()
  assert.is_true(allowed)
  assert.equals(0, consumed)
  assert.is_true(run(ctx))
  assert.equals(1, consumed)
end)

it("refuses false-returning consumption before running the tool body", function()
  local bodies = 0
  _G.gate_failed_consumption_body = function() bodies = bodies + 1 end
  define("sample", "return function() _G.gate_failed_consumption_body() end")
  setup(nil, function() return false, "consent unavailable" end)
  local allowed, _, run = gate()
  assert.is_true(allowed)
  denied_run(run, "consent unavailable")
  assert.equals(0, bodies)
  assert.equals(1, invalidated)
  _G.gate_failed_consumption_body = nil
end)

it("refuses yielding final validators", function()
  setup(nil, function() coroutine.yield() return true end)
  local _, _, run = gate()
  denied_run(run, "must not yield")
  assert.equals(1, invalidated)
end)

it("intersects ancestors and invalidates gates after narrowing", function()
  setup()
  controller.classify_ceiling(registry.get("tool.sample").identity, "edit")
  controller.install_ceiling(2, { parent = 1, allow = { "edit" } })
  ctx = { bufnr = 2 }
  family = controller.begin_family(ctx)
  assert.is_true(gate())
  local _, _, run = gate()
  controller.narrow_ceiling(1, { readonly = true })
  denied_run(run, "ceiling changed")
  assert.is_false(gate())
  assert.has_error(function() controller.narrow_ceiling(1, { allow = { "edit" } }) end, "cannot widen ceiling")
end)

it("keeps unrelated session installs and narrowing from invalidating gated calls", function()
  setup()
  local allowed, _, run = gate()
  assert.is_true(allowed)
  controller.install_ceiling(9, {})
  controller.narrow_ceiling(9, { readonly = true })
  local ok, result = run(ctx)
  assert.is_true(ok)
  assert.equals(7, result)
end)

it("invalidates own ceiling narrowing even when the tool remains permitted", function()
  setup()
  controller.classify_ceiling(registry.get("tool.sample").identity, "read")
  local _, _, run = gate()
  controller.narrow_ceiling(1, { readonly = true })
  denied_run(run, "ceiling changed")
  assert.is_true(gate())
end)

it("retains closed ancestor restrictions until every descendant retires", function()
  local ceilings = require("straps.ceilings").new()
  assert.is_function(ceilings.retire)
  local records
  for index = 1, 20 do
    local name, value = debug.getupvalue(ceilings.install, index)
    if name == "records" then records = value break end
  end
  assert.is_table(records)
  local definition = { name = "tool.write", identity = 700 }
  ceilings.classify(700, "edit")
  ceilings.install(1, { readonly = true })
  ceilings.install(2, { parent = 1 })
  ceilings.install(3, { parent = 2 })
  ceilings.install(4, { parent = 1 })
  local revision = ceilings.revision(3)
  assert.is_true(ceilings.retire(1))
  assert.is_true(ceilings.retire(2))
  assert.is_nil(ceilings.revision(1))
  assert.is_nil(ceilings.revision(2))
  assert.equals(revision, ceilings.revision(3))
  assert.is_false(ceilings.check(3, definition, {}))
  assert.is_false(ceilings.check(1, definition, {}))
  assert.has_error(function() ceilings.install(5, { parent = 1 }) end, "ceiling parent is closed")
  ceilings.install(5, { parent = 3 })
  assert.is_false(ceilings.check(5, definition, {}))
  assert.is_true(ceilings.retire(3))
  assert.is_table(records[1])
  assert.is_table(records[2])
  assert.is_true(ceilings.retire(5))
  assert.is_nil(records[2])
  assert.is_nil(records[3])
  assert.is_nil(records[5])
  assert.is_table(records[1])
  assert.is_true(ceilings.retire(4))
  assert.is_nil(next(records))
  assert.is_false(ceilings.retire(1))
  assert.is_false(ceilings.retire(999))
  assert.is_nil(ceilings.revision(1))
  assert.is_false(ceilings.check(1, definition, {}))
end)

it("invalidates closed-session gates and never reuses reclaimed ceiling revisions", function()
  setup()
  local _, _, run = gate()
  assert.is_function(controller.retire_ceiling)
  assert.is_true(controller.retire_ceiling(1))
  denied_run(run, "ceiling changed")
  local ceilings = require("straps.ceilings").new()
  ceilings.install(1, {})
  local revision = ceilings.revision(1)
  ceilings.retire(1)
  ceilings.install(1, {})
  assert.is_not.equals(revision, ceilings.revision(1))
end)

it("narrows category grants to exact tool identities without allowing replacements", function()
  setup()
  controller.classify_ceiling(registry.get("tool.sample").identity, "edit")
  controller.install_ceiling(2, { parent = 1, allow = { "edit" } })
  controller.narrow_ceiling(2, { allow = { "sample" } })
  local other = define("other")
  controller.classify_ceiling(other.identity, "edit")
  ctx = { bufnr = 2 }
  controller.begin_family(ctx)
  assert.is_true(gate())
  assert.is_false(gate("other"))
  define("sample")
  assert.is_false(gate())
  assert.has_error(function() controller.narrow_ceiling(2, { allow = { "edit" } }) end, "cannot widen ceiling")
end)

it("rejects specific grants derived from input-dependent category permissions", function()
  setup()
  controller.classify_ceiling(registry.get("tool.sample").identity, function(input) return input.write and "edit" or "exec" end)
  controller.install_ceiling(2, { parent = 1, allow = { "edit" } })
  assert.has_error(function() controller.narrow_ceiling(2, { allow = { "sample" } }) end, "cannot widen ceiling")
  ctx = { bufnr = 2 }
  controller.begin_family(ctx)
  assert.is_true(gate(nil, { write = true }))
  assert.is_false(gate(nil, {}))
end)

it("preserves trusted reads, explicit tool grants and parent-message exceptions", function()
  setup()
  local read = define("read_test")
  local message = define("send_message")
  controller.classify_ceiling(read.identity, "read")
  controller.classify_ceiling(message.identity, "spawn")
  controller.install_ceiling(2, { parent = 1, allow = { "sample" } })
  ctx = { bufnr = 2 }
  controller.begin_family(ctx)
  assert.is_true(gate("read_test"))
  assert.is_true(gate())
  assert.is_true(gate("send_message", { to = "parent" }))
  assert.is_false(gate("send_message", { to = "peer" }))
  define("send_message")
  assert.is_false(gate("send_message", { to = "parent" }))
end)

it("exposes detached bindings and invalidates retained handles after veto", function()
  local handle, binding
  setup(function(call, description)
    handle, binding = call, vim.deepcopy(description)
    return { decision = "allow" }
  end)
  local _, _, run = gate()
  local description = controller.describe(handle)
  description.input.value = 99
  assert.equals(7, controller.describe(handle).input.value)
  assert.is_true(controller.validate(handle, binding))
  assert.is_false(controller.validate(handle, description))
  assert.is_true(run(ctx))
  assert.is_false(controller.validate(handle, binding))
  assert.is_false(gate(nil, nil, { confirm = function() return false end }))
  assert.is_false(controller.validate(handle, binding))
end)

it("rejects changed cancellation callbacks and directories", function()
  setup()
  local _, _, run = gate()
  ctx.cancelled = function() return false end
  denied_run(run, "context changed")
  ctx.cancelled = nil
  local _, _, moved = gate()
  local cwd = vim.fn.getcwd()
  vim.cmd.cd(vim.fn.fnamemodify(cwd, ":h"))
  local ok, reason = moved(ctx)
  vim.cmd.cd(cwd)
  assert.is_false(ok)
  assert.matches("directory changed", reason)
end)

it("denies ask assessments without executing", function()
  setup(function() return { decision = "ask" } end)
  assert.is_false(gate())
  assert.equals(0, consumed)
  assert.equals(1, invalidated)
end)

it("keeps public setup closed while private controllers permit trusted callbacks", function()
  _G.authorization_test_registry = registry
  define("setup_attack", [[return function()
    return _G.authorization_test_registry.trusted_setup_allowed()
  end]])
  assert.is_false(registry.call("tool.setup_attack", {}))
  setup()
  _G.authorization_test_controller = controller
  define("narrow_attack", [[return function()
    _G.authorization_test_controller.narrow_ceiling(1, {readonly=true})
  end]])
  local _, _, run = gate("narrow_attack")
  local ok, reason = run(ctx)
  assert.is_true(ok)
  assert.is_nil(reason)
  assert.is_false(gate())
  _G.authorization_test_registry, _G.authorization_test_controller = nil, nil
end)

it("classifies frozen input and keeps watch exceptions bound to definitions", function()
  setup()
  local action = define("code_action")
  local watch, unwatch = define("watch_agent"), define("unwatch_agent")
  controller.classify_ceiling(action.identity, function(input) return input.index and "edit" or "read" end)
  controller.classify_ceiling(watch.identity, "spawn")
  controller.classify_ceiling(unwatch.identity, "spawn")
  controller.install_ceiling(2, { parent = 1, readonly = true })
  ctx = { bufnr = 2 }
  controller.begin_family(ctx)
  assert.is_true(gate("code_action", {}))
  assert.is_false(gate("code_action", { index = 1 }))
  assert.is_true(gate("watch_agent", { to = "peer" }))
  assert.is_true(gate("unwatch_agent", { to = "peer" }))
  define("watch_agent")
  assert.is_false(gate("watch_agent", { to = "peer" }))
end)

it("binds specific grants to caller-scoped definition identities", function()
  setup()
  local scoped = registry.define({ name = "tool.sample", kind = "tool", source = "return function() return 19 end" }, { scope = 1 })
  controller.install_ceiling(2, { parent = 1, allow = { "sample" } }, 1)
  registry.ensure_scope(2, 1)
  ctx = { bufnr = 2 }
  controller.begin_family(ctx)
  assert.is_true(gate())
  local replacement = registry.define({ name = "tool.sample", kind = "tool", source = "return function() end" }, { scope = 2 })
  assert.is_true(replacement.identity > scoped.identity)
  assert.is_false(gate())
end)

it("permits private consent and cancellation callbacks during nested execution", function()
  _G.authorization_test_registry = registry
  local handle, binding
  setup(function(call, description)
    handle, binding = call, vim.deepcopy(description)
    assert.is_true(controller.validate(call, description))
    return { decision = "allow" }
  end)
  _G.authorization_test_callback = function()
    local parallel = { bufnr = 1 }
    controller.bind_context(family, parallel)
    local allowed, _, run = registry.gate_tool("sample", { value = 12 }, parallel)
    assert.is_true(allowed)
    assert.is_true(controller.validate(handle, binding))
    assert.is_true(run(parallel))
    controller.cancel_family(family)
    return true
  end
  define("callback", "return function() return _G.authorization_test_callback() end")
  local _, _, run = gate("callback")
  local ok, result = run(ctx)
  assert.is_true(ok)
  assert.is_true(result)
  assert.is_false(gate())
  _G.authorization_test_callback, _G.authorization_test_registry = nil, nil
end)

it("binds child plans to the live exact call and restores outer nested records", function()
  setup()
  local parent_plan, saved_attach
  _G.authorization_test_child = function(input)
    local options = { task = input.task, readonly = true, relation = "child", focus = false }
    assert.has_error(function() controller.prepare_child("spawn", 1, options) end)
    assert.has_error(function() controller.prepare_child("fork", 2, options) end)
    options.task = "changed"
    assert.has_error(function() controller.prepare_child("fork", 1, options) end)
    options.task = input.task
    parent_plan = controller.prepare_child("fork", 1, options)
    assert.equals(4, registry.call("tool.sample", { value = 4 }))
    saved_attach = controller.prepare_child("fork", 1, options)
    assert.is_true(controller.attach_child(parent_plan, 2))
    assert.has_error(function() controller.attach_child(parent_plan, 3) end)
    return true
  end
  define("fork", "return function(input) return _G.authorization_test_child(input) end")
  local allowed, _, run = gate("fork", { task = "bounded", readonly = true })
  assert.is_true(allowed)
  local ok, result = run(ctx)
  assert.is_true(ok)
  assert.is_true(result)
  assert.has_error(function() controller.attach_child(saved_attach, 3) end)
  assert.has_error(function() controller.prepare_child("fork", 1, {}) end)
  ctx = { bufnr = 2 }
  controller.begin_family(ctx)
  assert.is_false(gate())
  _G.authorization_test_child = nil
end)

it("rejects child creation after cancellation, redefinition and from another tool", function()
  setup()
  local mode
  _G.authorization_test_child = function(input)
    if mode == "cancel" then controller.cancel_family(family) end
    if mode == "replace" then define("spawn") end
    local ok = pcall(controller.prepare_child, "spawn", 1, input)
    return ok
  end
  define("spawn", "return function(input) return _G.authorization_test_child(input) end")
  define("other", "return function(input) return _G.authorization_test_child(input) end")
  local _, _, wrong = gate("other", { task = "bounded" })
  local ok, prepared = wrong(ctx)
  assert.is_true(ok)
  assert.is_false(prepared)
  mode = "replace"
  local _, _, replaced = gate("spawn", { task = "bounded" })
  ok, prepared = replaced(ctx)
  assert.is_true(ok)
  assert.is_false(prepared)
  registry.define({ name = "tool.spawn", kind = "tool",
    source = "return function(input) return _G.authorization_test_child(input) end" }, { scope = 1 })
  mode = "cancel"
  local _, _, cancelled = gate("spawn", { task = "bounded" })
  ok, prepared = cancelled(ctx)
  assert.is_true(ok)
  assert.is_false(prepared)
  _G.authorization_test_child = nil
end)

it("installs spawn child ceilings before returning and grants no raw-name replacements", function()
  setup()
  _G.authorization_test_child = function(input)
    local plan = controller.prepare_child("spawn", 1, input)
    return controller.attach_child(plan, 2)
  end
  define("spawn", "return function(input) return _G.authorization_test_child(input) end")
  local _, _, run = gate("spawn", { task = "bounded", allow = { "sample" } })
  local ok, attached = run(ctx)
  assert.is_true(ok)
  assert.is_true(attached)
  ctx = { bufnr = 2 }
  controller.begin_family(ctx)
  assert.is_true(gate())
  registry.define({ name = "tool.sample", kind = "tool", source = "return function() end" }, { scope = 2 })
  assert.is_false(gate())
  _G.authorization_test_child = nil
end)

it("rejects yielding and mutating trusted input classifiers", function()
  setup()
  local mutating = define("mutating")
  local yielding = define("yielding")
  controller.classify_ceiling(mutating.identity, function(input) input.value = 0 return "read" end)
  controller.classify_ceiling(yielding.identity, function() coroutine.yield() return "read" end)
  assert.is_false(gate("mutating"))
  assert.is_false(gate("yielding"))
end)

it("accepts Neovim empty JSON objects while rejecting arbitrary metatables", function()
  local allowed, _, run = registry.gate_tool("sample", vim.empty_dict())
  assert.is_true(allowed)
  assert.is_true(run())
  assert.is_false(registry.gate_tool("sample", setmetatable({}, { __index = function() end })))
end)

it("rejects setup after session creation", function()
  registry.ensure_scope(1)
  assert.is_false(registry.trusted_setup_allowed())
  assert.has_error(function() registry.setup_authorization({}) end)
end)
