local counterfactual = vim.env.STRAPS_CONTEXT_QUALITY_COUNTERFACTUAL
if counterfactual then
  local original_assert = assert
  assert = function(condition, message, ...)
    if message == counterfactual then return original_assert(not condition, "counterfactual assertion: " .. message) end
    return original_assert(condition, message, ...)
  end
end
local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(vim.fn.fnamemodify(here, ":p"), ":h:h")
local usage = "usage: nvim --headless -u NONE -l tests/context_quality_eval.lua --self-test | --dry-run --output NEW_DIRECTORY | --live --runfile EXPLICIT.lua --output NEW_DIRECTORY"
local function arguments(args, env, reserve)
  local options = {}
  local i = 1
  while i <= #args do
    local key = args[i]
    if key == "--self-test" or key == "--dry-run" or key == "--live" then
      assert(not options.mode, usage)
      options.mode = key:sub(3)
    elseif key == "--output" or key == "--runfile" then
      assert(args[i + 1] and not options[key:sub(3)], usage)
      options[key:sub(3)] = args[i + 1]
      i = i + 1
    else
      error(usage, 0)
    end
    i = i + 1
  end
  assert(options.mode, usage)
  if options.mode == "live" then
    assert(env == "1", "live refused: set STRAPS_CONTEXT_QUALITY_LIVE=1")
    assert(options.runfile and options.output, "live refused: explicit runfile and exclusive output required")
  else
    assert(not options.runfile, "offline modes refuse runfiles")
    if options.mode == "dry-run" then assert(options.output, usage) end
  end
  if options.output then reserve(options.output) end
  return options
end
local function reserve(path)
  local ok, err = vim.uv.fs_mkdir(vim.fn.fnamemodify(path, ":p"), 448)
  assert(ok, "output must be a new directory: " .. tostring(err))
end
local options = arguments(arg, vim.env.STRAPS_CONTEXT_QUALITY_LIVE, reserve)
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
local corpus = dofile(root .. "/tests/fixtures/context_quality/corpus.lua")
local offline = options.mode ~= "live"
local fault = offline and vim.env.STRAPS_CONTEXT_QUALITY_OFFLINE_FAULT or nil
if offline then vim.env.XDG_CONFIG_HOME = vim.fn.tempname() end
local settings
if offline then
  settings = { provider = "llamacpp", model = "quality-offline-model", route = "llamacpp", trials = 1,
    max_dispatches = 256, timeout_ms = 10000, max_output_tokens = 2048,
    summary = { max_input_tokens = 100000, max_output_tokens = 2048, max_total_tokens = 1000000, max_calls = 64, max_depth = 8 },
    input_limit = 200000, configure = function() end }
else
  settings = assert(dofile(options.runfile), "runfile must return settings")
end
local function integer(n, upper)
  return type(n) == "number" and n > 0 and n % 1 == 0 and n <= upper
end
assert(type(settings) == "table" and type(settings.configure) == "function", "runfile requires configure function")
assert(({ anthropic = true, openai = true, llamacpp = true })[settings.provider], "explicit known provider required")
assert(type(settings.model) == "string" and settings.model ~= "" and type(settings.route) == "string", "explicit model and route required")
for key, upper in pairs({ trials = 100, max_dispatches = 10000, timeout_ms = 3600000, max_output_tokens = 65536, input_limit = 1048576 }) do
  assert(integer(settings[key], upper), "invalid explicit setting: " .. key)
end
assert(type(settings.summary) == "table", "explicit summary caps required")
for key, upper in pairs({ max_input_tokens = 1048576, max_output_tokens = 65536, max_total_tokens = 4194304, max_calls = 256, max_depth = 16 }) do
  assert(integer(settings.summary[key], upper), "invalid explicit summary cap: " .. key)
end
local straps = require("straps")
if fault == "deadline" then settings.timeout_ms = 75 end
settings.configure(straps)
straps.config.provider = settings.provider
straps.config[({ anthropic = "model", openai = "openai_model", llamacpp = "llamacpp_model" })[settings.provider]] = settings.model
straps.config.gzip = false
straps.config.max_tokens = settings.max_output_tokens
straps.config.request_timeout_ms = settings.timeout_ms
straps.config.session_dir = options.output and options.output .. "/sessions" or vim.fn.tempname()
straps.config.context_management = { enabled = true, mode = "mechanical", input_limit = settings.input_limit,
  reserve_tokens = 16000, target = 0.99, minimum_savings = 1, keep_turns = 1, summary = settings.summary }
local registry = require("straps.registry")
local provider = require("straps.provider")
provider.register()
require("straps.layers.session").register()
local state = require("straps.state")
local management = require("straps.context_management")
local archive = require("straps.context_archive")
local original_call, original_system = registry.call, vim.system
local records, transports, results, preflights, attempts = {}, {}, {}, {}, {}
local active_case, active_arm, active_trial, forced_omission
local phase, active_dispatch = "prepare", nil
local secrets = {}
local function sanitize(value)
  if type(value) == "table" then
    local out = {}
    for key, item in pairs(value) do
      if type(key) == "string" and (key:lower() == "access" or key:lower() == "refresh" or key:lower():match("token") and not key:match("tokens")
        or key:lower():match("secret") or key:lower():match("api_key") or key:lower():match("authorization") or key:lower():match("password")) then
        out[key] = "[REDACTED]"
      else out[key] = sanitize(item) end
    end
    return out
  end
  if type(value) ~= "string" then return value end
  for secret in pairs(secrets) do value = value:gsub(secret:gsub("([^%w])", "%%%1"), "[REDACTED]") end
  return value:gsub("Bearer%s+[^%s\"']+", "Bearer [REDACTED]")
end
local processes, transport_closed, deadline_exceeded = {}, false, false
local started = vim.uv.hrtime()
local function close_transport()
  transport_closed = true
  for process in pairs(processes) do pcall(process.kill, process, 9) end
end
local function failure_category()
  return deadline_exceeded and "deadline_exceeded" or "evaluation_failed"
end
local function save(name, value)
  if not options.output then return end
  local text = type(value) == "string" and sanitize(value) or vim.json.encode(sanitize(value))
  local fd = assert(vim.uv.fs_open(options.output .. "/" .. name, "wx", 384))
  assert(vim.uv.fs_write(fd, text, 0))
  assert(vim.uv.fs_close(fd))
end
local function elapsed()
  return (vim.uv.hrtime() - started) / 1000000
end
local function context(b, clock, wait, deadline)
  local callbacks = {}
  clock, wait, deadline = clock or elapsed, wait or vim.wait, deadline or settings.timeout_ms
  local function expired() return clock() >= deadline end
  return { bufnr = b, cancelled = expired,
    emit = function() end, on_cancel = function(callback) callbacks[#callbacks + 1] = callback end,
    await = function(start)
      if expired() then
        deadline_exceeded = true
        close_transport()
        for _, callback in ipairs(callbacks) do pcall(callback) end
        error("evaluation deadline exceeded", 0)
      end
      local done, value = false, nil
      start(function(result) if not done then value, done = result, true end end)
      local remaining = math.max(1, deadline - clock())
      if not wait(remaining, function() return done end, 5) then
        deadline_exceeded = true
        close_transport()
        for _, callback in ipairs(callbacks) do pcall(callback) end
        error("evaluation deadline exceeded", 0)
      end
      return value
    end }
end
local identity = {}
for _, name in ipairs({ "fn.provider", "fn.provider_anthropic", "fn.provider_openai", "fn.provider_llamacpp", "fn.anthropic_messages", "fn.context_summarize" }) do
  identity[name] = registry.get(name)
end
if offline then
  for _, name in ipairs({ "fn.llamacpp_api_key", "fn.anthropic_api_key", "fn.openai_api_key" }) do
    registry.define({ name = name, kind = "fn", source = 'return function() return "offline-not-a-credential", "env" end' })
  end
end
local retrieval = assert(registry.get("tool.context_retrieve"))
local tools = { { name = "context_retrieve", description = retrieval.doc, input_schema = retrieval.input_schema } }
local function request(b)
  local parsed = state.parse(b)
  return { system = parsed.system, messages = parsed.messages, tools = vim.deepcopy(tools), context_max_output = settings.max_output_tokens }
end
local function validate(prepared, cap)
  assert(prepared.provider == settings.provider and prepared.model == settings.model, "prepared provider/model mismatch")
  assert(prepared.route == settings.route and prepared.route ~= "codex", "prepared route mismatch or unsupported Codex cap")
  assert(integer(prepared.output_reserve, 65536) and prepared.output_reserve == cap, "unknown or mismatched output cap")
end
local function prepare(req, ctx, cap)
  local previous = phase
  phase = "prepare"
  if fault == "preflight" then error("raw-preflight-sentinel") end
  local prepctx = setmetatable({ context_prepare = true, context_isolated = true }, { __index = ctx })
  local ok, prepared = pcall(original_call, "fn.provider", req, prepctx)
  phase = previous
  if not ok then error(prepared, 0) end
  validate(prepared, cap)
  return prepared
end
registry.call = function(name, ...)
  local args = { ... }
  if name:match("api_key$") then
    local key, source, account = original_call(name, ...)
    if type(key) == "string" and key ~= "" then secrets[key] = true end
    return key, source, account
  end
  if name ~= "fn.provider" or (args[2] and args[2].context_prepare) then return original_call(name, ...) end
  assert(#records < settings.max_dispatches and elapsed() <= settings.timeout_ms, "evaluation dispatch/time cap exhausted")
  local record = { case = active_case.id, arm = active_arm, trial = active_trial, request = vim.deepcopy(args[1]),
    isolated = args[2].context_isolated == true, started_ms = elapsed() }
  records[#records + 1] = record
  local index = #records
  local ok, result = pcall(function()
    record.prepared = prepare(args[1], args[2], args[1].context_max_output or settings.max_output_tokens)
    phase, active_dispatch = "dispatch", index
    return original_call(name, unpack(args))
  end)
  phase, active_dispatch = "prepare", nil
  record.elapsed_ms = elapsed() - record.started_ms
  if ok then record.response = vim.deepcopy(result) else record.error = failure_category() end
  save(("request-%04d.json"):format(index), record)
  if not ok then error(result, 0) end
  return result
end
local function fake_reply(body)
  local last = body.messages[#body.messages]
  local text = type(last.content) == "table" and last.content[1] and last.content[1].text
  if body.system and vim.json.encode(body.system):find("Summarize only", 1, true) then
    local sources = vim.json.decode(text)
    local refs = {}
    for _, source in ipairs(sources) do refs[#refs + 1] = source.ref end
    return { { type = "text", text = vim.json.encode({ summary = forced_omission and "Evidence omitted; recover original archive." or active_case.summary,
      complete = true, source_refs = refs }) } }, "end_turn"
  end
  local serialized = vim.json.encode(body.messages)
  local key = active_case.expected.facts.ticket or active_case.expected.facts.identifier
  if not serialized:find(key, 1, true) then
    local id = serialized:match("straps%-context:([0-9a-f]+)")
    assert(id, "fake continuation cannot find archive receipt")
    local listings, retrieved, children = {}, {}, { id }
    for _, message in ipairs(body.messages) do
      for _, part in ipairs(type(message.content) == "table" and message.content or {}) do
        if part.type == "tool_result" then
          local content = type(part.content) == "string" and part.content or vim.json.encode(part.content)
          local metadata = content:match("\n({[^\n]+})")
          if metadata then
            local value = vim.json.decode(metadata)
            if value.sources then
              listings[value.id] = value.sources
              for _, child in ipairs(value.children or {}) do children[#children + 1] = child end
            elseif value.source_index then
              retrieved[value.id .. ":" .. value.source_index] = true
            end
          end
        end
      end
    end
    local selected, index
    for _, candidate in ipairs(children) do
      if not listings[candidate] then selected = candidate; break end
      for _, source in ipairs(listings[candidate]) do
        if not retrieved[candidate .. ":" .. source.index] then selected, index = candidate, source.index; break end
      end
      if selected then break end
    end
    assert(selected, "fake recovery exhausted archive graph")
    return { { type = "tool_use", id = "retrieve-" .. #transports, name = "context_retrieve", input = { id = selected, source_index = index, limit = 4096 } } }, "tool_use"
  end
  return { { type = "text", text = vim.json.encode(active_case.expected) } }, "end_turn"
end
if offline then
  vim.system = function(argv, opts, done)
    assert(argv[1] == "curl", "offline transport refuses every non-curl process")
    if not opts.stdout then
      if argv[#argv] == "spawn-unknown" then error("raw-spawn-sentinel") end
      vim.schedule(function()
        done({ code = 0, stdout = vim.json.encode({ access_token = "raw-access-sentinel", refresh_token = "raw-refresh-sentinel",
          id_token = "raw-id-sentinel", access = "raw-access-field-sentinel", refresh = "raw-refresh-field-sentinel" }) .. "\nSTRAPS_HTTP_STATUS:200\n",
          stderr = "raw-stderr-sentinel" })
      end)
      return { kill = function() end }
    end
    local body = vim.json.decode(opts.stdin)
    transports[#transports + 1] = body
    if fault == "dispatch" then error("raw-dispatch-sentinel") end
    if fault == "deadline" then return { kill = function() end } end
    local content, stop = fake_reply(body)
    vim.schedule(function()
      local function event(value) opts.stdout(nil, "data: " .. vim.json.encode(value) .. "\n\n") end
      event({ type = "message_start", message = { usage = { input_tokens = 7, output_tokens = 0 } } })
      for i, part in ipairs(content) do
        event({ type = "content_block_start", index = i - 1, content_block = part })
        if part.type == "tool_use" then
          event({ type = "content_block_delta", index = i - 1, delta = { type = "input_json_delta", partial_json = vim.json.encode(part.input) } })
        end
        event({ type = "content_block_stop", index = i - 1 })
      end
      event({ type = "message_delta", delta = { stop_reason = stop }, usage = { output_tokens = 3 } })
      event({ type = "message_stop" })
      done({ code = 0, stderr = "STRAPS_HTTP_STATUS:200\n" })
    end)
    return { kill = function() end }
  end
end
local function generation_transport(argv, route)
  if argv[1] ~= "curl" then return false end
  local url, method
  for i, item in ipairs(argv) do
    if item == "-X" or item == "--request" then method = argv[i + 1] end
    if item:match("^https?://") then
      if url then return false end
      url = item
    end
  end
  if method ~= "POST" or not url or url:find("[?#]") then return false end
  local base = provider.base_url(settings.provider, straps.config)
  if not base then return false end
  if (route == "anthropic" and settings.provider == "anthropic") or (route == "llamacpp" and settings.provider == "llamacpp") then
    return url == base .. "/v1/messages"
  end
  if settings.provider == "openai" and (route == "env" or route == "stored" or route == "oauth") then
    return url == base .. "/v1/responses"
  end
  return false
end
local function collect_credentials(value)
  if type(value) ~= "table" then return end
  for key, item in pairs(value) do
    if type(key) == "string" and (key:lower():find("token", 1, true) or key == "access" or key == "refresh"
      or key:lower():find("secret", 1, true) or key == "api_key") and type(item) == "string" and item ~= "" then
      secrets[item] = true
    elseif type(item) == "table" then collect_credentials(item) end
  end
end
local function instrument_transport(system, route, clock)
  clock = clock or elapsed
  return function(argv, opts, done)
    if transport_closed or clock() >= settings.timeout_ms then
      if clock() >= settings.timeout_ms then deadline_exceeded = true end
      close_transport()
      error("evaluation transport closed", 0)
    end
    opts = opts or {}
    local generation = generation_transport(argv, route)
    for i, item in ipairs(argv) do
      if item == "-H" or item == "--header" then
        local key, value = (argv[i + 1] or ""):match("^([^:]+):%s*(.*)$")
        if key and (key:lower() == "authorization" or key:lower() == "x-api-key") and value ~= "" then
          secrets[value] = true
          local bearer = value:match("^[Bb]earer%s+(.+)$")
          if bearer then secrets[bearer] = true end
        end
      end
    end
    if not generation and type(opts.stdin) == "string" then
      local parsed, body = pcall(vim.json.decode, opts.stdin)
      if parsed then collect_credentials(body) else collect_credentials(require("straps.oauth").parse_query(opts.stdin)) end
    end
    local attempt = { kind = generation and "generation" or "authentication_or_other", phase = phase,
      dispatch = active_dispatch, started_ms = elapsed(), completed = false }
    attempts[#attempts + 1] = attempt
    local index, handle = #attempts, nil
    local ok, process = pcall(system, argv, opts, function(result)
      if handle then processes[handle] = nil end
      attempt.completed = true
      for _, key in ipairs({ "code", "signal" }) do if type(result[key]) == "number" then attempt[key] = result[key] end end
      attempt.elapsed_ms = elapsed() - attempt.started_ms
      attempt.http_status = tonumber(((result.stderr or "") .. "\n" .. (result.stdout or "")):match("STRAPS_HTTP_STATUS:(%d%d%d)"))
      if not generation and type(result.stdout) == "string" then
        local payload = result.stdout:gsub("%s*STRAPS_HTTP_STATUS:%d+%s*$", "")
        local parsed, body = pcall(vim.json.decode, payload)
        if parsed then collect_credentials(body) end
      end
      if not transport_closed then save(("attempt-%04d.json"):format(index), attempt) end
      if done then done(result) end
    end)
    if not ok then
      attempt.spawn_failed, attempt.completed, attempt.elapsed_ms = true, true, elapsed() - attempt.started_ms
      save(("attempt-%04d.json"):format(index), attempt)
      error("transport spawn failed", 0)
    end
    handle = process
    if not attempt.completed then processes[process] = true end
    local kill = process.kill
    process.kill = function(self, signal)
      if attempt.killed then return end
      attempt.killed = true
      processes[self] = nil
      attempt.elapsed_ms = elapsed() - attempt.started_ms
      return kill(self, signal)
    end
    return process
  end
end
vim.system = instrument_transport(vim.system, settings.route)
local function fixture(case)
  local b = vim.api.nvim_create_buf(false, true)
  state.append(b, "system", nil, corpus.system)
  state.append(b, "user", nil, case.user)
  state.append(b, "assistant", nil, case.assistant)
  state.append(b, "tool_use", { id = "evidence", name = "read_file" }, '{"path":"synthetic-evidence"}')
  state.append(b, "tool_result", { id = "evidence", is_error = true }, case.evidence)
  state.append(b, "user", nil, case.correction)
  state.append(b, "assistant", nil, "Audit remains blocked pending evidence.")
  state.append(b, "user", nil, "Continue the audit with the exact JSON schema requested above.")
  return b
end
local function score(text, case, violations, complete)
  local ok, value = pcall(vim.json.decode, text)
  local result = { valid_json = ok and type(value) == "table", facts = {}, provenance = {}, forbidden_actions = violations,
    completion = false, extra_keys = false }
  if not result.valid_json then return result end
  for key, expected in pairs(case.expected.facts) do result.facts[key] = type(value.facts) == "table" and value.facts[key] == expected end
  for key, expected in pairs(case.expected.provenance) do result.provenance[key] = type(value.provenance) == "table" and value.provenance[key] == expected end
  result.completion = complete and value.completion == case.expected.completion
  if type(value.actions) ~= "table" or not vim.islist(value.actions) or next(value.actions) ~= nil then result.forbidden_actions = violations + 1 end
  for key in pairs(value) do if not case.expected[key] then result.extra_keys = true end end
  for _, group in ipairs({ "facts", "provenance" }) do
    for key in pairs(type(value[group]) == "table" and value[group] or {}) do
      if case.expected[group][key] == nil then result.extra_keys = true end
    end
  end
  result.pass = result.completion and result.forbidden_actions == 0 and not result.extra_keys
  for _, group in ipairs({ result.facts, result.provenance }) do for _, match in pairs(group) do result.pass = result.pass and match end end
  result.pass = result.pass == true
  return result
end
local function transform(b, ctx, arm, case)
  if arm == "baseline" then return end
  local cfg = vim.deepcopy(straps.config.context_management)
  cfg.mode = arm == "mechanical" and "mechanical" or "summary"
  vim.b[b].straps_context_management = cfg
  local report = management.preview(b, ctx, { generate = true, tools = tools })
  management.apply(b, ctx, report)
  assert(vim.b[b].straps_context_compaction.status == "applied", "production transformation did not apply")
  local first = vim.b[b].straps_context_compaction.archives[1]
  if case.repeated and cfg.mode == "summary" then
    local block = state.list_blocks(b)[3]
    vim.api.nvim_buf_set_lines(b, block.last_lnum, block.last_lnum, false, { string.rep("additional synthetic evidence ", 600) })
    report = management.preview(b, ctx, { generate = true, tools = tools })
    management.apply(b, ctx, report)
    local second = vim.b[b].straps_context_compaction.archives[1]
    assert(first ~= second and vim.tbl_contains(assert(archive.list(b, second, 1, 100)).children, first), "second archive must be a child-of-first summary merge")
  end
end
local function continuation(b, ctx)
  local violations, pages = 0, 0
  for _ = 1, settings.max_dispatches do
    local req = request(b)
    management.check(prepare(req, ctx, settings.max_output_tokens), ctx)
    local pending = assert(management.snapshot_pending(b))
    local response = registry.call("fn.provider", req, ctx)
    local complete = response.complete == true and (response.stop_reason == "end_turn" or response.stop_reason == "tool_use") and not ctx.cancelled()
    if complete then assert(management.consume_pending(pending, ctx).status == "committed_live", "consume failed") end
    local texts, calls = {}, {}
    for _, part in ipairs(response.content or {}) do
      if part.type == "tool_use" then calls[#calls + 1] = part
      elseif part.type == "text" then texts[#texts + 1] = part.text end
    end
    if #calls == 0 then return table.concat(texts), violations, complete, pages end
    if not complete then return table.concat(texts), violations + 1, false, pages end
    for _, call in ipairs(calls) do
      state.append(b, "tool_use", { id = call.id, name = call.name }, vim.json.encode(call.input))
      if call.name ~= "context_retrieve" then
        violations = violations + 1
        state.append(b, "tool_result", { id = call.id, is_error = true }, "FORBIDDEN: runner never executes this action")
      else
        local ok, value = pcall(registry.call, "tool.context_retrieve", call.input, ctx)
        if ok then
          assert(management.append_result(b, { id = call.id }, value, ctx).status == "committed_live", "append_result failed")
          pages = pages + 1
        else
          management.release(b)
          state.append(b, "tool_result", { id = call.id, is_error = true }, "retrieval_failed")
        end
      end
    end
  end
  error("continuation dispatch cap exhausted", 0)
end
local function auth_checks()
  local callback_done, callback_payload
  original_call("fn.openai_oauth_post", "refresh_token=outgoing-refresh-sentinel", function(payload)
    callback_payload, callback_done = payload, true
  end)
  assert(vim.wait(1000, function() return callback_done end), "OAuth callback absent")
  assert(callback_payload.access_token == "raw-access-sentinel" and callback_payload.refresh_token == "raw-refresh-sentinel"
    and callback_payload.id_token == "raw-id-sentinel", "OAuth callback payload changed")
  local before = #attempts
  local system = vim.system
  local base = assert(provider.base_url(settings.provider, straps.config))
  for _, url in ipairs({ base .. "/token?next=/v1/messages", base .. "/v1/messages?token=unknown-query-sentinel",
    base .. "/v1/messages#fragment", "https://unknown.invalid/v1/messages" }) do
    local done
    system({ "curl", "-X", "POST", url, "--data-binary", "@-", "-H", "Authorization: Bearer outgoing-header-sentinel" },
      { stdin = "refresh_token=outgoing-refresh-sentinel" }, function() done = true end)
    assert(vim.wait(1000, function() return done end), "unknown transport callback absent")
    assert(attempts[#attempts].kind == "authentication_or_other", "unknown URL classified as generation")
  end
  assert(not pcall(system, { "curl", "spawn-unknown" }, {}, function() end), "unknown spawn failure accepted")
  assert(attempts[#attempts].spawn_failed and #attempts == before + 5, "unknown spawn metadata absent")
  local key_entry, refresh_entry = registry.get("fn.openai_api_key"), registry.get("fn.openai_oauth_refresh")
  registry.define({ name = "fn.openai_api_key", kind = "fn", source = 'return function() return "outgoing-header-sentinel", "oauth" end' })
  registry.define({ name = "fn.openai_oauth_refresh", kind = "fn", source = [[return function(_, done)
    require("straps.registry").call("fn.openai_oauth_post", "refresh_token=outgoing-refresh-sentinel", function(payload, err)
      done(payload and { access = payload.access_token, refresh = payload.refresh_token }, err)
    end)
  end]] })
  local generation_calls, auth_calls = 0, 0
  vim.system = instrument_transport(function(argv, opts, done)
    if not opts.stdout then
      auth_calls = auth_calls + 1
      return system(argv, opts, done)
    end
    generation_calls = generation_calls + 1
    vim.schedule(function()
      if generation_calls == 1 then done({ code = 0, stderr = "STRAPS_HTTP_STATUS:401" })
      else
        opts.stdout(nil, 'data: {"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":1,"output_tokens":1}}}\n\n')
        done({ code = 0, stderr = "STRAPS_HTTP_STATUS:200" })
      end
    end)
    return { kill = function() end }
  end, "oauth")
  local refreshed = original_call("fn.provider_openai", { system = "synthetic", messages = {}, tools = {} }, context(nil))
  vim.system = system
  registry.define(key_entry)
  registry.define(refresh_entry)
  assert(refreshed.complete and generation_calls == 2 and auth_calls == 1, "after401 OAuth callback absent")
  for _, secret in ipairs({ "raw-access-sentinel", "raw-refresh-sentinel", "raw-id-sentinel", "raw-access-field-sentinel",
    "raw-refresh-field-sentinel", "outgoing-header-sentinel", "outgoing-refresh-sentinel" }) do
    assert(sanitize(secret) == "[REDACTED]", "authentication credential collection absent")
  end
end
local function execute()
  if fault == "auth" then auth_checks() end
  for _, case in ipairs(corpus.cases) do
    active_case = case
    for _, arm in ipairs({ "baseline", "mechanical", "summary", "summary-recovery-only" }) do
      local b = fixture(case)
      local ctx = context(b)
      preflights[#preflights + 1] = prepare(request(b), ctx, settings.max_output_tokens)
      if arm:find("summary", 1, true) then
        local isolated = setmetatable({ context_isolated = true }, { __index = ctx })
        preflights[#preflights + 1] = prepare({ system = "Summarize only ordered synthetic source records.",
          messages = { { role = "user", content = { { type = "text", text = case.evidence } } } }, tools = {},
          context_max_output = settings.summary.max_output_tokens }, isolated, settings.summary.max_output_tokens)
      end
      vim.api.nvim_buf_delete(b, { force = true })
    end
  end
  save("preflight.json", preflights)
  for trial = 1, settings.trials do
    for _, case in ipairs(corpus.cases) do
      for _, arm in ipairs({ "baseline", "mechanical", "summary", "summary-recovery-only" }) do
        active_case, active_arm, active_trial = case, arm, trial
        forced_omission = arm == "summary-recovery-only"
        if forced_omission and not offline then
          results[#results + 1] = { case = case.id, arm = arm, trial = trial, skipped = "forced omission is offline recovery-only; excluded from fidelity" }
        else
          local b = fixture(case)
          local ctx, before = context(b), vim.api.nvim_buf_get_lines(b, 0, -1, false)
          local arm_started = elapsed()
          local ok, err = pcall(function()
            transform(b, ctx, arm, case)
            if arm == "baseline" then assert(vim.deep_equal(before, vim.api.nvim_buf_get_lines(b, 0, -1, false)), "baseline mutated") end
            save(case.id .. "-" .. arm .. "-" .. trial .. "-transformed.txt", table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n"))
            local answer, violations, complete, pages = continuation(b, ctx)
            local measured = score(answer, case, violations, complete)
            results[#results + 1] = { case = case.id, arm = arm, trial = trial, score = measured, retrieval_pages = pages,
              answer = answer, fidelity = not forced_omission, offline = offline }
          end)
          if not ok then results[#results + 1] = { case = case.id, arm = arm, trial = trial, error = failure_category(), offline = offline } end
          results[#results].elapsed_ms = elapsed() - arm_started
          save(case.id .. "-" .. arm .. "-" .. trial .. "-final.txt", table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n"))
          vim.api.nvim_buf_delete(b, { force = true })
        end
      end
    end
  end
end
local deadline_timer = assert(vim.uv.new_timer())
deadline_timer:start(math.max(1, settings.timeout_ms - elapsed()), 0, vim.schedule_wrap(function()
  deadline_exceeded = true
  close_transport()
end))
local ok, err = xpcall(execute, function() return failure_category() end)
close_transport()
deadline_timer:stop()
deadline_timer:close()
for index, attempt in ipairs(attempts) do
  if not attempt.completed then
    attempt.elapsed_ms = elapsed() - attempt.started_ms
    save(("attempt-%04d.json"):format(index), attempt)
  end
end
registry.call = original_call
vim.system = function(...)
  error("evaluation transport closed", 0)
end
save("corpus.json", corpus)
local experiment_failed = false
for _, result in ipairs(results) do
  if result.error or (result.score and not result.score.pass) then experiment_failed = true end
end
local missing = { input_tokens = 0, output_tokens = 0, cache_read_input_tokens = 0, cache_creation_input_tokens = 0 }
for _, record in ipairs(records) do
  for key in pairs(missing) do if not (record.response and record.response.usage and record.response.usage[key] ~= nil) then missing[key] = missing[key] + 1 end end
end
local hashes = { corpus = vim.fn.sha256(table.concat(vim.fn.readfile(root .. "/tests/fixtures/context_quality/corpus.lua"), "\n")),
  runner = vim.fn.sha256(table.concat(vim.fn.readfile(here), "\n")), provider = {} }
for name, entry in pairs(identity) do
  assert(vim.deep_equal(entry, registry.get(name)), "provider registry identity changed: " .. name)
  hashes.provider[name] = vim.fn.sha256(entry.source)
end
local serializable_settings = {}
for _, key in ipairs({ "provider", "model", "route", "trials", "max_dispatches", "timeout_ms", "max_output_tokens", "input_limit", "summary" }) do
  serializable_settings[key] = vim.deepcopy(settings[key])
end
local effective_config = { provider = straps.config.provider, max_tokens = straps.config.max_tokens,
  request_timeout_ms = straps.config.request_timeout_ms, context_management = vim.deepcopy(straps.config.context_management),
  effort = straps.config.effort, gzip = straps.config.gzip }
if options.runfile then hashes.runfile = vim.fn.sha256(table.concat(vim.fn.readfile(options.runfile), "\n")) end
for _, path in ipairs({ "context_management", "context_summary", "context_archive", "state", "registry" }) do
  hashes[path] = vim.fn.sha256(table.concat(vim.fn.readfile(root .. "/lua/straps/" .. path .. ".lua"), "\n"))
end
local totals = {}
for _, record in ipairs(records) do
  local key = record.case .. "/" .. record.arm .. "/" .. record.trial
  local total = totals[key] or { input_tokens = 0, output_tokens = 0, requests = 0 }
  totals[key], total.requests = total, total.requests + 1
  local usage = record.response and record.response.usage or {}
  total.input_tokens = total.input_tokens + (usage.input_tokens or 0) + (usage.cache_read_input_tokens or 0) + (usage.cache_creation_input_tokens or 0)
  total.output_tokens = total.output_tokens + (usage.output_tokens or 0)
end
save("report.json", { settings = serializable_settings, effective_config = effective_config, corpus_version = corpus.version, prompt_version = corpus.prompt_version,
  hashes = hashes, results = results, missing_usage_counts = missing, totals = totals, dispatches = #records,
  transport_attempts = attempts, elapsed_ms = elapsed(),
  offline = offline, quality_evidence = not offline and ok and not experiment_failed,
  pass = ok and not experiment_failed, error = not ok and failure_category() or nil })
if not ok then error(failure_category(), 0) end
if experiment_failed then error("evaluation failed; inspect report.json and raw artifacts", 0) end
if options.mode == "self-test" then
  local production_attempts = #attempts
  transport_closed = false
  local starts, kills, dispatched = 0, 0, false
  local guarded = instrument_transport(function()
    starts = starts + 1
    return { kill = function() kills = kills + 1 end }
  end, settings.route, function() return 0 end)
  local process = guarded({ "curl", "unknown" }, {})
  close_transport()
  process:kill(9)
  assert(starts == 1 and kills == 1, "tracked transport killed more than once")
  assert(not pcall(guarded, { "curl" }, {} ) and starts == 1, "transport started after teardown")
  transport_closed = false
  local expired = instrument_transport(function() starts = starts + 1 end, settings.route, function() return settings.timeout_ms end)
  assert(not pcall(expired, { "curl" }, {}) and starts == 1, "transport started after deadline")
  vim.defer_fn(function()
    dispatched = not pcall(vim.system, { "curl", "late-auth" }, {})
  end, 1)
  assert(vim.wait(1000, function() return dispatched end) and starts == 1, "deferred authentication escaped teardown guard")
  local now, remaining, killed = 25, nil, false
  local ctx = context(nil, function() return now end, function(ms) remaining = ms; now = 100; return false end, 100)
  ctx.on_cancel(function() killed = true end)
  assert(not pcall(ctx.await, function() end), "deadline did not fail")
  assert(remaining == 75, "await reset the remaining deadline")
  assert(killed and ctx.cancelled(), "deadline did not run cancellation callbacks")
  killed = false
  assert(not pcall(ctx.await, function() error("expired start executed") end) and killed, "expired await skipped cancellation")
  secrets["test-secret-credential"] = true
  assert(sanitize("Bearer test-secret-credential") == "Bearer [REDACTED]", "credential text escaped sanitization")
  assert(sanitize({ api_key = "test-secret-credential", access_token = "secret" }).access_token == "[REDACTED]", "credential field escaped sanitization")
  for _, record in ipairs(records) do assert(record.elapsed_ms >= 0, "dispatch timing absent") end
  for _, result in ipairs(results) do assert(result.elapsed_ms >= 0, "arm timing absent") end
  for index = 1, production_attempts do
    local attempt = attempts[index]
    assert(attempt.kind == "generation" and attempt.phase == "dispatch" and attempt.dispatch and attempt.completed and attempt.elapsed_ms >= 0,
      "transport attempt accounting absent")
  end
  for _, injected in ipairs({ "dispatch", "preflight", "deadline", "auth" }) do
    local output = vim.fn.tempname()
    local job = original_system({ vim.v.progpath, "--headless", "-u", "NONE", "-l", here, "--dry-run", "--output", output },
      { text = true, env = { STRAPS_CONTEXT_QUALITY_OFFLINE_FAULT = injected } }):wait(30000)
    assert((job.code == 0) == (injected == "auth"), "failed CLI returned success")
    local report = vim.json.decode(table.concat(vim.fn.readfile(output .. "/report.json"), "\n"))
    assert(report.quality_evidence == false and report.pass == (injected == "auth"), "partial run claimed quality evidence")
    assert(type(report.elapsed_ms) == "number", "total timing absent")
    for _, path in ipairs(vim.fn.glob(output .. "/**/*", false, true)) do
      if vim.fn.filereadable(path) == 1 then
        local artifact = table.concat(vim.fn.readfile(path), "\n")
        assert(not artifact:find("sentinel", 1, true), "raw authentication sentinel persisted")
      end
    end
    if injected == "auth" then
      for _, attempt in ipairs(report.transport_attempts) do
        for key, value in pairs(attempt) do
          assert(key == "kind" or key == "phase" or type(value) == "number" or type(value) == "boolean", "raw transport field persisted")
        end
      end
    elseif injected == "dispatch" then
      assert(#report.transport_attempts > 0 and report.transport_attempts[1].spawn_failed == true, "failed transport attempt omitted")
      assert(#report.results > 0 and report.results[1].error, "arm failure omitted")
    elseif injected == "deadline" then
      assert(#report.transport_attempts > 0 and report.transport_attempts[1].killed == true, "deadline failed to kill transport")
    else assert(report.error and #report.results == 0, "preflight failure omitted") end
    vim.fn.delete(output, "rf")
  end
  local reserved, config_ran = false, false
  local function forbidden() config_ran = true; error("must not run config") end
  for _, args in ipairs({ {}, { "--live" }, { "--live", "--runfile", "never.lua" }, { "--dry-run", "--runfile", "never.lua" } }) do
    assert(not pcall(arguments, args, nil, forbidden), "unsafe invocation accepted")
  end
  assert(not config_ran, "configuration ran before gate")
  assert(not pcall(arguments, { "--live", "--runfile", "never.lua", "--output", "exists" }, "1", function() reserved = true; error("exists") end))
  assert(reserved, "exclusive output was not checked")
  local sentinel = vim.fn.tempname()
  local runfile = vim.fn.tempname() .. ".lua"
  vim.fn.writefile({ 'vim.fn.writefile({"executed"}, ' .. string.format("%q", sentinel) .. '); error("runfile executed")' }, runfile)
  local config = vim.fn.tempname()
  vim.fn.mkdir(config .. "/nvim", "p")
  vim.fn.writefile({ 'vim.fn.writefile({"config executed"}, ' .. string.format("%q", sentinel) .. ')' }, config .. "/nvim/init.lua")
  for _, args in ipairs({ {}, { "--dry-run", "--runfile", runfile, "--output", vim.fn.tempname() } }) do
    local command = { vim.v.progpath, "--headless", "-u", "NONE", "-l", here }
    vim.list_extend(command, args)
    local job = original_system(command, { text = true, env = { XDG_CONFIG_HOME = config,
      STRAPS_CONTEXT_QUALITY_LIVE = args[#args] == config and "1" or "0" } }):wait(settings.timeout_ms)
    assert(job.code ~= 0 and not vim.uv.fs_stat(sentinel), "actual CLI executed config/runfile before refusal")
  end
  vim.fn.delete(runfile)
  vim.fn.delete(config, "rf")
  for _, result in ipairs(results) do assert(result.score and result.score.pass, vim.json.encode(result)) end
  assert(#transports == #records and #records > #results, "fake backend or actual transformations bypassed")
  for _, record in ipairs(records) do
    assert(record.prepared.provider == settings.provider and record.prepared.route == settings.route and record.prepared.model == settings.model)
    assert(record.response.complete == true)
    if record.isolated then assert(#record.request.tools == 0 and record.prepared.body.max_tokens == settings.summary.max_output_tokens) end
  end
  for _, case in ipairs(corpus.cases) do
    assert(score(vim.json.encode(case.expected), case, 0, true).pass)
    for _, group in ipairs({ "facts", "provenance" }) do
      for key in pairs(case.expected[group]) do
        local changed = vim.deepcopy(case.expected)
        changed[group][key] = "wrong"
        assert(not score(vim.json.encode(changed), case, 0, true).pass, group .. "/" .. key .. " escaped rubric")
      end
    end
    local changed = vim.deepcopy(case.expected)
    changed.completion = "done"
    assert(not score(vim.json.encode(changed), case, 0, true).pass, "completion escaped rubric")
    changed = vim.deepcopy(case.expected)
    changed.actions = { "deploy" }
    assert(not score(vim.json.encode(changed), case, 0, true).pass, "reported action escaped rubric")
    assert(not score(vim.json.encode(case.expected), case, 1, true).pass, "forbidden tool escaped rubric")
    assert(not score(vim.json.encode(case.expected), case, 0, false).pass, "incomplete response escaped rubric")
    assert(not score("not json", case, 0, true).pass, "invalid JSON escaped rubric")
  end
  for _, change in ipairs({ function(p) p.route = "codex" end, function(p) p.route = "unknown" end,
    function(p) p.model = "other" end, function(p) p.provider = "other" end,
    function(p) p.output_reserve = nil end, function(p) p.output_reserve = settings.max_output_tokens + 1 end }) do
    local prepared = vim.deepcopy(preflights[1])
    change(prepared)
    assert(not pcall(validate, prepared, settings.max_output_tokens), "bad prepared route/cap accepted")
  end
  print("context quality self-test passed; fake transport only; no behavioral model-quality evidence")
else
  print("context quality " .. options.mode .. " artifacts: " .. options.output)
end
