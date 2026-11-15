local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(vim.fn.fnamemodify(here, ":p"), ":h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
vim.env.XDG_CONFIG_HOME = vim.fn.tempname()
local straps = require("straps").setup({ gzip = false, llamacpp_model = "test-model", context_management = { input_limit = 100000 } })
local registry = require("straps.registry")
for _, name in ipairs({ "anthropic", "openai", "llamacpp" }) do
  registry.define({ name = "fn." .. name .. "_api_key", kind = "fn", source = [[return function() return "test-key", "env" end]] })
end
local buf = vim.api.nvim_create_buf(false, true)
local anthropic = { type = "error", error = { type = "invalid_request_error", message = "prompt is too long: 101 tokens > 100 maximum" } }
local openai = { error = { code = "context_length_exceeded", message = "input exceeds context" } }

local function invoke(backend, attempts, options)
  options = options or {}
  local original, defer, new_timer = vim.system, vim.defer_fn, vim.uv.new_timer
  local calls, cancelled, watchdog, late_stdout = 0, false, nil, nil
  vim.uv.new_timer = function()
    local timer = { stop = function() end, close = function() end }
    timer.start = function(_, _, _, callback) timer.callback = callback end
    watchdog = timer
    return timer
  end
  straps.config.context_management.enabled = options.enabled == true
  vim.b[buf].straps_context_management = options.override
  vim.defer_fn = function(callback) vim.schedule(callback) end
  vim.system = function(argv, opts, done)
    assert.equals("curl", argv[1])
    calls = calls + 1
    local attempt = assert(attempts[calls], "unexpected transport attempt")
    vim.schedule(function()
      if late_stdout then
        local deliver = late_stdout
        late_stdout = nil
        deliver()
      end
      for _, chunk in ipairs(attempt.chunks or { vim.json.encode(attempt.body) }) do opts.stdout(nil, chunk) end
      cancelled = attempt.cancel == true
      if attempt.stall then
        assert(watchdog.callback, "watchdog did not arm")()
        late_stdout = function()
          for _, chunk in ipairs(attempt.late_chunks or {}) do opts.stdout(nil, chunk) end
          done({ code = 9, stderr = "" })
        end
        return
      end
      done({ code = attempt.exit or 0, stderr = "STRAPS_HTTP_STATUS:" .. tostring(attempt.status or 400) .. "\n" })
    end)
    return { kill = function() end }
  end
  local ctx = {
    bufnr = buf, model = "test-model", emit = function() end, on_cancel = function() end,
    cancelled = function() return cancelled end,
    await = function(start)
      local result, done
      start(function(value) if not done then result, done = value, true end end)
      assert(vim.wait(2000, function() return done end, 5), "fake transport did not resolve")
      return result
    end,
  }
  local ok, result = pcall(registry.call, backend, { messages = { { role = "user", content = "hi" } } }, ctx)
  vim.system, vim.defer_fn, vim.uv.new_timer = original, defer, new_timer
  return ok, result, calls
end

local function rejected(backend, attempts, options)
  local ok, result, calls = invoke(backend, attempts, options or { enabled = true })
  assert.is_false(ok)
  assert.equals("string", type(result))
  assert.matches("request failed", result)
  return calls, result
end

for _, case in ipairs({
  { backend = "fn.provider_anthropic", provider = "anthropic", route = "anthropic", code = "invalid_request_error", body = anthropic },
  { backend = "fn.provider_openai", provider = "openai", route = "env", code = "context_length_exceeded", body = openai },
}) do
  describe(case.backend .. " context rejection", function()
    it("preserves a typed rejection through registry dispatch", function()
      local encoded = vim.json.encode(case.body)
      local ok, result, calls = invoke(case.backend, { { chunks = { encoded:sub(1, 15), encoded:sub(16) } } }, { enabled = true })
      assert.is_false(ok)
      assert.equals("table", type(result))
      assert.equals("context_overflow", result.kind)
      assert.is_true(result.rejected)
      assert.is_false(result.response_started)
      assert.equals(case.provider, result.provider)
      assert.equals(case.route, result.route)
      assert.equals(400, result.status)
      assert.equals(case.code, result.code)
      assert.equals(case.body.error.message, result.message)
      assert.equals(result.message, tostring(result))
      assert.equals(1, calls)
    end)
    it("keeps default errors as strings", function() rejected(case.backend, { { body = case.body } }, {}) end)
    it("honors buffer opt in", function()
      local ok, result = invoke(case.backend, { { body = case.body } }, { override = { enabled = true } })
      assert.is_false(ok)
      assert.equals("context_overflow", result.kind)
    end)
    it("honors buffer opt out", function()
      rejected(case.backend, { { body = case.body } }, { enabled = true, override = { enabled = false } })
    end)
    for _, status in ipairs({ 200, 401, 403, 404, 413, 422 }) do
      it("rejects status " .. status, function() rejected(case.backend, { { status = status, body = case.body } }) end)
    end
    it("rejects a curl failure with HTTP 400", function() rejected(case.backend, { { exit = 7, body = case.body } }) end)
    it("returns cancellation without classification", function()
      local ok, result = invoke(case.backend, { { body = case.body, cancel = true } }, { enabled = true })
      assert.is_true(ok)
      assert.equals("cancelled", result.stop_reason)
    end)
    for _, prefix in ipairs({
      "event: unknown\n", "data: malformed\n", 'data: {"type":"unknown"}\n',
      'data: {"type":"message_start"}\n',
      'data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"x","name":"bash"}}\n',
      'data: {"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","call_id":"x","name":"bash"}}\n',
      'data: {"type":"response.created"}\n',
    }) do
      it("disqualifies stream prefix " .. prefix, function()
        rejected(case.backend, { { chunks = { prefix, vim.json.encode(case.body) } } })
      end)
    end
    for _, suffix in ipairs({ "broken", string.rep(" ", 65536), "\n" .. string.rep(" ", 65536) }) do
      it("rejects incomplete or over-cap evidence " .. #suffix, function()
        rejected(case.backend, { { chunks = { vim.json.encode(case.body), suffix } } })
      end)
    end
    it("rejects invalid UTF-8 evidence", function()
      local body = vim.json.encode(case.body):gsub("}$", ',"invalid":"' .. string.char(255) .. '"}')
      rejected(case.backend, { { chunks = { body } } })
    end)
    it("rejects malformed JSON", function() rejected(case.backend, { { chunks = { '{"error":' } } }) end)
    it("allows clean rejection after a nonstream retry", function()
      local ok, result, calls = invoke(case.backend, { { status = 503, body = {} }, { body = case.body } }, { enabled = true })
      assert.is_false(ok)
      assert.equals("context_overflow", result.kind)
      assert.equals(2, calls)
    end)
    it("retains oversized whitespace disqualification when the watchdog resolves before exit", function()
      local calls = rejected(case.backend, { { stall = true, chunks = { string.rep(" ", 65537) } }, { body = case.body } })
      assert.equals(2, calls)
    end)
    it("retains invalid UTF-8 disqualification when the watchdog resolves before exit", function()
      local calls = rejected(case.backend, { { stall = true, chunks = { string.char(255) } }, { body = case.body } })
      assert.equals(2, calls)
    end)
    it("retains incomplete UTF-8 disqualification when the watchdog resolves before exit", function()
      local calls = rejected(case.backend, { { stall = true, chunks = { string.char(226, 130) } }, { body = case.body } })
      assert.equals(2, calls)
    end)
    for _, prefix in ipairs({ "data: malformed", "event: unknown", '{"error":', '{"type":"unknown"}', "null" }) do
      it("retains unterminated watchdog evidence across retries " .. prefix, function()
        local calls = rejected(case.backend, { { stall = true, chunks = { prefix } }, { body = case.body } })
        assert.equals(2, calls)
      end)
    end
    for index, chunk in ipairs({ "data: malformed", "event: unknown", '{"error":', '{"type":"unknown"}',
      string.char(255), string.char(226, 130), string.rep(" ", 65537) }) do
      it("retains late watchdog evidence before the next response " .. index, function()
        local calls = rejected(case.backend, {
          { stall = true, chunks = {}, late_chunks = { chunk } }, { body = case.body },
        })
        assert.equals(2, calls)
      end)
    end
    it("allows bounded late whitespace after a watchdog retry", function()
      local ok, result, calls = invoke(case.backend, {
        { stall = true, chunks = {}, late_chunks = { " \r\n\t" } }, { body = case.body },
      }, { enabled = true })
      assert.is_false(ok)
      assert.equals("context_overflow", result.kind)
      assert.equals(2, calls)
    end)
    it("allows clean rejection after an empty watchdog retry", function()
      local ok, result, calls = invoke(case.backend, { { stall = true, chunks = {} }, { body = case.body } }, { enabled = true })
      assert.is_false(ok)
      assert.equals("context_overflow", result.kind)
      assert.equals(2, calls)
    end)
    it("allows clean rejection after a bounded whitespace watchdog retry", function()
      local ok, result, calls = invoke(case.backend, { { stall = true, chunks = { " " } }, { body = case.body } }, { enabled = true })
      assert.is_false(ok)
      assert.equals("context_overflow", result.kind)
      assert.equals(2, calls)
    end)
    it("retains a truncated whitespace attempt disqualification", function()
      local calls = rejected(case.backend, { { status = 503, chunks = { string.rep(" ", 65537) } }, { body = case.body } })
      assert.equals(2, calls)
    end)
    for _, prefix in ipairs({ "data: malformed\n", 'data: {"type":"unknown"}\n',
      'data: {"type":"response.created"}\n', 'data: {"type":"message_start"}\n',
      'data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"x","name":"bash"}}\n',
      'data: {"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","call_id":"x","name":"bash"}}\n',
    }) do
      it("retains stream disqualification across internal retries " .. prefix, function()
        local calls = rejected(case.backend, { { status = 503, chunks = { prefix } }, { body = case.body } })
        assert.equals(2, calls)
      end)
    end
  end)
end

describe("exact overflow predicates", function()
  for _, message in ipairs({ "prompt is too long: 100 tokens > 100 maximum", "prompt is too long: 99 tokens > 100 maximum",
    "prefix prompt is too long: 101 tokens > 100 maximum", "prompt is too long: 101 tokens > 100 maximum suffix", "context too long" }) do
    it("rejects Anthropic message " .. message, function()
      rejected("fn.provider_anthropic", { { body = { type = "error", error = { type = "invalid_request_error", message = message } } } })
    end)
  end
  for _, body in ipairs({ { error = anthropic.error }, { type = "other", error = anthropic.error },
    { type = "error", error = { type = "other", message = anthropic.error.message } } }) do
    it("rejects another Anthropic envelope " .. vim.json.encode(body), function() rejected("fn.provider_anthropic", { { body = body } }) end)
  end
  for _, code in ipairs({ "invalid_request_error", "context_window_exceeded", "unknown" }) do
    it("rejects OpenAI code " .. code, function()
      rejected("fn.provider_openai", { { body = { error = { code = code, message = "context too long" } } } })
    end)
  end
  it("does not classify llama.cpp", function() rejected("fn.provider_llamacpp", { { body = anthropic } }) end)
  it("does not classify streaming error events", function()
    for _, backend in ipairs({ "fn.provider_anthropic", "fn.provider_openai" }) do
      rejected(backend, { { chunks = { "data: " .. vim.json.encode({ type = "error", error = openai.error }) .. "\n\n" } } })
    end
  end)
  it("classifies the OpenAI code without a message", function()
    local ok, result = invoke("fn.provider_openai", { { body = { error = { code = "context_length_exceeded" } } } }, { enabled = true })
    assert.is_false(ok)
    assert.equals("context_overflow", result.kind)
    assert.equals("context_length_exceeded", result.message)
  end)
  it("retains streaming errors across internal attempts", function()
    for _, case in ipairs({
      { backend = "fn.provider_anthropic", body = anthropic, error = { type = "overloaded_error" } },
      { backend = "fn.provider_openai", body = openai, error = { code = "server_error" } },
    }) do
      local calls = rejected(case.backend, {
        { chunks = { 'data: ' .. vim.json.encode({ type = "error", error = case.error }) .. '\n\n' } },
        { body = case.body },
      })
      assert.equals(2, calls)
    end
  end)
  it("classifies the Codex route", function()
    local previous = registry.get("fn.openai_api_key").source
    registry.define({ name = "fn.openai_api_key", kind = "fn", source = [[return function() return "test-key", "codex", "account" end]] })
    local ok, result = invoke("fn.provider_openai", { { body = openai } }, { enabled = true })
    registry.define({ name = "fn.openai_api_key", kind = "fn", source = previous })
    assert.is_false(ok)
    assert.equals("context_overflow", result.kind)
    assert.equals("codex", result.route)
  end)
end)
