local M = {}
local uv = vim.uv
local definitions

local function defaults()
  if definitions then return definitions end
  definitions = {}
  local root = debug.getinfo(1, "S").source:sub(2):match("^(.*)/contextual_targets.lua$")
  for _, item in ipairs({ { "files", "register_tools" }, { "search", "register" }, { "exec", "register" } }) do
    local chunk = assert(loadfile(root .. "/layers/" .. item[1] .. ".lua"))
    setfenv(chunk, setmetatable({ require = function(name)
      assert(name == "straps.registry")
      return { define_default = function(entry) definitions[entry.name] = entry end }
    end }, { __index = _G }))
    chunk()[item[2]]()
  end
  return definitions
end

local function literal(path)
  if type(path) ~= "string" or path == "" or #path > 4096 or path:find("[%z\r\n$~*?%[%]{}\\]") then return false end
  for part in path:gmatch("[^/]+") do if part == ".." then return false end end
  return true
end

local function identity(path)
  local stat = uv.fs_stat(path)
  return stat and { dev = stat.dev, ino = stat.ino, type = stat.type } or nil
end

local function path_fact(path, cwd)
  if not literal(path) then return nil end
  local absolute = path:sub(1, 1) == "/" and path or cwd .. "/" .. path
  local ancestor, suffix = absolute, {}
  for _ = 1, 128 do
    local canonical = uv.fs_realpath(ancestor)
    if canonical then
      local stat = identity(canonical)
      if #suffix > 0 and (not stat or stat.type ~= "directory") then return nil end
      return { literal = path, absolute = absolute, canonical = canonical .. (#suffix > 0 and "/" .. table.concat(suffix, "/") or ""),
        ancestor = ancestor, ancestor_canonical = canonical, identity = stat, missing = #suffix > 0 }
    end
    if uv.fs_lstat(ancestor) then return nil end
    local parent, leaf = ancestor:match("^(.*)/([^/]+)/*$")
    if not parent or not leaf then return nil end
    table.insert(suffix, 1, leaf)
    ancestor = parent == "" and "/" or parent
  end
end

local function issue(record, field, reason)
  record.unresolved[#record.unresolved + 1] = { field = field, reason = reason }
end

local function add_path(record, field, path, cwd)
  if #record.known.paths >= 128 then issue(record, field, "path count exceeds 128"); return end
  local fact = path_fact(path, cwd)
  if not fact then issue(record, field, "path is not a bounded literal with a resolvable existing ancestor"); return end
  fact.field = field
  record.known.paths[#record.known.paths + 1] = fact
end

local shell_paths = { cat = true, ls = true, rm = true, touch = true, mkdir = true, cp = true, mv = true, rmdir = true }
local shell_output = { echo = true, printf = true, pwd = true, ["true"] = true, ["false"] = true }
local shell_options = { cat = { ["-n"] = true }, ls = { ["-a"] = true, ["-l"] = true, ["-la"] = true },
  rm = { ["-f"] = true, ["-r"] = true, ["-rf"] = true, ["-fr"] = true }, touch = {}, mkdir = { ["-p"] = true },
  cp = { ["-r"] = true, ["-f"] = true }, mv = { ["-f"] = true }, rmdir = {} }

local function shell(record, command, cwd)
  record.known.shell = { command = command, effects = {}, executables = {}, limit = "literal vocabulary only; shell startup, executable semantics and post-check filesystem races are not enforced" }
  if type(command) ~= "string" or #command > 8192 or command == "" or command:find("[^%w%s_./:%-;&|>]")
      or command:find("[\r\n]") then issue(record, "command", "unrecognized shell syntax or executable content"); return end
  local normalized = command:gsub("&&", " ; "):gsub("%|%|", " ; "):gsub("|", " ; ")
  if normalized:find("&", 1, true) then issue(record, "command", "background execution is unresolved"); return end
  local segments = 0
  for segment in (normalized .. ";"):gmatch("(.-);") do
    segments = segments + 1
    if segments > 32 then issue(record, "command", "shell segment count exceeds 32"); return end
    local words = {}
    segment = segment:gsub(">>", " > "):gsub(">", " > ")
    for word in segment:gmatch("%S+") do words[#words + 1] = word end
    local program = words[1]
    if not program or not (shell_paths[program] or shell_output[program]) then
      issue(record, "command", "unknown command effects or hidden executable targets")
    else
      record.known.shell.effects[#record.known.shell.effects + 1] = { program = program, arguments = vim.list_slice(words, 2) }
      if shell_paths[program] then
        issue(record, "command", "external executable semantics and shell resolution are untrusted")
        local executable = vim.fn.exepath(program)
        local fact = executable ~= "" and path_fact(executable, cwd) or nil
        if not fact then issue(record, "command", "executable resolution unavailable")
        else
          fact.program = program
          local stat = uv.fs_stat(fact.canonical)
          fact.size, fact.mtime = stat and stat.size, stat and stat.mtime
          record.known.shell.executables[#record.known.shell.executables + 1] = fact
        end
      end
      local operands, redirect, options = 0, false, true
      for index = 2, #words do
        local word = words[index]
        if word == ">" then
          if redirect then issue(record, "command", "redirection target missing") end
          redirect = true
        elseif redirect then
          add_path(record, "command.redirect", word, cwd)
          redirect = false
        elseif shell_output[program] and word:sub(1, 1) == "-" then
          issue(record, "command", "shell builtin options may mutate ambient execution state")
        elseif shell_paths[program] and word == "--" and options then
          options = false
        elseif shell_paths[program] and (not options or word:sub(1, 1) ~= "-") then
          operands = operands + 1
          add_path(record, "command.argument", word, cwd)
        elseif shell_paths[program] and word ~= "--" and not shell_options[program][word] then
          issue(record, "command", "unrecognized command option may change material targets")
        end
      end
      if redirect then issue(record, "command", "redirection target missing") end
      if shell_paths[program] and operands == 0 then
        if program == "ls" then add_path(record, "command.argument", ".", cwd)
        else issue(record, "command", "material path operands unavailable") end
      end
    end
  end
end

function M.resolve(binding)
  local record = { known = { paths = {} }, unresolved = {}, checks = {} }
  if type(binding) ~= "table" or type(binding.definition) ~= "table" or type(binding.input) ~= "table" then
    issue(record, "binding", "exact frozen binding unavailable")
    return record
  end
  record.checks.binding = vim.deepcopy(binding)
  record.known.session = { session = binding.session, session_id = binding.session_id, task_id = binding.task_id, scope = binding.scope }
  local account = uv.os_get_passwd()
  record.known.account = account and { uid = account.uid, gid = account.gid, username = account.username } or nil
  if not record.known.account then issue(record, "account", "process account unavailable") end
  local cwd = binding.cwd
  if not literal(cwd) or cwd:sub(1, 1) ~= "/" or cwd ~= vim.fn.getcwd() then
    issue(record, "cwd", "frozen execution directory unavailable or changed")
    return record
  end
  record.known.cwd = path_fact(cwd, cwd)
  if not record.known.cwd then issue(record, "cwd", "execution directory cannot be resolved") end
  local definition = binding.definition
  local expected = defaults()[definition.name]
  if not expected or definition.kind ~= "tool" or definition.source ~= expected.source
      or not vim.deep_equal(definition.input_schema, expected.input_schema) then
    issue(record, "definition", "custom or changed executable definition has unrecognized material targets; public metadata is untrusted")
    return record
  end
  local name, input = definition.name, binding.input
  if name == "tool.bash" or name == "tool.run_in_terminal" or name == "tool.run_quickfix" then
    if cwd ~= vim.fn.getcwd(-1, -1) then issue(record, "cwd", "shell global execution directory differs from frozen directory") end
    shell(record, input.command, cwd)
  elseif name == "tool.read_file" or name == "tool.write_file" or name == "tool.edit_file" or name == "tool.patch_file"
      or name == "tool.tree" or name == "tool.grep" then
    add_path(record, "path", input.path or ((name == "tool.tree" or name == "tool.grep") and "." or nil), cwd)
  elseif name == "tool.path_info" and type(input.paths) == "table" then
    local count = 0
    for key, path in pairs(input.paths) do
      count = count + 1
      if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or count > 128 then issue(record, "paths", "invalid or oversized path array"); break end
      add_path(record, "paths." .. key, path, cwd)
    end
    table.sort(record.known.paths, function(a, b) return a.field < b.field end)
    if count == 0 then issue(record, "paths", "no paths supplied") end
  else
    issue(record, "input", "tool target semantics are outside the bounded literal resolver")
  end
  return record
end

function M.validate(record, binding, options)
  if type(record) ~= "table" or type(record.checks) ~= "table" or not vim.deep_equal(record.checks.binding, binding) then
    return false, "exact frozen target binding changed"
  end
  local allow_unresolved = type(options) == "table" and options.allow_unresolved == true
  if type(record.unresolved) ~= "table" or not allow_unresolved and next(record.unresolved) ~= nil then return false, "unresolved material targets" end
  local current = M.resolve(binding)
  if not allow_unresolved and next(current.unresolved) ~= nil or not vim.deep_equal(record, current) then
    return false, "relied-upon target facts changed"
  end
  return true
end

defaults()
return M
