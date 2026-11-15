local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(here, ":p:h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
vim.env.XDG_CONFIG_HOME = vim.fn.tempname()
local straps, registry = require("straps"), require("straps.registry")
require("straps.provider").register()
local state, management = require("straps.state"), require("straps.context_management")
local summary = require("straps.context_summary")
local defaults, attempt, policy = vim.deepcopy(straps.config), summary.new_attempt, registry.get("fn.context_plan")
local archive = require("straps.context_archive")
local create, buffers, assertion = archive.create, {}, 0
local function check(value)
  assertion = assertion + 1
  if tonumber(vim.env.STRAPS_MULTISPAN_ASSERTION) == assertion then value = not value end
  assert(value, "multispan assertion " .. assertion)
end
local function fixture()
  local b = vim.api.nvim_create_buf(false, true)
  buffers[#buffers + 1] = b
  state.append(b, "system", nil, "instructions")
  for i = 1, 4 do
    state.append(b, "user", nil, "constraint " .. i)
    state.append(b, "assistant", nil, "claim " .. i)
    state.append(b, "tool_use", { id = tostring(i), name = "read_file" }, "{}")
    state.append(b, "tool_result", { id = tostring(i) }, string.rep("evidence", 1400))
  end
  return b, { bufnr = b, cancelled = function() return false end }
end
local function content(b) return vim.api.nvim_buf_get_lines(b, 0, -1, false) end
local function define(name, source) registry.define({ name = name, kind = "fn", source = source }) end
before_each(function()
  straps.config = vim.deepcopy(defaults)
  straps.config.session_dir = vim.fn.tempname()
  straps.config.context_management = { enabled = true, mode = "summary", input_limit = 100000,
    reserve_tokens = 1000, trigger = 0.001, target = 0.95, minimum_savings = 20 }
  registry.define(policy)
  define("fn.provider", "return function() error('no dispatch') end")
  define("fn.context_budget", [[return function(p)
    local text=vim.json.encode(p.body)
    local _,n=text:gsub('Assistant summary of archived','')
    return {tokens=1000-n*300,limit=1000,source='fixture',exact=true}
  end]])
end)
after_each(function()
  summary.new_attempt, archive.create = attempt, create
  _G.span_modes, _G.span_effect = nil, nil
  for _, b in ipairs(buffers) do if vim.api.nvim_buf_is_valid(b) then vim.api.nvim_buf_delete(b, { force = true }) end end
  buffers = {}
end)
it("fits only joint spans with one shared attempt and preserves each user position", function()
  local b, c = fixture()
  straps.config.context_management.target = 0.5
  local starts, calls = 0, 0
  summary.new_attempt = function()
    starts = starts + 1
    return { generate = function(sources)
      calls = calls + 1
      return { summary = "summary " .. calls, sources = sources }
    end }
  end
  management.boundary(b, c, {}, {})
  check(starts == 1 and calls == 2)
  check(#vim.b[b].straps_context_compaction.archives == 2)
  local text = table.concat(content(b), '\n')
  check(text:find('constraint 1', 1, true) < text:find('summary 1', 1, true))
  check(text:find('summary 1', 1, true) < text:find('constraint 2', 1, true))
  check(text:find('constraint 2', 1, true) < text:find('summary 2', 1, true))
  check(vim.b[b].straps_context_compaction.after.tokens == 400)
end)
it("does not partially adopt when later span exhausts a shared real attempt", function()
  local b, c = fixture()
  straps.config.context_management.target = 0.5
  straps.config.context_management.summary = { max_calls = 1 }
  local calls = 0
  _G.span_effect = function() calls = calls + 1 end
  define("fn.context_summarize", [[return function(r)
    _G.span_effect()
    local refs={} for _,s in ipairs(r.sources) do refs[#refs+1]=s.ref end
    return {summary='bounded',complete=true,source_refs=refs,stop_reason='end_turn'}
  end]])
  local old = content(b)
  check(not pcall(management.boundary, b, c, {}, {}))
  check(calls == 1)
  check(vim.deep_equal(old, content(b)))
  check(not pcall(management.boundary, b, c, {}, {}))
  check(calls == 1)
  straps.config.context_management.retry = true
  check(not pcall(management.boundary, b, c, {}, {}))
  check(calls == 2)
end)
for _, kind in ipairs({ "generation", "budget", "invalid", "cancelled", "internal" }) do
  it("restricts fallback to typed spending failures " .. kind, function()
    local b, c = fixture()
    straps.config.context_management.fallback = "mechanical"
    local calls = 0
    summary.new_attempt = function() return { generate = function()
      calls = calls + 1
      return nil, "synthetic " .. kind, {kind=kind}
    end } end
    define("fn.context_budget", "return function() return {tokens=100,limit=1000} end")
    _G.span_modes = {}
    define("fn.context_plan", [[return function(i)
      _G.span_modes[#_G.span_modes+1]=i.mode
      local s={} for _,v in ipairs(i.eligible) do s[#s+1]=v.index end
      return {version=1,snapshot_id=i.snapshot_id,selections=s}
    end]])
    local old = content(b)
    local ok = pcall(management.preview, b, c, {generate=true})
    local allowed = kind == "generation" or kind == "budget"
    check(ok == allowed)
    check(#_G.span_modes == (allowed and 2 or 1))
    check(_G.span_modes[1] == 'summary' and (not allowed or _G.span_modes[2] == 'mechanical'))
    check(calls == 1)
    check(vim.deep_equal(old, content(b)))
    pcall(management.preview, b, c, {generate=true})
    check(calls == 1)
  end)
end
for _, dimension in ipairs({ "source", "pin", "config", "cancel" }) do
  it("forbids fallback after generation callback changes " .. dimension, function()
    local b, c = fixture()
    straps.config.context_management.fallback = "mechanical"
    local stop, modes = false, 0
    c.cancelled = function() return stop end
    _G.span_effect = function() modes = modes + 1 end
    define("fn.context_plan", [[return function(i) _G.span_effect(); return {version=1,snapshot_id=i.snapshot_id,selections={1}} end]])
    summary.new_attempt = function() return { generate = function(sources)
      if dimension == "source" then state.append(b, "user", nil, "edit") end
      if dimension == "pin" then management.pin(b, sources[1].first_block, sources[#sources].last_block) end
      if dimension == "config" then straps.config.context_management.target = 0.1 end
      if dimension == "cancel" then stop = true end
      return nil, "failure", {kind="generation"}
    end } end
    check(not pcall(management.preview, b, c, {generate=true}))
    check(modes == 1)
  end)
end
it("falls back after aggregate fit failure and retries mechanically without more summary spending", function()
  local b, c = fixture()
  straps.config.context_management.target = 0.2
  straps.config.context_management.fallback = "mechanical"
  local calls = 0
  summary.new_attempt = function() return { generate = function(sources)
    calls = calls + 1
    return {summary='bounded',sources=sources}
  end } end
  _G.span_modes = {}
  define("fn.context_plan", [[return function(i)
    _G.span_modes[#_G.span_modes+1]=i.mode
    local s={} for _,v in ipairs(i.eligible) do s[#s+1]=v.index end
    return {version=1,snapshot_id=i.snapshot_id,selections=s}
  end]])
  local old = content(b)
  local p = management.preview(b, c, {generate=true})
  check(calls == 2)
  check(#p.proposals == 2 and p.proposals[1].summary == nil)
  check(#_G.span_modes == 2 and _G.span_modes[2] == 'mechanical')
  check(vim.deep_equal(old, content(b)))
  local q = management.preview(b, c, {generate=true})
  check(calls == 2)
  check(#q.proposals == 2 and _G.span_modes[4] == 'mechanical')
end)
it("never invokes fallback after archive failure", function()
  local b, c = fixture()
  straps.config.context_management.fallback = "mechanical"
  local calls, modes = 0, 0
  summary.new_attempt = function() return { generate = function(sources)
    calls = calls + 1
    return {summary='bounded',sources=sources}
  end } end
  _G.span_effect = function() modes=modes+1 end
  define('fn.context_plan', [[return function(i)
    _G.span_effect(); return {version=1,snapshot_id=i.snapshot_id,selections={1}}
  end]])
  archive.create = function() return nil, 'archive failure' end
  local old = content(b)
  check(not pcall(management.boundary, b, c, {}, {}))
  check(calls == 1 and modes == 1)
  check(vim.deep_equal(old, content(b)))
end)
for _, dimension in ipairs({ "source", "config", "later_pin" }) do
  it("stops a real fragmented attempt after first-call mutation " .. dimension, function()
    local b, c = fixture()
    straps.config.context_management.fallback = 'mechanical'
    straps.config.context_management.summary = {max_input_tokens=2400}
    local calls, modes = 0, 0
    _G.span_effect = function()
      calls=calls+1
      if dimension == 'source' then state.append(b, 'user', nil, 'changed') end
      if dimension == 'config' then straps.config.context_management.target=0.1 end
      if dimension == 'later_pin' then management.pin(b, 7, 9) end
    end
    _G.span_modes = function() modes=modes+1 end
    define('fn.context_plan', [[return function(i)
      _G.span_modes(); return {version=1,snapshot_id=i.snapshot_id,selections={1,2}}
    end]])
    define('fn.context_summarize', [[return function(r)
      _G.span_effect()
      local refs={} for _,s in ipairs(r.sources) do refs[#refs+1]=s.ref end
      return {summary='bounded',complete=true,source_refs=refs,stop_reason='end_turn'}
    end]])
    check(not pcall(management.preview, b, c, {generate=true}))
    check(calls == 1)
    check(modes == 1)
    check(not table.concat(content(b), '\n'):find('[straps-context:', 1, true))
  end)
end
it("requires explicit fallback and refuses invalid fallback policy without archive creation", function()
  local b, c = fixture()
  summary.new_attempt = function() return { generate = function() return nil, 'failed', {kind='generation'} end } end
  local old = content(b)
  check(not pcall(management.preview, b, c, {generate=true}))
  straps.config.context_management.fallback = "mechanical"
  define("fn.context_plan", [[return function(i)
    return {version=1,snapshot_id=i.snapshot_id,selections=i.mode=='mechanical' and {999} or {1}}
  end]])
  local archives = 0
  archive.create = function(...) archives=archives+1; return create(...) end
  check(not pcall(management.preview, b, c, {generate=true}))
  check(archives == 0)
  check(vim.deep_equal(old, content(b)))
end)
