-- tests/run_capability.lua — per-entry capability metadata (Contract 3).
--   nvim --headless -l tests/run_capability.lua
-- Covers: registry.define accepting/validating spec.capability, fn.capability
-- consulting a tool entry's own capability field before the hardcoded
-- classification, render() round-tripping the field, and builtins keeping
-- their hardcoded categories.

local script = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(vim.fn.fnamemodify(script, ":p"), ":h:h")
vim.opt.runtimepath:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local straps = require("straps").setup({})
straps.config.session_dir = vim.fn.tempname()

local registry = require("straps.registry")

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

local function define_tool(name, capability)
  return registry.define({
    name = "tool." .. name,
    kind = "tool",
    doc = "test tool " .. name,
    source = "return function(input) return 'ok' end",
    capability = capability,
  }, { scope = "global" })
end

case("capability='read' -> fn.capability and readonly_policy true", function()
  define_tool("t1", "read")
  assert(registry.call("fn.capability", "t1") == "read",
    "expected t1 capability read")
  assert(registry.call("fn.readonly_policy", "t1", {}) == true,
    "expected t1 readonly_policy true")
end)

case("capability='vcs' -> classified but never grantable", function()
  define_tool("t2", "vcs")
  assert(registry.call("fn.capability", "t2") == "vcs",
    "expected t2 capability vcs")
  assert(registry.call("fn.readonly_policy", "t2", {}) == false,
    "expected t2 readonly_policy false")
  local grantable = registry.call("fn.capability")
  local found = false
  for _, c in ipairs(grantable) do
    if c == "vcs" then found = true end
  end
  assert(not found, "vcs must not appear in the grantable list")
end)

case("undeclared tool -> other", function()
  registry.define({
    name = "tool.t3",
    kind = "tool",
    doc = "test tool t3",
    source = "return function(input) return 'ok' end",
  }, { scope = "global" })
  assert(registry.call("fn.capability", "t3") == "other",
    "expected t3 capability other")
end)

case("builtin write_file still edit", function()
  assert(registry.call("fn.capability", "write_file") == "edit",
    "expected write_file capability edit")
end)

case("builtin read_file still read", function()
  assert(registry.call("fn.capability", "read_file") == "read",
    "expected read_file capability read")
end)

case("render() emits capability and round-trips through execution", function()
  local rendered = registry.render("tool.t1")
  assert(rendered:find('capability = "read"', 1, true),
    "rendered chunk should contain capability = \"read\": " .. rendered)

  local swapped = rendered:gsub('name = "tool%.t1"', 'name = "tool.t1b"', 1)
  assert(swapped ~= rendered, "expected the name substitution to apply")

  local chunk, err = load(swapped, "test-render-t1b")
  assert(chunk, "rendered chunk failed to compile: " .. tostring(err))
  chunk()

  assert(registry.call("fn.capability", "t1b") == "read",
    "expected t1b (defined from rendered source) to keep capability read")
end)

case("registry.define with non-string capability errors", function()
  local ok, err = pcall(function()
    registry.define({
      name = "tool.t4",
      kind = "tool",
      doc = "test tool t4",
      source = "return function(input) return 'ok' end",
      capability = 42,
    }, { scope = "global" })
  end)
  assert(not ok, "expected registry.define to raise on non-string capability")
  assert(tostring(err):find("capability", 1, true),
    "error message should mention capability: " .. tostring(err))
end)

print(failed and "FAILED" or "ALL PASS")
os.exit(failed and 1 or 0)
