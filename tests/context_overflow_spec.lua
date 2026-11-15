local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(here, ":p:h:h")
vim.opt.runtimepath:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local registry, state, loop, management, straps, buf, calls, tools, failed
local assertion = 0
local function check(value)
  assertion = assertion + 1
  if tonumber(vim.env.STRAPS_OVERFLOW_ASSERTION) == assertion then value = not value end
  if not value then failed = "overflow assertion " .. assertion end
  assert(value, "overflow assertion " .. assertion .. "\n" .. (buf and vim.api.nvim_buf_is_valid(buf) and table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"):sub(-1500) or ""))
end
local function define(name, kind, source) registry.define({ name = name, kind = kind, source = source }) end
local function text() return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n") end
local function reject()
  error(setmetatable({ kind = "context_overflow", rejected = true, response_started = false, provider = "openai",
    route = "responses", status = 400, code = "context_length_exceeded", message = "too large" },
    { __tostring = function(e) return e.message end }), 0)
end
local function answer(ctx)
  ctx.emit({ type = "text_delta", text = "answer" })
  return { stop_reason = "end_turn", complete = true, content = { { type = "text", text = "answer" } } }
end
local function run()
  loop.start(buf)
  assert(vim.wait(3000, function() return not loop.running(buf) end, 5))
end
before_each(function()
  for _, name in ipairs({ "loop", "registry", "state", "context_management" }) do package.loaded["straps." .. name] = nil end
  registry, state = require("straps.registry"), require("straps.state")
  loop, management, straps = require("straps.loop"), require("straps.context_management"), require("straps")
  require("straps.provider").register()
  straps.config.provider, straps.config.model = 'anthropic', 'fixture'
  straps.config.session_dir = vim.fn.tempname()
  straps.config.context_management = { enabled = true, mode = "mechanical", input_limit = 100000,
    trigger = 1, target = 0.7, minimum_savings = 20, keep_turns = 2 }
  straps.config.max_turns, straps.config.stall_limit, straps.config.blank_nudge_limit = 4, 0, 0
  straps.config.auto_compact_bytes, straps.config.auto_compact_tokens = nil, nil
  calls, tools, failed = 0, 0, nil
  buf = state.new_session()
  state.append_text(buf, "initial")
  for i = 1, 3 do
    state.append(buf, "assistant", nil, "claim " .. i)
    state.append(buf, "tool_use", { id = tostring(i), name = "sample" }, "{}")
    state.append(buf, "tool_result", { id = tostring(i) }, string.rep("evidence", 400))
    state.append(buf, "user", nil, "continue " .. i)
  end
  define("hook.confirm", "hook", "return function() return true end")
  define("fn.build_tools", "fn", "return function() return {{name='sample'}} end")
  define("fn.model_note", "fn", "return function() return 'same model note' end")
  define("fn.context_budget", "fn", [[return function(p)
    local s=vim.json.encode(p.body)
    local _, n=s:gsub('archived tool evidence','')
    local _, summaries=s:gsub('Assistant summary of archived','')
    return {tokens=900-(n+summaries)*300,limit=1000,source='fixture',exact=true}
  end]])
  define("fn.provider", "fn", "return function(r,c) return _G.overflow_provider(r,c) end")
  define("tool.sample", "tool", "return function() return _G.overflow_tool() end")
  _G.overflow_tool = function() tools = tools + 1; return "tool evidence" end
  _G.overflow_provider = function(_, ctx) calls = calls + 1; if calls == 1 then reject() end; return answer(ctx) end
end)
after_each(function()
  if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end
  assert(not failed, failed)
end)
it("recounts below trigger and retries once with retained turns, tools and note", function()
  local first, second
  _G.overflow_provider = function(req, ctx)
    calls = calls + 1
    if calls == 1 then first = vim.deepcopy(req); reject() end
    second = vim.deepcopy(req)
    return answer(ctx)
  end
  run()
  check(calls == 2)
  check(vim.deep_equal(first.tools, second.tools) and first.system == second.system)
  check(text():find("answer", 1, true) ~= nil)
  check(text():find("[straps-context:", 1, true) ~= nil)
  local archived = vim.b[buf].straps_context_compaction
  check(archived.last_block == 5)
  check(text():find(string.rep("evidence", 400), 1, true) ~= nil)
end)
it("does not rerun a tool when its continuation overflows", function()
  _G.overflow_provider = function(_, ctx)
    calls = calls + 1
    if calls == 1 then return {stop_reason='tool_use',content={{type='tool_use',name='sample',id='new',input={}}}} end
    if calls == 2 then reject() end
    return answer(ctx)
  end
  run()
  check(calls == 3)
  check(tools == 1)
end)
for _, mode in ipairs({ "disabled", "string", "crafted", "cancel", "source", "config", "pin", "stream", "placeholder", "second" }) do
  it("refuses another dispatch after " .. mode, function()
    if mode == 'disabled' then straps.config.context_management.enabled = false end
    _G.overflow_provider = function(_, ctx)
      calls = calls + 1
      if mode == 'string' then error('context_length_exceeded') end
      if mode == 'crafted' then error({kind='context_overflow',rejected=true,response_started=false},0) end
      if mode == 'cancel' then loop.stop(buf) end
      if mode == 'source' then vim.api.nvim_buf_set_lines(buf,1,2,false,{'human edit'}) end
      if mode == 'config' then straps.config.context_management.target = 0.5 end
      if mode == 'pin' then management.pin(buf,3,5) end
      if mode == 'stream' then ctx.emit({type='text_delta',text='partial'}) end
      if mode == 'placeholder' then state.append_text(buf,'human placeholder edit') end
      reject()
    end
    run()
    check(calls == (mode == 'second' and 2 or 1))
    check(not loop.running(buf))
    if mode == 'source' then check(text():find('human edit',1,true) ~= nil) end
    if mode == 'placeholder' then check(text():find('human placeholder edit',1,true) ~= nil) end
    if mode == 'stream' then check(text():find('partial',1,true) ~= nil) end
  end)
end
it("refuses retry after recovery validation queues output", function()
  local recover = management.recover
  management.recover = function(...)
    local request, validate = recover(...)
    local ctx = select(2, ...)
    return request, function()
      validate()
      ctx.emit({ type = "text_delta", text = "recovery output" })
    end
  end
  local ok, err = pcall(run)
  management.recover = recover
  assert(ok, err)
  check(calls == 1)
  check(text():find("output appeared during overflow recovery", 1, true) ~= nil)
end)

it("retains pending evidence on refusal without extra retrieval resources", function()
  state.append(buf,'tool_use',{id='pending',name='context_retrieve'},'{}')
  local status = management.append_result(buf,{id='pending'},'protected pending evidence')
  check(status.status == 'committed_live')
  run()
  check(calls == 1)
  check(management.has_pending(buf))
  check(text():find('protected pending evidence',1,true) ~= nil)
end)
for _, phase in ipairs({ 'thinking', 'turn' }) do
  it("refuses recovery after a " .. phase .. " hook queues an emission", function()
    if phase == 'thinking' then
      define('hook.on_progress', 'hook', [[return function(ev,ctx)
        if ev.type == 'thinking' then ctx.emit({type='text_delta',text='queued progress text'}) end
      end]])
    else
      define('hook.on_turn_start', 'hook', [[return function(ctx)
        ctx.emit({type='text_delta',text='queued progress text'})
      end]])
    end
    run()
    check(calls == 1)
    check(text():find('queued progress text', 1, true) ~= nil)
    check(text():find('[straps-context:', 1, true) == nil)
  end)
end
for _, callback in ipairs({ 'preference', 'cancelled', 'delayed preference' }) do
  it("rejects preview context rebinding by " .. callback .. " before counting", function()
    local ctx, counted = {bufnr=buf}, 0
    _G.overflow_budget = function() counted = counted + 1; return {tokens=900,limit=1000} end
    define('fn.context_budget', 'fn', 'return function() return _G.overflow_budget() end')
    if callback ~= 'cancelled' then
      straps.config.provider, straps.config.model = nil, nil
      local preferences = 0
      _G.overflow_preference = function()
        preferences = preferences + 1
        if callback == 'preference' or preferences == 3 then ctx.bufnr = -1 end
      end
      define('fn.provider_pref', 'fn', "return function() _G.overflow_preference(); return 'anthropic' end")
    else
      ctx.cancelled = function() ctx.bufnr = -1; return false end
    end
    local ok, err = pcall(management.preview, buf, ctx, {tools={},note='note'})
    check(not ok and tostring(err):find('context buffer mismatch', 1, true) ~= nil)
    check(counted == 0)
    check(calls == 0)
  end)
end
for _, mutation in ipairs({ 'context', 'source', 'config', 'pin' }) do
  it("rejects capture preference " .. mutation .. " mutation before dispatch", function()
    straps.config.provider, straps.config.model = nil, nil
    _G.overflow_preference = function()
      if text():sub(-#'%%[straps:assistant]%%') ~= '%%[straps:assistant]%%' then return end
      if mutation == 'context' then _G.overflow_capture_ctx.bufnr = -1 end
      if mutation == 'source' then vim.api.nvim_buf_set_lines(buf,1,2,false,{'capture source edit'}) end
      if mutation == 'config' then straps.config.context_management.target = 0.5 end
      if mutation == 'pin' then management.pin(buf,3,5) end
    end
    define('fn.provider_pref', 'fn', "return function() _G.overflow_preference(); return 'anthropic' end")
    define('hook.on_turn_start','hook','return function(ctx) _G.overflow_capture_ctx = ctx end')
    run()
    check(calls == 0)
    check(text():find('[straps-context:', 1, true) == nil)
    if mutation == 'source' then check(text():find('capture source edit',1,true) ~= nil) end
  end)
end
for _, mutation in ipairs({ 'context', 'source', 'config', 'pin', 'cancel' }) do
  it("revalidates retry after pending snapshot " .. mutation .. " mutation", function()
    local snapshot = management.snapshot_pending
    management.snapshot_pending = function(...)
      local captured, status = snapshot(...)
      if calls ~= 1 or vim.b[buf].straps_context_compaction.status ~= 'applied' then return captured, status end
      if mutation == 'context' then _G.overflow_capture_ctx.bufnr = -1 end
      if mutation == 'source' then vim.api.nvim_buf_set_lines(buf,1,2,false,{'retry source edit'}) end
      if mutation == 'config' then straps.config.context_management.target = 0.5 end
      if mutation == 'pin' then management.pin(buf,3,5) end
      if mutation == 'cancel' then loop.stop(buf) end
      return captured, status
    end
    define('hook.on_turn_start','hook','return function(ctx) _G.overflow_capture_ctx = ctx end')
    run()
    check(calls == 1)
    check(text():find('\nanswer\n',1,true) == nil)
    if mutation == 'source' then check(text():find('retry source edit',1,true) ~= nil) end
  end)
end
for _, resolver in ipairs({ 'provider', 'model' }) do
  it("guards delayed " .. resolver .. " resolution mutation before budget callbacks", function()
    local ctx, counted, preferences = {bufnr=buf}, 0, 0
    straps.config.provider, straps.config.model = nil, nil
    _G.overflow_preference = function()
      preferences = preferences + 1
      if preferences == 3 then straps.config.context_management.target = 0.5 end
    end
    define('fn.' .. resolver .. '_pref', 'fn', "return function() _G.overflow_preference(); return 'anthropic' end")
    _G.overflow_budget = function() counted = counted + 1; return {tokens=900,limit=1000} end
    define('fn.context_budget','fn','return function() return _G.overflow_budget() end')
    local ok = pcall(management.preview,buf,ctx,{tools={},note='note'})
    check(not ok)
    check(counted == 0)
    check(calls == 0)
  end)
end
it("shares summary call allowance with normal boundary recovery", function()
  straps.config.context_management.mode = 'summary'
  straps.config.context_management.trigger = 0.1
  straps.config.context_management.summary = {max_calls=1}
  local generated = 0
  _G.overflow_summary = function() generated = generated + 1 end
  define('fn.context_summarize','fn',[[return function(r)
    _G.overflow_summary()
    local refs={} for _,s in ipairs(r.sources) do refs[#refs+1]=s.ref end
    return {summary='bounded',complete=true,source_refs=refs,stop_reason='end_turn'}
  end]])
  run()
  check(generated == 1)
  check(calls == 1)
  check(text():find('summary call budget exhausted',1,true) ~= nil)
end)
