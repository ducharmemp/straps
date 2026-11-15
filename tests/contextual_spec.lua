local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(here, ":p:h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. package.path

local contextual, registry, auth, adapters, config, screens, consent_screens, factories, assessed, enqueued, facts, composition
local fields = { "outcome", "mode", "targets", "effects", "constraints", "reserved_decisions", "latitude", "unresolved_scope" }
local standing
local function spec(snapshot)
  local result = { schema_version = 1, task_id = snapshot.task_id, instruction_revision = snapshot.epoch }
  for _, name in ipairs(fields) do result[name] = { value = {}, sources = { snapshot.adopted[1] } } end
  result.outcome.value, result.mode.value = "local work", "implementation"
  return result, { unsupported_authority = false, untrusted_authority = false, omitted_constraint = false,
    expanded_scope = false, lost_authorization = false, hidden_ambiguity = false }
end
local policy
local function boot(disclosure)
  config.disclosure = { approved = disclosure == true }
  contextual.setup(config)
  adapters.human.create(1)
end
local function submit()
  adapters.human.submit(1, "local work", function() enqueued = enqueued + 1 end)
end
local function adopt()
  submit()
  screens[#screens].answer(true)
end
local function gate()
  local ctx = { bufnr = 1 }
  local family = adapters.loop.begin(ctx)
  local allowed, reason, run = registry.gate_tool("sample", { value = 7 }, ctx)
  return allowed, reason, run, ctx, family
end
before_each(function()
  for _, name in ipairs({ "contextual", "registry", "authorization", "consent" }) do package.loaded["straps." .. name] = nil end
  local mutant = vim.env.STRAPS_CONTEXTUAL_MUTANT
  local registry_mutations = {
    registry_bytes = { 'if #item > limits.max_bytes then', 'if false then',
      'if bytes > limits.max_bytes then', 'if false then' },
    registry_depth = { 'depth > limits.max_depth', 'false' },
    registry_items = { 'items > limits.max_items', 'false' },
  }
  local change = registry_mutations[mutant]
  if change then
    local source = table.concat(vim.fn.readfile(root .. "/lua/straps/registry.lua"), "\n")
    for index = 1, #change, 2 do
      local first, last = source:find(change[index], 1, true)
      assert(first, "registry mutation site missing")
      source = source:sub(1, first - 1) .. change[index + 1] .. source:sub(last + 1)
    end
    package.loaded["straps.registry"] = assert(loadstring(source, "@" .. root .. "/lua/straps/registry.lua"))()
  end
  registry, auth = require("straps.registry"), require("straps.authorization")
  registry.define({ name = "tool.sample", kind = "tool", source = "return function(input) return input.value end" })
  adapters, screens, consent_screens = {}, {}, {}
  factories, assessed, enqueued, facts, composition = 0, 0, 0, "original", "composer"
  standing = { id = "standing", config_hash = "config", sources = {} }
  policy = { decision = "allow", reasons = { { code = "covered" } }, effects = { "read" }, source_ids = { "source" } }
  config = { enabled = true, limits = { max_bytes = 1048576, max_depth = 32, max_items = 10000 }, receipts = {
      identity = function() return composition end,
      validate = function() return true end,
      prepare_adoption = function(bufnr, opts, scope)
        assert.is_nil(opts)
        assert.equals(bufnr, scope)
        return { transcript = "exact legacy transcript", options = { subagent = false }, composition = composition },
          { composition = composition }
      end,
      adopt = function(token, validate_current)
        return token.composition == composition and validate_current() == true
      end,
      commit = function(token, scope) return token.scope == scope end,
    },
    run_human = function(bufnr, fn)
      local ctx = { bufnr = bufnr, cancelled = function() return false end }
      local co = coroutine.create(function() fn(ctx) end)
      local ok, why = coroutine.resume(co)
      assert(ok, why)
      assert.equals("dead", coroutine.status(co))
    end,
    discover = function() return vim.deepcopy(standing) end,
    adopt = function(view, answer) screens[#screens + 1] = { view = view, answer = answer } end,
    consent_display = function(view, answer) consent_screens[#consent_screens + 1] = { view = view, answer = answer } end,
    resolve_targets = function() return { known = { cwd = facts }, unresolved = {}, checks = { "cwd" } } end,
    validate_targets = function(record) return record.known.cwd == facts end,
    assessor_factory = function()
      factories = factories + 1
      return { synthesize = spec, assess = function() assessed = assessed + 1 return vim.deepcopy(policy) end }
    end,
    install = {},
  }
  for _, name in ipairs({ "human", "loop", "questions", "children" }) do
    local key = name
    config.install[key] = function(adapter) adapters[key] = adapter end
  end
  if mutant and mutant ~= "" and not registry_mutations[mutant] then
    local mutations = {
      classifications = { '  classify_defaults(registry, controller)', '' },
      default_identity = { 'for _, definition in ipairs(registry.trusted_default_tools()) do',
        'for _, definition in ipairs((function() local out = {} for _, name in ipairs(registry.names("tool")) do out[#out + 1] = registry.get(name) end return out end)()) do' },
      input_variants = { 'categories["tool.fix_diagnostic"] = categories["tool.code_action"]',
        'categories["tool.fix_diagnostic"] = "read"' },
      bounds = { 'input_limits = copy(config.limits)', 'input_limits = nil' },
      question_retirement = { 'for ticket, pending in pairs(question_tickets) do if pending.bufnr == bufnr then question_tickets[ticket] = nil end end', '' },
      pending_execution = { 'if not active and not record.human_override then return false, unavailable end', 'if not active then return false, unavailable end' },
      pending_auto = { 'record.policy_allow = record.assessment.outcome == "allow"', 'record.policy_allow = true' },
      live_retirement = { 'records[handle] = nil\n      return true', 'return true' },
      reset_retirement = { 'for key, record in pairs(records) do\n      if record.binding.session == bufnr then records[key] = nil end\n    end', '' },
      subscription_retirement = { 'if reason ~= "stopped" then', 'if false then' },
      adoption_owner = { 'if expected and pending ~= expected then return end', '' },
      synthesis_abandon = { 'if not spec then core.abandon_synthesis(ticket); return false, checks end', 'if not spec then return false, checks end' },
      rollback = { 'loop.close(child)', '' },
      disclosure = { 'if not config.disclosure or config.disclosure.approved ~= true then', 'if false then' },
      targets = { 'if target_ok ~= true then', 'if false then' },
      composition = { 'if identity == nil or not vim.deep_equal(identity, compositions[bufnr]) then', 'if false then' },
      consume = { 'if record.consent_required then', 'if true then' },
      capture = { 'core.capture(ticket)', 'if false then core.capture(ticket) end' },
      adoption = { 'if not vim.deep_equal(standing, immediate(discover)) then return false end', 'if false then return false end' },
      receipt_failure = { 'if valid ~= true then return false end', 'if false then return false end' },
      adoption_events = { 'vim.deep_equal(snapshot.events, now.events)', 'true' },
      adoption_reentrant = { 'or not displayed_current(freshctx) then return false end', 'then return false end' },
      child_commit = { 'if receipt_token ~= nil or subset then assert(committed, "child prompt receipt commit failed") end', 'if false then assert(committed) end' },
      pending_consumption = { 'if record.consent_required then', 'if record.consent_required and not record.human_override then' },
      override = { 'record.human_override = true', 'record.human_override = false' },
      discard = { 'if type(receipts.discard_adoption) == "function" then pcall(receipts.discard_adoption, pending.token) end', '' },
      terminal = { 'record.terminal = true; record.reason = reason', 'record.reason = reason' },
      inspect_id = { 'if type(id) ~= "number" or id < 1 or id > 9007199254740991 or id % 1 ~= 0 then return nil end', 'id = tonumber(id)' },
      submit_stamp = { 'local captured = authorization.execution_stamp(bufnr)\n    config.run_human(bufnr, function(freshctx) continue_submission(bufnr, freshctx, enqueue, captured) end)',
        'config.run_human(bufnr, function(freshctx) continue_submission(bufnr, freshctx, enqueue, authorization.execution_stamp(bufnr)) end)' },
      question_stamp = { 'or not vim.deep_equal(pending.stamp, authorization.execution_stamp(pending.bufnr)) then', 'then' },
      question_once = { 'question_tickets[question_ticket] = nil', 'local unused_ticket = question_ticket' },
      replay_once = { 'record.replay_started = true', 'record.replay_started = false' },
      replay_busy = { 'if accepted == false and not used then record.replay_started = nil end', '' },
      replay_unknown = { 'if accepted == false and not used then', 'if not used then' },
      captured_selection = { 'selection = copy(selection), accepted = true', 'selection = { kind = "free_text" }, accepted = true' },
      selection_validation = { 'if not valid_selection then resolve(); return false, "invalid answer selection" end', '' },
      resolver_override = { 'return human_override == true, "material target facts unavailable"', 'return false, "material target facts unavailable"' },
    }
    local change = assert(mutations[mutant], "unknown behavioral mutation")
    local source = table.concat(vim.fn.readfile(root .. "/lua/straps/contextual.lua"), "\n")
    local first, last = source:find(change[1], 1, true)
    assert(first, "mutation site missing")
    if mutant == "question_retirement" then
      local again, finish = source:find(change[1], last + 1, true)
      assert(again, "second question retirement site missing")
      source = source:sub(1, again - 1) .. change[2] .. source:sub(finish + 1)
    end
    contextual = assert(loadstring(source:sub(1, first - 1) .. change[2] .. source:sub(last + 1)))()
  else contextual = require("straps.contextual") end
end)

local function production_defaults()
  require("straps.tools").register()
  require("straps.editor").register()
end

local function production_gate(name, input, bufnr, confirmation)
  local ctx = { bufnr = bufnr or 1, await = function(fn)
    local result
    fn(function(value) result = value end)
    assert.is_true(vim.wait(5000, function() return result ~= nil end, 5))
    return result
  end }
  adapters.loop.begin(ctx)
  local allowed, reason, run = registry.gate_tool(name, input, ctx, { confirm = confirmation or false })
  return allowed, reason, run, ctx
end

it("executes shipped reads and exec under real restricted ceilings and retains ordinary vetoes", function()
  production_defaults()
  config.disclosure = { approved = true }
  contextual.setup(config)
  adapters.human.create(1, { ceiling = { allow = { "exec", "edit", "spawn" } } })
  adopt()
  local allowed, reason, run, ctx = production_gate("bash", { command = "printf contextual-production" })
  assert.is_true(allowed, tostring(reason))
  local ok, output = run(ctx)
  assert.is_true(ok, tostring(output))
  assert.matches("contextual%-production", output)
  assert.matches("exit code: 0", output)
  assert.is_false(production_gate("bash", { command = "printf vetoed" }, 1, function() return false end))
  local path = vim.fn.tempname()
  allowed, reason, run, ctx = production_gate("write_file", { path = path, content = "production-ceiling" })
  assert.is_true(allowed, tostring(reason))
  assert.is_true(run(ctx))
  assert.same({ "production-ceiling" }, vim.fn.readfile(path))
  registry.define({ name = "fn.capability", kind = "fn", source = 'return function() return "read" end' })
  adapters.human.create(2, { ceiling = { readonly = true } })
  local previous = registry.set_active_scope(2)
  adapters.human.submit(2, "read project", function() end)
  screens[#screens].answer(true)
  registry.set_active_scope(previous)
  allowed, reason, run, ctx = production_gate("read_file", { path = path }, 2)
  assert.is_true(allowed, tostring(reason))
  ok, output = run(ctx)
  assert.is_true(ok, tostring(output))
  assert.matches("production%-ceiling", output)
  for _, case in ipairs({ { "code_action", {} }, { "fix_diagnostic", {} }, { "undo_edit", { history = true } },
      { "transcript_excise", {} } }) do
    assert.is_true(production_gate(case[1], case[2], 2))
  end
  for _, case in ipairs({ { "code_action", { index = 1 } }, { "fix_diagnostic", { index = 1 } },
      { "undo_edit", {} }, { "transcript_excise", { blocks = { 1 } } }, { "bash", { command = "true" } },
      { "write_file", { path = path, content = "denied" } } }) do
    assert.is_false(production_gate(case[1], case[2], 2))
  end
  vim.fn.delete(path)
end)

it("does not classify preexisting replacements or later global and scoped definitions as shipped", function()
  registry.define({ name = "tool.read_file", kind = "tool", capability = "read", source = 'return function() return "replacement" end' })
  production_defaults()
  config.disclosure = { approved = true }
  contextual.setup(config)
  adapters.human.create(1, { ceiling = { readonly = true } })
  adopt()
  assert.is_false(production_gate("read_file", {}))
  assert.is_true(production_gate("glob", { pattern = "*.lua" }))
  registry.define({ name = "tool.glob", kind = "tool", capability = "read", source = 'return function() return "replacement" end' })
  require("straps.layers.search").register()
  assert.is_false(production_gate("glob", {}))
  registry.define({ name = "tool.path_info", kind = "tool", capability = "read", source = 'return function() return "shadow" end' }, { scope = 1 })
  assert.is_false(production_gate("path_info", {}))
  registry.define({ name = "tool.unknown", kind = "tool", capability = "read", source = 'return function() return "unknown" end' })
  assert.is_false(production_gate("unknown", {}))
end)

it("spawns a shipped child from a restricted parent and executes its delegated exec capability", function()
  production_defaults()
  package.loaded["straps.contextual_children"] = nil
  local bridge = require("straps.contextual_children")
  local original_loop, child = package.loaded["straps.loop"]
  package.loaded["straps.loop"] = { start = function(bufnr) child = bufnr end }
  config.install.children = function(adapter)
    adapters.children = adapter
    bridge.install(adapter, { receipts = { construct = function()
      return vim.api.nvim_create_buf(false, true), { scope = "child" }
    end } })
  end
  config.receipts.commit = function(_, scope) return type(scope) == "number" end
  registry.define({ name = "fn.system_prompt", kind = "fn", source = 'return function() return "PROMPT" end' })
  registry.define({ name = "fn.spawn_depth_limit", kind = "fn", source = 'return function() return 4 end' })
  config.disclosure = { approved = true }
  contextual.setup(config)
  adapters.human.create(1, { ceiling = { allow = { "spawn", "exec", "edit" } } })
  adopt()
  local subset = { targets = {}, effects = {}, capabilities = { "exec" }, sources = { auth.snapshot(1).adopted[1] } }
  local allowed, reason, run, ctx = production_gate("spawn", { task = "execute local command", allow = { "exec" }, delegation = subset })
  assert.is_true(allowed, tostring(reason))
  local ok, output = run(ctx)
  package.loaded["straps.loop"] = original_loop
  assert.is_true(ok, tostring(output))
  assert.is_number(child)
  assert.equals("active", auth.snapshot(child).status)
  assert.same({ "exec" }, auth.snapshot(child).delegation.subset.capabilities)
  allowed, reason, run, ctx = production_gate("bash", { command = "printf delegated-production" }, child)
  assert.is_true(allowed, tostring(reason))
  ok, output = run(ctx)
  assert.is_true(ok, tostring(output))
  assert.matches("delegated%-production", output)
  assert.is_false(production_gate("write_file", { path = vim.fn.tempname(), content = "denied" }, child))
end)

it("adopts an unattested legacy transcript through regeneration and captures the new identity", function()
  local regenerated, valid = 0, false
  config.receipts.identity = function() return valid and "regenerated" or nil end
  config.receipts.validate = function() return valid end
  config.receipts.adopt = function(_, validate_current)
    if not validate_current() then return false end
    regenerated, valid = regenerated + 1, true
    return true
  end
  boot(true)
  submit()
  assert.equals("exact legacy transcript", screens[1].view.transcript)
  assert.same({ subagent = false }, screens[1].view.options)
  assert.same(auth.execution_stamp(1), screens[1].view.stamp)
  assert.same(auth.snapshot(1).events, screens[1].view.events)
  assert.equals(0, regenerated)
  screens[1].answer(true)
  assert.equals(1, regenerated)
  assert.equals("active", contextual.status(1).status)
  assert.equals(1, enqueued)
  assert.is_true(gate())
end)

it("never grants task authority when private receipt adoption fails", function()
  config.receipts.adopt = function() return false, "receipt failed" end
  boot(true)
  adopt()
  assert.is_nil(auth.snapshot(1).standing)
  assert.same({}, auth.snapshot(1).adopted)
  assert.equals(0, factories)
  assert.equals(0, enqueued)
end)

it("rejects a changed displayed event set even when the stamp is unchanged", function()
  boot(true)
  submit()
  local original = auth.snapshot
  auth.snapshot = function(bufnr)
    local value = original(bufnr)
    value.events[1].payload.text = "different displayed task"
    return value
  end
  screens[1].answer(true)
  auth.snapshot = original
  assert.same({}, auth.snapshot(1).adopted)
  assert.equals(0, enqueued)
end)

it("rechecks task state after reentrant receipt validation before adopting", function()
  config.receipts.adopt = function(_, validate_current)
    assert.is_true(validate_current())
    adapters.human.submit(1, "reentrant new instruction", function() end)
    return true
  end
  boot(true)
  adopt()
  assert.same({}, auth.snapshot(1).adopted)
  assert.equals(0, enqueued)
end)

it("fresh registration never prepares or commits a receipt", function()
  local prepared, committed = 0, 0
  config.receipts.prepare_adoption = function() prepared = prepared + 1 end
  config.receipts.commit = function() committed = committed + 1 end
  boot(true)
  assert.equals(0, prepared)
  assert.equals(0, committed)
  assert.same({}, auth.snapshot(1).adopted)
end)

it("keeps capabilities private and never constructs an undisclosed assessor", function()
  boot(false)
  assert.is_nil(contextual.core)
  assert.is_nil(contextual.controller)
  assert.is_nil(contextual.adapters)
  assert.equals("draft", contextual.status(1).status)
  adopt()
  assert.equals(0, factories)
  assert.equals(1, enqueued)
  assert.equals("pending", contextual.status(1).status)
  assert.is_false(gate())
end)

it("never executes a pending adopted task even if a defective assessor allows it", function()
  config.assessor_factory = function()
    return { synthesize = function() return nil, "synthesis unavailable" end,
      assess = function() return { decision = "allow" } end }
  end
  boot(true)
  adopt()
  local pending = auth.execution_stamp(1)
  assert.equals("pending", pending.status)
  assert.is_nil(auth.snapshot(1).spec)
  local allowed, _, run, ctx = gate()
  assert.is_true(allowed)
  local executed, reason = run(ctx)
  assert.is_false(executed)
  assert.equals("authorization unavailable", reason)
end)

it("captures exact human bytes before enqueue and binds adoption to current standing", function()
  boot(true)
  submit()
  assert.equals(0, enqueued)
  assert.equals("local work", screens[1].view.events[1].payload.text)
  assert.same(standing, screens[1].view.standing)
  standing.id = "changed"
  screens[1].answer(true)
  assert.equals(0, factories)
  assert.equals(0, enqueued)
  assert.is_nil(auth.snapshot(1).spec)
  assert.same({}, auth.snapshot(1).adopted)
end)

it("consumes ordinary policy allow without requiring a consent record", function()
  boot(true)
  adopt()
  local allowed, _, run, ctx = gate()
  assert.is_true(allowed)
  assert.equals(1, assessed)
  assert.equals(0, #consent_screens)
  local ok, result = run(ctx)
  assert.is_true(ok)
  assert.equals(7, result)
  assert.has_error(function() run(ctx) end)
end)

it("invalidates execution for changed targets and prompt composition", function()
  boot(true)
  adopt()
  local allowed, _, run, ctx = gate()
  assert.is_true(allowed)
  facts = "changed"
  assert.is_false(run(ctx))
  facts = "original"
  allowed, _, run, ctx = gate()
  assert.is_true(allowed)
  composition = "other"
  assert.is_false(run(ctx))
  assert.equals("suspended", contextual.status(1).status)
end)

it("retains task on stop and changes task on reset", function()
  boot(true)
  adopt()
  local task = contextual.status(1).task_id
  local allowed, _, run, ctx = gate()
  assert.is_true(allowed)
  adapters.loop.stop(1)
  assert.equals(task, contextual.status(1).task_id)
  assert.is_false(run(ctx))
  adapters.human.reset(1)
  assert.is_not.equals(task, contextual.status(1).task_id)
  assert.equals("draft", contextual.status(1).status)
end)

it("preserves all decision details in detached denial inspection without prompting", function()
  boot(true)
  adopt()
  policy = { decision = "deny", reasons = { { code = "prohibited", detail = "no restart" } }, effects = { "restart" },
    source_ids = { "instruction" }, decision_identity = { boundary = "restart", targets = { "host" }, effects = { "restart" } } }
  assert.is_false(gate())
  assert.equals(0, #consent_screens)
  local descriptor = adapters.human.inspect(1)
  assert.equals("prohibited", descriptor.assessment.reasons[1].code)
  assert.same({ "instruction" }, descriptor.assessment.source_ids)
  assert.same(policy.decision_identity, descriptor.assessment.decision)
  descriptor.binding.input.value = 99
  assert.equals(7, adapters.human.inspect(1).binding.input.value)
  assert.is_true(adapters.human.inspect(1).terminal)
  for _, id in ipairs({ "1", "0", 0, -1, 1.5, math.huge, 0 / 0, 9007199254740992, {}, true }) do
    assert.is_nil(adapters.human.inspect(id))
  end
end)

it("unknown material targets remain unassessed without provider assessment", function()
  config.resolve_targets = function() return { known = {}, unresolved = { "host" }, checks = {} } end
  boot(true)
  adopt()
  assert.is_false(gate())
  assert.equals(0, assessed)
  assert.is_false(adapters.human.inspect(1).execution_started)
end)

it("stale adoption callbacks cannot adopt newer instructions or revive a stopped run", function()
  boot(true)
  submit()
  local first = screens[1]
  submit()
  first.answer(true)
  assert.equals(0, enqueued)
  adapters.loop.stop(1)
  screens[2].answer(true)
  assert.equals(0, enqueued)
  assert.equals(0, factories)
end)

it("first adoption rejection grants nothing and replay remains inspect-only without a trusted loop", function()
  boot(true)
  submit()
  screens[1].answer(false)
  assert.equals(0, factories)
  assert.equals(0, enqueued)
  screens[1].answer(true)
  assert.equals(0, factories)
  submit()
  screens[2].answer(true)
  policy.decision = "deny"
  local _, _, _, ctx = gate()
  local allowed, reason = adapters.human.reopen(1, ctx)
  assert.is_false(allowed)
  assert.equals("replay unavailable; inspection only", reason)
end)

it("legacy sessions and public loop context cannot acquire authority", function()
  boot(true)
  adapters.human.create(2, { resume = true })
  assert.equals("suspended", contextual.status(2).status)
  local ctx = { bufnr = 2, source = "user" }
  adapters.loop.begin(ctx)
  assert.is_false(registry.gate_tool("sample", {}, ctx))
  assert.equals(0, #auth.snapshot(2).events)
end)

local function delayed_scheduler()
  local jobs = {}
  config.run_human = function(bufnr, fn)
    local ctx = { bufnr = bufnr, cancelled = function() return false end }
    local co = coroutine.create(function() fn(ctx) end)
    local function resume(...)
      local ok, why = coroutine.resume(co, ...)
      assert(ok, why)
    end
    ctx.await = function(register)
      return coroutine.yield(register)
    end
    jobs[#jobs + 1] = { ctx = ctx, co = co, resume = resume }
    resume()
  end
  return jobs
end

it("captures synchronously and suppresses stale or cancelled synthesis enqueue", function()
  local jobs = delayed_scheduler()
  config.assessor_factory = function()
    return { synthesize = function(snapshot, ctx)
      ctx.await(function() end)
      return spec(snapshot)
    end, assess = function() return policy end }
  end
  boot(true)
  adopt()
  assert.equals("pending", contextual.status(1).status)
  assert.equals(0, enqueued)
  adapters.human.submit(1, "new exact instruction", function() enqueued = enqueued + 1 end)
  assert.equals("new exact instruction", auth.snapshot(1).events[2].payload.text)
  jobs[1].resume()
  assert.equals(0, enqueued)
  assert.is_nil(auth.snapshot(1).spec)
  jobs[2].ctx.cancelled = function() return true end
  jobs[2].resume()
  assert.equals(0, enqueued)
  assert.is_nil(auth.snapshot(1).spec)
end)

it("never schedules an older submission with a newer submission stamp", function()
  local jobs, queued = {}, {}
  config.run_human = function(bufnr, fn)
    jobs[#jobs + 1] = function() fn({ bufnr = bufnr, cancelled = function() return false end }) end
  end
  boot(true)
  adopt()
  jobs[1]()
  assert.equals(1, enqueued)
  adapters.human.submit(1, "older submission", function() queued[#queued + 1] = "older" end)
  adapters.human.submit(1, "newer submission", function() queued[#queued + 1] = "newer" end)
  jobs[2]()
  assert.same({}, queued)
  assert.equals("pending", contextual.status(1).status)
  jobs[3]()
  assert.same({ "newer" }, queued)
  assert.equals("active", contextual.status(1).status)
end)

it("publishes pending to active and enqueues once after an awaited synthesis", function()
  local jobs = delayed_scheduler()
  config.assessor_factory = function()
    return { synthesize = function(snapshot, ctx) ctx.await(function() end); return spec(snapshot) end }
  end
  boot(true)
  adopt()
  assert.equals(0, enqueued)
  jobs[1].resume()
  assert.equals("active", contextual.status(1).status)
  assert.equals(1, enqueued)
  screens[1].answer(true)
  assert.equals(1, #jobs)
end)

it("resolves question before fresh scheduled synthesis and captures exact proposal", function()
  local resolved, seenctx = false, nil
  config.assessor_factory = function()
    return { synthesize = function(snapshot, ctx)
      if #snapshot.events > 1 then assert.is_true(resolved); seenctx = ctx end
      return spec(snapshot)
    end }
  end
  boot(true)
  adopt()
  local order = {}
  local proposal = { question = "Restart?", options = { "yes", "no" }, content = "complete" }
  local questionctx = { bufnr = 1 }
  local ticket = adapters.questions.prepare(1, proposal, questionctx)
  proposal.content = "mutated caller view"
  adapters.questions.answer(ticket, "yes", function()
    order[#order + 1] = "resolved"
    resolved = true
    assert.equals("answer", auth.snapshot(1).events[2].kind)
  end, questionctx)
  assert.same({ "resolved" }, order)
  proposal.content = "complete"
  assert.same(proposal, auth.snapshot(1).events[2].payload.proposal)
  assert.equals(1, seenctx.bufnr)
  assert.equals("active", contextual.status(1).status)
end)

it("rejects stale and reused question tickets without capturing answers", function()
  boot(true)
  adopt()
  local ctx, resolved = { bufnr = 1 }, 0
  local ticket = adapters.questions.prepare(1, { question = "old question", options = {} }, ctx)
  adapters.human.submit(1, "new task instruction", function() end)
  assert.is_false(adapters.questions.answer(ticket, "yes", function() resolved = resolved + 1 end, ctx))
  assert.equals(2, #auth.snapshot(1).events)
  assert.equals(1, resolved)
  local original = auth.execution_stamp
  local captured = original(1)
  ticket = adapters.questions.prepare(1, { question = "current question", options = {} }, ctx)
  auth.execution_stamp = function() return vim.deepcopy(captured) end
  assert.is_true(adapters.questions.answer(ticket, "yes", function() end, ctx))
  assert.is_false(adapters.questions.answer(ticket, "yes again", function() end, ctx))
  auth.execution_stamp = original
  assert.equals(3, #auth.snapshot(1).events)
end)

it("finishes one family without stopping another or changing the task stamp", function()
  boot(true)
  adopt()
  local a, b = { bufnr = 1 }, { bufnr = 1 }
  local family = adapters.loop.begin(a)
  adapters.loop.begin(b)
  local stamp = auth.execution_stamp(1)
  local allowed, _, run = registry.gate_tool("sample", { value = 7 }, a)
  assert.is_true(allowed)
  assert.is_true(adapters.loop.finish(family))
  assert.is_false(run(a))
  assert.is_true(registry.gate_tool("sample", { value = 7 }, b))
  assert.same(stamp, auth.execution_stamp(1))
  assert.is_false(adapters.loop.finish(family))
end)

it("keeps unattested and mismatched persisted prompts unavailable without aborting setup", function()
  config.receipts.identity = function() return nil end
  config.receipts.validate = nil
  boot(true)
  adopt()
  assert.equals(0, factories)
  assert.equals(0, enqueued)
  assert.is_nil(auth.snapshot(1).spec)
end)

it("binds composition identity to each session and validates persisted prompt at execution", function()
  local sessions, valid = {}, true
  config.receipts.identity = function(bufnr) sessions[bufnr] = true; return "composer-" .. bufnr end
  config.receipts.validate = function() return valid end
  boot(true)
  adopt()
  local allowed, _, run, ctx = gate()
  assert.is_true(allowed)
  valid = false
  assert.is_false(run(ctx))
  assert.is_true(sessions[1])
  assert.is_nil(sessions[2])
end)

it("denial reopen rejects newer task revisions and changed original targets", function()
  local replays = 0
  config.replay = function() replays = replays + 1 end
  boot(true)
  adopt()
  policy.decision = "deny"
  local _, _, _, ctx = gate()
  facts = "changed"
  assert.is_false(adapters.human.reopen(1, ctx))
  facts = "original"
  adapters.human.submit(1, "new instruction", function() end)
  assert.is_false(adapters.human.reopen(1, ctx))
  assert.equals(0, replays)
end)

it("reopens only the exact semantic decision through a new normal-confirm family", function()
  local replayctx, confirmed, gate_result, changing = nil, 0, nil, false
  config.consent_display = function(_, answer) answer("once") end
  config.replay = function(_, oldctx, fresh_gate)
    replayctx = { bufnr = oldctx.bufnr }
    adapters.loop.begin(replayctx)
    if changing then policy.decision_identity.boundary = "other" end
    local allowed, reason, run = fresh_gate(function() confirmed = confirmed + 1; return true end, replayctx)
    gate_result = allowed
    if allowed then return run(replayctx) end
    return allowed, reason
  end
  boot(true)
  adopt()
  policy = { decision = "deny", decision_identity = { boundary = "restart", targets = { "host" }, effects = { "restart" } } }
  local _, _, _, ctx = gate()
  local ok, result = adapters.human.reopen(1, ctx)
  assert.is_true(ok)
  assert.equals(7, result)
  assert.is_true(gate_result)
  assert.equals(1, confirmed)
  assert.is_not.equals(ctx, replayctx)
  local denied = adapters.human.inspect(1)
  assert.is_false(denied.execution_started)
  assert.is_true(adapters.human.inspect(2).execution_started)
  local _, _, _, again = gate()
  changing = true
  assert.is_false(adapters.human.reopen(3, again))
  assert.equals(1, confirmed)
  assert.equals(0, #consent_screens)
end)

for _, refusal in ipairs({ "busy", "unknown", "throw" }) do
  it("preserves reopen only for definite preadmission " .. refusal, function()
    local attempts = 0
    config.replay = function()
      attempts = attempts + 1
      if refusal == "busy" then return false, "actor busy" end
      if refusal == "throw" then error("scheduler failed") end
    end
    boot(true)
    adopt()
    policy = { decision = "deny" }
    local _, _, _, ctx = gate()
    local ok, accepted = pcall(adapters.human.reopen, 1, ctx)
    assert.equals(refusal ~= "throw", ok)
    if refusal == "busy" then assert.is_false(accepted) end
    assert.is_false(adapters.human.reopen(1, ctx))
    assert.equals(refusal == "busy" and 2 or 1, attempts)
  end)
end

it("validates typed answer identity before capturing authority", function()
  boot(true)
  local proposal = { question = "Which?", options = { { label = "Apply", preview = "exact original" } } }
  local ctx = { bufnr = 1 }
  local invalid = {
    { kind = "option", index = 0, option = proposal.options[1] },
    { kind = "option", index = 1.5, option = proposal.options[1] },
    { kind = "option", index = math.huge, option = proposal.options[1] },
    { kind = "option", index = 1, option = { label = "Apply", preview = "forged" } },
    { kind = "free_text", option = proposal.options[1] },
    { kind = "unrecognized" },
  }
  for _, selection in ipairs(invalid) do
    local ticket = adapters.questions.prepare(1, proposal, ctx)
    local resolved = false
    assert.is_false(adapters.questions.answer(ticket, "Apply", function() resolved = true end, ctx, selection))
    assert.is_true(resolved)
    assert.equals(0, #auth.snapshot(1).events)
  end
  local ticket = adapters.questions.prepare(1, proposal, ctx)
  assert.is_false(adapters.questions.answer(ticket, "different label", function() end, ctx,
    { kind = "option", index = 1, option = proposal.options[1] }))
  assert.equals(0, #auth.snapshot(1).events)
  local selection = { kind = "option", index = 1, option = vim.deepcopy(proposal.options[1]) }
  ticket = adapters.questions.prepare(1, proposal, ctx)
  assert.is_true(adapters.questions.answer(ticket, "Apply", function() end, ctx, selection))
  assert.same(selection, auth.snapshot(1).events[1].payload.selection)
  selection.option.preview = "mutated after capture"
  assert.equals("exact original", auth.snapshot(1).events[1].payload.selection.option.preview)
end)

for _, choice in ipairs({ "reject", "once" }) do
  local answer_choice = choice
  it("consumes the original denial reopen after " .. (choice == "reject" and "rejection" or "a later confirmation veto"), function()
    local replays, confirmations, bodies = 0, 0, 0
    _G.contextual_replay_body = function() bodies = bodies + 1; return 7 end
    registry.define({ name = "tool.sample", kind = "tool", source = "return function() return _G.contextual_replay_body() end" })
    config.consent_display = function(_, answer) answer(answer_choice) end
    config.replay = function(_, oldctx, fresh_gate)
      replays = replays + 1
      local freshctx = { bufnr = oldctx.bufnr }
      adapters.loop.begin(freshctx)
      return fresh_gate(function() confirmations = confirmations + 1; return false end, freshctx)
    end
    boot(true)
    adopt()
    policy = { decision = "deny", decision_identity = { boundary = "restart", targets = { "host" }, effects = { "restart" } } }
    local _, _, _, ctx = gate()
    assert.is_false(adapters.human.reopen(1, ctx))
    assert.equals(1, replays)
    assert.equals(answer_choice == "reject" and 0 or 1, confirmations)
    assert.is_false(adapters.human.reopen(1, ctx))
    assert.equals(1, replays)
    assert.equals(answer_choice == "reject" and 0 or 1, confirmations)
    assert.equals(0, bodies)
    _G.contextual_replay_body = nil
  end)
end

for _, scenario in ipairs({ "hard denial", "missing disclosure", "failed synthesis", "unresolved targets",
  "resolver absent", "resolver throw", "resolver malformed", "resolver unavailable" }) do
  it("offers informed exact override for " .. scenario .. " without granting automatic authority", function()
    local confirmed, bodies, shown = 0, 0, nil
    local consumed = 0
    local consent_module = require("straps.consent")
    local connect = consent_module.connect
    consent_module.connect = function(options)
      local result = connect(options)
      local consume = result.consume
      result.consume = function(handle)
        consumed = consumed + 1
        return consume(handle)
      end
      return result
    end
    _G.contextual_override_body = function() bodies = bodies + 1; return 7 end
    registry.define({ name = "tool.sample", kind = "tool", source = "return function() return _G.contextual_override_body() end" })
    config.consent_display = function(view, answer) shown = view; answer("once") end
    config.replay = function(_, oldctx, fresh_gate)
      local freshctx = { bufnr = oldctx.bufnr }
      adapters.loop.begin(freshctx)
      local allowed, reason, run = fresh_gate(function() confirmed = confirmed + 1; return true end, freshctx)
      if not allowed then return false, reason end
      return run(freshctx)
    end
    if scenario == "failed synthesis" then
      config.assessor_factory = function()
        return { synthesize = function() return nil, "synthesis unavailable" end,
          assess = function() return { decision = "deny", failure = "unassessed task" } end }
      end
    elseif scenario == "unresolved targets" then
      config.resolve_targets = function() return { known = { cwd = facts }, unresolved = { "unknown executable" }, checks = {} } end
    elseif scenario == "resolver absent" then config.resolve_targets = nil
    elseif scenario == "resolver throw" then config.resolve_targets = function() error("resolver failed") end
    elseif scenario == "resolver malformed" then config.resolve_targets = function() return { known = false } end
    elseif scenario == "resolver unavailable" then config.resolve_targets = function() return nil, "offline" end
    end
    boot(scenario ~= "missing disclosure")
    adopt()
    if scenario == "hard denial" then
      local classifier_root = vim.fn.fnamemodify(root, ":h") .. "/straps-classifier"
      package.path = classifier_root .. "/lua/?.lua;" .. package.path
      local decide = assert(loadfile(classifier_root .. "/lua/straps_classifier/authorization.lua"))()
      local questions = require("straps_classifier.contextual_questions")
      local assessment = { status = "assessed", context_valid = true, capability_allowed = true,
        source_ids = { "instruction" }, checks = {}, effects = { { id = "restart", kind = "restart", target = "host",
          coverage = { score = 1, explanation = "requested restart", source_ids = { "instruction" } } } } }
      for _, id in ipairs(questions.authorization_ids()) do
        assessment.checks[id] = { score = 0, explanation = id, source_ids = { "instruction" } }
      end
      assessment.checks.task_connection.score, assessment.checks.authorization_coverage.score = 1, 1
      assessment.checks.violates_constraint.score = 1
      policy = decide.decide(assessment, { positive_threshold = 0.9, conflict_threshold = 0.8 })
      assert.equals("deny", policy.decision)
    end
    local allowed, _, _, ctx, family = gate()
    assert.is_false(allowed)
    assert.is_true(adapters.loop.finish(family))
    assert.equals(0, bodies)
    assert.is_nil(shown)
    local ok, result = adapters.human.reopen(1, ctx)
    assert.is_true(ok, tostring(result))
    assert.equals(7, result)
    assert.equals(1, bodies)
    assert.equals(1, confirmed)
    assert.equals(1, consumed)
    assert.same({ value = 7 }, shown.binding.input)
    if scenario == "missing disclosure" or scenario == "failed synthesis" then
      assert.equals("pending", auth.snapshot(1).status)
      assert.is_nil(auth.snapshot(1).spec)
      assert.is_string(shown.assessment.failure)
    elseif scenario == "hard denial" then
      local conflict = false
      for _, reason in ipairs(shown.assessment.reasons) do if reason.code == "violates_constraint" then conflict = true end end
      assert.is_true(conflict)
    elseif scenario == "unresolved targets" then
      assert.same({ "unknown executable" }, shown.assessment.uncertainty.unresolved)
    else
      assert.is_string(shown.assessment.uncertainty.unavailable)
      assert.is_true(#shown.assessment.uncertainty.unresolved > 0)
      assert.equals(0, assessed)
      assert.same({ value = 7 }, shown.assessment.uncertainty.binding.input)
    end
    assert.is_false(adapters.human.reopen(1, ctx))
    assert.equals(1, bodies)
    _G.contextual_override_body = nil
  end)
end

for _, bound in ipairs({
  { name = "bytes", limits = { max_bytes = 64, max_depth = 32, max_items = 10000 },
    input = { value = string.rep("x", 65) } },
  { name = "depth", limits = { max_bytes = 1048576, max_depth = 4, max_items = 10000 },
    input = { value = { a = { b = { c = { d = true } } } } } },
  { name = "items", limits = { max_bytes = 1048576, max_depth = 32, max_items = 8 },
    input = { value = { 1, 2, 3, 4, 5, 6, 7, 8, 9 } } },
}) do
  it("rejects configured input " .. bound.name .. " bound before assessment and record retention", function()
    config.limits = bound.limits
    boot(true)
    adopt()
    local ctx = { bufnr = 1 }
    adapters.loop.begin(ctx)
    local allowed, reason = registry.gate_tool("sample", bound.input, ctx)
    assert.is_false(allowed)
    assert.is_string(reason)
    assert.equals(0, assessed)
    assert.is_nil(adapters.human.inspect(1))
  end)
end

it("releases live coordinator handles after execution", function()
  boot(true)
  adopt()
  local allowed, _, run, ctx = gate()
  assert.is_true(allowed)
  local records
  for index = 1, 20 do
    local name, value = debug.getupvalue(adapters.human.inspect, index)
    if not name then break end
    if name == "records" then records = value end
  end
  assert.is_table(records)
  local handles = 0
  for key in pairs(records) do if type(key) == "table" then handles = handles + 1 end end
  assert.equals(1, handles)
  assert.same({ true, 7 }, { run(ctx) })
  handles = 0
  for key in pairs(records) do if type(key) == "table" then handles = handles + 1 end end
  assert.equals(0, handles)
  assert.is_true(adapters.human.inspect(1).terminal)
  assert.is_true(adapters.human.inspect(1).execution_started)
end)

it("abandons failed synthesis tickets without publishing an active task", function()
  local ticket, core
  local install = auth.install_core
  auth.install_core = function(callback, options)
    return install(function(value)
      core = value
      local begin = core.begin_synthesis
      core.begin_synthesis = function(...)
        local snapshot
        ticket, snapshot = begin(...)
        return ticket, snapshot
      end
      callback(value)
    end, options)
  end
  config.assessor_factory = function()
    return { synthesize = function() return nil, "failed synthesis" end }
  end
  boot(true)
  adopt()
  assert.is_table(ticket)
  assert.is_false(core.abandon_synthesis(ticket))
  assert.equals("pending", auth.snapshot(1).status)
  assert.is_nil(auth.snapshot(1).spec)
end)

it("releases question payloads on close before their late answer", function()
  boot(true)
  adopt()
  local ctx = { bufnr = 1 }
  local ticket = adapters.questions.prepare(1, { text = "proposal" }, ctx)
  assert.is_table(ticket)
  local pending
  for index = 1, 20 do
    local name, value = debug.getupvalue(adapters.questions.answer, index)
    if not name then break end
    if name == "question_tickets" then pending = value end
  end
  assert.is_table(pending)
  assert.is_table(pending[ticket])
  adapters.loop.close(1)
  assert.is_nil(pending[ticket])
  local resolved = 0
  assert.is_false(adapters.questions.answer(ticket, "late", function() resolved = resolved + 1 end, ctx))
  assert.equals(1, resolved)
  assert.equals("closed", auth.snapshot(1).status)
end)

it("retires numeric decisions after a new exact instruction", function()
  boot(true)
  adopt()
  policy.decision = "deny"
  assert.is_false(gate())
  assert.is_table(adapters.human.inspect(1))
  adapters.human.submit(1, "new exact instruction", function() end)
  assert.is_nil(adapters.human.inspect(1))
end)

it("retires coordinator decisions and adoption payloads on reset and close", function()
  local discarded, disposed, closed = 0, 0, 0
  config.receipts.discard_adoption = function() discarded = discarded + 1 end
  config.receipts.close = function() closed = closed + 1 end
  config.adopt = function(view, answer)
    screens[#screens + 1] = { view = view, answer = answer }
    return function() disposed = disposed + 1 end
  end
  boot(true)
  submit()
  screens[1].answer(false)
  assert.equals(1, discarded)
  assert.equals(1, disposed)
  submit()
  local old = screens[2].answer
  adapters.human.reset(1)
  assert.equals(2, discarded)
  assert.equals(2, disposed)
  old(true)
  assert.equals("draft", auth.snapshot(1).status)
  adopt()
  policy.decision = "deny"
  assert.is_false(gate())
  assert.is_table(adapters.human.inspect(1))
  adapters.human.reset(1)
  assert.is_nil(adapters.human.inspect(1))
  adopt()
  assert.is_false(gate())
  adapters.loop.close(1)
  adapters.loop.close(1)
  adapters.children.rollback(999)
  assert.is_nil(adapters.human.inspect(2))
  assert.equals("closed", auth.snapshot(1).status)
  assert.is_true(closed >= 1)
end)

it("preserves a newer adoption created while the older scheduler fails", function()
  local discarded = {}
  local serial = 0
  config.receipts.prepare_adoption = function()
    serial = serial + 1
    return {}, { id = serial }
  end
  config.receipts.discard_adoption = function(token) discarded[#discarded + 1] = token.id end
  local scheduling = false
  config.run_human = function()
    if not scheduling then
      scheduling = true
      adapters.human.submit(1, "newer proposal", function() end)
      error("older scheduler failed")
    end
  end
  boot(true)
  submit()
  screens[1].answer(true)
  assert.equals(2, #screens)
  assert.same({ 1 }, discarded)
  screens[2].answer(false)
  assert.same({ 1, 2 }, discarded)
end)

it("stale accepted adoption work cannot dispose the newer proposal", function()
  local jobs, discarded = {}, 0
  config.run_human = function(bufnr, fn) jobs[#jobs + 1] = function() fn({ bufnr = bufnr }) end end
  config.receipts.discard_adoption = function() discarded = discarded + 1 end
  boot(true)
  submit()
  screens[1].answer(true)
  adapters.human.submit(1, "newer work", function() end)
  assert.equals(2, #screens)
  assert.equals(1, discarded)
  jobs[1]()
  assert.equals(1, discarded)
  screens[2].answer(true)
  jobs[2]()
  assert.equals("active", auth.snapshot(1).status)
end)

it("discards displayed adoption on stop and rejects its late answer", function()
  local discarded = 0
  config.receipts.discard_adoption = function() discarded = discarded + 1 end
  boot(true)
  submit()
  adapters.loop.stop(1)
  assert.equals(1, discarded)
  screens[1].answer(true)
  assert.is_nil(auth.snapshot(1).spec)
end)

it("discards adoption on cancellation and display failure", function()
  local discarded, cancelled = 0, nil
  config.receipts.discard_adoption = function() discarded = discarded + 1 end
  boot(true)
  adapters.human.submit(1, "local work", function() end, { on_cancel = function(fn) cancelled = fn end })
  cancelled()
  assert.equals(1, discarded)
  screens[1].answer(true)
  assert.equals("pending", auth.snapshot(1).status)
  assert.is_nil(auth.snapshot(1).spec)
end)

it("discards adoption when its display raises", function()
  local discarded = 0
  config.receipts.discard_adoption = function() discarded = discarded + 1 end
  config.adopt = function() error("display failure") end
  boot(true)
  local ok, reason = adapters.human.submit(1, "work", function() end)
  assert.is_false(ok)
  assert.matches("display failure", reason)
  assert.equals(1, discarded)
end)

it("delegates only capabilities permitted by the real parent and child ceilings", function()
  local child, subset = 2
  _G.contextual_ceiling_child = function(options)
    local plan = adapters.children.prepare("spawn", 1, options)
    return adapters.children.attach(plan, child, subset, { scope = child })
  end
  registry.define({ name = "tool.spawn", kind = "tool", source = "return function(input) return _G.contextual_ceiling_child(input) end" })
  config.disclosure = { approved = true }
  contextual.setup(config)
  adapters.human.create(1)
  adopt()
  local source = auth.snapshot(1).adopted[1]
  local ctx = { bufnr = 1 }
  adapters.loop.begin(ctx)
  local function attempt(capabilities, allow)
    subset = { targets = {}, effects = {}, capabilities = capabilities, sources = { source } }
    local allowed, reason, run = registry.gate_tool("spawn", { delegation = subset, allow = allow }, ctx)
    assert.is_true(allowed, tostring(reason))
    return run(ctx)
  end
  assert.is_true(attempt({ "sample" }, { "sample" }))
  assert.equals("active", auth.snapshot(child).status)
  assert.same({ "sample" }, auth.snapshot(child).delegation.subset.capabilities)
  local childctx = { bufnr = child }
  adapters.loop.begin(childctx)
  local allowed, _, run = registry.gate_tool("sample", { value = 19 }, childctx)
  assert.is_true(allowed)
  assert.same({ true, 19 }, { run(childctx) })
  assert.is_false(registry.gate_tool("spawn", {}, childctx))
  child = 3
  assert.is_true(attempt({ "exec" }, nil))
  assert.same({ "exec" }, auth.snapshot(child).delegation.subset.capabilities)
  child = 4
  assert.is_false(attempt({ "sample" }, {}))
  assert.is_nil(auth.snapshot(child).delegation)
  assert.is_not.equals("active", auth.snapshot(child).status)
  _G.contextual_ceiling_child = nil
end)

it("requires successful final-scope child receipt commit before delegation activation", function()
  local token, commit_ok, commits = nil, false, 0
  config.receipts.commit = function(value, scope)
    commits = commits + 1
    return commit_ok and value.scope == scope
  end
  _G.contextual_receipt_child = function(options)
    local plan = adapters.children.prepare("spawn", 1, options)
    adapters.children.attach(plan, 2, options.delegation, token)
  end
  registry.define({ name = "tool.spawn", kind = "tool", source = "return function(input) return _G.contextual_receipt_child(input) end" })
  boot(true)
  adopt()
  local subset = { targets = {}, effects = {}, capabilities = { "sample" }, sources = { auth.snapshot(1).adopted[1] } }
  local ctx = { bufnr = 1 }
  adapters.loop.begin(ctx)
  local allowed, _, run = registry.gate_tool("spawn", { delegation = subset }, ctx)
  assert.is_true(allowed)
  assert.is_false(run(ctx))
  assert.is_nil(auth.snapshot(2).delegation)
  assert.is_not.equals("active", auth.snapshot(2).status)
  assert.equals(0, commits)
  adapters.children.rollback(2)
  assert.equals("closed", auth.snapshot(2).status)
  local childctx = { bufnr = 2 }
  adapters.loop.begin(childctx)
  assert.is_false(registry.gate_tool("sample", { value = 7 }, childctx))
  _G.contextual_receipt_child = nil
end)

it("rejects a failed child commit and leaves copied forks suspended without authority", function()
  local child, token = 2, { scope = 2 }
  config.receipts.commit = function() return false end
  _G.contextual_receipt_child = function(options)
    local plan = adapters.children.prepare("spawn", 1, options)
    return adapters.children.attach(plan, child, nil, token)
  end
  registry.define({ name = "tool.spawn", kind = "tool", source = "return function(input) return _G.contextual_receipt_child(input) end" })
  boot(true)
  adopt()
  local ctx = { bufnr = 1 }
  adapters.loop.begin(ctx)
  local allowed, _, run = registry.gate_tool("spawn", {}, ctx)
  assert.is_true(allowed)
  assert.is_false(run(ctx))
  assert.is_nil(auth.snapshot(2).delegation)
  child, token = 3, nil
  allowed, _, run = registry.gate_tool("spawn", {}, ctx)
  assert.is_true(allowed)
  assert.same({ true, true }, { run(ctx) })
  assert.equals("suspended", contextual.status(3).status)
  assert.is_nil(auth.snapshot(3).delegation)
  assert.same({}, auth.snapshot(3).adopted)
  _G.contextual_receipt_child = nil
end)

it("binds child delegation to frozen options and subscribes delegated children to invalidation", function()
  local subset, mismatch, child = nil, true, 2
  _G.contextual_child_fixture = function()
    local options = { delegation = vim.deepcopy(subset) }
    local plan = adapters.children.prepare("spawn", 1, options)
    if mismatch then
      assert.has_error(function() adapters.children.attach(plan, child, {}) end)
      return "mismatch"
    end
    adapters.children.attach(plan, child, subset, { scope = child })
    return "attached"
  end
  registry.define({ name = "tool.spawn", kind = "tool", source = "return function() return _G.contextual_child_fixture() end" })
  boot(true)
  adopt()
  subset = { targets = {}, effects = {}, capabilities = { "sample" }, sources = { auth.snapshot(1).adopted[1] } }
  local ctx = { bufnr = 1 }
  adapters.loop.begin(ctx)
  local allowed, _, run = registry.gate_tool("spawn", { delegation = subset }, ctx)
  assert.is_true(allowed)
  assert.same({ true, "mismatch" }, { run(ctx) })
  assert.is_nil(auth.snapshot(child))
  mismatch = false
  allowed, _, run = registry.gate_tool("spawn", { delegation = subset }, ctx)
  assert.is_true(allowed)
  assert.same({ true, "attached" }, { run(ctx) })
  assert.equals("active", contextual.status(child).status)
  policy = { decision = "ask", decision_identity = { boundary = "read", targets = { "local" }, effects = { "read" } } }
  local childctx = { bufnr = child, await = function() return "displayed" end }
  adapters.loop.begin(childctx)
  assert.is_false(registry.gate_tool("sample", { value = 7 }, childctx))
  assert.equals(1, #consent_screens)
  assert.is_false(consent_screens[1].view.status == "approved")
  adapters.human.submit(1, "parent changed", function() end)
  assert.equals("suspended", contextual.status(child).status)
  consent_screens[1].answer("once")
  assert.equals("suspended", contextual.status(child).status)
  _G.contextual_child_fixture = nil
end)
