-- tests/model_note_spec.lua — model awareness via the per-request system text:
-- fn.model_note names the session's provider/model/effort and the loop appends
-- it to each request's system, never to the transcript (a user-role notice
-- would merge with the user's own words in parse — harness text wearing the
-- user's voice).
--   busted tests/model_note_spec.lua
-- No network (fn.provider is stubbed for the loop cases). Covers: the note's
-- shape and vim.b override resolution, label rendering, nil for non-session
-- buffers and bad ctx, the loop appending it to every request (including a
-- mid-run model switch), the transcript staying clean of "[straps] Model"
-- lines, and a broken fn.model_note degrading to a note-less request.

local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(vim.fn.fnamemodify(here, ":p"), ":h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path


local straps = require("straps").setup({})
-- Hermetic: durable sessions write under a throwaway dir, never the real data dir.
straps.config.session_dir = vim.fn.tempname()
local registry = require("straps.registry")
local state = require("straps.state")
local loop = require("straps.loop")

-- The impersonation regression guard: no "[straps] Model" line may ever land
-- in the transcript (matched at line start; the system prompt does not carry
-- one at line start either, but keep the anchor for the avoidance of doubt).
local function transcript_notices(bufnr)
  local out = {}
  for _, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    if line:find("^%[straps%] Model") then out[#out + 1] = line end
  end
  return out
end

-- ------------------------------------------------------------- note shape

it("fn.model_note names the effective model, provider and effort", function()
  local me = state.new_session()
  vim.b[me].straps_model = "claude-test-model"
  vim.b[me].straps_effort = "high"
  local note = registry.call("fn.model_note", { bufnr = me })
  assert(type(note) == "string", "expected a note, got " .. type(note))
  assert(note:find("^# Model\n"), "note should open a # Model section: " .. note)
  assert(note:find("claude-test-model", 1, true), "note should name the model: " .. note)
  assert(note:find("provider anthropic", 1, true), "note should name the provider: " .. note)
  assert(note:find("effort high", 1, true), "note should name the effort: " .. note)
  assert(note:find("models tool", 1, true), "note should point at the models tool: " .. note)
  assert(note:find("Subagents inherit", 1, true), "note should carry the inheritance guidance: " .. note)
end)

it("a configured label renders as 'label (id)'", function()
  local me = state.new_session()
  local id = assert(straps.config.models[1] and straps.config.models[1].id,
    "config.models should seed at least one model")
  local label = straps.config.models[1].label
  vim.b[me].straps_model = id
  local note = registry.call("fn.model_note", { bufnr = me })
  if label and label ~= id then
    assert(note:find(("%s (%s)"):format(label, id), 1, true),
      "note should render 'label (id)': " .. note)
  else
    assert(note:find(id, 1, true), "note should name the id: " .. note)
  end
end)

it("effort defaults to 'off' when unset", function()
  local me = state.new_session()
  local note = registry.call("fn.model_note", { bufnr = me })
  assert(note:find("effort off", 1, true), "unset effort should read 'off': " .. note)
end)

-- ------------------------------------------------------------ degradation

it("nil for a non-session buffer, bad ctx, and a dead buffer", function()
  local plain = vim.api.nvim_create_buf(false, true)
  assert(registry.call("fn.model_note", { bufnr = plain }) == nil, "non-session buffer must yield nil")
  assert(registry.call("fn.model_note", {}) == nil, "ctx without bufnr must yield nil")
  assert(registry.call("fn.model_note", nil) == nil, "nil ctx must yield nil")
  local dead = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_delete(dead, { force = true })
  assert(registry.call("fn.model_note", { bufnr = dead }) == nil, "dead buffer must yield nil")
end)

-- --------------------------------------------------------- loop injection

-- A stubbed multi-turn run: capture each request's system text, drive a
-- mid-run model switch from the per-turn hook, and assert the note tracks it
-- while the transcript stays clean.
it("the loop appends the note to every request's system, tracking a mid-run switch", function()
  registry.define({ name = "hook.confirm", kind = "hook",
    doc = "test: allow everything", source = "return function() return true end" })
  registry.define({ name = "tool.noop", kind = "tool", doc = "test: no-op",
    input_schema = { type = "object", properties = vim.empty_dict() },
    source = "return function() return 'ok' end" })
  _G.straps_test_systems = {}
  registry.define({ name = "fn.provider", kind = "fn",
    doc = "test: two tool turns then an answer, capturing req.system",
    source = [==[
return function(req, ctx)
  _G.straps_test_systems[#_G.straps_test_systems + 1] = req.system or ""
  local n = #_G.straps_test_systems
  ctx.await(function(resolve) vim.defer_fn(resolve, 5) end)
  if n <= 2 then
    return { stop_reason = "tool_use", content = {
      { type = "tool_use", id = "n" .. n, name = "noop", input = {} } } }
  end
  return { stop_reason = "end_turn", content = { { type = "text", text = "done" } } }
end
]==] })
  -- The pickers write vim.b between turns; emulate that from the per-turn seam.
  registry.define({ name = "hook.on_turn_start", kind = "hook",
    doc = "test: switch the model before turn 3",
    source = [==[
return function(ctx, turn)
  if turn == 3 then vim.b[ctx.bufnr].straps_model = "switched-model" end
end
]==] })

  local bufnr = state.new_session()
  state.append_text(bufnr, "do the multi-turn thing")
  vim.b[bufnr].straps_model = "loop-test-model"
  loop.start(bufnr)
  assert(vim.wait(5000, function() return not loop.running(bufnr) end, 10),
    "run did not finish within 5s")

  local systems = _G.straps_test_systems
  assert(#systems == 3, "expected 3 provider turns, got " .. #systems)
  for i = 1, 2 do
    assert(systems[i]:find("This session is running on", 1, true),
      ("turn %d request should carry the # Model section"):format(i))
    assert(systems[i]:find("loop-test-model", 1, true),
      ("turn %d request should name the session's model"):format(i))
  end
  assert(systems[3]:find("switched-model", 1, true),
    "the request after a mid-run switch should name the NEW model: " .. systems[3]:sub(-200))
  assert(not systems[3]:find("loop-test-model", 1, true),
    "the old model must not linger in the note")
  -- The note rides the request only: the persisted transcript stays the
  -- user's and the assistant's words.
  assert(#transcript_notices(bufnr) == 0, "no [straps] Model line may land in the transcript")
  local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  assert(not text:find("# Model\n\nThis session is running", 1, true),
    "the note text must not be written into the buffer")

  registry.define({ name = "hook.on_turn_start", kind = "hook",
    doc = "restore: no-op", source = "return function() end" })
end)

it("a broken fn.model_note degrades to a note-less request, not a failed run", function()
  local default = assert(registry.get("fn.model_note"), "fn.model_note missing")
  registry.define({ name = "fn.model_note", kind = "fn",
    doc = "test: always errors", source = "return function() error('boom') end" })
  _G.straps_test_systems = {}
  registry.define({ name = "fn.provider", kind = "fn",
    doc = "test: one answer, capturing req.system",
    source = [==[
return function(req, ctx)
  _G.straps_test_systems[#_G.straps_test_systems + 1] = req.system or ""
  ctx.await(function(resolve) vim.defer_fn(resolve, 5) end)
  return { stop_reason = "end_turn", content = { { type = "text", text = "done" } } }
end
]==] })
  local bufnr = state.new_session()
  state.append_text(bufnr, "still works")
  loop.start(bufnr)
  assert(vim.wait(5000, function() return not loop.running(bufnr) end, 10),
    "run did not finish within 5s")
  assert(#_G.straps_test_systems == 1, "the run should still reach the provider")
  assert(not _G.straps_test_systems[1]:find("This session is running on", 1, true),
    "an erroring note must simply be absent")
  registry.define({ name = default.name, kind = default.kind, doc = default.doc,
    source = default.source }) -- restore the real fn
end)

-- ------------------------------------------------------------- tool.models

it("models lists the active provider's catalog and marks the active model", function()
  local me = state.new_session()
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

it("models follows the session's provider, never mixing catalogs", function()
  local oa = state.new_session()
  vim.b[oa].straps_provider = "openai"
  local out = registry.call("tool.models", {}, { bufnr = oa })
  assert(out:find("provider: openai", 1, true), "should report the openai provider: " .. out)
  assert(out:find("gpt-5", 1, true), "openai ids missing: " .. out)
  assert(not out:find("claude", 1, true),
    "an openai session must not be offered Anthropic ids: " .. out)
end)

it("models is read-only: auto-allowed and parallel-safe", function()
  assert(registry.call("fn.readonly_policy", "models", {}) == true,
    "models should be in the read-only policy")
  -- It must also be in the loop's parallel-readonly set, or a batch of reads
  -- including it silently serializes.
  local src = table.concat(vim.fn.readfile(root .. "/lua/straps/loop.lua"), "\n")
  local block = src:match("local PARALLEL_READONLY = {(.-)}")
  assert(block and block:find("models = true", 1, true),
    "models missing from loop.lua PARALLEL_READONLY")
end)

it("the note points at the models tool", function()
  local me = state.new_session()
  local note = registry.call("fn.model_note", { bufnr = me })
  assert(note:find("models tool", 1, true),
    "the note should point at the catalog: " .. note)
end)
