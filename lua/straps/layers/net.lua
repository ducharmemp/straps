-- straps/layers/net.lua — the NET layer: bounded, credential-free web fetch
-- (fetch_url) with its SSRF guard.
-- Future prompt-fragment slot: fn.system_prompt_layer.net.

local M = {}

function M.register()
  local registry = require("straps.registry")
  local define = registry.define_default

  -- ---------------------------------------------------------------- fetch_url

  define({
    name = "tool.fetch_url",
    kind = "tool",
    doc = "Fetch an http(s) URL with curl using a timeout and byte cap. It sends"
      .. " no cookies or credentials. Hostnames are resolved first and internal"
      .. " addresses are refused. Redirects are checked one hop at a time. Use for"
      .. " public docs or small artifacts, not secrets. Parameters: url (required);"
      .. " max_bytes (optional, default 200000, max 1000000); timeout_ms (optional,"
      .. " default 10000); follow_redirects (optional boolean).",
    input_schema = {
      type = "object",
      properties = {
        url = { type = "string", description = "http(s) URL to fetch." },
        max_bytes = { type = "integer", description = "Maximum body bytes (default 200000, max 1000000)." },
        timeout_ms = { type = "integer", description = "Timeout in milliseconds (default 10000)." },
        follow_redirects = { type = "boolean", description = "Deprecated safety flag. true returns a refusal; fetch each Location separately." },
      },
      required = { "url" },
    },
    source = [==[
return function(input, ctx)
  local url = input.url
  if type(url) ~= "string" or not url:match("^https?://") then
    error("fetch_url: url must start with http:// or https://")
  end
  local function host_of(u)
    local authority = u:match("^https?://([^/?#]+)") or ""
    authority = authority:gsub("^[^@]*@", "")
    return (authority:match("^%[([^%]]+)%]") or authority:match("^([^:]+)") or ""):lower()
  end
  local function is_internal(h)
    if h == "" then return false end
    if h == "localhost" or h:match("%.localhost$") then return true end
    if h == "0.0.0.0" or h == "::1" or h == "::" then return true end
    local a, b = h:match("^(%d+)%.(%d+)%.%d+%.%d+$")
    a, b = tonumber(a), tonumber(b)
    if a then
      if a == 0 or a == 10 or a == 127 then return true end
      if a == 169 and b == 254 then return true end
      if a == 172 and b >= 16 and b <= 31 then return true end
      if a == 192 and b == 168 then return true end
    end
    if h:match("^f[cd]") or h:match("^fe[89ab]") then return true end
    return false
  end
  local function check_url(u)
    local host = host_of(u)
    if is_internal(host) then
      return nil, "fetch_url: refusing to fetch an internal/loopback/link-local host (" .. host .. ")"
    end
    if not host:match("^%d+%.%d+%.%d+%.%d+$") and not host:find(":", 1, true) then
      local done, err, addresses = false, nil, nil
      vim.uv.getaddrinfo(host, nil, { socktype = "stream" }, function(e, a)
        err, addresses, done = e, a, true
      end)
      vim.wait(5000, function() return done end, 10)
      if not done then return nil, "fetch_url: DNS lookup timed out for " .. host end
      if err or type(addresses) ~= "table" or #addresses == 0 then
        return nil, "fetch_url: could not resolve " .. host .. ": " .. tostring(err)
      end
      for _, address in ipairs(addresses) do
        if is_internal(address.addr or "") then
          return nil, "fetch_url: refusing internal address " .. tostring(address.addr) .. " for " .. host
        end
      end
    end
    return true
  end
  local ok_url, url_err = check_url(url)
  if not ok_url then error(url_err) end
  if vim.fn.executable("curl") ~= 1 then
    return "fetch_url: curl is not executable"
  end
  local max_bytes = math.min(math.max(tonumber(input.max_bytes) or 200000, 1), 1000000)
  local timeout_ms = tonumber(input.timeout_ms) or 10000
  local cmd = { "curl", "--disable", "--silent", "--show-error", "--include", "--max-time", tostring(math.ceil(timeout_ms / 1000)) }
  -- Curl cannot re-run our DNS policy before each redirect connection. Keep
  -- redirects manual so every destination gets a fresh confirmed, checked call.
  if input.follow_redirects then
    return "fetch_url: redirects are not followed automatically; inspect the Location header and fetch the destination separately"
  end
  cmd[#cmd + 1] = "--"; cmd[#cmd + 1] = url
  local chunks, n, capped, proc = {}, 0, false, nil
  local res = ctx.await(function(resolve)
    proc = vim.system(cmd, {
      text = true,
      timeout = timeout_ms,
      stdout = function(_, chunk)
        if not chunk or chunk == "" then return end
        if n >= max_bytes then capped = true; if proc then pcall(function() proc:kill(9) end) end; return end
        local keep = math.min(#chunk, max_bytes - n)
        chunks[#chunks + 1] = chunk:sub(1, keep)
        n = n + keep
        if keep < #chunk then capped = true; if proc then pcall(function() proc:kill(9) end) end end
      end,
    }, function(out) resolve(out) end)
    if ctx.on_cancel then ctx.on_cancel(function() pcall(function() proc:kill(9) end) end) end
  end)
  local body = table.concat(chunks)
  local lines = { "exit code: " .. tostring(res.code) }
  if capped then lines[#lines + 1] = "body truncated at " .. tostring(max_bytes) .. " bytes" end
  if res.stderr and res.stderr ~= "" then lines[#lines + 1] = "stderr:\n" .. res.stderr end
  lines[#lines + 1] = body
  return table.concat(lines, "\n")
end
]==],
  })
end

return M
