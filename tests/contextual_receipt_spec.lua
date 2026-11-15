local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(here, ":p:h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. package.path

local registry, adapters, policy, records
local fields = { "outcome", "mode", "targets", "effects", "constraints", "reserved_decisions", "latitude", "unresolved_scope" }
local input_marker, source_marker, target_marker = "receipt-input-private", "receipt-source-private", "receipt-target-private"

before_each(function()
  for _, name in ipairs({ "contextual", "registry", "authorization", "consent" }) do package.loaded["straps." .. name] = nil end
  registry = require("straps.registry")
  registry.define({ name = "tool.sample", kind = "tool", source = "return function() local value = '" .. source_marker .. "'; return 'body completed' end" })
  adapters, policy = {}, { decision = "allow", reasons = {}, effects = {}, source_ids = {} }
  local config = {
    enabled = true, limits = { max_bytes = 1048576, max_depth = 32, max_items = 10000 }, disclosure = { approved = true },
    receipts = { identity = function() return "fixture" end, validate = function() return true end,
      prepare_adoption = function() return { transcript = "local task" }, {} end,
      adopt = function(_, validate) return validate() end },
    discover = function() return { id = "standing", config_hash = "fixture", sources = {} } end,
    run_human = function(buf, fn) fn({ bufnr = buf, cancelled = function() return false end }) end,
    adopt = function(_, answer) answer(true) end,
    resolve_targets = function() return { known = { private = target_marker }, unresolved = {}, checks = {} } end,
    validate_targets = function() return true end,
    assessor_factory = function() return {
      synthesize = function(snapshot)
        local spec = { schema_version = 1, task_id = snapshot.task_id, instruction_revision = snapshot.epoch }
        for _, field in ipairs(fields) do spec[field] = { value = {}, sources = { snapshot.adopted[1] } } end
        spec.outcome.value, spec.mode.value = "local task", "implementation"
        return spec, { unsupported_authority = false, untrusted_authority = false, omitted_constraint = false,
          expanded_scope = false, lost_authorization = false, hidden_ambiguity = false }
      end,
      assess = function() return vim.deepcopy(policy) end,
    } end,
    install = {},
  }
  for _, name in ipairs({ "human", "loop", "questions", "children" }) do
    local key = name
    config.install[key] = function(adapter) adapters[key] = adapter end
  end
  local contextual
  if vim.env.STRAPS_RECEIPT_MUTANT then
    local source = table.concat(vim.fn.readfile(root .. "/lua/straps/contextual.lua"), "\n")
    local target = 'records[record.id] = { id = record.id, terminal = true, execution_started = true,'
    local first, last = assert(source:find(target, 1, true))
    source = source:sub(1, first - 1) .. 'records[record.id] = { retained = record, id = record.id, terminal = true, execution_started = true,' .. source:sub(last + 1)
    contextual = assert(loadstring(source))()
  else contextual = require("straps.contextual") end
  contextual.setup(config)
  adapters.human.create(1)
  adapters.human.submit(1, "local task", function() end)
  for index = 1, 30 do
    local name, value = debug.getupvalue(adapters.human.inspect, index)
    if not name then break end
    if name == "records" then records = value end
  end
  assert.is_table(records)
end)

local function gate()
  local ctx = { bufnr = 1 }
  adapters.loop.begin(ctx)
  return { registry.gate_tool("sample", { private = input_marker }, ctx) }, ctx
end

local function contains(value, marker, seen)
  if type(value) == "string" then return value:find(marker, 1, true) ~= nil end
  if type(value) ~= "table" then return false end
  seen = seen or {}
  if seen[value] then return false end
  seen[value] = true
  for key, child in pairs(value) do if contains(key, marker, seen) or contains(child, marker, seen) then return true end end
  return false
end

it("keeps successful numeric receipt identity and status after releasing exact execution graphs", function()
  local result, ctx = gate()
  assert.is_true(result[1], tostring(result[2]))
  local before = adapters.human.inspect(1)
  assert.is_table(before.binding)
  assert.is_number(before.binding.call_id)
  local call_id = before.binding.call_id
  assert.same({ true, "body completed" }, { result[3](ctx) })
  local receipt = adapters.human.inspect(1)
  assert.is_table(receipt)
  assert.equals(1, receipt.id)
  assert.is_true(receipt.terminal)
  assert.is_true(receipt.execution_started)
  assert.equals(call_id, receipt.binding.call_id)
  local retained, exposed = {}, {}
  for _, marker in ipairs({ input_marker, source_marker, target_marker }) do
    retained[marker] = contains(records[1], marker)
    exposed[marker] = contains(receipt, marker)
  end
  local absent = { [input_marker] = false, [source_marker] = false, [target_marker] = false }
  assert.same({ retained = absent, exposed = absent, input = false, source = false }, {
    retained = retained, exposed = exposed, input = receipt.binding.input ~= nil, source = receipt.binding.definition.source ~= nil,
  })
end)

it("keeps denied exact receipts actionable until task cleanup", function()
  policy.decision = "deny"
  local result, ctx = gate()
  assert.is_false(result[1])
  local receipt = adapters.human.inspect(1)
  assert.is_true(receipt.terminal)
  assert.is_false(receipt.execution_started)
  assert.equals(input_marker, receipt.binding.input.private)
  assert.is_true(contains(records[1], source_marker))
  assert.is_true(contains(records[1], target_marker))
  local accepted, reason = adapters.human.reopen(1, ctx)
  assert.is_false(accepted)
  assert.equals("replay unavailable; inspection only", reason)
  adapters.human.reset(1)
  assert.is_nil(adapters.human.inspect(1))
  assert.is_nil(records[1])
end)
