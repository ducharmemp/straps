-- tests/spawn_model_spec.lua — tool.spawn provider/model/effort selection.
--   busted tests/spawn_model_spec.lua

local script = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(vim.fn.fnamemodify(script, ":p"), ":h:h")
vim.opt.runtimepath:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

-- Hermetic config dir: a real ~/.config/straps provider or model_<provider>
-- pref file would change the provider and model these tests resolve.
vim.env.XDG_CONFIG_HOME = vim.fn.tempname()
vim.fn.mkdir(vim.env.XDG_CONFIG_HOME, "p")
local straps = require("straps").setup({})
straps.config.session_dir = vim.fn.tempname()

local registry = require("straps.registry")
local loop = require("straps.loop")

local function define(name, source)
  registry.define({ name = name, kind = "fn", doc = "test", source = source }, { scope = "global" })
end

define("fn.provider_openai", [[return function(req, ctx) return { backend = "openai", bufnr = ctx.bufnr } end]])
define("fn.provider_anthropic", [[return function(req, ctx) return { backend = "anthropic", bufnr = ctx.bufnr } end]])
define("fn.provider_llamacpp", [[return function(req, ctx) return { backend = "llamacpp", bufnr = ctx.bufnr } end]])

define("fn.provider_pref", [[return function() return _G.__spawn_model_pref end]])

local function spawn(parent_vars, input, opts)
  opts = opts or {}
  _G.__spawn_model_pref = opts.pref
  straps.config.provider = opts.config_provider
  local parent = vim.api.nvim_create_buf(true, false)
  for k, v in pairs(parent_vars or {}) do vim.b[parent][k] = v end
  local child
  local real_start = loop.start
  loop.start = function(b) child = b end
  local ok, err = pcall(registry.call, "tool.spawn", vim.tbl_extend("force", { task = "probe" }, input or {}),
    { bufnr = parent })
  loop.start = real_start
  straps.config.provider = nil
  _G.__spawn_model_pref = nil
  assert(ok, tostring(err))
  assert(child, "loop.start was not called for the child")
  return child
end

local function dispatch(child)
  local ok, res = pcall(registry.call, "fn.provider", { messages = {} }, { bufnr = child })
  if not ok then return nil, res end
  return res.backend
end

local both = { straps_model = "claude-parent", straps_openai_model = "gpt-parent" }
local three = vim.tbl_extend("force", both, { straps_llamacpp_model = "qwen-parent" })

it("config.provider = openai: an explicit model lands in the OpenAI slot", function()
  local child = spawn(both, { model = "gpt-requested" }, { config_provider = "openai" })
  assert(vim.b[child].straps_openai_model == "gpt-requested", tostring(vim.b[child].straps_openai_model))
  assert(vim.b[child].straps_model == nil, tostring(vim.b[child].straps_model))
  assert(vim.b[child].straps_provider == "openai", tostring(vim.b[child].straps_provider))
  assert(dispatch(child) == "openai")
end)

it("config.provider = openai: the child inherits only the parent's OpenAI model", function()
  local child = spawn(both, {}, { config_provider = "openai" })
  assert(vim.b[child].straps_openai_model == "gpt-parent", tostring(vim.b[child].straps_openai_model))
  assert(vim.b[child].straps_model == nil, tostring(vim.b[child].straps_model))
end)

it("provider preference openai: explicit and inherited models use the OpenAI slot", function()
  local explicit = spawn(both, { model = "gpt-requested" }, { pref = "openai" })
  assert(vim.b[explicit].straps_openai_model == "gpt-requested", tostring(vim.b[explicit].straps_openai_model))
  assert(vim.b[explicit].straps_model == nil, tostring(vim.b[explicit].straps_model))
  assert(dispatch(explicit) == "openai")
  local inherited = spawn(both, {}, { pref = "openai" })
  assert(vim.b[inherited].straps_openai_model == "gpt-parent", tostring(vim.b[inherited].straps_openai_model))
  assert(vim.b[inherited].straps_model == nil, tostring(vim.b[inherited].straps_model))
end)

it("an OpenAI parent with no OpenAI model leaves the child on the OpenAI default", function()
  local child = spawn({ straps_model = "claude-parent" }, {}, { config_provider = "openai" })
  assert(vim.b[child].straps_openai_model == nil, tostring(vim.b[child].straps_openai_model))
  assert(vim.b[child].straps_model == nil, tostring(vim.b[child].straps_model))
  assert(dispatch(child) == "openai")
end)

it("config.provider wins over the provider preference", function()
  local child = spawn(both, {}, { config_provider = "anthropic", pref = "openai" })
  assert(vim.b[child].straps_provider == "anthropic", tostring(vim.b[child].straps_provider))
  assert(vim.b[child].straps_model == "claude-parent", tostring(vim.b[child].straps_model))
  assert(vim.b[child].straps_openai_model == nil, tostring(vim.b[child].straps_openai_model))
end)

it("the parent's straps_provider wins over config.provider and the preference", function()
  local child = spawn(vim.tbl_extend("force", both, { straps_provider = "anthropic" }), {},
    { config_provider = "openai", pref = "openai" })
  assert(vim.b[child].straps_provider == "anthropic", tostring(vim.b[child].straps_provider))
  assert(vim.b[child].straps_model == "claude-parent", tostring(vim.b[child].straps_model))
  assert(dispatch(child) == "anthropic")
end)

it("with no provider set anywhere the child uses Anthropic", function()
  local child = spawn(both, {})
  assert(vim.b[child].straps_provider == "anthropic", tostring(vim.b[child].straps_provider))
  assert(vim.b[child].straps_model == "claude-parent", tostring(vim.b[child].straps_model))
  assert(vim.b[child].straps_openai_model == nil, tostring(vim.b[child].straps_openai_model))
  assert(dispatch(child) == "anthropic")
end)

it("blank provider values count as unset", function()
  local child = spawn(vim.tbl_extend("force", both, { straps_provider = "" }), { provider = "" },
    { config_provider = "", pref = "openai" })
  assert(vim.b[child].straps_provider == "openai", tostring(vim.b[child].straps_provider))
  assert(vim.b[child].straps_openai_model == "gpt-parent", tostring(vim.b[child].straps_openai_model))
end)

it("an unknown input.provider raises and creates no child", function()
  local parent = vim.api.nvim_create_buf(true, false)
  local started = false
  local real_start = loop.start
  loop.start = function() started = true end
  local before = #vim.api.nvim_list_bufs()
  local ok, err = pcall(registry.call, "tool.spawn", { task = "probe", provider = "bogus" }, { bufnr = parent })
  loop.start = real_start
  assert(not ok and tostring(err):find("unknown provider bogus", 1, true), tostring(err))
  assert(not started, "loop.start ran for a rejected spawn")
  assert(#vim.api.nvim_list_bufs() == before, "a child buffer was created")
end)

it("an unknown provider inherited from the parent is kept so the dispatcher rejects it", function()
  local child = spawn(vim.tbl_extend("force", both, { straps_provider = "bogus" }), {})
  assert(vim.b[child].straps_provider == "bogus", tostring(vim.b[child].straps_provider))
  local backend, err = dispatch(child)
  assert(backend == nil and tostring(err):find("unknown provider bogus", 1, true), tostring(err))
end)

it("explicit llamacpp takes the parent's llama model when config has none", function()
  local saved = straps.config.llamacpp_model
  straps.config.llamacpp_model = nil
  local child = spawn({ straps_provider = "llamacpp", straps_llamacpp_model = "qwen-parent" }, { provider = "llamacpp" })
  straps.config.llamacpp_model = saved
  assert(vim.b[child].straps_llamacpp_model == "qwen-parent", tostring(vim.b[child].straps_llamacpp_model))
end)

it("explicit anthropic spawns with config.model unset and dispatches to anthropic", function()
  local saved = straps.config.model
  straps.config.model = nil
  local ok, child = pcall(spawn, {}, { provider = "anthropic" })
  local backend = ok and dispatch(child)
  straps.config.model = saved
  assert(ok, "spawn refused an anthropic child with config.model unset: " .. tostring(child))
  assert(backend == "anthropic", "child dispatched to " .. tostring(backend))
end)

it("a child spawned on llamacpp stays on it after the global provider and preference change", function()
  local child = spawn(three, {}, { config_provider = "llamacpp" })
  straps.config.provider = "anthropic"
  _G.__spawn_model_pref = "openai"
  local backend, err = dispatch(child)
  straps.config.provider = nil
  _G.__spawn_model_pref = nil
  assert(backend == "llamacpp", "child moved to " .. tostring(backend) .. " " .. tostring(err))
end)

it("the spawn provider enum lists llamacpp", function()
  local enum = registry.get("tool.spawn").input_schema.properties.provider.enum
  assert(vim.tbl_contains(enum, "llamacpp"), vim.inspect(enum))
end)

it("a llamacpp parent's child inherits only the llama.cpp model", function()
  local child = spawn(vim.tbl_extend("force", three, { straps_provider = "llamacpp" }), {})
  assert(vim.b[child].straps_provider == "llamacpp", tostring(vim.b[child].straps_provider))
  assert(vim.b[child].straps_llamacpp_model == "qwen-parent", tostring(vim.b[child].straps_llamacpp_model))
  assert(vim.b[child].straps_model == nil, tostring(vim.b[child].straps_model))
  assert(vim.b[child].straps_openai_model == nil, tostring(vim.b[child].straps_openai_model))
  assert(dispatch(child) == "llamacpp")
end)

it("explicit llamacpp with an explicit model uses the llama.cpp slot", function()
  local child = spawn(three, { provider = "llamacpp", model = "gpt-oss" }, { config_provider = "anthropic" })
  assert(vim.b[child].straps_llamacpp_model == "gpt-oss", tostring(vim.b[child].straps_llamacpp_model))
  assert(vim.b[child].straps_model == nil, tostring(vim.b[child].straps_model))
  assert(dispatch(child) == "llamacpp")
end)

it("explicit anthropic under an OpenAI parent inherits the Anthropic slot only", function()
  local child = spawn(both, { provider = "anthropic" }, { config_provider = "openai" })
  assert(vim.b[child].straps_model == "claude-parent", tostring(vim.b[child].straps_model))
  assert(vim.b[child].straps_openai_model == nil, tostring(vim.b[child].straps_openai_model))
  assert(dispatch(child) == "anthropic")
end)

it("explicit anthropic with no parent Anthropic model leaves both slots unset", function()
  local child = spawn({ straps_openai_model = "gpt-parent" }, { provider = "anthropic" }, { config_provider = "openai" })
  assert(vim.b[child].straps_model == nil, tostring(vim.b[child].straps_model))
  assert(vim.b[child].straps_openai_model == nil, tostring(vim.b[child].straps_openai_model))
end)

it("explicit openai under an Anthropic parent takes the explicit model", function()
  local child = spawn(both, { provider = "openai", model = "gpt-requested" }, { config_provider = "anthropic" })
  assert(vim.b[child].straps_openai_model == "gpt-requested", tostring(vim.b[child].straps_openai_model))
  assert(vim.b[child].straps_model == nil, tostring(vim.b[child].straps_model))
  assert(dispatch(child) == "openai")
end)

it("effort: explicit wins, otherwise the parent's is inherited", function()
  local explicit = spawn({ straps_effort = "medium" }, { effort = "high" }, { config_provider = "openai" })
  assert(vim.b[explicit].straps_effort == "high", tostring(vim.b[explicit].straps_effort))
  local inherited = spawn({ straps_effort = "medium" }, {}, { config_provider = "openai" })
  assert(vim.b[inherited].straps_effort == "medium", tostring(vim.b[inherited].straps_effort))
end)
