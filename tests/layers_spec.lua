-- tests/layers_spec.lua — config-gated layer registration: both layers off.
--   busted tests/layers_spec.lua
-- setup{ layers = { editor = false, openai = false } } ONCE (registry has no
-- reset; a second setup() in the same process could not un-register). Covers:
-- editor tools absent, core tools intact, fn.build_tools omits editor tools,
-- openai-only fns absent while fn.provider_anthropic stays, fn.provider
-- raising a clean "disabled" message for provider "openai", and fn.list_models
-- returning (nil, err) rather than raising.

local script = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(vim.fn.fnamemodify(script, ":p"), ":h:h")
vim.opt.runtimepath:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local straps = require("straps").setup({ layers = { editor = false, openai = false } })
straps.config.session_dir = vim.fn.tempname()

local registry = require("straps.registry")


it("editor = false: editor tools absent", function()
  assert(registry.get("tool.definition") == nil, "tool.definition should be absent")
  assert(registry.get("tool.diagnostics") == nil, "tool.diagnostics should be absent")
end)

it("editor = false: core tools stay registered", function()
  assert(registry.get("tool.read_file"), "tool.read_file should be present")
  assert(registry.get("tool.grep"), "tool.grep should be present")
end)

it("editor = false: fn.build_tools omits editor tool names", function()
  local tools = registry.call("fn.build_tools")
  for _, t in ipairs(tools) do
    assert(t.name ~= "definition", "build_tools should not list definition")
    assert(t.name ~= "diagnostics", "build_tools should not list diagnostics")
  end
  local names = {}
  for _, t in ipairs(tools) do names[#names + 1] = t.name end
  assert(#names > 0, "build_tools should still list core tools")
end)

it("openai = false: openai-only fns absent, anthropic stays", function()
  assert(registry.get("fn.provider_openai") == nil, "fn.provider_openai should be absent")
  assert(registry.get("fn.openai_api_key") == nil, "fn.openai_api_key should be absent")
  assert(registry.get("fn.provider_anthropic"), "fn.provider_anthropic should be present")
end)

it("openai = false: fn.provider raises a clean disabled message", function()
  straps.config.provider = "openai"
  local ok, err = pcall(registry.call, "fn.provider", { messages = {} }, {})
  straps.config.provider = nil
  assert(not ok, "fn.provider should raise when the openai layer is disabled")
  assert(tostring(err):find("openai layer is disabled", 1, true),
    "error should mention the disabled layer: " .. tostring(err))
end)

it("openai = false: fn.list_models returns (nil, err), does not raise", function()
  local ok, out, err = pcall(registry.call, "fn.list_models", "openai")
  assert(ok, "fn.list_models must not raise: " .. tostring(out))
  assert(out == nil, "fn.list_models should return nil result")
  assert(type(err) == "string" and err:find("disabled", 1, true),
    "err should mention 'disabled': " .. tostring(err))
end)
