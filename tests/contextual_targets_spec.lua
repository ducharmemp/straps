local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(here, ":p:h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. package.path

local targets, registry, directory, previous
local function binding(name, input)
  return { session = 7, session_id = "session", task_id = "task", epoch = 1, scope = 7,
    cwd = vim.fn.getcwd(), definition = registry.get("tool." .. name), input = input, call_id = 3 }
end
local function resolved(value)
  local record = targets.resolve(value)
  assert.same({}, record.unresolved)
  return record
end
before_each(function()
  previous = vim.fn.getcwd()
  directory = vim.fn.tempname()
  vim.fn.mkdir(directory .. "/one", "p")
  vim.fn.mkdir(directory .. "/two", "p")
  vim.api.nvim_set_current_dir(directory)
  package.loaded["straps.registry"] = nil
  package.loaded["straps.contextual_targets"] = nil
  registry = require("straps.registry")
  require("straps.layers.files").register_tools()
  require("straps.layers.search").register()
  require("straps.layers.exec").register()
  local mutant = vim.env.STRAPS_TARGET_MUTANT
  if mutant and mutant ~= "" then
    local changes = {
      binding = { 'or not vim.deep_equal(record.checks.binding, binding)', 'or false' },
      facts = { 'or not vim.deep_equal(record, current)', 'or false' },
      cwd = { 'or cwd ~= (type(opts) == "table" and opts.cwd or vim.fn.getcwd())', 'or false' },
      optscwd = { '(type(opts) == "table" and opts.cwd or vim.fn.getcwd())', 'vim.fn.getcwd()' },
      optstype = { 'type(opts) == "table" and opts.cwd', 'opts and opts.cwd' },
      custom = { 'definition.source ~= expected.source', 'false' },
      shell = { 'if not program or not (shell_paths[program] or shell_output[program]) then', 'if false then' },
      options = { 'shell_output[program] and word:sub(1, 1) == "-"', 'false' },
      terminator = { 'options = false', 'options = true' },
      globalcwd = { 'if cwd ~= vim.fn.getcwd(-1, -1) then', 'if false then' },
      unresolved = { 'if type(record.unresolved) ~= "table" or not allow_unresolved and next(record.unresolved) ~= nil then', 'if false then' },
      explicit_unresolved = { 'type(options) == "table" and options.allow_unresolved == true', 'true' },
      reject_unresolved = { 'type(options) == "table" and options.allow_unresolved == true', 'false' },
      override_facts = { 'or not vim.deep_equal(record, current)', 'or not allow_unresolved and not vim.deep_equal(record, current)' },
      external = { 'issue(record, "command", "external executable semantics and shell resolution are untrusted")', '' },
      path_short = { '#path > 4096', '#path >= 4096' },
      path_long = { '#path > 4096', '#path > 4097' },
      ancestor_short = { 'for _ = 1, 128 do', 'for _ = 1, 127 do' },
      ancestor_long = { 'for _ = 1, 128 do', 'for _ = 1, 129 do' },
      paths_short = { 'count > 128', 'count >= 128' },
      paths_long = { 'count > 128', 'count > 129' },
      add_paths_long = { '#record.known.paths >= 128', '#record.known.paths >= 129' },
      command_short = { '#command > 8192', '#command >= 8192' },
      command_long = { '#command > 8192', '#command > 8193' },
      segments_short = { 'segments > 32', 'segments >= 32' },
      segments_long = { 'segments > 32', 'segments > 33' },
    }
    local change = assert(changes[mutant], "unknown mutation")
    local source = table.concat(vim.fn.readfile(root .. "/lua/straps/contextual_targets.lua"), "\n")
    if mutant == "binding" then
      local site = 'local current = M.resolve(binding, options)'
      local start, finish = assert(source:find(site, 1, true))
      source = source:sub(1, start - 1) .. 'local current = M.resolve(record.checks.binding, options)' .. source:sub(finish + 1)
    end
    local first, last = source:find(change[1], 1, true)
    assert(first, "mutation site missing")
    targets = assert(loadstring(source:sub(1, first - 1) .. change[2] .. source:sub(last + 1), "@" .. root .. "/lua/straps/contextual_targets.lua"))()
  else targets = require("straps.contextual_targets") end
end)
after_each(function()
  vim.api.nvim_set_current_dir(previous)
  vim.fn.delete(directory, "rf")
end)

it("captures canonical literal targets and observed process account from a shipped definition", function()
  local value = binding("read_file", { path = "one" })
  local record = resolved(value)
  assert.equals(vim.uv.fs_realpath(directory .. "/one"), record.known.paths[1].canonical)
  assert.equals(vim.uv.os_get_passwd().uid, record.known.account.uid)
  assert.equals("session", record.known.session.session_id)
  assert.is_true(targets.validate(record, value))
end)

it("requires explicit unresolved approval and rechecks facts under that approval", function()
  assert(vim.uv.fs_symlink(directory .. "/one", directory .. "/link"))
  local value = binding("bash", { command = "cat link/file" })
  local record = targets.resolve(value)
  assert.is_not_nil(next(record.unresolved))
  for _, options in ipairs({ {}, { allow_unresolved = false }, { allow_unresolved = "true" } }) do
    assert.is_false(targets.validate(record, value, options))
  end
  assert.is_false(targets.validate(record, value))
  assert.is_true(targets.validate(record, value, { allow_unresolved = true }))
  local changed = vim.deepcopy(value)
  changed.call_id = changed.call_id + 1
  assert.is_false(targets.validate(record, changed, { allow_unresolved = true }))
  assert(vim.uv.fs_unlink(directory .. "/link"))
  assert(vim.uv.fs_symlink(directory .. "/two", directory .. "/link"))
  assert.is_false(targets.validate(record, value, { allow_unresolved = true }))
end)

it("rejects changed working directory at resolution", function()
  local value = binding("read_file", { path = "one" })
  vim.api.nvim_set_current_dir(directory .. "/two")
  local record = targets.resolve(value)
  assert.is_not_nil(record.unresolved[1])
  assert.equals("cwd", record.unresolved[1].field)
end)

it("ignores a non-table second argument, as before the cwd option existed", function()
  local value = binding("read_file", { path = "one" })
  local expected = targets.resolve(value)
  assert.same(expected, targets.resolve(value, true))
  assert.is_true(targets.validate(expected, value, true))
end)

it("resolves against an explicit cwd from a window whose directory differs", function()
  local value = binding("read_file", { path = "one" })
  local expected = targets.resolve(value)
  vim.cmd("tabnew")
  vim.cmd("tcd " .. vim.fn.fnameescape(directory .. "/two"))
  local from_other = targets.resolve(value, { cwd = value.cwd })
  local default = targets.resolve(value)
  local valid = targets.validate(expected, value, { cwd = value.cwd })
  vim.cmd("tabclose")
  assert.same({}, from_other.unresolved)
  assert.same(expected, from_other)
  assert.equals("cwd", default.unresolved[1].field)
  assert.is_true(valid)
end)

it("rejects window and tab directory differences for global shell execution", function()
  for _, command in ipairs({ "lcd", "tcd" }) do
    vim.cmd(command .. " " .. vim.fn.fnameescape(directory .. "/two"))
    local record = targets.resolve(binding("bash", { command = "echo text > output" }))
    assert.is_not_nil(record.unresolved[1])
    assert.equals("cwd", record.unresolved[1].field)
    vim.cmd("cd " .. vim.fn.fnameescape(directory))
  end
end)

it("rechecks directory facts without yielding", function()
  local value = binding("read_file", { path = "one" })
  local record = resolved(value)
  vim.api.nvim_set_current_dir(directory .. "/two")
  local co = coroutine.create(function() return targets.validate(record, value) end)
  local ok, valid = coroutine.resume(co)
  assert.is_true(ok)
  assert.equals("dead", coroutine.status(co))
  assert.is_false(valid)
end)

it("rejects a changed symlink target", function()
  assert(vim.uv.fs_symlink(directory .. "/one", directory .. "/link"))
  local value = binding("write_file", { path = "link/file", content = "text" })
  local record = resolved(value)
  assert(vim.uv.fs_unlink(directory .. "/link"))
  assert(vim.uv.fs_symlink(directory .. "/two", directory .. "/link"))
  assert.is_false(targets.validate(record, value))
end)

it("resolves missing paths through the nearest existing canonical parent", function()
  assert(vim.uv.fs_symlink(directory .. "/one", directory .. "/link"))
  local value = binding("write_file", { path = "link/missing/leaf", content = "text" })
  local record = resolved(value)
  local fact = record.known.paths[1]
  assert.is_true(fact.missing)
  assert.equals(vim.uv.fs_realpath(directory .. "/one") .. "/missing/leaf", fact.canonical)
  vim.fn.mkdir(directory .. "/one/missing", "p")
  assert.is_false(targets.validate(record, value))
end)

for _, scenario in ipairs({
  { "input", function(other) other.input.path = "two" end },
  { "definition identity", function(other) other.definition.identity = -1 end },
  { "session identity", function(other) other.session_id = "other" end },
  { "scope", function(other) other.scope = 8 end },
  { "call identity", function(other) other.call_id = 4 end },
}) do
  it("rejects changed target binding " .. scenario[1], function()
    local value = binding("read_file", { path = "one" })
    local record = resolved(value)
    local other = vim.deepcopy(value)
    scenario[2](other)
    assert.is_false(targets.validate(record, other))
  end)
end

it("leaves changed executable definitions unresolved even with plausible metadata", function()
  local value = binding("read_file", { path = "one" })
  value.definition.source = "return function() return 'changed' end"
  value.definition.targets = { path = "one", account = "trusted" }
  local record = targets.resolve(value)
  assert.is_not_nil(record.unresolved[1])
  assert.equals("definition", record.unresolved[1].field)
end)

it("retains shell path facts while external executable semantics remain unresolved", function()
  local value = binding("bash", { command = "echo text > one/output && rm -f one/old" })
  local record = targets.resolve(value)
  assert.equals(2, #record.known.shell.effects)
  assert.equals("rm", record.known.shell.effects[2].program)
  assert.equals(2, #record.known.paths)
  assert.equals("one/output", record.known.paths[1].literal)
  assert.equals("one/old", record.known.paths[2].literal)
  assert.is_not_nil(record.unresolved[1], "external executable semantics must remain unresolved")
  assert.equals("external executable semantics and shell resolution are untrusted", record.unresolved[1].reason)
  assert.is_false(targets.validate(record, value))
end)

it("tracks option terminators as literal path operands despite unresolved executable semantics", function()
  local value = binding("bash", { command = "rm -- -f one/old" })
  local record = targets.resolve(value)
  assert.equals(2, #record.known.paths)
  assert.equals("-f", record.known.paths[1].literal)
  assert.equals("one/old", record.known.paths[2].literal)
  assert.is_not_nil(record.unresolved[1], "external executable semantics must remain unresolved")
  assert.equals("external executable semantics and shell resolution are untrusted", record.unresolved[1].reason)
end)

it("recognizes literal command names without verifying executable resolution", function()
  local value = binding("bash", { command = "echo text > one/output && printf text; pwd; true; false" })
  local record = resolved(value)
  assert.equals("one/output", record.known.paths[1].literal)
  assert.is_true(targets.validate(record, value))
end)

it("leaves every external vocabulary command unresolved while retaining literal operands", function()
  for _, program in ipairs({ "cat", "ls", "rm", "touch", "mkdir", "cp", "mv", "rmdir" }) do
    local value = binding("bash", { command = program .. " one/file" })
    local record = targets.resolve(value)
    assert.equals("one/file", record.known.paths[1].literal)
    assert.is_not_nil(record.unresolved[1], "external executable semantics must remain unresolved")
    assert.equals("external executable semantics and shell resolution are untrusted", record.unresolved[1].reason)
    assert.is_false(targets.validate(record, value))
  end
end)

it("does not assess or execute a PATH script named rm", function()
  local script, marker = directory .. "/rm", directory .. "/executed"
  vim.fn.writefile({ "#!/bin/sh", "touch " .. marker }, script)
  assert(vim.uv.fs_chmod(script, 493))
  local old_path = vim.env.PATH
  vim.env.PATH = directory .. ":" .. old_path
  local ok, err = pcall(function()
    assert.equals(script, vim.fn.exepath("rm"))
    local value = binding("bash", { command = "rm one/file" })
    local record = targets.resolve(value)
    assert.is_not_nil(record.unresolved[1], "external executable semantics must remain unresolved")
    assert.equals("external executable semantics and shell resolution are untrusted", record.unresolved[1].reason)
    assert.equals("one/file", record.known.paths[1].literal)
    assert.is_false(targets.validate(record, value))
    assert.is_nil(vim.uv.fs_stat(marker))
  end)
  vim.env.PATH = old_path
  if not ok then error(err) end
end)

it("leaves hidden command contents and unknown commands unresolved", function()
  for _, command in ipairs({ "python task.py", "sh script.sh", "echo $(cat secret)", "cd one && rm file", "echo hi && unknown one", "printf -v PATH one; rm file" }) do
    local record = targets.resolve(binding("bash", { command = command }))
    assert.is_not_nil(next(record.unresolved))
  end
end)

it("represents unsupported paths and tools without inventing targets", function()
  for _, path in ipairs({ "../one", "$HOME/file", "~/file", "one/*" }) do
    assert.equals("path", targets.resolve(binding("read_file", { path = path })).unresolved[1].field)
  end
  assert.equals("input", targets.resolve(binding("glob", { pattern = "**/*" })).unresolved[1].field)
  assert.equals("binding", targets.resolve({}).unresolved[1].field)
end)

it("resolves path arrays with stable ordering", function()
  local value = binding("path_info", { paths = { "one", "two" } })
  local record = resolved(value)
  assert.equals(2, #record.known.paths)
  assert.equals("paths.1", record.known.paths[1].field)
  assert.is_true(targets.validate(record, value))
end)

it("rejects unresolved records even when unresolved state is unchanged", function()
  local value = binding("bash", { command = "unknown one" })
  local record = targets.resolve(value)
  local valid, reason = targets.validate(record, value)
  assert.is_false(valid)
  assert.equals("unresolved material targets", reason)
end)

it("bounds literal path bytes at 4096 and 4097", function()
  local function path(size)
    local prefix = string.rep(string.rep("a", 63) .. "/", 63)
    return prefix .. string.rep("a", size - #prefix)
  end
  local record = resolved(binding("read_file", { path = path(4096) }))
  assert.equals(4096, #record.known.paths[1].literal)
  local beyond = targets.resolve(binding("read_file", { path = path(4097) }))
  assert.is_not_nil(beyond.unresolved[1])
  assert.equals("path", beyond.unresolved[1].field)
end)

it("bounds nearest-existing-ancestor search at 128 probes", function()
  local path = string.rep("missing/", 126) .. "leaf"
  assert.equals(path, resolved(binding("read_file", { path = path })).known.paths[1].literal)
  local beyond = targets.resolve(binding("read_file", { path = "missing/" .. path }))
  assert.is_not_nil(beyond.unresolved[1])
  assert.equals("path", beyond.unresolved[1].field)
end)

it("bounds path arrays at 128 and 129 entries", function()
  local paths = {}
  for index = 1, 128 do paths[index] = "one" end
  assert.equals(128, #resolved(binding("path_info", { paths = paths })).known.paths)
  paths[129] = "one"
  local beyond = targets.resolve(binding("path_info", { paths = paths }))
  assert.equals("invalid or oversized path array", beyond.unresolved[1].reason)
end)

it("bounds shell redirect paths at 128 and 129", function()
  local command = "echo" .. string.rep(" > one", 128)
  assert.equals(128, #resolved(binding("bash", { command = command })).known.paths)
  local beyond = targets.resolve(binding("bash", { command = command .. " > one" }))
  assert.is_not_nil(beyond.unresolved[1])
  assert.equals("path count exceeds 128", beyond.unresolved[1].reason)
end)

it("bounds shell command bytes at 8192 and 8193", function()
  local command = "echo " .. string.rep("a", 8187)
  assert.equals(8192, #resolved(binding("bash", { command = command })).known.shell.command)
  local beyond = targets.resolve(binding("bash", { command = command .. "a" }))
  assert.is_not_nil(beyond.unresolved[1])
  assert.equals("unrecognized shell syntax or executable content", beyond.unresolved[1].reason)
end)

it("bounds shell segments at 32 and 33", function()
  local command = string.rep("true;", 31) .. "true"
  assert.equals(32, #resolved(binding("bash", { command = command })).known.shell.effects)
  local beyond = targets.resolve(binding("bash", { command = command .. ";true" }))
  assert.is_not_nil(beyond.unresolved[1])
  assert.equals("shell segment count exceeds 32", beyond.unresolved[1].reason)
end)
