-- tests/layers_spec.lua — config-gated layer registration: both layers off.
--   busted tests/layers_spec.lua
-- setup{ layers = { editor = false, openai = false } } ONCE (registry has no
-- reset; a second setup() in the same process could not un-register). Covers:
-- editor tools absent, core tools intact, fn.build_tools omits editor tools,
-- openai-only fns absent while fn.provider_anthropic stays, fn.provider
-- raising a clean "disabled" message for provider "openai", fn.list_models
-- returning (nil, err) rather than raising, :StrapsLogin/:StrapsLogout openai
-- reporting the disabled layer while the key store still works, and health
-- suggesting no :StrapsLogin openai command.

local script = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(vim.fn.fnamemodify(script, ":p"), ":h:h")
vim.opt.runtimepath:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
vim.env.XDG_CONFIG_HOME = vim.fn.tempname()
vim.env.HOME = vim.fn.tempname()

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
  for _, name in ipairs({ "fn.openai_oauth_credential", "fn.openai_device_id", "fn.openai_oauth_lock",
    "fn.openai_oauth_post", "fn.openai_oauth_refresh", "fn.openai_oauth_login", "fn.openai_oauth_logout" }) do
    assert(registry.get(name) == nil, name .. " should be absent")
  end
  assert(registry.get("fn.provider_anthropic"), "fn.provider_anthropic should be present")
  assert(registry.get("fn.anthropic_api_key"), "fn.anthropic_api_key should be present")
  assert(registry.get("fn.api_key_store"), "fn.api_key_store should be present")
end)

it("openai = false: the ChatGPT login forms report the disabled layer; logout still deletes the key file", function()
  local saved_xdg = vim.env.XDG_CONFIG_HOME
  vim.env.XDG_CONFIG_HOME = vim.fn.tempname()
  local msgs = {}
  local orig = vim.notify
  vim.notify = function(m) msgs[#msgs + 1] = tostring(m) end
  local ui = require("straps.ui")
  local asked = false
  local orig_input = vim.fn.inputsecret
  vim.fn.inputsecret = function() asked = true return "" end
  local stored
  local ok, err = pcall(function()
    ui.login({ "openai" })
    ui.login({ "openai", "key" })
    vim.fn.inputsecret = orig_input
    stored = pcall(registry.call, "fn.api_key_store", "openai", "sk-layer-off")
    ui.logout({ "openai" })
  end)
  vim.fn.inputsecret = orig_input
  vim.notify = orig
  assert(ok, tostring(err))
  local left = registry.call("fn.api_key_store", "openai")
  vim.env.XDG_CONFIG_HOME = saved_xdg
  assert(stored, "fn.api_key_store should work with the openai layer off")
  assert(not asked, "the key prompt should not run with the openai layer off")
  assert(msgs[1] and msgs[1]:find("the openai layer is disabled", 1, true), vim.inspect(msgs))
  assert(msgs[2] and msgs[2]:find("the openai layer is disabled", 1, true), vim.inspect(msgs))
  assert(msgs[3] and msgs[3]:find("straps: deleted ", 1, true), vim.inspect(msgs))
  assert(left == nil, "the key file should be gone")
end)

it("openai = false: health does not suggest a :StrapsLogin openai command", function()
  local rec = {}
  local orig = {}
  for _, k in ipairs({ "start", "ok", "warn", "error", "info" }) do
    orig[k] = vim.health[k]
    vim.health[k] = function(msg, advice) rec[#rec + 1] = tostring(msg) .. " " .. vim.inspect(advice) end
  end
  local saved_provider, saved_xdg = straps.config.provider, vim.env.XDG_CONFIG_HOME
  straps.config.provider = "openai"
  vim.env.XDG_CONFIG_HOME = vim.fn.tempname()
  local ok, err = pcall(require("straps.health").check)
  straps.config.provider, vim.env.XDG_CONFIG_HOME = saved_provider, saved_xdg
  for k, f in pairs(orig) do vim.health[k] = f end
  assert(ok, tostring(err))
  local text = table.concat(rec, "\n")
  assert(text:find("openai layer disabled", 1, true), text)
  assert(not text:find(":StrapsLogin openai", 1, true), "health suggested a command that errors:\n" .. text)
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

it("openai = false: :StrapsLogout openai says the ChatGPT login file stays", function()
  local saved_xdg = vim.env.XDG_CONFIG_HOME
  vim.env.XDG_CONFIG_HOME = vim.fn.tempname()
  vim.fn.mkdir(vim.env.XDG_CONFIG_HOME .. "/straps", "p")
  local login = vim.env.XDG_CONFIG_HOME .. "/straps/openai_oauth.json"
  vim.fn.writefile({ "{}" }, login)
  local msgs = {}
  local orig = vim.notify
  vim.notify = function(m) msgs[#msgs + 1] = tostring(m) end
  require("straps.ui").logout({ "openai" })
  vim.notify = orig
  local still = vim.uv.fs_stat(login) ~= nil
  vim.env.XDG_CONFIG_HOME = saved_xdg
  assert(still, "the login file should not be deleted with the layer off")
  assert(msgs[1] and msgs[1]:find("the ChatGPT login at " .. login .. " was not removed (the openai layer is off)", 1, true)
    and not msgs[1]:find("no stored openai credential", 1, true), vim.inspect(msgs))
end)
