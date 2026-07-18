-- tests/run_compact.lua — fn.compact, state.list_blocks and auto-compaction.
--   nvim --headless -l tests/run_compact.lua
-- No network: fn.provider is a scripted stub driving five fat tool turns;
-- the REAL fn.compact (registered by provider.register()) does the editing.

local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(vim.fn.fnamemodify(here, ":p"), ":h:h")
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

local straps = require("straps")
-- Hermetic: durable sessions write under a throwaway dir, never the real data dir.
straps.config.session_dir = vim.fn.tempname()
local registry = require("straps.registry")
local state = require("straps.state")
local loop = require("straps.loop")
require("straps.provider").register() -- registers fn.compact (and friends)

local function define(name, kind, doc, source)
  registry.define({ name = name, kind = kind, doc = doc, source = source })
end

define("hook.confirm", "hook", "test: allow all", "return function() return true end")

-- Fat tool: ~8KB single-line result with a distinctive per-turn tag, so
-- compaction savings are unambiguous and stubs are identifiable.
define("tool.fat", "tool", "test: fat output", [==[
return function(input)
  return "FAT-RESULT-" .. tostring(input.n) .. " " .. string.rep("x", 8000)
end
]==])

-- Five tool turns; the fifth carries stop_reason end_turn so the run ends on
-- a tool turn (the last 2 assistant turns are turns 4 and 5). Inputs are
-- >200 bytes pretty-printed, so old tool_use blocks are compaction-eligible.
define("fn.provider", "fn", "test: five fat tool turns", [==[
return function(req, ctx)
  _G.compact_test_calls = _G.compact_test_calls + 1
  local n = _G.compact_test_calls
  ctx.await(function(resolve) vim.defer_fn(resolve, 2) end)
  return {
    stop_reason = n < 5 and "tool_use" or "end_turn",
    content = { { type = "tool_use", id = "t" .. n, name = "fat",
      input = { n = n, pad = string.rep("p", 300) } } },
  }
end
]==])

local function buf_bytes(bufnr)
  return vim.api.nvim_buf_get_offset(bufnr, vim.api.nvim_buf_line_count(bufnr))
end

local function buf_text(bufnr)
  return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
end

local function run_fat_session()
  _G.compact_test_calls = 0
  local bufnr = state.new_session()
  state.append(bufnr, "user", nil, "eat context")
  loop.start(bufnr)
  assert(vim.wait(10000, function() return not loop.running(bufnr) end, 10),
    "run did not finish within 10s")
  return bufnr
end

local FAT = string.rep("x", 8000)

local bufnr = run_fat_session()
local size_before = buf_bytes(bufnr)

case("state.list_blocks indexes the transcript", function()
  local blocks = state.list_blocks(bufnr)
  assert(blocks[1].kind == "system" and blocks[1].marker_lnum == 1, "first block should be system at line 1")
  local kinds = {}
  for _, b in ipairs(blocks) do
    kinds[b.kind] = (kinds[b.kind] or 0) + 1
    assert(b.marker_lnum < b.first_lnum, "first_lnum must exclude the marker line")
  end
  assert(kinds.tool_use == 5 and kinds.tool_result == 5,
    "want 5 tool_use + 5 tool_result blocks, got " .. vim.inspect(kinds))
  assert(kinds.assistant == 5, "want 5 assistant blocks, got " .. tostring(kinds.assistant))
  -- last block is the trailing empty user marker: empty content range
  local last = blocks[#blocks]
  assert(last.kind == "user" and last.first_lnum > last.last_lnum,
    "trailing user block should have an empty content range")
end)

local summary
case("fn.compact shrinks old tool blocks and reports it", function()
  -- Measure against the compactable portion only: the system block is
  -- fixed overhead compaction never touches, and its size tracks the core
  -- prompt — including it would make this a test of prompt length.
  local sys = state.list_blocks(bufnr)[1]
  assert(sys.kind == "system", "first block should be system")
  local sys_bytes = #table.concat(
    vim.api.nvim_buf_get_lines(bufnr, sys.first_lnum - 1, sys.last_lnum, false), "\n")
  summary = registry.call("fn.compact", bufnr)
  assert(type(summary) == "string" and summary:find("compacted", 1, true) == 1,
    "unexpected summary: " .. tostring(summary))
  assert(summary:find("compacted 6 blocks", 1, true),
    "want 6 blocks (3 tool_use + 3 tool_result): " .. summary)
  local size_after = buf_bytes(bufnr)
  assert(size_after - sys_bytes < (size_before - sys_bytes) / 2,
    ("buffer only shrank %d -> %d bytes (system block: %d)")
      :format(size_before, size_after, sys_bytes))
end)

case("last 2 assistant turns untouched, older ones stubbed", function()
  local text = buf_text(bufnr)
  assert(text:find("FAT-RESULT-4 " .. FAT, 1, true), "turn 4 tool_result was touched")
  assert(text:find("FAT-RESULT-5 " .. FAT, 1, true), "turn 5 tool_result was touched")
  for i = 1, 3 do
    assert(not text:find("FAT-RESULT-" .. i .. " " .. FAT, 1, true),
      "turn " .. i .. " tool_result not compacted")
  end
  local stubs = 0
  for _ in text:gmatch("%[compacted: was ") do stubs = stubs + 1 end
  assert(stubs == 3, "want 3 stubs, found " .. stubs)
  assert(text:find("bytes] FAT-RESULT-1", 1, true), "stub missing the first-line snippet")
end)

case("parse stays valid: alternating roles, ids intact, old inputs {}", function()
  local parsed = state.parse(bufnr)
  assert(parsed.system and parsed.system ~= "", "system block lost")
  local prev
  for _, msg in ipairs(parsed.messages) do
    assert(msg.role ~= prev, "adjacent messages share role " .. tostring(msg.role))
    prev = msg.role
  end
  local uses, results = {}, {}
  for _, msg in ipairs(parsed.messages) do
    for _, part in ipairs(msg.content) do
      if part.type == "tool_use" then uses[part.id] = part end
      if part.type == "tool_result" then results[part.tool_use_id] = part end
    end
  end
  for i = 1, 5 do
    assert(uses["t" .. i], "missing tool_use t" .. i)
    assert(results["t" .. i], "missing tool_result t" .. i)
  end
  for i = 1, 3 do
    assert(next(uses["t" .. i].input) == nil, "old tool_use t" .. i .. " input should be {}")
  end
  assert(uses.t4.input.pad and uses.t5.input.pad, "recent tool_use inputs were touched")
end)

case("second fn.compact is a stable no-op", function()
  local size = buf_bytes(bufnr)
  local s2 = registry.call("fn.compact", bufnr)
  assert(s2 == "nothing to compact", "second compact returned: " .. tostring(s2))
  assert(buf_bytes(bufnr) == size, "second compact changed the buffer")
end)

case("auto_compact_bytes triggers fn.compact mid-run and logs it", function()
  local logfile = vim.fn.tempname()
  straps.config.auto_compact_bytes = 4000
  straps.config.log_file = logfile
  local ok, b2 = pcall(run_fat_session)
  straps.config.auto_compact_bytes = nil
  straps.config.log_file = nil
  assert(ok, "auto-compact run failed: " .. tostring(b2))

  local compact_ev
  for _, line in ipairs(vim.fn.readfile(logfile)) do
    local ev = vim.json.decode(line)
    if ev.ev == "compact" then compact_ev = ev end
  end
  assert(compact_ev, "no {ev=compact} line in the log")
  assert(type(compact_ev.summary) == "string", "compact event missing summary string")
  -- old turns shrank mid-run: final buffer smaller than the uncompacted run's
  assert(buf_bytes(b2) < size_before,
    ("auto-compacted session (%d bytes) not smaller than uncompacted baseline (%d)")
      :format(buf_bytes(b2), size_before))
  local parsed = state.parse(b2)
  assert(#parsed.messages > 0, "auto-compacted transcript no longer parses")
end)

case("auto_compact_tokens triggers and logs est_tokens", function()
  local logfile = vim.fn.tempname()
  straps.config.auto_compact_tokens = 1000 -- fat session is ~40KB -> ~11k est tokens
  straps.config.log_file = logfile
  local ok, b = pcall(run_fat_session)
  straps.config.auto_compact_tokens = nil
  straps.config.log_file = nil
  assert(ok, "token-threshold run failed: " .. tostring(b))
  local ev
  for _, line in ipairs(vim.fn.readfile(logfile)) do
    local e = vim.json.decode(line)
    if e.ev == "compact" then ev = e end
  end
  assert(ev, "no compact event from auto_compact_tokens")
  assert(type(ev.est_tokens) == "number" and ev.est_tokens > 1000,
    "compact event missing/low est_tokens: " .. tostring(ev and ev.est_tokens))
end)

case("growth guard: compaction fires once, not every turn, near the limit", function()
  -- Big baseline + tiny per-turn growth: without the guard this compacts on
  -- every turn (each a cache-blowing rewrite); the guard requires ~20% growth
  -- since the last compaction, so it fires exactly once across the run.
  define("fn.provider", "fn", "test: tiny growth, 5 turns", [==[
return function(req, ctx)
  _G.gg_calls = (_G.gg_calls or 0) + 1
  local n = _G.gg_calls
  ctx.await(function(resolve) vim.defer_fn(resolve, 2) end)
  return {
    stop_reason = n < 5 and "tool_use" or "end_turn",
    content = { { type = "tool_use", id = "g" .. n, name = "tiny", input = { n = n } } },
  }
end
]==])
  _G.gg_calls = 0
  local logfile = vim.fn.tempname()
  straps.config.auto_compact_bytes = 10000
  straps.config.log_file = logfile
  local b = state.new_session()
  state.append(b, "user", nil, "BIG " .. string.rep("y", 20000))
  state.append(b, "user", nil, "go")
  loop.start(b)
  assert(vim.wait(10000, function() return not loop.running(b) end, 10), "run hung")
  straps.config.auto_compact_bytes = nil
  straps.config.log_file = nil

  local compacts = 0
  for _, line in ipairs(vim.fn.readfile(logfile)) do
    if vim.json.decode(line).ev == "compact" then compacts = compacts + 1 end
  end
  assert(_G.gg_calls == 5, "provider should have run 5 turns, ran " .. tostring(_G.gg_calls))
  assert(compacts == 1, "growth guard should compact exactly once, got " .. compacts)
end)

case("compacting a BATCHED turn keeps pairing and API-valid alternation", function()
  -- The two-phase loop writes batches as use,use,result,result. Compaction
  -- rewrites old tool blocks in place; the batch shape must survive.
  local b = state.new_session()
  state.append(b, "user", nil, "do three batched rounds")
  -- Inputs above the 200-byte threshold so old ones get stubbed to {}.
  local fat_input = '{\n  "x": "' .. string.rep("z", 300) .. '"\n}'
  for turn = 1, 3 do
    state.append(b, "assistant", nil, "turn " .. turn)
    state.append(b, "tool_use", { id = "a" .. turn, name = "ping" }, fat_input)
    state.append(b, "tool_use", { id = "b" .. turn, name = "ping" }, fat_input)
    state.append(b, "tool_result", { id = "a" .. turn, is_error = false },
      "BATCH-RESULT-a" .. turn .. " " .. FAT)
    state.append(b, "tool_result", { id = "b" .. turn, is_error = false },
      "BATCH-RESULT-b" .. turn .. " " .. FAT)
  end

  local s = registry.call("fn.compact", b, { keep_turns = 2 })
  assert(s:find("compacted", 1, true) == 1, "unexpected summary: " .. tostring(s))

  local text = buf_text(b)
  assert(not text:find("BATCH-RESULT-a1 " .. FAT, 1, true), "old batch result a1 not compacted")
  assert(not text:find("BATCH-RESULT-b1 " .. FAT, 1, true), "old batch result b1 not compacted")
  assert(text:find("BATCH-RESULT-a3 " .. FAT, 1, true), "recent batch result was touched")

  local parsed = state.parse(b)
  for i = 2, #parsed.messages do
    assert(parsed.messages[i].role ~= parsed.messages[i - 1].role,
      "roles stopped alternating at message " .. i)
  end
  -- Every batch must survive as ONE assistant message with both tool_use
  -- blocks, immediately followed by ONE user message with both results.
  local batches = 0
  for i, m in ipairs(parsed.messages) do
    if m.role == "assistant" then
      local uses = {}
      for _, p in ipairs(m.content) do
        if p.type == "tool_use" then uses[#uses + 1] = p.id end
      end
      if #uses > 0 then
        batches = batches + 1
        assert(#uses == 2, "batch lost a tool_use: " .. table.concat(uses, ","))
        local nxt = parsed.messages[i + 1]
        assert(nxt and nxt.role == "user", "no user message after a batch")
        local results = {}
        for _, p in ipairs(nxt.content) do
          if p.type == "tool_result" then results[#results + 1] = p.tool_use_id end
        end
        assert(#results == 2 and results[1] == uses[1] and results[2] == uses[2],
          "pairing broken after compaction: " .. table.concat(results, ","))
      end
    end
  end
  assert(batches == 3, "expected 3 batched turns, found " .. batches)
  -- Compacted tool_use inputs collapse to {} but stay valid JSON objects.
  local p1 = parsed.messages
  local found_stub = false
  for _, m in ipairs(p1) do
    for _, part in ipairs(m.content) do
      if part.type == "tool_use" and part.id == "a1" then
        assert(type(part.input) == "table" and next(part.input) == nil,
          "compacted tool_use input should be an empty object")
        found_stub = true
      end
    end
  end
  assert(found_stub, "tool_use a1 disappeared from the parse")
end)

case(":StrapsCompact command smoke", function()
  vim.g.loaded_straps = nil
  vim.cmd("source " .. vim.fn.fnameescape(root .. "/plugin/straps.lua"))
  vim.api.nvim_set_current_buf(bufnr)
  vim.cmd.StrapsCompact() -- errors (including resolve failures) fail the case
end)

print(failed and "FAILED" or "ALL PASS")
os.exit(failed and 1 or 0)
