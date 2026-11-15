local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(here, ":p:h:h")
package.path = root .. "/lua/?.lua;" .. package.path
local original_system, original_exepath = vim.system, vim.fn.exepath
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local function write(path, content)
  local f = assert(io.open(path, "w")); f:write(content); f:close()
  vim.fn.setfperm(path, "rw-------")
end
write(tmp .. "/curl", "offline executable")
write(tmp .. "/ca", "offline CA")
vim.env.SSL_CERT_FILE = tmp .. "/ca"
vim.env.OPENAI_API_KEY = nil
local entries = {}
local sources = {}
for _, name in ipairs({ "fn.openai_api_key", "fn.openai_oauth_credential", "fn.openai_codex_credential", "fn.api_key_store" }) do
  sources[name] = name .. " default"
  entries[name] = { source = sources[name], identity = name }
end
entries["fn.provider_openai"] = { source = "backend", identity = 1 }
entries["fn.provider"] = { source = "dispatcher", identity = 2 }
local trusted, selected, selected_model = true, "openai", "gpt-6.1-sol"
package.loaded["straps.registry"] = { trusted_setup_allowed = function() return trusted end,
  get = function(name) return vim.deepcopy(entries[name]) end }
package.loaded["straps.provider"] = {
  contextual_auth_sources = sources, context_sources = { ["fn.provider_openai"] = "backend", ["fn.provider"] = "dispatcher" },
  resolve_provider = function() return selected end, resolve_model = function() return selected_model end,
  base_url = function(_, config) return config.openai_base_url or "https://api.openai.com" end,
  provider_slot = function() return package.loaded["straps.provider"].slot end,
  slot = { key_fn = "fn.openai_api_key", key_env = { "OPENAI_API_KEY" } },
  clean_key = function(value)
    if type(value) ~= "string" then return nil end
    value = vim.trim(value)
    return value ~= "" and not value:find("[%s%c]") and value or nil
  end,
}
package.loaded["straps.oauth"] = { config_dir = function() return tmp end, LOGIN_FILE = "openai_oauth.json",
  CODEX_LOGIN_FILE = "openai_codex.json", API_ORIGIN = "https://api.openai.com", CODEX_BASE_URL = "https://chatgpt.com/backend-api" }
local calls, response, code, before_dispatch, capture = 0, nil, 0, nil, nil
local deferred, process, spawn_error, stdout_error
local original_fs_read, original_fs_stat = vim.uv.fs_read, vim.uv.fs_stat
local original_fs_open, credential_reads = vim.uv.fs_open, 0
vim.uv.fs_open = function(path, ...)
  if path == tmp .. "/openai_api_key" or path == tmp .. "/openai_oauth.json" or path == tmp .. "/openai_codex.json" then
    credential_reads = credential_reads + 1
  end
  return original_fs_open(path, ...)
end
vim.fn.exepath = function(name) assert.equals("curl", name); return tmp .. "/curl" end
vim.system = function(argv, opts, done)
  calls = calls + 1
  capture = { argv = vim.deepcopy(argv), opts = opts, body = vim.json.decode(opts.stdin) }
  for i, arg in ipairs(argv) do
    if arg == "--header" and argv[i + 1]:sub(1, 1) == "@" then
      capture.headers = table.concat(vim.fn.readfile(argv[i + 1]:sub(2)), "\n")
    end
  end
  process = { kills = {}, stdout = opts.stdout, done = done, kill = function(self, signal) self.kills[#self.kills + 1] = signal end }
  if before_dispatch then before_dispatch() end
  if spawn_error then error("offline spawn exception") end
  if not deferred then opts.stdout(stdout_error, response); done({ code = code }) end
  return process
end
local mutations = {
  cancel_registration = { 'if isolated.on_cancel then isolated.on_cancel(abort) end', 'if isolated.on_cancel then isolated.on_cancel(function() end) end' },
  kill = { 'pcall(proc.kill, proc, 9)', 'pcall(function() end)' },
  kill_signal = { 'proc, 9)', 'proc, 15)' },
  finish_once = { 'if settled then return end\n        settled = true', 'if false then return end\n        settled = true' },
  kill_once = { 'proc and not killed', 'proc' },
  abort_resolution = { 'finish({ failed = true })\n      end', 'local ignored = true\n      end' },
  mode_race = { 'before.mode ~= after.mode or (private and after.mode % 64 ~= 0)', 'false' },
  private_mode = { '(private and before.mode % 64 ~= 0)', 'false' },
  credential_size = { 'before.size > maximum', 'false' },
  inode = { 'before.ino ~= after.ino', 'false' },
  device = { 'before.dev ~= after.dev', 'false' },
  read_size = { 'before.size ~= after.size', 'false' },
  mtime = { 'not vim.deep_equal(before.mtime, after.mtime)', 'false' },
  ctime = { 'not vim.deep_equal(before.ctime, after.ctime)', 'false' },
  exit_code = { 'or result.code ~= 0', 'or false' },
  http_status = { 'or status ~= "200"', 'or false' },
  stdout_failure = { 'if err then abort(); return end', 'if false then abort(); return end' },

  last_approval = { 'if validate and not validate() then return nil end', 'if false then return nil end' },
  frame_boundary = { 'if event_name then error("incomplete contextual event", 0) end', 'if false then error("incomplete contextual event", 0) end' },
  credential_order = { 'local function current()', 'local function current() credential()' },
  approval = { 'return ok and coroutine.status(thread) == "dead" and value == true', 'return true' },
  route = { 'if resolve_provider(held.session, selection) ~= provider or resolve_model(provider, held.session, selection) ~= model', 'if false' },
  auth_route = { 'if not auth_route_current() then return nil end', 'if false then return nil end' },
  config = { 'or config.disclosure_revision ~= held.disclosure_revision', 'or false' },
  transport = { 'if fingerprint(executable, 33554432) ~= executable_hash or fingerprint(ca, 4194304) ~= ca_hash then return nil end', 'if false then return nil end' },
  parser = { 'elseif not allowed[kind] then error("unexpected contextual event", 0) end', 'elseif false then error("unexpected contextual event", 0) end' },
  complete = { 'if not terminal then error("contextual response incomplete", 0) end', 'if false then error("contextual response incomplete", 0) end' },
  refusal = { 'if part.type == "refusal" then metadata.refused = true', 'if part.type == "refusal" then metadata.refused = false' },
  tools = { 'if item.type ~= "message" and item.type ~= "reasoning" then metadata.tool_output = true end', 'if false then metadata.tool_output = true end' },
  incomplete = { 'metadata.incomplete, metadata.stop_reason, terminal = true, "incomplete", true', 'metadata.incomplete, metadata.stop_reason, terminal = false, "end_turn", true' },
  generation = { 'if not now or not vim.deep_equal(secret, now) then return nil end', 'if false then return nil end' },
  isolated = { 'clear_env = true, env = {}', 'clear_env = false, env = {}' },
  bound = { 'if size > held.max_response_bytes then abort()', 'if false then abort()' },
}
local mutation = mutations[os.getenv("CONTEXTUAL_PROVIDER_MUTATION")]
local factory
if mutation then
  local source = table.concat(vim.fn.readfile(root .. "/lua/straps/contextual_provider.lua"), "\n")
  local first, last = source:find(mutation[1], 1, true)
  assert(first, "missing production mutation target")
  source = source:sub(1, first - 1) .. mutation[2] .. source:sub(last + 1)
  factory = assert(loadstring(source))()
else
  factory = require("straps.contextual_provider")
end
local construct
assert(factory.install(function(value) construct = value end))
local approved = true
local function config()
  return { session = 7, provider_config = { provider = "openai", openai_model = "gpt-6.1-sol" },
    disclosure_revision = "adopted-1", disclosure_approved = function() return approved end,
    max_output_tokens = 1000, max_response_bytes = 8192, timeout_ms = 10000 }
end
local function event(value) return "data: " .. vim.json.encode(value) .. "\n\n" end
local function terminal(status, output)
  return event({ type = "response.completed", response = { status = status or "completed", output = output or {} } })
end
local ctx = { await = function(start)
  local result; start(function(value) result = value end); return result
end, cancelled = function() return false end, emit = function() error("acting emit used") end,
  bufnr = 9, system = "acting instructions", pin = "acting pin", tools = { "bash" } }
local function request(adapter)
  return { provider_id = adapter.identity.provider_id, model = adapter.identity.model, route = vim.deepcopy(adapter.identity),
    tools = {}, messages = { { role = "user", content = "isolated evidence" } } }
end
local function send(adapter) return adapter.transport(request(adapter), ctx) end
before_each(function()
  trusted, approved, selected, selected_model, calls, code, before_dispatch = true, true, "openai", "gpt-6.1-sol", 0, 0, nil
  deferred, process, spawn_error, stdout_error = false, nil, false, nil
  vim.uv.fs_read, vim.uv.fs_stat = original_fs_read, original_fs_stat
  vim.fn.delete(tmp .. "/openai_codex.json")
  vim.fn.delete(tmp .. "/openai_oauth.json")
  write(tmp .. "/openai_api_key", "offline-test-key\n")
  write(tmp .. "/ca", "offline CA")
  entries["fn.provider_openai"].identity = 1
  response = event({ type = "response.output_text.delta", delta = "{}" }) .. terminal() .. "\nSTRAPS_HTTP:200"
end)
after_each(function() assert.equals(0, calls > 1 and 1 or 0) end)
teardown(function()
  vim.system, vim.fn.exepath, vim.uv.fs_open = original_system, original_exepath, original_fs_open
  vim.fn.delete(tmp, "rf")
end)
describe("configured contextual provider", function()
  it("requires trusted setup and approved disclosure before credential acquisition", function()
    trusted = false
    assert.is_nil(factory.install(function() end))
    trusted, approved = true, false
    assert.is_nil(construct(config()))
    assert.equals(0, calls)
  end)
  it("fixes configured route and sends isolated bounded input through fixed transport", function()
    local adapter = assert(construct(config()))
    local result = send(adapter)
    assert.same({ text = "{}", metadata = { complete = true, refused = false, incomplete = false, tool_output = false, stop_reason = "end_turn" } }, result)
    assert.equals("gpt-6.1-sol", capture.body.model)
    assert.equals(1000, capture.body.max_output_tokens)
    assert.same({ { role = "user", content = "isolated evidence" } }, capture.body.input)
    assert.is_nil(capture.body.instructions)
    assert.is_nil(capture.body.tools)
    assert.is_true(capture.opts.clear_env)
    assert.same({}, capture.opts.env)
    assert.equals("-q", capture.argv[2])
    assert.is_true(vim.tbl_contains(capture.argv, "https://api.openai.com/v1/responses"))
    assert.is_nil(table.concat(capture.argv, " "):find("offline-test-key", 1, true))
    assert.equals("Authorization: Bearer offline-test-key", capture.headers)
    assert.is_nil(vim.json.encode(adapter.identity):find("offline%-test%-key"))
    adapter.identity.model = "mutated"
    assert.equals("gpt-6.1-sol", adapter.resolve_identity().model)
  end)
  it("supports direct OAuth without refreshing", function()
    write(tmp .. "/openai_oauth.json", vim.json.encode({ access = "offline-oauth-token", refresh = "never-transmit", expires = 9999999999999 }))
    local adapter = assert(construct(config()))
    assert.equals("{}", send(adapter).text)
    assert.is_nil(table.concat(capture.argv, " "):find("offline-oauth-token", 1, true))
    assert.equals("Authorization: Bearer offline-oauth-token", capture.headers)
    assert.is_nil(capture.opts.stdin:find("offline-oauth-token", 1, true))
    assert.is_nil(capture.opts.stdin:find("never-transmit", 1, true))
    assert.is_nil(vim.json.encode(adapter.identity):find("offline-oauth-token", 1, true))
  end)
  it("rejects unsupported routes and unbounded Codex", function()
    selected = "anthropic"; assert.is_nil(construct(config()))
    selected = "openai"
    local c = config(); c.provider_config.openai_base_url = "https://elsewhere.example"
    assert.is_nil(construct(c))
    write(tmp .. "/openai_codex.json", "not read")
    local adapter, reason = construct(config())
    assert.is_nil(adapter); assert.equals("Codex output bound unsupported", reason)
    assert.equals(0, calls)
  end)
  it("fails closed on credential generation change and expired OAuth", function()
    local adapter = assert(construct(config()))
    write(tmp .. "/openai_api_key", "replacement-key\n")
    assert.is_nil(adapter.resolve_identity())
    assert.has_error(function() send(adapter) end)
    assert.equals(0, calls)
    write(tmp .. "/openai_oauth.json", vim.json.encode({ access = "old-token", expires = 1 }))
    assert.is_nil(construct(config()))
  end)
  it("rejects selector, backend, TLS and approval changes", function()
    local adapter = assert(construct(config()))
    selected_model = "different"; assert.is_nil(adapter.resolve_identity())
    selected_model = "gpt-6.1-sol"
    entries["fn.provider_openai"].identity = 3; assert.is_nil(adapter.resolve_identity())
    entries["fn.provider_openai"].identity = 1
    write(tmp .. "/ca", "changed CA"); assert.is_nil(adapter.resolve_identity())
    write(tmp .. "/ca", "offline CA")
    approved = false; assert.is_nil(adapter.resolve_identity())
    assert.has_error(function() send(adapter) end)
    assert.equals(0, calls)
  end)
  it("rejects changed route after dispatch", function()
    local adapter = assert(construct(config()))
    before_dispatch = function() selected_model = "changed while pending" end
    assert.has_error(function() send(adapter) end)
    assert.equals(1, calls)
  end)
  it("rejects missing terminal without retry", function()
    local adapter = assert(construct(config()))
    response = event({ type = "response.output_text.delta", delta = "{}" }) .. "\nSTRAPS_HTTP:200"
    assert.has_error(function() send(adapter) end)
    assert.equals(1, calls)
  end)
  it("reports refusal and tool output from terminal events", function()
    local adapter = assert(construct(config()))
    response = event({ type = "response.refusal.delta", delta = "no" })
      .. event({ type = "response.output_item.added", item = { type = "function_call" } }) .. terminal() .. "\nSTRAPS_HTTP:200"
    local result = send(adapter)
    assert.is_true(result.metadata.refused)
    assert.is_true(result.metadata.tool_output)
  end)
  it("reports incomplete terminal without claiming completion", function()
    local adapter = assert(construct(config()))
    response = event({ type = "response.incomplete", response = { status = "incomplete" } }) .. "\nSTRAPS_HTTP:200"
    local result = send(adapter)
    assert.is_false(result.metadata.complete)
    assert.is_true(result.metadata.incomplete)
    assert.equals("incomplete", result.metadata.stop_reason)
  end)
  it("bounds response bytes and refuses oversized output", function()
    local adapter = assert(construct(config()))
    response = string.rep(" ", 9000) .. "\n" .. terminal() .. "\nSTRAPS_HTTP:200"
    assert.has_error(function() send(adapter) end)
  end)
  it("rejects HTTP redirects without retry", function()
    local adapter = assert(construct(config()))
    response = terminal() .. "\nSTRAPS_HTTP:302"
    assert.has_error(function() send(adapter) end)
    assert.equals(1, calls)
  end)
  it("rejects cancellation before any subprocess", function()
    local adapter = assert(construct(config()))
    local cancelled = vim.tbl_extend("force", ctx, { cancelled = function() return true end })
    assert.has_error(function() adapter.transport(request(adapter), cancelled) end)
    assert.equals(0, calls)
  end)
  it("rejects custom authentication and changed disclosure revision", function()
    entries["fn.openai_api_key"].source = "custom"
    assert.is_nil(construct(config()))
    entries["fn.openai_api_key"].source = sources["fn.openai_api_key"]
    local c = config()
    local adapter = assert(construct(c))
    c.disclosure_revision = "changed"
    assert.is_nil(adapter.resolve_identity())
    assert.has_error(function() send(adapter) end)
    assert.equals(0, calls)
  end)
  it("supports environment API keys after approval", function()
    vim.fn.delete(tmp .. "/openai_api_key")
    vim.env.OPENAI_API_KEY = "offline-env-key"
    local adapter = assert(construct(config()))
    assert.equals("{}", send(adapter).text)
    vim.env.OPENAI_API_KEY = "changed-env-key"
    assert.is_nil(adapter.resolve_identity())
    vim.env.OPENAI_API_KEY = nil
  end)
  it("rejects authentication route mutation before dispatch", function()
    local p, o = package.loaded["straps.provider"], package.loaded["straps.oauth"]
    local changes = {
      { p.slot, "key_fn", "fn.other_key" }, { p.slot, "key_env", { "OTHER_KEY" } },
      { o, "LOGIN_FILE", "other.json" }, { o, "CODEX_LOGIN_FILE", "other-codex.json" },
      { o, "CODEX_BASE_URL", "https://elsewhere.example" }, { o, "API_ORIGIN", "https://elsewhere.example" },
      { p, "provider_slot", function() return {} end },
    }
    for _, change in ipairs(changes) do
      local adapter = assert(construct(config()))
      local old = change[1][change[2]]
      change[1][change[2]] = change[3]
      local identity = adapter.resolve_identity()
      local ok = pcall(send, adapter)
      change[1][change[2]] = old
      assert.equals(0, calls, "auth route mutation must dispatch zero requests: " .. change[2])
      assert.is_nil(identity, "auth route mutation must invalidate identity: " .. change[2])
      assert.is_false(ok, "auth route mutation must prevent transport: " .. change[2])
    end
  end)
  it("invalidates changed OAuth account metadata before dispatch", function()
    local value = { access = "offline-oauth-token", expires = 9999999999999, account_id = "first-account" }
    write(tmp .. "/openai_oauth.json", vim.json.encode(value))
    local adapter = assert(construct(config()))
    value.account_id = "second-account"
    write(tmp .. "/openai_oauth.json", vim.json.encode(value))
    assert.has_error(function() send(adapter) end)
    assert.equals(0, calls, "changed OAuth account must dispatch zero requests")
  end)
  it("rejects cancellation changed during synchronous dispatch", function()
    local adapter = assert(construct(config()))
    local cancelled = false
    before_dispatch = function() cancelled = true end
    local pending = vim.tbl_extend("force", ctx, { cancelled = function() return cancelled end })
    assert.has_error(function() adapter.transport(request(adapter), pending) end)
    assert.equals(1, calls)
  end)
  it("rejects configuration revision mutation before dispatch", function()
    local c = config()
    local adapter = assert(construct(c))
    c.disclosure_revision = "replacement"
    assert.has_error(function() send(adapter) end)
    assert.equals(0, calls, "changed disclosure config must dispatch zero requests")
  end)
  it("rejects transport executable mutation before dispatch", function()
    local adapter = assert(construct(config()))
    write(tmp .. "/curl", "changed executable")
    local identity = adapter.resolve_identity()
    local ok = pcall(send, adapter)
    write(tmp .. "/curl", "offline executable")
    assert.is_nil(identity, "changed executable must invalidate transport identity")
    assert.is_false(ok, "changed executable must prevent dispatch")
    assert.equals(0, calls)
  end)
  for _, case in ipairs({
    { "refusal", { type = "message", role = "assistant", content = { { type = "refusal" } } }, "refused" },
    { "unexpected content", { type = "message", role = "assistant", content = { { type = "input_text" } } }, "tool_output" },
    { "incomplete item", { type = "message", role = "assistant", status = "incomplete", content = {} }, "incomplete" },
    { "tool item", { type = "function_call" }, "tool_output" },
  }) do
    for _, location in ipairs({ "response.output_item.added", "response.output_item.done", "response.created", "terminal" }) do
      it("preserves " .. case[1] .. " from " .. location, function()
        local adapter = assert(construct(config()))
        local prefix = location == "terminal" and "" or event(location == "response.created"
          and { type = location, response = { output = { case[2] } } } or { type = location, item = case[2] })
        response = prefix .. terminal("completed", location == "terminal" and { case[2] } or {}) .. "\nSTRAPS_HTTP:200"
        assert.is_true(send(adapter).metadata[case[3]], "must retain " .. case[1] .. " in " .. location)
      end)
    end
  end
  it("rejects changed session and disclosure callback", function()
    local c = config()
    local adapter = assert(construct(c))
    c.session = 8
    assert.has_error(function() send(adapter) end)
    c.session = 7
    c.disclosure_approved = function() return true end
    assert.has_error(function() send(adapter) end)
    assert.equals(0, calls)
  end)
  it("rejects non-SSE content before a completed terminal", function()
    local adapter = assert(construct(config()))
    response = "unexpected content\n\n" .. terminal() .. "\nSTRAPS_HTTP:200"
    assert.has_error(function() send(adapter) end)
    assert.equals(1, calls)
  end)
  it("rejects malformed event framing and conflicting event names", function()
    local adapter = assert(construct(config()))
    response = "event: response.failed\n" .. terminal() .. "\nSTRAPS_HTTP:200"
    assert.has_error(function() send(adapter) end)
    assert.equals(1, calls)
  end)
  it("rejects an unterminated event frame", function()
    local adapter = assert(construct(config()))
    response = terminal():gsub("\n\n$", "") .. "\nSTRAPS_HTTP:200"
    assert.has_error(function() send(adapter) end)
    assert.equals(1, calls)
  end)
  it("rejects unknown events even with a completed terminal", function()
    local adapter = assert(construct(config()))
    response = event({ type = "response.unexpected", delta = "ignored" }) .. terminal() .. "\nSTRAPS_HTTP:200"
    assert.has_error(function() send(adapter) end, nil, "unknown event must fail closed")
  end)
  for _, framing in ipairs({ "\n", "\r\n" }) do
    it("rejects unknown event-only frames before a named terminal with " .. vim.inspect(framing), function()
      local adapter = assert(construct(config()))
      local stream = "event: response.unexpected\n\n" .. "event: response.completed\n" .. terminal()
      response = stream:gsub("\n", framing) .. "\nSTRAPS_HTTP:200"
      assert.has_error(function() send(adapter) end, "incomplete contextual event", "event-only frame must not be overwritten")
      assert.equals(1, calls)
    end)
  end
  for _, change in ipairs({
    { "revision", function(c) c.disclosure_revision = "replacement" end },
    { "denial callback", function(c) c.disclosure_approved = function() return false end end },
    { "session", function(c) c.session = 8 end },
    { "selection", function(c) c.provider_config.openai_model = "changed" end },
    { "resolved model", function() selected_model = "changed" end },
    { "backend", function() entries["fn.provider_openai"].identity = 3 end },
    { "authentication definition", function() entries["fn.openai_api_key"].identity = "changed" end },
    { "TLS", function() write(tmp .. "/ca", "changed CA") end },
  }) do
    it("invalidates " .. change[1] .. " before reading credentials", function()
      local c = config()
      local adapter = assert(construct(c))
      change[2](c)
      credential_reads = 0
      local identity = adapter.resolve_identity()
      local ok = pcall(send, adapter)
      entries["fn.openai_api_key"].identity = "fn.openai_api_key"
      assert.equals(0, credential_reads, "invalidated " .. change[1] .. " must read zero credentials")
      assert.is_nil(identity)
      assert.is_false(ok)
      assert.equals(0, calls, "invalidated " .. change[1] .. " must dispatch zero requests")
    end)
  end
  for _, change in ipairs({
    { "authentication route", function() package.loaded["straps.provider"].slot.key_fn = "fn.other_key" end },
    { "configuration", function(c) c.provider_config.openai_model = "changed" end },
    { "revision", function(c) c.disclosure_revision = "replacement" end },
    { "authentication definition", function() entries["fn.openai_api_key"].identity = "changed" end },
  }) do
    it("revalidates " .. change[1] .. " after credential-level approval", function()
      local c, armed, approvals = config(), false, 0
      c.disclosure_approved = function()
        if armed then
          approvals = approvals + 1
          if approvals == 2 then change[2](c) end
        end
        return true
      end
      local adapter = assert(construct(c))
      armed, credential_reads = true, 0
      local identity = adapter.resolve_identity()
      local reads = credential_reads
      local ok = pcall(send, adapter)
      package.loaded["straps.provider"].slot.key_fn = "fn.openai_api_key"
      entries["fn.openai_api_key"].identity = "fn.openai_api_key"
      assert.equals(0, reads, "credential-level approval mutation must precede credential reads")
      assert.equals(0, credential_reads, "stale approval must read zero credentials")
      assert.is_nil(identity)
      assert.is_false(ok)
      assert.equals(0, calls, "credential-level approval mutation must dispatch zero requests")
    end)
  end
  local function pending(adapter)
    deferred = true
    local state = { cancelled = false, resolutions = 0, outcome = nil, handler = nil }
    local thread
    local context = {
      cancelled = function() return state.cancelled end,
      on_cancel = function(fn) state.handler = fn end,
      await = function(start)
        start(function(value)
          state.resolutions = state.resolutions + 1
          if coroutine.status(thread) == "suspended" then
            assert(coroutine.resume(thread, value))
          else
            state.immediate = value
          end
        end)
        if state.immediate then return state.immediate end
        return coroutine.yield()
      end,
    }
    thread = coroutine.create(function() state.outcome = { pcall(adapter.transport, request(adapter), context) } end)
    assert(coroutine.resume(thread))
    state.thread = thread
    return state
  end
  it("cancels a suspended request once and ignores late duplicate completions", function()
    local state = pending(assert(construct(config())))
    assert.equals("suspended", coroutine.status(state.thread))
    assert.is_function(state.handler)
    state.cancelled = true
    state.handler(); state.handler()
    assert.same({ 9 }, process.kills, "cancel must kill the process once with SIGKILL")
    assert.equals(1, state.resolutions, "cancel must resolve the suspended await once")
    assert.equals("dead", coroutine.status(state.thread))
    assert.is_false(state.outcome[1], "cancel must never return an accepted result")
    process.stdout(nil, response); process.done({ code = 0 }); process.done({ code = 0 })
    assert.equals(1, state.resolutions, "late callbacks must not resolve again")
    assert.equals(1, calls, "cancel must not retry")
  end)
  it("kills cancellation observed before process assignment once", function()
    local adapter = assert(construct(config()))
    local cancelled = false
    deferred = true
    before_dispatch = function() cancelled = true end
    local resolutions = 0
    local context = { cancelled = function() return cancelled end, on_cancel = function() end,
      await = function(start) local value; start(function(v) resolutions = resolutions + 1; value = v end); return value end }
    assert.has_error(function() adapter.transport(request(adapter), context) end)
    assert.same({ 9 }, process.kills)
    assert.equals(1, resolutions, "preassignment cancellation must resolve once")
    process.done({ code = 0 })
    assert.equals(1, resolutions)
    assert.equals(1, calls)
  end)
  for _, failure in ipairs({ "overflow", "stdout" }) do
    it("terminates suspended " .. failure .. " once without accepting late success", function()
      local state = pending(assert(construct(config())))
      if failure == "overflow" then process.stdout(nil, string.rep("x", 8193)) else process.stdout("offline read error", nil) end
      assert.same({ 9 }, process.kills)
      assert.equals(1, state.resolutions)
      assert.equals("dead", coroutine.status(state.thread))
      assert.is_false(state.outcome[1])
      process.stdout(nil, response); process.done({ code = 0 }); process.done({ code = 0 })
      assert.equals(1, state.resolutions)
      assert.equals(1, calls)
    end)
  end
  it("accepts a deferred successful completion once", function()
    local state = pending(assert(construct(config())))
    process.stdout(nil, response); process.done({ code = 0 })
    assert.equals("dead", coroutine.status(state.thread))
    assert.is_true(state.outcome[1])
    assert.equals("{}", state.outcome[2].text)
    process.done({ code = 0 })
    state.handler()
    assert.equals(1, state.resolutions)
    assert.same({}, process.kills)
    assert.equals(1, calls)
  end)
  for _, failure in ipairs({ "spawn", "stdout", "exit", "missing trailer", "corrupt trailer" }) do
    it("refuses " .. failure .. " without retry", function()
      local adapter = assert(construct(config()))
      if failure == "spawn" then spawn_error = true
      elseif failure == "stdout" then stdout_error = "offline stdout error"
      elseif failure == "exit" then code = 23
      elseif failure == "missing trailer" then response = terminal()
      else response = terminal() .. "\nSTRAPS_HTTP:2xx" end
      assert.has_error(function() send(adapter) end)
      assert.equals(1, calls)
    end)
  end
  for _, failure in ipairs({ "permissions", "oversize", "malformed", "open", "read", "inode", "device", "size", "mtime", "ctime", "mode" }) do
    it("refuses credential " .. failure .. " without dispatch", function()
      local path = tmp .. "/openai_oauth.json"
      write(path, vim.json.encode({ access = "offline-token", expires = 9999999999999 }))
      local reads = 0
      vim.uv.fs_open = function(p, ...) if p == path then reads = reads + 1 end; return original_fs_open(p, ...) end
      if failure == "permissions" then vim.fn.setfperm(path, "rw-r--r--")
      elseif failure == "oversize" then write(path, string.rep("x", 65537))
      elseif failure == "malformed" then write(path, "{")
      elseif failure == "open" then
        local open = vim.uv.fs_open
        vim.uv.fs_open = function(p, ...) if p == path then return nil, "offline open error" end; return open(p, ...) end
      else
        local fd, changed = nil, false
        local open = vim.uv.fs_open
        vim.uv.fs_open = function(p, ...) local value = open(p, ...); if p == path then fd = value end; return value end
        vim.uv.fs_read = function(handle, ...)
          if handle == fd then changed = true; if failure == "read" then return nil, "offline read error" end end
          return original_fs_read(handle, ...)
        end
        vim.uv.fs_stat = function(p, ...)
          local stat = original_fs_stat(p, ...)
          if p == path and changed and stat then
            stat = vim.deepcopy(stat)
            if failure == "inode" then stat.ino = stat.ino + 1
            elseif failure == "device" then stat.dev = stat.dev + 1
            elseif failure == "size" then stat.size = stat.size + 1
            elseif failure == "mode" then stat.mode = stat.mode + 4
            elseif failure == "mtime" or failure == "ctime" then stat[failure].nsec = stat[failure].nsec + 1 end
          end
          return stat
        end
      end
      local adapter = construct(config())
      vim.uv.fs_open, vim.uv.fs_read, vim.uv.fs_stat = original_fs_open, original_fs_read, original_fs_stat
      assert.is_nil(adapter, "credential " .. failure .. " must refuse construction")
      if failure == "permissions" or failure == "oversize" then assert.equals(0, reads, "unsafe credential metadata must prevent reads") end
      assert.equals(0, calls)
    end)
  end
  it("requires exact tool-free request and never sends acting fields", function()
    local adapter = assert(construct(config()))
    local r = request(adapter); r.system = "acting instructions"
    assert.has_error(function() adapter.transport(r, ctx) end)
    r = request(adapter); r.tools = { "bash" }
    assert.has_error(function() adapter.transport(r, ctx) end)
    assert.equals(0, calls)
  end)
end)
