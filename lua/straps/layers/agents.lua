-- straps/layers/agents.lua — the AGENTS layer: peer awareness, spawning
-- subagents (spawn/spawn_wait), the agents/models tools, and the run/turn
-- lifecycle hooks. Future prompt-fragment slot: fn.system_prompt_layer.agents.

local M = {}

function M.register_peers()
  local registry = require("straps.registry")
  local define = registry.define_default

  -- ------------------------------------------------------------ fn.peer_agents

  -- The awareness counterpart to fn.check_writer: that fn tells an agent about
  -- a neighbour at the moment they collide, this one tells it they exist at
  -- all. Same-instance only — sessions in another Neovim share nothing but
  -- disk, where the only signal is fn.reconcile_buf's divergence check.
  define({
    name = "fn.peer_agents",
    kind = "fn",
    doc = "Describe every OTHER straps session in this Neovim. Called as"
      .. " (ctx_bufnr) -> list of { bufnr, label, running, parent, relation"
      .. " ('parent'|'child'|'sibling'|'peer'), task, depth, files }, running"
      .. " sessions first then by bufnr. Sessions are found by scanning buffers"
      .. " for b:straps_session, so IDLE ones are included (loop.running_sessions"
      .. " sees only active runs); files are the paths each peer last wrote,"
      .. " read from the b:straps_last_writer stamps fn.mark_seen leaves.",
    source = [==[
return function(ctx_bufnr)
  -- vim.b on an invalid buffer throws; every read here is pcall-wrapped, the
  -- same defensive idiom editor.lua's is_session uses.
  local function bvar(b, name)
    local ok, v = pcall(function() return vim.b[b][name] end)
    if ok then return v end
  end
  local function valid(b)
    return type(b) == "number" and b > 0 and vim.api.nvim_buf_is_valid(b)
  end

  local running = {}
  pcall(function()
    for _, b in ipairs(require("straps.loop").running_sessions()) do
      running[b] = true
    end
  end)

  -- Which files each session most recently wrote, from the write stamps
  -- fn.mark_seen leaves on the FILE buffers. Numbers survive vim.b's msgpack
  -- round trip (fn.check_writer compares stamp.session to a bufnr the same way).
  local wrote = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if valid(b) then
      local stamp = bvar(b, "straps_last_writer")
      if type(stamp) == "table" and type(stamp.session) == "number" then
        local name = vim.api.nvim_buf_get_name(b)
        if name ~= "" then
          local list = wrote[stamp.session] or {}
          list[#list + 1] = vim.fn.fnamemodify(name, ":.")
          wrote[stamp.session] = list
        end
      end
    end
  end

  local my_parent = valid(ctx_bufnr) and bvar(ctx_bufnr, "straps_parent") or nil
  if not valid(my_parent) then my_parent = nil end

  local out = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if b ~= ctx_bufnr and valid(b) and bvar(b, "straps_session") == true then
      local parent = bvar(b, "straps_parent")
      if not valid(parent) then parent = nil end
      local relation = "peer"
      if parent == ctx_bufnr then
        relation = "child"
      elseif b == my_parent then
        relation = "parent"
      elseif parent ~= nil and parent == my_parent then
        relation = "sibling"
      end
      local label = "buffer " .. tostring(b)
      pcall(function() label = require("straps.ui").session_label(b) end)
      local task = bvar(b, "straps_task")
      out[#out + 1] = {
        bufnr = b,
        label = label,
        running = running[b] == true,
        parent = parent,
        relation = relation,
        task = type(task) == "string" and task or nil,
        depth = tonumber(bvar(b, "straps_spawn_depth")) or 0,
        files = wrote[b] or {},
      }
    end
  end
  table.sort(out, function(a, b)
    if a.running ~= b.running then return a.running end
    return a.bufnr < b.bufnr
  end)
  return out
end
]==],
  })
end

function M.register_spawn()
  local registry = require("straps.registry")
  local define = registry.define_default

  -- -------------------------------------------------------------------- spawn

  define({
    name = "tool.spawn",
    kind = "tool",
    doc = "Launch a subagent on a task in its OWN session buffer and return"
      .. " IMMEDIATELY with a handle — the subagent runs concurrently while you"
      .. " keep working. Call spawn N times (batch the calls in one turn) to fan"
      .. " out N subagents that all run in parallel, then collect their answers"
      .. " with spawn_wait. The child is a full straps session: its transcript"
      .. " is a real buffer the user can open, watch and steer (show=true opens"
      .. " it in a split). The child inherits this session's registry view —"
      .. " your session-scoped tools included — but anything IT defines lands"
      .. " in its own scope and never leaks back. Use it to isolate context:"
      .. " the child burns its own transcript on a broad investigation and you"
      .. " receive only its final answer (via spawn_wait). The task must be"
      .. " COMPLETE and self-contained; the child sees none of this"
      .. " conversation. Returns the child's handle (buffer number) to pass to"
      .. " spawn_wait. Parameters: task (required); system (optional) — extra"
      .. " standing instructions, prepended to the task; provider (optional) —"
      .. " child backend, inherited from this session/global default when unset; tools (optional array"
      .. " of tool names) — the child sees only these tools; readonly (optional"
      .. " boolean) — the child may use only auto-allowed read-only tools,"
      .. " every write is denied without prompting (equivalent to allow={});"
      .. " allow (optional array) — grant these permission categories (edit,"
      .. " delete, exec, lua, net, spawn) or specific tool names to the child:"
      .. " granted calls run without prompting, everything else is DENIED"
      .. " (no prompt), readonly and allow are mutually exclusive; show (optional"
      .. " boolean) —"
      .. " open the child's transcript in a split; max_turns (optional,"
      .. " default 24); model (optional) — run the child on this model id"
      .. " instead of the session's; effort (optional) — extended-thinking"
      .. " effort name for the child; timeout_ms (optional, default 600000) —"
      .. " enforced by spawn_wait.",
    input_schema = {
      type = "object",
      properties = {
        task = { type = "string", description = "Complete, self-contained instructions for the subagent." },
        system = { type = "string", description = "Extra standing instructions for the child." },
        provider = { type = "string", enum = { "anthropic", "openai" }, description = "Provider for the child (default: this session's provider/global default)." },
        tools = {
          type = "array",
          items = { type = "string" },
          description = "Restrict the child to these tool names.",
        },
        readonly = { type = "boolean", description = "Read-only child: every write tool is denied." },
        allow = {
          type = "array",
          items = { type = "string" },
          description = "Grant these permission categories (edit, delete, exec, lua, net, spawn) or specific tool names to the child: granted calls run without prompting; everything else is DENIED (no prompt). readonly=true is equivalent to allow={}.",
        },
        show = { type = "boolean", description = "Open the child's transcript buffer in a split." },
        max_turns = { type = "integer", description = "Child turn budget (default 24)." },
        model = { type = "string", description = "Model id for the child (default: this session's model)." },
        effort = { type = "string", description = "Extended-thinking effort name for the child (default: this session's effort)." },
        timeout_ms = { type = "integer", description = "Wall-clock cap in milliseconds (default 600000), enforced by spawn_wait." },
      },
      required = { "task" },
    },
    source = [==[
return function(input, ctx)
  local task = input.task
  if type(task) ~= "string" or task == "" then
    error("spawn: task must be a non-empty string")
  end
  local registry = require("straps.registry")
  local state = require("straps.state")
  local loop = require("straps.loop")

  -- allow: grant permission categories or specific tool names to the child.
  -- readonly is the same mechanism with an empty grant set, so the two are
  -- mutually exclusive. Validate every entry up front: it must be a grantable
  -- category or an existing tool, so "define"/"other" (not grantable) and typos
  -- error here instead of silently granting nothing.
  if input.readonly and type(input.allow) == "table" then
    error("spawn: readonly and allow are mutually exclusive (readonly is allow={})")
  end
  if type(input.allow) == "table" then
    local grantable = registry.try_call("fn.capability") or {}
    local is_grantable = {}
    for _, c in ipairs(grantable) do is_grantable[c] = true end
    for _, entry in ipairs(input.allow) do
      if not (is_grantable[entry] or registry.get("tool." .. tostring(entry)) ~= nil) then
        error("spawn: allow entry " .. vim.inspect(entry)
          .. " is not a grantable category (" .. table.concat(grantable, ", ")
          .. ") or an existing tool")
      end
      -- A tool-name grant of a define-category tool (registry_define) would
      -- let the child shadow its own hook.confirm — an everything grant. The
      -- category ceiling must hold for name grants too.
      if registry.try_call("fn.capability", entry) == "define" then
        error("spawn: allow entry " .. vim.inspect(entry)
          .. " is in the define category, which is never grantable")
      end
    end
  end

  -- Depth guard: subagents do not spawn sub-subagents unless the user
  -- raises config.max_spawn_depth.
  local depth = 0
  pcall(function() depth = vim.b[ctx.bufnr].straps_spawn_depth or 0 end)
  local max_depth = 1
  pcall(function()
    max_depth = require("straps").config.max_spawn_depth or 1
  end)
  if depth >= max_depth then
    return "spawn: refused — subagent depth limit (" .. max_depth
      .. ") reached; do this work yourself"
  end

  -- Compose the child's prompt for its actual shape: no # Subagents section,
  -- a # You are a subagent section, plus readonly / tool-restriction notes.
  local child = state.new_session({
    subagent = true,
    readonly = input.readonly and true or nil,
    tools = (type(input.tools) == "table" and #input.tools > 0) and input.tools or nil,
  })
  vim.b[child].straps_spawn_depth = depth + 1
  vim.b[child].straps_max_turns = math.floor(tonumber(input.max_turns) or 24)
  -- Timeout is stored for spawn_wait to enforce (spawn itself returns at once).
  -- Stamp the start time too, so the deadline measures the child's real
  -- lifetime, not just the time spent inside spawn_wait.
  vim.b[child].straps_spawn_timeout_ms = tonumber(input.timeout_ms) or 600000
  vim.b[child].straps_spawn_started_ms = vim.uv.now()
  -- Provider / model / effort: explicit spawn args win; else inherit the
  -- PARENT's per-buffer overrides if it has them (so a subagent matches its
  -- session by default), else leave unset so fn.provider falls back globally.
  do
    local pp, pm, pom, pe
    pcall(function()
      pp = vim.b[ctx.bufnr].straps_provider
      pm = vim.b[ctx.bufnr].straps_model
      pom = vim.b[ctx.bufnr].straps_openai_model
      pe = vim.b[ctx.bufnr].straps_effort
    end)
    local provider = input.provider or pp
    local model = input.model or ((provider == "openai") and pom or pm)
    local effort = input.effort or pe
    if type(provider) == "string" and provider ~= "" then vim.b[child].straps_provider = provider end
    if type(model) == "string" and model ~= "" then
      if provider == "openai" then vim.b[child].straps_openai_model = model else vim.b[child].straps_model = model end
    end
    if type(effort) == "string" and effort ~= "" then vim.b[child].straps_effort = effort end
  end
  -- Parentage lets ui.pick_agents / the statusline show the spawn tree: who
  -- launched this subagent, and a one-line description of its task.
  vim.b[child].straps_parent = ctx.bufnr
  vim.b[child].straps_task = (task:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")):sub(1, 80)
  -- Chain the child's registry scope under THIS session: it reads our
  -- session-scoped entries; its own defines shadow privately.
  registry.ensure_scope(child, ctx.bufnr)

  if type(input.tools) == "table" and #input.tools > 0 then
    vim.b[child].straps_tool_filter = input.tools
  end
  if input.readonly or type(input.allow) == "table" then
    -- Seed the child's per-buffer grant set from allow (readonly => empty).
    -- vim.b returns copies, so build the whole table then assign once, before
    -- loop.start so the first tool call already sees it.
    local grantable = registry.try_call("fn.capability") or {}
    local is_grantable = {}
    for _, c in ipairs(grantable) do is_grantable[c] = true end
    local grants = {}
    if type(input.allow) == "table" then
      for _, entry in ipairs(input.allow) do
        if is_grantable[entry] then
          grants["cap:" .. entry] = true
        else
          grants[entry] = true -- tool-name grant
        end
      end
    end
    vim.b[child].straps_allowed = grants

    registry.define({
      name = "hook.confirm",
      kind = "hook",
      doc = "spawn: readonly/allow child — auto-allow read-only calls plus the"
        .. " granted categories/tools, deny everything else without a prompt."
        .. " readonly is this with an empty grant set (only reads pass).",
      source = [[
return function(name, tin, tctx)
  local reg = require("straps.registry")
  local cap = reg.try_call("fn.capability", name, tin)
  if cap == "read" then return true end
  local allowed
  pcall(function()
    allowed = tctx and tctx.bufnr and vim.b[tctx.bufnr].straps_allowed or nil
  end)
  if type(allowed) == "table" then
    if cap and allowed["cap:" .. tostring(cap)] then return true end
    if allowed[name] then return true end
  end
  if type(allowed) ~= "table" or next(allowed) == nil then
    return false, "readonly subagent: " .. tostring(name) .. " is not allowed"
  end
  local names = {}
  for k in pairs(allowed) do names[#names + 1] = k end
  table.sort(names)
  return false, "subagent: " .. tostring(name) .. " is not covered by this child's grants ("
    .. table.concat(names, ", ") .. ")"
end
]],
    }, { scope = child })
  end

  local header = task
  if type(input.system) == "string" and input.system ~= "" then
    header = input.system .. "\n\n" .. task
  end
  state.append_text(child, header)

  loop.start(child)
  -- If the parent run is cancelled before the matching spawn_wait, nothing
  -- else would stop this child; register a cancel handler so it is not
  -- orphaned (spawn_wait installs its own for the wait window).
  if ctx and ctx.on_cancel then
    ctx.on_cancel(function()
      pcall(function()
        if vim.api.nvim_buf_is_valid(child) and loop.running(child) then
          loop.stop(child)
        end
      end)
    end)
  end
  if input.show then
    pcall(function()
      local prev = vim.api.nvim_get_current_win()
      vim.cmd("botright vsplit")
      vim.api.nvim_win_set_buf(vim.api.nvim_get_current_win(), child)
      pcall(vim.api.nvim_set_current_win, prev)
    end)
  end

  -- Fire-and-return: the child is now running on its own coroutine. Report its
  -- handle so the parent can launch more (they run concurrently) and later
  -- collect answers with spawn_wait. Cancelling the parent while children are
  -- outstanding is handled by spawn_wait's cancel handler.
  local name = vim.api.nvim_buf_get_name(child)
  local where = name ~= "" and vim.fn.fnamemodify(name, ":~:.") or ("buffer " .. child)
  return ("subagent started — buffer %d, transcript: %s\n"
    .. "collect its answer with spawn_wait{ buffers = { %d } }"):format(child, where, child)
end
]==],
  })

  -- ---------------------------------------------------------------- spawn_wait

  define({
    name = "tool.spawn_wait",
    kind = "tool",
    doc = "Wait for one or more subagents (started with spawn) to finish and"
      .. " return their final answers. Pass the buffer handles spawn returned;"
      .. " all are awaited CONCURRENTLY, so waiting on N children costs the"
      .. " time of the slowest, not the sum. Each child's own timeout_ms (set"
      .. " at spawn) is enforced here; a child that overruns is stopped and"
      .. " reported as timed out. Cancelling the parent run stops every"
      .. " outstanding child. Returns one section per child: its handle, task,"
      .. " status (finished/timed out), and its final answer text."
      .. " Parameters: buffers (required) — array of subagent buffer numbers"
      .. " returned by spawn.",
    input_schema = {
      type = "object",
      properties = {
        buffers = {
          type = "array",
          items = { type = "integer" },
          description = "Subagent buffer numbers returned by spawn.",
        },
      },
      required = { "buffers" },
    },
    source = [==[
return function(input, ctx)
  local state = require("straps.state")
  local loop = require("straps.loop")

  local bufs = input.buffers
  if type(bufs) ~= "table" or #bufs == 0 then
    error("spawn_wait: buffers must be a non-empty array of subagent buffer numbers")
  end
  -- Normalize + validate: only wait on live buffers that this session spawned
  -- (straps_parent == us). Unknown/invalid handles are reported, never awaited.
  local children, bad = {}, {}
  for _, b in ipairs(bufs) do
    local child = math.floor(tonumber(b) or -1)
    local ok_valid = child >= 0 and vim.api.nvim_buf_is_valid(child)
    local parent
    if ok_valid then pcall(function() parent = vim.b[child].straps_parent end) end
    if ok_valid and parent == ctx.bufnr then
      children[#children + 1] = child
    else
      bad[#bad + 1] = child
    end
  end

  -- Await ALL outstanding children in a SINGLE await: one poll loop checks
  -- every child, so the wait costs the slowest child, not the sum. Each child
  -- carries its own deadline (straps_spawn_timeout_ms, stamped by spawn); a
  -- child past its deadline is stopped and marked timed out. Cancelling the
  -- parent stops every child at once.
  local timed_out = {}
  if #children > 0 then
    ctx.await(function(resolve)
      local starts = {}
      for _, c in ipairs(children) do
        -- Deadline is measured from the child's spawn (straps_spawn_started_ms),
        -- so time the parent spent working before calling spawn_wait counts
        -- against the child's timeout. Fall back to now if the stamp is missing.
        local started = vim.uv.now()
        pcall(function() started = vim.b[c].straps_spawn_started_ms or started end)
        starts[c] = started
      end
      local function poll()
        local pending = false
        for _, c in ipairs(children) do
          if loop.running(c) then
            local limit = 600000
            pcall(function() limit = vim.b[c].straps_spawn_timeout_ms or 600000 end)
            if vim.uv.now() - starts[c] >= limit then
              timed_out[c] = true
              pcall(loop.stop, c)
            else
              pending = true
            end
          end
        end
        if pending then vim.defer_fn(poll, 100) else resolve(true) end
      end
      if ctx.on_cancel then
        ctx.on_cancel(function()
          for _, c in ipairs(children) do pcall(loop.stop, c) end
        end)
      end
      poll()
    end)
    -- A stopped child (timed-out/cancelled) needs a beat to unwind its run;
    -- and a just-finished child may have a final streamed text_delta still
    -- scheduled (emit is vim.schedule'd, so it can trail the run-done signal).
    -- One settle tick lets both land before we read the answers.
    ctx.await(function(resolve) vim.defer_fn(resolve, 200) end)
  end

  -- The child's last assistant text IS its report to us.
  local function answer_of(child)
    local answer = ""
    pcall(function()
      local msgs = state.parse(child).messages
      for i = #msgs, 1, -1 do
        if msgs[i].role == "assistant" then
          local parts = {}
          for _, p in ipairs(msgs[i].content) do
            if p.type == "text" then parts[#parts + 1] = p.text end
          end
          if #parts > 0 then answer = table.concat(parts, "\n"); break end
        end
      end
    end)
    return answer
  end

  local out = {}
  for _, child in ipairs(children) do
    local nm = vim.api.nvim_buf_get_name(child)
    local where = nm ~= "" and vim.fn.fnamemodify(nm, ":~:.") or ("buffer " .. child)
    local task = ""
    pcall(function() task = vim.b[child].straps_task or "" end)
    local answer = answer_of(child)
    local status = timed_out[child] and "timed out (stopped)" or "finished"
    out[#out + 1] = ("## subagent (buffer %d) — %s\ntask: %s\ntranscript: %s\n\n%s")
      :format(child, status, task ~= "" and task or "(none)", where,
        answer ~= "" and answer or "(no final answer text)")
  end
  for _, b in ipairs(bad) do
    out[#out + 1] = ("## buffer %d — not a subagent of this session (skipped)"):format(b)
  end
  return table.concat(out, "\n\n")
end
]==],
  })
end

function M.register_tools()
  local registry = require("straps.registry")
  local define = registry.define_default

  -- ------------------------------------------------------------------- agents

  -- Defined LAST among this file's tools: seq order is append-only for
  -- prompt-cache stability (see fn.build_tools), so a new tool goes at the end
  -- of the list rather than into the middle of it.
  define({
    name = "tool.agents",
    kind = "tool",
    doc = "List the other straps agent sessions running in this Neovim — who"
      .. " else is working, whether they are running or idle, how they relate to"
      .. " you (parent/child/sibling), the task they were given, and which files"
      .. " they have written. Call it when a run starts alongside other agents"
      .. " (the multiplayer notice points here), before editing a file a peer may"
      .. " be in, or after an edit tool reports 'modified by another agent'. Peers"
      .. " share this Neovim's buffers, so their unsaved edits are already in the"
      .. " files you read. Agents in a DIFFERENT Neovim are invisible here. Read-only."
      .. " No parameters.",
    input_schema = {
      type = "object",
      properties = vim.empty_dict(),
      required = {},
    },
    source = [==[
return function(input, ctx)
  local registry = require("straps.registry")
  local me = ctx and ctx.bufnr
  local peers = registry.call("fn.peer_agents", me) or {}
  local mine = "buffer " .. tostring(me)
  pcall(function() mine = require("straps.ui").session_label(me) end)
  if #peers == 0 then
    return "you are the only straps agent in this Neovim (this session: "
      .. mine .. "). Note: agents running in a DIFFERENT Neovim instance are"
      .. " invisible here."
  end
  local lines = { ("%d other agent(s) in this Neovim; this session: %s")
    :format(#peers, mine) }
  for _, p in ipairs(peers) do
    local parts = { ("  %s [%s, %s]"):format(p.label, p.relation,
      p.running and "running" or "idle") }
    if p.task then parts[#parts + 1] = "task: " .. p.task end
    if #p.files > 0 then
      local files = p.files
      local shown = table.concat(files, ", ", 1, math.min(#files, 5))
      if #files > 5 then shown = shown .. (", +%d more"):format(#files - 5) end
      parts[#parts + 1] = "wrote: " .. shown
    end
    lines[#lines + 1] = table.concat(parts, "  ·  ")
  end
  lines[#lines + 1] = "Buffers are shared: a peer's unsaved edits are already in"
    .. " what you read, and your edit tools will refuse a file whose latest"
    .. " change is a peer's write. Load skill.multiplayer for the protocol."
  return table.concat(lines, "\n")
end
]==],
  })

  -- ------------------------------------------------------------------ models

  -- The other half of model awareness. fn.model_note tells an agent what
  -- it IS running; without a catalog it still cannot choose a subagent's model,
  -- because a model id has to be produced exactly and a wrong guess 400s the
  -- child's first request. The capability labels in config.models were written
  -- for precisely this comparison and had no reader until now.
  define({
    name = "tool.models",
    kind = "tool",
    doc = "List the models available to this session, so a subagent's model is"
      .. " a choice rather than an inherited default. Returns each model's id"
      .. " (what spawn's `model` argument takes, exactly), its label — which"
      .. " carries the capability/cost hint, e.g. 'most capable, slowest' vs"
      .. " 'fastest, cheapest' — and its context window, plus the effort names"
      .. " spawn's `effort` argument accepts. The session's active model is"
      .. " marked. Call it before fanning out work: mechanical children"
      .. " (searching, collecting, reformatting) belong on a cheap fast model,"
      .. " judgment children on a strong one. Lists the configured and"
      .. " previously discovered catalog for the ACTIVE provider (no network"
      .. " call); :StrapsModel refreshes it from the provider's API."
      .. " Read-only. No parameters.",
    input_schema = {
      type = "object",
      properties = vim.empty_dict(),
    },
    source = [==[
return function(input, ctx)
  local ok_straps, straps = pcall(require, "straps")
  if not ok_straps or type(straps) ~= "table" or type(straps.config) ~= "table" then
    return "straps config not available"
  end
  local cfg = straps.config

  -- Resolve the session's own provider/model the same way fn.provider will, so
  -- the marked entry is the one this session would actually send.
  local info
  pcall(function() info = require("straps.ui").session_info(ctx and ctx.bufnr) end)
  local provider = (info and info.provider)
    or (cfg.provider ~= "" and cfg.provider)
    or require("straps.registry").try_call("fn.provider_pref")
    or "anthropic"
  local current = info and info.model

  local list = cfg[provider == "openai" and "openai_models" or "models"]
  if type(list) ~= "table" or #list == 0 then
    return "no models configured for provider " .. tostring(provider)
      .. " (run :StrapsModel to discover the account's catalog)"
  end

  local lines = { ("models available to this session (provider: %s)"):format(provider) }
  for _, m in ipairs(list) do
    if type(m) == "table" and type(m.id) == "string" then
      local parts = { ("  %s%s"):format(m.id == current and "* " or "  ", m.id) }
      if type(m.label) == "string" and m.label ~= "" and m.label ~= m.id then
        parts[#parts + 1] = m.label
      end
      local ctx_tokens = tonumber(m.context)
      if ctx_tokens then
        parts[#parts + 1] = ("context %dk"):format(math.floor(ctx_tokens / 1000))
      end
      lines[#lines + 1] = table.concat(parts, "  ·  ")
    end
  end
  lines[#lines + 1] = "(* = this session's active model)"

  local efforts = {}
  if type(cfg.efforts) == "table" then
    for _, e in ipairs(cfg.efforts) do
      if type(e) == "table" and type(e.name) == "string" then efforts[#efforts + 1] = e.name end
    end
  end
  if #efforts > 0 then
    lines[#lines + 1] = "effort names: " .. table.concat(efforts, ", ")
      .. ((info and info.effort) and ("  (this session: " .. info.effort .. ")") or "")
  end
  lines[#lines + 1] = "Pass an id verbatim as spawn's `model`, and an effort name as"
    .. " `effort`; omitting them copies this session's."
  return table.concat(lines, "\n")
end
]==],
  })
end

function M.register_hooks()
  local registry = require("straps.registry")
  local define = registry.define_default

  -- ------------------------------------------------------- hook.on_run_start

  define({
    name = "hook.on_run_start",
    kind = "hook",
    doc = "Called as (ctx) when an agent run starts, before the first provider"
      .. " call. Default behavior: when OTHER sessions in this Neovim have"
      .. " active runs, append one user block telling the agent it is not alone"
      .. " (it can then call the agents tool and load skill.multiplayer)."
      .. " Silent when no peer is running, when the same peer set was already"
      .. " announced to this session, and when the transcript has nothing else"
      .. " to send — so a solo session gets no multiplayer notice at all."
      .. " Redefine for setup, notifications, or per-run state.",
    source = [==[
return function(ctx)
  local bufnr = ctx and ctx.bufnr
  if type(bufnr) ~= "number" or not vim.api.nvim_buf_is_valid(bufnr) then return end
  local registry = require("straps.registry")
  local state = require("straps.state")

  local peers = registry.try_call("fn.peer_agents", bufnr) or {}
  local live = {}
  for _, p in ipairs(peers) do
    if p.running then live[#live + 1] = p end
  end
  if #live == 0 then return end

  -- Announce a peer SET once, not once per run: a long session working
  -- alongside the same neighbour would otherwise accumulate an identical note
  -- in its persisted transcript every turn-loop start, and replay all of them.
  local sig = {}
  for _, p in ipairs(live) do sig[#sig + 1] = p.bufnr .. ":" .. p.relation end
  sig = table.concat(sig, ",")
  local ok_seen, seen = pcall(function() return vim.b[bufnr].straps_peers_noted end)
  if ok_seen and seen == sig then return end

  -- The note must never be the ONLY thing in the request: on a transcript with
  -- no other messages it would defeat the loop's "nothing to send" guard and
  -- spend a real API call announcing the neighbours to no purpose.
  local ok_parsed, parsed = pcall(state.parse, bufnr)
  if not ok_parsed or not parsed or #parsed.messages == 0 then return end

  local who = {}
  for _, p in ipairs(live) do
    who[#who + 1] = p.label .. " (" .. p.relation
      .. (p.task and (", " .. p.task) or "") .. ")"
  end
  pcall(state.append, bufnr, "user", nil,
    ("[straps] Multiplayer: %d other agent(s) working in this Neovim right now — %s."
      .. " You share their buffers. Call the agents tool for what they have"
      .. " touched, and load skill.multiplayer before editing anything they"
      .. " might be in."):format(#live, table.concat(who, ", ")))
  pcall(function() vim.b[bufnr].straps_peers_noted = sig end)
end
]==],
  })

  -- ------------------------------------------------------ hook.on_turn_start

  define({
    name = "hook.on_turn_start",
    kind = "hook",
    doc = "Called as (ctx, turn) at the top of every turn, after steering"
      .. " drains and before the transcript is parsed for the next request —"
      .. " so a block it appends belongs to that turn's request. No-op by"
      .. " default; redefine for per-turn budget checks or telemetry.",
    source = [==[
return function(ctx, turn)
  -- no-op by default
end
]==],
  })

  -- ---------------------------------------------------------- fn.model_note

  -- Model self-awareness. The winbar has always shown the user which model a
  -- session runs on; the agent itself had no way to know. It cannot live in
  -- the session's stored system prompt: that block is composed ONCE at
  -- session creation (state.new_session), so :StrapsModel / :StrapsEffort
  -- mid-session would make it a lie — and tool.spawn composes a child's
  -- prompt BEFORE stamping the child's model, so a static line would name the
  -- wrong model for every subagent. And it must never ride in the transcript:
  -- parse merges same-role messages, so a user-role notice concatenates with
  -- the user's own words — harness text wearing the user's voice. Hence a
  -- per-REQUEST system-text suffix: the loop calls this each turn and appends
  -- the result to the parsed system before fn.provider, touching no buffer.
  define({
    name = "fn.model_note",
    kind = "fn",
    doc = "Called as (ctx) each turn by the loop; returns a '# Model' section"
      .. " appended to that request's system text, naming the session's"
      .. " effective provider/model/effort (resolved through ui.session_info,"
      .. " the same vim.b-override -> config chain fn.provider uses) plus the"
      .. " standing note that subagents inherit them unless spawn is passed"
      .. " explicit arguments. nil for a non-session buffer. Redefine to"
      .. " reshape or silence it.",
    source = [==[
return function(ctx)
  local bufnr = ctx and ctx.bufnr
  if type(bufnr) ~= "number" or not vim.api.nvim_buf_is_valid(bufnr) then return end
  -- ui.session_info resolves the vim.b-override -> global-config chain for
  -- provider/model/effort (the same chain fn.provider uses to build the
  -- request), and returns nil for a non-session buffer.
  local ok, info = pcall(function() return require("straps.ui").session_info(bufnr) end)
  if not ok or type(info) ~= "table" then return end
  local shown = info.model_label ~= info.model
    and ("%s (%s)"):format(info.model_label, info.model) or info.model
  -- Carried here, not only in the prompt's # Subagents section: that section
  -- is dropped for subagents, so a nested spawner would never read it.
  return ("# Model\n\nThis session is running on %s · provider %s · effort %s."
    .. " Subagents inherit this model and effort unless you pass spawn an"
    .. " explicit model / effort — call the models tool for the ids you can"
    .. " pass, and match the child's capability to its task rather than"
    .. " defaulting to your own."):format(shown, info.provider, info.effort)
end
]==],
  })

  -- --------------------------------------------------------- hook.on_run_end

  define({
    name = "hook.on_run_end",
    kind = "hook",
    doc = "Called as (ctx) when an agent run ends (normally, on error, or after"
      .. " cancellation). No-op by default; redefine for teardown or"
      .. " notifications.",
    source = [==[
return function(ctx)
  -- no-op by default
end
]==],
  })

  -- ---------------------------------------------------------- autocmd bridge

  define({
    name = "fn.autocmd_bridge",
    kind = "fn",
    doc = "Bridge Neovim autocmd events back into a session — the 'editor"
      .. " talks to the agent' seam. Call as (spec) with spec = { event ="
      .. " 'BufWritePost' (or a list), pattern = optional autocmd pattern,"
      .. " entry = 'hook.NAME' (a registry entry called with the autocmd args"
      .. " table), bufnr = session buffer number }. Whenever the event fires,"
      .. " the entry runs; if it returns a non-empty string, that string is"
      .. " queued onto the session as a user message: steering if a run is"
      .. " active, an ordinary user block otherwise. Returns the autocmd id"
      .. " (remove with vim.api.nvim_del_autocmd). Example: bridge"
      .. " DiagnosticChanged to a hook that reports new errors, and the agent"
      .. " hears about breakage as the user saves.",
    source = [==[
return function(spec)
  assert(type(spec) == "table", "autocmd_bridge: spec table required")
  assert(spec.event, "autocmd_bridge: spec.event is required")
  assert(type(spec.entry) == "string", "autocmd_bridge: spec.entry (registry entry name) is required")
  local session = spec.bufnr
  assert(type(session) == "number", "autocmd_bridge: spec.bufnr (session buffer) is required")
  return vim.api.nvim_create_autocmd(spec.event, {
    group = vim.api.nvim_create_augroup("straps_bridge_" .. session, { clear = false }),
    pattern = spec.pattern,
    callback = function(args)
      local ok, s = pcall(function()
        local registry = require("straps.registry")
        local prev = registry.set_active_scope(session)
        local ok_call, out = pcall(registry.try_call, spec.entry, args)
        registry.set_active_scope(prev)
        if not ok_call then error(out) end
        return out
      end)
      if ok and type(s) == "string" and s ~= "" then
        vim.schedule(function()
          if not vim.api.nvim_buf_is_valid(session) then return end
          local loop = require("straps.loop")
          if loop.running(session) then
            loop.steer(session, s)
          else
            pcall(require("straps.state").append, session, "user", nil, s)
          end
        end)
      end
    end,
  })
end
]==],
  })
end

return M
