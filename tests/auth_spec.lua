-- Auth and endpoint tests: provider.base_url / normalize_base_url /
-- auth_headers, the key store fn.api_key_store, the key order every default
-- key fn shares (stored key, then env), the URL and auth header each request
-- path sends (a fake `curl` first on PATH logs argv), :StrapsLogin and
-- :StrapsLogout for every provider, and the slot-driven health key
-- section.
-- Run: busted tests/auth_spec.lua

local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(vim.fn.fnamemodify(here, ":p"), ":h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local tmp = vim.fn.tempname()
local xdg = tmp .. "/config"
vim.fn.mkdir(xdg, "p")
vim.env.XDG_CONFIG_HOME = xdg
vim.env.HOME = tmp .. "/home"
local KEY_VARS = { "ANTHROPIC_API_KEY", "OPENAI_API_KEY", "LLAMACPP_API_KEY", "LLAMA_API_KEY" }
for _, var in ipairs(KEY_VARS) do
  vim.env[var] = nil
end

local straps = require("straps").setup({})
straps.config.session_dir = vim.fn.tempname()
straps.config.gzip = false
local registry = require("straps.registry")
local providers = require("straps.provider")
local ui = require("straps.ui")

vim.fn.mkdir(tmp .. "/bin", "p")
local fake = ([[#!/usr/bin/env bash
D=%q
printf '%%s\n' "$*" >> "$D/argv"
cat > /dev/null
case "$*" in
  */v1/models*)
    printf '{"data":[{"id":"m1"}]}\nSTRAPS_HTTP_STATUS:200\n'
    ;;
  */v1/responses*)
    echo "STRAPS_HTTP_STATUS:200" >&2
    printf 'event: response.output_text.delta\ndata: {"type":"response.output_text.delta","output_index":0,"delta":"ok"}\n\n'
    printf 'event: response.completed\ndata: {"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":1,"output_tokens":1}}}\n\n'
    ;;
  *)
    echo "STRAPS_HTTP_STATUS:200" >&2
    printf 'event: content_block_start\ndata: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}\n\n'
    printf 'event: content_block_delta\ndata: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ok"}}\n\n'
    printf 'event: content_block_stop\ndata: {"type":"content_block_stop","index":0}\n\n'
    printf 'event: message_delta\ndata: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}\n\n'
    printf 'event: message_stop\ndata: {"type":"message_stop"}\n\n'
    ;;
esac
]]):format(tmp)
fake = fake:gsub("^#!/usr/bin/env bash", "#!" .. vim.fn.exepath("bash"), 1)
vim.fn.writefile(vim.split(fake, "\n"), tmp .. "/bin/curl")
vim.fn.setfperm(tmp .. "/bin/curl", "rwxr-xr-x")
vim.env.PATH = tmp .. "/bin:" .. vim.env.PATH

local function key_path(name) return xdg .. "/straps/" .. name .. "_api_key" end
local function write_key(name, text, mode)
  vim.fn.mkdir(xdg .. "/straps", "p")
  vim.fn.writefile({ text }, key_path(name))
  vim.fn.setfperm(key_path(name), mode or "rw-------")
end
local function clear_keys()
  for _, name in ipairs(providers.provider_names()) do vim.fn.delete(key_path(name)) end
end
local function take_argv()
  local lines = vim.fn.filereadable(tmp .. "/argv") == 1 and vim.fn.readfile(tmp .. "/argv") or {}
  vim.fn.delete(tmp .. "/argv")
  return table.concat(lines, "\n")
end
local function capture_notify(fn)
  local msgs = {}
  local orig = vim.notify
  vim.notify = function(m, lvl) msgs[#msgs + 1] = { msg = tostring(m), level = lvl } end
  local ok, err = pcall(fn)
  vim.notify = orig
  assert(ok, tostring(err))
  return msgs
end
local function has(msgs, s)
  for _, m in ipairs(msgs) do if m.msg:find(s, 1, true) then return m end end
end
local function with_input(answer, fn)
  local orig = vim.fn.inputsecret
  vim.fn.inputsecret = function() return answer end
  local ok, err = pcall(fn)
  vim.fn.inputsecret = orig
  assert(ok, tostring(err))
end

-- Runs fn with registry entry `name` redefined to `source` (or removed when
-- source is nil), restoring the real entry even when fn raises.
local function with_entry(name, source, fn)
  local real = registry.get(name)
  if source then
    registry.define({ name = name, kind = "fn", doc = "test", source = source })
  else
    registry.remove(name)
  end
  local ok, err = pcall(fn)
  registry.define({ name = real.name, kind = real.kind, doc = real.doc, source = real.source })
  assert(ok, tostring(err))
end

-- Runs fn after saving the named environment variables, restoring them even
-- when fn raises.
local function with_env(names, fn)
  local saved = {}
  for _, n in ipairs(names) do saved[n] = vim.env[n] end
  local ok, err = pcall(fn)
  for _, n in ipairs(names) do vim.env[n] = saved[n] end
  assert(ok, tostring(err))
end

-- A test that raises before its own cleanup would leave env or config set for
-- every later test; reset both after each test.
local CONFIG_DEFAULTS = { provider = false, base_url = false, openai_base_url = false, llamacpp_base_url = false,
  openai_model = false, llamacpp_model = "llama-test" }
after_each(function()
  vim.env.XDG_CONFIG_HOME = xdg
  vim.env.HOME = tmp .. "/home"
  for _, var in ipairs(KEY_VARS) do vim.env[var] = nil end
  for k, v in pairs(CONFIG_DEFAULTS) do straps.config[k] = v or nil end
end)

-- Runs one request through fn.provider for `provider` and returns the curl argv.
local function request(provider)
  local saved_provider = straps.config.provider
  straps.config.provider = provider
  local b = vim.api.nvim_create_buf(false, true)
  local ctx = {
    bufnr = b,
    emit = function() end,
    cancelled = function() return false end,
    on_cancel = function() end,
    await = function(start)
      local res, done = nil, false
      start(function(...) if not done then done, res = true, { n = select("#", ...), ... } end end)
      vim.wait(15000, function() return done end, 10)
      return unpack(res, 1, res.n)
    end,
  }
  local co = coroutine.create(function()
    return registry.call("fn.provider", { system = "s", messages = { { role = "user", content = "hi" } }, tools = {} }, ctx)
  end)
  local ok, res = coroutine.resume(co)
  straps.config.provider = saved_provider
  assert(ok, tostring(res))
  assert(type(res) == "table" and res.stop_reason ~= nil, vim.inspect(res))
  return take_argv()
end

straps.config.llamacpp_model = "llama-test"

-- ------------------------------------------------------------- base URL
it("provider.base_url: nil or empty config gives the slot default", function()
  for _, slot in ipairs(providers.PROVIDERS) do
    assert(providers.base_url(slot.name, {}) == slot.default_base_url, slot.name)
    assert(providers.base_url(slot.name, { [slot.base_url_key] = "" }) == slot.default_base_url, slot.name)
  end
  assert(providers.base_url("anthropic", {}) == "https://api.anthropic.com")
  assert(providers.base_url("openai", {}) == "https://api.openai.com")
  assert(providers.base_url("llamacpp", {}) == "http://127.0.0.1:8080")
  assert(providers.base_url("nope", {}) == nil)
end)

it("provider.base_url: a configured URL wins, with a trailing / and /v1 dropped", function()
  for _, slot in ipairs(providers.PROVIDERS) do
    local got = providers.base_url(slot.name, { [slot.base_url_key] = "http://h.invalid:1/v1/" })
    assert(got == "http://h.invalid:1", slot.name .. ": " .. tostring(got))
    got = providers.base_url(slot.name, { [slot.base_url_key] = "http://h.invalid:1/" })
    assert(got == "http://h.invalid:1", slot.name .. ": " .. tostring(got))
  end
end)

it("provider.auth_headers: x-api-key for anthropic, Bearer for openai and llamacpp, none without an optional key", function()
  assert(vim.deep_equal(providers.auth_headers("anthropic", "k"), { "-H", "x-api-key: k" }))
  assert(vim.deep_equal(providers.auth_headers("openai", "k"), { "-H", "Authorization: Bearer k" }))
  assert(vim.deep_equal(providers.auth_headers("llamacpp", "k"), { "-H", "Authorization: Bearer k" }))
  assert(vim.deep_equal(providers.auth_headers("llamacpp", nil), {}))
  assert(vim.deep_equal(providers.auth_headers("llamacpp", ""), {}))
end)

it("provider.auth_headers: a missing required key and an unknown provider raise", function()
  for _, p in ipairs({ "anthropic", "openai" }) do
    for _, key in ipairs({ "", false, "   " }) do
      local ok, err = pcall(providers.auth_headers, p, key)
      assert(not ok and tostring(err):find(providers.provider_slot(p).key_fn .. " returned no key", 1, true), p .. ": " .. tostring(err))
    end
  end
  local ok, err = pcall(providers.auth_headers, "nope", "k")
  assert(not ok and tostring(err):find("unknown provider nope", 1, true), tostring(err))
end)

it("provider.normalize_base_url: one pass removes every trailing / and /v1", function()
  local seen = 0
  for _, a in ipairs({ "", "/", "//", "/v1", "/v1/", "/v1/v1", "/v1//v1/" }) do
    for _, b in ipairs({ "", "/", "/v1", "/v1/" }) do
      local url = "http://h.invalid:1" .. a .. b
      local once = providers.normalize_base_url(url)
      assert(once == "http://h.invalid:1", url .. " -> " .. tostring(once))
      assert(providers.normalize_base_url(once) == once, url)
      seen = seen + 1
    end
  end
  assert(seen == 28)
  assert(providers.normalize_base_url("http://h.invalid/v1x") == "http://h.invalid/v1x")
  assert(providers.normalize_base_url(nil) == nil)
end)

it("provider.normalize_base_url: a host named v1 is kept", function()
  assert(providers.normalize_base_url("http://v1") == "http://v1")
  assert(providers.normalize_base_url("http://v1/v1/") == "http://v1")
  assert(providers.normalize_base_url("http://v1:8080/v1") == "http://v1:8080")
end)

it("provider.base_url: a non-string value or an unknown provider returns nil and an error", function()
  for _, bad in ipairs({ { "http://gpu:8080" }, 8080, false }) do
    local url, err = providers.base_url("llamacpp", { llamacpp_base_url = bad })
    assert(url == nil and tostring(err):find("config.llamacpp_base_url must be a URL string (got " .. type(bad) .. ")", 1, true),
      vim.inspect(bad) .. ": " .. tostring(err))
  end
  local url, err = providers.base_url("nope", {})
  assert(url == nil and tostring(err):find("unknown provider nope", 1, true), tostring(err))
end)

it("a non-string base URL fails requests and model lists with the config key named, for every provider", function()
  write_key("anthropic", "sk-ant")
  write_key("openai", "sk-oai")
  write_key("llamacpp", "sk-llama")
  for _, slot in ipairs(providers.PROVIDERS) do
    straps.config[slot.base_url_key] = 1
    local ok_req, req_err = pcall(request, slot.name)
    local models, list_err = registry.call("fn.list_models", slot.name)
    straps.config[slot.base_url_key] = nil
    local argv = take_argv()
    local want = "config." .. slot.base_url_key .. " must be a URL string (got number)"
    assert(not ok_req and tostring(req_err):find(want, 1, true), slot.name .. ": " .. tostring(req_err))
    assert(models == nil and tostring(list_err):find(want, 1, true), slot.name .. ": " .. tostring(list_err))
    assert(argv == "", slot.name .. ": curl should not run:\n" .. argv)
  end
  clear_keys()
end)

-- ------------------------------------------------------------- key store
it("fn.api_key_store: reads nil and the path when absent, writes mode 600, reads it back trimmed", function()
  clear_keys()
  local key, path = registry.call("fn.api_key_store", "anthropic")
  assert(key == nil and path == key_path("anthropic"), tostring(key) .. " " .. tostring(path))
  local saved, spath = registry.call("fn.api_key_store", "anthropic", "  sk-a  ")
  assert(saved == "sk-a" and spath == key_path("anthropic"))
  assert(vim.uv.fs_stat(key_path("anthropic")).mode % 512 == 384, "mode should be 600")
  assert(registry.call("fn.api_key_store", "anthropic") == "sk-a")
end)

it("fn.api_key_store: a blank file reads nil; a group-readable file raises without the key", function()
  write_key("llamacpp", "   ")
  assert(registry.call("fn.api_key_store", "llamacpp") == nil)
  write_key("llamacpp", "leaky", "rw-r--r--")
  local ok, err = pcall(registry.call, "fn.api_key_store", "llamacpp")
  assert(not ok and tostring(err):find("chmod 600", 1, true) and not tostring(err):find("leaky", 1, true), tostring(err))
  clear_keys()
end)

it("fn.api_key_store: false deletes and reports whether a file was removed", function()
  write_key("openai", "sk-o")
  local removed, path = registry.call("fn.api_key_store", "openai", false)
  assert(removed == true and path == key_path("openai"))
  removed, path = registry.call("fn.api_key_store", "openai", false)
  assert(removed == false and path == key_path("openai"))
end)

it("fn.api_key_store: an unknown provider name raises and touches no file", function()
  local ok, err = pcall(registry.call, "fn.api_key_store", "../x", "k")
  assert(not ok and tostring(err):find("unknown provider", 1, true), tostring(err))
  assert(vim.fn.filereadable(xdg .. "/x_api_key") == 0)
end)

it("fn.api_key_store: with no XDG_CONFIG_HOME or HOME, read and delete give nil and a write raises", function()
  local k, p, r, rp, ok, err, ok_fn, fn_err
  with_env({ "HOME", "XDG_CONFIG_HOME" }, function()
    vim.env.XDG_CONFIG_HOME = nil
    vim.env.HOME = nil
    k, p = registry.call("fn.api_key_store", "anthropic")
    r, rp = registry.call("fn.api_key_store", "anthropic", false)
    ok, err = pcall(registry.call, "fn.api_key_store", "anthropic", "k")
    ok_fn, fn_err = pcall(registry.call, "fn.anthropic_api_key")
  end)
  assert(k == nil and p == nil and r == nil and rp == nil)
  assert(not ok and tostring(err):find("no $XDG_CONFIG_HOME or $HOME", 1, true), tostring(err))
  assert(not ok_fn and tostring(fn_err):find(":StrapsLogin anthropic to store one", 1, true)
    and not tostring(fn_err):find("write the key to", 1, true), tostring(fn_err))
end)

-- ------------------------------------------------------------- key order
it("fn.llamacpp_api_key: the key file wins over LLAMACPP_API_KEY, which wins over LLAMA_API_KEY", function()
  local k1, s1, k2, s2, k3, k4
  with_env({ "LLAMACPP_API_KEY", "LLAMA_API_KEY" }, function()
    vim.env.LLAMACPP_API_KEY = "env-a"
    vim.env.LLAMA_API_KEY = "env-b"
    write_key("llamacpp", "file-l")
    k1, s1 = registry.call("fn.llamacpp_api_key")
    clear_keys()
    k2, s2 = registry.call("fn.llamacpp_api_key")
    vim.env.LLAMACPP_API_KEY = nil
    k3 = registry.call("fn.llamacpp_api_key")
    vim.env.LLAMA_API_KEY = nil
    k4 = registry.call("fn.llamacpp_api_key")
  end)
  assert(k1 == "file-l" and s1 == "stored", tostring(k1))
  assert(k2 == "env-a" and s2 == "env", tostring(k2))
  assert(k3 == "env-b", tostring(k3))
  assert(k4 == nil, tostring(k4))
end)

it("fn.llamacpp_api_key: a group-readable key file fails even with the env var set", function()
  vim.env.LLAMACPP_API_KEY = "env-a"
  write_key("llamacpp", "leaky", "rw-r--r--")
  local ok, err = pcall(registry.call, "fn.llamacpp_api_key")
  vim.env.LLAMACPP_API_KEY = nil
  clear_keys()
  assert(not ok and tostring(err):find("chmod 600", 1, true), tostring(err))
end)

it("a redefined fn.api_key_store is what the key fn, login, logout and health use", function()
  clear_keys()
  _G.straps_test_store = {}
  local stored, key, source, rec, msgs, after
  with_entry("fn.api_key_store", [[
return function(provider, value)
  local store = _G.straps_test_store
  if value == false then
    local had = store[provider] ~= nil
    store[provider] = nil
    return had, nil
  end
  if value ~= nil then store[provider] = value return value, nil end
  return store[provider], nil
end
]], function()
    with_input("mem-key", function() ui.login({ "anthropic" }) end)
    stored = _G.straps_test_store.anthropic
    key, source = registry.call("fn.anthropic_api_key")
    rec = {}
    local orig = {}
    for _, k in ipairs({ "start", "ok", "warn", "error", "info" }) do
      orig[k] = vim.health[k]
      vim.health[k] = function(msg) rec[#rec + 1] = tostring(msg) end
    end
    local saved_provider = straps.config.provider
    straps.config.provider = "anthropic"
    local ok_h, err_h = pcall(require("straps.health").check)
    straps.config.provider = saved_provider
    assert(ok_h, tostring(err_h))
    for k, f in pairs(orig) do vim.health[k] = f end
    msgs = capture_notify(function() ui.logout({ "anthropic" }) end)
    after = _G.straps_test_store.anthropic
  end)
  assert(stored == "mem-key", "login did not write through the entry")
  assert(key == "mem-key" and source == "stored", tostring(key))
  assert(vim.tbl_contains(rec, "fn.anthropic_api_key resolves a key (7 chars, source: stored)"), vim.inspect(rec))
  assert(after == nil, "logout did not delete through the entry")
  assert(#msgs == 1 and msgs[1].msg == "straps: deleted the stored anthropic API key", vim.inspect(msgs))
  assert(vim.fn.filereadable(key_path("anthropic")) == 0, "no file should be written")
end)

it("fn.api_key_store refuses to read a hand-written key with spaces or control characters", function()
  local results = {}
  for _, bad in ipairs({ "QZTOKEN\rX", "QZTOKEN a", "QZTOKEN\27b", "QZTOKEN\127b" }) do
    write_key("anthropic", bad)
    local ok, err = pcall(registry.call, "fn.api_key_store", "anthropic")
    results[#results + 1] = { ok, err }
  end
  write_key("openai", "sk a")
  local ok_o, err_o = pcall(registry.call, "fn.api_key_store", "openai")
  clear_keys()
  assert(not ok_o and tostring(err_o):find(":StrapsLogin openai key", 1, true), tostring(err_o))
  for _, r in ipairs(results) do
    assert(not r[1] and tostring(r[2]):find("has spaces or control characters", 1, true)
      and tostring(r[2]):find(":StrapsLogin anthropic", 1, true) and not tostring(r[2]):find("QZTOKEN", 1, true), tostring(r[2]))
  end
end)

it("fn.api_key_store rejects a key with spaces or control characters", function()
  clear_keys()
  for _, bad in ipairs({ "sk-a\nX: b", "sk a", "sk-a\tb", "sk-a\27b", "sk-a\127b" }) do
    local ok, err = pcall(registry.call, "fn.api_key_store", "anthropic", bad)
    assert(not ok and tostring(err):find("fn.api_key_store: the key has spaces or control characters", 1, true), vim.inspect(bad))
  end
  for _, blank in ipairs({ "", "   " }) do
    local ok, err = pcall(registry.call, "fn.api_key_store", "anthropic", blank)
    assert(not ok and tostring(err):find("fn.api_key_store: the key is empty", 1, true), vim.inspect(blank))
  end
  assert(vim.fn.filereadable(key_path("anthropic")) == 0, "nothing should be written")
end)

-- ------------------------------------------------------------- request argv
it("requests go to each provider's default URL with its auth header when no base URL is set", function()
  straps.config.base_url, straps.config.openai_base_url, straps.config.llamacpp_base_url = nil, nil, nil
  write_key("anthropic", "sk-ant")
  write_key("openai", "sk-oai")
  write_key("llamacpp", "sk-llama")
  local a = request("anthropic")
  local o = request("openai")
  local l = request("llamacpp")
  clear_keys()
  assert(a:find("https://api.anthropic.com/v1/messages", 1, true) and a:find("x-api-key: sk-ant", 1, true), a)
  assert(o:find("https://api.openai.com/v1/responses", 1, true) and o:find("Authorization: Bearer sk-oai", 1, true), o)
  assert(l:find("http://127.0.0.1:8080/v1/messages", 1, true) and l:find("Authorization: Bearer sk-llama", 1, true), l)
end)

it("requests and model lists normalize a configured base URL ending in /v1/", function()
  straps.config.base_url = "http://ant.invalid/v1/"
  straps.config.openai_base_url = "http://oai.invalid/v1/"
  straps.config.llamacpp_base_url = "http://llama.invalid/v1/"
  write_key("anthropic", "sk-ant")
  write_key("openai", "sk-oai")
  local a = request("anthropic")
  local o = request("openai")
  local l = request("llamacpp")
  local ok_a = registry.call("fn.list_models", "anthropic")
  local am = take_argv()
  local ok_o = registry.call("fn.list_models", "openai")
  local om = take_argv()
  local ok_l = registry.call("fn.list_models", "llamacpp")
  local lm = take_argv()
  clear_keys()
  straps.config.base_url, straps.config.openai_base_url, straps.config.llamacpp_base_url = nil, nil, nil
  for _, argv in ipairs({ a, o, l, am, om, lm }) do
    assert(not argv:find("/v1/v1/", 1, true), "/v1 doubled:\n" .. argv)
  end
  assert(a:find("http://ant.invalid/v1/messages", 1, true), a)
  assert(o:find("http://oai.invalid/v1/responses", 1, true), o)
  assert(l:find("http://llama.invalid/v1/messages", 1, true) and not l:find("Authorization", 1, true), l)
  assert(ok_a and am:find("http://ant.invalid/v1/models", 1, true) and am:find("x-api-key: sk-ant", 1, true)
    and am:find("anthropic-version: 2023-06-01", 1, true), am)
  assert(ok_o and om:find("http://oai.invalid/v1/models", 1, true) and om:find("Authorization: Bearer sk-oai", 1, true), om)
  assert(ok_l and lm:find("http://llama.invalid/v1/models", 1, true) and not lm:find("anthropic-version", 1, true), lm)
  assert(not om:find("anthropic-version", 1, true), om)
end)

it("fn.anthropic_messages passes the resolved base URL to fn.anthropic_api_key", function()
  _G.straps_test_key_opts = nil
  straps.config.base_url = "http://ant.invalid/v1"
  with_entry("fn.anthropic_api_key", [[return function(opts) _G.straps_test_key_opts = opts return "k", "stored" end]],
    function() request("anthropic") end)
  straps.config.base_url = nil
  local opts = _G.straps_test_key_opts
  assert(type(opts) == "table" and opts.base_url == "http://ant.invalid", vim.inspect(opts))
end)

it("fn.anthropic_messages normalizes an opts.base_url ending in /v1", function()
  _G.straps_test_argv_done = nil
  local co = coroutine.create(function()
    return registry.call("fn.anthropic_messages", { system = "s", messages = { { role = "user", content = "hi" } }, tools = {} },
      { emit = function() end, cancelled = function() return false end, on_cancel = function() end,
        await = function(start)
          local res, done = nil, false
          start(function(...) if not done then done, res = true, { n = select("#", ...), ... } end end)
          vim.wait(15000, function() return done end, 10)
          return unpack(res, 1, res.n)
        end },
      { base_url = "http://opt.invalid/v1/", model = "m", auth_headers = {} })
  end)
  local ok, res = coroutine.resume(co)
  local argv = take_argv()
  assert(ok, tostring(res))
  assert(argv:find("http://opt.invalid/v1/messages", 1, true) and not argv:find("/v1/v1/", 1, true), argv)
end)

it("a key fn that returns nothing fails an anthropic or openai request before curl runs", function()
  local errs = {}
  for _, p in ipairs({ "anthropic", "openai" }) do
    local slot = providers.provider_slot(p)
    with_entry(slot.key_fn, [[return function() return nil end]], function()
      local ok, err = pcall(request, p)
      errs[p] = ok and "no error" or tostring(err)
    end)
  end
  local argv = take_argv()
  assert(errs.anthropic:find("fn.anthropic_api_key returned no key", 1, true), errs.anthropic)
  assert(errs.openai:find("fn.openai_api_key returned no key", 1, true), errs.openai)
  assert(argv == "", "curl should not run:\n" .. argv)
end)

-- ------------------------------------------------------------- login/logout
it(":StrapsLogin anthropic and llamacpp store the typed key; an empty answer stores nothing", function()
  clear_keys()
  local msgs
  with_input("  sk-typed  ", function() msgs = capture_notify(function() ui.login({ "anthropic" }) end) end)
  assert(registry.call("fn.api_key_store", "anthropic") == "sk-typed", "anthropic key not stored")
  assert(has(msgs, "saved the anthropic API key to " .. key_path("anthropic")), vim.inspect(msgs))
  with_input("sk-llama", function() ui.login({ "llamacpp" }) end)
  assert(registry.call("fn.api_key_store", "llamacpp") == "sk-llama", "llamacpp key not stored")
  clear_keys()
  with_input("", function() msgs = capture_notify(function() ui.login({ "anthropic" }) end) end)
  assert(has(msgs, "login cancelled") and registry.call("fn.api_key_store", "anthropic") == nil, vim.inspect(msgs))
end)

it(":StrapsLogin and :StrapsLogout with a key in an argument remove that one history line", function()
  local asked = false
  local orig = vim.fn.inputsecret
  vim.fn.inputsecret = function() asked = true return "x" end
  local cases = {
    { ui.login, { "anthropic", "sk-in-history" }, "StrapsLogin anthropic sk-in-history" },
    { ui.login, { "openai", "key", "sk-in-history" }, "StrapsLogin openai key sk-in-history" },
    { ui.login, { "openai", "sk-in-history" }, "StrapsLogin openai sk-in-history" },
    { ui.login, { "sk-in-history" }, "StrapsLogin sk-in-history" },
    { ui.login, { "sk-in-history", "extra" }, "StrapsLogin sk-in-history extra" },
    { ui.logout, { "sk-in-history" }, "StrapsLogout sk-in-history" },
    { ui.logout, { "anthropic", "sk-in-history" }, "StrapsLogout anthropic sk-in-history" },
    { ui.login, { "openai", "http://127.0.0.1:1455/auth/callback?code=sk-in-history&state=bad" },
      "StrapsLogin openai http://127.0.0.1:1455/auth/callback?code=sk-in-history&state=bad" },
  }
  local results = {}
  for i, c in ipairs(cases) do
    vim.fn.histadd(":", "echo 'before " .. i .. "'")
    vim.fn.histadd(":", c[3])
    local msgs = capture_notify(function() c[1](c[2]) end)
    results[i] = { last = vim.fn.histget(":", -1), msgs = msgs }
  end
  vim.fn.inputsecret = orig
  require("straps.oauth").pending_login = nil
  assert(not asked, "no prompt should run")
  for i, r in ipairs(results) do
    assert(r.last == "echo 'before " .. i .. "'", "case " .. i .. ": history is now " .. r.last)
    for _, m in ipairs(r.msgs) do
      assert(not m.msg:find("sk-in-history", 1, true), "case " .. i .. " echoed the key: " .. m.msg)
    end
  end
  assert(has(results[1].msgs, "usage: :StrapsLogin anthropic"), vim.inspect(results[1].msgs))
  assert(has(results[2].msgs, "usage: :StrapsLogin openai"), vim.inspect(results[2].msgs))
  assert(has(results[7].msgs, "usage: :StrapsLogout"), vim.inspect(results[7].msgs))
end)

it(":StrapsLogin from a mapping or Lua leaves unrelated history alone", function()
  vim.fn.histadd(":", "echo 'mine'")
  capture_notify(function() ui.login({ "anthropic", "extra" }) end)
  local after_extra = vim.fn.histget(":", -1)
  with_input("", function() capture_notify(function() ui.login({ "openai", "key" }) end) end)
  local after_key = vim.fn.histget(":", -1)
  vim.fn.histadd(":", "StrapsLogin openai key")
  with_input("", function() capture_notify(function() ui.login({ "openai", "key" }) end) end)
  local after_typed_key = vim.fn.histget(":", -1)
  assert(after_extra == "echo 'mine'", "an unrelated entry was removed: " .. after_extra)
  assert(after_key == "echo 'mine'", "an unrelated entry was removed: " .. after_key)
  assert(after_typed_key == "StrapsLogin openai key", ":StrapsLogin openai key carries no secret and stays in history")
end)

it(":StrapsLogin reports an unreadable provider pref and prompts for nothing", function()
  if vim.uv.getuid() == 0 then return pending("file modes do not bind root") end
  local saved = straps.config.provider
  straps.config.provider = nil
  vim.fn.writefile({ "anthropic" }, xdg .. "/straps/provider")
  vim.fn.setfperm(xdg .. "/straps/provider", "---------")
  local asked = false
  local orig = vim.fn.inputsecret
  vim.fn.inputsecret = function() asked = true return "x" end
  local msgs = capture_notify(function() ui.login({}) end)
  vim.fn.inputsecret = orig
  vim.fn.delete(xdg .. "/straps/provider")
  straps.config.provider = saved
  assert(not asked, "no prompt should run")
  local m = has(msgs, ":StrapsLogin: ")
  assert(m and m.level == vim.log.levels.ERROR and m.msg:find(xdg .. "/straps/provider", 1, true), vim.inspect(msgs))
end)

it(":StrapsLogin and :StrapsLogout with no argument use the buffer's provider; a stale name is rejected", function()
  clear_keys()
  local saved_provider = straps.config.provider
  straps.config.provider = "anthropic"
  vim.b.straps_provider = "llamacpp"
  with_input("sk-buf", function() ui.login({}) end)
  assert(registry.call("fn.api_key_store", "llamacpp") == "sk-buf", "no-argument login should use the resolved provider")
  local orig_confirm = vim.fn.confirm
  local asked
  vim.fn.confirm = function(q) asked = q return 2 end
  local declined = capture_notify(function() ui.logout({}) end)
  local kept = registry.call("fn.api_key_store", "llamacpp")
  vim.fn.confirm = function(q) asked = q return 1 end
  local msgs = capture_notify(function() ui.logout({}) end)
  vim.fn.confirm = orig_confirm
  assert(has(declined, "logout cancelled") and kept == "sk-buf", "declining should keep the key: " .. vim.inspect(declined))
  assert(tostring(asked):find("llamacpp", 1, true), "the prompt should name the provider: " .. tostring(asked))
  assert(has(msgs, "deleted " .. key_path("llamacpp")), vim.inspect(msgs))
  vim.b.straps_provider = "gone"
  msgs = capture_notify(function() ui.login({}) end)
  local msgs2 = capture_notify(function() ui.logout({}) end)
  vim.b.straps_provider = nil
  straps.config.provider = saved_provider
  assert(has(msgs, "unknown provider") and has(msgs2, "unknown provider"), vim.inspect({ msgs, msgs2 }))
end)

it(":StrapsLogin names a key variable the stored key overrides", function()
  clear_keys()
  vim.env.LLAMA_API_KEY = "env-b"
  local msgs
  with_input("sk-o", function() msgs = capture_notify(function() ui.login({ "llamacpp" }) end) end)
  vim.env.LLAMA_API_KEY = nil
  local plain
  with_input("sk-p", function() plain = capture_notify(function() ui.login({ "anthropic" }) end) end)
  clear_keys()
  assert(msgs[1] and msgs[1].msg == "straps: saved the llamacpp API key to " .. key_path("llamacpp") .. "; the default fn.llamacpp_api_key reads it before $LLAMA_API_KEY",
    vim.inspect(msgs))
  assert(plain[1] and plain[1].msg == "straps: saved the anthropic API key to " .. key_path("anthropic"), vim.inspect(plain))
end)

it(":StrapsLogout reports nothing stored, and a key variable that is still set", function()
  clear_keys()
  local msgs = capture_notify(function() ui.logout({ "anthropic" }) end)
  assert(has(msgs, "no stored anthropic credential"), vim.inspect(msgs))
  write_key("llamacpp", "sk-l")
  vim.env.LLAMA_API_KEY = "env-b"
  msgs = capture_notify(function() ui.logout({ "llamacpp" }) end)
  vim.env.LLAMA_API_KEY = nil
  assert(msgs[1] and msgs[1].msg == "straps: deleted " .. key_path("llamacpp")
    .. "; $LLAMA_API_KEY is still set (the default fn.llamacpp_api_key reads it)", vim.inspect(msgs))
end)

it(":StrapsLogin <provider> key prompts like the bare form; a key with a space is refused", function()
  clear_keys()
  with_input("sk-k", function() ui.login({ "anthropic", "key" }) end)
  with_input("sk-l", function() ui.login({ "llamacpp", "key" }) end)
  local msgs
  with_input("sk a", function() msgs = capture_notify(function() ui.login({ "anthropic" }) end) end)
  local a, l = registry.call("fn.api_key_store", "anthropic"), registry.call("fn.api_key_store", "llamacpp")
  clear_keys()
  assert(a == "sk-k" and l == "sk-l", tostring(a) .. " " .. tostring(l))
  local e = has(msgs, "the key has spaces or control characters")
  assert(e and e.level == vim.log.levels.ERROR and not has(msgs, "saved"), vim.inspect(msgs))
end)

it("a blank key file falls through to the environment for every provider", function()
  for _, slot in ipairs(providers.PROVIDERS) do
    write_key(slot.name, "   ")
    vim.env[slot.key_env[#slot.key_env]] = "env-" .. slot.name
    local ok, key, source = pcall(registry.call, slot.key_fn, { refresh = false })
    vim.env[slot.key_env[#slot.key_env]] = nil
    clear_keys()
    assert(ok and key == "env-" .. slot.name and source == "env", slot.name .. ": " .. tostring(key) .. " " .. tostring(source))
  end
end)

it("fn.list_models reports a key fn that raises, and a required key fn that returns nothing", function()
  write_key("anthropic", "leaky", "rw-r--r--")
  local m1, e1 = registry.call("fn.list_models", "anthropic")
  clear_keys()
  local m2, e2
  with_entry("fn.openai_api_key", [[return function() return nil end]], function()
    m2, e2 = registry.call("fn.list_models", "openai")
  end)
  local argv = take_argv()
  assert(m1 == nil and tostring(e1):find("fn.anthropic_api_key failed (", 1, true) and tostring(e1):find("chmod 600", 1, true)
    and not tostring(e1):find("straps:", 1, true), tostring(e1))
  assert(m2 == nil and e2 == "fn.openai_api_key returned no key", tostring(e2))
  assert(argv == "", "curl should not run:\n" .. argv)
end)

it("fn.anthropic_messages raises for a non-string opts.base_url", function()
  local co = coroutine.create(function()
    return registry.call("fn.anthropic_messages", { system = "s", messages = {}, tools = {} },
      { emit = function() end, cancelled = function() return false end, on_cancel = function() end },
      { base_url = 8080, model = "m" })
  end)
  local ok, err = coroutine.resume(co)
  assert(not ok and tostring(err):find("opts.base_url must be a URL string (got number)", 1, true), tostring(err))
  assert(take_argv() == "", "curl should not run")
end)

it(":StrapsLogout openai reports a key store or ChatGPT logout that fails", function()
  local m1, m2
  require("straps.registry").call("fn.openai_oauth_credential", false)
  require("straps.oauth").pending_login = nil
  with_entry("fn.api_key_store", [[return function(p, v) if v == false then error("straps: vault locked", 0) end return nil, nil end]],
    function()
      m1 = capture_notify(function()
        ui.logout({ "openai" })
        vim.wait(50, function() return false end, 10)
      end)
    end)
  with_entry("fn.openai_oauth_logout", [[return function() error("straps: lock broken", 0) end]],
    function() m2 = capture_notify(function()
      ui.logout({ "openai" })
      vim.wait(2000, function() return false end, 10)
    end) end)
  local e1 = has(m1, "vault locked")
  local e2 = has(m2, "lock broken")
  assert(e1 and e1.level == vim.log.levels.ERROR and not has(m1, "no stored openai credential") and #m1 == 1, vim.inspect(m1))
  assert(e2 and e2.level == vim.log.levels.ERROR and not has(m2, "no stored openai credential"), vim.inspect(m2))
end)

it(":StrapsLogout reports a key store that fails to delete", function()
  local msgs
  with_entry("fn.api_key_store", [[return function(p, v) if v == false then error("straps: vault locked", 0) end return nil, nil end]],
    function() msgs = capture_notify(function() ui.logout({ "anthropic" }) end) end)
  local e = has(msgs, "vault locked")
  assert(e and e.level == vim.log.levels.ERROR, vim.inspect(msgs))
  assert(not has(msgs, "no stored anthropic credential"), vim.inspect(msgs))
end)

-- ------------------------------------------------------------- health
local function health_run(provider)
  local saved_provider = straps.config.provider
  straps.config.provider = provider
  local rec = {}
  local orig = {}
  for _, k in ipairs({ "start", "ok", "warn", "error", "info" }) do
    orig[k] = vim.health[k]
    vim.health[k] = function(msg, advice) rec[#rec + 1] = { kind = k, msg = tostring(msg), advice = advice } end
  end
  local ok, err = pcall(require("straps.health").check)
  straps.config.provider = saved_provider
  for k, f in pairs(orig) do vim.health[k] = f end
  assert(ok, "health raised: " .. tostring(err))
  return rec
end
local function hfind(rec, kind, s)
  for _, r in ipairs(rec) do if r.kind == kind and r.msg:find(s, 1, true) then return r end end
end

it("health shows each provider's base URL and the stored key's source", function()
  write_key("anthropic", "sk-ant")
  write_key("openai", "sk-oai")
  write_key("llamacpp", "sk-llama")
  straps.config.openai_model = "gpt-test"
  local ra = health_run("anthropic")
  local ro = health_run("openai")
  local rl = health_run("llamacpp")
  clear_keys()
  straps.config.openai_model = nil
  assert(hfind(ra, "info", "base_url: https://api.anthropic.com"), vim.inspect(ra))
  assert(hfind(ra, "ok", "fn.anthropic_api_key resolves a key (6 chars, source: stored)"), vim.inspect(ra))
  assert(hfind(ra, "ok", "anthropic model: claude-sonnet-5  @ https://api.anthropic.com"), vim.inspect(ra))
  assert(hfind(ro, "info", "openai_base_url: https://api.openai.com"), vim.inspect(ro))
  assert(hfind(ro, "ok", "fn.openai_api_key resolves a key (6 chars, source: stored)"), vim.inspect(ro))
  assert(hfind(ro, "ok", "openai model: gpt-test  @ https://api.openai.com"), vim.inspect(ro))
  assert(hfind(rl, "info", "llamacpp_base_url: http://127.0.0.1:8080"), vim.inspect(rl))
  assert(hfind(rl, "ok", "fn.llamacpp_api_key resolves a key (8 chars, source: stored)"), vim.inspect(rl))
  assert(hfind(rl, "ok", "llamacpp model: llama-test  @ http://127.0.0.1:8080"), vim.inspect(rl))
end)

it("health's model line shows each provider's configured base URL, normalized", function()
  straps.config.base_url = "http://ant.invalid/v1/"
  straps.config.openai_base_url = "http://oai.invalid/v1/"
  straps.config.llamacpp_base_url = "http://llama.invalid/v1/"
  straps.config.openai_model = "gpt-test"
  local ra, ro, rl = health_run("anthropic"), health_run("openai"), health_run("llamacpp")
  straps.config.base_url, straps.config.openai_base_url, straps.config.llamacpp_base_url = nil, nil, nil
  straps.config.openai_model = nil
  assert(hfind(ra, "ok", "anthropic model: claude-sonnet-5  @ http://ant.invalid"), vim.inspect(ra))
  assert(hfind(ro, "ok", "openai model: gpt-test  @ http://oai.invalid"), vim.inspect(ro))
  assert(hfind(rl, "ok", "llamacpp model: llama-test  @ http://llama.invalid"), vim.inspect(rl))
  for _, rec in ipairs({ ra, ro, rl }) do
    for _, r in ipairs(rec) do assert(not r.msg:find("/v1", 1, true), "not normalized: " .. r.msg) end
  end
end)

it("health reports a non-string base URL and still runs every later section", function()
  straps.config.llamacpp_base_url = 8080
  local rec = health_run("llamacpp")
  straps.config.llamacpp_base_url = nil
  assert(hfind(rec, "error", "config.llamacpp_base_url must be a URL string (got number); every llamacpp request will fail"),
    vim.inspect(rec))
  assert(hfind(rec, "start", "straps: sessions"), "health stopped early: " .. vim.inspect(rec))
end)

it("health reports a group-readable key file as an error with the chmod hint, per provider", function()
  for _, name in ipairs(providers.provider_names()) do
    write_key(name, "leaky", "rw-r--r--")
    local rec = health_run(name)
    clear_keys()
    local e = hfind(rec, "error", "accessible by group/other")
    assert(e and e.msg:find("chmod 600", 1, true) and not e.msg:find("leaky", 1, true), name .. ": " .. vim.inspect(rec))
  end
end)

it("health without a llamacpp key is info; without an anthropic key it is an error", function()
  clear_keys()
  local rl = health_run("llamacpp")
  local ra = health_run("anthropic")
  assert(hfind(rl, "info", "no API key; requests send no auth header. If the server requires a key, run :StrapsLogin llamacpp key or set $LLAMACPP_API_KEY or $LLAMA_API_KEY")
    and not hfind(rl, "error", "fn.llamacpp_api_key"), vim.inspect(rl))
  assert(hfind(ra, "error", "fn.anthropic_api_key raised"), vim.inspect(ra))
  local rn
  with_entry("fn.anthropic_api_key", [[return function() return nil end]], function() rn = health_run("anthropic") end)
  local e = hfind(rn, "error", "fn.anthropic_api_key returned no key")
  assert(e and vim.inspect(e.advice):find("run :StrapsLogin anthropic key or set $ANTHROPIC_API_KEY", 1, true),
    "a nil key is an error for a required provider: " .. vim.inspect(rn))
end)

it("health with fn.api_key_store unregistered shows the setup warning", function()
  local rec
  with_entry("fn.api_key_store", nil, function() rec = health_run("llamacpp") end)
  assert(hfind(rec, "warn", "fn.api_key_store is not registered"), vim.inspect(rec))
end)

it("health names the verdict's source and prints no per-source lookup lines", function()
  for _, name in ipairs(providers.provider_names()) do
    write_key(name, "sk-" .. name)
    local slot = providers.provider_slot(name)
    vim.env[slot.key_env[1]] = "env-" .. name
    local rec = health_run(name)
    vim.env[slot.key_env[1]] = nil
    clear_keys()
    assert(hfind(rec, "ok", slot.key_fn .. " resolves a key (" .. #("sk-" .. name) .. " chars, source: stored)"),
      name .. ": " .. vim.inspect(rec))
    for _, r in ipairs(rec) do
      assert(not r.msg:find("$" .. slot.key_env[1], 1, true) and not r.msg:find("stored key:", 1, true),
        name .. ": health restated the lookup order: " .. r.msg)
    end
  end
  vim.env.LLAMACPP_API_KEY = "env-a"
  local rl = health_run("llamacpp")
  vim.env.LLAMACPP_API_KEY = nil
  assert(hfind(rl, "ok", "fn.llamacpp_api_key resolves a key (5 chars, source: env)"), vim.inspect(rl))
end)

it("health flags a key file with an empty first line and a non-file at the key path", function()
  vim.fn.mkdir(xdg .. "/straps", "p")
  vim.fn.writefile({ "", "sk-line2" }, key_path("anthropic"))
  vim.fn.setfperm(key_path("anthropic"), "rw-------")
  local blank = health_run("anthropic")
  clear_keys()
  vim.fn.mkdir(key_path("anthropic"), "p")
  local dir = health_run("anthropic")
  vim.fn.delete(key_path("anthropic"), "d")
  local b = hfind(blank, "warn", "stored key file " .. key_path("anthropic") .. " has no key on its first line")
  assert(b and vim.inspect(b.advice):find("put the key on its first line", 1, true), vim.inspect(blank))
  assert(hfind(dir, "warn", key_path("anthropic") .. " is a directory, not a key file"), vim.inspect(dir))
  assert(not hfind(dir, "warn", "has no key on its first line"), vim.inspect(dir))
end)

it("health with a ChatGPT login and a stored openai key reports the login as the source", function()
  write_key("openai", "sk-oai")
  vim.env.OPENAI_API_KEY = "env-oai"
  registry.call("fn.openai_oauth_credential", { access = "acc-health", refresh = "ref", client_id = "cid",
    expires = require("straps.oauth").now_ms() + 3600 * 1000 })
  local rec = health_run("openai")
  registry.call("fn.openai_oauth_credential", false)
  vim.env.OPENAI_API_KEY = nil
  clear_keys()
  assert(hfind(rec, "ok", "fn.openai_api_key resolves a key (10 chars, source: oauth)"), vim.inspect(rec))
  for _, r in ipairs(rec) do
    assert(not r.msg:find("takes precedence", 1, true) and not r.msg:find("stored key:", 1, true), r.msg)
  end
end)

-- ------------------------------------------------------------- command layer
it("the :StrapsLogin and :StrapsLogout commands accept no argument and pass extra ones to the handler", function()
  clear_keys()
  vim.g.loaded_straps = nil
  vim.cmd.source(root .. "/plugin/straps.lua")
  local saved_provider = straps.config.provider
  straps.config.provider = "llamacpp"
  local orig_input, orig_confirm = vim.fn.inputsecret, vim.fn.confirm
  vim.fn.inputsecret = function() return "sk-cmd" end
  vim.fn.confirm = function() return 1 end
  local ok1, e1 = pcall(vim.cmd, "StrapsLogin")
  local stored = registry.call("fn.api_key_store", "llamacpp")
  local ok2, e2 = pcall(vim.cmd, "StrapsLogout")
  local after = registry.call("fn.api_key_store", "llamacpp")
  vim.fn.histadd(":", "echo 'before cmd'")
  vim.fn.histadd(":", "StrapsLogout anthropic sk-cmd-secret")
  local msgs
  local ok3, e3 = pcall(function() msgs = capture_notify(function() vim.cmd("StrapsLogout anthropic sk-cmd-secret") end) end)
  local last = vim.fn.histget(":", -1)
  vim.fn.inputsecret, vim.fn.confirm = orig_input, orig_confirm
  straps.config.provider = saved_provider
  assert(ok1, tostring(e1))
  assert(stored == "sk-cmd", "bare :StrapsLogin should store a key: " .. tostring(stored))
  assert(ok2 and after == nil, "bare :StrapsLogout should delete it: " .. tostring(e2))
  assert(ok3 and has(msgs, "usage: :StrapsLogout"), tostring(e3) .. vim.inspect(msgs))
  assert(last == "echo 'before cmd'", "history kept the key line: " .. last)
end)

it("completion works on an abbreviated command name", function()
  vim.g.loaded_straps = nil
  vim.cmd.source(root .. "/plugin/straps.lua")
  assert(vim.deep_equal(vim.fn.getcompletion("StrapsLogi openai ", "cmdline"), { "codex", "key" }),
    vim.inspect(vim.fn.getcompletion("StrapsLogi openai ", "cmdline")))
  assert(#vim.fn.getcompletion("StrapsLogin openai key ", "cmdline") == 0,
    vim.inspect(vim.fn.getcompletion("StrapsLogin openai key ", "cmdline")))
  assert(#vim.fn.getcompletion("StrapsLogo anthropic ", "cmdline") == 0)
end)

it(":StrapsLogin with a lone key argument is rejected without a prompt", function()
  local asked = false
  local orig = vim.fn.inputsecret
  vim.fn.inputsecret = function() asked = true return "x" end
  local msgs = capture_notify(function() ui.login({ "key" }) end)
  vim.fn.inputsecret = orig
  assert(not asked and has(msgs, "unknown provider"), vim.inspect(msgs))
end)

it(":StrapsLogin openai key with an extra argument shows the one openai usage", function()
  local msgs = capture_notify(function() ui.login({ "openai", "key", "extra" }) end)
  assert(has(msgs, "usage: :StrapsLogin openai [codex | redirect-url | key]"), vim.inspect(msgs))
end)

it("login and logout report an unregistered key store", function()
  local m1, m2
  with_entry("fn.api_key_store", nil, function()
    m1 = capture_notify(function() ui.login({ "anthropic" }) end)
    m2 = capture_notify(function() ui.logout({ "anthropic" }) end)
  end)
  assert(has(m1, "fn.api_key_store is not registered"), vim.inspect(m1))
  assert(has(m2, "fn.api_key_store is not registered"), vim.inspect(m2))
end)

it("fn.api_key_store reports a failed save and leaves no temp file", function()
  clear_keys()
  vim.fn.mkdir(key_path("anthropic") .. "/blocker", "p")
  local ok, err = pcall(registry.call, "fn.api_key_store", "anthropic", "sk-blocked")
  local leftovers = vim.fn.glob(xdg .. "/straps/anthropic_api_key.tmp.*", false, true)
  vim.fn.delete(key_path("anthropic"), "rf")
  assert(not ok and tostring(err):find("could not save", 1, true) and not tostring(err):find("sk-blocked", 1, true), tostring(err))
  assert(#leftovers == 0, "temp file left behind: " .. vim.inspect(leftovers))
end)

it("provider.base_url refuses a URL with a query or fragment", function()
  for _, bad in ipairs({ "http://h.invalid/v1?x=1", "http://h.invalid/#frag" }) do
    local url, err = providers.base_url("llamacpp", { llamacpp_base_url = bad })
    assert(url == nil and tostring(err):find("must not contain a query or fragment", 1, true), bad .. ": " .. tostring(err))
  end
end)

it("a key from the environment with spaces or control characters fails before curl runs, for every provider", function()
  clear_keys()
  take_argv()
  for _, slot in ipairs(providers.PROVIDERS) do
    vim.env[slot.key_env[1]] = "sk-a\r\nX-Injected: 1"
    local ok, err = pcall(request, slot.name)
    vim.env[slot.key_env[1]] = nil
    local argv = take_argv()
    assert(not ok and tostring(err):find(slot.key_fn .. " returned a key with spaces or control characters", 1, true),
      slot.name .. ": " .. tostring(err))
    assert(not tostring(err):find("Injected", 1, true), slot.name .. ": the key must not appear in the error")
    assert(argv == "", slot.name .. ": curl should not run:\n" .. argv)
  end
end)

-- ------------------------------------------------------------- refused keys
it("fn.list_models returns an error for a key requests refuse, for every provider", function()
  clear_keys()
  take_argv()
  for _, slot in ipairs(providers.PROVIDERS) do
    local var = slot.key_env[1]
    vim.env[var] = "sk-a b"
    local ok, models, err = pcall(registry.call, "fn.list_models", slot.name)
    vim.env[var] = nil
    assert(ok, slot.name .. ": fn.list_models raised: " .. tostring(models))
    assert(models == nil and tostring(err):find(slot.key_fn .. " returned a key with spaces or control characters", 1, true)
      and not tostring(err):find("sk-a", 1, true), slot.name .. ": " .. tostring(err))
  end
  local argv = take_argv()
  assert(argv == "", "curl should not run:\n" .. argv)
end)

it("health reports an error, not OK, for a key requests refuse; a trailing CR is trimmed", function()
  clear_keys()
  vim.env.ANTHROPIC_API_KEY = "sk-ant\27abc"
  local rec = health_run("anthropic")
  vim.env.ANTHROPIC_API_KEY = "sk-ant-abc\r"
  local crlf = health_run("anthropic")
  vim.env.ANTHROPIC_API_KEY = nil
  local e = hfind(rec, "error", "fn.anthropic_api_key resolves a key that requests refuse (source: env)")
  assert(e and vim.inspect(e.advice):find("the key has spaces or control characters", 1, true), vim.inspect(rec))
  assert(not hfind(rec, "ok", "resolves a key ("), vim.inspect(rec))
  assert(hfind(crlf, "ok", "fn.anthropic_api_key resolves a key (10 chars, source: env)"), vim.inspect(crlf))
end)

it("a key fn's key with a trailing CR or spaces is trimmed into the request header, for every provider", function()
  clear_keys()
  take_argv()
  for _, slot in ipairs(providers.PROVIDERS) do
    local argv
    with_entry(slot.key_fn, [[return function() return "  sk-env\r", "stored" end]], function() argv = request(slot.name) end)
    local header = slot.auth_header == "x-api-key" and "x-api-key: sk-env" or "Authorization: Bearer sk-env"
    assert(argv:find(header, 1, true), slot.name .. ": " .. argv)
    assert(not argv:find("sk-env\r", 1, true), slot.name .. ": " .. argv)
  end
end)

it("a blank key variable is skipped and the next one is used", function()
  clear_keys()
  vim.env.LLAMACPP_API_KEY = "   "
  vim.env.LLAMA_API_KEY = " env-b "
  local key, source = registry.call("fn.llamacpp_api_key")
  local argv = request("llamacpp")
  local msgs
  with_input("sk-l", function() msgs = capture_notify(function() ui.login({ "llamacpp" }) end) end)
  local out = capture_notify(function() ui.logout({ "llamacpp" }) end)
  vim.env.LLAMACPP_API_KEY, vim.env.LLAMA_API_KEY = nil, nil
  assert(key == "env-b" and source == "env", vim.inspect(key))
  assert(argv:find("Authorization: Bearer env-b", 1, true), argv)
  assert(msgs[1] and msgs[1].msg:find("reads it before $LLAMA_API_KEY", 1, true) and not msgs[1].msg:find("$LLAMACPP_API_KEY", 1, true),
    vim.inspect(msgs))
  assert(out[1] and out[1].msg:find("$LLAMA_API_KEY is still set", 1, true) and not out[1].msg:find("$LLAMACPP_API_KEY", 1, true),
    vim.inspect(out))
end)

it("a blank required key variable gives the key fn's own error", function()
  clear_keys()
  vim.env.ANTHROPIC_API_KEY = "  "
  vim.env.OPENAI_API_KEY = "  "
  local ok_a, err_a = pcall(registry.call, "fn.anthropic_api_key")
  local ok_o, err_o = pcall(registry.call, "fn.openai_api_key")
  vim.env.ANTHROPIC_API_KEY, vim.env.OPENAI_API_KEY = nil, nil
  assert(not ok_a and tostring(err_a):find("no Anthropic API key found", 1, true), tostring(err_a))
  assert(not ok_o and tostring(err_o):find("no OpenAI API key found", 1, true), tostring(err_o))
end)

it("provider.auth_headers refuses spaces and control characters for every provider without echoing the key", function()
  for _, slot in ipairs(providers.PROVIDERS) do
    for _, bad in ipairs({ "a b", "a\rb", "a\nX: y", "a\27b", "a\127b", "a\0b" }) do
      local ok, err = pcall(providers.auth_headers, slot.name, bad)
      assert(not ok and tostring(err):find(slot.key_fn .. " returned a key with spaces or control characters", 1, true)
        and not tostring(err):find(bad, 1, true), slot.name .. " " .. vim.inspect(bad) .. ": " .. tostring(err))
    end
  end
end)

it("provider.normalize_base_url strips the path of a URL with no scheme", function()
  assert(providers.normalize_base_url("localhost:8080/v1/") == "localhost:8080")
  assert(providers.normalize_base_url("v1/v1") == "v1")
end)

it("fn.anthropic_messages refuses an opts.base_url with a query", function()
  take_argv()
  local co = coroutine.create(function()
    return registry.call("fn.anthropic_messages", { system = "s", messages = {}, tools = {} },
      { emit = function() end, cancelled = function() return false end, on_cancel = function() end },
      { base_url = "http://opt.invalid/v1?x=1", model = "m", auth_headers = {} })
  end)
  local ok, err = coroutine.resume(co)
  assert(not ok and tostring(err):find("opts.base_url must not contain a query or fragment", 1, true), tostring(err))
  assert(take_argv() == "", "curl should not run")
end)

it(":StrapsLogin llamacpp names every set key variable in one clause", function()
  clear_keys()
  vim.env.LLAMACPP_API_KEY = "env-a"
  vim.env.LLAMA_API_KEY = "env-b"
  local msgs
  with_input("sk-both", function() msgs = capture_notify(function() ui.login({ "llamacpp" }) end) end)
  vim.env.LLAMACPP_API_KEY, vim.env.LLAMA_API_KEY = nil, nil
  clear_keys()
  assert(msgs[1] and msgs[1].msg == "straps: saved the llamacpp API key to " .. key_path("llamacpp")
    .. "; the default fn.llamacpp_api_key reads it before $LLAMACPP_API_KEY and $LLAMA_API_KEY", vim.inspect(msgs))
end)

it(":StrapsLogout does not report a deletion when a redefined store's delete returns something other than true", function()
  local msgs
  with_entry("fn.api_key_store", [[return function(p, v) if v == false then return "sk-still-here", nil end return "sk-still-here", nil end]],
    function() msgs = capture_notify(function() ui.logout({ "anthropic" }) end) end)
  assert(#msgs == 1 and msgs[1].msg == "straps: no stored anthropic credential", vim.inspect(msgs))
end)

it("fn.openai_api_key with no config directory names :StrapsLogin and no file", function()
  local saved_home = vim.env.HOME
  vim.env.XDG_CONFIG_HOME = nil
  vim.env.HOME = nil
  local ok, err = pcall(registry.call, "fn.openai_api_key")
  vim.env.HOME = saved_home
  vim.env.XDG_CONFIG_HOME = xdg
  assert(not ok and tostring(err):find(":StrapsLogin openai key", 1, true) and not tostring(err):find("write the key to", 1, true),
    tostring(err))
end)

it("fn.api_key_store reads through a symlink and refuses to replace or delete it", function()
  clear_keys()
  local target = tmp .. "/secret_key"
  vim.fn.writefile({ "sk-linked" }, target)
  vim.fn.setfperm(target, "rw-------")
  vim.uv.fs_symlink(target, key_path("anthropic"))
  local read = registry.call("fn.api_key_store", "anthropic")
  local ok_w, err_w = pcall(registry.call, "fn.api_key_store", "anthropic", "sk-new")
  local ok_d, err_d = pcall(registry.call, "fn.api_key_store", "anthropic", false)
  local lst = vim.uv.fs_lstat(key_path("anthropic"))
  local still = vim.fn.readfile(target)[1]
  vim.fn.delete(key_path("anthropic"))
  vim.fn.delete(target)
  assert(read == "sk-linked", tostring(read))
  assert(not ok_w and tostring(err_w):find("is a symlink", 1, true), tostring(err_w))
  assert(not ok_d and tostring(err_d):find("is a symlink", 1, true), tostring(err_d))
  assert(lst and lst.type == "link" and still == "sk-linked", "the link and its target must be untouched")
end)

-- ------------------------------------------------------------- shared URL and key validators
it("provider.check_base_url refuses a URL without an http(s) scheme, for config and opts", function()
  for _, bad in ipairs({ "api.anthropic.com", "ftp://h.invalid", "-K/tmp/x", "file:///etc" }) do
    local url, err = providers.check_base_url(bad, "config.base_url")
    assert(url == nil and tostring(err):find("config.base_url must start with http:// or https://", 1, true), bad .. ": " .. tostring(err))
    local u2, e2 = providers.base_url("anthropic", { base_url = bad })
    assert(u2 == nil and tostring(e2):find("must start with http:// or https://", 1, true), bad)
  end
  assert(providers.check_base_url("HTTPS://h.invalid/v1", "x") == "https://h.invalid")
end)

it("fn.openai_api_key refuses a bad opts.base_url with a ChatGPT login, naming opts.base_url", function()
  registry.call("fn.openai_oauth_credential", { access = "acc", refresh = "ref", client_id = "cid",
    expires = require("straps.oauth").now_ms() + 3600 * 1000 })
  local ok, err = pcall(registry.call, "fn.openai_api_key", { base_url = 7, refresh = false })
  local ok2, err2 = pcall(registry.call, "fn.openai_api_key", { base_url = "api.openai.com", refresh = false })
  registry.call("fn.openai_oauth_credential", false)
  assert(not ok and tostring(err):find("opts.base_url must be a URL string (got number)", 1, true), tostring(err))
  assert(not ok2 and tostring(err2):find("opts.base_url must start with http:// or https://", 1, true), tostring(err2))
end)

it("provider.auth_headers raises for an unknown auth_header style", function()
  local slot = providers.provider_slot("llamacpp")
  local saved = slot.auth_header
  slot.auth_header = "beare"
  local ok, err = pcall(providers.auth_headers, "llamacpp", "k")
  slot.auth_header = saved
  assert(not ok and tostring(err):find("unknown auth_header beare", 1, true), tostring(err))
end)

it(":StrapsLogin openai key names $OPENAI_API_KEY when it is set", function()
  clear_keys()
  registry.call("fn.openai_oauth_credential", false)
  require("straps.oauth").pending_login = nil
  vim.env.OPENAI_API_KEY = "env-o"
  local msgs = {}
  local orig = vim.notify
  vim.notify = function(m) msgs[#msgs + 1] = tostring(m) end
  with_input("sk-oo", function() ui.login({ "openai", "key" }) end)
  vim.wait(2000, function() return #msgs > 0 end, 10)
  vim.notify = orig
  vim.env.OPENAI_API_KEY = nil
  clear_keys()
  assert(msgs[1] == "straps: saved the openai API key to " .. key_path("openai")
    .. "; the default fn.openai_api_key reads it before $OPENAI_API_KEY", vim.inspect(msgs))
end)

it("fn.api_key_store reports a failed temp-file write without the key and leaves no temp file", function()
  if vim.uv.getuid() == 0 then return pending("file modes do not bind root") end
  clear_keys()
  vim.fn.setfperm(xdg .. "/straps", "r-x------")
  local ok, err = pcall(registry.call, "fn.api_key_store", "anthropic", "sk-ro")
  local leftovers = vim.fn.glob(xdg .. "/straps/anthropic_api_key.tmp.*", false, true)
  vim.fn.setfperm(xdg .. "/straps", "rwx------")
  assert(not ok and tostring(err):find("could not write", 1, true) and not tostring(err):find("sk-ro", 1, true), tostring(err))
  assert(#leftovers == 0, vim.inspect(leftovers))
end)

it("health refuses a base URL with a query without printing it, and the model line drops the URL", function()
  straps.config.llamacpp_base_url = "http://h.invalid/?token=qsecret"
  local rec = health_run("llamacpp")
  straps.config.llamacpp_base_url = nil
  assert(hfind(rec, "error", "config.llamacpp_base_url must not contain a query or fragment"), vim.inspect(rec))
  for _, r in ipairs(rec) do assert(not r.msg:find("qsecret", 1, true), "printed the query: " .. r.msg) end
  local model = hfind(rec, "ok", "llamacpp model: llama-test")
  assert(model and not model.msg:find(" @ ", 1, true), vim.inspect(model))
end)

it("provider.check_base_url refuses whitespace, control characters and a missing host", function()
  for _, bad in ipairs({ "https://api.openai.com ", "https://a b/x", "https://h.invalid/x\ny", "http://h.invalid\t" }) do
    local url, err = providers.check_base_url(bad, "config.base_url")
    assert(url == nil and tostring(err):find("config.base_url must not contain whitespace or control characters", 1, true),
      vim.inspect(bad) .. ": " .. tostring(err))
  end
  for _, bad in ipairs({ "http://", "https://", "https:///v1", "http://:8080", "http://@h.invalid" }) do
    local url, err = providers.check_base_url(bad, "config.base_url")
    assert(url == nil and tostring(err):find("config.base_url must name a host after the scheme", 1, true), bad .. ": " .. tostring(err))
  end
  assert(providers.check_base_url("http://[::1]:8080/v1", "x") == "http://[::1]:8080")
end)

it("fn.api_key_store raises for a symlink to a missing file, and health reports it", function()
  clear_keys()
  vim.fn.mkdir(xdg .. "/straps", "p")
  vim.uv.fs_symlink(tmp .. "/no_such_key", key_path("llamacpp"))
  local ok, err = pcall(registry.call, "fn.api_key_store", "llamacpp")
  local ok_fn, err_fn = pcall(registry.call, "fn.llamacpp_api_key")
  local rec = health_run("llamacpp")
  vim.fn.delete(key_path("llamacpp"))
  assert(not ok and tostring(err):find(key_path("llamacpp") .. " is a symlink to a missing file", 1, true), tostring(err))
  assert(not ok_fn and tostring(err_fn):find("is a symlink to a missing file", 1, true), tostring(err_fn))
  assert(hfind(rec, "error", "is a symlink to a missing file"), vim.inspect(rec))
end)

it("provider.clean_key refuses exactly the whitespace, control and non-ASCII bytes inside a key", function()
  for b = 0, 255 do
    local key, why = providers.clean_key("a" .. string.char(b) .. "b")
    local want = (b <= 32 or b == 127) and "spaces or control characters" or b >= 128 and "non-ASCII characters" or nil
    assert((key == nil) == (want ~= nil), ("byte %d: %s"):format(b, tostring(key)))
    assert(why == want, ("byte %d: %s"):format(b, tostring(why)))
  end
  local ok, err = pcall(registry.call, "fn.api_key_store", "anthropic", "sk-ant-abc\226\128\139\194\160")
  assert(not ok and tostring(err):find("the key has non-ASCII characters", 1, true), tostring(err))
end)

it("health prints a stored key error once when the key fn raises the same error", function()
  vim.env.ANTHROPIC_API_KEY = nil
  write_key("anthropic", "leaky", "rw-r--r--")
  local rec = health_run("anthropic")
  clear_keys()
  local n = 0
  for _, r in ipairs(rec) do
    if r.msg:find("accessible by group/other", 1, true) or vim.inspect(r.advice or {}):find("accessible by group/other", 1, true) then
      n = n + 1
    end
  end
  assert(n == 1, "the store error should print once: " .. vim.inspect(rec))
  assert(hfind(rec, "error", "fn.anthropic_api_key raised the stored key error above"), vim.inspect(rec))
end)

it(":StrapsLogin names the stored key the new one replaces", function()
  clear_keys()
  local prompts = {}
  local orig = vim.fn.inputsecret
  vim.fn.inputsecret = function(p) prompts[#prompts + 1] = p return "sk-1" end
  capture_notify(function() ui.login({ "anthropic" }) end)
  capture_notify(function() ui.login({ "anthropic" }) end)
  vim.fn.inputsecret = orig
  clear_keys()
  assert(prompts[1] == "straps: anthropic API key: ", vim.inspect(prompts))
  assert(prompts[2] == "straps: anthropic API key (replaces the stored key): ", vim.inspect(prompts))
end)

it(":StrapsLogout openai reports a ChatGPT sign-out that fails through its callback", function()
  local runs = {}
  for _, with_key in ipairs({ true, false }) do
    clear_keys()
    if with_key then write_key("openai", "sk-o") end
    local msgs = {}
    with_entry("fn.openai_oauth_logout",
      [[return function(cb) vim.schedule(function() cb("straps: could not lock the ChatGPT login: busy") end) end]],
      function()
        local orig = vim.notify
        vim.notify = function(m, lvl) msgs[#msgs + 1] = { msg = tostring(m), level = lvl } end
        local ok, err = pcall(function()
          ui.logout({ "openai" })
          vim.wait(2000, function() return has(msgs, "could not lock") ~= nil end, 10)
        end)
        vim.notify = orig
        assert(ok, tostring(err))
      end)
    runs[#runs + 1] = msgs
  end
  clear_keys()
  for i, msgs in ipairs(runs) do
    local e = has(msgs, "could not lock")
    assert(e and e.level == vim.log.levels.ERROR, i .. ": " .. vim.inspect(msgs))
    assert(not has(msgs, "no stored openai credential"), i .. ": " .. vim.inspect(msgs))
  end
  assert(has(runs[1], "deleted " .. key_path("openai")), vim.inspect(runs[1]))
end)

it("the default key fns' missing-key error names the slot's variables", function()
  clear_keys()
  local errs = {}
  for _, p in ipairs({ "anthropic", "openai" }) do
    local slot = providers.provider_slot(p)
    local saved = slot.key_env
    slot.key_env = { "STRAPS_TEST_KEY_A", "STRAPS_TEST_KEY_B" }
    local ok, err = pcall(registry.call, slot.key_fn)
    slot.key_env = saved
    errs[p] = ok and "no error" or tostring(err)
  end
  for p, err in pairs(errs) do
    assert(err:find("export STRAPS_TEST_KEY_A or STRAPS_TEST_KEY_B in your shell", 1, true), p .. ": " .. err)
  end
end)

it(":StrapsLogin <provider> key replaces a group-readable or malformed key file", function()
  for _, bad in ipairs({ { "leaky", "rw-r--r--" }, { "sk a", "rw-------" } }) do
    clear_keys()
    write_key("anthropic", bad[1], bad[2])
    local msgs, prompt
    local orig = vim.fn.inputsecret
    vim.fn.inputsecret = function(p) prompt = p return "sk-new" end
    local ok, err = pcall(function() msgs = capture_notify(function() ui.login({ "anthropic", "key" }) end) end)
    vim.fn.inputsecret = orig
    assert(ok, tostring(err))
    assert(prompt == "straps: anthropic API key (replaces the stored key): ", bad[1] .. ": " .. tostring(prompt))
    local key = registry.call("fn.api_key_store", "anthropic")
    local st = vim.uv.fs_stat(key_path("anthropic"))
    clear_keys()
    assert(key == "sk-new", bad[1] .. ": " .. tostring(key))
    assert(st and st.mode % 512 == 384, bad[1] .. ": mode " .. tostring(st and st.mode))
    for _, m in ipairs(msgs) do assert(m.level ~= vim.log.levels.ERROR, bad[1] .. ": " .. m.msg) end
  end
end)

it("a symlinked key path's errors name the tool that created it, not :StrapsLogin", function()
  clear_keys()
  vim.fn.mkdir(xdg .. "/straps", "p")
  local target = tmp .. "/bad_linked_key"
  vim.fn.writefile({ "sk a" }, target)
  vim.fn.setfperm(target, "rw-------")
  vim.uv.fs_symlink(target, key_path("anthropic"))
  local ok, err = pcall(registry.call, "fn.api_key_store", "anthropic")
  local rec = health_run("anthropic")
  vim.fn.delete(key_path("anthropic"))
  vim.fn.delete(target)
  assert(not ok and tostring(err):find("fix it with the tool that created it", 1, true)
    and not tostring(err):find(":StrapsLogin", 1, true), tostring(err))
  local e = hfind(rec, "error", "has spaces or control characters in its key")
  assert(e and not vim.inspect(e.advice or {}):find(":StrapsLogin", 1, true), vim.inspect(rec))
end)

it("provider.normalize_base_url lowercases the scheme and host and drops a default port", function()
  assert(providers.normalize_base_url("HTTPS://API.OpenAI.com:443/v1") == "https://api.openai.com")
  assert(providers.normalize_base_url("http://H.invalid:80/") == "http://h.invalid")
  assert(providers.normalize_base_url("http://h.invalid:443/v1") == "http://h.invalid:443")
  assert(providers.normalize_base_url("https://User@H.invalid/Path/v1") == "https://User@h.invalid/Path")
  registry.call("fn.openai_oauth_credential", { access = "acc-up", refresh = "ref", client_id = "cid",
    expires = require("straps.oauth").now_ms() + 3600 * 1000 })
  local ok, key = pcall(registry.call, "fn.openai_api_key", { base_url = "HTTPS://API.OPENAI.COM:443/v1", refresh = false })
  registry.call("fn.openai_oauth_credential", false)
  assert(ok and key == "acc-up", tostring(key))
end)

it("every request and model list passes -g so curl does not expand {} or [] in the URL", function()
  write_key("anthropic", "sk-ant")
  write_key("openai", "sk-oai")
  take_argv()
  local lines = { request("anthropic"), request("openai"), request("llamacpp") }
  registry.call("fn.list_models", "llamacpp")
  lines[#lines + 1] = take_argv()
  clear_keys()
  for i, argv in ipairs(lines) do assert(argv:find("-sS -g ", 1, true), i .. ": " .. argv) end
end)

it(":StrapsLogout names every key variable still set, in the order the default key fn reads them", function()
  clear_keys()
  vim.env.LLAMACPP_API_KEY, vim.env.LLAMA_API_KEY = "env-a", "env-b"
  local both = capture_notify(function() ui.logout({ "llamacpp" }) end)
  vim.env.LLAMACPP_API_KEY = nil
  local one = capture_notify(function() ui.logout({ "llamacpp" }) end)
  vim.env.LLAMA_API_KEY = nil
  assert(has(both, "$LLAMACPP_API_KEY and $LLAMA_API_KEY are still set (the default fn.llamacpp_api_key reads the first one set"),
    vim.inspect(both))
  assert(has(one, "$LLAMA_API_KEY is still set (the default fn.llamacpp_api_key reads it)"), vim.inspect(one))
end)

it("a symlinked key file with a group-readable mode names the tool that created it, not chmod", function()
  clear_keys()
  vim.fn.mkdir(xdg .. "/straps", "p")
  local target = tmp .. "/loose_linked_key"
  vim.fn.writefile({ "sk-linked" }, target)
  vim.fn.setfperm(target, "r--r--r--")
  vim.uv.fs_symlink(target, key_path("anthropic"))
  local ok, err = pcall(registry.call, "fn.api_key_store", "anthropic")
  vim.fn.delete(key_path("anthropic"))
  vim.fn.setfperm(target, "rw-------")
  vim.fn.delete(target)
  assert(not ok and tostring(err):find("(mode 444); fix it with the tool that created it", 1, true)
    and not tostring(err):find("chmod", 1, true), tostring(err))
end)

it(":StrapsLogin over a symlinked key path prompts, then reports the store's refusal", function()
  clear_keys()
  vim.fn.mkdir(xdg .. "/straps", "p")
  local target = tmp .. "/linked_login_key"
  vim.fn.writefile({ "sk-old" }, target)
  vim.fn.setfperm(target, "rw-------")
  vim.uv.fs_symlink(target, key_path("anthropic"))
  local asked, msgs = false, nil
  local orig = vim.fn.inputsecret
  vim.fn.inputsecret = function() asked = true return "sk-new" end
  local ok, err = pcall(function() msgs = capture_notify(function() ui.login({ "anthropic", "key" }) end) end)
  vim.fn.inputsecret = orig
  local link = vim.uv.fs_readlink(key_path("anthropic"))
  local content = vim.fn.readfile(target)[1]
  vim.fn.delete(key_path("anthropic"))
  vim.fn.delete(target)
  assert(ok, tostring(err))
  assert(asked, "the key prompt did not run")
  local e
  for _, m in ipairs(msgs) do if m.level == vim.log.levels.ERROR and m.msg:find("is a symlink", 1, true) then e = m end end
  assert(e, vim.inspect(msgs))
  assert(not has(msgs, "saved"), vim.inspect(msgs))
  assert(link == target and content == "sk-old", tostring(link) .. " " .. tostring(content))
end)

it("fn.api_key_store names the type of a value that is not a key string, false or nil", function()
  for _, bad in ipairs({ true, 42, {} }) do
    local ok, err = pcall(registry.call, "fn.api_key_store", "anthropic", bad)
    assert(not ok and tostring(err):find("must be a key string, false or nil (got " .. type(bad) .. ")", 1, true), tostring(err))
  end
end)

it(":StrapsLogin! and :StrapsLogout! run, so a key typed after the bang leaves history", function()
  local asked = false
  local orig = vim.fn.inputsecret
  vim.fn.inputsecret = function() asked = true return "" end
  local results = {}
  for i, line in ipairs({ "StrapsLogin! anthropic sk-in-history", "StrapsLogout! anthropic sk-in-history" }) do
    vim.fn.histadd(":", "echo 'before bang " .. i .. "'")
    vim.fn.histadd(":", line)
    local ok, err
    local msgs = capture_notify(function() ok, err = pcall(vim.cmd, line) end)
    results[i] = { ok = ok, err = err, last = vim.fn.histget(":", -1), msgs = msgs }
  end
  vim.fn.inputsecret = orig
  assert(not asked, "no prompt should run")
  for i, r in ipairs(results) do
    assert(r.ok, i .. ": " .. tostring(r.err))
    assert(r.last == "echo 'before bang " .. i .. "'", i .. ": history is now " .. r.last)
    for _, m in ipairs(r.msgs) do assert(not m.msg:find("sk-in-history", 1, true), i .. " echoed the key: " .. m.msg) end
  end
end)

it("fn.openai_api_key checks openai_base_url from config with a ChatGPT login, and health prints that error once", function()
  registry.call("fn.openai_oauth_credential", { access = "acc", refresh = "ref", client_id = "cid",
    expires = require("straps.oauth").now_ms() + 3600 * 1000 })
  straps.config.openai_base_url = 1
  local ok, err = pcall(registry.call, "fn.openai_api_key", { refresh = false })
  local rec = health_run("openai")
  straps.config.openai_base_url = nil
  registry.call("fn.openai_oauth_credential", false)
  assert(not ok and tostring(err):find("config.openai_base_url must be a URL string (got number)", 1, true), tostring(err))
  local n = 0
  for _, r in ipairs(rec) do
    if r.msg:find("must be a URL string", 1, true) or vim.inspect(r.advice or {}):find("must be a URL string", 1, true) then n = n + 1 end
  end
  assert(n == 1, vim.inspect(rec))
  assert(hfind(rec, "error", "fn.openai_api_key raised the base URL error above"), vim.inspect(rec))
end)

it("a relative XDG_CONFIG_HOME or HOME is ignored, so no key store resolves in the working directory", function()
  local cwd = vim.fn.getcwd()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir .. "/rel/straps", "p")
  vim.fn.writefile({ "sk-planted" }, dir .. "/rel/straps/anthropic_api_key")
  vim.fn.setfperm(dir .. "/rel/straps/anthropic_api_key", "rw-------")
  local key, source, path, rel_home_path
  with_env({ "XDG_CONFIG_HOME", "HOME", "ANTHROPIC_API_KEY" }, function()
    vim.cmd.cd(dir)
    local ok, err = pcall(function()
      vim.env.XDG_CONFIG_HOME = "rel"
      vim.env.HOME = dir .. "/home"
      vim.env.ANTHROPIC_API_KEY = "sk-env"
      key, source = registry.call("fn.anthropic_api_key")
      path = select(2, registry.call("fn.api_key_store", "anthropic"))
      vim.env.XDG_CONFIG_HOME = nil
      vim.env.HOME = "rel"
      rel_home_path = select(2, registry.call("fn.api_key_store", "anthropic"))
    end)
    vim.cmd.cd(cwd)
    assert(ok, tostring(err))
  end)
  vim.fn.delete(dir, "rf")
  assert(key == "sk-env" and source == "env", "source: " .. tostring(source))
  assert(path == dir .. "/home/.config/straps/anthropic_api_key", tostring(path))
  assert(rel_home_path == nil, tostring(rel_home_path))
end)

it("health reports a ChatGPT login file accessible by group or other", function()
  registry.call("fn.openai_oauth_credential", { access = "acc", refresh = "ref", client_id = "cid",
    expires = require("straps.oauth").now_ms() + 3600 * 1000 })
  local login = xdg .. "/straps/" .. require("straps.oauth").LOGIN_FILE
  vim.fn.setfperm(login, "rw-r--r--")
  local rec = health_run("openai")
  vim.fn.setfperm(login, "rw-------")
  registry.call("fn.openai_oauth_credential", false)
  local e = hfind(rec, "error", login .. " is accessible by group/other (mode 644)")
  assert(e and vim.inspect(e.advice):find("chmod 600 " .. login, 1, true), vim.inspect(rec))
end)

it("a relative XDG_CONFIG_HOME puts the provider and model prefs in the same directory as the key store", function()
  local cwd = vim.fn.getcwd()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local key_dir, rel_exists
  with_env({ "XDG_CONFIG_HOME", "HOME" }, function()
    vim.cmd.cd(dir)
    local ok, err = pcall(function()
      vim.env.XDG_CONFIG_HOME = "rel"
      vim.env.HOME = dir .. "/home"
      key_dir = vim.fs.dirname(select(2, registry.call("fn.api_key_store", "anthropic")))
      assert(registry.call("fn.provider_pref", "llamacpp"))
      assert(registry.call("fn.model_pref", "llamacpp", "m-rel"))
      rel_exists = vim.uv.fs_stat(dir .. "/rel") ~= nil
    end)
    vim.cmd.cd(cwd)
    assert(ok, tostring(err))
  end)
  local prov = vim.uv.fs_stat(key_dir .. "/provider")
  local model = vim.uv.fs_stat(key_dir .. "/model_llamacpp")
  vim.fn.delete(dir, "rf")
  assert(key_dir == dir .. "/home/.config/straps", tostring(key_dir))
  assert(prov and model, "the prefs should be in " .. key_dir)
  assert(not rel_exists, "nothing should be written under the working directory")
end)

it("health reports an unreadable stored key file once, without the key", function()
  if vim.uv.getuid() == 0 then return pending("file modes do not bind root") end
  write_key("anthropic", "QZSECRET", "---------")
  local ok, err = pcall(registry.call, "fn.api_key_store", "anthropic")
  local rec = health_run("anthropic")
  vim.fn.setfperm(key_path("anthropic"), "rw-------")
  clear_keys()
  assert(not ok and tostring(err):find("exists but could not be read", 1, true), tostring(err))
  local n = 0
  for _, r in ipairs(rec) do
    assert(not r.msg:find("QZSECRET", 1, true) and not vim.inspect(r.advice or {}):find("QZSECRET", 1, true), r.msg)
    if r.kind == "error" and r.msg:find("exists but could not be read", 1, true) then n = n + 1 end
  end
  assert(n == 1 and hfind(rec, "error", "fn.anthropic_api_key raised the stored key error above"), vim.inspect(rec))
end)

it("fn.openai_api_key with a ChatGPT login and a custom openai_base_url names both remedies", function()
  registry.call("fn.openai_oauth_credential", { access = "acc", refresh = "ref", client_id = "cid",
    expires = require("straps.oauth").now_ms() + 3600 * 1000 })
  straps.config.openai_base_url = "https://gateway.invalid"
  local ok, err = pcall(registry.call, "fn.openai_api_key", { refresh = false })
  straps.config.openai_base_url = nil
  registry.call("fn.openai_oauth_credential", false)
  assert(not ok and tostring(err):find(":StrapsLogout openai to use $OPENAI_API_KEY", 1, true)
    and tostring(err):find(":StrapsLogin openai key to store an API key (it replaces the ChatGPT login and wins over $OPENAI_API_KEY)", 1, true),
    tostring(err))
end)

it("health warns when the provider's key fn is not registered and checks nothing further", function()
  local rec
  with_entry("fn.anthropic_api_key", nil, function() rec = health_run("anthropic") end)
  assert(hfind(rec, "warn", "fn.anthropic_api_key is not registered (setup() has not run yet)"), vim.inspect(rec))
  assert(not hfind(rec, "error", "raised") and not hfind(rec, "error", "returned no key")
    and not hfind(rec, "info", "no API key"), vim.inspect(rec))
end)

it(":StrapsLogin reports a saved key without a path when a redefined store returns none", function()
  local msgs
  with_entry("fn.api_key_store", [[return function(p, v) if v == nil then return nil, nil end return v, nil end]], function()
    with_input("sk-pathless", function() msgs = capture_notify(function() ui.login({ "anthropic", "key" }) end) end)
  end)
  assert(#msgs == 1 and msgs[1].msg == "straps: saved the anthropic API key", vim.inspect(msgs))
end)

it("fn.list_models for llamacpp sends the stored key as a Bearer header", function()
  write_key("llamacpp", "sk-llama-list")
  take_argv()
  registry.call("fn.list_models", "llamacpp")
  local argv = take_argv()
  clear_keys()
  assert(argv:find("Authorization: Bearer sk-llama-list", 1, true), argv)
end)
