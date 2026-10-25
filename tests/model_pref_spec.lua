-- tests/model_pref_spec.lua — the persisted global model choice (fn.model_pref)
-- and provider.resolve_model / model_entry reading it on each call, below a
-- model key that setup{} or runtime code set.
--   busted tests/model_pref_spec.lua
-- No network. Writes only under a throwaway $XDG_CONFIG_HOME.

local script = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(vim.fn.fnamemodify(script, ":p"), ":h:h")
vim.opt.runtimepath:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

vim.env.XDG_CONFIG_HOME = vim.fn.tempname()
vim.fn.mkdir(vim.env.XDG_CONFIG_HOME .. "/straps", "p")
vim.fn.writefile({ vim.json.encode({ id = "qwen-saved", entry = { id = "qwen-saved", thinking = "adaptive", context = 65536 } }) },
  vim.env.XDG_CONFIG_HOME .. "/straps/model_llamacpp")
vim.fn.writefile({ vim.json.encode({ id = "claude-saved" }) }, vim.env.XDG_CONFIG_HOME .. "/straps/model_anthropic")

local straps = require("straps").setup({ model = "claude-from-setup" })
straps.config.session_dir = vim.fn.tempname()
local registry = require("straps.registry")

it("a persisted model applies to a provider key setup{} did not set", function()
  local model = require("straps.provider").resolve_model("llamacpp", nil, straps.config)
  assert(model == "qwen-saved", "resolved llamacpp model: " .. tostring(model))
end)

it("a persisted model is read on each call, so a pick written by another Neovim applies at once", function()
  registry.call("fn.model_pref", "llamacpp", "qwen-from-elsewhere")
  local model = require("straps.provider").resolve_model("llamacpp", nil, straps.config)
  registry.call("fn.model_pref", "llamacpp", "qwen-saved", { id = "qwen-saved", thinking = "adaptive", context = 65536 })
  assert(model == "qwen-from-elsewhere", "resolved " .. tostring(model))
end)

it("an unset model key yields to the persisted model, and with neither the slot default applies", function()
  registry.call("fn.model_pref", "openai", "gpt-persisted")
  local persisted = require("straps.provider").resolve_model("openai", nil, straps.config)
  vim.fn.delete(vim.env.XDG_CONFIG_HOME .. "/straps/model_openai")
  local fallback = require("straps.provider").resolve_model("openai", nil, straps.config)
  assert(straps.config.openai_model == nil, "openai_model should default to nil")
  assert(persisted == "gpt-persisted", "resolved " .. tostring(persisted))
  assert(fallback == "gpt-5", "slot default: " .. tostring(fallback))
end)

it("a model key that is set wins over the persisted model even when it equals the slot default", function()
  local saved = straps.config.model
  straps.config.model = "claude-sonnet-5"
  local model = require("straps.provider").resolve_model("anthropic", nil, straps.config)
  straps.config.model = saved
  assert(model == "claude-sonnet-5", "resolved " .. tostring(model))
end)

it("fn.model_pref reads a file rewritten outside straps, despite its read cache", function()
  local path = vim.env.XDG_CONFIG_HOME .. "/straps/model_openai"
  vim.fn.writefile({ vim.json.encode({ id = "gpt-first" }) }, path)
  local first = registry.call("fn.model_pref", "openai")
  vim.fn.writefile({ vim.json.encode({ id = "gpt-second-longer" }) }, path)
  local second = registry.call("fn.model_pref", "openai")
  vim.fn.delete(path)
  assert(first == "gpt-first" and second == "gpt-second-longer", tostring(first) .. " / " .. tostring(second))
end)

it("a model key set at runtime wins over the persisted model", function()
  local saved = straps.config.llamacpp_model
  straps.config.llamacpp_model = "qwen-runtime"
  local model = require("straps.provider").resolve_model("llamacpp", nil, straps.config)
  straps.config.llamacpp_model = saved
  assert(model == "qwen-runtime", "resolved " .. tostring(model))
end)

it("model_entry returns the persisted model's stored list entry", function()
  local entry = require("straps.provider").model_entry("llamacpp", "qwen-saved", straps.config)
  assert(entry and entry.thinking == "adaptive" and entry.context == 65536, "entry not merged: " .. vim.inspect(entry))
end)

it("a model key set in setup{} wins over the persisted model", function()
  assert(straps.config.model == "claude-from-setup", "model: " .. tostring(straps.config.model))
end)

it("a global pick of a model key setup{} set lasts for this Neovim only and writes nothing", function()
  local ui = require("straps.ui")
  local real_pick, real_notify = ui.pick, vim.notify
  local saved_list, saved_provider = straps.config.models, straps.config.provider
  straps.config.provider = "anthropic"
  local said
  vim.notify = function(msg) said = msg end
  registry.define({ name = "fn.list_models", kind = "fn", doc = "test stub",
    source = "return function() return { { id = 'claude-picked', label = 'claude-picked' } } end" })
  ui.pick = function(items, opts, on_choice) on_choice({ id = "claude-picked", label = "claude-picked" }) end
  local ok, err = pcall(ui.pick_model)
  ui.pick, vim.notify = real_pick, real_notify
  local stored = registry.call("fn.model_pref", "anthropic")
  local picked = straps.config.model
  straps.config.models, straps.config.provider, straps.config.model = saved_list, saved_provider, "claude-from-setup"
  assert(ok, tostring(err))
  assert(picked == "claude-picked", "the pick did not apply: " .. tostring(picked))
  assert(said and said:find("this Neovim only: config.model is set", 1, true), "notice: " .. tostring(said))
  assert(stored == "claude-saved", "the pick overwrote the persisted model: " .. tostring(stored))
end)

local function global_pick(provider, id)
  local ui = require("straps.ui")
  local real_pick, real_notify = ui.pick, vim.notify
  local saved_provider = straps.config.provider
  straps.config.provider = provider
  local said
  vim.notify = function(msg) said = msg end
  registry.define({ name = "fn.list_models", kind = "fn", doc = "test stub",
    source = ("return function() return { { id = %q, label = %q } } end"):format(id, id) })
  ui.pick = function(items, opts, on_choice)
    for _, item in ipairs(items) do if item.id == id then return on_choice(item) end end
  end
  local ok, err = pcall(ui.pick_model)
  ui.pick, vim.notify = real_pick, real_notify
  straps.config.provider = saved_provider
  assert(ok, tostring(err))
  return said
end

it("a global pick of an unset key writes only the pref, so a later pick from another Neovim applies here", function()
  local said = global_pick("openai", "gpt-picked-here")
  local config_after = straps.config.openai_model
  local here = require("straps.provider").resolve_model("openai", nil, straps.config)
  vim.fn.writefile({ vim.json.encode({ id = "gpt-picked-elsewhere" }) }, vim.env.XDG_CONFIG_HOME .. "/straps/model_openai")
  local after_other = require("straps.provider").resolve_model("openai", nil, straps.config)
  vim.fn.delete(vim.env.XDG_CONFIG_HOME .. "/straps/model_openai")
  assert(said and said:find("(persisted;", 1, true), "notice: " .. tostring(said))
  assert(config_after == nil, "the pick wrote config.openai_model: " .. tostring(config_after))
  assert(here == "gpt-picked-here", "the pick did not apply: " .. tostring(here))
  assert(after_other == "gpt-picked-elsewhere", "the other Neovim's pick did not apply: " .. tostring(after_other))
end)

it("a global pick equal to the slot default sticks over an older persisted model", function()
  registry.call("fn.model_pref", "openai", "gpt-older")
  global_pick("openai", "gpt-5")
  local model = require("straps.provider").resolve_model("openai", nil, straps.config)
  vim.fn.delete(vim.env.XDG_CONFIG_HOME .. "/straps/model_openai")
  assert(model == "gpt-5", "resolved " .. tostring(model))
end)

it("a global pick whose pref write fails applies to this Neovim and says it was not persisted", function()
  local real = registry.get("fn.model_pref")
  registry.define({ name = "fn.model_pref", kind = "fn", doc = "test: write fails",
    source = [[return function(provider, value) if value ~= nil then return nil, "disk full" end return nil end]] })
  local said = global_pick("openai", "gpt-unsaved")
  registry.define({ name = real.name, kind = real.kind, doc = real.doc, source = real.source })
  local config_after = straps.config.openai_model
  straps.config.openai_model = nil
  assert(config_after == "gpt-unsaved", "the failed pick did not apply: " .. tostring(config_after))
  assert(said and said:find("this Neovim only; not persisted: disk full", 1, true), "notice: " .. tostring(said))
end)

it("after a failed pref write, the next global pick retries the write and clears the fallback", function()
  local real = registry.get("fn.model_pref")
  registry.define({ name = "fn.model_pref", kind = "fn", doc = "test: write fails",
    source = [[return function(provider, value) if value ~= nil then return nil, "disk full" end return nil end]] })
  global_pick("openai", "gpt-unsaved")
  registry.define({ name = real.name, kind = real.kind, doc = real.doc, source = real.source })
  local said = global_pick("openai", "gpt-saved-now")
  local config_after = straps.config.openai_model
  local stored = registry.call("fn.model_pref", "openai")
  vim.fn.delete(vim.env.XDG_CONFIG_HOME .. "/straps/model_openai")
  straps.config.openai_model = nil
  assert(stored == "gpt-saved-now", "the retry did not write the pref: " .. tostring(stored))
  assert(config_after == nil, "the fallback config value was kept: " .. tostring(config_after))
  assert(said and said:find("(persisted;", 1, true), "notice: " .. tostring(said))
end)

it("a global provider pick with config.provider set lasts for this Neovim only and writes no pref", function()
  local ui = require("straps.ui")
  local real_pick, real_notify = ui.pick, vim.notify
  local saved = straps.config.provider
  straps.config.provider = "anthropic"
  local said
  vim.notify = function(msg) said = msg end
  ui.pick = function(items, opts, on_choice) on_choice("openai") end
  local ok, err = pcall(ui.pick_provider)
  ui.pick, vim.notify = real_pick, real_notify
  local picked = straps.config.provider
  straps.config.provider = saved
  local pref_exists = vim.fn.filereadable(vim.env.XDG_CONFIG_HOME .. "/straps/provider") == 1
  assert(ok, tostring(err))
  assert(picked == "openai", "the pick did not apply: " .. tostring(picked))
  assert(said and said:find("this Neovim only: config.provider is set", 1, true), "notice: " .. tostring(said))
  assert(not pref_exists, "the pick wrote the provider pref")
end)

local function global_provider_pick(choice)
  local ui = require("straps.ui")
  local real_pick, real_notify = ui.pick, vim.notify
  local said
  vim.notify = function(msg) said = msg end
  ui.pick = function(items, opts, on_choice) on_choice(choice) end
  local ok, err = pcall(ui.pick_provider)
  ui.pick, vim.notify = real_pick, real_notify
  assert(ok, tostring(err))
  return said
end

it("a global provider pick whose pref write fails applies here, and the next pick retries the write", function()
  local saved = straps.config.provider
  straps.config.provider = nil
  local real = registry.get("fn.provider_pref")
  registry.define({ name = "fn.provider_pref", kind = "fn", doc = "test: write fails",
    source = [[return function(value) if value ~= nil then return nil, "disk full" end return nil end]] })
  local first_said = global_provider_pick("openai")
  local after_fail = straps.config.provider
  registry.define({ name = real.name, kind = real.kind, doc = real.doc, source = real.source })
  local second_said = global_provider_pick("llamacpp")
  local after_retry = straps.config.provider
  local stored = registry.call("fn.provider_pref")
  vim.fn.delete(vim.env.XDG_CONFIG_HOME .. "/straps/provider")
  straps.config.provider = saved
  assert(after_fail == "openai", "the failed pick did not apply: " .. tostring(after_fail))
  assert(first_said and first_said:find("could not persist: disk full", 1, true), "notice: " .. tostring(first_said))
  assert(stored == "llamacpp", "the retry did not write the pref: " .. tostring(stored))
  assert(after_retry == nil, "the fallback config.provider was kept: " .. tostring(after_retry))
  assert(second_said and second_said:find("(persisted;", 1, true), "notice: " .. tostring(second_said))
end)

it("fn.model_pref writes, reads back, and rejects an unknown provider", function()
  assert(registry.call("fn.model_pref", "openai", "gpt-saved", { id = "gpt-saved", reasoning = true }) == "gpt-saved",
    "write did not return the value")
  local id, entry = registry.call("fn.model_pref", "openai")
  assert(id == "gpt-saved", "read-back wrong")
  assert(entry and entry.reasoning == true, "entry not read back: " .. vim.inspect(entry))
  local got, err = registry.call("fn.model_pref", "bogus", "x")
  assert(got == nil and tostring(err):find("unknown provider bogus", 1, true), tostring(err))
  local read_id, read_entry, read_err = registry.call("fn.model_pref", "bogus")
  assert(read_id == nil and read_entry == nil and tostring(read_err):find("unknown provider bogus", 1, true),
    "a read for an unknown provider should return nil, nil, err: " .. tostring(read_entry) .. " / " .. tostring(read_err))
  assert(vim.fn.filereadable(vim.env.XDG_CONFIG_HOME .. "/straps/model_bogus") == 0, "wrote a file for an unknown provider")
end)

it("fn.model_pref drops a stored entry whose id differs from the stored model", function()
  vim.fn.writefile({ vim.json.encode({ id = "gpt-a", entry = { id = "gpt-b", reasoning = true } }) },
    vim.env.XDG_CONFIG_HOME .. "/straps/model_openai")
  local id, entry = registry.call("fn.model_pref", "openai")
  assert(id == "gpt-a" and entry == nil, "read " .. tostring(id) .. " / " .. vim.inspect(entry))
end)

it("fn.model_pref reads nil for a provider with no stored model", function()
  vim.fn.delete(vim.env.XDG_CONFIG_HOME .. "/straps/model_openai")
  assert(registry.call("fn.model_pref", "openai") == nil, "expected nil for a missing file")
end)
