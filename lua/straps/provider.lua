-- straps.provider: registers fn.provider (Anthropic Messages API, streaming
-- SSE via curl + vim.system), plus fn.api_key, fn.build_tools, the layered
-- system prompt (fn.system_prompt_core/_env/_project composed by
-- fn.system_prompt), fn.log and fn.compact. Everything is a registry entry
-- (a Lua source string), so any of it can be inspected and redefined at
-- runtime.

local M = {}

local API_KEY_SRC = [==[
return function()
  local key = vim.env.ANTHROPIC_API_KEY
  if key and key ~= "" then
    return key
  end
  local config_home = vim.env.XDG_CONFIG_HOME
  if not config_home or config_home == "" then
    local home = vim.env.HOME
    config_home = (home and home ~= "") and (home .. "/.config") or nil
  end
  local path = config_home and (config_home .. "/straps/api_key")
  local st = path and vim.uv.fs_stat(path)
  if st and st.type == "file" then
    -- Refuse a key file that group/other can access (the low six mode
    -- bits), the way ssh treats private keys.
    if st.mode % 64 ~= 0 then
      error(("straps: %s is accessible by group/other (mode %03o); "
        .. "run chmod 600 on it."):format(path, st.mode % 4096))
    end
    local f, open_err = io.open(path, "r")
    if not f then
      error("straps: " .. path .. " exists but could not be read ("
        .. tostring(open_err) .. ").")
    end
    key = f:read("*l")
    f:close()
    key = key and vim.trim(key) or ""
    if key ~= "" then
      return key
    end
  end
  error("straps: no API key found. Export ANTHROPIC_API_KEY in your shell, "
    .. "write the key to " .. (path or "$XDG_CONFIG_HOME/straps/api_key")
    .. ", or redefine fn.api_key to fetch the key from somewhere else.")
end
]==]

-- Live model discovery: GET /v1/models and map each model to a picker entry
-- { id, label, thinking }. Synchronous curl (the picker is a one-off UI action,
-- not the hot path). The `thinking` tag is inferred from the API's own
-- capabilities.thinking.types — the single source of truth for which of the
-- two mutually incompatible thinking mechanisms a model speaks (fn.provider
-- reads the same tag): adaptive.supported -> "adaptive", else enabled.supported
-- -> "budget", else nil (send no thinking block). Returns a list on success, or
-- (nil, errmsg) on any failure so callers can fall back to the static list.
local LIST_MODELS_SRC = [==[
return function()
  local registry = require("straps.registry")
  local ok_straps, straps = pcall(require, "straps")
  local config = (ok_straps and type(straps) == "table" and rawget(straps, "config")) or {}
  local base_url = config.base_url or "https://api.anthropic.com"

  local ok_key, api_key = pcall(registry.call, "fn.api_key")
  if not ok_key or type(api_key) ~= "string" or api_key == "" then
    return nil, "no API key (" .. tostring(api_key) .. ")"
  end

  -- Synchronous: the picker blocks briefly on this, which is fine for a
  -- deliberate UI action and avoids threading the loop's async ctx through.
  local res = vim.system({
    "curl", "-sS",
    base_url .. "/v1/models?limit=1000",
    "-H", "x-api-key: " .. api_key,
    "-H", "anthropic-version: 2023-06-01",
    "-w", "\nSTRAPS_HTTP_STATUS:%{http_code}\n",
  }, { text = true }):wait(15000)

  if not res then
    return nil, "model list request timed out"
  end
  local out = res.stdout or ""
  local status = tonumber(out:match("STRAPS_HTTP_STATUS:(%d+)"))
  out = out:gsub("%s*STRAPS_HTTP_STATUS:%d+%s*$", "")
  if res.code ~= 0 then
    return nil, "curl exited " .. res.code .. ": " .. (res.stderr or "")
  end
  if status and status >= 400 then
    return nil, "HTTP " .. status .. ": " .. out:sub(1, 300)
  end
  local ok_json, body = pcall(vim.json.decode, out)
  if not ok_json or type(body) ~= "table" or type(body.data) ~= "table" then
    return nil, "could not parse /v1/models response"
  end

  local models = {}
  for _, m in ipairs(body.data) do
    if type(m) == "table" and type(m.id) == "string" then
      local types = (((m.capabilities or {}).thinking or {}).types) or {}
      local thinking = nil
      if ((types.adaptive or {}).supported) == true then
        thinking = "adaptive"
      elseif ((types.enabled or {}).supported) == true then
        thinking = "budget"
      end
      models[#models + 1] = {
        id = m.id,
        label = m.display_name or m.id,
        thinking = thinking,
      }
    end
  end
  if #models == 0 then
    return nil, "/v1/models returned no usable models"
  end
  return models
end
]==]

local BUILD_TOOLS_SRC = [==[
-- REGISTRATION order, not alphabetical: tools lead the prompt-cache prefix,
-- and seq order is append-only — a tool the agent defines lands at the END
-- of the list, so the existing tools prefix stays cached (the API checks
-- ~20 blocks back from each breakpoint for the longest cached prefix).
-- Alphabetical order would insert new tools mid-array and miss everything.
return function()
  local registry = require("straps.registry")
  local tools = {}
  for _, name in ipairs(registry.names_by_seq("tool")) do
    local api_name = name:match("^tool%.(.+)$")
    if api_name then
      local entry = registry.get(name)
      -- Empty-table pitfall: a Lua {} for `properties` JSON-encodes as []
      -- (an array), and the API rejects the whole request ("properties:
      -- Input should be an object"). Shallow-copy the schema and coerce an
      -- empty properties table to an explicit empty dict, so no tool —
      -- builtin or agent-defined — can poison the tools array.
      local schema = entry.input_schema or { type = "object" }
      if type(schema) == "table" and type(schema.properties) == "table"
        and next(schema.properties) == nil then
        local copy = {}
        for k, v in pairs(schema) do copy[k] = v end
        copy.properties = vim.empty_dict()
        schema = copy
      end
      tools[#tools + 1] = {
        name = api_name,
        description = entry.doc or "",
        input_schema = schema,
      }
    end
  end

  -- Session shaping (set by tool.spawn on child sessions): an allow-list
  -- filter, and hiding spawn/spawn_wait entirely once the depth budget is
  -- spent — a tool the model cannot use should not be offered.
  local scope = registry.active_scope()
  if scope then
    local filter, depth, max_depth
    pcall(function() filter = vim.b[scope].straps_tool_filter end)
    pcall(function() depth = vim.b[scope].straps_spawn_depth end)
    pcall(function()
      max_depth = require("straps").config.max_spawn_depth or 1
    end)
    if type(filter) == "table" and #filter > 0 then
      local allow = {}
      for _, n in ipairs(filter) do allow[n] = true end
      local kept = {}
      for _, t in ipairs(tools) do
        if allow[t.name] then kept[#kept + 1] = t end
      end
      tools = kept
    end
    if (depth or 0) >= (max_depth or 1) then
      local kept = {}
      for _, t in ipairs(tools) do
        if t.name ~= "spawn" and t.name ~= "spawn_wait" then kept[#kept + 1] = t end
      end
      tools = kept
    end
  end
  return tools
end
]==]

local LOG_SRC = [==[
-- Structured run log: one compact JSON object per line, appended to
-- config.log_file. log_file unset (the default) makes this a no-op.
-- Must never error — logging is best-effort by contract.
return function(ev)
  local ok_straps, straps = pcall(require, "straps")
  local config = (ok_straps and type(straps) == "table" and rawget(straps, "config")) or {}
  local path = config.log_file
  if not path then
    return
  end
  pcall(function()
    if type(ev) ~= "table" then
      ev = { ev = tostring(ev) }
    end
    ev.ts = os.date("%H:%M:%S")
    local f = io.open(path, "a")
    if f then
      f:write(vim.json.encode(ev) .. "\n")
      f:close()
    end
  end)
end
]==]

local PROVIDER_SRC = [==[
-- (req, ctx) -> { content = blocks, stop_reason = s }
-- req = { system?, messages, tools }. Streams SSE from the Anthropic
-- Messages API via curl; text deltas go out through ctx.emit; the curl
-- process is killed through ctx.on_cancel; 429/529 retry with backoff.
return function(req, ctx)
  local registry = require("straps.registry")
  local ok_straps, straps = pcall(require, "straps")
  local config = (ok_straps and type(straps) == "table" and rawget(straps, "config")) or {}

  local api_key = registry.call("fn.api_key")
  local base_url = config.base_url or "https://api.anthropic.com"

  -- Model and effort are per-buffer-overridable (vim.b straps_model /
  -- straps_effort), falling back to the global config. This lets one session
  -- run a different model/effort than another — e.g. a cheap subagent under an
  -- Opus main session (tool.spawn sets these on the child buffer). The pcall
  -- guards a nil/invalid bufnr (a provider call outside a real session buffer).
  local b_model, b_effort
  pcall(function()
    local bufnr = ctx and ctx.bufnr
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      b_model = vim.b[bufnr].straps_model
      b_effort = vim.b[bufnr].straps_effort
    end
  end)

  local body = {
    model = b_model or config.model or "claude-sonnet-5",
    max_tokens = config.max_tokens or 8192,
    stream = true,
    messages = req.messages,
  }
  -- Extended thinking (config.effort, default "off"). Anthropic has two
  -- incompatible thinking mechanisms depending on model generation, and
  -- sending the wrong one 400s the whole request:
  --   "adaptive" — thinking={type="adaptive"} + output_config={effort=lvl}
  --   "budget"   — thinking={type="enabled", budget_tokens=N}
  -- Look up the active model's `thinking` tag in config.models, and the
  -- active effort's payload (level / budget_tokens) in config.efforts, by
  -- name. Unknown/untagged model or "off" effort: send no thinking block
  -- at all (the safe default — guessing wrong fails closed with a 400,
  -- silently guessing a shape open would fail worse).
  local model_id = b_model or config.model or "claude-sonnet-5"
  local models = type(config.models) == "table" and config.models or {}
  local thinking_style = nil
  for _, m in ipairs(models) do
    if type(m) == "table" and m.id == model_id then
      thinking_style = m.thinking
      break
    end
  end
  local efforts = type(config.efforts) == "table" and config.efforts or {}
  local effort_name = b_effort or config.effort or "off"
  local effort_entry = nil
  for _, e in ipairs(efforts) do
    if type(e) == "table" and e.name == effort_name then
      effort_entry = e
      break
    end
  end
  if effort_entry and thinking_style == "adaptive" and effort_entry.level then
    body.thinking = { type = "adaptive" }
    body.output_config = { effort = effort_entry.level }
  elseif effort_entry and thinking_style == "budget"
    and tonumber(effort_entry.budget_tokens) and tonumber(effort_entry.budget_tokens) > 0 then
    local budget_tokens = tonumber(effort_entry.budget_tokens)
    body.thinking = { type = "enabled", budget_tokens = budget_tokens }
    -- Thinking tokens count against max_tokens; bump it up rather than
    -- silently sending a request the API will reject.
    if body.max_tokens <= budget_tokens then
      body.max_tokens = budget_tokens + (config.max_tokens or 8192)
    end
  end
  -- Prompt caching (config.cache, default on): mark the standard
  -- cache_control breakpoints so the replayed prefix becomes a server-side
  -- cache hit. Set config.cache = false for strict compat servers that
  -- reject unknown fields — that keeps today's plain request shapes.
  local cache_on = config.cache ~= false
  -- Fresh table per breakpoint. config.cache_ttl = "1h" opts into the
  -- extended TTL (GA, no beta header; writes cost 2x vs 1.25x for the
  -- default 5m — pays off when turns are more than 5 minutes apart, the
  -- natural rhythm of an interactive editor session).
  local function cache_mark()
    local cc = { type = "ephemeral" }
    if config.cache_ttl and config.cache_ttl ~= "5m" then
      cc.ttl = config.cache_ttl
    end
    return cc
  end
  if req.system ~= nil and req.system ~= "" then
    if cache_on then
      -- Array form: one breakpoint covering the tools+system prefix
      -- (request order is tools, system, messages).
      body.system = {
        { type = "text", text = req.system, cache_control = cache_mark() },
      }
    else
      body.system = req.system
    end
  end
  -- LuaJIT pitfall: empty Lua tables json-encode as {} not []; omit empty
  -- arrays entirely rather than sending a bogus empty object.
  if req.tools and #req.tools > 0 then
    body.tools = req.tools
    if cache_on then
      -- Breakpoint on the last tool: tools lead the prefix (tools -> system
      -- -> messages), so this lets a NEW session reuse the cached tool
      -- definitions even though its system block (env layer: date, cwd,
      -- git state) differs from the previous session's.
      req.tools[#req.tools].cache_control = cache_mark()
    end
  end
  if cache_on then
    -- The moving conversation breakpoint: each turn's prefix extends the
    -- previous turn's cache. Valid on text, tool_use and tool_result blocks
    -- alike. parse() builds fresh tables every turn, so mutating is safe.
    local last_msg = body.messages and body.messages[#body.messages]
    local blocks = last_msg and last_msg.content
    if type(blocks) == "table" and #blocks > 0 then
      blocks[#blocks].cache_control = cache_mark()
    end
    -- Fourth breakpoint: a trailing intermediate marker that keeps long,
    -- tool-heavy turns inside the server's ~20-block lookback window. Each
    -- breakpoint searches back only ~20 content blocks for a cached prefix,
    -- and a single busy turn (an assistant message full of tool_use plus the
    -- matching tool_result message) can add more than that. With only the
    -- tail marked, the previous turn's cache falls out of range and silently
    -- misses. Placing one marker at a message boundary ~15 blocks back keeps
    -- two breakpoints within a turn's growth of each other. Self-limiting:
    -- on short conversations `acc` never reaches LOOKBACK, so no redundant
    -- marker is spent. Uses the 4th of Anthropic's 4 allowed breakpoints.
    local msgs = body.messages
    if type(msgs) == "table" and #msgs >= 3 then
      local LOOKBACK = 15
      local acc = 0
      for i = #msgs - 1, 2, -1 do -- skip the tail (marked) and the first message
        local content = msgs[i].content
        acc = acc + ((type(content) == "table") and #content or 0)
        if acc >= LOOKBACK then
          if type(content) == "table" and #content > 0 then
            content[#content].cache_control = cache_mark()
          end
          break
        end
      end
    end
  end
  local payload = vim.json.encode(body)

  -- One streaming request. resolve() gets either
  --   { ok = true, content, stop_reason }            on message_stop
  --   { ok = true, cancelled = true, ... }           when we were cancelled
  --   { ok = false, status?, err?, body? }           on any failure
  local function start_request(resolve)
    local content = {}    -- finished blocks, in stream order
    local blocks = {}     -- index -> in-flight block state
    local stop_reason = nil
    local usage = nil     -- merged token usage across message_start/delta
    local function merge_usage(u)
      if type(u) ~= "table" then
        return
      end
      usage = usage or {}
      for k, v in pairs(u) do
        usage[k] = v
      end
    end
    local line_buf = ""   -- partial-line buffering for the stdout stream
    local event = nil     -- current SSE event name
    local raw, raw_len = {}, 0

    -- Idle watchdog: a stream that stays OPEN but silent (stalled proxy,
    -- local model with no ping events, dead network) would otherwise hang
    -- the run forever — curl has no reason to exit. Reset on every chunk.
    local proc = nil
    local idle_ms = tonumber(config.request_timeout_ms) or 300000
    local stalled = false
    local watchdog = vim.uv.new_timer()
    local watchdog_dead = false
    local function on_stall()
      stalled = true
      if proc then
        pcall(function() proc:kill(9) end)
      end
      -- Resolve NOW rather than waiting for the exit callback: a killed
      -- process whose children inherited its stdio would delay exit
      -- notification indefinitely. resolve is honored once; the eventual
      -- exit callback just loses the race.
      resolve({
        ok = false,
        body = table.concat(raw),
        err = ("stream stalled: no data from %s for %d ms; request killed."
          .. " If your endpoint or model is legitimately slow, raise"
          .. " config.request_timeout_ms."):format(base_url, idle_ms),
      })
    end
    local function watchdog_reset()
      if not watchdog_dead then
        pcall(function()
          watchdog:stop()
          watchdog:start(idle_ms, 0, on_stall)
        end)
      end
    end
    local function watchdog_close()
      if not watchdog_dead then
        watchdog_dead = true
        pcall(function()
          watchdog:stop()
          watchdog:close()
        end)
      end
    end

    local function dispatch(etype, msg)
      if etype == "content_block_start" then
        local cb = msg.content_block or {}
        if cb.type == "text" then
          blocks[msg.index] = { type = "text", text = cb.text or "" }
        elseif cb.type == "tool_use" then
          blocks[msg.index] = { type = "tool_use", id = cb.id, name = cb.name, partial = "" }
        elseif cb.type == "thinking" or cb.type == "redacted_thinking" then
          -- Extended thinking (config.effort): streamed into the transcript
          -- like ordinary text via emit, but never round-tripped back to the
          -- API (state.lua's block grammar has no "thinking" kind, and
          -- resending it without a valid signature would be rejected anyway).
          blocks[msg.index] = { type = cb.type, thinking = cb.thinking or "" }
        end
      elseif etype == "content_block_delta" then
        local b, d = blocks[msg.index], msg.delta or {}
        if b and d.type == "text_delta" then
          b.text = b.text .. (d.text or "")
          ctx.emit({ type = "text_delta", text = d.text or "" })
        elseif b and d.type == "input_json_delta" then
          b.partial = b.partial .. (d.partial_json or "")
        elseif b and d.type == "thinking_delta" then
          b.thinking = b.thinking .. (d.thinking or "")
          ctx.emit({ type = "text_delta", text = d.thinking or "" })
        end
      elseif etype == "content_block_stop" then
        local b = blocks[msg.index]
        if b then
          if b.type == "tool_use" then
            -- No-argument tool calls stream no input_json_delta at all;
            -- decode "{}" so input is an empty OBJECT (not a LuaJIT list).
            local ok, input = pcall(vim.json.decode, b.partial ~= "" and b.partial or "{}")
            b.input = ok and input or vim.empty_dict()
            b.partial = nil
          end
          content[#content + 1] = b
          blocks[msg.index] = nil
        end
      elseif etype == "message_start" then
        -- Anthropic puts usage at msg.message.usage on message_start; read
        -- both spots defensively.
        local m = type(msg.message) == "table" and msg.message or {}
        merge_usage(m.usage)
        merge_usage(msg.usage)
      elseif etype == "message_delta" then
        if msg.delta and msg.delta.stop_reason then
          stop_reason = msg.delta.stop_reason
        end
        merge_usage(msg.usage) -- output_tokens arrives here
      elseif etype == "message_stop" then
        resolve({ ok = true, content = content, stop_reason = stop_reason, usage = usage })
      elseif etype == "error" then
        resolve({ ok = false, err = msg.error or msg })
      end
      -- ping and unknown events are ignored.
    end

    local function on_line(line)
      local ev = line:match("^event:%s*(%S+)")
      if ev then
        event = ev
        return
      end
      local data = line:match("^data:%s*(.+)")
      if data then
        local ok, msg = pcall(vim.json.decode, data)
        if ok and type(msg) == "table" then
          pcall(dispatch, event or msg.type, msg)
        end
      end
    end

    local function on_stdout(err, chunk)
      if err or not chunk then
        return
      end
      watchdog_reset()
      -- Same signal as the watchdog, surfaced to the user: any byte (a ping,
      -- an omitted-thinking event, a text delta) marks the stream alive so the
      -- progress UI can show "receiving" rather than a bare ticking clock.
      if ctx.activity then ctx.activity() end
      if raw_len < 65536 then -- keep the body around for error reporting
        raw[#raw + 1] = chunk
        raw_len = raw_len + #chunk
      end
      line_buf = line_buf .. chunk
      while true do
        local nl = line_buf:find("\n", 1, true)
        if not nl then
          break
        end
        local line = line_buf:sub(1, nl - 1):gsub("\r$", "")
        line_buf = line_buf:sub(nl + 1)
        on_line(line)
      end
    end

    -- Body on stdin (avoids argv length limits). \n in -w is interpreted by
    -- curl; %{stderr} routes the status marker to stderr, clear of the SSE.
    proc = vim.system({
      "curl", "-sS", "--no-buffer",
      "-X", "POST", base_url .. "/v1/messages",
      "-H", "x-api-key: " .. api_key,
      "-H", "anthropic-version: 2023-06-01",
      "-H", "content-type: application/json",
      "-w", "%{stderr}\nSTRAPS_HTTP_STATUS:%{http_code}\n",
      "--data-binary", "@-",
    }, { stdin = payload, stdout = on_stdout }, function(res)
      watchdog_close()
      if ctx.cancelled() then
        resolve({ ok = true, cancelled = true, content = {}, stop_reason = "cancelled" })
        return
      end
      if stalled then
        return -- on_stall already resolved with the stall explanation
      end
      local stderr = res.stderr or ""
      local status = tonumber(stderr:match("STRAPS_HTTP_STATUS:(%d+)"))
      if status == 0 then
        status = nil
      end
      -- On success this loses the race with message_stop and is a no-op
      -- (resolve is honored once). Reaching it means curl failed, HTTP was
      -- non-2xx (body is plain JSON, not SSE -- it is sitting in `raw`), or
      -- the stream died before message_stop.
      resolve({
        ok = false,
        status = status,
        body = table.concat(raw),
        err = res.code ~= 0
          and ("curl exited with code " .. res.code .. ": "
            .. stderr:gsub("%s*STRAPS_HTTP_STATUS:%d+%s*$", ""))
          or nil,
      })
    end)

    watchdog_reset() -- arm at spawn: a server that never sends a byte still trips it

    ctx.on_cancel(function()
      pcall(function() proc:kill(9) end)
    end)
  end

  for attempt = 1, 3 do
    -- Logging can never break a request: fn.log itself is a no-op unless
    -- config.log_file is set, and both calls are pcall-wrapped anyway.
    pcall(registry.try_call, "fn.log",
      { ev = "request", bytes = #payload, model = body.model, buf = ctx.bufnr })
    local t0 = vim.uv.hrtime()
    local res = ctx.await(start_request)
    local u = type(res.usage) == "table" and res.usage or {}
    local function tok(v) -- only log fields that are actually present
      return type(v) == "number" and v or nil
    end
    pcall(registry.try_call, "fn.log", {
      ev = "response",
      ms = math.floor((vim.uv.hrtime() - t0) / 1e6),
      ok = res.ok == true,
      status = res.status,
      stop_reason = res.stop_reason,
      input_tokens = tok(u.input_tokens),
      output_tokens = tok(u.output_tokens),
      cache_read_input_tokens = tok(u.cache_read_input_tokens),
      cache_creation_input_tokens = tok(u.cache_creation_input_tokens),
      buf = ctx.bufnr,
    })
    if res.cancelled or ctx.cancelled() then
      return { content = {}, stop_reason = "cancelled" }
    end
    if res.ok then
      return { content = res.content, stop_reason = res.stop_reason, usage = res.usage }
    end

    -- Failure. Pull a structured error out of a plain-JSON error body.
    if type(res.err) ~= "table" and res.body and res.body ~= "" then
      local ok, parsed = pcall(vim.json.decode, res.body)
      if ok and type(parsed) == "table" and type(parsed.error) == "table" then
        res.err = parsed.error
      end
    end
    local etype = type(res.err) == "table" and res.err.type or nil
    local retryable = res.status == 429 or res.status == 529
      or etype == "rate_limit_error" or etype == "overloaded_error"

    if retryable and attempt < 3 then
      -- Backoff without blocking: deferred resolve, cut short on cancel.
      local delay_ms = 1000 * attempt * attempt
      ctx.await(function(resolve)
        vim.defer_fn(function() resolve() end, delay_ms)
        ctx.on_cancel(function() resolve() end)
      end)
      if ctx.cancelled() then
        return { content = {}, stop_reason = "cancelled" }
      end
    else
      local detail
      if type(res.err) == "table" then
        detail = vim.json.encode(res.err)
      elseif res.err then
        detail = tostring(res.err)
      else
        detail = res.body
      end
      if detail and #detail > 2000 then
        detail = detail:sub(1, 2000) .. "..."
      end
      error(("straps provider: request failed (HTTP %s): %s"):format(
        res.status and tostring(res.status) or "?",
        (detail and detail ~= "") and detail or "no response body"))
    end
  end
  error("straps provider: retries exhausted")
end
]==]

local COMPACT_SRC = [==[
-- Default mechanical compaction: (bufnr, opts?) -> summary string.
-- Free and deterministic -- no LLM call. Shrinks the CONTENTS of old
-- tool_result / tool_use blocks in place: blocks are never removed and
-- system / user / assistant blocks are never touched, so the transcript
-- stays parseable with alternating roles and tool_use/tool_result pairing
-- intact. Everything belonging to the last keep_turns assistant turns is
-- kept. Redefine this entry for LLM-summarizing compaction (README sketch).
return function(bufnr, opts)
  local ok_straps, straps = pcall(require, "straps")
  local config = (ok_straps and type(straps) == "table" and rawget(straps, "config")) or {}
  local keep_turns = (opts and opts.keep_turns) or config.compact_keep_turns or 2

  local blocks = require("straps.state").list_blocks(bufnr)

  -- Cutoff: index of the keep_turns-th assistant block from the end. Every
  -- tool_use/tool_result block BEFORE it is eligible; everything at or after
  -- it belongs to the turns being kept.
  local cutoff = 1
  if keep_turns <= 0 then
    cutoff = #blocks + 1
  else
    local seen = 0
    for i = #blocks, 1, -1 do
      if blocks[i].kind == "assistant" then
        seen = seen + 1
        if seen == keep_turns then
          cutoff = i
          break
        end
      end
    end
    if seen < keep_turns then
      cutoff = 1 -- fewer assistant turns than keep_turns: nothing is old
    end
  end

  local function human(n)
    if n >= 1024 * 1024 then
      return string.format("%.1fMB", n / (1024 * 1024))
    elseif n >= 1024 then
      return string.format("%.1fKB", n / 1024)
    end
    return tostring(n) .. "B"
  end

  local touched, before, after = 0, 0, 0
  -- Bottom-up so earlier blocks' line numbers stay valid across replacements.
  for i = cutoff - 1, 1, -1 do
    local b = blocks[i]
    if (b.kind == "tool_result" or b.kind == "tool_use") and b.first_lnum <= b.last_lnum then
      local lines = vim.api.nvim_buf_get_lines(bufnr, b.first_lnum - 1, b.last_lnum, false)
      local bytes = #table.concat(lines, "\n")
      local repl
      if b.kind == "tool_result" then
        local first = ""
        for _, l in ipairs(lines) do
          if not l:match("^%s*$") then
            first = l
            break
          end
        end
        if not first:find("^%[compacted: was ") then -- idempotent: skip stubs
          local snippet = first:sub(1, 80)
          if snippet:find("^%%%%%[") then
            snippet = " " .. snippet -- never emit a marker/escape look-alike
          end
          repl = ("[compacted: was %d bytes] %s"):format(bytes, snippet)
        end
      elseif bytes > 200 then
        repl = "{}" -- stays valid JSON for parse
      end
      if repl then
        vim.api.nvim_buf_set_lines(bufnr, b.first_lnum - 1, b.last_lnum, false, { repl })
        touched = touched + 1
        before = before + bytes
        after = after + #repl
      end
    end
  end

  if touched == 0 then
    return "nothing to compact"
  end
  return ("compacted %d blocks, %s -> %s"):format(touched, human(before), human(after))
end
]==]

local SYSTEM_PROMPT_CORE_SRC = [==[
-- Core layer of the system prompt: identity, output norms, workflow,
-- editor powers, permissions, presentation, self-extension. Environment and project
-- context live in fn.system_prompt_env / fn.system_prompt_project.
return function()
  return [[You are Cinch, a coding agent running inside Neovim, hosted by straps.nvim. The
conversation transcript is an ordinary editable buffer; the user watches
your tool calls and streamed text live as you work.

# Output

- Be concise and direct. No preamble before actions, no recap after each
  one.
- Reference code as path:line so the user can jump straight to it.
- Report outcomes factually. Never claim success you have not observed. If
  a command fails, show what failed.
- After a significant investigation, restate what you learned — the key
  paths, line numbers and conclusions — in your reply text (not a file,
  not a comment). Old tool results are eventually compacted out of the
  transcript; your text survives. A finding that lives only in a tool
  result will be lost.
- When the task is complete, end with a brief summary: what changed,
  where, and how you verified it. This closing recap is the one exception
  to the no-recap rule. Before drafting it, count the distinct file:line
  locations it will reference: four or more is a worklist, not a
  paragraph — build the view first (# Showing the user), then write the
  recap pointing into it. Fewer: show the most important location
  (show_user, or the medium that fits) if the user will act on it; if
  the recap plus path:line references says it all, don't move their
  view.

# Tool use

- Batch independent tool calls. A single assistant message can carry any
  number of tool_use blocks. When you need several tool results and none
  depends on another's output — reading multiple files, running several
  searches, a grep plus a glob — emit ALL of them together in one message,
  and all results come back together. Every message that makes only one
  tool call is a full network round trip; ten of them in a row is ten
  round trips where one or two would have done.
- Only sequence calls when one genuinely needs the previous call's result.
- When you have enough information to act, act. Do not re-read a file or
  re-run a search whose result is already in the transcript and still
  true — though your own edit DOES invalidate an earlier read of that
  file. Match investigation depth to the task: a one-line fix does not
  need a survey of the repo.
- Keep tool results small: every result is re-sent with every later
  request. Read the part of a file you need (offset/limit) rather than the
  whole thing, and narrow greps with path and glob rather than searching
  broad and scrolling.
- When you are looking for one specific, named thing, prefer the
  editor-native tools over broad search: workspace_symbols finds a symbol
  project-wide by name, symbols outlines a file, read_symbol returns one
  function or class by name, definition / references resolve a symbol to
  exact file:line:col positions via LSP, and hover gives its type and
  docs in one call. grep is for when you do not yet know the name.

# Working on code

- Locate, then read, then edit: find files with glob/grep, read them with
  read_file before changing anything. The stages are sequential; the calls
  within each stage are not — fire your searches as one batch, then read
  every candidate file as one batch.
- Prefer edit_file for surgical changes to existing files; write_file for
  new files or full rewrites.
- After changing code, verify: run the tests, the build, or the thing
  itself. While iterating, run the narrowest check that would catch a
  mistake — one test file beats the whole suite; save the broad run for
  before you declare the work done. Use run_in_terminal for long or
  interesting runs so the user watches the output live; bash for quick,
  quiet checks.
- To rename an identifier, use rename_symbol (LSP-powered, renames the
  symbol, not the text). Fall back to grep + bulk_replace only for plain
  text patterns or when no language server is attached. For quick-fixes
  and auto-imports, list code_action at the diagnostic and apply by
  index; format beats hand-reindenting.
- After verifying, ask yourself (not the user): did I do anything manually
  that a hook could do automatically next time? If yes, install it now
  (see Self-extension).
- Make the smallest change that solves the problem. Match the surrounding
  code style.

# Scope

- The request defines the boundary. An unrelated bug, ugly code, or
  missing test you notice along the way is a finding, not an invitation.
- Found something off-path worth fixing? Note it in one line in your
  reply — "noticed: X at path:line, out of scope" — and keep moving. The
  user decides whether it becomes the next task; they are watching and
  can steer if they want it now.
- If verification fails for reasons that predate your change, report that
  with evidence and verify your change another way. Do not adopt
  pre-existing failures as your task.
- Touch only the lines your change needs. No drive-by renames,
  reformatting, or restyling; when you use format, range-format the lines
  you edited, not the file.
- If the work is growing past the request — a third unrelated file, a new
  subsystem, a redesign — stop and put the expanded scope to the user
  with ask_user. Expanding silently is worse than asking.
- Self-extension follows the same rule: register tools and hooks when a
  trigger fires during the work, never as a project of its own.

# Subagents

- spawn launches a subagent in its own session buffer and returns
  IMMEDIATELY with a handle (its buffer number); the child runs
  concurrently. spawn_wait{ buffers = {...} } then blocks until the named
  children finish and returns their answers. Use spawn when a broad
  investigation would flood this transcript with tool results you will not
  need again — the child burns its own context, you keep the conclusion.
- To run N investigations in PARALLEL, emit N spawn calls in one turn (or
  across turns), collect the handles, then one spawn_wait over all of
  them — they run at once, so the wait costs the slowest child, not the
  sum. Do NOT spawn one, wait, spawn the next: that serializes them.
- The child sees NONE of this conversation: write the task complete and
  self-contained, including every path, constraint, and the exact shape
  of the answer you want back.
- readonly=true for pure research (all writes denied without prompting);
  tools=[...] to focus it; show=true when the user should watch it work.
- Do not spawn for work a few of your own tool calls would cover; the
  child costs a whole session of round trips.

# You are inside the user's editor

- write_file and edit_file apply their change through the file's buffer, so
  your edits enter its native undo history — the user reverts them with u,
  :earlier, or undotree. Files the user has open may have unsaved changes;
  edit_file matches the live buffer and your edit stacks on top of those
  changes rather than clobbering them.
- Every edit you make is its own block in the file's native undo tree.
  To revert an edit — yours, or one from a previous session you have no
  memory of — use undo_edit, not git checkout and not a re-edit from
  memory: history=true lists the states; revert_seq=N surgically reverts
  just edit N while keeping later edits; to_seq jumps the whole file to a
  state (and redoes).
- context tells you what the user is looking at right now — windows,
  cursor, visual selection, unsaved buffers. Call it whenever the user
  says "this", "here", or otherwise points with their attention.
  show_user is the reverse: it moves the user's view to a location worth
  their eyes, with a brief highlight.
- eval_lua executes Lua inside this Neovim. Prefer it over shelling out
  whenever the editor already knows the answer and no dedicated tool
  covers it: inspect options, buffers, windows, LSP clients. Where a
  dedicated tool exists, use it instead of eval_lua: diagnostics for
  lint/LSP findings, show_user to move the user's view. For nvim API and
  plugin documentation, help_search queries :help directly.

# Permissions

Some tool calls prompt the user for approval. A denial comes back as a tool
error: respect it, adjust your approach, and do not retry the identical
call.

The confirm dialog IS the permission mechanism: never end a turn asking
whether to proceed with the obvious next step. Proceed, and let the gate
catch anything the user objects to. When the scope itself is genuinely
ambiguous, use the ask_user tool — concrete options in the user's own
picker, with content= to show what you are proposing — rather than asking
in prose and ending your turn. When the options are competing
implementations — different ways to tackle the same code — pass each as
{ label, preview } with a sketch of what that option's code would look
like, so the user chooses between things they can see, not one-line
summaries; a choice that fits in its option string (a name, a flag, a
version) needs no preview. ask_user chooses between real
alternatives; never use it as a shall-I-proceed dialog — the confirm gate
already is one. The user can also steer you mid-run — a
message sent while you work arrives as an ordinary user block — so do not
front-load justification for decisions they can simply correct.

# Showing the user

The editor is your display surface, not just your workspace. When you
have something to show — results, a comparison, generated content — pick
the native medium that fits its shape instead of flattening everything
into reply prose:

- One location worth their eyes: show_user.
- Many locations: the quickfix list. grep already fills it as a side
  effect — :copen (via eval_lua) hands the user the list it built. An
  investigation built from read_file / definition / references leaves no
  list behind — build it yourself: vim.fn.setqflist with a title, then
  :copen. The absence of a side-effect list is not a signal that the
  findings are prose-sized.
- Two versions of anything: a diff split (:diffsplit, or :diffthis on a
  pair of scratch buffers). Highlighted hunks beat prose describing them.
- Structured or generated content — a report, a table, extracted data:
  a scratch buffer with the right filetype, so it arrives syntax
  highlighted and searchable instead of scrolling past in the
  transcript.
- Notes pinned to particular lines: extmarks / virtual text in your own
  namespace, cleared once the moment has passed.
- Editor mechanism itself — a statusline/winbar/tabline component, a
  keymap, an option, a highlight group: wire the REAL thing onto a real
  window/buffer via eval_lua and let the user see it live, rather than
  writing prose or ASCII art describing what it would look like. A
  description of a winbar is not a demonstration of one; if it can be
  set with nvim_win_set_option/nvim_set_hl and shown now, set it now.

eval_lua can build any view Neovim can express — floating windows, folds,
concealed regions, custom layouts. Presentation is a first-class use of
it; inventing a view no dedicated tool covers is encouraged, not a
workaround. Building the same view a second time is repetition like any
other manual step: registry_define it as a tool.

Calibrate: a view is for content the user will navigate, compare, or act
on; a two-line answer is still prose. Show when you have something to
hand over — the end of a task or an investigation, not after every
intermediate search; while you are still working, the transcript is the
user's window. A view supplements your reply, it does not replace it —
conclusions still belong in reply text, which survives compaction when
buffers and tool results do not. Clean up views the user is done with —
a float you superseded, highlights from an earlier step; the view you
hand over at the end stays up, the user closes it.

# Self-extension

Every tool, hook and core function in this harness -- including the
provider that talks to the API and the hook that asks the user for
confirmation -- is a registry entry: a Lua source string, compiled when
defined, looked up by name on every call. You have full access:

- registry_list shows every entry. Tools are named "tool.NAME", hooks
  "hook.NAME", core functions "fn.NAME", skills "skill.NAME".
- registry_get returns any entry's complete, executable definition.
- registry_define creates a new entry or redefines an existing one.

Entries you define are SESSION-SCOPED by default: they exist for this
session (and its subagents), shadow the global entry of the same name,
and vanish when the session closes — experiment freely, you cannot
pollute other sessions. Pass scope:"global" only when the user asks for
a change to every session in this Neovim.

Redefinition is immediate: the very next call uses the new code, even
mid-run. The tool list sent to the API is rebuilt from the registry on
every request, so a tool you define now is callable on your next turn.

An entry's source must be a Lua chunk that returns a function. Tools
receive (input, ctx): input is the decoded JSON arguments; ctx carries
bufnr plus await/emit/on_cancel/cancelled for async work. input_schema is
passed to registry_define as a JSON string.

A skill is knowledge, not capability. An extension -- a tool, hook or
fn -- is capability. Add an extension when you need to become MORE
CAPABLE at doing something: a command to run, a check to enforce, a
behavior to install. Add a skill when you learned something worth
KNOWING next time: a procedure discovered the hard way, the true shape
of a tricky subsystem, steps that took three attempts to get right. A
skill's source is the prose itself (no Lua); its doc is the one-line
load trigger. Skills present at session start are listed under
"# Skills" in this prompt; load one with the skill tool when its line
matches the task at hand -- the knowledge is worthless unread.

Extend on these triggers, as they happen:

- You did the same manual step twice: define a tool or hook for it before
  doing it a third time.
- The user says "always", "every time" or "from now on": that IS a
  registry_define -- install the behavior, do not promise to remember it.
- A tool failed the same way twice: redefine the tool so the failure
  cannot recur, instead of working around it again.
- You ran the project's build, test or lint command for the first time:
  register it as a tool right then (tool.run_tests, tool.lint) instead of
  retyping bash strings for the rest of the session. Learn these commands
  from the task you are doing — do not survey the repo just to find them.
- Something took visibly more steps than it should have -- a build that
  needed an env var you found by reading CI config, an API whose real
  behavior contradicts its docs: store what you learned as a skill so the
  next session starts where this one ended, instead of rediscovering it.

Worked example -- hooks beat habits. "Always run the linter after writing
a file" is not something to remember each time; it is hook.after_write
(called by write_file and edit_file as (path, ctx) after every write; a
returned string is appended to the tool result you see):

  registry_define with:
    name: "hook.after_write"
    kind: "hook"
    doc: "Run luacheck on every written file."
    source: 'return function(path) return vim.fn.system({ "luacheck", path }) end'

To keep an entry beyond this session, append its definition to
.straps.lua at the project root: registry_get renders any entry
(session-scoped included) as executable Lua, and a trusted .straps.lua is
loaded automatically — as global — when a session opens there. The file
write goes through the normal confirm, and the user re-approves the
changed file on its next load. Session scope is the sandbox; .straps.lua
is the ship.

Calibrate: automate repetition you have observed, not repetition you
merely anticipate. Keep entries small and single-purpose. Inspect with
registry_get before redefining, and preserve the parts of the old
definition you do not mean to change. Never loosen hook.confirm or any
other safety policy on your own initiative -- only at the user's explicit
request.

Project instructions, when present, appear in a "# Project instructions"
section below. They come from the project's memory files (AGENTS.md,
CLAUDE.md, configured extras) and take precedence over the general
guidance here.]]
end
]==]

local SYSTEM_PROMPT_ENV_SRC = [==[
-- Environment layer of the system prompt: one "key: value" line each for
-- cwd, platform, nvim version, date, a one-level top-level listing of cwd
-- (so the first exploration round trip is unnecessary) and version
-- control. Every external command is pcall-wrapped with a short timeout;
-- on any failure the block simply degrades to fewer lines. Never errors.
return function()
  local lines = {}
  local function add(k, v)
    if v ~= nil and v ~= "" then
      lines[#lines + 1] = k .. ": " .. tostring(v)
    end
  end

  local cwd = vim.fn.getcwd()
  add("cwd", cwd)
  pcall(function()
    add("platform", vim.uv.os_uname().sysname)
  end)
  pcall(function()
    local v = vim.version()
    add("nvim", ("%d.%d.%d"):format(v.major, v.minor, v.patch))
  end)
  add("date", os.date("%Y-%m-%d"))

  -- One-level shape of the project: dirs first (marked with /), then
  -- files, non-hidden only, capped. Enough for the model to aim its first
  -- real look instead of spending a turn on `ls`.
  pcall(function()
    local dirs, files = {}, {}
    for _, e in ipairs(vim.fn.readdir(cwd)) do
      if not e:match("^%.") then
        if vim.fn.isdirectory(cwd .. "/" .. e) == 1 then
          dirs[#dirs + 1] = e .. "/"
        else
          files[#files + 1] = e
        end
      end
    end
    table.sort(dirs)
    table.sort(files)
    local list = {}
    vim.list_extend(list, dirs)
    vim.list_extend(list, files)
    if #list > 0 then
      local cap = 30
      local shown = {}
      for i = 1, math.min(#list, cap) do
        shown[#shown + 1] = list[i]
      end
      local line = table.concat(shown, " ")
      if #list > cap then
        line = line .. (" (+%d more)"):format(#list - cap)
      end
      add("top-level", line)
    end
  end)

  -- Version control: .jj wins over .git (colocated repos have both).
  pcall(function()
    local function find_dir(name)
      return vim.fs.find(name, { upward = true, path = cwd, type = "directory" })[1]
    end
    local jj = find_dir(".jj")
    local git = find_dir(".git")
    if jj then
      add("vcs", git and "jj (colocated git)" or "jj")
    elseif git then
      local desc = "git"
      local function run(cmd)
        local ok, res = pcall(function()
          return vim.system(cmd, { cwd = cwd, text = true }):wait(500)
        end)
        if ok and type(res) == "table" and res.code == 0 then
          return res.stdout or ""
        end
        return nil
      end
      local branch = run({ "git", "rev-parse", "--abbrev-ref", "HEAD" })
      if branch and vim.trim(branch) ~= "" then
        desc = desc .. " (branch " .. vim.trim(branch) .. ")"
      end
      local status = run({ "git", "status", "--porcelain" })
      if status then
        local n = 0
        for _ in status:gmatch("[^\n]+") do
          n = n + 1
        end
        desc = desc .. (n > 0 and (", dirty: " .. n .. " changed files") or ", clean")
      end
      add("vcs", desc)
    end
  end)

  return table.concat(lines, "\n")
end
]==]

local SYSTEM_PROMPT_PROJECT_SRC = [==[
-- Project layer of the system prompt: the NEAREST AGENTS.md and the
-- NEAREST CLAUDE.md found upward from cwd (ecosystem memory-file
-- convention), plus every path in config.instructions_files verbatim.
-- Each file is fenced under a "## <absolute path>" header and capped at
-- 20000 bytes with a truncation note. Unreadable/missing files are
-- skipped silently. Returns "" when nothing is found.
return function()
  local ok_straps, straps = pcall(require, "straps")
  local config = (ok_straps and type(straps) == "table" and rawget(straps, "config")) or {}
  local cwd = vim.fn.getcwd()
  local CAP = 20000

  local paths, seen = {}, {}
  local function add(path)
    if type(path) ~= "string" or path == "" then
      return
    end
    local abs = vim.fn.fnamemodify(path, ":p")
    if not seen[abs] then
      seen[abs] = true
      paths[#paths + 1] = abs
    end
  end

  for _, name in ipairs({ "AGENTS.md", "CLAUDE.md" }) do
    add(vim.fs.find(name, { upward = true, path = cwd, type = "file" })[1])
  end
  local extras = type(config.instructions_files) == "table" and config.instructions_files or {}
  for _, p in ipairs(extras) do
    add(p)
  end

  local sections = {}
  for _, path in ipairs(paths) do
    local f = io.open(path, "r")
    if f then
      local content = f:read(CAP)
      local truncated = f:read(1) ~= nil
      f:close()
      if type(content) == "string" and content ~= "" then
        if truncated then
          content = content .. "\n[straps: truncated]"
        end
        sections[#sections + 1] = "## " .. path .. "\n" .. content
      end
    end
  end
  return table.concat(sections, "\n\n")
end
]==]

local SYSTEM_PROMPT_SKILLS_SRC = [==[
-- Skills layer of the system prompt: one "- name: doc" line per skill.*
-- entry, so the model knows what knowledge is loadable via tool.skill
-- without paying for the bodies up front. Returns "" when no skills exist
-- (the composition skips the section, keeping the default prompt — and its
-- cache prefix — unchanged).
return function()
  local registry = require("straps.registry")
  local lines = {}
  for _, name in ipairs(registry.names("skill")) do
    local e = registry.get(name)
    local doc = tostring(e.doc or ""):match("^[^\n]*") or ""
    lines[#lines + 1] = "- " .. name .. (doc ~= "" and (": " .. doc) or "")
  end
  return table.concat(lines, "\n")
end
]==]

local SYSTEM_PROMPT_SRC = [==[
-- Composes the system prompt for new sessions from four layers, each
-- looked up through the registry AT CALL TIME: fn.system_prompt_core,
-- fn.system_prompt_env (under "# Environment"), fn.system_prompt_skills
-- (under "# Skills") and fn.system_prompt_project (under "# Project
-- instructions"). Redefine any single layer to change the next new
-- session; redefine this entry to replace the composition wholesale.
-- Empty layers are skipped.
return function()
  local registry = require("straps.registry")
  local parts = {}

  local core = registry.call("fn.system_prompt_core")
  if core and core ~= "" then
    parts[#parts + 1] = core
  end

  local env = registry.call("fn.system_prompt_env")
  if env and env ~= "" then
    parts[#parts + 1] = "# Environment\n\n" .. env
  end

  local skills = registry.try_call("fn.system_prompt_skills")
  if skills and skills ~= "" then
    parts[#parts + 1] = "# Skills\n\n"
      .. "Stored knowledge, loadable on demand: call the skill tool with a"
      .. " name below when its description matches the task at hand.\n\n"
      .. skills
  end

  local project = registry.call("fn.system_prompt_project")
  if project and project ~= "" then
    parts[#parts + 1] = "# Project instructions\n\n"
      .. "The following instructions come from the project's memory files;"
      .. " follow them -- they take precedence over the general guidance above.\n\n"
      .. project
  end

  return table.concat(parts, "\n\n")
end
]==]

--- Register the provider-side defaults. Uses define_default so re-running
--- setup() never clobbers a user's (or the agent's) redefinitions.
function M.register()
  local registry = require("straps.registry")
  local define = registry.define_default or registry.define

  define({
    name = "fn.system_prompt_core",
    kind = "fn",
    doc = "Core layer of the system prompt: identity, norms, workflow, self-extension.",
    source = SYSTEM_PROMPT_CORE_SRC,
  })
  define({
    name = "fn.system_prompt_env",
    kind = "fn",
    doc = "Environment layer of the system prompt: cwd, platform, nvim, date, VCS.",
    source = SYSTEM_PROMPT_ENV_SRC,
  })
  define({
    name = "fn.system_prompt_project",
    kind = "fn",
    doc = "Project layer of the system prompt: AGENTS.md/CLAUDE.md + config.instructions_files.",
    source = SYSTEM_PROMPT_PROJECT_SRC,
  })
  define({
    name = "fn.system_prompt_skills",
    kind = "fn",
    doc = "Skills layer of the system prompt: one line per skill.* entry, loadable via tool.skill.",
    source = SYSTEM_PROMPT_SKILLS_SRC,
  })
  define({
    name = "fn.system_prompt",
    kind = "fn",
    doc = "Compose the system prompt for new sessions from the core/env/skills/project layers.",
    source = SYSTEM_PROMPT_SRC,
  })
  define({
    name = "fn.api_key",
    kind = "fn",
    doc = "Return the Anthropic API key (default: $ANTHROPIC_API_KEY, then $XDG_CONFIG_HOME/straps/api_key; the file must be chmod 600).",
    source = API_KEY_SRC,
  })
  define({
    name = "fn.list_models",
    kind = "fn",
    doc = "GET /v1/models and return picker entries { id, label, thinking } (thinking tag inferred from the API's capabilities); (nil, err) on failure.",
    source = LIST_MODELS_SRC,
  })
  define({
    name = "fn.build_tools",
    kind = "fn",
    doc = "Map every tool.* registry entry to an Anthropic API tool definition.",
    source = BUILD_TOOLS_SRC,
  })
  define({
    name = "fn.log",
    kind = "fn",
    doc = "Append a structured single-line JSON event to config.log_file (no-op when unset).",
    source = LOG_SRC,
  })
  define({
    name = "fn.compact",
    kind = "fn",
    doc = "Mechanically compact old tool_use/tool_result block contents. (bufnr, opts?) -> summary.",
    source = COMPACT_SRC,
  })
  define({
    name = "fn.provider",
    kind = "fn",
    doc = "Anthropic Messages API over streaming SSE via curl. (req, ctx) -> { content, stop_reason }.",
    source = PROVIDER_SRC,
  })
end

return M
