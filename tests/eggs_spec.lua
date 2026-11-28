local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(root)
require('straps').setup({ session_dir = vim.fn.tempname(), terminal_status = false })
vim.cmd.runtime('plugin/straps.lua')
local api, ui = vim.api, require('straps.ui')
local attention, ratchet = require('straps.attention'), require('straps.ratchet')
local source, session, queue
local defer, waiting, notify = vim.defer_fn, attention.waiting, vim.notify
local stock = api.nvim_get_option_info2('statusline', {}).default
local function tick() assert(table.remove(queue, 1), 'missing frame')() end
local function drain()
  for _ = 1, 64 do if #queue == 0 then return end; tick() end
  error('animation did not stop')
end
local function floats()
  return vim.tbl_filter(function(w) return api.nvim_win_get_config(w).relative ~= '' end, api.nvim_tabpage_list_wins(0))
end
local function statusline(win)
  return api.nvim_get_option_value('statusline', { win = win or source, scope = 'local' })
end

before_each(function()
  if #api.nvim_tabpage_list_wins(0) > 1 then vim.cmd.only({ bang = true }) end
  session = ui.open_session('none', { instruction = 'draft' })
  source = api.nvim_get_current_win()
  queue = {}
  vim.defer_fn = function(fn) queue[#queue + 1] = fn end
end)
after_each(function()
  attention.waiting, vim.notify = waiting, notify
  drain()
  vim.defer_fn = defer
end)

it('completes names and rejects neighboring non-session windows', function()
  assert.same({ 'firefly' }, vim.fn.getcompletion('StrapsEgg f', 'cmdline'))
  local warning
  vim.notify = function(msg) warning = msg end
  vim.cmd.vnew()
  vim.cmd.StrapsEgg('exoskeleton')
  assert.matches('requires a session window', warning)
  assert.same({}, floats())
end)

it('moves the firefly in two dimensions without changing the session', function()
  local layout = vim.fn.winlayout()
  local bar, rev = vim.wo[source].winbar, api.nvim_buf_get_changedtick(session)
  vim.cmd.StrapsEgg('firefly')
  local windows = floats()
  assert.equals(3, #windows)
  local head = assert(vim.iter(windows):find(function(win)
    return api.nvim_buf_get_lines(api.nvim_win_get_buf(win), 0, 1, true)[1] == '✦'
  end))
  local first = api.nvim_win_get_config(head)
  assert.is_false(first.focusable)
  assert.is_false(first.mouse)
  for _ = 1, 3 do tick() end
  local next = api.nvim_win_get_config(head)
  assert(first.row ~= next.row and first.col ~= next.col, 'firefly must change rows and columns')
  assert.same(layout, vim.fn.winlayout())
  assert.equals(source, api.nvim_get_current_win())
  assert.equals(bar, vim.wo[source].winbar)
  drain()
  assert.same({}, floats())
  assert.equals(rev, api.nvim_buf_get_changedtick(session))
end)

it('replaces playback, lights the exoskeleton, and leaves duplicate windows open', function()
  vim.cmd.StrapsEgg('firefly')
  vim.cmd.StrapsEgg('exoskeleton')
  local preview = assert(floats()[1])
  local art = api.nvim_win_get_buf(preview)
  assert.equals(1, #floats())
  local duplicate = api.nvim_open_win(art, false, { win = source, split = 'below' })
  tick()
  assert.matches('◌', api.nvim_buf_get_lines(art, 1, 2, true)[1])
  for _ = 1, 4 do tick() end
  assert.matches('●', api.nvim_buf_get_lines(art, 1, 2, true)[1])
  tick()
  assert.is_false(api.nvim_win_is_valid(preview))
  assert.is_true(api.nvim_win_is_valid(duplicate))
  assert.same({ '' }, api.nvim_buf_get_lines(art, 0, -1, true))
end)

it('stops playback when a prompt arrives', function()
  vim.cmd.StrapsEgg('exoskeleton')
  attention.waiting = function(buf) return buf == session end
  tick()
  assert.same({}, floats())
  assert.same({}, queue)
end)

it('installs the ratchet in the stock statusline and preserves custom formats', function()
  assert.matches('ratchet_status', statusline())
  vim.opt.ruler = true
  local filename = 'ratchet-status-test.straps'
  api.nvim_buf_set_name(session, vim.fn.getcwd() .. '/' .. filename)
  local function columns(width)
    local rendered = api.nvim_eval_statusline(statusline(), { winid = source, maxwidth = width }).str
    local file = assert(rendered:find(filename, 1, true), rendered)
    local strap = assert(rendered:find('◀', 1, true), rendered)
    local ruler = assert(rendered:find('%d+,%d+', strap), rendered)
    assert(file < strap and strap < ruler, rendered)
    return file, vim.fn.strdisplaywidth(rendered:sub(1, strap - 1)), rendered
  end
  local file, strap, narrow = columns(65)
  local wider_file, wider_strap, wide = columns(75)
  assert.equals(file, wider_file)
  assert(wider_strap - strap == 10, vim.inspect({ narrow, wide, strap, wider_strap }))
  vim.cmd('setglobal statusline=custom')
  assert.equals('', statusline())
  vim.cmd('setlocal statusline=local')
  api.nvim_set_option_value('statusline', stock, { scope = 'global' })
  assert.equals('local', statusline())
  local custom = "%{v:lua.require'straps.ui'.ratchet_status()}%f"
  api.nvim_set_option_value('statusline', custom, { win = source, scope = 'local' })
  assert.equals(custom, statusline())
  vim.cmd('setlocal statusline=')
  assert.matches('ratchet_status', statusline())
  api.nvim_win_set_buf(source, api.nvim_create_buf(false, true))
  assert.equals('', statusline())
end)

it('plays the ratchet only for a successful provider run', function()
  local loop, registry = require('straps.loop'), require('straps.registry')
  registry.define({ name = 'fn.provider', kind = 'fn', source = [[return function()
    return { stop_reason = 'end_turn', content = { { type = 'text', text = 'hello' } } }
  end]] })
  loop.start(session)
  assert.equals('ok', vim.b[session].straps_run_reason)
  assert.matches('done', ui.ratchet_status(session))
  drain()
  session = ui.open_session('none', { instruction = 'wait' })
  registry.define({ name = 'fn.provider', kind = 'fn', source = [[return function(_, ctx)
    return ctx.await(function() end)
  end]] })
  loop.start(session)
  assert.matches('running', ui.ratchet_status(session))
  loop.stop(session)
  drain()
  assert.matches('idle', ui.ratchet_status(session))
end)

it('shortens the ratchet after a successful finish and cancels on restart', function()
  local idle = ui.ratchet_status(session)
  ratchet.finish(session, false)
  assert.same({}, queue)
  ratchet.finish(session, true)
  local first = ui.ratchet_status(session)
  assert.matches('done', first)
  for _ = 1, 4 do tick() end
  assert.matches(string.rep('═', 12) .. '╸', ui.ratchet_status(session))
  assert.equals(vim.fn.strdisplaywidth(first), vim.fn.strdisplaywidth(ui.ratchet_status(session)))
  ratchet.start(session)
  drain()
  assert.equals(idle, ui.ratchet_status(session))
  ratchet.finish(session, true)
  drain()
  assert.equals(idle, ui.ratchet_status(session))
end)
