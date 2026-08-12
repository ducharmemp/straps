-- straps.findings — the session findings-list service: the session window's
-- location list when on-screen, else the global quickfix list. Used by
-- grep/run_quickfix/editor tools; ui.lua delegates here for back-compat.

local M = {}

-- Per-session findings lists (quickfix isolation) ---------------------------
-- The quickfix list is GLOBAL to the Neovim instance, so two concurrent
-- sessions populating it would stomp each other — and bulk_replace, which acts
-- on "the current list", could then edit another session's files. Fix: when a
-- session is on-screen, route its findings to that WINDOW's location list
-- (per-window, private); fall back to the global quickfix list only when the
-- session has no window (e.g. a windowless subagent), which is the pre-existing
-- global behavior and no worse than today.

--- The window showing session buffer `bufnr`, or nil. Non-floating, and
--- deterministic (lowest win id) so a grep and the later bulk_replace on the
--- same session resolve to the SAME window's location list.
function M.session_win(bufnr)
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    return nil
  end
  local wins = vim.fn.win_findbuf(bufnr)
  if type(wins) ~= "table" then
    return nil
  end
  table.sort(wins)
  for _, w in ipairs(wins) do
    if vim.api.nvim_win_is_valid(w)
        and vim.api.nvim_win_get_config(w).relative == "" then
      return w
    end
  end
  return nil
end

--- Set this session's findings list. `what` = { title, items }. Uses the
--- session window's location list when on-screen (isolated per session), else
--- the global quickfix list. `open` opens the matching list window when there
--- are entries. Returns "loclist" or "quickfix" (so callers can name the right
--- :lnext/:cnext navigation).
function M.set_locations(bufnr, what, open)
  local win = M.session_win(bufnr)
  local title = what.title
  local items = what.items or {}
  if win then
    pcall(vim.fn.setloclist, win, {}, " ", { title = title, items = items })
    if open and #items > 0 then
      pcall(vim.fn.win_execute, win, "lopen")
    end
    return "loclist"
  end
  pcall(vim.fn.setqflist, {}, " ", { title = title, items = items })
  if open and #items > 0 then
    pcall(function() vim.cmd("botright copen") end)
  end
  return "quickfix"
end

--- Read this session's findings list. Returns items(list), kind, win-or-nil.
function M.get_locations(bufnr)
  local win = M.session_win(bufnr)
  if win then
    return vim.fn.getloclist(win), "loclist", win
  end
  return vim.fn.getqflist(), "quickfix", nil
end

--- Run an ex substitution across this session's findings list: `:ldo` in its
--- window (private) when on-screen, else `:cdo` globally. `body` is the part
--- after the do-command, e.g. "s#a#b#ge | update". Returns ok, err, kind.
---
--- :ldo/:cdo NAVIGATE the window through every entry (that is how they visit
--- files), so the window ends up showing the last edited file — for the ldo
--- path that window is the SESSION's, and the transcript vanishes from view.
--- Snapshot the window's buffer and view before, restore after (success or
--- failure), so the do-command's edits land but the displacement never shows.
function M.locations_do(bufnr, body)
  local win = M.session_win(bufnr)
  local target = win or vim.api.nvim_get_current_win()
  local prev_buf = vim.api.nvim_win_get_buf(target)
  local view
  pcall(function()
    view = vim.api.nvim_win_call(target, vim.fn.winsaveview)
  end)
  local ok, err
  if win then
    ok, err = pcall(vim.fn.win_execute, win, "silent ldo " .. body)
  else
    ok, err = pcall(vim.cmd, "silent cdo " .. body)
  end
  pcall(function()
    if not (vim.api.nvim_win_is_valid(target) and vim.api.nvim_buf_is_valid(prev_buf)) then
      return
    end
    if vim.api.nvim_win_get_buf(target) ~= prev_buf then
      vim.api.nvim_win_set_buf(target, prev_buf)
    end
    if type(view) == "table" then
      vim.api.nvim_win_call(target, function() vim.fn.winrestview(view) end)
    end
  end)
  return ok, err, win and "loclist" or "quickfix"
end

return M
