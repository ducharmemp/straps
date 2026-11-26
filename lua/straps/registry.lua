-- straps.registry: the late-bound registry (heart of the plugin).
-- Entries are Lua source strings compiled on define and looked up by name at
-- every call site, so redefining an entry takes effect on the very next call.
--
-- Storage is private to this module. Callers see read-only copies of entries

local M = {}

-- name -> { name, kind, doc, input_schema, source, fn, version, seq, scope }
-- This is the GLOBAL scope. scope on an entry is the owning bufnr, or nil
-- for global entries.
local entries = {}
local default_tools = {}

-- Session overlays, vim's :set/:setlocal split applied to the registry:
-- bufnr -> { entries = {}, parent = bufnr|nil }. Lookups made while a
-- scope is ACTIVE resolve child -> parent -> ... -> global; defines made
-- while a scope is active land in that scope unless told otherwise. A
-- session's experiments shadow the world without mutating it, and die
-- with the buffer.
local scopes = {}

-- hook.guard.* entries: the policy chain that gates tool execution and
-- entry definition. Kept outside entries/scopes so no scope shadow, and no
-- reference handed out by this module, can reach them. Frozen after the
-- user's global corpus loads (see freeze_guards).
local guards = {}
local guards_frozen = false

-- Per-session permission grants (formerly vim.b straps_allowed). A buffer
-- variable is writable by any Lua the agent runs; a module upvalue is not.
local grants = {}

-- The subprocess semaphore's state: slots in flight and the FIFO of waiters
-- (fn.subprocess_acquire in layers/exec.lua). One table per Neovim, shared
-- by every session, kept here so a redefined acquire or limit fn reads the
-- same counter as the default.
local subprocess = { in_flight = 0, waiters = {} }

function M.window_cwd(win)
  if not (win and vim.api.nvim_win_is_valid(win)) then return vim.fn.getcwd() end
  return vim.fn.getcwd(win, vim.api.nvim_tabpage_get_number(vim.api.nvim_win_get_tabpage(win)))
end

function M.subprocess_state()
  return subprocess
end

-- Which tool.* body is executing, two views:
--   executing_name[co]      coroutine -> tool name (for info.executing)
--   executing_for[bufnr]    session -> weak set of coroutines running a tool
--                           body on its behalf
-- The self-grant refusal keys on the SESSION, not the coroutine: a body that
-- hops into coroutine.wrap() is still executing for its session. The inner
-- set is weak-keyed so a body abandoned mid-await (cancelled run) is collected
-- instead of refusing the session's grants forever.
local executing_name = setmetatable({}, { __mode = "k" })
local executing_for = {}

local function executing_for_session(bufnr)
  local set = executing_for[bufnr]
  return set ~= nil and next(set) ~= nil
end

-- coroutine -> true while a hook.guard.* body runs on it. A guard that calls
-- back into a guarded operation would recurse into the fold; the nested fold
-- raises instead, and the fail-closed rule turns that into a block of the
-- outer operation. Per-coroutine because a guard on the loop path may yield
-- (ctx.await) while another session's guard runs.
local in_guard = setmetatable({}, { __mode = "k" })

-- The buffer whose scope chain resolves lookups right now. The loop sets
-- this around every resume of a run's coroutine, so all registry traffic
-- inside a run — tools, hooks, fns, and anything they call — resolves
-- through that session's chain. nil = plain global resolution.
local active = nil

--- Set the active scope; returns the previous value so callers can restore.
function M.set_active_scope(bufnr)
  local prev = active
  active = bufnr
  return prev
end

function M.active_scope()
  return active
end

local function current_co()
  return coroutine.running() or "main"
end

--- Create (or fetch) the overlay for bufnr. parent, when given, chains this
--- scope under another buffer's scope (subagents chain under their spawner).
--- The parent is fixed at creation: re-parenting an existing scope would let
--- one session route another session's lookups through its own overlay.
--- The overlay is dropped automatically when the buffer is wiped out.
function M.ensure_scope(bufnr, parent)
  local s = scopes[bufnr]
  if not s then
    s = { entries = {}, parent = parent }
    scopes[bufnr] = s
    pcall(vim.api.nvim_create_autocmd, "BufWipeout", {
      buffer = bufnr,
      once = true,
      callback = function()
        scopes[bufnr] = nil
        grants[bufnr] = nil
        executing_for[bufnr] = nil
      end,
    })
  elseif parent ~= nil and s.parent ~= parent then
    error(("straps.registry.ensure_scope: scope %d already has parent %s; parents are fixed at creation")
      :format(bufnr, tostring(s.parent)), 0)
  end
  return s
end

--- parent bufnr (or nil) and whether a scope exists for bufnr at all.
function M.scope_parent(bufnr)
  local s = scopes[bufnr]
  if not s then return nil, false end
  return s.parent, true
end

local GUARD_PREFIX = "hook.guard"

local function is_guard_name(name)
  return name == GUARD_PREFIX or name:sub(1, #GUARD_PREFIX + 1) == GUARD_PREFIX .. "."
end

-- Resolve name through a scope chain starting at buf, falling back to
-- global. Hop cap guards against accidental parent cycles.
local function resolve_in(buf, name)
  local hops = 0
  while buf and hops < 8 do
    local s = scopes[buf]
    if not s then break end
    local e = s.entries[name]
    if e then return e end
    buf = s.parent
    hops = hops + 1
  end
  return entries[name] or guards[name]
end

local function resolve(name)
  return resolve_in(active, name)
end

-- The merged view of the active chain: global entries overlaid root-first
-- so the leaf scope's shadows win, plus the guard chain (unshadowable, so it
-- goes on last). name -> entry.
local function merged_entries()
  local chain = {}
  local buf, hops = active, 0
  while buf and scopes[buf] and hops < 8 do
    chain[#chain + 1] = scopes[buf]
    buf = scopes[buf].parent
    hops = hops + 1
  end
  local out = {}
  for name, e in pairs(entries) do out[name] = e end
  for i = #chain, 1, -1 do
    for name, e in pairs(chain[i].entries) do out[name] = e end
  end
  for name, e in pairs(guards) do out[name] = e end
  return out
end

local COPY_FIELDS = { "name", "kind", "doc", "input_schema", "capability", "segment_break", "source", "version", "seq", "scope", "identity" }

local function view(e)
  if not e then return nil end
  local out = {}
  for _, k in ipairs(COPY_FIELDS) do out[k] = vim.deepcopy(e[k]) end
  return out
end

local KINDS = { tool = true, hook = true, fn = true, skill = true }

-- Monotonic registration order. Stamped at FIRST define and preserved across
-- redefines, so anything ordered by seq (the API tool list, dump()) is
-- append-only: new entries go last and never shift existing ones. That is
-- what keeps the prompt-cache prefix stable when the agent defines a tool.
-- A scoped SHADOW of an existing name reuses the shadowed entry's seq, so
-- shadowing never reorders the tool list either.
local next_seq = 0
local next_identity = 0

-- ------------------------------------------------------------------- guards

local GUARD_ARITY = { before = 5, after = 7, define = 4, remove = 4 }

local function guard_info()
  return { active = active, executing = executing_name[current_co()], frozen = guards_frozen }
end

-- Guard events go to the GLOBAL fn.log on purpose: a session-scoped fn.log
-- is agent-definable and must not be able to observe or swallow policy events.
local function log_guard(ev)
  local fl = entries["fn.log"]
  if fl then pcall(fl.fn, ev) end
end

-- Run every guard for op in seq order. Returns nil when no guard objects,
-- otherwise the block text. For op == "after", also returns the (possibly
-- replaced) result as the second value.
-- Fixed arity per op: a trailing nil (ctx on the direct path) must reach the
-- guard as an explicit argument, and #{...} would drop it.
local function run_guards(op, a, b, c, d, e)
  local co = current_co()
  if in_guard[co] then
    error("straps.registry: guard reentrancy — a guard body called a guarded operation", 0)
  end
  local list = {}
  for _, g in pairs(guards) do list[#list + 1] = g end
  if #list == 0 then
    if op == "after" then return nil, c end
    return nil
  end
  table.sort(list, function(x, y) return x.seq < y.seq end)
  local info = guard_info()
  local block
  local result = c
  for _, g in ipairs(list) do
    local t0 = vim.uv.hrtime()
    in_guard[co] = true
    local ok, verdict, reason
    if op == "before" then
      local detached = vim.deepcopy(b)
      ok, verdict, reason = pcall(g.fn, "before", a, detached, c, vim.deepcopy(info))
      if not vim.deep_equal(detached, b) then
        ok, verdict = false, "guard mutated tool input"
      end
    elseif op == "after" then
      ok, verdict, reason = pcall(g.fn, "after", a, b, result, d, e, info)
    else
      ok, verdict, reason = pcall(g.fn, op, a, b, info)
    end
    in_guard[co] = nil
    local outcome
    if not ok then
      outcome = "error"
      block = block or ("blocked by " .. g.name .. ": guard " .. g.name .. " raised: " .. tostring(verdict))
    elseif verdict == false then
      outcome = "block"
      block = block or ("blocked by " .. g.name .. ": " .. (reason == nil and "no reason given" or tostring(reason)))
    elseif op == "after" and type(verdict) == "string" then
      outcome = "replace"
      result = verdict
    else
      outcome = "pass"
    end
    log_guard({ ev = "guard", op = op, name = type(a) == "table" and a.name or a, guard = g.name,
      verdict = outcome, ms = math.floor((vim.uv.hrtime() - t0) / 1e6) })
  end
  return block, result
end

--- Freeze the guard chain. One-way: after this, hook.guard.* entries can be
--- neither defined nor removed until Neovim restarts. Called when the user's
--- global corpus has loaded and at every run start.
function M.freeze_guards()
  guards_frozen = true
end

function M.guards_frozen()
  return guards_frozen
end

--- Copies of the guard entries in seq order (read-only; for listing).
function M.guard_entries()
  local list = {}
  for _, g in pairs(guards) do list[#list + 1] = view(g) end
  table.sort(list, function(x, y) return x.seq < y.seq end)
  return list
end

-- ------------------------------------------------------------------- define

--- Define (or redefine) an entry. Raises on invalid spec or bad source; the
--- previous entry, if any, is left untouched on failure.
--- Scope targeting (opts.scope):
---   nil       -> the ACTIVE scope if one is set (i.e. defines made inside a
---                run are session-scoped by default), else global
---   "global"  -> the global registry, regardless of active scope
---   <bufnr>   -> that buffer's overlay (created as needed)
--- hook.guard.* entries are global-only and refused once frozen.
function M.define(spec, opts)
  if type(spec) ~= "table" then
    error("straps.registry.define: spec must be a table", 0)
  end
  if type(spec.name) ~= "string" or spec.name == "" then
    error("straps.registry.define: spec.name must be a non-empty string", 0)
  end
  if not KINDS[spec.kind] then
    error(("straps.registry.define: %s: kind must be 'tool', 'hook', 'fn' or 'skill' (got %s)")
      :format(spec.name, tostring(spec.kind)), 0)
  end
  local suffix = spec.name:match("^" .. spec.kind .. "%.(.+)$")
  if not suffix then
    error(("straps.registry.define: %s: name must start with '%s.'")
      :format(spec.name, spec.kind), 0)
  end
  if spec.kind == "tool" and not suffix:match("^[%w_%-]+$") then
    error(("straps.registry.define: %s: tool API name must match ^[A-Za-z0-9_-]+$")
      :format(spec.name), 0)
  elseif spec.kind ~= "tool" and not suffix:match("^[%w_][%w_%.%-]*$") then
    error(("straps.registry.define: %s: invalid %s name")
      :format(spec.name, spec.kind), 0)
  end
  if type(spec.source) ~= "string" then
    error(("straps.registry.define: %s: source must be a string"):format(spec.name), 0)
  end
  if spec.capability ~= nil and type(spec.capability) ~= "string" then
    error(("straps.registry.define: %s: capability must be a string"):format(spec.name), 0)
  end
  if spec.segment_break ~= nil and type(spec.segment_break) ~= "boolean" then
    error(("straps.registry.define: %s: segment_break must be a boolean"):format(spec.name), 0)
  end

  local scope_opt = opts and opts.scope
  local guard = is_guard_name(spec.name)
  if guard then
    if scope_opt ~= nil and scope_opt ~= "global" then
      error(("straps.registry.define: %s: guards are global-only; no session shadows"):format(spec.name), 0)
    end
    if guards_frozen then
      error(("straps.registry.define: %s: guards are frozen: install them in stdpath('config')/straps/init.lua and restart")
        :format(spec.name), 0)
    end
  end

  local block = run_guards("define", spec, opts)
  if block then error(block, 0) end

  local fn
  if spec.kind == "skill" then
    -- A skill's source is prose (knowledge), not code: nothing to compile.
    -- fn returns the body so call()/try_call() work uniformly on skills.
    local body = spec.source
    fn = function()
      return body
    end
  else
    local chunk, err = load(spec.source, "straps:" .. spec.name)
    if not chunk then
      error(("straps.registry.define: %s: source does not compile: %s"):format(spec.name, err), 0)
    end
    local ok
    ok, fn = pcall(chunk)
    if not ok then
      error(("straps.registry.define: %s: source raised on load: %s"):format(spec.name, tostring(fn)), 0)
    end
    if type(fn) ~= "function" then
      error(("straps.registry.define: %s: source chunk must return a function (got %s)")
        :format(spec.name, type(fn)), 0)
    end
  end

  -- Pick the target entries table from opts.scope / the active scope.
  local target, scope_buf
  if guard then
    target, scope_buf = guards, nil
  elseif scope_opt == "global" or (scope_opt == nil and active == nil) then
    target, scope_buf = entries, nil
  else
    scope_buf = (type(scope_opt) == "number") and scope_opt or active
    target = M.ensure_scope(scope_buf).entries
  end

  -- Version/seq build on whatever this define REPLACES OR SHADOWS: the
  -- entry already in the target scope, else the one visible through the
  -- chain. Reusing a shadowed entry's seq keeps the tool list order (and
  -- with it the prompt-cache prefix) stable under shadowing.
  local prev = target[spec.name] or resolve_in(scope_buf, spec.name)
  local seq
  if prev then
    seq = prev.seq
  else
    next_seq = next_seq + 1
    seq = next_seq
  end
  next_identity = next_identity + 1
  local entry = {
    identity = next_identity,
    name = spec.name,
    kind = spec.kind,
    doc = spec.doc,
    input_schema = vim.deepcopy(spec.input_schema),
    source = spec.source,
    capability = spec.capability,
    segment_break = spec.segment_break,
    fn = fn,
    version = (prev and prev.version or 0) + 1,
    seq = seq,
    scope = scope_buf,
  }
  target[spec.name] = entry

  if not guard then
    local on_define = resolve("hook.on_define")
    if on_define then
      pcall(on_define.fn, view(entry)) -- never let the hook break define
    end
  end
  return view(entry)
end

--- Define only if the name is absent GLOBALLY; used for builtin defaults so
--- re-running setup() never clobbers user redefinitions. Always global —
--- builtins are the root of every scope chain.
function M.define_default(spec)
  if entries[spec.name] then
    return view(entries[spec.name])
  end
  local definition = M.define(spec, { scope = "global" })
  if definition.kind == "tool" then default_tools[definition.name] = definition.identity end
  return definition
end

function M.trusted_default_tools()
  assert(M.trusted_setup_allowed(), "trusted defaults require setup")
  local definitions = {}
  for name, identity in pairs(default_tools) do
    if entries[name] and entries[name].identity == identity then definitions[#definitions + 1] = view(entries[name]) end
  end
  return definitions
end

--- Resolve name through the active scope chain, falling back to global.
--- Returns a read-only copy (no fn); nil if absent.
function M.get(name)
  return view(resolve(name))
end

--- The compiled function behind a hook.* or fn.* entry, resolved NOW (not at
--- call time). This is the chaining idiom — capture the previous definition
--- before redefining — and it refuses tool.* so it cannot skip the gate.
function M.bind(name)
  if type(name) == "string" and (name:sub(1, 5) == "tool." or is_guard_name(name)) then
    error(("straps.registry.bind: %s: tools run only through call/gate_tool; guards only through the gate"):format(name), 0)
  end
  local e = resolve(name)
  return e and e.fn or nil
end

-- --------------------------------------------------------------------- tools

--- The gate every tool execution passes: the before-guards, then
--- opts.confirm(name, input, ctx) if given (the loop supplies hook.confirm
--- plus the before_tool fan-out; direct callers are never confirmed).
--- opts.confirm returning false, reason, "hook" marks a hook veto: the
--- refusal reads "blocked by hook.confirm: <reason>"; any other refusal
--- reads "user denied: <reason>".
--- Returns allowed, reason, run. On allowed, `run(ctx) -> ok, raw` executes
--- the entry resolved HERE exactly once (pcall'd; never raises for a tool
--- error). On refusal, run is nil.
local authorization
local families = setmetatable({}, { __mode = "k" })
local family_records = setmetatable({}, { __mode = "k" })
local body_families = setmetatable({}, { __mode = "k" })
local calls = setmetatable({}, { __mode = "k" })
local next_call = 0
local executing_calls = setmetatable({}, { __mode = "k" })
local data_copy

function M.tool_body_running_here()
  for co in pairs(executing_name) do
    if co == "main" then return true end
    if type(co) == "thread" then
      local status = coroutine.status(co)
      if status == "running" or status == "normal" then return true end
    end
  end
  return false
end

function M.any_tool_executing()
  for _, set in pairs(executing_for) do if next(set) then return true end end
  return next(executing_name) ~= nil
end

function M.trusted_setup_allowed()
  return not M.any_tool_executing() and not guards_frozen and next(scopes) == nil
end

function M.setup_authorization(config)
  assert(not authorization and M.trusted_setup_allowed(), "authorization setup must precede sessions and guard freeze")
  for _, key in ipairs({ "assess", "execution_stamp", "validate_stamp" }) do
    assert(type(config[key]) == "function", "missing authorization callback: " .. key)
  end
  local ceilings = require("straps.ceilings").new(resolve_in)
  authorization = {
    assess = config.assess, execution_stamp = config.execution_stamp, validate_stamp = config.validate_stamp,
    invalidate = config.invalidate, consume = config.consume, ceilings = ceilings, input_limits = config.input_limits,
  }
  local controller = {}
  function controller.begin_family(ctx)
    assert(type(ctx) == "table" and type(ctx.bufnr) == "number", "family requires session context")
    M.ensure_scope(ctx.bufnr)
    local handle = {}
    family_records[handle] = { session = ctx.bufnr, cancelled = false }
    families[ctx] = handle
    return handle
  end
  function controller.bind_context(handle, ctx)
    local family = family_records[handle]
    assert(family and not family.cancelled and ctx.bufnr == family.session, "invalid execution family")
    families[ctx] = handle
  end
  function controller.cancel_family(handle)
    assert(family_records[handle], "invalid execution family").cancelled = true
    local pending = {}
    for call_handle, call in pairs(calls) do if call.family == handle then pending[#pending + 1] = call_handle end end
    for _, call_handle in ipairs(pending) do
      if authorization.invalidate then pcall(authorization.invalidate, call_handle, "execution family cancelled") end
      calls[call_handle] = nil
    end
  end
  for _, key in ipairs({ "install", "narrow", "classify", "subset", "retire" }) do
    local operation = ceilings[key]
    controller[key .. "_ceiling"] = function(...)
      return operation(...)
    end
  end
  function controller.describe(handle)
    local call = calls[handle]
    return call and vim.deepcopy(call.description) or nil
  end
  function controller.validate(handle, binding)
    local call = calls[handle]
    if not call or not vim.deep_equal(binding, call.description) then return false end
    return call.validate()
  end
  controller.describe_call = controller.describe
  controller.current_call = controller.validate
  local child_plans = setmetatable({}, { __mode = "k" })
  function controller.prepare_child(action, source, normalized_opts)
    local call = executing_calls[current_co()]
    assert(call and (action == "fork" or action == "spawn") and call.name == action and call.session == source,
      "child action requires exact executing call")
    assert(call.valid(), "child action call is stale")
    local expected = data_copy(call.input)
    expected.readonly = expected.readonly and true or nil
    if action == "fork" then
      expected.relation, expected.focus = "child", false
      expected.split = expected.show and "botright vsplit" or nil
      expected.show = nil
    end
    assert(vim.deep_equal(data_copy(normalized_opts), expected), "child action options differ from approved input")
    local plan = {}
    child_plans[plan] = { call = call, options = expected }
    return plan
  end
  function controller.attach_child(plan, child)
    local pending = child_plans[plan]
    assert(pending and pending.call == executing_calls[current_co()], "invalid child action plan")
    child_plans[plan] = nil
    assert(pending.call.valid(), "child action call is stale")
    assert(type(child) == "number" and child ~= pending.call.session, "invalid child session")
    M.ensure_scope(child, pending.call.session)
    ceilings.install(child, { parent = pending.call.session, readonly = pending.options.readonly,
      allow = pending.options.allow }, pending.call.session)
    return true
  end
  return controller
end

data_copy = function(value, seen)
  local kind = type(value)
  if kind == "nil" or kind == "string" or kind == "boolean" then return value end
  if kind == "number" and value == value and value ~= math.huge and value ~= -math.huge then return value end
  local metatable = kind == "table" and getmetatable(value) or nil
  if kind ~= "table" or (metatable ~= nil and metatable ~= getmetatable(vim.empty_dict())) then error("tool input must be data-only", 0) end
  seen = seen or {}
  if seen[value] then error("tool input must be acyclic", 0) end
  seen[value] = true
  local out = {}
  for key, item in pairs(value) do
    if type(key) ~= "string" and type(key) ~= "number" then error("invalid tool input key", 0) end
    out[data_copy(key)] = data_copy(item, seen)
  end
  seen[value] = nil
  return out
end

local execution_bindings = setmetatable({}, { __mode = "k" })

local function bound_call(binding, fn, ...)
  local co, previous, scope_before = current_co(), execution_bindings[current_co()], active
  execution_bindings[co] = binding
  if binding then active = binding.session end
  local result = { pcall(fn, ...) }
  execution_bindings[co], active = previous, scope_before
  if not result[1] then error(result[2], 0) end
  return unpack(result, 2, table.maxn(result))
end

local function inherited_binding(ctx)
  local binding = execution_bindings[current_co()]
  if binding then return binding end
  for co, candidate in pairs(execution_bindings) do
    if candidate.session == active and (not ctx or co == "main" or coroutine.status(co) == "normal") then
      if binding and binding.cancelled ~= candidate.cancelled then
        return nil, "ambiguous execution context"
      end
      binding = candidate
    end
  end
  return binding
end

local function immediate(fn, ...)
  local binding = execution_bindings[current_co()]
  local co = coroutine.create(function(...) return bound_call(binding, fn, ...) end)
  local scope_before = active
  local ok, result, reason = coroutine.resume(co, ...)
  active = scope_before
  if not ok then return false, tostring(result) end
  if coroutine.status(co) ~= "dead" then
    execution_bindings[co] = nil
    return false, "execution validation must not yield"
  end
  return result, reason
end

local function bounded_input(value, limits)
  if not limits then return true end
  local bytes, items, active = 0, 0, {}
  local function visit(item, depth)
    items = items + 1
    if items > limits.max_items or depth > limits.max_depth then error("tool input structural overflow", 0) end
    local kind = type(item)
    if kind == "string" then
      if #item > limits.max_bytes then error("tool input byte overflow", 0) end
      bytes = bytes + #vim.json.encode(item)
    elseif kind == "table" then
      if active[item] then error("tool input must be acyclic", 0) end
      active[item] = true
      bytes = bytes + 2
      for key, child in pairs(item) do visit(key, depth + 1); visit(child, depth + 1); bytes = bytes + 2 end
      active[item] = nil
    elseif kind == "number" or kind == "boolean" or kind == "nil" then bytes = bytes + #tostring(item)
    else error("tool input must be data-only", 0) end
    if bytes > limits.max_bytes then error("tool input byte overflow", 0) end
  end
  visit(value, 1)
  return true
end

local function preflight_tool_input(input)
  if authorization and authorization.input_limits then
    local bounded, reason = pcall(bounded_input, input, authorization.input_limits)
    if not bounded then return false, reason end
  end
  return true
end
M.preflight_tool_input = preflight_tool_input

function M.child_permission(name, input, ctx)
  local session = ctx and ctx.bufnr
  local allowed = session and grants[session]
  if not allowed or not allowed["spawn:gated"] then return true end
  local detached = data_copy(input)
  local previous = active
  active = session
  local binding = execution_bindings[current_co()]
  if binding and binding.checking_capability then active = previous return false, "capability check reentrancy" end
  if binding then binding.checking_capability = true end
  local ok, cap, why = pcall(immediate, function() return M.try_call("fn.capability", name, detached) end)
  if binding then binding.checking_capability = nil end
  local key = M.tool_grant_key(name)
  active = previous
  if not ok then return false, tostring(cap) end
  if cap == false then return false, why end
  if not vim.deep_equal(detached, input) then return false, "capability mutated tool input" end
  if cap == "read" or (cap and allowed["cap:" .. tostring(cap)]) or allowed[key] then return true end
  if cap == "spawn" and (name == "watch_agent" or name == "unwatch_agent") then return true end
  if name == "send_message" and type(input) == "table" and input.to == "parent" then return true end
  local names = {}
  for key in pairs(allowed) do if key ~= "spawn:gated" then names[#names + 1] = key end end
  if #names == 0 then return false, "readonly subagent: " .. tostring(name) .. " is not allowed" end
  table.sort(names)
  return false, "subagent: " .. tostring(name) .. " is not covered by this child's grants (" .. table.concat(names, ", ") .. ")"
end

local function gate_tool(name, input, ctx, opts)
  local full = "tool." .. name
  local bounded, reason = preflight_tool_input(input)
  if not bounded then return false, reason end
  local copied, frozen = pcall(data_copy, input)
  if not copied then return false, frozen end
  local inherited = body_families[current_co()]
  local family_handle = (ctx and families[ctx]) or inherited
  local family = family_handle and family_records[family_handle]
  if authorization and (not family or family.cancelled or (ctx and ctx.bufnr ~= family.session)) then
    return false, "authorization requires a trusted execution family"
  end
  local session = family and family.session or (ctx and ctx.bufnr)
  local scope = session or active
  local scope_chain = {}
  local cursor = scope
  while cursor and scopes[cursor] do
    scope_chain[#scope_chain + 1] = { cursor, scopes[cursor], scopes[cursor].parent }
    cursor = scopes[cursor].parent
  end
  local handle, stamp, ceiling_revision
  local prev_active = active
  if ctx and ctx.bufnr then active = ctx.bufnr end
  local entry = resolve(full)
  if not entry then
    active = prev_active
    return false, ("straps.registry: no entry named %q"):format(full)
  end

  local gate_cwd = vim.fn.getcwd()
  local gate_win = vim.api.nvim_get_current_win()
  local gate_ctx = ctx and { bufnr = ctx.bufnr, cancelled = ctx.cancelled } or nil
  local used = false
  local function invalidate(reason)
    used = true
    if authorization and handle and authorization.invalidate then pcall(authorization.invalidate, handle, reason) end
    if handle then calls[handle] = nil end
  end
  local function gate_window_cwd() return M.window_cwd(gate_win) end
  local function valid(run_ctx, executing, refresh)
    if used and not executing then return false, "gate result already used" end
    local permitted, permission_reason = M.child_permission(name, frozen, gate_ctx)
    if not permitted then return false, permission_reason end
    if ctx and (ctx.bufnr ~= gate_ctx.bufnr or ctx.cancelled ~= gate_ctx.cancelled) then return false, "execution context changed" end
    if gate_ctx and gate_ctx.cancelled and gate_ctx.cancelled() then return false, "execution cancelled" end
    if (family and family.cancelled) or (run_ctx and run_ctx.cancelled and run_ctx.cancelled()) then return false, "execution cancelled" end
    if (refresh and gate_window_cwd() or vim.fn.getcwd()) ~= gate_cwd then return false, "execution directory changed" end
    if run_ctx and (run_ctx.bufnr ~= session or run_ctx.cancelled ~= (gate_ctx and gate_ctx.cancelled)) then return false, "execution context changed" end
    if authorization and ctx and families[ctx] ~= family_handle then return false, "execution context changed" end
    if authorization and run_ctx and families[run_ctx] ~= family_handle then return false, "execution context changed" end
    if resolve_in(scope, full) ~= entry then return false, "tool definition changed" end
    for _, link in ipairs(scope_chain) do
      if scopes[link[1]] ~= link[2] or scopes[link[1]].parent ~= link[3] then return false, "resolution scope changed" end
    end
    if not authorization then return true end
    if authorization.ceilings.revision(session) ~= ceiling_revision then return false, "capability ceiling changed" end
    local ceiling_ok, why = authorization.ceilings.check(session, view(entry), frozen)
    if not ceiling_ok then return false, why end
    if refresh then return immediate(authorization.validate_stamp, session, vim.deepcopy(stamp), gate_cwd) end
    return immediate(authorization.validate_stamp, session, vim.deepcopy(stamp))
  end
  if authorization then
    handle = {}
    next_call = next_call + 1
    local stamp_ok, value = pcall(authorization.execution_stamp, session)
    if not stamp_ok or type(value) ~= "table" then active = prev_active return false, "authorization stamp unavailable" end
    stamp = data_copy(value)
    ceiling_revision = authorization.ceilings.revision(session)
    calls[handle] = {
      family = family_handle,
      description = { call_id = next_call, session = session, session_id = stamp.session_id, task_id = stamp.task_id,
        epoch = stamp.epoch, scope = scope, cwd = gate_cwd, input = vim.deepcopy(frozen),
        definition = view(entry), stamp = vim.deepcopy(stamp), ceiling_revision = ceiling_revision },
      validate = function() return valid(ctx, nil, true) end,
    }
  end

  -- Guards and confirm may raise (reentrancy, a broken confirm); the active
  -- scope must be restored on that path too, so run them under pcall.
  local ok, refused, reason = pcall(function()
    local permitted, permission_reason = M.child_permission(name, frozen, gate_ctx)
    if not permitted then return true, permission_reason end
    local block = run_guards("before", name, frozen, ctx)
    if block then return true, block end
    if authorization then
      local allowed, why = valid(ctx)
      if not allowed then return true, why end
      local description = vim.deepcopy(calls[handle].description)
      local decision = authorization.assess(handle, description, ctx)
      local current_call = calls[handle]
      if not current_call then return true, "execution family cancelled" end
      if not vim.deep_equal(description, current_call.description) then return true, "assessment mutated call" end
      if type(decision) ~= "table" or decision.decision ~= "allow" then
        return true, type(decision) == "table" and type(decision.reason) == "string" and decision.reason or "contextual authorization denied"
      end
    end
    if opts and opts.confirm then
      local detached = vim.deepcopy(frozen)
      local allowed, why, source = opts.confirm(name, detached, ctx)
      if not vim.deep_equal(detached, frozen) then return true, "confirmation mutated tool input" end
      if not allowed then
        local prefix = source == "hook" and "blocked by hook.confirm: " or "user denied: "
        return true, prefix .. (why or "")
      end
    end
    return false
  end)
  active = prev_active
  if not ok then invalidate(refused) error(refused, 0) end
  if refused then invalidate(reason) return false, reason end

  local function run(run_ctx)
    if used then error("straps.registry: gate result already used", 0) end
    local valid_ok, valid_reason = immediate(valid, run_ctx)
    if not valid_ok then used = true invalidate(valid_reason) return false, valid_reason end
    if authorization and authorization.consume then
      local consumed, why = immediate(authorization.consume, handle)
      if not consumed then used = true invalidate(why) return false, why or "consent unavailable" end
      local still_valid, changed = immediate(valid, run_ctx)
      if not still_valid then used = true invalidate(changed) return false, changed end
    end
    used = true
    local co = current_co()
    local outer_family = body_families[co]
    body_families[co] = family_handle
    local outer = executing_name[co]
    executing_name[co] = name
    local set
    if session then
      set = executing_for[session]
      if not set then
        set = setmetatable({}, { __mode = "k" })
        executing_for[session] = set
      end
      set[co] = (set[co] or 0) + 1
    end
    local scope_before = active
    if session then active = session end
    local outer_call = executing_calls[co]
    executing_calls[co] = authorization and { name = name, session = session, input = data_copy(frozen),
      valid = function() return valid(run_ctx, true) end } or nil
    local ok_run, raw = pcall(entry.fn, frozen, run_ctx or ctx)
    executing_calls[co] = outer_call
    body_families[co] = outer_family
    active = scope_before
    if set then
      set[co] = set[co] - 1
      if set[co] == 0 then set[co] = nil end
    end
    executing_name[co] = outer
    if handle then calls[handle] = nil end
    return ok_run, raw
  end
  return true, nil, run
end

function M.gate_tool(name, input, ctx, opts)
  local inherited, reason = inherited_binding(ctx)
  if reason then return false, reason end
  if inherited then
    if inherited.ctx and (inherited.ctx.bufnr ~= inherited.session or inherited.ctx.cancelled ~= inherited.cancelled) then
      return false, "execution context changed"
    end
    if inherited.cancelled and inherited.cancelled() then return false, "execution cancelled" end
    if ctx and (ctx.bufnr ~= inherited.session or ctx.cancelled ~= inherited.cancelled) then
      return false, "execution context changed"
    end
    ctx = ctx or inherited.ctx
  elseif not ctx and active and grants[active] and grants[active]["spawn:gated"] then
    return false, "session tool call requires execution context"
  end
  local binding = inherited or { session = ctx and ctx.bufnr or active, ctx = ctx, cancelled = ctx and ctx.cancelled }
  local allowed, why, run = bound_call(binding, gate_tool, name, input, ctx, opts)
  if not allowed then return false, why end
  return true, nil, function(run_ctx)
    local current, inherited_reason = inherited_binding(run_ctx)
    if inherited_reason then return false, inherited_reason end
    if current and (current.session ~= binding.session or current.cancelled ~= binding.cancelled) then
      return false, "execution context changed"
    end
    local body_binding = { session = binding.session, ctx = run_ctx or ctx, cancelled = binding.cancelled }
    return bound_call(body_binding, run, run_ctx)
  end
end

--- The after-stage of the pipeline: every guard sees (name, input, result,
--- ok, ctx) in seq order; false blocks, a string replaces the result.
--- Returns result, ok.
function M.after_guards(name, input, result, ok, ctx)
  local block, replaced = run_guards("after", name, input, result, ok, ctx)
  if block then
    if not ok then
      local orig = tostring(result)
      if #orig > 200 then orig = require("straps.state").utf8_cut(orig, 200) end
      block = block .. " (tool had already failed: " .. orig .. ")"
    end
    return block, false
  end
  return replaced, ok
end

local function call_tool(name, ...)
  local input, ctx = ...
  local allowed, reason, run = M.gate_tool(name, input, ctx)
  if not allowed then error(reason, 0) end
  local ok, raw = run(ctx)
  if not ok then error(raw, 0) end
  return raw
end

--- Call an entry, looking it up at call time. Errors clearly if missing.
--- hook.guard.* is refused: guards run only inside the gate.
function M.call(name, ...)
  if type(name) == "string" and name:sub(1, 5) == "tool." then
    return call_tool(name:sub(6), ...)
  end
  if type(name) == "string" and is_guard_name(name) then
    error(("straps.registry: %s: guards run only inside the gate"):format(name), 0)
  end
  local entry = resolve(name)
  if not entry then
    error(("straps.registry: no entry named %q"):format(name), 0)
  end
  return entry.fn(...)
end

--- Like call, but returns nil if the entry does not exist (optional hooks).
--- Errors inside the fn — and, for tools, a guard block — still propagate.
function M.try_call(name, ...)
  local entry = resolve(name)
  if not entry then
    return nil
  end
  return M.call(name, ...)
end

-- --------------------------------------------------------------------- hooks

-- Internal: live entries (with fn) for a hook fan-out. Guards are excluded:
-- they run only inside the gate, never through call_hooks.
local function hook_entries_live(name)
  local merged = merged_entries()
  local prefix = name .. "."
  local out = {}
  for entry_name, entry in pairs(merged) do
    if entry.kind == "hook" and not is_guard_name(entry_name)
      and (entry_name == name or entry_name:sub(1, #prefix) == prefix) then
      out[#out + 1] = entry
    end
  end
  table.sort(out, function(a, b)
    return a.seq < b.seq
  end)
  return out
end

--- Ordered fan-out subscriber list for hook `name`: the entry named exactly
--- `name` plus every entry whose name starts with `name .. "."`, all
--- kind == "hook", resolved through the MERGED active-scope view (so a
--- session-scoped subscriber and the global default both appear), sorted by
--- seq ascending — registration order, oldest (usually the builtin default)
--- first. Returns read-only copies; call each with call(entry.name, ...).
function M.hook_entries(name)
  local out = {}
  for i, e in ipairs(hook_entries_live(name)) do out[i] = view(e) end
  return out
end

--- Call every subscriber to hook `name` (see hook_entries) with pcall, so one
--- broken subscriber never prevents the others from running. Returns two
--- tables: `results`, the non-nil return values in seq order, and `errors`,
--- one {name = <entry name>, err = <message>} per subscriber that raised.
function M.call_hooks(name, ...)
  local results, errors = {}, {}
  for _, entry in ipairs(hook_entries_live(name)) do
    local ok, ret = pcall(entry.fn, ...)
    if ok then
      if ret ~= nil then
        results[#results + 1] = ret
      end
    else
      errors[#errors + 1] = { name = entry.name, err = tostring(ret) }
    end
  end
  return results, errors
end

-- ------------------------------------------------------------------- listing

--- Entry names in REGISTRATION order (by seq), optionally filtered by kind,
--- over the MERGED view of the active scope chain. This is the order that
--- must stay append-only for prompt-cache stability; scoped shadows reuse
--- the shadowed seq, so they hold their position.
function M.names_by_seq(kind)
  local merged = merged_entries()
  local out = {}
  for name, entry in pairs(merged) do
    if kind == nil or entry.kind == kind then
      out[#out + 1] = name
    end
  end
  table.sort(out, function(a, b)
    return merged[a].seq < merged[b].seq
  end)
  return out
end

--- Sorted entry names over the merged view, optionally filtered by kind.
function M.names(kind)
  local out = {}
  for name, entry in pairs(merged_entries()) do
    if kind == nil or entry.kind == kind then
      out[#out + 1] = name
    end
  end
  table.sort(out)
  return out
end

-- ------------------------------------------------------------------- remove

--- Remove an entry. By default this removes the entry that the ACTIVE scope
--- would resolve: a session-scoped shadow in the active chain is removed first
--- (un-shadowing any global of the same name), otherwise the global entry is
--- removed. Pass opts.scope = "global" to force removing the global entry, or
--- a buffer number to remove from that specific scope's overlay. Returns true
--- if something was removed. hook.guard.* entries are refused once frozen.
function M.remove(name, opts)
  opts = opts or {}
  if type(name) ~= "string" then
    error("straps.registry.remove: name must be a string", 0)
  end
  if is_guard_name(name) then
    if guards_frozen then
      error(("straps.registry.remove: %s: guards are frozen: install them in stdpath('config')/straps/init.lua and restart")
        :format(name), 0)
    end
    local block = run_guards("remove", name, opts)
    if block then error(block, 0) end
    local had = guards[name] ~= nil
    guards[name] = nil
    return had
  end
  local block = run_guards("remove", name, opts)
  if block then error(block, 0) end
  if opts.scope == "global" then
    local had = entries[name] ~= nil
    entries[name] = nil
    return had
  end
  local scope_buf = type(opts.scope) == "number" and opts.scope or active
  -- Walk the active chain leaf-first; remove from the nearest scope holding it.
  local buf, hops = scope_buf, 0
  while buf and scopes[buf] and hops < 8 do
    if scopes[buf].entries[name] ~= nil then
      scopes[buf].entries[name] = nil
      return true
    end
    buf = scopes[buf].parent
    hops = hops + 1
  end
  local had = entries[name] ~= nil
  entries[name] = nil
  return had
end

-- ------------------------------------------------------------------- grants

--- Grant a permission key ("cap:exec", "editdir:/x", a tool name) to a
--- session. Refused from inside a tool body executing for that same session,
--- so eval_lua cannot award its own session a grant; hook.confirm (which runs
--- in the gate, before any tool body), :StrapsAuto (no active run) and spawn
--- (granting the CHILD) are unaffected.
function M.grant(bufnr, key)
  if type(bufnr) ~= "number" or type(key) ~= "string" or key == "" then
    error("straps.registry.grant: (bufnr, key) required", 0)
  end
  if executing_for_session(bufnr) then
    error(("straps.registry.grant: %s: a tool body cannot grant its own session"):format(key), 0)
  end
  local set = grants[bufnr]
  if not set then
    set = {}
    grants[bufnr] = set
    M.ensure_scope(bufnr)
  end
  set[key] = true
end

function M.clear_grants(bufnr, prefix)
  prefix = prefix or ""
  local set = grants[bufnr]
  local removed = {}
  if not set then return removed end
  for k in pairs(set) do
    if k ~= "spawn:gated" and k:sub(1, #prefix) == prefix then
      removed[#removed + 1] = k
      set[k] = nil
    end
  end
  table.sort(removed)
  return removed
end

--- The grant-set key for a tool-name grant: "<name>@v<version>" of the entry
--- the active scope resolves ("<name>@v<version>@<bufnr>" for a session-scoped
--- entry), or the bare name when no such tool exists. A name grant names a
--- definition: a session shadow or a redefinition bumps the version (define
--- reuses the shadowed entry's version as its base), and the scope suffix keeps
--- a shadow's key apart from a later global redefinition at the same version.
function M.tool_grant_key(name)
  local e = resolve("tool." .. tostring(name))
  if not e then return tostring(name) end
  local key = tostring(name) .. "@v" .. tostring(e.version)
  if e.scope ~= nil then key = key .. "@" .. tostring(e.scope) end
  return key
end

--- A copy of the grant set for bufnr (key -> true); empty when none.
function M.granted(bufnr)
  local out = {}
  local set = grants[bufnr]
  if set then
    for k, v in pairs(set) do out[k] = v end
  end
  return out
end

-- ------------------------------------------------------------------- render

--- Render an entry as an executable Lua chunk that re-defines it. Resolves
--- through the active scope chain, so a session-scoped entry renders (and
--- can therefore be persisted to .straps.lua, where it loads as global).
function M.render(name)
  local e = resolve(name)
  if not e then
    error(("straps.registry.render: no entry named %q"):format(name), 0)
  end
  -- Pick a long-bracket level that cannot collide with the source: bump while
  -- the source contains "]" followed by that many "="s (covers both an inner
  -- closer and a boundary collision with our appended closer).
  local level = 2
  while e.source:find("]" .. string.rep("=", level), 1, true) do
    level = level + 1
  end
  local eq = string.rep("=", level)

  local parts = { 'require("straps.registry").define{' }
  parts[#parts + 1] = ("  name = %q,"):format(e.name)
  parts[#parts + 1] = ("  kind = %q,"):format(e.kind)
  if e.doc ~= nil then
    parts[#parts + 1] = ("  doc = %q,"):format(e.doc)
  end
  if e.input_schema ~= nil then
    parts[#parts + 1] = "  input_schema = " .. vim.inspect(e.input_schema) .. ","
  end
  if e.capability ~= nil then
    parts[#parts + 1] = ("  capability = %q,"):format(e.capability)
  end
  if e.segment_break ~= nil then
    parts[#parts + 1] = ("  segment_break = %s,"):format(tostring(e.segment_break))
  end
  parts[#parts + 1] = ("  source = [%s[\n%s]%s],"):format(eq, e.source, eq)
  parts[#parts + 1] = "}"
  return table.concat(parts, "\n")
end

--- Every GLOBAL entry (guards included) rendered and concatenated; executing
--- the result restores the global registry. Ordered by seq so a restore
--- re-registers entries in the original order — preserving the append-only
--- tool ordering across sessions. Session overlays are deliberately excluded:
--- they are ephemeral by design (persist one with render() into .straps.lua).
--- Guard entries replay only before the freeze (i.e. from the global corpus).
function M.dump()
  local function seq_of(name)
    local e = entries[name] or guards[name]
    return e.seq
  end
  local names = {}
  for name in pairs(entries) do
    names[#names + 1] = name
  end
  for name in pairs(guards) do
    names[#names + 1] = name
  end
  table.sort(names, function(a, b)
    return seq_of(a) < seq_of(b)
  end)
  local parts = {}
  for _, name in ipairs(names) do
    -- Render from the global entry directly (render() resolves scoped).
    local saved = M.set_active_scope(nil)
    local ok, rendered = pcall(M.render, name)
    M.set_active_scope(saved)
    if ok then
      parts[#parts + 1] = rendered
    end
  end
  return table.concat(parts, "\n\n") .. "\n"
end

return M
