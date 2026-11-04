-- OAuth ("Sign in with ChatGPT") tests: PKCE, credential storage, device id,
-- the paste-based login, the lock, refresh, fn.openai_api_key precedence, and
-- the provider's 401 refresh-and-retry. A fake `curl` first on PATH serves
-- both the token endpoint and /v1/responses, logging argv and stdin.
-- Run: busted tests/oauth_spec.lua

local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(vim.fn.fnamemodify(here, ":p"), ":h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local straps = require("straps").setup({})
straps.config.session_dir = vim.fn.tempname()
straps.config.provider = "openai"
local registry = require("straps.registry")
local oauth = require("straps.oauth")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp .. "/bin", "p")
local xdg = tmp .. "/config"
vim.env.XDG_CONFIG_HOME = xdg
vim.env.OPENAI_API_KEY = nil
vim.env.PATH = tmp .. "/bin:" .. vim.env.PATH

local fake = ([[#!/usr/bin/env bash
D=%q
N=$(cat "$D/n" 2>/dev/null || echo 0); N=$((N+1)); echo $N > "$D/n"
printf '%%s\n' "$*" >> "$D/argv"
BODY=$(cat)
printf '%%s' "$BODY" > "$D/stdin.$N"
case "$*" in
  *oauth/token*)
    MODE=$(cat "$D/token_mode" 2>/dev/null || echo ok)
    SLEEP=$(cat "$D/token_sleep" 2>/dev/null || echo 0)
    sleep "$SLEEP"
    if [ "$MODE" = fail ]; then
      printf '{"error":"invalid_grant","error_description":"secret-detail"}\nSTRAPS_HTTP_STATUS:400\n'
    elif [ "$MODE" = echo ]; then
      printf '{"error":"invalid_grant","echo":"%%s"}\nSTRAPS_HTTP_STATUS:400\n' "$BODY"
    elif [ "$MODE" = noscope ]; then
      printf '{"access_token":"acc-%%s","refresh_token":"ref-%%s","id_token":"idt","expires_in":3600,"scope":"openid"}\nSTRAPS_HTTP_STATUS:200\n' "$N" "$N"
    else
      printf '{"access_token":"acc-%%s","refresh_token":"ref-%%s","id_token":"idt","expires_in":3600,"scope":"openid offline_access chatgpt.tokens.use.direct"}\nSTRAPS_HTTP_STATUS:200\n' "$N" "$N"
    fi
    ;;
  *v1/responses*)
    if printf '%%s' "$*" | grep -q 'Bearer acc-old'; then
      printf '{"error":{"message":"expired","type":"invalid_request_error"}}'
      echo "STRAPS_HTTP_STATUS:401" >&2
    else
      echo "STRAPS_HTTP_STATUS:200" >&2
      printf 'event: response.output_text.delta\ndata: {"type":"response.output_text.delta","output_index":0,"delta":"oauth-ok"}\n\n'
      printf 'event: response.completed\ndata: {"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":5,"output_tokens":5}}}\n\n'
    fi
    ;;
esac
]]):format(tmp)
fake = fake:gsub("^#!/usr/bin/env bash", "#!" .. vim.fn.exepath("bash"), 1)
vim.fn.writefile(vim.split(fake, "\n"), tmp .. "/bin/curl")
vim.fn.setfperm(tmp .. "/bin/curl", "rwxr-xr-x")

local function post_count()
  local f = io.open(tmp .. "/argv")
  if not f then return 0 end
  local n = 0
  for line in f:lines() do if line:find("oauth/token", 1, true) then n = n + 1 end end
  f:close()
  return n
end
local function argv_text() return table.concat(vim.fn.readfile(tmp .. "/argv"), "\n") end
local function last_stdin() return table.concat(vim.fn.readfile(tmp .. "/stdin." .. vim.fn.readfile(tmp .. "/n")[1]), "\n") end
local function set_mode(m) vim.fn.writefile({ m }, tmp .. "/token_mode") end
local function set_sleep(s) vim.fn.writefile({ tostring(s) }, tmp .. "/token_sleep") end
local cred_path = xdg .. "/straps/openai_oauth.json"
local function store(c) registry.call("fn.openai_oauth_credential", c) end
local function cred_fixture(over)
  return vim.tbl_extend("force", { access = "acc-stored", refresh = "ref-stored", client_id = "cid-issued",
    expires = oauth.now_ms() + 3600 * 1000, scopes = { oauth.DIRECT_TOKEN_SCOPE } }, over or {})
end
local function refresh_sync(opts)
  local done, c, e = false, nil, nil
  registry.call("fn.openai_oauth_refresh", opts or {}, function(a, b) done, c, e = true, a, b end)
  assert(vim.wait(20000, function() return done end, 10), "refresh never called back")
  return c, e
end
local function login_url()
  local opened
  local url = registry.call("fn.openai_oauth_login", { open = function(u) opened = u end })
  assert(opened == url, "login should open the authorize URL")
  return url, oauth.parse_query(url:match("%?(.*)$"))
end
local function complete(callback)
  local done, err = false, nil
  registry.call("fn.openai_oauth_login", { callback_url = callback, on_done = function(e) done, err = true, e end })
  assert(vim.wait(20000, function() return done end, 10), "login never finished")
  return err
end

it("PKCE challenge matches RFC 7636 appendix B", function()
  assert(oauth.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
end)

it("url_decode handles %XX and +", function()
  assert(oauth.url_decode("a+b%20c%2Fd") == "a b c/d")
end)

it("credential write is mode 600 and tightens an existing 0755 directory to 0700", function()
  vim.fn.mkdir(xdg .. "/straps", "p")
  vim.uv.fs_chmod(xdg .. "/straps", 493)
  store(cred_fixture())
  local st = vim.uv.fs_stat(cred_path)
  assert(st.mode % 512 == 384, ("mode %o"):format(st.mode % 512))
  assert(vim.uv.fs_stat(xdg .. "/straps").mode % 512 == 448, "dir should be 0700")
  assert(registry.call("fn.openai_oauth_credential").access == "acc-stored")
end)

it("a group/other-readable credential file is refused without leaking the token", function()
  vim.fn.setfperm(cred_path, "rw-r--r--")
  local ok, err = pcall(registry.call, "fn.openai_oauth_credential")
  vim.fn.setfperm(cred_path, "rw-------")
  assert(not ok and tostring(err):find("chmod 600", 1, true), tostring(err))
  assert(not tostring(err):find("acc-stored", 1, true))
end)

it("credential delete removes the file", function()
  registry.call("fn.openai_oauth_credential", false)
  assert(vim.uv.fs_stat(cred_path) == nil)
  assert(registry.call("fn.openai_oauth_credential") == nil)
end)

it("device id is a stable lowercase UUIDv4", function()
  local a = registry.call("fn.openai_device_id")
  local b = registry.call("fn.openai_device_id")
  assert(a == b, "device id changed between calls")
  assert(a:match("^%x+%-%x+%-4%x%x%x%-[89ab]%x%x%x%-%x+$") and #a == 36 and a == a:lower(), a)
end)

it("authorize URL carries Pi's parameters", function()
  local _, q = login_url()
  assert(q.client_id == "dynamic_agent_client")
  assert(q.agent_name_hint == "straps")
  assert(q.ext_agent_host_id == "urn:uuid:" .. registry.call("fn.openai_device_id"))
  assert(q.response_type == "code")
  assert(q.redirect_uri == "http://127.0.0.1:1455/auth/callback")
  assert(q.resource == "https://api.openai.com/v1")
  assert(q.scope == "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct")
  assert(q.code_challenge_method == "S256")
  assert(#q.state >= 43 and #q.nonce >= 43 and #q.code_challenge == 43)
end)

it("pasted URL with the wrong state, host, error, or no client_id is refused", function()
  local _, q = login_url()
  local base = "http://127.0.0.1:1455/auth/callback?code=c1&client_id=cid&state="
  local cases = {
    { base .. "nope", "state mismatch" },
    { "http://localhost:1455/auth/callback?code=c1&client_id=cid&state=" .. q.state, "must start with" },
    { "http://127.0.0.1:1455/auth/callback?error=access_denied&state=" .. q.state, "access_denied" },
    { "http://127.0.0.1:1455/auth/callback?code=c1&state=" .. q.state, "client_id" },
    { "not a url", "full callback URL" },
  }
  for _, c in ipairs(cases) do
    local ok, err = pcall(registry.call, "fn.openai_oauth_login", { callback_url = c[1] })
    assert(not ok and tostring(err):find(c[2], 1, true), c[2] .. " -> " .. tostring(err))
  end
  assert(oauth.pending_login, "a refused paste must leave the login pending")
end)

it("pasted URL completes the login; secrets travel on stdin, not argv", function()
  set_mode("ok")
  set_sleep(0)
  local _, q = login_url()
  local t_before = oauth.now_ms()
  local err = complete("http://127.0.0.1:1455/auth/callback?code=the-code&scope=x&client_id=%20cid-issued%20&state=" .. q.state)
  assert(err == nil, tostring(err))
  local body = oauth.parse_query(last_stdin())
  assert(body.grant_type == "authorization_code" and body.code == "the-code" and body.client_id == "cid-issued")
  assert(body.redirect_uri == oauth.REDIRECT_URI and body.resource == oauth.RESOURCE)
  assert(oauth.challenge(body.code_verifier) == q.code_challenge, "verifier does not match the challenge")
  assert(not argv_text():find("the-code", 1, true) and not argv_text():find(body.code_verifier, 1, true))
  local c = registry.call("fn.openai_oauth_credential")
  assert(c.client_id == "cid-issued" and c.access:match("^acc%-") and c.refresh:match("^ref%-"))
  assert(c.expires >= t_before + 3600 * 1000 - 180 * 1000 and c.expires <= oauth.now_ms() + 3600 * 1000 - 180 * 1000,
    "expires should be now + expires_in - 3 min, got offset " .. (c.expires - t_before))
  assert(oauth.pending_login == nil, "login record should be cleared")
end)

it("a login older than its TTL is refused", function()
  local _, q = login_url()
  oauth.pending_login.expires_at = oauth.now_ms() - 1
  local ok, err = pcall(registry.call, "fn.openai_oauth_login",
    { callback_url = "http://127.0.0.1:1455/auth/callback?code=c&client_id=cid&state=" .. q.state })
  assert(not ok and tostring(err):find("no pending", 1, true), tostring(err))
  assert(oauth.pending_login == nil)
end)

it("a second paste of the same URL finds no pending login", function()
  local ok, err = pcall(registry.call, "fn.openai_oauth_login",
    { callback_url = "http://127.0.0.1:1455/auth/callback?code=x&client_id=c&state=s" })
  assert(not ok and tostring(err):find("no pending", 1, true), tostring(err))
end)

it("a grant without chatgpt.tokens.use.direct is rejected and nothing is saved", function()
  registry.call("fn.openai_oauth_credential", false)
  registry.call("fn.api_key_store", "openai", "sk-keep")
  set_mode("noscope")
  local _, q = login_url()
  local err = complete("http://127.0.0.1:1455/auth/callback?code=c&client_id=cid&state=" .. q.state)
  set_mode("ok")
  local kept = registry.call("fn.api_key_store", "openai")
  registry.call("fn.api_key_store", "openai", false)
  assert(err and tostring(err):find("chatgpt.tokens.use.direct", 1, true), tostring(err))
  assert(registry.call("fn.openai_oauth_credential") == nil)
  assert(kept == "sk-keep", "a rejected login must keep the stored key: " .. tostring(kept))
end)

it("a failed token exchange keeps the stored OpenAI key", function()
  registry.call("fn.openai_oauth_credential", false)
  registry.call("fn.api_key_store", "openai", "sk-keep")
  set_mode("fail")
  local _, q = login_url()
  local err = complete("http://127.0.0.1:1455/auth/callback?code=c&client_id=cid&state=" .. q.state)
  set_mode("ok")
  local kept = registry.call("fn.api_key_store", "openai")
  registry.call("fn.api_key_store", "openai", false)
  assert(err ~= nil, "the exchange should fail")
  assert(kept == "sk-keep", "a failed login must keep the stored key: " .. tostring(kept))
end)

it("a login whose openai_base_url changes to another host before completion is not saved and keeps the key", function()
  set_mode("ok")
  set_sleep(0)
  registry.call("fn.openai_oauth_credential", false)
  registry.call("fn.api_key_store", "openai", "sk-keep")
  local _, q = login_url()
  local saved = straps.config.openai_base_url
  straps.config.openai_base_url = "https://router.example/api"
  local err = complete("http://127.0.0.1:1455/auth/callback?code=c&client_id=cid&state=" .. q.state)
  straps.config.openai_base_url = saved
  local kept = registry.call("fn.api_key_store", "openai")
  registry.call("fn.api_key_store", "openai", false)
  assert(err and tostring(err):find("a ChatGPT login only works with https://api.openai.com", 1, true)
    and tostring(err):find("the ChatGPT login was not saved", 1, true) and not tostring(err):find("router.example", 1, true), tostring(err))
  assert(registry.call("fn.openai_oauth_credential") == nil, "the login must not be saved")
  assert(kept == "sk-keep", "the stored key must stay: " .. tostring(kept))
end)

it("a non-string openai_base_url refuses a login at start and at completion, naming the config key", function()
  set_mode("ok")
  set_sleep(0)
  registry.call("fn.openai_oauth_credential", false)
  local saved = straps.config.openai_base_url
  straps.config.openai_base_url = 1
  oauth.pending_login = nil
  local ok, err = pcall(registry.call, "fn.openai_oauth_login", { open = function() end })
  local pending = oauth.pending_login
  straps.config.openai_base_url = saved
  local _, q = login_url()
  straps.config.openai_base_url = 1
  local done_err = complete("http://127.0.0.1:1455/auth/callback?code=c&client_id=cid&state=" .. q.state)
  straps.config.openai_base_url = saved
  assert(not ok and tostring(err):find("config.openai_base_url must be a URL string (got number)", 1, true), tostring(err))
  assert(pending == nil, "no login should start")
  assert(tostring(done_err):find("config.openai_base_url must be a URL string (got number); the ChatGPT login was not saved", 1, true),
    tostring(done_err))
  assert(registry.call("fn.openai_oauth_credential") == nil, "the login must not be saved")
end)

it("a ChatGPT login starts with openai_base_url set to https://api.openai.com/v1/", function()
  local saved = straps.config.openai_base_url
  straps.config.openai_base_url = "https://api.openai.com/v1/"
  oauth.pending_login = nil
  local ok, err = pcall(registry.call, "fn.openai_oauth_login", { open = function() end })
  straps.config.openai_base_url = saved
  local pending = oauth.pending_login
  oauth.pending_login = nil
  assert(ok, tostring(err))
  assert(pending ~= nil, "the login should start")
end)

it("logout during an in-flight exchange deletes the stored login and the new one is not saved", function()
  store(cred_fixture())
  set_sleep(1)
  local _, q = login_url()
  local done, err = false, nil
  registry.call("fn.openai_oauth_login", { callback_url = "http://127.0.0.1:1455/auth/callback?code=c&client_id=cid&state=" .. q.state,
    on_done = function(e) done, err = true, e end })
  local lo = false
  registry.call("fn.openai_oauth_logout", function() lo = true end)
  registry.call("fn.api_key_store", "openai", "sk-keep")
  assert(vim.wait(20000, function() return done and lo end, 10))
  set_sleep(0)
  local kept = registry.call("fn.api_key_store", "openai")
  registry.call("fn.api_key_store", "openai", false)
  assert(err and tostring(err):find("cancelled", 1, true), tostring(err))
  assert(registry.call("fn.openai_oauth_credential") == nil, "cancelled login must not be saved")
  assert(kept == "sk-keep", "a cancelled login must keep the stored key: " .. tostring(kept))
end)

it("a cancel that arrives while the login save waits on the lock drops the credential", function()
  registry.call("fn.openai_oauth_credential", false)
  local lock = xdg .. "/straps/openai_oauth.lock"
  vim.uv.fs_mkdir(lock, 448)
  vim.fn.writefile({ "other" }, lock .. "/owner")
  local _, q = login_url()
  local done, err = false, nil
  registry.call("fn.openai_oauth_login", { callback_url = "http://127.0.0.1:1455/auth/callback?code=c&client_id=cid&state=" .. q.state,
    on_done = function(e) done, err = true, e end })
  vim.wait(500, function() return done end, 10)
  assert(not done, "save should be waiting on the lock")
  registry.call("fn.openai_oauth_login", { cancel = true })
  vim.fn.delete(lock, "rf")
  assert(vim.wait(5000, function() return done end, 10), "login never finished")
  assert(err and tostring(err):find("cancelled", 1, true), tostring(err))
  assert(registry.call("fn.openai_oauth_credential") == nil, "cancelled login must not be saved")
  assert(vim.uv.fs_stat(lock) == nil, "lock left behind")
end)

it("refresh skips the POST while the token is outside the 5-minute window", function()
  store(cred_fixture())
  local before = post_count()
  local c = refresh_sync()
  assert(c.access == "acc-stored" and post_count() == before)
end)

it("refresh inside the window POSTs on stdin and saves the rotated token", function()
  store(cred_fixture({ expires = oauth.now_ms() + 60 * 1000 }))
  local before = post_count()
  local c = refresh_sync()
  assert(post_count() == before + 1)
  local body = oauth.parse_query(last_stdin())
  assert(body.grant_type == "refresh_token" and body.refresh_token == "ref-stored" and body.client_id == "cid-issued")
  assert(not argv_text():find("ref-stored", 1, true), "refresh token leaked into argv")
  assert(registry.call("fn.openai_oauth_credential").access == c.access and c.access ~= "acc-stored")
  assert(vim.uv.fs_stat(xdg .. "/straps/openai_oauth.lock") == nil, "lock not released")
end)

it("two concurrent refreshes produce one POST", function()
  store(cred_fixture({ expires = oauth.now_ms() - 1000 }))
  set_sleep(0.3)
  local before = post_count()
  local n, got = 0, {}
  for i = 1, 2 do
    registry.call("fn.openai_oauth_refresh", {}, function(c) n = n + 1; got[i] = c end)
  end
  assert(vim.wait(20000, function() return n == 2 end, 10))
  set_sleep(0)
  assert(post_count() == before + 1, "expected one POST, got " .. (post_count() - before))
  assert(got[1].access == got[2].access)
end)

it("rejected_access forces a refresh only when it matches the stored token", function()
  store(cred_fixture())
  local before = post_count()
  local c = refresh_sync({ rejected_access = "some-other-token" })
  assert(c.access == "acc-stored" and post_count() == before)
  c = refresh_sync({ rejected_access = "acc-stored" })
  assert(c.access ~= "acc-stored" and post_count() == before + 1)
end)

it("a failed refresh releases the lock, reports the full server body, and the next call POSTs", function()
  store(cred_fixture({ expires = 0 }))
  set_mode("fail")
  local c, err = refresh_sync()
  set_mode("ok")
  assert(c == nil and tostring(err):find("HTTP 400", 1, true) and tostring(err):find("invalid_grant", 1, true), tostring(err))
  assert(tostring(err):find("secret-detail", 1, true), "error_description missing: " .. tostring(err))
  assert(tostring(err):find(":StrapsLogin openai", 1, true))
  assert(not tostring(err):find("ref-stored", 1, true))
  assert(vim.uv.fs_stat(xdg .. "/straps/openai_oauth.lock") == nil, "lock not released after failure")
  local before = post_count()
  assert(refresh_sync() and post_count() == before + 1)
end)

it("a server body that echoes request secrets is redacted in the error", function()
  store(cred_fixture({ expires = 0, refresh = "ref-echo-secret-123" }))
  set_mode("echo")
  local _, err = refresh_sync()
  set_mode("ok")
  assert(tostring(err):find("HTTP 400", 1, true) and tostring(err):find("[redacted]", 1, true), tostring(err))
  assert(not tostring(err):find("ref-echo-secret-123", 1, true), tostring(err))
  assert(not tostring(err):find("cid-issued", 1, true), tostring(err))
end)

it("a refresh with no client_id or a logged-out file fails cleanly", function()
  store(cred_fixture({ expires = 0, client_id = "" }))
  local _, err = refresh_sync()
  assert(tostring(err):find("no client id", 1, true), tostring(err))
  registry.call("fn.openai_oauth_credential", false)
  _, err = refresh_sync()
  assert(tostring(err):find("logged out", 1, true), tostring(err))
end)

it("a fresh lock is waited on; a stale lock is taken over", function()
  store(cred_fixture())
  local lock = xdg .. "/straps/openai_oauth.lock"
  vim.uv.fs_mkdir(lock, 448)
  vim.fn.writefile({ "other" }, lock .. "/owner")
  local done = false
  registry.call("fn.openai_oauth_refresh", {}, function() done = true end)
  vim.wait(300, function() return done end, 10)
  assert(not done, "refresh should wait on a fresh lock")
  local old = (oauth.now_ms() - 60 * 1000) / 1000
  vim.uv.fs_utime(lock, old, old)
  assert(vim.wait(5000, function() return done end, 10), "stale lock was not taken over")
  assert(vim.uv.fs_stat(lock) == nil)
end)

it("fn.openai_api_key: a stored login wins over $OPENAI_API_KEY (precedence A)", function()
  store(cred_fixture())
  vim.env.OPENAI_API_KEY = "env-key"
  local key, source = registry.call("fn.openai_api_key")
  assert(key == "acc-stored" and source == "oauth", tostring(key) .. " " .. tostring(source))
  registry.call("fn.openai_oauth_credential", false)
  key, source = registry.call("fn.openai_api_key")
  vim.env.OPENAI_API_KEY = nil
  assert(key == "env-key" and source == "env")
end)

it("fn.openai_api_key: a stored login wins over the key file", function()
  store(cred_fixture())
  vim.fn.writefile({ "file-key" }, xdg .. "/straps/openai_api_key")
  vim.fn.setfperm(xdg .. "/straps/openai_api_key", "rw-------")
  local key, source = registry.call("fn.openai_api_key")
  vim.fn.delete(xdg .. "/straps/openai_api_key")
  assert(key == "acc-stored" and source == "oauth", tostring(key) .. " " .. tostring(source))
end)

it("fn.openai_api_key: a failed refresh errors and does not fall back to the key file or env key", function()
  store(cred_fixture({ expires = 0 }))
  vim.env.OPENAI_API_KEY = "env-key"
  registry.call("fn.api_key_store", "openai", "file-key")
  set_mode("fail")
  local ok, err = pcall(registry.call, "fn.openai_api_key")
  set_mode("ok")
  vim.env.OPENAI_API_KEY = nil
  registry.call("fn.api_key_store", "openai", false)
  assert(not ok and tostring(err):find(":StrapsLogin openai", 1, true), tostring(err))
end)

it("fn.openai_api_key: refresh = false never POSTs", function()
  store(cred_fixture({ expires = 0 }))
  local before = post_count()
  local key = registry.call("fn.openai_api_key", { refresh = false })
  assert(key == "acc-stored" and post_count() == before)
end)

it("fn.openai_api_key: the login token is never sent to a custom base URL", function()
  store(cred_fixture())
  local ok, err = pcall(registry.call, "fn.openai_api_key", { base_url = "https://proxy.example" })
  assert(not ok and tostring(err):find("openai_base_url", 1, true), tostring(err))
  assert(tostring(err):find(":StrapsLogin openai key", 1, true), tostring(err))
  assert(registry.call("fn.openai_api_key", { base_url = "https://api.openai.com/" }) == "acc-stored")
  assert(registry.call("fn.openai_api_key", { base_url = "https://api.openai.com/v1" }) == "acc-stored")
  local saved = straps.config.openai_base_url
  straps.config.openai_base_url = "https://api.openai.com/v1/"
  local ok_cfg, key = pcall(registry.call, "fn.openai_api_key")
  straps.config.openai_base_url = saved
  assert(ok_cfg and key == "acc-stored", tostring(key))
end)

it("fn.openai_api_key: without a ChatGPT login, the env key is used once the key file is gone", function()
  registry.call("fn.openai_oauth_credential", false)
  registry.call("fn.api_key_store", "openai", "file-key")
  vim.env.OPENAI_API_KEY = "env-key"
  local key1, source1 = registry.call("fn.openai_api_key")
  registry.call("fn.api_key_store", "openai", false)
  local key2, source2 = registry.call("fn.openai_api_key")
  vim.env.OPENAI_API_KEY = nil
  assert(key1 == "file-key" and source1 == "stored", tostring(key1) .. " " .. tostring(source1))
  assert(key2 == "env-key" and source2 == "env", tostring(key2) .. " " .. tostring(source2))
end)

it("a completed ChatGPT login deletes a stored OpenAI key file", function()
  set_mode("ok")
  set_sleep(0)
  registry.call("fn.api_key_store", "openai", "file-key")
  local msgs = {}
  local orig = vim.notify
  vim.notify = function(m) msgs[#msgs + 1] = tostring(m) end
  local _, q = login_url()
  local done = false
  registry.call("fn.openai_oauth_login", { callback_url = "http://127.0.0.1:1455/auth/callback?code=c&client_id=cid&state=" .. q.state })
  done = vim.wait(20000, function() return #msgs > 0 end, 10)
  vim.notify = orig
  assert(done, "login never reported")
  assert(registry.call("fn.openai_oauth_credential") ~= nil, "login not saved")
  assert(registry.call("fn.api_key_store", "openai") == nil, "key file should be deleted")
  assert(msgs[1]:find("signed in with ChatGPT; deleted " .. xdg .. "/straps/openai_api_key", 1, true), vim.inspect(msgs))
end)

local function login_notices()
  local msgs = {}
  local orig = vim.notify
  vim.notify = function(m, lvl) msgs[#msgs + 1] = { msg = tostring(m), level = lvl } end
  local _, q = login_url()
  registry.call("fn.openai_oauth_login", { callback_url = "http://127.0.0.1:1455/auth/callback?code=c&client_id=cid&state=" .. q.state })
  local done = vim.wait(20000, function() return #msgs > 0 end, 10)
  vim.notify = orig
  assert(done, "login never reported")
  return msgs
end

it("a completed ChatGPT login with no key file reports only the sign-in", function()
  set_mode("ok")
  set_sleep(0)
  registry.call("fn.api_key_store", "openai", false)
  local msgs = login_notices()
  assert(#msgs == 1 and msgs[1].msg == "straps: signed in with ChatGPT", vim.inspect(msgs))
end)

it("a completed ChatGPT login whose key-file delete fails still reports success, with a note", function()
  set_mode("ok")
  set_sleep(0)
  vim.fn.mkdir(xdg .. "/straps/openai_api_key/blocker", "p")
  local msgs = login_notices()
  vim.fn.delete(xdg .. "/straps/openai_api_key", "rf")
  assert(registry.call("fn.openai_oauth_credential") ~= nil, "login not saved")
  assert(#msgs == 1 and msgs[1].level ~= vim.log.levels.ERROR, vim.inspect(msgs))
  assert(msgs[1].msg:find("^straps: signed in with ChatGPT; could not delete the stored OpenAI API key"), vim.inspect(msgs))
end)

local function provider_call(opts)
  opts = opts or {}
  local result, err
  local cancelled = false
  local cancel_fns = {}
  local ctx = {
    emit = function() end,
    cancelled = function() return cancelled end,
    on_cancel = function(fn) cancel_fns[#cancel_fns + 1] = fn end,
    await = function(start)
      local res, done = nil, false
      start(function(...) if not done then done, res = true, { n = select("#", ...), ... } end end)
      if opts.cancel_after_ms then
        vim.defer_fn(function()
          cancelled = true
          for _, fn in ipairs(cancel_fns) do pcall(fn) end
        end, opts.cancel_after_ms)
      end
      vim.wait(20000, function() return done end, 10)
      cancel_fns = {}
      return unpack(res, 1, res.n)
    end,
  }
  local co = coroutine.create(function()
    return registry.call("fn.provider_openai", { system = "s", messages = { { role = "user", content = "hi" } } }, ctx)
  end)
  local ok, r = coroutine.resume(co)
  if ok then result = r else err = r end
  return result, err
end

it("provider: a 401 with a login token refreshes once and retries with the new token", function()
  store(cred_fixture({ access = "acc-old" }))
  local before = post_count()
  local res, err = provider_call()
  assert(res and not err, tostring(err))
  assert(res.content[1].text == "oauth-ok", vim.inspect(res))
  assert(post_count() == before + 1, "expected exactly one refresh POST")
  local last_bearer
  for _, l in ipairs(vim.fn.readfile(tmp .. "/argv")) do
    if l:find("Bearer", 1, true) then last_bearer = l end
  end
  assert(last_bearer:find("Bearer acc%-") and not last_bearer:find("acc-old", 1, true), last_bearer)
end)

it("provider: a spawned child under a ChatGPT login sends its explicit model with the login token", function()
  store(cred_fixture({ access = "acc-spawn" }))
  local loop = require("straps.loop")
  local parent = vim.api.nvim_create_buf(true, false)
  vim.b[parent].straps_model = "claude-parent"
  local child
  local real_start = loop.start
  loop.start = function(b) child = b end
  local ok, serr = pcall(registry.call, "tool.spawn", { task = "probe", model = "gpt-spawned" }, { bufnr = parent })
  loop.start = real_start
  assert(ok and child, tostring(serr))
  local ctx = {
    bufnr = child,
    emit = function() end,
    cancelled = function() return false end,
    on_cancel = function() end,
    await = function(start)
      local r, fin = nil, false
      start(function(...) if not fin then fin, r = true, { n = select("#", ...), ... } end end)
      vim.wait(20000, function() return fin end, 10)
      return unpack(r, 1, r.n)
    end,
  }
  local co = coroutine.create(function()
    return registry.call("fn.provider", { system = "s", messages = { { role = "user", content = "hi" } } }, ctx)
  end)
  local done, res = coroutine.resume(co)
  assert(done and res.content[1].text == "oauth-ok", vim.inspect(res))
  local body = vim.json.decode(last_stdin())
  assert(body.model == "gpt-spawned", "child sent model " .. tostring(body.model))
  local last_bearer
  for _, l in ipairs(vim.fn.readfile(tmp .. "/argv")) do
    if l:find("Bearer", 1, true) then last_bearer = l end
  end
  assert(last_bearer:find("Bearer acc-spawn", 1, true), last_bearer)
end)

it("provider: a refresh that keeps failing surfaces the 401 instead of looping", function()
  store(cred_fixture({ access = "acc-old" }))
  set_mode("fail")
  local res, err = provider_call()
  set_mode("ok")
  assert(not res and tostring(err):find("401", 1, true) and tostring(err):find("StrapsLogin", 1, true), tostring(err))
end)

it("provider: cancel during the key refresh returns stop_reason cancelled and the token is still saved", function()
  store(cred_fixture({ expires = 0 }))
  set_sleep(0.5)
  local res, err = provider_call({ cancel_after_ms = 50 })
  assert(res and res.stop_reason == "cancelled", tostring(err) .. vim.inspect(res))
  assert(vim.wait(5000, function()
    local c = registry.call("fn.openai_oauth_credential")
    return c and c.access ~= "acc-stored"
  end, 20), "rotated token not saved after cancel")
  set_sleep(0)
end)

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

it(":StrapsLogin rejects unknown providers (not echoed) and extra arguments; completion offers providers and key", function()
  local ui = require("straps.ui")
  local msgs = capture_notify(function() ui.login({ "sk-secret" }) end)
  local m = has(msgs, "unknown provider")
  assert(m and not m.msg:find("sk-secret", 1, true) and m.msg:find("anthropic, openai, llamacpp", 1, true), vim.inspect(msgs))
  msgs = capture_notify(function() ui.login({ "openai", "a", "b" }) end)
  assert(has(msgs, "usage"), vim.inspect(msgs))
  vim.g.loaded_straps = nil
  vim.cmd.source(root .. "/plugin/straps.lua")
  assert(vim.deep_equal(vim.fn.getcompletion("StrapsLogin o", "cmdline"), { "openai" }))
  assert(vim.deep_equal(vim.fn.getcompletion("StrapsLogin ", "cmdline"), { "anthropic", "openai", "llamacpp" }))
  assert(#vim.fn.getcompletion("StrapsLogin x", "cmdline") == 0)
  assert(vim.deep_equal(vim.fn.getcompletion("StrapsLogin openai ", "cmdline"), { "codex", "key" }))
  assert(vim.deep_equal(vim.fn.getcompletion("StrapsLogin openai c", "cmdline"), { "codex" }))
  assert(vim.deep_equal(vim.fn.getcompletion("StrapsLogin anthropic ", "cmdline"), { "key" }))
  assert(#vim.fn.getcompletion("StrapsLogin nope ", "cmdline") == 0)
  assert(vim.deep_equal(vim.fn.getcompletion("StrapsLogout l", "cmdline"), { "llamacpp" }))
end)

it(":StrapsLogin openai key stores the key, then signs out of ChatGPT and cancels a pending login", function()
  local ui = require("straps.ui")
  store(cred_fixture())
  login_url()
  assert(oauth.pending_login ~= nil)
  local orig_input = vim.fn.inputsecret
  vim.fn.inputsecret = function() return "  sk-typed  " end
  local msgs = {}
  local orig = vim.notify
  vim.notify = function(mm) msgs[#msgs + 1] = tostring(mm) end
  local ok, err = pcall(ui.login, { "openai", "key" })
  vim.wait(5000, function() return #msgs > 0 end, 10)
  vim.notify = orig
  vim.fn.inputsecret = orig_input
  local pending = oauth.pending_login
  local cred = registry.call("fn.openai_oauth_credential")
  local stored = registry.call("fn.api_key_store", "openai")
  registry.call("fn.api_key_store", "openai", false)
  assert(ok, tostring(err))
  assert(pending == nil, "pending login should be cancelled")
  assert(cred == nil, "ChatGPT login should be deleted")
  assert(stored == "sk-typed", "key file should hold the typed key")
  assert(msgs[1] and msgs[1]:find("saved the openai API key", 1, true) and msgs[1]:find("signed out of ChatGPT", 1, true),
    vim.inspect(msgs))
end)

it(":StrapsLogin openai key with an empty answer keeps the ChatGPT login", function()
  local ui = require("straps.ui")
  store(cred_fixture())
  local orig_input = vim.fn.inputsecret
  vim.fn.inputsecret = function() return "" end
  local msgs = capture_notify(function() ui.login({ "openai", "key" }) end)
  vim.fn.inputsecret = orig_input
  assert(has(msgs, "login cancelled"), vim.inspect(msgs))
  assert(registry.call("fn.openai_oauth_credential") ~= nil, "the ChatGPT login should stay")
  assert(registry.call("fn.api_key_store", "openai") == nil, "no key should be written")
end)

it(":StrapsLogin openai key stores the key and says the login still wins when the sign-out fails", function()
  local ui = require("straps.ui")
  store(cred_fixture())
  registry.call("fn.api_key_store", "openai", "sk-old")
  local real = registry.get("fn.openai_oauth_logout")
  registry.define({ name = real.name, kind = "fn", doc = "test",
    source = [[return function(cb) vim.schedule(function() cb("could not lock the ChatGPT login: busy") end) end]] })
  local orig_input = vim.fn.inputsecret
  vim.fn.inputsecret = function() return "sk-new" end
  local msgs = {}
  local orig = vim.notify
  vim.notify = function(m, lvl) msgs[#msgs + 1] = { msg = tostring(m), level = lvl } end
  local ok, err = pcall(ui.login, { "openai", "key" })
  vim.wait(2000, function() return #msgs > 0 end, 10)
  vim.notify = orig
  vim.fn.inputsecret = orig_input
  registry.define({ name = real.name, kind = real.kind, doc = real.doc, source = real.source })
  local left = registry.call("fn.api_key_store", "openai")
  registry.call("fn.api_key_store", "openai", false)
  local cred = registry.call("fn.openai_oauth_credential")
  registry.call("fn.openai_oauth_credential", false)
  assert(ok, tostring(err))
  assert(msgs[1] and msgs[1].level == vim.log.levels.ERROR and msgs[1].msg:find("saved the openai API key", 1, true)
    and msgs[1].msg:find("could not lock", 1, true) and msgs[1].msg:find("still takes precedence", 1, true), vim.inspect(msgs))
  assert(left == "sk-new", "the new key should be stored: " .. tostring(left))
  assert(cred ~= nil, "the ChatGPT login was not signed out")
end)

it(":StrapsLogin openai key reports a sign-out that raises", function()
  local ui = require("straps.ui")
  store(cred_fixture())
  local real = registry.get("fn.openai_oauth_logout")
  registry.define({ name = real.name, kind = "fn", doc = "test", source = [[return function() error("straps: lock broken", 0) end]] })
  local orig_input = vim.fn.inputsecret
  vim.fn.inputsecret = function() return "sk-raise" end
  local ok, msgs = pcall(capture_notify, function()
    ui.login({ "openai", "key" })
    vim.wait(2000, function() return false end, 10)
  end)
  vim.fn.inputsecret = orig_input
  registry.define({ name = real.name, kind = real.kind, doc = real.doc, source = real.source })
  local left = registry.call("fn.api_key_store", "openai")
  registry.call("fn.api_key_store", "openai", false)
  registry.call("fn.openai_oauth_credential", false)
  assert(ok, tostring(msgs))
  local e = has(msgs, "lock broken")
  assert(e and e.level == vim.log.levels.ERROR and e.msg:find("saved the openai API key", 1, true)
    and e.msg:find("still takes precedence", 1, true), vim.inspect(msgs))
  assert(left == "sk-raise", tostring(left))
end)

it(":StrapsLogin with no argument and openai as the resolved provider starts the ChatGPT login", function()
  local ui = require("straps.ui")
  oauth.pending_login = nil
  local asked = false
  local orig_input, orig_open = vim.fn.inputsecret, vim.ui.open
  vim.fn.inputsecret = function() asked = true return "x" end
  vim.ui.open = function() return nil, "no browser" end
  local msgs = capture_notify(function() ui.login({}) end)
  vim.fn.inputsecret, vim.ui.open = orig_input, orig_open
  local pending = oauth.pending_login
  oauth.pending_login = nil
  assert(not asked, "no key prompt should run")
  assert(pending ~= nil and has(msgs, oauth.AUTHORIZE_URL), vim.inspect(msgs))
end)

it(":StrapsLogin openai key with an invalid key keeps the ChatGPT login and the old key", function()
  local ui = require("straps.ui")
  store(cred_fixture())
  registry.call("fn.api_key_store", "openai", "sk-old")
  local orig_input = vim.fn.inputsecret
  vim.fn.inputsecret = function() return "sk new" end
  local msgs = capture_notify(function() ui.login({ "openai", "key" }) end)
  vim.fn.inputsecret = orig_input
  local left = registry.call("fn.api_key_store", "openai")
  registry.call("fn.api_key_store", "openai", false)
  local e = has(msgs, "the key has spaces or control characters")
  assert(e and e.level == vim.log.levels.ERROR and not e.msg:find("sk new", 1, true), vim.inspect(msgs))
  assert(registry.call("fn.openai_oauth_credential") ~= nil, "the ChatGPT login should stay")
  assert(left == "sk-old", "the old key should stay: " .. tostring(left))
end)

it(":StrapsLogin openai key with no ChatGPT login says only that the key was saved", function()
  local ui = require("straps.ui")
  registry.call("fn.openai_oauth_credential", false)
  oauth.pending_login = nil
  local orig_input = vim.fn.inputsecret
  vim.fn.inputsecret = function() return "sk-only" end
  local msgs = {}
  local orig = vim.notify
  vim.notify = function(m) msgs[#msgs + 1] = tostring(m) end
  ui.login({ "openai", "key" })
  vim.wait(2000, function() return #msgs > 0 end, 10)
  vim.notify = orig
  vim.fn.inputsecret = orig_input
  registry.call("fn.api_key_store", "openai", false)
  assert(msgs[1] == "straps: saved the openai API key to " .. xdg .. "/straps/openai_api_key", vim.inspect(msgs))
end)

it(":StrapsLogin openai key during a pending ChatGPT login reports the cancel", function()
  local ui = require("straps.ui")
  registry.call("fn.openai_oauth_credential", false)
  login_url()
  local orig_input = vim.fn.inputsecret
  vim.fn.inputsecret = function() return "sk-p" end
  local msgs = {}
  local orig = vim.notify
  vim.notify = function(m) msgs[#msgs + 1] = tostring(m) end
  ui.login({ "openai", "key" })
  vim.wait(2000, function() return #msgs > 0 end, 10)
  vim.notify = orig
  vim.fn.inputsecret = orig_input
  registry.call("fn.api_key_store", "openai", false)
  assert(msgs[1] and msgs[1]:find("; pending ChatGPT login cancelled$"), vim.inspect(msgs))
  assert(oauth.pending_login == nil)
end)

it(":StrapsLogin openai with a non-URL argument shows the usage without echoing it", function()
  local ui = require("straps.ui")
  local msgs = capture_notify(function() ui.login({ "openai", "sk-pasted" }) end)
  local m = has(msgs, "usage: :StrapsLogin openai [codex | redirect-url | key]")
  assert(m and not m.msg:find("sk-pasted", 1, true), vim.inspect(msgs))
end)

it("a ChatGPT login is refused with a custom openai_base_url, and the stored key stays", function()
  local ui = require("straps.ui")
  registry.call("fn.api_key_store", "openai", "sk-router")
  oauth.pending_login = nil
  local saved = straps.config.openai_base_url
  straps.config.openai_base_url = "https://router.example/api"
  local msgs = capture_notify(function() ui.login({ "openai" }) end)
  straps.config.openai_base_url = saved
  local left = registry.call("fn.api_key_store", "openai")
  registry.call("fn.api_key_store", "openai", false)
  local m = has(msgs, "a ChatGPT login only works with https://api.openai.com")
  assert(m and m.msg:find(":StrapsLogin openai key", 1, true), vim.inspect(msgs))
  assert(oauth.pending_login == nil, "no login should start")
  assert(left == "sk-router", "the stored key should stay")
end)

it("opts.on_done gets a note when a completed ChatGPT login deletes the stored key", function()
  set_mode("ok")
  set_sleep(0)
  registry.call("fn.api_key_store", "openai", "sk-old")
  local _, q = login_url()
  local done, err, note = false, nil, nil
  registry.call("fn.openai_oauth_login", { callback_url = "http://127.0.0.1:1455/auth/callback?code=c&client_id=cid&state=" .. q.state,
    on_done = function(e, n) done, err, note = true, e, n end })
  assert(vim.wait(20000, function() return done end, 10), "login never finished")
  assert(err == nil, tostring(err))
  assert(note == "deleted " .. xdg .. "/straps/openai_api_key", tostring(note))
end)

it(":StrapsLogout openai with only a pending login reports the cancel", function()
  local ui = require("straps.ui")
  registry.call("fn.openai_oauth_credential", false)
  registry.call("fn.api_key_store", "openai", false)
  login_url()
  local msgs = {}
  local orig = vim.notify
  vim.notify = function(m) msgs[#msgs + 1] = tostring(m) end
  ui.logout({ "openai" })
  vim.wait(2000, function() return #msgs > 0 end, 10)
  vim.notify = orig
  assert(msgs[1] == "straps: pending ChatGPT login cancelled", vim.inspect(msgs))
  assert(oauth.pending_login == nil)
end)

it(":StrapsLogin openai starts a login and prints the URL; a bad paste is reported without a prefix twice", function()
  local ui = require("straps.ui")
  local orig_open = vim.ui.open
  vim.ui.open = function() return nil, "no browser" end
  local msgs = capture_notify(function() ui.login({ "openai" }) end)
  vim.ui.open = orig_open
  local m = has(msgs, oauth.AUTHORIZE_URL)
  assert(m and m.msg:find("open this URL", 1, true) and m.msg:find(oauth.REDIRECT_ORIGIN, 1, true), vim.inspect(msgs))
  msgs = capture_notify(function() ui.login({ "openai", "http://127.0.0.1:1455/auth/callback?code=c&client_id=x&state=bad" }) end)
  local e = has(msgs, "state mismatch")
  assert(e and not e.msg:find("straps: straps:", 1, true) and e.level == vim.log.levels.ERROR, vim.inspect(msgs))
end)

it(":StrapsLogout reports what it did", function()
  local ui = require("straps.ui")
  registry.call("fn.openai_oauth_credential", false)
  oauth.pending_login = nil
  local msgs = {}
  local orig = vim.notify
  vim.notify = function(mm) msgs[#msgs + 1] = { msg = tostring(mm) } end
  ui.logout({ "openai" })
  vim.wait(2000, function() return #msgs > 0 end, 10)
  store(cred_fixture())
  ui.logout({ "openai" })
  vim.wait(5000, function() return #msgs > 1 end, 10)
  registry.call("fn.api_key_store", "openai", "file-key")
  ui.logout({ "openai" })
  vim.wait(5000, function() return #msgs > 2 end, 10)
  store(cred_fixture())
  registry.call("fn.api_key_store", "openai", "file-key")
  vim.env.OPENAI_API_KEY = "env-key"
  ui.logout({ "openai" })
  vim.wait(5000, function() return #msgs > 3 end, 10)
  vim.env.OPENAI_API_KEY = nil
  vim.notify = orig
  assert(msgs[1].msg:find("no stored openai credential", 1, true), vim.inspect(msgs))
  assert(msgs[2] and msgs[2].msg == "straps: signed out of ChatGPT", vim.inspect(msgs))
  assert(msgs[3] and msgs[3].msg == "straps: deleted " .. xdg .. "/straps/openai_api_key", vim.inspect(msgs))
  assert(msgs[4] and msgs[4].msg:find("signed out of ChatGPT", 1, true) and msgs[4].msg:find("deleted ", 1, true)
    and msgs[4].msg:find("$OPENAI_API_KEY is still set", 1, true), vim.inspect(msgs))
  assert(registry.call("fn.openai_oauth_credential") == nil)
  assert(registry.call("fn.api_key_store", "openai") == nil)
end)

it("health reports a stored login, its source, and a missing client id", function()
  local rec = {}
  local orig = {}
  for _, k in ipairs({ "start", "ok", "warn", "error", "info" }) do
    orig[k] = vim.health[k]
    vim.health[k] = function(msg) rec[#rec + 1] = { kind = k, msg = tostring(msg) } end
  end
  local function run()
    rec = {}
    local ok, err = pcall(require("straps.health").check)
    assert(ok, tostring(err))
    return rec
  end
  local function find(kind, s)
    for _, r in ipairs(rec) do if r.kind == kind and r.msg:find(s, 1, true) then return r end end
  end
  store(cred_fixture())
  run()
  local good = find("ok", "ChatGPT login:") and find("ok", "source: oauth")
  store(cred_fixture({ client_id = "" }))
  run()
  local missing = find("error", "has no client id")
  for k, f in pairs(orig) do vim.health[k] = f end
  assert(good, vim.inspect(rec))
  assert(missing, vim.inspect(rec))
end)

it("list_models applies the base URL guard", function()
  store(cred_fixture())
  local saved = straps.config.openai_base_url
  straps.config.openai_base_url = "https://proxy.example"
  local models, err = registry.call("fn.list_models", "openai")
  straps.config.openai_base_url = saved
  assert(models == nil and tostring(err):find("openai_base_url", 1, true), tostring(err))
end)
