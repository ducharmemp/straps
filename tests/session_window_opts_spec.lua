-- tests/session_window_opts_spec.lua — fold fill, wrapping and list options in session windows.
-- Run from the repo root: busted tests/session_window_opts_spec.lua

local script = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(vim.fn.fnamemodify(script, ":p"), ":h:h")
vim.opt.runtimepath:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local straps = require("straps").setup({})
straps.config.session_dir = vim.fn.tempname()
local ui = require("straps.ui")
vim.cmd("filetype plugin on")

local function fresh()
  vim.cmd("silent! only!")
  vim.cmd("enew!")
end

after_each(function()
  vim.o.fillchars = ""
  vim.o.breakindentopt = ""
  vim.cmd("filetype plugin on")
end)

local function open_session_file()
  local path = vim.fn.tempname() .. ".straps"
  vim.fn.writefile({ "%%[straps:user]%%", "hi" }, path)
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  return vim.api.nvim_get_current_buf()
end

local function items(value)
  local out = {}
  for part in value:gmatch("[^,]+") do out[#out + 1] = part end
  return out
end

it("formatlistpat matches dash, star, plus and numbered items", function()
  fresh()
  local b = open_session_file()
  local pat = vim.bo[b].formatlistpat
  for _, line in ipairs({ "- x", "* x", "+ x", "1. x", "  12) x" }) do
    assert(vim.fn.match(line, pat) == 0, line .. " not matched by " .. pat)
  end
  assert.are.equal(-1, vim.fn.match("plain text", pat))
end)

it("the FileType autocmd sets formatlistpat and omnifunc with filetype plugins off", function()
  fresh()
  vim.cmd("filetype plugin off")
  local b = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(b, vim.fn.tempname() .. "-hidden.straps")
  vim.bo[b].filetype = "straps"
  vim.cmd("filetype plugin on")
  assert.is_nil(vim.b[b].did_ftplugin)
  assert.are.equal(ui.LIST_PATTERN, vim.bo[b].formatlistpat)
  assert.are.equal("v:lua.require'straps.ask'.omnifunc", vim.bo[b].omnifunc)
end)

it("the ftplugin sets formatlistpat and omnifunc without the straps FileType autocmd", function()
  fresh()
  vim.api.nvim_clear_autocmds({ group = "StrapsUI", event = "FileType" })
  local ok, err = pcall(function()
    local b = open_session_file()
    assert.are.equal(1, vim.b[b].did_ftplugin)
    assert.are.equal(ui.LIST_PATTERN, vim.bo[b].formatlistpat)
    assert.are.equal("v:lua.require'straps.ask'.omnifunc", vim.bo[b].omnifunc)
  end)
  ui.setup()
  assert(ok, tostring(err))
end)

it("an after/ftplugin setting survives setup() run after filetype plugins load", function()
  fresh()
  local after = vim.fn.tempname()
  vim.fn.mkdir(after .. "/after/ftplugin", "p")
  vim.fn.writefile({ "vim.bo.formatlistpat = 'USERPAT'", "vim.bo.omnifunc = 'UserOmni'" }, after .. "/after/ftplugin/straps.lua")
  vim.opt.runtimepath:append(after .. "/after")
  ui.setup()
  local ok, err = pcall(function()
    local b = open_session_file()
    assert.are.equal("USERPAT", vim.bo[b].formatlistpat)
    assert.are.equal("UserOmni", vim.bo[b].omnifunc)
  end)
  vim.opt.runtimepath:remove(after .. "/after")
  assert(ok, tostring(err))
end)

it("fold fill is a space and global fillchars items are kept", function()
  fresh()
  vim.o.fillchars = "eob:x"
  open_session_file()
  local fc = items(vim.wo.fillchars)
  assert(vim.tbl_contains(fc, "fold: "), vim.wo.fillchars)
  assert(vim.tbl_contains(fc, "eob:x"), vim.wo.fillchars)
  vim.o.fillchars = ""
end)

it("an existing fold item is replaced, not duplicated", function()
  fresh()
  vim.o.fillchars = "fold:-,eob:x"
  open_session_file()
  local fc = items(vim.wo.fillchars)
  local folds = vim.tbl_filter(function(item) return vim.startswith(item, "fold:") end, fc)
  assert.same({ "fold: " }, folds)
end)

it("an existing list item in breakindentopt is replaced, not duplicated", function()
  fresh()
  vim.o.breakindentopt = "list:2,shift:2"
  open_session_file()
  local bio = items(vim.wo.breakindentopt)
  assert.same({ "list:-1" }, vim.tbl_filter(function(item) return vim.startswith(item, "list:") end, bio))
  assert(vim.tbl_contains(bio, "shift:2"), vim.wo.breakindentopt)
end)

it("breakindentopt merges list:-1 with an existing shift:2", function()
  fresh()
  vim.o.breakindentopt = "shift:2"
  open_session_file()
  local bio = items(vim.wo.breakindentopt)
  assert(vim.tbl_contains(bio, "list:-1"), vim.wo.breakindentopt)
  assert(vim.tbl_contains(bio, "shift:2"), vim.wo.breakindentopt)
  vim.o.breakindentopt = ""
end)

it("linebreak and breakindent are on", function()
  fresh()
  open_session_file()
  assert.is_true(vim.wo.linebreak)
  assert.is_true(vim.wo.breakindent)
end)

it("a :setlocal nolinebreak survives a WinEnter re-apply", function()
  fresh()
  open_session_file()
  vim.cmd("setlocal nolinebreak")
  vim.api.nvim_exec_autocmds("WinEnter", {})
  vim.api.nvim_exec_autocmds("BufWinEnter", { buffer = 0 })
  assert.is_false(vim.wo.linebreak)
end)

it(":edit of another named file in the window leaves linebreak off", function()
  fresh()
  open_session_file()
  assert.is_true(vim.wo.linebreak)
  local other = vim.fn.tempname() .. ".txt"
  vim.fn.writefile({ "x" }, other)
  vim.cmd("edit " .. vim.fn.fnameescape(other))
  assert.is_false(vim.wo.linebreak)
  assert.is_false(vim.wo.breakindent)
end)

it("changing filetype away from straps restores the global options", function()
  fresh()
  vim.o.breakindentopt = "shift:2"
  vim.o.fillchars = "eob:x"
  local b = open_session_file()
  vim.bo[b].filetype = "text"
  assert.are.equal("shift:2", vim.wo.breakindentopt)
  assert.are.equal("eob:x", vim.wo.fillchars)
  assert.is_false(vim.wo.linebreak)
  assert.is_false(vim.wo.breakindent)
  assert.are.equal(vim.go.formatlistpat, vim.bo[b].formatlistpat)
  assert.are.equal(vim.go.omnifunc, vim.bo[b].omnifunc)
  vim.o.breakindentopt = ""
  vim.o.fillchars = ""
end)

it("after a filetype change, a later global fillchars change reaches the window", function()
  fresh()
  vim.o.fillchars = "eob:x"
  local b = open_session_file()
  vim.bo[b].filetype = "text"
  vim.cmd("setglobal fillchars=eob:y")
  assert.are.equal("eob:y", vim.wo.fillchars)
end)
