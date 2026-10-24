-- tests/spawn_model_spec.lua — tool.spawn provider/model/effort selection.
--   busted tests/spawn_model_spec.lua

local script = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(vim.fn.fnamemodify(script, ":p"), ":h:h")
vim.opt.runtimepath:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local straps = require("straps").setup({})
straps.config.session_dir = vim.fn.tempname()

local registry = require("straps.registry")
local loop = require("straps.loop")

local function define(name, source)
  registry.define({ name = name, kind = "fn", doc = "test", source = source }, { scope = "global" })
end

define("fn.provider_openai", [[return function(req, ctx) return { backend = "openai", bufnr = ctx.bufnr } end]])
define("fn.provider_anthropic", [[return function(req, ctx) return { backend = "anthropic", bufnr = ctx.bufnr } end]])

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

it("an unknown provider is kept so the dispatcher rejects it", function()
  local child = spawn(both, { provider = "bogus" })
  assert(vim.b[child].straps_provider == "bogus", tostring(vim.b[child].straps_provider))
  local backend, err = dispatch(child)
  assert(backend == nil and tostring(err):find("unknown provider bogus", 1, true), tostring(err))
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
