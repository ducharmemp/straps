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
      .. " no cookies or credentials, follows redirects only when follow_redirects"
      .. " is true, and returns status/headers/body. Use for public docs or small"
      .. " artifacts, not secrets. Parameters: url (required); max_bytes (optional,"
      .. " default 200000, max 1000000); timeout_ms (optional, default 10000);"
      .. " follow_redirects (optional boolean).",
    input_schema = {
      type = "object",
      properties = {
        url = { type = "string", description = "http(s) URL to fetch." },
        max_bytes = { type = "integer", description = "Maximum body bytes (default 200000, max 1000000)." },
        timeout_ms = { type = "integer", description = "Timeout in milliseconds (default 10000)." },
        follow_redirects = { type = "boolean", description = "Follow redirects (default false)." },
      },
      required = { "url" },
    },
    source = [==[
return function(input, ctx)
  local url = input.url
  if type(url) ~= "string" or not url:match("^https?://") then
    error("fetch_url: url must start with http:// or https://")
  end
  -- Basic SSRF guard: refuse obviously-internal hosts. Extract the host from
  -- the authority (strip userinfo, port, and IPv6 brackets), lowercase it.
  local function host_of(u)
    local authority = u:match("^https?://([^/?#]+)") or ""
    authority = authority:gsub("^[^@]*@", "")          -- strip userinfo
    local h = authority:match("^%[([^%]]+)%]") or authority:match("^([^:]+)")
    return (h or ""):lower()
  end
  local function is_internal(h)
    if h == "" then return false end
    if h == "localhost" or h:match("%.localhost$") then return true end
    if h == "0.0.0.0" or h == "::1" or h == "::" then return true end
    -- IPv4 literal ranges: loopback, private, link-local (incl. cloud metadata).
    local a, b = h:match("^(%d+)%.(%d+)%.%d+%.%d+$")
    a, b = tonumber(a), tonumber(b)
    if a then
      if a == 127 then return true end            -- 127.0.0.0/8 loopback
      if a == 10 then return true end             -- 10.0.0.0/8
      if a == 169 and b == 254 then return true end -- 169.254.0.0/16 link-local / metadata
      if a == 172 and b >= 16 and b <= 31 then return true end -- 172.16.0.0/12
      if a == 192 and b == 168 then return true end -- 192.168.0.0/16
    end
    -- IPv6 unique-local (fc00::/7) and link-local (fe80::/10).
    if h:match("^f[cd]") or h:match("^fe[89ab]") then return true end
    return false
  end
  if is_internal(host_of(url)) then
    error("fetch_url: refusing to fetch an internal/loopback/link-local host ("
      .. host_of(url) .. ")")
  end
  if vim.fn.executable("curl") ~= 1 then
    return "fetch_url: curl is not executable"
  end
  local max_bytes = math.min(math.max(tonumber(input.max_bytes) or 200000, 1), 1000000)
  local timeout_ms = tonumber(input.timeout_ms) or 10000
  local cmd = { "curl", "--disable", "--silent", "--show-error", "--include", "--max-time", tostring(math.ceil(timeout_ms / 1000)) }
  if input.follow_redirects then
    cmd[#cmd + 1] = "--location"
    -- Never let a redirect downgrade the protocol or reach non-http(s) schemes
    -- (e.g. file://, gopher://) — a common SSRF pivot.
    cmd[#cmd + 1] = "--proto-redir"; cmd[#cmd + 1] = "=http,https"
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
