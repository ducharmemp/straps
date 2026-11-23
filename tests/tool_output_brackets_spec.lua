local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
local straps = require("straps").setup({ session_dir = vim.fn.tempname(), terminal_status = false })
local api = vim.api
local ui = require("straps.ui")
local ns = api.nvim_create_namespace("straps_render")

local lines = {
  "%%[straps:user]%%",
  "question",
  "%%[straps:assistant]%%",
  "answer",
  '%%[straps:tool_use]%% {"id":"a","name":"bash"}',
  '{"command":"echo hi"}',
  '%%[straps:tool_result]%% {"id":"a"}',
  "",
  "first",
  "",
  "  last",
  " ",
  '%%[straps:tool_result]%% {"id":"b","is_error":true}',
  "single",
  '%%[straps:tool_result]%% {"id":"c"}',
  "",
  '%%[straps:tool_result]%% {"id":"d"}',
  "%%[straps:user]%%",
  "next question",
}

local function matches(id, expected, actual)
  local equal = vim.deep_equal(expected, actual)
  if vim.env.STRAPS_BRACKET_COUNTERFACTUAL == id then equal = not equal end
  assert(equal, ("%s: expected %s, got %s"):format(id, vim.inspect(expected), vim.inspect(actual)))
end

local function prefixes(buf)
  local found = {}
  for _, mark in ipairs(api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    local details = mark[4]
    if details.virt_text_pos == "inline" then
      found[#found + 1] = { mark[2] + 1, mark[3], details.virt_text }
    end
  end
  return found
end

local buf
before_each(function()
  buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  api.nvim_set_current_buf(buf)
end)

after_each(function()
  straps.config.render = true
  api.nvim_buf_delete(buf, { force = true })
end)

it("marks output rows, excluding separator blanks, empty results, tool inputs and prose", function()
  ui._render(buf)
  ui._render(buf)
  matches("prefixes", {
    { 9, 0, { { "╭ ", "StrapsCardBorder" } } },
    { 10, 0, { { "│ ", "StrapsCardBorder" } } },
    { 11, 0, { { "╰ ", "StrapsCardBorder" } } },
    { 14, 0, { { "│ ", "StrapsCardBorder" } } },
  }, prefixes(buf))
end)

it("displays the result prefix when opened and hides it when closed", function()
  ui._render(buf)
  vim.wo[0][0].foldmethod = "expr"
  vim.wo[0][0].foldexpr = "v:lua.require'straps.ui'.foldexpr(v:lnum)"
  vim.wo[0][0].foldlevel = 0
  vim.wo[0][0].foldenable = true
  vim.wo[0][0].conceallevel = 2
  api.nvim_win_set_cursor(0, { 5, 0 })
  local function visible_first()
    vim.cmd("redraw!")
    for row = 1, vim.o.lines do
      local cells = {}
      for col = 1, 15 do cells[col] = vim.fn.screenstring(row, col) end
      if table.concat(cells):find("╭ first", 1, true) then return true end
    end
    return false
  end
  matches("closed", false, visible_first())
  vim.cmd("normal! zo")
  matches("opened", true, visible_first())
end)

it("preserves bytes, modified state and linewise yanks", function()
  vim.bo[buf].modified = false
  ui._render(buf)
  matches("bytes", lines, api.nvim_buf_get_lines(buf, 0, -1, false))
  matches("modified", false, vim.bo[buf].modified)
  vim.wo[0][0].foldenable = false
  vim.cmd('9,11yank z')
  matches("yank", { "first", "", "  last" }, vim.fn.getreg("z", 1, true))
end)

it("clears prefixes on a render with render=false", function()
  ui._render(buf)
  straps.config.render = false
  ui._render(buf)
  matches("disabled", {}, prefixes(buf))
end)
