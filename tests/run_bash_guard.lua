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

local function call_tool(name, input)
  return registry.call("tool." .. name, input, ctx)
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

case("bare listings are refused toward tree/glob", function()
  assert_refused("ls", "tool.tree")
  assert_refused("ls -la lua/", "tool.tree")
  assert_refused("find . -name '*.lua'", "tool.tree")
  assert_refused("fd straps", "tool.tree")
end)

case("bare metadata and web fetch commands are refused toward native tools", function()
  assert_refused("stat lua/straps/tools.lua", "tool.path_info")
  assert_refused("file lua/straps/tools.lua", "tool.path_info")
  assert_refused("curl https://example.com", "tool.fetch_url")
  assert_refused("wget https://example.com", "tool.fetch_url")
end)

case("path_info and tree provide native filesystem introspection", function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local file = dir .. "/a.txt"
  local f = assert(io.open(file, "w")); f:write("hi\n"); f:close()
  local info = call_tool("path_info", { paths = { file, dir .. "/missing" } })
  assert(info:find("a.txt: file", 1, true), "path_info file missing: " .. info)
  assert(info:find("missing: missing", 1, true), "path_info missing entry missing: " .. info)
  local tree = call_tool("tree", { path = dir, max_depth = 1 })
  assert(tree:find("a.txt", 1, true), "tree missing file: " .. tree)
end)

case("shell logic exempts a command from the guard", function()
  assert_ran("echo hi | cat")
  assert_ran("ls | wc -l")
  assert_ran("grep -c x /dev/null; true")
end)

case("prefix lookalikes and unrelated commands run", function()
  assert_ran("lsof -h 2>&1 || true") -- not "ls"
  assert_ran("catalog() { true; }; catalog") -- has shell logic anyway
  assert_ran("curl https://example.com | head -1") -- shell logic: tool no longer equivalent
  assert_ran("sed -i.bak -e '' /dev/null || true") -- sed without -n
  assert_ran("true")
end)

case("fetch_url is registered but not auto-allowed", function()
  local e = registry.get("tool.fetch_url")
  assert(e and e.kind == "tool", "fetch_url not registered")
  local allowed = registry.call("hook.confirm", "fetch_url", { url = "https://example.com" }, { bufnr = 0 })
  assert(allowed ~= true, "fetch_url should require confirmation")
end)

case("fetch_url refuses internal/loopback/link-local hosts (SSRF guard)", function()
  local blocked = {
    "http://localhost/x",
    "http://127.0.0.1/x",
    "http://127.5.5.5/x",
    "http://169.254.169.254/latest/meta-data/", -- cloud metadata
    "http://10.0.0.1/x",
    "http://192.168.1.1/x",
    "http://172.16.0.1/x",
    "http://[::1]/x",
    "http://user:pass@localhost/x", -- userinfo must not hide the host
  }
  for _, url in ipairs(blocked) do
    local ok, err = pcall(registry.call, "tool.fetch_url", { url = url }, ctx)
    assert(not ok, "expected refusal for " .. url)
    assert(tostring(err):find("internal", 1, true),
      "wrong error for " .. url .. ": " .. tostring(err))
  end
  -- A public IP reaches curl rather than the SSRF refusal.
  local ok, err = pcall(registry.call, "tool.fetch_url",
    { url = "http://93.184.216.34/x", timeout_ms = 1 }, ctx)
  if not ok then
    assert(not tostring(err):find("internal", 1, true),
      "public IP wrongly blocked as internal: " .. tostring(err))
  end
end)

case("fetch_url refuses automatic redirects", function()
  local out = registry.call("tool.fetch_url",
    { url = "http://93.184.216.34/x", follow_redirects = true }, ctx)
  assert(out:find("not followed automatically", 1, true), "redirect refusal missing: " .. out)
end)

case("huge output is capped before returning to the loop", function()
  local out = bash("yes x | head -c 400000")
  assert(out:find("output truncated", 1, true), "missing truncation note: " .. out:sub(1, 200))
  assert(#out < 300000, "bash returned too much output: " .. #out)
end)

if failed then
  vim.cmd("cquit 1")
end
vim.cmd("quit")
