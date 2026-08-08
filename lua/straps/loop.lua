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
    -- A turn that ends (no tool_use) with no visible text after a tool call is
    -- the "runs a command then goes silent" symptom. Nudge the model up to
    -- this many times per run to report/continue before ending the run loudly
    -- with reason "blank". 0 disables the nudge (still ends loudly on the
    -- first blank turn). max_tokens with no text always ends loudly, no nudge.
    blank_nudge_limit = cfg.blank_nudge_limit or 1,
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
  -- The agents buffer (straps://agents) re-renders on any session's progress.
  -- This is mechanism, not policy, so it lives here beside the phase mirror
  -- rather than in the redefinable hook.on_progress. No-ops without an agents
  -- buffer open; always runs on the main loop.
  pcall(function() require("straps.ui").agents_refresh() end)
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
-- confirm -> before_tool -> call -> after_tool -> normalized result. The caller
-- appends tool_result blocks in API order, even when execution was parallel.
local function execute_tool(bufnr, ctx, block, cfg, opts)
  local registry = require("straps.registry")
  local name, input = block.name, block.input or {}

  if not (opts and opts.skip_confirm) then
    local allowed, reason = registry.call("hook.confirm", name, input, ctx)
    if not allowed then
      return false, "user denied: " .. (reason or "")
    end
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
    -- Back the cut up to a UTF-8 character boundary so we never emit a byte
    -- sequence split mid-character into the transcript / API payload.
    local cut = cfg.max_tool_result_bytes
    while cut > 0 do
      local b = result:byte(cut + 1)
      if not b or b < 0x80 or b >= 0xC0 then break end -- next byte is not a continuation byte
      cut = cut - 1
    end
    result = result:sub(1, cut)
      .. ("\n[straps: result truncated at %d bytes]"):format(cfg.max_tool_result_bytes)
  end

  result = registry.try_call("hook.after_tool", name, input, result, ok, ctx) or result
  return ok, tostring(result)
end

local function append_tool_result(bufnr, block, ok, result)
  require("straps.state").append(bufnr, "tool_result",
    { id = block.id, is_error = not ok }, tostring(result))
end

-- Builtin read-only tools whose effects are safe to overlap when the model
-- sends a batch. Writes and user-interaction/presentation tools stay serial.
local PARALLEL_READONLY = {
  read_file = true, glob = true, tree = true, path_info = true, grep = true,
  registry_list = true, registry_get = true, skill = true,
  diagnostics = true, diagnostic_at = true, diagnostic_next = true,
  lsp_status = true,
  declaration = true, definition = true, type_definition = true,
  implementation = true, references = true,
  symbols = true, read_symbol = true, tree_sitter_status = true, node_at = true,
  read_node = true, hover = true, workspace_symbols = true,
  context = true, help_search = true, agents = true, models = true,
}

local function all_parallel_readonly(blocks)
  if #blocks < 2 then return false end
  for _, block in ipairs(blocks) do
    if not PARALLEL_READONLY[block.name] then return false end
  end
  return true
end

local function child_ctx(parent_ctx, bufnr, finish)
  local ctx = {
    bufnr = bufnr,
    emit = parent_ctx.emit,
    on_cancel = parent_ctx.on_cancel,
    cancelled = parent_ctx.cancelled,
    activity = parent_ctx.activity,
  }
  ctx.await = function(start)
    local co = assert(coroutine.running(), "straps: child ctx.await outside coroutine")
    ctx._await_seq = (ctx._await_seq or 0) + 1
    local seq = ctx._await_seq
    local resolved = false
    start(function(...)
      if resolved then return end
      resolved = true
      local args = pack(...)
      vim.schedule(function()
        if ctx._await_seq ~= seq or coroutine.status(co) ~= "suspended" then return end
        local reg = require("straps.registry")
        local prev_scope = reg.set_active_scope(bufnr)
        local ok, err = coroutine.resume(co, unpack(args, 1, args.n))
        reg.set_active_scope(prev_scope)
        if not ok then finish(false, tostring(err)) end
      end)
    end)
    return coroutine.yield()
  end
  return ctx
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

-- Returns the run's ending reason:
-- "ok" | "cancelled" | "max_turns" | "stalled" | "blank".
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
  -- Blank-turn nudges used so far this run (a model that ends its turn with no
  -- visible text after a tool call gets nudged, bounded by blank_nudge_limit).
  run.blank_nudges = 0
  local blank_nudge_limit = cfg.blank_nudge_limit or 0

  for turn = 1, max_turns do
    run.turns = turn
    drain_steering(bufnr) -- queued steering becomes user blocks before parse
    -- Per-turn seam, before the parse that builds this turn's request: the
    -- default notice tells the agent which model/effort it is running on and
    -- re-announces a mid-run switch (the pickers write vim.b between turns).
    registry.try_call("hook.on_turn_start", ctx, turn)
    -- Auto-compaction (off unless a threshold is set): the loop is about to
    -- read the whole buffer anyway, so the size check is cheap. Every compaction
    -- rewrites old message blocks, which invalidates the messages cache tier
    -- from the first edit onward (tools+system survive) — so it must be COARSE:
    -- a growth guard stops it re-firing every turn (which would blow the cache
    -- every turn) when keep_turns content alone already sits above the limit.
    if type(cfg.auto_compact_tokens) == "number" or type(cfg.auto_compact_bytes) == "number" then
      local bytes = vim.api.nvim_buf_get_offset(bufnr, vim.api.nvim_buf_line_count(bufnr))
      -- Prefer the REAL context fill the API reported last turn (input_tokens
      -- is the whole replayed prompt the model just saw) over a byte guess.
      -- Only fall back to bytes/3.5 before the first response, when there is
      -- no usage yet. Users tune the threshold, so the divisor need only be in
      -- the ballpark.
      local real = run.usage and tonumber(run.usage.input_billed)
      local est_tokens = real or math.floor(bytes / 3.5)
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

    -- Model awareness rides in the REQUEST's system text, never the
    -- transcript: parse merges same-role messages, so a user-role notice
    -- would concatenate with the user's own words (harness text wearing the
    -- user's voice). fn.model_note re-resolves per request, so a mid-run
    -- :StrapsModel / :StrapsEffort switch is named on the very next turn.
    -- parsed is a fresh table each turn; appending here never touches the
    -- buffer. pcall so a broken redefinition degrades to no note, not a
    -- failed run.
    local ok_note, note = pcall(registry.try_call, "fn.model_note", ctx)
    local system = parsed.system
    if ok_note and type(note) == "string" and note ~= "" then
      system = (system and system ~= "") and (system .. "\n\n" .. note) or note
    end

    -- Empty assistant marker first: the provider streams text_delta events
    -- into it via ctx.emit/state.append_text. Empty text is dropped by parse.
    state.append(bufnr, "assistant", nil, "")
    progress(bufnr, ctx, { type = "thinking", turn = turn, max = max_turns }, "thinking")
    local resp = registry.call("fn.provider",
      { system = system, messages = parsed.messages, tools = tools }, ctx)
    if run.cancelled then
      return cancelled_note()
    end
    assert(type(resp) == "table", "straps: fn.provider must return a table")

    -- Thread token usage back into buffer state. The provider captures it per
    -- response; accumulate it on the run and mirror it to vim.b so the winbar
    -- and auto-compaction can read a REAL context-fill number instead of a
    -- bytes/token guess. `input_tokens` is the size of the prompt the model
    -- just saw (the whole replayed transcript), so it — not a running sum — is
    -- the current context fill; cache_read/creation are the caching split.
    if type(resp.usage) == "table" then
      local u = resp.usage
      local acc = run.usage or { requests = 0, output_total = 0 }
      acc.requests = acc.requests + 1
      acc.input = tonumber(u.input_tokens) or acc.input
      acc.cache_read = tonumber(u.cache_read_input_tokens) or 0
      acc.cache_creation = tonumber(u.cache_creation_input_tokens) or 0
      acc.output = tonumber(u.output_tokens) or 0
      acc.output_total = acc.output_total + (tonumber(u.output_tokens) or 0)
      -- The billed input side = fresh input + both cache tiers; the ratio of
      -- cache_read to that total is the cache hit rate the winbar shows.
      acc.input_billed = (acc.input or 0) + acc.cache_read + acc.cache_creation
      run.usage = acc
      pcall(function() vim.b[bufnr].straps_usage = acc end)
      pcall(function() require("straps.ui").redraw_status(true) end)
    end

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
    -- Per-turn stall signals, folded in as each tool runs. any_new tracks
    -- whether the turn made at least one call never seen before, so a turn
    -- that mixes fresh work with an idempotent re-read (a legitimate pattern)
    -- is not mistaken for spinning.
    local n_calls, n_errors, any_repeat, any_new, last_error = 0, 0, false, false, nil
    if all_parallel_readonly(tool_blocks) then
      local jobs = {}
      for i, block in ipairs(tool_blocks) do
        progress(bufnr, ctx, { type = "tool", name = block.name }, "tool: " .. tostring(block.name))
        local key = tostring(block.name) .. "\0" .. pretty_json(block.input or {})
        if run.seen_calls[key] then any_repeat = true else any_new = true end
        run.seen_calls[key] = true
        n_calls = n_calls + 1
        local t0 = vim.uv.hrtime()
        local allowed, reason = registry.call("hook.confirm", block.name, block.input or {}, ctx)
        if not allowed then
          jobs[i] = { done = true, ok = false, result = "user denied: " .. (reason or ""), ms = 0 }
        else
          jobs[i] = { done = false, block = block, started = t0 }
          local job = jobs[i]
          local function finish(ok, result)
            if job.done then return end
            job.done = true
            job.ok = ok
            job.result = tostring(result)
            job.ms = math.floor((vim.uv.hrtime() - job.started) / 1e6)
          end
          local co = coroutine.create(function()
            local cctx = child_ctx(ctx, bufnr, finish)
            finish(execute_tool(bufnr, cctx, block, cfg, { skip_confirm = true }))
          end)
          local reg = require("straps.registry")
          local prev_scope = reg.set_active_scope(bufnr)
          local ok_resume, err = coroutine.resume(co)
          reg.set_active_scope(prev_scope)
          if not ok_resume then finish(false, err) end
        end
      end
      ctx.await(function(resolve)
        local function poll()
          local pending = false
          for _, job in ipairs(jobs) do
            if not job.done then pending = true break end
          end
          if pending and not run.cancelled then
            vim.defer_fn(poll, 20)
          else
            resolve()
          end
        end
        poll()
      end)
      for i, block in ipairs(tool_blocks) do
        local job = jobs[i]
        local ok, result = job.ok == true, job.result or ""
        if run.cancelled and not job.done then
          ok, result = false, "run cancelled before this tool executed"
        end
        append_tool_result(bufnr, block, ok, result)
        if not ok then
          n_errors = n_errors + 1
          last_error = result
        end
        log(bufnr, { ev = "tool", name = block.name, ms = job.ms or 0, is_error = not ok })
        progress(bufnr, ctx, { type = "tool_done", name = block.name, is_error = not ok })
      end
      if run.cancelled then return cancelled_note() end
    else
      for i, block in ipairs(tool_blocks) do
        if run.cancelled then
          -- Every appended tool_use must get a result, or the next parse
          -- ships an unpaired tool_use block and the API rejects the request.
          for j = i, #tool_blocks do
            append_tool_result(bufnr, tool_blocks[j], false,
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
        else
          any_new = true
        end
        run.seen_calls[key] = true
        local t0 = vim.uv.hrtime()
        local ok, result = execute_tool(bufnr, ctx, block, cfg)
        append_tool_result(bufnr, block, ok, result)
        n_calls = n_calls + 1
        if not ok then
          n_errors = n_errors + 1
          last_error = result
        end
        log(bufnr, { ev = "tool", name = block.name,
          ms = math.floor((vim.uv.hrtime() - t0) / 1e6), is_error = not ok })
        progress(bufnr, ctx, { type = "tool_done", name = block.name, is_error = not ok })
      end
    end

    -- Classify the turn for the stall detector. A turn with no tool calls is
    -- never a stall (it is either the final answer or steering). A turn that
    -- did work is stalled when every call errored, or when every call was an
    -- exact repeat of an earlier one (no new distinct call this turn) — a
    -- turn that also made progress on something new is not spinning.
    -- Consecutive stalls accumulate; a productive turn resets.
    if stall_limit > 0 and n_calls > 0 then
      local stalled = (n_errors == n_calls) or (any_repeat and not any_new)
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
      -- Blank final turn: the model ended (no tool_use) but produced no
      -- visible text — the "runs a command then returns silence" symptom. A
      -- normal end_turn carries an answer; an empty one is an anomaly, not a
      -- clean success, so it must not read as one. Two causes, handled apart:
      --   * max_tokens with nothing visible: the response budget (often the
      --     thinking budget under load) was consumed before any answer — a
      --     loud, distinct ending, never a silent "ok".
      --   * blank end_turn: the model just trailed off. Nudge it once (a
      --     synthetic user turn) to report or continue; only escalate to the
      --     loud ending if it stays blank past config.blank_nudge_limit.
      -- A turn that ran tools THIS turn is not silent — it did visible work,
      -- even if the model reported end_turn without prose. Only a turn with no
      -- tool calls AND no visible text is the "returns silence" symptom.
      local has_text = false
      for _, block in ipairs(resp.content or {}) do
        local t = (block.type == "text" and block.text)
          or ((block.type == "thinking" or block.type == "redacted_thinking") and block.thinking)
        if type(t) == "string" and t:match("%S") then
          has_text = true
          break
        end
      end
      if n_calls == 0 and not has_text then
        if resp.stop_reason == "max_tokens" then
          state.append(bufnr, "assistant", nil,
            "[straps: the model hit max_tokens without producing a visible answer"
              .. " — the response budget (likely the thinking budget) was consumed"
              .. " before any text. Set config.max_tokens (a higher explicit cap)"
              .. " or lower the effort, then send a message to continue.]")
          log(bufnr, { ev = "blank_end", cause = "max_tokens", turn = turn })
          return "blank"
        end
        -- Blank end_turn: nudge, bounded by config.blank_nudge_limit.
        if run.blank_nudges < blank_nudge_limit then
          run.blank_nudges = run.blank_nudges + 1
          state.append(bufnr, "user", nil,
            "[straps] Your last turn produced no text after the tool call."
              .. " Report the result of what you just ran, or continue the task.")
          log(bufnr, { ev = "blank_nudge", turn = turn, attempt = run.blank_nudges })
          -- fall through to the continue below (do NOT return)
        else
          state.append(bufnr, "assistant", nil,
            ("[straps: the model returned no text after %d nudge(s) — it keeps"
              .. " ending its turn silently. Send a message to steer, or raise"
              .. " config.blank_nudge_limit.]"):format(run.blank_nudges))
          log(bufnr, { ev = "blank_end", cause = "end_turn", turn = turn })
          return "blank"
        end
      elseif not drain_steering(bufnr) then
        -- A steering message typed while the model streamed its final answer
        -- still gets acted on: drain, and if anything arrived, keep looping.
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
  -- all windows: a subagent run changes the parent's agent count
  pcall(function() require("straps.ui").redraw_status(true) end)

  local ctx = new_ctx(bufnr, run)
  run.ctx = ctx
  local co = coroutine.create(function()
    local ok, ret = pcall(run_turns, bufnr, ctx, run)
    run.done = true
    if not ok then
      pcall(state.append, bufnr, "assistant", nil, "straps: run error: " .. tostring(ret))
    end
    -- done fires on every exit; run_turns names its own ending
    -- ("ok" | "cancelled" | "max_turns" | "stalled" | "blank"), crash = "error".
    local reason = ok and (ret or "ok") or "error"
    log(bufnr, { ev = "run_end", reason = reason, turns = run.turns })
    progress(bufnr, ctx, { type = "done", reason = reason }, "")
    pcall(registry.try_call, "hook.on_run_end", ctx)
    pcall(state.ensure_trailing_user, bufnr)
    runs[bufnr] = nil
    pcall(function() vim.b[bufnr].straps_status = "idle" end)
    -- all windows: subagent finishing updates the parent's count
    pcall(function() require("straps.ui").redraw_status(true) end)
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
