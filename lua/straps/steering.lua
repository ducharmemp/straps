local M = {}
local api = vim.api
local state = require("straps.state")
local stopping = {}
local submissions = setmetatable({}, { __mode = "v" })

function M.open(bufnr)
  local win = require("straps.since_you_left").window(bufnr)
  if not win then return end
  api.nvim_set_current_win(win)
  state.open_draft(bufnr)
  api.nvim_win_set_cursor(win, { api.nvim_buf_line_count(bufnr), 0 })
  vim.cmd("normal! zb")
  return win
end

local function submit(bufnr, human, text, active)
  local loop = require("straps.loop")
  local id = {}
  submissions[bufnr] = id
  local function deliver()
    if submissions[bufnr] ~= id or not api.nvim_buf_is_loaded(bufnr) then return end
    submissions[bufnr] = nil
    if loop.running(bufnr) then
      if not active or not loop.steer(bufnr, text) then return end
    else
      state.add_to_trailing_user(bufnr, text)
    end
    if state.draft_text(bufnr) == text then state.clear_draft(bufnr) end
    if not active then loop.start(bufnr) end
  end
  if human then
    if active then return human.steer(bufnr, text, deliver) end
    return human.send(bufnr, text, deliver)
  end
  return deliver()
end

function M.send(bufnr, human, now)
  local loop = require("straps.loop")
  if stopping[bufnr] then return end
  local active = loop.running(bufnr)
  local text = state.draft_text(bufnr)
  if not text or not text:find("%S") then
    if active then return end
    if human then return human.send(bufnr) end
    return loop.start(bufnr)
  end
  if not active or not now then return submit(bufnr, human, text, active) end

  local id = {}
  submissions[bufnr] = nil
  stopping[bufnr] = id
  loop.stop_then(bufnr, function()
    if stopping[bufnr] ~= id then return end
    stopping[bufnr] = nil
    if not api.nvim_buf_is_loaded(bufnr) or loop.running(bufnr) then return end
    submit(bufnr, human, text, false)
  end, function()
    if stopping[bufnr] == id then stopping[bufnr] = nil end
  end)
end

function M.cancel(bufnr)
  stopping[bufnr], submissions[bufnr] = nil, nil
end

api.nvim_create_autocmd("BufUnload", { callback = function(ev) M.cancel(ev.buf) end })

return M
