local M = {}
local uv = vim.uv
local providers = require("straps.provider")
local oauth = require("straps.oauth")
local registry = require("straps.registry")
local encode, decode, deepcopy = vim.json.encode, vim.json.decode, vim.deepcopy
local resolve_provider, resolve_model, base_url = providers.resolve_provider, providers.resolve_model, providers.base_url
local config_dir, clean_key = oauth.config_dir, providers.clean_key
local system, sha256 = vim.system, vim.fn.sha256

local function integer(n, maximum)
  return type(n) == "number" and n >= 1 and n <= maximum and n == math.floor(n)
end

local function read(path, maximum, private)
  local before = uv.fs_stat(path)
  if not before or before.type ~= "file" or before.size > maximum or (private and before.mode % 64 ~= 0) then return nil end
  local fd = uv.fs_open(path, "r", 0)
  if not fd then return nil end
  local value = uv.fs_read(fd, maximum + 1, 0)
  uv.fs_close(fd)
  local after = uv.fs_stat(path)
  if not value or #value > maximum or not after or before.ino ~= after.ino or before.dev ~= after.dev
    or before.size ~= after.size or before.mode ~= after.mode or (private and after.mode % 64 ~= 0) or not vim.deep_equal(before.mtime, after.mtime)
    or not vim.deep_equal(before.ctime, after.ctime) then return nil end
  return value
end

local function fingerprint(path, maximum)
  local content = read(path, maximum, false)
  return content and sha256(content)
end

local function approved(fn)
  local thread = coroutine.create(fn)
  local ok, value = coroutine.resume(thread)
  return ok and coroutine.status(thread) == "dead" and value == true
end

local function new(config)
  if type(config) ~= "table" or type(config.provider_config) ~= "table"
    or type(config.disclosure_revision) ~= "string" or not config.disclosure_revision:find("%S")
    or type(config.disclosure_approved) ~= "function" or not approved(config.disclosure_approved)
    or not integer(config.max_output_tokens, 65536) or not integer(config.max_response_bytes, 4194304)
    or not integer(config.timeout_ms, 300000) then return nil, "approved bounded configuration required" end
  local held = deepcopy(config)
  local selection = deepcopy(config.provider_config)
  local provider = resolve_provider(held.session, selection)
  if provider ~= "openai" then return nil, "configured provider unsupported: " .. tostring(provider) end
  local model = resolve_model(provider, held.session, selection)
  if type(model) ~= "string" or not model:find("%S") then return nil, "configured model unavailable" end
  local endpoint = base_url(provider, selection)
  if endpoint ~= "https://api.openai.com" then return nil, "configured endpoint unsupported" end
  local sources, definitions = providers.contextual_auth_sources, {}
  if type(sources) ~= "table" then return nil, "default authentication unavailable" end
  for name, source in pairs(sources) do
    local entry = registry.get(name)
    if not entry or entry.source ~= source then return nil, "custom authentication unsupported" end
    definitions[name] = entry
  end
  local backend = registry.get("fn.provider_openai")
  local dispatcher = registry.get("fn.provider")
  if not backend or not dispatcher or not providers.context_sources
    or backend.source ~= providers.context_sources["fn.provider_openai"]
    or dispatcher.source ~= providers.context_sources["fn.provider"] then return nil, "custom provider unsupported" end
  local provider_slot = providers.provider_slot
  if type(provider_slot) ~= "function" then return nil, "provider selection unavailable" end
  local slot = deepcopy(provider_slot(provider))
  if slot.key_fn ~= "fn.openai_api_key" or not vim.deep_equal(slot.key_env, { "OPENAI_API_KEY" })
    or oauth.LOGIN_FILE ~= "openai_oauth.json" or oauth.CODEX_LOGIN_FILE ~= "openai_codex.json"
    or oauth.API_ORIGIN ~= "https://api.openai.com" then return nil, "custom authentication route unsupported" end
  local oauth_route = {}
  for name, value in pairs(oauth) do
    if name:match("^CODEX_") or name == "LOGIN_FILE" or name == "API_ORIGIN" or name == "REFRESH_WINDOW_MS" then
      oauth_route[name] = deepcopy(value)
    end
  end
  local function auth_route_current()
    if providers.provider_slot ~= provider_slot or not vim.deep_equal(provider_slot(provider), slot) then return false end
    local now = {}
    for name, value in pairs(oauth) do
      if name:match("^CODEX_") or name == "LOGIN_FILE" or name == "API_ORIGIN" or name == "REFRESH_WINDOW_MS" then
        now[name] = value
      end
    end
    return vim.deep_equal(oauth_route, now)
  end
  local dir = config_dir()
  if not dir then return nil, "credential directory unavailable" end
  local oauth_path, codex_path, key_path = dir .. "/openai_oauth.json", dir .. "/openai_codex.json", dir .. "/openai_api_key"
  local function credential(validate)
    if not approved(held.disclosure_approved) then return nil end
    if validate and not validate() then return nil end
    local path, kind, raw
    if uv.fs_stat(oauth_path) then
      path, kind = oauth_path, "oauth"
    elseif uv.fs_stat(codex_path) then
      return nil, "Codex output bound unsupported"
    elseif uv.fs_stat(key_path) then
      path, kind = key_path, "stored"
    else
      kind, raw = "env", vim.env.OPENAI_API_KEY
    end
    if path then raw = read(path, 65536, true) end
    if type(raw) ~= "string" then return nil, "credential unavailable" end
    local token, expires
    if kind == "oauth" then
      local ok, value = pcall(decode, raw)
      if not ok or type(value) ~= "table" then return nil, "credential unavailable" end
      token, expires = clean_key(value.access), tonumber(value.expires)
      local sec, usec = uv.gettimeofday()
      if not expires or expires <= sec * 1000 + math.floor(usec / 1000) + 180000 then return nil, "credential expired" end
    else
      token = clean_key(kind == "stored" and raw:match("^[^\r\n]*") or raw)
    end
    if not token then return nil, "credential unavailable" end
    local stat = path and uv.fs_stat(path) or nil
    return { token = token, kind = kind, digest = sha256(raw), expires = expires, path = path,
      generation = stat and encode({ stat.dev, stat.ino, stat.size, stat.mode, stat.mtime, stat.ctime }) or "env" }
  end
  local executable = vim.fn.exepath("curl")
  executable = executable ~= "" and uv.fs_realpath(executable) or nil
  local executable_hash = executable and fingerprint(executable, 33554432)
  local ca = vim.env.SSL_CERT_FILE
  if not ca or ca == "" then ca = "/etc/ssl/certs/ca-certificates.crt" end
  ca = uv.fs_realpath(ca)
  local ca_hash = ca and fingerprint(ca, 4194304)
  if not executable_hash or not ca_hash then return nil, "fixed TLS transport unavailable" end
  local identity = {
    provider_id = provider, model = model, backend = "openai.responses.direct",
    backend_definition = sha256(backend.source), endpoint = endpoint .. "/v1/responses",
    config = sha256(encode({ model = model, max_output_tokens = held.max_output_tokens,
      max_response_bytes = held.max_response_bytes, timeout_ms = held.timeout_ms })),
    account = "private:" .. vim.base64.encode(uv.random(24)), credentials = "generation:" .. vim.base64.encode(uv.random(24)),
    transport = sha256(executable .. executable_hash .. ca .. ca_hash .. ":empty-env:no-proxy:no-retry:no-redirect"),
    disclosure_revision = held.disclosure_revision,
  }
  local function noncredential_current()
    if not auth_route_current() then return nil end
    if not vim.deep_equal(selection, config.provider_config)
      or config.disclosure_approved ~= held.disclosure_approved or config.session ~= held.session
      or config.disclosure_revision ~= held.disclosure_revision or config.max_output_tokens ~= held.max_output_tokens
      or config.max_response_bytes ~= held.max_response_bytes or config.timeout_ms ~= held.timeout_ms
      or providers.resolve_provider ~= resolve_provider or providers.resolve_model ~= resolve_model
      or providers.base_url ~= base_url or oauth.config_dir ~= config_dir or providers.clean_key ~= clean_key
      or vim.system ~= system or config_dir() ~= dir then return nil end
    if resolve_provider(held.session, selection) ~= provider or resolve_model(provider, held.session, selection) ~= model
      or base_url(provider, selection) ~= endpoint or not vim.deep_equal(registry.get("fn.provider_openai"), backend)
      or not vim.deep_equal(registry.get("fn.provider"), dispatcher) then return nil end
    for name, definition in pairs(definitions) do
      if not vim.deep_equal(registry.get(name), definition) then return nil end
    end
    if fingerprint(executable, 33554432) ~= executable_hash or fingerprint(ca, 4194304) ~= ca_hash then return nil end
    return true
  end
  local secret, secret_err = credential(noncredential_current)
  if not secret then return nil, secret_err or "disclosure approval required" end
  local function current()
    if not approved(held.disclosure_approved) or not noncredential_current() then return nil end
    local now = credential(noncredential_current)
    if not now or not vim.deep_equal(secret, now) then return nil end
    return deepcopy(identity)
  end
  local function transport(request, ctx)
    if type(ctx) ~= "table" or type(ctx.await) ~= "function" or type(ctx.cancelled) ~= "function" then error("isolated context required", 0) end
    local isolated = { await = ctx.await, cancelled = ctx.cancelled, on_cancel = ctx.on_cancel, emit = function() end }
    if isolated.cancelled() ~= false or not current() then error("provider resolution changed", 0) end
    if type(request) ~= "table" or getmetatable(request) ~= nil or request.provider_id ~= provider or request.model ~= model
      or not vim.deep_equal(request.route, identity) or type(request.tools) ~= "table" or next(request.tools) ~= nil
      or type(request.messages) ~= "table" or #request.messages ~= 1 then error("invalid isolated request", 0) end
    for key in pairs(request) do
      if key ~= "provider_id" and key ~= "model" and key ~= "route" and key ~= "messages" and key ~= "tools" then error("unexpected request field", 0) end
    end
    for key in pairs(request.messages) do if key ~= 1 then error("unexpected message index", 0) end end
    local message = request.messages[1]
    if type(message) ~= "table" or message.role ~= "user" or type(message.content) ~= "string"
      or #message.content > held.max_response_bytes then error("invalid isolated message", 0) end
    for key in pairs(message) do if key ~= "role" and key ~= "content" then error("unexpected message field", 0) end end
    local payload = encode({ model = model, input = { { role = "user", content = message.content } },
      stream = true, store = false, max_output_tokens = held.max_output_tokens })
    local argv = { executable, "-q", "--silent", "--show-error", "--globoff", "--no-buffer", "--request", "POST",
      "--proto", "=https", "--no-insecure", "--no-location", "--max-redirs", "0", "--retry", "0", "--proxy", "", "--noproxy", "*", "--cacert", ca, "--capath", "",
      "--max-time", tostring(held.timeout_ms / 1000), "--header", "Content-Type: application/json",
      "--header", "Authorization: Bearer " .. secret.token, "--data-binary", "@-", "--write-out", "\nSTRAPS_HTTP:%{http_code}", identity.endpoint }
    local result = isolated.await(function(resolve)
      if isolated.cancelled() ~= false or not current() then resolve({ failed = true }); return end
      local chunks, size, failed, proc, settled, killed = {}, 0, false, nil, false, false
      local function finish(value)
        if settled then return end
        settled = true
        resolve(value)
      end
      local function abort()
        if settled and not failed then return end
        failed = true
        if proc and not killed then killed = true; pcall(proc.kill, proc, 9) end
        finish({ failed = true })
      end
      local ok, value = pcall(function(command, options, done) return require("straps.provider_transport").system(command, options, done, system) end, argv, { stdin = payload, clear_env = true, env = {}, timeout = held.timeout_ms,
        stdout = function(err, data)
          if settled then return end
          if err then abort(); return end
          if data then
            size = size + #data
            if size > held.max_response_bytes then abort() else chunks[#chunks + 1] = data end
          end
        end,
        stderr = function() end,
      }, function(exit)
        finish({ code = exit.code, failed = failed, output = table.concat(chunks) })
      end)
      if not ok then finish({ failed = true }); return end
      proc = value
      if failed or isolated.cancelled() ~= false then abort() end
      if isolated.on_cancel then isolated.on_cancel(abort) end
    end)
    if isolated.cancelled() ~= false or not current() then error("provider resolution changed", 0) end
    if type(result) ~= "table" or result.failed or result.code ~= 0 then error("contextual transport unavailable", 0) end
    local stream, status = result.output:match("^(.*)\nSTRAPS_HTTP:(%d%d%d)$")
    if not stream or status ~= "200" then error("contextual HTTP unavailable", 0) end
    local metadata = { complete = false, refused = false, incomplete = false, tool_output = false, stop_reason = "unknown" }
    local texts, terminal = {}, false
    local function array(value)
      if type(value) ~= "table" then error("invalid contextual array", 0) end
      local count = 0
      for key in pairs(value) do
        count = count + 1
        if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then error("invalid contextual array", 0) end
      end
      for index = 1, count do if rawget(value, index) == nil then error("invalid contextual array", 0) end end
      return value
    end
    local function inspect_part(part)
      if type(part) ~= "table" then error("invalid contextual content", 0) end
      if part.type == "refusal" then metadata.refused = true
      elseif part.type ~= "output_text" then metadata.tool_output = true end
    end
    local function inspect_item(item)
      if type(item) ~= "table" then error("invalid contextual item", 0) end
      if item.type ~= "message" and item.type ~= "reasoning" then metadata.tool_output = true end
      if item.status == "incomplete" or item.status == "failed" then metadata.incomplete = true end
      if item.type == "message" then
        if item.role ~= "assistant" then metadata.tool_output = true end
        for _, part in ipairs(array(item.content)) do inspect_part(part) end
      elseif item.content ~= nil then
        for _, part in ipairs(array(item.content)) do inspect_part(part) end
      end
    end
    local allowed = {
      ["response.created"] = true, ["response.queued"] = true, ["response.in_progress"] = true,
      ["response.output_text.done"] = true, ["response.reasoning_summary_part.added"] = true,
      ["response.reasoning_summary_part.done"] = true, ["response.reasoning_summary_text.delta"] = true,
      ["response.reasoning_summary_text.done"] = true,
    }
    if not stream:match("\n\r?\n$") then error("incomplete contextual event frame", 0) end
    local function process_frame(event_name, data)
      if #data == 0 then
        if event_name then error("incomplete contextual event", 0) end
        return
      end
      local ok, event = pcall(decode, table.concat(data, "\n"))
      if not ok or type(event) ~= "table" or terminal then error("invalid contextual event", 0) end
      local kind = event.type
      if event_name and event_name ~= kind then error("mismatched contextual event", 0) end
      if event.response ~= nil then
        if type(event.response) ~= "table" then error("invalid contextual response", 0) end
        if event.response.status == "incomplete" or event.response.incomplete_details ~= nil
          and event.response.incomplete_details ~= vim.NIL then metadata.incomplete = true end
        if event.response.output ~= nil then
          for _, item in ipairs(array(event.response.output)) do inspect_item(item) end
        end
      end
      if kind == "response.output_text.delta" then
        if type(event.delta) ~= "string" then error("invalid contextual text", 0) end
        texts[#texts + 1] = event.delta
      elseif kind == "response.refusal.delta" or kind == "response.refusal.done" then metadata.refused = true
      elseif kind == "response.output_item.added" or kind == "response.output_item.done" then inspect_item(event.item)
      elseif kind == "response.content_part.added" or kind == "response.content_part.done" then inspect_part(event.part)
      elseif kind == "response.completed" or kind == "response.done" then
        local response = event.response
        if type(response) ~= "table" or response.status ~= "completed" then error("unassessed terminal response", 0) end
        array(response.output)
        metadata.complete, metadata.stop_reason, terminal = true, "end_turn", true
      elseif kind == "response.incomplete" then
        metadata.incomplete, metadata.stop_reason, terminal = true, "incomplete", true
      elseif kind == "response.failed" or kind == "error" then error("contextual provider failed", 0)
      elseif not allowed[kind] then error("unexpected contextual event", 0) end
    end
    local event_name, data = nil, {}
    for line in stream:gmatch("([^\n]*)\n") do
      line = line:gsub("\r$", "")
      if line == "" then
        process_frame(event_name, data)
        event_name, data = nil, {}
      elseif line:sub(1, 6) == "event:" then
        if event_name then error("duplicate contextual event name", 0) end
        event_name = line:sub(7):match("^%s*(.-)%s*$")
      elseif line:sub(1, 5) == "data:" then
        data[#data + 1] = line:sub(6):gsub("^ ", "")
      elseif line:sub(1, 1) ~= ":" then error("unexpected contextual stream field", 0) end
    end
    if not terminal then error("contextual response incomplete", 0) end
    return { text = table.concat(texts), metadata = metadata }
  end
  return { identity = deepcopy(identity), resolve_identity = current, transport = transport }
end

local installed = false
function M.install(consumer)
  if installed or not registry.trusted_setup_allowed() or type(consumer) ~= "function" then return nil, "trusted bootstrap required" end
  installed = true
  consumer(new)
  return true
end

return M
