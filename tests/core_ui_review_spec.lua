local script = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(vim.fn.fnamemodify(script, ":p"), ":h:h")
vim.opt.runtimepath:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
vim.env.XDG_CONFIG_HOME = vim.fn.tempname()
local straps = require("straps").setup({ provider = "anthropic", model = "claude-test", effort = "off" })
straps.config.session_dir = vim.fn.tempname()
local registry = require("straps.registry")
local state = require("straps.state")
local ui = require("straps.ui")
local loop = require("straps.loop")
vim.cmd("source " .. vim.fn.fnameescape(root .. "/plugin/straps.lua"))

local function stub(name, source)
  local old = registry.get(name)
  registry.define({ name = name, kind = "fn", source = source })
  return function() registry.define(old) end
end

it("async catalog resumes once in its captured registry scope", function()
  local real_system = vim.system
  local restore = stub("fn.anthropic_api_key", [[return function(opts)
    _G.review_scope_before = require("straps.registry").active_scope()
    opts.ctx.await(function(resolve) _G.review_resolve = resolve end)
    _G.review_scope_after = require("straps.registry").active_scope()
    return "test-key"
  end]])
  local b = state.new_session()
  registry.ensure_scope(b)
  local callbacks, requests, got_scope = 0, 0
  vim.system = function(_, _, done)
    requests = requests + 1
    _G.review_curl_done = done
  end
  local previous = registry.set_active_scope(b)
  local ok, err = pcall(function()
    registry.call("fn.list_models", "anthropic", function()
      callbacks = callbacks + 1
      got_scope = registry.active_scope()
    end)
    registry.set_active_scope(previous)
    _G.review_resolve()
    _G.review_resolve()
    assert(vim.wait(2000, function() return requests > 0 end, 10))
    vim.wait(30, function() return false end, 10)
    assert.are.equal(0, callbacks)
    local response = { code = 0, stdout = '{"data":[{"id":"scope-test"}]}\nSTRAPS_HTTP_STATUS:200\n' }
    _G.review_curl_done(response)
    _G.review_curl_done(response)
    assert(vim.wait(2000, function() return callbacks > 0 end, 10))
    vim.wait(30, function() return false end, 10)
    assert.are.equal(b, _G.review_scope_before)
    assert.are.equal(b, _G.review_scope_after)
    assert.are.equal(b, got_scope)
    assert.are.equal(previous, registry.active_scope())
    assert.are.equal(1, requests)
    assert.are.equal(1, callbacks)
  end)
  registry.set_active_scope(previous)
  vim.system = real_system
  restore()
  assert(ok, vim.inspect(err))
end)

it("synchronous catalog keeps returning entries without a callback", function()
  local real_system = vim.system
  local restore = stub("fn.anthropic_api_key", [[return function(opts)
    assert(opts.ctx == nil)
    return "test-key"
  end]])
  vim.system = function(_, _, done)
    assert.is_nil(done)
    return { wait = function(_, timeout)
      assert.are.equal(15000, timeout)
      return { code = 0, stdout = '{"data":[{"id":"sync-test"}]}\nSTRAPS_HTTP_STATUS:200\n' }
    end }
  end
  local ok, err = pcall(function()
    local models, why = registry.call("fn.list_models", "anthropic")
    assert.is_nil(why)
    assert.are.equal("sync-test", models[1].id)
  end)
  vim.system = real_system
  restore()
  assert(ok, vim.inspect(err))
end)

for _, kind in ipairs({ "oauth", "codex" }) do
  it("async catalog yields while expired " .. kind .. " credentials refresh", function()
    local restores = {}
    restores[#restores + 1] = stub("fn.openai_oauth_credential", kind == "oauth"
      and [[return function() return { access = "old", expires = 0 } end]] or [[return function() end]])
    restores[#restores + 1] = stub("fn.openai_codex_credential", kind == "codex"
      and [[return function() return { access = "old", expires = 0, account_id = "acct" } end]] or [[return function() end]])
    restores[#restores + 1] = stub("fn.openai_" .. kind .. "_refresh", [[return function(_, done) _G.review_refresh = done end]])
    local real_system, real_wait = vim.system, vim.wait
    local requests, got = {}, nil
    vim.system = function(argv, _, done)
      requests[#requests + 1] = argv
      done({ code = 0, stdout = '{"data":[{"id":"catalog-test"}]}\nSTRAPS_HTTP_STATUS:200\n' })
    end
    vim.wait = function() error("credential discovery blocked in vim.wait") end
    _G.review_refresh = nil
    local ok, err = pcall(function()
      local returned = vim.F.pack_len(registry.call("fn.list_models", "openai", function(models, why) got = { models, why } end))
      assert.are.equal(0, returned.n, vim.inspect(returned))
      assert.is_function(_G.review_refresh)
      assert.is_nil(got)
      assert.are.equal(0, #requests)
      _G.review_refresh({ access = "new", account_id = "acct" })
      vim.wait = real_wait
      assert(real_wait(2000, function() return got ~= nil end, 10))
      assert.are.equal("catalog-test", got[1] and got[1][1].id, tostring(got[2]))
      assert.are.equal(1, #requests)
      assert.truthy(table.concat(requests[1], " "):find("Bearer new", 1, true))
    end)
    vim.system, vim.wait = real_system, real_wait
    for i = #restores, 1, -1 do restores[i]() end
    assert(ok, vim.inspect(err))
  end)
end

it("model, effort and provider pickers target the only visible session from another buffer", function()
  vim.cmd("silent! only!")
  vim.cmd("enew!")
  local other = vim.api.nvim_get_current_buf()
  local b = state.new_session()
  ui.show_session(b)
  vim.api.nvim_set_current_win(vim.fn.bufwinid(other))
  local real_pick, prompts = ui.pick, {}
  local restore = stub("fn.list_models", [[return function() return { { id = "claude-selected" } } end]])
  ui.pick = function(items, opts, done)
    prompts[#prompts + 1] = opts.prompt
    local choice = items[1]
    for _, item in ipairs(items) do
      if type(item) == "table" and item.id == "claude-selected" then choice = item end
    end
    done(choice)
  end
  local old_model, old_effort, old_provider = straps.config.model, straps.config.effort, straps.config.provider
  local ok, err = pcall(function()
    ui.pick_model()
    ui.pick_effort()
    ui.pick_provider()
    assert.are.equal("claude-selected", vim.b[b].straps_model)
    assert.are.equal(straps.config.efforts[1].name, vim.b[b].straps_effort)
    assert.is_string(vim.b[b].straps_provider)
    for _, prompt in ipairs(prompts) do assert.truthy(prompt:find("this session", 1, true), prompt) end
    assert.are.equal(old_model, straps.config.model)
    assert.are.equal(old_effort, straps.config.effort)
    assert.are.equal(old_provider, straps.config.provider)
  end)
  ui.pick = real_pick
  straps.config.model, straps.config.effort, straps.config.provider = old_model, old_effort, old_provider
  restore()
  assert(ok, vim.inspect(err))
end)

it("picker scope is global with no visible session or ambiguous visible sessions", function()
  local real_pick, prompts = ui.pick, {}
  local restore = stub("fn.list_models", [[return function() return { { id = "claude-test" } } end]])
  ui.pick = function(_, opts) prompts[#prompts + 1] = opts.prompt end
  local ok, err = pcall(function()
    vim.cmd("silent! only!")
    vim.cmd("enew!")
    ui.pick_model()
    ui.pick_effort()
    ui.pick_provider()
    local plain = vim.api.nvim_get_current_win()
    for _ = 1, 2 do
      vim.cmd("split")
      vim.api.nvim_set_current_buf(state.new_session())
    end
    vim.api.nvim_set_current_win(plain)
    ui.pick_model()
    ui.pick_effort()
    ui.pick_provider()
    assert.are.equal(6, #prompts)
    for _, prompt in ipairs(prompts) do assert.truthy(prompt:find("global", 1, true), prompt) end
  end)
  ui.pick = real_pick
  restore()
  assert(ok, vim.inspect(err))
end)

for _, note in ipairs({
  "run cancelled (:StrapsStop)",
  "stopped after 1 turns (config.max_turns) — send a message to continue",
  "stopped after 1 consecutive turns with no apparent progress (config.stall_limit=1). — send a message to steer, or raise config.stall_limit",
  "the model returned no text after 1 nudge(s) — it keeps ending its turn silently. Send a message to steer, or raise config.blank_nudge_limit.",
}) do
  it("empty send after terminal note stays idle: " .. note, function()
    local restore = stub("fn.provider", [[return function() _G.review_calls = _G.review_calls + 1; return { stop_reason = "end_turn", content = { { type = "text", text = "done" } } } end]])
    _G.review_calls = 0
    local b = state.new_session()
    state.seed_user(b, "request")
    state.append(b, "assistant", nil, "answer")
    state.append(b, "user", nil, "[straps] " .. note)
    state.ensure_trailing_user(b)
    local before = vim.api.nvim_buf_get_lines(b, 0, -1, false)
    local real_notify, notes = vim.notify, {}
    vim.notify = function(msg) notes[#notes + 1] = msg end
    loop.start(b)
    vim.notify = real_notify
    assert.is_false(loop.running(b))
    assert.are.equal(0, _G.review_calls)
    assert.same(before, vim.api.nvim_buf_get_lines(b, 0, -1, false))
    assert.truthy(notes[1] and notes[1]:find("nothing to send", 1, true))
    vim.b[b].straps_steering = { "queued request" }
    loop.start(b)
    assert(vim.wait(2000, function() return not loop.running(b) end, 10))
    assert.are.equal(1, _G.review_calls)
    vim.api.nvim_set_current_buf(b)
    vim.cmd("StrapsContinue")
    assert(vim.wait(2000, function() return not loop.running(b) end, 10))
    assert.are.equal(2, _G.review_calls)
    restore()
  end)
end
