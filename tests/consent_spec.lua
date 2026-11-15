local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(here, ":p:h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local function check(value, message)
  assert(value, message)
end
local frozen, executing = false, false
package.loaded["straps.registry"] = {
  guards_frozen = function() return frozen end,
  any_tool_executing = function() return executing end,
}
local function load_consent()
  package.loaded["straps.consent"] = nil
  local mutant = os.getenv("STRAPS_CONSENT_MUTANT")
  if mutant then
    local source = table.concat(vim.fn.readfile(root .. "/lua/straps/consent.lua"), "\n")
    local variants = {
      release_definition = { 'binding[key].source, binding[key].doc, binding[key].input_schema = nil, nil, nil', '' },
      release_payload = { 'binding.input, binding.targets = nil, nil', '' },
      release_context = { 'record.handle, record.context = nil, nil', 'record.handle = nil' },
      release_handle = { 'record.handle, record.context = nil, nil', 'record.context = nil' },
      retire_receipt = { 'if record.binding.session_id == session then records[handle] = nil end', '' },
      search = { 'ipairs({ "q", "<Esc>" })', 'ipairs({ "n", "q", "<Esc>" })' },
      freshness = { 'local valid, reason = current(record)\n      if not valid then\n        terminal(record, reason == "expired" and "expired" or "invalidated", reason)', 'local valid, reason = true, nil\n      if not valid then\n        terminal(record, reason == "expired" and "expired" or "invalidated", reason)' },
      clearing = { 'if opts and opts.human_reopen == true then rejected[record.family] = nil end', 'if opts and opts.human_reopen == true then end' },
    }
    local variant = assert(variants[mutant])
    local first, last = assert(source:find(variant[1], 1, true))
    package.loaded["straps.consent"] = assert(loadstring(source:sub(1, first - 1) .. variant[2] .. source:sub(last + 1)))()
  end
  return require("straps.consent")
end
local consent = load_consent()
local time, shown, bindings, valid, events = 0, {}, {}, {}, {}
local options = {
  clock = function() return time end,
  max_pending = 3,
  expiry_ms = 50,
  describe = function(handle) return bindings[handle] end,
  validate = function(handle, binding)
    return valid[handle] and vim.deep_equal(binding, bindings[handle]), "revision changed"
  end,
  display = function(view, answer)
    local screen = { view = view, answer = answer }
    shown[#shown + 1] = screen
    return function() screen.disposed = true end
  end,
  amend_scope = function(_, boundary) return { event_id = "human-1", boundary = boundary, evidence = events } end,
}
local adapter
local function request(outcome, boundary, session, scope)
  local handle = {}
  bindings[handle] = { session_id = session or "session", parent = "parent", task_id = "task", epoch = 1,
    tool = { name = "tool.exec", identity = 1 }, input = { command = string.rep("payload", 5000) },
    grant_revision = 1, ceiling_revision = 1, targets = { "host" } }
  valid[handle] = true
  local assessment = { outcome = outcome or "ask", effects = { "restart" }, source = { "source-1" },
    conflicts = { "no restart" }, failure = "unassessed", scope = scope,
    decision = { boundary = boundary or "restart", targets = { "host" }, effects = { "restart" } } }
  local status = adapter.request(handle, assessment)
  return handle, status
end

it("issues one private connector only during trusted setup", function()
  executing = true
  check(not pcall(consent.connect, options), "executing tool must not acquire connector")
  executing, frozen = false, true
  check(not pcall(consent.connect, options), "frozen guards must close setup")
  frozen = false
  adapter = consent.connect(options)
  check(not pcall(consent.connect, options), "connector must issue once")
  check(consent.approve == nil and consent.resolve == nil and adapter.approve == nil, "approval setter must not exist")
end)

it("shows detached complete payload and all consent context before one-time final consumption", function()
  local handle, status = request()
  check(status == "displayed", "request must reach core display")
  local screen = shown[#shown]
  check(#screen.view.binding.input.command == 35000, "complete arguments must remain accessible")
  check(screen.view.binding.session_id == "session" and screen.view.binding.parent == "parent", "display must identify origin")
  check(screen.view.assessment.effects[1] == "restart" and screen.view.assessment.source[1] == "source-1",
    "display must show effects and sources")
  check(screen.view.assessment.conflicts[1] == "no restart" and screen.view.assessment.failure == "unassessed"
    and screen.view.lifetime.milliseconds == 50, "display must show conflicts failure and lifetime")
  screen.view.binding.input.command = "changed"
  check(adapter.inspect(handle).binding.input.command == bindings[handle].input.command, "inspection must be detached")
  check(not adapter.consume(handle), "display cannot consume before approval")
  screen.answer("once")
  check(adapter.status(handle) == "approved", "human core callback must approve")
  check(adapter.consume(handle) == true, "final execution must consume approval")
  check(adapter.consume(handle) == false, "approval must consume once")
  screen.answer("once")
  check(adapter.status(handle) == "consumed", "late callback must not resurrect consumed approval")
end)

it("serializes decisions bounds queue and suppresses target-effect-boundary families", function()
  local first = request("ask", "shared")
  local second = request("ask", "shared")
  local independent = request("ask", "independent")
  local overflow, status = request("ask", "overflow")
  check(status == "denied" and adapter.inspect(overflow).reason:find("queue full", 1, true), "pending queue must be bounded")
  check(adapter.status(second) == "queued" and adapter.status(independent) == "queued", "display must serialize across requests")
  shown[#shown].answer("reject")
  check(adapter.status(first) == "rejected" and adapter.status(second) == "denied", "reject must suppress equivalent pending family")
  check(adapter.status(independent) == "displayed", "independent decision must remain eligible")
  adapter.invalidate(independent, "veto")
  check(adapter.reopen(first) == true and adapter.status(first) == "displayed", "trusted human reopen must permit rejected family")
  shown[#shown].answer("reject")
  check(adapter.inspect(second).status == "denied", "denials must remain inspectable")
end)

it("drops terminal execution payloads and retires session rejection receipts", function()
  local handle = request("ask", "retained", "retention")
  local function upvalue(fn, name)
    for index = 1, 40 do
      local key, value = debug.getupvalue(fn, index)
      if key == name then return value end
      if key == nil then break end
    end
    error("missing upvalue " .. name)
  end
  local records = upvalue(adapter.inspect, "records")
  local record = records[handle]
  local denied = {}
  bindings[denied], valid[denied] = vim.deepcopy(bindings[handle]), true
  bindings[denied].definition = { name = "tool.exec", identity = 99, source = "secret source", doc = "full doc", input_schema = { huge = "payload" } }
  local denied_context = { await = function() error("denial must not await") end }
  assert.equals("denied", adapter.request(denied, { outcome = "deny" }, denied_context))
  assert.is_nil(records[denied].context)
  assert.same({ name = "tool.exec", identity = 99 }, records[denied].binding.definition)
  assert.equals(handle, record.handle)
  shown[#shown].answer("reject")
  assert.is_nil(record.handle)
  assert.is_nil(record.context)
  assert.is_nil(record.binding.input)
  assert.is_nil(record.binding.targets)
  assert.same({}, record.waiters)
  assert.equals("no restart", adapter.inspect(handle).assessment.conflicts[1])
  assert.equals("source-1", adapter.inspect(handle).assessment.source[1])
  assert.is_true(adapter.reopen(handle))
  shown[#shown].answer("once")
  assert.is_true(adapter.consume(handle))
  assert.is_nil(record.handle)
  assert.is_nil(record.binding.input)
  adapter.retire_session("retention")
  assert.is_nil(adapter.inspect(handle))
  local fresh, status = request("ask", "retained", "retention")
  assert.equals("displayed", status)
  adapter.invalidate(fresh)
end)

it("requires valid opaque handles and leaves denial automatic prompts closed", function()
  check(adapter.request({}, {}) == "denied", "forged opaque handle must deny")
  local handle = request("deny", "denied")
  check(adapter.status(handle) == "denied", "classifier denial must not auto-prompt")
  check(adapter.reopen(handle) == true, "human must be able to reopen classifier denial")
  adapter.invalidate(handle)
  local no_identity = {}
  bindings[no_identity], valid[no_identity] = bindings[handle], true
  check(adapter.request(no_identity, { outcome = "ask" }) == "denied", "missing identity must deny without global suppression")
end)

it("invalidates revision cancellation veto expiry and cross-session requests", function()
  local stale = request("ask", "stale")
  shown[#shown].answer("once")
  bindings[stale].epoch = 2
  check(not adapter.consume(stale) and adapter.status(stale) == "invalidated", "changed immutable revision must invalidate approval")
  local cancelled = request("ask", "cancel")
  local callback = shown[#shown].answer
  adapter.invalidate(cancelled, "cancelled")
  callback("once")
  check(not adapter.consume(cancelled), "cancel and late callback must execute nothing")
  local veto = request("ask", "veto")
  shown[#shown].answer("once")
  adapter.invalidate(veto, "later guard veto")
  check(not adapter.consume(veto), "later veto must invalidate approval")
  local expires = request("ask", "expiry")
  shown[#shown].answer("once")
  time = 51
  check(not adapter.consume(expires) and adapter.status(expires) == "expired", "expired approval must not execute")
  time = 52
  local session = request("ask", "session", "child")
  adapter.invalidate_session("child", "epoch changed")
  check(adapter.status(session) == "invalidated", "session lifecycle must invalidate pending requests")
end)

it("requires exact explicit amendment evidence and invalidates affected revisions", function()
  local scope = { boundary = "restart allowed", targets = { "host" }, effects = { "restart" } }
  local unsupported = request("ask", "scope1", nil, scope)
  shown[#shown].answer("scoped")
  check(adapter.status(unsupported) == "invalidated", "missing amendment evidence must refuse scope")
  events = { "explicit-human-source" }
  local handle = request("ask", "scope2", nil, scope)
  local affected = request("ask", "affected")
  shown[#shown].answer("scoped")
  check(adapter.status(handle) == "amended" and not adapter.consume(handle), "scope amendment must require new assessment")
  check(adapter.status(affected) == "invalidated", "amendment must invalidate affected pending revision")
end)

it("awaits core UI and cancellation through supplied async context", function()
  local handle = {}
  bindings[handle], valid[handle] = { session_id = "async", task_id = "task", epoch = 1 }, true
  local cancel
  local status = adapter.request(handle, { outcome = "ask", decision = {
    boundary = "async", targets = { "host" }, effects = { "restart" },
  } }, {
    on_cancel = function(fn) cancel = fn end,
    await = function(register)
      local outcome
      register(function(result) outcome = result end)
      shown[#shown].answer("once")
      return outcome
    end,
  })
  check(status == "approved", "async caller must receive human decision")
  cancel()
  check(not adapter.consume(handle), "async cancellation must invalidate approved request")
end)

it("disposes the active interaction before displaying the next queued request", function()
  local first = request("ask", "dispose-first")
  local screen = shown[#shown]
  local second = request("ask", "dispose-second")
  adapter.invalidate(first)
  check(screen.disposed == true and adapter.status(second) == "displayed", "invalidation must dispose before advancing")
  local next_screen = shown[#shown]
  shown[#shown].answer("once")
  check(next_screen.disposed == true, "approval must dispose interaction")
  adapter.invalidate(second)
  local expires = request("ask", "dispose-expiry")
  local expiry_screen = shown[#shown]
  time = time + 51
  check(adapter.status(expires) == "expired" and expiry_screen.disposed == true, "expiry must dispose interaction")
end)

it("owns production input without replaceable selectors and closes complete request views", function()
  package.loaded["straps.consent"] = nil
  local old_select = vim.ui.select
  local selector_calls = 0
  vim.ui.select = function(_, _, answer) selector_calls = selector_calls + 1; answer(nil, 2) end
  local production = load_consent().connect({ describe = options.describe, validate = options.validate,
    expiry_ms = 5000 })
  local function open(boundary)
    local handle = {}
    bindings[handle], valid[handle] = { session_id = "ui", task_id = "task", epoch = 1,
      input = { exact = string.rep("complete-input", 5000) .. "END-EXACT" } }, true
    production.request(handle, { outcome = "ask", decision = { boundary = boundary,
      targets = { "host" }, effects = { "restart" } } })
    return handle, vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  end
  local ok, reason = pcall(function()
    local handle, window, buffer = open("ui-once")
    local text = table.concat(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), "\n")
    check(text:find(bindings[handle].input.exact, 1, true) ~= nil, "production view must retain exact untruncated input")
    check(selector_calls == 0 and production.status(handle) == "displayed", "replaceable selector cannot approve")
    vim.fn.setreg("/", "input")
    vim.api.nvim_win_set_cursor(window, { 1, 0 })
    vim.api.nvim_feedkeys("n", "xt", false)
    check(production.status(handle) == "displayed" and vim.api.nvim_win_get_cursor(window)[1] > 1,
      "search repeat must navigate without rejecting consent")
    local mappings = vim.api.nvim_buf_get_keymap(buffer, "n")
    local stale_answer
    for _, mapping in ipairs(mappings) do if mapping.lhs == "y" then stale_answer = mapping.callback end end
    check(type(stale_answer) == "function", "owned view must bind approval input")
    vim.defer_fn(function() vim.api.nvim_feedkeys("y", "xt", false) end, 10)
    check(vim.wait(1000, function() return production.status(handle) == "approved" end), "owned input must approve once")
    check(not vim.api.nvim_win_is_valid(window) and not vim.api.nvim_buf_is_valid(buffer), "approval must close request view")
    local cancelled, cancelled_window, cancelled_buffer = open("ui-cancel")
    stale_answer()
    check(production.status(cancelled) == "displayed", "disposed callback must not approve next request")
    local queued = open("ui-queued")
    vim.defer_fn(function() production.invalidate(cancelled); production.invalidate(queued) end, 10)
    check(vim.wait(1000, function() return production.status(cancelled) == "invalidated" end), "scheduled cancellation must run during input")
    check(not vim.api.nvim_win_is_valid(cancelled_window) and not vim.api.nvim_buf_is_valid(cancelled_buffer),
      "cancellation must close active view")
    check(production.status(queued) == "invalidated", "queued cancellation must invalidate before display can approve")
    local closed, close_window, close_buffer = open("ui-close")
    vim.api.nvim_win_close(close_window, true)
    check(production.status(closed) == "rejected" and not vim.api.nvim_buf_is_valid(close_buffer),
      "closing the owned interaction must reject and dispose")
  end)
  vim.ui.select = old_select
  production.invalidate_session("ui")
  check(ok, reason)
end)

it("reopens only a fresh trusted real gate and preserves other rejected families", function()
  package.loaded["straps.registry"] = nil
  local registry = require("straps.registry")
  local core, connector, last_handle, last_status
  local stamp = { session_id = "reopen-session", task_id = "reopen-task", epoch = 1, task_revision = 1 }
  local boundary, choice, trusted, change = "rejected-a", "reject", false, nil
  local assessment
  local definition = { name = "tool.reopen_probe", kind = "tool", source = "return function() return 'executed' end" }
  registry.define(definition)
  core = registry.setup_authorization({
    execution_stamp = function() return vim.deepcopy(stamp) end,
    validate_stamp = function(_, binding) return vim.deep_equal(binding, stamp) end,
    assess = function(handle)
      last_handle = handle
      assessment = { outcome = "ask", decision = { boundary = boundary, targets = { "host" }, effects = { "read" } } }
      if change then change(); change = nil end
      last_status = connector.request(handle, assessment, { await = function(register)
        local result
        register(function(value) result = value end)
        shown[#shown].answer(choice)
        return result
      end }, trusted and { human_reopen = true } or nil)
      return { decision = last_status == "approved" and "allow" or "deny" }
    end,
    consume = function(handle) return connector.consume(handle) end,
    invalidate = function(handle, reason) connector.invalidate(handle, reason) end,
  })
  connector = load_consent().connect({ describe = core.describe, validate = core.validate, display = options.display })
  core.install_ceiling(42, {})
  local ctx = { bufnr = 42 }
  core.begin_family(ctx)
  local function gate() return registry.gate_tool("reopen_probe", {}, ctx) end
  check(gate() == false and last_status == "rejected", "real gate must record initial human rejection")
  local original = last_handle
  check(not connector.reopen(original), "terminal registry handle must be unusable")
  boundary = "rejected-b"
  check(gate() == false and last_status == "rejected", "unrelated family must record human rejection")
  boundary, trusted, choice = "rejected-a", true, "once"
  local screens = #shown
  check(connector.request(original, assessment, nil, { human_reopen = true }) ~= "displayed" and #shown == screens,
    "trusted flag cannot resurrect terminal handle")
  change = function() stamp.task_revision = stamp.task_revision + 1 end
  check(gate() == false and #shown == screens, "stale task revision must not display trusted reopen")
  trusted = false
  check(gate() == false and last_status == "denied" and #shown == screens,
    "stale task revision must not clear family rejection")
  trusted = true
  change = function() registry.define(definition) end
  check(gate() == false and #shown == screens, "stale registry identity must not display trusted reopen")
  trusted = false
  check(gate() == false and last_status == "denied" and #shown == screens,
    "stale registry identity must not clear family rejection")
  boundary, trusted = "different-family", true
  local allowed, _, run = gate()
  check(allowed == true and #shown == screens + 1, "different fresh family must retain normal consent: " .. tostring(_) .. "; " .. tostring(last_status))
  check(run(ctx) == true, "different family consent must consume")
  boundary, trusted = "rejected-a", false
  check(gate() == false and last_status == "denied" and #shown == screens + 1,
    "different family reopen must not clear rejected family")
  trusted = true
  allowed, _, run = gate()
  check(allowed == true and last_status == "approved" and #shown == screens + 2,
    "fresh trusted gate must display the rejected family once")
  check(connector.status(original) == "invalidated", "fresh reopen must leave original terminal handle unusable")
  check(run(ctx) == true, "fresh trusted approval must execute once")
  boundary, trusted = "rejected-b", false
  check(gate() == false and last_status == "denied" and #shown == screens + 2,
    "trusted reopen must preserve unrelated rejection")
  check(consent.reset == nil and consent.get == nil and consent.approve == nil and connector.reset == nil,
    "reopen must add no public reset getter or approval API")
end)

it("binds real registry execution handles and consumes only in final closure", function()
  package.loaded["straps.registry"] = nil
  package.loaded["straps.consent"] = nil
  local registry = require("straps.registry")
  local core, connector, consumptions, last_handle = nil, nil, 0, nil
  local stamp = { session_id = "real-session", task_id = "real-task", epoch = 1 }
  registry.define({ name = "tool.consent_probe", kind = "tool", source = "return function() return 'executed' end" })
  core = registry.setup_authorization({
    execution_stamp = function() return vim.deepcopy(stamp) end,
    validate_stamp = function(_, binding) return vim.deep_equal(binding, stamp) end,
    assess = function(handle)
      last_handle = handle
      local result = connector.request(handle, { outcome = "ask", decision = {
        boundary = "real", targets = { "host" }, effects = { "read" },
      } }, { await = function(register)
        local result
        register(function(value) result = value end)
        shown[#shown].answer("once")
        return result
      end })
      return { decision = result == "approved" and "allow" or "deny" }
    end,
    consume = function(handle) consumptions = consumptions + 1; return connector.consume(handle) end,
    invalidate = function(handle, reason) connector.invalidate(handle, reason) end,
  })
  connector = require("straps.consent").connect({ describe = core.describe, validate = core.validate,
    display = options.display })
  core.install_ceiling(41, { allow = { "consent_probe" } })
  local ctx = { bufnr = 41 }
  core.begin_family(ctx)
  local allowed, reason, run = registry.gate_tool("consent_probe", {}, ctx)
  check(allowed == true and reason == nil, "real registry handle must permit consent request")
  check(connector.status(last_handle) == "approved" and consumptions == 0, "gate must retain unconsumed approval")
  local binding = connector.inspect(last_handle).binding
  check(binding.session_id == "real-session" and binding.task_id == "real-task" and binding.epoch == 1,
    "registry stable identities must reach consent inspection")
  local ok, result = run(ctx)
  check(ok == true and result == "executed" and consumptions == 1, "real execution closure must consume consent once")
  check(connector.status(last_handle) == "consumed", "real execution must leave consent consumed")
  check(not pcall(run, ctx) and consumptions == 1, "execution closure cannot reuse consumed consent")
  local vetoed, veto_reason = registry.gate_tool("consent_probe", {}, ctx, {
    confirm = function() return false, "other veto" end,
  })
  check(vetoed == false and veto_reason == "user denied: other veto", "ordinary confirmation must retain veto")
  local veto_status, invalidation_reason = connector.status(last_handle)
  check(veto_status == "invalidated" and invalidation_reason == "user denied: other veto"
    and not connector.consume(last_handle), "later confirmation veto must invalidate consent")
  local stale_allowed, _, stale_run = registry.gate_tool("consent_probe", {}, ctx)
  check(stale_allowed == true, "fresh real call must gate before revision change")
  stamp.epoch = 2
  local stale_ok = stale_run(ctx)
  check(stale_ok == false and connector.status(last_handle) == "invalidated" and consumptions == 1,
    "stale real stamp must invalidate before consumption")
end)

