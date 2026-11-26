local M = {}
local windows = {}

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

function M.defer(bufnr, entry)
  if type(bufnr) ~= "number" or bufnr <= 0 or not vim.api.nvim_buf_is_valid(bufnr) then return nil end
  if type(entry) == "function" then entry = { kind = "presenter", present = entry } end
  local review = require("straps.permission_review")
  entry.bufnr = bufnr
  review.add(entry)
  redraw()
  local released = false
  return function()
    if released then return end
    released = true
    review.remove(entry)
    redraw()
  end
end

function M.has_permission(bufnr)
  for _, entry in ipairs(require("straps.permission_review").entries()) do
    if entry.bufnr == bufnr then return true end
  end
  return false
end

function M.review_permission(bufnr)
  if not M.has_permission(bufnr) then return false end
  return require("straps.permission_review").review(bufnr)
end

function M.confirm(ctx, present, spec)
  local review = require("straps.permission_review")
  local mode = review.mode()
  if not (ctx and ctx.await and ctx.on_cancel and coroutine.running()) then return present() end
  if mode ~= "deferred" and not M.visible(ctx.bufnr) then return present() end
  local release_attention = require("straps.attention").wait(ctx, "permission")
  local ok, choice = ctx.await(function(done)
    local release
    local entry = { kind = "confirm", spec = spec, mode = mode }
    entry.present = function()
      local success, result = pcall(present)
      release()
      done(success, result)
    end
    entry.done = function(result)
      release()
      done(true, result)
    end
    release = M.defer(ctx.bufnr, entry)
    if not release then
      release = function() end
      done(pcall(present))
      return
    end
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
