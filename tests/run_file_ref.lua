-- tests/run_file_ref.lua — ui.open_file_ref: gf on path:line[:col] refs.
--   nvim --headless -l tests/run_file_ref.lua
-- No network. Puts a reference in a scratch buffer, positions the cursor
-- and asserts open_file_ref lands the (non-session) window on the right
-- file/line/col, and declines (returns false) off-reference or on files
-- that do not exist so the mapping can fall back to native gf.

local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(vim.fn.fnamemodify(here, ":p"), ":h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
vim.fn.chdir(root)

local failed = false
local function case(name, fn)
  local ok, err = pcall(fn)
  if ok then
    print("PASS  " .. name)
  else
    failed = true
    print("FAIL  " .. name .. ": " .. tostring(err))
  end
end

local ui = require("straps.ui")

-- Fresh scratch buffer showing `line`, cursor on byte column `col` (1-based).
local function at(line, col)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line })
  vim.api.nvim_win_set_buf(0, buf)
  vim.api.nvim_win_set_cursor(0, { 1, col - 1 })
end

case("path:line opens the file at the line", function()
  at("the guard lives in lua/straps/tools.lua:293 now", 25)
  assert(ui.open_file_ref() == true, "should open")
  local name = vim.api.nvim_buf_get_name(0)
  assert(name:match("lua/straps/tools%.lua$"), "wrong file: " .. name)
  local pos = vim.api.nvim_win_get_cursor(0)
  assert(pos[1] == 293, "wrong line: " .. pos[1])
end)

case("path:line:col also sets the column", function()
  at("see lua/straps/ui.lua:10:5", 5)
  assert(ui.open_file_ref() == true, "should open")
  local pos = vim.api.nvim_win_get_cursor(0)
  assert(pos[1] == 10 and pos[2] == 4, "wrong pos: " .. pos[1] .. ":" .. pos[2])
end)

case("cursor off the reference returns false", function()
  at("the guard lives in lua/straps/tools.lua:293 now", 5)
  assert(ui.open_file_ref() == false, "should decline off-reference")
end)

case("nonexistent file returns false", function()
  at("see no/such/file.lua:12", 5)
  assert(ui.open_file_ref() == false, "should decline missing file")
end)

case("plain path without :line returns false (native gf territory)", function()
  at("see lua/straps/ui.lua for details", 8)
  assert(ui.open_file_ref() == false, "should decline bare path")
end)

case("line beyond EOF clamps to the last line", function()
  at("bogus tests/run_file_ref.lua:99999 ref", 10)
  assert(ui.open_file_ref() == true, "should open")
  local pos = vim.api.nvim_win_get_cursor(0)
  assert(pos[1] == vim.api.nvim_buf_line_count(0), "should clamp to EOF")
end)

if failed then
  vim.cmd("cquit 1")
end
vim.cmd("quit")
