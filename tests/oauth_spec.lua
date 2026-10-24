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
  set_mode("noscope")
  local _, q = login_url()
  local err = complete("http://127.0.0.1:1455/auth/callback?code=c&client_id=cid&state=" .. q.state)
  set_mode("ok")
  assert(err and tostring(err):find("chatgpt.tokens.use.direct", 1, true), tostring(err))
  assert(registry.call("fn.openai_oauth_credential") == nil)
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
  assert(vim.wait(20000, function() return done and lo end, 10))
  set_sleep(0)
  assert(err and tostring(err):find("cancelled", 1, true), tostring(err))
  assert(registry.call("fn.openai_oauth_credential") == nil, "cancelled login must not be saved")
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

it("fn.openai_api_key: a failed refresh errors and does not fall back to the env key", function()
  store(cred_fixture({ expires = 0 }))
  vim.env.OPENAI_API_KEY = "env-key"
  set_mode("fail")
  local ok, err = pcall(registry.call, "fn.openai_api_key")
  set_mode("ok")
  vim.env.OPENAI_API_KEY = nil
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
  assert(registry.call("fn.openai_api_key", { base_url = "https://api.openai.com/" }) == "acc-stored")
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

it(":StrapsLogin rejects other providers and extra arguments; completion offers openai", function()
  local ui = require("straps.ui")
  local msgs = capture_notify(function() ui.login({ "anthropic" }) end)
  assert(has(msgs, "only `openai` supports login"), vim.inspect(msgs))
  msgs = capture_notify(function() ui.login({ "openai", "a", "b" }) end)
  assert(has(msgs, "usage"), vim.inspect(msgs))
  vim.g.loaded_straps = nil
  vim.cmd.source(root .. "/plugin/straps.lua")
  assert(vim.deep_equal(vim.fn.getcompletion("StrapsLogin o", "cmdline"), { "openai" }))
  assert(#vim.fn.getcompletion("StrapsLogin x", "cmdline") == 0)
  assert(#vim.fn.getcompletion("StrapsLogin openai ", "cmdline") == 0)
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
  vim.notify = orig
  assert(msgs[1].msg:find("no ChatGPT login stored", 1, true), vim.inspect(msgs))
  assert(msgs[2] and msgs[2].msg:find("signed out", 1, true), vim.inspect(msgs))
  assert(registry.call("fn.openai_oauth_credential") == nil)
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
    pcall(require("straps.health").check)
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
