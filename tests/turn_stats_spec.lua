-- tests/turn_stats_spec.lua — per-turn stats on the Cinch rule, the wait accumulator and the ◆N count.
-- Run from the repo root: busted tests/turn_stats_spec.lua

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
require("straps").setup({ session_dir = vim.fn.tempname(), terminal_status = false })
local api = vim.api
local ui, state = require("straps.ui"), require("straps.state")
local loop, registry = require("straps.loop"), require("straps.registry")
local attention = require("straps.attention")
local default_confirm = registry.get("hook.confirm")

local function rule_text(buf, lnum)
  local ns = api.nvim_get_namespaces().straps_render
  for _, m in ipairs(api.nvim_buf_get_extmarks(buf, ns, { lnum - 1, 0 }, { lnum - 1, -1 }, { details = true })) do
    local d = m[4]
    if d.virt_text and d.virt_text_pos == "overlay" then
      local parts = {}
      for _, chunk in ipairs(d.virt_text) do parts[#parts + 1] = chunk[1] end
      return table.concat(parts)
    end
  end
end

local function use(id) return '%%[straps:tool_use]%% {"id":"' .. id .. '","name":"custom"}' end
local function result(id) return '%%[straps:tool_result]%% {"id":"' .. id .. '"}' end

local function transcript(lines)
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "straps"
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  registry.call("fn.render", buf)
  return buf
end

local function assistant_rows(buf)
  local rows = {}
  for i, line in ipairs(api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if line == "%%[straps:assistant]%%" then rows[#rows + 1] = i end
  end
  return rows
end

it("counts calls per turn and shows no segment for a turn without calls", function()
  local buf = transcript({
    "%%[straps:user]%%", "go",
    "%%[straps:assistant]%%", use("a1"), "{}", use("a2"), "{}", use("a3"), "{}",
    result("a1"), "x", result("a2"), "x", result("a3"), "x",
    "%%[straps:assistant]%%", use("b1"), "{}", result("b1"), "x",
    "%%[straps:assistant]%%", "done",
  })
  local rows = assistant_rows(buf)
  assert(rule_text(buf, rows[1]):find("Cinch · 3 calls ", 1, true), rule_text(buf, rows[1]))
  assert(rule_text(buf, rows[2]):find("Cinch · 1 call ", 1, true), rule_text(buf, rows[2]))
  assert(not rule_text(buf, rows[3]):find("·", 1, true), rule_text(buf, rows[3]))
end)

it("shows recorded seconds and output tokens, and omits a missing token count", function()
  local buf = transcript({
    "%%[straps:assistant]%%", use("s1"), "{}", result("s1"), "x",
    "%%[straps:assistant]%%", use("s2"), "{}", result("s2"), "x",
  })
  ui.record_turn_stats(buf, "s1", 14200, 1234)
  ui.record_turn_stats(buf, "s2", 3000, nil)
  registry.call("fn.render", buf)
  local rows = assistant_rows(buf)
  assert(rule_text(buf, rows[1]):find("1 call · 14s · 1.2k out ", 1, true), rule_text(buf, rows[1]))
  assert(rule_text(buf, rows[2]):find("1 call · 3s ━", 1, true), rule_text(buf, rows[2]))
end)

it("keeps numbers on their turn when lines are inserted above or an earlier turn is excised", function()
  local buf = transcript({
    "%%[straps:assistant]%%", use("e1"), "{}", result("e1"), "x",
    "%%[straps:assistant]%%", use("e2"), "{}", result("e2"), "x",
  })
  ui.record_turn_stats(buf, "e1", 1000, 10)
  ui.record_turn_stats(buf, "e2", 2000, 20)
  api.nvim_buf_set_lines(buf, 0, 0, false, { "%%[straps:user]%%", "inserted" })
  registry.call("fn.render", buf)
  local rows = assistant_rows(buf)
  assert(rule_text(buf, rows[1]):find("1s · 10 out", 1, true), rule_text(buf, rows[1]))
  assert(rule_text(buf, rows[2]):find("2s · 20 out", 1, true), rule_text(buf, rows[2]))
  api.nvim_buf_set_lines(buf, 2, 7, false, {})
  registry.call("fn.render", buf)
  rows = assistant_rows(buf)
  assert.are.equal(1, #rows)
  assert(rule_text(buf, rows[1]):find("2s · 20 out", 1, true), rule_text(buf, rows[1]))
end)

it("replace_transcript removing a middle turn shows no other turn's numbers", function()
  local buf = state.new_session()
  local lines = {
    "%%[straps:assistant]%%", use("r1"), "{}", result("r1"), "x",
    "%%[straps:assistant]%%", use("r2"), "{}", result("r2"), "x",
    "%%[straps:assistant]%%", use("r3"), "{}", result("r3"), "x",
  }
  state.replace_transcript(buf, lines)
  ui.record_turn_stats(buf, "r1", 1000, 1)
  ui.record_turn_stats(buf, "r2", 2000, 2)
  ui.record_turn_stats(buf, "r3", 3000, 3)
  state.replace_transcript(buf, vim.list_extend(vim.list_slice(lines, 1, 5), vim.list_slice(lines, 11, 15)))
  registry.call("fn.render", buf)
  local rows = assistant_rows(buf)
  assert.are.equal(2, #rows)
  assert(rule_text(buf, rows[1]):find("1s · 1 out", 1, true), rule_text(buf, rows[1]))
  assert(rule_text(buf, rows[2]):find("3s · 3 out", 1, true), rule_text(buf, rows[2]))
end)

it(":edit! keeps numbers only for turns whose key is still in the file", function()
  local path = vim.fn.tempname() .. ".straps"
  vim.fn.writefile({
    "%%[straps:assistant]%%", use("k1"), "{}", result("k1"), "x",
    "%%[straps:assistant]%%", use("k2"), "{}", result("k2"), "x",
  }, path)
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  local buf = api.nvim_get_current_buf()
  ui.record_turn_stats(buf, "k1", 1000, 1)
  ui.record_turn_stats(buf, "k2", 2000, 2)
  vim.fn.writefile({ "%%[straps:assistant]%%", use("k2"), "{}", result("k2"), "x",
    "%%[straps:assistant]%%", use("k9"), "{}", result("k9"), "x" }, path)
  vim.cmd("edit!")
  registry.call("fn.render", buf)
  local rows = assistant_rows(buf)
  assert(rule_text(buf, rows[1]):find("2s · 2 out", 1, true), rule_text(buf, rows[1]))
  assert(rule_text(buf, rows[2]):find("1 call ━", 1, true), rule_text(buf, rows[2]))
  vim.cmd("enew!")
end)

it("a nil or replay id stores nothing, and duplicate first ids show calls only", function()
  assert.is_nil(ui.turn_stats_key({ { id = nil }, { id = "" }, { id = "straps-replay-1" } }))
  assert.are.equal("ok", ui.turn_stats_key({ { id = nil }, { id = "ok" } }))
  local buf = transcript({
    "%%[straps:assistant]%%", use("d1"), "{}", result("d1"), "x",
    "%%[straps:assistant]%%", use("d1"), "{}", result("d1"), "x",
    "%%[straps:assistant]%%", '%%[straps:tool_use]%% {"name":"custom"}', "{}",
  })
  ui.record_turn_stats(buf, "d1", 5000, 5)
  registry.call("fn.render", buf)
  local rows = assistant_rows(buf)
  assert(rule_text(buf, rows[1]):find("1 call ━", 1, true), rule_text(buf, rows[1]))
  assert(rule_text(buf, rows[2]):find("1 call ━", 1, true), rule_text(buf, rows[2]))
  assert(rule_text(buf, rows[3]):find("1 call ━", 1, true), rule_text(buf, rows[3]))
end)

it("the rule finds the turn's key past a tool_use without an id or with a replay id", function()
  local buf = transcript({
    "%%[straps:assistant]%%", '%%[straps:tool_use]%% {"name":"custom"}', "{}",
    '%%[straps:tool_use]%% {"id":"straps-replay-1","name":"custom"}', "{}", use("ok"), "{}",
    '%%[straps:tool_result]%% {}', "x", result("straps-replay-1"), "x", result("ok"), "x",
  })
  ui.record_turn_stats(buf, "ok", 4000, 9)
  registry.call("fn.render", buf)
  local text = rule_text(buf, assistant_rows(buf)[1])
  assert(text:find("Cinch · 3 calls · 4s · 9 out", 1, true), text)
end)

it("a release called twice decrements once, and a later wait still grows wait_ms", function()
  local buf = api.nvim_create_buf(false, true)
  local release = attention.wait({ bufnr = buf }, "permission")
  release()
  release()
  local before = attention.wait_ms(buf)
  local again = attention.wait({ bufnr = buf }, "permission")
  vim.uv.sleep(30)
  assert(attention.wait_ms(buf) - before >= 25, tostring(attention.wait_ms(buf) - before))
  again()
  local closed = attention.wait_ms(buf)
  vim.uv.sleep(30)
  assert.are.equal(closed, attention.wait_ms(buf))
end)

it("wait_ms survives BufUnload of the attention record and resets at BufWipeout", function()
  local buf = api.nvim_create_buf(true, false)
  local release = attention.wait({ bufnr = buf }, "question")
  vim.uv.sleep(20)
  api.nvim_exec_autocmds("BufUnload", { buffer = buf })
  vim.uv.sleep(20)
  release()
  assert(attention.wait_ms(buf) >= 35, tostring(attention.wait_ms(buf)))
  api.nvim_buf_delete(buf, { force = true })
  assert.are.equal(0, attention.wait_ms(buf))
  release()
  assert.are.equal(0, attention.wait_ms(buf))
end)

it("a nil ctx or a non-number bufnr skips accounting", function()
  assert.has_no.errors(function()
    attention.wait(nil, "consent")()
    attention.wait({ bufnr = "x" }, "consent")()
  end)
end)

after_each(function()
  for _, b in ipairs(loop.running_sessions()) do loop.stop(b) end
  vim.wait(500, function() return #loop.running_sessions() == 0 end, 10)
end)

local function define_ping()
  registry.define({ name = "tool.stats_ping", kind = "tool", source = [[return function() return "pong" end]] })
end

local function define_waiting_confirm()
  registry.define({ name = "hook.confirm", kind = "hook", source = [[return function(name, input, ctx)
    local release = require("straps.attention").wait(ctx, "permission")
    local ok = ctx.await(function(done) _G.straps_stats_decide = done end)
    release()
    release()
    return ok
  end]] })
end

local function define_provider(ids, usage)
  _G.straps_stats_calls = 0
  define_ping()
  registry.define({ name = "fn.provider", kind = "fn", source = ([=[return function(req, ctx)
    _G.straps_stats_calls = _G.straps_stats_calls + 1
    if _G.straps_stats_calls > 1 then
      return { stop_reason = 'end_turn', content = {{ type = 'text', text = 'Done' }} }
    end
    local content = {}
    for _, id in ipairs(%s) do
      content[#content + 1] = { type = 'tool_use', id = id, name = 'stats_ping', input = {} }
    end
    return { stop_reason = 'tool_use', content = content, usage = %s }
  end]=]):format(vim.inspect(ids), usage and vim.inspect(usage) or "nil") })
end

local function decide_all(buf)
  while loop.running(buf) do
    if not vim.wait(2000, function() return _G.straps_stats_decide ~= nil or not loop.running(buf) end, 10) then
      error("no decision requested")
    end
    local decide = _G.straps_stats_decide
    _G.straps_stats_decide = nil
    if decide then decide(true) end
    vim.wait(200, function() return _G.straps_stats_decide ~= nil or not loop.running(buf) end, 10)
  end
end

it("a run stores the turn's seconds without the permission wait, and its output tokens", function()
  define_waiting_confirm()
  define_provider({ "run1", "run2" }, { output_tokens = 42, input_tokens = 5 })
  local buf = ui.open_session("split", { explicit_split = true, instruction = "go" })
  local waited = attention.wait_ms(buf)
  loop.start(buf)
  assert(vim.wait(2000, function() return _G.straps_stats_decide ~= nil end, 10))
  assert.are.equal("🤖 1 ◆1", ui.agents_status())
  vim.wait(2100, function() return false end, 50)
  decide_all(buf)
  assert(attention.wait_ms(buf) - waited >= 2000, tostring(attention.wait_ms(buf) - waited))
  registry.call("fn.render", buf)
  local text = rule_text(buf, assistant_rows(buf)[1])
  assert(text:find("Cinch · 2 calls · 0s · 42 out ", 1, true), text)
  assert.are.equal("", ui.agents_status())
end)

it("a real run's seconds count tool time and subtract only this turn's wait growth", function()
  registry.define({ name = "hook.confirm", kind = "hook", source = [[return function() return true end]] })
  registry.define({ name = "tool.stats_slow", kind = "tool", source = [[return function(input, ctx)
    return ctx.await(function(done) vim.defer_fn(function() done("slow") end, 1600) end)
  end]] })
  _G.straps_stats_calls = 0
  registry.define({ name = "fn.provider", kind = "fn", source = [=[return function()
    _G.straps_stats_calls = _G.straps_stats_calls + 1
    if _G.straps_stats_calls > 1 then return { stop_reason = 'end_turn', content = {{ type = 'text', text = 'Done' }} } end
    return { stop_reason = 'tool_use', content = {{ type = 'tool_use', id = 'slow1', name = 'stats_slow', input = {} }} }
  end]=] })
  local buf = ui.open_session("split", { explicit_split = true, instruction = "go" })
  local earlier = attention.wait({ bufnr = buf }, "question")
  vim.wait(1300, function() return false end, 50)
  earlier()
  assert(attention.wait_ms(buf) >= 1200, tostring(attention.wait_ms(buf)))
  loop.start(buf)
  assert(vim.wait(4000, function() return not loop.running(buf) end, 10))
  registry.call("fn.render", buf)
  local text = rule_text(buf, assistant_rows(buf)[1])
  assert(text:find("Cinch · 1 call · [12]s ", 1) , text)
  vim.cmd("silent! only!")
end)

it("a response without usage stores seconds and no tokens", function()
  define_waiting_confirm()
  define_provider({ "nou1" }, nil)
  local buf = ui.open_session("split", { explicit_split = true, instruction = "go" })
  loop.start(buf)
  decide_all(buf)
  registry.call("fn.render", buf)
  local text = rule_text(buf, assistant_rows(buf)[1])
  assert(text:find("Cinch · 1 call · 0s ━", 1, true), text)
end)

it("a response without usage shows no tokens even after an earlier response had usage", function()
  define_waiting_confirm()
  define_ping()
  _G.straps_stats_calls = 0
  registry.define({ name = "fn.provider", kind = "fn", source = [=[return function(req, ctx)
    _G.straps_stats_calls = _G.straps_stats_calls + 1
    local n = _G.straps_stats_calls
    if n > 2 then return { stop_reason = 'end_turn', content = {{ type = 'text', text = 'Done' }} } end
    return { stop_reason = 'tool_use', usage = n == 1 and { output_tokens = 99 } or nil,
      content = {{ type = 'tool_use', id = 'mix' .. n, name = 'stats_ping', input = {} }} }
  end]=] })
  local buf = ui.open_session("split", { explicit_split = true, instruction = "go" })
  loop.start(buf)
  decide_all(buf)
  registry.call("fn.render", buf)
  local rows = assistant_rows(buf)
  assert(rule_text(buf, rows[1]):find("1 call · 0s · 99 out ", 1, true), rule_text(buf, rows[1]))
  assert(rule_text(buf, rows[2]):find("1 call · 0s ━", 1, true), rule_text(buf, rows[2]))
end)

it("the rule shows a turn's numbers before the next provider call returns", function()
  define_waiting_confirm()
  define_ping()
  _G.straps_stats_calls = 0
  registry.define({ name = "fn.provider", kind = "fn", source = [=[return function(req, ctx)
    _G.straps_stats_calls = _G.straps_stats_calls + 1
    if _G.straps_stats_calls > 1 then
      ctx.await(function(done) _G.straps_stats_finish = done end)
      return { stop_reason = 'end_turn', content = {{ type = 'text', text = 'Done' }} }
    end
    return { stop_reason = 'tool_use', usage = { output_tokens = 5 },
      content = {{ type = 'tool_use', id = 'live1', name = 'stats_ping', input = {} }} }
  end]=] })
  _G.straps_stats_finish = nil
  local buf = ui.open_session("split", { explicit_split = true, instruction = "go" })
  loop.start(buf)
  assert(vim.wait(2000, function() return _G.straps_stats_decide ~= nil end, 10))
  local decide = _G.straps_stats_decide
  _G.straps_stats_decide = nil
  decide(true)
  assert(vim.wait(2000, function() return _G.straps_stats_finish ~= nil end, 10))
  local row = assistant_rows(buf)[1]
  assert(vim.wait(500, function() return (rule_text(buf, row) or ""):find("5 out", 1, true) ~= nil end, 10),
    rule_text(buf, row))
  _G.straps_stats_finish()
  assert(vim.wait(2000, function() return not loop.running(buf) end, 10))
end)

it("a cancelled turn stores no seconds", function()
  define_waiting_confirm()
  define_provider({ "can1" }, { output_tokens = 7 })
  local buf = ui.open_session("split", { explicit_split = true, instruction = "go" })
  loop.start(buf)
  assert(vim.wait(2000, function() return _G.straps_stats_decide ~= nil end, 10))
  loop.stop(buf)
  local decide = _G.straps_stats_decide
  _G.straps_stats_decide = nil
  decide(false)
  assert(vim.wait(2000, function() return not loop.running(buf) end, 10))
  registry.call("fn.render", buf)
  local text = rule_text(buf, assistant_rows(buf)[1])
  assert(text:find("Cinch · 1 call ━", 1, true), text)
end)

it("◆N counts a question wait inside a permission wait once, survives :edit!, and redraws the tabline", function()
  define_waiting_confirm()
  define_provider({ "q1" }, nil)
  local buf = ui.open_session("split", { explicit_split = true, instruction = "go" })
  loop.start(buf)
  assert(vim.wait(2000, function() return _G.straps_stats_decide ~= nil end, 10))
  local real = vim.cmd
  local seen = {}
  vim.cmd = function(c) seen[#seen + 1] = c end
  local question = attention.wait({ bufnr = buf }, "question")
  vim.cmd = real
  assert(vim.tbl_contains(seen, "redrawtabline"), vim.inspect(seen))
  seen = {}
  assert.are.equal("🤖 1 ◆1", ui.agents_status())
  question()
  question()
  assert.are.equal("🤖 1 ◆1", ui.agents_status())
  vim.uv.sleep(20)
  local pre_edit = attention.wait_ms(buf)
  vim.cmd = function(c) seen[#seen + 1] = c end
  local edit_ok = pcall(real, "silent! edit!")
  local before = attention.wait_ms(buf)
  local late_ok, late = pcall(attention.wait, { bufnr = buf }, "permission")
  vim.cmd = real
  assert(late_ok, tostring(late))
  assert(before >= pre_edit, before .. " < " .. pre_edit)
  assert(edit_ok)
  assert(vim.tbl_contains(seen, "redrawtabline"), vim.inspect(seen))
  vim.uv.sleep(30)
  assert(attention.wait_ms(buf) - before >= 25)
  late()
  decide_all(buf)
  assert.are.equal("", ui.agents_status())
end)

it("a wait left open when the run finishes keeps growing until it is released", function()
  define_waiting_confirm()
  define_provider({ "open1" }, nil)
  local buf = ui.open_session("split", { explicit_split = true, instruction = "go" })
  loop.start(buf)
  assert(vim.wait(2000, function() return _G.straps_stats_decide ~= nil end, 10))
  local left_open = attention.wait({ bufnr = buf }, "question")
  decide_all(buf)
  local at_finish = attention.wait_ms(buf)
  vim.uv.sleep(30)
  assert(attention.wait_ms(buf) - at_finish >= 25)
  assert.is_false(attention.waiting(buf))
  left_open()
  local released = attention.wait_ms(buf)
  vim.uv.sleep(30)
  assert.are.equal(released, attention.wait_ms(buf))
end)

it("a released wait clears ◆ while the run continues", function()
  _G.straps_stats_wake = nil
  registry.define({ name = "tool.stats_sleep", kind = "tool", source = [[return function(input, ctx)
    return ctx.await(function(done) _G.straps_stats_wake = done end)
  end]] })
  registry.define({ name = "hook.confirm", kind = "hook", source = [[return function() return true end]] })
  _G.straps_stats_calls = 0
  registry.define({ name = "fn.provider", kind = "fn", source = [=[return function()
    _G.straps_stats_calls = _G.straps_stats_calls + 1
    if _G.straps_stats_calls > 1 then return { stop_reason = 'end_turn', content = {{ type = 'text', text = 'Done' }} } end
    return { stop_reason = 'tool_use', content = {{ type = 'tool_use', id = 'sleep1', name = 'stats_sleep', input = {} }} }
  end]=] })
  local buf = ui.open_session("split", { explicit_split = true, instruction = "go" })
  loop.start(buf)
  assert(vim.wait(2000, function() return _G.straps_stats_wake ~= nil end, 10))
  local release = attention.wait({ bufnr = buf }, "question")
  assert.are.equal("🤖 1 ◆1", ui.agents_status())
  release()
  assert.is_true(loop.running(buf))
  assert.are.equal("🤖 1", ui.agents_status())
  _G.straps_stats_wake(true, "woke")
  assert(vim.wait(2000, function() return not loop.running(buf) end, 10))
  vim.cmd("silent! only!")
end)

it("one running session that never waited shows no ◆", function()
  registry.define({ name = "hook.confirm", kind = "hook", source = [[return function() return true end]] })
  registry.define({ name = "fn.provider", kind = "fn", source = [=[return function(req, ctx)
    ctx.await(function(done) _G.straps_stats_finish = done end)
    return { stop_reason = 'end_turn', content = {{ type = 'text', text = 'Done' }} }
  end]=] })
  local buf = ui.open_session("split", { explicit_split = true, instruction = "go" })
  loop.start(buf)
  assert(vim.wait(2000, function() return _G.straps_stats_finish ~= nil end, 10))
  assert.are.equal("🤖 1", ui.agents_status())
  _G.straps_stats_finish()
  assert(vim.wait(2000, function() return not loop.running(buf) end, 10))
end)

it("a deferred permission wait stops growing when loop.stop cancels it", function()
  require("straps").config.permission_review = "deferred"
  registry.define({ name = "hook.confirm", kind = "hook", doc = default_confirm.doc, source = default_confirm.source })
  registry.define({ name = "fn.provider", kind = "fn", source = [=[return function()
    return { stop_reason = 'tool_use', content = {{ type = 'tool_use', id = 'cancel1', name = 'bash', input = { command = 'true' } }} }
  end]=] })
  local review = require("straps.permission_review")
  local buf = ui.open_session("split", { explicit_split = true, instruction = "go" })
  local waited = attention.wait_ms(buf)
  loop.start(buf)
  assert(vim.wait(2000, function() return #review.entries() > 0 end, 10))
  vim.uv.sleep(30)
  loop.stop(buf)
  assert(vim.wait(2000, function() return not loop.running(buf) end, 10))
  local stopped = attention.wait_ms(buf)
  assert(stopped - waited >= 25, tostring(stopped - waited))
  vim.wait(60, function() return false end, 10)
  assert.are.equal(stopped, attention.wait_ms(buf))
  assert.are.equal(0, #review.entries())
  assert.is_false(attention.waiting(buf))
  vim.cmd("silent! only!")
end)

it("a deferred permission review excludes its wait from turn seconds and shows ◆1 across :edit!", function()
  require("straps").config.permission_review = "deferred"
  registry.define({ name = "hook.confirm", kind = "hook", doc = default_confirm.doc, source = default_confirm.source })
  _G.straps_stats_calls = 0
  registry.define({ name = "fn.provider", kind = "fn", source = [=[return function()
    _G.straps_stats_calls = _G.straps_stats_calls + 1
    if _G.straps_stats_calls > 1 then return { stop_reason = 'end_turn', content = {{ type = 'text', text = 'Done' }} } end
    return { stop_reason = 'tool_use', content = {{ type = 'tool_use', id = 'deferred1', name = 'bash', input = { command = 'true' } }},
      usage = { output_tokens = 7 } }
  end]=] })
  local review = require("straps.permission_review")
  local buf = ui.open_session("split", { explicit_split = true, instruction = "go" })
  local waited = attention.wait_ms(buf)
  loop.start(buf)
  assert(vim.wait(2000, function() return #review.entries() > 0 end, 10))
  pcall(vim.cmd, "silent! edit!")
  assert.are.equal("🤖 1 ◆1", ui.agents_status())
  vim.wait(2100, function() return false end, 50)
  assert.is_true(review.review(buf))
  api.nvim_feedkeys("y", "mx", false)
  assert(vim.wait(3000, function() return not loop.running(buf) end, 10))
  assert(attention.wait_ms(buf) - waited >= 2000, tostring(attention.wait_ms(buf) - waited))
  registry.call("fn.render", buf)
  local text = rule_text(buf, assistant_rows(buf)[1])
  assert(text:find("Cinch · 1 call · 0s · 7 out ", 1, true), text)
  assert.are.equal("", ui.agents_status())
end)

it("a stalled turn stores no stats", function()
  define_waiting_confirm()
  registry.define({ name = "tool.stats_fail", kind = "tool", source = [[return function() error("broken", 0) end]] })
  _G.straps_stats_calls = 0
  registry.define({ name = "fn.provider", kind = "fn", source = [=[return function()
    _G.straps_stats_calls = _G.straps_stats_calls + 1
    return { stop_reason = 'tool_use', usage = { output_tokens = 3 },
      content = {{ type = 'tool_use', id = 'stall' .. _G.straps_stats_calls, name = 'stats_fail', input = {} }} }
  end]=] })
  local straps_config = require("straps").config
  local saved = straps_config.stall_limit
  straps_config.stall_limit = 1
  local ok, err = pcall(function()
    local buf = ui.open_session("split", { explicit_split = true, instruction = "go" })
    loop.start(buf)
    decide_all(buf)
    registry.call("fn.render", buf)
    local text = rule_text(buf, assistant_rows(buf)[1])
    assert(text:find("Cinch · 1 call ━", 1, true), text)
    assert.is_nil(text:find("3 out", 1, true), text)
    assert.are.equal(1, _G.straps_stats_calls)
  end)
  straps_config.stall_limit = saved
  assert(ok, tostring(err))
end)
