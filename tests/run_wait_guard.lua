-- tests/run_wait_guard.lua — the "wait tripwire" (lua/straps/guard.lua) and
-- ctx.system sugar. Run from anywhere:
--   nvim --headless -l tests/run_wait_guard.lua
-- No network: fn.provider is redefined with scripted stubs, same pattern as
-- tests/run_loop.lua. Plain asserts; exits 0/1.

local script = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(vim.fn.fnamemodify(script, ":p"), ":h:h")
vim.opt.runtimepath:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local registry = require("straps.registry")
local state = require("straps.state")
local loop = require("straps.loop")
local guard = require("straps.guard")
require("straps.provider").register()
require("straps").config.session_dir = vim.fn.tempname()

local failed = 0
local function case(name, fn)
  local ok, err = pcall(fn)
  if ok then
    print("PASS  " .. name)
  else
    failed = failed + 1
    print("FAIL  " .. name .. "\n      " .. tostring(err))
  end
end

local function define(name, kind, doc, source)
  registry.define({ name = name, kind = kind, doc = doc, source = source })
end

local function buf_text(bufnr)
  return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
end

local function new_session_with_prompt(text)
  local bufnr = state.new_session()
  state.append_text(bufnr, text)
  return bufnr
end

local function wait_done(bufnr)
  assert(vim.wait(5000, function() return not loop.running(bufnr) end, 10),
    "run did not finish within 5s")
end

local function allow_all()
  define("hook.confirm", "hook", "test: allow everything", "return function() return true end")
end

allow_all()
guard.install()

-- One tool_use for `tool_name`, then end_turn — the shared one-call script
-- every case below reuses.
local function one_call_provider(tool_name, tool_input)
  define("fn.provider", "fn", "test: one tool call then end_turn", ([==[
return function(req, ctx)
  ctx.await(function(resolve) vim.defer_fn(resolve, 5) end)
  if _G.straps_test_called then
    return { stop_reason = "end_turn", content = { { type = "text", text = "done" } } }
  end
  _G.straps_test_called = true
  return { stop_reason = "tool_use", content = {
    { type = "tool_use", id = "t1", name = %q, input = %s },
  } }
end
]==]):format(tool_name, tool_input or "vim.empty_dict()"))
end

-- --------------------------------------------------------------- (a)/(b)

case("vim.system():wait() inside a run errors with a teaching message", function()
  _G.straps_test_called = false
  define("tool.blocking_wait", "tool", "test: blocking wait", [==[
return function(input, ctx)
  return vim.system({ "true" }, { text = true }):wait().code
end
]==])
  one_call_provider("blocking_wait")

  local bufnr = new_session_with_prompt("call the blocking tool")
  loop.start(bufnr)
  wait_done(bufnr)

  local text = buf_text(bufnr)
  assert(text:find('"is_error":true', 1, true), "tool_result should be an error:\n" .. text)
  assert(text:find("blocks Neovim's main loop", 1, true),
    "missing teaching message:\n" .. text)
  assert(text:find("ctx.await", 1, true) or text:find("ctx.system", 1, true),
    "teaching message should point at the fix:\n" .. text)
  -- The run itself still ends normally (the error is a TOOL error, not a
  -- run crash) — a fresh case-9 empty session is unaffected.
  assert(not loop.running(bufnr), "run should have ended")
end)

case("vim.wait() inside a run errors with a teaching message", function()
  _G.straps_test_called = false
  define("tool.blocking_vimwait", "tool", "test: vim.wait", [==[
return function(input, ctx)
  vim.wait(50)
  return "unreachable"
end
]==])
  one_call_provider("blocking_vimwait")

  local bufnr = new_session_with_prompt("call the vim.wait tool")
  loop.start(bufnr)
  wait_done(bufnr)

  local text = buf_text(bufnr)
  assert(text:find('"is_error":true', 1, true), "tool_result should be an error:\n" .. text)
  assert(text:find("blocks Neovim's main loop", 1, true),
    "missing teaching message:\n" .. text)
end)

-- Counterfactual for (a)/(b): with the guard NOT installed (a fresh
-- unwrapped vim.system/vim.wait), the same tool sources must NOT error —
-- proving the assertions above test the guard, not some unrelated failure.
-- We can't literally uninstall (guard.install is idempotent-forward-only by
-- design), so instead we verify directly against the pre-guard behavior:
-- the ORIGINAL vim.wait (captured before install() ran at file load) does
-- not raise outside a run either way; the real counterfactual is case (c)
-- below, which proves in_run()-gating, not just "guard exists".

-- ------------------------------------------------------------------- (c)

case("outside a run, vim.system():wait() and vim.wait() still work (pass-through)", function()
  local res = vim.system({ "true" }, { text = true }):wait()
  assert(res.code == 0, "vim.system():wait() should pass through outside a run")
  local satisfied = false
  vim.defer_fn(function() satisfied = true end, 5)
  local ok = vim.wait(2000, function() return satisfied end, 10)
  assert(ok == true, "vim.wait() should pass through outside a run")
end)

-- ------------------------------------------------------------------- (d)

case("allow_blocking suppresses the guard inside a run", function()
  _G.straps_test_called = false
  define("tool.blessed_wait", "tool", "test: allow_blocking-wrapped wait", [==[
return function(input, ctx)
  local guard = require("straps.guard")
  local res = guard.allow_blocking(function()
    return vim.system({ "true" }, { text = true }):wait()
  end)
  return "exit " .. tostring(res.code)
end
]==])
  one_call_provider("blessed_wait")

  local bufnr = new_session_with_prompt("call the blessed tool")
  loop.start(bufnr)
  wait_done(bufnr)

  local text = buf_text(bufnr)
  assert(not text:find('"is_error":true', 1, true), "allow_blocking-wrapped call should not error:\n" .. text)
  assert(text:find("exit 0", 1, true), "missing the blessed call's result:\n" .. text)
end)

-- ------------------------------------------------------------------- (e)

case("guard.install() twice does not double-wrap", function()
  guard.install()
  guard.install()
  local res = vim.system({ "true" }, { text = true }):wait()
  assert(res.code == 0, "double-install should not break pass-through: " .. vim.inspect(res))
end)

-- ------------------------------------------------------------------- (f)

case("ctx.system returns a result inside a run", function()
  _G.straps_test_called = false
  define("tool.via_ctx_system", "tool", "test: ctx.system", [==[
return function(input, ctx)
  local res = ctx.system({ "true" }, { text = true })
  return "code=" .. tostring(res.code)
end
]==])
  one_call_provider("via_ctx_system")

  local bufnr = new_session_with_prompt("call the ctx.system tool")
  loop.start(bufnr)
  wait_done(bufnr)

  local text = buf_text(bufnr)
  assert(not text:find('"is_error":true', 1, true), "ctx.system call should not error:\n" .. text)
  assert(text:find("code=0", 1, true), "missing ctx.system's result:\n" .. text)
end)

-- --------------------------------------------------- git-branch fixture (D)

-- fn.system_prompt_env's git branch (provider.lua) wraps its :wait(500) in
-- guard.allow_blocking — but that branch is DEAD in this repo's own test
-- runs, because straps itself is a colocated jj+git repo and the jj check
-- wins. Build a throwaway dir with ONLY .git (no .jj) and chdir into it so
-- the git branch (and its allow_blocking wrap) actually executes.
case("fn.system_prompt_env's git branch (allow_blocking) does not trip the guard", function()
  local tmp = vim.fn.tempname()
  vim.fn.mkdir(tmp, "p")
  -- A real `git init`, not just an empty .git/ dir: vim.fs.find(".git") only
  -- needs the directory to exist, but the guarded `git rev-parse` call needs
  -- an actual repository underneath it, or it exits nonzero and the branch's
  -- own pcall silently swallows that — indistinguishable from a guard firing.
  local init = vim.system({ "git", "init", "-q", tmp }, { text = true }):wait(5000)
  assert(init.code == 0, "git init failed, cannot build the fixture: " .. tostring(init.stderr))
  local cfg1 = vim.system({ "git", "-C", tmp, "config", "user.email", "t@example.com" }):wait(2000)
  local cfg2 = vim.system({ "git", "-C", tmp, "config", "user.name", "t" }):wait(2000)
  assert(cfg1.code == 0 and cfg2.code == 0, "git config failed, cannot build the fixture")
  -- `git rev-parse --abbrev-ref HEAD` needs a resolvable HEAD, which needs at
  -- least one commit — an init with no commits leaves HEAD unborn.
  local commit = vim.system({ "git", "-C", tmp, "commit", "--allow-empty", "-q", "-m", "init" })
    :wait(5000)
  assert(commit.code == 0, "git commit failed, cannot build the fixture: " .. tostring(commit.stderr))
  local prev_cwd = vim.fn.getcwd()
  local ok, err = pcall(function()
    vim.fn.chdir(tmp)
    -- Run fn.system_prompt_env ON A MARKED COROUTINE, exactly like the real
    -- in-run call path (tool.spawn -> state.new_session -> fn.system_prompt),
    -- so this genuinely exercises in_run() == true, not a main-thread call.
    local co = coroutine.create(function()
      return registry.call("fn.system_prompt_env")
    end)
    guard.mark(co)
    local resumed, env = coroutine.resume(co)
    assert(resumed, "fn.system_prompt_env raised instead of using allow_blocking: " .. tostring(env))
    -- desc = "git" is set unconditionally BEFORE the guarded :wait(500) calls
    -- run — so asserting only "contains git" would pass even if the guard
    -- fired and pcall silently swallowed it (verified: an earlier version of
    -- this test passed with allow_blocking bypassed entirely). Require the
    -- "(branch " text that ONLY appears when `git rev-parse --abbrev-ref
    -- HEAD` actually returned output through the allow_blocking-wrapped wait.
    assert(type(env) == "string" and env:find("git (branch ", 1, true),
      "expected 'git (branch ...' — the guarded wait may have raised/failed"
        .. " silently instead of returning real git output:\n" .. tostring(env))
  end)
  vim.fn.chdir(prev_cwd)
  assert(ok, err)
end)

print(("%s (%d case%s failed)"):format(failed == 0 and "ALL PASS" or "FAILED",
  failed, failed == 1 and "" or "s"))
if failed > 0 then
  os.exit(1)
end
