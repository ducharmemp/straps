-- tests/bash_guard_spec.lua — tool.bash's read/search/list redirect guard.
--   busted tests/bash_guard_spec.lua
-- No network. Registers the real tools and calls tool.bash directly. Bare
-- read (cat/head/tail/sed -n), search (grep/rg) and list (ls/find/fd)
-- commands must be refused with a pointer to the vim-native tool, also behind
-- a leading `cd X &&` and when piped only into pure filters; anything with
-- other shell logic, and unrelated commands, must run. Also covers the cwd
-- the command runs in and the repeat-command nudge.

local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(vim.fn.fnamemodify(here, ":p"), ":h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path


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

it("bare reads are refused toward read_file", function()
  assert_refused("cat foo.lua", "tool.read_file")
  assert_refused("head -20 foo.lua", "tool.read_file")
  assert_refused("tail -n5 foo.lua", "tool.read_file")
  assert_refused("sed -n '10,20p' foo.lua", "tool.read_file")
end)

it("bare searches are refused toward grep", function()
  assert_refused("grep -rn pattern lua/", "tool.grep")
  assert_refused("rg pattern", "tool.grep")
end)

it("bare listings are refused toward tree/glob", function()
  assert_refused("ls", "tool.tree")
  assert_refused("ls -la lua/", "tool.tree")
  assert_refused("find . -name '*.lua'", "tool.tree")
  assert_refused("fd straps", "tool.tree")
end)

it("bare metadata and web fetch commands are refused toward native tools", function()
  assert_refused("stat lua/straps/tools.lua", "tool.path_info")
  assert_refused("file lua/straps/tools.lua", "tool.path_info")
  assert_refused("curl https://example.com", "tool.fetch_url")
  assert_refused("wget https://example.com", "tool.fetch_url")
end)

it("path_info and tree provide native filesystem introspection", function()
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

it("shell logic exempts a command from the guard", function()
  assert_ran("echo hi | cat")
  assert_ran("ls | xargs echo")
  assert_ran("grep -c x /dev/null; true")
end)

it("a leading cd prefix does not hide a read", function()
  assert_refused("cd /tmp && cat foo.lua", "tool.read_file")
  assert_refused("cd '/tmp/a b'; grep -rn x .", "tool.grep")
  assert_refused("cd /tmp&&ls", "tool.tree")
end)

it("reads piped only into filters are refused", function()
  assert_refused("cat foo.lua | head -50", "tool.read_file")
  assert_refused("sed -n '1,9p' f | sort | uniq -c", "tool.read_file")
  assert_refused("wc -l foo.lua", "tool.read_file")
  assert_refused("grep -rn x lua/ | wc -l", "tool.grep")
  assert_refused("cd /x && rg foo | cut -d: -f1 | sort -u | tr a b | tail -3", "tool.grep")
  assert_refused("ls lua | wc -l", "tool.tree")
end)

it("reads with a non-filter stage, redirect, or shell logic run", function()
  assert_ran("cat /dev/null | xargs echo")
  assert_ran("cat /dev/null > /dev/null")
  assert_ran("grep -c x /dev/null | awk '{print $1}'")
  assert_ran("cat /dev/null | head -1 && true")
  assert_ran("cat /dev/null | head -1 || true")
  assert_ran("cd /tmp && cd / && cat /dev/null")
  assert_ran("cd /tmp && sudo -n cat /dev/null")
  assert_ran("grep -c x /dev/null | xargs echo '|'")
end)

it("a single-quoted pipe is an argument, not a stage", function()
  assert_refused("grep 'a|b' foo.lua", "tool.grep")
  assert_refused("rg 'x|y' lua | wc -l", "tool.grep")
end)

it("runs in the editor's working directory", function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  dir = vim.uv.fs_realpath(dir)
  local real_getcwd = vim.fn.getcwd
  vim.fn.getcwd = function() return dir end
  local ok, out = pcall(bash, "pwd -P")
  vim.fn.getcwd = real_getcwd
  assert(ok, out)
  assert(out:find("stdout:\n" .. dir .. "\n", 1, true), "pwd was not " .. dir .. ": " .. out)
  assert(dir ~= vim.uv.cwd(), "test needs the process cwd to differ from the stubbed getcwd")
end)

it("nudges on the second identical command in a session", function()
  local buf = vim.api.nvim_create_buf(false, true)
  local sctx = { await = ctx.await, bufnr = buf }
  local function run(c)
    return registry.call("tool.bash", { command = c }, sctx)
  end
  local nudge = "this exact command has run"
  local first = run("echo nudge-check")
  assert(not first:find(nudge, 1, true), "nudged on first run: " .. first)
  local second = run("  echo nudge-check ")
  assert(second:find("[straps: this exact command has run 2 times this session", 1, true),
    "no nudge on second run: " .. second)
  local last_line = second:match("([^\n]*)$")
  assert(last_line:find(nudge, 1, true), "nudge is not the final line: " .. second)
  assert(run("echo nudge-check"):find("run 3 times", 1, true), "count did not advance")
  run("echo hi")
  assert(not run("echo hi"):find(nudge, 1, true), "short command was nudged")
  local other = vim.api.nvim_create_buf(false, true)
  local ok = registry.call("tool.bash", { command = "echo nudge-check" }, { await = ctx.await, bufnr = other })
  assert(not ok:find(nudge, 1, true), "count leaked across sessions: " .. ok)
  vim.api.nvim_buf_delete(buf, { force = true })
  assert(not run("echo nudge-check"):find(nudge, 1, true), "count survived buffer wipe")
end)

it("prefix lookalikes and unrelated commands run", function()
  assert_ran("lsof -h 2>&1 || true") -- not "ls"
  assert_ran("catalog() { true; }; catalog") -- has shell logic anyway
  assert_ran("curl https://example.com | head -1") -- shell logic: tool no longer equivalent
  assert_ran("sed -i.bak -e '' /dev/null || true") -- sed without -n
  assert_ran("true")
end)

it("fetch_url is registered but not auto-allowed", function()
  local e = registry.get("tool.fetch_url")
  assert(e and e.kind == "tool", "fetch_url not registered")
  local allowed = registry.call("hook.confirm", "fetch_url", { url = "https://example.com" }, { bufnr = 0 })
  assert(allowed ~= true, "fetch_url should require confirmation")
end)

it("fetch_url refuses internal/loopback/link-local hosts (SSRF guard)", function()
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

it("fetch_url refuses automatic redirects", function()
  local out = registry.call("tool.fetch_url",
    { url = "http://93.184.216.34/x", follow_redirects = true }, ctx)
  assert(out:find("not followed automatically", 1, true), "redirect refusal missing: " .. out)
end)

it("huge output is capped before returning to the loop", function()
  local out = bash("yes x | head -c 400000")
  assert(out:find("output truncated", 1, true), "missing truncation note: " .. out:sub(1, 200))
  assert(#out < 300000, "bash returned too much output: " .. #out)
end)
