local M = {}
local windows, pending = {}, {}

function M.is_window(win, bufnr)
  return windows[win] == bufnr
end

function M.open(bufnr, split_cmd)
  if require("straps").config.session_dock ~= true or (split_cmd and split_cmd ~= "" and split_cmd ~= "split") then return end
  local ok, win = pcall(vim.api.nvim_open_win, bufnr, true, { split = "below", win = -1, height = 7 })
  if not ok then return end
  windows[win] = bufnr
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win), once = true, callback = function() windows[win] = nil end,
  })
  return win
end

function M.visible(bufnr)
  for win, buf in pairs(windows) do
    if buf == bufnr and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == bufnr then return true end
  end
  return false
end

local function redraw()
  pcall(vim.cmd, "redrawstatus!")
end

function M.defer(bufnr, present)
  local queue = pending[bufnr] or {}
  pending[bufnr] = queue
  local entry = { present = present }
  queue[#queue + 1] = entry
  redraw()
  return function()
    for i, active in ipairs(queue) do
      if active == entry then table.remove(queue, i); break end
    end
    if pending[bufnr] == queue and #queue == 0 then pending[bufnr] = nil end
    redraw()
  end
end

function M.has_permission(bufnr)
  return pending[bufnr] ~= nil
end

function M.review_permission(bufnr)
  if require("straps.registry").any_tool_executing() then return false end
  for _, entry in ipairs(pending[bufnr] or {}) do
    if entry.present then
      local present = entry.present
      entry.present = nil
      present()
      return true
    end
  end
  return false
end

function M.confirm(ctx, present)
  if not (ctx and ctx.await and ctx.on_cancel and coroutine.running() and M.visible(ctx.bufnr)) then return present() end
  local release_attention = require("straps.attention").wait(ctx, "permission")
  local ok, choice = ctx.await(function(done)
    local release
    release = M.defer(ctx.bufnr, function()
      local success, result = pcall(present)
      release()
      done(success, result)
    end)
    ctx.on_cancel(function()
      release()
      release_attention()
      done(true, nil)
    end)
  end)
  release_attention()
  if not ok then error(choice, 0) end
  return choice
end

return M
