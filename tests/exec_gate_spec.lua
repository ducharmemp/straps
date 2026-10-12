-- tests/exec_gate_spec.lua — the subprocess semaphore shared by the shell
-- tools and grep (fn.subprocess_acquire / fn.subprocess_limit /
-- fn.subprocess_threads / fn.subprocess_in_flight, layers/exec.lua).
--   busted tests/exec_gate_spec.lua
-- No network. Registers the real tools, pins fn.subprocess_limit to a small
-- number, and drives tool.bash / tool.grep through a coroutine ctx so a call
-- past the limit parks in ctx.await. Covers: the default limit and
-- config.max_subprocesses; parking and FIFO admission at the limit; a limit
-- raised mid-wait, with and without a release; release on every cancel path
-- (a parked waiter, a running holder, a waiter admitted then cancelled before
-- or after its resume); the direct-call (no await) path; the derived
-- --threads count on rg's argv; the grep timeout; a raising vim.system
-- (EAGAIN) in each tool; a failing terminal split; grep refusing a ctx with
-- no await; and the removed-fn fallback.

local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(vim.fn.fnamemodify(here, ":p"), ":h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local registry = require("straps.registry")
require("straps.tools").register()

local unpack = unpack or table.unpack
local function pack(...) return { n = select("#", ...), ... } end

local function define_limit(n)
  local st = registry.subprocess_state()
  st.in_flight, st.waiters = 0, {}
  registry.define({ name = "fn.subprocess_limit", kind = "fn", doc = "test: fixed limit",
    source = "return function() return " .. n .. " end" })
end

-- A run-shaped ctx: await parks the coroutine, resolve resumes it through
-- vim.schedule, on_cancel collects handlers that cancel() fires (as
-- loop.stop does). Returns the ctx and a handle { done, out, err, cancel }.
local function start(thunk)
  local h = { done = false, cancel_fns = {} }
  local co
  local ctx = {
    bufnr = 0,
    await = function(begin)
      local resolved = false
      begin(function(...)
        if resolved then return end
        resolved = true
        local a = pack(...)
        vim.schedule(function()
          if coroutine.status(co) == "suspended" then
            local ok, e = coroutine.resume(co, unpack(a, 1, a.n))
            if not ok then h.done, h.err = true, e end
          end
        end)
      end)
      local r = pack(coroutine.yield())
      h.cancel_fns = {}
      return unpack(r, 1, r.n)
    end,
    on_cancel = function(fn)
      if h.cancelled then pcall(fn) return end
      h.cancel_fns[#h.cancel_fns + 1] = fn
    end,
    cancelled = function() return h.cancelled == true end,
  }
  h.cancel = function()
    h.cancelled = true
    local fns = h.cancel_fns
    h.cancel_fns = {}
    for _, fn in ipairs(fns) do pcall(fn) end
  end
  co = coroutine.create(function()
    local ok, r = pcall(thunk, ctx)
    if ok then h.out = r else h.err = r end
    h.done = true
  end)
  local ok, err = coroutine.resume(co)
  if not ok then error(err) end
  return h
end

local function wait_for(pred, ms)
  vim.wait(ms or 8000, pred, 10)
  return pred()
end

local function in_flight()
  return registry.call("fn.subprocess_in_flight")
end

local function bash_sleep(seconds, marker)
  return function(ctx)
    return registry.call("tool.bash", { command = ("sleep %s; echo %s"):format(seconds, marker) }, ctx)
  end
end

it("fn.subprocess_limit defaults to 2 * CPU count when max_subprocesses is nil", function()
  local straps = require("straps")
  local prev = straps.config and straps.config.max_subprocesses
  if straps.config then straps.config.max_subprocesses = nil end
  local original = registry.get("fn.subprocess_limit")
  registry.define({ name = "fn.subprocess_limit", kind = "fn", doc = original.doc, source = original.source })
  local ncpu = vim.uv.available_parallelism() or 1
  local got = registry.call("fn.subprocess_limit")
  local load = vim.uv.loadavg() or 0
  local expect = load > 2 * ncpu and ncpu or 2 * ncpu
  assert(got == expect, ("limit %s, expected %d (ncpu %d, load %s)"):format(tostring(got), expect, ncpu, tostring(load)))
  if straps.config then
    straps.config.max_subprocesses = 3
    local with_three = registry.call("fn.subprocess_limit")
    straps.config.max_subprocesses = prev
    assert(with_three == (load > 2 * ncpu and 1 or 3), "config.max_subprocesses not honored: " .. tostring(with_three))
  end
end)

it("at the limit the next call parks and is admitted when a slot frees", function()
  define_limit(1)
  local a = start(bash_sleep("0.4", "A"))
  assert(wait_for(function() return in_flight() == 1 end, 2000), "first call did not take a slot")
  local b = start(bash_sleep("0", "B"))
  local c = start(bash_sleep("0", "C"))
  vim.wait(150, function() return false end, 10)
  assert(in_flight() == 1, "parked calls must not hold slots, in_flight=" .. in_flight())
  assert(not b.done and not c.done, "parked calls ran before the slot freed")
  assert(wait_for(function() return a.done and b.done and c.done end), "calls did not finish: "
    .. tostring(a.err) .. " / " .. tostring(b.err) .. " / " .. tostring(c.err))
  assert(a.out:find("A", 1, true) and b.out:find("B", 1, true) and c.out:find("C", 1, true), "lost output")
  assert(in_flight() == 0, "slots not released, in_flight=" .. in_flight())
end)

it("admission order is FIFO: B (queued first) runs before C", function()
  define_limit(1)
  local a = start(bash_sleep("0.3", "A"))
  assert(wait_for(function() return in_flight() == 1 end, 2000))
  local order = {}
  local function marked(m)
    return function(ctx)
      local r = registry.call("tool.bash", { command = "echo " .. m }, ctx)
      order[#order + 1] = m
      return r
    end
  end
  local b = start(marked("B"))
  local c = start(marked("C"))
  vim.wait(100, function() return false end, 10)
  assert(not b.done and not c.done and #order == 0, "B/C ran while A held the only slot")
  assert(wait_for(function() return a.done and b.done and c.done end))
  assert(order[1] == "B" and order[2] == "C", "order was " .. table.concat(order, ","))
  assert(in_flight() == 0, "slots not released, in_flight=" .. in_flight())
end)

it("raising the limit admits the parked waiters on the next release", function()
  define_limit(1)
  local a = start(bash_sleep("0.3", "A"))
  assert(wait_for(function() return in_flight() == 1 end, 2000))
  local b = start(bash_sleep("0.3", "B"))
  local c = start(bash_sleep("0.3", "C"))
  vim.wait(100, function() return false end, 10)
  assert(in_flight() == 1)
  registry.define({ name = "fn.subprocess_limit", kind = "fn", doc = "test: raised", source = "return function() return 3 end" })
  -- The new limit is read when A releases; both waiters then run at once.
  assert(wait_for(function() return a.done end))
  assert(wait_for(function() return in_flight() == 2 end, 500), "both waiters should hold slots, in_flight=" .. in_flight())
  assert(wait_for(function() return b.done and c.done end))
  assert(in_flight() == 0)
end)

it("raising the limit while waiters are parked admits them at the next acquire, with no release", function()
  define_limit(1)
  local holder = registry.call("fn.subprocess_acquire", {}, { tool = "holder" })
  local b = start(bash_sleep("0", "B"))
  vim.wait(50, function() return false end, 10)
  assert(not b.done and #registry.subprocess_state().waiters == 1, "B should be parked")
  registry.define({ name = "fn.subprocess_limit", kind = "fn", doc = "test", source = "return function() return 3 end" })
  local extra = registry.call("fn.subprocess_acquire", {}, { tool = "probe" })
  assert(#registry.subprocess_state().waiters == 0, "the acquire did not drain the queue under the raised limit")
  assert(wait_for(function() return b.done end), "B never ran: " .. tostring(b.err))
  extra(); holder()
  assert(in_flight() == 0)
end)

it("a run cancelled between admission and resume errors instead of starting its process", function()
  define_limit(1)
  local holder = registry.call("fn.subprocess_acquire", {}, { tool = "holder" })
  local b = start(bash_sleep("0", "B"))
  vim.wait(50, function() return false end, 10)
  assert(not b.done)
  holder()
  assert(in_flight() == 1, "B should hold the slot after admission, in_flight=" .. in_flight())
  b.cancelled = true
  assert(wait_for(function() return b.done end, 2000))
  assert(b.err and tostring(b.err):find("slot wait cancelled", 1, true), "expected the cancel error, got " .. tostring(b.err) .. " / " .. tostring(b.out))
  assert(in_flight() == 0, "declined admission leaked a slot, in_flight=" .. in_flight())
end)

it("cancelling a parked waiter drops it from the queue without taking a slot", function()
  define_limit(1)
  local a = start(bash_sleep("0.3", "A"))
  assert(wait_for(function() return in_flight() == 1 end, 2000))
  local b = start(bash_sleep("0", "B"))
  vim.wait(50, function() return false end, 10)
  b.cancel()
  assert(wait_for(function() return b.done end, 2000), "cancelled waiter did not end")
  assert(b.err and tostring(b.err):find("slot wait cancelled", 1, true), "expected the cancel error, got " .. tostring(b.err) .. " / " .. tostring(b.out))
  assert(wait_for(function() return a.done end))
  assert(in_flight() == 0, "cancelled waiter leaked a slot, in_flight=" .. in_flight())
  assert(#registry.subprocess_state().waiters == 0, "cancelled waiter left in the queue")
end)

it("a waiter cancelled while parked is dropped before the coroutine resumes", function()
  define_limit(1)
  local holder = registry.call("fn.subprocess_acquire", {}, { tool = "holder" })
  local fns = {}
  local ctx = {
    on_cancel = function(fn) fns[#fns + 1] = fn end,
    await = function(begin)
      begin(function() end)
      return coroutine.yield()
    end,
  }
  local co = coroutine.create(function() registry.call("fn.subprocess_acquire", ctx, { tool = "waiter" }) end)
  assert(coroutine.resume(co))
  assert(#registry.subprocess_state().waiters == 1, "waiter not queued")
  for _, fn in ipairs(fns) do fn() end
  assert(#registry.subprocess_state().waiters == 0, "cancel handler must drop the parked waiter at once")
  holder()
  assert(in_flight() == 0, "a dead waiter was admitted on release, in_flight=" .. in_flight())
end)

it("cancelling a running holder releases its slot synchronously, before the process exits", function()
  define_limit(1)
  local a = start(bash_sleep("1", "A"))
  assert(wait_for(function() return in_flight() == 1 end, 2000))
  local fns = a.cancel_fns
  a.cancelled = true
  a.cancel_fns = {}
  for _, fn in ipairs(fns) do assert(pcall(fn)) end
  assert(in_flight() == 0, "release did not run synchronously in the cancel handlers, in_flight=" .. in_flight())
  assert(not a.done, "the exit callback cannot have fired synchronously; this case did not separate cancel from exit")
  assert(wait_for(function() return a.done end, 4000), "holder never finished")
  assert(in_flight() == 0)
end)

it("acquire registers release on ctx.on_cancel, so a holder that never resolves still frees its slot", function()
  define_limit(4)
  local fns = {}
  local ctx = { on_cancel = function(fn) fns[#fns + 1] = fn end }
  registry.call("fn.subprocess_acquire", ctx, { tool = "test" })
  assert(in_flight() == 1)
  for _, fn in ipairs(fns) do fn() end
  assert(in_flight() == 0, "cancel handlers did not release, in_flight=" .. in_flight())
end)

it("a ctx without await (direct registry.call) is admitted at once", function()
  define_limit(1)
  local a = start(bash_sleep("0.3", "A"))
  assert(wait_for(function() return in_flight() == 1 end, 2000))
  local release = registry.call("fn.subprocess_acquire", {}, { tool = "test" })
  assert(in_flight() == 2, "direct call should take a slot immediately, in_flight=" .. in_flight())
  release()
  release()
  assert(in_flight() == 1, "release must be idempotent, in_flight=" .. in_flight())
  assert(wait_for(function() return a.done end))
  assert(in_flight() == 0)
end)

it("fn.subprocess_threads divides the CPU count by the slots in flight", function()
  define_limit(8)
  local ncpu = vim.uv.available_parallelism() or 1
  assert(registry.call("fn.subprocess_threads") == ncpu, "idle: every core")
  local r1 = registry.call("fn.subprocess_acquire", {}, { tool = "t" })
  local r2 = registry.call("fn.subprocess_acquire", {}, { tool = "t" })
  assert(registry.call("fn.subprocess_threads") == math.max(1, math.floor(ncpu / 2)),
    "two in flight: ncpu/2, got " .. registry.call("fn.subprocess_threads"))
  r1(); r2()
  assert(in_flight() == 0)
end)

it("grep passes --threads from fn.subprocess_threads and still matches", function()
  if vim.fn.executable("rg") ~= 1 then return end
  define_limit(8)
  local saved = registry.get("fn.subprocess_threads")
  registry.define({ name = "fn.subprocess_threads", kind = "fn", doc = "test", source = "return function() return 3 end" })
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local f = assert(io.open(dir .. "/x.txt", "w")); f:write("NEEDLE\n"); f:close()
  local seen_argv
  local real_system = vim.system
  vim.system = function(argv, ...)
    if argv[1] == "rg" then seen_argv = vim.deepcopy(argv) end
    return real_system(argv, ...)
  end
  local h = start(function(ctx)
    return registry.call("tool.grep", { pattern = "NEEDLE", path = dir }, ctx)
  end)
  local ok_wait = wait_for(function() return h.done end)
  vim.system = real_system
  registry.define({ name = "fn.subprocess_threads", kind = "fn", doc = saved.doc, source = saved.source })
  assert(ok_wait, "grep did not finish")
  assert(h.out and h.out:find("NEEDLE", 1, true), "grep lost its match: " .. tostring(h.out) .. tostring(h.err))
  assert(in_flight() == 0, "grep did not release, in_flight=" .. in_flight())
  local joined = table.concat(seen_argv or {}, " ")
  assert(joined:find("--threads 3", 1, true), "rg argv lacks --threads from fn.subprocess_threads: " .. joined)
end)

it("grep is killed after timeout_ms and reports the timeout", function()
  define_limit(8)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  -- A FIFO never reaches EOF, so rg/grep block on it until killed.
  local fifo = dir .. "/pipe"
  vim.fn.system({ "mkfifo", fifo })
  local h = start(function(ctx)
    return registry.call("tool.grep", { pattern = "x", path = fifo, timeout_ms = 300 }, ctx)
  end)
  assert(wait_for(function() return h.done end, 5000), "grep on a fifo never returned: " .. tostring(h.err))
  assert(h.out and h.out:find("grep timed out after 300 ms", 1, true), "expected a timeout result, got " .. tostring(h.out) .. tostring(h.err))
  assert(in_flight() == 0, "timed-out grep leaked a slot")
end)

it("a vim.system that raises (EAGAIN) releases the slot and returns an error result", function()
  define_limit(4)
  local real_system = vim.system
  vim.system = function(argv, ...)
    if argv[1] == "bash" or argv[1] == "rg" or argv[1] == "grep" then error("EAGAIN: resource temporarily unavailable") end
    return real_system(argv, ...)
  end
  local a = start(function(ctx) return registry.call("tool.bash", { command = "echo never" }, ctx) end)
  local q = start(function(ctx) return registry.call("tool.run_quickfix", { command = "echo never" }, ctx) end)
  local g = start(function(ctx)
    return registry.call("tool.grep", { pattern = "x", path = root .. "/tests" }, ctx)
  end)
  local ok_wait = wait_for(function() return a.done and q.done and g.done end, 5000)
  vim.system = real_system
  assert(ok_wait, "tools hung after a raising spawn")
  assert(in_flight() == 0, "a raising spawn leaked a slot, in_flight=" .. in_flight())
  assert(a.out and a.out:find("could not spawn", 1, true), "bash: " .. tostring(a.out) .. tostring(a.err))
  assert(q.out and q.out:find("could not spawn", 1, true), "run_quickfix: " .. tostring(q.out) .. tostring(q.err))
  assert(g.out and g.out:find("could not spawn", 1, true), "grep: " .. tostring(g.out) .. tostring(g.err))
end)

it("a waiter admitted and then cancelled before its coroutine resumes releases through the cancel handler", function()
  define_limit(1)
  local holder = registry.call("fn.subprocess_acquire", {}, { tool = "holder" })
  local cancelled = false
  local fns = {}
  local ctx = {
    on_cancel = function(fn) fns[#fns + 1] = fn end,
    cancelled = function() return cancelled end,
    await = function(begin)
      begin(function() end)
      return coroutine.yield()
    end,
  }
  local co = coroutine.create(function() registry.call("fn.subprocess_acquire", ctx, { tool = "waiter" }) end)
  assert(coroutine.resume(co))
  holder()
  assert(in_flight() == 1, "waiter should have been admitted, in_flight=" .. in_flight())
  cancelled = true
  for _, fn in ipairs(fns) do fn() end
  assert(in_flight() == 0, "the waiter's cancel handler must release a slot its coroutine will never see, in_flight=" .. in_flight())
end)

it("a parked waiter admitted after its run was cancelled declines the slot", function()
  define_limit(1)
  local holder = registry.call("fn.subprocess_acquire", {}, { tool = "holder" })
  local cancelled = false
  local resolved_with
  local ctx = {
    on_cancel = function() end,
    cancelled = function() return cancelled end,
    await = function(begin)
      begin(function(v) resolved_with = v end)
      return coroutine.yield()
    end,
  }
  local co = coroutine.create(function() registry.call("fn.subprocess_acquire", ctx, { tool = "waiter" }) end)
  assert(coroutine.resume(co))
  assert(#registry.subprocess_state().waiters == 1)
  cancelled = true
  holder()
  assert(resolved_with == false, "a cancelled waiter must be resolved false, got " .. tostring(resolved_with))
  assert(in_flight() == 0, "a cancelled waiter took a slot it can never release, in_flight=" .. in_flight())
end)

it("release from a fast-event callback defers admission to the main loop", function()
  define_limit(1)
  local a = start(bash_sleep("0.2", "A"))
  assert(wait_for(function() return in_flight() == 1 end, 2000))
  registry.define({ name = "fn.subprocess_limit", kind = "fn", doc = "test: records context",
    source = "return function() _G.__gate_fast = vim.in_fast_event(); return 1 end" })
  local b = start(bash_sleep("0", "B"))
  assert(wait_for(function() return a.done and b.done end))
  assert(_G.__gate_fast == false, "fn.subprocess_limit ran in a fast event (vim.api would raise): " .. tostring(_G.__gate_fast))
  _G.__gate_fast = nil
  assert(in_flight() == 0, "slots not released, in_flight=" .. in_flight())
end)

it("run_in_terminal releases the slot when the split cannot be opened", function()
  define_limit(4)
  local real_cmd = vim.cmd
  vim.cmd = setmetatable({}, { __call = function(_, s)
    if type(s) == "string" and s:find("15new", 1, true) then error("E36: Not enough room") end
    return real_cmd(s)
  end, __index = real_cmd })
  local h = start(function(ctx) return registry.call("tool.run_in_terminal", { command = "echo never" }, ctx) end)
  local ok_wait = wait_for(function() return h.done end, 3000)
  vim.cmd = real_cmd
  assert(ok_wait, "run_in_terminal hung")
  assert(h.err and tostring(h.err):find("could not open the terminal split", 1, true), "expected the split error, got " .. tostring(h.err) .. tostring(h.out))
  assert(in_flight() == 0, "failed split leaked a slot, in_flight=" .. in_flight())
end)

it("grep refuses a ctx without await before taking a slot", function()
  define_limit(4)
  local ok, err = pcall(registry.call, "tool.grep", { pattern = "x", path = root .. "/tests" })
  assert(not ok and tostring(err):find("requires a run ctx", 1, true), "expected the ctx error, got " .. tostring(err))
  assert(in_flight() == 0, "a refused direct call took a slot, in_flight=" .. in_flight())
end)

it("with fn.subprocess_acquire removed the tools run ungated", function()
  define_limit(1)
  local saved = registry.get("fn.subprocess_acquire")
  registry.remove("fn.subprocess_acquire")
  local a = start(bash_sleep("0.3", "A"))
  local b = start(bash_sleep("0.3", "B"))
  vim.wait(100, function() return false end, 10)
  assert(in_flight() == 0, "no fn, no counting")
  assert(wait_for(function() return a.done and b.done end))
  assert(a.out:find("A", 1, true) and b.out:find("B", 1, true))
  registry.define({ name = "fn.subprocess_acquire", kind = "fn", doc = saved.doc, source = saved.source })
end)
