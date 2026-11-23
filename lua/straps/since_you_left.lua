local M = {}
local api = vim.api
local ns = api.nvim_create_namespace("straps.since_you_left")
local views = {}
local marks = {}
local reading
local enabled = false

local function rendering()
  return enabled and require("straps").config.render ~= false
end

local function clear(buf)
  if marks[buf] and api.nvim_buf_is_valid(buf) then
    api.nvim_buf_del_extmark(buf, ns, marks[buf])
  end
  marks[buf] = nil
end

local function row_of(buf)
  if not marks[buf] then return nil end
  local pos = api.nvim_buf_get_extmark_by_id(buf, ns, marks[buf], { details = true })
  if not rendering() or not pos[1] or pos[3].invalid then return nil end
  return pos[1]
end

local function shows(win, buf)
  return api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == buf
end

function M.window(buf)
  local current = api.nvim_get_current_win()
  if shows(current, buf) then return current end
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    if shows(win, buf) then return win end
  end
end

local function composing(win, buf)
  local row = require("straps.state").draft_row(buf)
  return row and api.nvim_win_get_cursor(win)[1] > row
end

function M.preserve_view(buf)
  return row_of(buf) ~= nil
end

function M.wants_output(buf)
  if not rendering() or row_of(buf) ~= nil then return false end
  local win = api.nvim_get_current_win()
  if shows(win, buf) then return composing(win, buf) end
  return views[buf] ~= nil
end

function M.output(buf, row)
  if not M.wants_output(buf) then return end
  clear(buf)
  marks[buf] = api.nvim_buf_set_extmark(buf, ns, row, 0, {
    end_row = row + 1,
    end_col = 0,
    right_gravity = false,
    invalidate = true,
    undo_restore = false,
    virt_lines_above = true,
    virt_lines = { { { "── since you left ──", "StrapsRule" } } },
  })
end

function M.follow(win, buf)
  local current = api.nvim_get_current_win()
  if not shows(win, buf) then return false end
  return not rendering() or vim.b[buf].straps_session ~= true
    or (win == current and not M.preserve_view(buf))
end

local function observe(entering, scrolling)
  local win = api.nvim_get_current_win()
  local buf = api.nvim_win_get_buf(win)
  local row = row_of(buf)
  if row and composing(win, buf) and api.nvim_get_mode().mode:sub(1, 1) == "i" then
    reading = nil
    return
  end
  if not row then
    reading = nil
    return
  end
  local cursor = api.nvim_win_get_cursor(win)[1]
  local top = vim.fn.line("w0")
  if entering or not reading or reading.win ~= win or reading.buf ~= buf then
    reading = { win = win, buf = buf, cursor = cursor, top = top }
    return
  end
  local previous, current = reading.cursor, cursor
  if scrolling then
    previous, current = reading.top, top
    reading.top = top
  else
    reading.cursor = cursor
  end
  if previous <= row + 1 and current > row + 1 then
    clear(buf)
    reading = nil
  end
end

function M.reset_reading()
  observe(true)
end

function M.jump(buf)
  local row = row_of(buf)
  if row == nil then
    vim.notify("straps: no new output", vim.log.levels.INFO)
    return
  end
  local win = M.window(buf)
  if not win then
    vim.notify("straps: open a transcript reading window to jump to new output", vim.log.levels.INFO)
    return
  end
  api.nvim_set_current_win(win)
  api.nvim_win_set_cursor(win, { row + 1, 0 })
  vim.cmd("normal! zvzz")
  M.reset_reading()
end

function M.setup(render)
  local group = api.nvim_create_augroup("StrapsSinceYouLeft", { clear = true })
  enabled = render ~= false
  if not enabled then
    for buf in pairs(marks) do clear(buf) end
    views, reading = {}, nil
    return
  end
  api.nvim_create_autocmd({ "BufLeave", "WinLeave" }, {
    group = group,
    callback = function(ev)
      local win = api.nvim_get_current_win()
      if rendering() and vim.b[ev.buf].straps_session == true and shows(win, ev.buf) then
        views[ev.buf] = views[ev.buf] or {}
        views[ev.buf][win] = vim.fn.winsaveview()
        views[ev.buf][win].draft = require("straps.state").draft_row(ev.buf)
      end
    end,
  })
  api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
    group = group,
    callback = function(ev)
      local win = api.nvim_get_current_win()
      local saved = views[ev.buf] and views[ev.buf][win]
      if ev.event == "BufEnter" and saved and shows(win, ev.buf) and M.preserve_view(ev.buf)
          and not (saved.lnum > (saved.draft or math.huge)) then
        vim.fn.winrestview(saved)
      end
      observe(true)
    end,
  })
  api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "WinScrolled" }, {
    group = group,
    callback = function(ev)
      if ev.event == "WinScrolled" then
        local win = tostring(api.nvim_get_current_win())
        if ev.match ~= win and not vim.v.event[win] then return end
      end
      observe(false, ev.event == "WinScrolled")
    end,
  })
  api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(ev)
      local win = tonumber(ev.match)
      for _, saved in pairs(views) do saved[win] = nil end
    end,
  })
  api.nvim_create_autocmd({ "BufReadPost", "BufUnload" }, {
    group = group,
    callback = function(ev)
      clear(ev.buf)
      views[ev.buf] = nil
      if reading and reading.buf == ev.buf then reading = nil end
    end,
  })
end

return M
