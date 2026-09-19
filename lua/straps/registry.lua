-- straps.registry: the late-bound registry (heart of the plugin).
-- Entries are Lua source strings compiled on define and looked up by name at
-- every call site, so redefining an entry takes effect on the very next call.
--
-- Storage is private to this module. Callers see read-only copies of entries
-- (never the compiled fn), and every tool execution passes gate_tool, so the
-- guard chain (hook.guard.*) and hook.confirm sit in front of every tool call
-- regardless of who makes it.

local M = {}

-- name -> { name, kind, doc, input_schema, source, fn, version, seq, scope }
-- This is the GLOBAL scope. scope on an entry is the owning bufnr, or nil
-- for global entries.
local entries = {}

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
      :format(bufnr, tostring(s.parent)))
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

local COPY_FIELDS = { "name", "kind", "doc", "input_schema", "capability", "source", "version", "seq", "scope" }

-- Read-only view: a shallow copy of the public fields. The compiled fn is
-- deliberately absent — handing it out would be a way to run a tool without
-- passing gate_tool.
local function view(e)
  if not e then return nil end
  local out = {}
  for _, k in ipairs(COPY_FIELDS) do out[k] = e[k] end
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
      ok, verdict, reason = pcall(g.fn, "before", a, b, c, info)
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
    error("straps.registry.define: spec must be a table")
  end
  if type(spec.name) ~= "string" or spec.name == "" then
    error("straps.registry.define: spec.name must be a non-empty string")
  end
  if not KINDS[spec.kind] then
    error(("straps.registry.define: %s: kind must be 'tool', 'hook', 'fn' or 'skill' (got %s)")
      :format(spec.name, tostring(spec.kind)))
  end
  local suffix = spec.name:match("^" .. spec.kind .. "%.(.+)$")
  if not suffix then
    error(("straps.registry.define: %s: name must start with '%s.'")
      :format(spec.name, spec.kind))
  end
  if spec.kind == "tool" and not suffix:match("^[%w_%-]+$") then
    error(("straps.registry.define: %s: tool API name must match ^[A-Za-z0-9_-]+$")
      :format(spec.name))
  elseif spec.kind ~= "tool" and not suffix:match("^[%w_][%w_%.%-]*$") then
    error(("straps.registry.define: %s: invalid %s name")
      :format(spec.name, spec.kind))
  end
  if type(spec.source) ~= "string" then
    error(("straps.registry.define: %s: source must be a string"):format(spec.name))
  end
  if spec.capability ~= nil and type(spec.capability) ~= "string" then
    error(("straps.registry.define: %s: capability must be a string"):format(spec.name))
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
      error(("straps.registry.define: %s: source does not compile: %s"):format(spec.name, err))
    end
    local ok
    ok, fn = pcall(chunk)
    if not ok then
      error(("straps.registry.define: %s: source raised on load: %s"):format(spec.name, tostring(fn)))
    end
    if type(fn) ~= "function" then
      error(("straps.registry.define: %s: source chunk must return a function (got %s)")
        :format(spec.name, type(fn)))
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
  local entry = {
    name = spec.name,
    kind = spec.kind,
    doc = spec.doc,
    input_schema = spec.input_schema,
    source = spec.source,
    capability = spec.capability,
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
  return M.define(spec, { scope = "global" })
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
--- Returns allowed, reason, run. On allowed, `run(ctx) -> ok, raw` executes
--- the entry resolved HERE exactly once (pcall'd; never raises for a tool
--- error). On refusal, run is nil.
function M.gate_tool(name, input, ctx, opts)
  local full = "tool." .. name
  local prev_active = active
  if ctx and ctx.bufnr then active = ctx.bufnr end
  local entry = resolve(full)
  if not entry then
    active = prev_active
    return false, ("straps.registry: no entry named %q"):format(full)
  end

  -- Guards and confirm may raise (reentrancy, a broken confirm); the active
  -- scope must be restored on that path too, so run them under pcall.
  local ok, refused, reason = pcall(function()
    local block = run_guards("before", name, input, ctx)
    if block then return true, block end
    if opts and opts.confirm then
      local allowed, why = opts.confirm(name, input, ctx)
      if not allowed then return true, "user denied: " .. (why or "") end
    end
    return false
  end)
  active = prev_active
  if not ok then error(refused, 0) end
  if refused then return false, reason end

  local used = false
  local session = ctx and ctx.bufnr or nil
  local function run(run_ctx)
    if used then error("straps.registry: gate result already used", 0) end
    used = true
    local co = current_co()
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
    if run_ctx and run_ctx.bufnr then active = run_ctx.bufnr end
    local ok_run, raw = pcall(entry.fn, input, run_ctx)
    active = scope_before
    if set then
      set[co] = set[co] - 1
      if set[co] == 0 then set[co] = nil end
    end
    executing_name[co] = outer
    return ok_run, raw
  end
  return true, nil, run
end

--- The after-stage of the pipeline: every guard sees (name, input, result,
--- ok, ctx) in seq order; false blocks, a string replaces the result.
--- Returns result, ok.
function M.after_guards(name, input, result, ok, ctx)
  local block, replaced = run_guards("after", name, input, result, ok, ctx)
  if block then
    if not ok then
      local orig = tostring(result)
      if #orig > 200 then orig = orig:sub(1, 200) end
      block = block .. " (tool had already failed: " .. orig .. ")"
    end
    return block, false
  end
  return replaced, ok
end

-- Direct tool execution (hook bodies, tests, eval_lua): before-guards, no
-- confirm, no after-stage (no ctx/truncation to speak of). Raises with the
-- original error value on tool failure so pcall callers see what they see
-- today; level 0 keeps a second position prefix off string errors.
local function call_tool(name, ...)
  local input, ctx = ...
  local allowed, reason, run = M.gate_tool(name, input, ctx)
  if not allowed then error(reason, 0) end
  local ok, raw = run(ctx)
  if not ok then error(raw, 0) end
  return raw
end

--- Call an entry, looking it up at call time. Errors clearly if missing.
--- tool.* names go through the gate (before-guards); hook.*/fn.* are direct.
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
    error(("straps.registry: no entry named %q"):format(name))
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

--- Remove every grant on bufnr whose key starts with prefix ("" = all).
--- Returns the removed keys, sorted.
function M.clear_grants(bufnr, prefix)
  prefix = prefix or ""
  local set = grants[bufnr]
  local removed = {}
  if not set then return removed end
  for k in pairs(set) do
    if k:sub(1, #prefix) == prefix then
      removed[#removed + 1] = k
      set[k] = nil
    end
  end
  table.sort(removed)
  return removed
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
    error(("straps.registry.render: no entry named %q"):format(name))
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
