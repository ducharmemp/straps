-- Project registry tests: .straps.lua discovery, direnv-style trust
-- (confirm gate, sha256 trust store, in-memory once-per-content guard),
-- append-only seq ordering of project-defined tools, and the
-- ui.open_session() auto-load path.
-- Run: nvim --headless -l tests/run_project.lua

-- :p makes root absolute: this suite cd's into tempdirs before some modules
-- (straps.state) are first required, so a cwd-relative package.path would
-- break resolution mid-test.
local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(here, ":p:h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local failed = false
local function case(name, fn)
  local ok, err = pcall(fn)
  if ok then
    print("PASS  " .. name)
  else
    failed = true
    print("FAIL  " .. name .. ": " .. tostring(err))
  end
end

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
-- Canonicalize: macOS tempname() returns /var/... but load_project_registry
-- finds .straps.lua upward from getcwd(), which resolves the /var ->
-- /private/var symlink, so the trust store is keyed by canonical paths.
tmp = assert(vim.uv.fs_realpath(tmp))

-- Redirect the data dir so the ui case's DEFAULT trust store lands in the
-- tempdir, never in the user's real stdpath("data").
vim.env.XDG_DATA_HOME = tmp .. "/xdg"
assert(vim.fn.stdpath("data"):find(tmp, 1, true) == 1,
  "stdpath('data') did not follow XDG_DATA_HOME; refusing to touch the real data dir")

local straps = require("straps").setup({})
-- Hermetic: durable sessions write under a throwaway dir (independent of the
-- XDG_DATA_HOME redirect above), never the real data dir.
straps.config.session_dir = vim.fn.tempname()
local registry = require("straps.registry")

local orig_cwd = vim.fn.getcwd()
local function cd(dir)
  vim.cmd("cd " .. vim.fn.fnameescape(dir))
end

local function write_file(path, text)
  local f = assert(io.open(path, "w"))
  f:write(text)
  f:close()
end

local function read_file(path)
  local f = assert(io.open(path, "r"))
  local text = f:read("*a")
  f:close()
  return text
end

local store = tmp .. "/store/trusted.json"

-- The project file: a counter global (proves how many times it executed)
-- plus a marker fn and a marker tool.
local MARKER_SRC = [[
_G.STRAPS_PROJ_COUNT = (_G.STRAPS_PROJ_COUNT or 0) + 1
require("straps.registry").define({
  name = "fn.project_marker", kind = "fn", doc = "test: project marker",
  source = "return function() return 'project-marker' end",
})
require("straps.registry").define({
  name = "tool.project_tool", kind = "tool", doc = "test: project tool",
  source = "return function() return 'project-tool' end",
})
]]

-- ---------------------------------------------------------------- no file
case("no .straps.lua anywhere upward: false, 'none', no error", function()
  local bare = tmp .. "/bare/deep/inside"
  vim.fn.mkdir(bare, "p")
  cd(bare)
  local ok, loaded, info = pcall(straps.load_project_registry, { store_path = store })
  cd(orig_cwd)
  assert(ok, "load_project_registry threw: " .. tostring(loaded))
  assert(loaded == false, "expected loaded=false, got " .. tostring(loaded))
  assert(type(info) == "string" and info:find("none", 1, true),
    "expected 'none'-ish info, got " .. tostring(info))
end)

-- ------------------------------------------------------- untrusted headless
local proj = tmp .. "/proj"
vim.fn.mkdir(proj, "p")
write_file(proj .. "/.straps.lua", MARKER_SRC)

case("untrusted file + headless confirm (0): not executed, no error", function()
  cd(proj)
  local ok, loaded, info = pcall(straps.load_project_registry, { store_path = store })
  cd(orig_cwd)
  assert(ok, "load_project_registry threw: " .. tostring(loaded))
  assert(loaded == false, "untrusted content must not load, info: " .. tostring(info))
  assert(registry.get("fn.project_marker") == nil, "marker entry defined despite no trust")
  assert((_G.STRAPS_PROJ_COUNT or 0) == 0, "project file executed despite no trust")
end)

-- ---------------------------------------------------------------- trust_all
case("opts.trust_all executes and records path + hash in the store", function()
  cd(proj)
  local loaded, info = straps.load_project_registry({ trust_all = true, store_path = store })
  cd(orig_cwd)
  assert(loaded == true, "trust_all load failed: " .. tostring(info))
  assert(registry.get("fn.project_marker"), "marker entry missing after trusted load")
  assert(_G.STRAPS_PROJ_COUNT == 1,
    "expected exactly 1 execution, got " .. tostring(_G.STRAPS_PROJ_COUNT))
  local decoded = vim.json.decode(read_file(store))
  local abs = vim.fn.fnamemodify(proj .. "/.straps.lua", ":p")
  assert(decoded[abs], "store has no entry for " .. abs .. ": " .. vim.inspect(decoded))
  assert(decoded[abs] == vim.fn.sha256(MARKER_SRC),
    "stored hash does not match the file content's sha256")
end)

-- ------------------------------------------------------- once-per-content
case("second call without trust_all: trusted via store, once-guard skips re-exec", function()
  cd(proj)
  local loaded, info = straps.load_project_registry({ store_path = store })
  cd(orig_cwd)
  assert(loaded == true, "hash matches the store; expected loaded=true, got: " .. tostring(info))
  assert(_G.STRAPS_PROJ_COUNT == 1,
    "same content must execute at most once per session, got "
      .. tostring(_G.STRAPS_PROJ_COUNT) .. " executions")
end)

-- ------------------------------------------------------------ changed file
case("changed content is untrusted again: not executed", function()
  write_file(proj .. "/.straps.lua", MARKER_SRC .. "\n-- edited after trust\n")
  cd(proj)
  local ok, loaded, info = pcall(straps.load_project_registry, { store_path = store })
  cd(orig_cwd)
  assert(ok, "load_project_registry threw: " .. tostring(loaded))
  assert(loaded == false, "changed content must not load silently, info: " .. tostring(info))
  assert(_G.STRAPS_PROJ_COUNT == 1,
    "changed content executed without confirmation; count = " .. tostring(_G.STRAPS_PROJ_COUNT))
end)

-- ------------------------------------------------------------ seq ordering
case("project-defined tool lands AFTER builtins in names_by_seq order", function()
  local names = registry.names_by_seq("tool")
  local idx_read, idx_proj
  for i, name in ipairs(names) do
    if name == "tool.read_file" then idx_read = i end
    if name == "tool.project_tool" then idx_proj = i end
  end
  assert(idx_read, "builtin tool.read_file missing from names_by_seq")
  assert(idx_proj, "tool.project_tool missing from names_by_seq")
  assert(idx_proj > idx_read, "project tool must come after builtins (append-only)")
  assert(names[#names] == "tool.project_tool",
    "project tool should be LAST, got order: " .. table.concat(names, ","))
end)

-- --------------------------------------------------------------- ui path
case("ui.open_session() loads a trusted .straps.lua from cwd", function()
  local uiproj = tmp .. "/uiproj"
  vim.fn.mkdir(uiproj, "p")
  local ui_src = [[
_G.STRAPS_UI_COUNT = (_G.STRAPS_UI_COUNT or 0) + 1
require("straps.registry").define({
  name = "fn.ui_marker", kind = "fn", doc = "test: ui marker",
  source = "return function() return 'ui-marker' end",
})
]]
  write_file(uiproj .. "/.straps.lua", ui_src)
  -- Pre-seed the DEFAULT trust store (under the redirected XDG_DATA_HOME)
  -- with this content's hash, so open_session loads without a confirm.
  local default_store = vim.fn.stdpath("data") .. "/straps/trusted.json"
  vim.fn.mkdir(vim.fn.fnamemodify(default_store, ":h"), "p")
  local abs = vim.fn.fnamemodify(uiproj .. "/.straps.lua", ":p")
  write_file(default_store, vim.json.encode({ [abs] = vim.fn.sha256(ui_src) }))

  cd(uiproj)
  local ok, err = pcall(function()
    local bufnr = require("straps.ui").open_session()
    assert(vim.api.nvim_buf_is_valid(bufnr), "open_session returned an invalid buffer")
  end)
  cd(orig_cwd)
  assert(ok, "open_session threw: " .. tostring(err))
  assert(registry.get("fn.ui_marker"), "ui marker entry missing after open_session")
  assert(_G.STRAPS_UI_COUNT == 1,
    "expected exactly 1 execution via open_session, got " .. tostring(_G.STRAPS_UI_COUNT))
end)

if failed then
  print("FAILED")
  os.exit(1)
end
print("ALL PASS")
os.exit(0)
