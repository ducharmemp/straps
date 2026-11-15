local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(here, ":p:h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. package.path

it("retains rejected decision families across stop in the same task and epoch", function()
  for _, name in ipairs({ "contextual", "registry", "authorization", "consent" }) do package.loaded["straps." .. name] = nil end
  local registry = require("straps.registry")
  local authorization = require("straps.authorization")
  local contextual
  if vim.env.STRAPS_DECISION_MUTANT then
    local source = table.concat(vim.fn.readfile(root .. "/lua/straps/contextual.lua"), "\n")
    local target = 'if reason == "stopped" then consent.invalidate_session(stamp.session_id, reason)'
    local first, last = assert(source:find(target, 1, true))
    contextual = assert(loadstring(source:sub(1, first - 1) .. 'if reason == "stopped" then consent.retire_session(stamp.session_id, reason)' .. source:sub(last + 1)))()
  else contextual = require("straps.contextual") end
  local adapters, adoption, screens = {}, nil, {}
  registry.define({ name = "tool.sample", kind = "tool", source = "return function() return true end" })
  local fields = { "outcome", "mode", "targets", "effects", "constraints", "reserved_decisions", "latitude", "unresolved_scope" }
  local config = {
    enabled = true, disclosure = { approved = true },
    limits = { max_bytes = 1048576, max_depth = 32, max_items = 10000 },
    receipts = {
      identity = function() return "composer" end,
      validate = function() return true end,
      prepare_adoption = function() return { transcript = "exact task", options = {} }, {} end,
      adopt = function(_, current) return current() end,
    },
    run_human = function(bufnr, fn) fn({ bufnr = bufnr, cancelled = function() return false end }) end,
    discover = function() return { id = "standing", config_hash = "config", sources = {} } end,
    adopt = function(_, answer) adoption = answer end,
    consent_display = function(view, answer) screens[#screens + 1] = { view = view, answer = answer } end,
    resolve_targets = function() return { known = { cwd = "local" }, unresolved = {}, checks = { "cwd" } } end,
    validate_targets = function() return true end,
    assessor_factory = function()
      return {
        synthesize = function(snapshot)
          local spec = { schema_version = 1, task_id = snapshot.task_id, instruction_revision = snapshot.epoch }
          for _, name in ipairs(fields) do spec[name] = { value = {}, sources = { snapshot.adopted[1] } } end
          spec.outcome.value, spec.mode.value = "local work", "implementation"
          return spec, { unsupported_authority = false, untrusted_authority = false, omitted_constraint = false,
            expanded_scope = false, lost_authorization = false, hidden_ambiguity = false }
        end,
        assess = function()
          return { decision = "ask", decision_identity = { boundary = "restart", targets = { "host" }, effects = { "restart" } } }
        end,
      }
    end,
    install = {},
  }
  for _, name in ipairs({ "human", "loop" }) do
    local key = name
    config.install[key] = function(adapter) adapters[key] = adapter end
  end
  contextual.setup(config)
  adapters.human.create(1)
  local enqueued = false
  adapters.human.submit(1, "local work", function() enqueued = true end)
  assert.is_function(adoption)
  adoption(true)
  assert.is_true(enqueued)
  local function attempt()
    local ctx = { bufnr = 1, await = function(begin)
      local result
      begin(function(value) result = value end)
      screens[#screens].answer("reject")
      return result
    end }
    local family = adapters.loop.begin(ctx)
    local allowed = registry.gate_tool("sample", {}, ctx)
    adapters.loop.finish(family)
    return allowed
  end
  assert.is_false(attempt())
  assert.equals(1, #screens)
  assert.is_false(attempt())
  assert.equals(1, #screens, "rejected family is suppressed before stop")
  local before = authorization.snapshot(1)
  adapters.loop.stop(1)
  local after = authorization.snapshot(1)
  assert.equals(before.task_id, after.task_id)
  assert.equals(before.epoch, after.epoch)
  assert.equals("active", after.status)
  assert.is_false(attempt())
  assert.equals(1, #screens, "stop must preserve rejection suppression until human reopen or task revision")
end)
