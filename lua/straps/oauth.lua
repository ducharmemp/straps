local M = {}

M.AUTHORIZE_URL = "https://auth.openai.com/api/accounts/authorize"
M.TOKEN_URL = "https://auth.openai.com/api/accounts/oauth/token"
M.RESOURCE = "https://api.openai.com/v1"
M.API_ORIGIN = "https://api.openai.com"
M.REDIRECT_ORIGIN = "http://127.0.0.1:1455"
M.LOGIN_FILE = "openai_oauth.json"
M.REDIRECT_PATH = "/auth/callback"
M.REDIRECT_URI = M.REDIRECT_ORIGIN .. M.REDIRECT_PATH
M.DYNAMIC_CLIENT_ID = "dynamic_agent_client"
M.AGENT_NAME_HINT = "straps"
M.DIRECT_TOKEN_SCOPE = "chatgpt.tokens.use.direct"
M.SCOPE = "openid profile email offline_access resource.invoke " .. M.DIRECT_TOKEN_SCOPE
M.EXPIRY_MARGIN_MS = 3 * 60 * 1000
M.REFRESH_WINDOW_MS = 5 * 60 * 1000
M.LOGIN_TTL_MS = 15 * 60 * 1000
M.LOCK_STALE_MS = 20 * 1000
M.LOCK_DEADLINE_MS = 30 * 1000

M.CODEX_AUTHORIZE_URL = "https://auth.openai.com/oauth/authorize"
M.CODEX_TOKEN_URL = "https://auth.openai.com/oauth/token"
M.CODEX_CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"
M.CODEX_REDIRECT_ORIGIN = "http://localhost:1455"
M.CODEX_REDIRECT_URI = M.CODEX_REDIRECT_ORIGIN .. M.REDIRECT_PATH
M.CODEX_SCOPE = "openid profile email offline_access"
M.CODEX_LOGIN_FILE = "openai_codex.json"
M.CODEX_BASE_URL = "https://chatgpt.com/backend-api"
M.CODEX_ORIGINATOR = "straps"
M.CODEX_CLIENT_VERSION = "0.99.0"
M.JWT_AUTH_CLAIM = "https://api.openai.com/auth"
M.CODEX_MODELS = {
  { id = "gpt-6.1-sol", label = "GPT-6.1 Sol", context = 500000, reasoning = true },
  { id = "gpt-6.1-terra", label = "GPT-6.1 Terra", context = 500000, reasoning = true },
  { id = "gpt-6-astra", label = "GPT-6 Astra", context = 272000, reasoning = true },
  { id = "gpt-6-sol", label = "GPT-6 Sol", context = 272000, reasoning = true },
  { id = "gpt-6-luna", label = "GPT-6 Luna", context = 272000, reasoning = true },
  { id = "gpt-5.6-luna", label = "GPT-5.6 Luna", context = 272000, reasoning = true },
  { id = "gpt-5.6-sol", label = "GPT-5.6 Sol", context = 272000, reasoning = true },
  { id = "gpt-5.6-terra", label = "GPT-5.6 Terra", context = 272000, reasoning = true },
}

M.pending_login = nil
M.pending_codex_login = nil

function M.now_ms()
  local sec, usec = vim.uv.gettimeofday()
  return sec * 1000 + math.floor(usec / 1000)
end

-- The XDG spec says to ignore a relative $XDG_CONFIG_HOME; a relative
-- $HOME is ignored too, so the store never lands in the working directory.
local function absolute(path)
  return path and path ~= "" and vim.startswith(path, "/") and path or nil
end

function M.config_dir()
  local config_home = absolute(vim.env.XDG_CONFIG_HOME)
  if not config_home then
    local home = absolute(vim.env.HOME)
    config_home = home and (home .. "/.config")
  end
  return config_home and (config_home .. "/straps") or nil
end

function M.ensure_dir(dir)
  local st = vim.uv.fs_stat(dir)
  if st then
    if st.mode % 64 ~= 0 then vim.uv.fs_chmod(dir, 448) end
    return
  end
  local parent = vim.fs.dirname(dir)
  if parent and parent ~= dir and not vim.uv.fs_stat(parent) then
    vim.fn.mkdir(parent, "p")
  end
  vim.uv.fs_mkdir(dir, 448)
end

function M.b64url(raw)
  return (vim.base64.encode(raw):gsub("%+", "-"):gsub("/", "_"):gsub("=", ""))
end

function M.random_b64url(n)
  return M.b64url(vim.uv.random(n))
end

function M.challenge(verifier)
  local raw = vim.fn.sha256(verifier):gsub("%x%x", function(h) return string.char(tonumber(h, 16)) end)
  return M.b64url(raw)
end

function M.pkce()
  local verifier = M.random_b64url(32)
  return verifier, M.challenge(verifier)
end

local function encode_component(s)
  return (tostring(s):gsub("[^A-Za-z0-9%-%._~]", function(c) return ("%%%02X"):format(c:byte()) end))
end

function M.form_encode(pairs_list)
  local parts = {}
  for _, kv in ipairs(pairs_list) do
    parts[#parts + 1] = encode_component(kv[1]) .. "=" .. encode_component(kv[2])
  end
  return table.concat(parts, "&")
end

function M.url_decode(s)
  return (s:gsub("+", " "):gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

function M.parse_query(query)
  local out = {}
  for part in query:gmatch("[^&]+") do
    local k, v = part:match("^([^=]*)=?(.*)$")
    if k and k ~= "" then
      k = M.url_decode(k)
      if out[k] == nil then out[k] = M.url_decode(v) end
    end
  end
  return out
end

function M.callback_origin(url)
  local origin = vim.trim(url or ""):match("^(https?://[^/?#]+)")
  return origin and origin:lower()
end

function M.parse_callback(url, expected_state, opts)
  opts = opts or {}
  local want_origin = opts.origin or M.REDIRECT_ORIGIN
  local cmd = opts.cmd or ":StrapsLogin openai"
  url = vim.trim(url or "")
  local origin, path = url:match("^(https?://[^/?#]+)(/[^?#]*)")
  if not origin then
    error("straps: paste the full callback URL from the browser's address bar", 0)
  end
  if origin:lower() ~= want_origin or path ~= M.REDIRECT_PATH then
    error("straps: the pasted URL must start with " .. want_origin .. M.REDIRECT_PATH, 0)
  end
  local params = M.parse_query(url:match("%?([^#]*)") or "")
  if params.error and params.error ~= "" then
    error("straps: " .. (opts.label or "ChatGPT") .. " authorization failed: " .. params.error, 0)
  end
  if not params.code or params.code == "" then error("straps: the pasted URL has no authorization code", 0) end
  if not params.state or params.state == "" then error("straps: the pasted URL has no OAuth state", 0) end
  if params.state ~= expected_state then
    error("straps: OAuth state mismatch; paste the URL from the most recent " .. cmd, 0)
  end
  if opts.require_client_id == false then return { code = params.code } end
  local client_id = vim.trim(params.client_id or "")
  if client_id == "" then error("straps: the pasted URL has no issued client_id", 0) end
  return { code = params.code, client_id = client_id }
end

function M.jwt_payload(token)
  if type(token) ~= "string" then return nil end
  local part = token:match("^[^.]+%.([^.]+)%.[^.]*$")
  if not part then return nil end
  local b64 = part:gsub("%-", "+"):gsub("_", "/")
  local rem = #b64 % 4
  if rem == 1 then return nil end
  if rem > 0 then b64 = b64 .. string.rep("=", 4 - rem) end
  local ok, raw = pcall(vim.base64.decode, b64)
  if not ok then return nil end
  local okj, payload = pcall(vim.json.decode, raw)
  if not okj or type(payload) ~= "table" then return nil end
  return payload
end

function M.codex_account_id(access)
  local payload = M.jwt_payload(access)
  local auth = payload and payload[M.JWT_AUTH_CLAIM]
  local id = type(auth) == "table" and auth.chatgpt_account_id or nil
  if type(id) ~= "string" or id == "" or id:find("[%s%c\128-\255]") then return nil end
  return id
end

function M.codex_credential_from_token(token)
  if type(token) ~= "table" then error("straps: Codex OAuth token response is not an object", 0) end
  for _, field in ipairs({ "access_token", "refresh_token" }) do
    if type(token[field]) ~= "string" or vim.trim(token[field]) == "" then
      error("straps: Codex OAuth token response has invalid " .. field, 0)
    end
  end
  if type(token.expires_in) ~= "number" or token.expires_in <= 0 then
    error("straps: Codex OAuth token response has invalid expires_in", 0)
  end
  local account_id = M.codex_account_id(token.access_token)
  if not account_id then
    error("straps: the Codex access token has no usable ChatGPT account id", 0)
  end
  return {
    access = token.access_token,
    refresh = token.refresh_token,
    expires = M.now_ms() + token.expires_in * 1000 - M.EXPIRY_MARGIN_MS,
    account_id = account_id,
  }
end

function M.uuid4()
  local bit = require("bit")
  local b = { vim.uv.random(16):byte(1, 16) }
  b[7] = bit.bor(bit.band(b[7], 0x0f), 0x40)
  b[9] = bit.bor(bit.band(b[9], 0x3f), 0x80)
  local hex = {}
  for i = 1, 16 do hex[i] = ("%02x"):format(b[i]) end
  local h = table.concat(hex)
  return h:sub(1, 8) .. "-" .. h:sub(9, 12) .. "-" .. h:sub(13, 16) .. "-" .. h:sub(17, 20) .. "-" .. h:sub(21, 32)
end

function M.credential_from_token(token, client_id, require_id_token)
  local function need_string(field)
    local v = token[field]
    if type(v) ~= "string" or vim.trim(v) == "" then
      error("straps: OpenAI OAuth token response has invalid " .. field, 0)
    end
    return v
  end
  if type(token) ~= "table" then error("straps: OpenAI OAuth token response is not an object", 0) end
  local access = need_string("access_token")
  local refresh = need_string("refresh_token")
  local scope = need_string("scope")
  if require_id_token then need_string("id_token") end
  if type(token.expires_in) ~= "number" or token.expires_in <= 0 then
    error("straps: OpenAI OAuth token response has invalid expires_in", 0)
  end
  local scopes = vim.split(vim.trim(scope), "%s+")
  if not vim.tbl_contains(scopes, M.DIRECT_TOKEN_SCOPE) then
    error("straps: OpenAI OAuth grant did not include " .. M.DIRECT_TOKEN_SCOPE, 0)
  end
  return {
    access = access,
    refresh = refresh,
    expires = M.now_ms() + token.expires_in * 1000 - M.EXPIRY_MARGIN_MS,
    client_id = client_id,
    scopes = scopes,
  }
end

return M
