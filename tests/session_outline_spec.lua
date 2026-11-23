local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
local straps = require("straps").setup({ session_dir = vim.fn.tempname(), terminal_status = false })
local api, state = vim.api, require("straps.state")
local ui, loop, registry = require("straps.ui"), require("straps.loop"), require("straps.registry")
vim.cmd.runtime("plugin/straps.lua")

local assertion = 0
local function check(ok, message)
  assertion = assertion + 1
  if assertion == tonumber(vim.env.STRAPS_OUTLINE_COUNTERFACTUAL) then ok = not ok end
  assert(ok, ("outline assertion %d: %s"):format(assertion, message))
end

local lines = {
  "%%[straps:system]%%", "system text",
  "%%[straps:user]%% First actual prompt", "second line of first prompt",
  "%%[straps:assistant]%%", "first response",
  '%%[straps:tool_use]%% {"id":"1","name":"example"}', '{}',
  '%%[straps:tool_result]%% {"id":"1"}', "original tool output",
  "%%[straps:user]%%", "[straps] from agent helper (buffer 4): not a heading",
  "%%[straps:assistant]%%", "follow-up response",
  "%%[straps:user]%%", "", state.escape_line("%%[straps:assistant]%% as literal text"),
  "%%[straps:assistant]%%", "second response",
  "%%[straps:user]%%", "Newest prompt",
  "%%[straps:assistant]%%", "newest response",
  "%%[straps:user]%%", "Unsent text",
}

local function open()
  local b = state.new_session()
  api.nvim_buf_set_lines(b, 0, -1, false, lines)
  ui.show_session(b)
  return b
end

after_each(function()
  vim.cmd("tabonly!")
  vim.cmd("only!")
  vim.cmd("enew!")
end)

it("opens numbered prompt folds on the original buffer and reveals the entire turn with zo", function()
  local b = open()
  state.open_draft(b)
  local tick = api.nvim_buf_get_changedtick(b)
  local origin = api.nvim_get_current_win()
  check(vim.fn.foldclosed(3) == -1 and vim.fn.foldclosed(10) == 7, "normal view starts with tool folds only")
  vim.cmd.StrapsOutline()
  check(origin ~= api.nvim_get_current_win() and api.nvim_get_current_buf() == b, "reader uses the original buffer in another window")
  check(api.nvim_buf_get_changedtick(b) == tick, "opening never edits the transcript")
  check(vim.fn.foldtextresult(3) == "1. First actual prompt", "first heading prefers marker-line text")
  check(vim.fn.foldtextresult(15) == "2. %%[straps:assistant]%% as literal text", "second heading decodes escaped first content line")
  check(vim.fn.foldclosedend(3) == 14 and vim.fn.foldclosed(12) == 3, "agent notice stays in the preceding turn")
  check(vim.fn.foldclosedend(15) == 19, "second fold stops before latest prompt")
  check(vim.fn.foldclosed(21) == -1 and vim.fn.foldclosed(23) == -1, "latest turn remains visible")
  check(vim.fn.foldclosed(25) == -1 and vim.fn.foldclosed(26) == -1, "unsent text and steering draft remain visible")
  vim.cmd("normal! zo")
  check(vim.fn.foldclosed(4) == -1 and vim.fn.foldclosed(6) == -1, "zo reveals the prompt body and response")
  check(vim.fn.foldclosed(10) == -1 and vim.fn.getline(10) == "original tool output", "zo reveals original tool output without a nested fold")
  check(vim.fn.foldclosed(17) == 15, "opening one turn leaves other folds closed")
end)

it("returns to the original views and native fold choices on either exit", function()
  local b = open()
  vim.cmd("vsplit")
  local origin = api.nvim_get_current_win()
  vim.cmd("10foldopen")
  vim.cmd("normal! 21G2lzt")
  local saved = vim.fn.winsaveview()
  local other = vim.fn.win_getid(vim.fn.winnr("#"))
  local tabs = #api.nvim_list_tabpages()
  for _, command in ipairs({ "StrapsOutline", "close" }) do
    vim.cmd.StrapsOutline()
    local reader = api.nvim_get_current_win()
    api.nvim_set_current_win(other)
    check(vim.fn.foldclosed(10) == 7, "other transcript window still has its closed tool fold")
    api.nvim_set_current_win(reader)
    ui.apply_fold_opts(b)
    check(vim.fn.foldclosed(4) == 3, "ordinary UI initialization leaves the reader folds alone")
    vim.cmd(command)
    check(vim.wait(100, function() return api.nvim_get_current_win() == origin end) and #api.nvim_list_tabpages() == tabs,
      "exit returns to original window")
    check(vim.fn.foldclosed(10) == -1 and vim.wo.foldmethod == "expr" and vim.wo.foldlevel == 0, "native fold preferences preserved")
    check(vim.wait(100, function() return vim.deep_equal(vim.fn.winsaveview(), saved) end), "viewport and cursor preserved")
  end
end)

it("does not create or close reading folds when a real loop run finishes", function()
  registry.define({ name = "fn.provider", kind = "fn", source = [[return function(_, ctx)
    ctx.await(function(resolve) _G.outline_test_finish = resolve end)
    ctx.emit({ type = "text_delta", text = "run completed" })
    return { stop_reason = "end_turn", content = {{ type = "text", text = "run completed" }} }
  end]] })
  local b = open()
  vim.cmd.StrapsOutline()
  vim.cmd("normal! zo")
  loop.start(b)
  check(vim.wait(1000, function() return _G.outline_test_finish ~= nil end), "provider starts")
  api.nvim_win_set_cursor(0, { 23, 3 })
  local cursor = api.nvim_win_get_cursor(0)
  _G.outline_test_finish()
  _G.outline_test_finish = nil
  check(vim.wait(1000, function() return not loop.running(b) end), "loop finishes")
  check(table.concat(state.transcript_lines(b), "\n"):find("run completed", 1, true) ~= nil, "provider response lands in transcript")
  check(vim.fn.foldclosed(4) == -1 and vim.fn.foldclosed(17) == 15, "expanded and collapsed choices survive completion")
  check(vim.fn.foldclosed(23) == -1 and vim.deep_equal(cursor, api.nvim_win_get_cursor(0)), "older text under cursor stays visible")
end)

it("does not open an outline for a single sent prompt followed by a draft", function()
  local b = open()
  api.nvim_buf_set_lines(b, 0, -1, false, { "%%[straps:user]%% Sent", "%%[straps:assistant]%% Reply", "%%[straps:user]%% Draft" })
  local origin = api.nvim_get_current_win()
  vim.cmd.StrapsOutline()
  check(api.nvim_get_current_win() == origin, "draft alone does not create an outline")
end)
