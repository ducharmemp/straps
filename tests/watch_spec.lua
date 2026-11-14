-- tests/watch_spec.lua — tool.watch_agent / tool.unwatch_agent and fn.notify_watchers.
--   busted tests/watch_spec.lua
-- No network: fn.provider is scripted per case. Covers waking an idle watcher
-- on run_end, wake=false, one-shot watches, closed after :bdelete and
-- :bwipeout, no delivery for a cancelled run, a draft blocking the wake, the
-- gated-family rule, the wake cap and its reset by user activity, the
-- :StrapsStop pause, and a watch notice waking a watcher blocked in spawn_wait.

local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(vim.fn.fnamemodify(here, ":p"), ":h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local straps = require("straps").setup({})
straps.config.session_dir = vim.fn.tempname()
straps.config.stop_backstop_ms = 400

local registry = require("straps.registry")
local state = require("straps.state")
local loop = require("straps.loop")

local function define(name, kind, source)
  registry.define({ name = name, kind = kind, doc = "test", source = source }, { scope = "global" })
end

define("hook.confirm", "hook", "return function() return true end")

local function text_of(bufnr)
  return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
end

local function wait_idle(bufnr, ms)
  assert(vim.wait(ms or 10000, function() return not loop.running(bufnr) end, 10), "run did not finish in time")
end

local unpack = unpack or table.unpack
local function pack(...) return { n = select("#", ...), ... } end
local function drive(bufnr, thunk)
  local out, finished, co, err
  local ctx = {
    bufnr = bufnr,
    await = function(start)
      local resolved = false
      start(function(...)
        if resolved then return end
        resolved = true
        local a = pack(...)
        vim.schedule(function()
          if coroutine.status(co) == "suspended" then coroutine.resume(co, unpack(a, 1, a.n)) end
        end)
      end)
      return coroutine.yield()
    end,
  }
  co = coroutine.create(function()
    local ok, res = pcall(thunk, ctx)
    if ok then out = res else err = res end
    finished = true
  end)
  assert(coroutine.resume(co))
  vim.wait(10000, function() return finished end, 10)
  if err then error(err, 0) end
  return out
end

local function watch(watcher, input)
  return drive(watcher, function(ctx) return registry.call("tool.watch_agent", input, ctx) end)
end

-- Every session's run: "TARGET" sessions answer after a short delay; anything
-- else (a woken watcher) records that it ran and which watch notice it saw.
local function provider(target_ms)
  _G.woken = {}
  define("fn.provider", "fn", ([[
return function(req, ctx)
  local first = req.messages[1].content[1].text or ""
  local last = req.messages[#req.messages]
  local t = {}
  for _, p in ipairs(last.content) do if p.type == "text" then t[#t + 1] = p.text end end
  t = table.concat(t, "\n")
  if not first:find("TARGET", 1, true) then
    table.insert(_G.woken, { bufnr = ctx.bufnr, text = t })
  else
    ctx.await(function(r) vim.defer_fn(r, %d) end)
  end
  ctx.await(function(r) vim.defer_fn(function() ctx.emit({ type = "text_delta", text = "ok" }); r() end, 5) end)
  return { stop_reason = "end_turn", content = { { type = "text", text = "ok" } } }
end]]):format(target_ms or 50))
end

local function target_session()
  local b = state.new_session()
  state.append_text(b, "TARGET work")
  return b
end

local function run_target(b)
  loop.start(b)
  wait_idle(b)
  vim.wait(200)
end

local function woken_for(bufnr)
  local n, last = 0, nil
  for _, w in ipairs(_G.woken) do
    if w.bufnr == bufnr then n = n + 1; last = w.text end
  end
  return n, last
end

it("watch_agent and unwatch_agent are registered in the spawn category", function()
  for _, name in ipairs({ "watch_agent", "unwatch_agent" }) do
    assert(registry.get("tool." .. name), name .. " not registered")
    assert(registry.call("fn.capability", name, { to = "1" }) == "spawn", name .. " must share the spawn grant")
    assert(registry.call("fn.readonly_policy", name, { to = "1" }) == false, name .. " is not read-only")
  end
end)

it("an idle watcher is woken by the target's run_end and reads the notice", function()
  provider()
  local target = target_session()
  local watcher = state.new_session()
  local out = watch(watcher, { to = tostring(target) })
  assert(out:find("watching", 1, true), out)
  run_target(target)
  wait_idle(watcher)
  local n, text = woken_for(watcher)
  assert(n == 1, "watcher should have run once, ran " .. n)
  assert(text and text:find("[straps] watched agent", 1, true) and text:find("run_end (ok)", 1, true),
    "the woken run's request should carry the notice: " .. tostring(text))
  assert(vim.b[watcher].straps_watch_wakes == 1, "one wake counted")
end)

it("a watch fires once", function()
  provider()
  local target = target_session()
  local watcher = state.new_session()
  watch(watcher, { to = tostring(target) })
  run_target(target)
  wait_idle(watcher)
  assert(vim.b[target].straps_watchers == nil, "the fired watch must be removed")
  state.append_text(target, "TARGET again")
  run_target(target)
  wait_idle(watcher)
  assert(woken_for(watcher) == 1, "a second run_end must not reach a one-shot watch")
end)

it("wake=false appends the notice without starting the watcher", function()
  provider()
  local target = target_session()
  local watcher = state.new_session()
  watch(watcher, { to = tostring(target), wake = false })
  run_target(target)
  assert(not loop.running(watcher), "wake=false must not start the watcher")
  assert(woken_for(watcher) == 0)
  assert(text_of(watcher):find("[straps] watched agent", 1, true), "the notice should be appended")
end)

it("run_start is delivered when watched", function()
  provider()
  local target = target_session()
  local watcher = state.new_session()
  watch(watcher, { to = tostring(target), events = { "run_start" }, wake = false })
  run_target(target)
  assert(text_of(watcher):find("): run_start.", 1, true), "run_start notice missing:\n" .. text_of(watcher))
end)

it("a cancelled run notifies nobody and leaves the watch armed", function()
  provider(3000)
  local target = target_session()
  local watcher = state.new_session()
  watch(watcher, { to = tostring(target), wake = false })
  loop.start(target)
  vim.wait(100)
  loop.stop(target)
  wait_idle(target)
  vim.wait(200)
  assert(not text_of(watcher):find("[straps] watched agent", 1, true), "a stopped run must not notify")
  assert(type(vim.b[target].straps_watchers) == "table", "the watch stays armed")
end)

it("closed fires once across :bdelete then :bwipeout", function()
  provider()
  local target = target_session()
  local watcher = state.new_session()
  watch(watcher, { to = tostring(target), wake = false })
  vim.cmd("bdelete! " .. target)
  vim.wait(200)
  vim.cmd("bwipeout! " .. target)
  vim.wait(200)
  local _, count = text_of(watcher):gsub("%): closed%.", "")
  assert(count == 1, "closed should be delivered exactly once, got " .. count)
end)

it("closed fires on a plain :bwipeout", function()
  provider()
  local target = target_session()
  local watcher = state.new_session()
  watch(watcher, { to = tostring(target), events = { "closed" }, wake = false })
  vim.cmd("bwipeout! " .. target)
  vim.wait(200)
  assert(text_of(watcher):find("): closed.", 1, true), "closed notice missing")
end)

it("unsent text in the watcher's prompt blocks the wake", function()
  provider()
  local target = target_session()
  local watcher = state.new_session()
  state.append_text(watcher, "half-typed draft")
  watch(watcher, { to = tostring(target) })
  run_target(target)
  assert(not loop.running(watcher) and woken_for(watcher) == 0, "a draft must never be sent by a wake")
  assert(text_of(watcher):find("half-typed draft", 1, true), "the draft must survive")
  assert(text_of(watcher):find("[straps] watched agent", 1, true), "the notice should still be appended")
end)

it("the wake cap stops wakes until the user sends again", function()
  provider()
  local prev = straps.config.watch_wake_limit
  straps.config.watch_wake_limit = 1
  local target = target_session()
  local watcher = state.new_session()
  watch(watcher, { to = tostring(target) })
  run_target(target)
  wait_idle(watcher)
  assert(woken_for(watcher) == 1, "first wake under the cap")
  watch(watcher, { to = tostring(target) })
  state.append_text(target, "TARGET again")
  run_target(target)
  assert(woken_for(watcher) == 1, "second wake must be refused at the cap")
  assert(not loop.running(watcher))
  loop.note_user_activity(watcher)
  assert(vim.b[watcher].straps_watch_wakes == 0, "user activity resets the count")
  watch(watcher, { to = tostring(target) })
  state.append_text(target, "TARGET third")
  run_target(target)
  wait_idle(watcher)
  straps.config.watch_wake_limit = prev
  assert(woken_for(watcher) == 2, "a wake is allowed again after user activity")
end)

it("a user start resets the wake count", function()
  local b = state.new_session()
  vim.b[b].straps_watch_wakes = 5
  vim.b[b].straps_watch_paused = true
  provider()
  state.append_text(b, "TARGET user typed")
  loop.start(b)
  wait_idle(b)
  assert(vim.b[b].straps_watch_wakes == 0 and vim.b[b].straps_watch_paused == nil, "user start re-arms wakes")
end)

it("a session the user stopped is not woken until the user sends to it", function()
  provider(3000)
  local stopped = state.new_session()
  state.append_text(stopped, "TARGET long")
  loop.start(stopped)
  vim.wait(100)
  loop.user_stop(stopped)
  wait_idle(stopped)
  assert(vim.b[stopped].straps_watch_paused == true, "user_stop pauses watch wakes")
  -- A fresh watcher with an empty prompt and the pause set: only the pause can
  -- refuse the wake (a stopped run's cancel note would block it as a draft).
  provider()
  local watcher = state.new_session()
  vim.b[watcher].straps_watch_paused = true
  local target = target_session()
  watch(watcher, { to = tostring(target) })
  run_target(target)
  assert(woken_for(watcher) == 0 and not loop.running(watcher), "a user-stopped session must not be woken")
  assert(text_of(watcher):find("[straps] watched agent", 1, true), "the notice should still be appended")
end)

it("a wake keeps steering a stopped run left in the queue", function()
  provider()
  local target = target_session()
  local watcher = state.new_session()
  vim.b[watcher].straps_steering = { { text = "LEFTOVER-STEER", source = "user" } }
  watch(watcher, { to = tostring(target) })
  run_target(target)
  wait_idle(watcher)
  assert(text_of(watcher):find("LEFTOVER-STEER", 1, true), "queued steering must not be overwritten by a wake")
  assert(text_of(watcher):find("[straps] watched agent", 1, true), "the watch notice is drained too")
end)

it("a child collected by spawn_wait notifies again when a later run ends", function()
  provider()
  local parent = state.new_session()
  local child = state.new_session()
  vim.b[child].straps_parent = parent
  vim.b[child].straps_task = "COLLECTED"
  state.append_text(child, "TARGET first")
  run_target(child)
  drive(parent, function(ctx) return registry.call("tool.spawn_wait", { buffers = { child } }, ctx) end)
  local prefix = ("[straps] subagent buffer %d: finished"):format(child)
  local function notices()
    local n, from = 0, 1
    while true do
      local s = text_of(parent):find(prefix, from, true)
      if not s then return n end
      n, from = n + 1, s + 1
    end
  end
  local before = notices()
  state.append_text(child, "TARGET second")
  run_target(child)
  assert(notices() == before + 1,
    "the second run's completion notice must reach the parent:\n" .. text_of(parent):sub(-400))
end)

it("validates its target", function()
  local me = state.new_session()
  local function fails(input, pat)
    local ok, err = pcall(watch, me, input)
    assert(not ok and tostring(err):find(pat, 1, true), ("expected %q, got %s"):format(pat, tostring(err)))
  end
  fails({ to = tostring(me) }, "this session")
  fails({ to = "999999" }, "not a straps session")
  fails({ to = "parent" }, "no parent")
  fails({ to = "x1" }, "buffer number")
  fails({ to = tostring(state.new_session()), events = { "exploded" } }, "unknown event")
  fails({ to = tostring(state.new_session()), events = {} }, "non-empty")
end)

it("unwatch_agent removes the watch", function()
  provider()
  local target = target_session()
  local watcher = state.new_session()
  watch(watcher, { to = tostring(target), wake = false })
  local out = drive(watcher, function(ctx) return registry.call("tool.unwatch_agent", { to = tostring(target) }, ctx) end)
  assert(out:find("stopped watching", 1, true), out)
  assert(vim.b[target].straps_watchers == nil, "the last watch removed leaves no table")
  run_target(target)
  assert(not text_of(watcher):find("[straps] watched agent", 1, true), "an unwatched target must not notify")
end)

it("a gated child may watch its parent but not a stranger", function()
  local stranger = state.new_session()
  define("fn.provider", "fn", ([[
return function(req, ctx)
  local n = #req.messages
  if n == 1 then
    return { stop_reason = "tool_use", content = {
      { type = "tool_use", id = "w1", name = "watch_agent", input = { to = "parent", wake = false } },
      { type = "tool_use", id = "w2", name = "watch_agent", input = { to = "%d", wake = false } } } }
  end
  ctx.await(function(r) vim.defer_fn(function() ctx.emit({ type = "text_delta", text = "gated-done" }); r() end, 5) end)
  return { stop_reason = "end_turn", content = { { type = "text", text = "gated-done" } } }
end]]):format(stranger))
  local parent = state.new_session()
  local out = drive(parent, function(ctx)
    local started = registry.call("tool.spawn", { task = "GATED-WATCH", readonly = true }, ctx)
    return registry.call("tool.spawn_wait", { buffers = { tonumber(started:match("buffer (%d+)")) } }, ctx)
  end)
  assert(out:find("gated-done", 1, true), out)
  local pw = vim.b[parent].straps_watchers
  assert(type(pw) == "table" and next(pw) ~= nil, "the gated child's watch on its parent should be stored")
  assert(vim.b[stranger].straps_watchers == nil, "a gated child must not watch a stranger")
end)

it("a gated child granted watch_agent by name still cannot watch outside its family", function()
  local stranger = state.new_session()
  define("fn.provider", "fn", ([[
return function(req, ctx)
  local n = #req.messages
  if n == 1 then
    return { stop_reason = "tool_use", content = {
      { type = "tool_use", id = "w2", name = "watch_agent", input = { to = "%d", wake = false } } } }
  end
  ctx.await(function(r) vim.defer_fn(function() ctx.emit({ type = "text_delta", text = "gated-done" }); r() end, 5) end)
  return { stop_reason = "end_turn", content = { { type = "text", text = "gated-done" } } }
end]]):format(stranger))
  local parent = state.new_session()
  local child
  drive(parent, function(ctx)
    local started = registry.call("tool.spawn", { task = "GATED-WATCH-2", allow = { "watch_agent" } }, ctx)
    child = tonumber(started:match("buffer (%d+)"))
    return registry.call("tool.spawn_wait", { buffers = { child } }, ctx)
  end)
  assert(vim.b[stranger].straps_watchers == nil, "a name grant must not reach a stranger")
  assert(text_of(child):find("may watch only its parent or its own children", 1, true),
    "the tool body should refuse the out-of-family target")
end)

it("a watch notice wakes a watcher blocked in spawn_wait", function()
  _G.wait_result = nil
  define("fn.provider", "fn", [[
return function(req, ctx)
  local first = req.messages[1].content[1].text or ""
  if first:find("SLOW-CHILD", 1, true) then
    ctx.await(function(r) vim.defer_fn(r, 3000) end)
  elseif first:find("TARGET", 1, true) then
    ctx.await(function(r) vim.defer_fn(r, 50) end)
  else
    local n = #req.messages
    if n == 1 then
      return { stop_reason = "tool_use", content = {
        { type = "tool_use", id = "s", name = "spawn", input = { task = "SLOW-CHILD" } } } }
    elseif n == 3 then
      local h = tonumber(req.messages[3].content[1].content:match("buffer (%d+)"))
      return { stop_reason = "tool_use", content = {
        { type = "tool_use", id = "w", name = "spawn_wait", input = { buffers = { h } } } } }
    elseif n == 5 then
      _G.wait_result = req.messages[5].content[1].content
      local t = {}
      for _, p in ipairs(req.messages[5].content) do if p.type == "text" then t[#t + 1] = p.text end end
      _G.wait_notice = table.concat(t, "\n")
    end
  end
  ctx.await(function(r) vim.defer_fn(function() ctx.emit({ type = "text_delta", text = "ok" }); r() end, 5) end)
  return { stop_reason = "end_turn", content = { { type = "text", text = "ok" } } }
end]])
  local target = target_session()
  local watcher = state.new_session()
  watch(watcher, { to = tostring(target) })
  state.append_text(watcher, "spawn and wait")
  _G.in_wait = false
  define("hook.before_tool", "hook", [[
return function(name) if name == "spawn_wait" then _G.in_wait = true end end]])
  local ok, err = pcall(function()
    loop.start(watcher)
    assert(vim.wait(8000, function() return _G.in_wait end, 10), "watcher never reached spawn_wait")
    loop.start(target)
    assert(vim.wait(2500, function() return _G.wait_result ~= nil end, 10),
      "the watch notice should end the wait before the child finishes")
  end)
  define("hook.before_tool", "hook", "return function() end")
  assert(ok, tostring(err))
  assert(_G.wait_result:find("still running", 1, true), _G.wait_result)
  assert(_G.wait_notice:find("[straps] watched agent", 1, true), "the notice follows the result: " .. _G.wait_notice)
  wait_idle(watcher, 15000)
end)
