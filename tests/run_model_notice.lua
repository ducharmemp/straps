-- tests/run_model_notice.lua — the model-awareness notice: telling the agent
-- which provider/model/effort it runs on, and re-announcing a mid-session
-- change (the :StrapsModel / :StrapsEffort pickers write vim.b between turns).
--   nvim --headless -l tests/run_model_notice.lua
-- No network (fn.provider is stubbed for the loop case). Covers: the default
-- hook.on_turn_start notice (first announcement, silence when unchanged,
-- change notices for model and effort, the zero-message and assistant-tail
-- guards and their deferral), tolerance of bad input, and the loop's per-turn
-- call site driving it through a real multi-turn run.

local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(vim.fn.fnamemodify(here, ":p"), ":h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

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

local straps = require("straps").setup({})
-- Hermetic: durable sessions write under a throwaway dir, never the real data dir.
straps.config.session_dir = vim.fn.tempname()
local registry = require("straps.registry")
local state = require("straps.state")
local loop = require("straps.loop")

local function transcript(bufnr)
  return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
end

-- The notice lines themselves, matched at line start. The system prompt's
-- "# Subagents" bullet MENTIONS "[straps] Model:" and the system block is part
-- of the transcript, so a bare substring search would pass on the prompt alone.
local function notices(bufnr)
  local out = {}
  for _, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    if line:find("^%[straps%] Model") then out[#out + 1] = line end
  end
  return out
end

-- A session whose transcript already holds a real user message, so the notice
-- is never the only thing in the request.
local function session_with_prompt(text)
  local bufnr = state.new_session()
  state.append(bufnr, "user", nil, text or "do the thing")
  return bufnr
end

local function fire(bufnr, turn)
  registry.call("hook.on_turn_start", { bufnr = bufnr }, turn or 1)
end

-- ------------------------------------------------------- first announcement

case("announces the effective model, provider and effort as a user block", function()
  local me = session_with_prompt()
  vim.b[me].straps_model = "claude-test-model"
  vim.b[me].straps_effort = "high"
  fire(me)
  local got = notices(me)
  assert(#got == 1, "expected exactly one notice, got " .. #got)
  local text = got[1]
  assert(text:find("^%[straps%] Model: "), "notice should lead with the model: " .. text)
  assert(text:find("claude-test-model", 1, true), "notice should name the effective model")
  assert(text:find("effort high", 1, true), "notice should name the effective effort")
  assert(text:find("provider anthropic", 1, true), "notice should name the provider")
  -- It must be a USER block, or the model never sees it as input.
  local parsed = state.parse(me)
  assert(parsed.messages[#parsed.messages].role == "user",
    "notice must parse as a user message")
end)

case("the notice carries the subagent inheritance guidance", function()
  -- The "# Subagents" prompt section is dropped for subagents, so a nested
  -- spawner would never read the guidance there; the notice is the universal
  -- channel and must carry it.
  local me = session_with_prompt()
  fire(me)
  local text = assert(notices(me)[1], "notice missing")
  assert(text:find("Subagents inherit this model and effort", 1, true),
    "notice should state that subagents inherit model/effort")
  assert(text:find("spawn an explicit model / effort", 1, true),
    "notice should point at spawn's model/effort arguments")
end)

case("a listed model is named by label AND id; an unlisted one just by id", function()
  local listed = session_with_prompt()
  vim.b[listed].straps_model = "claude-sonnet-5" -- in config.models, has a label
  fire(listed)
  local text = assert(notices(listed)[1], "notice missing")
  assert(text:find("claude-sonnet-5", 1, true), "listed model id missing")
  assert(text:find("Sonnet 5", 1, true), "listed model should also show its label")

  local unlisted = session_with_prompt()
  vim.b[unlisted].straps_model = "some-unlisted-model"
  fire(unlisted)
  local raw = assert(notices(unlisted)[1], "notice missing")
  assert(raw:find("Model: some-unlisted-model ", 1, true),
    "an unlisted model should be named once, without a parenthesized duplicate: " .. raw)
end)

-- ------------------------------------------------------------------ silence

case("a turn with nothing changed is silent", function()
  local me = session_with_prompt()
  fire(me, 1)
  local before = transcript(me)
  fire(me, 2)
  fire(me, 3)
  assert(transcript(me) == before,
    "an unchanged model must not be announced again")
end)

-- ------------------------------------------------------------ change notices

case("a mid-session model change is announced with old and new", function()
  local me = session_with_prompt()
  vim.b[me].straps_model = "model-before"
  fire(me, 1)
  -- What :StrapsModel does to a session buffer mid-run.
  vim.b[me].straps_model = "model-after"
  fire(me, 2)
  local got = notices(me)
  assert(#got == 2, "expected the first notice plus a change notice, got " .. #got)
  local text = got[2]
  assert(text:find("Model changed mid-session", 1, true),
    "change notice missing: " .. text)
  assert(text:find("model%-before.*%-%>.*model%-after"),
    "change notice should name old -> new: " .. text)
end)

case("a mid-session effort change is announced", function()
  local me = session_with_prompt()
  vim.b[me].straps_effort = "low"
  fire(me, 1)
  vim.b[me].straps_effort = "high"
  fire(me, 2)
  local text = assert(notices(me)[2], "effort change not announced")
  assert(text:find("Model changed mid-session", 1, true), "should be a change notice: " .. text)
  assert(text:find("effort low", 1, true), "old effort missing from the change notice: " .. text)
  assert(text:find("effort high", 1, true), "new effort missing from the change notice: " .. text)
end)

case("switching back and forth announces each switch", function()
  local me = session_with_prompt()
  vim.b[me].straps_model = "model-a"
  fire(me, 1)
  vim.b[me].straps_model = "model-b"
  fire(me, 2)
  local two = transcript(me)
  vim.b[me].straps_model = "model-a"
  fire(me, 3)
  local three = transcript(me)
  assert(three ~= two, "switching back must be announced (it is the current model)")
  local got = notices(me)
  assert(#got == 3, "expected the first notice plus two change notices, got " .. #got)
  assert(got[3]:find("model%-b.*%-%>.*model%-a"),
    "the third notice should name b -> a: " .. got[3])
end)

case("a model id containing the signature delimiter still renders correctly", function()
  -- The dedup signature is "provider|model|effort", and the change notice
  -- re-reads the old side out of it. A custom or proxied model id may itself
  -- contain "|", which a non-greedy split would mangle.
  local me = session_with_prompt()
  vim.b[me].straps_model = "proxy|weird|id"
  fire(me, 1)
  assert(notices(me)[1]:find("Model: proxy|weird|id ", 1, true),
    "the raw id should appear in the first notice: " .. notices(me)[1])
  vim.b[me].straps_model = "plain-id"
  fire(me, 2)
  local text = assert(notices(me)[2], "change notice missing")
  assert(text:find("proxy|weird|id · provider anthropic · effort off ->", 1, true),
    "the old side must render the full id and the right provider/effort: " .. text)
  assert(text:find("-> plain-id · provider anthropic · effort off.", 1, true),
    "the new side should name the new id and close the sentence: " .. text)
end)

-- ------------------------------------------------------------------- guards

case("a zero-message transcript is left untouched, and the notice defers", function()
  -- A session with nothing but the system block and the empty trailing user
  -- marker parses to zero messages; the loop errors "nothing to send". The
  -- notice must not turn that into a real API request.
  local me = state.new_session()
  assert(#state.parse(me).messages == 0, "fixture should start unsendable")
  local before = transcript(me)
  fire(me)
  assert(transcript(me) == before, "notice must not be appended to an empty transcript")
  assert(#state.parse(me).messages == 0, "transcript must still be unsendable")
  -- Deferred, not dropped: once there is something to answer, it announces.
  state.append(me, "user", nil, "now there is a request")
  fire(me)
  assert(#notices(me) == 1,
    "the deferred notice should land on the next turn that can carry it")
end)

case("an assistant-role tail is left untouched, and the notice defers", function()
  -- Appending a user block over an assistant tail would mask the loop's
  -- "the last turn added nothing to respond to" diagnostic (loop.lua ~366).
  local me = session_with_prompt()
  state.append(me, "assistant", nil, "talking, no tool calls")
  assert(state.parse(me).messages[#state.parse(me).messages].role == "assistant",
    "fixture should end on an assistant message")
  local before = transcript(me)
  fire(me)
  assert(transcript(me) == before, "notice must not append over an assistant tail")
  -- The signature must NOT have been recorded, or the notice would be lost.
  assert(vim.b[me].straps_model_noted == nil,
    "the deferring guard must not record the signature")
  state.append(me, "user", nil, "user replies")
  fire(me)
  assert(#notices(me) == 1,
    "the deferred notice should land once the tail is user-role again")
end)

case("a normal tool-using turn's tail (tool_result) still carries the notice", function()
  -- At turn N>1 the tail is the previous turn's tool_result blocks, which parse
  -- as role user — the notice must fire there, not be starved by the guard.
  local me = session_with_prompt()
  state.append(me, "assistant", nil, "I will look")
  state.append(me, "tool_use", { id = "t1", name = "read_file" }, '{"path":"x"}')
  state.append(me, "tool_result", { id = "t1", is_error = false }, "contents")
  fire(me, 2)
  assert(#notices(me) == 1, "the notice must fire on a tool_result tail")
end)

-- ------------------------------------------------------------- tool.models

case("models lists the active provider's catalog and marks the active model", function()
  local me = session_with_prompt()
  vim.b[me].straps_model = "claude-haiku-4-5-20251001"
  vim.b[me].straps_effort = "medium"
  local out = registry.call("tool.models", {}, { bufnr = me })
  -- The ids are what spawn's `model` takes, so they must appear verbatim.
  assert(out:find("claude-haiku-4-5-20251001", 1, true), "seeded id missing: " .. out)
  assert(out:find("claude-sonnet-5", 1, true), "other ids should be listed too")
  -- The capability/cost labels are the whole point: they make the choice.
  assert(out:find("fastest, cheapest", 1, true), "capability label missing: " .. out)
  assert(out:find("most capable, slowest", 1, true), "capability label missing: " .. out)
  assert(out:find("* claude%-haiku%-4%-5%-20251001"),
    "the session's active model should be marked: " .. out)
  assert(out:find("effort names: off, low, medium, high", 1, true),
    "effort names missing: " .. out)
  assert(out:find("this session: medium", 1, true), "active effort missing: " .. out)
end)

case("models follows the session's provider, never mixing catalogs", function()
  local oa = session_with_prompt()
  vim.b[oa].straps_provider = "openai"
  local out = registry.call("tool.models", {}, { bufnr = oa })
  assert(out:find("provider: openai", 1, true), "should report the openai provider: " .. out)
  assert(out:find("gpt-5", 1, true), "openai ids missing: " .. out)
  assert(not out:find("claude", 1, true),
    "an openai session must not be offered Anthropic ids: " .. out)
end)

case("models is read-only: auto-allowed and parallel-safe", function()
  assert(registry.call("fn.readonly_policy", "models", {}) == true,
    "models should be in the read-only policy")
  assert(registry.call("hook.confirm", "models", {}, { bufnr = session_with_prompt() }) == true,
    "models should be auto-allowed without a prompt")
  -- It must also be in the loop's parallel-readonly set, or a batch of reads
  -- including it silently serializes.
  local src = table.concat(vim.fn.readfile(root .. "/lua/straps/loop.lua"), "\n")
  local block = src:match("local PARALLEL_READONLY = {(.-)}")
  assert(block and block:find("models = true", 1, true),
    "models missing from loop.lua PARALLEL_READONLY")
end)

case("the notice points at the models tool", function()
  local me = session_with_prompt()
  fire(me)
  assert(notices(me)[1]:find("models tool", 1, true),
    "the notice should point at the catalog: " .. notices(me)[1])
end)

-- ---------------------------------------------------------------- resume

-- Persist a session, wipe its buffer, and reload it from its file — what
-- reopening a durable transcript does. vim.b (and so the dedup signature) does
-- NOT survive; the notice in the file does.
local function resume(bufnr)
  local path = vim.api.nvim_buf_get_name(bufnr)
  state.persist(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
  local fresh = vim.fn.bufadd(path)
  vim.fn.bufload(fresh)
  vim.b[fresh].straps_session = true
  return fresh
end

case("a resumed session does not re-announce an unchanged model", function()
  local me = session_with_prompt()
  vim.b[me].straps_model = "resume-model"
  fire(me, 1)
  assert(#notices(me) == 1, "fixture should have announced once")
  local back = resume(me)
  assert(vim.b[back].straps_model_noted == nil,
    "vim.b should not survive a reload (else this test proves nothing)")
  vim.b[back].straps_model = "resume-model" -- unchanged since it stopped
  fire(back, 1)
  assert(#notices(back) == 1,
    "the signature must be recovered from the transcript, not re-announced")
  assert(vim.b[back].straps_model_noted == "anthropic|resume-model|off",
    "recovered signature: " .. tostring(vim.b[back].straps_model_noted))
end)

case("resume recovers the id from a labelled notice, and from a change notice", function()
  -- A first notice may render "<label> (<id>)", and a change notice carries the
  -- current triple after "-> "; both must yield the ID, not the label.
  local labelled = session_with_prompt()
  vim.b[labelled].straps_model = "claude-sonnet-5" -- labelled in config.models
  fire(labelled, 1)
  local back = resume(labelled)
  vim.b[back].straps_model = "claude-sonnet-5"
  fire(back, 1)
  assert(#notices(back) == 1, "a labelled model re-announced after resume")
  assert(vim.b[back].straps_model_noted == "anthropic|claude-sonnet-5|off",
    "label should not leak into the signature: " .. tostring(vim.b[back].straps_model_noted))

  local changed = session_with_prompt()
  vim.b[changed].straps_model = "first-model"
  fire(changed, 1)
  vim.b[changed].straps_model = "second-model"
  fire(changed, 2)
  local back2 = resume(changed)
  vim.b[back2].straps_model = "second-model"
  fire(back2, 1)
  assert(#notices(back2) == 2, "a change notice was re-announced after resume")
  assert(vim.b[back2].straps_model_noted == "anthropic|second-model|off",
    "the change notice's NEW side is the current signature: "
      .. tostring(vim.b[back2].straps_model_noted))
end)

case("a real change after a resume is still announced", function()
  local me = session_with_prompt()
  vim.b[me].straps_model = "before-resume"
  fire(me, 1)
  local back = resume(me)
  vim.b[back].straps_model = "after-resume" -- switched while it was closed
  fire(back, 1)
  local got = notices(back)
  assert(#got == 2, "a genuine change across a resume must announce, got " .. #got)
  assert(got[2]:find("before%-resume.*%-%>.*after%-resume"),
    "the change notice should name both sides: " .. got[2])
end)

-- -------------------------------------------------------------- robustness

case("a ctx without a bufnr never writes to the session the user is viewing", function()
  -- ui.session_info(nil) falls back to the CURRENT buffer, so a hook called
  -- without a bufnr must not resolve THAT session and append to it. The bufnr
  -- check stops it first; the pcall-guarded vim.b read and state.parse behind
  -- it are the second line of defense. This pins the OUTCOME, so it holds
  -- whichever layer catches it.
  local me = session_with_prompt()
  local prev = vim.api.nvim_get_current_buf()
  vim.api.nvim_set_current_buf(me)
  local before = transcript(me)
  registry.call("hook.on_turn_start", {}, 1)
  registry.call("hook.on_turn_start", nil, 1)
  local after = transcript(me)
  pcall(vim.api.nvim_set_current_buf, prev)
  assert(after == before,
    "a bufnr-less call must not append to the current session buffer")
end)

case("tolerates an invalid session buffer and a missing ctx", function()
  local dead = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_delete(dead, { force = true })
  fire(dead)
  registry.call("hook.on_turn_start", {}, 1)
  registry.call("hook.on_turn_start", nil, 1)
  -- A plain (non-session) buffer has no session_info; it must be ignored.
  local plain = vim.api.nvim_create_buf(false, true)
  local before = table.concat(vim.api.nvim_buf_get_lines(plain, 0, -1, false), "\n")
  fire(plain)
  assert(table.concat(vim.api.nvim_buf_get_lines(plain, 0, -1, false), "\n") == before,
    "a non-session buffer must not be written to")
end)

-- ------------------------------------------------------------- loop wiring

case("the loop fires the hook every turn, and the notice lands once", function()
  registry.define({ name = "hook.confirm", kind = "hook",
    doc = "test: allow everything", source = "return function() return true end" })
  -- Count invocations per turn, and let the default notice run underneath.
  _G.straps_test_turn_hook = 0
  local default = assert(registry.get("hook.on_turn_start"), "hook.on_turn_start missing")
  registry.define({ name = "hook.on_turn_start", kind = "hook",
    doc = "test: count then delegate",
    source = [==[
return function(ctx, turn)
  _G.straps_test_turn_hook = (_G.straps_test_turn_hook or 0) + 1
  _G.straps_test_turn_last = turn
  return _G.straps_test_default_turn_hook(ctx, turn)
end
]==] })
  _G.straps_test_default_turn_hook = default.fn

  registry.define({ name = "tool.noop", kind = "tool", doc = "test: no-op",
    input_schema = { type = "object", properties = vim.empty_dict() },
    source = "return function() return 'ok' end" })
  _G.straps_test_calls = 0
  registry.define({ name = "fn.provider", kind = "fn",
    doc = "test: two tool turns then an answer",
    source = [==[
return function(req, ctx)
  _G.straps_test_calls = _G.straps_test_calls + 1
  local n = _G.straps_test_calls
  ctx.await(function(resolve) vim.defer_fn(resolve, 5) end)
  if n <= 2 then
    return { stop_reason = "tool_use", content = {
      { type = "tool_use", id = "n" .. n, name = "noop", input = {} } } }
  end
  return { stop_reason = "end_turn", content = { { type = "text", text = "done" } } }
end
]==] })

  local bufnr = state.new_session()
  state.append_text(bufnr, "do the multi-turn thing")
  vim.b[bufnr].straps_model = "loop-test-model"
  loop.start(bufnr)
  assert(vim.wait(5000, function() return not loop.running(bufnr) end, 10),
    "run did not finish within 5s")

  assert(_G.straps_test_calls == 3, "expected 3 provider turns, got " .. _G.straps_test_calls)
  assert(_G.straps_test_turn_hook == 3,
    "hook should fire once per turn (3), got " .. tostring(_G.straps_test_turn_hook))
  assert(_G.straps_test_turn_last == 3, "hook should receive the turn number, got "
    .. tostring(_G.straps_test_turn_last))
  local got = notices(bufnr)
  assert(#got == 1,
    "across 3 turns the unchanged model must be announced exactly once, got " .. #got)
  assert(got[1]:find("loop-test-model", 1, true), "notice should name the session's model")

  registry.define({ name = default.name, kind = default.kind, doc = default.doc,
    source = default.source }) -- restore the real hook
end)

if failed > 0 then
  print("FAILED (" .. failed .. ")")
  os.exit(1)
end
print("ALL PASS")
os.exit(0)
