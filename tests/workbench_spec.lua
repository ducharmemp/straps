local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(root)
package.path = root .. '/lua/?.lua;' .. root .. '/lua/?/init.lua;' .. package.path
local straps = require('straps').setup({ session_dir = vim.fn.tempname(), terminal_status = false })
local registry, loop, ui = require('straps.registry'), require('straps.loop'), require('straps.ui')
local workbench, dock = require('straps.workbench'), require('straps.dock')
local api = vim.api
local real_confirm = vim.fn.confirm
local steps, messages, session, decisions, choice

local function check(id, value)
  if vim.env.STRAPS_WORKBENCH_COUNTERFACTUAL == id then value = not value end
  assert(value, 'workbench assertion: ' .. id)
end

local function preview()
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    if vim.bo[api.nvim_win_get_buf(win)].filetype == 'diff' then return win end
  end
end

local function awaiting(id)
  return vim.wait(1000, function()
    local info = workbench.pending(session)
    return info and info.call_id == id
  end)
end

local function edit(path, before, after, id)
  return { type = 'tool_use', id = id or 'edit-1', name = 'edit_file', input = { path = path, old_string = before, new_string = after } }
end

local function start(is_dock, calls, leave_transcript)
  straps.config.session_dock = is_dock
  steps = { { stop_reason = 'tool_use', content = calls } }
  local source = api.nvim_get_current_win()
  session = ui.open_session('split', { explicit_split = true, instruction = 'test the proposed edit' })
  local transcript = api.nvim_get_current_win()
  if leave_transcript then api.nvim_set_current_win(source) end
  loop.start(session)
  return transcript, source
end

before_each(function()
  decisions, choice, messages = 0, 2, {}
  vim.fn.confirm = function(prompt, options, default)
    decisions = decisions + 1
    messages[decisions] = { prompt = prompt, options = options, default = default }
    return choice
  end
  _G.straps_workbench_provider = function()
    return table.remove(steps, 1) or { stop_reason = 'end_turn', content = {{ type = 'text', text = 'done' }} }
  end
  vim.g.loaded_straps = nil
  vim.cmd.runtime('plugin/straps.lua')
  registry.define({ name = 'fn.provider', kind = 'fn', source = 'return _G.straps_workbench_provider' })
end)

after_each(function()
  if session and loop.running(session) then loop.stop(session) end
  session = nil
  vim.fn.confirm = real_confirm
  vim.cmd('only!')
  vim.cmd('enew!')
end)

it('defers inspection and approval, preserves the transcript cursor, and keeps a closed diff pending', function()
  local path = vim.fn.tempname()
  vim.fn.writefile({ 'keep', 'before', 'keep' }, path)
  local transcript, source = start(true, { edit(path, 'before', 'after') }, true)
  check('arrives', awaiting('edit-1'))
  check('no_automatic_preview', not preview() and decisions == 0 and api.nvim_get_current_win() == source)
  local info = workbench.pending(session)
  check('metadata', info.name == 'edit_file' and info.path == path and dock.has_permission(session))
  info.path = 'changed'
  check('detached_metadata', workbench.pending(session).path == path)
  vim.cmd.StrapsInspect()
  check('wrong_window_refuses', not preview() and api.nvim_get_current_win() == source and decisions == 0)
  api.nvim_set_current_win(transcript)
  api.nvim_win_set_cursor(transcript, { 3, 1 })
  local cursor = api.nvim_win_get_cursor(transcript)
  vim.cmd.StrapsInspect()
  local diff = preview()
  check('adjoins_transcript', diff and api.nvim_win_get_position(diff)[1] > api.nvim_win_get_position(transcript)[1])
  check('focus_and_cursor', api.nvim_get_current_win() == transcript and vim.deep_equal(cursor, api.nvim_win_get_cursor(transcript)))
  local buf = api.nvim_win_get_buf(diff)
  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  check('unified_diff', vim.tbl_contains(lines, '-before') and vim.tbl_contains(lines, '+after') and not vim.bo[buf].modifiable)
  vim.cmd.StrapsInspect()
  check('reuses_diff', preview() == diff and #api.nvim_tabpage_list_wins(0) == 3)
  api.nvim_win_close(diff, false)
  check('close_keeps_pending', not api.nvim_buf_is_valid(buf) and awaiting('edit-1') and decisions == 0)
  check('inspect_writes_nothing', vim.fn.readfile(path)[2] == 'before' and next(registry.granted(session)) == nil)
  vim.cmd.StrapsInspect()
  check('reopens_diff', preview() ~= nil)
  vim.cmd.StrapsPermission()
  check('denial_resumes', vim.wait(1000, function() return not loop.running(session) end) and decisions == 1)
  check('denial_no_write_or_grant', vim.fn.readfile(path)[2] == 'before' and next(registry.granted(session)) == nil)
  check('denial_cleans_up', not preview() and not workbench.pending(session) and not dock.has_permission(session))
end)

it('inspects against earlier approved edits in a batch and stops without applying either edit', function()
  local path = vim.fn.tempname()
  vim.fn.writefile({ 'one' }, path)
  local transcript = start(false, { edit(path, 'one', 'two'), edit(path, 'two', 'three', 'edit-2') })
  check('ordinary_arrives', awaiting('edit-1') and not preview() and decisions == 0)
  choice = 1
  vim.cmd.StrapsPermission()
  check('second_arrives', awaiting('edit-2') and not preview() and decisions == 1 and vim.fn.readfile(path)[1] == 'one')
  vim.cmd.StrapsInspect()
  local diff = preview()
  check('narrow_below', diff and api.nvim_win_get_position(diff)[1] > api.nvim_win_get_position(transcript)[1])
  local lines = api.nvim_buf_get_lines(api.nvim_win_get_buf(diff), 0, -1, false)
  check('staged_base', vim.tbl_contains(lines, '-two') and vim.tbl_contains(lines, '+three'))
  vim.cmd.StrapsStop()
  check('stop_cleans_up', vim.wait(1000, function() return not loop.running(session) end)
    and not preview() and not workbench.pending(session) and not dock.has_permission(session))
  check('stop_no_write_or_grant', vim.fn.readfile(path)[1] == 'one' and next(registry.granted(session)) == nil)
end)

it('previews live unsaved text and refuses inspection after a directory change', function()
  local path = vim.fn.tempname()
  vim.fn.writefile({ 'disk' }, path)
  vim.cmd.edit(vim.fn.fnameescape(path))
  api.nvim_buf_set_lines(0, 0, -1, false, { 'unsaved' })
  start(false, { edit(path, 'unsaved', 'proposed') })
  check('live_pending', awaiting('edit-1'))
  local cwd = vim.fn.getcwd()
  local other = vim.fn.tempname()
  vim.fn.mkdir(other)
  vim.cmd.lcd(vim.fn.fnameescape(other))
  local ok, reason = workbench.inspect()
  check('changed_cwd_refuses', not ok and reason:find('directory changed', 1, true)
    and not preview() and workbench.pending(session) and decisions == 0)
  vim.cmd.lcd(vim.fn.fnameescape(cwd))
  vim.cmd.StrapsInspect()
  local diff = preview()
  local lines = diff and api.nvim_buf_get_lines(api.nvim_win_get_buf(diff), 0, -1, false) or {}
  check('live_buffer_base', vim.tbl_contains(lines, '-unsaved') and vim.tbl_contains(lines, '+proposed')
    and vim.fn.readfile(path)[1] == 'disk')
end)

it('can approve from a source window without inspecting first', function()
  local path = vim.fn.tempname()
  local _, source = start(false, {{ type = 'tool_use', id = 'write', name = 'write_file', input = { path = path, content = 'written' } }}, true)
  check('write_pending', awaiting('write') and not preview() and api.nvim_get_current_win() == source)
  choice = 1
  vim.cmd.StrapsPermission()
  check('approved_write', vim.wait(1000, function() return not loop.running(session) end) and vim.fn.filereadable(path) == 1
    and vim.fn.readfile(path)[1] == 'written')
  check('approval_options', decisions == 1 and messages[1].default == 2 and messages[1].options:find('&Yes\n&No', 1, true))
  check('approval_no_preview', not preview() and not workbench.pending(session) and api.nvim_get_current_win() == source)
end)
