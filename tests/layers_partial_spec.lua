-- tests/layers_partial_spec.lua — config-gated layer registration: partial
-- table keeps the other layer's default ON.
--   busted tests/layers_partial_spec.lua
-- setup{ layers = { editor = false } } ONCE: tbl_deep_extend("force") merges
-- nested tables key-by-key, so leaving layers.openai unset in the user's
-- table must not turn it off.

local script = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(vim.fn.fnamemodify(script, ":p"), ":h:h")
vim.opt.runtimepath:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local straps = require("straps").setup({ layers = { editor = false } })
straps.config.session_dir = vim.fn.tempname()

local registry = require("straps.registry")


it("partial layers table: editor off, editor tools absent", function()
  assert(registry.get("tool.definition") == nil, "tool.definition should be absent")
  assert(registry.get("tool.diagnostics") == nil, "tool.diagnostics should be absent")
end)

it("partial layers table: openai left unset stays ON (default true)", function()
  assert(registry.get("fn.provider_openai"), "fn.provider_openai should still be present")
  assert(registry.get("fn.openai_api_key"), "fn.openai_api_key should still be present")
end)
