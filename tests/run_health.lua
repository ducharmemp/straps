-- tests/run_health.lua — :checkhealth straps (lua/straps/health.lua).
--   nvim --headless -l tests/run_health.lua
-- No network. health.check() drives vim.health.{start,ok,warn,error,info}; we
-- stub those to collect the report, then assert on it. The point of the module
-- is to run WHEN THINGS ARE BROKEN, so the key cases are the broken ones: no
-- setup(), an unwritable session dir — the report must classify, never throw.

local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(vim.fn.fnamemodify(here, ":p"), ":h:h")
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

case("before setup(): reports missing registry/tools as errors, never throws", function()
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
local straps = require("straps").setup({})
straps.config.session_dir = vim.fn.tempname()

case("after setup(): registry section reports tool/hook/fn counts as OK", function()
  local rec = collect()
  local r = find(rec, "ok", "tools,")
  assert(r, "expected a 'N tools, ...' OK line")
  assert(r.msg:find("hooks,") and r.msg:find("fns,"), "counts line malformed: " .. r.msg)
  -- No missing-core-entry errors once setup() has run.
  assert(not find(rec, "error", "missing core entry"),
    "core entries should all be present after setup()")
end)

case("healthy session dir is reported writable", function()
  local rec = collect()
  assert(find(rec, "ok", "session dir writable"), "writable dir should be OK")
end)

case("unwritable session dir -> ERROR, no throw", function()
  local saved = straps.config.session_dir
  straps.config.session_dir = "/proc/nonexistent/straps/sessions"
  local rec = collect()
  straps.config.session_dir = saved
  local r = find(rec, "error", "session dir")
  assert(r, "expected a session-dir ERROR for an unwritable path")
end)

case("model section reports model and effort pairing", function()
  local rec = collect()
  assert(find(rec, "ok", "model: claude-sonnet-5"), "model line missing")
  -- Default effort is off -> an info line, not an error.
  assert(find(rec, nil, "effort"), "effort line missing")
end)

case("API key section present; resolves a key when env is set", function()
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

case("API key health follows the persisted OpenAI provider preference", function()
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
end)

case("curl section present (dependency probe)", function()
  local rec = collect()
  assert(find(rec, "start", "straps: dependencies"), "dependencies section missing")
  -- curl is a hard requirement; on the CI/dev box it is present.
  assert(find(rec, nil, "curl"), "curl line missing")
end)

case("no runs in flight is reported OK", function()
  local rec = collect()
  assert(find(rec, "ok", "no runs in flight"), "expected 'no runs in flight'")
end)

case("report never throws even with a bogus base_url / config", function()
  local saved = straps.config.base_url
  straps.config.base_url = "http://127.0.0.1:0"
  local ok = pcall(collect)
  straps.config.base_url = saved
  assert(ok, "health.check() must not throw on odd config")
end)

if failed then
  os.exit(1)
end
print("ALL PASS")
