-- straps/layers/selfext.lua — the SELF-EXTENSION layer: registry inspection
-- and (re)definition (registry_list/get/define), skill loading, eval_lua.
-- Future prompt-fragment slot: fn.system_prompt_layer.selfext.

local M = {}

function M.register()
  local registry = require("straps.registry")
  local define = registry.define_default

  -- ------------------------------------------------------------ registry_list

  define({
    name = "tool.registry_list",
    kind = "tool",
    doc = "List all registry entries visible to THIS session (global plus"
      .. " session-scoped shadows), one per line formatted as"
      .. " 'name (kind, vN[, session]): first line of doc'. The version N"
      .. " increments each time an entry is redefined; a 'session' tag marks"
      .. " entries scoped to this session. Parameters: kind (optional) —"
      .. " filter to only 'tool', 'hook', or 'fn' entries.",
    input_schema = {
      type = "object",
      properties = {
        kind = {
          type = "string",
          enum = { "tool", "hook", "fn" },
          description = "Only list entries of this kind.",
        },
      },
      required = {},
    },
    source = [==[
return function(input, ctx)
  local registry = require("straps.registry")
  local lines = {}
  for _, name in ipairs(registry.names(input and input.kind or nil)) do
    local e = registry.get(name)
    if e then
      local doc = tostring(e.doc or ""):match("^[^\n]*") or ""
      lines[#lines + 1] = string.format("%s (%s, v%d%s): %s",
        e.name, e.kind, e.version or 1, e.scope and ", session" or "", doc)
    end
  end
  if #lines == 0 then
    return "no registry entries" .. (input and input.kind and (" of kind " .. input.kind) or "")
  end
  return table.concat(lines, "\n")
end
]==],
  })

  -- ------------------------------------------------------------- registry_get

  define({
    name = "tool.registry_get",
    kind = "tool",
    doc = "Fetch the full definition of one registry entry as an executable Lua"
      .. " chunk: a require('straps.registry').define{...} call including doc,"
      .. " input_schema, and the complete Lua source. Use this to inspect how"
      .. " any tool/hook/fn works before redefining it. Parameters: name"
      .. " (required) — full entry name, e.g. 'tool.write_file' or 'hook.confirm'.",
    input_schema = {
      type = "object",
      properties = {
        name = { type = "string", description = "Full registry entry name, e.g. 'tool.bash'." },
      },
      required = { "name" },
    },
    source = [==[
return function(input, ctx)
  local registry = require("straps.registry")
  if not registry.get(input.name) then
    error("registry_get: no entry named " .. tostring(input.name))
  end
  return registry.render(input.name)
end
]==],
  })

  -- ---------------------------------------------------------- registry_define

  define({
    name = "tool.registry_define",
    kind = "tool",
    doc = "Call this whenever something learned should persist beyond the"
      .. " current exchange — define or redefine a registry entry, THE"
      .. " self-extension tool. An extension (tool/hook/fn) is capability:"
      .. " define one when you need to become more capable at doing something."
      .. " A skill is knowledge, not capability: define one to store prose you"
      .. " will want loaded before doing something again. New tools become"
      .. " callable on your next turn; redefinitions of existing"
      .. " tools/hooks/fns (including the provider and hook.confirm) take effect"
      .. " on the very next call. Parameters: name (required) — full name like"
      .. " 'tool.run_tests', 'hook.after_write', 'fn.provider', or"
      .. " 'skill.release_process'; for tools the"
      .. " part after 'tool.' is the API name and must match ^[a-zA-Z0-9_-]+$;"
      .. " kind (required) — 'tool', 'hook', 'fn', or 'skill'; doc (optional) — for tools"
      .. " this is the LLM-facing description, for skills the one-line trigger"
      .. " ('when to load this'); input_schema (optional, tools only) — JSON"
      .. " Schema for the tool's input, passed as a JSON-encoded STRING (e.g."
      .. " '{\"type\":\"object\",\"properties\":{...},\"required\":[...]}');"
      .. " source (required) — for tool/hook/fn, Lua source whose chunk returns"
      .. " function(input, ctx); for skills, the prose body itself (no Lua);"
      .. " scope (optional, default 'session') —"
      .. " 'session' entries exist only for THIS session (and its subagents),"
      .. " shadow any global entry of the same name, and vanish when the"
      .. " session closes; 'global' affects every session in this Neovim —"
      .. " use it only when the user asked for that. Persist an entry across"
      .. " Neovim restarts by appending its registry_get rendering to"
      .. " .straps.lua. Returns 'defined <name> v<version> (scope)'.",
    input_schema = {
      type = "object",
      properties = {
        name = { type = "string", description = "Full entry name, e.g. 'tool.run_tests'." },
        kind = { type = "string", enum = { "tool", "hook", "fn", "skill" }, description = "Entry kind." },
        doc = { type = "string", description = "Description; for tools the LLM-facing tool description, for skills the one-line load trigger." },
        input_schema = { type = "string", description = "JSON Schema for tool input, as a JSON string (tools only)." },
        source = { type = "string", description = "tool/hook/fn: Lua source whose chunk returns function(input, ctx). skill: the prose body itself." },
        scope = { type = "string", enum = { "session", "global" }, description = "Entry scope (default 'session')." },
      },
      required = { "name", "kind", "source" },
    },
    source = [==[
return function(input, ctx)
  local registry = require("straps.registry")
  local kind = input.kind
  if kind ~= "tool" and kind ~= "hook" and kind ~= "fn" and kind ~= "skill" then
    error("registry_define: kind must be 'tool', 'hook', 'fn', or 'skill' (got " .. tostring(kind) .. ")")
  end
  local schema = nil
  if input.input_schema ~= nil and input.input_schema ~= "" then
    if type(input.input_schema) ~= "string" then
      error("registry_define: input_schema must be a JSON-encoded string")
    end
    local ok, decoded = pcall(vim.json.decode, input.input_schema)
    if not ok then
      error("registry_define: input_schema is not valid JSON: " .. tostring(decoded))
    end
    schema = decoded
  end
  local opts = nil
  if input.scope == "global" then
    opts = { scope = "global" }
  end
  -- Default (no scope / "session"): registry.define writes to the active
  -- session scope — invisible to other sessions, gone when this one closes.
  local entry = registry.define({
    name = input.name,
    kind = kind,
    doc = input.doc,
    input_schema = schema,
    source = input.source,
  }, opts)
  local result = "defined " .. entry.name .. " v" .. tostring(entry.version)
    .. (entry.scope and " (session scope — shadows global, dies with this session)"
      or " (global scope — all sessions)")
  -- Warn (never refuse) when a new tool's source appears to block Neovim's
  -- main loop: :wait()/vim.wait/vim.fn.system freeze the transcript and
  -- prevent :StrapsStop from running for the call's whole duration.
  if kind == "tool" and type(input.source) == "string" then
    local blocking = input.source:find(":wait%s*%(")
      or input.source:find("vim%.wait")
      or input.source:find("vim%.fn%.system")
    if blocking then
      result = result .. "\nwarning: this tool source appears to call a blocking wait"
        .. " (vim.system():wait(), vim.wait, or vim.fn.system). These block Neovim's"
        .. " main loop for their whole duration — the transcript freezes and"
        .. " :StrapsStop cannot run. Do subprocess/timer work through ctx.await instead."
    end
  end
  return result
end
]==],
  })

  -- -------------------------------------------------------------------- skill

  define({
    name = "tool.skill",
    kind = "tool",
    doc = "Load a skill — a named piece of stored knowledge (prose) — into"
      .. " the conversation. Skills that existed at session start are listed"
      .. " under '# Skills' in the system prompt; call with no name to list"
      .. " every skill currently defined, including ones defined mid-session."
      .. " Parameters: name (optional) — the skill to load, with or without"
      .. " the 'skill.' prefix; omit to list.",
    input_schema = {
      type = "object",
      properties = {
        name = {
          type = "string",
          description = "Skill to load, e.g. 'release_process' or 'skill.release_process'. Omit to list all skills.",
        },
      },
    },
    source = [==[
return function(input, ctx)
  local registry = require("straps.registry")
  local name = input and input.name
  if name == nil or name == "" then
    local lines = {}
    for _, n in ipairs(registry.names("skill")) do
      local e = registry.get(n)
      local doc = tostring(e.doc or ""):match("^[^\n]*") or ""
      lines[#lines + 1] = n .. (doc ~= "" and (": " .. doc) or "")
    end
    if #lines == 0 then
      return "no skills defined"
    end
    return table.concat(lines, "\n")
  end
  local entry = registry.get(name)
  if not (entry and entry.kind == "skill") then
    entry = registry.get("skill." .. name)
  end
  if not entry or entry.kind ~= "skill" then
    return "skill: no skill named " .. tostring(name) .. " (call with no name to list)"
  end
  return entry.source
end
]==],
  })

  -- ----------------------------------------------------------------- eval_lua

  define({
    name = "tool.eval_lua",
    kind = "tool",
    doc = "Evaluate Lua code inside the running Neovim instance, with full"
      .. " access to vim.* and the straps modules. The code is compiled with"
      .. " load() and run under pcall; use 'return <expr>' to produce output."
      .. " Results are formatted for legibility: a returned string prints"
      .. " verbatim; a flat list/array prints one element per line (numbered);"
      .. " other tables fall back to vim.inspect. Multiple return values are"
      .. " shown in order. Dangerous by design — gated by hook.confirm."
      .. " Parameters: code (required) — a Lua chunk.",
    input_schema = {
      type = "object",
      properties = {
        code = { type = "string", description = "Lua chunk to evaluate; use 'return ...' to produce output." },
      },
      required = { "code" },
    },
    source = [==[
return function(input, ctx)
  local chunk, err = load(input.code, "straps:eval_lua")
  if not chunk then
    return "load error: " .. tostring(err)
  end
  local function pack(...) return { n = select("#", ...), ... } end
  local res = pack(pcall(chunk))
  if not res[1] then
    return "error: " .. tostring(res[2])
  end
  if res.n <= 1 then
    return "nil"
  end

  local islist = vim.islist or vim.tbl_islist

  -- Is this a "flat" list — a pure array whose elements are all scalars
  -- (string/number/boolean)? Those read badly under vim.inspect (a wall of
  -- quoted, comma-joined items), so we render them one per line instead.
  local function is_flat_list(v)
    if type(v) ~= "table" or not islist(v) then
      return false
    end
    for _, item in ipairs(v) do
      local t = type(item)
      if t ~= "string" and t ~= "number" and t ~= "boolean" then
        return false
      end
    end
    return true
  end

  -- Format one returned value:
  --   string     -> verbatim (no surrounding quotes / escaping)
  --   flat list  -> one element per line, "  N | value"
  --   everything -> vim.inspect
  local function format_value(v)
    if type(v) == "string" then
      return v
    elseif is_flat_list(v) then
      if #v == 0 then
        return "{} (empty list)"
      end
      local out = {}
      local width = #tostring(#v)
      for i, item in ipairs(v) do
        local num = string.format("%" .. width .. "d", i)
        local shown = type(item) == "string" and item or vim.inspect(item)
        out[#out + 1] = "  " .. num .. " | " .. shown
      end
      return table.concat(out, "\n")
    else
      return vim.inspect(v)
    end
  end

  local parts = {}
  for i = 2, res.n do
    local formatted = format_value(res[i])
    -- With more than one return value, label each so they don't run together
    -- ambiguously (especially when a value is a multi-line block).
    if res.n > 2 then
      parts[#parts + 1] = ("-- value %d --\n%s"):format(i - 1, formatted)
    else
      parts[#parts + 1] = formatted
    end
  end
  return table.concat(parts, "\n")
end
]==],
  })
end

return M
