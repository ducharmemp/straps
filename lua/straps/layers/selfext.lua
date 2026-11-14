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
      .. " filter to only 'tool', 'hook', 'fn', or 'skill' entries.",
    input_schema = {
      type = "object",
      properties = {
        kind = {
          type = "string",
          enum = { "tool", "hook", "fn", "skill" },
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
    error("registry_get: no entry named " .. tostring(input.name), 0)
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
    error("registry_define: kind must be 'tool', 'hook', 'fn', or 'skill' (got " .. tostring(kind) .. ")", 0)
  end
  local schema = nil
  if input.input_schema ~= nil and input.input_schema ~= "" then
    if type(input.input_schema) ~= "string" then
      error("registry_define: input_schema must be a JSON-encoded string", 0)
    end
    local ok, decoded = pcall(vim.json.decode, input.input_schema)
    if not ok then
      error("registry_define: input_schema is not valid JSON: " .. tostring(decoded), 0)
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
  -- Warn (never refuse) when new tool/hook/fn source appears to block Neovim's
  -- main loop: :wait()/vim.wait/vim.fn.system freeze the transcript and
  -- prevent :StrapsStop from running for the call's whole duration.
  if kind ~= "skill" and type(input.source) == "string" then
    local blocking = input.source:find(":wait%s*%(")
      or input.source:find("vim%.wait")
      or input.source:find("vim%.fn%.system")
    if blocking then
      result = result .. "\nwarning: this " .. kind .. " source appears to call a blocking wait"
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
      .. " every skill available now: registry skill.* entries, including ones"
      .. " defined mid-session, plus SKILL.md files found on disk (listed with"
      .. " '(file: <path>)'). Parameters: name (optional) — the skill to load,"
      .. " with or without the 'skill.' prefix; omit to list.",
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
  local uv = vim.uv or vim.loop
  local function discovered()
    local ok, found = pcall(registry.try_call, "fn.discover_skills")
    local out = { skills = {}, order = {} }
    if ok and type(found) == "table" and type(found.skills) == "table" and type(found.order) == "table" then
      for _, n in ipairs(found.order) do
        local s = found.skills[n]
        if type(n) == "string" and type(s) == "table" and type(s.path) == "string"
            and type(s.dir) == "string" and type(s.description) == "string" then
          out.skills[n] = s
          out.order[#out.order + 1] = n
        end
      end
    end
    return out
  end
  local name = input and input.name
  if name == nil or name == "" then
    local lines = {}
    for _, n in ipairs(registry.names("skill")) do
      local e = registry.get(n)
      local doc = tostring(e.doc or ""):match("^[^\n]*") or ""
      lines[#lines + 1] = n .. (doc ~= "" and (": " .. doc) or "")
    end
    local found = discovered()
    for _, n in ipairs(found.order) do
      local s = found.skills[n]
      if s and not registry.get("skill." .. n) then
        lines[#lines + 1] = n .. " (file: " .. s.path .. "): " .. s.description
      end
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
  if entry and entry.kind == "skill" then
    return entry.source
  end
  local bare = tostring(name):gsub("^skill%.", "")
  local s = discovered().skills[bare]
  if not s then
    return "skill: no skill named " .. tostring(name)
      .. " (call with no name to list; discovery cwd: " .. vim.fn.getcwd() .. ")"
  end
  local f = io.open(s.path, "r")
  if not f then
    return "skill: could not read " .. s.path
  end
  local text = f:read("*a")
  f:close()
  text = text:gsub("^\239\187\191", ""):gsub("\r", "")
  local lines = vim.split(text, "\n", { plain = true })
  local first = 1
  if lines[1] and lines[1]:match("^%-%-%-%s*$") then
    for i = 2, #lines do
      if lines[i]:match("^%-%-%-%s*$") then
        first = i + 1
        break
      end
    end
  end
  local body = table.concat(lines, "\n", first):gsub("^%s+", ""):gsub("%s+$", "")

  local files, walked, capped, LIMIT, WALK_CAP = {}, 0, false, 50, 2000
  local prefix = s.dir == "/" and "/" or s.dir .. "/"
  local function walk(dir, rel, depth)
    local handle = uv.fs_scandir(dir)
    if not handle then return end
    while true do
      local entry_name, typ = uv.fs_scandir_next(handle)
      if not entry_name then break end
      if walked >= WALK_CAP then
        capped = true
        break
      end
      walked = walked + 1
      local full = dir .. "/" .. entry_name
      local relpath = rel == "" and entry_name or (rel .. "/" .. entry_name)
      if typ == nil or typ == "unknown" then
        local lst = uv.fs_lstat(full)
        typ = lst and lst.type
      end
      if relpath == "SKILL.md" then
      elseif typ == "link" then
        local target = uv.fs_realpath(full)
        local st = target and uv.fs_stat(target)
        if target and st and st.type == "file" and target:sub(1, #prefix) == prefix then
          files[#files + 1] = relpath
        end
      elseif typ == "directory" then
        if entry_name ~= ".git" and entry_name ~= "node_modules" and depth < 3 then
          walk(full, relpath, depth + 1)
        end
      elseif typ == "file" then
        files[#files + 1] = relpath
      end
    end
  end
  walk(s.dir, "", 1)
  table.sort(files)

  local out = { body, "", "Skill file: " .. s.path, "Skill directory: " .. s.dir,
    "Relative paths in this skill resolve against that directory." }
  if #files > 0 then
    out[#out + 1] = "Bundled files (listed, not loaded):"
    for i = 1, math.min(#files, LIMIT) do
      out[#out + 1] = "  " .. files[i]
    end
    if #files > LIMIT or capped then
      out[#out + 1] = "  (listing truncated)"
    end
  end
  return table.concat(out, "\n")
end
]==],
  })

  define({
    name = "fn.discover_skills",
    kind = "fn",
    doc = "Find SKILL.md skills on disk (user, project, config.skill_paths roots); returns { skills, order, diagnostics }.",
    source = [==[
return function()
  local uv = vim.uv or vim.loop
  local ok_straps, straps = pcall(require, "straps")
  local config = (ok_straps and type(straps) == "table" and rawget(straps, "config")) or {}
  local result = { skills = {}, order = {}, diagnostics = {} }
  if config.skill_discovery == false then
    return result
  end
  local function diag(msg)
    result.diagnostics[#result.diagnostics + 1] = msg
  end

  local function parse(text)
    text = text:gsub("^\239\187\191", ""):gsub("\r", "")
    local lines = vim.split(text, "\n", { plain = true })
    if not (lines[1] and lines[1]:match("^%-%-%-%s*$")) then
      return nil
    end
    local fields, i, closed = {}, 2, false
    while i <= #lines do
      local line = lines[i]
      if line:match("^%-%-%-%s*$") then
        closed = true
        break
      end
      local key, value = line:match("^([%w_%-]+):%s*(.-)%s*$")
      if key then
        local parts = {}
        local style = value:match("^[>|][%-+]?%d?[%-+]?$")
        if not style and value ~= "" then parts[1] = value end
        while lines[i + 1] and (lines[i + 1]:match("^%s+%S") or lines[i + 1]:match("^%s*$"))
            and not lines[i + 1]:match("^%-%-%-%s*$") do
          i = i + 1
          local piece = lines[i]:match("^%s*(.-)%s*$")
          if piece ~= "" then parts[#parts + 1] = piece end
        end
        if style then
          fields[key] = table.concat(parts, " ")
        elseif value == "" and #parts > 0 and parts[1]:match("^[%w_%-]+:") then
          fields[key] = ""
        else
          value = table.concat(parts, " ")
          local q = value:sub(1, 1)
          if (q == '"' or q == "'") and #value >= 2 and value:sub(-1) == q then
            value = value:sub(2, -2)
          end
          fields[key] = value
        end
      end
      i = i + 1
    end
    if not closed then
      return nil
    end
    return fields
  end

  local function read_head(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local chunks, n = {}, 0
    for line in f:lines() do
      if n >= 400 then
        f:close()
        return nil, true
      end
      n = n + 1
      chunks[n] = line
      local bare = line:gsub("\r$", "")
      if n == 1 and not bare:gsub("^\239\187\191", ""):match("^%-%-%-%s*$") then break end
      if n > 1 and bare:match("^%-%-%-%s*$") then break end
    end
    f:close()
    return table.concat(chunks, "\n")
  end

  local function scan_root(root)
    local real_root = uv.fs_realpath(root)
    if not real_root then return end
    local handle = uv.fs_scandir(real_root)
    if not handle then return end
    local dirs = {}
    while true do
      local entry, typ = uv.fs_scandir_next(handle)
      if not entry then break end
      if typ == nil or typ == "unknown" then
        local lst = uv.fs_lstat(real_root .. "/" .. entry)
        typ = lst and lst.type
      end
      if typ == "directory" or typ == "link" then dirs[#dirs + 1] = entry end
    end
    table.sort(dirs)
    for _, entry in ipairs(dirs) do
      local dir = uv.fs_realpath(real_root .. "/" .. entry)
      local st = dir and uv.fs_stat(dir)
      local skill_md = st and st.type == "directory" and uv.fs_realpath(dir .. "/SKILL.md")
      local md_stat = skill_md and uv.fs_stat(skill_md)
      if skill_md then
        local prefix = dir == "/" and "/" or dir .. "/"
        if skill_md:find("%c") then
          diag(vim.inspect(skill_md) .. ": path contains a control character; skipped")
        elseif skill_md:sub(1, #prefix) ~= prefix then
          diag(root .. "/" .. entry .. "/SKILL.md resolves outside its skill directory (" .. skill_md .. "); skipped")
        elseif not (md_stat and md_stat.type == "file") then
          diag(skill_md .. ": not a regular file; skipped")
        else
          local head, too_long = read_head(skill_md)
          local fields = parse(head or "")
          if too_long then
            diag(skill_md .. ": frontmatter longer than 400 lines; skipped")
          elseif not fields then
            diag(skill_md .. ": no YAML frontmatter; skipped")
          elseif not fields.description or fields.description == "" then
            diag(skill_md .. ": empty or missing description; skipped")
          else
            local name = fields.name
            if not name or name == "" then
              name = entry
              diag(skill_md .. ": missing name; using directory name " .. entry)
            end
            if not name:match("^[%w_][%w_%-]*$") then
              diag(skill_md .. ": name " .. name .. " has characters outside [A-Za-z0-9_-]; skipped")
            else
              if name ~= entry then
                diag(skill_md .. ": name " .. name .. " does not match directory " .. entry)
              end
              if #name > 64 or name:find("[^a-z0-9%-]") then
                diag(skill_md .. ": name " .. name .. " breaks the spec (lowercase a-z, 0-9, '-', at most 64 chars)")
              end
              if #fields.description > 1024 then
                diag(skill_md .. ": description is longer than the spec's 1024 characters")
              end
              local prev = result.skills[name]
              if prev and prev.path ~= skill_md then
                diag("skill " .. name .. ": " .. skill_md .. " shadows " .. prev.path)
              end
              result.skills[name] = {
                name = name,
                description = (fields.description:gsub("%c", " "):gsub("%s+", " ")),
                path = skill_md,
                dir = dir,
              }
            end
          end
        end
      end
    end
  end

  local function configured(key, p)
    if type(p) ~= "string" or p == "" then
      diag("config." .. key .. " has a " .. type(p) .. " entry; expected a non-empty path string")
      return nil
    end
    local abs = vim.fn.fnamemodify(p, ":p")
    return #abs > 1 and abs:gsub("/$", "") or abs
  end
  for _, key in ipairs({ "skill_roots", "skill_paths" }) do
    if config[key] ~= nil and type(config[key]) ~= "table" then
      diag("config." .. key .. " is a " .. type(config[key]) .. "; expected a list of paths")
    end
  end

  local home = uv.os_homedir()
  local roots = {}
  if type(config.skill_roots) == "table" then
    for _, r in ipairs(config.skill_roots) do roots[#roots + 1] = configured("skill_roots", r) end
  elseif home and home ~= "" then
    roots[#roots + 1] = home .. "/.agents/skills"
    roots[#roots + 1] = home .. "/.claude/skills"
    roots[#roots + 1] = vim.fn.stdpath("config") .. "/straps/skills"
  end

  local real_home = home and uv.fs_realpath(home)
  local cwd = uv.fs_realpath(vim.fn.getcwd()) or vim.fn.getcwd()
  local chain, dir = {}, cwd
  local below_home = real_home ~= nil and (cwd == real_home or cwd:sub(1, #real_home + 1) == real_home .. "/")
  while dir and dir ~= "" do
    if below_home and dir == real_home then break end
    table.insert(chain, 1, dir)
    local parent = vim.fs.dirname(dir)
    if not parent or parent == dir then break end
    dir = parent
  end
  for _, d in ipairs(chain) do
    local base = d == "/" and "" or d
    roots[#roots + 1] = base .. "/.agents/skills"
    roots[#roots + 1] = base .. "/.claude/skills"
  end
  if type(config.skill_paths) == "table" then
    for _, p in ipairs(config.skill_paths) do roots[#roots + 1] = configured("skill_paths", p) end
  end

  for _, root in ipairs(roots) do
    scan_root(root)
  end
  for name in pairs(result.skills) do
    result.order[#result.order + 1] = name
  end
  table.sort(result.order)
  return result
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
