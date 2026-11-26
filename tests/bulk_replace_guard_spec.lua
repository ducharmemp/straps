-- tests/bulk_replace_guard_spec.lua — bulk_replace never evaluates or reinterprets agent-supplied text.
-- Run from the repo root: busted tests/bulk_replace_guard_spec.lua

local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(vim.fn.fnamemodify(here, ":p"), ":h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

require("straps").config.session_dir = vim.fn.tempname()
local registry = require("straps.registry")
require("straps.tools").register()

local function seed(lines)
  local path = vim.fn.tempname() .. ".txt"
  vim.fn.writefile(lines, path)
  vim.fn.setqflist({}, "r", { items = { { filename = path, lnum = 1, col = 1, text = lines[1] } } })
  return path
end

local function lines_of(path)
  return vim.fn.readfile(path)
end

local function run(input)
  return pcall(registry.call, "tool.bulk_replace", input, { bufnr = 0 })
end

local function refused(input, lines, needle)
  for _, dry in ipairs({ false, true }) do
    _G.HIT = nil
    local path = seed(lines or { "FOO" })
    local call = vim.deepcopy(input)
    call.dry_run = dry
    local ok, err = run(call)
    assert(not ok, ("accepted %s (dry_run=%s): %s"):format(vim.inspect(input), tostring(dry), tostring(err)))
    if needle then assert(tostring(err):find(needle, 1, true), tostring(err)) end
    assert.is_nil(_G.HIT)
    assert.same(lines or { "FOO" }, lines_of(path))
  end
end

local function replaced(input, lines, expected)
  _G.HIT = nil
  local path = seed(lines)
  local ok, out = run(input)
  assert(ok, tostring(out))
  assert.is_nil(_G.HIT)
  assert.same(expected, lines_of(path))
  return out
end

it("refuses a replacement that starts with \\=", function()
  refused({ pattern = "FOO", replacement = "\\=luaeval('rawset(_G,[[HIT]],1) and 1')" }, nil, "must not start with")
end)

it("refuses a leading ~ on a fresh state and after an empty replacement", function()
  refused({ pattern = "FOO", replacement = "~\\=luaeval('rawset(_G,[[HIT]],1) and 1')" }, nil, "must not start with")
  replaced({ pattern = "QQQ", replacement = "" }, { "QQQ" }, { "" })
  refused({ pattern = "FOO", replacement = "~\\=luaeval('rawset(_G,[[HIT]],1) and 1')" }, nil, "must not start with")
end)

it("refuses a carriage return in the replacement or the pattern", function()
  refused({ pattern = "FOO", replacement = "a\rb" }, nil, "carriage return")
  refused({ pattern = "F\rOO", replacement = "a" }, nil, "carriage return")
end)

it("refuses a replacement that ends in an odd run of backslashes", function()
  refused({ pattern = "FOO", replacement = "X\\" }, nil, "unescaped backslash")
  refused({ pattern = "FOO", replacement = "X\\\\\\" }, nil, "unescaped backslash")
end)

it("refuses a NUL byte in the replacement or the pattern", function()
  refused({ pattern = "FOO", replacement = "a\0b" }, nil, "NUL")
  refused({ pattern = "F\0OO", replacement = "b" }, nil, "NUL")
end)

it("refuses a replacement that contains every delimiter", function()
  refused({ pattern = "FOO", replacement = "#@!%,;:^$*+=?/-" }, nil, "delimiter")
end)

it("keeps \\~ literal under nomagic", function()
  vim.o.magic = false
  local ok, err = pcall(replaced, { pattern = "FOO", replacement = "\\~\\=luaeval('rawset(_G,[[HIT]],1) and 1')" }, { "FOO" },
    { "~=luaeval('rawset(_G,[[HIT]],1) and 1')" })
  vim.o.magic = true
  assert(ok, tostring(err))
end)

it("treats the round-8 trailing-backslash input as literal text", function()
  replaced({ pattern = "FOO\\", replacement = "X\\#\\=luaeval('rawset(_G,[[HIT]],1) and 1')" }, { "FOO\\" },
    { "X#=luaeval('rawset(_G,[[HIT]],1) and 1')" })
end)

it("accepts escaped backslashes and a mid-string \\=", function()
  replaced({ pattern = "FOO", replacement = "\\\\=x" }, { "FOO" }, { "\\=x" })
  replaced({ pattern = "FOO", replacement = "x\\=y" }, { "FOO" }, { "x=y" })
end)

it("matches an unclosed [ literally, with and without dry_run", function()
  local path = seed({ "x[ x@]abc" })
  local ok, out = run({ pattern = "x[", replacement = "]abc", dry_run = true })
  assert(ok, tostring(out))
  assert(out:find("dry_run", 1, true), out)
  assert.same({ "x[ x@]abc" }, lines_of(path))
  replaced({ pattern = "x[", replacement = "]abc" }, { "x[ x@]abc" }, { "]abc x@]abc" })
end)

it("accepts a pattern containing # and @", function()
  replaced({ pattern = "a#b@c", replacement = "Z" }, { "1 a#b@c 2" }, { "1 Z 2" })
end)

it("restores the search register and direction after success and after an error", function()
  vim.fn.setreg("/", "prior")
  vim.v.searchforward = 0
  replaced({ pattern = "FOO", replacement = "BAR" }, { "FOO" }, { "BAR" })
  assert.are.equal("prior", vim.fn.getreg("/"))
  assert.are.equal(0, vim.v.searchforward)
  seed({ "FOO" })
  local ok = run({ pattern = "\\(", replacement = "BAR" })
  assert.is_false(ok)
  assert.are.equal("prior", vim.fn.getreg("/"))
  assert.are.equal(0, vim.v.searchforward)
end)

it("reports a failure when the findings walk raises, and restores the search register", function()
  local findings = require("straps.findings")
  local real = findings.locations_do
  vim.fn.setreg("/", "prior")
  local path = seed({ "FOO" })
  findings.locations_do = function() error("walk failed", 0) end
  local ok, err = run({ pattern = "FOO", replacement = "BAR" })
  findings.locations_do = real
  assert.is_false(ok)
  assert(tostring(err):find("substitution failed: walk failed", 1, true), tostring(err))
  assert.are.equal("prior", vim.fn.getreg("/"))
  assert.same({ "FOO" }, lines_of(path))
end)

it("N after the tool keeps a prior ? search direction", function()
  local buf = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "mark", "x", "mark", "x", "mark" })
  vim.api.nvim_win_set_cursor(0, { 5, 0 })
  vim.cmd("silent! normal! ?mark\r")
  assert.are.equal(3, vim.fn.line("."))
  replaced({ pattern = "FOO", replacement = "BAR" }, { "FOO" }, { "BAR" })
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  vim.cmd("silent! normal! N")
  assert.are.equal(5, vim.fn.line("."))
end)

it("names the command that ran in the success message", function()
  local out = replaced({ pattern = "FOO", replacement = "B#R" }, { "FOO" }, { "B#R" })
  assert(out:find("`smagic@@B#R@ge`", 1, true), out)
  assert(out:find("`FOO`", 1, true), out)
end)

it("leaves search highlighting off when it was off before", function()
  vim.o.hlsearch = true
  vim.fn.setreg("/", "prior")
  vim.cmd("nohlsearch")
  assert.are.equal(0, vim.v.hlsearch)
  replaced({ pattern = "FOO", replacement = "BAR" }, { "FOO" }, { "BAR" })
  assert.are.equal(0, vim.v.hlsearch)
  vim.o.hlsearch = false
end)
