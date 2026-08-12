-- straps.guard: the "wait tripwire". Agent-authored tool sources sometimes
-- call vim.system():wait() or vim.wait() to do subprocess/timer work — the
-- exact mistake the register-time warning in layers/selfext.lua flags, and
-- the one that actually froze a real session (see .straps.lua's tool.run_tests
-- history). Warning alone did not stop a repeat. This module makes the
-- mistake FAIL FAST instead: inside a straps run coroutine, the wait family
-- errors with a teaching message pointing at ctx.await/ctx.system, rather
-- than silently blocking Neovim's main loop (UI, transcript, :StrapsStop)
-- until the subprocess exits.
--
-- Scope, stated plainly: this guards vim.system():wait() and vim.wait() only.
-- vim.fn.system is left to the register-time pattern warning (layers/selfext.lua)
-- deliberately — wrapping vim.fn is riskier (it is a magic table, not a plain
-- function) and short legitimate uses inside runs are common enough that a
-- hard error there would cost more false positives than it prevents.
--
-- KNOWN LIMITATION: marking is by coroutine IDENTITY. A tool source that
-- spawns its OWN nested coroutine (coroutine.create/coroutine.wrap) and calls
-- a blocking wait from inside THAT coroutine is invisible to in_run() —
-- coroutine.running() there returns the new, unmarked coroutine, so the guard
-- does not fire and the wait blocks the main loop exactly as before. This is
-- a real gap, not fixable without instrumenting coroutine.create itself
-- (which would be a much larger, riskier intervention); it is accepted and
-- documented here and in the system prompt rather than silently left open.

local M = {}

-- Weak keys: a finished/garbage-collected coroutine's entry is reclaimed
-- automatically, so this never grows without bound across a long session.
local marked = setmetatable({}, { __mode = "k" })

local suppressed = false
local installed = false

--- Mark a coroutine as "inside a straps run" — call this on every coroutine
--- the loop creates to execute a run or a parallel-readonly tool batch.
function M.mark(co)
  if co then
    marked[co] = true
  end
end

--- True when running on a coroutine M.mark'd as a run, and not currently
--- inside M.allow_blocking. Main-thread calls (coroutine.running() == nil
--- under LuaJIT/Lua 5.1 semantics) are never "in run".
function M.in_run()
  if suppressed then
    return false
  end
  local co = coroutine.running()
  return co ~= nil and marked[co] == true
end

local function pack(...)
  return { n = select("#", ...), ... }
end
local unpack = unpack or table.unpack

--- Run fn(...) with the guard suppressed for its ENTIRE synchronous extent —
--- for a deliberate, bounded blocking call inside a run (see provider.lua's
--- fn.system_prompt_env git branch). fn must not yield (it runs synchronously
--- start to finish; there is no coroutine boundary to restore `suppressed`
--- correctly around a yield). Because SystemObj:wait() itself calls the
--- (possibly wrapped) global vim.wait internally, suppressing must cover the
--- whole call, not just the outer vim.system():wait() frame — this function
--- does that by construction (one flag, held for fn's whole extent).
function M.allow_blocking(fn, ...)
  local prev = suppressed
  suppressed = true
  local results = pack(pcall(fn, ...))
  suppressed = prev
  if not results[1] then
    error(results[2], 0)
  end
  return unpack(results, 2, results.n)
end

-- level = the stack frame to blame in the error's "file:line:" prefix, counted
-- from teaching_error's own frame. Both wrappers pass 3 (tool -> wrapper ->
-- teaching_error), which blames the tool's call site rather than guard.lua
-- itself. This is best-effort: when a tool reaches the wait through its own
-- helper frames the cited line can be one frame off, so the MESSAGE TEXT (not
-- the prefix) is the load-bearing part — it names the mistake and the fix
-- regardless of which line the prefix lands on.
local function teaching_error(what, alt, level)
  error(("straps: %s inside a tool source blocks Neovim's main loop — the UI,"
    .. " the transcript, and :StrapsStop all freeze until it returns. Use %s"
    .. " instead."):format(what, alt), level)
end

--- Install the tripwire (idempotent — a second call is a no-op). Wraps the
--- global vim.system so every returned SystemObj's :wait() errors when
--- called in_run(), and wraps the global vim.wait the same way. Outside a
--- run (main thread, a hook invoked directly, a test with no marked
--- coroutine), both behave exactly as stock Neovim.
function M.install()
  if installed then
    return
  end
  installed = true

  local real_system = vim.system
  vim.system = function(cmd, opts, on_exit)
    local obj = real_system(cmd, opts, on_exit)
    -- SystemObj is a plain table whose methods resolve through a metatable
    -- __index (see $VIMRUNTIME lua/vim/_core/system.lua new_systemobj), so an
    -- own field on THIS instance shadows the method without touching the
    -- shared metatable or any other SystemObj.
    local real_wait = obj.wait
    obj.wait = function(self, timeout)
      if M.in_run() then
        teaching_error("vim.system():wait()",
          "ctx.await(function(resolve) vim.system(cmd, opts, resolve) end), or"
            .. " ctx.system(cmd, opts)", 3)
      end
      return real_wait(self, timeout)
    end
    return obj
  end

  local real_vim_wait = vim.wait
  vim.wait = function(...)
    if M.in_run() then
      teaching_error("vim.wait()", "ctx.await", 3)
    end
    return real_vim_wait(...)
  end
end

return M
