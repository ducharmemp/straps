local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(here, ":p:h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
vim.env.XDG_CONFIG_HOME = vim.fn.tempname()
local straps, registry = require("straps"), require("straps.registry")
require("straps.provider").register()
local state, management = require("straps.state"), require("straps.context_management")
local defaults, policy = vim.deepcopy(straps.config), registry.get("fn.context_plan")
local buffers, assertion = {}, 0
local function check(value)
  assertion = assertion + 1
  if tonumber(vim.env.STRAPS_POLICY_ASSERTION) == assertion then value = not value end
  assert(value, "policy assertion " .. assertion)
end
local function define(source) registry.define({ name = "fn.context_plan", kind = "fn", source = source }) end
local function fixture()
  local b = vim.api.nvim_create_buf(false, true)
  buffers[#buffers + 1] = b
  state.append(b, "system", nil, "instructions")
  state.append(b, "user", nil, "constraint")
  for i = 1, 4 do
    state.append(b, "assistant", nil, "claim " .. i)
    state.append(b, "tool_use", { id = tostring(i), name = "read_file" }, "{}")
    state.append(b, "tool_result", { id = tostring(i) }, string.rep("evidence", 1400))
  end
  return b, { bufnr = b, cancelled = function() return false end }
end
local function content(b) return vim.api.nvim_buf_get_lines(b, 0, -1, false) end
before_each(function()
  straps.config = vim.deepcopy(defaults)
  straps.config.session_dir = vim.fn.tempname()
  straps.config.context_management = { enabled = true, mode = "mechanical", input_limit = 100000,
    reserve_tokens = 1000, trigger = 0.001, target = 0.95, minimum_savings = 20 }
  registry.define(policy)
  registry.define({ name = "fn.provider", kind = "fn", source = "return function() error('no dispatch') end" })
end)
after_each(function()
  _G.policy_effect = nil
  for _, b in ipairs(buffers) do if vim.api.nvim_buf_is_valid(b) then vim.api.nvim_buf_delete(b, { force = true }) end end
  buffers = {}
end)
it("late binds ordered policy selection and supplies detached eligible records", function()
  local b, c = fixture()
  local p = management.preview(b, c)
  check(#p.proposals == 2)
  define([[return function(input)
    assert(input.version == 1 and input.reason == 'explicit' and input.mode == 'mechanical')
    assert(type(input.snapshot_id) == 'string' and input.before.tokens > 0 and input.target_tokens > 0)
    assert(input.eligible[2].index == 2 and input.eligible[2].sources[1].kind == 'tool_result')
    return {version=1, snapshot_id=input.snapshot_id, selections={2}}
  end]])
  local q = management.preview(b, c)
  check(#q.proposals == 1 and q.proposals[1].first_block == 8)
  check(not pcall(management.apply, b, c, p))
  management.apply(b, c, q)
  local text = table.concat(content(b), '\n')
  check(text:find('evidenceevidence', 1, true) ~= nil)
  check(vim.b[b].straps_context_compaction.first_block == 8)
end)
for _, expression in ipairs({ "{2,1}", "{1,1}", "{999}", "{0}", "{1.5}", "{[2]=1}", "{[1]=1,[3]=2}", "{extra=1}", "{false}" }) do
  it("refuses malformed policy selection " .. expression, function()
    local b, c = fixture()
    local old = content(b)
    define("return function(i) return {version=1,snapshot_id=i.snapshot_id,selections=" .. expression .. "} end")
    check(not pcall(management.preview, b, c))
    check(vim.deep_equal(old, content(b)))
  end)
end
for _, mutation in ipairs({ "i.snapshot_id='other'", "i.eligible[1].sources[1].text='mutated'", "i.eligible[1].mode='summary'" }) do
  it("refuses policy input mutation " .. mutation, function()
    local b, c = fixture()
    define("return function(i) " .. mutation .. "; return {version=1,snapshot_id=i.snapshot_id,selections={1}} end")
    local old = content(b)
    check(not pcall(management.preview, b, c))
    check(vim.deep_equal(old, content(b)))
  end)
end
for _, result in ipairs({ "{version=2,snapshot_id=i.snapshot_id,selections={1}}", "{version=1,snapshot_id='other',selections={1}}", "'legacy string'" }) do
  it("refuses incompatible result " .. result, function()
    local b, c = fixture()
    define("return function(i) return " .. result .. " end")
    check(not pcall(management.preview, b, c))
  end)
end
for _, dimension in ipairs({ "source", "pin", "config", "cancel", "policy", "compact" }) do
  it("rechecks callback effects before accepting " .. dimension, function()
    local b, c = fixture()
    local stopped = false
    c.cancelled = function() return stopped end
    _G.policy_effect = function()
      if dimension == "source" then state.append(b, "user", nil, "changed") end
      if dimension == "pin" then management.pin(b, 5, 5) end
      if dimension == "config" then straps.config.context_management.target = 0.5 end
      if dimension == "cancel" then stopped = true end
      if dimension == "policy" then define("return function() end") end
      if dimension == "compact" then registry.define({name="fn.compact",kind="fn",source="return function() return 'changed' end"}) end
    end
    define([[return function(i) _G.policy_effect(); return {version=1,snapshot_id=i.snapshot_id,selections={1}} end]])
    check(not pcall(management.preview, b, c))
    check(vim.b[b].straps_context_compaction.status == "refused")
  end)
end
it("passes pressure reason without policy dispatch below trigger", function()
  local b, c = fixture()
  define([[return function(i) assert(i.reason=='pressure'); return {version=1,snapshot_id=i.snapshot_id,selections={1}} end]])
  management.boundary(b, c, {}, {})
  check(vim.b[b].straps_context_compaction.status == "applied")
  straps.config.context_management.trigger = 1
  define("return function() error('below trigger') end")
  check(pcall(management.boundary, b, c, {}, {}))
end)
