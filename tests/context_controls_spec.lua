local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(vim.fn.fnamemodify(here, ":p"), ":h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
vim.env.XDG_CONFIG_HOME = vim.fn.tempname()
local straps = require("straps")
local registry = require("straps.registry")
require("straps.provider").register()
local state = require("straps.state")
local management = require("straps.context_management")
local archive = require("straps.context_archive")
local summary = require("straps.context_summary")
local defaults = vim.deepcopy(straps.config)
local generate, create, persist = summary.generate, archive.create, management.persist_checked
local original_attempt = summary.new_attempt
summary.new_attempt = function(opts, ctx)
  if summary.generate == generate then return original_attempt(opts, ctx) end
  return { generate = function(sources) return summary.generate(sources, opts, ctx) end }
end
local buffers, assertion = {}, 0
local function check(value)
  assertion = assertion + 1
  if tonumber(vim.env.STRAPS_CONTROLS_ASSERTION) == assertion then value = not value end
  assert(value, "controls assertion " .. assertion)
end
local function content(b) return vim.api.nvim_buf_get_lines(b, 0, -1, false) end
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
  state.append(b, "user", nil, "continue")
  return b, { bufnr = b, cancelled = function() return false end }
end
local function preview(b, c, opts) return management.preview(b, c, opts or {}) end
local function refuses(b, c, p, tools, note)
  local original = content(b)
  check(not pcall(management.apply, b, c, p, tools, note))
  check(vim.deep_equal(original, content(b)))
  check(vim.b[b].straps_context_compaction.status == "refused")
end
before_each(function()
  straps.config = vim.deepcopy(defaults)
  straps.config.session_dir = vim.fn.tempname()
  straps.config.context_management = { enabled = true, mode = "mechanical", input_limit = 100000,
    reserve_tokens = 1000, trigger = 0.001, target = 0.95, minimum_savings = 20 }
  registry.define({ name = "fn.provider", kind = "fn", source = "return function() error('no dispatch') end" })
end)
after_each(function()
  summary.generate, archive.create, management.persist_checked = generate, create, persist
  for _, b in ipairs(buffers) do if vim.api.nvim_buf_is_valid(b) then vim.api.nvim_buf_delete(b, { force = true }) end end
  buffers = {}
end)
it("returns detached data and applies captured request inputs once", function()
  local b, c = fixture()
  local tools = { { name = "exact-tool" } }
  local p = preview(b, c, { tools = tools, note = "exact note" })
  local function data(value)
    if type(value) == "function" then return false end
    if type(value) == "table" then for _, item in pairs(value) do if not data(item) then return false end end end
    return true
  end
  check(data(p))
  tools[1].name = "mutated caller copy"
  local req = management.apply(b, c, p)
  check(req.tools[1].name == "exact-tool")
  check(req.system:find("exact note", 1, true) ~= nil)
  local metrics = vim.b[b].straps_context_compaction
  check(metrics.status == "applied" and metrics.before.tokens > metrics.after.tokens)
  check(metrics.first_block == 5 and metrics.last_block == 8 and metrics.earliest_line == p.replacements[1].first)
  check(#metrics.archives == 2)
  refuses(b, c, p)
end)
it("rejects fabricated copied and modified reports and consumes failed attempts", function()
  local b, c = fixture()
  local p = preview(b, c)
  refuses(b, c, vim.deepcopy(p))
  p.lines[1] = "forged"
  refuses(b, c, p)
  p.lines[1] = p.original[1]
  refuses(b, c, p)
  refuses(b, c, nil)
end)
it("binds buffer and exact context identity", function()
  local b, c = fixture()
  local other, nextctx = fixture()
  local p = preview(b, c)
  refuses(other, nextctx, p)
  refuses(b, c, p)
  refuses(b, { bufnr = b }, preview(b, c))
end)
for _, dimension in ipairs({ "source", "append", "config", "model", "disabled", "cancelled", "pin", "retrieval", "tools", "note" }) do
  it("invalidates a preview after " .. dimension .. " changes", function()
    local b, c = fixture()
    local p = preview(b, c, { tools = {}, note = "note" })
    local tools, note
    if dimension == "source" then vim.api.nvim_buf_set_lines(b, 0, 1, false, { "changed" }) end
    if dimension == "append" then state.append(b, "user", nil, "later") end
    if dimension == "config" then straps.config.context_management.target = 0.8 end
    if dimension == "model" then straps.config.model = "changed" end
    if dimension == "disabled" then straps.config.context_management.enabled = false end
    if dimension == "cancelled" then c.cancelled = function() return true end end
    if dimension == "pin" then management.pin(b, 5, 5) end
    if dimension == "retrieval" then management.protect(b) end
    if dimension == "tools" then tools = { { name = "changed" } } end
    if dimension == "note" then note = "changed" end
    refuses(b, c, p, tools, note)
    refuses(b, c, p)
  end)
end
it("rechecks supplied request tables after replaceable accounting", function()
  local b, c = fixture()
  local tools = { { name = "original" } }
  local account = registry.get("fn.context_budget")
  registry.define({ name = "fn.context_budget", kind = "fn", source = [[return function(req,ctx)
    if _G.controls_tools then _G.controls_tools[1].name = 'changed' end
    return require('straps.context_management').account(req,ctx)
  end]] })
  local p = preview(b, c, { tools = tools })
  _G.controls_tools = tools
  local ok = pcall(management.apply, b, c, p, tools)
  registry.define(account)
  _G.controls_tools = nil
  check(not ok)
  check(content(b)[1] == p.original[1])
end)
it("rejects context rebinding during preview and adoption accounting", function()
  local account = registry.get("fn.context_budget")
  registry.define({ name = "fn.context_budget", kind = "fn", source = [[return function(req,ctx)
    local result = require('straps.context_management').account(req,ctx)
    if _G.controls_rebind then ctx.bufnr = -1 end
    return result
  end]] })
  local b, c = fixture()
  _G.controls_rebind = true
  local original = content(b)
  check(not pcall(preview, b, c))
  check(vim.deep_equal(original, content(b)))
  c.bufnr, _G.controls_rebind = b, nil
  local p = preview(b, c)
  _G.controls_rebind = true
  refuses(b, c, p)
  _G.controls_rebind = nil
  registry.define(account)
end)
for _, stage in ipairs({ "preview", "apply" }) do
  local dimensions = { "buffer", "source", "config", "model", "disabled", "pin", "retrieval" }
  if stage == "apply" then vim.list_extend(dimensions, { "tools", "note", "report" }) end
  for _, dimension in ipairs(dimensions) do
    it("rejects " .. dimension .. " mutation in final " .. stage .. " cancellation callback", function()
      local b, c = fixture()
      local tools, note = { { name = "original" } }, { "original" }
      local p = stage == "apply" and preview(b, c, { tools = tools, note = note }) or nil
      local counts, callbacks, armed = 0, 0, stage == "preview"
      local original = content(b)
      local expected = original
      c.cancelled = function()
        if not armed then return false end
        callbacks = callbacks + 1
        c.cancelled = function() error("validation repeated cancellation callback") end
        if dimension == "buffer" then c.bufnr = -1 end
        if dimension == "source" then state.append(b, "user", nil, "callback edit"); expected = content(b) end
        if dimension == "config" then straps.config.context_management.target = 0.8 end
        if dimension == "model" then straps.config.model = "callback model" end
        if dimension == "disabled" then straps.config.context_management.enabled = false end
        if dimension == "pin" then management.pin(b, 5, 5) end
        if dimension == "retrieval" then management.protect(b) end
        if dimension == "tools" then tools[1].name = "callback tool" end
        if dimension == "note" then note[1] = "callback note" end
        if dimension == "report" then p.original[1] = "callback report" end
        return false
      end
      local old_account = management.account
      if stage == "apply" then
        management.account = function(...)
          local result = old_account(...)
          counts = counts + 1
          if counts == 3 then armed = true end
          return result
        end
      end
      local ok = pcall(function()
        if p then management.apply(b, c, p, tools, note) else preview(b, c, { tools = tools, note = note }) end
      end)
      management.account = old_account
      check(callbacks == 1)
      check(not ok)
      check(vim.deep_equal(expected, content(b)))
      check(vim.b[b].straps_context_compaction.status == "refused")
    end)
  end
end
for _, stage in ipairs({ "preview", "apply" }) do
  for _, preference in ipairs({ "provider", "model" }) do
    local dimensions = { "buffer", "tools", "note", "selected_provider", "selected_model", "provider_definition", "model_entry", "unchanged" }
    if stage == "apply" then dimensions[#dimensions + 1] = "report" end
    for _, dimension in ipairs(dimensions) do
      it("checks " .. dimension .. " after final " .. stage .. " " .. preference .. " preference callbacks", function()
        local b, c = fixture()
        local tools, note = { { name = "original" } }, { "original" }
        local old_provider, old_model = registry.get("fn.provider_pref"), registry.get("fn.model_pref")
        straps.config.provider, straps.config.model, straps.config.models = nil, nil, {}
        registry.define({ name = "fn.provider_pref", kind = "fn", source = [[return function()
          if _G.controls_preference then _G.controls_preference('provider') end
          return 'anthropic'
        end]] })
        registry.define({ name = "fn.model_pref", kind = "fn", source = [[return function()
          if _G.controls_preference then _G.controls_preference('model') end
          return 'controls-model'
        end]] })
        local p = stage == "apply" and preview(b, c, { tools = tools, note = note }) or nil
        local counts, calls, armed = 0, 0, false
        local expected_calls = preference == "provider" and 1 or 2
        local original = content(b)
        _G.controls_preference = function(kind)
          if not armed or kind ~= preference then return end
          calls = calls + 1
          if calls ~= expected_calls then return end
          if dimension == "buffer" then c.bufnr = -1 end
          if dimension == "tools" then tools[1].name = "callback tool" end
          if dimension == "note" then note[1] = "callback note" end
          if dimension == "report" then p.original[1] = "callback report" end
          if dimension == "selected_provider" then straps.config.provider = "openai" end
          if dimension == "selected_model" then straps.config.model = "callback model" end
          if dimension == "provider_definition" then
            registry.define({ name = "fn.provider", kind = "fn", source = "return function() error('changed dispatch') end" })
          end
          if dimension == "model_entry" then straps.config.models = { { id = 'controls-model', context = 12345 } } end
        end
        local old_account = management.account
        if stage == "apply" then
          management.account = function(...)
            local result = old_account(...)
            counts = counts + 1
            if counts == 3 then armed = true end
            return result
          end
        else
          c.cancelled = function() armed = true; return false end
        end
        local ok = pcall(function()
          if p then management.apply(b, c, p, tools, note) else preview(b, c, { tools = tools, note = note }) end
        end)
        management.account, _G.controls_preference = old_account, nil
        registry.define(old_provider)
        registry.define(old_model)
        check(dimension == "unchanged" and calls >= expected_calls or calls == expected_calls)
        check(ok == (dimension == "unchanged"))
        check(vim.deep_equal(original, content(b)) == (dimension ~= "unchanged" or stage == "preview"))
        check(vim.b[b].straps_context_compaction.status == (dimension == "unchanged" and (p and "applied" or "preview") or "refused"))
      end)
    end
  end
end
it("claims a candidate before reentrant replaceable work", function()
  local b, c = fixture()
  local p = preview(b, c)
  local calls, rejected = 0, false
  archive.create = function(...)
    calls = calls + 1
    rejected = not pcall(management.apply, b, c, p)
    return create(...)
  end
  management.apply(b, c, p)
  check(rejected)
  check(calls == 2)
  refuses(b, c, p)
end)
it("applies generated previews without generating again despite attempt suppression", function()
  local b, c = fixture()
  straps.config.context_management.mode = "summary"
  local calls = 0
  summary.generate = function(sources) calls = calls + 1; return { sources = sources, summary = "exact summary" } end
  local p = preview(b, c, { generate = true })
  check(calls == 1)
  check(#preview(b, c, { generate = true }).proposals == 0)
  management.apply(b, c, p)
  check(calls == 1)
  check(table.concat(content(b), "\n"):find("exact summary", 1, true) ~= nil)
end)
it("requires explicit generation and consumes nongenerated reports", function()
  local b, c = fixture()
  straps.config.context_management.mode = "summary"
  summary.generate = function() error("must not generate") end
  local p = preview(b, c)
  check(p.needs_generation == true)
  refuses(b, c, p)
end)
it("rejects generation-time source and effective configuration mutations", function()
  for _, dimension in ipairs({ "source", "model", "config" }) do
    local b, c = fixture()
    straps.config.context_management.mode = "summary"
    summary.generate = function(sources)
      if dimension == "source" then state.append(b, "user", nil, "changed during generation") end
      if dimension == "model" then straps.config.model = "different" end
      if dimension == "config" then straps.config.context_management.target = 0.5 end
      return { sources = sources, summary = "summary" }
    end
    check(not pcall(preview, b, c, { generate = true }))
  end
end)
it("accepts only finite integer existing pin endpoints", function()
  local b = fixture()
  for _, range in ipairs({ { 0, 1 }, { 1.5, 2 }, { 1, 2.5 }, { 1, math.huge }, { 1, 1000 }, { 0/0, 2 } }) do
    check(not pcall(management.pin, b, range[1], range[2]))
  end
end)
it("keeps disjoint pins valid after appends including a captured final block", function()
  local b, c = fixture()
  management.pin(b, 2, 2)
  state.append(b, "user", nil, "appended")
  check(#preview(b, c).replacements == 2)
  management.unpin(b)
  management.pin(b, #state.list_blocks(b), #state.list_blocks(b))
  state.append(b, "user", nil, "final-block separator append")
  check(#preview(b, c).replacements == 2)
end)
it("protects overlap and conservatively refuses changed prefixes", function()
  local b, c = fixture()
  management.pin(b, 5, 5)
  local p = preview(b, c)
  check(#p.replacements == 1 and p.proposals[1].first_block == 8)
  vim.api.nvim_buf_set_lines(b, 0, 1, false, { "%%[straps:system]%% changed prefix" })
  check(#preview(b, c).replacements == 0)
  management.unpin(b)
  check(#preview(b, c).replacements == 2)
end)
it("records refusal counts and consumes persistence failures while retaining retrieval evidence", function()
  local b, c = fixture()
  local original = content(b)
  local p = preview(b, c)
  management.persist_checked = function() return nil, "injected failure", "unchanged" end
  refuses(b, c, p)
  local m = vim.b[b].straps_context_compaction
  check(m.before.tokens > m.after.tokens and #m.archives == 2)
  check(archive.get(b, m.archives[1]) ~= nil)
  check(vim.deep_equal(original, content(b)))
  refuses(b, c, p)
end)
it("checks durable disk identity before adoption and records persistence success", function()
  local b, c = fixture()
  vim.bo[b].buftype = ""
  vim.api.nvim_buf_set_name(b, vim.fn.tempname())
  vim.api.nvim_buf_call(b, function() vim.cmd("silent noautocmd write") end)
  local p = preview(b, c)
  vim.fn.writefile({ "external change" }, vim.api.nvim_buf_get_name(b))
  refuses(b, c, p)
  local nextbuf, nextctx = fixture()
  vim.bo[nextbuf].buftype = ""
  vim.api.nvim_buf_set_name(nextbuf, vim.fn.tempname())
  vim.api.nvim_buf_call(nextbuf, function() vim.cmd("silent noautocmd write") end)
  management.apply(nextbuf, nextctx, preview(nextbuf, nextctx))
  check(vim.deep_equal(content(nextbuf), vim.fn.readfile(vim.api.nvim_buf_get_name(nextbuf))))
  check(vim.b[nextbuf].straps_context_compaction.status == "applied")
end)
