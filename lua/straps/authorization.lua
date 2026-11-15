local M = {}
local sessions, captures, synthesis, listeners = {}, {}, {}, {}
local installed, serial = false, 0
local validate_ceiling, activate_ceiling
local core = {}

local function array(value)
  assert(type(value) == "table", "array required")
  local count = 0
  for key in pairs(value) do
    assert(type(key) == "number" and key >= 1 and key % 1 == 0, "invalid array key")
    count = count + 1
  end
  for index = 1, count do assert(value[index] ~= nil, "sparse array") end
  return count
end

local function strings(value, required)
  local count, seen = array(value), {}
  assert(not required or count > 0, "nonempty array required")
  for _, item in ipairs(value) do
    assert(type(item) == "string" and item:find("%S") and not seen[item], "nonempty unique string array required")
    seen[item] = true
  end
end
local prefix = tostring(vim.uv.hrtime()) .. ":"
local fields = { "outcome", "mode", "targets", "effects", "constraints", "reserved_decisions", "latitude", "unresolved_scope" }
local defects = { "unsupported_authority", "untrusted_authority", "omitted_constraint", "expanded_scope", "lost_authorization", "hidden_ambiguity" }

local function id(kind)
  serial = serial + 1
  return prefix .. kind .. ":" .. serial
end

local function copy(value, seen)
  local kind = type(value)
  if kind == "nil" or kind == "string" or kind == "boolean" then return value end
  if kind == "number" and value == value and value ~= math.huge and value ~= -math.huge then return value end
  assert(kind == "table" and getmetatable(value) == nil, "authorization requires data-only values")
  seen = seen or {}
  assert(not seen[value], "authorization rejects cyclic data")
  seen[value] = true
  local result = {}
  for key, item in pairs(value) do
    assert(type(key) == "string" or type(key) == "number", "invalid data key")
    result[key] = copy(item, seen)
  end
  seen[value] = nil
  return result
end

local function trusted()
  local registry = require("straps.registry")
  assert(not registry.any_tool_executing or not registry.any_tool_executing(), "authority mutation during tool execution")
end

local function session(bufnr)
  local s = sessions[bufnr]
  assert(s and s.status ~= "closed", "unknown or closed authorization session")
  return s
end

local function stamp(s)
  return { session_id = s.session_id, task_id = s.task_id, epoch = s.epoch, instruction_revision = s.epoch,
    lifecycle_generation = s.lifecycle_generation, grant_revision = s.grant_revision,
    standing_snapshot_id = s.standing and s.standing.id or nil, status = s.status }
end

local function notify(s, reason)
  local callbacks = {}
  for callback in pairs(listeners[s.bufnr] or {}) do callbacks[#callbacks + 1] = callback end
  for _, callback in ipairs(callbacks) do pcall(callback, copy(stamp(s)), reason) end
end

local function retire_tickets(s)
  for ticket, record in pairs(captures) do if record.bufnr == s.bufnr then captures[ticket] = nil end end
  for ticket, record in pairs(synthesis) do if record.bufnr == s.bufnr then synthesis[ticket] = nil end end
end

local function retire_delegation(s)
  if s.unsubscribe_parent then s.unsubscribe_parent(); s.unsubscribe_parent = nil end
end

local function invalidate(s, reason, status)
  retire_tickets(s)
  s.epoch = s.epoch + 1
  s.grant_revision = s.grant_revision + 1
  s.spec = nil
  s.status = status or "pending"
  notify(s, reason)
end

local function current(s, old)
  local now = stamp(s)
  for _, key in ipairs({ "session_id", "task_id", "epoch", "instruction_revision", "lifecycle_generation", "grant_revision", "standing_snapshot_id", "status" }) do
    if old[key] ~= now[key] then return false, "authorization changed: " .. key end
  end
  return true
end

function M.snapshot(bufnr)
  local s = sessions[bufnr]
  if not s then return nil end
  local result = stamp(s)
  result.events, result.adopted, result.standing, result.spec = copy(s.events), copy(s.adopted), copy(s.standing), copy(s.spec)
  result.delegation = copy(s.delegation)
  return result
end

function M.execution_stamp(bufnr)
  local s = sessions[bufnr]
  return s and copy(stamp(s)) or nil
end

function M.validate_context_stamp(bufnr, old)
  local s = sessions[bufnr]
  if not s or type(old) ~= "table" then return false, "unknown authorization session" end
  if s.status ~= "active" and (s.status ~= "pending" or not s.standing or #s.adopted == 0) then
    return false, "authorization unavailable"
  end
  return current(s, old)
end

function M.validate_stamp(bufnr, old)
  local s = sessions[bufnr]
  if not s or type(old) ~= "table" then return false, "unknown authorization session" end
  if s.status ~= "active" or not s.spec then return false, "authorization unavailable" end
  return current(s, old)
end

function M.validate(old, ctx)
  return M.validate_stamp(ctx and ctx.bufnr, old)
end

function M.subscribe(bufnr, callback)
  assert(type(callback) == "function", "invalidation callback required")
  listeners[bufnr] = listeners[bufnr] or {}
  listeners[bufnr][callback] = true
  return function() if listeners[bufnr] then listeners[bufnr][callback] = nil end end
end

local function standing(value)
  local result = copy(value)
  assert(type(result) == "table" and type(result.id) == "string" and type(result.config_hash) == "string", "invalid standing snapshot")
  array(result.sources)
  local seen = {}
  for index, source in ipairs(result.sources) do
    assert(type(source.id) == "string" and not seen[source.id], "invalid standing source ID")
    assert(type(source.path) == "string" and type(source.hash) == "string" and type(source.text) == "string", "invalid standing source")
    assert(type(source.canonical_path) == "string" and source.precedence == index, "invalid standing precedence")
    seen[source.id] = true
  end
  return result
end

function M.observe_standing(bufnr, value)
  local s, value_copy = session(bufnr), standing(value)
  if s.standing and not vim.deep_equal(s.standing, value_copy) then
    invalidate(s, "standing instructions changed", "suspended")
    return false
  end
  return true
end

function M.stop(bufnr)
  local s = session(bufnr)
  s.lifecycle_generation = s.lifecycle_generation + 1
  retire_tickets(s)
  notify(s, "stopped")
end

function M.suspend(bufnr)
  invalidate(session(bufnr), "suspended", "suspended")
end

function M.close(bufnr)
  local s = session(bufnr)
  s.lifecycle_generation = s.lifecycle_generation + 1
  invalidate(s, "closed", "closed")
  retire_delegation(s)
  s.events, s.adopted, s.standing, s.delegation = {}, {}, nil, nil
  listeners[bufnr] = nil
end

function core.create_session(bufnr)
  assert(type(bufnr) == "number" and not sessions[bufnr], "authorization session already exists or invalid")
  sessions[bufnr] = { bufnr = bufnr, session_id = id("session"), task_id = id("task"), epoch = 0,
    lifecycle_generation = 0, grant_revision = 0, status = "draft", events = {}, adopted = {} }
  return M.execution_stamp(bufnr)
end

function core.prepare_capture(bufnr, kind, payload)
  local s = session(bufnr)
  assert(kind == "instruction" or kind == "answer" or kind == "draft" or kind == "stdin", "invalid capture kind")
  local data = copy(payload)
  assert(type(data) == "table" and type(data.text) == "string", "capture text required")
  if kind == "answer" then
    assert(type(data.proposal) == "table" and type(data.proposal.question) == "string" and type(data.proposal.options) == "table", "full question proposal required")
    assert(data.accepted == true, "only final accepted answers establish authority")
  end
  local ticket = {}
  captures[ticket] = { bufnr = bufnr, stamp = stamp(s), kind = kind, payload = data }
  return ticket
end

function core.capture(ticket)
  local record = captures[ticket]
  captures[ticket] = nil
  assert(record, "unknown or consumed capture ticket (stale or closed)")
  local s = session(record.bufnr)
  assert(current(s, record.stamp), "stale capture ticket")
  local event = { id = id("event"), session_id = s.session_id, task_id = s.task_id, kind = record.kind,
    payload = record.payload, revision = s.epoch + 1 }
  s.events[#s.events + 1] = event
  if record.kind == "instruction" or record.kind == "answer" then
    if s.standing then s.adopted[#s.adopted + 1] = event.id end
    invalidate(s, "instruction captured", (s.status == "suspended" or s.status == "inactive") and s.status or nil)
  end
  return copy(event)
end

local function adopt(bufnr, event_ids, snapshot)
  local s, selected = session(bufnr), copy(event_ids)
  local adopted_standing = standing(snapshot)
  strings(selected, true)
  local available, seen = {}, {}
  for _, event in ipairs(s.events) do
    if event.task_id == s.task_id then available[event.id] = true end
  end
  for _, event_id in ipairs(selected) do
    assert(available[event_id] and not seen[event_id], "unknown or duplicate adopted event")
    seen[event_id] = true
  end
  s.adopted, s.standing = selected, adopted_standing
  invalidate(s, "task adopted")
  return M.execution_stamp(bufnr)
end

function core.adopt_task(bufnr, event_ids, snapshot)
  return adopt(bufnr, event_ids, snapshot)
end

function core.reactivate(bufnr, event_ids, snapshot)
  local s = session(bufnr)
  assert(s.status == "suspended" or s.status == "inactive", "session does not require reactivation")
  return adopt(bufnr, event_ids, snapshot)
end

function core.reset_task(bufnr)
  local s = session(bufnr)
  retire_delegation(s)
  s.events = {}
  s.task_id, s.adopted, s.standing, s.delegation = id("task"), {}, nil, nil
  invalidate(s, "task reset", "draft")
  return M.execution_stamp(bufnr)
end

function core.abandon_synthesis(ticket)
  local existed = synthesis[ticket] ~= nil
  synthesis[ticket] = nil
  return existed
end

function core.begin_synthesis(bufnr)
  local s = session(bufnr)
  assert(s.status == "pending" and s.standing and #s.adopted > 0, "task needs adoption")
  local ticket = {}
  synthesis[ticket] = { bufnr = bufnr, stamp = stamp(s) }
  return ticket, M.snapshot(bufnr)
end

local function validate_spec(s, spec, checks)
  local available = {}
  for _, event_id in ipairs(s.adopted) do available[event_id] = true end
  for _, source in ipairs(s.standing.sources) do available[source.id] = true end
  assert(type(spec) == "table" and spec.schema_version == 1, "invalid specification schema")
  local allowed = { schema_version = true, task_id = true, instruction_revision = true }
  assert(spec.task_id == s.task_id and spec.instruction_revision == s.epoch, "specification revision mismatch")
  for _, name in ipairs(fields) do
    allowed[name] = true
    local field = spec[name]
    assert(type(field) == "table" and field.value ~= nil and type(field.sources) == "table" and #field.sources > 0, "missing specification field: " .. name)
    for key in pairs(field) do assert(key == "value" or key == "sources", "unexpected specification field member") end
    if name == "outcome" then
      assert(type(field.value) == "string" and field.value ~= "", "invalid outcome")
    elseif name == "mode" then
      assert(({ discussion = true, investigation = true, planning = true, implementation = true })[field.value], "invalid mode")
    else
      strings(field.value)
    end
    strings(field.sources, true)
    for _, source_id in ipairs(field.sources) do
      assert(available[source_id], "unsupported specification source")
    end
  end
  for key in pairs(spec) do assert(allowed[key], "unexpected specification field") end
  assert(type(checks) == "table", "independent synthesis checks required")
  local known = {}
  for _, name in ipairs(defects) do
    known[name] = true
    assert(checks[name] == false, "synthesis defect or missing check: " .. name)
  end
  for key in pairs(checks) do assert(known[key], "unknown synthesis check") end
end

function core.publish_spec(ticket, value, checks)
  local record = synthesis[ticket]
  synthesis[ticket] = nil
  assert(record, "unknown or consumed synthesis ticket (stale or closed)")
  local s = session(record.bufnr)
  assert(current(s, record.stamp), "stale synthesis ticket")
  local spec, check_copy = copy(value), copy(checks)
  validate_spec(s, spec, check_copy)
  s.spec, s.status = spec, "active"
  return M.execution_stamp(record.bufnr)
end

function core.delegate(parent_bufnr, child_bufnr, subset)
  local parent, child, requested = session(parent_bufnr), session(child_bufnr), copy(subset)
  assert(parent ~= child and parent.status == "active" and parent.spec, "active distinct parent required")
  assert(child.status == "draft" and not child.delegation, "child already adopted")
  assert(type(requested) == "table", "explicit delegation required")
  local keys = { targets = true, effects = true, capabilities = true, sources = true }
  for key in pairs(requested) do assert(keys[key], "unexpected delegation field") end
  for key in pairs(keys) do strings(requested[key], key == "sources") end
  local available = {}
  for _, event_id in ipairs(parent.adopted) do available[event_id] = true end
  for _, source in ipairs(parent.standing.sources) do available[source.id] = true end
  for _, source_id in ipairs(requested.sources) do assert(available[source_id], "unsupported delegation source") end
  for _, name in ipairs({ "targets", "effects" }) do
    for _, item in ipairs(requested[name]) do
      local found = false
      for _, allowed in ipairs(parent.spec[name].value) do if vim.deep_equal(item, allowed) then found = true end end
      assert(found, "delegation expands " .. name)
    end
  end
  assert(type(requested.capabilities) == "table", "capability subset required")
  if #requested.capabilities > 0 then
    assert(validate_ceiling and validate_ceiling(parent_bufnr, child_bufnr, copy(requested)) == true, "capability delegation requires core ceiling validation")
  end
  child.delegation = { parent = stamp(parent), subset = requested, id = id("delegation") }
  local unsubscribe
  unsubscribe = M.subscribe(parent_bufnr, function()
    if child.status ~= "closed" then invalidate(child, "parent authority changed", "suspended") end
    unsubscribe()
  end)
  child.unsubscribe_parent = unsubscribe
  invalidate(child, "delegation recorded", "inactive")
  return copy(child.delegation)
end

function core.activate_delegation(parent_bufnr, child_bufnr, subset)
  assert(type(activate_ceiling) == "function", "delegation activation requires core ceiling installer")
  core.delegate(parent_bufnr, child_bufnr, subset)
  local parent, child = session(parent_bufnr), session(child_bufnr)
  local delegated = child.delegation
  local child_stamp = stamp(child)
  assert(activate_ceiling(parent_bufnr, child_bufnr, copy(delegated.subset.capabilities)) == true, "delegation ceiling installation failed")
  assert(current(parent, delegated.parent), "parent authority changed during delegation")
  assert(current(child, child_stamp) and child.status == "inactive", "child authority changed during delegation")
  local event = { id = id("event"), session_id = child.session_id, task_id = child.task_id, kind = "delegation",
    revision = child.epoch + 1, payload = { delegation_id = delegated.id, parent = copy(delegated.parent),
      subset = copy(delegated.subset), specification = copy(parent.spec) } }
  local spec = copy(parent.spec)
  spec.task_id, spec.instruction_revision = child.task_id, child.epoch + 1
  for _, name in ipairs(fields) do spec[name].sources = { event.id } end
  spec.targets.value, spec.effects.value = copy(delegated.subset.targets), copy(delegated.subset.effects)
  child.events[#child.events + 1], child.adopted, child.standing = event, { event.id }, copy(parent.standing)
  local expected = stamp(child)
  expected.epoch, expected.instruction_revision = expected.epoch + 1, expected.instruction_revision + 1
  expected.grant_revision, expected.status = expected.grant_revision + 1, "pending"
  invalidate(child, "delegation activated")
  assert(current(parent, delegated.parent), "parent authority changed during delegation")
  assert(current(child, expected), "child authority changed during delegation")
  local checks = {}
  for _, name in ipairs(defects) do checks[name] = false end
  validate_spec(child, spec, checks)
  child.spec, child.status = spec, "active"
  return M.execution_stamp(child_bufnr)
end

function M.install_core(consumer, options)
  trusted()
  local registry = require("straps.registry")
  assert(not installed and registry.trusted_setup_allowed(), "authorization setup sealed")
  assert(type(consumer) == "function", "core consumer required")
  options = options or {}
  assert(options.validate_ceiling == nil or type(options.validate_ceiling) == "function", "invalid ceiling validator")
  assert(options.activate_ceiling == nil or type(options.activate_ceiling) == "function", "invalid ceiling installer")
  validate_ceiling, activate_ceiling = options.validate_ceiling, options.activate_ceiling
  installed = true
  consumer(core)
  return true
end

return M
