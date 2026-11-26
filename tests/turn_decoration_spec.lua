local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(root)
package.path = root .. '/lua/?.lua;' .. root .. '/lua/?/init.lua;' .. package.path
require('straps').setup({ session_dir = vim.fn.tempname(), terminal_status = false })
local api, ui = vim.api, require('straps.ui')
local loop, registry = require('straps.loop'), require('straps.registry')
local workbench = require('straps.workbench')

local function check(id, value)
  if tonumber(vim.env.STRAPS_WAIT_COUNTERFACTUAL) == id then value = not value end
  assert(value, 'wait assertion ' .. id)
end

it('reports a pending edit in the winbar without marking the active turn', function()
  local buf = ui.open_session('split', { explicit_split = true, instruction = 'create file' })
  local win = api.nvim_get_current_win()
  local function winbar()
    return api.nvim_eval_statusline(vim.wo[win].winbar, { winid = win, use_winbar = true }).str
  end
  local path = vim.fn.tempname()
  registry.define({ name = 'fn.provider', kind = 'fn', source = ([=[return function(req, ctx)
    if _G.straps_wait_dispatched then
      return { stop_reason = 'end_turn', content = {{ type = 'text', text = 'Done' }} }
    end
    _G.straps_wait_dispatched = true
    return { stop_reason = 'tool_use', content = {{ type = 'tool_use', id = 'w1', name = 'write_file',
      input = { path = %q, content = 'unused' } }} }
  end]=]):format(path) })
  loop.start(buf)
  check(1, vim.wait(1000, function() return workbench.pending(buf) ~= nil end))
  check(2, winbar():find(':StrapsPermission', 1, true))
  check(3, winbar():find(':StrapsInspect', 1, true))
  local ns = api.nvim_get_namespaces().straps_turn_decoration
  check(4, not ns or #api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}) == 0)
  local ok, err = pcall(require('straps.dock').review_permission, buf)
  assert(ok, err)
  assert(require('straps.permission_review').review_window(), 'review float did not open')
  api.nvim_feedkeys('n', 'mx', false)
  check(5, vim.wait(1000, function() return not loop.running(buf) end))
  check(6, not winbar():find('waiting', 1, true))
end)
