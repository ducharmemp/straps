local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(vim.fn.fnamemodify(here, ":p"), ":h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
vim.env.XDG_CONFIG_HOME = vim.fn.tempname()
local straps = require("straps").setup({ gzip = false, llamacpp_model = "test-model" })
local registry = require("straps.registry")
for _, name in ipairs({ "anthropic", "openai", "llamacpp" }) do
  registry.define({ name = "fn." .. name .. "_api_key", kind = "fn", source = [[return function() return "test-key", "env" end]] })
end

local function invoke(backend, events, cancel, exit_code)
  local original = vim.system
  local cancelled = false
  local calls = 0
  vim.system = function(argv, opts, done)
    assert.equals("curl", argv[1])
    calls = calls + 1
    vim.schedule(function()
      for _, event in ipairs(events) do
        opts.stdout(nil, "data: " .. vim.json.encode(event) .. "\n\n")
      end
      cancelled = cancel == true
      done({ code = exit_code or 0, stderr = "STRAPS_HTTP_STATUS:200\n" })
    end)
    return { kill = function() end }
  end
  local ctx = {
    model = "test-model", emit = function() end, on_cancel = function() end,
    cancelled = function() return cancelled end,
    await = function(start)
      local result, done
      start(function(value) if not done then result, done = value, true end end)
      assert(vim.wait(2000, function() return done end, 5), "fake transport did not resolve")
      return result
    end,
  }
  local ok, result = pcall(registry.call, backend, { messages = { { role = "user", content = "hi" } } }, ctx)
  vim.system = original
  assert.equals(1, calls)
  return ok, result
end

local function anthropic(reason, open)
  local events = {
    { type = "content_block_start", index = 0, content_block = { type = "text", text = "answer" } },
  }
  if not open then events[#events + 1] = { type = "content_block_stop", index = 0 } end
  events[#events + 1] = { type = "message_delta", delta = { stop_reason = reason } }
  events[#events + 1] = { type = "message_stop" }
  return events
end

for _, backend in ipairs({ "fn.provider_anthropic", "fn.provider_llamacpp" }) do
  describe(backend .. " completion", function()
    for _, reason in ipairs({ "end_turn", "tool_use", "stop_sequence", "refusal", "max_tokens", "pause_turn", "unknown" }) do
      it("marks terminal reason " .. reason, function()
        local ok, result = invoke(backend, anthropic(reason))
        assert.is_true(ok)
        assert.equals(reason, result.stop_reason)
        assert.equals(reason == "end_turn" or reason == "tool_use" or reason == "stop_sequence" or reason == "refusal", result.complete)
      end)
    end
    it("rejects an unfinished block", function()
      local ok, result = invoke(backend, anthropic("end_turn", true))
      assert.is_true(ok)
      assert.is_false(result.complete)
    end)
    for _, kind in ipairs({ "thinking", "redacted_thinking" }) do
      for _, closed in ipairs({ false, true }) do
        it("checks " .. kind .. " closure " .. tostring(closed), function()
          local events = anthropic("end_turn")
          table.insert(events, 1, { type = "content_block_start", index = 1, content_block = { type = kind } })
          if closed then table.insert(events, 2, { type = "content_block_stop", index = 1 }) end
          local ok, result = invoke(backend, events)
          assert.is_true(ok)
          assert.equals(closed, result.complete)
        end)
      end
    end
    it("marks cancellation incomplete", function()
      local ok, result = invoke(backend, {}, true)
      assert.is_true(ok)
      assert.equals("cancelled", result.stop_reason)
      assert.is_false(result.complete)
    end)
    it("raises on a truncated stream", function()
      local ok, err = invoke(backend, { { type = "message_start" } }, false, 7)
      assert.is_false(ok)
      assert.matches("request failed", err)
    end)
  end)
end

describe("OpenAI completion", function()
  for _, case in ipairs({
    { "response.completed", "completed", nil, true, "end_turn" },
    { "response.completed", nil, nil, true, "end_turn" },
    { "response.done", "completed", nil, true, "end_turn" },
    { "response.done", nil, nil, false, "end_turn" },
    { "response.completed", "in_progress", nil, false, "end_turn" },
    { "response.incomplete", "incomplete", "max_output_tokens", false, "max_tokens" },
    { "response.incomplete", "incomplete", "content_filter", false, "end_turn" },
    { "response.done", "incomplete", "content_filter", false, "end_turn" },
  }) do
    it("marks " .. case[1] .. " " .. tostring(case[2]) .. " " .. tostring(case[3]), function()
      local ok, result = invoke("fn.provider_openai", {
        { type = "response.output_text.delta", output_index = 0, delta = "answer" },
        { type = case[1], response = { status = case[2], incomplete_details = { reason = case[3] } } },
      })
      assert.is_true(ok)
      assert.equals(case[4], result.complete)
      assert.equals(case[5], result.stop_reason)
      assert.equals("answer", result.content[1].text)
    end)
  end
  for _, incomplete in ipairs({ false, true }) do
    it("preserves completed tool calls on " .. tostring(incomplete), function()
      local ok, result = invoke("fn.provider_openai", {
        { type = "response.output_item.done", output_index = 0,
          item = { type = "function_call", call_id = "call-1", name = "bash", arguments = "{}", status = "completed" } },
        { type = incomplete and "response.incomplete" or "response.completed", response = {
          status = incomplete and "incomplete" or "completed", incomplete_details = { reason = "max_output_tokens" } } },
      })
      assert.is_true(ok)
      assert.equals(not incomplete, result.complete)
      assert.equals("tool_use", result.stop_reason)
      assert.equals("call-1", result.content[1].id)
    end)
  end
  for _, item_type in ipairs({ "function_call", "message" }) do
    it("rejects completed responses with incomplete " .. item_type, function()
      local ok, result = invoke("fn.provider_openai", {
        { type = "response.output_item.done", output_index = 0,
          item = { type = item_type, status = "incomplete", call_id = "partial", name = "bash", arguments = "{}" } },
        { type = "response.completed", response = { status = "completed" } },
      })
      assert.is_true(ok)
      assert.is_false(result.complete)
    end)
  end
  for _, event_type in ipairs({ "response.completed", "response.done" }) do
    for _, item_type in ipairs({ "function_call", "message" }) do
      it("rejects terminal incomplete output " .. event_type .. " " .. item_type, function()
        local ok, result = invoke("fn.provider_openai", {
          { type = event_type, response = { status = "completed", output = { { type = item_type, status = "incomplete" } } } },
        })
        assert.is_true(ok)
        assert.is_false(result.complete)
      end)
    end
  end
  it("rejects a tool without its done event", function()
    local ok, result = invoke("fn.provider_openai", {
      { type = "response.output_item.added", output_index = 0,
        item = { type = "function_call", call_id = "partial", name = "bash" } },
      { type = "response.function_call_arguments.delta", output_index = 0, delta = '{"command":' },
      { type = "response.completed", response = { status = "completed" } },
    })
    assert.is_true(ok)
    assert.is_false(result.complete)
  end)
  for _, event in ipairs({ "response.failed", "error", "truncated" }) do
    it("raises on " .. event, function()
      local ok, err = invoke("fn.provider_openai", {
        { type = "response.output_text.delta", delta = "partial" },
        { type = event, response = { status = "failed", error = { message = "fixture failure" } }, message = "fixture failure" },
      })
      assert.is_false(ok)
      assert.matches("request failed", err)
    end)
  end
  it("marks cancellation incomplete", function()
    local ok, result = invoke("fn.provider_openai", {}, true)
    assert.is_true(ok)
    assert.equals("cancelled", result.stop_reason)
    assert.is_false(result.complete)
  end)
end)
