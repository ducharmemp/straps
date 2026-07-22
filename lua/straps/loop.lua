-- straps.loop: the coroutine-driven agent loop.
-- Owns the run lifecycle per buffer (start/stop/running), the ctx handed to
-- provider/tools/hooks (await/emit/on_cancel/cancelled), and the turn loop:
-- parse buffer -> provider -> tool_use blocks -> tool_results -> repeat.

local M = {}

local unpack = unpack or table.unpack

-- bufnr -> { cancelled, cancel_fns, await_seq, done }
local runs = {}

-- Config is read lazily per run so tests can run without init.lua/setup().
local function get_config()
  local ok, straps = pcall(require, "straps")
  local cfg = (ok and type(straps) == "table" and rawget(straps, "config")) or {}
  return {
    max_turns = cfg.max_turns or 128,
    -- Soft stop: end the run after this many CONSECUTIVE stalled turns (a turn
    -- is stalled when every tool call in it errored, or it repeats a
    -- (tool,input) call already made this run). This is the real
    -- spinning-catcher; max_turns is only the hard backstop, so it can be
    -- generous. 0 disables the detector (max_turns alone bounds the run).
    stall_limit = cfg.stall_limit or 6,
    max_tool_result_bytes = cfg.max_tool_result_bytes or 100000,
    -- Auto-compaction thresholds (both nil = off). Prefer auto_compact_tokens:
    -- with prompt caching on, a stable transcript is already cheap (cache
    -- reads), so compaction is a context-WINDOW tool, not a cost tool — set it
    -- near the model's limit. auto_compact_bytes stays for back-compat.
    auto_compact_tokens = cfg.auto_compact_tokens,
    auto_compact_bytes = cfg.auto_compact_bytes,
  }
end

local islist = vim.islist or vim.tbl_islist

-- vim.json.encode is compact-only; tool_use blocks want readable input.
local function pretty_json(v, ind)
  ind = ind or ""
  if type(v) ~= "table" then
    return vim.json.encode(v)
  end
  local nested = ind .. "  "
  if islist(v) and #v > 0 then
    local parts = {}
    for _, item in ipairs(v) do
      parts[#parts + 1] = nested .. pretty_json(item, nested)
    end
    return "[\n" .. table.concat(parts, ",\n") .. "\n" .. ind .. "]"
  end
  local keys = {}
  for k in pairs(v) do
    keys[#keys + 1] = k
  end
  if #keys == 0 then
    return "{}"
  end
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)
  local parts = {}
  for _, k in ipairs(keys) do
    parts[#parts + 1] = nested .. vim.json.encode(tostring(k)) .. ": " .. pretty_json(v[k], nested)
  end
  return "{\n" .. table.concat(parts, ",\n") .. "\n" .. ind .. "}"
end

local function pack(...)
  return { n = select("#", ...), ... }
end

-- Progress must never break a run: hook errors are swallowed, and the phase
-- mirror (vim.b straps_phase) is best-effort. phase == nil means "no change".
local function progress(bufnr, ctx, ev, phase)
  pcall(require("straps.registry").try_call, "hook.on_progress", ev, ctx)
  if phase ~= nil then
    pcall(function() vim.b[bufnr].straps_phase = phase end)
  end
end

-- fn.log is optional and must never break a run: pcall'd try_call. The
-- buffer is stamped onto every event here so call sites stay terse.
local function log(bufnr, ev)
  ev.buf = bufnr
  pcall(require("straps.registry").try_call, "fn.log", ev)
end

local function new_ctx(bufnr, run)
  local ctx
  ctx = {
    bufnr = bufnr,

    -- start(resolve) begins async work; await yields the coroutine and
    -- resolve(...) resumes it. The driver wraps resume in vim.schedule so
    -- resolve is safe from any callback context; resolve is honored exactly
    -- once (later calls, and calls belonging to a previous await, are no-ops).
    await = function(start)
      local co = assert(coroutine.running(), "straps: ctx.await outside the run coroutine")
      run.await_seq = run.await_seq + 1
      local seq = run.await_seq
      local resolved = false
      start(function(...)
        if resolved then
          return
        end
        resolved = true
        local args = pack(...)
        vim.schedule(function()
          if run.done or run.await_seq ~= seq or coroutine.status(co) ~= "suspended" then
            return
          end
          -- Every synchronous segment of the run executes with this
          -- buffer's registry scope active, so all lookups (and defines)
          -- inside the run resolve through the session's scope chain.
          local reg = require("straps.registry")
          local prev_scope = reg.set_active_scope(bufnr)
          local ok, err = coroutine.resume(co, unpack(args, 1, args.n))
          reg.set_active_scope(prev_scope)
          if not ok then
            runs[bufnr] = nil
            vim.notify("straps: run crashed: " .. tostring(err), vim.log.levels.ERROR)
          end
        end)
      end)
      local ret = pack(coroutine.yield())
      run.cancel_fns = {} -- handlers are cleared after each await completes
      return unpack(ret, 1, ret.n)
    end,

    -- Provider streaming events. text_delta is appended to the current
    -- (assistant) block; buffer mutation is scheduled onto the main loop.
    -- vim.schedule is FIFO, so deltas emitted before resolve land first.
    emit = function(ev)
      if type(ev) == "table" and ev.type == "text_delta" and ev.text and ev.text ~= "" then
        vim.schedule(function()
          if vim.api.nvim_buf_is_valid(bufnr) then
            require("straps.state").append_text(bufnr, ev.text)
          end
        end)
      end
    end,

    on_cancel = function(fn)
      if run.cancelled then
        pcall(fn)
        return
      end
      run.cancel_fns[#run.cancel_fns + 1] = fn
    end,

    cancelled = function()
      return run.cancelled
    end,

    -- Stream liveness heartbeat: the provider calls this from its stdout
    -- callback on every received chunk (the same signal the watchdog resets
    -- on). Records a last-byte time the default progress UI reads to show
    -- "receiving" vs "silent Ns". Pure table write via ui.note_activity; never
    -- touches the buffer, so it is safe from the fast callback context. The
    -- pcall keeps a redefined/absent progress hook from breaking the stream.
    activity = function()
      pcall(function() require("straps.ui").note_activity(bufnr) end)
    end,
  }
  return ctx
end

-- One tool_use block (its tool_use marker is already in the buffer):
-- confirm -> before_tool -> call -> after_tool -> result.
local function run_tool(bufnr, ctx, block, cfg)
  local registry = require("straps.registry")
  local state = require("straps.state")
  local id, name, input = block.id, block.name, block.input or {}

  local allowed, reason = registry.call("hook.confirm", name, input, ctx)
  if not allowed then
    state.append(bufnr, "tool_result", { id = id, is_error = true },
      "user denied: " .. (reason or ""))
    return false
  end

  registry.try_call("hook.before_tool", name, input, ctx)

  local ok, result = pcall(registry.call, "tool." .. name, input, ctx)
  if ok then
    if result == nil then
      result = "ok"
    elseif type(result) == "table" then
      result = vim.json.encode(result)
    else
      result = tostring(result)
    end
  else
    result = tostring(result)
  end
  if #result > cfg.max_tool_result_bytes then
    result = result:sub(1, cfg.max_tool_result_bytes)
      .. ("\n[straps: result truncated at %d bytes]"):format(cfg.max_tool_result_bytes)
  end

  result = registry.try_call("hook.after_tool", name, input, result, ok, ctx) or result
  state.append(bufnr, "tool_result", { id = id, is_error = not ok }, tostring(result))
  return ok, tostring(result)
end

-- Drain the steering queue (vim.b straps_steering): append each queued string
-- as an ordinary user block and clear the queue. Returns true if anything was
-- drained. The buffer IS the request, so the next parse picks these up.
local function drain_steering(bufnr)
  local state = require("straps.state")
  local queue = vim.b[bufnr].straps_steering
  if type(queue) ~= "table" or #queue == 0 then
    return false
  end
  for _, text in ipairs(queue) do
    state.append(bufnr, "user", nil, text)
  end
  vim.b[bufnr].straps_steering = nil
  return true
end

-- Returns the run's ending reason: "ok" | "cancelled" | "max_turns" | "stalled".
local function run_turns(bufnr, ctx, run)
  local registry = require("straps.registry")
  local state = require("straps.state")
  local cfg = get_config()

  local function cancelled_note()
    state.append(bufnr, "assistant", nil, "[straps: run cancelled]")
    return "cancelled"
  end

  progress(bufnr, ctx, { type = "start" }, "starting")
  log(bufnr, { ev = "run_start" })
  registry.try_call("hook.on_run_start", ctx)

  -- Per-buffer override (subagents get their own, usually tighter, budget).
  local max_turns = cfg.max_turns
  pcall(function()
    max_turns = vim.b[bufnr].straps_max_turns or max_turns
  end)

  -- Stall detection state: run.stall counts CONSECUTIVE stalled turns (reset
  -- by any productive turn); seen_calls records (tool.name .. input) of every
  -- tool call so far, so a repeat is a stall signal. A turn is stalled when it
  -- issued tool calls AND every one errored, OR any was an exact repeat.
  run.stall = 0
  run.seen_calls = {}
  local stall_limit = cfg.stall_limit or 0

  for turn = 1, max_turns do
    run.turns = turn
    drain_steering(bufnr) -- queued steering becomes user blocks before parse
    -- Auto-compaction (off unless a threshold is set): the loop is about to
    -- read the whole buffer anyway, so the size check is cheap. Every compaction
    -- rewrites old message blocks, which invalidates the messages cache tier
    -- from the first edit onward (tools+system survive) — so it must be COARSE:
    -- a growth guard stops it re-firing every turn (which would blow the cache
    -- every turn) when keep_turns content alone already sits above the limit.
    if type(cfg.auto_compact_tokens) == "number" or type(cfg.auto_compact_bytes) == "number" then
      local bytes = vim.api.nvim_buf_get_offset(bufnr, vim.api.nvim_buf_line_count(bufnr))
      -- Rough proxy: mixed code + JSON transcripts average ~3.5 bytes/token.
      -- Users tune the threshold, so the divisor need only be in the ballpark.
      local est_tokens = math.floor(bytes / 3.5)
      local over = (type(cfg.auto_compact_tokens) == "number" and est_tokens > cfg.auto_compact_tokens)
        or (type(cfg.auto_compact_bytes) == "number" and bytes > cfg.auto_compact_bytes)
      -- Coarseness guard: after a compaction, require ~20% growth before the
      -- next one, so a session that stays near the limit doesn't thrash the
      -- cache. (Post-compaction size is smaller, so this naturally spaces them.)
      local grown = (not run.last_compact_bytes) or (bytes > run.last_compact_bytes * 1.2)
      if over and grown then
        local ok_c, summary = pcall(registry.try_call, "fn.compact", bufnr)
        run.last_compact_bytes =
          vim.api.nvim_buf_get_offset(bufnr, vim.api.nvim_buf_line_count(bufnr))
        log(bufnr, { ev = "compact", est_tokens = est_tokens,
          summary = (ok_c and type(summary) == "string") and summary or nil })
      end
    end
    local parsed = state.parse(bufnr)
    if #parsed.messages == 0 then
      error("nothing to send — type your request under the trailing %%[straps:user]%% marker", 0)
    end
    -- Newer models (including the default) reject a request that ends on an
    -- assistant message — assistant prefill is unsupported — so fail here,
    -- not with an opaque HTTP 400 after a round trip.
    if parsed.messages[#parsed.messages].role ~= "user" then
      if turn > 1 then
        -- Mid-run an assistant-role tail means the finished turn appended no
        -- user-role content for the model to answer.
        error("the last turn added nothing to respond to — the model claimed"
          .. ' stop_reason "tool_use" but requested no tools, or steering was blank', 0)
      end
      error("nothing to send — the transcript ends with an assistant message;"
        .. " type your request under the trailing %%[straps:user]%% marker", 0)
    end
    log(bufnr, { ev = "turn", turn = turn, messages = #parsed.messages })
    local tools = registry.call("fn.build_tools")

    -- Empty assistant marker first: the provider streams text_delta events
    -- into it via ctx.emit/state.append_text. Empty text is dropped by parse.
    state.append(bufnr, "assistant", nil, "")
    progress(bufnr, ctx, { type = "thinking", turn = turn, max = max_turns }, "thinking")
    local resp = registry.call("fn.provider",
      { system = parsed.system, messages = parsed.messages, tools = tools }, ctx)
    if run.cancelled then
      return cancelled_note()
    end
    assert(type(resp) == "table", "straps: fn.provider must return a table")

    -- Two phases: append EVERY tool_use marker first, THEN execute each and
    -- append its result. The transcript then replays as ONE assistant
    -- message carrying the whole batch of tool_use blocks followed by one
    -- user message with all the results (parse merges adjacent same-role
    -- blocks) — the exact shape the model sent. Interleaving use/result
    -- pairs would rewrite a batched turn into single-call turns, teaching
    -- the model by its own example never to batch.
    local tool_blocks = {}
    for _, block in ipairs(resp.content or {}) do
      if block.type == "tool_use" then
        tool_blocks[#tool_blocks + 1] = block
        state.append(bufnr, "tool_use",
          { id = block.id, name = block.name }, pretty_json(block.input or {}))
      end
    end
    -- Per-turn stall signals, folded in as each tool runs.
    local n_calls, n_errors, any_repeat, last_error = 0, 0, false, nil
    for i, block in ipairs(tool_blocks) do
      if run.cancelled then
        -- Every appended tool_use must get a result, or the next parse
        -- ships an unpaired tool_use block and the API rejects the request.
        for j = i, #tool_blocks do
          state.append(bufnr, "tool_result",
            { id = tool_blocks[j].id, is_error = true },
            "run cancelled before this tool executed")
        end
        return cancelled_note()
      end
      progress(bufnr, ctx, { type = "tool", name = block.name }, "tool: " .. tostring(block.name))
      -- (tool.name .. canonical input) identifies a call for repeat detection;
      -- pretty_json sorts object keys, so equivalent inputs hash identically.
      local key = tostring(block.name) .. "\0" .. pretty_json(block.input or {})
      if run.seen_calls[key] then
        any_repeat = true
      end
      run.seen_calls[key] = true
      local t0 = vim.uv.hrtime()
      local ok, result = run_tool(bufnr, ctx, block, cfg)
      n_calls = n_calls + 1
      if not ok then
        n_errors = n_errors + 1
        last_error = result
      end
      log(bufnr, { ev = "tool", name = block.name,
        ms = math.floor((vim.uv.hrtime() - t0) / 1e6), is_error = not ok })
      progress(bufnr, ctx, { type = "tool_done", name = block.name, is_error = not ok })
    end

    -- Classify the turn for the stall detector. A turn with no tool calls is
    -- never a stall (it is either the final answer or steering). A turn that
    -- did work is stalled when every call errored, or any call repeated an
    -- earlier one. Consecutive stalls accumulate; a productive turn resets.
    if stall_limit > 0 and n_calls > 0 then
      local stalled = (n_errors == n_calls) or any_repeat
      run.stall = stalled and (run.stall + 1) or 0
      if run.stall >= stall_limit then
        local why = last_error and (" Last error: " .. last_error:gsub("%s+", " "):sub(1, 200))
          or " (repeated tool calls with no new progress)"
        state.append(bufnr, "assistant", nil,
          ("[straps: stopped after %d consecutive turns with no apparent progress"
            .. " (config.stall_limit=%d).%s — send a message to steer, or raise"
            .. " config.stall_limit]"):format(run.stall, stall_limit, why))
        log(bufnr, { ev = "stall", turn = turn, consecutive = run.stall })
        return "stalled"
      end
    end

    if resp.stop_reason ~= "tool_use" then
      -- A steering message typed while the model streamed its final answer
      -- still gets acted on: drain, and if anything arrived, keep looping.
      if not drain_steering(bufnr) then
        return "ok"
      end
    end
    if run.cancelled then
      return cancelled_note()
    end
  end

  -- Exhaustion must be loud: a silent end reads as "the agent died".
  state.append(bufnr, "assistant", nil,
    ("[straps: stopped after %d turns (config.max_turns) — send a message to continue]")
      :format(max_turns))
  return "max_turns"
end

--- Start a run for bufnr (default: current buffer). One active run per buffer.
function M.start(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if runs[bufnr] then
    vim.notify("straps: a run is already active for this buffer", vim.log.levels.WARN)
    return
  end
  local registry = require("straps.registry")
  local state = require("straps.state")

  local run = { cancelled = false, cancel_fns = {}, await_seq = 0, done = false, turns = 0 }
  runs[bufnr] = run
  pcall(function() vim.b[bufnr].straps_status = "running" end)
  vim.cmd("redrawstatus!") -- all windows: a subagent run changes the parent's agent count

  local ctx = new_ctx(bufnr, run)
  run.ctx = ctx
  local co = coroutine.create(function()
    local ok, ret = pcall(run_turns, bufnr, ctx, run)
    run.done = true
    if not ok then
      pcall(state.append, bufnr, "assistant", nil, "straps: run error: " .. tostring(ret))
    end
    -- done fires on every exit; run_turns names its own ending
    -- ("ok" | "cancelled" | "max_turns" | "stalled"), a crash is "error".
    local reason = ok and (ret or "ok") or "error"
    log(bufnr, { ev = "run_end", reason = reason, turns = run.turns })
    progress(bufnr, ctx, { type = "done", reason = reason }, "")
    pcall(registry.try_call, "hook.on_run_end", ctx)
    pcall(state.ensure_trailing_user, bufnr)
    runs[bufnr] = nil
    pcall(function() vim.b[bufnr].straps_status = "idle" end)
    vim.cmd("redrawstatus!") -- all windows: subagent finishing updates the parent's count
  end)

  -- Initial resume under this buffer's registry scope (see ctx.await for
  -- the matching per-resume scoping).
  local reg = require("straps.registry")
  local prev_scope = reg.set_active_scope(bufnr)
  local ok, err = coroutine.resume(co)
  reg.set_active_scope(prev_scope)
  if not ok then
    runs[bufnr] = nil
    error(err)
  end
end

--- Request cancel: flip the flag and invoke registered cancel handlers.
--- The run notices between turns / tool calls and ends with a note.
function M.stop(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local run = runs[bufnr]
  if not run then
    vim.notify("straps: no active run for this buffer", vim.log.levels.INFO)
    return
  end
  run.cancelled = true
  local fns = run.cancel_fns
  run.cancel_fns = {}
  for _, fn in ipairs(fns) do
    pcall(fn)
  end
end

--- Queue a mid-run user message ("steering"). Returns true if queued, false
--- if no run is active (callers fall back to M.start). The queue lives in
--- vim.b straps_steering; vim.b tables are snapshots, so copy-modify-write.
function M.steer(bufnr, text)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local run = runs[bufnr]
  if not run then
    return false
  end
  local queue = vim.b[bufnr].straps_steering
  if type(queue) ~= "table" then
    queue = {}
  end
  queue[#queue + 1] = text
  vim.b[bufnr].straps_steering = queue
  progress(bufnr, run.ctx, { type = "steer_queued" })
  vim.notify("straps: steering queued")
  return true
end

function M.running(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  return runs[bufnr] ~= nil
end

--- Bufnrs of every session with an active run, newest-started first.
--- The authoritative "who is working right now" list — the agents picker
--- and statusline component read it. Stale/invalid buffers are skipped.
function M.running_sessions()
  local out = {}
  for bufnr in pairs(runs) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      out[#out + 1] = bufnr
    end
  end
  table.sort(out)
  return out
end

return M
