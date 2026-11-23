local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(root)
package.path = root .. '/lua/?.lua;' .. root .. '/lua/?/init.lua;' .. package.path
local straps = require('straps').setup({ session_dir = vim.fn.tempname(), terminal_status = false })
local api, ui, state = vim.api, require('straps.ui'), require('straps.state')
local loop, registry = require('straps.loop'), require('straps.registry')
local turn, workbench = require('straps.turn_decoration'), require('straps.workbench')
local real_pending, real_confirm = workbench.pending, vim.fn.confirm
local counter = tonumber(vim.env.STRAPS_TURN_COUNTERFACTUAL)

local function check(id, condition)
  if counter == id then condition = not condition end
  assert(condition, 'turn assertion ' .. id)
end

local function screen(win)
  vim.cmd('redraw!')
  local x = api.nvim_win_get_position(win)[2] + 1
  local y = api.nvim_win_get_position(win)[1] + 1
  local rows = {}
  for r = y, y + api.nvim_win_get_height(win) do
    local cells = {}
    for c = x, x + api.nvim_win_get_width(win) - 1 do cells[#cells + 1] = vim.fn.screenstring(r, c) end
    rows[#rows + 1] = table.concat(cells)
  end
  return table.concat(rows, '\n')
end

local function winbar(win)
  return api.nvim_eval_statusline(vim.wo[win].winbar, { winid = win, use_winbar = true }).str
end

after_each(function()
  workbench.pending, vim.fn.confirm = real_pending, real_confirm
  straps.config.render, straps.config.turn_decoration, straps.config.session_winbar = true, true, true
  vim.cmd('only!')
  vim.cmd('enew!')
end)

it('renders only the current turn, including a folded pending action, without moving the view or editing text', function()
  local buf = ui.open_session('split', { explicit_split = true })
  local win = api.nvim_get_current_win()
  vim.wo[win].number, vim.wo[win].relativenumber = false, false
  api.nvim_win_set_height(win, 12)
  state.append(buf, 'assistant', nil, 'earlier turn')
  state.append(buf, 'user', nil, ('older text\n'):rep(24))
  state.append(buf, 'assistant', nil, 'current body')
  local first = api.nvim_buf_line_count(buf) - 2
  state.append(buf, 'tool_use', { id = 'one', name = 'edit_file' }, '{}')
  state.append(buf, 'tool_use', { id = 'two', name = 'edit_file' }, '{}')
  local blocks = state.list_blocks(buf)
  local action = blocks[#blocks - 1].marker_lnum
  ui._render(buf)
  vim.cmd('normal! zx')
  workbench.pending = function(b) if b == buf then return { call_id = 'one', name = 'edit_file' } end end
  api.nvim_win_set_cursor(win, {1, 0})
  vim.cmd('normal! zt')
  local saved = vim.fn.winsaveview()
  local tick = api.nvim_buf_get_changedtick(buf)
  local modified = vim.bo[buf].modified
  turn.begin(buf, first)
  local past = screen(win)
  check(1, not past:find('│', 1, true) and not past:find('◆ permit', 1, true))
  check(2, past:find('◆ waiting', 1, true) ~= nil)
  check(3, vim.deep_equal(saved, vim.fn.winsaveview()) and api.nvim_get_current_win() == win)
  check(4, api.nvim_buf_get_changedtick(buf) == tick and vim.bo[buf].modified == modified)
  api.nvim_win_set_cursor(win, { first + 1, 0 })
  vim.cmd('normal! zt')
  local current = screen(win)
  check(5, current:find('│current body', 1, true) ~= nil)
  check(6, vim.fn.foldclosed(action) == action and current:find('◆ permit ▸', 1, true) ~= nil)
  check(7, select(3, turn.rows(buf)) == action - 1)
  check(8, vim.wo[win].conceallevel == 2)
  straps.setup({ render = false })
  check(9, not screen(win):find('│current body', 1, true) and not winbar(win):find('◆ waiting', 1, true))
  straps.setup({ render = true, turn_decoration = false })
  check(10, not screen(win):find('◆ permit', 1, true) and winbar(win):find(':StrapsInspect', 1, true) ~= nil)
  straps.setup({ turn_decoration = true })
  workbench.pending = function() return { name = 'edit_file' } end
  turn.redraw(buf)
  check(11, select(3, turn.rows(buf)) == nil and not screen(win):find('◆ permit', 1, true))
  vim.wo[win].winbar = 'custom winbar'
  check(12, vim.wo[win].winbar == 'custom winbar' and not screen(win):find('◆ waiting', 1, true))
end)

it('tracks real workbench waits, clears the previous turn on continuation, and clears on finish', function()
  local buf = ui.open_session('split', { explicit_split = true, instruction = 'create file' })
  local win = api.nvim_get_current_win()
  local path = vim.fn.tempname()
  local unload = function() vim.fn.delete(path) end
  api.nvim_create_autocmd('BufWipeout', { buffer = buf, once = true, callback = unload })
  _G.straps_turn_release = nil
  registry.define({ name = 'fn.provider', kind = 'fn', source = ([=[return function(req, ctx)
    if not _G.straps_turn_dispatched then
      _G.straps_turn_dispatched = true
      return { stop_reason = 'tool_use', content = {{ type = 'tool_use', id = 'turn-write', name = 'write_file',
        input = { path = %q, content = 'unused' } }} }
    end
    ctx.await(function(done) _G.straps_turn_release = done end)
    return { stop_reason = 'end_turn', content = {{ type = 'text', text = 'Done' }} }
  end]=]):format(path) })
  _G.straps_turn_dispatched = false
  loop.start(buf)
  check(13, vim.wait(1000, function() return workbench.pending(buf) ~= nil end))
  local first, _, permit = turn.rows(buf)
  check(14, first ~= nil and permit ~= nil and winbar(win):find(':StrapsPermission', 1, true) ~= nil)
  vim.fn.confirm = function() return 2 end
  require('straps.dock').review_permission(buf)
  check(15, vim.wait(1000, function() return _G.straps_turn_release ~= nil end))
  local next_first, _, next_permit = turn.rows(buf)
  check(16, next_first > permit and next_permit == nil and not winbar(win):find('◆ waiting', 1, true))
  _G.straps_turn_release()
  check(17, vim.wait(1000, function() return not loop.running(buf) end) and turn.rows(buf) == nil)
end)
