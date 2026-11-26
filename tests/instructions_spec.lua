local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(vim.fn.fnamemodify(here, ":p"), ":h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local straps = require("straps").setup({})
straps.config.session_dir = vim.fn.tempname()
local registry = require("straps.registry")
local discover
local mutant = vim.env.STRAPS_INSTRUCTIONS_MUTANT
if mutant then
  local file = assert(io.open(root .. "/lua/straps/instructions.lua", "r"))
  local source = file:read("*a")
  file:close()
  local mutations = {
    order = { 'for i = #found, 1, -1 do', 'for i = 1, #found do' },
    dedup = { 'if not seen[abs] then', 'if true then' },
    bytes = { 'text = file:read("*a")', 'text = vim.trim(file:read("*a") or "")' },
    omitted = { 'type(text) == "string" and text or unavailable(path)', 'type(text) == "string" and text or "omitted"' },
    config = { 'local config_hash = digest(config_parts)', 'local config_hash = digest({})' },
    content = { 'snapshot_parts[#snapshot_parts + 1] = type(text) == "string" and text or unavailable(path)',
      'snapshot_parts[#snapshot_parts + 1] = "constant"' },
    canonical = { 'local canonical = vim.uv.fs_realpath(path) or path', 'local canonical = path' },
    precedence = { 'precedence = #sources + 1', 'precedence = 0' },
    source_id = { 'id = digest({ path, canonical, hash })', 'id = path' },
    source_hash = { 'local hash = vim.fn.sha256(text)', 'local hash = "constant"' },
    array = { 'sources = sources, presentation', 'sources = { nested = sources }, presentation' },
    presentation = { 'table.concat(sections, "\\n\\n")', 'table.concat(sections, "\\n")' },
  }
  local mutation = assert(mutations[mutant], "unknown mutant")
  local first, last = source:find(mutation[1], 1, true)
  assert(first, "mutation missing")
  source = source:sub(1, first - 1) .. mutation[2] .. source:sub(last + 1)
  discover = assert(loadstring(source, "@instructions-mutant"))().discover
else
  discover = require("straps.instructions").discover
end

local tmp, original, files, denied
local function write(path, text)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local file = assert(original.open(path, "w"))
  file:write(text)
  file:close()
end
local function parity(config)
  straps.config.instructions_files = config and config.instructions_files or nil
  local result = discover(config)
  assert.equals(registry.call("fn.system_prompt_project"), result.presentation)
  return result
end

before_each(function()
  tmp = vim.fn.tempname()
  vim.fn.mkdir(tmp .. "/project/deep", "p")
  tmp = assert(vim.uv.fs_realpath(tmp))
  files, denied = {}, {}
  original = { cwd = vim.fn.getcwd, stdpath = vim.fn.stdpath, home = vim.loop.os_homedir,
    find = vim.fs.find, open = io.open, extras = straps.config.instructions_files }
  vim.fn.getcwd = function() return tmp .. "/project/deep" end
  vim.fn.stdpath = function(kind)
    if kind == "config" then return tmp .. "/config" end
    return original.stdpath(kind)
  end
  vim.loop.os_homedir = function() return tmp .. "/home" end
  vim.fs.find = function(name) return files[name] or {} end
  io.open = function(path, mode)
    if denied[path] then return nil, "fixture unreadable" end
    return original.open(path, mode)
  end
end)

after_each(function()
  vim.fn.getcwd, vim.fn.stdpath, vim.loop.os_homedir = original.cwd, original.stdpath, original.home
  vim.fs.find, io.open = original.find, original.open
  straps.config.instructions_files = original.extras
  vim.fn.delete(tmp, "rf")
end)

it("matches legacy global, filename-major ancestor and extra ordering with lexical duplicates", function()
  local paths = { tmp .. "/config/straps/AGENTS.md", tmp .. "/config/straps/CLAUDE.md",
    tmp .. "/home/AGENTS.md", tmp .. "/home/CLAUDE.md", tmp .. "/project/AGENTS.md",
    tmp .. "/project/deep/AGENTS.md", tmp .. "/project/CLAUDE.md", tmp .. "/project/deep/CLAUDE.md", tmp .. "/extra" }
  for i, path in ipairs(paths) do write(path, tostring(i)) end
  files["AGENTS.md"] = { paths[6], paths[5], paths[3] }
  files["CLAUDE.md"] = { paths[8], paths[7], paths[4] }
  local result = parity({ instructions_files = { paths[6], paths[9], paths[9] } })
  assert.equals(#paths, #result.sources)
  local actual = {}
  for i, source in ipairs(result.sources) do
    actual[i] = source.path
    assert.equals(i, source.precedence)
  end
  assert.same(paths, actual)
end)

it("preserves exact disk bytes and ignores unsaved instruction buffers", function()
  local path = tmp .. "/extra"
  local text = "  first\r\nsecond\000byte\n\n"
  write(path, text)
  local buffer = vim.fn.bufadd(path)
  vim.fn.bufload(buffer)
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "unsaved" })
  local result = parity({ instructions_files = { path } })
  assert.equals(text, result.sources[1].text)
  assert.equals(vim.fn.sha256(text), result.sources[1].hash)
  assert.equals("## " .. path .. "\n" .. text, result.presentation)
  vim.api.nvim_buf_delete(buffer, { force = true })
end)

it("returns dense empty arrays and stable snapshots when nothing is presented", function()
  local a = parity({ instructions_files = { tmp .. "/missing" } })
  local b = discover({ instructions_files = { tmp .. "/missing" } })
  assert.same({}, a.sources)
  assert.equals("", a.presentation)
  assert.same(a, b)
  assert.equals(64, #a.id)
  assert.equals(64, #a.config_hash)
end)

it("retains stable identities and returns detached snapshot data", function()
  local path = tmp .. "/extra"
  write(path, "stable")
  local config = { instructions_files = { path } }
  local a, b = parity(config), discover(config)
  assert.same(a, b)
  a.sources[1].text = "mutated"
  assert.equals("stable", discover(config).sources[1].text)
  write(path, "changed")
  local c = parity(config)
  assert.is_not.equal(b.sources[1].id, c.sources[1].id)
  assert.is_not.equal(b.id, c.id)
  assert.equals(b.config_hash, c.config_hash)
end)

it("hashes discovery config even when duplicate extras preserve presentation", function()
  local path = tmp .. "/extra"
  write(path, "same")
  local a = parity({ instructions_files = { path } })
  local b = parity({ instructions_files = { path, path } })
  assert.equals(a.presentation, b.presentation)
  assert.is_not.equal(a.config_hash, b.config_hash)
  assert.is_not.equal(a.id, b.id)
  assert.equals(a.sources[1].id, b.sources[1].id)
end)

it("invalidates omitted unreadable candidates when disk content changes", function()
  local path = tmp .. "/unreadable"
  write(path, "one")
  denied[path] = true
  local config = { instructions_files = { path } }
  local a = parity(config)
  write(path, "different length")
  local b = parity(config)
  assert.equals("", a.presentation)
  assert.equals("", b.presentation)
  assert.is_not.equal(a.id, b.id)
end)

it("distinguishes missing, empty, unreadable and readable discovery states", function()
  local path = tmp .. "/extra"
  local config = { instructions_files = { path } }
  local missing = parity(config)
  write(path, "")
  local empty = parity(config)
  denied[path] = true
  local unreadable = parity(config)
  denied[path] = nil
  write(path, "visible")
  local readable = parity(config)
  assert.is_not.equal(missing.id, empty.id)
  assert.is_not.equal(empty.id, unreadable.id)
  assert.is_not.equal(unreadable.id, readable.id)
  assert.equals("visible", readable.sources[1].text)
end)

it("keeps lexical alias paths distinct while recording canonical identity", function()
  local path, alias = tmp .. "/extra", tmp .. "/alias"
  write(path, "shared")
  assert(vim.uv.fs_symlink(path, alias))
  local result = parity({ instructions_files = { path, alias } })
  assert.equals(2, #result.sources)
  assert.equals(path, result.sources[2].canonical_path)
  assert.equals(alias, result.sources[2].path)
  assert.is_not.equal(result.sources[1].id, result.sources[2].id)
end)

it("uses current straps configuration when config is omitted and ignores unrelated settings", function()
  local path = tmp .. "/extra"
  write(path, "default")
  straps.config.instructions_files = { path }
  local a = discover()
  assert.equals(registry.call("fn.system_prompt_project"), a.presentation)
  assert.equals("default", a.sources[1].text)
  assert.same(a, discover({ instructions_files = { path }, unrelated = true }))
end)

it("resolves a relative ../ entry with cwd omitted to the same path as fnamemodify :p", function()
  vim.fn.getcwd = original.cwd
  local previous = original.cwd()
  vim.api.nvim_set_current_dir(tmp .. "/project/deep")
  write(tmp .. "/project/x", "parent note")
  local expected = vim.fn.fnamemodify("../x", ":p")
  local ok, result = pcall(discover, { instructions_files = { "../x" } })
  vim.api.nvim_set_current_dir(previous)
  assert(ok, tostring(result))
  assert.equals(1, #result.sources)
  assert.equals(expected, result.sources[1].path)
end)

it("deduplicates a ../AGENTS.md entry against the upward-found AGENTS.md", function()
  local agents = tmp .. "/project/AGENTS.md"
  write(agents, "agents")
  files["AGENTS.md"] = { agents }
  local result = discover({ instructions_files = { "../AGENTS.md" } })
  assert.equals(1, #result.sources)
  assert.equals(agents, result.sources[1].path)
  files["AGENTS.md"] = {}
  local alone = discover({ instructions_files = { "../AGENTS.md" } })
  assert.equals(1, #alone.sources)
  assert.equals(agents, alone.sources[1].path)
  assert.equals("agents", alone.sources[1].text)
end)

it("collapses a repeated slash in a relative entry, as fnamemodify :p does with cwd omitted", function()
  vim.fn.getcwd = original.cwd
  local previous = original.cwd()
  vim.api.nvim_set_current_dir(tmp .. "/project/deep")
  write(tmp .. "/project/deep/x/y", "nested")
  local expected = vim.fn.fnamemodify("x//y", ":p")
  local ok, result = pcall(discover, { instructions_files = { "x//y" } })
  vim.api.nvim_set_current_dir(previous)
  assert(ok, tostring(result))
  assert.equals(1, #result.sources)
  assert.equals(expected, result.sources[1].path)
  assert.equals("nested", result.sources[1].text)
end)
