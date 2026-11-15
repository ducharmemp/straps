local here = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(here, ':p:h:h')
package.path = root .. '/lua/?.lua;' .. package.path
local original_send = vim.api.nvim_ui_send
local attention, adapter, ctx, run, packets, answer, cancel, clock, handle, status
before_each(function()
  package.loaded['straps.registry'] = { guards_frozen = function() return false end,
    any_tool_executing = function() return false end }
  package.loaded['straps.consent'], package.loaded['straps.attention'] = nil, nil
  packets, clock, handle = {}, 0, {}
  vim.api.nvim_ui_send = function(packet) packets[#packets + 1] = packet end
  attention = require('straps.attention')
  ctx = { bufnr = 991, on_cancel = function(callback) cancel = callback end,
    await = function(register) register(function(value) status = value end); return 'waiting' end }
  run = { ctx = ctx }
  attention.start(ctx.bufnr, run)
end)
after_each(function()
  attention.shutdown()
  vim.api.nvim_ui_send = original_send
end)
local function request(mode)
  local consent = require('straps.consent')
  if vim.env.STRAPS_ATTENTION_MUTANT then
    local source = table.concat(vim.fn.readfile(root .. '/lua/straps/consent.lua'), '\n')
    local site = vim.env.STRAPS_ATTENTION_MUTANT == 'acquire' and 'require("straps.attention").wait' or 'record.release_attention'
    assert.is_truthy(source:find(site, 1, true))
    if vim.env.STRAPS_ATTENTION_MUTANT == 'acquire' then
      source = source:gsub('require%("straps.attention"%).wait', '(function() return function() end end)')
    else
      local first, last = assert(source:find('if release_attention then pcall(release_attention) end', 1, true))
      source = source:sub(1, first - 1) .. source:sub(last + 1)
    end
    consent = assert(loadstring(source))()
  end
  adapter = consent.connect({ clock = function() return clock end, expiry_ms = 50,
    describe = function() return { session_id = 'session', task_id = 'task', epoch = 1 } end,
    validate = function() return true end,
    display = mode ~= 'close' and function(_, callback)
      answer = callback
      if mode == 'error' then error('display failed') end
      return function() end
    end or nil })
  return adapter.request(handle, { outcome = 'ask', decision = {
    boundary = 'restart', targets = { 'host' }, effects = { 'restart' },
  } }, ctx)
end
local function state(value)
  assert.is_truthy(packets[#packets]:find(':state=' .. value, 1, true), packets[#packets])
end
for _, choice in ipairs({ 'once', 'reject' }) do
  it('holds actor attention until consent ' .. choice, function()
    assert.equals('waiting', request())
    state('blocked')
    assert.is_truthy(packets[#packets]:find(':kind=consent', 1, true))
    answer(choice)
    assert.equals(choice == 'once' and 'approved' or 'rejected', status)
    state('working')
  end)
end
for _, ending in ipairs({ 'cancel', 'close', 'session', 'expiry', 'error' }) do
  it('releases actor attention after consent ' .. ending, function()
    request(ending)
    if ending ~= 'error' then state('blocked') end
    if ending == 'cancel' then cancel()
    elseif ending == 'session' then adapter.invalidate_session('session', 'closed')
    elseif ending == 'expiry' then clock = 51; adapter.status(handle)
    elseif ending == 'close' then vim.api.nvim_win_close(vim.api.nvim_get_current_win(), true) end
    state('working')
    assert.is_not.equal('approved', adapter.status(handle))
  end)
end
