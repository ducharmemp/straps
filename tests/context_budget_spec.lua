local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(vim.fn.fnamemodify(here, ":p"), ":h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
vim.env.XDG_CONFIG_HOME = vim.fn.tempname()
local straps = require("straps")
straps.config.session_dir = vim.fn.tempname()
local registry = require("straps.registry")
require("straps.provider").register()
local state = require("straps.state")
local management = require("straps.context_management")
local defaults = vim.deepcopy(straps.config)
local saved_provider = registry.get("fn.provider")
local summary = require("straps.context_summary")
local original_generate, original_attempt = summary.generate, summary.new_attempt
summary.new_attempt = function(opts, ctx)
  if summary.generate == original_generate then return original_attempt(opts, ctx) end
  return { generate = function(sources) return summary.generate(sources, opts, ctx) end }
end

local function define(name, source)
  registry.define({ name = name, kind = "fn", source = source })
end

local function fixture()
  local b = vim.api.nvim_create_buf(false, true)
  state.append(b, "system", nil, "system instructions")
  state.append(b, "user", nil, "original user constraint")
  for i = 1, 4 do
    state.append(b, "assistant", nil, "assistant prose " .. i)
    state.append(b, "tool_use", { id = "t" .. i, name = "read_file" }, '{"path":"exact-id"}')
    state.append(b, "tool_result", { id = "t" .. i }, "evidence " .. i .. string.rep("x", 9000))
  end
  state.append(b, "user", nil, "continue")
  return b
end

local function text(b)
  return table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
end

local function ctx(b)
  return { bufnr = b, cancelled = function() return false end, emit = function() error("unexpected streaming") end }
end

before_each(function()
  straps.config = vim.deepcopy(defaults)
  straps.config.context_management = { enabled = true, mode = "mechanical", input_limit = 20000,
    reserve_tokens = 1000, trigger = 0.3, target = 0.9, minimum_savings = 20 }
  registry.define(saved_provider)
  define("fn.provider", "return function() error('custom provider must not dispatch during accounting') end")
end)

it("requires strict opt-in and leaves provider checks inert when disabled", function()
  straps.config.context_management.enabled = false
  assert.is_false(management.enabled())
  assert.is_nil(management.check({}, {}))
  straps.config.context_management.enabled = "true"
  assert.is_false(management.enabled())
end)

it("counts complete wire bodies and separates combined limits and output reserves", function()
  local p = { body = { system = "constraints", tools = { { name = "tool", description = string.rep("x", 1000) } } },
    output_reserve = 3000, model_entry = { context_limit = 17000 } }
  local a = management.account(p, {})
  p.body.tools = nil
  local b = management.account(p, {})
  assert.is_true(a.tokens > b.tokens)
  assert.are.equal(13000, a.limit)
  assert.is_false(a.exact)
  assert.are.equal("wire-byte estimate", a.source)
end)

it("refuses unknown budgets and output reservations", function()
  straps.config.context_management.input_limit = nil
  assert.has_error(function() management.account({ body = {} }, {}) end)
  straps.config.context_management.context_limit = 10000
  assert.has_error(function() management.account({ body = {} }, {}) end)
end)

it("archives evidence before one adopted transformation and preserves protected prose and tool pairs", function()
  local b = fixture()
  local old = text(b)
  management.boundary(b, ctx(b), {}, {}, nil)
  local new = text(b)
  assert.is_true(#new < #old)
  assert.is_truthy(new:find("original user constraint", 1, true))
  assert.is_truthy(new:find("assistant prose 1", 1, true))
  assert.is_truthy(new:find("evidence 4" .. string.rep("x", 9000), 1, true))
  local id = new:match("%[straps%-context:([%w_-]+)%]")
  assert.is_truthy(id)
  local source = assert(require("straps.context_archive").get(b, id))
  assert.is_truthy(source.sources[1].text:find("evidence 1", 1, true))
  local uses, results = 0, 0
  for _, msg in ipairs(state.parse(b).messages) do
    for _, part in ipairs(msg.content) do
      if part.type == "tool_use" then uses = uses + 1 end
      if part.type == "tool_result" then results = results + 1 end
    end
  end
  assert.are.equal(4, uses)
  assert.are.equal(4, results)
end)

it("leaves the transcript unchanged when archive persistence fails", function()
  local b = fixture()
  local old = text(b)
  local archive = require("straps.context_archive")
  local create = archive.create
  archive.create = function() return nil, "injected archive failure" end
  local ok = pcall(management.boundary, b, ctx(b), {}, {}, nil)
  archive.create = create
  assert.is_false(ok)
  assert.are.equal(old, text(b))
end)

it("restores the transcript after checked persistence rejects adoption", function()
  local b = fixture()
  local old = text(b)
  local persist = management.persist_checked
  management.persist_checked = function() return nil, "injected write failure" end
  local ok = pcall(management.boundary, b, ctx(b), {}, {}, nil)
  management.persist_checked = persist
  assert.is_false(ok)
  assert.are.equal(old, text(b))
end)

it("protects retrieval until continuation and rejects repeat retrieval", function()
  local b = fixture()
  straps.config.context_management.trigger = 1
  management.boundary(b, ctx(b), {}, {}, nil)
  assert.is_true(management.retrieval_limit(b) > 128)
  local old = text(b)
  management.protect(b)
  assert.is_nil(management.retrieval_limit(b))
  management.boundary(b, ctx(b), {}, {}, nil)
  assert.are.equal(old, text(b))
  management.consumed(b)
  assert.is_number(management.retrieval_limit(b))
end)

it("enforces the hard budget when pins prohibit any reduction", function()
  local b = fixture()
  straps.config.context_management.input_limit = 2000
  management.protect(b)
  local old = text(b)
  assert.has_error(function() management.boundary(b, ctx(b), {}, {}, nil) end)
  assert.are.equal(old, text(b))
end)

it("keeps summary preview free of generation", function()
  local b = fixture()
  straps.config.context_management.mode = "summary"
  local preview = management.preview(b, ctx(b))
  assert.is_true(preview.needs_generation)
  assert.are.equal(text(b), table.concat(preview.lines, "\n"))
end)

it("rejects summary adoption when the effective model changes during generation", function()
  local b = fixture()
  straps.config.context_management.mode = "summary"
  local summary = require("straps.context_summary")
  local generate = summary.generate
  local identity
  summary.generate = function(sources, opts)
    identity = opts.config_id
    straps.config.model = "changed-during-generation"
    return { summary = "bounded summary", sources = sources }
  end
  local old = text(b)
  local ok, err = pcall(management.boundary, b, ctx(b), {}, {}, nil)
  summary.generate = generate
  assert.is_string(identity)
  assert.is_false(ok)
  assert.is_truthy(tostring(err):find("provider configuration changed", 1, true))
  assert.are.equal(old, text(b))
end)

it("retains summary source tool attributes and source coordinates", function()
  local b = fixture()
  straps.config.context_management.mode = "summary"
  local summary = require("straps.context_summary")
  local generate = summary.generate
  local supplied
  summary.generate = function(sources)
    supplied = sources
    return nil, "injected inspection stop"
  end
  pcall(management.boundary, b, ctx(b), {}, {}, nil)
  summary.generate = generate
  local use
  for _, source in ipairs(supplied or {}) do if source.kind == "tool_use" then use = source; break end end
  assert.are.equal("read_file", use.attrs.name)
  assert.are.equal("t1", use.attrs.id)
  assert.is_number(use.first_block)
  assert.are.equal(use.first_block, use.last_block)
end)

it("prepares Anthropic wire accounting after thinking raises the response cap", function()
  registry.define(saved_provider)
  define("fn.anthropic_api_key", "return function() return 'synthetic-key' end")
  straps.config.provider = "anthropic"
  straps.config.model = "budget-test"
  straps.config.models = { { id = "budget-test", thinking = "budget", context = 40000 } }
  straps.config.max_tokens = 1024
  straps.config.effort = "test"
  straps.config.efforts = { { name = "test", budget_tokens = 2048 } }
  local b = fixture()
  local c = ctx(b)
  c.context_prepare = true
  local p = registry.call("fn.provider", { system = "instruction", messages = {}, tools = {} }, c)
  assert.are.equal(3072, p.output_reserve)
  assert.are.equal(2048, p.body.thinking.budget_tokens)
  assert.is_truthy(p.body.system)
end)

it("prepares Codex after its wire mutation without inventing an output cap", function()
  registry.define(saved_provider)
  define("fn.openai_api_key", "return function() return 'synthetic-key', 'codex', 'synthetic-account' end")
  straps.config.provider = "openai"
  straps.config.openai_model = "synthetic-model"
  local b = fixture()
  local c = ctx(b)
  c.context_prepare = true
  local p = registry.call("fn.provider", { system = "instruction", messages = {}, tools = {} }, c)
  assert.are.equal("codex", p.route)
  assert.is_nil(p.body.max_output_tokens)
  assert.is_truthy(p.body.prompt_cache_key)
end)

it("subtracts output from combined OpenAI and llama.cpp windows and requires a Codex reserve", function()
  straps.config.context_management.input_limit = nil
  for _, provider in ipairs({ "openai", "llamacpp" }) do
    local prepared = { provider = provider, body = {}, model_entry = { context = 17000 }, output_reserve = 3000 }
    assert.are.equal(13000, management.account(prepared, {}).limit)
    prepared.output_reserve, prepared.route = nil, "codex"
    assert.has_error(function() management.account(prepared, {}) end)
    straps.config.context_management.output_reserve = 4000
    assert.are.equal(12000, management.account(prepared, {}).limit)
    straps.config.context_management.output_reserve = nil
  end
  assert.are.equal(16000, management.account({ provider = "anthropic", body = {}, model_entry = { context = 17000 } }, {}).limit)
end)

it("disables thinking for isolated Anthropic summaries with a smaller output cap", function()
  registry.define(saved_provider)
  define("fn.anthropic_api_key", "return function() return 'synthetic-key' end")
  straps.config.provider, straps.config.model = "anthropic", "budget-test"
  straps.config.models = { { id = "budget-test", thinking = "budget", context = 40000 } }
  straps.config.effort, straps.config.efforts = "test", { { name = "test", budget_tokens = 2048 } }
  local c = ctx(fixture())
  c.context_prepare, c.context_isolated = true, true
  local req = { system = "summary", messages = {}, tools = {}, context_max_output = 512 }
  local prepared = registry.call("fn.provider", req, c)
  assert.are.equal(512, prepared.body.max_tokens)
  assert.is_nil(prepared.body.thinking)
  c.context_isolated = false
  assert.has_error(function() registry.call("fn.provider", req, c) end)
end)

it("rechecks pins added while a summary is generated", function()
  local b = fixture()
  straps.config.context_management.mode = "summary"
  local summary, old = require("straps.context_summary"), text(b)
  local generate = summary.generate
  summary.generate = function(sources)
    management.pin(b, sources[1].first_block, sources[#sources].last_block)
    return { summary = "summary", sources = sources }
  end
  local ok, err = pcall(management.boundary, b, ctx(b), {}, {}, nil)
  summary.generate = generate
  assert.is_false(ok)
  assert.is_truthy(tostring(err):find("protection", 1, true))
  assert.are.equal(old, text(b))
end)

it("suppresses rejected paid candidates until the effective model changes", function()
  local b = fixture()
  straps.config.context_management.mode, straps.config.context_management.minimum_savings = "summary", 100000
  local summary, calls = require("straps.context_summary"), 0
  local generate = summary.generate
  summary.generate = function(sources)
    calls = calls + 1
    return { summary = "summary", sources = sources }
  end
  local ok, err = pcall(function()
    management.boundary(b, ctx(b), {}, {}, nil)
    management.boundary(b, ctx(b), {}, {}, nil)
    assert.are.equal(1, calls)
    state.append(b, "user", nil, "unrelated trailing request")
    management.boundary(b, ctx(b), {}, {}, nil)
    assert.are.equal(1, calls)
    straps.config.model = "different-effective-model"
    management.boundary(b, ctx(b), {}, {}, nil)
    assert.are.equal(2, calls)
    straps.config.model = defaults.model
    management.boundary(b, ctx(b), {}, {}, nil)
    assert.are.equal(2, calls)
    local blocks = state.list_blocks(b)
    vim.api.nvim_buf_set_lines(b, blocks[3].first_lnum - 1, blocks[3].last_lnum, false, { "changed source prose" })
    management.boundary(b, ctx(b), {}, {}, nil)
    assert.are.equal(3, calls)
    straps.config.context_management.retry = true
    management.boundary(b, ctx(b), {}, {}, nil)
    management.boundary(b, ctx(b), {}, {}, nil)
    assert.are.equal(5, calls)
  end)
  summary.generate = generate
  assert.is_true(ok, tostring(err))
end)

it("retains rejected source suppression after another interval is adopted and shifts its coordinates", function()
  local b = fixture()
  straps.config.context_management.mode = "summary"
  local blocks = state.list_blocks(b)
  vim.api.nvim_buf_set_lines(b, blocks[6].marker_lnum - 1, blocks[6].marker_lnum - 1, false,
    { "%%[straps:user]%% separate protected interval" })
  management.pin(b, 3, 5)
  local summary, calls = require("straps.context_summary"), {}
  local generate = summary.generate
  summary.generate = function(sources)
    local first = sources[1].text:match("assistant prose %d+")
    calls[#calls + 1] = first
    return { summary = first == "assistant prose 1" and "summary" or string.rep("x", 40000), sources = sources }
  end
  local ok, err = pcall(function()
    management.boundary(b, ctx(b), {}, {}, nil)
    management.unpin(b)
    management.boundary(b, ctx(b), {}, {}, nil)
    assert.is_truthy(text(b):find("[straps-context:", 1, true))
    management.pin(b, 3, 3)
    management.boundary(b, ctx(b), {}, {}, nil)
    assert.same({ "assistant prose 2", "assistant prose 1" }, calls)
  end)
  summary.generate = generate
  assert.is_true(ok, tostring(err))
end)

it("bounds retained summary attempts without evicting old failures and releases them on wipeout", function()
  local b = fixture()
  straps.config.context_management.mode = "summary"
  local summary, calls = require("straps.context_summary"), 0
  local generate = summary.generate
  summary.generate = function(sources)
    calls = calls + 1
    return { summary = "summary", sources = sources }
  end
  local function upvalue(fn, wanted)
    for i = 1, 100 do
      local name, value = debug.getupvalue(fn, i)
      if name == wanted then return value end
      if not name then break end
    end
    error("missing upvalue " .. wanted)
  end
  local ok, err = pcall(function()
    for i = 1, 256 do
      straps.config.max_tokens = i
      management.preview(b, ctx(b), { generate = true })
    end
    assert.are.equal(256, calls)
    straps.config.max_tokens = 257
    local accepted, reason = pcall(management.preview, b, ctx(b), { generate = true })
    assert.is_false(accepted)
    assert.is_truthy(tostring(reason):find("summary attempt history is full", 1, true))
    assert.are.equal(256, calls)
    straps.config.max_tokens = 1
    assert.same({}, management.preview(b, ctx(b), { generate = true }).proposals)
    straps.config.context_management.retry = true
    assert.are.equal(1, #management.preview(b, ctx(b), { generate = true }).proposals)
    assert.are.equal(257, calls)
    local failures = upvalue(upvalue(upvalue(management.preview, "preview_candidate"), "propose"), "failures")
    assert.is_table(failures[b])
    assert.are.equal(256, failures[b].count)
    vim.api.nvim_buf_delete(b, { force = true })
    assert.is_nil(failures[b])
  end)
  summary.generate = generate
  assert.is_true(ok, tostring(err))
end)

it("uses session idle timing across distinct runs", function()
  local b = fixture()
  straps.config.context_management.trigger = 1
  straps.config.context_management.idle_compaction, straps.config.context_management.idle_seconds = true, 1
  management.boundary(b, ctx(b), {}, {}, nil)
  local old = text(b)
  vim.b[b].straps_context_last_request = vim.uv.hrtime() / 1e9 - 2
  management.boundary(b, ctx(b), {}, {}, nil)
  assert.is_true(#text(b) < #old)
  assert.are.equal("idle", vim.b[b].straps_context_compaction.reason)
end)

local function durable_fixture()
  local b = fixture()
  vim.bo[b].buftype = ""
  vim.api.nvim_buf_set_name(b, vim.fn.tempname())
  vim.api.nvim_buf_call(b, function() vim.cmd("silent noautocmd write") end)
  return b
end

it("restores live text when the real persistence path throws during its disk read", function()
  local b = durable_fixture()
  local old, read, persist = text(b), vim.uv.fs_read, management.persist_checked
  local persisting = false
  management.persist_checked = function(...)
    persisting = true
    return persist(...)
  end
  vim.uv.fs_read = function(...)
    if persisting then error("injected disk read exception") end
    return read(...)
  end
  local ok, err = pcall(management.boundary, b, ctx(b), {}, {}, nil)
  vim.uv.fs_read, management.persist_checked = read, persist
  assert.is_false(ok)
  assert.is_truthy(tostring(err):find("live transcript restored", 1, true))
  assert.are.equal(old, text(b))
end)

it("reports ambiguous disk durability and restores live text when directory fsync fails", function()
  local b = durable_fixture()
  local old, sync, calls = text(b), vim.uv.fs_fsync, 0
  local call, adopted = vim.api.nvim_buf_call, false
  vim.api.nvim_buf_call = function(bufnr, fn)
    local result = call(bufnr, fn)
    if bufnr == b then adopted = true end
    return result
  end
  vim.uv.fs_fsync = function(fd)
    local stat = vim.uv.fs_fstat(fd)
    if adopted and stat and stat.type == "directory" then
      calls = calls + 1
      return nil, "injected directory sync failure"
    end
    return sync(fd)
  end
  local ok, err = pcall(management.boundary, b, ctx(b), {}, {}, nil)
  vim.uv.fs_fsync, vim.api.nvim_buf_call = sync, call
  assert.is_false(ok)
  assert(calls > 0, tostring(err))
  assert.is_truthy(tostring(err):find("disk outcome ambiguous", 1, true))
  assert.are.equal(old, text(b))
end)

it("retains retrieval protection when a real loop provider response is cancelled", function()
  local b = fixture()
  straps.config.context_management.trigger = 1
  define("fn.provider", [[return function(_, ctx)
    require("straps.loop").stop(ctx.bufnr)
    return { content = {}, stop_reason = "cancelled" }
  end]])
  management.boundary(b, ctx(b), {}, {}, nil)
  management.protect(b)
  local loop = require("straps.loop")
  loop.start(b)
  assert.is_true(vim.wait(5000, function() return not loop.running(b) end, 10))
  assert.is_nil(management.retrieval_limit(b))
  management.consumed(b)
end)
it("catches an unexpected persistence exception after mutation and restores live text", function()
  local b = fixture()
  local old, persist = text(b), management.persist_checked
  management.persist_checked = function() error("unexpected persistence exception") end
  local ok, err = pcall(management.boundary, b, ctx(b), {}, {}, nil)
  management.persist_checked = persist
  assert.is_false(ok)
  assert.is_truthy(tostring(err):find("unexpected persistence exception", 1, true))
  assert.is_truthy(tostring(err):find("live transcript restored", 1, true))
  assert.is_truthy(tostring(err):find("disk outcome ambiguous", 1, true))
  assert.are.equal(old, text(b))
end)

it("suppresses adoption failures until the effective request cap changes", function()
  local b = fixture()
  straps.config.context_management.mode = "summary"
  local summary, generate, persist = require("straps.context_summary"), require("straps.context_summary").generate, management.persist_checked
  local calls = 0
  summary.generate = function(sources)
    calls = calls + 1
    return { summary = "summary", sources = sources }
  end
  management.persist_checked = function() return nil, "injected adoption failure" end
  local ok, err = pcall(function()
    assert.is_false(pcall(management.boundary, b, ctx(b), {}, {}, nil))
    management.boundary(b, ctx(b), {}, {}, nil)
    assert.are.equal(1, calls)
    straps.config.max_tokens = 31415
    assert.is_false(pcall(management.boundary, b, ctx(b), {}, {}, nil))
    assert.are.equal(2, calls)
  end)
  summary.generate, management.persist_checked = generate, persist
  assert.is_true(ok, tostring(err))
end)

it("suppresses every unchanged rejected span without alternating retries", function()
  local b = fixture()
  straps.config.context_management.mode, straps.config.context_management.minimum_savings = "summary", 100000
  local blocks = state.list_blocks(b)
  vim.api.nvim_buf_set_lines(b, blocks[6].marker_lnum - 1, blocks[6].marker_lnum - 1, false,
    { "%%[straps:user]%% separate protected interval" })
  local summary, calls = require("straps.context_summary"), {}
  local generate = summary.generate
  summary.generate = function(sources)
    calls[#calls + 1] = sources[1].first_block
    return { summary = "summary", sources = sources }
  end
  local ok, err = pcall(function()
    for _ = 1, 5 do management.boundary(b, ctx(b), {}, {}, nil) end
    assert.same({ 3, 7 }, calls)
    straps.config.max_tokens = 27182
    for _ = 1, 3 do management.boundary(b, ctx(b), {}, {}, nil) end
    assert.same({ 3, 7, 3, 7 }, calls)
  end)
  summary.generate = generate
  assert.is_true(ok, tostring(err))
end)
