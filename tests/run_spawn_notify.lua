-- tests/run_spawn_notify.lua — subagent completion notices. Run from anywhere:
--   nvim --headless -l tests/run_spawn_notify.lua
-- No network: fn.provider is scripted per case. Covers hook.on_run_end's
-- reason argument, fn.session_notify's two delivery paths (steering while a
-- run is active, an appended user block when idle), fn.spawn_notice's outcome
-- wording, every suppression rule of hook.on_run_end.notify_parent (claimed /
-- stopped / cancelled / non-subagent / config off), spawn_wait's claim and
-- steering-queue dedupe, and fn.autocmd_bridge still delivering through the
-- shared notify entry.

local script = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(vim.fn.fnamemodify(script, ":p"), ":h:h")
vim.opt.runtimepath:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local straps = require("straps").setup({})
straps.config.session_dir = vim.fn.tempname()
straps.config.stop_backstop_ms = 400

local registry = require("straps.registry")
local state = require("straps.state")
local loop = require("straps.loop")

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

local function define(name, kind, doc, source)
  registry.define({ name = name, kind = kind, doc = doc, source = source }, { scope = "global" })
end

define("hook.confirm", "hook", "test: allow everything", "return function() return true end")

local function text_of(bufnr)
  return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
end

local function wait_idle(bufnr, ms)
  assert(vim.wait(ms or 10000, function() return not loop.running(bufnr) end, 10),
    "run did not finish in time")
end

-- A session that is a child of `parent`, shaped exactly as tool.spawn shapes
-- one (parentage + one-line task), without going through spawn itself.
local function child_of(parent, task)
  local child = state.new_session()
  vim.b[child].straps_parent = parent
  vim.b[child].straps_task = task or "do the child thing"
  state.append_text(child, "go")
  return child
end

local function provider(src)
  define("fn.provider", "fn", "test provider", src)
end

-- Final text must be STREAMED via ctx.emit, exactly as the real SSE provider
-- does: the loop never copies a returned text block into the transcript, so a
-- provider that only returns one leaves an empty assistant block behind.
local ANSWER = [[
return function(req, ctx)
  ctx.await(function(resolve)
    vim.defer_fn(function() ctx.emit({ type = "text_delta", text = "CHILD-ANSWER" }); resolve(true) end, 5)
  end)
  return { content = { { type = "text", text = "CHILD-ANSWER" } }, stop_reason = "end_turn" }
end]]

-- ------------------------------------------------------------- the reason arg

case("hook.on_run_end receives the run's ending reason", function()
  _G.seen_reasons = {}
  define("hook.on_run_end.test_reason", "hook", "test: record reason", [[
return function(ctx, reason) table.insert(_G.seen_reasons, tostring(reason)) end
]])
  provider(ANSWER)
  local b = state.new_session()
  state.append_text(b, "go")
  loop.start(b)
  wait_idle(b)
  vim.wait(100)
  assert(#_G.seen_reasons == 1, "expected one run end, got " .. #_G.seen_reasons)
  assert(_G.seen_reasons[1] == "ok",
    "clean run should report reason 'ok', got " .. _G.seen_reasons[1])

  -- A run the loop ends with an error names it "error", not "ok".
  provider([[return function() error("provider boom") end]])
  local e = state.new_session()
  state.append_text(e, "go")
  loop.start(e)
  wait_idle(e)
  vim.wait(100)
  assert(_G.seen_reasons[2] == "error",
    "crashed run should report reason 'error', got " .. tostring(_G.seen_reasons[2]))
  define("hook.on_run_end.test_reason", "hook", "test: disabled", "return function() end")
end)

case("a raising subscriber still lets the run clean up, and is logged", function()
  local logfile = vim.fn.tempname()
  straps.config.log_file = logfile
  define("hook.on_run_end.test_boom", "hook", "test: raise", [[
return function(ctx, reason) error("subscriber boom") end
]])
  provider(ANSWER)
  local b = state.new_session()
  state.append_text(b, "go")
  loop.start(b)
  wait_idle(b)
  vim.wait(150)

  assert(not loop.running(b), "run should have ended")
  assert(vim.b[b].straps_status == "idle",
    "status must be stamped idle despite the raising subscriber, got "
      .. tostring(vim.b[b].straps_status))
  assert(text_of(b):match("%%%%%[straps:user%]%%%%%s*$"),
    "trailing user block must be restored despite the raising subscriber")

  local log = table.concat(vim.fn.readfile(logfile), "\n")
  local n = select(2, log:gsub("run_end_hook_error", ""))
  assert(n == 1, "expected exactly one run_end_hook_error event, got " .. n)
  assert(log:find("hook.on_run_end.test_boom", 1, true),
    "the error event should name the failing subscriber")

  define("hook.on_run_end.test_boom", "hook", "test: disabled", "return function() end")
  straps.config.log_file = nil
end)

-- ---------------------------------------------------------- fn.session_notify

case("fn.session_notify appends a user block to an idle session, without starting it", function()
  local s = state.new_session()
  state.append(s, "user", nil, "an earlier prompt")
  local out = registry.call("fn.session_notify", s, "[straps] hello idle")
  assert(out == "append", "idle session should take the append path, got " .. tostring(out))
  assert(vim.wait(2000, function() return text_of(s):find("hello idle", 1, true) ~= nil end, 20),
    "notice never landed in the idle session")
  assert(not loop.running(s), "delivering a notice must NOT start the session's run")
  -- The user still needs somewhere to type: a trailing empty user block.
  assert(text_of(s):match("%%%%%[straps:user%]%%%%%s*$"),
    "append path must restore the trailing user block:\n" .. text_of(s):sub(-200))
  -- And it parses as a user message the model will actually see.
  local parsed = state.parse(s)
  local last = parsed.messages[#parsed.messages]
  assert(last.role == "user", "notice must parse as a user message, got " .. last.role)
end)

case("fn.session_notify steers a running session instead of appending", function()
  -- The provider holds the run open across two turns, so the notice is queued
  -- mid-run and drains at the next turn boundary.
  provider([[
return function(req, ctx)
  _G.turns = (_G.turns or 0) + 1
  ctx.await(function(resolve) vim.defer_fn(function() resolve(true) end, 150) end)
  return { content = { { type = "text", text = "ANSWER" .. _G.turns } }, stop_reason = "end_turn" }
end]])
  _G.turns = 0
  local s = state.new_session()
  state.append_text(s, "go")
  loop.start(s)
  vim.wait(80)
  local out = registry.call("fn.session_notify", s, "[straps] hello running", { quiet = true })
  assert(out == "steer", "running session should take the steer path, got " .. tostring(out))
  wait_idle(s)
  vim.wait(150)
  local txt = text_of(s)
  assert(txt:find("hello running", 1, true), "steered notice never reached the transcript")
  -- Queued steering drains as its own user block, not glued into the
  -- assistant block the provider was streaming into.
  local parsed = state.parse(s)
  local in_user = false
  for _, m in ipairs(parsed.messages) do
    if m.role == "user" then
      for _, c in ipairs(m.content) do
        if type(c.text) == "string" and c.text:find("hello running", 1, true) then in_user = true end
      end
    end
  end
  assert(in_user, "the notice must arrive as user-role content")
end)

case("fn.session_notify's quiet flag controls the steering toast", function()
  -- A notice the user did not type must not toast at them; ordinary steering
  -- (the autocmd bridge, :StrapsSteer) still must.
  provider([[
return function(req, ctx)
  ctx.await(function(resolve) vim.defer_fn(function() resolve(true) end, 200) end)
  return { content = { { type = "text", text = "A" } }, stop_reason = "end_turn" }
end]])
  local real_notify = vim.notify
  local toasts = {}
  vim.notify = function(msg, ...) toasts[#toasts + 1] = tostring(msg); return real_notify(msg, ...) end
  local ok, err = pcall(function()
    local s = state.new_session()
    state.append_text(s, "go")
    loop.start(s)
    vim.wait(60)
    registry.call("fn.session_notify", s, "[straps] quiet one", { quiet = true })
    local quiet_toasts = 0
    for _, m in ipairs(toasts) do
      if m:find("steering queued", 1, true) then quiet_toasts = quiet_toasts + 1 end
    end
    assert(quiet_toasts == 0, "quiet = true must not toast; got " .. quiet_toasts)

    registry.call("fn.session_notify", s, "[straps] loud one")
    local loud_toasts = 0
    for _, m in ipairs(toasts) do
      if m:find("steering queued", 1, true) then loud_toasts = loud_toasts + 1 end
    end
    assert(loud_toasts == 1, "without quiet the toast must fire; got " .. loud_toasts)
    wait_idle(s)
  end)
  vim.notify = real_notify
  assert(ok, tostring(err))
end)

case("fn.session_notify refuses an invalid buffer and empty text", function()
  local dead = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_delete(dead, { force = true })
  assert(registry.call("fn.session_notify", dead, "x") == nil, "invalid buffer should return nil")
  local s = state.new_session()
  assert(registry.call("fn.session_notify", s, "") == nil, "empty text should return nil")
  assert(registry.call("fn.session_notify", nil, "x") == nil, "nil buffer should return nil")
end)

-- ------------------------------------------------------------ fn.spawn_notice

case("fn.spawn_notice words each outcome honestly and names the child", function()
  local child = state.new_session()
  vim.b[child].straps_task = "READ-THE-DOCS"
  local body = registry.call("fn.spawn_notice", child, "ok")
  assert(body:find("finished", 1, true), "ok should read 'finished': " .. body)
  assert(body:find("READ-THE-DOCS", 1, true), "the notice should carry the child's task")
  assert(body:find("spawn_wait{ buffers = { " .. child .. " } }", 1, true),
    "the notice should say how to collect this child: " .. body)

  assert(registry.call("fn.spawn_notice", child, "error"):find("crashed", 1, true),
    "error should read 'crashed'")
  local mt = registry.call("fn.spawn_notice", child, "max_turns")
  assert(mt:find("hit its turn limit", 1, true), "max_turns wording: " .. mt)
  assert(not mt:find("finished", 1, true), "a truncated child must NOT read as finished")
  for _, r in ipairs({ "stalled", "blank" }) do
    local b = registry.call("fn.spawn_notice", child, r)
    assert(b:find("stopped without producing an answer", 1, true), r .. " wording: " .. b)
    assert(not b:find("finished", 1, true), r .. " must not read as finished")
  end
end)

-- ------------------------------------------- notify_parent: the delivery path

case("a child finishing while the parent runs steers the notice into it", function()
  -- Parent holds its run open; the child answers during it.
  provider([[
return function(req, ctx)
  if vim.b[ctx.bufnr].straps_parent ~= nil then
    ctx.await(function(resolve)
      vim.defer_fn(function() ctx.emit({ type = "text_delta", text = "CHILD-ANSWER" }); resolve(true) end, 5)
    end)
    return { content = { { type = "text", text = "CHILD-ANSWER" } }, stop_reason = "end_turn" }
  end
  ctx.await(function(resolve) vim.defer_fn(function() resolve(true) end, 400) end)
  return { content = { { type = "text", text = "PARENT-ANSWER" } }, stop_reason = "end_turn" }
end]])
  local parent = state.new_session()
  state.append_text(parent, "go")
  loop.start(parent)
  local child = child_of(parent, "CHILD-TASK-A")
  loop.start(child)
  wait_idle(child)
  wait_idle(parent)
  vim.wait(200)
  local txt = text_of(parent)
  assert(txt:find("[straps] subagent buffer " .. child .. ":", 1, true),
    "the parent never heard about its child:\n" .. txt:sub(-300))
  assert(txt:find("CHILD-TASK-A", 1, true), "the notice should name the child's task")
  assert(not txt:find("CHILD-ANSWER", 1, true),
    "the notice must NOT carry the child's answer text (context isolation)")
end)

case("a child finishing while the parent is idle appends a user block", function()
  provider(ANSWER)
  local parent = state.new_session()
  state.append(parent, "user", nil, "earlier prompt")
  local child = child_of(parent, "CHILD-TASK-B")
  loop.start(child)
  wait_idle(child)
  assert(vim.wait(2000, function()
    return text_of(parent):find("subagent buffer " .. child, 1, true) ~= nil
  end, 20), "idle parent never received the notice")
  assert(not loop.running(parent), "a finishing child must NOT start the parent's run")
  assert(text_of(parent):match("%%%%%[straps:user%]%%%%%s*$"),
    "the parent must keep a trailing user block to type in")
end)

-- ------------------------------------------------- notify_parent: suppression

case("a child spawn_wait already claimed produces no notice", function()
  provider(ANSWER)
  local parent = state.new_session()
  state.append(parent, "user", nil, "earlier prompt")
  local child = child_of(parent, "CHILD-TASK-C")
  vim.b[child].straps_spawn_claimed = true
  loop.start(child)
  wait_idle(child)
  vim.wait(300)
  assert(not text_of(parent):find("subagent buffer " .. child, 1, true),
    "a claimed child must be reported by spawn_wait's result, not by a notice")
end)

case("a stopped child is silent even when its run ends with reason error", function()
  -- This is the path `reason` alone cannot see: the stop backstop force-resumes
  -- the coroutine, the provider raises on the nil resume, and the run ends
  -- "error" seconds after the stop. Reporting that as "crashed" would be a lie.
  provider([[
return function(req, ctx)
  local resp = ctx.await(function(resolve) end)
  return { content = resp.content, stop_reason = "end_turn" }
end]])
  local parent = state.new_session()
  state.append(parent, "user", nil, "earlier prompt")
  local child = child_of(parent, "CHILD-TASK-D")
  _G.stop_reason = nil
  define("hook.on_run_end.test_capture", "hook", "test: capture reason", [[
return function(ctx, reason)
  if vim.b[ctx.bufnr].straps_task == "CHILD-TASK-D" then _G.stop_reason = tostring(reason) end
end]])
  loop.start(child)
  vim.wait(150)
  loop.stop(child)
  wait_idle(child)
  vim.wait(300)
  assert(_G.stop_reason == "error",
    "this case must exercise the backstop error path; got reason " .. tostring(_G.stop_reason))
  assert(not text_of(parent):find("subagent buffer " .. child, 1, true),
    "a deliberately stopped child must not be reported as crashed")
  define("hook.on_run_end.test_capture", "hook", "test: disabled", "return function() end")
end)

case("an ordinary (non-subagent) run end notifies nobody and logs no error", function()
  -- An ordinary session has no straps_parent at all, and nvim_buf_is_valid(nil)
  -- raises — so a mis-ordered guard would log an error on every normal run.
  local logfile = vim.fn.tempname()
  straps.config.log_file = logfile
  provider(ANSWER)
  local b = state.new_session()
  state.append_text(b, "go")
  loop.start(b)
  wait_idle(b)
  vim.wait(150)
  local log = table.concat(vim.fn.readfile(logfile), "\n")
  assert(not log:find("run_end_hook_error", 1, true),
    "an ordinary run end must not raise inside the notify subscriber:\n" .. log)
  straps.config.log_file = nil
end)

case("config.spawn_notify = false silences the notice", function()
  provider(ANSWER)
  straps.config.spawn_notify = false
  local parent = state.new_session()
  state.append(parent, "user", nil, "earlier prompt")
  local child = child_of(parent, "CHILD-TASK-E")
  loop.start(child)
  wait_idle(child)
  vim.wait(300)
  straps.config.spawn_notify = true
  assert(not text_of(parent):find("subagent buffer " .. child, 1, true),
    "config.spawn_notify = false must suppress the notice")
end)

-- ------------------------------------------------ spawn_wait claim and dedupe

case("spawn_wait claims its children and drops their queued notices", function()
  -- The parent is mid-run with three notices queued: two for children it is
  -- about to collect, one for a child of another session. spawn_wait must drop
  -- only the first two, and claim only its own children.
  local parent = state.new_session()
  local mine_a = child_of(parent, "A")
  local mine_b = child_of(parent, "B")
  local stranger = state.new_session()
  vim.b[stranger].straps_parent = state.new_session() -- someone else's child

  local notice_a = ("[straps] subagent buffer %d: finished"):format(mine_a)
  local notice_b = ("[straps] subagent buffer %d: finished"):format(mine_b)
  local notice_s = ("[straps] subagent buffer %d: finished"):format(stranger)
  -- A notice whose buffer number EXTENDS a collected child's (child 7 vs 79):
  -- dropping it would mean the prefix match is not anchored on the ": ".
  local lookalike = ("[straps] subagent buffer %d: finished"):format(mine_a * 10 + 9)
  vim.b[parent].straps_steering =
    { notice_a, "a real user message", notice_s, notice_b, lookalike }

  local unpack = unpack or table.unpack
  local function pack(...) return { n = select("#", ...), ... } end
  local out, finished, co
  local ctx = {
    bufnr = parent,
    await = function(start)
      local resolved = false
      start(function(...)
        if resolved then return end
        resolved = true
        local a = pack(...)
        vim.schedule(function()
          if coroutine.status(co) == "suspended" then
            local ok, e = coroutine.resume(co, unpack(a, 1, a.n))
            if not ok then finished = true; error(e) end
          end
        end)
      end)
      return coroutine.yield()
    end,
  }
  co = coroutine.create(function()
    out = registry.call("tool.spawn_wait", { buffers = { mine_a, mine_b, stranger } }, ctx)
    finished = true
  end)
  local ok, err = coroutine.resume(co)
  assert(ok, tostring(err))
  assert(vim.wait(10000, function() return finished end, 20), "spawn_wait did not return")

  assert(vim.b[mine_a].straps_spawn_claimed == true, "own child A must be claimed")
  assert(vim.b[mine_b].straps_spawn_claimed == true, "own child B must be claimed")
  assert(vim.b[stranger].straps_spawn_claimed == nil,
    "another session's child must NEVER be claimed — that would silence a sibling's notice")

  local queue = vim.b[parent].straps_steering
  assert(type(queue) == "table", "the steering queue should survive as a table")
  local left = table.concat(queue, "\n")
  assert(not left:find(notice_a, 1, true), "notice for collected child A should be dropped")
  assert(not left:find(notice_b, 1, true), "notice for collected child B should be dropped")
  assert(left:find(notice_s, 1, true), "a stranger's notice must be left alone")
  assert(left:find(lookalike, 1, true),
    "child " .. mine_a .. "'s prefix must not swallow buffer " .. (mine_a * 10 + 9)
      .. " — the trailing ': ' is what anchors it")
  assert(left:find("a real user message", 1, true), "real steering must never be dropped")
  assert(out:find("subagent (buffer", 1, true), "spawn_wait should still return its report")
end)

case("the dedupe prefix cannot confuse child 1 with child 12", function()
  -- "buffer 1: " must not prefix-match "buffer 12: " — the trailing ": " is
  -- what makes that true, and the notice text contains [ ] so a pattern match
  -- would silently match nothing at all.
  local pre1 = ("[straps] subagent buffer %d: "):format(1)
  local m1 = pre1 .. "finished"
  local m12 = ("[straps] subagent buffer %d: "):format(12) .. "finished"
  assert(m1:sub(1, #pre1) == pre1, "the prefix must match its own notice")
  assert(m12:sub(1, #pre1) ~= pre1, "child 1's prefix must not match child 12's notice")
  assert(m1:find(pre1) == nil,
    "a pattern-mode find must NOT be used here (magic [ ]) — this asserts why")
  assert(m1:find(pre1, 1, true) == 1, "a plain find anchors at 1")
end)

case("spawn_wait survives a child buffer wiped during the wait", function()
  -- nvim_buf_get_name raises on a wiped buffer. Unguarded, one wiped child
  -- aborts the whole call and the live siblings' answers are lost with it.
  -- The wipe has to happen AFTER validation (a buffer already gone at that
  -- point just lands in `bad`), so it fires from inside the await.
  provider(ANSWER)
  local parent = state.new_session()
  local doomed = child_of(parent, "DOOMED")
  local alive = child_of(parent, "ALIVE")
  loop.start(alive)
  wait_idle(alive)

  local unpack = unpack or table.unpack
  local function pack(...) return { n = select("#", ...), ... } end
  local out, finished, co
  local first_await = true
  local ctx = {
    bufnr = parent,
    await = function(start)
      -- Validation is done by the time the first await runs; wipe the child
      -- here, so the collection loop meets an invalid handle.
      if first_await then
        first_await = false
        pcall(vim.api.nvim_buf_delete, doomed, { force = true })
      end
      local resolved = false
      start(function(...)
        if resolved then return end
        resolved = true
        local a = pack(...)
        vim.schedule(function()
          if coroutine.status(co) == "suspended" then
            local ok, e = coroutine.resume(co, unpack(a, 1, a.n))
            if not ok then finished = true; error(e) end
          end
        end)
      end)
      return coroutine.yield()
    end,
  }
  co = coroutine.create(function()
    out = registry.call("tool.spawn_wait", { buffers = { doomed, alive } }, ctx)
    finished = true
  end)
  local ok, err = coroutine.resume(co)
  assert(ok, tostring(err))
  assert(vim.wait(10000, function() return finished end, 20),
    "spawn_wait never returned after a child buffer was wiped")
  assert(not vim.api.nvim_buf_is_valid(doomed), "the doomed child should be wiped by now")
  assert(type(out) == "string" and out:find("CHILD-ANSWER", 1, true),
    "the live sibling's answer must survive a wiped child:\n" .. tostring(out))
end)

-- --------------------------------------------------------- the shared channel

case("fn.autocmd_bridge still delivers through fn.session_notify", function()
  local session = state.new_session()
  local prev = registry.set_active_scope(session)
  registry.define({
    name = "hook.bridge_notify_test",
    kind = "hook",
    doc = "test bridge hook",
    source = [[return function(args) return "BRIDGED-VIA-NOTIFY (" .. tostring(args.event) .. ")" end]],
  })
  registry.set_active_scope(prev)
  local id = registry.call("fn.autocmd_bridge", {
    event = "User",
    pattern = "StrapsNotifyBridgeTest",
    entry = "hook.bridge_notify_test",
    bufnr = session,
  })
  vim.api.nvim_exec_autocmds("User", { pattern = "StrapsNotifyBridgeTest" })
  assert(vim.wait(2000, function()
    return text_of(session):find("BRIDGED-VIA-NOTIFY (User)", 1, true) ~= nil
  end, 20), "the bridge no longer delivers after the refactor")
  vim.api.nvim_del_autocmd(id)
end)

print(failed and "FAILED" or "ALL PASS")
os.exit(failed and 1 or 0)
