-- tests/bash_guard_spec.lua — tool.bash's read/search/list redirect guard.
--   busted tests/bash_guard_spec.lua
-- No network. Registers the real tools and calls tool.bash directly. Bare
-- read (cat/head/tail/sed -n), search (grep/rg) and list (ls/find/fd)
-- commands must be refused with a pointer to the vim-native tool, also behind
-- a leading `cd X &&` and when piped only into pure filters; anything with
-- other shell logic, and unrelated commands, must run. Also covers the cwd
-- the command runs in, the repeat-command nudge, fetch_url failure paths,
-- glob pattern errors, run_quickfix cwd and stream cap, exact-path buffer
-- lookup in read_file/path_info, and registry_list kind=skill.

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
  local ok, err = pcall(registry.call, "tool.fetch_url",
    { url = "http://93.184.216.34/x", follow_redirects = true }, ctx)
  assert.is_false(ok)
  assert.are.equal("fetch_url: ", err:sub(1, 11))
  assert(err:find("not followed automatically", 1, true), "redirect refusal missing: " .. err)
end)

it("fetch_url resolves hostnames through ctx.await, not a blocking wait", function()
  local awaited = 0
  local counting = { await = function(fn) awaited = awaited + 1; return ctx.await(fn) end }
  local ok, err = pcall(registry.call, "tool.fetch_url", { url = "http://straps-test.invalid/x" }, counting)
  assert.is_false(ok)
  assert.are.equal(1, awaited)
  assert.truthy(err:find("^fetch_url: could not resolve straps%-test%.invalid"))
end)

it("fetch_url raises when curl is missing", function()
  local path = vim.env.PATH
  vim.env.PATH = ""
  local ok, err = pcall(registry.call, "tool.fetch_url", { url = "http://93.184.216.34/x" }, ctx)
  vim.env.PATH = path
  assert.is_false(ok)
  assert.are.equal("fetch_url: curl is not executable", err)
end)

it("fetch_url takes and releases a subprocess slot", function()
  local saved = registry.render("fn.subprocess_acquire")
  local taken, released = 0, 0
  registry.define({ name = "fn.subprocess_acquire", kind = "fn", source = [[
    return function(ctx, info)
      _G.straps_test_slot = (_G.straps_test_slot or 0) + 1
      _G.straps_test_tool = info.tool
      return function() _G.straps_test_released = (_G.straps_test_released or 0) + 1 end
    end
  ]] })
  pcall(registry.call, "tool.fetch_url", { url = "http://93.184.216.34/x", timeout_ms = 1 }, ctx)
  taken, released = _G.straps_test_slot, _G.straps_test_released
  assert(load(saved))()
  assert.are.equal(1, taken)
  assert.are.equal("fetch_url", _G.straps_test_tool)
  assert.are.equal(1, released)
end)

it("huge output is capped before returning to the loop", function()
  local out = bash("yes x | head -c 400000")
  assert(out:find("output truncated", 1, true), "missing truncation note: " .. out:sub(1, 200))
  assert(#out < 300000, "bash returned too much output: " .. #out)
end)

it("fetch_url's cancel handler is safe when curl failed to spawn", function()
  local saved_system = vim.system
  local cancel_fns = {}
  vim.system = function() error("spawn boom") end
  local cctx = { await = ctx.await, on_cancel = function(f) cancel_fns[#cancel_fns + 1] = f end }
  local ok, err = pcall(registry.call, "tool.fetch_url", { url = "http://93.184.216.34/x" }, cctx)
  vim.system = saved_system
  assert.is_false(ok)
  assert.truthy(err:find("^fetch_url: could not spawn curl: .*spawn boom"))
  for _, f in ipairs(cancel_fns) do assert.is_true(pcall(f)) end
end)

local function cancellation_probe(check)
  local saved = { system = vim.system, schedule = vim.schedule, defer = vim.defer_fn,
    dns = vim.uv.getaddrinfo, executable = vim.fn.executable }
  local queue, timers, run = {}, {}, { cancelled = false, done = false, await_seq = 0, cancel_fns = {} }
  local new_ctx
  for i = 1, 100 do
    local name, value = debug.getupvalue(require("straps.loop").start, i)
    if not name then break end
    if name == "new_ctx" then new_ctx = value; break end
  end
  assert(new_ctx, "loop.start must retain the installed new_ctx")
  local probe = { resumes = 0, completed = 0, spawned = 0, killed = 0 }
  local cctx = new_ctx(0, run)
  vim.schedule = function(fn) queue[#queue + 1] = fn end
  vim.defer_fn = function(fn) timers[#timers + 1] = fn end
  vim.fn.executable = function() return 1 end
  vim.uv.getaddrinfo = function(_, _, _, callback) probe.dns = callback; return {} end
  vim.system = function(_, opts, callback)
    probe.spawned = probe.spawned + 1
    probe.exit = callback
    return { kill = function(_, signal) probe.killed = probe.killed + 1; assert.are.equal(9, signal) end }
  end
  function probe.start(url)
    probe.co = coroutine.create(function()
      probe.ok, probe.result = pcall(registry.call, "tool.fetch_url", { url = url }, cctx)
      probe.completed = probe.completed + 1
    end)
    assert(coroutine.resume(probe.co))
    assert.are.equal("suspended", coroutine.status(probe.co))
  end
  function probe.cancel()
    run.cancelled = true
    local handlers = run.cancel_fns
    run.cancel_fns = {}
    for _, fn in ipairs(handlers) do fn() end
  end
  function probe.flush()
    while #queue > 0 do
      probe.resumes = probe.resumes + 1
      table.remove(queue, 1)()
    end
  end
  probe.timers = timers
  local ok, err = xpcall(function() check(probe) end, debug.traceback)
  vim.system, vim.schedule, vim.defer_fn = saved.system, saved.schedule, saved.defer
  vim.uv.getaddrinfo, vim.fn.executable = saved.dns, saved.executable
  assert(ok, err)
end

it("fetch_url cancellation during active DNS resolves once without spawning curl", function()
  cancellation_probe(function(p)
    local slots = registry.subprocess_state().in_flight
    p.start("http://pending.example/x")
    assert.is_function(p.dns)
    assert.are.equal(0, p.spawned)
    p.cancel()
    p.flush()
    assert.is_false(p.ok)
    assert.truthy(p.result:find("fetch_url: DNS lookup timed out", 1, true), p.result)
    assert.are.equal(1, p.completed)
    assert.are.equal(1, p.resumes)
    p.dns(nil, { { addr = "93.184.216.34" } })
    p.timers[1]()
    p.flush()
    assert.are.equal(1, p.resumes)
    assert.are.equal(1, p.completed)
    assert.are.equal(0, p.spawned)
    assert.are.equal(slots, registry.subprocess_state().in_flight)
  end)
end)

it("fetch_url cancellation kills active curl and releases its slot before late duplicate exits", function()
  cancellation_probe(function(p)
    local slots = registry.subprocess_state().in_flight
    p.start("http://93.184.216.34/x")
    assert.are.equal(1, p.spawned)
    assert.are.equal(slots + 1, registry.subprocess_state().in_flight)
    p.cancel()
    assert.are.equal(1, p.killed)
    assert.are.equal(slots, registry.subprocess_state().in_flight)
    assert.are.equal(0, p.completed)
    p.exit({ code = 137, stderr = "" })
    p.exit({ code = 0, stderr = "duplicate" })
    p.flush()
    assert.is_true(p.ok)
    assert.are.equal("exit code: 137\n", p.result)
    assert.are.equal(1, p.completed)
    assert.are.equal(1, p.resumes)
    assert.are.equal(slots, registry.subprocess_state().in_flight)
  end)
end)

it("glob raises a prefixed error for an unbalanced brace and supports {a,b}", function()
  local ok, err = pcall(call_tool, "glob", { pattern = root .. "/lua/straps/{loop" })
  assert.is_false(ok)
  assert.truthy(err:find("^glob: invalid pattern .*E220"), err)
  local out = call_tool("glob", { pattern = root .. "/lua/straps/{loop,state}.lua" })
  assert.truthy(out:find("loop.lua", 1, true) and out:find("state.lua", 1, true), out)
end)

it("run_in_terminal and run_quickfix run in Neovim's global working directory", function()
  local dir = vim.uv.fs_realpath(vim.fn.tempname():match("^(.*)/"))
  local saved = vim.fn.getcwd
  local seen = {}
  vim.fn.getcwd = function(...) seen[#seen + 1] = select("#", ...); return dir end
  local out = call_tool("run_quickfix", { command = "pwd -P | sed 's|$|:1:1: here|'", errorformat = "%f:%l:%c: %m" })
  vim.fn.getcwd = saved
  assert.truthy(out:find(vim.fn.fnamemodify(dir, ":.") .. ":1:1: here", 1, true), out)
  assert.are.same({ 2 }, seen)
end)

for _, stream in ipairs({ "stdout", "stderr" }) do
  it("run_quickfix caps " .. stream .. " at 262144 bytes before parsing", function()
    local saved_system, saved_getqflist, saved_defer = vim.system, vim.fn.getqflist, vim.defer_fn
    local parsed_raw
    vim.system = function(_, opts, done)
      opts[stream](nil, string.rep("x", 262140))
      opts[stream](nil, "123456789")
      opts[stream](nil, "ignored")
      done({ code = 0 })
      return { pid = 123 }
    end
    vim.defer_fn = function() end
    vim.fn.getqflist = function(opts)
      if opts and opts.lines then parsed_raw = table.concat(opts.lines, "\n"); return { items = {} } end
      return saved_getqflist(opts)
    end
    local ok, out = pcall(call_tool, "run_quickfix", { command = "stubbed", errorformat = "%f:%l:%c: %m", open = false })
    vim.system, vim.fn.getqflist, vim.defer_fn = saved_system, saved_getqflist, saved_defer
    assert(ok, out)
    assert.truthy(out:find("output truncated at 262144 bytes per stream", 1, true), out)
    assert.are.equal(262144, #parsed_raw)
    assert.are.equal("xxxx1234", parsed_raw:sub(-8))
  end)
end

it("run_quickfix does not claim truncation below the stream cap", function()
  local out = call_tool("run_quickfix", { command = "head -c 1000 /dev/zero | tr '\\0' x", errorformat = "%f:%l:%c: %m", open = false })
  assert.falsy(out:find("output truncated", 1, true), out)
end)

it("read_file and path_info match a buffer by exact full path, not a bufname pattern", function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local real = dir .. "/target.txt"
  local f = assert(io.open(real, "w")); f:write("disk\n"); f:close()
  local decoy = vim.fn.bufadd(dir .. "/target.txt.bak")
  vim.fn.bufload(decoy)
  vim.api.nvim_buf_set_lines(decoy, 0, -1, false, { "DECOY" })
  vim.bo[decoy].modified = true
  local info = call_tool("path_info", { paths = { real } })
  assert.falsy(info:find("loaded", 1, true), info)
  local out = call_tool("read_file", { path = real })
  assert.truthy(out:find("disk", 1, true), out)
  assert.falsy(out:find("DECOY", 1, true), out)
  local only = dir .. "/only.txt"
  local g = assert(io.open(only, "w")); g:write("only\n"); g:close()
  call_tool("read_file", { path = only })
  local ok, err = pcall(call_tool, "read_file", { path = dir .. "/only" })
  assert.is_false(ok)
  assert.are.equal("read_file: cannot open " .. dir .. "/only: no such file", err)
end)

it("registry_list accepts kind=skill", function()
  local schema = registry.get("tool.registry_list").input_schema
  assert.truthy(vim.tbl_contains(schema.properties.kind.enum, "skill"))
  registry.define({ name = "skill.bg_skill", kind = "skill", doc = "a test skill", source = "prose" })
  local out = call_tool("registry_list", { kind = "skill" })
  assert.truthy(out:find("skill.bg_skill", 1, true), out)
  assert.falsy(out:find("tool.", 1, true), out)
end)
