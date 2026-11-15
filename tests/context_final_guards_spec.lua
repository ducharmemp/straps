local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(vim.fn.fnamemodify(here, ":p"), ":h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
local straps = require("straps")
local registry = require("straps.registry")
local state = require("straps.state")
local management = require("straps.context_management")
local buffers, paths = {}, {}
local assertion = 0
local function check(value)
  assertion = assertion + 1
  if tonumber(vim.env.STRAPS_FINAL_GUARD_ASSERTION) == assertion then value = not value end
  assert(value, "final guard assertion " .. assertion)
end
local function content(b) return vim.api.nvim_buf_get_lines(b, 0, -1, false) end
local function fixture(durable)
  local b = vim.api.nvim_create_buf(false, true)
  buffers[#buffers + 1] = b
  if durable then
    local path = vim.fn.tempname()
    paths[#paths + 1] = path
    vim.bo[b].buftype = ""
    vim.api.nvim_buf_set_name(b, path)
  end
  state.append(b, "user", nil, "original input")
  return b
end
before_each(function()
  require("straps.provider").register()
  straps.config.context_management = { enabled = true, input_limit = 10000, reserve_tokens = 1000 }
  registry.define({ name = "fn.provider", kind = "fn", source = "return function() error('unexpected dispatch') end" })
end)
after_each(function()
  _G.final_guard_budget = nil
  for _, b in ipairs(buffers) do if vim.api.nvim_buf_is_valid(b) then vim.api.nvim_buf_delete(b, { force = true }) end end
  for _, path in ipairs(paths) do vim.fn.delete(path) end
  buffers, paths = {}, {}
end)
for _, operation in ipairs({ "append", "consume" }) do
  for _, mutation in ipairs({ "live", "disk" }) do
    it("preserves " .. mutation .. " edits from cancellation during pending " .. operation, function()
      local b = fixture(true)
      if operation == "consume" then
        assert.are.equal("committed_live", management.append_result(b, { id = "evidence" }, "evidence").status)
      end
      local capture = assert(management.snapshot_pending(b))
      local expected = content(b)
      local path = vim.api.nvim_buf_get_name(b)
      local ctx = { bufnr = b, cancelled = function()
        if mutation == "live" then
          state.append(b, "user", nil, "callback input")
          expected = content(b)
        else
          vim.fn.writefile({ "callback disk input" }, path)
        end
        return false
      end }
      local result = operation == "append" and management.append_result(b, { id = "new" }, "new evidence", ctx)
        or management.consume_pending(capture, ctx)
      check(result.status == "conflict")
      check(vim.deep_equal(expected, content(b)))
      check(management.has_pending(b) == (operation == "consume"))
      if mutation == "disk" then check(vim.deep_equal({ "callback disk input" }, vim.fn.readfile(path))) end
    end)
  end
end
for _, mutation in ipairs({ "live", "disk", "tools", "request", "config", "context", "cancel" }) do
  it("refuses below-trigger requests after " .. mutation .. " callback mutation", function()
    local b = fixture(true)
    local tools = { { name = "original" } }
    local ctx = { bufnr = b }
    local expected = content(b)
    local calls, dispatched = 0, false
    local function mutate(prepared)
      if mutation == "live" or mutation == "cancel" then
        state.append(b, "user", nil, "callback input")
        expected = content(b)
      elseif mutation == "disk" then vim.fn.writefile({ "callback disk input" }, vim.api.nvim_buf_get_name(b))
      elseif mutation == "tools" then tools[1].name = "changed"
      elseif mutation == "request" then prepared.body.system = "changed"
      elseif mutation == "config" then straps.config.context_management.trigger = 0.99
      elseif mutation == "context" then ctx.bufnr = fixture(false) end
    end
    if mutation == "cancel" then ctx.cancelled = function() mutate(); return false end end
    _G.final_guard_budget = function(prepared)
      calls = calls + 1
      if mutation ~= "cancel" then mutate(prepared) end
      return { tokens = 1, limit = 10000 }
    end
    registry.define({ name = "fn.context_budget", kind = "fn", source = "return function(p) return _G.final_guard_budget(p) end" })
    local ok = pcall(function()
      management.boundary(b, ctx, {}, tools)
      dispatched = true
    end)
    check(ok == false)
    check(dispatched == false)
    check(vim.deep_equal(expected, content(b)))
    check(calls <= 1)
    if mutation == "disk" then check(vim.deep_equal({ "callback disk input" }, vim.fn.readfile(vim.api.nvim_buf_get_name(b)))) end
  end)
end
