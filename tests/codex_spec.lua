-- Codex login tests: the Codex-CLI-style ChatGPT login as the openai
-- provider's third credential (:StrapsLogin openai codex), its refresh, the
-- one-credential rule, the Codex request shape, errors, the model list and the
-- session id. A fake `curl` first on PATH serves the token endpoint, the Codex
-- responses and models endpoints and /v1/responses, logging argv and stdin.
-- Run: busted tests/codex_spec.lua

local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(vim.fn.fnamemodify(here, ":p"), ":h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local straps = require("straps").setup({})
straps.config.session_dir = vim.fn.tempname()
straps.config.provider = "openai"
local registry = require("straps.registry")
local oauth = require("straps.oauth")
local state = require("straps.state")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp .. "/bin", "p")
local xdg = tmp .. "/config"
vim.env.XDG_CONFIG_HOME = xdg
vim.env.OPENAI_API_KEY = nil
vim.env.PATH = tmp .. "/bin:" .. vim.env.PATH

local function b64url(s) return oauth.b64url(s) end
local function jwt(claims)
  return b64url('{"alg":"none"}') .. "." .. b64url(vim.json.encode(claims)) .. ".sig"
end
local function codex_jwt(account, extra)
  local claims = { [oauth.JWT_AUTH_CLAIM] = { chatgpt_account_id = account } }
  for k, v in pairs(extra or {}) do claims[k] = v end
  return jwt(claims)
end
vim.fn.writefile({ codex_jwt("acct-1") }, tmp .. "/access1")
vim.fn.writefile({ codex_jwt("acct-2") }, tmp .. "/access2")

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
    ACC=$(cat "$D/access_next" 2>/dev/null || cat "$D/access1")
    if [ "$MODE" = fail ]; then
      printf '{"error":"invalid_grant"}\nSTRAPS_HTTP_STATUS:400\n'
    elif [ "$MODE" = noacct ]; then
      printf '{"access_token":"plain-token","refresh_token":"ref-%%s","expires_in":3600}\nSTRAPS_HTTP_STATUS:200\n' "$N"
    else
      printf '{"access_token":"%%s","refresh_token":"ref-%%s","expires_in":3600}\nSTRAPS_HTTP_STATUS:200\n' "$ACC" "$N"
    fi
    ;;
  *codex/models*)
    MODE=$(cat "$D/models_mode" 2>/dev/null || echo ok)
    if [ "$MODE" = fail ]; then
      printf 'nope\nSTRAPS_HTTP_STATUS:500\n'
    elif [ "$MODE" = empty ]; then
      printf '{"models":[{"slug":"gpt-hidden","visibility":"hide"}]}\nSTRAPS_HTTP_STATUS:200\n'
    else
      printf '{"models":[{"slug":"gpt-live","display_name":"GPT Live","context_window":123,"visibility":"list","supported_reasoning_levels":[{"effort":"medium","description":"m"},{"effort":"low","description":"l"}]},{"slug":"gpt-junk","visibility":"list","supported_reasoning_levels":[{"description":"no effort"},7]},{"slug":"gpt-hidden","visibility":"hide"}]}\nSTRAPS_HTTP_STATUS:200\n'
    fi
    ;;
  *codex/responses*|*v1/responses*)
    MODE=$(cat "$D/resp_mode" 2>/dev/null || echo ok)
    if printf '%%s' "$*" | grep -q 'Bearer stale-access'; then
      printf '{"error":{"message":"expired"}}'
      echo "STRAPS_HTTP_STATUS:401" >&2
    elif [ "$MODE" = usage ]; then
      printf '{"error":{"code":"usage_limit_reached","message":"limit","plan_type":"PLUS","resets_at":%%s}}' "$(cat "$D/resets_at")"
      echo "STRAPS_HTTP_STATUS:429" >&2
    elif [ "$MODE" = notincluded ]; then
      printf '{"error":{"type":"usage_not_included","message":"no"}}'
      echo "STRAPS_HTTP_STATUS:403" >&2
    elif [ "$MODE" = after_terminal ]; then
      echo "STRAPS_HTTP_STATUS:200" >&2
      printf 'data: {"type":"response.output_text.delta","output_index":0,"delta":"hi"}\n\ndata: {"type":"response.done","response":{"status":"completed","usage":{"input_tokens":3,"output_tokens":2}}}\n\ndata: {"type":"response.output_text.delta","output_index":0,"delta":"LATE"}\n\ndata: {"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":99,"output_tokens":99}}}\n\n'
    elif [ "$MODE" = ratelimit ]; then
      printf '{"error":{"code":"rate_limit_exceeded","message":"slow down"}}'
      echo "STRAPS_HTTP_STATUS:429" >&2
    elif [ "$MODE" = done_completed ]; then
      echo "STRAPS_HTTP_STATUS:200" >&2
      printf 'data: {"type":"response.output_text.delta","output_index":0,"delta":"hi"}\n\n'
      printf 'data: {"type":"response.done","response":{"status":"completed","usage":{"input_tokens":3,"output_tokens":2}}}\n\n'
      printf 'data: {"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":99,"output_tokens":99}}}\n\n'
    elif [ "$MODE" = done_nostatus ]; then
      echo "STRAPS_HTTP_STATUS:200" >&2
      printf 'data: {"type":"response.output_text.delta","output_index":0,"delta":"hi"}\n\n'
      printf 'data: {"type":"response.done","response":{}}\n\n'
    elif [ "$MODE" = done_incomplete ]; then
      echo "STRAPS_HTTP_STATUS:200" >&2
      printf 'data: {"type":"response.output_item.added","output_index":1,"item":{"type":"function_call","call_id":"c1","name":"half"}}\n\n'
      printf 'data: {"type":"response.function_call_arguments.delta","output_index":1,"delta":"{\\"a\\":"}\n\n'
      printf 'data: {"type":"response.done","response":{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"}}}\n\n'
    elif [ "$MODE" = done_failed ]; then
      echo "STRAPS_HTTP_STATUS:200" >&2
      printf 'data: {"type":"response.done","response":{"status":"failed","error":{"code":"bad_thing","message":"it broke"}}}\n\n'
    else
      echo "STRAPS_HTTP_STATUS:200" >&2
      printf 'data: {"type":"response.output_text.delta","output_index":0,"delta":"codex-ok"}\n\n'
      printf 'data: {"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":5,"output_tokens":5}}}\n\n'
    fi
    ;;
esac
]]):format(tmp)
fake = fake:gsub("^#!/usr/bin/env bash", "#!" .. vim.fn.exepath("bash"), 1)
vim.fn.writefile(vim.split(fake, "\n"), tmp .. "/bin/curl")
vim.fn.setfperm(tmp .. "/bin/curl", "rwxr-xr-x")

local function reset_log()
  vim.fn.delete(tmp .. "/argv")
end
local function argv_lines()
  return vim.fn.filereadable(tmp .. "/argv") == 1 and vim.fn.readfile(tmp .. "/argv") or {}
end
local function count(pattern)
  local n = 0
  for _, l in ipairs(argv_lines()) do if l:find(pattern, 1, true) then n = n + 1 end end
  return n
end
local function last_stdin() return table.concat(vim.fn.readfile(tmp .. "/stdin." .. vim.fn.readfile(tmp .. "/n")[1]), "\n") end
local function set(name, v) vim.fn.writefile({ tostring(v) }, tmp .. "/" .. name) end
local function unset(name) vim.fn.delete(tmp .. "/" .. name) end
local codex_path = xdg .. "/straps/openai_codex.json"
local chatgpt_path = xdg .. "/straps/openai_oauth.json"

local function codex_fixture(over)
  return vim.tbl_extend("force", { access = vim.fn.readfile(tmp .. "/access1")[1], refresh = "ref-stored",
    account_id = "acct-1", expires = oauth.now_ms() + 3600 * 1000 }, over or {})
end
local function chatgpt_fixture()
  return { access = "acc-chatgpt", refresh = "ref-chatgpt", client_id = "cid", expires = oauth.now_ms() + 3600 * 1000,
    scopes = { oauth.DIRECT_TOKEN_SCOPE } }
end
local function clear_all()
  registry.call("fn.openai_codex_credential", false)
  registry.call("fn.openai_oauth_credential", false)
  registry.call("fn.api_key_store", "openai", false)
  oauth.pending_login, oauth.pending_codex_login = nil, nil
end
local function codex_login_url()
  local url = registry.call("fn.openai_codex_login", { open = function() return true end })
  return url, oauth.parse_query(url:match("%?(.*)$"))
end
local function codex_complete(callback)
  local done, err, note = false, nil, nil
  registry.call("fn.openai_codex_login", { callback_url = callback, on_done = function(e, n) done, err, note = true, e, n end })
  assert(vim.wait(20000, function() return done end, 10), "codex login never finished")
  return err, note
end
local function callback_for(q) return oauth.CODEX_REDIRECT_URI .. "?code=the-code&scope=x&state=" .. q.state end

local function provider_call(opts)
  opts = opts or {}
  local cancelled = false
  local emitted = {}
  local ctx = {
    bufnr = opts.bufnr,
    emit = function(e) emitted[#emitted + 1] = e end,
    cancelled = function() return cancelled end,
    on_cancel = function() end,
    model = opts.model,
    model_entry = opts.model_entry,
    await = function(start)
      local res, done = nil, false
      start(function(...) if not done then done, res = true, { n = select("#", ...), ... } end end)
      vim.wait(30000, function() return done end, 10)
      return unpack(res, 1, res.n)
    end,
  }
  local co = coroutine.create(function()
    return registry.call("fn.provider_openai", { system = opts.system == nil and "sys" or opts.system,
      messages = { { role = "user", content = "hi" } } }, ctx)
  end)
  local ok, r = coroutine.resume(co)
  if ok then return r, nil, emitted end
  return nil, r, emitted
end
local function last_request()
  local n = tonumber(vim.fn.readfile(tmp .. "/n")[1])
  for i = n, 1, -1 do
    local ok, body = pcall(vim.json.decode, table.concat(vim.fn.readfile(tmp .. "/stdin." .. i), "\n"))
    if ok and type(body) == "table" and body.input then return body end
  end
end
local function last_argv_with(pattern)
  local lines = argv_lines()
  for i = #lines, 1, -1 do if lines[i]:find(pattern, 1, true) then return lines[i] end end
end

it("jwt_payload decodes base64url payloads of every padding length; codex_account_id reads the claim", function()
  for _, pad in ipairs({ "", "x", "xy", "xyz" }) do
    local payload = { [oauth.JWT_AUTH_CLAIM] = { chatgpt_account_id = "acct" }, p = pad }
    local token = jwt(payload)
    local part = token:match("^[^.]+%.([^.]+)")
    local got = oauth.jwt_payload(token)
    assert(got and got.p == pad, ("pad %q len%%4=%d"):format(pad, #part % 4))
    assert(oauth.codex_account_id(token) == "acct")
  end
  local seen = {}
  for _, pad in ipairs({ "", "x", "xy", "xyz" }) do
    seen[#(jwt({ p = pad }):match("^[^.]+%.([^.]+)")) % 4] = true
  end
  assert(seen[2] and seen[3], "the cases must cover payload length mod 4 = 2 and 3")
  assert(oauth.jwt_payload("not-a-jwt") == nil)
  assert(oauth.codex_account_id(jwt({ other = 1 })) == nil)
  assert(oauth.codex_account_id(codex_jwt("bad\r\nx-injected: 1")) == nil)
  assert(oauth.codex_account_id(codex_jwt("has space")) == nil)
end)

it("codex_credential_from_token requires the fields and the account id", function()
  local ok, err = pcall(oauth.codex_credential_from_token, { access_token = "plain", refresh_token = "r", expires_in = 10 })
  assert(not ok and tostring(err):find("account id", 1, true), tostring(err))
  ok, err = pcall(oauth.codex_credential_from_token, { access_token = codex_jwt("a"), refresh_token = "r" })
  assert(not ok and tostring(err):find("expires_in", 1, true), tostring(err))
  ok, err = pcall(oauth.codex_credential_from_token, { access_token = codex_jwt("a"), expires_in = 5 })
  assert(not ok and tostring(err):find("refresh_token", 1, true), tostring(err))
  local before = oauth.now_ms()
  local c = oauth.codex_credential_from_token({ access_token = codex_jwt("a"), refresh_token = "r", expires_in = 3600 })
  assert(c.account_id == "a" and c.refresh == "r")
  assert(c.expires <= before + 3600 * 1000 - oauth.EXPIRY_MARGIN_MS + 1000 and c.expires >= before + 3600 * 1000 - oauth.EXPIRY_MARGIN_MS)
end)

it("the Codex credential file is mode 600 and a malformed account id is refused", function()
  clear_all()
  registry.call("fn.openai_codex_credential", codex_fixture())
  local st = vim.uv.fs_stat(codex_path)
  assert(st.mode % 512 == 384, ("mode %o"):format(st.mode % 512))
  assert(registry.call("fn.openai_codex_credential").account_id == "acct-1")
  registry.call("fn.openai_codex_credential", codex_fixture({ account_id = "a b" }))
  local ok, err = pcall(registry.call, "fn.openai_codex_credential")
  assert(not ok and tostring(err):find("not a valid Codex login", 1, true), tostring(err))
  vim.fn.setfperm(codex_path, "rw-r--r--")
  ok, err = pcall(registry.call, "fn.openai_codex_credential")
  assert(not ok and tostring(err):find("chmod 600", 1, true), tostring(err))
  clear_all()
end)

it("the Codex authorize URL carries the Codex CLI parameters", function()
  clear_all()
  local url, q = codex_login_url()
  assert(vim.startswith(url, "https://auth.openai.com/oauth/authorize?"), url)
  assert(q.client_id == "app_EMoamEEZ73f0CkXaXp7hrann")
  assert(q.redirect_uri == "http://localhost:1455/auth/callback")
  assert(q.scope == "openid profile email offline_access")
  assert(q.response_type == "code" and q.code_challenge_method == "S256" and #q.code_challenge == 43)
  assert(q.id_token_add_organizations == "true" and q.codex_cli_simplified_flow == "true" and q.originator == "straps")
  assert(q.resource == nil and q.client_id ~= "dynamic_agent_client")
  assert(#q.state >= 43)
  clear_all()
end)

it("completing a Codex login exchanges the code (no resource), stores the account id, and refuses bad pastes", function()
  clear_all()
  unset("token_mode")
  local _, q = codex_login_url()
  for _, c in ipairs({
    { oauth.CODEX_REDIRECT_URI .. "?code=c&state=nope", "state mismatch" },
    { oauth.REDIRECT_URI .. "?code=c&state=" .. q.state, "must start with http://localhost:1455" },
  }) do
    local ok, err = pcall(registry.call, "fn.openai_codex_login", { callback_url = c[1] })
    assert(not ok and tostring(err):find(c[2], 1, true), c[2] .. " -> " .. tostring(err))
  end
  reset_log()
  local err = codex_complete(callback_for(q))
  assert(err == nil, tostring(err))
  local form = oauth.parse_query(last_stdin())
  assert(form.grant_type == "authorization_code" and form.code == "the-code")
  assert(form.client_id == oauth.CODEX_CLIENT_ID and form.redirect_uri == oauth.CODEX_REDIRECT_URI and form.code_verifier)
  assert(form.resource == nil, "the Codex exchange sends no resource")
  assert(last_argv_with("oauth/token"):find("https://auth.openai.com/oauth/token", 1, true))
  assert(not last_argv_with("oauth/token"):find("the-code", 1, true), "the code must not be on argv")
  local cred = registry.call("fn.openai_codex_credential")
  assert(cred and cred.account_id == "acct-1" and cred.refresh:match("^ref%-"), vim.inspect(cred))
  assert(oauth.pending_codex_login == nil)
  clear_all()
end)

it("a Codex token without an account id fails the login and saves nothing", function()
  clear_all()
  set("token_mode", "noacct")
  local _, q = codex_login_url()
  local err = codex_complete(callback_for(q))
  unset("token_mode")
  assert(err and tostring(err):find("account id", 1, true), tostring(err))
  assert(registry.call("fn.openai_codex_credential") == nil)
end)

it("one stored openai credential: a Codex login deletes the ChatGPT login and the key, and both replace it", function()
  clear_all()
  registry.call("fn.openai_oauth_credential", chatgpt_fixture())
  registry.call("fn.api_key_store", "openai", "sk-old")
  local _, q = codex_login_url()
  local err, note = codex_complete(callback_for(q))
  assert(err == nil, tostring(err))
  assert(registry.call("fn.openai_codex_credential") ~= nil)
  assert(registry.call("fn.openai_oauth_credential") == nil, "ChatGPT login must be deleted")
  assert(registry.call("fn.api_key_store", "openai") == nil, "stored key must be deleted")
  assert(note and note:find("signed out of the ChatGPT login", 1, true) and note:find("deleted ", 1, true), tostring(note))

  local purl = registry.call("fn.openai_oauth_login", { open = function() return true end })
  local pq = oauth.parse_query(purl:match("%?(.*)$"))
  local done, perr, pnote = false, nil, nil
  local real_post = registry.get("fn.openai_oauth_post")
  registry.define({ name = "fn.openai_oauth_post", kind = "fn", doc = "test", source = [[
return function(form, cb) vim.schedule(function() cb({ access_token = "acc-c", refresh_token = "ref-c", id_token = "i",
  expires_in = 3600, scope = "openid chatgpt.tokens.use.direct" }) end) end]] })
  registry.call("fn.openai_oauth_login", { callback_url = oauth.REDIRECT_URI .. "?code=c&client_id=cid&state=" .. pq.state,
    on_done = function(e, n) done, perr, pnote = true, e, n end })
  assert(vim.wait(20000, function() return done end, 10), "ChatGPT login never finished")
  registry.define({ name = real_post.name, kind = real_post.kind, doc = real_post.doc, source = real_post.source })
  assert(perr == nil, tostring(perr))
  assert(registry.call("fn.openai_oauth_credential") ~= nil)
  assert(registry.call("fn.openai_codex_credential") == nil, "the ChatGPT login must delete the Codex login")
  assert(pnote and pnote:find("signed out of the Codex login", 1, true), tostring(pnote))

  registry.call("fn.openai_codex_credential", codex_fixture())
  local orig_input = vim.fn.inputsecret
  vim.fn.inputsecret = function() return "sk-new" end
  local msgs = {}
  local orig = vim.notify
  vim.notify = function(m) msgs[#msgs + 1] = tostring(m) end
  require("straps.ui").login({ "openai", "key" })
  vim.wait(5000, function() return #msgs > 0 end, 10)
  vim.notify = orig
  vim.fn.inputsecret = orig_input
  assert(registry.call("fn.openai_codex_credential") == nil, "the key form must delete the Codex login")
  assert(registry.call("fn.openai_oauth_credential") == nil)
  assert(registry.call("fn.api_key_store", "openai") == "sk-new")
  assert(msgs[1] and msgs[1]:find("signed out of the Codex login", 1, true) and msgs[1]:find("signed out of ChatGPT", 1, true),
    vim.inspect(msgs))
  clear_all()
end)

it("a Codex login whose ChatGPT sign-out fails reports an error naming the remedy", function()
  clear_all()
  registry.call("fn.openai_oauth_credential", chatgpt_fixture())
  local _, q = codex_login_url()
  local real = registry.get("fn.openai_oauth_logout")
  registry.define({ name = real.name, kind = "fn", doc = "test",
    source = [[return function(cb) vim.schedule(function() cb("could not lock the ChatGPT login: busy") end) end]] })
  local err = codex_complete(callback_for(q))
  registry.define({ name = real.name, kind = real.kind, doc = real.doc, source = real.source })
  assert(err and tostring(err):find("still takes precedence", 1, true) and tostring(err):find("busy", 1, true), tostring(err))
  assert(registry.call("fn.openai_codex_credential") ~= nil, "the Codex login is saved")
  clear_all()
end)

it("a Codex callback with an error names Codex; an upper-case localhost URL routes to the Codex login", function()
  clear_all()
  local _, q = codex_login_url()
  local ok, err = pcall(registry.call, "fn.openai_codex_login",
    { callback_url = oauth.CODEX_REDIRECT_URI .. "?error=access_denied&state=" .. q.state })
  assert(not ok and tostring(err):find("Codex authorization failed: access_denied", 1, true), tostring(err))
  local msgs = {}
  local orig = vim.notify
  vim.notify = function(m) msgs[#msgs + 1] = tostring(m) end
  require("straps.ui").login({ "openai", "http://LOCALHOST:1455/auth/callback?code=c&state=" .. q.state })
  assert(vim.wait(20000, function() return registry.call("fn.openai_codex_credential") ~= nil end, 10), vim.inspect(msgs))
  vim.notify = orig
  assert(msgs[1]:find("exchanging the Codex authorization code", 1, true), vim.inspect(msgs))
  clear_all()
end)

it("the model picker merge keeps a live entry's reasoning flag and takes its reasoning levels", function()
  local merged = require("straps.ui")._merge_models({ { id = "gpt-live", label = "Mine", supported_reasoning_levels = { "none" } } },
    { { id = "gpt-live", label = "GPT Live", reasoning = true, supported_reasoning_levels = { "low", "high" } } })
  assert(merged[1].label == "Mine" and merged[1].reasoning == true, vim.inspect(merged))
  assert(vim.deep_equal(merged[1].supported_reasoning_levels, { "low", "high" }), vim.inspect(merged))
  merged = require("straps.ui")._merge_models({ { id = "gpt-live", supported_reasoning_levels = { "none" } } },
    { { id = "gpt-live", reasoning = true } })
  assert(vim.deep_equal(merged[1].supported_reasoning_levels, { "none" }), "a live entry without levels keeps the stored ones")
end)

it("health reports the Codex login, a model outside the Codex list, and a bad Codex file", function()
  clear_all()
  local rec = {}
  local orig = {}
  for _, k in ipairs({ "start", "ok", "warn", "error", "info" }) do
    orig[k] = vim.health[k]
    vim.health[k] = function(msg) rec[#rec + 1] = { k, tostring(msg) } end
  end
  local function run()
    rec = {}
    pcall(require("straps.health").check)
    return rec
  end
  local function find(kind, s)
    for _, r in ipairs(rec) do if r[1] == kind and r[2]:find(s, 1, true) then return r end end
  end
  registry.call("fn.openai_codex_credential", codex_fixture())
  straps.config.openai_model = "gpt-5"
  run()
  assert(find("ok", "Codex login: " .. codex_path), vim.inspect(rec))
  assert(find("warn", "not in the built-in Codex model list"), vim.inspect(rec))
  straps.config.openai_model = "gpt-5.6-sol"
  run()
  assert(not find("warn", "not in the built-in Codex model list"), vim.inspect(rec))
  registry.call("fn.openai_codex_credential", codex_fixture({ account_id = "a b" }))
  run()
  assert(find("error", "not a valid Codex login"), vim.inspect(rec))
  straps.config.openai_model = nil
  for k, f in pairs(orig) do vim.health[k] = f end
  clear_all()
end)

it("a ChatGPT refresh in flight while a Codex login completes does not write the ChatGPT login back", function()
  clear_all()
  registry.call("fn.openai_oauth_credential", vim.tbl_extend("force", chatgpt_fixture(), { expires = 0 }))
  local _, q = codex_login_url()
  local real_post = registry.get("fn.openai_oauth_post")
  registry.define({ name = "fn.openai_oauth_post", kind = "fn", doc = "test", source = [[
return function(form, cb, opts)
  if opts and opts.token_url then
    return require("straps.registry").call("fn.test_real_post", form, cb, opts)
  end
  vim.defer_fn(function() cb({ access_token = "acc-new", refresh_token = "ref-new", expires_in = 3600,
    scope = "openid chatgpt.tokens.use.direct" }) end, 600)
end]] })
  registry.define({ name = "fn.test_real_post", kind = "fn", doc = "test", source = real_post.source })
  local rdone, rcred, rerr = false, nil, nil
  registry.call("fn.openai_oauth_refresh", {}, function(c, e) rdone, rcred, rerr = true, c, e end)
  vim.wait(100, function() return false end, 10)
  local err = codex_complete(callback_for(q))
  assert(vim.wait(20000, function() return rdone end, 10), "refresh never finished")
  registry.define({ name = real_post.name, kind = real_post.kind, doc = real_post.doc, source = real_post.source })
  assert(err == nil, tostring(err))
  assert(registry.call("fn.openai_codex_credential") ~= nil, "the Codex login must be saved")
  assert(registry.call("fn.openai_oauth_credential") == nil, "the ChatGPT login must stay deleted")
  assert(rcred ~= nil or rerr ~= nil)
  clear_all()
end)

it("starting one login cancels the other pending login", function()
  clear_all()
  codex_login_url()
  assert(oauth.pending_codex_login ~= nil)
  registry.call("fn.openai_oauth_login", { open = function() return true end })
  assert(oauth.pending_codex_login == nil and oauth.pending_login ~= nil)
  codex_login_url()
  assert(oauth.pending_login == nil and oauth.pending_codex_login ~= nil)
  clear_all()
end)

it(":StrapsLogin openai <url> routes by origin, and :StrapsLogin openai codex starts the Codex login", function()
  clear_all()
  local ui = require("straps.ui")
  local orig_open = vim.ui.open
  vim.ui.open = function() return nil, "no browser" end
  local msgs = {}
  local orig = vim.notify
  vim.notify = function(m, lvl) msgs[#msgs + 1] = { msg = tostring(m), level = lvl } end
  ui.login({ "openai", "codex" })
  local rec = oauth.pending_codex_login
  assert(rec and msgs[1] and msgs[1].msg:find(oauth.CODEX_AUTHORIZE_URL, 1, true)
    and msgs[1].msg:find("http://localhost:1455", 1, true) and msgs[1].msg:find("Codex CLI", 1, true), vim.inspect(msgs))
  ui.login({ "openai", oauth.CODEX_REDIRECT_URI .. "?code=c&state=" .. rec.state })
  assert(vim.wait(20000, function() return registry.call("fn.openai_codex_credential") ~= nil end, 10), vim.inspect(msgs))
  assert(msgs[2].msg:find("exchanging the Codex authorization code", 1, true), vim.inspect(msgs))
  msgs = {}
  ui.login({ "openai", oauth.REDIRECT_URI .. "?code=c&client_id=x&state=s" })
  vim.notify = orig
  vim.ui.open = orig_open
  assert(msgs[1] and msgs[1].msg:find("no pending ChatGPT login", 1, true), vim.inspect(msgs))
  clear_all()
end)

it("a Codex login is refused with a custom openai_base_url, at start, completion and key read", function()
  clear_all()
  straps.config.openai_base_url = "https://router.example/v1"
  local ok, err = pcall(registry.call, "fn.openai_codex_login", { open = function() end })
  assert(not ok and tostring(err):find("only works when openai_base_url", 1, true), tostring(err))
  straps.config.openai_base_url = nil
  local _, q = codex_login_url()
  straps.config.openai_base_url = "https://router.example"
  err = codex_complete(callback_for(q))
  assert(err and tostring(err):find("was not saved", 1, true), tostring(err))
  assert(registry.call("fn.openai_codex_credential") == nil)
  registry.call("fn.openai_codex_credential", codex_fixture())
  for _, base in ipairs({ "https://router.example", "https://chatgpt.com.evil.test/backend-api", "http://api.openai.com" }) do
    straps.config.openai_base_url = base
    ok, err = pcall(registry.call, "fn.openai_api_key", {})
    assert(not ok and tostring(err):find("Codex login is only used", 1, true), base .. ": " .. tostring(err))
  end
  straps.config.openai_base_url = "https://router.example"
  reset_log()
  local models, merr = registry.call("fn.list_models", "openai")
  assert(models == nil and tostring(merr):find("Codex login is only used", 1, true), tostring(merr))
  assert(count("router.example") == 0 and count("chatgpt.com") == 0, "no request may go out")
  straps.config.openai_base_url = nil
  clear_all()
end)

it("fn.openai_api_key returns the Codex login after the ChatGPT login and before the key", function()
  clear_all()
  registry.call("fn.api_key_store", "openai", "sk-file")
  registry.call("fn.openai_codex_credential", codex_fixture())
  local key, source, account = registry.call("fn.openai_api_key", {})
  assert(source == "codex" and account == "acct-1" and key == codex_fixture().access, tostring(source))
  registry.call("fn.openai_oauth_credential", chatgpt_fixture())
  key, source = registry.call("fn.openai_api_key", {})
  assert(source == "oauth" and key == "acc-chatgpt", tostring(source))
  clear_all()
end)

it("a Codex refresh sends client_id and refresh_token only, and a changed account id replaces the old one", function()
  clear_all()
  registry.call("fn.openai_codex_credential", codex_fixture({ expires = 0 }))
  vim.fn.writefile(vim.fn.readfile(tmp .. "/access2"), tmp .. "/access_next")
  reset_log()
  local key, source, account = registry.call("fn.openai_api_key", { wait_ms = 20000 })
  unset("access_next")
  local form = oauth.parse_query(last_stdin())
  assert(form.grant_type == "refresh_token" and form.refresh_token == "ref-stored" and form.client_id == oauth.CODEX_CLIENT_ID)
  assert(form.resource == nil)
  assert(source == "codex" and account == "acct-2", tostring(account))
  assert(registry.call("fn.openai_codex_credential").account_id == "acct-2")
  assert(key == vim.fn.readfile(tmp .. "/access2")[1])
  clear_all()
end)

it("a Codex request goes to chatgpt.com with the Codex headers and body", function()
  clear_all()
  unset("resp_mode")
  registry.call("fn.openai_codex_credential", codex_fixture())
  reset_log()
  local entry = { id = "gpt-5.6-sol", reasoning = true }
  local res, err = provider_call({ model = "gpt-5.6-sol", model_entry = entry })
  assert(res and res.content[1] and res.content[1].text == "codex-ok", tostring(err) .. vim.inspect(res))
  local a = last_argv_with("responses")
  assert(a:find("https://chatgpt.com/backend-api/codex/responses", 1, true), a)
  assert(not a:find("api.openai.com", 1, true), a)
  for _, h in ipairs({ "Authorization: Bearer " .. codex_fixture().access, "chatgpt-account-id: acct-1",
    "OpenAI-Beta: responses=experimental", "originator: straps", "accept: text/event-stream", "session-id: ",
    "x-client-request-id: " }) do
    assert(a:find(h, 1, true), h .. " missing from " .. a)
  end
  local body = last_request()
  assert(body.max_output_tokens == nil, "no max_output_tokens")
  assert(body.instructions == "sys" and body.store == false and body.stream == true)
  assert(body.text and body.text.verbosity == "low")
  assert(body.include and body.include[1] == "reasoning.encrypted_content")
  assert(body.tool_choice == "auto" and body.parallel_tool_calls == true)
  assert(type(body.prompt_cache_key) == "string" and a:find("session-id: " .. body.prompt_cache_key, 1, true))
  assert(a:find("x-client-request-id: " .. body.prompt_cache_key, 1, true), a)
  assert(body.reasoning and body.reasoning.effort == "low" and body.reasoning.summary == nil, vim.inspect(body.reasoning))
  clear_all()
end)

it("Codex reasoning: a level with summary when effort applies; omitted for a non-reasoning entry; instructions fallback", function()
  clear_all()
  registry.call("fn.openai_codex_credential", codex_fixture())
  local prev = straps.config.effort
  straps.config.effort = "high"
  provider_call({ model = "gpt-5.6-sol", model_entry = { id = "gpt-5.6-sol", reasoning = true } })
  local body = last_request()
  local hi = straps.config.efforts and vim.tbl_filter(function(e) return e.name == "high" end, straps.config.efforts)[1]
  assert(body.reasoning and body.reasoning.effort == (hi and hi.level) and body.reasoning.summary == "auto", vim.inspect(body.reasoning))
  straps.config.effort = prev
  provider_call({ model = "plain", model_entry = { id = "plain" }, system = "" })
  body = last_request()
  assert(body.reasoning == nil, vim.inspect(body.reasoning))
  assert(body.instructions == "You are a helpful assistant.", tostring(body.instructions))
  clear_all()
end)

it("Codex effort off sends the entry's lowest reasoning level, or none only when listed, or no reasoning when no levels are known", function()
  clear_all()
  registry.call("fn.openai_codex_credential", codex_fixture())
  local prev = straps.config.effort
  straps.config.effort = "off"
  local cases = {
    { { id = "x", reasoning = true, supported_reasoning_levels = { "medium", "low", "high" } }, "low" },
    { { id = "x", reasoning = true, supported_reasoning_levels = { "ultra", "max", "xhigh" } }, "xhigh" },
    { { id = "x", reasoning = true, supported_reasoning_levels = { "low", "none" } }, "none" },
    { { id = "x", reasoning = true, supported_reasoning_levels = { { effort = "high" }, { effort = "medium" } } }, "medium" },
    { { id = "x", reasoning = true, supported_reasoning_levels = { "turbo", "slow" } }, "turbo" },
    { { id = "gpt-6.1-sol", reasoning = true }, "low" },
    { { id = "gpt-6.1-sol", reasoning = true, supported_reasoning_levels = {} }, "low" },
    { { id = "gpt-unknown", reasoning = true }, nil },
    { { id = "gpt-unknown", reasoning = true, supported_reasoning_levels = { { description = "no effort" } } }, nil },
  }
  for i, c in ipairs(cases) do
    provider_call({ model = c[1].id, model_entry = c[1] })
    local body = last_request()
    if c[2] then
      assert(body.reasoning and body.reasoning.effort == c[2] and body.reasoning.summary == nil,
        "case " .. i .. ": " .. vim.inspect(body.reasoning))
    else
      assert(body.reasoning == nil, "case " .. i .. ": " .. vim.inspect(body.reasoning))
    end
  end
  straps.config.effort = prev
  clear_all()
end)

it("Codex sends the entry's lowest level when the effort's level is not in the entry's list", function()
  clear_all()
  registry.call("fn.openai_codex_credential", codex_fixture())
  local prev = straps.config.effort
  straps.config.effort = "high"
  provider_call({ model = "x", model_entry = { id = "x", reasoning = true, supported_reasoning_levels = { "medium", "low" } } })
  local body = last_request()
  assert(body.reasoning and body.reasoning.effort == "low" and body.reasoning.summary == nil, vim.inspect(body.reasoning))
  straps.config.effort = prev
  clear_all()
end)

it("an API-key request is unchanged: /v1/responses on api.openai.com with max_output_tokens and no Codex headers", function()
  clear_all()
  registry.call("fn.api_key_store", "openai", "sk-file")
  provider_call({ model = "gpt-5" })
  local a = last_argv_with("responses")
  assert(a:find("https://api.openai.com/v1/responses", 1, true), a)
  for _, h in ipairs({ "chatgpt-account-id", "originator:", "OpenAI-Beta:", "session-id:", "x-client-request-id:" }) do
    assert(not a:find(h, 1, true), h .. " must not be sent: " .. a)
  end
  local body = last_request()
  assert(body.max_output_tokens and body.text == nil and body.prompt_cache_key == nil)
  assert(body.include == nil and body.tool_choice == nil and body.parallel_tool_calls == nil and body.reasoning == nil)
  clear_all()
end)

it("response.done: completed, missing status, incomplete and failed", function()
  clear_all()
  registry.call("fn.openai_codex_credential", codex_fixture())
  set("resp_mode", "done_completed")
  local res = provider_call({ model = "m" })
  assert(res and res.stop_reason == "end_turn" and res.content[1].text == "hi", vim.inspect(res))
  assert(res.usage.input_tokens == 3, "the first terminal event wins: " .. vim.inspect(res.usage))
  assert(#res.content == 1, "a second terminal event must not append to the content: " .. vim.inspect(res.content))
  set("resp_mode", "done_nostatus")
  res = provider_call({ model = "m" })
  assert(res and res.stop_reason == "end_turn" and res.content[1].text == "hi", vim.inspect(res))
  set("resp_mode", "done_incomplete")
  res = provider_call({ model = "m" })
  assert(res and res.stop_reason == "max_tokens" and #res.content == 0, vim.inspect(res))
  set("resp_mode", "done_failed")
  local _, err = provider_call({ model = "m" })
  assert(err and tostring(err):find("it broke", 1, true) and tostring(err):find("openai (codex)", 1, true), tostring(err))
  unset("resp_mode")
  clear_all()
end)

it("a usage-limit 429 is not retried and names the plan and the reset time", function()
  clear_all()
  registry.call("fn.openai_codex_credential", codex_fixture())
  set("resp_mode", "usage")
  set("resets_at", math.floor(oauth.now_ms() / 1000) + 600)
  reset_log()
  local _, err = provider_call({ model = "m" })
  unset("resp_mode")
  assert(count("codex/responses") == 1, "made " .. count("codex/responses") .. " requests")
  assert(tostring(err):find("usage limit (plus plan)", 1, true) and tostring(err):find("~10 min", 1, true), tostring(err))
  clear_all()
end)

it("usage_not_included in error.type is not retried and uses the usage-limit wording", function()
  clear_all()
  registry.call("fn.openai_codex_credential", codex_fixture())
  set("resp_mode", "notincluded")
  reset_log()
  local _, err = provider_call({ model = "m" })
  unset("resp_mode")
  assert(count("codex/responses") == 1, "made " .. count("codex/responses") .. " requests")
  assert(tostring(err):find("usage limit", 1, true) and tostring(err):find("HTTP 403", 1, true), tostring(err))
  clear_all()
end)

it("events after the first terminal event change neither the text nor the usage", function()
  clear_all()
  registry.call("fn.openai_codex_credential", codex_fixture())
  set("resp_mode", "after_terminal")
  local res, _, emitted = provider_call({ model = "m" })
  unset("resp_mode")
  assert(res and res.content[1].text == "hi", vim.inspect(res))
  assert(res.usage.input_tokens == 3 and res.usage.output_tokens == 2, vim.inspect(res.usage))
  for _, e in ipairs(emitted) do
    assert(not tostring(e.text):find("LATE", 1, true), "a delta after the terminal event reached ctx.emit")
  end
  clear_all()
end)

it("a transient Codex 429 is retried, and the final error uses the usage-limit wording", function()
  clear_all()
  registry.call("fn.openai_codex_credential", codex_fixture())
  set("resp_mode", "ratelimit")
  reset_log()
  local _, err = provider_call({ model = "m" })
  unset("resp_mode")
  assert(count("codex/responses") == 3, "made " .. count("codex/responses") .. " requests")
  assert(tostring(err):find("usage limit", 1, true) and tostring(err):find("HTTP 429", 1, true), tostring(err))
  clear_all()
end)

it("a Codex 401 refreshes once and retries with the new token and account id", function()
  clear_all()
  unset("resp_mode")
  registry.call("fn.openai_codex_credential", codex_fixture({ access = "stale-access" }))
  vim.fn.writefile(vim.fn.readfile(tmp .. "/access2"), tmp .. "/access_next")
  reset_log()
  local res, err = provider_call({ model = "m" })
  unset("access_next")
  assert(res and res.content[1].text == "codex-ok", tostring(err))
  assert(count("codex/responses") == 2 and count("oauth/token") == 1)
  local a = last_argv_with("codex/responses")
  assert(a:find("chatgpt-account-id: acct-2", 1, true) and a:find("Bearer " .. vim.fn.readfile(tmp .. "/access2")[1], 1, true), a)
  clear_all()
end)

it("fn.list_models with a Codex login reads the Codex catalog and falls back to the built-in list", function()
  clear_all()
  registry.call("fn.openai_codex_credential", codex_fixture())
  unset("models_mode")
  reset_log()
  local models = registry.call("fn.list_models", "openai")
  local a = last_argv_with("codex/models")
  assert(oauth.CODEX_CLIENT_VERSION == "0.159.0", oauth.CODEX_CLIENT_VERSION)
  assert(a and a:find(oauth.CODEX_BASE_URL .. "/codex/models?client_version=" .. oauth.CODEX_CLIENT_VERSION .. " ", 1, true)
    and a:find("chatgpt-account-id: acct-1", 1, true) and a:find("originator: straps", 1, true), tostring(a))
  assert(#models == 2 and models[1].id == "gpt-live" and models[1].reasoning == true and models[1].context == 123,
    vim.inspect(models))
  assert(vim.deep_equal(models[1].supported_reasoning_levels, { "medium", "low" }), vim.inspect(models[1]))
  assert(models[2].id == "gpt-junk" and models[2].supported_reasoning_levels == nil, vim.inspect(models[2]))
  set("models_mode", "fail")
  local msgs = {}
  local orig = vim.notify
  vim.notify = function(m) msgs[#msgs + 1] = tostring(m) end
  models = registry.call("fn.list_models", "openai")
  vim.notify = orig
  unset("models_mode")
  assert(#models == #oauth.CODEX_MODELS and models[1].id == oauth.CODEX_MODELS[1].id and models[1].reasoning == true,
    vim.inspect(models))
  for _, m in ipairs(models) do
    assert(type(m.supported_reasoning_levels) == "table" and #m.supported_reasoning_levels > 0
      and not vim.tbl_contains(m.supported_reasoning_levels, "none"), vim.inspect(m))
  end
  assert(msgs[1] and msgs[1]:find("HTTP 500", 1, true), vim.inspect(msgs))
  set("models_mode", "empty")
  vim.notify = function() end
  models = registry.call("fn.list_models", "openai")
  vim.notify = orig
  unset("models_mode")
  assert(#models == #oauth.CODEX_MODELS, "a catalog with no visible models falls back: " .. vim.inspect(models))
  clear_all()
end)

it("the Codex session id is per buffer, clamped, written to .meta and restored on resume", function()
  clear_all()
  local path = vim.fn.tempname() .. ".straps"
  vim.fn.writefile({}, path)
  local buf = state.open_session_file(path)
  local id = state.codex_session_id(buf)
  assert(id:match("^%x+%-%x+%-4%x%x%x%-[89ab]%x%x%x%-%x+$"), id)
  assert(state.codex_session_id(buf) == id)
  local meta = vim.json.decode(table.concat(vim.fn.readfile(path .. ".meta"), "\n"))
  assert(meta.codex_session_id == id, vim.inspect(meta))
  vim.api.nvim_buf_delete(buf, { force = true })
  local buf2 = state.open_session_file(path)
  assert(vim.b[buf2].straps_codex_session_id == nil, "the id must come from .meta, not a surviving buffer variable")
  assert(state.codex_session_id(buf2) == id, "a resumed session keeps its id")
  local other = vim.api.nvim_create_buf(false, true)
  assert(state.codex_session_id(other) ~= id, "another buffer gets its own id")
  vim.b[other].straps_codex_session_id = string.rep("a", 100)
  assert(#state.codex_session_id(other) == 64)
end)

it("completion offers codex and key after openai", function()
  vim.g.loaded_straps = nil
  vim.cmd.source(root .. "/plugin/straps.lua")
  assert(vim.deep_equal(vim.fn.getcompletion("StrapsLogin openai ", "cmdline"), { "codex", "key" }))
  assert(vim.deep_equal(vim.fn.getcompletion("StrapsLogin anthropic ", "cmdline"), { "key" }))
end)

it(":StrapsLogout openai deletes the Codex login and cancels a pending one", function()
  clear_all()
  registry.call("fn.openai_codex_credential", codex_fixture())
  local msgs = {}
  local orig = vim.notify
  vim.notify = function(m) msgs[#msgs + 1] = tostring(m) end
  require("straps.ui").logout({ "openai" })
  vim.wait(5000, function() return #msgs > 0 end, 10)
  codex_login_url()
  require("straps.ui").logout({ "openai" })
  vim.wait(5000, function() return #msgs > 1 end, 10)
  vim.notify = orig
  assert(registry.call("fn.openai_codex_credential") == nil)
  assert(msgs[1] == "straps: signed out of the Codex login", vim.inspect(msgs))
  assert(msgs[2] == "straps: pending Codex login cancelled" and oauth.pending_codex_login == nil, vim.inspect(msgs))
end)
