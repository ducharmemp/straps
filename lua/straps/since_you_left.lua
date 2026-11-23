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
  if not rendering() or not pos[1] or pos[3].invalid then
    clear(buf)
    return nil
  end
  return pos[1]
end

local function in_transcript(win, buf)
  return api.nvim_win_get_buf(win) == buf and vim.w[win].straps_steer_draft ~= buf
end

function M.preserve_view(buf)
  return row_of(buf) ~= nil
end

function M.wants_output(buf)
  return rendering() and views[buf] ~= nil and not in_transcript(api.nvim_get_current_win(), buf) and row_of(buf) == nil
end

function M.output(buf, row)
  if not M.wants_output(buf) then return end
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
  return not rendering() or vim.b[buf].straps_session ~= true
    or (win == api.nvim_get_current_win() and not M.preserve_view(buf))
end

local function observe(entering, scrolling)
  local win = api.nvim_get_current_win()
  local buf = api.nvim_win_get_buf(win)
  local row = in_transcript(win, buf) and row_of(buf)
  if not row then
    reading = nil
    return
  end
  local cursor = api.nvim_win_get_cursor(win)[1]
  local top = vim.fn.line("w0")
  if not entering and reading and reading.win == win and reading.buf == buf
    and ((not scrolling and cursor > reading.cursor and cursor > row + 1)
      or (scrolling and top > reading.top and top > row + 1)) then
    clear(buf)
    reading = nil
    return
  end
  reading = { win = win, buf = buf, cursor = cursor, top = top }
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
      if rendering() and vim.b[ev.buf].straps_session == true and in_transcript(win, ev.buf) then
        views[ev.buf] = views[ev.buf] or {}
        views[ev.buf][win] = vim.fn.winsaveview()
      end
    end,
  })
  api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
    group = group,
    callback = function(ev)
      local win = api.nvim_get_current_win()
      local saved = views[ev.buf] and views[ev.buf][win]
      if ev.event == "BufEnter" and saved and in_transcript(win, ev.buf) and M.preserve_view(ev.buf) then
        vim.fn.winrestview(saved)
      end
      observe(true)
    end,
  })
  api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "WinScrolled" }, {
    group = group,
    callback = function(ev) observe(false, ev.event == "WinScrolled") end,
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
