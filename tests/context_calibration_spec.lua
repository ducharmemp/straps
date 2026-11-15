local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(vim.fn.fnamemodify(here, ":p"), ":h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
vim.env.XDG_CONFIG_HOME = vim.fn.tempname()
local straps = require("straps").setup({ gzip = false, context_management = { enabled = true, input_limit = 1000000 } })
local registry = require("straps.registry")
local calibration = require("straps.context_calibration")
registry.define({ name = "fn.openai_api_key", kind = "fn", source = [[return function() return "test-key", "env" end]] })
registry.define({ name = "fn.anthropic_api_key", kind = "fn", source = [[return function() return "test-key", "env" end]] })

local function buffer()
  local b = vim.api.nvim_create_buf(false, false)
  vim.b[b].straps_session = true
  return b
end

local function context(b, prepare)
  return { bufnr = b, model = "test-model", context_prepare = prepare, emit = function() end,
    cancelled = function() return false end, on_cancel = function() end,
    await = function(start)
      local result, done
      start(function(value) if not done then result, done = value, true end end)
      assert(vim.wait(2000, function() return done end, 5), "fake transport did not resolve")
      return result
    end }
end

local function request(text)
  return { messages = { { role = "user", content = text or "hi" } } }
end

local function dispatch(b, usage, opts)
  opts = opts or {}
  local original, calls = vim.system, 0
  vim.system = function(_, transport, done)
    calls = calls + 1
    vim.schedule(function()
      if opts.refresh and calls == 1 then
        done({ code = 0, stderr = "STRAPS_HTTP_STATUS:401\n" })
      elseif opts.fail then
        transport.stdout(nil, 'data: {"type":"response.failed","response":{"error":{"message":"bad"}}}\n\n')
        done({ code = 0, stderr = "STRAPS_HTTP_STATUS:400\n" })
      else
        local event = opts.anthropic and { type = "message_start", message = { usage = usage } }
          or { type = "response.completed", response = { status = "completed", usage = usage } }
        transport.stdout(nil, "data: " .. vim.json.encode(event) .. "\n\n")
        if opts.anthropic then
          transport.stdout(nil, 'data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}\n\n')
          transport.stdout(nil, 'data: {"type":"message_stop"}\n\n')
        end
        done({ code = 0, stderr = "STRAPS_HTTP_STATUS:200\n" })
      end
    end)
    return { kill = function() end }
  end
  local ctx = context(b)
  ctx.context_isolated = opts.isolated
  if opts.cancel then ctx.cancelled = function() return calls > 0 end end
  local ok, result = pcall(registry.call, opts.anthropic and "fn.provider_anthropic" or "fn.provider_openai", request(), ctx)
  vim.system = original
  return ok, result, calls
end

local function prepared(b, text)
  return registry.call("fn.provider_openai", request(text), context(b, true))
end

describe("response input calibration", function()
  it("reuses actual dispatch input and cached usage with uncertain byte growth", function()
    local b = buffer()
    assert.is_true(dispatch(b, { input_tokens = 100, input_tokens_details = { cached_tokens = 80 }, output_tokens = 9000 }))
    local report = calibration.estimate(b, prepared(b, "hi appended"))
    assert.equals(100, report.observed_input)
    assert.is_true(report.delta_bytes > 0)
    assert.equals(100 + math.ceil(report.delta_bytes / 3 * 1.3) + 64, report.tokens)
    assert.is_false(report.exact)
    assert.matches("estimate", report.source)
    assert.equals(64, #report.calibration_identity)
  end)

  it("uses calibration in production accounting without changing the allowance", function()
    local b = buffer()
    assert.is_true(dispatch(b, { input_tokens = 100, output_tokens = 1 }))
    local p = prepared(b, "hi appended")
    local management = require("straps.context_management")
    local report = management.account(p, context(b))
    local estimate = calibration.estimate(b, p)
    assert.equals(estimate.tokens, report.tokens)
    assert.equals(estimate.source, report.source)
    assert.equals(100, report.observed_input)
    assert.equals(1000000 - 4096, report.limit)
    local isolated = context(b)
    isolated.context_isolated = true
    assert.equals("wire-byte estimate", management.account(p, isolated).source)
  end)

  it("sums fresh and both cache fields for Anthropic", function()
    local b = buffer()
    assert.is_true(dispatch(b, { input_tokens = 10, cache_read_input_tokens = 20, cache_creation_input_tokens = 30 }, { anthropic = true }))
    local p = registry.call("fn.provider_anthropic", request(), context(b, true))
    assert.equals(60, calibration.estimate(b, p).observed_input)
  end)

  it("requires fresh finite input and preserves prior records on invalid observation", function()
    local b = buffer()
    local p = prepared(b)
    for _, usage in ipairs({ {}, { cache_read_input_tokens = 50 }, { input_tokens = -1 },
      { input_tokens = math.huge }, { input_tokens = 0 / 0 }, { input_tokens = 4, cache_read_input_tokens = -1 },
      { input_tokens = 4, cache_creation_input_tokens = "3" } }) do
      calibration.observe(b, p, usage, p.calibration_identity)
      assert.is_nil(calibration.estimate(b, p))
    end
    calibration.observe(b, p, { input_tokens = 0 }, p.calibration_identity)
    calibration.observe(b, p, {}, p.calibration_identity)
    assert.equals(0, calibration.estimate(b, p).observed_input)
  end)

  it("rejects static changes and nonprefix edits without erasing the observation", function()
    local b = buffer()
    assert.is_true(dispatch(b, { input_tokens = 100 }))
    local p = prepared(b)
    for _, key in ipairs({ "tools", "instructions", "model", "max_output_tokens", "reasoning" }) do
      local changed = vim.deepcopy(p)
      changed.body[key] = "changed"
      assert.is_nil(calibration.estimate(b, changed))
    end
    assert.is_nil(calibration.estimate(b, prepared(b, "replacement")))
    assert.equals(100, calibration.estimate(b, p).observed_input)
    p.body.input[#p.body.input + 1] = { role = "assistant", content = "answer" }
    assert.is_table(calibration.estimate(b, p))
  end)

  it("ignores failed cancelled missing usage summary and scratch attempts without erasure", function()
    local b = buffer()
    assert.is_true(dispatch(b, { input_tokens = 100 }))
    assert.is_false(dispatch(b, nil, { fail = true }))
    assert.is_true(dispatch(b, { input_tokens = 300 }, { isolated = true }))
    assert.is_true(dispatch(b, { input_tokens = 400 }, { cancel = true }))
    assert.is_true(dispatch(b, nil))
    vim.bo[b].buftype = "nofile"
    assert.is_true(dispatch(b, { input_tokens = 500 }))
    vim.bo[b].buftype = ""
    assert.equals(100, calibration.estimate(b, prepared(b)).observed_input)
  end)

  it("uses the successful post-refresh account identity", function()
    local key = registry.get("fn.openai_api_key").source
    registry.define({ name = "fn.openai_api_key", kind = "fn", source = [[return function() return "old-key", "oauth" end]] })
    registry.define({ name = "fn.openai_oauth_refresh", kind = "fn", source = [[return function(_, done) done({access="new-key"}) end]] })
    local b = buffer()
    local old = prepared(b)
    local ok, _, calls = dispatch(b, { input_tokens = 70 }, { refresh = true })
    assert.is_true(ok)
    assert.equals(2, calls)
    assert.is_nil(calibration.estimate(b, old))
    old.calibration_identity = calibration.identity(old, "https://api.openai.com/v1/responses", "new-key")
    assert.equals(70, calibration.estimate(b, old).observed_input)
    registry.define({ name = "fn.openai_api_key", kind = "fn", source = key })
  end)

  it("compares structured same-role content extensions and identity dimensions", function()
    local b = buffer()
    local p = prepared(b)
    p.body.input = { { role = "user", content = { { type = "input_text", text = "prefix" } } } }
    calibration.observe(b, p, { input_tokens = 12 }, p.calibration_identity)
    local grown = vim.deepcopy(p)
    grown.body.input[1].content[1].text = "prefix extension"
    grown.body.input[1].content[2] = { type = "input_text", text = "next" }
    assert.is_table(calibration.estimate(b, grown))
    grown.body.input[1].role = "assistant"
    assert.is_nil(calibration.estimate(b, grown))
    for _, identity in ipairs({ calibration.identity(p, "https://other.example/v1/responses", "test-key"),
      calibration.identity(p, "https://api.openai.com/v1/responses", "other-account") }) do
      grown = vim.deepcopy(p)
      grown.calibration_identity = identity
      assert.is_nil(calibration.estimate(b, grown))
    end
    local changed = vim.deepcopy(p)
    changed.route = "codex"
    assert.is_not.equals(p.calibration_identity, calibration.identity(changed, "https://api.openai.com/v1/responses", "test-key"))
    assert.is_nil(p.account_id)
    assert.is_nil(p.api_key)
  end)

  it("ignores unsupported source and wipes private observations", function()
    local b = buffer()
    assert.is_true(dispatch(b, { input_tokens = 100 }))
    local p = prepared(b)
    local source = registry.get("fn.provider_openai").source
    registry.define({ name = "fn.provider_openai", kind = "fn", source = "return function() return {} end" })
    assert.is_nil(calibration.identity(p, "https://api.openai.com/v1/responses", "test-key"))
    registry.define({ name = "fn.provider_openai", kind = "fn", source = source })
    vim.api.nvim_exec_autocmds("BufWipeout", { buffer = b })
    assert.is_nil(calibration.estimate(b, p))
  end)

  it("does not create metadata or update observations when disabled", function()
    local b = buffer()
    straps.config.context_management.enabled = false
    assert.is_nil(prepared(b).calibration_identity)
    assert.is_true(dispatch(b, { input_tokens = 100 }))
    straps.config.context_management.enabled = true
    assert.is_nil(calibration.estimate(b, prepared(b)))
  end)
end)
