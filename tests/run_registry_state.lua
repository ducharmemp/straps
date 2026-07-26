-- Tests for straps.registry and straps.state.
-- Run from the repo root: nvim --headless -l tests/run_registry_state.lua

local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(vim.fn.fnamemodify(here, ":p"), ":h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local registry = require("straps.registry")
local state = require("straps.state")
-- Hermetic: durable sessions write under a throwaway dir, never the real data dir.
require("straps").config.session_dir = vim.fn.tempname()

local fails = 0
local function case(name, fn)
  local ok, err = pcall(fn)
  if ok then
    print("PASS  " .. name)
  else
    fails = fails + 1
    print("FAIL  " .. name .. "\n      " .. tostring(err))
  end
end

local function eq(got, want, label)
  if not vim.deep_equal(got, want) then
    error(("%s:\n  got:  %s\n  want: %s"):format(
      label or "not equal", vim.inspect(got), vim.inspect(want)), 2)
  end
end

-- --------------------------------------------------------------- registry

case("define and call", function()
  local e = registry.define{
    name = "fn.add", kind = "fn",
    source = "return function(a, b) return a + b end",
  }
  eq(e.version, 1, "version")
  eq(registry.call("fn.add", 2, 3), 5, "call result")
  eq(registry.get("fn.add").name, "fn.add", "get")
end)

case("redefine is late-bound at existing call sites", function()
  registry.define{ name = "fn.greet", kind = "fn",
    source = 'return function() return "v1" end' }
  local site = function() return registry.call("fn.greet") end
  eq(site(), "v1")
  registry.define{ name = "fn.greet", kind = "fn",
    source = 'return function() return "v2" end' }
  eq(site(), "v2", "same call site sees new definition")
  eq(registry.get("fn.greet").version, 2, "version bumped")
end)

case("bad source rejected, old entry kept", function()
  registry.define{ name = "fn.keep", kind = "fn",
    source = 'return function() return "old" end' }
  -- does not compile
  assert(not pcall(registry.define,
    { name = "fn.keep", kind = "fn", source = "this is not lua ((" }))
  -- compiles but does not return a function
  assert(not pcall(registry.define,
    { name = "fn.keep", kind = "fn", source = "return 42" }))
  -- raises while loading
  assert(not pcall(registry.define,
    { name = "fn.keep", kind = "fn", source = 'error("boom")' }))
  eq(registry.call("fn.keep"), "old", "old behavior intact")
  eq(registry.get("fn.keep").version, 1, "version untouched")
end)

case("define validates name and kind", function()
  assert(not pcall(registry.define, { kind = "fn", source = "return function() end" }))
  assert(not pcall(registry.define, { name = "fn.x", kind = "nope", source = "return function() end" }))
  assert(not pcall(registry.define, { name = "fn.x", kind = "fn" }))
  assert(not pcall(registry.define, { name = "tool.bad/name", kind = "tool", source = "return function() end" }))
  assert(not pcall(registry.define, { name = "fn", kind = "fn", source = "return function() end" }))
  assert(not pcall(registry.define, { name = "skill.bad name", kind = "skill", source = "body" }))
end)

case("call errors on missing, try_call returns nil", function()
  assert(not pcall(registry.call, "fn.does_not_exist"))
  eq(registry.try_call("fn.does_not_exist"), nil)
  registry.define{ name = "fn.thrower", kind = "fn",
    source = 'return function() error("inside") end' }
  assert(not pcall(registry.try_call, "fn.thrower"),
    "errors inside the fn propagate through try_call")
end)

case("names is sorted and filters by kind", function()
  registry.define{ name = "tool.zz", kind = "tool", source = "return function() end" }
  registry.define{ name = "tool.aa", kind = "tool", source = "return function() end" }
  registry.define{ name = "hook.hh", kind = "hook", source = "return function() end" }
  eq(registry.names("tool"), { "tool.aa", "tool.zz" })
  local all = registry.names()
  for i = 2, #all do
    assert(all[i - 1] < all[i], "names() sorted")
  end
end)

case("define_default only defines when absent", function()
  registry.define{ name = "fn.dd", kind = "fn",
    source = 'return function() return "user" end' }
  registry.define_default{ name = "fn.dd", kind = "fn",
    source = 'return function() return "builtin" end' }
  eq(registry.call("fn.dd"), "user", "existing entry not clobbered")
  registry.define_default{ name = "fn.dd2", kind = "fn",
    source = 'return function() return "builtin" end' }
  eq(registry.call("fn.dd2"), "builtin", "absent entry defined")
end)

case("remove", function()
  registry.define{ name = "fn.gone", kind = "fn", source = "return function() end" }
  registry.remove("fn.gone")
  eq(registry.get("fn.gone"), nil)
end)

case("scope-aware remove un-shadows a session-scoped entry", function()
  -- A global entry shadowed by a session-scoped one: remove (with that scope
  -- active) must drop the shadow and un-cover the global, not delete global.
  registry.define{ name = "fn.shadowed", kind = "fn",
    source = 'return function() return "global" end' }
  local sbuf = vim.api.nvim_create_buf(false, true)
  registry.ensure_scope(sbuf)
  local prev = registry.set_active_scope(sbuf)
  registry.define({ name = "fn.shadowed", kind = "fn",
    source = 'return function() return "scoped" end' }, { scope = sbuf })
  eq(registry.call("fn.shadowed"), "scoped", "scoped shadow resolves while active")
  local removed = registry.remove("fn.shadowed")
  assert(removed, "remove reported nothing removed")
  eq(registry.call("fn.shadowed"), "global", "global re-exposed after shadow removed")
  registry.set_active_scope(prev)
  -- Global is still intact and now the only definition.
  eq(registry.call("fn.shadowed"), "global")
  registry.remove("fn.shadowed", { scope = "global" })
  eq(registry.get("fn.shadowed"), nil)
end)

case("hook.on_define fires and cannot break define", function()
  local seen = {}
  registry.define{ name = "hook.on_define", kind = "hook",
    source = "return function(entry) _G.__straps_seen(entry) end" }
  _G.__straps_seen = function(entry) seen[#seen + 1] = entry.name end
  registry.define{ name = "fn.watched", kind = "fn", source = "return function() end" }
  eq(seen, { "fn.watched" })
  registry.define{ name = "hook.on_define", kind = "hook",
    source = 'return function() error("hook blew up") end' }
  registry.define{ name = "fn.watched2", kind = "fn", source = "return function() end" } -- must not raise
  assert(registry.get("fn.watched2"), "define survived a broken on_define")
  registry.remove("hook.on_define")
  _G.__straps_seen = nil
end)

case("render -> execute round-trip", function()
  registry.define{
    name = "tool.rt", kind = "tool",
    doc = 'docs with "quotes" and\nnewline',
    input_schema = { type = "object", properties = { path = { type = "string" } } },
    source = 'return function(input) return "rt:" .. input.path end',
  }
  local before = registry.get("tool.rt")
  assert(load(registry.render("tool.rt"), "render"))()
  local after = registry.get("tool.rt")
  eq(after.version, before.version + 1, "re-executed define bumps version")
  eq(after.source, before.source, "source round-trips")
  eq(after.doc, before.doc, "doc round-trips")
  eq(after.input_schema, before.input_schema, "input_schema round-trips")
  eq(registry.call("tool.rt", { path = "x" }), "rt:x", "behavior round-trips")
end)

case("render bumps bracket level on collision", function()
  registry.define{ name = "fn.bracket", kind = "fn",
    source = 'return function() return "a]==]b" end' }
  local chunk = registry.render("fn.bracket")
  assert(not chunk:find("source = [==[", 1, true), "level 2 would collide")
  assert(load(chunk, "render"))()
  eq(registry.call("fn.bracket"), "a]==]b")
  -- boundary collision: source ending in "]" + equals must not merge with the closer
  registry.define{ name = "fn.bracket2", kind = "fn",
    source = 'return function() return 7 end --]==' }
  assert(load(registry.render("fn.bracket2"), "render"))()
  eq(registry.call("fn.bracket2"), 7)
end)

case("dump restores the registry", function()
  local dump = registry.dump()
  local names = registry.names()
  local sources = {}
  for _, n in ipairs(names) do sources[n] = registry.get(n).source end
  for _, n in ipairs(names) do registry.remove(n) end
  eq(registry.names(), {})
  assert(load(dump, "dump"))()
  eq(registry.names(), names, "all names restored")
  for _, n in ipairs(names) do
    eq(registry.get(n).source, sources[n], "source restored for " .. n)
  end
  eq(registry.call("fn.add", 2, 3), 5, "restored entries are callable")
end)

-- ------------------------------------------------------------------ state

case("new_session: system block + empty trailing user", function()
  local bufnr = state.new_session()
  assert(vim.b[bufnr].straps_session, "b:straps_session")
  -- Durable sessions are file-backed: buftype "" (so :w / persist work), not
  -- the old ephemeral "nofile". (session_dir is isolated at the top of file.)
  eq(vim.bo[bufnr].buftype, "")
  eq(vim.bo[bufnr].filetype, "straps")
  local parsed = state.parse(bufnr)
  assert(type(parsed.system) == "string" and #parsed.system > 0, "system prompt present")
  eq(parsed.messages, {}, "empty trailing user block dropped")
  eq(state.last_user_text(bufnr), "", "trailing user block exists and is empty")
end)

case("transcript parse: roles merged, ids intact", function()
  local bufnr = state.new_session()
  state.append(bufnr, "user", nil, "add a linter hook")
  state.append(bufnr, "assistant", nil, "I'll look at the registry first.")
  state.append(bufnr, "tool_use", { id = "toolu_01", name = "registry_get" },
    '{\n  "name": "tool.write_file"\n}')
  state.append(bufnr, "tool_result", { id = "toolu_01", is_error = false },
    "return function(input, ctx) end")
  state.append(bufnr, "tool_result", { id = "toolu_02", is_error = true },
    "no such entry")
  state.append(bufnr, "assistant", nil, "done")
  state.ensure_trailing_user(bufnr)

  local parsed = state.parse(bufnr)
  eq(#parsed.messages, 4, "user / assistant-run / tool_result-run / assistant")

  eq(parsed.messages[1],
    { role = "user", content = { { type = "text", text = "add a linter hook" } } })

  local asst = parsed.messages[2]
  eq(asst.role, "assistant")
  eq(#asst.content, 2, "text + tool_use grouped into one assistant message")
  eq(asst.content[1], { type = "text", text = "I'll look at the registry first." })
  eq(asst.content[2].type, "tool_use")
  eq(asst.content[2].id, "toolu_01")
  eq(asst.content[2].name, "registry_get")
  eq(asst.content[2].input, { name = "tool.write_file" }, "input decoded from JSON")

  local results = parsed.messages[3]
  eq(results.role, "user")
  eq(#results.content, 2, "tool_result run grouped into one user message")
  eq(results.content[1],
    { type = "tool_result", tool_use_id = "toolu_01",
      content = "return function(input, ctx) end", is_error = false })
  eq(results.content[2],
    { type = "tool_result", tool_use_id = "toolu_02",
      content = "no such entry", is_error = true })

  eq(parsed.messages[4],
    { role = "assistant", content = { { type = "text", text = "done" } } })
end)

case("adjacent same-role messages merged", function()
  local bufnr = state.new_session()
  state.append(bufnr, "user", nil, "first")
  state.append(bufnr, "user", nil, "second")
  state.append(bufnr, "tool_use", { id = "t1", name = "ping" }, "{}")
  state.append(bufnr, "assistant", nil, "text after tool_use")
  local parsed = state.parse(bufnr)
  eq(#parsed.messages, 2)
  eq(parsed.messages[1].role, "user")
  eq(#parsed.messages[1].content, 2, "two user text blocks merged")
  eq(parsed.messages[2].role, "assistant")
  eq(#parsed.messages[2].content, 2, "tool_use + trailing assistant text merged")
end)

case("empty assistant block omitted", function()
  local bufnr = state.new_session()
  state.append(bufnr, "user", nil, "hi")
  state.append(bufnr, "assistant", nil, "") -- pre-provider marker, no text streamed
  state.append(bufnr, "tool_use", { id = "t1", name = "ping" }, "{}")
  local parsed = state.parse(bufnr)
  eq(#parsed.messages, 2)
  eq(#parsed.messages[2].content, 1, "no empty text part")
  eq(parsed.messages[2].content[1].type, "tool_use")
end)

case("tool blocks with undecodable attrs are skipped, not emitted null", function()
  -- A hand-edited/corrupt transcript can have a tool_use marker whose attrs
  -- JSON failed to decode (match_marker returns attrs=nil). Emitting it would
  -- ship a null-id/name block that the API rejects; parse must skip it.
  local bufnr = state.new_session()
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    "%%[straps:user]%%",
    "hi",
    "",
    "%%[straps:assistant]%%",
    "working",
    "",
    "%%[straps:tool_use]%% {not valid json",
    "{}",
    "",
    "%%[straps:tool_result]%% {not valid json",
    "orphan result",
  })
  local parsed = state.parse(bufnr)
  for _, msg in ipairs(parsed.messages) do
    for _, part in ipairs(msg.content) do
      if part.type == "tool_use" then
        error("a null-attr tool_use survived parse")
      elseif part.type == "tool_result" then
        error("a null-attr tool_result survived parse")
      end
    end
  end
  -- The valid user/assistant text still parses.
  eq(parsed.messages[1].content[1], { type = "text", text = "hi" })
  eq(parsed.messages[2].content[1], { type = "text", text = "working" })
end)

case("escaping round-trips marker-like content", function()
  local bufnr = state.new_session()
  local tricky = "%%[straps:user]%%\nplain line\n%%[[esc]]already escaped\n%%[straps:system]%% {}"
  state.append(bufnr, "user", nil, tricky)
  local parsed = state.parse(bufnr)
  eq(#parsed.messages, 1, "still one user message (no phantom blocks)")
  eq(parsed.messages[1].content[1].text, tricky, "content round-trips exactly")
  eq(state.last_user_text(bufnr), tricky)
end)

case("append_text streams into the current block", function()
  local bufnr = state.new_session()
  state.append(bufnr, "user", nil, "go")
  state.append(bufnr, "assistant", nil, "")
  state.append_text(bufnr, "hello")
  state.append_text(bufnr, " world\nsecond line")
  local parsed = state.parse(bufnr)
  local last = parsed.messages[#parsed.messages]
  eq(last.role, "assistant")
  eq(last.content[1].text, "hello world\nsecond line")
end)

case("ensure_trailing_user and last_user_text", function()
  local bufnr = state.new_session()
  state.append(bufnr, "user", nil, "question")
  state.append(bufnr, "assistant", nil, "answer")
  eq(state.last_user_text(bufnr), nil, "last block is assistant")
  state.ensure_trailing_user(bufnr)
  eq(state.last_user_text(bufnr), "")
  local before = vim.api.nvim_buf_line_count(bufnr)
  state.ensure_trailing_user(bufnr) -- idempotent
  eq(vim.api.nvim_buf_line_count(bufnr), before, "no duplicate empty user block")
end)

case("parse is total: garbage before first marker ignored", function()
  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false,
    { "junk", "more junk", "%%[straps:user]%%", "hello" })
  local parsed = state.parse(bufnr)
  eq(parsed.system, nil)
  eq(parsed.messages,
    { { role = "user", content = { { type = "text", text = "hello" } } } })
end)

case("new_session falls back without fn.system_prompt, uses it when present", function()
  assert(registry.get("fn.system_prompt") == nil, "tests run without provider.lua")
  registry.define{ name = "fn.system_prompt", kind = "fn",
    source = 'return function() return "custom prompt" end' }
  local bufnr = state.new_session()
  eq(state.parse(bufnr).system, "custom prompt")
  registry.remove("fn.system_prompt")
end)

case("text typed on the user marker line is content, not dropped", function()
  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    "%%[straps:system]%%", "sys", "",
    "%%[straps:user]%% This is a test, say hello",
  })
  local parsed = state.parse(bufnr)
  eq(parsed.messages, {
    { role = "user", content = { { type = "text", text = "This is a test, say hello" } } },
  })
end)

case("inline marker text concatenates with following lines", function()
  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false,
    { "%%[straps:user]%% first line", "second line" })
  eq(state.parse(bufnr).messages[1].content[1].text, "first line\nsecond line")
end)

case("JSON-looking inline text on a user marker stays content", function()
  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false,
    { '%%[straps:user]%% {"id":"x"}' })
  eq(state.parse(bufnr).messages[1].content[1].text, '{"id":"x"}')
end)

case("tool markers still parse JSON attrs, not inline content", function()
  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    '%%[straps:tool_use]%% {"id":"t1","name":"ping"}', '{"a":1}',
    '%%[straps:tool_result]%% {"id":"t1","is_error":false}', 'pong',
  })
  local msgs = state.parse(bufnr).messages
  eq(msgs[1].content[1].id, "t1")
  eq(msgs[1].content[1].input, { a = 1 })
  eq(msgs[2].content[1].content, "pong")
end)

case("append_text glues onto a marker line that has inline content", function()
  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "%%[straps:assistant]%% hel" })
  state.append_text(bufnr, "lo")
  eq(state.parse(bufnr).messages[1].content[1].text, "hello")
  -- and still starts a fresh line under a bare marker
  local b2 = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(b2, 0, -1, false, { "%%[straps:assistant]%%" })
  state.append_text(b2, "hi")
  eq(vim.api.nvim_buf_get_lines(b2, 0, -1, false), { "%%[straps:assistant]%%", "hi" })
end)

case("inline text on the trailing user marker counts for last_user_text", function()
  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "%%[straps:user]%% hey" })
  eq(state.last_user_text(bufnr), "hey")
end)

case("seq is stamped at first define and survives redefinition", function()
  registry.define({ name = "tool.zz_seq_a", kind = "tool", doc = "a",
    source = "return function() end" })
  registry.define({ name = "tool.aa_seq_b", kind = "tool", doc = "b",
    source = "return function() end" })
  local seq_a = registry.get("tool.zz_seq_a").seq
  local seq_b = registry.get("tool.aa_seq_b").seq
  assert(seq_a < seq_b, "seq should follow registration order")
  registry.define({ name = "tool.zz_seq_a", kind = "tool", doc = "a v2",
    source = "return function() return 2 end" })
  eq(registry.get("tool.zz_seq_a").seq, seq_a, "redefine must preserve seq")
  eq(registry.get("tool.zz_seq_a").version, 2)

  local by_seq = registry.names_by_seq("tool")
  local pos = {}
  for i, n in ipairs(by_seq) do pos[n] = i end
  assert(pos["tool.zz_seq_a"] < pos["tool.aa_seq_b"],
    "names_by_seq must order by registration, not alphabetically")
  registry.remove("tool.zz_seq_a")
  registry.remove("tool.aa_seq_b")
end)

case("dump restores entries in registration order", function()
  registry.define({ name = "fn.zz_dump_first", kind = "fn",
    source = "return function() end" })
  registry.define({ name = "fn.aa_dump_second", kind = "fn",
    source = "return function() end" })
  local dump = registry.dump()
  local first = dump:find("zz_dump_first", 1, true)
  local second = dump:find("aa_dump_second", 1, true)
  assert(first and second and first < second,
    "dump must be seq-ordered so restore preserves append-only tool order")
  registry.remove("fn.zz_dump_first")
  registry.remove("fn.aa_dump_second")
end)

print(("\n%s"):format(fails == 0 and "ALL PASS" or (fails .. " FAILURE(S)")))
os.exit(fails == 0 and 0 or 1)
