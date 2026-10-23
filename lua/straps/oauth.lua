local M = {}

M.AUTHORIZE_URL = "https://auth.openai.com/api/accounts/authorize"
M.TOKEN_URL = "https://auth.openai.com/api/accounts/oauth/token"
M.RESOURCE = "https://api.openai.com/v1"
M.API_ORIGIN = "https://api.openai.com"
M.REDIRECT_ORIGIN = "http://127.0.0.1:1455"
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

M.pending_login = nil

function M.now_ms()
  local sec, usec = vim.uv.gettimeofday()
  return sec * 1000 + math.floor(usec / 1000)
end

function M.config_dir()
  local config_home = vim.env.XDG_CONFIG_HOME
  if not config_home or config_home == "" then
    local home = vim.env.HOME
    config_home = (home and home ~= "") and (home .. "/.config") or nil
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

function M.parse_callback(url, expected_state)
  url = vim.trim(url or "")
  local origin, path = url:match("^(https?://[^/?#]+)(/[^?#]*)")
  if not origin then
    error("straps: paste the full callback URL from the browser's address bar", 0)
  end
  if origin ~= M.REDIRECT_ORIGIN or path ~= M.REDIRECT_PATH then
    error("straps: the pasted URL must start with " .. M.REDIRECT_URI, 0)
  end
  local params = M.parse_query(url:match("%?([^#]*)") or "")
  if params.error and params.error ~= "" then
    error("straps: ChatGPT authorization failed: " .. params.error, 0)
  end
  if not params.code or params.code == "" then error("straps: the pasted URL has no authorization code", 0) end
  if not params.state or params.state == "" then error("straps: the pasted URL has no OAuth state", 0) end
  if params.state ~= expected_state then
    error("straps: OAuth state mismatch; paste the URL from the most recent :StrapsLogin openai", 0)
  end
  local client_id = vim.trim(params.client_id or "")
  if client_id == "" then error("straps: the pasted URL has no issued client_id", 0) end
  return { code = params.code, client_id = client_id }
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
