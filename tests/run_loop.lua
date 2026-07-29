-- tests/run_loop.lua — agent loop tests. Run from anywhere:
--   nvim --headless -l tests/run_loop.lua
-- No network: fn.provider is redefined with scripted stubs (this late-binding
-- redefinition IS the architecture under test). Plain asserts; exits 0/1.

local script = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(vim.fn.fnamemodify(script, ":p"), ":h:h")
vim.opt.runtimepath:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local registry = require("straps.registry")
local state = require("straps.state")
local loop = require("straps.loop")
-- Registers fn.provider/fn.api_key/fn.build_tools/fn.system_prompt and, as a
-- side effect, syntax-checks + compiles every embedded provider source.
require("straps.provider").register()
-- Hermetic: durable sessions write under a throwaway dir, never the real data dir.
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

local function last_marker(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for i = #lines, 1, -1 do
    if lines[i]:find("%%[straps:", 1, true) == 1 then
      return lines[i]
    end
  end
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

case("provider entries registered and compiled", function()
  for _, name in ipairs({ "fn.provider", "fn.api_key", "fn.build_tools", "fn.system_prompt" }) do
    local e = registry.get(name)
    assert(e, name .. " not registered")
    assert(type(e.fn) == "function", name .. " did not compile to a function")
  end
  assert(registry.call("fn.system_prompt"):find("registry_define", 1, true),
    "system prompt does not teach self-extension")
end)

case("tool loop with mid-run tool.ping redefinition", function()
  define("tool.ping", "tool", "ping v1", [[return function() return "pong-1" end]])
  _G.straps_test_calls = 0
  -- 3-turn script: ping, then (redefine tool.ping!) ping again, then text.
  -- Emits happen before resolve, like the real provider's stdout callbacks.
  define("fn.provider", "fn", "test: scripted 3-turn provider", [==[
return function(req, ctx)
  _G.straps_test_calls = _G.straps_test_calls + 1
  local n = _G.straps_test_calls
  ctx.await(function(resolve)
    vim.defer_fn(function()
      if n == 3 then ctx.emit({ type = "text_delta", text = "done" }) end
      resolve()
    end, 5)
  end)
  if n == 1 then
    return { stop_reason = "tool_use", content = {
      { type = "tool_use", id = "t1", name = "ping", input = vim.empty_dict() },
    } }
  elseif n == 2 then
    -- mid-run redefinition: the run's next tool.ping call must pick this up
    require("straps.registry").define({
      name = "tool.ping", kind = "tool", doc = "ping v2",
      source = [[return function() return "pong-2" end]],
    })
    return { stop_reason = "tool_use", content = {
      { type = "tool_use", id = "t2", name = "ping", input = vim.empty_dict() },
    } }
  end
  return { stop_reason = "end_turn", content = { { type = "text", text = "done" } } }
end
]==])

  local bufnr = new_session_with_prompt("please ping twice")
  loop.start(bufnr)
  wait_done(bufnr)

  local text = buf_text(bufnr)
  assert(_G.straps_test_calls == 3, "provider called " .. _G.straps_test_calls .. " times, want 3")
  assert(text:find("pong-1", 1, true), "missing result of tool.ping v1")
  assert(text:find("pong-2", 1, true), "mid-run redefinition of tool.ping not picked up")
  assert(text:find("done", 1, true), "missing streamed final assistant text")

  -- transcript round-trips: tool_use/tool_result blocks parse with ids intact
  local flat = vim.json.encode(state.parse(bufnr).messages)
  assert(flat:find("t1", 1, true) and flat:find("t2", 1, true), "tool ids lost in parse")
  assert(flat:find("tool_result", 1, true), "parsed messages missing tool_result")

  -- run ended cleanly: flag cleared, fresh prompt area appended
  assert(not loop.running(bufnr), "running flag not cleared")
  assert(last_marker(bufnr):find("user", 1, true), "no trailing user block after run")
end)

case("a batched tool response replays as ONE assistant message with all tool_use blocks", function()
  allow_all()
  define("tool.ping", "tool", "ping",
    [[return function(input) return "pong-" .. (input.tag or "?") end]])
  _G.straps_test_calls = 0
  _G.straps_test_reqs = {}
  define("fn.provider", "fn", "test: two tool_use blocks in one response", [==[
return function(req, ctx)
  _G.straps_test_calls = _G.straps_test_calls + 1
  local n = _G.straps_test_calls
  _G.straps_test_reqs[n] = req
  ctx.await(function(resolve) vim.defer_fn(resolve, 5) end)
  if n == 1 then
    return { stop_reason = "tool_use", content = {
      { type = "tool_use", id = "b1", name = "ping", input = { tag = "one" } },
      { type = "tool_use", id = "b2", name = "ping", input = { tag = "two" } },
    } }
  end
  return { stop_reason = "end_turn", content = { { type = "text", text = "done" } } }
end
]==])

  local bufnr = new_session_with_prompt("do two things at once")
  loop.start(bufnr)
  wait_done(bufnr)

  local text = buf_text(bufnr)
  assert(text:find("pong-one", 1, true) and text:find("pong-two", 1, true),
    "both batched tools should have run")

  -- Turn 2's request must carry the batch in API-native shape: one assistant
  -- message holding BOTH tool_use blocks, then one user message with both
  -- tool_results, order preserved — not two single-call turn pairs.
  local msgs = _G.straps_test_reqs[2].messages
  local a_idx
  for i, m in ipairs(msgs) do
    if m.role == "assistant" then
      local uses = {}
      for _, part in ipairs(m.content) do
        if part.type == "tool_use" then uses[#uses + 1] = part.id end
      end
      if #uses > 0 then
        assert(a_idx == nil, "tool_use blocks split across assistant messages")
        assert(#uses == 2, "assistant message has " .. #uses .. " tool_use blocks, want 2")
        assert(uses[1] == "b1" and uses[2] == "b2",
          "tool_use order lost: " .. table.concat(uses, ","))
        a_idx = i
      end
    end
  end
  assert(a_idx, "no assistant message with tool_use blocks")
  local results = {}
  for _, part in ipairs(msgs[a_idx + 1].content) do
    if part.type == "tool_result" then results[#results + 1] = part.tool_use_id end
  end
  assert(#results == 2 and results[1] == "b1" and results[2] == "b2",
    "tool_results not grouped in the following user message: " .. table.concat(results, ","))
end)

case("cancel mid-batch stubs results for unexecuted tool_use blocks", function()
  allow_all()
  define("tool.stopping", "tool", "stops the run when it executes", [==[
return function(input, ctx)
  require("straps.loop").stop(ctx.bufnr)
  return "ran-then-stopped"
end
]==])
  define("fn.provider", "fn", "test: a batch of two run-stopping tools", [==[
return function(req, ctx)
  ctx.await(function(resolve) vim.defer_fn(resolve, 5) end)
  return { stop_reason = "tool_use", content = {
    { type = "tool_use", id = "c1", name = "stopping", input = vim.empty_dict() },
    { type = "tool_use", id = "c2", name = "stopping", input = vim.empty_dict() },
  } }
end
]==])

  local bufnr = new_session_with_prompt("stop mid-batch")
  loop.start(bufnr)
  wait_done(bufnr)

  local text = buf_text(bufnr)
  assert(text:find("ran-then-stopped", 1, true), "first tool of the batch should have run")
  assert(text:find("run cancelled before this tool executed", 1, true),
    "unexecuted tool_use missing its stub result")
  assert(text:find("[straps: run cancelled]", 1, true), "missing cancellation note")

  -- Round-trip safety: every appended tool_use is paired with a result, so
  -- the next request cannot ship an unpaired tool_use block.
  local uses, results = 0, 0
  for _, m in ipairs(state.parse(bufnr).messages) do
    for _, part in ipairs(m.content) do
      if part.type == "tool_use" then uses = uses + 1 end
      if part.type == "tool_result" then results = results + 1 end
    end
  end
  assert(uses == 2 and results == 2,
    "unpaired tool blocks after cancel: " .. uses .. " uses, " .. results .. " results")
end)

case("confirm denial yields is_error tool_result and the run continues", function()
  define("tool.ping", "tool", "ping", [[return function() return "pong" end]])
  define("hook.confirm", "hook", "test: deny ping", [[
return function(name)
  if name == "ping" then return false, "nope" end
  return true
end
]])
  _G.straps_test_calls = 0
  define("fn.provider", "fn", "test: one denied tool then text", [==[
return function(req, ctx)
  _G.straps_test_calls = _G.straps_test_calls + 1
  local n = _G.straps_test_calls
  ctx.await(function(resolve)
    vim.defer_fn(function()
      if n == 2 then ctx.emit({ type = "text_delta", text = "after-deny" }) end
      resolve()
    end, 5)
  end)
  if n == 1 then
    return { stop_reason = "tool_use", content = {
      { type = "tool_use", id = "t1", name = "ping", input = vim.empty_dict() },
    } }
  end
  return { stop_reason = "end_turn", content = { { type = "text", text = "after-deny" } } }
end
]==])

  local bufnr = new_session_with_prompt("ping, but I will say no")
  loop.start(bufnr)
  wait_done(bufnr)

  local text = buf_text(bufnr)
  assert(text:find("user denied: nope", 1, true), "missing denial tool_result")
  assert(text:find('"is_error":true', 1, true), "denial not marked is_error")
  assert(not text:find("pong", 1, true), "denied tool ran anyway")
  assert(text:find("after-deny", 1, true), "run did not continue after denial")

  allow_all()
end)

case("provider error is appended as an assistant block and the run ends", function()
  define("fn.provider", "fn", "test: always errors",
    [[return function() error("provider exploded") end]])

  local bufnr = new_session_with_prompt("hi")
  loop.start(bufnr)
  wait_done(bufnr)

  local text = buf_text(bufnr)
  assert(text:find("provider exploded", 1, true), "error text not surfaced in transcript")
  assert(not loop.running(bufnr), "running flag not cleared after error")
  assert(last_marker(bufnr):find("user", 1, true), "no trailing user block after error")
end)

case("loop.stop mid-await cancels cleanly", function()
  _G.straps_test_started = false
  define("fn.provider", "fn", "test: hangs until cancelled", [==[
return function(req, ctx)
  _G.straps_test_started = true
  ctx.await(function(resolve)
    ctx.on_cancel(function() resolve("killed") end)
    vim.defer_fn(function() resolve("timeout") end, 3000) -- double-resolve is a no-op
  end)
  if ctx.cancelled() then
    return { content = {}, stop_reason = "cancelled" }
  end
  return { stop_reason = "end_turn", content = { { type = "text", text = "should-not-appear" } } }
end
]==])

  local bufnr = new_session_with_prompt("hang")
  loop.start(bufnr)
  assert(_G.straps_test_started, "provider did not start")
  assert(loop.running(bufnr), "run should be active while awaiting")

  -- one run per buffer: a second start is refused, first run unaffected
  loop.start(bufnr)
  assert(loop.running(bufnr), "second start broke the active run")

  loop.stop(bufnr)
  assert(vim.wait(2000, function() return not loop.running(bufnr) end, 10),
    "stop did not end the run")

  local text = buf_text(bufnr)
  assert(text:find("cancelled", 1, true), "missing cancellation note")
  assert(not text:find("should-not-appear", 1, true), "run continued past cancellation")
  assert(last_marker(bufnr):find("user", 1, true), "no trailing user block after cancel")

  -- the buffer is reusable: a fresh run works after a cancelled one. The
  -- cancellation note is an assistant block, so the user must type a new
  -- message first (a bare re-run fails the trailing-assistant guard).
  state.append_text(bufnr, "try again")
  define("fn.provider", "fn", "test: immediate text", [==[
return function(req, ctx)
  ctx.await(function(resolve)
    vim.defer_fn(function()
      ctx.emit({ type = "text_delta", text = "recovered" })
      resolve()
    end, 5)
  end)
  return { stop_reason = "end_turn", content = { { type = "text", text = "recovered" } } }
end
]==])
  loop.start(bufnr)
  wait_done(bufnr)
  assert(buf_text(bufnr):find("recovered", 1, true), "buffer not reusable after stop")
end)

case("empty conversation fails fast with a helpful message, no provider call", function()
  define("fn.provider", "fn", "test: must not be called", [==[
return function() error("provider should not be reached for an empty conversation") end
]==])
  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false,
    { "%%[straps:system]%%", "sys", "", "%%[straps:user]%%" })
  loop.start(bufnr)
  wait_done(bufnr)
  local text = buf_text(bufnr)
  assert(text:find("nothing to send", 1, true), "missing friendly empty-conversation error")
  assert(not text:find("should not be reached", 1, true), "provider was called")
end)

case("trailing assistant message fails fast with a helpful message, no provider call", function()
  define("fn.provider", "fn", "test: must not be called", [==[
return function() error("provider should not be reached for a trailing assistant message") end
]==])
  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false,
    { "%%[straps:system]%%", "sys", "", "%%[straps:user]%%", "hi", "",
      "%%[straps:assistant]%%", "prior answer", "", "%%[straps:user]%%" })
  loop.start(bufnr)
  wait_done(bufnr)
  local text = buf_text(bufnr)
  assert(text:find("ends with an assistant message", 1, true),
    "missing friendly trailing-assistant error")
  assert(not text:find("should not be reached", 1, true), "provider was called")
end)

case("stop_reason tool_use with no tool blocks errors, not a resend or user-blaming message", function()
  _G.straps_test_calls = 0
  define("fn.provider", "fn", "test: claims tool_use but requests no tools", [==[
return function(req, ctx)
  _G.straps_test_calls = _G.straps_test_calls + 1
  ctx.await(function(resolve)
    vim.defer_fn(function()
      ctx.emit({ type = "text_delta", text = "let me look" })
      resolve()
    end, 5)
  end)
  return { stop_reason = "tool_use", content = { { type = "text", text = "let me look" } } }
end
]==])
  local bufnr = new_session_with_prompt("go")
  loop.start(bufnr)
  wait_done(bufnr)
  assert(_G.straps_test_calls == 1,
    "provider called " .. _G.straps_test_calls .. " times, expected 1")
  local text = buf_text(bufnr)
  assert(text:find("requested no tools", 1, true), "missing malformed-turn error")
  assert(not text:find("type your request", 1, true),
    "mid-run failure misdiagnosed as an empty prompt")
end)

case("steering message is delivered on the next turn", function()
  allow_all()
  _G.straps_test_calls = 0
  _G.straps_test_reqs = {}
  -- Turn 1 streams text and returns end_turn, but steers BEFORE resolving —
  -- the drain at end-of-turn must trigger a second provider call.
  define("fn.provider", "fn", "test: steer while streaming the final answer", [==[
return function(req, ctx)
  _G.straps_test_calls = _G.straps_test_calls + 1
  local n = _G.straps_test_calls
  _G.straps_test_reqs[n] = req
  ctx.await(function(resolve)
    vim.defer_fn(function()
      if n == 1 then
        ctx.emit({ type = "text_delta", text = "first answer" })
        require("straps.loop").steer(_G.straps_test_bufnr, "also do X")
      else
        ctx.emit({ type = "text_delta", text = "second answer" })
      end
      resolve()
    end, 5)
  end)
  local text = n == 1 and "first answer" or "second answer"
  return { stop_reason = "end_turn", content = { { type = "text", text = text } } }
end
]==])

  local bufnr = new_session_with_prompt("do the thing")
  _G.straps_test_bufnr = bufnr
  loop.start(bufnr)
  wait_done(bufnr)

  assert(_G.straps_test_calls == 2,
    "provider called " .. _G.straps_test_calls .. " times, want 2")

  -- turn 2's request carries the steering text as an ordinary user message
  local found = false
  for _, msg in ipairs(_G.straps_test_reqs[2].messages) do
    if msg.role == "user" then
      for _, part in ipairs(msg.content) do
        if part.type == "text" and part.text == "also do X" then
          found = true
        end
      end
    end
  end
  assert(found, "turn 2 request missing the steering user message")

  -- transcript: a user block with the steering text, then turn 2's output
  local text = buf_text(bufnr)
  local upos = text:find("%%[straps:user]%%\nalso do X", 1, true)
  assert(upos, "transcript missing the steering user block")
  local spos = text:find("second answer", 1, true)
  assert(spos and spos > upos, "turn-2 assistant output not after the steering block")

  assert(loop.steer(bufnr, "too late") == false,
    "steer must return false once the run has finished")
end)

case("progress events fire in order with a final done", function()
  allow_all()
  define("tool.ping", "tool", "ping", [[return function() return "pong" end]])
  _G.straps_test_progress = {}
  -- Replaces any default ui hook: recording only, no extmark assertions here.
  define("hook.on_progress", "hook", "test: record event types", [[
return function(ev) _G.straps_test_progress[#_G.straps_test_progress + 1] = ev.type end
]])
  _G.straps_test_calls = 0
  define("fn.provider", "fn", "test: one tool turn then text", [==[
return function(req, ctx)
  _G.straps_test_calls = _G.straps_test_calls + 1
  local n = _G.straps_test_calls
  ctx.await(function(resolve)
    vim.defer_fn(function()
      if n == 2 then ctx.emit({ type = "text_delta", text = "done" }) end
      resolve()
    end, 5)
  end)
  if n == 1 then
    return { stop_reason = "tool_use", content = {
      { type = "tool_use", id = "t1", name = "ping", input = vim.empty_dict() },
    } }
  end
  return { stop_reason = "end_turn", content = { { type = "text", text = "done" } } }
end
]==])

  local bufnr = new_session_with_prompt("ping then finish")
  loop.start(bufnr)
  wait_done(bufnr)

  local seq = table.concat(_G.straps_test_progress, ",")
  assert(seq:find("start,thinking,tool,tool_done,thinking", 1, true),
    "unexpected progress sequence: " .. seq)
  assert(_G.straps_test_progress[#_G.straps_test_progress] == "done",
    "progress sequence does not end with done: " .. seq)
  local phase = vim.b[bufnr].straps_phase
  assert(phase == "" or phase == nil, "straps_phase not cleared: " .. tostring(phase))
end)

case("max_turns exhaustion is loud", function()
  allow_all()
  define("tool.ping", "tool", "ping", [[return function() return "pong" end]])
  local straps = require("straps") -- config works without setup(); loop reads it lazily
  local saved_max = straps.config.max_turns
  straps.config.max_turns = 3
  _G.straps_test_progress = {}
  define("hook.on_progress", "hook", "test: record full events", [[
return function(ev) _G.straps_test_progress[#_G.straps_test_progress + 1] = ev end
]])
  _G.straps_test_calls = 0
  define("fn.provider", "fn", "test: always requests ping", [==[
return function(req, ctx)
  _G.straps_test_calls = _G.straps_test_calls + 1
  local n = _G.straps_test_calls
  ctx.await(function(resolve) vim.defer_fn(resolve, 5) end)
  return { stop_reason = "tool_use", content = {
    { type = "tool_use", id = "t" .. n, name = "ping", input = vim.empty_dict() },
  } }
end
]==])

  local bufnr = new_session_with_prompt("ping forever")
  loop.start(bufnr)
  wait_done(bufnr)
  straps.config.max_turns = saved_max

  assert(_G.straps_test_calls == 3,
    "provider called " .. _G.straps_test_calls .. " times, want exactly max_turns=3")
  local text = buf_text(bufnr)
  assert(text:find("stopped after 3 turns", 1, true), "missing loud exhaustion note")
  assert(text:find("config.max_turns", 1, true), "note does not name config.max_turns")

  local done_ev
  for _, ev in ipairs(_G.straps_test_progress) do
    if ev.type == "done" then done_ev = ev end
  end
  assert(done_ev, "no done progress event")
  assert(done_ev.reason == "max_turns",
    "done reason is " .. tostring(done_ev.reason) .. ", want max_turns")
end)

case("stall detector stops an all-errors loop before max_turns", function()
  allow_all()
  -- A tool that always errors; every turn calls it, so every turn is stalled.
  define("tool.boom", "tool", "always errors",
    [[return function() error("kaboom", 0) end]])
  local straps = require("straps")
  local saved_max, saved_stall = straps.config.max_turns, straps.config.stall_limit
  straps.config.max_turns = 50
  straps.config.stall_limit = 3
  _G.straps_test_calls = 0
  define("fn.provider", "fn", "test: always requests boom", [==[
return function(req, ctx)
  _G.straps_test_calls = _G.straps_test_calls + 1
  local n = _G.straps_test_calls
  ctx.await(function(resolve) vim.defer_fn(resolve, 5) end)
  return { stop_reason = "tool_use", content = {
    { type = "tool_use", id = "b" .. n, name = "boom", input = { attempt = n } },
  } }
end
]==])

  local bufnr = new_session_with_prompt("keep failing")
  loop.start(bufnr)
  wait_done(bufnr)
  straps.config.max_turns, straps.config.stall_limit = saved_max, saved_stall

  assert(_G.straps_test_calls == 3,
    "provider called " .. _G.straps_test_calls .. " times, want stall_limit=3 (not max_turns=50)")
  local text = buf_text(bufnr)
  assert(text:find("no apparent progress", 1, true), "missing loud stall note")
  assert(text:find("config.stall_limit=3", 1, true), "note does not name config.stall_limit")
  assert(text:find("kaboom", 1, true), "note does not quote the last error")
end)

case("stall detector catches an exact-repeat loop", function()
  allow_all()
  define("tool.ping", "tool", "ping", [[return function() return "pong" end]])
  local straps = require("straps")
  local saved_max, saved_stall = straps.config.max_turns, straps.config.stall_limit
  straps.config.max_turns = 50
  straps.config.stall_limit = 3
  _G.straps_test_calls = 0
  -- Identical (tool,input) every turn: succeeds, but repeats -> stalled.
  define("fn.provider", "fn", "test: same ping input forever", [==[
return function(req, ctx)
  _G.straps_test_calls = _G.straps_test_calls + 1
  local n = _G.straps_test_calls
  ctx.await(function(resolve) vim.defer_fn(resolve, 5) end)
  return { stop_reason = "tool_use", content = {
    { type = "tool_use", id = "p" .. n, name = "ping", input = { q = "same" } },
  } }
end
]==])

  local bufnr = new_session_with_prompt("ping the same thing")
  loop.start(bufnr)
  wait_done(bufnr)
  straps.config.max_turns, straps.config.stall_limit = saved_max, saved_stall

  -- Turn 1 is novel (resets/keeps stall 0), turns 2/3/4 repeat -> stall hits 3.
  assert(_G.straps_test_calls == 4,
    "provider called " .. _G.straps_test_calls .. " times, want 4 (1 novel + 3 repeats)")
  local text = buf_text(bufnr)
  assert(text:find("no apparent progress", 1, true), "missing loud stall note")
  assert(text:find("repeated tool calls", 1, true), "repeat stall should note repetition, not an error")
end)

case("a repeat mixed with a new call is not a stall", function()
  allow_all()
  define("tool.ping", "tool", "ping", [[return function() return "pong" end]])
  local straps = require("straps")
  local saved_max, saved_stall = straps.config.max_turns, straps.config.stall_limit
  straps.config.max_turns = 50
  straps.config.stall_limit = 3
  _G.straps_test_calls = 0
  -- Every turn repeats the SAME ping (q="same") AND issues a fresh ping with a
  -- new input. Because each turn makes a never-seen call, it is productive, so
  -- the stall detector must NOT trip on the repeat alone. Ends at turn 6.
  define("fn.provider", "fn", "test: repeat + new every turn", [==[
return function(req, ctx)
  _G.straps_test_calls = _G.straps_test_calls + 1
  local n = _G.straps_test_calls
  ctx.await(function(resolve) vim.defer_fn(resolve, 5) end)
  if n >= 6 then
    return { stop_reason = "end_turn", content = { { type = "text", text = "stop" } } }
  end
  return { stop_reason = "tool_use", content = {
    { type = "tool_use", id = "same" .. n, name = "ping", input = { q = "same" } },
    { type = "tool_use", id = "new" .. n, name = "ping", input = { q = "fresh-" .. n } },
  } }
end
]==])

  local bufnr = new_session_with_prompt("repeat plus new")
  loop.start(bufnr)
  wait_done(bufnr)
  straps.config.max_turns, straps.config.stall_limit = saved_max, saved_stall

  assert(_G.straps_test_calls == 6,
    "provider called " .. _G.straps_test_calls .. " times, want 6 (never stalled — each turn had a new call)")
  local text = buf_text(bufnr)
  assert(not text:find("no apparent progress", 1, true),
    "stall note appeared even though every turn made a new distinct call")
end)

case("a productive turn resets the stall counter", function()
  allow_all()
  define("tool.ping", "tool", "ping", [[return function() return "pong" end]])
  define("tool.boom", "tool", "always errors", [[return function() error("boom", 0) end]])
  local straps = require("straps")
  local saved_max, saved_stall = straps.config.max_turns, straps.config.stall_limit
  straps.config.max_turns = 50
  straps.config.stall_limit = 3
  _G.straps_test_calls = 0
  -- Pattern: err, err, ok, err, err, ok, ... never 3 errors in a row, so the
  -- stall detector never trips; only max_turns/end_turn can stop it. End at 8.
  define("fn.provider", "fn", "test: never 3 stalls in a row", [==[
return function(req, ctx)
  _G.straps_test_calls = _G.straps_test_calls + 1
  local n = _G.straps_test_calls
  ctx.await(function(resolve) vim.defer_fn(resolve, 5) end)
  if n >= 8 then
    return { stop_reason = "end_turn", content = { { type = "text", text = "stop" } } }
  end
  local name = (n % 3 == 0) and "ping" or "boom" -- ok on every 3rd turn
  return { stop_reason = "tool_use", content = {
    { type = "tool_use", id = "x" .. n, name = name, input = { attempt = n } },
  } }
end
]==])

  local bufnr = new_session_with_prompt("mixed progress")
  loop.start(bufnr)
  wait_done(bufnr)
  straps.config.max_turns, straps.config.stall_limit = saved_max, saved_stall

  assert(_G.straps_test_calls == 8,
    "provider called " .. _G.straps_test_calls .. " times, want 8 (stall reset, ran to end_turn)")
  local text = buf_text(bufnr)
  assert(not text:find("no apparent progress", 1, true),
    "stall note appeared even though errors never ran 3 in a row")
end)

case("fn.log writes structured events", function()
  allow_all()
  define("tool.ping", "tool", "ping", [[return function() return "pong" end]])
  local straps = require("straps")
  local logfile = vim.fn.tempname()
  straps.config.log_file = logfile
  _G.straps_test_calls = 0
  define("fn.provider", "fn", "test: one ping turn then text", [==[
return function(req, ctx)
  _G.straps_test_calls = _G.straps_test_calls + 1
  local n = _G.straps_test_calls
  ctx.await(function(resolve) vim.defer_fn(resolve, 5) end)
  if n == 1 then
    return { stop_reason = "tool_use", content = {
      { type = "tool_use", id = "t1", name = "ping", input = vim.empty_dict() },
    } }
  end
  return { stop_reason = "end_turn", content = { { type = "text", text = "done" } } }
end
]==])

  local bufnr = new_session_with_prompt("ping then finish")
  loop.start(bufnr)
  wait_done(bufnr)
  straps.config.log_file = nil

  local lines = vim.fn.readfile(logfile)
  assert(#lines > 0, "log file is empty")
  local seen, run_end = {}, nil
  for _, line in ipairs(lines) do
    local ev = vim.json.decode(line) -- every line must be valid JSON
    assert(type(ev) == "table" and type(ev.ev) == "string", "malformed log line: " .. line)
    assert(ev.ts, "log line missing ts: " .. line)
    assert(ev.buf == bufnr, "log line missing/wrong buf: " .. line)
    seen[ev.ev] = true
    if ev.ev == "run_end" then run_end = ev end
  end
  -- The scripted stub replaces fn.provider, so no request/response events —
  -- only the loop-side events are expected here.
  for _, k in ipairs({ "run_start", "turn", "tool", "run_end" }) do
    assert(seen[k], "missing " .. k .. " event in log")
  end
  assert(run_end.reason == "ok", "run_end reason is " .. tostring(run_end.reason))
  assert(type(run_end.turns) == "number" and run_end.turns >= 2,
    "run_end turns is " .. tostring(run_end.turns) .. ", want >= 2")
end)

case("thinking event carries max", function()
  allow_all()
  local straps = require("straps")
  local saved_max = straps.config.max_turns
  straps.config.max_turns = 7
  _G.straps_test_progress = {}
  define("hook.on_progress", "hook", "test: record full events", [[
return function(ev) _G.straps_test_progress[#_G.straps_test_progress + 1] = ev end
]])
  define("fn.provider", "fn", "test: immediate end_turn", [==[
return function(req, ctx)
  ctx.await(function(resolve) vim.defer_fn(resolve, 5) end)
  return { stop_reason = "end_turn", content = { { type = "text", text = "hi" } } }
end
]==])

  local bufnr = new_session_with_prompt("hello")
  loop.start(bufnr)
  wait_done(bufnr)
  straps.config.max_turns = saved_max

  local found = false
  for _, ev in ipairs(_G.straps_test_progress) do
    if ev.type == "thinking" then
      found = true
      assert(ev.turn == 1, "thinking turn is " .. tostring(ev.turn) .. ", want 1")
      assert(ev.max == 7, "thinking max is " .. tostring(ev.max) .. ", want config.max_turns=7")
    end
  end
  assert(found, "no thinking progress event recorded")
end)

case("provider usage is accumulated onto vim.b.straps_usage", function()
  allow_all()
  define("fn.provider", "fn", "test: provider that reports token usage", [==[
return function(req, ctx)
  ctx.await(function(resolve)
    vim.defer_fn(function()
      ctx.emit({ type = "text_delta", text = "hi" })
      resolve()
    end, 5)
  end)
  return {
    stop_reason = "end_turn",
    content = { { type = "text", text = "hi" } },
    usage = {
      input_tokens = 12000,
      output_tokens = 200,
      cache_read_input_tokens = 8000,
      cache_creation_input_tokens = 1000,
    },
  }
end
]==])

  local bufnr = new_session_with_prompt("go")
  loop.start(bufnr)
  wait_done(bufnr)

  local u = vim.b[bufnr].straps_usage
  assert(type(u) == "table", "straps_usage not set on the session buffer")
  assert(u.input == 12000, "input wrong: " .. tostring(u.input))
  assert(u.cache_read == 8000, "cache_read wrong: " .. tostring(u.cache_read))
  -- input_billed = input + cache_read + cache_creation = 21000
  assert(u.input_billed == 21000, "input_billed wrong: " .. tostring(u.input_billed))
  assert(u.requests == 1, "requests wrong: " .. tostring(u.requests))
  assert(u.output_total == 200, "output_total wrong: " .. tostring(u.output_total))
end)

case("a blank turn after a tool call is nudged, then ends loudly if still blank", function()
  allow_all()
  define("tool.ping", "tool", "ping", [[return function() return "pong" end]])
  local straps = require("straps")
  local saved = straps.config.blank_nudge_limit
  straps.config.blank_nudge_limit = 1
  _G.straps_test_progress = {}
  define("hook.on_progress", "hook", "test: record events", [[
return function(ev) _G.straps_test_progress[#_G.straps_test_progress + 1] = ev end
]])
  -- Turn 1: run a tool. Turn 2 and beyond: end_turn with NO visible text —
  -- the "runs a command then returns silence" symptom. With blank_nudge_limit=1
  -- turn 2 nudges (transcript gains a user block), turn 3 stays blank -> loud
  -- "blank" ending. So the provider is called exactly 3 times.
  _G.straps_test_calls = 0
  define("fn.provider", "fn", "test: tool then silent end_turns", [==[
return function(req, ctx)
  _G.straps_test_calls = _G.straps_test_calls + 1
  local n = _G.straps_test_calls
  ctx.await(function(resolve) vim.defer_fn(resolve, 5) end)
  if n == 1 then
    return { stop_reason = "tool_use", content = {
      { type = "tool_use", id = "p1", name = "ping", input = vim.empty_dict() },
    } }
  end
  -- blank: end_turn, empty content (no text block at all)
  return { stop_reason = "end_turn", content = {} }
end
]==])

  local bufnr = new_session_with_prompt("do a thing")
  loop.start(bufnr)
  wait_done(bufnr)
  straps.config.blank_nudge_limit = saved

  assert(_G.straps_test_calls == 3,
    "provider called " .. _G.straps_test_calls .. " times, want 3 (tool, nudge, give up)")
  local text = buf_text(bufnr)
  assert(text:find("produced no text after the tool call", 1, true),
    "missing the nudge user block")
  assert(text:find("ending its turn silently", 1, true),
    "missing the loud blank ending note")

  local done_ev
  for _, ev in ipairs(_G.straps_test_progress) do
    if ev.type == "done" then done_ev = ev end
  end
  assert(done_ev and done_ev.reason == "blank",
    "done reason is " .. tostring(done_ev and done_ev.reason) .. ", want blank")
end)

case("a blank turn on max_tokens ends loudly with no nudge", function()
  allow_all()
  local straps = require("straps")
  _G.straps_test_progress = {}
  define("hook.on_progress", "hook", "test: record events", [[
return function(ev) _G.straps_test_progress[#_G.straps_test_progress + 1] = ev end
]])
  _G.straps_test_calls = 0
  define("fn.provider", "fn", "test: max_tokens with no text", [==[
return function(req, ctx)
  _G.straps_test_calls = _G.straps_test_calls + 1
  ctx.await(function(resolve) vim.defer_fn(resolve, 5) end)
  return { stop_reason = "max_tokens", content = {} }
end
]==])

  local bufnr = new_session_with_prompt("go")
  loop.start(bufnr)
  wait_done(bufnr)

  assert(_G.straps_test_calls == 1,
    "provider called " .. _G.straps_test_calls .. " times, want 1 (no nudge on max_tokens)")
  local text = buf_text(bufnr)
  assert(text:find("hit max_tokens", 1, true), "missing the max_tokens blank note")

  local done_ev
  for _, ev in ipairs(_G.straps_test_progress) do
    if ev.type == "done" then done_ev = ev end
  end
  assert(done_ev and done_ev.reason == "blank",
    "done reason is " .. tostring(done_ev and done_ev.reason) .. ", want blank")
end)

case("a normal end_turn WITH text is still a clean ok (no false blank)", function()
  allow_all()
  _G.straps_test_progress = {}
  define("hook.on_progress", "hook", "test: record events", [[
return function(ev) _G.straps_test_progress[#_G.straps_test_progress + 1] = ev end
]])
  define("fn.provider", "fn", "test: end_turn with visible text", [==[
return function(req, ctx)
  ctx.await(function(resolve)
    vim.defer_fn(function() ctx.emit({ type = "text_delta", text = "here is the answer" }) resolve() end, 5)
  end)
  return { stop_reason = "end_turn", content = { { type = "text", text = "here is the answer" } } }
end
]==])

  local bufnr = new_session_with_prompt("answer me")
  loop.start(bufnr)
  wait_done(bufnr)

  local text = buf_text(bufnr)
  assert(not text:find("produced no text", 1, true), "false blank nudge on a turn that had text")
  local done_ev
  for _, ev in ipairs(_G.straps_test_progress) do
    if ev.type == "done" then done_ev = ev end
  end
  assert(done_ev and done_ev.reason == "ok",
    "done reason is " .. tostring(done_ev and done_ev.reason) .. ", want ok")
end)

case("oversized tool result truncates on a UTF-8 char boundary", function()
  allow_all()
  local straps = require("straps")
  local saved = straps.config.max_tool_result_bytes
  -- "é" is 2 bytes (0xC3 0xA9). Cap at an odd byte so the naive cut would land
  -- between the two bytes of a character; the guard must back up to a boundary.
  straps.config.max_tool_result_bytes = 101
  define("tool.big", "tool", "returns many multibyte chars",
    [[return function() return string.rep("é", 200) end]])
  define("fn.provider", "fn", "test: call big once then stop", [==[
return function(req, ctx)
  _G.straps_test_calls = (_G.straps_test_calls or 0) + 1
  ctx.await(function(resolve) vim.defer_fn(resolve, 5) end)
  if _G.straps_test_calls == 1 then
    return { stop_reason = "tool_use", content = {
      { type = "tool_use", id = "b1", name = "big", input = {} } } }
  end
  return { stop_reason = "end_turn", content = { { type = "text", text = "done" } } }
end
]==])
  _G.straps_test_calls = 0
  local bufnr = new_session_with_prompt("big result")
  loop.start(bufnr)
  wait_done(bufnr)
  straps.config.max_tool_result_bytes = saved

  -- Find the tool_result content and assert it is valid UTF-8 (no split char).
  local parsed = state.parse(bufnr)
  local result
  for _, msg in ipairs(parsed.messages) do
    for _, part in ipairs(msg.content) do
      if part.type == "tool_result" then result = part.content end
    end
  end
  assert(result, "no tool_result found")
  assert(result:find("result truncated at 101 bytes", 1, true), "missing truncation note")
  local body = result:gsub("\n%[straps: result truncated.*$", "")
  assert(pcall(vim.str_utfindex, body), "truncated body is not valid UTF-8")
  -- The kept prefix must be whole 'é's: even byte count.
  assert(#body % 2 == 0, "cut landed mid-character (odd byte length): " .. #body)
end)

-- ------------------------------------------ continuing a stopped run
-- :StrapsContinue is "append a user block, loop.start the same buffer". The
-- buffer IS the run state, so a stopped run resumes with no restore step; what
-- these cases pin down is that the transcript loop.stop leaves behind is
-- actually sendable, and that the model sees the turns it already completed.
case("a stopped run continues from where it left off", function()
  allow_all()
  define("tool.slow", "tool", "test: a tool that takes a while", [[
return function(input, ctx)
  ctx.await(function(resolve) vim.defer_fn(resolve, 300) end)
  return "slow-done-" .. tostring(input.n)
end
]])
  -- Turns 1-2 call tool.slow, turn 3 answers. The counter is module-global, so
  -- the continued run advances the script instead of restarting it.
  _G.straps_test_calls = 0
  define("fn.provider", "fn", "test: two tool turns then an answer", [==[
return function(req, ctx)
  _G.straps_test_calls = _G.straps_test_calls + 1
  local n = _G.straps_test_calls
  _G.straps_test_messages = #req.messages
  -- Emit before resolve, like the real provider's stdout callbacks, so the
  -- delta lands in the assistant block instead of after the run's tail.
  ctx.await(function(resolve)
    vim.defer_fn(function()
      if n > 2 then ctx.emit({ type = "text_delta", text = "continued-answer" }) end
      resolve()
    end, 5)
  end)
  if n <= 2 then
    return { stop_reason = "tool_use", content = {
      { type = "tool_use", id = "s" .. n, name = "slow", input = { n = n } } } }
  end
  return { stop_reason = "end_turn", content = { { type = "text", text = "continued-answer" } } }
end
]==])

  local bufnr = new_session_with_prompt("do the multi-turn thing")
  loop.start(bufnr)
  -- Stop while turn 1's tool.slow is still in flight.
  assert(vim.wait(2000, function() return buf_text(bufnr):find("straps:tool_use", 1, true) ~= nil end, 10),
    "first tool_use never appeared")
  loop.stop(bufnr)
  wait_done(bufnr)
  local stopped = buf_text(bufnr)
  assert(stopped:find("[straps: run cancelled]", 1, true), "missing cancellation note")
  assert(not stopped:find("continued-answer", 1, true), "run should have stopped before the answer")
  local turns_at_stop = _G.straps_test_calls

  -- Sending as-is is exactly what :StrapsSend does, and it must fail: the
  -- transcript ends on the assistant-role cancellation note (no prefill). This
  -- is the whole reason :StrapsContinue has to append a user block.
  pcall(loop.start, bufnr)
  assert(vim.wait(2000, function() return not loop.running(bufnr) end, 10), "bare send did not settle")
  assert(buf_text(bufnr):find("transcript ends with an assistant message", 1, true),
    "sending a stopped transcript as-is should fail loudly")

  -- What :StrapsContinue does: append a user block, start the same buffer.
  -- Assertions below read only the text appended from here on, so the
  -- deliberate bare-send error above cannot satisfy or spoil them.
  local from = vim.api.nvim_buf_line_count(bufnr)
  state.append(bufnr, "user", nil, "[straps] Continue where you left off.")
  _G.straps_test_messages = nil -- so the assertion below reads THIS run's value
  loop.start(bufnr)
  wait_done(bufnr)

  local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, from, -1, false), "\n")
  assert(text:find("continued-answer", 1, true), "continued run did not reach the answer")
  assert(not text:find("run error", 1, true), "continued run hit an error: " .. text:sub(-400))
  assert(_G.straps_test_calls > turns_at_stop,
    "the continued run restarted the script instead of advancing it")
  -- The continued run replayed the pre-stop history, not just the new block.
  assert(type(_G.straps_test_messages) == "number", "the continued run made no provider call")
  assert(_G.straps_test_messages > 2,
    "continued run sent only " .. tostring(_G.straps_test_messages) .. " messages — history was lost")
end)

case("an interrupted transcript (tool_use, no result) is healed and continues", function()
  allow_all()
  -- Exactly the on-disk shape when Neovim dies mid-tool: persist() runs at
  -- block boundaries, so the tool_use is written and its result never is.
  local bufnr = state.new_session()
  state.append(bufnr, "user", nil, "run something slow")
  state.append(bufnr, "tool_use", { id = "k1", name = "slow" }, '{"n":1}')

  local before = state.parse(bufnr).messages
  assert(before[#before].role == "assistant", "precondition: interrupted tail is assistant-role")

  local healed = state.heal_interrupted(bufnr)
  assert(healed == 1, "expected 1 healed tool call, got " .. tostring(healed))
  local uses, results = 0, 0
  for _, m in ipairs(state.parse(bufnr).messages) do
    for _, part in ipairs(m.content) do
      if part.type == "tool_use" then uses = uses + 1 end
      if part.type == "tool_result" then results = results + 1 end
    end
  end
  assert(uses == 1 and results == 1, "heal left unpaired blocks: " .. uses .. "/" .. results)
  assert(buf_text(bufnr):find("run interrupted before this tool finished", 1, true),
    "healed result should say why it is an error")
  -- is_error is what tells the model the call did not complete: without it the
  -- model reads "run interrupted..." as the tool's successful output.
  local healed_error
  for _, m in ipairs(state.parse(bufnr).messages) do
    for _, part in ipairs(m.content) do
      if part.type == "tool_result" then healed_error = part.is_error end
    end
  end
  assert(healed_error == true, "healed result must be flagged is_error, got " .. tostring(healed_error))
  -- The tail is typeable again (heal restores the trailing user block).
  assert(last_marker(bufnr):find("straps:user", 1, true), "heal did not restore a trailing user block")
  assert(state.heal_interrupted(bufnr) == 0, "heal must be idempotent")

  -- And the healed transcript actually sends.
  define("fn.provider", "fn", "test: answer, rejecting unpaired tool_use like the API", [==[
return function(req, ctx)
  ctx.await(function(resolve) vim.defer_fn(resolve, 5) end)
  for i, m in ipairs(req.messages) do
    if m.role == "assistant" then
      for _, p in ipairs(m.content) do
        if p.type == "tool_use" then
          local nxt, paired = req.messages[i + 1], false
          if nxt and nxt.role == "user" then
            for _, q in ipairs(nxt.content) do
              if q.type == "tool_result" and q.tool_use_id == p.id then paired = true end
            end
          end
          if not paired then error("simulated API 400: unpaired tool_use " .. tostring(p.id)) end
        end
      end
    end
  end
  ctx.emit({ type = "text_delta", text = "healed-answer" })
  return { stop_reason = "end_turn", content = { { type = "text", text = "healed-answer" } } }
end
]==])
  state.append(bufnr, "user", nil, "[straps] Continue where you left off.")
  loop.start(bufnr)
  wait_done(bufnr)
  local text = buf_text(bufnr)
  assert(text:find("healed-answer", 1, true), "healed transcript did not send cleanly: " .. text:sub(-400))
  assert(not text:find("run error", 1, true), "healed transcript still errored: " .. text:sub(-400))
end)

case("heal pairs only the unfinished calls of an interrupted batch", function()
  -- A parallel batch interrupted partway: the first call's result persisted, the
  -- second never did, and the tail is tool blocks only (no trailing user block
  -- to end the scan early) — so this is what actually exercises the per-id
  -- pairing bookkeeping rather than the trailing-block guard.
  local bufnr = state.new_session()
  state.append(bufnr, "user", nil, "read two files")
  state.append(bufnr, "tool_use", { id = "p1", name = "read_file" }, '{"path":"a"}')
  state.append(bufnr, "tool_use", { id = "p2", name = "read_file" }, '{"path":"b"}')
  state.append(bufnr, "tool_result", { id = "p1", is_error = false }, "contents of a")

  local function results_by_id(b)
    local per_id = {}
    for _, m in ipairs(state.parse(b).messages) do
      for _, part in ipairs(m.content) do
        if part.type == "tool_result" then
          per_id[part.tool_use_id] = (per_id[part.tool_use_id] or 0) + 1
        end
      end
    end
    return per_id
  end

  assert(state.heal_interrupted(bufnr) == 1, "expected exactly the unpaired call to be healed")
  local per_id = results_by_id(bufnr)
  assert(per_id.p1 == 1, "already-finished call got " .. tostring(per_id.p1) .. " results")
  assert(per_id.p2 == 1, "interrupted call got " .. tostring(per_id.p2) .. " results")
  assert(state.heal_interrupted(bufnr) == 0, "heal must be idempotent on a healed batch")
  per_id = results_by_id(bufnr)
  assert(per_id.p1 == 1 and per_id.p2 == 1, "second heal duplicated results")

  -- Same batch with the results in the other order: the orphan comes FIRST and
  -- an already-answered call follows it. Heal is per-id, not positional, so it
  -- must still add exactly one result and never duplicate the existing one.
  local rev = state.new_session()
  state.append(rev, "user", nil, "read two files")
  state.append(rev, "tool_use", { id = "r1", name = "read_file" }, '{"path":"a"}')
  state.append(rev, "tool_use", { id = "r2", name = "read_file" }, '{"path":"b"}')
  state.append(rev, "tool_result", { id = "r2", is_error = false }, "contents of b")
  assert(state.heal_interrupted(rev) == 1, "expected one healed call in the reversed batch")
  local rev_ids = results_by_id(rev)
  assert(rev_ids.r1 == 1, "orphan-first: r1 got " .. tostring(rev_ids.r1) .. " results")
  assert(rev_ids.r2 == 1, "orphan-first: answered r2 got " .. tostring(rev_ids.r2) .. " results")

  -- A batch interrupted before ANY result landed: the return value is the count
  -- resume_session reports to the user, so it must track the work done, not just
  -- be nonzero. Also pins the trailing-user restore for the batch shape.
  local both = state.new_session()
  state.append(both, "user", nil, "read two files")
  state.append(both, "tool_use", { id = "b1", name = "read_file" }, '{"path":"a"}')
  state.append(both, "tool_use", { id = "b2", name = "read_file" }, '{"path":"b"}')
  assert(state.heal_interrupted(both) == 2, "both unfinished calls should be healed")
  local both_ids = results_by_id(both)
  assert(both_ids.b1 == 1 and both_ids.b2 == 1,
    "each orphan needs exactly one result: b1=" .. tostring(both_ids.b1)
      .. " b2=" .. tostring(both_ids.b2))
  assert(last_marker(both):find("straps:user", 1, true),
    "heal did not restore a trailing user block for the batch shape")
end)

case("heal refuses to touch a session with a live run", function()
  -- A tool in flight is indistinguishable, on disk, from an interrupted one:
  -- the tool_use is written, the result is not. Resuming can reach a LIVE
  -- buffer (open_session_file reuses the loaded buffer for a path, and while a
  -- subagent runs the newest saved session is that running child — what bare
  -- :StrapsResume picks), so healing must decline, or the model is told a tool
  -- failed while it is still working AND the real result lands too.
  allow_all()
  define("tool.slow", "tool", "test: still running when we try to heal", [[
return function(input, ctx)
  ctx.await(function(resolve) vim.defer_fn(resolve, 600) end)
  return "the-real-result"
end
]])
  _G.straps_test_calls = 0
  define("fn.provider", "fn", "test: one slow tool then an answer", [==[
return function(req, ctx)
  _G.straps_test_calls = _G.straps_test_calls + 1
  local n = _G.straps_test_calls
  ctx.await(function(resolve)
    vim.defer_fn(function()
      if n > 1 then ctx.emit({ type = "text_delta", text = "live-run-done" }) end
      resolve()
    end, 5)
  end)
  if n == 1 then
    return { stop_reason = "tool_use", content = {
      { type = "tool_use", id = "L1", name = "slow", input = vim.empty_dict() } } }
  end
  return { stop_reason = "end_turn", content = { { type = "text", text = "live-run-done" } } }
end
]==])

  local bufnr = new_session_with_prompt("run something slow")
  loop.start(bufnr)
  assert(vim.wait(2000, function() return buf_text(bufnr):find("straps:tool_use", 1, true) ~= nil end, 10),
    "tool_use marker never appeared")
  assert(loop.running(bufnr), "precondition: the run must still be active")
  assert(state.heal_interrupted(bufnr) == 0, "heal must decline while a run is active")

  wait_done(bufnr)
  local per_id = {}
  for _, m in ipairs(state.parse(bufnr).messages) do
    for _, part in ipairs(m.content) do
      if part.type == "tool_result" then
        per_id[part.tool_use_id] = (per_id[part.tool_use_id] or 0) + 1
      end
    end
  end
  assert(per_id.L1 == 1, "the in-flight call ended up with " .. tostring(per_id.L1) .. " results")
  local text = buf_text(bufnr)
  assert(text:find("the-real-result", 1, true), "the real tool result is missing")
  assert(not text:find("run interrupted before this tool finished", 1, true),
    "heal falsely reported an in-flight tool as interrupted")
end)

case("heal leaves a hand-mangled transcript alone", function()
  -- An orphan tool_use with conversation AFTER it is not an interrupt: a result
  -- appended at the end would not pair it (the result must be in the user
  -- message right after its tool_use), so heal must not touch it — the loud
  -- failure in run_scope.lua is the correct behavior and must stay reachable.
  local bufnr = state.new_session()
  state.append(bufnr, "user", nil, "run a tool")
  state.append(bufnr, "tool_use", { id = "m1", name = "ping" }, "{}")
  state.append(bufnr, "user", nil, "and now continue")   -- user deleted the result
  local before = buf_text(bufnr)
  assert(state.heal_interrupted(bufnr) == 0, "mid-transcript orphan must not be healed")
  assert(buf_text(bufnr) == before, "heal modified a hand-mangled transcript")
end)

case("heal is a no-op on a well-formed transcript", function()
  local bufnr = state.new_session()
  state.append(bufnr, "user", nil, "hi")
  state.append(bufnr, "tool_use", { id = "w1", name = "ping" }, "{}")
  state.append(bufnr, "tool_result", { id = "w1", is_error = false }, "pong")
  state.append(bufnr, "assistant", nil, "done")
  state.ensure_trailing_user(bufnr)
  local before = buf_text(bufnr)
  assert(state.heal_interrupted(bufnr) == 0, "well-formed transcript should need no healing")
  assert(buf_text(bufnr) == before, "heal modified a well-formed transcript")
end)

print(failed == 0 and "ALL PASS" or (failed .. " case(s) FAILED"))
os.exit(failed == 0 and 0 or 1)
