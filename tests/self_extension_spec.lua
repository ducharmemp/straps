local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(here, ":p:h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local checks = 0
local invert = tonumber(vim.env.STRAPS_EXTENSION_INVERT)
local function check(condition, message)
  checks = checks + 1
  if checks == invert then condition = not condition end
  assert(condition, ("extension check %d: %s"):format(checks, message))
end
local registry, ctx, prompts, answer, original_confirm, buffers
local function definition(name, kind, scope)
  return { name = name or "tool.extension_probe", kind = kind or "tool", scope = scope,
    source = '_G.extension_compiled = _G.extension_compiled + 1; return function() _G.extension_called = _G.extension_called + 1; return "executed" end' }
end
local function session(parent)
  local bufnr = vim.api.nvim_create_buf(false, true)
  buffers[#buffers + 1] = bufnr
  registry.ensure_scope(bufnr, parent)
  return { bufnr = bufnr }
end
local function gate(name, input, context)
  return registry.gate_tool(name, input, context or ctx, { confirm = function(n, i, c)
    return registry.call("hook.confirm", n, i, c)
  end })
end
local function execute(name, input, context)
  local allowed, reason, body = gate(name, input, context)
  check(allowed == true, "gate allows " .. name .. ": " .. tostring(reason))
  local ok, result = body(context or ctx)
  check(ok == true, "body executes " .. name .. ": " .. tostring(result))
  return result
end
local function classify(input)
  return registry.call("fn.capability", "registry_define", input)
end
before_each(function()
  package.loaded["straps.registry"] = nil
  registry = require("straps.registry")
  require("straps.tools").register()
  buffers, prompts, answer = {}, {}, 2
  ctx = nil
  _G.extension_compiled, _G.extension_called = 0, 0
  original_confirm = vim.fn.confirm
  vim.fn.confirm = function(message, choices)
    prompts[#prompts + 1] = { message = message, choices = choices }
    return answer
  end
end)
after_each(function()
  vim.fn.confirm = original_confirm
  registry.set_active_scope(nil)
  for _, bufnr in ipairs(buffers) do
    if vim.api.nvim_buf_is_valid(bufnr) then vim.api.nvim_buf_delete(bufnr, { force = true }) end
  end
  _G.extension_compiled, _G.extension_called = nil, nil
end)
teardown(function() print("STRAPS_EXTENSION_CHECKS=" .. checks) end)

it("classifies session definitions without compiling or invoking their source", function()
  for _, kind in ipairs({ "tool", "hook", "fn" }) do
    for _, scope in ipairs({ "default", "session" }) do
      local input = definition(kind .. ".extension_probe", kind, scope == "session" and scope or nil)
      check(classify(input) == "lua", kind .. " session definition is Lua")
    end
  end
  check(classify({ name = "skill.extension_probe", kind = "skill", source = "prose" }) == "read", "session skill is read")
  check(_G.extension_compiled == 0, "classification does not compile source")
  check(_G.extension_called == 0, "classification does not invoke source")
end)

it("allows Lua definitions, revisions, and builtin shadows without prompts", function()
  ctx = session()
  registry.grant(ctx.bufnr, "cap:lua")
  for _, name in ipairs({ "tool.extension_probe", "tool.extension_probe", "tool.read_file" }) do
    execute("registry_define", definition(name))
    check(execute(name:sub(6), {}) == "executed", "session tool returns result")
  end
  check(_G.extension_compiled == 3, "each approved definition compiles once")
  check(_G.extension_called == 3, "each approved tool executes once")
  check(#prompts == 0, "Lua grant covers definitions and invocation")
end)

it("executes approved hook and function definitions and stores skills as text", function()
  ctx = session()
  registry.grant(ctx.bufnr, "cap:lua")
  for _, kind in ipairs({ "hook", "fn" }) do
    execute("registry_define", definition(kind .. ".extension_probe", kind))
    registry.set_active_scope(ctx.bufnr)
    check(registry.call(kind .. ".extension_probe") == "executed", kind .. " definition is callable")
    registry.set_active_scope(nil)
  end
  registry.clear_grants(ctx.bufnr)
  local skill = definition("skill.extension_probe", "skill")
  execute("registry_define", skill)
  registry.set_active_scope(ctx.bufnr)
  check(registry.get(skill.name).source == skill.source, "skill retains literal source text")
  registry.set_active_scope(nil)
  check(_G.extension_compiled == 2, "skill text does not execute its chunk")
  check(_G.extension_called == 2, "hook and function execute once each")
  check(#prompts == 0, "Lua hooks/functions and ungranted session skills need no prompt")
end)

it("does not authorize a protected registry tool shadow through Lua or a name grant", function()
  ctx = session()
  registry.define(definition("tool.registry_define"), { scope = ctx.bufnr })
  registry.grant(ctx.bufnr, "cap:lua")
  registry.set_active_scope(ctx.bufnr)
  registry.grant(ctx.bufnr, registry.tool_grant_key("registry_define"))
  registry.set_active_scope(nil)
  check(gate("registry_define", definition()) == false, "protected shadow cannot use Lua or identity grant")
  check(prompts[1].choices == "&Yes\n&No", "protected shadow offers only one-call consent")
  check(_G.extension_called == 0, "protected shadow denial prevents execution")
end)

it("prompts separately for manual definition and invocation", function()
  ctx, answer = session(), 1
  execute("registry_define", definition())
  check(#prompts == 1, "manual definition prompts")
  check(prompts[1].choices == "&Yes\n&No", "definition has no Always choice")
  check(_G.extension_compiled == 1, "approved definition executes its chunk")
  check(_G.extension_called == 0, "definition does not invoke returned function")
  check(execute("extension_probe", {}) == "executed", "manual invocation succeeds")
  check(#prompts == 2, "invocation asks separate consent")
  execute("registry_define", definition())
  check(#prompts == 3, "manual definition consent is not retained")
end)

it("denies exec-only definitions and invocation without running their bodies", function()
  ctx = session()
  registry.grant(ctx.bufnr, "cap:exec")
  check(gate("registry_define", definition()) == false, "exec does not grant definition")
  check(_G.extension_compiled == 0, "denied definition has no compile side effects")
  registry.define(definition(), { scope = ctx.bufnr })
  check(gate("extension_probe", {}) == false, "exec does not grant invocation")
  check(_G.extension_called == 0, "denied invocation has no side effects")
  check(#prompts == 2, "exec-only calls still prompt")
end)

it("keeps global and protected definitions behind individual consent", function()
  ctx = session()
  registry.grant(ctx.bufnr, "cap:lua")
  local requests = { definition("tool.extension_global", "tool", "global"),
    { name = "skill.extension_global", kind = "skill", scope = "global", source = "prose" } }
  for _, name in ipairs({ "hook.confirm", "fn.capability", "fn.readonly_policy", "tool.registry_define", "hook.guard", "hook.guard.extension" }) do
    requests[#requests + 1] = definition(name, name:match("^[^.]+"))
  end
  for _, input in ipairs(requests) do
    check(classify(input) == "define", input.name .. " requires define consent")
    check(gate("registry_define", input) == false, input.name .. " cannot use Lua grant")
    check(prompts[#prompts].choices == "&Yes\n&No", input.name .. " has no Always choice")
  end
  check(_G.extension_compiled == 0, "protected/global denied chunks never execute")
  answer = 1
  execute("registry_define", requests[1])
  check(_G.extension_compiled == 1, "approved global definition executes")
  answer = 2
  check(gate("extension_global", {}) == false, "unknown global tool cannot use Lua grant")
  check(_G.extension_called == 0, "global invocation denial prevents body")
end)

it("rejects malformed definition classification and definition name-grant bypass", function()
  ctx = session()
  registry.grant(ctx.bufnr, "cap:lua")
  for _, input in ipairs({ false, {}, { name = "tool.x", kind = "tool" }, definition("tool.bad.name"),
    definition("fn.x", "tool"), definition("tool.x", "tool", "invalid"), definition("tool.x", "invalid") }) do
    check(classify(input) == "define", "malformed input stays define")
    check(gate("registry_define", input) == false, "malformed input prompts and denies")
  end
  check(classify(nil) == "define", "missing input stays define")
  check(gate("registry_define", nil) == false, "missing input prompts and denies")
  registry.clear_grants(ctx.bufnr)
  registry.grant(ctx.bufnr, registry.tool_grant_key("registry_define"))
  check(gate("registry_define", definition()) == false, "tool-name grant cannot bypass definition consent")
  answer = 3
  check(gate("registry_define", definition()) == false, "unoffered Always response does not grant definition")
  check(_G.extension_compiled == 0, "malformed and denied definitions do not compile")
end)

local function contextual_controller()
  local controller = registry.setup_authorization({ assess = function() return { decision = "allow" } end,
    execution_stamp = function(bufnr) return { session = bufnr } end, validate_stamp = function() return true end })
  local setup = require("straps.contextual").setup
  local mapping
  for index = 1, 100 do
    local name, value = debug.getupvalue(setup, index)
    if not name then break end
    if name == "classify_defaults" then mapping = value break end
  end
  check(type(mapping) == "function", "production contextual classification helper is present")
  mapping(registry, controller)
  return controller
end
local function contextual_session(controller, spec, parent)
  local context = session(parent)
  spec = vim.deepcopy(spec or {})
  spec.parent = parent
  controller.install_ceiling(context.bufnr, spec)
  controller.begin_family(context)
  return context
end
local function contextual_execute(context, name, input)
  local allowed, reason, body = registry.gate_tool(name, input, context)
  check(allowed == true, "contextual gate allows " .. name .. ": " .. tostring(reason))
  local ok, result = body(context)
  check(ok == true, "contextual execution succeeds: " .. tostring(result))
  return result
end

it("rejects a contextual registry_define name grant", function()
  local controller = contextual_controller()
  local ok = pcall(contextual_session, controller, { allow = { "registry_define" } })
  check(ok == false, "contextual registry_define name grant is rejected")
  check(_G.extension_compiled == 0, "rejected name grant never compiles source")
end)

it("uses production contextual identity classification for Lua and readonly skills", function()
  local controller = contextual_controller()
  ctx = contextual_session(controller, { allow = { "lua" } })
  contextual_execute(ctx, "registry_define", definition())
  check(contextual_execute(ctx, "extension_probe", {}) == "executed", "contextual session tool runs")
  contextual_execute(ctx, "registry_define", definition())
  check(contextual_execute(ctx, "extension_probe", {}) == "executed", "contextual revised tool runs")
  local readonly = contextual_session(controller, { readonly = true })
  contextual_execute(readonly, "registry_define", { name = "skill.extension_probe", kind = "skill", source = "prose" })
  check(registry.gate_tool("registry_define", definition(), readonly) == false, "readonly denies executable definition")
  check(_G.extension_compiled == 2, "readonly denial never compiles")
  check(#prompts == 0, "contextual controller does not invoke legacy prompts")
end)

it("applies inherited tools and every ancestor ceiling", function()
  local controller = contextual_controller()
  local parent = contextual_session(controller, { allow = { "lua" } })
  contextual_execute(parent, "registry_define", definition())
  local child = contextual_session(controller, { allow = { "lua" } }, parent.bufnr)
  check(contextual_execute(child, "extension_probe", {}) == "executed", "Lua child invokes inherited tool")
  contextual_execute(child, "registry_define", definition("tool.child_probe"))
  check(contextual_execute(child, "child_probe", {}) == "executed", "Lua child defines and invokes tool")
  for _, spec in ipairs({ { readonly = true }, { allow = { "exec" } } }) do
    local denied = contextual_session(controller, spec, parent.bufnr)
    check(registry.gate_tool("extension_probe", {}, denied) == false, "restricted child denies inherited Lua invocation")
    check(registry.gate_tool("registry_define", definition(), denied) == false, "restricted child denies Lua definition")
    local descendant = contextual_session(controller, { allow = { "lua" } }, denied.bufnr)
    check(registry.gate_tool("extension_probe", {}, descendant) == false, "descendant cannot bypass ancestor restriction")
  end
  check(_G.extension_called == 2, "only permitted children execute")
end)

it("delegates and narrows a Lua ceiling to a session tool identity", function()
  local controller = contextual_controller()
  local parent = contextual_session(controller, { allow = { "lua" } })
  contextual_execute(parent, "registry_define", definition())
  local child = contextual_session(controller, { allow = { "lua" } }, parent.bufnr)
  check(controller.subset_ceiling(parent.bufnr, child.bufnr, { "extension_probe" }) == true, "Lua parent permits session tool-name subset")
  controller.narrow_ceiling(child.bufnr, { allow = { "extension_probe" } })
  check(contextual_execute(child, "extension_probe", {}) == "executed", "narrowed child invokes selected identity")
  check(registry.gate_tool("registry_define", definition("tool.other_probe"), child) == false, "narrowed child cannot define more tools")
  local allowed, _, body = registry.gate_tool("extension_probe", {}, child)
  check(allowed == true, "old identity is admitted before revision")
  contextual_execute(parent, "registry_define", definition())
  local ok, reason = body(child)
  check(ok == false, "revision invalidates admitted old identity")
  check(tostring(reason):find("tool definition changed", 1, true) ~= nil, "stale call reports identity change")
  check(registry.gate_tool("extension_probe", {}, child) == false, "identity grant does not authorize revision")
  check(_G.extension_called == 1, "changed identity never executes")
end)

it("denies contextual global, protected, missing-input and shadowed registry definitions", function()
  local controller = contextual_controller()
  ctx = contextual_session(controller, { allow = { "lua", "exec" } })
  for _, input in ipairs({ definition("tool.extension_global", "tool", "global"), definition("hook.confirm", "hook"),
    definition("fn.capability", "fn"), definition("fn.readonly_policy", "fn"), definition("tool.registry_define"),
    definition("hook.guard.extension", "hook") }) do
    check(registry.gate_tool("registry_define", input, ctx) == false, "contextual protected/global request denied")
  end
  check(registry.gate_tool("registry_define", nil, ctx) == false, "contextual missing input denied")
  registry.define(definition("tool.extension_global"), { scope = "global" })
  check(registry.gate_tool("extension_global", {}, ctx) == false, "unclassified global identity denied")
  registry.define(definition("tool.registry_define"), { scope = ctx.bufnr })
  check(registry.gate_tool("registry_define", definition(), ctx) == false, "protected shadow does not inherit trusted definition classification")
  check(_G.extension_called == 0, "protected and global denied bodies never execute")
end)
