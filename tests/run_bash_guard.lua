-- tests/run_bash_guard.lua — tool.bash's read/search/list redirect guard.
--   nvim --headless -l tests/run_bash_guard.lua
-- No network. Registers the real tools and calls tool.bash directly. Bare
-- read (cat/head/tail/sed -n), search (grep/rg) and list (ls/find/fd)
-- commands must be refused with a pointer to the vim-native tool; anything
-- with shell logic, and unrelated commands, must run.

local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(vim.fn.fnamemodify(here, ":p"), ":h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

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

local registry = require("straps.registry")
require("straps.tools").register()

-- Minimal ctx.await for commands that actually execute: run the thunk and
-- pump the event loop until vim.system's callback resolves.
local ctx = {
  await = function(fn)
    local result
    fn(function(r)
      result = r
    end)
    vim.wait(5000, function()
      return result ~= nil
    end)
    return result
  end,
}

local function bash(cmd)
  return registry.call("tool.bash", { command = cmd }, ctx)
end

local function assert_refused(cmd, tool)
  local out = bash(cmd)
  assert(out:match("^bash: refusing"), cmd .. " was not refused, got: " .. out)
  assert(out:find(tool, 1, true), cmd .. " refusal should point at " .. tool .. ", got: " .. out)
end

local function assert_ran(cmd)
  local out = bash(cmd)
  assert(out:match("^exit code:"), cmd .. " should have run, got: " .. out)
end

case("bare reads are refused toward read_file", function()
  assert_refused("cat foo.lua", "tool.read_file")
  assert_refused("head -20 foo.lua", "tool.read_file")
  assert_refused("tail -n5 foo.lua", "tool.read_file")
  assert_refused("sed -n '10,20p' foo.lua", "tool.read_file")
end)

case("bare searches are refused toward grep", function()
  assert_refused("grep -rn pattern lua/", "tool.grep")
  assert_refused("rg pattern", "tool.grep")
end)

case("bare listings are refused toward glob", function()
  assert_refused("ls", "tool.glob")
  assert_refused("ls -la lua/", "tool.glob")
  assert_refused("find . -name '*.lua'", "tool.glob")
  assert_refused("fd straps", "tool.glob")
end)

case("shell logic exempts a command from the guard", function()
  assert_ran("echo hi | cat")
  assert_ran("ls | wc -l")
  assert_ran("grep -c x /dev/null; true")
end)

case("prefix lookalikes and unrelated commands run", function()
  assert_ran("lsof -h 2>&1 || true") -- not "ls"
  assert_ran("catalog() { true; }; catalog") -- has shell logic anyway
  assert_ran("sed -i.bak -e '' /dev/null || true") -- sed without -n
  assert_ran("true")
end)

if failed then
  vim.cmd("cquit 1")
end
vim.cmd("quit")
