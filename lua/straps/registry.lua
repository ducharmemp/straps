-- straps.registry: the late-bound registry (heart of the plugin).
-- Entries are Lua source strings compiled on define and looked up by name at
-- every call site, so redefining an entry takes effect on the very next call.

local M = {}

-- name -> { name, kind, doc, input_schema, source, fn, version, seq, scope }
-- This is the GLOBAL scope. scope on an entry is the owning bufnr, or nil
-- for global entries.
M.entries = {}

-- Session overlays, vim's :set/:setlocal split applied to the registry:
-- bufnr -> { entries = {}, parent = bufnr|nil }. Lookups made while a
-- scope is ACTIVE resolve child -> parent -> ... -> global; defines made
-- while a scope is active land in that scope unless told otherwise. A
-- session's experiments shadow the world without mutating it, and die
-- with the buffer.
M.scopes = {}

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

--- Create (or fetch) the overlay for bufnr. parent, when given, chains this
--- scope under another buffer's scope (subagents chain under their spawner).
--- The overlay is dropped automatically when the buffer is wiped out.
function M.ensure_scope(bufnr, parent)
  local s = M.scopes[bufnr]
  if not s then
    s = { entries = {}, parent = parent }
    M.scopes[bufnr] = s
    pcall(vim.api.nvim_create_autocmd, "BufWipeout", {
      buffer = bufnr,
      once = true,
      callback = function() M.scopes[bufnr] = nil end,
    })
  elseif parent ~= nil then
    s.parent = parent
  end
  return s
end

-- Resolve name through a scope chain starting at buf, falling back to
-- global. Hop cap guards against accidental parent cycles.
local function resolve_in(buf, name)
  local hops = 0
  while buf and hops < 8 do
    local s = M.scopes[buf]
    if not s then break end
    local e = s.entries[name]
    if e then return e end
    buf = s.parent
    hops = hops + 1
  end
  return M.entries[name]
end

local function resolve(name)
  return resolve_in(active, name)
end

-- The merged view of the active chain: global entries overlaid root-first
-- so the leaf scope's shadows win. name -> entry.
local function merged_entries()
  local chain = {}
  local buf, hops = active, 0
  while buf and M.scopes[buf] and hops < 8 do
    chain[#chain + 1] = M.scopes[buf]
    buf = M.scopes[buf].parent
    hops = hops + 1
  end
  local out = {}
  for name, e in pairs(M.entries) do out[name] = e end
  for i = #chain, 1, -1 do
    for name, e in pairs(chain[i].entries) do out[name] = e end
  end
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

--- Define (or redefine) an entry. Raises on invalid spec or bad source; the
--- previous entry, if any, is left untouched on failure.
--- Scope targeting (opts.scope):
---   nil       -> the ACTIVE scope if one is set (i.e. defines made inside a
---                run are session-scoped by default), else global
---   "global"  -> the global registry, regardless of active scope
---   <bufnr>   -> that buffer's overlay (created as needed)
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
  local scope_opt = opts and opts.scope
  local target, scope_buf
  if scope_opt == "global" or (scope_opt == nil and active == nil) then
    target, scope_buf = M.entries, nil
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
    fn = fn,
    version = (prev and prev.version or 0) + 1,
    seq = seq,
    scope = scope_buf,
  }
  target[spec.name] = entry

  local on_define = resolve("hook.on_define")
  if on_define then
    pcall(on_define.fn, entry) -- never let the hook break define
  end
  return entry
end

--- Define only if the name is absent GLOBALLY; used for builtin defaults so
--- re-running setup() never clobbers user redefinitions. Always global —
--- builtins are the root of every scope chain.
function M.define_default(spec)
  if M.entries[spec.name] then
    return M.entries[spec.name]
  end
  return M.define(spec, { scope = "global" })
end

--- Resolve name through the active scope chain, falling back to global.
function M.get(name)
  return resolve(name)
end

--- Call an entry, looking it up at call time. Errors clearly if missing.
function M.call(name, ...)
  local entry = resolve(name)
  if not entry then
    error(("straps.registry: no entry named %q"):format(name))
  end
  return entry.fn(...)
end

--- Like call, but returns nil if the entry does not exist (optional hooks).
--- Errors inside the fn still propagate.
function M.try_call(name, ...)
  local entry = resolve(name)
  if not entry then
    return nil
  end
  return entry.fn(...)
end

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

function M.remove(name)
  M.entries[name] = nil
end

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
  parts[#parts + 1] = ("  source = [%s[\n%s]%s],"):format(eq, e.source, eq)
  parts[#parts + 1] = "}"
  return table.concat(parts, "\n")
end

--- Every GLOBAL entry rendered and concatenated; executing the result
--- restores the global registry. Ordered by seq so a restore re-registers
--- entries in the original order — preserving the append-only tool ordering
--- across sessions. Session overlays are deliberately excluded: they are
--- ephemeral by design (persist one with render() into .straps.lua).
function M.dump()
  local names = {}
  for name in pairs(M.entries) do
    names[#names + 1] = name
  end
  table.sort(names, function(a, b)
    return M.entries[a].seq < M.entries[b].seq
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
