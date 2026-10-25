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
-- Hermetic config dir: a real ~/.config/straps provider or model_<provider>
-- pref file would change which provider and model the requests use.
vim.env.XDG_CONFIG_HOME = vim.fn.tempname()
vim.fn.mkdir(vim.env.XDG_CONFIG_HOME, "p")
local straps = require("straps").setup({})
-- Hermetic: durable sessions write under a throwaway dir, never the real data dir.
straps.config.session_dir = vim.fn.tempname()
-- Hermetic backend: this suite exercises the Anthropic SSE path via run_session;
-- pin the provider so a developer's persisted ~/.config/straps/provider (which
-- fn.provider would otherwise consult) can't route these turns to OpenAI. The
-- OpenAI-specific sections set config.provider = "openai" locally and restore it.
straps.config.provider = "anthropic"
-- The fake curls below capture the request body with `cat > file` and the
-- tests json-decode it, so request compression stays off here; the gz
-- fixture further down turns it on for its own step and restores it.
straps.config.gzip = false
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

step(function()
  straps.config.effort = "off"
  run_session("bad bytes ab\226\148 end")
end)

it("invalid UTF-8 in the transcript reaches curl scrubbed to U+FFFD", function()
  local f = assert(io.open(tmp .. "/thinking_body", "rb"))
  local body = f:read("*a")
  f:close()
  local rest = body:gsub("[\194-\223][\128-\191]", ""):gsub("[\224-\239][\128-\191][\128-\191]", "")
    :gsub("[\240-\244][\128-\191][\128-\191][\128-\191]", "")
  assert(not rest:find("[\128-\255]"), "request body contains invalid UTF-8")
  assert(body:find("bad bytes ab\239\191\189\239\191\189 end", 1, true), "scrubbed text missing from body")
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

-- ------------------------------------------------------- gzip request body
-- A fake that gunzips what curl would have sent and logs argv, so both the
-- Content-Encoding header and the compressed bytes are checked end to end.
local gz_argv, gz_body
step(function()
  vim.env.PATH = real_path
  if vim.fn.executable("gzip") == 1 then
    vim.fn.mkdir(tmp .. "/gz", "p")
    write_exec(tmp .. "/gz/curl", ([[#!/usr/bin/env bash
D=%q
printf '%%s\n' "$*" > "$D/gz_argv"
gunzip -c > "$D/gz_body"
echo "STRAPS_HTTP_STATUS:200" >&2
cat <<'EOF'
event: message_start
data: {"type":"message_start","message":{"usage":{}}}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"gz ok"}}

event: content_block_stop
data: {"type":"content_block_stop","index":0}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}

event: message_stop
data: {"type":"message_stop"}
EOF
]]):format(tmp))
    vim.env.PATH = tmp .. "/gz:" .. real_path
    straps.config.base_url = "http://straps-fake.invalid"
    straps.config.gzip = true
    straps.config.log_file = tmp .. "/gz_events.log"
    local gb = state.new_session()
    state.append(gb, "user", nil, "compress me")
    loop.start(gb)
    vim.wait(15000, function() return not loop.running(gb) end, 50)
    straps.config.gzip = false
    straps.config.log_file = nil
    gz_argv = table.concat(vim.fn.readfile(tmp .. "/gz_argv"), "\n")
    gz_body = table.concat(vim.fn.readfile(tmp .. "/gz_body"), "\n")
  end
end)

it("config.gzip compresses the request body and sets Content-Encoding: gzip", function()
  if vim.fn.executable("gzip") == 0 then
    print("SKIP  no gzip on PATH — request compression case skipped")
    return
  end
  assert(gz_argv:find("Content-Encoding: gzip", 1, true), "gzip header missing from argv:\n" .. gz_argv)
  local decoded = vim.json.decode(gz_body) -- the fake gunzipped the wire bytes
  assert(decoded.model, "gunzipped body missing model")
  assert(type(decoded.messages) == "table" and #decoded.messages >= 1, "gunzipped body missing messages")
  assert(decoded.messages[1].content[1].text == "compress me", "user text did not survive compression")
  local last_request
  for _, line in ipairs(vim.fn.readfile(tmp .. "/gz_events.log")) do
    local ev = vim.json.decode(line)
    if ev.ev == "request" then last_request = ev end
  end
  assert(last_request and type(last_request.wire_bytes) == "number", "request event missing wire_bytes")
  assert(last_request.wire_bytes < last_request.bytes,
    ("wire_bytes should be smaller than bytes: %d vs %d"):format(last_request.wire_bytes, last_request.bytes))
end)

-- A gzip that fails must not fail the request: the body goes out plain, with
-- no Content-Encoding header, and the request event reports equal sizes.
step(function()
  vim.fn.mkdir(tmp .. "/badgzip", "p")
  write_exec(tmp .. "/badgzip/gzip", [[#!/usr/bin/env bash
cat > /dev/null
exit 1
]])
  vim.fn.delete(tmp .. "/gz_argv")
  vim.fn.delete(tmp .. "/gz_body")
  write_exec(tmp .. "/badgzip/curl", ([[#!/usr/bin/env bash
D=%q
printf '%%s\n' "$*" > "$D/gz_argv"
cat > "$D/gz_body"
echo "STRAPS_HTTP_STATUS:200" >&2
cat <<'EOF'
event: message_start
data: {"type":"message_start","message":{"usage":{}}}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"plain ok"}}

event: content_block_stop
data: {"type":"content_block_stop","index":0}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}

event: message_stop
data: {"type":"message_stop"}
EOF
]]):format(tmp))
  vim.env.PATH = tmp .. "/badgzip:" .. real_path
  straps.config.gzip = true
  straps.config.log_file = tmp .. "/badgzip_events.log"
  local gb = state.new_session()
  state.append(gb, "user", nil, "gzip is broken here")
  loop.start(gb)
  vim.wait(15000, function() return not loop.running(gb) end, 50)
  straps.config.gzip = false
  straps.config.log_file = nil
  gz_argv = table.concat(vim.fn.readfile(tmp .. "/gz_argv"), "\n")
  gz_body = table.concat(vim.fn.readfile(tmp .. "/gz_body"), "\n")
end)

it("a failing gzip falls back to the plain body with no header", function()
  assert(not gz_argv:find("Content-Encoding", 1, true), "header sent although gzip failed:\n" .. gz_argv)
  local decoded = vim.json.decode(gz_body) -- plain JSON reached curl
  assert(decoded.messages[1].content[1].text == "gzip is broken here", "plain body did not reach curl")
  local last_request
  for _, line in ipairs(vim.fn.readfile(tmp .. "/badgzip_events.log")) do
    local ev = vim.json.decode(line)
    if ev.ev == "request" then last_request = ev end
  end
  assert(last_request.wire_bytes == last_request.bytes,
    ("fallback should log equal sizes: %d vs %d"):format(last_request.wire_bytes, last_request.bytes))
end)

it("config.gzip = false sends the plain body with no Content-Encoding header", function()
  local argv = table.concat(vim.fn.readfile(tmp .. "/argv"), "\n")
  assert(not argv:find("Content-Encoding", 1, true), "header leaked into a gzip=false request:\n" .. argv)
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
  straps.config.base_url = "http://user:hunter2@straps-stall.invalid"
  t0 = vim.uv.hrtime()
  bufnr2, text2 = run_session("this endpoint hangs")
  straps.config.base_url = nil
  elapsed_ms = (vim.uv.hrtime() - t0) / 1e6
end)

it("idle watchdog kills a silent stream instead of hanging forever", function()
  assert(not loop.running(bufnr2), "run never finished — watchdog did not fire")
  assert(text2:find("stream stalled", 1, true), "missing stall explanation:\n" .. text2)
  assert(text2:find("request_timeout_ms", 1, true), "error should mention the config knob")
  assert(not text2:find("hunter2", 1, true), "the stall error wrote the URL password into the transcript")
  assert(text2:find("http://***@straps-stall.invalid", 1, true), "the stall error should name the redacted URL")
  assert(elapsed_ms < 10000, "took too long: " .. elapsed_ms .. "ms")
end)

local half_text, half_requests
step(function()
  vim.fn.mkdir(tmp .. "/halfstall", "p")
  write_exec(tmp .. "/halfstall/curl", ([[#!/usr/bin/env bash
D=%q
cat > /dev/null
echo x >> "$D/halfstall_n"
echo "STRAPS_HTTP_STATUS:200" >&2
cat <<'EOF'
event: message_start
data: {"type":"message_start","message":{"usage":{}}}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"HALFWAY-TEXT "}}

EOF
sleep 60
]]):format(tmp))
  vim.env.PATH = tmp .. "/halfstall:" .. real_path
  straps.config.request_timeout_ms = 400
  local _
  _, half_text = run_session("this stream stalls after some text")
  half_requests = #vim.fn.readfile(tmp .. "/halfstall_n")
end)

it("a stream that stalls after text has streamed is not retried, so the text appears once", function()
  local _, count = half_text:gsub("HALFWAY%-TEXT", "")
  assert(count == 1, ("streamed text repeated %d times:\n%s"):format(count, half_text))
  assert(half_requests == 1, "request was retried after text streamed: " .. half_requests .. " requests")
  assert(half_text:find("stream stalled", 1, true), "stall explanation missing:\n" .. half_text)
end)

local empty_requests
step(function()
  vim.fn.mkdir(tmp .. "/emptystall", "p")
  write_exec(tmp .. "/emptystall/curl", ([[#!/usr/bin/env bash
D=%q
cat > /dev/null
echo x >> "$D/emptystall_n"
echo "STRAPS_HTTP_STATUS:200" >&2
cat <<'EOF'
event: message_start
data: {"type":"message_start","message":{"usage":{}}}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":""}}

EOF
sleep 60
]]):format(tmp))
  vim.env.PATH = tmp .. "/emptystall:" .. real_path
  run_session("this stream stalls after an empty text delta")
  empty_requests = #vim.fn.readfile(tmp .. "/emptystall_n")
end)

it("a stream that stalls after only an empty text delta is still retried", function()
  assert(empty_requests > 1, "an empty text delta blocked the retry: " .. empty_requests .. " request(s)")
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
  assert(text400:find("straps provider: request failed (HTTP 400)", 1, true),
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

-- A vim.system that raises on the curl spawn (EAGAIN with the process table
-- full) must resolve as a curl-level failure and retry, not escape the run.
local bufs, texts, spawn_raised
step(function()
  vim.fn.mkdir(tmp .. "/spawnfail", "p")
  write_exec(tmp .. "/spawnfail/curl", [[#!/usr/bin/env bash
cat > /dev/null
echo "STRAPS_HTTP_STATUS:200" >&2
printf 'event: message_start\ndata: {"type":"message_start"}\n\n'
printf 'event: content_block_start\ndata: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}\n\n'
printf 'event: content_block_delta\ndata: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"survived the spawn failure"}}\n\n'
printf 'event: content_block_stop\ndata: {"type":"content_block_stop","index":0}\n\n'
printf 'event: message_delta\ndata: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}\n\n'
printf 'event: message_stop\ndata: {"type":"message_stop"}\n\n'
]])
  vim.env.PATH = tmp .. "/spawnfail:" .. real_path
  local real_system = vim.system
  spawn_raised = 0
  vim.system = function(argv, ...)
    if argv[1] == "curl" and spawn_raised == 0 then
      spawn_raised = 1
      error("EAGAIN: resource temporarily unavailable")
    end
    return real_system(argv, ...)
  end
  bufs, texts = run_session("spawn fails once")
  vim.system = real_system
end)

it("a raising curl spawn is retried as a transport failure, not a run error", function()
  assert(spawn_raised == 1, "the stub never fired")
  assert(not loop.running(bufs), "run still active")
  assert(texts:find("survived the spawn failure", 1, true), "retry after spawn failure did not complete:\n" .. texts:sub(-400))
  assert(not texts:find("run error", 1, true), "spawn failure escaped as a run error:\n" .. texts:sub(-400))
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

-- A ChatGPT login is served the Codex catalog shape instead of {data:[{id}]}:
-- {models:[{slug, display_name, context_window, visibility}]}.
step(function()
  vim.fn.mkdir(tmp .. "/models_chatgpt", "p")
  write_exec(tmp .. "/models_chatgpt/curl", [[#!/usr/bin/env bash
cat <<'EOF'
{"models":[
  {"slug":"gpt-6-sol","display_name":"GPT-6-Sol","context_window":272000,"visibility":"list"},
  {"slug":"gpt-reserve","display_name":"GPT-Reserve","context_window":272000,"visibility":"hide"},
  {"slug":"gpt-6-luna","context_window":128000}
]}
EOF
printf '\nSTRAPS_HTTP_STATUS:200\n'
]])
end)

do
  local saved_path, saved_oai_base, saved_oai_key
  local models, err
  step(function()
    saved_path = vim.env.PATH
    saved_oai_base = straps.config.openai_base_url
    saved_oai_key = vim.env.OPENAI_API_KEY
    vim.env.PATH = tmp .. "/models_chatgpt:" .. real_path
    straps.config.openai_base_url = "http://straps-chatgpt-models.invalid"
    vim.env.OPENAI_API_KEY = "openai-test-key"
    models, err = registry.call("fn.list_models", "openai")
  end)

  it("fn.list_models (openai) parses the ChatGPT catalog: slug as id, display_name as label", function()
    assert(type(models) == "table", "expected a model list, got err: " .. tostring(err))
    assert(models[1].id == "gpt-6-sol" and models[1].label == "GPT-6-Sol", "id/label wrong: " .. vim.inspect(models[1]))
    assert(models[1].thinking == nil, "openai models carry no thinking tag")
    assert(models[1].context == 272000, "context_window not mapped: " .. vim.inspect(models[1]))
    assert(models[2].id == "gpt-6-luna" and models[2].label == "gpt-6-luna", "label fallback wrong: " .. vim.inspect(models[2]))
  end)

  it("fn.list_models (openai) drops ChatGPT catalog entries with visibility=hide", function()
    assert(type(models) == "table", "expected a model list, got err: " .. tostring(err))
    assert(#models == 2, "expected 2 visible models, got " .. vim.inspect(models))
    for _, m in ipairs(models) do
      assert(m.id ~= "gpt-reserve", "hidden model gpt-reserve was listed: " .. vim.inspect(models))
    end
  end)

  step(function()
    vim.env.PATH = saved_path
    straps.config.openai_base_url = saved_oai_base
    vim.env.OPENAI_API_KEY = saved_oai_key
  end)
end

step(function()
  vim.env.ANTHROPIC_API_KEY = saved_key

  -- ------------------------------------------------------------ openai backend
  -- Fake curl serving OpenAI Responses SSE. Turn 1 streams a reasoning item
  -- (ignored) and a function_call (echo via bash), turn 2 streams text. A body
  -- containing "trigger-stream-error" gets an `error` event. Captures argv +
  -- request bodies so we can assert the translated wire shape and Bearer auth.
  vim.fn.mkdir(tmp .. "/openai", "p")
  write_exec(tmp .. "/openai/curl", ([[#!/usr/bin/env bash
D=%q
N=$(cat "$D/oai_n" 2>/dev/null || echo 0); N=$((N+1)); echo $N > "$D/oai_n"
printf '%%s\n' "$*" >> "$D/oai_argv"
cat > "$D/oai_body.$N"
echo "STRAPS_HTTP_STATUS:200" >&2
if grep -q trigger-stream-error "$D/oai_body.$N"; then
  printf 'event: error\ndata: {"type":"error","code":"invalid_request_error","message":"fake stream failure","param":"tools","sequence_number":1}\n\n'
elif grep -q trigger-retry-error "$D/oai_body.$N" && [ ! -e "$D/oai_retry_done" ]; then
  touch "$D/oai_retry_done"
  printf 'event: error\ndata: {"type":"error","code":"rate_limit_exceeded","message":"fake rate limit","param":null,"sequence_number":1}\n\n'
elif grep -q trigger-stall-after-empty "$D/oai_body.$N"; then
  printf 'event: response.output_text.delta\ndata: {"type":"response.output_text.delta","output_index":0,"delta":""}\n\n'
  sleep 60
elif grep -q trigger-stall-after-text "$D/oai_body.$N"; then
  printf 'event: response.output_text.delta\ndata: {"type":"response.output_text.delta","output_index":0,"delta":"OAI-STALL-TEXT "}\n\n'
  sleep 60
elif grep -q trigger-late-retry "$D/oai_body.$N"; then
  printf 'event: response.output_text.delta\ndata: {"type":"response.output_text.delta","output_index":0,"delta":"partial-before-error "}\n\n'
  printf 'event: error\ndata: {"type":"error","code":"server_error","message":"fake late server error","param":null,"sequence_number":2}\n\n'
elif grep -q trigger-failed "$D/oai_body.$N"; then
  printf 'event: response.failed\ndata: {"type":"response.failed","response":{"status":"failed","error":{"code":"invalid_prompt","message":"fake response failed"}}}\n\n'
elif grep -q trigger-refusal "$D/oai_body.$N"; then
  printf 'event: response.output_text.delta\ndata: {"type":"response.output_text.delta","output_index":0,"delta":"first-item"}\n\n'
  printf 'event: response.refusal.delta\ndata: {"type":"response.refusal.delta","output_index":1,"delta":"fake-refusal-text"}\n\n'
  printf 'event: response.completed\ndata: {"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":5,"output_tokens":5}}}\n\n'
elif grep -q trigger-done-only "$D/oai_body.$N" && ! grep -q oai-done-only-output "$D/oai_body.$N"; then
  printf 'event: response.output_item.done\ndata: {"type":"response.output_item.done","output_index":0,"item":{"type":"function_call","id":"fc_d","call_id":"call_d","name":"bash","status":"completed","arguments":"{\\"command\\":\\"echo oai-done-only-output\\"}"}}\n\n'
  printf 'event: response.completed\ndata: {"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":5,"output_tokens":5}}}\n\n'
elif grep -q trigger-truncated "$D/oai_body.$N"; then
  printf 'event: response.output_item.added\ndata: {"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","id":"fc_t","call_id":"call_t","name":"bash","arguments":""}}\n\n'
  printf 'event: response.function_call_arguments.delta\ndata: {"type":"response.function_call_arguments.delta","output_index":0,"item_id":"fc_t","delta":"{\\"command\\":\\"touch '"$D"'/oai_truncated_ran\\"}"}\n\n'
  printf 'event: response.incomplete\ndata: {"type":"response.incomplete","response":{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"usage":{"input_tokens":10,"output_tokens":8192}}}\n\n'
elif [ "$N" = 1 ]; then
  printf 'event: response.created\ndata: {"type":"response.created","sequence_number":0,"response":{"status":"in_progress"}}\n\n'
  printf 'event: response.output_item.added\ndata: {"type":"response.output_item.added","output_index":0,"item":{"type":"reasoning","id":"rs_1","summary":[]}}\n\n'
  printf 'event: response.output_item.added\ndata: {"type":"response.output_item.added","output_index":1,"item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"bash","arguments":""}}\n\n'
  printf 'event: response.function_call_arguments.delta\ndata: {"type":"response.function_call_arguments.delta","output_index":1,"item_id":"fc_1","delta":"{\\"command\\":\\"echo "}\n\n'
  printf 'event: response.function_call_arguments.delta\ndata: {"type":"response.function_call_arguments.delta","output_index":1,"item_id":"fc_1","delta":"openai-e2e-output\\"}"}\n\n'
  printf 'event: response.output_item.done\ndata: {"type":"response.output_item.done","output_index":1,"item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"bash","arguments":"{\\"command\\":\\"echo openai-e2e-output\\"}"}}\n\n'
  printf 'event: response.completed\ndata: {"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":1200,"output_tokens":20,"input_tokens_details":{"cached_tokens":1100}}}}\n\n'
else
  printf 'event: response.output_item.added\ndata: {"type":"response.output_item.added","output_index":0,"item":{"type":"message","id":"msg_1","role":"assistant","content":[]}}\n\n'
  printf 'event: response.output_text.delta\ndata: {"type":"response.output_text.delta","output_index":0,"content_index":0,"delta":"openai "}\n\n'
  printf 'event: response.output_text.delta\ndata: {"type":"response.output_text.delta","output_index":0,"content_index":0,"delta":"done"}\n\n'
  printf 'event: response.completed\ndata: {"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":50,"output_tokens":5}}}\n\n'
fi
]]):format(tmp))
end)

do
  local saved_provider
  local saved_oai_base
  local saved_oai_model, saved_model, saved_oai_key_env
  local oai_buf, oai_text
  local initial_oai_n
  step(function()
    saved_provider = straps.config.provider
    saved_oai_base = straps.config.openai_base_url
    saved_oai_model, saved_model, saved_oai_key_env =
      straps.config.openai_model, straps.config.model, vim.env.OPENAI_API_KEY
    vim.env.PATH = tmp .. "/openai:" .. real_path
    vim.env.OPENAI_API_KEY = "openai-test-key"
    straps.config.provider = "openai"
    straps.config.openai_base_url = "http://straps-openai.invalid"
    straps.config.openai_model = "gpt-5-test"
    straps.config.log_file = tmp .. "/oai_events.log"

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

  it("openai backend: hits base_url/v1/responses with Bearer auth", function()
    local argv = table.concat(vim.fn.readfile(tmp .. "/oai_argv"), "\n")
    assert(argv:find("http://straps-openai.invalid/v1/responses", 1, true),
      "custom openai base_url not in argv:\n" .. argv)
    assert(argv:find("Authorization: Bearer openai-test-key", 1, true),
      "Bearer auth header missing:\n" .. argv)
  end)

  it("openai backend: request 1 is translated Responses shape (instructions + input + tools + model)", function()
    local body = read_oai_body(initial_oai_n - 1)
    assert(body.model == "gpt-5-test", "model wrong: " .. tostring(body.model))
    assert(body.stream == true, "stream should be true")
    assert(body.store == false, "store should be false")
    assert(type(body.max_output_tokens) == "number", "max_output_tokens missing")
    assert(body.reasoning == nil, "untagged OpenAI model must not receive reasoning: " .. vim.inspect(body.reasoning))
    assert(type(body.instructions) == "string" and body.instructions ~= "", "system prompt not sent as instructions")
    assert(body.input[1].role == "user" and body.input[1].content:find("run echo via bash on openai", 1, true),
      "first input item should be the user message: " .. vim.inspect(body.input[1]))
    assert(type(body.tools) == "table" and #body.tools > 0, "tools missing")
    local t1 = body.tools[1]
    assert(t1.type == "function" and type(t1.name) == "string", "tool not in Responses function shape")
    assert(type(t1.parameters) == "table", "tool parameters missing")
    assert(t1.strict == false, "tool strict should be false")
  end)

  it("openai backend: request 2 carries the function_call + function_call_output items", function()
    local body = read_oai_body(initial_oai_n)
    local call_i, out_i
    for i, item in ipairs(body.input) do
      if item.type == "function_call" then call_i = i end
      if item.type == "function_call_output" then out_i = i end
    end
    assert(call_i, "function_call item missing: " .. vim.inspect(body.input))
    local call = body.input[call_i]
    assert(call.name == "bash", "function_call name lost")
    assert(call.call_id == "call_1", "function_call call_id lost: " .. tostring(call.call_id))
    local args = vim.json.decode(call.arguments)
    assert(args.command and args.command:find("openai-e2e-output", 1, true),
      "function_call arguments not a JSON string round-trip: " .. vim.inspect(args))
    assert(out_i and out_i > call_i, "function_call_output must follow its function_call")
    local out = body.input[out_i]
    assert(out.call_id == "call_1", "call_id not threaded back to the output")
    assert(tostring(out.output):find("openai-e2e-output", 1, true), "tool output not sent back")
  end)

  it("openai backend: usage maps to the Anthropic names with cached tokens split out", function()
    local resp
    for _, line in ipairs(vim.fn.readfile(tmp .. "/oai_events.log")) do
      local ev = vim.json.decode(line)
      if ev.ev == "response" and ev.stop_reason == "tool_use" then resp = ev end
    end
    assert(resp, "no response event for the tool_use turn")
    assert(resp.input_tokens == 100, "input_tokens is " .. tostring(resp.input_tokens) .. ", want 100")
    assert(resp.cache_read_input_tokens == 1100,
      "cache_read_input_tokens is " .. tostring(resp.cache_read_input_tokens) .. ", want 1100")
    assert(resp.output_tokens == 20, "output_tokens is " .. tostring(resp.output_tokens) .. ", want 20")
  end)

  it("openai backend: per-buffer OpenAI model slot wins over config.openai_model", function()
    vim.b[oai_buf].straps_openai_model = "gpt-5-mini-session"
    state.append_text(oai_buf, "run with a session-specific OpenAI model")
    loop.start(oai_buf)
    vim.wait(15000, function() return not loop.running(oai_buf) end, 50)
    local body = read_latest_oai_body()
    assert(body.model == "gpt-5-mini-session", "per-buffer OpenAI model ignored: " .. tostring(body.model))
  end)

  it("openai backend: opted-in model receives reasoning.effort alongside tools", function()
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
      assert(type(body.reasoning) == "table" and body.reasoning.effort == "high",
        "opted-in model with tools should receive reasoning.effort=high, got " .. vim.inspect(body.reasoning))
      assert(body.reasoning_effort == nil, "Chat Completions reasoning_effort must not be sent")
    end)
    straps.config.effort, straps.config.efforts, straps.config.openai_models =
      saved_effort, saved_efforts, saved_openai_models
    if not ok then error(err, 0) end
  end)

  it("openai backend: a model not opted in gets no reasoning field, even with an effort active", function()
    local saved_effort, saved_efforts, saved_openai_models =
      straps.config.effort, straps.config.efforts, straps.config.openai_models
    straps.config.effort = "high"
    straps.config.efforts = { { name = "high", level = "high" } }
    straps.config.openai_models = {
      { id = "gpt-5.1-codex-sol", label = "sol" },
    }
    local ok, err = pcall(function()
      vim.b[oai_buf].straps_openai_model = "gpt-5.1-codex-sol"
      state.append_text(oai_buf, "run with an untagged model and tools")
      loop.start(oai_buf)
      vim.wait(15000, function() return not loop.running(oai_buf) end, 50)
      local body = read_latest_oai_body()
      assert(body.model == "gpt-5.1-codex-sol", "model wrong: " .. tostring(body.model))
      assert(type(body.tools) == "table" and #body.tools > 0, "tools should be present")
      assert(body.reasoning == nil, "untagged model must get no reasoning field, got " .. vim.inspect(body.reasoning))
    end)
    straps.config.effort, straps.config.efforts, straps.config.openai_models =
      saved_effort, saved_efforts, saved_openai_models
    if not ok then error(err, 0) end
  end)

  it("openai backend: an empty tool list is omitted from the request", function()
    local saved_build_tools = registry.get("fn.build_tools").source
    registry.define({ name = "fn.build_tools", kind = "fn", doc = "test: no tools",
      source = [[return function() return {} end]] })
    local ok, err = pcall(function()
      state.append_text(oai_buf, "run with no tools")
      loop.start(oai_buf)
      vim.wait(15000, function() return not loop.running(oai_buf) end, 50)
      local body = read_latest_oai_body()
      assert(body.tools == nil, "empty tool list should be omitted, got: " .. vim.inspect(body.tools))
    end)
    registry.define({ name = "fn.build_tools", kind = "fn", doc = "restored", source = saved_build_tools })
    if not ok then error(err, 0) end
  end)

  it("openai backend: an `error` stream event fails the run with its message", function()
    local n_before = tonumber(vim.fn.readfile(tmp .. "/oai_n")[1])
    local _, text = run_session("trigger-stream-error please")
    assert(text:find("fake stream failure", 1, true), "stream error message not surfaced:\n" .. text:sub(-600))
    assert(tonumber(vim.fn.readfile(tmp .. "/oai_n")[1]) == n_before + 1, "non-retryable stream error was retried")
  end)

  it("openai backend: a rate_limit_exceeded stream event is retried", function()
    local n_before = tonumber(vim.fn.readfile(tmp .. "/oai_n")[1])
    local _, text = run_session("trigger-retry-error please")
    assert(not text:find("fake rate limit", 1, true), "retryable stream error surfaced as a run error")
    assert(tonumber(vim.fn.readfile(tmp .. "/oai_n")[1]) == n_before + 2, "rate-limited request was not retried once")
  end)

  it("openai backend: a retryable stream error after streamed text is not retried", function()
    local n_before = tonumber(vim.fn.readfile(tmp .. "/oai_n")[1])
    local _, text = run_session("trigger-late-retry please")
    assert(text:find("fake late server error", 1, true), "late stream error not surfaced:\n" .. text:sub(-600))
    assert(tonumber(vim.fn.readfile(tmp .. "/oai_n")[1]) == n_before + 1, "stream error after streamed text was retried")
  end)

  it("openai backend: a stream that stalls after text has streamed is not retried, so the text appears once", function()
    local n_before = tonumber(vim.fn.readfile(tmp .. "/oai_n")[1])
    local saved_timeout = straps.config.request_timeout_ms
    straps.config.request_timeout_ms = 400
    local _, text = run_session("trigger-stall-after-text please")
    straps.config.request_timeout_ms = saved_timeout
    local _, count = text:gsub("OAI%-STALL%-TEXT", "")
    local requests = tonumber(vim.fn.readfile(tmp .. "/oai_n")[1]) - n_before
    assert(count == 1, ("streamed text repeated %d times:\n%s"):format(count, text:sub(-600)))
    assert(requests == 1, "request was retried after text streamed: " .. requests .. " requests")
  end)

  it("openai backend: a stream that stalls after only an empty text delta is still retried", function()
    local n_before = tonumber(vim.fn.readfile(tmp .. "/oai_n")[1])
    local saved_timeout = straps.config.request_timeout_ms
    straps.config.request_timeout_ms = 400
    run_session("trigger-stall-after-empty please")
    straps.config.request_timeout_ms = saved_timeout
    local requests = tonumber(vim.fn.readfile(tmp .. "/oai_n")[1]) - n_before
    assert(requests > 1, "an empty text delta blocked the retry: " .. requests .. " request(s)")
  end)

  it("openai backend: response.failed fails the run with the response error", function()
    local _, text = run_session("trigger-failed please")
    assert(text:find("fake response failed", 1, true), "response.failed error not surfaced:\n" .. text:sub(-600))
  end)

  it("openai backend: refusal text streams, and separate output items are joined by a blank line", function()
    local _, text = run_session("trigger-refusal please")
    assert(text:find("first-item\n\nfake-refusal-text", 1, true), "refusal/second item text wrong:\n" .. text:sub(-600))
  end)

  it("openai backend: a function call whose arguments arrive only in output_item.done runs", function()
    local _, text = run_session("trigger-done-only please")
    assert(text:find("oai-done-only-output", 1, true), "done-only function call did not run:\n" .. text:sub(-600))
  end)

  it("openai backend: text around a tool_use becomes separate input items in block order", function()
    local before = tonumber(vim.fn.readfile(tmp .. "/oai_n")[1])
    local co = coroutine.create(function()
      registry.call("fn.provider_openai", {
        system = "sys",
        messages = {
          { role = "user", content = "start" },
          { role = "assistant", content = {
            { type = "text", text = "before" },
            { type = "tool_use", id = "call_x", name = "bash", input = { command = "true" } },
            { type = "text", text = "after" },
          } },
          { role = "user", content = {
            { type = "tool_result", tool_use_id = "call_x", content = "ok" },
            { type = "text", text = "next" },
          } },
        },
      }, {
        bufnr = nil,
        emit = function() end,
        cancelled = function() return false end,
        on_cancel = function() end,
        await = function(start)
          local res, done
          start(function(r) if not done then done, res = true, r end end)
          vim.wait(10000, function() return done end, 20)
          return res
        end,
      })
    end)
    local ok, err = coroutine.resume(co)
    assert(ok, tostring(err))
    assert(tonumber(vim.fn.readfile(tmp .. "/oai_n")[1]) == before + 1, "provider made no request")
    local input = read_latest_oai_body().input
    local shape = {}
    for _, item in ipairs(input) do
      shape[#shape + 1] = item.type or (item.role .. ":" .. item.content)
    end
    local want = { "user:start", "assistant:before", "function_call", "assistant:after", "function_call_output", "user:next" }
    assert(vim.deep_equal(shape, want), "input item order wrong: " .. vim.inspect(shape))
  end)

  it("openai backend: a function call cut off by max_output_tokens is not run", function()
    run_session("trigger-truncated please")
    assert(vim.fn.filereadable(tmp .. "/oai_truncated_ran") == 0, "truncated function call was executed")
    local resp
    for _, line in ipairs(vim.fn.readfile(tmp .. "/oai_events.log")) do
      local ev = vim.json.decode(line)
      if ev.ev == "response" then resp = ev end
    end
    assert(resp and resp.stop_reason == "max_tokens",
      "incomplete response should map to max_tokens, got " .. tostring(resp and resp.stop_reason))
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
    straps.config.openai_model = saved_oai_model
    straps.config.model = saved_model
    straps.config.log_file = nil
    vim.env.PATH = real_path
    vim.env.OPENAI_API_KEY = saved_oai_key_env
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

  it("fn.provider_pref: llamacpp writes, and a file holding llamacpp reads back", function()
    assert(registry.call("fn.provider_pref", "llamacpp") == "llamacpp", "llamacpp write rejected")
    vim.fn.writefile({ "llamacpp" }, pd .. "/straps/provider")
    assert(registry.call("fn.provider_pref") == "llamacpp", "llamacpp read-back wrong")
    local w, err = registry.call("fn.provider_pref", "bogus")
    assert(w == nil and tostring(err):find("unknown provider bogus", 1, true), tostring(err))
  end)

  -- Snapshot the real backend sources so we can restore them after spying.
  local real_anthropic
  local real_openai
  local real_llamacpp
  step(function()
    real_anthropic = registry.get("fn.provider_anthropic").source
    real_openai = registry.get("fn.provider_openai").source
    real_llamacpp = registry.get("fn.provider_llamacpp").source
  end)

  -- Backend spies for the dispatcher tests below; the step after them
  -- restores the real sources.
  step(function()
    registry.define({ name = "fn.provider_anthropic", kind = "fn", doc = "spy",
      source = [[return function() return { content = {}, stop_reason = "end_turn", _who = "a" } end]] })
    registry.define({ name = "fn.provider_openai", kind = "fn", doc = "spy",
      source = [[return function() return { content = {}, stop_reason = "end_turn", _who = "o" } end]] })
    registry.define({ name = "fn.provider_llamacpp", kind = "fn", doc = "spy",
      source = [[return function() return { content = {}, stop_reason = "end_turn", _who = "l" } end]] })
  end)

  it("dispatcher: config.provider overrides the persisted file", function()
    -- File says openai; config pins anthropic -> anthropic wins.
    registry.call("fn.provider_pref", "openai")
    straps.config.provider = "anthropic"
    local picked
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

  it("dispatcher: llamacpp routes to fn.provider_llamacpp", function()
    registry.define({ name = "fn.provider_llamacpp", kind = "fn", doc = "spy",
      source = [[return function() return { content = {}, stop_reason = "end_turn", _who = "l" } end]] })
    straps.config.provider = "llamacpp"
    local resp = registry.call("fn.provider", { messages = {} }, { bufnr = nil })
    assert(resp._who == "l", "llamacpp should reach fn.provider_llamacpp, got " .. tostring(resp._who))
    straps.config.provider = "bogus"
    local ok, err = pcall(registry.call, "fn.provider", { messages = {} }, { bufnr = nil })
    straps.config.provider = nil
    assert(not ok and tostring(err):find("llamacpp", 1, true), "unknown-provider error should list llamacpp: " .. tostring(err))
  end)

  it("dispatcher and fn.list_models: an unknown value in the pref file raises or returns (nil, err), never anthropic", function()
    straps.config.provider = nil
    vim.fn.mkdir(pd .. "/straps", "p")
    vim.fn.writefile({ "llama.cpp" }, pd .. "/straps/provider")
    local ok, err = pcall(registry.call, "fn.provider", { messages = {} }, { bufnr = nil })
    local saved_path = vim.env.PATH
    vim.env.PATH = tmp .. "/models_500:" .. real_path
    local models, why = registry.call("fn.list_models")
    vim.env.PATH = saved_path
    vim.fn.delete(pd .. "/straps/provider")
    assert(not ok and tostring(err):find("unknown provider llama.cpp (expected one of:", 1, true)
      and tostring(err):find("), from the provider pref file", 1, true),
      "unknown pref value should raise and name the pref file, got: " .. tostring(err))
    assert(models == nil and tostring(why):find("unknown provider", 1, true), "list_models should refuse: " .. tostring(why))
  end)

  it("dispatcher: a session's first request pins its provider in vim.b and the .meta file", function()
    straps.config.provider = "llamacpp"
    local sess = state.new_session()
    local first = registry.call("fn.provider", { messages = {} }, { bufnr = sess })
    straps.config.provider = "anthropic"
    local second = registry.call("fn.provider", { messages = {} }, { bufnr = sess })
    local fresh = state.new_session()
    local other = registry.call("fn.provider", { messages = {} }, { bufnr = fresh })
    local path = vim.api.nvim_buf_get_name(sess)
    straps.config.provider = nil
    assert(first._who == "l" and second._who == "l",
      "pinned session moved to another backend: " .. tostring(first._who) .. "/" .. tostring(second._who))
    assert(other._who == "a", "a new session should follow the new global provider, got " .. tostring(other._who))
    assert(vim.b[sess].straps_provider == "llamacpp", "vim.b not pinned: " .. tostring(vim.b[sess].straps_provider))
    assert((state.session_pin(path)) == "llamacpp", "provider not saved in .meta: " .. tostring((state.session_pin(path))))
  end)

  it("state: a resumed session restores its pinned provider; the title and provider share the .meta file", function()
    local sess = state.new_session()
    local path = vim.api.nvim_buf_get_name(sess)
    state.set_session_pin(sess, "llamacpp")
    assert(state.set_session_title(path, "my title"), "title write failed")
    assert((state.session_pin(path)) == "llamacpp", "setting the title dropped the provider")
    assert(state.set_session_title(path, nil), "title clear failed")
    assert((state.session_pin(path)) == "llamacpp", "clearing the title dropped the provider")
    vim.api.nvim_buf_delete(sess, { force = true })
    local resumed = state.open_session_file(path)
    assert(vim.b[resumed].straps_provider == "llamacpp",
      "resume did not restore the provider: " .. tostring(vim.b[resumed].straps_provider))
  end)

  it("state: pinning a provider keeps the title already in the .meta file", function()
    local sess = state.new_session()
    local path = vim.api.nvim_buf_get_name(sess)
    assert(state.set_session_title(path, "kept title"), "title write failed")
    state.set_session_pin(sess, "llamacpp")
    assert((state.session_pin(path)) == "llamacpp", "provider not saved: " .. tostring((state.session_pin(path))))
    assert(state.session_title(path) == "kept title", "pinning dropped the title: " .. tostring(state.session_title(path)))
  end)

  it("dispatcher: a failed or cancelled first request pins nothing; the next successful one pins", function()
    local spy_l = registry.get("fn.provider_llamacpp").source
    straps.config.provider = "llamacpp"
    local sess = state.new_session()
    local path = vim.api.nvim_buf_get_name(sess)
    registry.define({ name = "fn.provider_llamacpp", kind = "fn", doc = "spy",
      source = [[return function() error("fake backend failure") end]] })
    local ok = pcall(registry.call, "fn.provider", { messages = {} }, { bufnr = sess })
    local after_fail_b, after_fail_meta = vim.b[sess].straps_provider, (state.session_pin(path))
    registry.define({ name = "fn.provider_llamacpp", kind = "fn", doc = "spy",
      source = [[return function() return { content = {}, stop_reason = "cancelled" } end]] })
    registry.call("fn.provider", { messages = {} }, { bufnr = sess })
    local after_cancel_b, after_cancel_meta = vim.b[sess].straps_provider, (state.session_pin(path))
    registry.define({ name = "fn.provider_llamacpp", kind = "fn", doc = "spy", source = spy_l })
    registry.call("fn.provider", { messages = {} }, { bufnr = sess })
    straps.config.provider = nil
    assert(not ok, "the failing backend did not raise")
    assert(after_fail_b == nil and after_fail_meta == nil,
      "a failed request pinned: " .. tostring(after_fail_b) .. "/" .. tostring(after_fail_meta))
    assert(after_cancel_b == nil and after_cancel_meta == nil,
      "a cancelled request pinned: " .. tostring(after_cancel_b) .. "/" .. tostring(after_cancel_meta))
    assert(vim.b[sess].straps_provider == "llamacpp" and (state.session_pin(path)) == "llamacpp",
      "a successful request did not pin")
  end)

  it("dispatcher: an unknown provider pins nothing and the error names its source", function()
    straps.config.provider = "bogus"
    local sess = state.new_session()
    local path = vim.api.nvim_buf_get_name(sess)
    local ok, err = pcall(registry.call, "fn.provider", { messages = {} }, { bufnr = sess })
    straps.config.provider = nil
    vim.b[sess].straps_provider = "bogus2"
    local ok_b, err_b = pcall(registry.call, "fn.provider", { messages = {} }, { bufnr = sess })
    vim.b[sess].straps_provider = nil
    assert(not ok and tostring(err):find("unknown provider bogus (expected one of:", 1, true)
      and tostring(err):find("), from setup{ provider }", 1, true), tostring(err))
    assert(not tostring(err):find('[string "', 1, true), "the error carries a chunk position: " .. tostring(err))
    assert(not ok_b and tostring(err_b):find("unknown provider bogus2 (expected one of:", 1, true)
      and tostring(err_b):find("), from the session's vim.b straps_provider", 1, true),
      tostring(err_b))
    assert((state.session_pin(path)) == nil, ".meta pinned an unknown provider: " .. tostring((state.session_pin(path))))
  end)

  it("dispatcher: a pinned session switched per buffer saves the new provider and uses it", function()
    straps.config.provider = "llamacpp"
    local sess = state.new_session()
    local path = vim.api.nvim_buf_get_name(sess)
    registry.call("fn.provider", { messages = {} }, { bufnr = sess })
    vim.b[sess].straps_provider = "openai"
    local resp = registry.call("fn.provider", { messages = {} }, { bufnr = sess })
    straps.config.provider = nil
    assert(resp._who == "o", "switched session still went to " .. tostring(resp._who))
    assert((state.session_pin(path)) == "openai", ".meta kept " .. tostring((state.session_pin(path))))
  end)

  it("dispatcher: after a rename the next request saves the pin beside the new path", function()
    straps.config.provider = "llamacpp"
    local sess = state.new_session()
    registry.call("fn.provider", { messages = {} }, { bufnr = sess })
    local renamed = vim.fn.tempname() .. ".straps"
    vim.api.nvim_buf_set_name(sess, renamed)
    registry.call("fn.provider", { messages = {} }, { bufnr = sess })
    straps.config.provider = nil
    assert((state.session_pin(renamed)) == "llamacpp",
      "the renamed transcript has no pin: " .. tostring((state.session_pin(renamed))))
  end)

  it("state: a .meta file that does not parse warns on resume, restores nothing, and the next request heals it", function()
    local sess = state.new_session()
    local path = vim.api.nvim_buf_get_name(sess)
    vim.api.nvim_buf_delete(sess, { force = true })
    vim.fn.writefile({ "{not json" }, path .. ".meta")
    local warned
    local real_notify = vim.notify
    vim.notify = function(msg, level) if level == vim.log.levels.WARN then warned = msg end end
    local resumed = state.open_session_file(path)
    vim.notify = real_notify
    local restored = vim.b[resumed].straps_provider
    straps.config.provider = "llamacpp"
    registry.call("fn.provider", { messages = {} }, { bufnr = resumed })
    straps.config.provider = nil
    assert(warned and warned:find("not a JSON object", 1, true), "no warning: " .. tostring(warned))
    assert(restored == nil, "an unparsable .meta restored " .. tostring(restored))
    assert((state.session_pin(path)) == "llamacpp",
      "the request did not replace the unparsable .meta: " .. table.concat(vim.fn.readfile(path .. ".meta"), "\n"))
  end)

  it("dispatcher: the first request pins the resolved model, so a later global model change does not move the session", function()
    straps.config.provider = "anthropic"
    local saved_model = straps.config.model
    straps.config.model = "claude-first"
    local sess = state.new_session()
    local path = vim.api.nvim_buf_get_name(sess)
    registry.call("fn.provider", { messages = {} }, { bufnr = sess })
    straps.config.model = "claude-later"
    local resolved = require("straps.provider").resolve_model("anthropic", sess, straps.config)
    local _, saved = state.session_pin(path)
    straps.config.model = saved_model
    straps.config.provider = nil
    assert(vim.b[sess].straps_model == "claude-first", "model not pinned in the buffer: " .. tostring(vim.b[sess].straps_model))
    assert(resolved == "claude-first", "a global model change moved the pinned session to " .. tostring(resolved))
    assert(saved == "claude-first", "model not saved in .meta: " .. tostring(saved))
  end)

  it("state: set_session_pin writes the provider it is given, even over a different buffer provider", function()
    local sess = state.new_session()
    local path = vim.api.nvim_buf_get_name(sess)
    vim.b[sess].straps_provider = "anthropic"
    state.set_session_pin(sess, "openai", "gpt-x")
    local provider, model = state.session_pin(path)
    assert(vim.b[sess].straps_provider == "openai", "vim.b kept " .. tostring(vim.b[sess].straps_provider))
    assert(vim.b[sess].straps_openai_model == "gpt-x", "model variable not set: " .. tostring(vim.b[sess].straps_openai_model))
    assert(provider == "openai" and model == "gpt-x", ".meta holds " .. tostring(provider) .. "/" .. tostring(model))
  end)

  it("state: a failed pin write warns once per buffer and keeps the pin in memory", function()
    local sess = state.new_session()
    vim.api.nvim_buf_set_name(sess, vim.fn.tempname() .. "/missing-dir/s.straps")
    local warnings = {}
    local real_notify = vim.notify
    vim.notify = function(msg, level) if level == vim.log.levels.WARN then warnings[#warnings + 1] = msg end end
    state.set_session_pin(sess, "llamacpp", "m1")
    state.set_session_pin(sess, "llamacpp", "m1")
    vim.notify = real_notify
    assert(#warnings == 1, "expected one warning, got " .. #warnings .. ": " .. vim.inspect(warnings))
    assert(warnings[1]:find("could not save this session's provider", 1, true), warnings[1])
    assert(vim.b[sess].straps_provider == "llamacpp", "the pin was lost in memory")
  end)

  it("state: a .meta deleted while the buffer is open is written again on the next pin", function()
    local sess = state.new_session()
    local path = vim.api.nvim_buf_get_name(sess)
    state.set_session_pin(sess, "llamacpp", "m1")
    vim.fn.delete(path .. ".meta")
    state.set_session_pin(sess, "llamacpp", "m1")
    local provider, model = state.session_pin(path)
    assert(provider == "llamacpp" and model == "m1", "the deleted .meta was not rewritten: " .. tostring(provider))
  end)

  it("state: a resume keeps a model variable the loaded buffer already has", function()
    local sess = state.new_session()
    local path = vim.api.nvim_buf_get_name(sess)
    state.set_session_pin(sess, "llamacpp", "saved-model")
    vim.b[sess].straps_provider = nil
    vim.b[sess].straps_llamacpp_model = "live-model"
    state.open_session_file(path)
    assert(vim.b[sess].straps_llamacpp_model == "live-model",
      "resume overwrote the buffer's model with " .. tostring(vim.b[sess].straps_llamacpp_model))
  end)

  it("state: a .meta holding valid JSON that is not an object warns on resume and restores nothing", function()
    local sess = state.new_session()
    local path = vim.api.nvim_buf_get_name(sess)
    vim.api.nvim_buf_delete(sess, { force = true })
    vim.fn.writefile({ "[1,2]" }, path .. ".meta")
    local warned
    local real_notify = vim.notify
    vim.notify = function(msg, level) if level == vim.log.levels.WARN then warned = msg end end
    local resumed = state.open_session_file(path)
    vim.notify = real_notify
    assert(warned and warned:find("not a JSON object", 1, true), "no warning for a JSON array: " .. tostring(warned))
    assert(vim.b[resumed].straps_provider == nil, "a JSON array restored " .. tostring(vim.b[resumed].straps_provider))
  end)

  it("state: a failed title write returns false and the error", function()
    local path = vim.fn.tempname() .. "/missing-dir/t.straps"
    local ok, err = state.set_session_title(path, "x")
    assert(ok == false, "a title write into a missing directory succeeded")
    assert(type(err) == "string" and err:find("t.straps.meta.tmp", 1, true), "error missing: " .. tostring(err))
  end)

  it("dispatcher: a per-session provider switch made during a request survives the request", function()
    local spy_a = registry.get("fn.provider_anthropic").source
    straps.config.provider = "anthropic"
    local sess = state.new_session()
    local path = vim.api.nvim_buf_get_name(sess)
    _G.__switch_buf = sess
    registry.define({ name = "fn.provider_anthropic", kind = "fn", doc = "spy: switches mid-request",
      source = [[return function()
  require("straps.state").set_session_pin(_G.__switch_buf, "llamacpp", "local-model")
  return { content = {}, stop_reason = "end_turn" }
end]] })
    registry.call("fn.provider", { messages = {} }, { bufnr = sess })
    registry.define({ name = "fn.provider_anthropic", kind = "fn", doc = "spy", source = spy_a })
    _G.__switch_buf = nil
    straps.config.provider = nil
    local provider, model = state.session_pin(path)
    assert(vim.b[sess].straps_provider == "llamacpp", "the request reverted the switch to " .. tostring(vim.b[sess].straps_provider))
    assert(provider == "llamacpp" and model == "local-model", ".meta holds " .. tostring(provider) .. "/" .. tostring(model))
  end)

  it("dispatcher: the backend gets ctx.model, and a global model change during the request does not change the pin", function()
    local spy_a = registry.get("fn.provider_anthropic").source
    straps.config.provider = "anthropic"
    local saved_model = straps.config.model
    straps.config.model = "claude-dispatched"
    local sess = state.new_session()
    local path = vim.api.nvim_buf_get_name(sess)
    registry.define({ name = "fn.provider_anthropic", kind = "fn", doc = "spy: global pick mid-request",
      source = [[return function(req, ctx)
  _G.__ctx_model = ctx.model
  require("straps").config.model = "claude-picked-later"
  return { content = {}, stop_reason = "end_turn" }
end]] })
    registry.call("fn.provider", { messages = {} }, { bufnr = sess })
    registry.define({ name = "fn.provider_anthropic", kind = "fn", doc = "spy", source = spy_a })
    local seen = _G.__ctx_model
    _G.__ctx_model = nil
    straps.config.model = saved_model
    straps.config.provider = nil
    local _, model = state.session_pin(path)
    assert(seen == "claude-dispatched", "ctx.model was " .. tostring(seen))
    assert(model == "claude-dispatched", "the pin recorded " .. tostring(model) .. " instead of the model sent")
  end)

  it("dispatcher: a per-session model pick during a request survives the request", function()
    local spy_a = registry.get("fn.provider_anthropic").source
    straps.config.provider = "anthropic"
    local sess = state.new_session()
    local path = vim.api.nvim_buf_get_name(sess)
    _G.__pick_buf = sess
    registry.define({ name = "fn.provider_anthropic", kind = "fn", doc = "spy: model pick mid-request",
      source = [[return function()
  require("straps.state").set_session_pin(_G.__pick_buf, "anthropic", "claude-picked-mid-request")
  return { content = {}, stop_reason = "end_turn" }
end]] })
    registry.call("fn.provider", { messages = {} }, { bufnr = sess })
    registry.define({ name = "fn.provider_anthropic", kind = "fn", doc = "spy", source = spy_a })
    _G.__pick_buf = nil
    straps.config.provider = nil
    local _, model = state.session_pin(path)
    assert(vim.b[sess].straps_model == "claude-picked-mid-request", "the request reverted the pick to " .. tostring(vim.b[sess].straps_model))
    assert(model == "claude-picked-mid-request", ".meta holds " .. tostring(model))
  end)

  it("dispatcher: the backend gets ctx.provider and ctx.model_entry", function()
    local spy_l = registry.get("fn.provider_llamacpp").source
    straps.config.provider = "llamacpp"
    local saved_list, saved_model = straps.config.llamacpp_models, straps.config.llamacpp_model
    straps.config.llamacpp_models = { { id = "ctx-model", thinking = "adaptive" } }
    straps.config.llamacpp_model = "ctx-model"
    registry.define({ name = "fn.provider_llamacpp", kind = "fn", doc = "spy: ctx fields",
      source = [[return function(req, ctx)
  _G.__ctx_seen = { provider = ctx.provider, entry = ctx.model_entry }
  return { content = {}, stop_reason = "end_turn" }
end]] })
    registry.call("fn.provider", { messages = {} }, { bufnr = nil })
    registry.define({ name = "fn.provider_llamacpp", kind = "fn", doc = "spy", source = spy_l })
    local seen = _G.__ctx_seen
    _G.__ctx_seen = nil
    straps.config.llamacpp_models, straps.config.llamacpp_model = saved_list, saved_model
    straps.config.provider = nil
    assert(seen and seen.provider == "llamacpp", "ctx.provider: " .. vim.inspect(seen))
    assert(seen.entry and seen.entry.id == "ctx-model" and seen.entry.thinking == "adaptive",
      "ctx.model_entry: " .. vim.inspect(seen.entry))
  end)

  it("provider.resolve_provider: vim.b first, then setup{}, then the pref file, then anthropic, with the source", function()
    local providers = require("straps.provider")
    local sess = state.new_session()
    vim.b[sess].straps_provider = "openai"
    local b, b_src = providers.resolve_provider(sess, { provider = "llamacpp" })
    local c, c_src = providers.resolve_provider(nil, { provider = "llamacpp" })
    registry.call("fn.provider_pref", "openai")
    local p, p_src = providers.resolve_provider(nil, {})
    vim.fn.delete(pd .. "/straps/provider")
    local d, d_src = providers.resolve_provider(nil, {})
    assert(b == "openai" and b_src:find("vim.b", 1, true), b .. " / " .. b_src)
    assert(c == "llamacpp" and c_src == "setup{ provider }", c .. " / " .. c_src)
    assert(p == "openai" and p_src:find("pref file", 1, true), p .. " / " .. p_src)
    assert(d == "anthropic", d)
  end)

  it("state: set_session_pin refuses an unknown provider and pins nothing", function()
    local sess = state.new_session()
    local path = vim.api.nvim_buf_get_name(sess)
    local ok, err = state.set_session_pin(sess, "bogus", "m1")
    assert(ok == nil and tostring(err):find("unknown provider bogus", 1, true), tostring(err))
    assert(vim.b[sess].straps_provider == nil, "an unknown provider was pinned in memory")
    assert((state.session_pin(path)) == nil, "an unknown provider was written to .meta")
  end)

  it("dispatcher: a pinned model keeps its entry after a global pick elsewhere changes the model pref", function()
    local spy_a = registry.get("fn.provider_anthropic").source
    straps.config.provider = "anthropic"
    local saved_models, saved_model = straps.config.models, straps.config.model
    straps.config.models = {}
    straps.config.model = nil
    registry.call("fn.model_pref", "anthropic", "claude-from-pref", { id = "claude-from-pref", thinking = "adaptive" })
    local sess = state.new_session()
    local path = vim.api.nvim_buf_get_name(sess)
    registry.define({ name = "fn.provider_anthropic", kind = "fn", doc = "spy: records ctx.model_entry",
      source = [[return function(req, ctx)
  _G.__entries = _G.__entries or {}
  table.insert(_G.__entries, ctx.model_entry and ctx.model_entry.thinking or "none")
  return { content = {}, stop_reason = "end_turn" }
end]] })
    _G.__entries = {}
    registry.call("fn.provider", { messages = {} }, { bufnr = sess })
    registry.call("fn.model_pref", "anthropic", "claude-other")
    registry.call("fn.provider", { messages = {} }, { bufnr = sess })
    registry.define({ name = "fn.provider_anthropic", kind = "fn", doc = "spy", source = spy_a })
    local seen = _G.__entries
    _G.__entries = nil
    local _, model, _, entry = state.session_pin(path)
    vim.fn.delete(pd .. "/straps/model_anthropic")
    straps.config.models, straps.config.model = saved_models, saved_model
    straps.config.provider = nil
    assert(seen[1] == "adaptive" and seen[2] == "adaptive", "the entry was lost: " .. vim.inspect(seen))
    assert(model == "claude-from-pref" and entry and entry.thinking == "adaptive", ".meta lost the entry: " .. vim.inspect(entry))
  end)

  it("state: pinning the same model without an entry keeps the entry already saved", function()
    local sess = state.new_session()
    local path = vim.api.nvim_buf_get_name(sess)
    state.set_session_pin(sess, "llamacpp", "m1", { id = "m1", thinking = "budget" })
    state.set_session_pin(sess, "llamacpp", "m1", nil)
    local _, _, _, entry = state.session_pin(path)
    assert(entry and entry.thinking == "budget", "the saved entry was erased: " .. vim.inspect(entry))
  end)

  it("dispatcher: an unreadable provider pref file raises instead of falling back to anthropic", function()
    straps.config.provider = nil
    vim.fn.mkdir(pd .. "/straps", "p")
    vim.fn.writefile({ "llamacpp" }, pd .. "/straps/provider")
    vim.uv.fs_chmod(pd .. "/straps/provider", 0)
    local sess = state.new_session()
    local ok, err = pcall(registry.call, "fn.provider", { messages = {} }, { bufnr = sess })
    vim.uv.fs_chmod(pd .. "/straps/provider", 420)
    vim.fn.delete(pd .. "/straps/provider")
    assert(not ok and tostring(err):find("exists but could not be read", 1, true), tostring(err))
    assert(vim.b[sess].straps_provider == nil, "a session was pinned despite the unreadable pref")
  end)

  it("dispatcher: a model pref file that is not a JSON object raises instead of using the default model", function()
    straps.config.provider = "anthropic"
    local saved_model = straps.config.model
    straps.config.model = nil
    vim.fn.mkdir(pd .. "/straps", "p")
    vim.fn.writefile({ "claude-opus-4-8" }, pd .. "/straps/model_anthropic")
    local ok, err = pcall(registry.call, "fn.provider", { messages = {} }, { bufnr = nil })
    vim.fn.delete(pd .. "/straps/model_anthropic")
    straps.config.model = saved_model
    straps.config.provider = nil
    assert(not ok and tostring(err):find("is not a JSON object", 1, true), tostring(err))
  end)

  it("fn.provider_pref and fn.model_pref write through a temporary file and leave none behind", function()
    registry.call("fn.provider_pref", "openai")
    registry.call("fn.model_pref", "openai", "gpt-x")
    local leftovers = vim.fn.glob(pd .. "/straps/*.tmp", false, true)
    vim.fn.delete(pd .. "/straps/provider")
    vim.fn.delete(pd .. "/straps/model_openai")
    assert(#leftovers == 0, "temporary files left: " .. vim.inspect(leftovers))
  end)

  it("provider.redact_url hides credentials with or without a scheme, and the query and fragment", function()
    local redact = require("straps.provider").redact_url
    assert(redact("http://u:p@ss@h:8080/x?k=1") == "http://***@h:8080/x?***", redact("http://u:p@ss@h:8080/x?k=1"))
    assert(redact("admin:secret@10.0.0.5:8080") == "***@10.0.0.5:8080", redact("admin:secret@10.0.0.5:8080"))
    assert(redact("http://h/#tok=abc") == "http://h/?***", redact("http://h/#tok=abc"))
    assert(redact("http://127.0.0.1:8080") == "http://127.0.0.1:8080", redact("http://127.0.0.1:8080"))
  end)

  it("state: a changed entry for the same model rewrites .meta", function()
    local sess = state.new_session()
    local path = vim.api.nvim_buf_get_name(sess)
    state.set_session_pin(sess, "llamacpp", "m1", { id = "m1" })
    state.set_session_pin(sess, "llamacpp", "m1", { id = "m1", thinking = "adaptive" })
    local _, _, _, entry = state.session_pin(path)
    assert(entry and entry.thinking == "adaptive", "the changed entry was not written: " .. vim.inspect(entry))
  end)

  it("state: an entry whose id differs from the pinned model is not saved", function()
    local sess = state.new_session()
    local path = vim.api.nvim_buf_get_name(sess)
    state.set_session_pin(sess, "llamacpp", "m1", { id = "other" })
    local _, _, _, entry = state.session_pin(path)
    assert(entry == nil, "a mismatched entry was saved: " .. vim.inspect(entry))
  end)

  it("provider.merge_model_entry adds an entry once and never duplicates an id", function()
    local providers = require("straps.provider")
    local cfg = { llamacpp_models = { { id = "a" } } }
    providers.merge_model_entry("llamacpp", { id = "a", thinking = "adaptive" }, cfg)
    providers.merge_model_entry("llamacpp", { id = "b" }, cfg)
    providers.merge_model_entry("llamacpp", { id = "b" }, cfg)
    assert(#cfg.llamacpp_models == 2, "list length " .. #cfg.llamacpp_models)
    assert(cfg.llamacpp_models[1].thinking == nil, "merge replaced the existing entry")
  end)

  it("state: a pin write that fails, then succeeds, then fails warns twice and returns false, err", function()
    local sess = state.new_session()
    local good = vim.api.nvim_buf_get_name(sess)
    local bad = vim.fn.tempname() .. "/missing/s.straps"
    local warnings = {}
    local real_notify = vim.notify
    vim.notify = function(msg, level) if level == vim.log.levels.WARN then warnings[#warnings + 1] = msg end end
    vim.api.nvim_buf_set_name(sess, bad)
    local ok1, err1 = state.set_session_pin(sess, "llamacpp", "m1")
    vim.api.nvim_buf_set_name(sess, good)
    local ok2 = state.set_session_pin(sess, "llamacpp", "m2")
    vim.api.nvim_buf_set_name(sess, bad)
    state.set_session_pin(sess, "llamacpp", "m3")
    vim.notify = real_notify
    assert(ok1 == false and type(err1) == "string", "failed write returned " .. tostring(ok1))
    assert(ok2 == true, "successful write returned " .. tostring(ok2))
    assert(#warnings == 2, "expected two warnings, got " .. #warnings)
  end)

  it("state: resuming a session whose first request is still running does not warn about a missing pin", function()
    local sess = state.new_session()
    local path = vim.api.nvim_buf_get_name(sess)
    state.append(sess, "user", nil, "hello")
    state.append(sess, "assistant", nil, "")
    local loop_mod = require("straps.loop")
    local real_running = loop_mod.running
    loop_mod.running = function(b) return b == sess end
    local warned
    local real_notify = vim.notify
    vim.notify = function(msg, level) if level == vim.log.levels.WARN then warned = msg end end
    state.open_session_file(path)
    vim.notify = real_notify
    loop_mod.running = real_running
    assert(warned == nil, "a running session warned: " .. tostring(warned))
  end)

  it("dispatcher: a backend that returns result.model gets that model pinned", function()
    local spy_a = registry.get("fn.provider_anthropic").source
    straps.config.provider = "anthropic"
    local sess = state.new_session()
    local path = vim.api.nvim_buf_get_name(sess)
    registry.define({ name = "fn.provider_anthropic", kind = "fn", doc = "spy: own model",
      source = [[return function() return { content = {}, stop_reason = "end_turn", model = "claude-own-choice" } end]] })
    registry.call("fn.provider", { messages = {} }, { bufnr = sess })
    registry.define({ name = "fn.provider_anthropic", kind = "fn", doc = "spy", source = spy_a })
    straps.config.provider = nil
    local _, model = state.session_pin(path)
    assert(model == "claude-own-choice", "pinned " .. tostring(model))
  end)

  it("dispatcher: the pin saves the model's list entry, and a resume merges it back into the model list", function()
    straps.config.provider = "anthropic"
    local saved_models, saved_model = straps.config.models, straps.config.model
    straps.config.models = { { id = "claude-discovered", thinking = "adaptive", max_output = 4321 } }
    straps.config.model = "claude-discovered"
    local sess = state.new_session()
    local path = vim.api.nvim_buf_get_name(sess)
    registry.call("fn.provider", { messages = {} }, { bufnr = sess })
    local _, _, _, entry = state.session_pin(path)
    vim.api.nvim_buf_delete(sess, { force = true })
    straps.config.models = {}
    straps.config.model = saved_model
    state.open_session_file(path)
    local restored = require("straps.provider").model_entry("anthropic", "claude-discovered", straps.config)
    straps.config.models = saved_models
    straps.config.provider = nil
    assert(entry and entry.thinking == "adaptive", ".meta has no entry: " .. vim.inspect(entry))
    assert(restored and restored.thinking == "adaptive" and restored.max_output == 4321,
      "the entry was not merged back: " .. vim.inspect(restored))
  end)

  it("state: renaming onto a transcript whose .meta already exists rewrites that .meta on the next request", function()
    straps.config.provider = "llamacpp"
    local sess = state.new_session()
    registry.call("fn.provider", { messages = {} }, { bufnr = sess })
    local renamed = vim.fn.tempname() .. ".straps"
    vim.fn.writefile({ vim.json.encode({ provider = "openai" }) }, renamed .. ".meta")
    vim.api.nvim_buf_set_name(sess, renamed)
    registry.call("fn.provider", { messages = {} }, { bufnr = sess })
    straps.config.provider = nil
    assert((state.session_pin(renamed)) == "llamacpp", "the existing .meta kept " .. tostring((state.session_pin(renamed))))
  end)

  it("state: an unchanged pin does not rewrite .meta, including right after a resume", function()
    local sess = state.new_session()
    local path = vim.api.nvim_buf_get_name(sess)
    state.set_session_pin(sess, "llamacpp", "m1")
    local sentinel = vim.json.encode({ provider = "llamacpp", model = "m1", title = "sentinel" })
    vim.fn.writefile({ sentinel }, path .. ".meta")
    state.set_session_pin(sess, "llamacpp", "m1")
    local after_pin = table.concat(vim.fn.readfile(path .. ".meta"), "\n")
    vim.api.nvim_buf_delete(sess, { force = true })
    local resumed = state.open_session_file(path)
    state.set_session_pin(resumed, "llamacpp", "m1")
    local after_resume = table.concat(vim.fn.readfile(path .. ".meta"), "\n")
    assert(after_pin == sentinel, "an unchanged pin rewrote .meta: " .. after_pin)
    assert(after_resume == sentinel, "an unchanged pin after resume rewrote .meta: " .. after_resume)
  end)

  it("state: a corrupt .meta on a reused buffer warns that the buffer keeps its provider, and the next pin rewrites it", function()
    local sess = state.new_session()
    local path = vim.api.nvim_buf_get_name(sess)
    state.set_session_pin(sess, "llamacpp", "m1")
    vim.fn.writefile({ "not json" }, path .. ".meta")
    local warned
    local real_notify = vim.notify
    vim.notify = function(msg, level) if level == vim.log.levels.WARN then warned = msg end end
    state.open_session_file(path)
    vim.notify = real_notify
    state.set_session_pin(sess, "llamacpp", "m1")
    assert(warned and warned:find("keeps provider llamacpp", 1, true), "warning wrong: " .. tostring(warned))
    assert((state.session_pin(path)) == "llamacpp", "the corrupt .meta was not rewritten")
  end)

  it("state: resuming a transcript with assistant turns and no saved provider warns; one without assistant turns does not", function()
    local function resume_warning(with_assistant)
      local sess = state.new_session()
      local path = vim.api.nvim_buf_get_name(sess)
      state.append(sess, "user", nil, "hello")
      if with_assistant then state.append(sess, "assistant", nil, "hi") end
      vim.api.nvim_buf_call(sess, function() vim.cmd("silent write") end)
      vim.api.nvim_buf_delete(sess, { force = true })
      vim.fn.delete(path .. ".meta")
      local warned
      local real_notify = vim.notify
      vim.notify = function(msg, level) if level == vim.log.levels.WARN then warned = msg end end
      state.open_session_file(path)
      vim.notify = real_notify
      return warned
    end
    local with = resume_warning(true)
    local without = resume_warning(false)
    assert(with and with:find("has no saved provider", 1, true), "no warning: " .. tostring(with))
    assert(without == nil, "a transcript with no assistant turns warned: " .. tostring(without))
  end)

  it("state: a .meta naming an unknown provider restores it, and the next request raises naming the source", function()
    local sess = state.new_session()
    local path = vim.api.nvim_buf_get_name(sess)
    vim.api.nvim_buf_delete(sess, { force = true })
    vim.fn.writefile({ vim.json.encode({ provider = "retired", model = "x" }) }, path .. ".meta")
    local resumed = state.open_session_file(path)
    local ok, err = pcall(registry.call, "fn.provider", { messages = {} }, { bufnr = resumed })
    assert(vim.b[resumed].straps_model == nil, "a model was restored into the anthropic slot for an unknown provider")
    assert(not ok and tostring(err):find("unknown provider retired (expected one of:", 1, true)
      and tostring(err):find("), from the session's vim.b straps_provider", 1, true),
      tostring(err))
  end)

  it("state: a failed rename in a .meta write removes the temporary file and raises", function()
    local mp = vim.fn.tempname() .. ".straps.meta"
    vim.fn.mkdir(mp, "p")
    vim.fn.writefile({ "x" }, mp .. "/occupied")
    local ok = pcall(state._write_meta_fields, mp, { title = "t" })
    assert(not ok, "a rename onto a directory succeeded")
    assert(vim.fn.filereadable(mp .. ".tmp") == 0, "the temporary file was left behind")
  end)

  it("dispatcher: every provider name reaches its own backend", function()
    local seen = {}
    for _, name in ipairs(require("straps.provider").provider_names()) do
      local entry = "fn.provider_" .. name
      local real = registry.get(entry)
      registry.define({ name = entry, kind = "fn", doc = "spy",
        source = ([[return function() return { content = {}, stop_reason = "end_turn", _who = %q } end]]):format(name) })
      straps.config.provider = name
      local resp = registry.call("fn.provider", { messages = {} }, { bufnr = nil })
      registry.define({ name = real.name, kind = real.kind, doc = real.doc, source = real.source })
      seen[name] = resp._who
    end
    straps.config.provider = nil
    for name, who in pairs(seen) do
      assert(who == name, name .. " reached " .. tostring(who))
    end
  end)

  it("state: a blank .meta reads as empty, warns nothing, and takes a title", function()
    local sess = state.new_session()
    local path = vim.api.nvim_buf_get_name(sess)
    vim.api.nvim_buf_delete(sess, { force = true })
    vim.fn.writefile({}, path .. ".meta")
    local warned
    local real_notify = vim.notify
    vim.notify = function(msg, level) if level == vim.log.levels.WARN then warned = msg end end
    state.open_session_file(path)
    vim.notify = real_notify
    local ok, err = state.set_session_title(path, "after crash")
    assert(warned == nil, "a blank .meta warned: " .. tostring(warned))
    assert(ok, "title write failed on a blank .meta: " .. tostring(err))
    assert(state.session_title(path) == "after crash", "title not saved: " .. tostring(state.session_title(path)))
  end)

  it("state: the pin saves the session's model with the provider and a resume restores both", function()
    straps.config.provider = "llamacpp"
    local sess = state.new_session()
    local path = vim.api.nvim_buf_get_name(sess)
    vim.b[sess].straps_llamacpp_model = "qwen-session"
    registry.call("fn.provider", { messages = {} }, { bufnr = sess })
    straps.config.provider = nil
    local provider, model = state.session_pin(path)
    vim.api.nvim_buf_delete(sess, { force = true })
    local resumed = state.open_session_file(path)
    assert(provider == "llamacpp" and model == "qwen-session",
      "pin saved " .. tostring(provider) .. "/" .. tostring(model))
    assert(vim.b[resumed].straps_provider == "llamacpp", "provider not restored")
    assert(vim.b[resumed].straps_llamacpp_model == "qwen-session",
      "model not restored: " .. tostring(vim.b[resumed].straps_llamacpp_model))
    vim.b[resumed].straps_llamacpp_model = nil
    state.set_session_pin(resumed, "llamacpp")
    local _, cleared = state.session_pin(path)
    assert(cleared == nil, "an unset session model stayed in .meta: " .. tostring(cleared))
  end)

  it("state: a resume keeps a provider the loaded buffer already has", function()
    local sess = state.new_session()
    local path = vim.api.nvim_buf_get_name(sess)
    state.set_session_pin(sess, "llamacpp")
    vim.b[sess].straps_provider = "openai"
    local same = state.open_session_file(path)
    assert(same == sess, "open_session_file did not reuse the loaded buffer")
    assert(vim.b[sess].straps_provider == "openai",
      "resume overwrote the buffer's provider with " .. tostring(vim.b[sess].straps_provider))
  end)

  it("state: a file buffer that is not a session is never pinned", function()
    local name = vim.fn.tempname() .. ".lua"
    local buf = vim.fn.bufadd(name)
    vim.fn.bufload(buf)
    state.set_session_pin(buf, "llamacpp")
    assert(vim.b[buf].straps_provider == nil, "a non-session buffer was pinned")
    assert(vim.fn.filereadable(name .. ".meta") == 0, "a non-session buffer wrote a .meta file")
  end)

  it("state: .meta holds exactly the fields set, over every set/clear sequence up to length 4", function()
    local ops = {
      { title = "t1" }, { title = false }, { provider = "llamacpp" }, { provider = false }, { model = "m1" }, { model = false },
    }
    local mp = vim.fn.tempname() .. ".straps.meta"
    local checked = 0
    local function run(seq)
      for start_name, content in pairs({ absent = false, blank = "", corrupt = "{not json", array = "[1,2]" }) do
        vim.fn.delete(mp)
        if content then vim.fn.writefile({ content }, mp) end
        local expect = {}
        for _, op in ipairs(seq) do
          state._write_meta_fields(mp, op)
          for k, v in pairs(op) do
            if v == false then expect[k] = nil else expect[k] = v end
          end
          local exists = vim.fn.filereadable(mp) == 1
          local label = start_name .. " " .. vim.inspect(seq)
          assert(exists == (next(expect) ~= nil), "file presence wrong after " .. label)
          if exists then
            local got = vim.json.decode(table.concat(vim.fn.readfile(mp), "\n"))
            assert(vim.deep_equal(got, expect), label .. ": " .. vim.inspect(got) .. " ~= " .. vim.inspect(expect))
          end
          assert(vim.fn.filereadable(mp .. ".tmp") == 0, "temporary file left behind after " .. label)
          checked = checked + 1
        end
      end
    end
    local function walk(seq, depth)
      if #seq > 0 then run(seq) end
      if depth == 0 then return end
      for _, op in ipairs(ops) do
        local next_seq = vim.list_extend(vim.deepcopy(seq), { op })
        walk(next_seq, depth - 1)
      end
    end
    walk({}, 4)
    assert(checked > 10000, "the sequence walk covered only " .. checked .. " writes")
  end)

  it("state: a scratch session buffer is pinned in memory and writes no .meta file", function()
    local buf = vim.api.nvim_create_buf(false, true)
    local name = vim.fn.tempname() .. ".straps"
    vim.api.nvim_buf_set_name(buf, name)
    vim.b[buf].straps_session = true
    state.set_session_pin(buf, "llamacpp")
    assert(vim.b[buf].straps_provider == "llamacpp", "scratch buffer not pinned in memory")
    assert(vim.fn.filereadable(name .. ".meta") == 0, "a scratch buffer wrote a .meta file")
  end)

  it("fn.list_models: an explicit unknown provider returns (nil, err) instead of resolving another", function()
    local saved_path = vim.env.PATH
    vim.env.PATH = tmp .. "/models_500:" .. real_path
    local models, why = registry.call("fn.list_models", "llama.cpp")
    vim.env.PATH = saved_path
    assert(models == nil and tostring(why):find("unknown provider llama.cpp", 1, true), tostring(why))
  end)

  -- Restore the real backends the rest of the suite (and any later run) needs.
  step(function()
    registry.define({ name = "fn.provider_anthropic", kind = "fn",
      doc = "restored", source = real_anthropic })
    registry.define({ name = "fn.provider_openai", kind = "fn",
      doc = "restored", source = real_openai })
    registry.define({ name = "fn.provider_llamacpp", kind = "fn",
      doc = "restored", source = real_llamacpp })
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

  it("fn.openai_api_key: no env and no file errors naming OPENAI_API_KEY and :StrapsLogin", function()
    vim.fn.delete(kd .. "/straps/openai_api_key")
    vim.env.OPENAI_API_KEY = nil
    local ok, err = pcall(registry.call, "fn.openai_api_key")
    assert(not ok and tostring(err):find("OPENAI_API_KEY", 1, true), "wrong error: " .. tostring(err))
    assert(tostring(err):find(":StrapsLogin openai", 1, true), "error should mention :StrapsLogin: " .. tostring(err))
  end)

  step(function()
    vim.env.OPENAI_API_KEY = saved_oai
    vim.env.XDG_CONFIG_HOME = saved_xdg2
  end)
end

-- ---------------------------------------------------------- llamacpp backend
-- fn.provider_llamacpp drives fn.anthropic_messages at llamacpp_base_url with
-- no x-api-key, an optional Bearer key, the llama.cpp model slot and no gzip.
-- Its own fake directory keeps the scripted fixture's argv/body files intact.
do
  local ld = tmp .. "/llama"
  local saved = {}
  local function read(name) return table.concat(vim.fn.readfile(ld .. "/" .. name), "\n") end
  local function reset()
    for _, name in ipairs(vim.fn.readdir(ld)) do
      if name ~= "curl" and name ~= "gzip" then vim.fn.delete(ld .. "/" .. name) end
    end
  end
  local function session(text, model)
    local b = state.new_session()
    if model then vim.b[b].straps_llamacpp_model = model end
    state.append(b, "user", nil, text)
    loop.start(b)
    vim.wait(15000, function() return not loop.running(b) end, 50)
    return b, table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
  end
  local text1, argv1, body1, body2
  local lines_keyed, argv_keyed
  local gz_argv, gz_body
  local nomodel_text, nomodel_ok, nomodel_err
  local fail_text
  local switched_body, leak_argv, redefined_argv, llama_fallback_argv, per_server_argv
  local v1_argv, blank_body, guard_body, adaptive_body, budget_body, pref_entry_body, own_model_pin

  step(function()
    vim.fn.mkdir(ld, "p")
    write_exec(ld .. "/curl", ([[#!/usr/bin/env bash
D=%q
N=$(cat "$D/n" 2>/dev/null || echo 0); N=$((N+1)); echo $N > "$D/n"
printf '%%s\n' "$*" >> "$D/argv"
cat > "$D/body.$N"
if [ -f "$D/fail" ]; then
  echo "STRAPS_HTTP_STATUS:400" >&2
  echo '{"error":{"code":400,"message":"model name is missing from the request","type":"invalid_request_error"}}'
  exit 0
fi
echo "STRAPS_HTTP_STATUS:200" >&2
if [ "$N" = 1 ] && [ -f "$D/tool" ]; then
cat <<'EOF'
event: message_start
data: {"type":"message_start","message":{"usage":{"input_tokens":50}}}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"use bash"}}

event: content_block_start
data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"Lt1","name":"bash"}}

event: content_block_delta
data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"command\":\"echo llama-e2e-output\"}"}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":""}}

event: content_block_stop
data: {"type":"content_block_stop","index":0}

event: content_block_stop
data: {"type":"content_block_stop","index":1}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"tool_use"}}

event: message_stop
data: {"type":"message_stop"}
EOF
else
cat <<'EOF'
event: message_start
data: {"type":"message_start","message":{"usage":{"input_tokens":60}}}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"llama done"}}

event: content_block_stop
data: {"type":"content_block_stop","index":0}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}

event: message_stop
data: {"type":"message_stop"}
EOF
fi
]]):format(ld))
    write_exec(ld .. "/gzip", [[#!/usr/bin/env bash
cat > /dev/null
printf 'GZIPPED'
]])
    saved.path = vim.env.PATH
    saved.provider = straps.config.provider
    saved.anthropic_key = vim.env.ANTHROPIC_API_KEY
    saved.llama_key = vim.env.LLAMACPP_API_KEY
    saved.llama_server_key = vim.env.LLAMA_API_KEY
    vim.env.LLAMA_API_KEY = nil
    saved.xdg = vim.env.XDG_CONFIG_HOME
    saved.base_url = straps.config.base_url
    saved.llamacpp_base_url = straps.config.llamacpp_base_url
    saved.llamacpp_model = straps.config.llamacpp_model
    vim.env.PATH = ld .. ":" .. real_path
    vim.env.ANTHROPIC_API_KEY = nil
    vim.env.LLAMACPP_API_KEY = nil
    vim.env.XDG_CONFIG_HOME = vim.fn.tempname()
    vim.fn.mkdir(vim.env.XDG_CONFIG_HOME, "p")
    straps.config.provider = "llamacpp"
    straps.config.base_url = "http://anthropic-must-not-be-used.invalid"
    straps.config.llamacpp_base_url = "http://straps-llama.invalid:8080"
    straps.config.llamacpp_model = "config-model"
    saved.llamacpp_models = straps.config.llamacpp_models
    straps.config.llamacpp_models = { { id = "buffer-model", max_output = 1234 } }

    reset()
    vim.fn.writefile({}, ld .. "/tool")
    local _
    _, text1 = session("run echo via bash", "buffer-model")
    argv1 = read("argv")
    body1 = vim.json.decode(read("body.1"))
    body2 = vim.json.decode(read("body.2"))
    straps.config.llamacpp_models = saved.llamacpp_models

    reset()
    vim.env.LLAMACPP_API_KEY = "llama-secret"
    session("keyed", nil)
    argv_keyed = read("argv")
    lines_keyed = vim.json.decode(read("body.1"))
    vim.env.LLAMACPP_API_KEY = nil

    reset()
    straps.config.gzip = true
    session("compress me not", nil)
    straps.config.gzip = false
    gz_argv = read("argv")
    gz_body = read("body.1")

    reset()
    straps.config.llamacpp_model = nil
    _, nomodel_text = session("no model anywhere", nil)
    nomodel_ok, nomodel_err = pcall(registry.call, "fn.provider_llamacpp", { messages = {} }, {})
    straps.config.llamacpp_model = "config-model"

    reset()
    vim.fn.writefile({}, ld .. "/fail")
    _, fail_text = session("this one fails", nil)
    vim.fn.delete(ld .. "/fail")

    reset()
    local sb = state.new_session()
    vim.b[sb].straps_model = "claude-left-over"
    vim.b[sb].straps_llamacpp_model = "switched-model"
    state.append(sb, "user", nil, "switched from anthropic")
    loop.start(sb)
    vim.wait(15000, function() return not loop.running(sb) end, 50)
    switched_body = vim.json.decode(read("body.1"))

    reset()
    local real_llama = registry.get("fn.provider_llamacpp")
    vim.env.ANTHROPIC_API_KEY = "sk-ant-MUST-NOT-LEAVE"
    registry.define({ name = "fn.provider_llamacpp", kind = "fn", doc = "test: base_url without headers",
      source = [[return function(req, ctx)
  return require("straps.registry").call("fn.anthropic_messages", req, ctx,
    { base_url = "http://other-host.invalid:9000", model = "m", gzip = false })
end]] })
    session("opts without headers", nil)
    registry.define({ name = real_llama.name, kind = real_llama.kind, doc = real_llama.doc, source = real_llama.source })
    vim.env.ANTHROPIC_API_KEY = nil
    leak_argv = read("argv")

    reset()
    local real_anthropic = registry.get("fn.provider_anthropic")
    vim.env.ANTHROPIC_API_KEY = "sk-ant-MUST-NOT-LEAVE"
    registry.define({ name = "fn.provider_anthropic", kind = "fn", doc = "test: two-argument fn.provider_anthropic redefinition",
      source = [[return function(req, ctx)
  return require("straps.registry").call("fn.anthropic_messages", req, ctx)
end]] })
    session("redefined anthropic backend", nil)
    registry.define({ name = real_anthropic.name, kind = real_anthropic.kind, doc = real_anthropic.doc,
      source = real_anthropic.source })
    vim.env.ANTHROPIC_API_KEY = nil
    redefined_argv = read("argv")

    reset()
    vim.env.LLAMA_API_KEY = "llama-server-var"
    session("server variable", nil)
    vim.env.LLAMA_API_KEY = nil
    llama_fallback_argv = read("argv")

    reset()
    local real_key = registry.get("fn.llamacpp_api_key")
    registry.define({ name = "fn.llamacpp_api_key", kind = "fn", doc = "test: key per server",
      source = [[return function(opts) return "k-" .. tostring(opts and opts.base_url) end]] })
    session("key per server", nil)
    registry.define({ name = real_key.name, kind = real_key.kind, doc = real_key.doc, source = real_key.source })
    per_server_argv = read("argv")

    reset()
    straps.config.llamacpp_base_url = "http://straps-llama.invalid:8080/v1/"
    session("v1 suffix", nil)
    straps.config.llamacpp_base_url = "http://straps-llama.invalid:8080"
    v1_argv = read("argv")

    reset()
    session("blank buffer model", "")
    blank_body = vim.json.decode(read("body.1"))

    reset()
    local models_before, effort_before, llama_models_before = straps.config.models, straps.config.effort,
      straps.config.llamacpp_models
    straps.config.models = { { id = "config-model", thinking = "adaptive", max_output = 777 } }
    straps.config.llamacpp_models = nil
    straps.config.effort = "high"
    session("anthropic list must not apply", nil)
    straps.config.models, straps.config.effort, straps.config.llamacpp_models = models_before, effort_before,
      llama_models_before
    guard_body = vim.json.decode(read("body.1"))

    local efforts_before, effort_before2, list_before = straps.config.efforts, straps.config.effort,
      straps.config.llamacpp_models
    straps.config.efforts = { { name = "high", level = "high", budget_tokens = 4000 } }
    straps.config.effort = "high"
    reset()
    straps.config.llamacpp_models = { { id = "config-model", thinking = "adaptive" } }
    session("thinking-tagged adaptive", nil)
    adaptive_body = vim.json.decode(read("body.1"))
    reset()
    straps.config.llamacpp_models = { { id = "config-model", thinking = "budget" } }
    session("thinking-tagged budget", nil)
    budget_body = vim.json.decode(read("body.1"))
    straps.config.efforts, straps.config.effort, straps.config.llamacpp_models = efforts_before, effort_before2,
      list_before

    reset()
    local list_before2 = straps.config.llamacpp_models
    straps.config.llamacpp_models = {}
    registry.call("fn.model_pref", "llamacpp", "config-model", { id = "config-model", max_output = 4321 })
    session("entry from the model pref", nil)
    vim.fn.delete(vim.env.XDG_CONFIG_HOME .. "/straps/model_llamacpp")
    straps.config.llamacpp_models = list_before2
    pref_entry_body = vim.json.decode(read("body.1"))

    reset()
    local real_llama2 = registry.get("fn.provider_llamacpp")
    registry.define({ name = "fn.provider_llamacpp", kind = "fn", doc = "test: own model",
      source = [[return function(req, ctx)
  return require("straps.registry").call("fn.anthropic_messages", req, ctx,
    { base_url = "http://straps-llama.invalid:8080", model = "own-model", auth_headers = {}, gzip = false })
end]] })
    local own_buf = session("own model", nil)
    registry.define({ name = real_llama2.name, kind = real_llama2.kind, doc = real_llama2.doc, source = real_llama2.source })
    own_model_pin = select(2, state.session_pin(vim.api.nvim_buf_get_name(own_buf)))
  end)

  it("llamacpp: a backend that sends its own opts.model gets that model pinned (result.model)", function()
    assert(own_model_pin == "own-model", "pinned " .. tostring(own_model_pin))
  end)

  it("llamacpp: an entry stored with the model pref reaches the request (opts.model_entry)", function()
    assert(pref_entry_body.max_tokens == 4321, "the pref entry's max_output was not used: " .. tostring(pref_entry_body.max_tokens))
  end)

  it("llamacpp: a thinking-tagged llamacpp_models entry gets thinking in the request", function()
    assert(adaptive_body.thinking and adaptive_body.thinking.type == "adaptive",
      "adaptive thinking missing: " .. vim.inspect(adaptive_body.thinking))
    assert(adaptive_body.output_config and adaptive_body.output_config.effort == "high",
      "output_config.effort missing: " .. vim.inspect(adaptive_body.output_config))
    assert(budget_body.thinking and budget_body.thinking.type == "enabled" and budget_body.thinking.budget_tokens == 4000,
      "budget thinking missing: " .. vim.inspect(budget_body.thinking))
    assert(budget_body.max_tokens > 4000, "max_tokens not raised above the budget: " .. tostring(budget_body.max_tokens))
  end)

  it("llamacpp: a base URL ending in /v1/ is not doubled", function()
    assert(v1_argv:find("http://straps-llama.invalid:8080/v1/messages", 1, true), "url wrong:\n" .. v1_argv)
    assert(not v1_argv:find("/v1/v1/", 1, true), "/v1 doubled:\n" .. v1_argv)
  end)

  it("llamacpp: a blank per-session model falls back to config.llamacpp_model", function()
    assert(blank_body.model == "config-model", "model: " .. tostring(blank_body.model))
  end)

  it("llamacpp: with llamacpp_models unset, the Anthropic model list never supplies thinking or max_tokens", function()
    assert(guard_body.thinking == nil, "Anthropic thinking entry applied: " .. vim.inspect(guard_body.thinking))
    assert(guard_body.max_tokens ~= 777, "Anthropic max_output applied to a llamacpp request")
  end)

  it("fn.anthropic_messages raises when opts.base_url is set without opts.model", function()
    local ok, err = pcall(registry.call, "fn.anthropic_messages", { messages = {} }, {},
      { base_url = "http://elsewhere.invalid", label = "test" })
    assert(not ok and tostring(err):find("opts.base_url is set without opts.model", 1, true), tostring(err))
  end)

  it("llamacpp: the backend passes llamacpp_base_url to fn.llamacpp_api_key", function()
    assert(per_server_argv:find("Authorization: Bearer k-http://straps-llama.invalid:8080", 1, true),
      "the key fn did not receive opts.base_url:\n" .. per_server_argv)
  end)

  it("llamacpp: posts to llamacpp_base_url/v1/messages with no x-api-key and no Anthropic key", function()
    assert(argv1:find("http://straps-llama.invalid:8080/v1/messages", 1, true), "llamacpp url not in argv:\n" .. argv1)
    assert(not argv1:find("anthropic-must-not-be-used", 1, true), "config.base_url leaked:\n" .. argv1)
    assert(not argv1:find("x-api-key", 1, true), "x-api-key sent to llama-server:\n" .. argv1)
    assert(not argv1:find("Authorization", 1, true), "Authorization sent without LLAMACPP_API_KEY:\n" .. argv1)
  end)

  it("llamacpp: full tool round-trip completes, thinking stays out of the transcript", function()
    assert(text1:find("llama-e2e-output", 1, true), "bash tool_result missing:\n" .. text1)
    assert(text1:find("llama done", 1, true), "final text missing:\n" .. text1)
    assert(not text1:find("use bash", 1, true), "thinking text leaked into the transcript")
    local last = body2.messages[#body2.messages]
    assert(last.content[1].type == "tool_result" and last.content[1].content:find("llama-e2e-output", 1, true),
      "second request lacks the tool_result: " .. vim.inspect(last))
  end)

  it("llamacpp: vim.b straps_llamacpp_model wins over config.llamacpp_model", function()
    assert(body1.model == "buffer-model", "model wrong: " .. tostring(body1.model))
    assert(body1.max_tokens == 1234, "llamacpp_models max_output not used: " .. tostring(body1.max_tokens))
    assert(lines_keyed.model == "config-model", "config model not used without a buffer model: "
      .. tostring(lines_keyed.model))
  end)

  it("llamacpp: LLAMACPP_API_KEY is sent as a Bearer token, never as x-api-key", function()
    assert(argv_keyed:find("Authorization: Bearer llama-secret", 1, true), "Bearer header missing:\n" .. argv_keyed)
    assert(not argv_keyed:find("x-api-key", 1, true), "x-api-key sent:\n" .. argv_keyed)
  end)

  it("llamacpp: no gzip even with config.gzip on and gzip available", function()
    assert(not gz_argv:find("Content-Encoding", 1, true), "Content-Encoding sent to llama-server:\n" .. gz_argv)
    assert(vim.json.decode(gz_body).messages, "body is not plain JSON: " .. gz_body:sub(1, 80))
  end)

  it("llamacpp: no model set errors with the remedy, also for ctx = {}", function()
    assert(nomodel_text:find("set llamacpp_model in setup{} or run :StrapsModel", 1, true),
      "no-model error missing from the transcript:\n" .. nomodel_text)
    assert(not nomodel_ok and tostring(nomodel_err):find("set llamacpp_model in setup{} or run :StrapsModel", 1, true),
      "ctx = {} call should raise the no-model error with the remedy: " .. tostring(nomodel_err))
  end)

  it("llamacpp: a session switched from anthropic sends the llama model, not the left-over Claude id", function()
    assert(switched_body.model == "switched-model", "model wrong: " .. tostring(switched_body.model))
  end)

  it("fn.anthropic_messages: opts.base_url without opts.auth_headers sends no Anthropic key", function()
    assert(leak_argv:find("http://other-host.invalid:9000/v1/messages", 1, true), "request not sent:\n" .. leak_argv)
    assert(not leak_argv:find("x-api-key", 1, true), "Anthropic key sent to another host:\n" .. leak_argv)
    assert(not leak_argv:find("MUST-NOT-LEAVE", 1, true), "Anthropic key value in argv:\n" .. leak_argv)
  end)

  it("llamacpp: a redefined fn.provider_anthropic does not reroute llama.cpp sessions", function()
    assert(redefined_argv:find("http://straps-llama.invalid:8080/v1/messages", 1, true),
      "llamacpp request left the llama server:\n" .. redefined_argv)
    assert(not redefined_argv:find("x-api-key", 1, true), "Anthropic key sent:\n" .. redefined_argv)
  end)

  it("llamacpp: $LLAMA_API_KEY is the fallback key source", function()
    assert(llama_fallback_argv:find("Authorization: Bearer llama-server-var", 1, true),
      "LLAMA_API_KEY not used:\n" .. llama_fallback_argv)
  end)

  it("llamacpp: a failed request names the llamacpp backend", function()
    assert(fail_text:find("straps provider (llamacpp): request failed (HTTP 400)", 1, true),
      "labelled failure missing:\n" .. fail_text)
    assert(fail_text:find("model name is missing", 1, true), "server error message missing")
  end)

  step(function()
    vim.env.PATH = saved.path
    vim.env.ANTHROPIC_API_KEY = saved.anthropic_key
    vim.env.LLAMACPP_API_KEY = saved.llama_key
    vim.env.LLAMA_API_KEY = saved.llama_server_key
    vim.env.XDG_CONFIG_HOME = saved.xdg
    straps.config.provider = saved.provider
    straps.config.base_url = saved.base_url
    straps.config.llamacpp_base_url = saved.llamacpp_base_url
    straps.config.llamacpp_model = saved.llamacpp_model
  end)
end

-- ------------------------------------------------- llamacpp model discovery
do
  local md = tmp .. "/llama_models"
  local saved = {}
  local models, err, argv_nokey, argv_key
  step(function()
    vim.fn.mkdir(md, "p")
    write_exec(md .. "/curl", ([[#!/usr/bin/env bash
D=%q
printf '%%s\n' "$*" >> "$D/argv"
cat <<'EOF'
{"object":"list","data":[
  {"id":"qwen-dense","object":"model","owned_by":"llamacpp","status":{"value":"loaded"},"meta":{"n_ctx":131072}},
  {"id":"gpt-oss","object":"model","owned_by":"llamacpp","status":{"value":"unloaded"}}
]}
EOF
printf '\nSTRAPS_HTTP_STATUS:200\n'
]]):format(md))
    saved.path = vim.env.PATH
    saved.provider = straps.config.provider
    saved.anthropic_key = vim.env.ANTHROPIC_API_KEY
    saved.llama_key = vim.env.LLAMACPP_API_KEY
    saved.llama_server_key = vim.env.LLAMA_API_KEY
    saved.xdg = vim.env.XDG_CONFIG_HOME
    saved.llamacpp_base_url = straps.config.llamacpp_base_url
    vim.env.PATH = md .. ":" .. real_path
    vim.env.ANTHROPIC_API_KEY = nil
    vim.env.LLAMACPP_API_KEY = nil
    vim.env.LLAMA_API_KEY = nil
    vim.env.XDG_CONFIG_HOME = vim.fn.tempname()
    vim.fn.mkdir(vim.env.XDG_CONFIG_HOME, "p")
    straps.config.provider = "anthropic"
    straps.config.llamacpp_base_url = "http://straps-llama-models.invalid:8080"
    models, err = registry.call("fn.list_models", "llamacpp")
    argv_nokey = table.concat(vim.fn.readfile(md .. "/argv"), "\n")
    vim.fn.delete(md .. "/argv")
    vim.env.LLAMACPP_API_KEY = "llama-secret"
    registry.call("fn.list_models", "llamacpp")
    argv_key = table.concat(vim.fn.readfile(md .. "/argv"), "\n")
  end)

  it("fn.list_models (llamacpp) needs no key and hits llamacpp_base_url/v1/models without ?limit", function()
    assert(type(models) == "table", "expected a model list, got err: " .. tostring(err))
    assert(argv_nokey:find("http://straps-llama-models.invalid:8080/v1/models", 1, true), "url wrong:\n" .. argv_nokey)
    assert(not argv_nokey:find("limit=", 1, true), "?limit sent to llama-server:\n" .. argv_nokey)
    assert(not argv_nokey:find("x-api-key", 1, true), "x-api-key sent:\n" .. argv_nokey)
    assert(not argv_nokey:find("Authorization", 1, true), "Authorization sent without a key:\n" .. argv_nokey)
  end)

  it("fn.list_models (llamacpp) maps meta.n_ctx to context, id doubles as label", function()
    assert(#models == 2, "expected 2 models, got " .. #models)
    assert(models[1].id == "qwen-dense" and models[1].label == "qwen-dense", vim.inspect(models[1]))
    assert(models[1].context == 131072, "n_ctx not mapped: " .. tostring(models[1].context))
    assert(models[2].context == nil, "an unloaded model has no n_ctx: " .. tostring(models[2].context))
    assert(models[1].thinking == nil, "llama.cpp entries carry no thinking tag")
  end)

  it("fn.list_models (llamacpp) returns (nil, err) when fn.llamacpp_api_key raises", function()
    local real = registry.get("fn.llamacpp_api_key")
    registry.define({ name = "fn.llamacpp_api_key", kind = "fn", doc = "test",
      source = [[return function() error("vault locked") end]] })
    local ok, got, why = pcall(registry.call, "fn.list_models", "llamacpp")
    registry.define({ name = real.name, kind = real.kind, doc = real.doc, source = real.source })
    assert(ok, "fn.list_models raised: " .. tostring(got))
    assert(got == nil and tostring(why):find("fn.llamacpp_api_key failed", 1, true)
      and tostring(why):find("vault locked", 1, true), "wrong result: " .. tostring(why))
  end)

  it("fn.llamacpp_api_key: an empty LLAMACPP_API_KEY falls through to LLAMA_API_KEY; both empty is nil", function()
    local a, b = vim.env.LLAMACPP_API_KEY, vim.env.LLAMA_API_KEY
    vim.env.LLAMACPP_API_KEY = ""
    vim.env.LLAMA_API_KEY = "server-key"
    local got = registry.call("fn.llamacpp_api_key")
    vim.env.LLAMA_API_KEY = ""
    local none = registry.call("fn.llamacpp_api_key")
    vim.env.LLAMACPP_API_KEY, vim.env.LLAMA_API_KEY = a, b
    assert(got == "server-key", "empty LLAMACPP_API_KEY did not fall through: " .. tostring(got))
    assert(none == nil, "both empty should give nil: " .. tostring(none))
  end)

  it("fn.list_models (llamacpp) passes llamacpp_base_url to fn.llamacpp_api_key", function()
    local real = registry.get("fn.llamacpp_api_key")
    registry.define({ name = "fn.llamacpp_api_key", kind = "fn", doc = "test",
      source = [[return function(opts) return "k-" .. tostring(opts and opts.base_url) end]] })
    vim.fn.delete(md .. "/argv")
    registry.call("fn.list_models", "llamacpp")
    registry.define({ name = real.name, kind = real.kind, doc = real.doc, source = real.source })
    local argv = table.concat(vim.fn.readfile(md .. "/argv"), "\n")
    assert(argv:find("Authorization: Bearer k-http://straps-llama-models.invalid:8080", 1, true),
      "the key fn did not receive opts.base_url:\n" .. argv)
  end)

  it("fn.list_models (llamacpp) sends LLAMACPP_API_KEY as a Bearer token", function()
    assert(argv_key:find("Authorization: Bearer llama-secret", 1, true), "Bearer header missing:\n" .. argv_key)
    assert(not argv_key:find("x-api-key", 1, true), "x-api-key sent:\n" .. argv_key)
  end)

  step(function()
    vim.env.PATH = saved.path
    vim.env.ANTHROPIC_API_KEY = saved.anthropic_key
    vim.env.LLAMACPP_API_KEY = saved.llama_key
    vim.env.LLAMA_API_KEY = saved.llama_server_key
    vim.env.XDG_CONFIG_HOME = saved.xdg
    straps.config.provider = saved.provider
    straps.config.llamacpp_base_url = saved.llamacpp_base_url
  end)
end
