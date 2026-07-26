-- Full-stack integration test: real setup() (provider, tools, hooks, ui),
-- then fn.provider and hook.confirm are REDEFINED at runtime — which is
-- itself the architecture under test — and a scripted 3-turn session runs
-- the canonical self-extension scenario:
--   turn 1: agent redefines hook.after_write (auto-lint) and defines a new
--           tool ("shout") via registry_define
--   turn 2: agent calls write_file (linter hook must fire) and shout
--           (new tool must be callable one turn after its definition)
--   turn 3: agent streams final text
-- Run: nvim --headless -l tests/run_integration.lua

local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(here, ":h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

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

local straps = require("straps").setup({ max_turns = 8 })
-- Hermetic: durable sessions write under a throwaway dir, never the real data dir.
straps.config.session_dir = vim.fn.tempname()
local registry = require("straps.registry")
local state = require("straps.state")
local loop = require("straps.loop")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local demo_path = tmp .. "/demo.txt"

case("setup registers provider, tools, hooks", function()
  for _, name in ipairs({
    "fn.provider", "fn.build_tools", "fn.system_prompt", "fn.api_key",
    "tool.write_file", "tool.read_file", "tool.registry_define", "hook.confirm", "hook.after_write",
  }) do
    assert(registry.get(name), "missing " .. name)
  end
end)

-- Runtime redefinitions (no network, no confirm dialogs in headless).
registry.define({
  name = "hook.confirm",
  kind = "hook",
  doc = "test: allow everything",
  source = [[return function() return true end]],
})

_G.__it = { turn = 0, tools_seen = {}, last_roles = {} }
_G.__it_demo_path = demo_path

registry.define({
  name = "fn.provider",
  kind = "fn",
  doc = "test: scripted 3-turn provider",
  source = [==[
-- Async like the real provider: suspend in ctx.await, emit deltas from a
-- callback context, resolve with the final response.
return function(req, ctx)
  local it = _G.__it
  it.turn = it.turn + 1
  it.tools_seen[it.turn] = vim.tbl_map(function(t) return t.name end, req.tools)
  it.last_roles[it.turn] = #req.messages > 0 and req.messages[#req.messages].role or "?"
  local function respond(resp)
    return ctx.await(function(resolve)
      vim.defer_fn(function()
        if resp.content[1] and resp.content[1].type == "text" then
          ctx.emit({ type = "text_delta", text = resp.content[1].text })
        end
        resolve(resp)
      end, 5)
    end)
  end
  if it.turn == 1 then
    return respond({
      stop_reason = "tool_use",
      content = {
        { type = "tool_use", id = "t1", name = "registry_define", input = {
            name = "hook.after_write", kind = "hook",
            doc = "auto-lint after every write",
            source = 'return function(path, ctx) return "LINT " .. path .. ": ok" end',
        } },
        { type = "tool_use", id = "t2", name = "registry_define", input = {
            name = "tool.shout", kind = "tool",
            doc = "Uppercase some text.",
            input_schema = '{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}',
            source = 'return function(input) return string.upper(input.text) end',
        } },
      },
    })
  elseif it.turn == 2 then
    return respond({
      stop_reason = "tool_use",
      content = {
        { type = "tool_use", id = "t3", name = "write_file",
          input = { path = _G.__it_demo_path, content = "hello from straps\n" } },
        { type = "tool_use", id = "t4", name = "shout", input = { text = "it works" } },
      },
    })
  end
  return respond({ stop_reason = "end_turn", content = { { type = "text", text = "done: linting is now automatic" } } })
end
]==],
})

local bufnr = state.new_session()
state.append(bufnr, "user", nil, "from now on, lint every file you write; then write demo.txt")

loop.start(bufnr)
vim.wait(10000, function()
  return not loop.running(bufnr)
end, 10)

local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")

case("run completed", function()
  assert(not loop.running(bufnr), "loop still running")
  assert(_G.__it.turn == 3, "expected 3 provider turns, got " .. _G.__it.turn)
end)

case("hook.after_write redefinition is SESSION-scoped: chain sees v2, global stays v1", function()
  -- The agent's registry_define during the run lands in the session scope.
  local g = assert(registry.get("hook.after_write"))
  assert(g.version == 1, "global entry should be untouched, version = " .. tostring(g.version))
  assert(g.scope == nil, "global entry should have no scope")
  local prev = registry.set_active_scope(bufnr)
  local ok, e = pcall(registry.get, "hook.after_write")
  registry.set_active_scope(prev)
  assert(ok and e, "session-scoped entry missing")
  assert(e.version == 2, "session-scoped version = " .. tostring(e.version))
  assert(e.doc:find("auto%-lint"), "doc not updated")
  assert(e.scope == bufnr, "entry should record its owning scope")
end)

case("new tool is in the tool list on the following turn", function()
  assert(not vim.tbl_contains(_G.__it.tools_seen[1], "shout"), "shout leaked into turn 1")
  assert(vim.tbl_contains(_G.__it.tools_seen[2], "shout"), "shout missing in turn 2")
end)

case("write_file wrote the file and the linter hook fired into its result", function()
  assert(vim.fn.filereadable(demo_path) == 1, "file not written")
  assert(table.concat(vim.fn.readfile(demo_path), "\n") == "hello from straps")
  assert(text:find("LINT " .. demo_path .. ": ok", 1, true), "linter output not in tool_result")
end)

case("agent-defined tool executed", function()
  assert(text:find("IT WORKS", 1, true), "shout result missing")
end)

case("final assistant text streamed into the buffer", function()
  assert(text:find("done: linting is now automatic", 1, true))
end)

case("transcript still parses; messages stay API-valid", function()
  local parsed = state.parse(bufnr)
  assert(parsed.system and #parsed.system > 0, "system prompt missing")
  assert(#parsed.messages >= 5, "too few messages: " .. #parsed.messages)
  for i = 2, #parsed.messages do
    assert(parsed.messages[i].role ~= parsed.messages[i - 1].role, "roles not alternating at " .. i)
  end
  for t = 2, 3 do
    assert(_G.__it.last_roles[t] == "user", "provider turn " .. t .. " did not end on a user message")
  end
  assert(state.last_user_text(bufnr) == nil or state.last_user_text(bufnr) == "",
    "trailing user prompt block should be empty")
end)

case("session buffer is buffer-state", function()
  assert(vim.b[bufnr].straps_session == true)
  assert(vim.b[bufnr].straps_status == "idle")
end)

case("config merge applied", function()
  assert(straps.config.max_turns == 8)
  assert(straps.config.model == "claude-sonnet-5")
end)

-- Picker tests: stub ui.pick (the snacks/vim.ui.select seam) so these run
-- headless and deterministically, rather than exercising the real backend.
do
  local ui = require("straps.ui")
  local real_pick = ui.pick

  local function with_stub(choice, fn)
    ui.pick = function(items, opts, on_choice)
      on_choice(choice)
    end
    local ok, err = pcall(fn)
    ui.pick = real_pick
    if not ok then
      error(err, 0)
    end
  end

  -- Hermetic model discovery: stub fn.list_models so pick_model never touches
  -- the network. A nil return exercises the graceful fallback to config.models.
  local registry = require("straps.registry")
  local function with_list_models(source, fn)
    registry.define({ name = "fn.list_models", kind = "fn",
      doc = "test stub", source = source })
    local ok, err = pcall(fn)
    if not ok then
      error(err, 0)
    end
  end

  case("pick_model sets config.model from a picked entry", function()
    straps.config.provider = "anthropic"
    with_list_models("return function() return nil, 'stubbed offline' end", function()
      with_stub({ id = "claude-opus-4-8", label = "Opus 4.8" }, function()
        ui.pick_model()
      end)
    end)
    assert(straps.config.model == "claude-opus-4-8",
      "config.model is " .. tostring(straps.config.model))
  end)

  case("pick_model writes config.openai_model and uses only OpenAI models when OpenAI is active", function()
    straps.config.provider = "openai"
    straps.config.model = "claude-sonnet-5"
    straps.config.openai_model = "gpt-5"
    straps.config.openai_models = { { id = "gpt-5", label = "GPT-5" } }
    local seen
    with_list_models("return function(provider) _G.__last_model_provider = provider; return { { id = 'gpt-5-mini', label = 'gpt-5-mini' } } end", function()
      ui.pick = function(items, opts, on_choice)
        seen = items
        on_choice({ id = "gpt-5-mini", label = "gpt-5-mini" })
      end
      ui.pick_model()
      ui.pick = real_pick
    end)
    assert(_G.__last_model_provider == "openai", "pick_model did not request the OpenAI catalog")
    assert(straps.config.openai_model == "gpt-5-mini",
      "openai_model is " .. tostring(straps.config.openai_model))
    assert(straps.config.model == "claude-sonnet-5", "OpenAI pick should not overwrite Anthropic config.model")
    for _, m in ipairs(seen or {}) do
      assert(not tostring(m.id):find("claude", 1, true), "OpenAI picker leaked Claude model: " .. vim.inspect(m))
    end
    straps.config.provider = "anthropic"
  end)

  case("pick_model cancel (nil choice) leaves config.model untouched", function()
    straps.config.model = "claude-sonnet-5"
    with_list_models("return function() return nil, 'stubbed offline' end", function()
      with_stub(nil, function()
        ui.pick_model()
      end)
    end)
    assert(straps.config.model == "claude-sonnet-5",
      "cancel should not change config.model, got " .. tostring(straps.config.model))
  end)

  case("pick_model merges live-discovered models into the picker list", function()
    -- A fresh discovery brings a model absent from config.models.
    with_list_models([[
return function()
  return {
    { id = "claude-sonnet-5", label = "API Sonnet 5", thinking = "adaptive" },
    { id = "claude-fable-5", label = "Claude Fable 5", thinking = "adaptive" },
  }
end
]], function()
      local seen
      local saved_pick = ui.pick
      ui.pick = function(items) seen = items end
      pcall(ui.pick_model)
      ui.pick = saved_pick
      assert(type(seen) == "table", "picker never received items")
      local has_fable, sonnet_label
      for _, m in ipairs(seen) do
        if m.id == "claude-fable-5" then has_fable = true end
        if m.id == "claude-sonnet-5" then sonnet_label = m.label end
      end
      assert(has_fable, "live-only model claude-fable-5 not merged into the picker")
      -- Curated static label must win over the API display_name.
      assert(sonnet_label == "Sonnet 5 — balanced (default)",
        "curated label lost in merge, got " .. tostring(sonnet_label))
      -- The merged list is persisted so fn.provider can read the thinking tag.
      local persisted
      for _, m in ipairs(straps.config.models) do
        if m.id == "claude-fable-5" then persisted = m end
      end
      local sonnet
      for _, m in ipairs(straps.config.models) do
        if m.id == "claude-sonnet-5" then sonnet = m end
      end
      assert(persisted and persisted.thinking == "adaptive",
        "discovered model not persisted with its thinking tag")
      assert(sonnet and sonnet.context == 200000,
        "static context metadata was not preserved through merge")
    end)
    straps.config.models = {
      { id = "claude-opus-4-8", label = "Opus 4.8 — most capable, slowest", thinking = "adaptive", context = 200000 },
      { id = "claude-sonnet-5", label = "Sonnet 5 — balanced (default)", thinking = "adaptive", context = 200000 },
      { id = "claude-sonnet-4-6", label = "Sonnet 4.6", thinking = "adaptive", context = 200000 },
      { id = "claude-haiku-4-5-20251001", label = "Haiku 4.5 — fastest, cheapest", thinking = "budget", context = 200000 },
    }
  end)

  case("pick_effort sets config.effort from a picked entry", function()
    with_stub({ name = "high", level = "high", budget_tokens = 24000 }, function()
      ui.pick_effort()
    end)
    assert(straps.config.effort == "high", "config.effort is " .. tostring(straps.config.effort))
  end)

  case("pick_model on a session buffer sets the provider-specific PER-BUFFER slot", function()
    local sess = state.new_session()
    local prev = vim.api.nvim_get_current_buf()
    vim.api.nvim_set_current_buf(sess)
    straps.config.model = "claude-sonnet-5"
    with_list_models("return function() return nil end", function()
      with_stub({ id = "claude-fable-5", label = "Fable 5" }, function()
        ui.pick_model()
      end)
    end)
    assert(vim.b[sess].straps_model == "claude-fable-5",
      "per-buffer Anthropic model not set: " .. tostring(vim.b[sess].straps_model))
    assert(straps.config.model == "claude-sonnet-5",
      "global config.model was mutated (" .. tostring(straps.config.model)
        .. ") — should stay put when picking on a session buffer")

    vim.b[sess].straps_provider = "openai"
    straps.config.openai_model = "gpt-5"
    with_list_models("return function(provider) _G.__last_session_model_provider = provider; return nil end", function()
      with_stub({ id = "gpt-5-mini", label = "gpt-5-mini" }, function()
        ui.pick_model()
      end)
    end)
    vim.api.nvim_set_current_buf(prev)
    assert(_G.__last_session_model_provider == "openai", "session OpenAI picker did not request OpenAI")
    assert(vim.b[sess].straps_openai_model == "gpt-5-mini",
      "per-buffer OpenAI model not set: " .. tostring(vim.b[sess].straps_openai_model))
    assert(vim.b[sess].straps_model == "claude-fable-5", "OpenAI pick clobbered Anthropic per-buffer model")
    assert(straps.config.openai_model == "gpt-5", "global openai_model was mutated on a session buffer")
  end)

  case("pick_effort on a session buffer sets it PER-BUFFER, not global", function()
    local sess = state.new_session()
    local prev = vim.api.nvim_get_current_buf()
    vim.api.nvim_set_current_buf(sess)
    straps.config.effort = "off"
    with_stub({ name = "high", level = "high" }, function()
      ui.pick_effort()
    end)
    vim.api.nvim_set_current_buf(prev)
    assert(vim.b[sess].straps_effort == "high",
      "per-buffer effort not set: " .. tostring(vim.b[sess].straps_effort))
    assert(straps.config.effort == "off",
      "global config.effort was mutated — should stay put on a session buffer")
  end)

  -- Provider picker: hermetic XDG so fn.provider_pref writes to a throwaway dir.
  do
    local saved_xdg = vim.env.XDG_CONFIG_HOME
    local saved_provider = straps.config.provider
    local pdir = vim.fn.tempname()
    vim.fn.mkdir(pdir, "p")
    vim.env.XDG_CONFIG_HOME = pdir

    case("pick_provider global sets config.provider AND persists to the file", function()
      straps.config.provider = nil
      with_stub("openai", function()
        ui.pick_provider()
      end)
      assert(straps.config.provider == "openai",
        "config.provider is " .. tostring(straps.config.provider))
      local line = vim.trim(table.concat(vim.fn.readfile(pdir .. "/straps/provider"), "\n"))
      assert(line == "openai", "persisted file wrong: " .. line)
      -- fn.provider_pref reads it back.
      assert(registry.call("fn.provider_pref") == "openai", "provider_pref read-back wrong")
    end)

    case("pick_provider cancel (nil) leaves config.provider untouched", function()
      straps.config.provider = "anthropic"
      with_stub(nil, function()
        ui.pick_provider()
      end)
      assert(straps.config.provider == "anthropic",
        "cancel should not change config.provider, got " .. tostring(straps.config.provider))
    end)

    case("pick_provider on a session buffer sets it PER-BUFFER, no file write", function()
      local sess = state.new_session()
      local prev = vim.api.nvim_get_current_buf()
      vim.api.nvim_set_current_buf(sess)
      straps.config.provider = nil
      vim.fn.delete(pdir .. "/straps/provider")
      with_stub("openai", function()
        ui.pick_provider()
      end)
      vim.api.nvim_set_current_buf(prev)
      assert(vim.b[sess].straps_provider == "openai",
        "per-buffer provider not set: " .. tostring(vim.b[sess].straps_provider))
      assert(straps.config.provider == nil,
        "global config.provider was mutated on a session buffer")
      assert(vim.fn.filereadable(pdir .. "/straps/provider") == 0,
        "session pick should not persist to the global file")
    end)

    vim.env.XDG_CONFIG_HOME = saved_xdg
    straps.config.provider = saved_provider
  end

  straps.config.model = "claude-sonnet-5"
  straps.config.effort = "off"
end

case("session_status reflects per-buffer override with a divergence marker", function()
  local ui = require("straps.ui")
  local sess = state.new_session()
  local prev = vim.api.nvim_get_current_buf()
  vim.api.nvim_set_current_buf(sess)
  straps.config.model = "claude-sonnet-5"
  straps.config.effort = "off"
  -- No override: shows the global default, no marker.
  local base = ui.session_status()
  assert(base:find("claude-sonnet-5", 1, true) or base:find("Sonnet 5", 1, true),
    "status should show the global model when no override: " .. base)
  assert(not base:find("*", 1, true), "no override should have no divergence marker: " .. base)
  -- With override: shows it, with a trailing marker.
  vim.b[sess].straps_model = "claude-fable-5"
  vim.b[sess].straps_effort = "high"
  local over = ui.session_status()
  vim.api.nvim_set_current_buf(prev)
  assert(over:find("high", 1, true), "effort missing from status: " .. over)
  assert(over:sub(-1) == "*", "override should end with the divergence marker: " .. over)
end)

case("session_status and session_winbar are empty on non-session buffers", function()
  local ui = require("straps.ui")
  local scratch = vim.api.nvim_create_buf(false, true)
  local prev = vim.api.nvim_get_current_buf()
  vim.api.nvim_set_current_buf(scratch)
  local s, w = ui.session_status(), ui.session_winbar()
  vim.api.nvim_set_current_buf(prev)
  assert(s == "", "session_status should be empty off a session buffer: [" .. s .. "]")
  assert(w == "", "session_winbar should be empty off a session buffer: [" .. w .. "]")
end)

case("usage_status: empty with no usage, and off a session buffer", function()
  local ui = require("straps.ui")
  local sess = state.new_session()
  local prev = vim.api.nvim_get_current_buf()
  vim.api.nvim_set_current_buf(sess)
  assert(ui.usage_status() == "", "no usage yet should be empty")
  vim.api.nvim_set_current_buf(prev)
  local scratch = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(scratch)
  assert(ui.usage_status() == "", "usage_status should be empty off a session buffer")
  vim.api.nvim_set_current_buf(prev)
end)

case("usage_status: context fill percent and cache rate from vim.b.straps_usage", function()
  local ui = require("straps.ui")
  local sess = state.new_session()
  local prev = vim.api.nvim_get_current_buf()
  vim.api.nvim_set_current_buf(sess)
  straps.config.model = "claude-sonnet-5"     -- context = 200000
  -- 50000 input of which 40000 was a cache read.
  vim.b[sess].straps_usage = {
    input = 10000, cache_read = 40000, cache_creation = 0,
    input_billed = 50000, output = 200,
  }
  local out = ui.usage_status()
  vim.api.nvim_set_current_buf(prev)
  assert(out:find("50.0k/200k", 1, true) or out:find("50k/200k", 1, true),
    "context fill missing: " .. out)
  assert(out:find("(25%)", 1, true), "context percent wrong (want 25%%): " .. out)
  assert(out:find("cache 80%", 1, true), "cache rate wrong (want 80%%): " .. out)
end)

case("usage_status: unknown model with no context_window shows raw count", function()
  local ui = require("straps.ui")
  local sess = state.new_session()
  local prev = vim.api.nvim_get_current_buf()
  vim.api.nvim_set_current_buf(sess)
  vim.b[sess].straps_model = "some-unlisted-model"
  local saved = straps.config.context_window
  straps.config.context_window = nil
  vim.b[sess].straps_usage = { input_billed = 1234, cache_read = 0 }
  local out = ui.usage_status()
  straps.config.context_window = saved
  vim.api.nvim_set_current_buf(prev)
  assert(out:find("ctx", 1, true), "expected a raw ctx count: " .. out)
  assert(not out:find("%%", 1, true), "no percent should show without a window: " .. out)
end)

case("session_winbar includes the usage segment when usage is present", function()
  local ui = require("straps.ui")
  local sess = state.new_session()
  local prev = vim.api.nvim_get_current_buf()
  vim.api.nvim_set_current_buf(sess)
  straps.config.model = "claude-sonnet-5"
  vim.b[sess].straps_usage = { input_billed = 20000, cache_read = 0 }
  local w = ui.session_winbar()
  vim.api.nvim_set_current_buf(prev)
  assert(w:find("20k/200k", 1, true) or w:find("20.0k/200k", 1, true),
    "winbar should embed the usage segment: " .. w)
  assert(w:find("idle", 1, true), "winbar should still show run status: " .. w)
end)

case("default progress hook cleaned up its extmarks", function()
  -- setup() registered the real hook.on_progress default, so the run above
  -- exercised the ui mechanism; done must have torn the indicator down.
  local ns = vim.api.nvim_create_namespace("straps_progress")
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})
  assert(#marks == 0, "leftover progress extmarks: " .. #marks)
end)

-- ui.open_session() is a single ordinary buffer now (no linked compose split):
-- type directly under the trailing %%[straps:user]%% marker and press <CR>
-- in normal mode. These cases drive the real keymap via nvim_feedkeys so the
-- wiring under test is exactly what a person at the keyboard exercises.
local ui = require("straps.ui")

local function press_enter(bufnr)
  local win = assert(vim.fn.win_findbuf(bufnr)[1], "session buffer has no window")
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(bufnr), 0 })
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
end

case("typing under the trailing user marker and <CR> starts a run", function()
  local session = ui.open_session()
  assert(vim.b[session].straps_session, "opened buffer isn't a session")

  _G.__it.turn = 0 -- replay the scripted 3-turn provider
  vim.api.nvim_buf_set_lines(session, -1, -1, false, { "line one of the ask", "line two of the ask" })
  press_enter(session)

  local t = table.concat(vim.api.nvim_buf_get_lines(session, 0, -1, false), "\n")
  assert(t:find("%%[straps:user]%%\nline one of the ask\nline two of the ask", 1, true),
    "typed text not present as a user block")

  assert(vim.wait(10000, function() return not loop.running(session) end, 10),
    "run did not finish")
  assert(_G.__it.turn == 3, "expected 3 provider turns, got " .. _G.__it.turn)
end)

case("<CR> while a run is active prompts to steer instead of starting a second run", function()
  _G.__steer = { calls = 0, mid_turn = false }
  registry.define({
    name = "fn.provider",
    kind = "fn",
    doc = "test: slow first turn so a mid-run <CR> lands as steering",
    source = [==[
return function(req, ctx)
  local st = _G.__steer
  st.calls = st.calls + 1
  local n = st.calls
  return ctx.await(function(resolve)
    vim.defer_fn(function()
      if n == 1 then
        st.mid_turn = true -- the test presses <CR> again now
        vim.defer_fn(function()
          ctx.emit({ type = "text_delta", text = "slow first reply" })
          resolve({ stop_reason = "end_turn",
            content = { { type = "text", text = "slow first reply" } } })
        end, 100)
      else
        ctx.emit({ type = "text_delta", text = "steered second reply" })
        resolve({ stop_reason = "end_turn",
          content = { { type = "text", text = "steered second reply" } } })
      end
    end, 5)
  end)
end
]==],
  })

  local session = ui.open_session()
  vim.api.nvim_buf_set_lines(session, -1, -1, false, { "first message" })
  press_enter(session)
  assert(loop.running(session), "run did not start from <CR>")

  assert(vim.wait(2000, function() return _G.__steer.mid_turn end, 5),
    "provider never reached mid-turn")
  assert(loop.running(session), "run finished before the steering <CR>")

  -- <CR> mid-run opens vim.ui.input({prompt="steer: "}); stub it.
  local real_input = vim.ui.input
  vim.ui.input = function(_, on_confirm) on_confirm("second message") end
  press_enter(session)
  vim.ui.input = real_input

  assert(vim.wait(10000, function() return not loop.running(session) end, 10),
    "run did not finish")
  assert(_G.__steer.calls == 2,
    "provider called " .. _G.__steer.calls .. " times, want 2 (steer at end_turn continues)")
  local t = table.concat(vim.api.nvim_buf_get_lines(session, 0, -1, false), "\n")
  local first = t:find("%%[straps:user]%%\nfirst message", 1, true)
  local second = t:find("%%[straps:user]%%\nsecond message", 1, true)
  assert(first, "first message missing as a user block")
  assert(second and second > first, "steered message missing as a user block after the first")
  assert(t:find("steered second reply", 1, true), "turn-2 output missing")
end)

if failed then
  print("FAILED")
  os.exit(1)
end
print("ALL PASS")
os.exit(0)
