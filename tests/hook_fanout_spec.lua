-- tests/hook_fanout_spec.lua — multi-subscriber hook fan-out (Contract 1).
--   busted tests/hook_fanout_spec.lua
-- Covers: registry.hook_entries ordering, registry.call_hooks result
-- collection + error isolation, the after_write call-site adoption in
-- tool.write_file, and the hook.after_tool fold in loop.lua.

local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(vim.fn.fnamemodify(here, ":p"), ":h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path


local straps = require("straps").setup({})
straps.config.session_dir = vim.fn.tempname()
local registry = require("straps.registry")
local state = require("straps.state")
local loop = require("straps.loop")
require("straps.provider").register()

local function define(name, kind, doc, source)
  registry.define({ name = name, kind = kind, doc = doc, source = source })
end

-- ---------------------------------------------------------- write_file setup

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")

-- The default hook.after_write's LSP probe is inert here: a fresh headless
-- nvim has no LSP clients, and the cases below redefine hook.after_write to a
-- test stub anyway, replacing the default body entirely.

it("write_file result carries both default and extra subscriber output, in seq order", function()
  -- Redefine the base hook.after_write (subscriber #1) and add an extra
  -- subscriber (hook.after_write.extra, subscriber #2).
  define("hook.after_write", "hook", "test: base subscriber", [[return function() return "HOOK_BASE" end]])
  define("hook.after_write.extra", "hook", "test: extra subscriber", [[return function() return "HOOK_EXTRA" end]])

  local path = tmp .. "/g1.txt"
  local result = registry.call("tool.write_file", { path = path, content = "hi\n" }, { bufnr = 0 })
  assert(type(result) == "string", "expected a string result")
  local pos_a = assert(result:find("\nHOOK_BASE\n", 1, true), "missing base subscriber output: " .. result)
  local pos_b = assert(result:find("\nHOOK_EXTRA", 1, true), "missing extra subscriber output: " .. result)
  assert(pos_a < pos_b, "subscriber result order is wrong: " .. result)
end)

-- Counterfactual: with the extra subscriber removed, "B" must not appear.
it("counterfactual: removing the extra subscriber drops its output", function()
  registry.remove("hook.after_write.extra", { scope = "global" })
  local path = tmp .. "/g1b.txt"
  local result = registry.call("tool.write_file", { path = path, content = "hi\n" }, { bufnr = 0 })
  assert(result:find("\nHOOK_BASE", 1, true), "base subscriber output missing: " .. result)
  assert(not result:find("HOOK_EXTRA", 1, true), "removed subscriber output survived: " .. result)
  -- restore for later cases
  define("hook.after_write.extra", "hook", "test: extra subscriber", [[return function() return "HOOK_EXTRA" end]])
end)

it("a broken subscriber does not prevent the write or the other subscribers", function()
  define("hook.after_write.boom", "hook", "test: errors", [[return function() error("kaboom") end]])

  local path = tmp .. "/g2.txt"
  local result = registry.call("tool.write_file", { path = path, content = "hi\n" }, { bufnr = 0 })
  assert(result:find("wrote ", 1, true), "write itself must still succeed: " .. result)
  assert(result:find("HOOK_BASE", 1, true), "base subscriber output missing: " .. result)
  assert(result:find("HOOK_EXTRA", 1, true), "extra subscriber output missing: " .. result)
  assert(result:find("[hook hook.after_write.boom error:", 1, true),
    "missing the error line naming the failing subscriber: " .. result)
  assert(result:find("kaboom", 1, true), "error line should carry the raised message: " .. result)
end)

-- Counterfactual: fix the boom subscriber (make it return nil, not error) and
-- confirm the error line disappears — proves the assertion actually tracks
-- the error, not some unrelated static text.
it("counterfactual: a fixed subscriber no longer produces an error line", function()
  define("hook.after_write.boom", "hook", "test: fixed, no longer errors", [[return function() end]])
  local path = tmp .. "/g2b.txt"
  local result = registry.call("tool.write_file", { path = path, content = "hi\n" }, { bufnr = 0 })
  assert(not result:find("[hook hook.after_write.boom error:", 1, true),
    "error line should be gone once the subscriber stops erroring: " .. result)
  registry.remove("hook.after_write.boom", { scope = "global" })
end)

-- ------------------------------------------------------- registry primitives

it("hook_entries: exact name plus dotted suffixes, sorted by seq, kind filtered", function()
  define("hook.fanout_test", "hook", "base", [[return function() return 1 end]])
  define("hook.fanout_test.b", "hook", "second", [[return function() return 2 end]])
  define("hook.fanout_test.a", "hook", "third", [[return function() return 3 end]])
  -- A non-hook entry with a colliding dotted name must NOT be picked up.
  define("fn.fanout_test.not_a_hook", "fn", "decoy", [[return function() return "nope" end]])
  -- A same-prefix-but-different-name entry must not match either.
  define("hook.fanout_test_other", "hook", "unrelated", [[return function() return "x" end]])

  local entries = registry.hook_entries("hook.fanout_test")
  assert(#entries == 3, "expected 3 matching entries, got " .. #entries)
  assert(entries[1].name == "hook.fanout_test", "first entry should be the exact-name one (lowest seq): "
    .. entries[1].name)
  -- entries 2/3 are .b then .a in DEFINITION order (seq), not alphabetical.
  assert(entries[2].name == "hook.fanout_test.b", "second entry should be .b (registered before .a): "
    .. entries[2].name)
  assert(entries[3].name == "hook.fanout_test.a", "third entry should be .a: " .. entries[3].name)
  for _, e in ipairs(entries) do
    assert(e.kind == "hook", "hook_entries returned a non-hook entry: " .. e.name)
  end
end)

it("counterfactual: hook_entries with a name that has no subscribers returns empty", function()
  local entries = registry.hook_entries("hook.no_such_thing_at_all")
  assert(#entries == 0, "expected zero entries, got " .. #entries)
end)

it("call_hooks collects non-nil results in seq order", function()
  define("hook.ch_test", "hook", "base", [[return function() return "r1" end]])
  define("hook.ch_test.two", "hook", "second", [[return function() return "r2" end]])
  define("hook.ch_test.skip", "hook", "returns nil, skipped", [[return function() end]])

  local results, errors = registry.call_hooks("hook.ch_test", "arg1")
  assert(#errors == 0, "unexpected errors: " .. vim.inspect(errors))
  assert(#results == 2, "expected 2 non-nil results, got " .. #results .. ": " .. vim.inspect(results))
  assert(results[1] == "r1" and results[2] == "r2",
    "results out of seq order: " .. vim.inspect(results))
end)

it("call_hooks: one broken subscriber does not block the others; error names the entry", function()
  define("hook.iso_test", "hook", "ok subscriber 1", [[return function() return "ok1" end]])
  define("hook.iso_test.broken", "hook", "raises", [[return function() error("subscriber blew up") end]])
  define("hook.iso_test.zzz", "hook", "ok subscriber 2", [[return function() return "ok2" end]])

  local results, errors = registry.call_hooks("hook.iso_test")
  assert(#results == 2, "expected the two healthy subscribers to still run: " .. vim.inspect(results))
  assert(results[1] == "ok1" and results[2] == "ok2", "healthy results wrong/out of order: " .. vim.inspect(results))
  assert(#errors == 1, "expected exactly one error, got " .. #errors)
  assert(errors[1].name == "hook.iso_test.broken",
    "error entry should name the failing subscriber, got: " .. tostring(errors[1].name))
  assert(errors[1].err:find("subscriber blew up", 1, true), "error message lost: " .. tostring(errors[1].err))
end)

it("counterfactual: fixing the broken subscriber empties the errors table", function()
  define("hook.iso_test.broken", "hook", "fixed", [[return function() return "ok3" end]])
  local results, errors = registry.call_hooks("hook.iso_test")
  assert(#errors == 0, "errors should be empty once the subscriber stops raising: " .. vim.inspect(errors))
  assert(#results == 3, "all three subscribers should now contribute a result: " .. vim.inspect(results))
end)

-- ------------------------------------------------------- hook.after_tool fold

-- Exercised through the REAL loop.lua execute_tool path: a scripted provider
-- calls tool.ping once, two hook.after_tool subscribers each append a suffix
-- to the tool result, and the second must see the first's transformation.
it("hook.after_tool fold (via the real loop): each subscriber sees the previous one's result", function()
  define("hook.confirm", "hook", "test: allow everything", "return function() return true end")
  define("tool.ping", "tool", "ping", [[return function() return "pong" end]])
  define("hook.after_tool", "hook", "test: base +1", [[
return function(name, input, result, ok, ctx)
  return result .. "+1"
end
]])
  define("hook.after_tool.two", "hook", "test: +2, sees base's output", [[
return function(name, input, result, ok, ctx)
  return result .. "+2"
end
]])

  _G.straps_test_calls = 0
  define("fn.provider", "fn", "test: one ping turn then text", [==[
return function(req, ctx)
  _G.straps_test_calls = _G.straps_test_calls + 1
  local n = _G.straps_test_calls
  ctx.await(function(resolve)
    vim.defer_fn(function()
      if n == 2 then ctx.emit({ type = "text_delta", text = "done" }) end
      resolve()
    end, 5)
  end)
  if n == 1 then
    return { stop_reason = "tool_use", content = {
      { type = "tool_use", id = "t1", name = "ping", input = vim.empty_dict() },
    } }
  end
  return { stop_reason = "end_turn", content = { { type = "text", text = "done" } } }
end
]==])

  local bufnr = state.new_session()
  state.append_text(bufnr, "ping once")
  loop.start(bufnr)
  assert(vim.wait(5000, function() return not loop.running(bufnr) end, 10), "run did not finish within 5s")

  local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  assert(text:find("pong+1+2", 1, true),
    "expected the folded result 'pong+1+2' (base then .two, each seeing the prior transform): " .. text:sub(-500))

  registry.remove("hook.after_tool", { scope = "global" })
  registry.remove("hook.after_tool.two", { scope = "global" })
end)

it("counterfactual: without the second subscriber the fold stops after the first", function()
  define("hook.confirm", "hook", "test: allow everything", "return function() return true end")
  define("tool.ping", "tool", "ping", [[return function() return "pong" end]])
  define("hook.after_tool", "hook", "test: base +1 only", [[
return function(name, input, result, ok, ctx)
  return result .. "+1"
end
]])
  _G.straps_test_calls = 0
  define("fn.provider", "fn", "test: one ping turn then text", [==[
return function(req, ctx)
  _G.straps_test_calls = _G.straps_test_calls + 1
  local n = _G.straps_test_calls
  ctx.await(function(resolve)
    vim.defer_fn(function()
      if n == 2 then ctx.emit({ type = "text_delta", text = "done" }) end
      resolve()
    end, 5)
  end)
  if n == 1 then
    return { stop_reason = "tool_use", content = {
      { type = "tool_use", id = "t2", name = "ping", input = vim.empty_dict() },
    } }
  end
  return { stop_reason = "end_turn", content = { { type = "text", text = "done" } } }
end
]==])
  local bufnr = state.new_session()
  state.append_text(bufnr, "ping once")
  loop.start(bufnr)
  assert(vim.wait(5000, function() return not loop.running(bufnr) end, 10), "run did not finish within 5s")
  local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  assert(text:find("pong+1", 1, true), "expected 'pong+1': " .. text:sub(-500))
  assert(not text:find("pong+1+2", 1, true), "should NOT see +2 with only one subscriber: " .. text:sub(-500))
  registry.remove("hook.after_tool", { scope = "global" })
end)
