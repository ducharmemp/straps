-- Provider tests: run the REAL fn.provider source against fake `curl`
-- binaries placed first on PATH. Covers the full tool round-trip (the model
-- requests bash, the tool runs, the follow-up turn completes), the custom
-- base_url config, and the idle-stream watchdog (a server that keeps the
-- connection open but silent must not hang the run forever).
-- Run: busted tests/provider_spec.lua

local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(vim.fn.fnamemodify(here, ":p"), ":h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

-- Runs `fn` at test time, in document order with the surrounding `it`s (the
-- old runner executed cases inline; busted collects first, then runs).
local function step(fn)
  local info = debug.getinfo(fn, "S")
  describe("step@" .. info.short_src .. ":" .. info.linedefined, function() setup(fn) end)
end


vim.env.ANTHROPIC_API_KEY = "test-key-not-real"
local straps = require("straps").setup({})
-- Hermetic: durable sessions write under a throwaway dir, never the real data dir.
straps.config.session_dir = vim.fn.tempname()
-- Hermetic backend: this suite exercises the Anthropic SSE path via run_session;
-- pin the provider so a developer's persisted ~/.config/straps/provider (which
-- fn.provider would otherwise consult) can't route these turns to OpenAI. The
-- OpenAI-specific sections set config.provider = "openai" locally and restore it.
straps.config.provider = "anthropic"
local registry = require("straps.registry")
local state = require("straps.state")
local loop = require("straps.loop")

registry.define({ name = "hook.confirm", kind = "hook", doc = "test: allow all",
  source = [[return function() return true end]] })

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp .. "/scripted", "p")
vim.fn.mkdir(tmp .. "/stalling", "p")
local real_path = vim.env.PATH

local function write_exec(path, text)
  -- Sandboxed builds (nix flake check) have no /usr/bin/env; point the
  -- shebang at the bash actually on PATH instead.
  text = text:gsub("^#!/usr/bin/env bash", "#!" .. vim.fn.exepath("bash"), 1)
  local f = assert(io.open(path, "w"))
  f:write(text)
  f:close()
  vim.fn.setfperm(path, "rwxr-xr-x")
end

-- Fake curl #1: scripted two-turn Anthropic SSE server. Turn 1 asks for a
-- real bash tool call; turn 2 streams text. Logs argv and request bodies.
write_exec(tmp .. "/scripted/curl", ([[#!/usr/bin/env bash
D=%q
N=$(cat "$D/n" 2>/dev/null || echo 0); N=$((N+1)); echo $N > "$D/n"
printf '%%s\n' "$*" >> "$D/argv"
cat > "$D/body.$N"
echo "STRAPS_HTTP_STATUS:200" >&2
if [ "$N" = 1 ]; then
cat <<'EOF'
event: message_start
data: {"type":"message_start","message":{"usage":{"input_tokens":1200,"cache_read_input_tokens":1100,"cache_creation_input_tokens":100}}}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"t1","name":"bash"}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"command\":\"echo provider-e2e-output\"}"}}

event: content_block_stop
data: {"type":"content_block_stop","index":0}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"tool_use"}}

event: message_stop
data: {"type":"message_stop"}
EOF
else
cat <<'EOF'
event: message_start
data: {"type":"message_start"}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"provider done"}}

event: content_block_stop
data: {"type":"content_block_stop","index":0}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}

event: message_stop
data: {"type":"message_stop"}
EOF
fi
]]):format(tmp))

-- Fake curl #2: accepts the request then goes silent, holding the
-- connection open. Only the watchdog can end this one.
write_exec(tmp .. "/stalling/curl", [[#!/usr/bin/env bash
cat > /dev/null
sleep 60
]])

-- Fake curl #3: single-turn server that streams a thinking block before its
-- text answer, exercising fn.provider's thinking/thinking_delta dispatch.
vim.fn.mkdir(tmp .. "/thinking", "p")
write_exec(tmp .. "/thinking/curl", ([[#!/usr/bin/env bash
D=%q
cat > "$D/thinking_body"
echo "STRAPS_HTTP_STATUS:200" >&2
cat <<'EOF'
event: message_start
data: {"type":"message_start"}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"pondering..."}}

event: content_block_stop
data: {"type":"content_block_stop","index":0}

event: content_block_start
data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}

event: content_block_delta
data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"thinking test done"}}

event: content_block_stop
data: {"type":"content_block_stop","index":1}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}

event: message_stop
data: {"type":"message_stop"}
EOF
]]):format(tmp))

local function run_session(user_text)
  local bufnr = state.new_session()
  state.append(bufnr, "user", nil, user_text)
  loop.start(bufnr)
  vim.wait(15000, function() return not loop.running(bufnr) end, 50)
  return bufnr, table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
end

-- ---------------------------------------------------------------- scripted
vim.env.PATH = tmp .. "/scripted:" .. real_path
straps.config.base_url = "http://straps-fake.invalid"
straps.config.log_file = tmp .. "/events.log"
straps.config.cache_ttl = "1h"
-- Alphabetically FIRST, registered LAST: proves build_tools uses
-- registration order (append-only, cache-stable), not names() order.
registry.define({ name = "tool.aaa_first_alphabetically", kind = "tool",
  doc = "ordering canary", source = [[return function() return "ok" end]] })
local bufnr, text = run_session("run echo via bash")

it("full tool round-trip through the real provider source", function()
  assert(text:find("provider-e2e-output", 1, true), "bash tool_result missing")
  assert(text:find('"name":"bash"', 1, true) or text:find('"bash"', 1, true), "tool_use block missing")
  assert(text:find("provider done", 1, true), "final streamed text missing")
  assert(not loop.running(bufnr), "run still active")
end)

it("config.base_url reaches curl", function()
  local argv = table.concat(vim.fn.readfile(tmp .. "/argv"), "\n")
  assert(argv:find("http://straps-fake.invalid/v1/messages", 1, true), "custom base_url not in argv:\n" .. argv)
end)

it("second request contains the tool_result", function()
  local body = table.concat(vim.fn.readfile(tmp .. "/body.2"), "\n")
  local decoded = vim.json.decode(body)
  local last = decoded.messages[#decoded.messages]
  assert(last.role == "user", "last message should be the tool_result user message")
  assert(last.content[1].type == "tool_result", "missing tool_result part")
  assert(last.content[1].content:find("provider-e2e-output", 1, true), "tool output not sent back")
end)

it("fn.log captures request/response and loop events", function()
  local lines = vim.fn.readfile(tmp .. "/events.log")
  assert(#lines > 0, "log file is empty")
  local seen, request, response = {}, nil, nil
  for _, line in ipairs(lines) do
    local ev = vim.json.decode(line) -- every line must be valid JSON
    assert(type(ev) == "table" and type(ev.ev) == "string", "malformed log line: " .. line)
    seen[ev.ev] = true
    if ev.ev == "request" and not request then request = ev end
    if ev.ev == "response" and ev.stop_reason == "end_turn" then response = ev end
  end
  for _, k in ipairs({ "run_start", "turn", "tool", "run_end" }) do
    assert(seen[k], "missing loop event in log: " .. k)
  end
  assert(request, "no request event logged")
  assert(type(request.bytes) == "number" and request.bytes > 0, "request event bytes not > 0")
  assert(request.model, "request event missing model")
  assert(response, "no response event with stop_reason end_turn")
  assert(response.ok == true, "response event ok is not true")
  assert(type(response.ms) == "number", "response event missing ms")
end)

it("cache breakpoints are in the request body", function()
  local body = table.concat(vim.fn.readfile(tmp .. "/body.1"), "\n")
  local decoded = vim.json.decode(body)
  assert(type(decoded.system) == "table", "system should be the array form when cache is on")
  assert(decoded.system[1] and type(decoded.system[1].cache_control) == "table"
    and decoded.system[1].cache_control.type == "ephemeral",
    "system[1] missing cache_control ephemeral")
  local last = decoded.messages[#decoded.messages]
  local lastblock = last.content[#last.content]
  assert(type(lastblock.cache_control) == "table" and lastblock.cache_control.type == "ephemeral",
    "last content block of last message missing cache_control")
  assert(type(decoded.tools) == "table" and #decoded.tools > 0, "tools missing from body")
  local lasttool = decoded.tools[#decoded.tools]
  assert(type(lasttool.cache_control) == "table" and lasttool.cache_control.type == "ephemeral",
    "last tool missing cache_control (tools-prefix breakpoint)")
  for i = 1, #decoded.tools - 1 do
    assert(decoded.tools[i].cache_control == nil, "cache_control leaked onto tool " .. i)
  end
end)

it("tools are sent in registration order, new tools appended last", function()
  local decoded = vim.json.decode(table.concat(vim.fn.readfile(tmp .. "/body.1"), "\n"))
  local names = {}
  for i, t in ipairs(decoded.tools) do names[i] = t.name end
  assert(names[#names] == "aaa_first_alphabetically",
    "late-registered tool should be LAST, got order: " .. table.concat(names, ","))
  assert(names[1] ~= "aaa_first_alphabetically", "tool list looks alphabetical")
end)

it("config.cache_ttl = 1h reaches all three breakpoints", function()
  local decoded = vim.json.decode(table.concat(vim.fn.readfile(tmp .. "/body.1"), "\n"))
  assert(decoded.system[1].cache_control.ttl == "1h", "system breakpoint missing ttl")
  assert(decoded.tools[#decoded.tools].cache_control.ttl == "1h", "tools breakpoint missing ttl")
  local last = decoded.messages[#decoded.messages]
  assert(last.content[#last.content].cache_control.ttl == "1h", "message breakpoint missing ttl")
end)

step(function()
  straps.config.cache_ttl = nil
  registry.remove("tool.aaa_first_alphabetically")
end)

it("response log event carries usage and cache counters", function()
  local resp
  for _, line in ipairs(vim.fn.readfile(tmp .. "/events.log")) do
    local ev = vim.json.decode(line)
    if ev.ev == "response" and ev.stop_reason == "tool_use" then resp = ev end
  end
  assert(resp, "no response event for the tool_use turn")
  assert(resp.input_tokens == 1200,
    "input_tokens is " .. tostring(resp.input_tokens) .. ", want 1200")
  assert(resp.cache_read_input_tokens == 1100,
    "cache_read_input_tokens is " .. tostring(resp.cache_read_input_tokens) .. ", want 1100")
  assert(resp.cache_creation_input_tokens == 100,
    "cache_creation_input_tokens is " .. tostring(resp.cache_creation_input_tokens) .. ", want 100")
end)

local _, text_nc
step(function()
  straps.config.log_file = nil

  -- ------------------------------------------------------------ cache = false
  -- Same scripted fake; reset its counter and body captures so the run replays
  -- turn 1 + turn 2 from scratch.
  vim.fn.delete(tmp .. "/n")
  vim.fn.delete(tmp .. "/body.1")
  vim.fn.delete(tmp .. "/body.2")
  straps.config.cache = false
  _, text_nc = run_session("run echo via bash, no caching")
end)

it("config.cache = false keeps the plain request shapes", function()
  assert(text_nc:find("provider done", 1, true), "cache=false run did not complete")
  local body = table.concat(vim.fn.readfile(tmp .. "/body.1"), "\n")
  local decoded = vim.json.decode(body)
  assert(type(decoded.system) == "string", "system should be a plain string when cache is off")
  assert(not body:find("cache_control", 1, true), "cache_control leaked into a cache=false request")
end)

local _, text_effort
step(function()
  straps.config.cache = true

  -- ----------------------------------------------------------------- effort
  -- Same scripted fake; reset counters/body captures again. config.model is
  -- still the default (claude-sonnet-5, tagged thinking="adaptive").
  vim.fn.delete(tmp .. "/n")
  vim.fn.delete(tmp .. "/body.1")
  vim.fn.delete(tmp .. "/body.2")
  straps.config.effort = "high"
  _, text_effort = run_session("run echo via bash, high effort")
end)

it("config.effort maps to output_config.effort for an adaptive-thinking model", function()
  assert(text_effort:find("provider done", 1, true), "high-effort run did not complete")
  local body = table.concat(vim.fn.readfile(tmp .. "/body.1"), "\n")
  local decoded = vim.json.decode(body)
  assert(type(decoded.thinking) == "table", "thinking block missing from request body")
  assert(decoded.thinking.type == "adaptive", "thinking.type is " .. tostring(decoded.thinking.type))
  assert(decoded.thinking.budget_tokens == nil,
    "adaptive thinking must not send budget_tokens, got " .. tostring(decoded.thinking.budget_tokens))
  assert(type(decoded.output_config) == "table", "output_config missing from request body")
  assert(decoded.output_config.effort == "high",
    "output_config.effort is " .. tostring(decoded.output_config.effort) .. ", want high")
end)

local _, text_budget
step(function()
  vim.fn.delete(tmp .. "/n")
  vim.fn.delete(tmp .. "/body.1")
  vim.fn.delete(tmp .. "/body.2")
  straps.config.model = "claude-haiku-4-5-20251001" -- tagged thinking="budget"
  straps.config.effort = "high"
  _, text_budget = run_session("run echo via bash, high effort, budget model")
end)

it("config.effort maps to thinking.budget_tokens for a budget-thinking model", function()
  assert(text_budget:find("provider done", 1, true), "budget-model high-effort run did not complete")
  local body = table.concat(vim.fn.readfile(tmp .. "/body.1"), "\n")
  local decoded = vim.json.decode(body)
  assert(type(decoded.thinking) == "table", "thinking block missing from request body")
  assert(decoded.thinking.type == "enabled", "thinking.type is " .. tostring(decoded.thinking.type))
  assert(decoded.thinking.budget_tokens == 24000,
    "thinking.budget_tokens is " .. tostring(decoded.thinking.budget_tokens) .. ", want 24000")
  assert(decoded.output_config == nil,
    "budget-thinking model must not send output_config.effort")
  assert(decoded.max_tokens > decoded.thinking.budget_tokens,
    "max_tokens (" .. tostring(decoded.max_tokens) .. ") must exceed budget_tokens")
end)

-- Budget-thinking bump when the resolved cap does NOT clear budget_tokens: an
-- explicit config.max_tokens below the budget is still bumped above it, because
-- the API rejects max_tokens <= budget_tokens (the one case an explicit cap
-- does not win). Without the bump the base cap (4096) would stay below 24000.
local _, text_bump
step(function()
  vim.fn.delete(tmp .. "/n")
  vim.fn.delete(tmp .. "/body.1")
  vim.fn.delete(tmp .. "/body.2")
  straps.config.model = "claude-haiku-4-5-20251001"
  straps.config.effort = "high"
  straps.config.max_tokens = 4096
  _, text_bump = run_session("run echo via bash, explicit cap below budget")
end)

it("an explicit max_tokens below budget_tokens is bumped above it", function()
  assert(text_bump:find("provider done", 1, true), "bump run did not complete")
  local decoded = vim.json.decode(table.concat(vim.fn.readfile(tmp .. "/body.1"), "\n"))
  assert(decoded.thinking.budget_tokens == 24000, "budget wrong: " .. tostring(decoded.thinking.budget_tokens))
  assert(decoded.max_tokens > decoded.thinking.budget_tokens,
    "explicit cap 4096 should be bumped above budget 24000, got " .. tostring(decoded.max_tokens))
end)

local _, text_off
step(function()
  straps.config.max_tokens = nil
  straps.config.effort = "off"
  straps.config.model = "claude-sonnet-5"

  vim.fn.delete(tmp .. "/n")
  vim.fn.delete(tmp .. "/body.1")
  vim.fn.delete(tmp .. "/body.2")
  straps.config.effort = "off"
  _, text_off = run_session("run echo via bash, effort off")
end)

it("config.effort = off sends no thinking block", function()
  assert(text_off:find("provider done", 1, true), "off-effort run did not complete")
  local body = table.concat(vim.fn.readfile(tmp .. "/body.1"), "\n")
  local decoded = vim.json.decode(body)
  assert(decoded.thinking == nil, "thinking block should be absent when effort is off")
  assert(decoded.output_config == nil, "output_config should be absent when effort is off")
end)

step(function()
  straps.config.effort = "off"
end)

-- ----------------------------------------------------------- max_tokens resolution
-- config.max_tokens defaults to nil = the active model's max_output (from its
-- config.models entry) else config.default_max_tokens. The scripted curl is on
-- PATH and effort is off (no thinking bump), so body.1's max_tokens is the pure
-- resolution. Save/restore the config knobs each case touches.
do
  local saved_mt
  local saved_dmt
  local saved_model
  step(function()
    saved_mt = straps.config.max_tokens
    saved_dmt = straps.config.default_max_tokens
    saved_model = straps.config.model
  end)

  local function req_max_tokens(user_text)
    vim.fn.delete(tmp .. "/n")
    vim.fn.delete(tmp .. "/body.1")
    vim.fn.delete(tmp .. "/body.2")
    local _, txt = run_session(user_text)
    assert(txt:find("provider done", 1, true), "run did not complete: " .. user_text)
    local body = table.concat(vim.fn.readfile(tmp .. "/body.1"), "\n")
    return vim.json.decode(body).max_tokens
  end

  step(function()
    straps.config.max_tokens = nil
    straps.config.default_max_tokens = 32000
    straps.config.model = "claude-sonnet-5" -- seed max_output = 128000
  end)

  it("nil max_tokens resolves to the model's max_output", function()
    assert(req_max_tokens("resolve for a listed model") == 128000,
      "listed model should send its max_output (128000)")
  end)

  it("explicit config.max_tokens wins over the model's max_output", function()
    straps.config.max_tokens = 4096
    local got = req_max_tokens("resolve with explicit cap")
    straps.config.max_tokens = nil
    assert(got == 4096, "explicit cap should win, got " .. tostring(got))
  end)

  it("an unlisted model falls back to default_max_tokens", function()
    straps.config.model = "claude-not-in-config"
    local got = req_max_tokens("resolve for an unlisted model")
    straps.config.model = "claude-sonnet-5"
    assert(got == 32000, "unlisted model should use default_max_tokens (32000), got " .. tostring(got))
  end)

  step(function()
    straps.config.max_tokens = saved_mt
    straps.config.default_max_tokens = saved_dmt
    straps.config.model = saved_model
  end)
end
local _, text_think
step(function()
  straps.config.effort = "off"

  -- --------------------------------------------------------------- thinking
  vim.env.PATH = tmp .. "/thinking:" .. real_path
  straps.config.effort = "medium"
  _, text_think = run_session("think about it")
end)

it("thinking_delta stays out of the transcript while visible text remains", function()
  assert(not text_think:find("pondering...", 1, true),
    "thinking_delta leaked into transcript:\n" .. text_think)
  assert(text_think:find("thinking test done", 1, true), "visible answer after thinking missing")
end)

local bp_buf
step(function()
  straps.config.effort = "off"
  vim.env.PATH = tmp .. "/scripted:" .. real_path

  -- ------------------------------------------------ 4th (intermediate) breakpoint
  -- A fresh single-turn fake that captures its request body, driven over a
  -- pre-seeded long, tool-heavy transcript so the provider places the trailing
  -- intermediate breakpoint that keeps busy turns inside the ~20-block lookback.
  vim.fn.mkdir(tmp .. "/bp", "p")
  write_exec(tmp .. "/bp/curl", ([[#!/usr/bin/env bash
D=%q
cat > "$D/bpbody"
echo "STRAPS_HTTP_STATUS:200" >&2
cat <<'EOF'
event: message_start
data: {"type":"message_start","message":{"usage":{}}}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ok"}}

event: content_block_stop
data: {"type":"content_block_stop","index":0}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}

event: message_stop
data: {"type":"message_stop"}
EOF
]]):format(tmp))

  vim.env.PATH = tmp .. "/bp:" .. real_path
  straps.config.cache = true
  straps.config.cache_ttl = nil
  straps.config.base_url = "http://straps-fake.invalid"

  bp_buf = state.new_session()
  state.append(bp_buf, "user", nil, "kick off a long tool-heavy session")
  for i = 1, 22 do -- 22 alternating rounds -> ~46 content blocks across many messages
    state.append(bp_buf, "tool_use", { id = "t" .. i, name = "noop" }, "{}")
    state.append(bp_buf, "tool_result", { id = "t" .. i, is_error = false }, "result " .. i)
  end
  state.append(bp_buf, "user", nil, "now answer")
  loop.start(bp_buf)
  vim.wait(15000, function() return not loop.running(bp_buf) end, 50)
end)

it("long conversations get a 4th intermediate breakpoint within lookback", function()
  local decoded = vim.json.decode(table.concat(vim.fn.readfile(tmp .. "/bpbody"), "\n"))
  local marked, total = {}, 0
  for mi, msg in ipairs(decoded.messages) do
    if type(msg.content) == "table" then
      for _, blk in ipairs(msg.content) do
        total = total + 1
        if type(blk.cache_control) == "table" then marked[#marked + 1] = mi end
      end
    end
  end
  assert(total > 20, "seed did not exceed 20 content blocks (" .. total .. ")")
  assert(#marked == 2, "expected 2 message breakpoints (intermediate + tail), got " .. #marked)
  assert(marked[1] < marked[2], "breakpoints out of order")
  assert(marked[2] == #decoded.messages, "tail breakpoint not on the last message")
  -- The intermediate must sit far enough back to bridge a >20-block turn:
  -- the provider accumulates >= 15 blocks (messages marked[1]..tail-1) before
  -- placing it.
  local bridge = 0
  for mi = marked[1], #decoded.messages - 1 do bridge = bridge + #decoded.messages[mi].content end
  assert(bridge >= 15, "intermediate breakpoint too close to tail: bridges " .. bridge .. " blocks")
end)

step(function()
  vim.env.PATH = real_path
  straps.config.base_url = nil

  -- --------------------------------------------- per-buffer model / effort
  -- fn.provider must read vim.b straps_model / straps_effort in preference to
  -- the global config, so two sessions can run different models. Reuse the bp
  -- fake (captures its request body to bpbody).
  vim.env.PATH = tmp .. "/bp:" .. real_path
  straps.config.base_url = "http://straps-fake.invalid"
end)
do
  -- Global points at Sonnet 5 / off; the buffer overrides to Fable 5 / medium.
  local saved_model, saved_effort, saved_models, saved_efforts
  local pb
  local body
  step(function()
    saved_model, saved_effort, saved_models, saved_efforts =
      straps.config.model, straps.config.effort, straps.config.models, straps.config.efforts
    straps.config.model = "claude-sonnet-5"
    straps.config.effort = "off"
    -- Both tagged adaptive so the per-buffer effort produces a thinking block.
    straps.config.models = {
      { id = "claude-sonnet-5", label = "Sonnet 5", thinking = "adaptive" },
      { id = "claude-fable-5", label = "Fable 5", thinking = "adaptive" },
    }
    straps.config.efforts = { { name = "medium", level = "medium" } }

    pb = state.new_session()
    vim.b[pb].straps_model = "claude-fable-5"
    vim.b[pb].straps_effort = "medium"
    state.append(pb, "user", nil, "use my per-buffer model")
    loop.start(pb)
    vim.wait(15000, function() return not loop.running(pb) end, 50)

    body = vim.json.decode(table.concat(vim.fn.readfile(tmp .. "/bpbody"), "\n"))
  end)

  it("fn.provider uses vim.b straps_model over config.model", function()
    assert(body.model == "claude-fable-5",
      "request model is " .. tostring(body.model) .. ", want the per-buffer claude-fable-5")
  end)

  it("fn.provider uses vim.b straps_effort (adaptive thinking from the buffer)", function()
    -- config.effort is "off" (no thinking); the per-buffer "medium" must win
    -- and, because fable-5 is tagged adaptive, produce the adaptive block.
    assert(type(body.thinking) == "table" and body.thinking.type == "adaptive",
      "expected an adaptive thinking block from the per-buffer effort, got "
        .. vim.inspect(body.thinking))
    assert(body.output_config and body.output_config.effort == "medium",
      "expected output_config.effort=medium, got " .. vim.inspect(body.output_config))
  end)

  step(function()
    straps.config.model, straps.config.effort, straps.config.models, straps.config.efforts =
      saved_model, saved_effort, saved_models, saved_efforts
  end)
end
local t0
local bufnr2, text2
local elapsed_ms
step(function()
  vim.env.PATH = real_path
  straps.config.base_url = nil

  -- ---------------------------------------------------------------- watchdog
  vim.env.PATH = tmp .. "/stalling:" .. real_path
  straps.config.request_timeout_ms = 400
  t0 = vim.uv.hrtime()
  bufnr2, text2 = run_session("this endpoint hangs")
  elapsed_ms = (vim.uv.hrtime() - t0) / 1e6
end)

it("idle watchdog kills a silent stream instead of hanging forever", function()
  assert(not loop.running(bufnr2), "run never finished — watchdog did not fire")
  assert(text2:find("stream stalled", 1, true), "missing stall explanation:\n" .. text2)
  assert(text2:find("request_timeout_ms", 1, true), "error should mention the config knob")
  assert(elapsed_ms < 10000, "took too long: " .. elapsed_ms .. "ms")
end)

local buf400, text400
step(function()
  vim.env.PATH = real_path
  straps.config.request_timeout_ms = nil
  straps.config.base_url = nil

  -- ------------------------------------------------------------- HTTP errors
  -- Fake curl #4: non-2xx with a JSON error body (the live tools.22 failure
  -- shape). The run must surface a READABLE error naming the status and the
  -- API's message, and end cleanly.
  vim.fn.mkdir(tmp .. "/err400", "p")
  write_exec(tmp .. "/err400/curl", [[#!/usr/bin/env bash
cat > /dev/null
echo "STRAPS_HTTP_STATUS:400" >&2
printf '%s' '{"type":"error","error":{"type":"invalid_request_error","message":"tools.22.custom.input_schema.properties: Input should be an object"}}'
]])

  vim.env.PATH = tmp .. "/err400:" .. real_path
  straps.config.base_url = "http://straps-fake.invalid"
  buf400, text400 = run_session("this request will 400")
end)

it("HTTP 400 surfaces the API's error message and ends the run cleanly", function()
  assert(not loop.running(buf400), "run still active after a 400")
  assert(text400:find("request failed (HTTP 400)", 1, true),
    "status missing from error:\n" .. text400:sub(-400))
  assert(text400:find("Input should be an object", 1, true),
    "API error message not surfaced:\n" .. text400:sub(-400))
end)

-- Fake curl #5: 429 once, then a normal 200 answer — the retry path.
local t429
local buf429, text429
local ms429
step(function()
  vim.fn.mkdir(tmp .. "/flaky", "p")
  write_exec(tmp .. "/flaky/curl", ([[#!/usr/bin/env bash
D=%q
N=$(cat "$D/flaky_n" 2>/dev/null || echo 0); N=$((N+1)); echo $N > "$D/flaky_n"
cat > /dev/null
if [ "$N" = 1 ]; then
  echo "STRAPS_HTTP_STATUS:429" >&2
  printf '%%s' '{"type":"error","error":{"type":"rate_limit_error","message":"slow down"}}'
  exit 0
fi
echo "STRAPS_HTTP_STATUS:200" >&2
cat <<'EOF'
event: message_start
data: {"type":"message_start"}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"survived the rate limit"}}

event: content_block_stop
data: {"type":"content_block_stop","index":0}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}

event: message_stop
data: {"type":"message_stop"}
EOF
]]):format(tmp))

  vim.env.PATH = tmp .. "/flaky:" .. real_path
  t429 = vim.uv.hrtime()
  buf429, text429 = run_session("rate limit me once")
  ms429 = (vim.uv.hrtime() - t429) / 1e6
end)

it("429 retries with backoff and the run completes", function()
  assert(text429:find("survived the rate limit", 1, true),
    "retry did not complete:\n" .. text429:sub(-400))
  local n = tonumber(vim.fn.readfile(tmp .. "/flaky_n")[1])
  assert(n == 2, "curl called " .. tostring(n) .. " times, want 2 (one retry)")
  assert(ms429 >= 900, "backoff skipped: only " .. math.floor(ms429) .. "ms elapsed")
  assert(not text429:find("request failed", 1, true), "retryable error leaked into the transcript")
end)

-- Fake curl #6: always 429 — exhaustion must surface, not loop forever.
local bufx, textx
step(function()
  vim.fn.mkdir(tmp .. "/always429", "p")
  write_exec(tmp .. "/always429/curl", ([[#!/usr/bin/env bash
D=%q
N=$(cat "$D/a429_n" 2>/dev/null || echo 0); N=$((N+1)); echo $N > "$D/a429_n"
cat > /dev/null
echo "STRAPS_HTTP_STATUS:429" >&2
printf '%%s' '{"type":"error","error":{"type":"rate_limit_error","message":"still rate limited"}}'
]]):format(tmp))

  vim.env.PATH = tmp .. "/always429:" .. real_path
  bufx, textx = run_session("rate limit me forever")
end)

it("persistent 429 exhausts retries with a readable error", function()
  assert(not loop.running(bufx), "run still active after exhausted retries")
  local n = tonumber(vim.fn.readfile(tmp .. "/a429_n")[1])
  assert(n == 3, "curl called " .. tostring(n) .. " times, want exactly 3 attempts")
  assert(textx:find("request failed (HTTP 429)", 1, true),
    "exhaustion error missing status:\n" .. textx:sub(-400))
  assert(textx:find("still rate limited", 1, true), "API message not surfaced")
end)

-- ------------------------------------------------- chunked multi-tool stream
-- Fake curl #7: one response carrying TWO tool_use blocks, streamed rudely —
-- the data line for block 0 is split mid-JSON across writes (line_buf
-- reassembly), and block 1's input arrives as two input_json_delta events.
-- Turn 2 answers in text. This drives the real SSE dispatch through the
-- batched-tools path end to end.
local bufc, textc
step(function()
  registry.define({ name = "tool.echo_tag", kind = "tool", doc = "echo the tag",
    source = [[return function(input) return "tag-" .. tostring(input.tag) end]] })
  vim.fn.mkdir(tmp .. "/chunky", "p")
  write_exec(tmp .. "/chunky/curl", ([[#!/usr/bin/env bash
D=%q
N=$(cat "$D/chunky_n" 2>/dev/null || echo 0); N=$((N+1)); echo $N > "$D/chunky_n"
cat > "$D/chunky_body.$N"
echo "STRAPS_HTTP_STATUS:200" >&2
if [ "$N" = 1 ]; then
  printf 'event: message_start\ndata: {"type":"message_start"}\n\n'
  printf 'event: content_block_start\ndata: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"c1","name":"echo_tag"}}\n\n'
  # block 0 input: ONE data line split across two writes, mid-JSON
  printf 'event: content_block_delta\ndata: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\"tag\\":\\"o'
  sleep 0.05
  printf 'ne\\"}"}}\n\n'
  printf 'event: content_block_stop\ndata: {"type":"content_block_stop","index":0}\n\n'
  printf 'event: content_block_start\ndata: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"c2","name":"echo_tag"}}\n\n'
  # block 1 input: two separate delta EVENTS
  printf 'event: content_block_delta\ndata: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\"tag\\":\\"tw"}}\n\n'
  sleep 0.05
  printf 'event: content_block_delta\ndata: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"o\\"}"}}\n\n'
  printf 'event: content_block_stop\ndata: {"type":"content_block_stop","index":1}\n\n'
  printf 'event: message_delta\ndata: {"type":"message_delta","delta":{"stop_reason":"tool_use"}}\n\n'
  printf 'event: message_stop\ndata: {"type":"message_stop"}\n\n'
else
  printf 'event: message_start\ndata: {"type":"message_start"}\n\n'
  printf 'event: content_block_start\ndata: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}\n\n'
  printf 'event: content_block_delta\ndata: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"chunked done"}}\n\n'
  printf 'event: content_block_stop\ndata: {"type":"content_block_stop","index":0}\n\n'
  printf 'event: message_delta\ndata: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}\n\n'
  printf 'event: message_stop\ndata: {"type":"message_stop"}\n\n'
fi
]]):format(tmp))

  vim.env.PATH = tmp .. "/chunky:" .. real_path
  bufc, textc = run_session("stream me two tools, rudely chunked")
end)

it("split SSE chunks reassemble; a two-tool stream batches end to end", function()
  assert(textc:find("tag-one", 1, true), "block 0 (split data line) input lost:\n" .. textc:sub(-500))
  assert(textc:find("tag-two", 1, true), "block 1 (split delta events) input lost")
  assert(textc:find("chunked done", 1, true), "follow-up turn missing")
  -- Batch shape survives the REAL SSE path: one assistant message carries
  -- both tool_use blocks in the replayed request.
  local body2 = vim.json.decode(table.concat(vim.fn.readfile(tmp .. "/chunky_body.2"), "\n"))
  local batch
  for _, m in ipairs(body2.messages) do
    if m.role == "assistant" then
      local uses = {}
      for _, p in ipairs(m.content) do
        if p.type == "tool_use" then uses[#uses + 1] = p end
      end
      if #uses > 0 then batch = uses end
    end
  end
  assert(batch and #batch == 2, "expected one assistant message with 2 tool_use blocks")
  assert(batch[1].id == "c1" and batch[2].id == "c2", "tool_use order lost")
  assert(batch[1].input.tag == "one" and batch[2].input.tag == "two",
    "reassembled inputs wrong: " .. vim.inspect({ batch[1].input, batch[2].input }))
end)

local saved_key
local saved_xdg
local keydir
step(function()
  registry.remove("tool.echo_tag")
  vim.env.PATH = real_path
  straps.config.base_url = nil

  -- --------------------------------------------------------------- fn.api_key
  -- Sourcing order: $ANTHROPIC_API_KEY first, then the first line of
  -- $XDG_CONFIG_HOME/straps/api_key, else a readable error naming both.
  saved_key = vim.env.ANTHROPIC_API_KEY
  saved_xdg = vim.env.XDG_CONFIG_HOME
  keydir = vim.fn.tempname()
  vim.fn.mkdir(keydir .. "/straps", "p")
  vim.env.XDG_CONFIG_HOME = keydir
end)

-- The file fallback refuses group/other-accessible key files, and writefile's
-- mode depends on the umask — pin every key file the tests expect to be read.
local function write_key_file(kf, lines)
  vim.fn.writefile(lines, kf)
  vim.fn.setfperm(kf, "rw-------")
end

it("fn.api_key: env var wins over the config file", function()
  write_key_file(keydir .. "/straps/api_key", { "file-key" })
  vim.env.ANTHROPIC_API_KEY = "env-key"
  assert(registry.call("fn.api_key") == "env-key", "env var should take precedence over the file")
end)

it("fn.api_key: falls back to $XDG_CONFIG_HOME/straps/api_key, trimmed", function()
  write_key_file(keydir .. "/straps/api_key", { "  file-key  " })
  vim.env.ANTHROPIC_API_KEY = nil
  local got = registry.call("fn.api_key")
  assert(got == "file-key", "file fallback wrong: " .. vim.inspect(got))
end)

it("fn.api_key: a group/other-accessible key file is refused", function()
  local kf = keydir .. "/straps/api_key"
  vim.fn.writefile({ "leaky-key" }, kf)
  vim.fn.setfperm(kf, "rw-r--r--")
  vim.env.ANTHROPIC_API_KEY = nil
  local ok, err = pcall(registry.call, "fn.api_key")
  assert(not ok, "expected an error for a group-readable key file")
  assert(tostring(err):find("chmod 600", 1, true), "error should say how to fix it: " .. tostring(err))
  assert(not tostring(err):find("leaky-key", 1, true), "the key itself must not appear in the error")
end)

it("fn.api_key: an unreadable key file gets its own error, not the generic one", function()
  local kf = keydir .. "/straps/api_key"
  vim.fn.writefile({ "unreachable-key" }, kf)
  vim.fn.setfperm(kf, "---------")
  vim.env.ANTHROPIC_API_KEY = nil
  local ok, err = pcall(registry.call, "fn.api_key")
  vim.fn.setfperm(kf, "rw-------") -- so later cases can delete/rewrite it
  assert(not ok, "expected an error for an unreadable key file")
  assert(tostring(err):find("could not be read", 1, true),
    "unreadable file should not fall through to the generic error: " .. tostring(err))
end)

it("fn.api_key: a present-but-blank key file still errors", function()
  write_key_file(keydir .. "/straps/api_key", { "   " })
  vim.env.ANTHROPIC_API_KEY = nil
  local ok, err = pcall(registry.call, "fn.api_key")
  assert(not ok, "expected an error for a whitespace-only key file")
  assert(tostring(err):find("no API key found", 1, true), "wrong error: " .. tostring(err))
end)

it("fn.api_key: no env var and no file errors naming the file path", function()
  vim.fn.delete(keydir .. "/straps/api_key")
  vim.env.ANTHROPIC_API_KEY = nil
  local ok, err = pcall(registry.call, "fn.api_key")
  assert(not ok, "expected an error when no key source is available")
  assert(tostring(err):find(keydir .. "/straps/api_key", 1, true),
    "error should name the fallback file path: " .. tostring(err))
end)

it("fn.api_key: falls back to $HOME/.config when XDG_CONFIG_HOME is unset", function()
  vim.fn.mkdir(keydir .. "/.config/straps", "p")
  write_key_file(keydir .. "/.config/straps/api_key", { "home-key" })
  local saved_home = vim.env.HOME
  vim.env.XDG_CONFIG_HOME = nil
  vim.env.HOME = keydir
  vim.env.ANTHROPIC_API_KEY = nil
  local ok, got = pcall(registry.call, "fn.api_key")
  vim.env.HOME = saved_home
  vim.env.XDG_CONFIG_HOME = keydir
  assert(ok and got == "home-key", "HOME fallback wrong: " .. vim.inspect(got))
end)

it("fn.api_key: XDG_CONFIG_HOME and HOME both unset errors with the generic path", function()
  local saved_home = vim.env.HOME
  vim.env.XDG_CONFIG_HOME = nil
  vim.env.HOME = nil
  vim.env.ANTHROPIC_API_KEY = nil
  local ok, err = pcall(registry.call, "fn.api_key")
  vim.env.HOME = saved_home
  vim.env.XDG_CONFIG_HOME = keydir
  assert(not ok, "expected an error with no key source at all")
  assert(tostring(err):find("$XDG_CONFIG_HOME/straps/api_key", 1, true),
    "error should show the generic path: " .. tostring(err))
end)

step(function()
  vim.env.ANTHROPIC_API_KEY = saved_key
  vim.env.XDG_CONFIG_HOME = saved_xdg

  -- ---------------------------------------------------------------- list_models
  -- Fake curl serving a /v1/models catalog, so fn.list_models runs end-to-end
  -- (real source, faked HTTP) and the thinking-tag inference is exercised.
  vim.fn.mkdir(tmp .. "/models", "p")
  write_exec(tmp .. "/models/curl", ([[#!/usr/bin/env bash
D=%q
printf '%%s\n' "$*" >> "$D/models_argv"
cat <<'EOF'
{"data":[
  {"type":"model","id":"claude-sonnet-5","display_name":"Claude Sonnet 5","max_tokens":128000,"max_input_tokens":1000000,
   "capabilities":{"thinking":{"supported":true,"types":{"enabled":{"supported":false},"adaptive":{"supported":true}}}}},
  {"type":"model","id":"claude-fable-5","display_name":"Claude Fable 5","max_tokens":128000,"max_input_tokens":1000000,
   "capabilities":{"thinking":{"supported":true,"types":{"enabled":{"supported":false},"adaptive":{"supported":true}}}}},
  {"type":"model","id":"claude-haiku-4-5-20251001","display_name":"Claude Haiku 4.5","max_tokens":64000,"max_input_tokens":200000,
   "capabilities":{"thinking":{"supported":true,"types":{"enabled":{"supported":true},"adaptive":{"supported":false}}}}},
  {"type":"model","id":"claude-legacy-0","display_name":"Legacy",
   "capabilities":{"thinking":{"supported":false}}}
], "has_more": false}
EOF
printf '\nSTRAPS_HTTP_STATUS:200\n'
]]):format(tmp))
end)

do
  local saved_path
  local saved_base
  local saved_provider
  local models, err
  step(function()
    saved_path = vim.env.PATH
    saved_base = straps.config.base_url
    saved_provider = straps.config.provider
    vim.env.PATH = tmp .. "/models:" .. real_path
    vim.env.ANTHROPIC_API_KEY = "test-key-not-real"
    straps.config.base_url = "http://straps-models.invalid"
    -- Pin Anthropic: discovery now follows the effective provider, and the host
    -- running the tests may have a persisted openai preference or config.
    straps.config.provider = "anthropic"

    models, err = registry.call("fn.list_models")
  end)

  it("fn.list_models hits base_url/v1/models", function()
    local argv = table.concat(vim.fn.readfile(tmp .. "/models_argv"), "\n")
    assert(argv:find("http://straps-models.invalid/v1/models", 1, true),
      "custom base_url /v1/models not in argv:\n" .. argv)
  end)

  it("fn.list_models parses the catalog", function()
    assert(type(models) == "table", "expected a model list, got err: " .. tostring(err))
    assert(#models == 4, "expected 4 models, got " .. #models)
    assert(models[1].id == "claude-sonnet-5", "first id wrong: " .. tostring(models[1].id))
    assert(models[1].label == "Claude Sonnet 5", "label should be display_name")
  end)

  it("fn.list_models infers the thinking tag from capabilities", function()
    local by = {}
    for _, m in ipairs(models) do by[m.id] = m end
    assert(by["claude-sonnet-5"].thinking == "adaptive", "adaptive not inferred")
    assert(by["claude-fable-5"].thinking == "adaptive", "fable adaptive not inferred")
    assert(by["claude-haiku-4-5-20251001"].thinking == "budget", "enabled->budget not inferred")
    assert(by["claude-legacy-0"].thinking == nil, "no-thinking model should get nil tag")
  end)

  it("fn.list_models maps max_tokens->max_output and max_input_tokens->context", function()
    local by = {}
    for _, m in ipairs(models) do by[m.id] = m end
    assert(by["claude-sonnet-5"].max_output == 128000,
      "sonnet-5 max_output wrong: " .. tostring(by["claude-sonnet-5"].max_output))
    assert(by["claude-sonnet-5"].context == 1000000,
      "sonnet-5 context wrong: " .. tostring(by["claude-sonnet-5"].context))
    assert(by["claude-haiku-4-5-20251001"].max_output == 64000,
      "haiku max_output wrong: " .. tostring(by["claude-haiku-4-5-20251001"].max_output))
    assert(by["claude-legacy-0"].max_output == nil,
      "a catalog entry without max_tokens should leave max_output nil")
  end)

  step(function()
    vim.env.PATH = saved_path
    straps.config.base_url = saved_base
    straps.config.provider = saved_provider
  end)
end

it("fn.list_models returns (nil, err) on HTTP failure, never throws", function()
  vim.fn.mkdir(tmp .. "/models_500", "p")
  write_exec(tmp .. "/models_500/curl", [[#!/usr/bin/env bash
printf '%s\nSTRAPS_HTTP_STATUS:401\n' '{"error":{"message":"bad key"}}'
]])
  local saved_path = vim.env.PATH
  local saved_provider = straps.config.provider
  vim.env.PATH = tmp .. "/models_500:" .. real_path
  vim.env.ANTHROPIC_API_KEY = "test-key-not-real"
  straps.config.provider = "anthropic"
  local models, err = registry.call("fn.list_models")
  vim.env.PATH = saved_path
  straps.config.provider = saved_provider
  assert(models == nil, "HTTP 401 should yield nil, got a list")
  assert(type(err) == "string" and err:find("401", 1, true), "err should mention the status: " .. tostring(err))
end)

-- Provider-aware discovery: with provider="openai", fn.list_models must hit
-- the OpenAI /v1/models endpoint with Bearer auth and parse OpenAI's flat
-- {data:[{id}]} shape (no display_name / thinking capabilities).
step(function()
  vim.fn.mkdir(tmp .. "/models_openai", "p")
  write_exec(tmp .. "/models_openai/curl", ([[#!/usr/bin/env bash
D=%q
printf '%%s\n' "$*" >> "$D/models_openai_argv"
cat <<'EOF'
{"object":"list","data":[
  {"id":"gpt-5","object":"model","owned_by":"openai"},
  {"id":"gpt-5-mini","object":"model","owned_by":"openai"}
]}
EOF
printf '\nSTRAPS_HTTP_STATUS:200\n'
]]):format(tmp))
end)

do
  local saved_path
  local saved_provider
  local saved_oai_base
  local saved_oai_key
  local models, err
  step(function()
    saved_path = vim.env.PATH
    saved_provider = straps.config.provider
    saved_oai_base = straps.config.openai_base_url
    saved_oai_key = vim.env.OPENAI_API_KEY
    vim.env.PATH = tmp .. "/models_openai:" .. real_path
    straps.config.provider = "openai"
    straps.config.openai_base_url = "http://straps-openai-models.invalid"
    vim.env.OPENAI_API_KEY = "openai-test-key"

    models, err = registry.call("fn.list_models")
  end)

  it("fn.list_models explicit provider arg overrides config/provider pref", function()
    straps.config.provider = "anthropic"
    local forced = registry.call("fn.list_models", "openai")
    assert(type(forced) == "table" and forced[1].id == "gpt-5",
      "explicit openai provider did not return OpenAI models: " .. vim.inspect(forced))
  end)

  it("fn.list_models (openai) hits openai_base_url/v1/models with Bearer auth", function()
    local argv = table.concat(vim.fn.readfile(tmp .. "/models_openai_argv"), "\n")
    assert(argv:find("http://straps-openai-models.invalid/v1/models", 1, true),
      "openai base_url /v1/models not in argv:\n" .. argv)
    assert(argv:find("Authorization: Bearer openai-test-key", 1, true),
      "Bearer auth header missing:\n" .. argv)
    assert(not argv:find("anthropic-version", 1, true), "anthropic header leaked into openai request")
  end)

  it("fn.list_models (openai) parses OpenAI's flat catalog, id doubles as label, no thinking", function()
    assert(type(models) == "table", "expected a model list, got err: " .. tostring(err))
    assert(#models == 2, "expected 2 models, got " .. #models)
    assert(models[1].id == "gpt-5" and models[1].label == "gpt-5", "id/label wrong: " .. vim.inspect(models[1]))
    assert(models[1].thinking == nil, "openai models carry no thinking tag")
  end)

  step(function()
    vim.env.PATH = saved_path
    straps.config.provider = saved_provider
    straps.config.openai_base_url = saved_oai_base
    vim.env.OPENAI_API_KEY = saved_oai_key
  end)
end

step(function()
  vim.env.ANTHROPIC_API_KEY = saved_key

  -- ------------------------------------------------------------ openai backend
  -- Fake curl serving OpenAI Chat Completions SSE. Turn 1 streams a tool_call
  -- (echo via bash), turn 2 streams text. Captures argv + request bodies so we
  -- can assert the translated OpenAI wire shape and the Bearer auth header.
  vim.fn.mkdir(tmp .. "/openai", "p")
  write_exec(tmp .. "/openai/curl", ([[#!/usr/bin/env bash
D=%q
N=$(cat "$D/oai_n" 2>/dev/null || echo 0); N=$((N+1)); echo $N > "$D/oai_n"
printf '%%s\n' "$*" >> "$D/oai_argv"
cat > "$D/oai_body.$N"
echo "STRAPS_HTTP_STATUS:200" >&2
if [ "$N" = 1 ]; then
  printf 'data: {"choices":[{"index":0,"delta":{"role":"assistant","tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"bash","arguments":""}}]}}]}\n\n'
  printf 'data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"command\\":\\"echo "}}]}}]}\n\n'
  printf 'data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"openai-e2e-output\\"}"}}]}}]}\n\n'
  printf 'data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}\n\n'
  printf 'data: {"choices":[],"usage":{"prompt_tokens":1200,"completion_tokens":20,"prompt_tokens_details":{"cached_tokens":1100}}}\n\n'
  printf 'data: [DONE]\n\n'
else
  printf 'data: {"choices":[{"index":0,"delta":{"role":"assistant","content":"openai "}}]}\n\n'
  printf 'data: {"choices":[{"index":0,"delta":{"content":"done"}}]}\n\n'
  printf 'data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\n'
  printf 'data: {"choices":[],"usage":{"prompt_tokens":50,"completion_tokens":5}}\n\n'
  printf 'data: [DONE]\n\n'
fi
]]):format(tmp))
end)

do
  local saved_provider
  local saved_oai_base
  local oai_buf, oai_text
  local initial_oai_n
  step(function()
    saved_provider = straps.config.provider
    saved_oai_base = straps.config.openai_base_url
    vim.env.PATH = tmp .. "/openai:" .. real_path
    vim.env.OPENAI_API_KEY = "openai-test-key"
    straps.config.provider = "openai"
    straps.config.openai_base_url = "http://straps-openai.invalid"
    straps.config.openai_model = "gpt-5-test"

    oai_buf, oai_text = run_session("run echo via bash on openai")
    initial_oai_n = tonumber((vim.fn.readfile(tmp .. "/oai_n")[1] or "0"))
  end)
  local function read_oai_body(n)
    return vim.json.decode(table.concat(vim.fn.readfile(tmp .. ("/oai_body.%d"):format(n)), "\n"))
  end
  local function read_latest_oai_body()
    return read_oai_body(tonumber((vim.fn.readfile(tmp .. "/oai_n")[1] or "0")))
  end
  it("openai backend: full tool round-trip completes", function()
    assert(oai_text:find("openai-e2e-output", 1, true), "bash tool_result missing:\n" .. oai_text:sub(-500))
    assert(oai_text:find("openai done", 1, true), "final streamed text missing")
    assert(not loop.running(oai_buf), "run still active")
  end)

  it("openai backend: hits base_url/v1/chat/completions with Bearer auth", function()
    local argv = table.concat(vim.fn.readfile(tmp .. "/oai_argv"), "\n")
    assert(argv:find("http://straps-openai.invalid/v1/chat/completions", 1, true),
      "custom openai base_url not in argv:\n" .. argv)
    assert(argv:find("Authorization: Bearer openai-test-key", 1, true),
      "Bearer auth header missing:\n" .. argv)
  end)

  it("openai backend: request 1 is translated OpenAI shape (system + tools + model)", function()
    local body = read_oai_body(initial_oai_n - 1)
    assert(body.model == "gpt-5-test", "model wrong: " .. tostring(body.model))
    assert(body.stream == true, "stream should be true")
    assert(body.reasoning_effort == nil,
      "untagged OpenAI model must not receive reasoning_effort: " .. tostring(body.reasoning_effort))
    assert(body.messages[1].role == "system", "first message should be the system role")
    assert(body.messages[2].role == "user", "user message missing")
    assert(type(body.tools) == "table" and #body.tools > 0, "tools missing")
    local t1 = body.tools[1]
    assert(t1.type == "function" and type(t1["function"]) == "table"
      and type(t1["function"].name) == "string", "tool not in OpenAI function shape")
    assert(type(t1["function"].parameters) == "table", "tool parameters missing")
  end)

  it("openai backend: request 2 carries the tool_call + tool result messages", function()
    local body = read_oai_body(initial_oai_n)
    local assistant_tc, tool_msg
    for _, m in ipairs(body.messages) do
      if m.role == "assistant" and type(m.tool_calls) == "table" then assistant_tc = m end
      if m.role == "tool" then tool_msg = m end
    end
    assert(assistant_tc, "assistant tool_calls message missing")
    assert(assistant_tc.tool_calls[1]["function"].name == "bash", "tool_call name lost")
    local args = vim.json.decode(assistant_tc.tool_calls[1]["function"].arguments)
    assert(args.command and args.command:find("openai-e2e-output", 1, true),
      "tool_call arguments not a JSON string round-trip: " .. vim.inspect(args))
    assert(tool_msg, "role=tool result message missing")
    assert(tool_msg.tool_call_id == "call_1", "tool_call_id not threaded back")
    assert(tostring(tool_msg.content):find("openai-e2e-output", 1, true),
      "tool output not sent back in the tool message")
  end)

  it("openai backend: per-buffer OpenAI model slot wins over config.openai_model", function()
    vim.b[oai_buf].straps_openai_model = "gpt-5-mini-session"
    state.append_text(oai_buf, "run with a session-specific OpenAI model")
    loop.start(oai_buf)
    vim.wait(15000, function() return not loop.running(oai_buf) end, 50)
    local body = read_latest_oai_body()
    assert(body.model == "gpt-5-mini-session", "per-buffer OpenAI model ignored: " .. tostring(body.model))
  end)

  it("openai backend: tool-bearing requests suppress reasoning_effort", function()
    local saved_effort, saved_efforts, saved_openai_models =
      straps.config.effort, straps.config.efforts, straps.config.openai_models
    straps.config.effort = "high"
    straps.config.efforts = { { name = "high", level = "high" } }
    straps.config.openai_models = {
      { id = "gpt-5-mini-session", label = "GPT-5 mini", reasoning = true },
    }
    local ok, err = pcall(function()
      vim.b[oai_buf].straps_openai_model = "gpt-5-mini-session"
      state.append_text(oai_buf, "run with OpenAI reasoning effort and tools")
      loop.start(oai_buf)
      vim.wait(15000, function() return not loop.running(oai_buf) end, 50)
      local body = read_latest_oai_body()
      assert(body.model == "gpt-5-mini-session", "reasoning test model wrong: " .. tostring(body.model))
      assert(type(body.tools) == "table" and #body.tools > 0, "tools should be present")
      assert(body.reasoning_effort == nil,
        "tool-bearing OpenAI requests must not receive reasoning_effort: " .. tostring(body.reasoning_effort))
    end)
    straps.config.effort, straps.config.efforts, straps.config.openai_models =
      saved_effort, saved_efforts, saved_openai_models
    if not ok then error(err, 0) end
  end)

  it("openai backend: reasoning_effort is sent for opted-in model without tools", function()
    local saved_effort, saved_efforts, saved_openai_models =
      straps.config.effort, straps.config.efforts, straps.config.openai_models
    local saved_build_tools = registry.get("fn.build_tools").source
    straps.config.effort = "high"
    straps.config.efforts = { { name = "high", level = "high" } }
    straps.config.openai_models = {
      { id = "gpt-5-mini-session", label = "GPT-5 mini", reasoning = true },
    }
    registry.define({ name = "fn.build_tools", kind = "fn", doc = "test: no tools",
      source = [[return function() return {} end]] })
    local ok, err = pcall(function()
      vim.b[oai_buf].straps_openai_model = "gpt-5-mini-session"
      state.append_text(oai_buf, "run with OpenAI reasoning effort and no tools")
      loop.start(oai_buf)
      vim.wait(15000, function() return not loop.running(oai_buf) end, 50)
      local body = read_latest_oai_body()
      assert(body.model == "gpt-5-mini-session", "reasoning test model wrong: " .. tostring(body.model))
      assert(body.tools == nil, "empty tool list should be omitted, got: " .. vim.inspect(body.tools))
      assert(body.reasoning_effort == "high",
        "opted-in OpenAI model without tools should receive reasoning_effort=high, got "
          .. tostring(body.reasoning_effort))
    end)
    registry.define({ name = "fn.build_tools", kind = "fn", doc = "restored", source = saved_build_tools })
    straps.config.effort, straps.config.efforts, straps.config.openai_models =
      saved_effort, saved_efforts, saved_openai_models
    if not ok then error(err, 0) end
  end)

  it("openai backend: unset openai_model does not fall through to the Claude default", function()
    vim.b[oai_buf].straps_openai_model = nil
    straps.config.openai_model = nil
    straps.config.model = "claude-sonnet-5"
    state.append_text(oai_buf, "one more openai turn for model fallback")
    loop.start(oai_buf)
    vim.wait(15000, function() return not loop.running(oai_buf) end, 50)
    local body = read_latest_oai_body()
    assert(body.model == "gpt-5", "OpenAI fallback model should be gpt-5, got " .. tostring(body.model))
  end)

  step(function()
    straps.config.provider = saved_provider
    straps.config.openai_base_url = saved_oai_base
    straps.config.openai_model = nil
    vim.env.PATH = real_path
    vim.env.OPENAI_API_KEY = nil
  end)
end

-- ---------------------------------------------------- provider dispatch pref
-- fn.provider_pref round-trips the persisted choice, and the dispatcher's
-- precedence is: vim.b straps_provider > config.provider > file > "anthropic".
do
  local saved_xdg
  local saved_provider
  local pd
  step(function()
    saved_xdg = vim.env.XDG_CONFIG_HOME
    saved_provider = straps.config.provider
    pd = vim.fn.tempname()
    vim.fn.mkdir(pd, "p")
    vim.env.XDG_CONFIG_HOME = pd
  end)

  it("fn.provider_pref: read returns nil when no file exists", function()
    straps.config.provider = nil
    assert(registry.call("fn.provider_pref") == nil, "expected nil with no file")
  end)

  it("fn.provider_pref: write then read round-trips", function()
    local w = registry.call("fn.provider_pref", "openai")
    assert(w == "openai", "write should return the value")
    assert(registry.call("fn.provider_pref") == "openai", "read-back wrong")
    assert(vim.trim(vim.fn.readfile(pd .. "/straps/provider")[1]) == "openai", "file content wrong")
  end)

  -- Snapshot the real backend sources so we can restore them after spying.
  local real_anthropic
  local real_openai
  step(function()
    real_anthropic = registry.get("fn.provider_anthropic").source
    real_openai = registry.get("fn.provider_openai").source
  end)

  it("dispatcher: config.provider overrides the persisted file", function()
    -- File says openai; config pins anthropic -> anthropic wins.
    registry.call("fn.provider_pref", "openai")
    straps.config.provider = "anthropic"
    local picked
    registry.define({ name = "fn.provider_anthropic", kind = "fn", doc = "spy",
      source = [[return function() return { content = {}, stop_reason = "end_turn", _who = "a" } end]] })
    registry.define({ name = "fn.provider_openai", kind = "fn", doc = "spy",
      source = [[return function() return { content = {}, stop_reason = "end_turn", _who = "o" } end]] })
    local resp = registry.call("fn.provider", { messages = {} }, { bufnr = nil })
    picked = resp._who
    assert(picked == "a", "config anthropic should win over file openai, got " .. tostring(picked))
  end)

  it("dispatcher: falls back to the file when config.provider is nil", function()
    registry.call("fn.provider_pref", "openai")
    straps.config.provider = nil
    local resp = registry.call("fn.provider", { messages = {} }, { bufnr = nil })
    assert(resp._who == "o", "file openai should be used when config is nil, got " .. tostring(resp._who))
  end)

  it("dispatcher: no config and no file -> anthropic", function()
    vim.fn.delete(pd .. "/straps/provider")
    straps.config.provider = nil
    local resp = registry.call("fn.provider", { messages = {} }, { bufnr = nil })
    assert(resp._who == "a", "default should be anthropic, got " .. tostring(resp._who))
  end)

  -- Restore the real backends the rest of the suite (and any later run) needs.
  step(function()
    registry.define({ name = "fn.provider_anthropic", kind = "fn",
      doc = "restored", source = real_anthropic })
    registry.define({ name = "fn.provider_openai", kind = "fn",
      doc = "restored", source = real_openai })
    vim.env.XDG_CONFIG_HOME = saved_xdg
    straps.config.provider = saved_provider
  end)
end

-- ---------------------------------------------------------- fn.openai_api_key
do
  local saved_oai
  local saved_xdg2
  local kd
  step(function()
    saved_oai = vim.env.OPENAI_API_KEY
    saved_xdg2 = vim.env.XDG_CONFIG_HOME
    kd = vim.fn.tempname()
    vim.fn.mkdir(kd .. "/straps", "p")
    vim.env.XDG_CONFIG_HOME = kd
  end)

  it("fn.openai_api_key: env var wins over the config file", function()
    vim.fn.writefile({ "file-oai" }, kd .. "/straps/openai_api_key")
    vim.fn.setfperm(kd .. "/straps/openai_api_key", "rw-------")
    vim.env.OPENAI_API_KEY = "env-oai"
    assert(registry.call("fn.openai_api_key") == "env-oai", "env var should take precedence")
  end)

  it("fn.openai_api_key: falls back to the config file, trimmed", function()
    vim.fn.writefile({ "  file-oai  " }, kd .. "/straps/openai_api_key")
    vim.fn.setfperm(kd .. "/straps/openai_api_key", "rw-------")
    vim.env.OPENAI_API_KEY = nil
    assert(registry.call("fn.openai_api_key") == "file-oai", "file fallback wrong")
  end)

  it("fn.openai_api_key: a group/other-accessible key file is refused", function()
    vim.fn.writefile({ "leaky-oai" }, kd .. "/straps/openai_api_key")
    vim.fn.setfperm(kd .. "/straps/openai_api_key", "rw-r--r--")
    vim.env.OPENAI_API_KEY = nil
    local ok, err = pcall(registry.call, "fn.openai_api_key")
    assert(not ok and tostring(err):find("chmod 600", 1, true), "should refuse leaky file: " .. tostring(err))
    assert(not tostring(err):find("leaky-oai", 1, true), "key must not leak into the error")
  end)

  it("fn.openai_api_key: no env and no file errors naming OPENAI_API_KEY", function()
    vim.fn.delete(kd .. "/straps/openai_api_key")
    vim.env.OPENAI_API_KEY = nil
    local ok, err = pcall(registry.call, "fn.openai_api_key")
    assert(not ok and tostring(err):find("OPENAI_API_KEY", 1, true), "wrong error: " .. tostring(err))
  end)

  step(function()
    vim.env.OPENAI_API_KEY = saved_oai
    vim.env.XDG_CONFIG_HOME = saved_xdg2
  end)
end
