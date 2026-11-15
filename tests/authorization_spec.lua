local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(vim.fn.fnamemodify(here, ":p"), ":h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local auth, core, event, evidence, core_options
local names = { "outcome", "mode", "targets", "effects", "constraints", "reserved_decisions", "latitude", "unresolved_scope" }
local function standing(text)
  return { id = "standing:1", config_hash = "configuration", sources = {
    { id = "standing-source", path = "/AGENTS.md", canonical_path = "/AGENTS.md", hash = "hash", text = text or "No remote writes", precedence = 1 },
  } }
end
local function capture(kind, text, extra)
  local payload = extra or {}
  payload.text = text
  return core.capture(core.prepare_capture(1, kind, payload))
end
local function adopt()
  event = capture("instruction", "Implement local change")
  core.adopt_task(1, { event.id }, standing())
end
local function candidate()
  local snapshot = auth.snapshot(1)
  local spec = { schema_version = 1, task_id = snapshot.task_id, instruction_revision = snapshot.epoch }
  for _, name in ipairs(names) do spec[name] = { value = {}, sources = { event.id } } end
  spec.outcome.value, spec.mode.value = "local change", "implementation"
  spec.targets.value, spec.effects.value = { "project" }, { "write" }
  return spec
end
local function proof()
  return { unsupported_authority = false, untrusted_authority = false, omitted_constraint = false,
    expanded_scope = false, lost_authorization = false, hidden_ambiguity = false }
end
local function publish()
  local ticket
  ticket, evidence = core.begin_synthesis(1)
  return core.publish_spec(ticket, candidate(), proof())
end
local function refuses(fn, text)
  local ok, err = pcall(fn)
  assert.is_false(ok)
  if text then assert.matches(text, tostring(err), 1, true) end
end

it("distinguishes inspectable adopted pending context from executable authority", function()
  local draft = auth.execution_stamp(1)
  assert.is_false(auth.validate_context_stamp(1, draft))
  adopt()
  local pending = auth.execution_stamp(1)
  assert.is_true(auth.validate_context_stamp(1, pending))
  assert.is_false(auth.validate_stamp(1, pending))
  publish()
  assert.is_false(auth.validate_context_stamp(1, pending))
  local active = auth.execution_stamp(1)
  assert.is_true(auth.validate_context_stamp(1, active))
  assert.is_true(auth.validate_stamp(1, active))
  capture("instruction", "new prohibition")
  assert.is_false(auth.validate_context_stamp(1, active))
  auth.suspend(1)
  assert.is_false(auth.validate_context_stamp(1, auth.execution_stamp(1)))
end)

before_each(function()
  package.loaded["straps.authorization"] = nil
  local mutant = vim.env.STRAPS_AUTH_MUTANT
  if mutant then
    local source = table.concat(vim.fn.readfile(root .. "/lua/straps/authorization.lua"), "\n")
    local mutations = {
      release_tickets = { '  retire_tickets(s)\n  s.epoch', '  s.epoch' },
      abandon = { 'synthesis[ticket] = nil\n  return existed', 'return existed' },
      reset_payload = { '  s.events = {}\n  s.task_id', '  s.task_id' },
      close_payload = { '  s.events, s.adopted, s.standing, s.delegation = {}, {}, nil, nil', '' },
      close_listener = { '  listeners[bufnr] = nil', '' },
      child_listener = { '  child.unsubscribe_parent = unsubscribe', '' },
      context_pending = { 's.status ~= "pending"', 'true' },
      execution_pending = { 'if s.status ~= "active" or not s.spec then return false, "authorization unavailable" end', 'if false then return false, "authorization unavailable" end' },
      status = { '(s.status == "suspended" or s.status == "inactive") and s.status or nil', 'nil' },
      callback = { 'function core.adopt_task(bufnr, event_ids, snapshot)', 'function core.adopt_task(bufnr, event_ids, snapshot) trusted()' },
      array = { '  local count = 0\n  for key in pairs(value) do\n    assert(type(key) == "number" and key >= 1 and key % 1 == 0, "invalid array key")\n    count = count + 1\n  end\n  for index = 1, count do assert(value[index] ~= nil, "sparse array") end\n  return count', '  return #value' },
      inactive = { '(s.status == "suspended" or s.status == "inactive") and s.status or nil', 's.status == "suspended" and s.status or nil' },
      bootstrap = { 'function M.install_core(consumer, options)\n  trusted()', 'function M.install_core(consumer, options)' },
      hole = { 'for index = 1, count do assert(value[index] ~= nil, "sparse array") end', '' },
      duplicate = { ' and not seen[item]', '' },
      blank = { ' and item:find("%S")', '' },
      required = { 'assert(not required or count > 0, "nonempty array required")', '' },
      keys = { 'for key in pairs(requested) do assert(keys[key], "unexpected delegation field") end', '' },
      source = { 'assert(available[source_id], "unsupported delegation source")', '' },
      standing = { 'array(result.sources)', '' },
      adoption = { 'strings(selected, true)', '' },
      values = { 'strings(field.value)', '' },
      evidence = { 'strings(field.sources, true)', '' },
      delegated_targets = { 'spec.targets.value, spec.effects.value = copy(delegated.subset.targets), copy(delegated.subset.effects)', 'spec.targets.value, spec.effects.value = copy(parent.spec.targets.value), copy(parent.spec.effects.value)' },
      delegated_constraints = { 'local spec = copy(parent.spec)\n  spec.task_id', 'local spec = copy(parent.spec)\n  spec.constraints.value = {}\n  spec.task_id' },
      delegated_mode = { 'local spec = copy(parent.spec)\n  spec.task_id', 'local spec = copy(parent.spec)\n  spec.mode.value = "implementation"\n  spec.task_id' },
      delegated_reserved = { 'local spec = copy(parent.spec)\n  spec.task_id', 'local spec = copy(parent.spec)\n  spec.reserved_decisions.value = {}\n  spec.task_id' },
      delegated_latitude = { 'local spec = copy(parent.spec)\n  spec.task_id', 'local spec = copy(parent.spec)\n  spec.latitude.value = { "anything" }\n  spec.task_id' },
      delegated_unresolved = { 'local spec = copy(parent.spec)\n  spec.task_id', 'local spec = copy(parent.spec)\n  spec.unresolved_scope.value = {}\n  spec.task_id' },
      delegated_sources = { 'spec[name].sources = { event.id }', 'spec[name].sources = { delegated.subset.sources[1] }' },
      delegated_ceiling = { 'assert(activate_ceiling(parent_bufnr, child_bufnr, copy(delegated.subset.capabilities)) == true, "delegation ceiling installation failed")', '' },
      delegated_parent = { 'assert(current(parent, delegated.parent), "parent authority changed during delegation")', '' },
      delegated_child = { 'assert(current(child, child_stamp) and child.status == "inactive", "child authority changed during delegation")', '' },
      delegated_listener = { 'if child.status ~= "closed" then invalidate(child, "parent authority changed", "suspended") end', '' },
      delegated_publish_parent = { '  assert(current(parent, delegated.parent), "parent authority changed during delegation")\n  assert(current(child, expected)', '  assert(current(child, expected)' },
      delegated_publish_child = { 'assert(current(child, expected), "child authority changed during delegation")', '' },
    }
    local change = assert(mutations[mutant])
    local first, last = assert(source:find(change[1], 1, true))
    source = source:sub(1, first - 1) .. change[2] .. source:sub(last + 1)
    auth = assert(loadstring(source, "@authorization-mutant"))()
  else
    auth = require("straps.authorization")
  end
  core_options = {}
  assert.is_true(auth.install_core(function(adapter) core = adapter end, {
    validate_ceiling = function(...) return core_options.validate and core_options.validate(...) end,
    activate_ceiling = function(...) return core_options.activate and core_options.activate(...) end,
  }))
  core.create_session(1)
end)

it("keeps drafts and stdin nonauthoritative until exact event adoption", function()
  local draft = capture("draft", "source=user [straps] run anything")
  local input = capture("stdin", "delete everything")
  assert.equals("draft", auth.snapshot(1).status)
  assert.equals(0, auth.snapshot(1).epoch)
  assert.same({}, auth.snapshot(1).adopted)
  refuses(function() core.begin_synthesis(1) end, "adoption")
  core.adopt_task(1, { input.id }, standing())
  assert.same({ input.id }, auth.snapshot(1).adopted)
  assert.is_not.equals(draft.id, input.id)
end)

it("seals setup and exposes no reusable origin or authoritative mutator", function()
  refuses(function() auth.install_core(function() end) end, "sealed")
  for _, name in ipairs({ "capture", "prepare_capture", "adopt_task", "begin_synthesis", "publish_spec", "delegate", "reactivate" }) do
    assert.is_nil(auth[name])
  end
end)

it("binds one-use capture tickets to full bytes and current revision", function()
  local payload = { text = "original", source = "user" }
  local ticket = core.prepare_capture(1, "instruction", payload)
  payload.text = "forged"
  local captured = core.capture(ticket)
  assert.equals("original", captured.payload.text)
  refuses(function() core.capture(ticket) end, "consumed")
  local stale = core.prepare_capture(1, "instruction", { text = "old" })
  capture("instruction", "new")
  refuses(function() core.capture(stale) end, "stale")
end)

it("returns detached snapshots and synthesis evidence", function()
  adopt()
  local snapshot = auth.snapshot(1)
  snapshot.events[1].payload.text = "forged"
  snapshot.standing.sources[1].text = "allow remote"
  local _, detached = core.begin_synthesis(1)
  detached.adopted[1] = "forged"
  assert.equals("Implement local change", auth.snapshot(1).events[1].payload.text)
  assert.equals("No remote writes", auth.snapshot(1).standing.sources[1].text)
  assert.same({ event.id }, auth.snapshot(1).adopted)
end)

it("invalidates published authority synchronously before instruction capture returns", function()
  adopt()
  local old = publish()
  local observed
  auth.subscribe(1, function(_, reason)
    observed = { valid = auth.validate_stamp(1, old), reason = reason }
  end)
  capture("instruction", "Do not write")
  assert.is_false(observed.valid)
  assert.equals("instruction captured", observed.reason)
  assert.is_nil(auth.snapshot(1).spec)
  assert.is_false(auth.validate_stamp(1, old))
end)

it("rejects stale synthesis and consumes failed publication tickets", function()
  adopt()
  local stale = core.begin_synthesis(1)
  local spec = candidate()
  capture("instruction", "Do not restart")
  refuses(function() core.publish_spec(stale, spec, proof()) end, "stale")
  local invalid = core.begin_synthesis(1)
  spec = candidate()
  spec.effects.sources = { "assistant-forgery" }
  refuses(function() core.publish_spec(invalid, spec, proof()) end, "source")
  refuses(function() core.publish_spec(invalid, candidate(), proof()) end, "consumed")
  assert.is_nil(auth.snapshot(1).spec)
end)

it("requires complete typed schema and all independent defect checks", function()
  adopt()
  for _, name in ipairs(names) do
    local spec = candidate()
    spec[name] = nil
    refuses(function() core.publish_spec(core.begin_synthesis(1), spec, proof()) end, "field")
  end
  for name in pairs(proof()) do
    local checks = proof()
    checks[name] = true
    refuses(function() core.publish_spec(core.begin_synthesis(1), candidate(), checks) end, "defect")
  end
  local spec = candidate()
  spec.mode.value = "anything"
  refuses(function() core.publish_spec(core.begin_synthesis(1), spec, proof()) end, "mode")
  spec = candidate()
  spec.task_id = "wrong"
  refuses(function() core.publish_spec(core.begin_synthesis(1), spec, proof()) end, "revision")
  local stamp = publish()
  assert.is_true(auth.validate_stamp(1, stamp))
end)

it("publishes detached validated specifications", function()
  adopt()
  local spec, ticket = candidate(), core.begin_synthesis(1)
  local stamp = core.publish_spec(ticket, spec, proof())
  spec.targets.value[1] = "remote"
  assert.same({ "project" }, auth.snapshot(1).spec.targets.value)
  assert.equals(auth.snapshot(1).epoch, stamp.instruction_revision)
  assert.is_true(auth.validate_stamp(1, stamp))
  stamp.epoch = stamp.epoch + 1
  assert.is_false(auth.validate_stamp(1, stamp))
end)

it("suspends on changed standing bytes even with reused snapshot identity", function()
  adopt()
  local old = publish()
  assert.is_true(auth.observe_standing(1, standing()))
  assert.is_false(auth.observe_standing(1, standing("allow everything")))
  assert.equals("suspended", auth.snapshot(1).status)
  assert.is_false(auth.validate_stamp(1, old))
  core.reactivate(1, { event.id }, standing("allow everything"))
  assert.equals("pending", auth.snapshot(1).status)
  assert.is_nil(auth.snapshot(1).spec)
end)

it("stop retains task while invalidating run and synthesis tickets", function()
  adopt()
  local old = publish()
  local before = auth.snapshot(1)
  auth.stop(1)
  assert.is_false(auth.validate_stamp(1, old))
  assert.equals(before.task_id, auth.snapshot(1).task_id)
  assert.equals(before.epoch, auth.snapshot(1).epoch)
  assert.equals("active", auth.snapshot(1).status)
  assert.is_true(auth.validate_stamp(1, auth.execution_stamp(1)))
end)

it("reset changes task identity and never adopts historical events", function()
  adopt()
  local before = publish()
  core.reset_task(1)
  assert.is_not.equals(before.task_id, auth.snapshot(1).task_id)
  assert.same({}, auth.snapshot(1).adopted)
  refuses(function() core.adopt_task(1, { event.id }, standing()) end, "unknown")
  assert.is_false(auth.validate_stamp(1, before))
end)

it("close permanently prevents callback capture and reactivation", function()
  adopt()
  local ticket = core.prepare_capture(1, "instruction", { text = "late" })
  auth.close(1)
  refuses(function() core.capture(ticket) end, "closed")
  refuses(function() core.reactivate(1, { event.id }, standing()) end, "closed")
  assert.equals("closed", auth.snapshot(1).status)
end)

it("captures only final answers with the complete detached proposal", function()
  refuses(function() capture("answer", "Other", { accepted = false, proposal = {} }) end, "proposal")
  local proposal = { question = "Apply?", options = { { label = "yes", preview = "full change" } }, content = "full input" }
  local answer = capture("answer", "yes", { accepted = true, proposal = proposal })
  proposal.options[1].preview = "forged"
  assert.equals("full change", answer.payload.proposal.options[1].preview)
  assert.equals("full input", answer.payload.proposal.content)
end)

it("preserves suspended and inactive adoption requirements across human instructions", function()
  adopt()
  publish()
  auth.observe_standing(1, standing("changed instructions"))
  capture("instruction", "Continue")
  assert.equals("suspended", auth.snapshot(1).status)
  refuses(function() core.begin_synthesis(1) end, "adoption")
  core.reactivate(1, { event.id }, standing("changed instructions"))
  publish()
  core.create_session(2)
  core.delegate(1, 2, { targets = {}, effects = {}, capabilities = {}, sources = { event.id } })
  core.capture(core.prepare_capture(2, "instruction", { text = "Continue child" }))
  assert.equals("inactive", auth.snapshot(2).status)
  refuses(function() core.begin_synthesis(2) end, "adoption")
end)

it("permits private human callbacks during unrelated tool execution but seals bootstrap", function()
  local registry = require("straps.registry")
  local original = registry.any_tool_executing
  registry.any_tool_executing = function() return true end
  local ok, err = pcall(function()
    core.create_session(2)
    adopt()
    publish()
    capture("instruction", "Continue")
    core.adopt_task(1, { event.id }, standing())
    assert.equals("pending", auth.snapshot(1).status)
    refuses(function() auth.install_core(function() end) end, "tool execution")
  end)
  registry.any_tool_executing = original
  assert.is_true(ok, tostring(err))
end)

it("rejects nondense standing source and adoption event arrays", function()
  event = capture("instruction", "Implement local change")
  local source = standing().sources[1]
  for _, sources in ipairs({ { named = source }, { [2] = source }, { source, [3] = source } }) do
    local snapshot = standing()
    snapshot.sources = sources
    refuses(function() core.adopt_task(1, { event.id }, snapshot) end, "array")
  end
  for _, ids in ipairs({ { named = event.id }, { [2] = event.id }, { event.id, [3] = event.id },
    { event.id, event.id }, { "" }, { " " } }) do
    refuses(function() core.adopt_task(1, ids, standing()) end)
  end
  assert.equals("pending", auth.snapshot(1).status)
  assert.is_nil(auth.snapshot(1).standing)
end)

it("rejects malformed specification value and evidence arrays", function()
  adopt()
  for _, key in ipairs({ "value", "sources" }) do
    for _, shape in ipairs({ "named", "hole", "interior", "duplicate", "empty", "blank" }) do
      local spec = candidate()
      local item = key == "sources" and event.id or "project"
      local arrays = { named = { named = item }, hole = { [2] = item }, interior = { item, [3] = item },
        duplicate = { item, item }, empty = { "" }, blank = { " " } }
      spec.targets[key] = arrays[shape]
      refuses(function() core.publish_spec(core.begin_synthesis(1), spec, proof()) end)
    end
  end
  assert.is_nil(auth.snapshot(1).spec)
end)

it("rejects malformed delegation lists and unexpected authority keys", function()
  adopt()
  publish()
  core.create_session(2)
  for _, name in ipairs({ "targets", "effects", "capabilities", "sources" }) do
    for _, shape in ipairs({ "named", "hole", "interior", "duplicate", "empty", "blank" }) do
      local item = ({ targets = "project", effects = "write", capabilities = "exec", sources = event.id })[name]
      local arrays = { named = { named = item }, hole = { [2] = item }, interior = { item, [3] = item },
        duplicate = { item, item }, empty = { "" }, blank = { " " } }
      local subset = { targets = {}, effects = {}, capabilities = {}, sources = { event.id } }
      subset[name] = arrays[shape]
      refuses(function() core.delegate(1, 2, subset) end)
    end
  end
  refuses(function() core.delegate(1, 2, { targets = {}, effects = {}, capabilities = {}, sources = {} }) end)
  refuses(function() core.delegate(1, 2, { targets = {}, effects = {}, capabilities = {}, sources = { "forged" } }) end, "source")
  refuses(function() core.delegate(1, 2, { targets = {}, effects = {}, capabilities = {}, sources = { event.id }, outcome = "remote" }) end, "unexpected")
  assert.is_nil(auth.snapshot(2).delegation)
end)

it("activates a delegated specification with preserved boundaries and trusted child evidence", function()
  adopt()
  local spec = candidate()
  spec.mode.value = "investigation"
  spec.targets.value, spec.effects.value = { "project", "dependency" }, { "read", "write" }
  spec.constraints.value, spec.reserved_decisions.value = { "no remote writes" }, { "restart requires approval" }
  spec.latitude.value, spec.unresolved_scope.value = { "local inspection" }, { "unknown host" }
  core.publish_spec(core.begin_synthesis(1), spec, proof())
  core.create_session(2)
  local installed
  core_options.validate = function() return true end
  core_options.activate = function(parent, child, capabilities)
    installed = { parent, child, capabilities }
    return true
  end
  local subset = { targets = { "project" }, effects = { "read" }, capabilities = { "read_file" }, sources = { event.id } }
  local active = core.activate_delegation(1, 2, subset)
  assert.same({ 1, 2, { "read_file" } }, installed)
  assert.is_true(auth.validate_stamp(2, active))
  local child = auth.snapshot(2)
  assert.equals(child.task_id, child.spec.task_id)
  assert.equals(child.epoch, child.spec.instruction_revision)
  assert.same(subset.targets, child.spec.targets.value)
  assert.same(subset.effects, child.spec.effects.value)
  for _, name in ipairs({ "outcome", "mode", "constraints", "reserved_decisions", "latitude", "unresolved_scope" }) do
    assert.same(spec[name].value, child.spec[name].value)
  end
  local delegated = child.events[1]
  assert.equals("delegation", delegated.kind)
  assert.equals(child.session_id, delegated.session_id)
  assert.same(spec, delegated.payload.specification)
  assert.same(auth.execution_stamp(1), delegated.payload.parent)
  for _, name in ipairs(names) do assert.same({ delegated.id }, child.spec[name].sources) end
  assert.same({ delegated.id }, child.adopted)
  assert.same(standing(), child.standing)
  subset.targets[1] = "remote"
  assert.same({ "project" }, auth.snapshot(2).spec.targets.value)
  capture("instruction", "No reads")
  assert.equals("suspended", auth.snapshot(2).status)
  assert.is_nil(auth.snapshot(2).spec)
  assert.is_false(auth.validate_stamp(2, active))
end)

it("installs the enforceable delegated capability subset before activation", function()
  local registry = assert(loadfile(root .. "/lua/straps/registry.lua"))()
  local write = registry.define({ name = "tool.write", kind = "tool", source = "return function() return true end" })
  local execute = registry.define({ name = "tool.execute", kind = "tool", source = "return function() return true end" })
  local controller = registry.setup_authorization({
    execution_stamp = auth.execution_stamp, validate_stamp = auth.validate_stamp,
    assess = function() return { decision = "allow" } end,
  })
  controller.classify_ceiling(write.identity, "edit")
  controller.classify_ceiling(execute.identity, "exec")
  controller.install_ceiling(1, { allow = { "edit", "exec" } })
  controller.install_ceiling(2, { parent = 1, allow = { "edit", "exec" } })
  controller.install_ceiling(3, { parent = 1, allow = { "edit", "exec" } })
  registry.ensure_scope(2, 1)
  registry.ensure_scope(3, 1)
  adopt()
  publish()
  core.create_session(2)
  core.create_session(3)
  core_options.validate = function() return true end
  core_options.activate = function(_, child, capabilities)
    assert.equals("inactive", auth.snapshot(child).status)
    controller.narrow_ceiling(child, { allow = capabilities })
    return true
  end
  core.activate_delegation(1, 2, { targets = { "project" }, effects = { "write" }, capabilities = { "write" }, sources = { event.id } })
  local context = { bufnr = 2 }
  controller.begin_family(context)
  local allowed, _, run = registry.gate_tool("write", {}, context)
  assert.is_true(allowed)
  assert.is_true(run())
  assert.is_false(registry.gate_tool("execute", {}, context))
  core.activate_delegation(1, 3, { targets = {}, effects = {}, capabilities = {}, sources = { event.id } })
  context = { bufnr = 3 }
  controller.begin_family(context)
  assert.is_false(registry.gate_tool("write", {}, context))
  assert.is_false(registry.gate_tool("execute", {}, context))
end)

it("requires installation even for empty capabilities and never activates after installer failure or revision changes", function()
  adopt()
  publish()
  local subset = { targets = {}, effects = {}, capabilities = {}, sources = { event.id } }
  for child = 2, 4 do core.create_session(child) end
  refuses(function() core.activate_delegation(1, 2, subset) end, "installation failed")
  assert.equals("inactive", auth.snapshot(2).status)
  assert.is_nil(auth.snapshot(2).spec)
  core_options.activate = function(_, _, capabilities)
    assert.same({}, capabilities)
    capture("instruction", "No delegated work")
    return true
  end
  refuses(function() core.activate_delegation(1, 3, subset) end, "parent authority changed")
  assert.equals("suspended", auth.snapshot(3).status)
  assert.is_nil(auth.snapshot(3).spec)
  publish()
  core_options.activate = function(_, child)
    auth.suspend(child)
    return true
  end
  refuses(function() core.activate_delegation(1, 4, subset) end, "child authority changed")
  assert.is_nil(auth.snapshot(4).spec)
end)

it("refuses parent and child changes from delegation activation notification callbacks", function()
  for _, change_parent in ipairs({ true, false }) do
    adopt()
    publish()
    local child = change_parent and 2 or 3
    core.create_session(child)
    core_options.activate = function() return true end
    auth.subscribe(child, function(_, reason)
      if reason == "delegation activated" then
        if change_parent then capture("instruction", "Revoke delegation") else auth.suspend(child) end
      end
    end)
    refuses(function()
      core.activate_delegation(1, child, { targets = {}, effects = {}, capabilities = {}, sources = { event.id } })
    end, change_parent and "parent authority changed" or "child authority changed")
    assert.equals("suspended", auth.snapshot(child).status)
    assert.is_nil(auth.snapshot(child).spec)
    assert.is_false(auth.validate_stamp(child, auth.execution_stamp(child)))
  end
end)

it("releases synthesis tickets and old task payloads at lifecycle boundaries", function()
  adopt()
  local ticket = core.begin_synthesis(1)
  assert.is_true(core.abandon_synthesis(ticket))
  assert.is_false(core.abandon_synthesis(ticket))
  refuses(function() core.publish_spec(ticket, candidate(), proof()) end, "consumed")
  local stale = core.begin_synthesis(1)
  auth.stop(1)
  assert.is_false(core.abandon_synthesis(stale))
  local instruction_stale = core.begin_synthesis(1)
  capture("instruction", "new revision invalidates retained synthesis")
  assert.is_false(core.abandon_synthesis(instruction_stale))
  local reset = core.begin_synthesis(1)
  core.reset_task(1)
  assert.is_false(core.abandon_synthesis(reset))
  assert.same({}, auth.snapshot(1).events)
  adopt()
  auth.close(1)
  local closed = auth.snapshot(1)
  assert.same({}, closed.events)
  assert.same({}, closed.adopted)
  assert.is_nil(closed.standing)
  assert.is_nil(closed.spec)
  assert.is_nil(closed.delegation)
end)

it("removes closed child delegation subscriptions without dropping live child invalidation", function()
  adopt()
  publish()
  core.create_session(2)
  core.delegate(1, 2, { targets = {}, effects = {}, capabilities = {}, sources = { event.id } })
  local function upvalue(fn, name)
    for index = 1, 40 do
      local key, value = debug.getupvalue(fn, index)
      if key == name then return value end
      if key == nil then break end
    end
    error("missing upvalue " .. name)
  end
  local subscriptions = upvalue(auth.subscribe, "listeners")
  assert.is_not_nil(next(subscriptions[1]))
  auth.close(2)
  assert.is_nil(next(subscriptions[1]))
  local calls = 0
  auth.subscribe(1, function() calls = calls + 1 end)
  auth.close(1)
  assert.equals(1, calls)
  assert.is_nil(subscriptions[1])
end)

it("records only exact delegation subsets without activating copied task authority", function()
  adopt()
  publish()
  core.create_session(2)
  refuses(function() core.delegate(1, 2, { targets = { "remote" }, effects = {}, capabilities = {}, sources = { event.id } }) end, "expands")
  refuses(function() core.delegate(1, 2, { targets = {}, effects = {}, capabilities = { "exec" }, sources = { event.id } }) end, "ceiling")
  local record = core.delegate(1, 2, { targets = { "project" }, effects = { "write" }, capabilities = {}, sources = { event.id } })
  record.subset.targets[1] = "remote"
  assert.same({ "project" }, auth.snapshot(2).delegation.subset.targets)
  assert.equals("inactive", auth.snapshot(2).status)
  assert.is_false(auth.validate_stamp(2, auth.execution_stamp(2)))
  capture("instruction", "No writes")
  assert.equals("suspended", auth.snapshot(2).status)
end)
