-- tests/health_spec.lua — :checkhealth straps (lua/straps/health.lua).
--   busted tests/health_spec.lua
-- No network. health.check() drives vim.health.{start,ok,warn,error,info}; we
-- stub those to collect the report, then assert on it. The point of the module
-- is to run WHEN THINGS ARE BROKEN, so the key cases are the broken ones: no
-- setup(), an unwritable session dir — the report must classify, never throw.

local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(vim.fn.fnamemodify(here, ":p"), ":h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

-- Runs `fn` at test time, in document order with the surrounding `it`s (the
-- old runner executed cases inline; busted collects first, then runs).
local function step(fn)
  local info = debug.getinfo(fn, "S")
  describe("step@" .. info.short_src .. ":" .. info.linedefined, function() setup(fn) end)
end


-- Collect a health run into a flat record list, restoring vim.health after.
local function collect()
  local rec = {}
  local orig = {}
  for _, k in ipairs({ "start", "ok", "warn", "error", "info" }) do
    orig[k] = vim.health[k]
    vim.health[k] = function(msg, extra)
      rec[#rec + 1] = { kind = k, msg = tostring(msg), extra = extra }
    end
  end
  local ok, err = pcall(function()
    package.loaded["straps.health"] = nil
    require("straps.health").check()
  end)
  for k, v in pairs(orig) do
    vim.health[k] = v
  end
  assert(ok, "health.check() threw: " .. tostring(err))
  return rec
end

-- Predicates over a collected report.
local function count(rec, kind)
  local n = 0
  for _, r in ipairs(rec) do
    if r.kind == kind then n = n + 1 end
  end
  return n
end
local function find(rec, kind, substr)
  for _, r in ipairs(rec) do
    if (kind == nil or r.kind == kind) and r.msg:find(substr, 1, true) then
      return r
    end
  end
  return nil
end

-- Isolate every run from the user's real environment.
vim.env.XDG_DATA_HOME = vim.fn.tempname() .. "/xdg"
-- Hermetic config dir: a real ~/.config/straps provider or model_<provider>
-- pref file would change the provider and model health reports.
vim.env.XDG_CONFIG_HOME = vim.fn.tempname()
vim.fn.mkdir(vim.env.XDG_CONFIG_HOME, "p")

it("before setup(): reports missing registry/tools as errors, never throws", function()
  -- A pristine registry state: whatever this process has, health must cope.
  local rec = collect()
  assert(#rec > 0, "expected a report")
  -- Sections always present regardless of state.
  assert(find(rec, "start", "straps: neovim"), "missing neovim section")
  assert(find(rec, "start", "straps: registry"), "missing registry section")
  -- nvim version check is environment-true, always OK on the test runner.
  assert(find(rec, "ok", ">= 0.11 required"), "nvim version should be OK")
end)

-- From here on, a real setup so the healthy path is exercised too.
local straps
step(function()
  straps = require("straps").setup({})
  straps.config.session_dir = vim.fn.tempname()
end)

it("after setup(): registry section reports tool/hook/fn counts as OK", function()
  local rec = collect()
  local r = find(rec, "ok", "tools,")
  assert(r, "expected a 'N tools, ...' OK line")
  assert(r.msg:find("hooks,") and r.msg:find("fns,"), "counts line malformed: " .. r.msg)
  -- No missing-core-entry errors once setup() has run.
  assert(not find(rec, "error", "missing core entry"),
    "core entries should all be present after setup()")
end)

it("healthy session dir is reported writable", function()
  local rec = collect()
  assert(find(rec, "ok", "session dir writable"), "writable dir should be OK")
end)

it("unwritable session dir -> ERROR, no throw", function()
  local saved = straps.config.session_dir
  straps.config.session_dir = "/proc/nonexistent/straps/sessions"
  local rec = collect()
  straps.config.session_dir = saved
  local r = find(rec, "error", "session dir")
  assert(r, "expected a session-dir ERROR for an unwritable path")
end)

local function with_provider(name, fn)
  local saved = straps.config.provider
  straps.config.provider = name
  local ok, res = pcall(fn)
  straps.config.provider = saved
  if not ok then error(res, 0) end
  return res
end

it("model section reports model and effort pairing", function()
  local rec = with_provider("anthropic", collect)
  assert(find(rec, "ok", "anthropic model: claude-sonnet-5"), "model line missing")
  -- Default effort is off -> an info line, not an error.
  assert(find(rec, nil, "effort"), "effort line missing")
end)

it("nil max_tokens is healthy and reports the resolved model max", function()
  -- Default config leaves max_tokens nil; sonnet-5 seeds max_output = 128000.
  assert(straps.config.max_tokens == nil, "test premise: default max_tokens should be nil")
  local rec = with_provider("anthropic", collect)
  local r = find(rec, "ok", "max_tokens: auto")
  assert(r, "nil max_tokens should be an OK 'auto' line, not a warning")
  assert(r.msg:find("model max 128000", 1, true),
    "auto line should name the resolved model max: " .. r.msg)
  assert(not find(rec, "warn", "max_tokens"), "nil max_tokens must not warn")
end)

it("explicit max_tokens reports as an explicit cap; non-positive warns", function()
  local saved = straps.config.max_tokens
  straps.config.max_tokens = 50000
  local rec = with_provider("anthropic", collect)
  assert(find(rec, "ok", "max_tokens: 50000 (explicit cap)"), "explicit cap line missing")
  straps.config.max_tokens = 0
  local rec0 = with_provider("anthropic", collect)
  assert(find(rec0, "warn", "max_tokens is set but not a positive number"),
    "a non-positive explicit cap should warn")
  straps.config.max_tokens = saved
end)

it("API key section present; resolves a key when env is set", function()
  local saved_key = vim.env.ANTHROPIC_API_KEY
  local saved_provider = straps.config.provider
  straps.config.provider = "anthropic"
  vim.env.ANTHROPIC_API_KEY = "sk-test-key-for-health"
  local rec = collect()
  vim.env.ANTHROPIC_API_KEY = saved_key
  straps.config.provider = saved_provider
  assert(find(rec, "start", "straps: API key (anthropic)"), "API key section missing")
  assert(find(rec, "ok", "fn.api_key resolves a key"), "key should resolve")
end)

it("API key health follows the persisted OpenAI provider preference", function()
  local saved_provider = straps.config.provider
  local saved_xdg = vim.env.XDG_CONFIG_HOME
  local saved_oai = vim.env.OPENAI_API_KEY
  local prefdir = vim.fn.tempname()
  vim.fn.mkdir(prefdir, "p")
  vim.env.XDG_CONFIG_HOME = prefdir
  straps.config.provider = nil
  require("straps.registry").call("fn.provider_pref", "openai")
  vim.env.OPENAI_API_KEY = "sk-openai-health"
  local rec = collect()
  straps.config.provider = saved_provider
  vim.env.XDG_CONFIG_HOME = saved_xdg
  vim.env.OPENAI_API_KEY = saved_oai
  assert(find(rec, "start", "straps: API key (openai)"), "health did not select OpenAI")
  assert(find(rec, "ok", "fn.openai_api_key resolves a key"), "OpenAI key should resolve")
  assert(find(rec, "ok", "source: env"), "health should name the key source")
  assert(find(rec, "info", "no ChatGPT login"), "health should report the missing ChatGPT login")
end)

it("API key health follows the persisted llamacpp preference without probing Anthropic keys", function()
  local saved_provider = straps.config.provider
  local saved_xdg = vim.env.XDG_CONFIG_HOME
  local saved_llama = vim.env.LLAMACPP_API_KEY
  local saved_server = vim.env.LLAMA_API_KEY
  vim.env.LLAMA_API_KEY = nil
  local saved_base = straps.config.llamacpp_base_url
  local prefdir = vim.fn.tempname()
  vim.fn.mkdir(prefdir, "p")
  vim.env.XDG_CONFIG_HOME = prefdir
  straps.config.provider = nil
  straps.config.llamacpp_base_url = "http://user:p@secret@192.0.2.7:8080/?token=qsecret"
  require("straps.registry").call("fn.provider_pref", "llamacpp")
  vim.env.LLAMACPP_API_KEY = nil
  local rec = collect()
  vim.env.LLAMACPP_API_KEY = "llama-health-key"
  local rec_key = collect()
  straps.config.provider = saved_provider
  vim.env.XDG_CONFIG_HOME = saved_xdg
  vim.env.LLAMACPP_API_KEY = saved_llama
  vim.env.LLAMA_API_KEY = saved_server
  straps.config.llamacpp_base_url = saved_base
  assert(find(rec, "start", "straps: API key (llamacpp)"), "health did not select llamacpp")
  assert(find(rec, "info", "http://***@192.0.2.7:8080"), "base url not reported")
  for _, r in ipairs(rec) do
    assert(not r.msg:find("secret", 1, true), "URL password or query token printed: " .. r.msg)
  end
  assert(find(rec, "info", "no API key"), "missing key should be info")
  assert(not find(rec, nil, "ANTHROPIC_API_KEY"), "Anthropic key probed under llamacpp")
  assert(not find(rec, nil, "fn.api_key"), "fn.api_key probed under llamacpp")
  assert(find(rec_key, "ok", "API key set (16 chars)"), "set key not reported")
end)

local function collect_with(provider, overrides, key_source)
  local registry = require("straps.registry")
  local saved, real_key = {}, registry.get("fn.llamacpp_api_key")
  for k, v in pairs(overrides or {}) do
    saved[k] = straps.config[k]
    straps.config[k] = v ~= vim.NIL and v or nil
  end
  if key_source then
    registry.define({ name = "fn.llamacpp_api_key", kind = "fn", doc = "test", source = key_source })
  end
  local ok, rec = pcall(with_provider, provider, collect)
  if key_source then
    registry.define({ name = real_key.name, kind = real_key.kind, doc = real_key.doc, source = real_key.source })
  end
  for k in pairs(overrides or {}) do straps.config[k] = saved[k] end
  if not ok then error(rec, 0) end
  return rec
end

it("llamacpp key health reports a redefined fn.llamacpp_api_key", function()
  local saved_llama = vim.env.LLAMACPP_API_KEY
  vim.env.LLAMACPP_API_KEY = nil
  local ok, rec = pcall(collect_with, "llamacpp", nil, [[return function() return "from-the-registry" end]])
  local ok_raise, rec_raise = pcall(collect_with, "llamacpp", nil, [[return function() error("vault locked") end]])
  vim.env.LLAMACPP_API_KEY = saved_llama
  assert(ok, tostring(rec))
  assert(ok_raise, tostring(rec_raise))
  assert(find(rec, "ok", "API key set (17 chars)"), "redefined key source not reported")
  local raised = find(rec_raise, "error", "fn.llamacpp_api_key raised")
  assert(raised and vim.inspect(raised.extra):find("vault locked", 1, true), "raising key source not reported as an error")
end)

it("an unreadable provider pref file and an unparseable model pref file are health errors naming the file", function()
  local saved_xdg, saved_provider, saved_model = vim.env.XDG_CONFIG_HOME, straps.config.provider, straps.config.model
  vim.env.XDG_CONFIG_HOME = vim.fn.tempname()
  vim.fn.mkdir(vim.env.XDG_CONFIG_HOME .. "/straps", "p")
  local pref = vim.env.XDG_CONFIG_HOME .. "/straps/provider"
  vim.fn.writefile({ "llamacpp" }, pref)
  vim.uv.fs_chmod(pref, 0)
  straps.config.provider = nil
  local ok1, rec_provider = pcall(collect)
  vim.uv.fs_chmod(pref, 420)
  vim.fn.delete(pref)
  vim.fn.writefile({ "claude-opus-4-8" }, vim.env.XDG_CONFIG_HOME .. "/straps/model_anthropic")
  straps.config.model = nil
  local ok2, rec_model = pcall(with_provider, "anthropic", collect)
  vim.env.XDG_CONFIG_HOME, straps.config.provider, straps.config.model = saved_xdg, saved_provider, saved_model
  assert(ok1, tostring(rec_provider))
  assert(ok2, tostring(rec_model))
  assert(find(rec_provider, "error", "exists but could not be read"), "the unreadable provider pref was not reported")
  assert(not find(rec_provider, nil, "unknown provider nil"), "health reported the unreadable pref as provider nil")
  assert(find(rec_model, "error", "model_anthropic is not a JSON object"), "the unparseable model pref was not reported")
  assert(not find(rec_model, "warn", "config.model is unset"), "health pointed at config.model instead of the file")
end)

it("an unknown provider name in the pref file is a health error", function()
  local saved_xdg, saved_provider = vim.env.XDG_CONFIG_HOME, straps.config.provider
  vim.env.XDG_CONFIG_HOME = vim.fn.tempname()
  vim.fn.mkdir(vim.env.XDG_CONFIG_HOME .. "/straps", "p")
  vim.fn.writefile({ "llama.cpp" }, vim.env.XDG_CONFIG_HOME .. "/straps/provider")
  straps.config.provider = nil
  local ok, rec = pcall(collect)
  vim.env.XDG_CONFIG_HOME, straps.config.provider = saved_xdg, saved_provider
  assert(ok, tostring(rec))
  assert(find(rec, "error", "unknown provider llama.cpp"), "an unknown pref-file provider was not reported")
end)

it("an unknown provider name is a health error, not a quiet anthropic report", function()
  local rec = collect_with("llamcpp", {})
  local err = find(rec, "error", "unknown provider llamcpp")
  assert(err, "unknown provider not reported as an error")
  assert(vim.inspect(err.extra):find("llamacpp", 1, true), "remedy should list the valid names")
  local section
  for _, r in ipairs(rec) do
    if r.kind == "start" then section = r.msg end
    if r == err then break end
  end
  assert(section == "straps: provider", "the error is filed under " .. tostring(section))
  assert(not find(rec, "start", "API key (anthropic)"), "an unknown provider got an Anthropic key section")
  assert(not find(rec, "ok", "anthropic model"), "an unknown provider got an Anthropic model line")
end)

it("model section follows the active provider", function()
  local listed = { llamacpp_model = "qwen-dense", llamacpp_models = { { id = "qwen-dense", max_output = 4096 } } }
  local rec = collect_with("llamacpp", listed)
  assert(find(rec, "ok", "llamacpp model: qwen-dense"), "llamacpp model line missing")
  assert(find(rec, "ok", "max_tokens: auto (model max 4096"), "llamacpp_models max_output not used")
  assert(not find(rec, "info", "model is not in config.llamacpp_models"), "listed llamacpp model reported unlisted")

  local rec_effort = collect_with("llamacpp", vim.tbl_extend("force", listed, { effort = "high" }))
  assert(find(rec_effort, "info", "effort = high is inert"), "llamacpp effort should be reported inert")
  assert(not find(rec_effort, "ok", "effort: high"), "llamacpp effort reported as working")

  local rec_unlisted = collect_with("llamacpp", { llamacpp_model = "qwen-dense", llamacpp_models = {} })
  assert(find(rec_unlisted, "ok", "max_tokens: auto (default_max_tokens"), "max_tokens line missing under llamacpp")

  local rec_unset = collect_with("llamacpp", { llamacpp_model = vim.NIL })
  local unset = find(rec_unset, "warn", "config.llamacpp_model is unset")
  assert(unset, "unset llamacpp model should warn")
  assert(vim.inspect(unset.extra):find("set llamacpp_model in setup{} or run :StrapsModel", 1, true),
    "unset llamacpp model warning lacks the remedy: " .. vim.inspect(unset))
  assert(find(rec_unset, "ok", "max_tokens: auto"), "max_tokens line missing with an unset model")

  local rec_oai = collect_with("openai", { openai_model = "gpt-5-mini" })
  assert(find(rec_oai, "ok", "openai model: gpt-5-mini"), "openai model line missing")
  assert(not find(rec_oai, "ok", "model: claude"), "openai health reported the Anthropic model")

  local rec_reasoning = collect_with("openai",
    { openai_model = "gpt-5-mini", effort = "high", openai_models = { { id = "gpt-5-mini", reasoning = true, max_output = 999 } } })
  local rec_plain = collect_with("openai",
    { openai_model = "gpt-5-mini", effort = "high", openai_models = { { id = "gpt-5-mini" } } })
  assert(find(rec_reasoning, "ok", "effort: high"), "an opted-in openai model should report effort as working")
  local rec_reasoning_effort = collect_with("openai",
    { openai_model = "gpt-5-mini", effort = "high", openai_models = { { id = "gpt-5-mini", reasoning_effort = true } } })
  assert(find(rec_reasoning_effort, "ok", "effort: high"), "reasoning_effort = true should report effort as working")
  assert(find(rec_plain, "info", "effort = high is inert"), "an openai model without reasoning should report inert")
  assert(find(rec_reasoning, "ok", "effort: high  (reasoning)"), "openai effort line should report reasoning")
  local rec_oai_off = collect_with("openai",
    { openai_model = "gpt-5-mini", effort = "off", openai_models = { { id = "gpt-5-mini", reasoning = true } } })
  assert(not find(rec_oai_off, nil, "thinking style: nil"), "openai health printed a thinking style")
  assert(not find(rec_reasoning, "ok", "model max 999"), "openai health reported a max_output the backend never sends")

  local rec_adaptive = collect_with("anthropic",
    { model = "claude-x", effort = "high", models = { { id = "claude-x", thinking = "adaptive" } } })
  local rec_untagged = collect_with("anthropic",
    { model = "claude-x", effort = "high", models = { { id = "claude-x" } } })
  assert(find(rec_adaptive, "ok", "effort: high  (thinking style: adaptive)"), "anthropic thinking model effort not ok")
  assert(find(rec_untagged, "info", "effort = high is inert"), "anthropic untagged model effort should be inert")
  local rec_noentry = collect_with("anthropic",
    { model = "claude-x", effort = "turbo", models = { { id = "claude-x", thinking = "adaptive" } } })
  assert(find(rec_noentry, "info", "config.efforts has no entry named turbo"),
    "an effort with no config.efforts entry should be reported inert")
end)

it("curl section present (dependency probe)", function()
  local rec = collect()
  assert(find(rec, "start", "straps: dependencies"), "dependencies section missing")
  -- curl is a hard requirement; on the CI/dev box it is present.
  assert(find(rec, nil, "curl"), "curl line missing")
end)

it("no runs in flight is reported OK", function()
  local rec = collect()
  assert(find(rec, "ok", "no runs in flight"), "expected 'no runs in flight'")
end)

it("layers section reports both default-on layers as OK", function()
  local rec = collect()
  assert(find(rec, "start", "straps: layers"), "missing layers section")
  assert(find(rec, "ok", "editor layer enabled"), "editor layer should be OK by default")
  assert(find(rec, "ok", "openai layer enabled"), "openai layer should be OK by default")
end)

it("disabled layer reports as info, not error", function()
  local saved = straps.config.layers
  straps.config.layers = { editor = true, openai = false }
  local rec = collect()
  straps.config.layers = saved
  -- The openai entries ARE registered in this process (setup ran all-on);
  -- the flag alone must flip the report to the deliberate-off info line.
  assert(find(rec, "info", "openai layer disabled"), "expected the disabled info line")
  assert(not find(rec, "error", "openai layer"), "a disabled layer must not error")
end)

it("report never throws even with a bogus base_url / config", function()
  local saved = straps.config.base_url
  straps.config.base_url = "http://127.0.0.1:0"
  local ok = pcall(collect)
  straps.config.base_url = saved
  assert(ok, "health.check() must not throw on odd config")
end)
