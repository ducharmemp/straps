local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(root)
package.path = root .. '/lua/?.lua;' .. root .. '/lua/?/init.lua;' .. package.path
local straps = require('straps').setup({ session_dir = vim.fn.tempname(), terminal_status = false })
local dock, registry = require('straps.dock'), require('straps.registry')
local ui, loop, state = require('straps.ui'), require('straps.loop'), require('straps.state')
local api = vim.api
local consent = require('straps.consent').connect({
  describe = function() return { session_id = 'dock-test', task_id = 'dock-task', epoch = 1 } end,
  validate = function() return true end,
})
vim.g.loaded_straps = nil
vim.cmd.runtime('plugin/straps.lua')
local real_confirm = vim.fn.confirm
local assertion = 0
local function check(ok, name)
  assertion = assertion + 1
  if assertion == tonumber(vim.env.STRAPS_DOCK_COUNTERFACTUAL) then ok = not ok end
  assert(ok, ('dock assertion %d: %s'):format(assertion, name))
end
local function split_count()
  local n = 0
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    if api.nvim_win_get_config(win).relative == '' then n = n + 1 end
  end
  return n
end
local function border(win)
  return api.nvim_eval_statusline(vim.wo[win].winbar, { winid = win, use_winbar = true }).str
end
local function open(prompt)
  local source = api.nvim_get_current_win()
  local buf = ui.open_session('split', { explicit_split = true, instruction = prompt })
  return buf, api.nvim_get_current_win(), source
end
local function reset()
  vim.cmd('only!')
  vim.cmd('enew!')
end

after_each(function()
  vim.fn.confirm = real_confirm
  reset()
end)

it('uses the default placement unless opted in and respects an explicit placement', function()
  local b, w = open('draft')
  check(not dock.is_window(w, b), 'default is ordinary split')
  reset()
  straps.config.session_dock = true
  local v = ui.open_session('vsplit', { explicit_split = true })
  check(not dock.is_window(api.nvim_get_current_win(), v), 'vsplit stays ordinary')
end)

it('opens the live transcript full-width, resizes it, and retains a draft', function()
  straps.config.session_dock, straps.config.session_winbar = true, false
  local b, w, source = open()
  check(api.nvim_win_get_buf(w) == b and vim.b[b].straps_session == true, 'native window displays the actual session buffer')
  check(api.nvim_win_get_width(w) == vim.o.columns and api.nvim_win_get_width(source) == vim.o.columns, 'both windows span the tab')
  check(api.nvim_win_get_position(w)[1] > api.nvim_win_get_position(source)[1] and api.nvim_win_get_height(w) <= 7, 'shallow window below source')
  state.seed_user(b, 'unsent edit')
  vim.cmd('resize 12')
  check(api.nvim_win_get_height(w) == 12, 'native expansion')
  vim.cmd('resize 5')
  check(api.nvim_win_get_height(w) == 5 and state.last_user_text(b) == 'unsent edit', 'native shrink retains draft')
  api.nvim_set_current_win(source)
  check(border(w):find(ui.session_label(b), 1, true) ~= nil, 'unfocused winbar identifies the conversation with model winbar disabled')
  state.persist(b)
  vim.fn.writefile({ vim.json.encode({ title = 'Dock title' }) }, api.nvim_buf_get_name(b) .. '.meta')
  check(border(w):find('Dock title (' .. ui.session_label(b) .. ')', 1, true) ~= nil, 'a human title shows with the filename')
  api.nvim_win_close(w, false)
  ui.show_session(b)
  check(state.last_user_text(b) == 'unsent edit', 'reopening the same session retains the draft')
  straps.config.session_winbar = true
end)

it('defers the default gate without focus or a preview split and clears on decision or stop', function()
  straps.config.session_dock = true
  straps.config.permission_review = 'modal'
  local decisions = 0
  vim.fn.confirm = function()
    decisions = decisions + 1
    return 2
  end
  local p = vim.fn.tempname()
  registry.define({ name = 'fn.provider', kind = 'fn', source = ([=[return function(req, ctx)
    if _G.dock_test_call then
      _G.dock_test_call = false
      return { stop_reason = 'tool_use', content = {{ type = 'tool_use', id = 'dock-edit',
        name = 'write_file', input = { path = %q, content = 'must not write' } }} }
    end
    return { stop_reason = 'end_turn', content = {{ type = 'text', text = 'done' }} }
  end]=]):format(p) })
  for _, resolution in ipairs({ 'StrapsPermission', 'StrapsStop' }) do
    _G.dock_test_call = true
    local b, w, source = open('write a test file')
    api.nvim_set_current_win(source)
    local source_buf = api.nvim_get_current_buf()
    local entered = 0
    local observer = api.nvim_create_autocmd('WinEnter', { callback = function() entered = entered + 1 end })
    local before = decisions
    loop.start(b)
    check(vim.wait(1000, function() return dock.has_permission(b) or decisions ~= before end), 'reaches permission gate')
    check(decisions == before and entered == 0 and split_count() == 2, 'arrival neither prompts nor opens a window')
    check(api.nvim_get_current_win() == source and api.nvim_get_current_buf() == source_buf, 'source remains focused')
    check(border(w):find('Permission pending', 1, true) ~= nil, 'rendered border shows pending state')
    vim.cmd(resolution)
    check(vim.wait(1000, function() return not loop.running(b) end), 'request resolves')
    check(decisions == before + (resolution == 'StrapsPermission' and 1 or 0), 'only explicit review invokes confirmation')
    check(not border(w):find('Permission pending', 1, true), 'pending label cleared')
    check(vim.fn.filereadable(p) == 0, 'denial or stop prevented the write')
    api.nvim_del_autocmd(observer)
    api.nvim_win_close(w, false)
  end
end)

it('defers the default contextual consent dialog until explicit review', function()
  straps.config.session_dock = true
  straps.config.permission_review = 'modal'
  local b, w, source = open()
  api.nvim_set_current_win(source)
  local decision
  local ctx = { bufnr = b, await = function(register) register(function(status) decision = status end) end,
    on_cancel = function() end }
  consent.request({}, { outcome = 'ask', decision = {
    boundary = 'edit', targets = { 'test file' }, effects = { 'write' },
  } }, ctx)
  check(decision == nil and api.nvim_get_current_win() == source and split_count() == 2,
    'consent waits without opening its dialog')
  check(border(w):find('Permission pending', 1, true) ~= nil, 'rendered border shows pending consent')
  vim.cmd.StrapsPermission()
  local dialog = api.nvim_get_current_buf()
  check(api.nvim_buf_get_lines(dialog, 0, 1, false)[1]:find('Consent:', 1, true) == 1 and decision == nil,
    'review opens consent without deciding it')
  vim.cmd.close()
  check(decision == 'rejected' and not dock.has_permission(b), 'closing consent rejects it and clears the pending request')
end)

it('keeps the filename visible in the dock winbar with a long title and a pending request', function()
  straps.config.session_dock = true
  straps.config.permission_review = 'deferred'
  local function narrow(win)
    return api.nvim_eval_statusline(vim.wo[win].winbar, { winid = win, use_winbar = true, maxwidth = 80 }).str
  end
  for _, case in ipairs({ { true, 'bash' }, { true, 'write_file' }, { false, 'write_file' } }) do
    straps.config.session_winbar = case[1]
    local call = case[2] == 'bash' and { name = 'bash', input = { command = 'echo pending' } }
      or { name = 'write_file', input = { path = vim.fn.tempname(), content = 'x' } }
    _G.dock_title_call = call
    registry.define({ name = 'fn.provider', kind = 'fn', source = [=[return function(req, ctx)
      local call = _G.dock_title_call
      if call then
        _G.dock_title_call = nil
        return { stop_reason = 'tool_use', content = {{ type = 'tool_use', id = 'dt-' .. call.name, name = call.name, input = call.input }} }
      end
      return { stop_reason = 'end_turn', content = {{ type = 'text', text = 'done' }} }
    end]=] })
    local b, w, source = open('go')
    state.persist(b)
    vim.fn.writefile({ vim.json.encode({ title = ('T'):rep(200) }) }, api.nvim_buf_get_name(b) .. '.meta')
    api.nvim_set_current_win(source)
    loop.start(b)
    check(vim.wait(2000, function() return #require('straps.permission_review').entries() > 0 end), call.name .. ' request pending')
    local text = narrow(w)
    check(text:find(ui.session_label(b), 1, true) ~= nil, call.name .. ': filename visible with a long title: ' .. text)
    check(text:find('waiting', 1, true) ~= nil, call.name .. ': the waiting marker stays visible: ' .. text)
    loop.stop(b)
    vim.wait(1000, function() return not loop.running(b) end)
    reset()
  end
  straps.config.session_winbar = true
  straps.config.permission_review = 'deferred'
  straps.config.session_dock = false
end)

it('renders title text literally in the dock winbar, including %, %{ and NUL', function()
  straps.config.session_dock = true
  local b, w = open('go')
  state.persist(b)
  local function title(text)
    vim.fn.writefile({ vim.json.encode({ title = text }) }, api.nvim_buf_get_name(b) .. '.meta')
    return border(w)
  end
  local text = title('100%{v:true}')
  check(text:find('100%{v:true}', 1, true) ~= nil, 'a %{ title renders literally: ' .. text)
  text = title('a\0b')
  check(vim.wo[w].winbar ~= '' and text:find('a^@b', 1, true) ~= nil, 'a NUL title keeps the winbar and shows ^@: ' .. text)
  text = title(('p'):rep(12) .. '%' .. ('q'):rep(40))
  check(text:find(('p'):rep(12) .. '%…', 1, true) ~= nil, 'a title cut right after % renders the % and the ellipsis: ' .. text)
  check(vim.fn.iconv(text, 'utf-8', 'utf-16') ~= '', 'the rendered winbar is valid UTF-8: ' .. text)
end)

it('shortens the title so the filename and the waiting label fit a narrow dock window', function()
  straps.config.session_dock = true
  straps.config.permission_review = 'deferred'
  finally(function() straps.config.session_dock = false end)
  _G.dock_title_call = { name = 'write_file', input = { path = vim.fn.tempname(), content = 'x' } }
  registry.define({ name = 'fn.provider', kind = 'fn', source = [=[return function(req, ctx)
    local call = _G.dock_title_call
    if call then
      _G.dock_title_call = nil
      return { stop_reason = 'tool_use', content = {{ type = 'tool_use', id = 'dn', name = call.name, input = call.input }} }
    end
    return { stop_reason = 'end_turn', content = {{ type = 'text', text = 'done' }} }
  end]=] })
  local b, w, source = open('go')
  state.persist(b)
  vim.fn.writefile({ vim.json.encode({ title = ('T'):rep(40) }) }, api.nvim_buf_get_name(b) .. '.meta')
  api.nvim_set_current_win(source)
  loop.start(b)
  check(vim.wait(2000, function() return #require('straps.permission_review').entries() > 0 end), 'narrow dock request pending')
  api.nvim_win_call(w, function() vim.cmd('vsplit') end)
  for _, width in ipairs({ 60, 50 }) do
    api.nvim_win_set_width(w, width)
    local actual = api.nvim_win_get_width(w)
    local text = api.nvim_eval_statusline(vim.wo[w].winbar, { winid = w, use_winbar = true, maxwidth = actual }).str
    check(text:find(ui.session_label(b) .. ')', 1, true) ~= nil, 'filename and its parenthesis visible at width ' .. actual .. ': ' .. text)
    check(text:find('waiting', 1, true) ~= nil, 'waiting label visible at width ' .. actual .. ': ' .. text)
    local shown = select(2, text:gsub('T', ''))
    check(shown >= actual - #ui.session_label(b) - 20, 'title cut too far at width ' .. actual .. ': ' .. text)
  end
  loop.stop(b)
  vim.wait(1000, function() return not loop.running(b) end)
end)
