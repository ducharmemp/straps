local M = {}
local api = vim.api
local state = require("straps.state")
local windows = {}

local function restore_view(record)
  if api.nvim_win_is_valid(record.origin) and api.nvim_win_get_buf(record.origin) == record.origin_buf then
    api.nvim_win_call(record.origin, function() vim.fn.winrestview(record.view) end)
  end
end

local function close_record(bufnr, record)
  if windows[bufnr] ~= record then return end
  windows[bufnr] = nil
  if api.nvim_win_is_valid(record.origin) then vim.w[record.origin].straps_steer_origin = nil end
  state.persist(bufnr)
  if not record.submitting then
    vim.schedule(function()
      if not windows[bufnr] then restore_view(record) end
    end)
  end
end

local function dismiss(bufnr, record)
  if api.nvim_win_is_valid(record.origin) then api.nvim_set_current_win(record.origin) end
  record.submitting = true
  local ok, err = pcall(api.nvim_win_close, record.win, false)
  if not ok then
    record.submitting = nil
    vim.notify("straps: cannot close steering split: " .. tostring(err), vim.log.levels.WARN)
    return false
  end
  close_record(bufnr, record)
  restore_view(record)
  return true
end

function M.open(bufnr)
  local record = windows[bufnr]
  if record then
    if api.nvim_win_is_valid(record.win) and api.nvim_win_get_buf(record.win) == bufnr then
      api.nvim_set_current_win(record.win)
      return record.win
    end
    close_record(bufnr, record)
  end
  local origin = api.nvim_get_current_win()
  record = { origin = origin, origin_buf = api.nvim_get_current_buf(), view = vim.fn.winsaveview() }
  local ok, win = pcall(api.nvim_open_win, bufnr, true, { split = "below", height = 5 })
  if not ok then
    vim.notify("straps: cannot open steering split: " .. tostring(win), vim.log.levels.WARN)
    return
  end
  if not api.nvim_win_is_valid(win) or api.nvim_win_get_buf(win) ~= bufnr then return end
  record.win = win
  windows[bufnr] = record
  vim.w[origin].straps_steer_origin = bufnr
  api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win), once = true, callback = function() close_record(bufnr, record) end,
  })
  vim.wo[win].foldenable = false
  state.open_draft(bufnr)
  api.nvim_win_set_cursor(win, { api.nvim_buf_line_count(bufnr), 0 })
  api.nvim_win_call(win, function() vim.cmd("normal! zb") end)
  restore_view(record)
  return win
end

local function submit(bufnr, record, human, loop)
  local text = state.draft_text(bufnr)
  if not text or not text:find("%S") or not dismiss(bufnr, record) then return end
  local function deliver()
    if not api.nvim_buf_is_loaded(bufnr) then return end
    if state.draft_text(bufnr) == text then state.clear_draft(bufnr) end
    if not loop.steer(bufnr, text) then
      state.add_to_trailing_user(bufnr, text)
      vim.notify("straps: no active run; steering is in the trailing user block (send it with :StrapsSend)",
        vim.log.levels.WARN)
    end
  end
  if human then return human.steer(bufnr, text, deliver) end
  deliver()
end

function M.send(bufnr, human)
  local loop = require("straps.loop")
  local win = api.nvim_get_current_win()
  local record = windows[bufnr]
  if record and record.win == win then
    return submit(bufnr, record, human, loop)
  end
  local draft = state.draft_text(bufnr)
  if loop.running(bufnr) or (draft and draft:find("%S")) then return M.open(bufnr) end
  if draft then state.clear_draft(bufnr) end
  if human then return human.send(bufnr) end
  return loop.start(bufnr)
end

return M
