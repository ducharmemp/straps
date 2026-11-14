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
      .. " spawn_wait. You do NOT have to block: when a child finishes while you"
      .. " keep working, a [straps] notice naming its buffer arrives in this"
      .. " conversation, and you collect it with spawn_wait then (it returns at"
      .. " once for a finished child). Parameters: task (required); system (optional) — extra"
      .. " standing instructions, prepended to the task; provider (optional) —"
      .. " child backend, inherited from this session/global default when unset; tools (optional array"
      .. " of tool names) — the child sees only these tools (an unknown name is an error); readonly (optional"
      .. " boolean) — the child may use only auto-allowed read-only tools,"
      .. " every write is denied without prompting (equivalent to allow={});"
      .. " allow (optional array) — grant these permission categories (edit,"
      .. " delete, exec, lua, net, spawn) or specific tool names to the child:"
      .. " granted calls run without prompting, everything else is DENIED"
      .. " (no prompt); a tool-name grant covers the tool's current definition, so"
      .. " a child that shadows that tool, or any redefinition of it, is denied under it;"
      .. " readonly and allow are mutually exclusive — a session"
      .. " that is itself readonly/allow-gated can grant only a subset of its"
      .. " own grants, and its children default to readonly; nesting depth is"
      .. " capped by config.max_spawn_depth; show (optional boolean) —"
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
        provider = { type = "string", enum = require("straps.provider").provider_names(), description = "Provider for the child (default: this session's provider/global default)." },
        tools = {
          type = "array",
          items = { type = "string" },
          description = "Restrict the child to these tool names (each must be a registered tool).",
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
    error("spawn: task must be a non-empty string", 0)
  end
  local registry = require("straps.registry")
  local state = require("straps.state")
  local loop = require("straps.loop")

  -- allow: grant permission categories or specific tool names to the child.
  -- readonly is the same mechanism with an empty grant set, so the two are
  -- mutually exclusive. Validate every entry up front: it must be a grantable
  -- category or an existing tool, so "define"/"agent_tool" (not grantable) and typos
  -- error here instead of silently granting nothing.
  if input.readonly and type(input.allow) == "table" then
    error("spawn: readonly and allow are mutually exclusive (readonly is allow={})", 0)
  end
  if input.allow ~= nil and type(input.allow) ~= "table" then
    error("spawn: allow must be an array of categories or tool names", 0)
  end
  local providers = require("straps.provider")
  if type(input.provider) == "string" and input.provider ~= "" and not providers.is_provider(input.provider) then
    error("spawn: " .. providers.unknown_provider_error(input.provider), 0)
  end
  -- A gated spawner (itself a readonly/allow child, marked by the spawn:gated
  -- grant) is a permission ceiling for its own children: it may delegate only
  -- what it holds, and a child it spawns without allow/readonly is read-only.
  -- A grant set with no marker is an ungated session whose gate is the user's
  -- confirm dialog (or :StrapsAuto), so no ceiling applies there.
  local parent_grants = registry.granted(ctx.bufnr)
  local gated = parent_grants["spawn:gated"] == true
  local forced_readonly = false
  if gated and not input.readonly and input.allow == nil then
    input.readonly = true
    forced_readonly = true
  end
  if input.tools ~= nil then
    if type(input.tools) ~= "table" then
      error("spawn: tools must be an array of tool names", 0)
    end
    local unknown = {}
    for _, t in ipairs(input.tools) do
      if type(t) ~= "string" or registry.get("tool." .. t) == nil then
        unknown[#unknown + 1] = vim.inspect(t)
      end
    end
    if #unknown > 0 then
      error("spawn: unknown tool name(s) in tools: " .. table.concat(unknown, ", "), 0)
    end
  end
  if type(input.allow) == "table" then
    local grantable = registry.try_call("fn.capability") or {}
    local is_grantable = {}
    for _, c in ipairs(grantable) do is_grantable[c] = true end
    for _, entry in ipairs(input.allow) do
      if not (is_grantable[entry] or registry.get("tool." .. tostring(entry)) ~= nil) then
        error("spawn: allow entry " .. vim.inspect(entry)
          .. " is not a grantable category (" .. table.concat(grantable, ", ")
          .. ") or an existing tool", 0)
      end
      -- A tool-name grant of a define-category tool (registry_define) would
      -- let the child shadow its own hook.confirm — an everything grant. The
      -- category ceiling must hold for name grants too.
      if registry.try_call("fn.capability", entry) == "define" then
        error("spawn: allow entry " .. vim.inspect(entry)
          .. " is in the define category, which is never grantable", 0)
      end
      if gated then
        local within
        if is_grantable[entry] then
          within = parent_grants["cap:" .. entry] == true
        else
          -- Classify by the tool's worst-case input: code_action/fix_diagnostic
          -- read without an index and edit with one, and a name grant covers
          -- every input.
          local cap = registry.try_call("fn.capability", entry)
          if cap == "read" then cap = registry.try_call("fn.capability", entry, { index = 1 }) end
          within = cap == "read" or parent_grants[registry.tool_grant_key(entry)] == true
            or (type(cap) == "string" and parent_grants["cap:" .. cap] == true)
        end
        if not within then
          local held = {}
          for k in pairs(parent_grants) do
            if k ~= "spawn:gated" then held[#held + 1] = k end
          end
          table.sort(held)
          error("spawn: allow entry " .. vim.inspect(entry)
            .. " exceeds this session's own grants (" .. table.concat(held, ", ") .. ")", 0)
        end
      end
    end
  end

  -- Depth guard: subagents nest only as deep as config.max_spawn_depth
  -- (clamped by fn.spawn_depth_limit) allows.
  local depth = 0
  pcall(function() depth = vim.b[ctx.bufnr].straps_spawn_depth or 0 end)
  local max_depth = registry.try_call("fn.spawn_depth_limit") or 1
  if depth >= max_depth then
    return "spawn: refused — subagent depth limit (" .. max_depth
      .. ") reached; do this work yourself"
  end

  -- Compose the child's prompt for its actual shape: a # You are a subagent
  -- section plus readonly / tool-restriction notes; # Subagents stays only
  -- when the child has depth budget left AND its own gate would let a spawn
  -- call through (a gated child needs the spawn category or tool name).
  local child_gated = input.readonly or type(input.allow) == "table"
  local child_may_spawn = not child_gated
  if child_gated and type(input.allow) == "table" then
    for _, e in ipairs(input.allow) do
      if e == "spawn" then child_may_spawn = true end
    end
  end
  local child = state.new_session({
    subagent = true,
    can_spawn = (depth + 1 < max_depth and child_may_spawn) or nil,
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
  do
    local pe
    pcall(function()
      pe = vim.b[ctx.bufnr].straps_effort
    end)
    local function present(v) return type(v) == "string" and v ~= "" end
    local ok_straps, straps = pcall(require, "straps")
    local config = (ok_straps and type(straps) == "table" and rawget(straps, "config")) or {}
    local provider = (present(input.provider) and input.provider)
      or providers.resolve_provider(ctx.bufnr, config)
    local slot = providers.provider_slot(provider)
    local model = input.model
    if not present(model) then
      pcall(function() model = vim.b[ctx.bufnr][slot.buf_model_var] end)
    end
    local effort = input.effort or pe
    vim.b[child].straps_provider = provider
    if present(model) then
      vim.b[child][slot.buf_model_var] = model
    end
    if type(effort) == "string" and effort ~= "" then vim.b[child].straps_effort = effort end
  end
  -- Parentage lets ui.pick_agents / the statusline show the spawn tree: who
  -- launched this subagent, and a one-line description of its task.
  vim.b[child].straps_parent = ctx.bufnr
  vim.b[child].straps_task = require("straps.state").utf8_cut(
    (task:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")), 80)
  -- Chain the child's registry scope under THIS session: it reads our
  -- session-scoped entries; its own defines shadow privately.
  registry.ensure_scope(child, ctx.bufnr)

  if type(input.tools) == "table" and #input.tools > 0 then
    vim.b[child].straps_tool_filter = input.tools
  end
  if input.readonly or type(input.allow) == "table" then
    -- Seed the child's grant set from allow (readonly => empty), before
    -- loop.start so the first tool call already sees it. Grants live in the
    -- registry, keyed by the CHILD buffer — granting another session is
    -- permitted; only self-grants from a tool body are refused.
    local grantable = registry.try_call("fn.capability") or {}
    local is_grantable = {}
    for _, c in ipairs(grantable) do is_grantable[c] = true end
    if type(input.allow) == "table" then
      for _, entry in ipairs(input.allow) do
        if is_grantable[entry] then
          registry.grant(child, "cap:" .. entry)
        else
          registry.grant(child, registry.tool_grant_key(entry))
        end
      end
    end
    -- The marker makes the child a ceiling for ITS children (see above). It
    -- lives in the registry, where allow validation refuses it as an entry
    -- and a tool body cannot grant its own session, so a child cannot forge
    -- or shed it through spawn.
    registry.grant(child, "spawn:gated")
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
    allowed = tctx and tctx.bufnr and reg.granted(tctx.bufnr) or nil
  end)
  if type(allowed) == "table" then
    if cap and allowed["cap:" .. tostring(cap)] then return true end
    if allowed[reg.tool_grant_key(name)] then return true end
  end
  -- A gated child can always report to (and watch) its parent: the parent-only
  -- shape is the one message a research child must be able to send, and the tool body
  -- confines a gated sender to its own family on every other target.
  if (name == "send_message" or name == "watch_agent" or name == "unwatch_agent")
    and type(tin) == "table" and tin.to == "parent" then
    return true
  end
  local names = {}
  if type(allowed) == "table" then
    for k in pairs(allowed) do
      if k ~= "spawn:gated" then names[#names + 1] = k end
    end
  end
  if #names == 0 then
    return false, "readonly subagent: " .. tostring(name) .. " is not allowed"
  end
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

  loop.start(child, { source = "agent" })
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
  local out = ("subagent started — buffer %d, transcript: %s\n"
    .. "collect its answer with spawn_wait{ buffers = { %d } }"):format(child, where, child)
  if forced_readonly then
    out = out .. "\nthis session is permission-gated, so the child was made read-only;"
      .. " pass allow={...} within your own grants to delegate writes"
  end
  return out
end
]==],
  })

  -- ------------------------------------------------------ fn.spawn_depth_limit

  define({
    name = "fn.spawn_depth_limit",
    kind = "fn",
    doc = "The effective subagent nesting limit: config.max_spawn_depth clamped"
      .. " to [0, 6] (depth D means D+1 chained scopes; 6 keeps one hop of"
      .. " headroom under the registry's 8-hop scope-chain walk). tool.spawn"
      .. " refuses at this depth and"
      .. " fn.build_tools hides spawn/spawn_wait there, so the two agree."
      .. " 0 hides spawn everywhere. Redefine to compute the limit some other way.",
    source = [==[
return function()
  local raw
  pcall(function() raw = require("straps").config.max_spawn_depth end)
  local n = math.floor(tonumber(raw) or 1)
  return math.max(0, math.min(n, 6))
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
      .. " status (finished/timed out), and its final answer text. Collecting a"
      .. " child here is what silences its completion notice, so a child that"
      .. " already finished is reported once, not twice. A message arriving for"
      .. " this session (from the user, a peer, a child, or the harness) ends the"
      .. " wait early: children still running are listed as 'still running' and"
      .. " the message follows the result; call spawn_wait again to keep waiting."
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
    error("spawn_wait: buffers must be a non-empty array of subagent buffer numbers", 0)
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

  -- Claim each VALIDATED child, and drop any completion notice already queued
  -- for it. Both happen here, in one synchronous segment before the first
  -- await, so no child can finish in between.
  --
  -- The claim is what silences hook.on_run_end.notify_parent: while it holds,
  -- THIS tool's result is how the child gets reported. It holds for the wait
  -- only: the result (below) releases every claim, so a child reported still
  -- running sends its notice when it finishes, and a finished child's later
  -- runs notify again. A parent cancelled mid-wait never reaches the release,
  -- and the cancelled child's run end is silent anyway.
  --
  -- Only `children` are claimed, never `bad`: a handle belonging to another
  -- session is somebody else's child, and claiming it would silence a SIBLING
  -- session's notice.
  --
  -- The filter covers the ordinary fan-out shape — spawn N, do other work, then
  -- one spawn_wait — where a child that finished during "other work" already
  -- queued a notice that this result is about to make redundant. A notice that
  -- already drained into the transcript is out of reach; fn.spawn_notice's text
  -- tells the agent to ignore a notice it has already collected.
  for _, c in ipairs(children) do
    pcall(function() vim.b[c].straps_spawn_claimed = true end)
  end
  pcall(function()
    local queue = vim.b[ctx.bufnr].straps_steering
    if type(queue) ~= "table" or #queue == 0 then return end
    local prefixes = {}
    for _, c in ipairs(children) do
      prefixes[#prefixes + 1] = ("[straps] subagent buffer %d: "):format(c)
    end
    local kept = {}
    for _, entry in ipairs(queue) do
      local s, source = loop.steering_entry(entry)
      local drop = false
      if source == "harness" then
        for _, pre in ipairs(prefixes) do
          -- Plain prefix compare: the notice text contains [ and ], so a pattern
          -- match would silently find nothing. The trailing ": " in the prefix is
          -- what keeps child 1 from matching child 12.
          if s:sub(1, #pre) == pre then
            drop = true
            break
          end
        end
      end
      if not drop then kept[#kept + 1] = entry end
    end
    if #kept ~= #queue then vim.b[ctx.bufnr].straps_steering = kept end
  end)

  -- Await ALL outstanding children in a SINGLE await: one poll loop checks
  -- every child, so the wait costs the slowest child, not the sum. Each child
  -- carries its own deadline (straps_spawn_timeout_ms, stamped by spawn); a
  -- child past its deadline is stopped and marked timed out. Cancelling the
  -- parent stops every child at once.
  local timed_out = {}
  local woken = false
  local function steering_queued()
    local queue
    pcall(function() queue = vim.b[ctx.bufnr].straps_steering end)
    return type(queue) == "table" and #queue > 0
  end
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
        if not pending then
          resolve(true)
        elseif steering_queued() then
          woken = true
          resolve(true)
        else
          vim.defer_fn(poll, 100)
        end
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

  -- Every claim is released here: a finished child's run end already passed
  -- hook.on_run_end, and a later run of it (a user restart, a watch wake)
  -- notifies again. From the settle tick to the return there is no await, so a
  -- child judged still running here cannot reach hook.on_run_end before its
  -- claim is released: its completion notice is pushed when it finishes.
  local out, still = {}, {}
  for _, child in ipairs(children) do
    -- A child buffer wiped during the wait makes nvim_buf_get_name raise,
    -- which would abort the whole call and lose the answers of its live
    -- siblings in this same batch.
    local nm = ""
    pcall(function() nm = vim.api.nvim_buf_get_name(child) end)
    local where = nm ~= "" and vim.fn.fnamemodify(nm, ":~:.") or ("buffer " .. child)
    local task = ""
    pcall(function() task = vim.b[child].straps_task or "" end)
    pcall(function() vim.b[child].straps_spawn_claimed = nil end)
    if not timed_out[child] and woken and loop.running(child) then
      still[#still + 1] = child
      out[#out + 1] = ("## subagent (buffer %d) — still running\ntask: %s\ntranscript: %s")
        :format(child, task ~= "" and task or "(none)", where)
    else
      local answer = answer_of(child)
      local status = timed_out[child] and "timed out (stopped)" or "finished"
      out[#out + 1] = ("## subagent (buffer %d) — %s\ntask: %s\ntranscript: %s\n\n%s")
        :format(child, status, task ~= "" and task or "(none)", where,
          answer ~= "" and answer or "(no final answer text)")
    end
  end
  for _, b in ipairs(bad) do
    out[#out + 1] = ("## buffer %d — not a subagent of this session (skipped)"):format(b)
  end
  if #still > 0 then
    local list = {}
    for _, c in ipairs(still) do list[#list + 1] = tostring(c) end
    table.insert(out, 1, ("spawn_wait returned early: a message arrived for this session and follows"
      .. " this result. Still running: buffer(s) %s. Call spawn_wait{ buffers = { %s } } again to keep"
      .. " waiting, or keep working; each still-running child sends a completion notice when it ends.")
      :format(table.concat(list, ", "), table.concat(list, ", ")))
    if ctx.forget_call then pcall(ctx.forget_call, "spawn_wait", input) end
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
  local provider = (info and info.provider) or require("straps.provider").resolve_provider(nil, cfg)
  local current = info and info.model

  local providers = require("straps.provider")
  if info and info.error then return "straps: " .. info.error end
  if not providers.is_provider(provider) then
    return providers.unknown_provider_error(provider) .. "; run :StrapsProvider"
  end
  local list = cfg[providers.provider_slot(provider).models_key]
  if type(list) ~= "table" or #list == 0 then
    return "no models configured for provider " .. tostring(provider)
      .. " (run :StrapsModel to discover the provider's catalog)"
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

  -- ------------------------------------------------------------ send_message

  -- Framed by state.agent_message rather than sent bare: the recipient's
  -- transcript can then render the block as `agent N` instead of `you`, and
  -- its prompt can rank it as a peer's claim. Delivery goes through
  -- fn.session_notify so the never-start-the-recipient rule lives in one place.
  define({
    name = "tool.send_message",
    kind = "tool",
    doc = "Send a message to another straps agent session in this Neovim:"
      .. " your parent, a subagent you spawned, or a peer. It arrives in the"
      .. " recipient's transcript as a user-role block framed `[straps] from"
      .. " agent <label> (buffer N): ...` (your session label and buffer"
      .. " number), rendered as `agent N`, so it is never mistaken for the"
      .. " user. A running recipient reads it at its next turn boundary"
      .. " (steering), and one blocked in spawn_wait is woken to read it; an"
      .. " idle one finds it appended, and its run is NOT started. In an ungated session this call prompts for confirmation"
      .. " unless the spawn category is granted. Use it for a"
      .. " note that cannot wait for a final answer: a child reporting a"
      .. " blocker or a collision to its parent, a parent redirecting a running"
      .. " child, a peer asked to stay out of a file. Write it as an"
      .. " instruction or a fact the recipient can act on; the frame already"
      .. " says who it is from. On an idle session the block lands after"
      .. " whatever the user has half-typed in the trailing prompt. Parameters:"
      .. " to (required) — the recipient's buffer number as digits, or the"
      .. " word \"parent\"; text (required) — the message, at most 4000 bytes."
      .. " A readonly/allow-gated session may message only its parent (or its"
      .. " own children when granted); messaging to=\"parent\" is always"
      .. " allowed for a gated child.",
    input_schema = {
      type = "object",
      properties = {
        to = {
          type = "string",
          description = "Recipient: a session buffer number as digits (e.g. \"42\"), or \"parent\".",
        },
        text = {
          type = "string",
          description = "The message (at most 4000 bytes).",
        },
      },
      required = { "to", "text" },
    },
    source = [==[
return function(input, ctx)
  local registry = require("straps.registry")
  local me = ctx and ctx.bufnr
  if type(me) ~= "number" or not vim.api.nvim_buf_is_valid(me) then
    error("send_message: no session buffer in context", 0)
  end
  local function bvar(b, name)
    local ok, v = pcall(function() return vim.b[b][name] end)
    if ok then return v end
  end
  local function is_session(b)
    return type(b) == "number" and b > 0 and vim.api.nvim_buf_is_valid(b)
      and bvar(b, "straps_session") == true
  end

  local text = input.text
  if type(text) ~= "string" or not text:match("%S") then
    error("send_message: text must be a non-empty string", 0)
  end
  if #text > 4000 then
    error(("send_message: text is %d bytes; the cap is 4000 — a message is a note,"
      .. " not a report (put a long one in a file and send its path)"):format(#text), 0)
  end

  local my_parent = bvar(me, "straps_parent")
  local to = input.to
  local target
  if to == "parent" then
    if not is_session(my_parent) then
      error("send_message: this session has no parent", 0)
    end
    target = my_parent
  else
    if type(to) ~= "string" or not to:match("^%d+$") then
      error("send_message: to must be a buffer number as digits, or \"parent\"", 0)
    end
    target = tonumber(to)
    if not is_session(target) then
      error(("send_message: buffer %s is not a straps session in this Neovim"):format(tostring(to)), 0)
    end
  end
  if target == me then
    error("send_message: that is this session", 0)
  end

  -- A gated session (readonly/allow child) stays inside its own family: its
  -- confirm hook let the call through on a name grant or the to="parent"
  -- exception, and neither should reach an unrelated session.
  local gated = false
  pcall(function() gated = registry.granted(me)["spawn:gated"] == true end)
  if gated and target ~= my_parent and bvar(target, "straps_parent") ~= me then
    error("send_message: a permission-gated session may message only its parent or its own children", 0)
  end

  local label = "buffer " .. tostring(me)
  pcall(function() label = require("straps.ui").session_label(me) end)
  local msg = require("straps.state").agent_message(label, me, text)
  local how = registry.try_call("fn.session_notify", target, msg, { quiet = true, source = "agent" })
  local target_label = "buffer " .. tostring(target)
  pcall(function() target_label = require("straps.ui").session_label(target) end)
  if how == "steer" then
    return ("queued as steering for %s (buffer %d); it reads it at its next turn boundary")
      :format(target_label, target)
  elseif how == "append" then
    return ("appended to %s (buffer %d); it is idle and its run was not started")
      :format(target_label, target)
  end
  error("send_message: delivery failed (the recipient buffer vanished)", 0)
end
]==],
  })

  -- ------------------------------------------------------------- watch_agent

  define({
    name = "tool.watch_agent",
    kind = "tool",
    doc = "Subscribe to another straps agent session's lifecycle, so you hear"
      .. " when it starts a run, ends a run, or its buffer closes. When a"
      .. " watched event fires, a `[straps] watched agent <label> (buffer N):"
      .. " <event>` notice arrives in this session: as steering if you are"
      .. " running (a spawn_wait in progress returns early to let it through),"
      .. " and, when you are idle and wake is true, it STARTS your run so you"
      .. " can act on it. A watch fires once and is then removed; call"
      .. " watch_agent again to keep watching. A stopped run (by the user, its"
      .. " parent's stop, or a spawn_wait timeout) never notifies, and the watch"
      .. " stays armed. Wakes are capped per session by"
      .. " config.watch_wake_limit until the user sends to it, and none happen"
      .. " after the user stops this session or while the user has unsent text"
      .. " in its prompt; the notice is then appended without starting a run."
      .. " Parameters: to (required) — the session's buffer number as digits,"
      .. " or \"parent\"; events (optional) — any of run_start, run_end, closed"
      .. " (default run_end and closed); wake (optional, default true). A"
      .. " readonly/allow-gated session may watch only its parent or its own"
      .. " children.",
    input_schema = {
      type = "object",
      properties = {
        to = { type = "string", description = "Session to watch: a buffer number as digits, or \"parent\"." },
        events = {
          type = "array",
          items = { type = "string", enum = { "run_start", "run_end", "closed" } },
          description = "Events to watch (default run_end and closed).",
        },
        wake = { type = "boolean", description = "Start this session's run when idle (default true)." },
      },
      required = { "to" },
    },
    source = [==[
return function(input, ctx)
  local registry = require("straps.registry")
  local me = ctx and ctx.bufnr
  if type(me) ~= "number" or not vim.api.nvim_buf_is_valid(me) then
    error("watch_agent: no session buffer in context", 0)
  end
  local function bvar(b, name)
    local ok, v = pcall(function() return vim.b[b][name] end)
    if ok then return v end
  end
  local function is_session(b)
    return type(b) == "number" and b > 0 and vim.api.nvim_buf_is_valid(b)
      and bvar(b, "straps_session") == true
  end
  local my_parent = bvar(me, "straps_parent")
  local to, target = input.to, nil
  if to == "parent" then
    if not is_session(my_parent) then error("watch_agent: this session has no parent", 0) end
    target = my_parent
  else
    if type(to) ~= "string" or not to:match("^%d+$") then
      error("watch_agent: to must be a buffer number as digits, or \"parent\"", 0)
    end
    target = tonumber(to)
    if not is_session(target) then
      error(("watch_agent: buffer %s is not a straps session in this Neovim"):format(to), 0)
    end
  end
  if target == me then error("watch_agent: that is this session", 0) end
  local gated = false
  pcall(function() gated = registry.granted(me)["spawn:gated"] == true end)
  if gated and target ~= my_parent and bvar(target, "straps_parent") ~= me then
    error("watch_agent: a permission-gated session may watch only its parent or its own children", 0)
  end

  local known = { run_start = true, run_end = true, closed = true }
  local events = input.events
  if events == nil then
    events = { "run_end", "closed" }
  elseif type(events) ~= "table" or #events == 0 then
    error("watch_agent: events must be a non-empty array of run_start, run_end, closed", 0)
  end
  local seen, list = {}, {}
  for _, e in ipairs(events) do
    if not known[e] then
      error(("watch_agent: unknown event %q (run_start, run_end, closed)"):format(tostring(e)), 0)
    end
    if not seen[e] then seen[e] = true; list[#list + 1] = e end
  end
  local wake = input.wake ~= false

  local watchers = bvar(target, "straps_watchers")
  if type(watchers) ~= "table" then watchers = {} end
  watchers[tostring(me)] = { events = list, wake = wake }
  vim.b[target].straps_watchers = watchers

  local label = "buffer " .. tostring(target)
  pcall(function() label = require("straps.ui").session_label(target) end)
  return ("watching %s (buffer %d) for %s; fires once, then call watch_agent again to keep watching; %s")
    :format(label, target, table.concat(list, ", "),
      wake and "an event starts this session's run if it is idle" or "an event never starts this session's run")
end
]==],
  })

  -- ----------------------------------------------------------- unwatch_agent

  define({
    name = "tool.unwatch_agent",
    kind = "tool",
    doc = "Remove this session's watch_agent subscription on another session."
      .. " Parameters: to (required) — the watched session's buffer number as"
      .. " digits, or \"parent\".",
    input_schema = {
      type = "object",
      properties = {
        to = { type = "string", description = "Watched session: a buffer number as digits, or \"parent\"." },
      },
      required = { "to" },
    },
    source = [==[
return function(input, ctx)
  local me = ctx and ctx.bufnr
  if type(me) ~= "number" or not vim.api.nvim_buf_is_valid(me) then
    error("unwatch_agent: no session buffer in context", 0)
  end
  local target
  if input.to == "parent" then
    pcall(function() target = vim.b[me].straps_parent end)
    if type(target) ~= "number" then error("unwatch_agent: this session has no parent", 0) end
  elseif type(input.to) == "string" and input.to:match("^%d+$") then
    target = tonumber(input.to)
  else
    error("unwatch_agent: to must be a buffer number as digits, or \"parent\"", 0)
  end
  local watchers
  pcall(function() watchers = vim.b[target].straps_watchers end)
  if type(watchers) ~= "table" or watchers[tostring(me)] == nil then
    return ("no watch on buffer %d to remove"):format(target)
  end
  watchers[tostring(me)] = nil
  vim.b[target].straps_watchers = next(watchers) and watchers or nil
  return ("stopped watching buffer %d"):format(target)
end
]==],
  })
end

-- Lifecycle events reach fn.notify_watchers from autocmds. The autocmds fire
-- inside the TARGET's run (its registry scope active), so the dispatcher
-- resolves the global entry: a session must not decide delivery for its
-- watchers by shadowing the notifier.
local function dispatch_watch(target, event, reason, cancelled)
  local registry = require("straps.registry")
  local prev = registry.set_active_scope(nil)
  pcall(registry.try_call, "fn.notify_watchers", target, event, reason, cancelled)
  registry.set_active_scope(prev)
end

local function install_watch_autocmds()
  local group = vim.api.nvim_create_augroup("straps_watch", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "StrapsRunStart",
    callback = function(args)
      local d = args.data or {}
      if type(d.bufnr) == "number" then dispatch_watch(d.bufnr, "run_start") end
    end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "StrapsRunEnd",
    callback = function(args)
      local d = args.data or {}
      if type(d.bufnr) == "number" then dispatch_watch(d.bufnr, "run_end", d.reason, d.cancelled) end
    end,
  })
  -- BufUnload covers :bdelete and :bwipeout alike and fires while b: variables
  -- are still readable; :bdelete then clears them, so a later wipeout of the
  -- unloaded buffer has no watchers left to notify.
  vim.api.nvim_create_autocmd("BufUnload", {
    group = group,
    callback = function(args)
      if vim.v.exiting ~= vim.NIL then return end
      local watchers
      pcall(function() watchers = vim.b[args.buf].straps_watchers end)
      if type(watchers) ~= "table" or next(watchers) == nil then return end
      dispatch_watch(args.buf, "closed")
    end,
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
      .. " with the rules fn.provider uses), an '(inert: <reason>)' marker"
      .. " when the effort changes nothing for the model (provider.effort_applies),"
      .. " plus the standing note that subagents inherit them unless spawn is"
      .. " passed explicit arguments. nil for a non-session buffer. Redefine to"
      .. " reshape or silence it.",
    source = [==[
return function(ctx)
  local bufnr = ctx and ctx.bufnr
  if type(bufnr) ~= "number" or not vim.api.nvim_buf_is_valid(bufnr) then return end
  -- ui.session_info resolves provider/model/effort with the rules the request
  -- uses (fn.provider's provider order, provider.resolve_model), and returns nil for a
  -- non-session buffer.
  local ok, info = pcall(function() return require("straps.ui").session_info(bufnr) end)
  if not ok or type(info) ~= "table" then return end
  local shown = info.model_label ~= info.model
    and ("%s (%s)"):format(info.model_label, info.model) or info.model
  -- An effort is inert when provider.effort_applies says the backend sends no
  -- field for it, the same rule :checkhealth reports;
  -- provider.unapplied_effort_note states what the request carries instead.
  local effort = info.effort
  if effort ~= "off" then
    local cfg = require("straps").config or {}
    local providers = require("straps.provider")
    local entry = providers.is_provider(info.provider) and providers.model_entry(info.provider, info.model, cfg) or nil
    local applies, why = providers.effort_applies(info.provider, entry, effort, cfg.efforts)
    if not applies then
      effort = effort .. " (inert: " .. why .. "; " .. providers.unapplied_effort_note(info.provider, entry) .. ")"
    end
  end
  -- Carried here, not only in the prompt's # Subagents section: that section
  -- is dropped for a subagent at the depth limit, so a nested spawner whose
  -- limit was raised mid-session would never read it.
  return ("# Model\n\nThis session is running on %s · provider %s · effort %s."
    .. " Subagents inherit this model and effort unless you pass spawn an"
    .. " explicit model / effort — call the models tool for the ids you can"
    .. " pass, and match the child's capability to its task rather than"
    .. " defaulting to your own."):format(shown, info.provider, effort)
end
]==],
  })

  -- --------------------------------------------------------- hook.on_run_end

  define({
    name = "hook.on_run_end",
    kind = "hook",
    doc = "Called as (ctx, reason) when an agent run ends (normally, on error,"
      .. " or after cancellation). reason is the ending the loop named:"
      .. " \"ok\", \"cancelled\", \"max_turns\", \"stalled\", \"blank\", or"
      .. " \"error\". This base entry is a no-op; redefine it for teardown, or"
      .. " ADD a subscriber (hook.on_run_end.<suffix>, see the fan-out"
      .. " convention) to leave it in place — hook.on_run_end.notify_parent is"
      .. " the builtin subscriber that tells a parent its subagent finished.",
    source = [==[
return function(ctx, reason)
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
      .. " delivered onto the session as a user message through"
      .. " fn.session_notify (steering if a run is active, an ordinary user"
      .. " block otherwise). Returns the autocmd id"
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
        if not ok_call then error(out, 0) end
        return out
      end)
      if ok and type(s) == "string" and s ~= "" then
        vim.schedule(function()
          require("straps.registry").try_call("fn.session_notify", session, s, { source = "harness" })
        end)
      end
    end,
  })
end
]==],
  })

  -- --------------------------------------------------------- fn.session_notify

  -- The "harness speaks to an agent" delivery policy, at ONE late-bound name:
  -- a running session hears it as steering, an idle one as an ordinary user
  -- block. fn.autocmd_bridge and hook.on_run_end.notify_parent both route
  -- through here, so redefining delivery changes every channel at once.
  --
  -- Why loop.steer's RETURN is the running test rather than loop.running: the
  -- two must not be separable. state.append into a session whose provider is
  -- mid-stream lands the block inside the streaming assistant block and glues
  -- the following deltas onto it — a corrupted transcript. steer returns false
  -- only when no run is active, with no window in between.
  define({
    name = "fn.session_notify",
    kind = "fn",
    doc = "Deliver a harness-generated user message to a session. Call as"
      .. " (bufnr, text, opts) with opts = { quiet = true } to suppress the"
      .. " steering toast (for messages the user did not type) and opts.source"
      .. " = 'harness' (default), 'agent' or 'user' to label the queued entry."
      .. " A session with an active run gets it as steering, drained into the"
      .. " transcript at the next turn boundary (and a spawn_wait in progress"
      .. " returns early to let it through); an idle session gets an ordinary"
      .. " user block plus a restored trailing user block, and is not started"
      .. " here (fn.notify_watchers is the one path that starts an idle"
      .. " session, for a watch it asked for). Returns 'steer', 'append', or nil"
      .. " for an invalid buffer or empty text.",
    source = [==[
return function(bufnr, text, opts)
  if type(bufnr) ~= "number" or not vim.api.nvim_buf_is_valid(bufnr) then return end
  if type(text) ~= "string" or text == "" then return end
  local loop = require("straps.loop")
  local source = opts and opts.source or "harness"
  local quiet = { quiet = opts and opts.quiet or nil, source = source }
  if source == "user" then loop.note_user_activity(bufnr) end
  if loop.steer(bufnr, text, quiet) then return "steer" end
  -- Idle: append directly. Scheduled so any already-scheduled streaming delta
  -- from the run that just ended lands first (ctx.emit schedules its appends
  -- and vim.schedule is FIFO), and re-tested because a new run may have
  -- started in the meantime — exactly one steer attempt, so a queued message
  -- is never also appended.
  vim.schedule(function()
    pcall(function()
      if not vim.api.nvim_buf_is_valid(bufnr) then return end
      if loop.steer(bufnr, text, quiet) then return end
      local state = require("straps.state")
      state.append(bufnr, "user", nil, text)
      state.ensure_trailing_user(bufnr)
    end)
  end)
  return "append"
end
]==],
  })

  -- ----------------------------------------------------------- fn.spawn_notice

  define({
    name = "fn.spawn_notice",
    kind = "fn",
    doc = "The BODY of the notice hook.on_run_end.notify_parent delivers to a"
      .. " parent when its subagent finishes. Called as (child, reason) ->"
      .. " string; the child's one-line task is read from b:straps_task. The"
      .. " caller owns the '[straps] subagent buffer N: ' prefix (spawn_wait"
      .. " matches it to drop notices for children it already collected), so a"
      .. " redefinition here cannot break that dedupe. Return the empty string"
      .. " to silence the notice.",
    source = [==[
return function(child, reason)
  -- Never "finished" for a truncated ending: a parent that trusts a partial
  -- answer is worse off than one told the child stopped short.
  local outcome = ({
    ok = "finished",
    error = "crashed",
    max_turns = "hit its turn limit",
    stalled = "stopped without producing an answer",
    blank = "stopped without producing an answer",
  })[tostring(reason)] or ("ended (" .. tostring(reason) .. ")")
  local task
  pcall(function() task = vim.b[child].straps_task end)
  local parts = { outcome }
  if type(task) == "string" and task ~= "" then
    parts[#parts + 1] = "task: " .. task
  end
  return table.concat(parts, " — ")
    .. (". Collect its answer with spawn_wait{ buffers = { %d } } (it returns at"
      .. " once now). Ignore this if you already collected that subagent; if you"
      .. " have already given your final answer and do not need it, restate that"
      .. " answer."):format(child)
end
]==],
  })

  -- ------------------------------------------- hook.on_run_end.notify_parent

  -- Completion PUSH for subagents. Without it spawn_wait is the only channel
  -- back from a child, so a parent must block to learn anything; with it a
  -- parent can spawn, keep working, and collect when the notice lands.
  --
  -- A SUBSCRIBER (hook.on_run_end.<suffix>), not a redefinition of the base
  -- entry: the no-op default and any user redefinition of hook.on_run_end both
  -- keep working, and this can be silenced on its own.
  --
  -- Suppression is deliberately two-part. reason == "cancelled" covers the
  -- ordinary stop; ctx.cancelled() covers the case reason cannot — a stopped
  -- run whose forced resume raises inside the provider ends "error" seconds
  -- after the stop, and reporting a user-killed child as "crashed" would be a
  -- lie. straps_spawn_claimed covers the other half: while spawn_wait holds a
  -- child's claim, its tool result is the report and the push is redundant.
  -- An early-returning spawn_wait releases the claim of a still-running child.
  define({
    name = "hook.on_run_end.notify_parent",
    kind = "hook",
    doc = "Subscriber to hook.on_run_end: when a SUBAGENT's run ends, deliver a"
      .. " one-line notice to its parent session (steering if the parent is"
      .. " running, an ordinary user block if it is idle — never starting the"
      .. " parent's run), so the parent can keep working instead of blocking in"
      .. " spawn_wait. The notice names the child buffer and how to collect it,"
      .. " never its answer text — the child's context stays isolated. Silent"
      .. " for a non-subagent run, a stopped/cancelled child, a child spawn_wait"
      .. " already claimed, and when config.spawn_notify = false (or redefine"
      .. " this entry). Text comes from fn.spawn_notice.",
    source = [==[
return function(ctx, reason)
  local child = ctx and ctx.bufnr
  if type(child) ~= "number" or not vim.api.nvim_buf_is_valid(child) then return end
  -- Read the parent handle BEFORE any validity call: an ordinary (non-subagent)
  -- session has no straps_parent, and nvim_buf_is_valid(nil) raises.
  local parent
  pcall(function() parent = vim.b[child].straps_parent end)
  if type(parent) ~= "number" then return end
  if not vim.api.nvim_buf_is_valid(parent) then return end
  local is_session
  pcall(function() is_session = vim.b[parent].straps_session end)
  if is_session ~= true then return end

  local enabled = true
  pcall(function()
    local cfg = require("straps").config
    if cfg and cfg.spawn_notify == false then enabled = false end
  end)
  if not enabled then return end

  if reason == "cancelled" then return end
  local stopped = false
  pcall(function()
    if ctx.cancelled and ctx.cancelled() then stopped = true end
  end)
  if stopped then return end

  local claimed
  pcall(function() claimed = vim.b[child].straps_spawn_claimed end)
  if claimed then return end

  local registry = require("straps.registry")
  local ok_body, body = pcall(registry.try_call, "fn.spawn_notice", child, reason)
  if not ok_body or type(body) ~= "string" or body == "" then return end
  -- The prefix is OURS, not fn.spawn_notice's: spawn_wait matches it verbatim
  -- to drop notices for children it collected, so a redefined body cannot
  -- break that dedupe.
  local notice = ("[straps] subagent buffer %d: "):format(child) .. body
  registry.try_call("fn.session_notify", parent, notice, { quiet = true })
end
]==],
  })

  -- ------------------------------------------------------- fn.notify_watchers

  define({
    name = "fn.notify_watchers",
    kind = "fn",
    doc = "Deliver a lifecycle event of session `target` to the sessions"
      .. " watching it (tool.watch_agent). Called as (target, event, reason,"
      .. " cancelled) from the StrapsRunStart / StrapsRunEnd User autocmds and"
      .. " BufUnload, always resolved globally. event is run_start, run_end or"
      .. " closed. A run_end that was cancelled (reason 'cancelled' or a stopped"
      .. " run) is not delivered and leaves the watches armed. Each matching"
      .. " watch is removed (one-shot) and gets a `[straps] watched agent"
      .. " <label> (buffer N): <event>` notice, under the watcher's registry"
      .. " scope: steering if the watcher is running; if it is idle and its"
      .. " watch has wake = true, the notice is queued and its run is started,"
      .. " unless the user stopped that session, its trailing prompt holds"
      .. " unsent text, or it has used config.watch_wake_limit wakes since the"
      .. " user last sent to it, in which case the notice is appended without a"
      .. " start. Returns the number of watchers notified.",
    source = [==[
return function(target, event, reason, cancelled)
  if type(target) ~= "number" then return 0 end
  if event == "run_end" and (reason == "cancelled" or cancelled) then return 0 end
  local watchers
  pcall(function() watchers = vim.b[target].straps_watchers end)
  if type(watchers) ~= "table" then return 0 end

  local due, kept = {}, {}
  for key, w in pairs(watchers) do
    local match = false
    if type(w) == "table" and type(w.events) == "table" then
      for _, e in ipairs(w.events) do
        if e == event then match = true break end
      end
    end
    if match then due[#due + 1] = { bufnr = tonumber(key), wake = w.wake ~= false } else kept[key] = w end
  end
  if #due == 0 then return 0 end
  if event ~= "closed" then
    pcall(function() vim.b[target].straps_watchers = next(kept) and kept or nil end)
  end

  local label = "buffer " .. tostring(target)
  pcall(function() label = require("straps.ui").session_label(target) end)
  local what = event
  if event == "run_end" and reason ~= nil then what = ("run_end (%s)"):format(tostring(reason)) end
  local notice = ("[straps] watched agent %s (buffer %d): %s. This watch has fired and is removed;"
    .. " call watch_agent again to keep watching."):format(label, target, what)

  local registry = require("straps.registry")
  local loop = require("straps.loop")
  local state = require("straps.state")
  local limit = 20
  pcall(function()
    local cfg = require("straps").config
    if cfg and tonumber(cfg.watch_wake_limit) then limit = tonumber(cfg.watch_wake_limit) end
  end)

  local function is_session(b)
    if type(b) ~= "number" or not vim.api.nvim_buf_is_valid(b) then return false end
    local ok, v = pcall(function() return vim.b[b].straps_session end)
    return ok and v == true
  end

  local function wake_or_append(watcher, wake)
    if not is_session(watcher) then return end
    local prev = registry.set_active_scope(watcher)
    local ok = pcall(function()
      if loop.steer(watcher, notice, { quiet = true, source = "harness" }) then return end
      local paused, wakes = false, 0
      pcall(function()
        paused = vim.b[watcher].straps_watch_paused == true
        wakes = tonumber(vim.b[watcher].straps_watch_wakes) or 0
      end)
      local draft = state.last_user_text(watcher)
      local blank = draft == nil or not draft:match("%S")
      if wake and not paused and wakes < limit and blank then
        local queue = vim.b[watcher].straps_steering
        if type(queue) ~= "table" then queue = {} end
        queue[#queue + 1] = { text = notice, source = "harness" }
        vim.b[watcher].straps_steering = queue
        vim.b[watcher].straps_watch_wakes = wakes + 1
        loop.start(watcher, { source = "harness" })
      else
        registry.try_call("fn.session_notify", watcher, notice, { quiet = true, source = "harness" })
      end
    end)
    registry.set_active_scope(prev)
    return ok
  end

  local n = 0
  for _, d in ipairs(due) do
    if d.bufnr ~= target and is_session(d.bufnr) then
      n = n + 1
      local prev = registry.set_active_scope(d.bufnr)
      local steered = loop.steer(d.bufnr, notice, { quiet = true, source = "harness" })
      registry.set_active_scope(prev)
      if not steered then
        vim.schedule(function() wake_or_append(d.bufnr, d.wake) end)
      end
    end
  end
  return n
end
]==],
  })

  install_watch_autocmds()
end

return M
