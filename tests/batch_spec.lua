-- tests/batch_spec.lua — batches that are not all parallel-read-only run in
-- segments (loop.lua run_segments): gate every block of a segment, then
-- execute, then one diagnostics wait over every written file, then append.
--   busted tests/batch_spec.lua
-- No network: fn.provider is scripted per case. Covers confirm-before-run,
-- segment breaks after define/lua/agent_tool calls and before a segment_break
-- tool, denial, cancel, crash pairing, the batched diagnostics wait, the
-- confirm preview of a second same-file edit, and the gate/tool log events.

local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(vim.fn.fnamemodify(here, ":p"), ":h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local tmp = assert(vim.uv.fs_realpath((function()
  local t = vim.fn.tempname(); vim.fn.mkdir(t, "p"); return t
end)()))
vim.env.XDG_DATA_HOME = tmp .. "/xdg"

local straps = require("straps").setup({})
straps.config.session_dir = tmp .. "/sessions"
straps.config.after_write_diagnostics_ms = 600
straps.config.stop_backstop_ms = 300
local registry = require("straps.registry")
local state = require("straps.state")
local loop = require("straps.loop")

local function define(name, kind, source, extra)
  local spec = { name = name, kind = kind, doc = "test", source = source }
  for k, v in pairs(extra or {}) do spec[k] = v end
  return registry.define(spec, { scope = "global" })
end

_G.B = {}
local function reset() _G.B = { events = {}, confirms = {}, logs = {}, diag_calls = 0 } end

define("hook.confirm", "hook", [==[
return function(name, input, ctx)
  local B = _G.B
  table.insert(B.confirms, { name = name, input = input, preview = ctx and ctx.batch_preview
    and type(input) == "table" and type(input.path) == "string" and ctx.batch_preview(input.path) or nil })
  table.insert(B.events, "confirm:" .. name)
  if B.confirm_raise and #B.confirms == B.confirm_raise then error("confirm exploded") end
  if B.deny and B.deny[#B.confirms] then return false, "nope" end
  if B.grant_on and B.grant_on == #B.confirms then
    local ok, err = pcall(require("straps.registry").grant, ctx.bufnr, "editdir:/x")
    B.grant_ok, B.grant_err = ok, err
  end
  return true
end
]==])
define("fn.log", "fn", [[return function(e) table.insert(_G.B.logs, e) end]])
define("tool.mark", "tool", [==[
return function(input, ctx)
  table.insert(_G.B.events, "run:" .. tostring(input.id))
  if input.slow then ctx.await(function(resolve) vim.defer_fn(resolve, input.slow) end) end
  if input.stop then require("straps.loop").stop(ctx.bufnr) end
  if input.bad then return { f = function() end } end
  return "ran " .. tostring(input.id)
end
]==], { capability = "exec" })
define("tool.fork", "tool", [==[
return function(input, ctx)
  table.insert(_G.B.events, "run:fork")
  local seen = {}
  for _, m in ipairs(require("straps.state").parse(ctx.bufnr).messages) do
    for _, p in ipairs(m.content) do
      if p.type == "tool_result" then seen[#seen + 1] = p.content end
    end
  end
  _G.B.fork_saw = seen
  return "forked"
end
]==], { capability = "spawn", segment_break = true })

local function scripted(blocks)
  _G.script_blocks = blocks
  _G.script_calls = 0
  define("fn.provider", "fn", [==[
return function(req, ctx)
  _G.script_calls = _G.script_calls + 1
  local n = _G.script_calls
  ctx.await(function(resolve) vim.defer_fn(resolve, 5) end)
  if n == 1 then
    local content = {}
    for i, b in ipairs(_G.script_blocks) do
      content[i] = { type = "tool_use", id = "t" .. i, name = b.name, input = b.input or vim.empty_dict() }
    end
    return { stop_reason = "tool_use", content = content }
  end
  ctx.emit({ type = "text_delta", text = "done" })
  return { stop_reason = "end_turn", content = { { type = "text", text = "done" } } }
end
]==])
end

local function run(blocks)
  scripted(blocks)
  local buf = state.new_session()
  state.append_text(buf, "go")
  loop.start(buf)
  assert(vim.wait(8000, function() return not loop.running(buf) end, 10), "run did not finish")
  return buf
end

local function results(buf)
  local out = {}
  for _, m in ipairs(state.parse(buf).messages) do
    for _, p in ipairs(m.content) do
      if p.type == "tool_result" then out[#out + 1] = p end
    end
  end
  return out
end

local function index_of(list, item)
  for i, v in ipairs(list) do if v == item then return i end end
end

local function text_of(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

local function mk(path, text)
  local f = assert(io.open(path, "w")); f:write(text); f:close()
end

-- ------------------------------------------------------------------ cases

it("every confirm of a segment happens before the first call runs", function()
  reset()
  local buf = run({ { name = "mark", input = { id = 1 } }, { name = "mark", input = { id = 2 } },
    { name = "mark", input = { id = 3 } } })
  local e = _G.B.events
  assert(#_G.B.confirms == 3, vim.inspect(e))
  assert(index_of(e, "run:1") > 3, "a call ran before its segment was gated: " .. vim.inspect(e))
  local r = results(buf)
  assert(#r == 3 and r[1].content == "ran 1" and r[3].content == "ran 3", vim.inspect(r))
end)

it("a define, lua or agent_tool call ends the gate run; the next block is gated after it ran", function()
  reset()
  run({ { name = "mark", input = { id = 1 } }, { name = "registry_define",
    input = { name = "tool.foo", kind = "tool", source = "return function() return 'foo!' end" } },
    { name = "foo" } })
  local e = _G.B.events
  assert(index_of(e, "confirm:foo") > index_of(e, "run:1"), "foo was gated before the define ran: " .. vim.inspect(e))
  reset()
  local buf = run({ { name = "eval_lua", input = { code =
    "require('straps.registry').define({ name = 'tool.bar', kind = 'tool', source = 'return function() return [[bar!]] end' }); return 1" } },
    { name = "bar" } })
  local r = results(buf)
  assert(r[2] and r[2].content == "bar!" and not r[2].is_error, "eval_lua-defined tool did not run: " .. vim.inspect(r))
  reset()
  _G.B.deny = { [1] = true }
  buf = run({ { name = "registry_define", input = { name = "tool.baz", kind = "tool", source = "return function() end" } },
    { name = "mark", input = { id = 9 } } })
  r = results(buf)
  assert(r[1].is_error and r[2].content == "ran 9", "a denied define must not stop later calls: " .. vim.inspect(r))
end)

it("registry_define of hook.confirm gates the calls after it with the new policy", function()
  reset()
  local buf = run({ { name = "registry_define", input = { name = "hook.confirm", kind = "hook",
    source = "return function(n) if n == 'mark' then return false, 'new policy' end return true end" } },
    { name = "mark", input = { id = 1 } } })
  local r = results(buf)
  assert(r[2].is_error and r[2].content:find("new policy", 1, true), vim.inspect(r))
  registry.remove("hook.confirm", { scope = buf })
end)

it("a segment_break tool starts a segment: it sees the results before it", function()
  reset()
  run({ { name = "mark", input = { id = 1 } }, { name = "fork" } })
  assert(_G.B.fork_saw and _G.B.fork_saw[1] == "ran 1", "fork did not see block 1's result: " .. vim.inspect(_G.B.fork_saw))
  reset()
  local buf = run({ { name = "fork" }, { name = "fork" }, { name = "mark", input = { id = 2 } } })
  local r = results(buf)
  assert(#r == 3 and r[3].content == "ran 2", "opening/consecutive forks did not advance: " .. vim.inspect(r))
  local v = registry.get("tool.fork")
  assert(v.segment_break == true, "segment_break missing from the view")
  assert(registry.render("tool.fork"):find("segment_break = true", 1, true), "render dropped segment_break")
  assert(not pcall(registry.define, { name = "tool.x", kind = "tool", source = "return function() end", segment_break = "y" }),
    "non-boolean segment_break accepted")
end)

it("a denied block gets its refusal; the others run; a grant in segment 2 is recorded", function()
  reset()
  _G.B.deny = { [2] = true }
  local buf = run({ { name = "mark", input = { id = 1 } }, { name = "mark", input = { id = 2 } },
    { name = "mark", input = { id = 3 } } })
  local r = results(buf)
  assert(r[1].content == "ran 1" and r[2].is_error and r[2].content:find("user denied", 1, true)
    and r[3].content == "ran 3", vim.inspect(r))
  reset()
  _G.B.grant_on = 2
  run({ { name = "eval_lua", input = { code = "return 1" } }, { name = "mark", input = { id = 1 } } })
  assert(_G.B.grant_ok, "grant refused in segment 2: " .. tostring(_G.B.grant_err))
end)

it("cancel mid-segment keeps executed results and stubs the rest", function()
  reset()
  local buf = run({ { name = "mark", input = { id = 1 } }, { name = "mark", input = { id = 2, stop = true } },
    { name = "mark", input = { id = 3 } } })
  local r = results(buf)
  assert(#r == 3, "every tool_use needs a result: " .. vim.inspect(r))
  assert(r[1].content == "ran 1" and r[2].content == "ran 2", vim.inspect(r))
  assert(r[3].is_error and r[3].content:find("cancelled", 1, true), vim.inspect(r))
  assert(not index_of(_G.B.events, "run:3"), "block 3 ran after cancel")
end)

local function count_diag_autocmds()
  return #vim.api.nvim_get_autocmds({ event = "DiagnosticChanged" })
end

it("crash pairing: a raising confirm in segment 2, a raising append in post-processing", function()
  local base = count_diag_autocmds()
  for _, case in ipairs({ "confirm", "append" }) do
    reset()
    local blocks
    if case == "confirm" then
      _G.B.confirm_raise = 3
      blocks = { { name = "mark", input = { id = 1 } }, { name = "eval_lua", input = { code = "return 1" } },
        { name = "mark", input = { id = 3 } } }
    else
      local real_append = state.append
      state.append = function(b, kind, attrs, text)
        if kind == "tool_result" and attrs and attrs.id == "t2" and not _G.B.append_raised then
          _G.B.append_raised = true
          error("append exploded")
        end
        return real_append(b, kind, attrs, text)
      end
      _G.B.restore_append = function() state.append = real_append end
      blocks = { { name = "mark", input = { id = 1 } }, { name = "mark", input = { id = 2 } },
        { name = "mark", input = { id = 3 } } }
    end
    local buf = run(blocks)
    if _G.B.restore_append then _G.B.restore_append() end
    local r = results(buf)
    assert(#r == 3, case .. ": expected one result per tool_use, got " .. vim.inspect(r))
    local ids = {}
    for _, x in ipairs(r) do
      assert(not ids[x.tool_use_id], case .. ": duplicate result for " .. tostring(x.tool_use_id)); ids[x.tool_use_id] = true
    end
    local t = text_of(buf)
    assert(t:find("straps: run error", 1, true), case .. ": no run error block")
    assert(t:find("straps: run error", 1, true) > t:find("t3", 1, true), case .. ": run error before results")
    assert(r[1].content == "ran 1", vim.inspect(r))
    if case == "confirm" then
      assert(r[3].content:find("interrupted before", 1, true), vim.inspect(r))
    else
      for k = 2, 3 do
        assert(r[k].is_error and r[k].content:find("not processed", 1, true) and not r[k].content:find("ran ", 1, true),
          "unprocessed output reached the transcript: " .. vim.inspect(r[k]))
      end
    end
  end
  assert(count_diag_autocmds() == base, "a DiagnosticChanged listener leaked")
end)

it("an unencodable result is an error result, and the batch goes on", function()
  reset()
  local buf = run({ { name = "mark", input = { id = 1, bad = true } }, { name = "mark", input = { id = 2 } } })
  local r = results(buf)
  assert(r[1].is_error and r[1].content:find("could not encode", 1, true), vim.inspect(r))
  assert(r[2].content == "ran 2" and not text_of(buf):find("run error", 1, true), vim.inspect(r))
end)

-- ------------------------------------------------------ diagnostics batching
local real_get_clients = vim.lsp.get_clients
local ns = vim.api.nvim_create_namespace("batch_spec")

local function with_lsp(fn)
  vim.lsp.get_clients = function() return { { name = "fake" } } end
  local orig = registry.get("fn.write_diagnostics")
  define("fn.write_diagnostics", "fn", ([==[
local real = load(%q)()
return function(records, ctx)
  _G.B.diag_calls = _G.B.diag_calls + 1
  _G.B.diag_records = #records
  if _G.B.diag_raise then error("diag exploded") end
  local t0 = vim.uv.hrtime()
  local out = real(records, ctx)
  _G.B.diag_ms = (vim.uv.hrtime() - t0) / 1e6
  return out
end
]==]):format(orig.source))
  local ok, err = pcall(fn)
  define("fn.write_diagnostics", "fn", orig.source)
  vim.lsp.get_clients = real_get_clients
  if not ok then error(err, 0) end
end

local function seed(path, msg)
  local buf = vim.fn.bufadd(path); vim.fn.bufload(buf)
  vim.diagnostic.set(ns, buf, { { lnum = 0, col = 0, severity = vim.diagnostic.severity.ERROR, message = msg } })
  return buf
end

it("three edits to A and one to B wait once; text lands on the last A and on B", function()
  local a, b = tmp .. "/a.lua", tmp .. "/b.lua"
  mk(a, "one\n"); mk(b, "uno\n")
  seed(a, "A broken"); seed(b, "B broken")
  local diag_base = #vim.api.nvim_get_autocmds({ event = "DiagnosticChanged" })
  with_lsp(function()
    reset()
    local buf = run({
      { name = "edit_file", input = { path = a, old_string = "one", new_string = "two" } },
      { name = "edit_file", input = { path = a, old_string = "two", new_string = "three" } },
      { name = "edit_file", input = { path = b, old_string = "uno", new_string = "dos" } },
      { name = "edit_file", input = { path = tmp .. "/./a.lua", old_string = "three", new_string = "four" } },
    })
    local r = results(buf)
    assert(_G.B.diag_calls == 1 and _G.B.diag_records == 2, "expected one wait over two buffers: " .. vim.inspect(_G.B))
    assert(not r[1].content:find("A broken", 1, true) and not r[2].content:find("A broken", 1, true), vim.inspect(r))
    assert(r[3].content:find("B broken", 1, true), "B result lacks its diagnostics: " .. r[3].content)
    assert(r[4].content:find("A broken", 1, true), "last A result lacks diagnostics: " .. r[4].content)
    assert(_G.B.diag_ms < 2 * straps.config.after_write_diagnostics_ms, "wait too long: " .. tostring(_G.B.diag_ms))
    assert(#vim.api.nvim_get_autocmds({ event = "DiagnosticChanged" }) == diag_base, "a DiagnosticChanged listener leaked")
  end)
end)

it("a later failed edit to the same file leaves the text on the earlier success", function()
  local a = tmp .. "/c.lua"
  mk(a, "one\n"); seed(a, "C broken")
  with_lsp(function()
    reset()
    local buf = run({
      { name = "edit_file", input = { path = a, old_string = "one", new_string = "two" } },
      { name = "edit_file", input = { path = a, old_string = "missing", new_string = "x" } },
    })
    local r = results(buf)
    assert(r[1].content:find("C broken", 1, true), "first result lacks diagnostics: " .. r[1].content)
    assert(r[2].is_error, "second edit should fail")
  end)
end)

it("an event during the segment ends the wait within the debounce", function()
  local a = tmp .. "/d.lua"
  mk(a, "one\n"); local abuf = seed(a, "D broken")
  with_lsp(function()
    reset()
    local id = vim.api.nvim_create_autocmd("BufWritePost", { buffer = abuf, callback = function()
      vim.schedule(function()
        vim.diagnostic.set(ns, abuf, { { lnum = 0, col = 0, severity = 1, message = "D relinted" } })
      end)
    end })
    local buf = run({
      { name = "edit_file", input = { path = a, old_string = "one", new_string = "two" } },
      { name = "mark", input = { id = 1, slow = 200 } },
    })
    vim.api.nvim_del_autocmd(id)
    local r = results(buf)
    assert(r[1].content:find("D relinted", 1, true), r[1].content)
    assert(_G.B.diag_ms < 60, "waited although the server had already re-linted: " .. tostring(_G.B.diag_ms))
  end)
end)

it("the debounce takes the last event of a burst", function()
  local a = tmp .. "/e.lua"
  mk(a, "one\n"); local abuf = seed(a, "stale")
  with_lsp(function()
    reset()
    local id = vim.api.nvim_create_autocmd("BufWritePost", { buffer = abuf, callback = function()
      local function set(msg) vim.diagnostic.set(ns, abuf, { { lnum = 0, col = 0, severity = 1, message = msg } }) end
      vim.defer_fn(function() set("first") end, 10)
      vim.defer_fn(function() set("middle") end, 90)
      vim.defer_fn(function() set("final") end, 170)
    end })
    local buf = run({ { name = "edit_file", input = { path = a, old_string = "one", new_string = "two" } } })
    vim.api.nvim_del_autocmd(id)
    local r = results(buf)
    assert(r[1].content:find("final", 1, true), "reported an intermediate state: " .. r[1].content)
  end)
end)

it("diagnostics off, raising fn.write_diagnostics, suffix subscribers, symlinked dirs", function()
  local a = tmp .. "/f.lua"
  mk(a, "one\n"); seed(a, "F broken")
  with_lsp(function()
    reset()
    straps.config.after_write_diagnostics = false
    local buf = run({ { name = "edit_file", input = { path = a, old_string = "one", new_string = "two" } } })
    straps.config.after_write_diagnostics = true
    assert(_G.B.diag_calls == 0, "write_diagnostics called while disabled")
    assert(not results(buf)[1].content:find("F broken", 1, true))

    reset()
    _G.B.diag_raise = true
    buf = run({ { name = "edit_file", input = { path = a, old_string = "two", new_string = "three" } },
      { name = "mark", input = { id = 1 } } })
    local r = results(buf)
    assert(not r[1].is_error and r[2].content == "ran 1", "a raising diagnostics fn broke the batch: " .. vim.inspect(r))
    assert(not text_of(buf):find("run error", 1, true), "a raising diagnostics fn crashed the run")
    _G.B.diag_raise = nil

    reset()
    _G.B.suffix = 0
    define("hook.after_write.count", "hook", "return function() _G.B.suffix = _G.B.suffix + 1 end")
    run({ { name = "edit_file", input = { path = a, old_string = "three", new_string = "four" } },
      { name = "edit_file", input = { path = a, old_string = "four", new_string = "five" } } })
    registry.remove("hook.after_write.count", { scope = "global" })
    assert(_G.B.suffix == 2, "suffix subscriber did not run per write: " .. tostring(_G.B.suffix))

    local real_dir = tmp .. "/real"; vim.fn.mkdir(real_dir, "p")
    local link = tmp .. "/link"; vim.uv.fs_symlink(real_dir, link)
    mk(real_dir .. "/g.lua", "one\n")
    seed(link .. "/g.lua", "G broken")
    reset()
    buf = run({ { name = "edit_file", input = { path = link .. "/g.lua", old_string = "one", new_string = "two" } } })
    assert(results(buf)[1].content:find("G broken", 1, true), "symlinked path lost its diagnostics")
  end)
end)

it("cancel during the diagnostics wait ends it at once", function()
  local a = tmp .. "/h.lua"
  mk(a, "one\n"); seed(a, "H broken")
  straps.config.after_write_diagnostics_ms = 3000
  with_lsp(function()
    reset()
    scripted({ { name = "edit_file", input = { path = a, old_string = "one", new_string = "two" } } })
    local buf = state.new_session()
    state.append_text(buf, "go")
    loop.start(buf)
    vim.wait(2000, function() return _G.B.diag_calls == 1 end, 5)
    local t0 = vim.uv.hrtime()
    loop.stop(buf)
    assert(vim.wait(2000, function() return not loop.running(buf) end, 5), "run did not end")
    assert((vim.uv.hrtime() - t0) / 1e6 < 250, "stop waited for the diagnostics cap")
  end)
  straps.config.after_write_diagnostics_ms = 600
end)

it("a raising tool_use append leaves no orphan result", function()
  reset()
  local real_append = state.append
  state.append = function(b, kind, attrs, text)
    if kind == "tool_use" and attrs and attrs.id == "t2" then error("marker exploded") end
    return real_append(b, kind, attrs, text)
  end
  local ok, buf = pcall(run, { { name = "mark", input = { id = 1 } }, { name = "mark", input = { id = 2 } } })
  state.append = real_append
  assert(ok, buf)
  local t = text_of(buf)
  local n1 = 0
  for line in t:gmatch("[^\n]+") do
    if line:find("%[straps:tool_result%]") and line:find('"id":"t1"', 1, true) then n1 = n1 + 1 end
    assert(not (line:find("%[straps:tool_result%]") and line:find('"id":"t2"', 1, true)),
      "a tool_result was written for a tool_use that never reached the transcript")
  end
  assert(n1 == 1, "t1 needs exactly one result, got " .. n1)
end)

it("simulate_edit refuses what the tools refuse; find_buf skips non-file buffers", function()
  assert(state.simulate_edit("edit_file", { old_string = "a", new_string = "b" }, "a a") == nil, "ambiguous edit previewed")
  assert(state.simulate_edit("edit_file", { old_string = "a", new_string = "b", replace_all = true }, "a a") == "b b")
  local two = "x\ny"
  assert(state.simulate_edit("patch_file", { hunks = { { start_line = 1, end_line = 5, new_text = "z" } } }, two) == nil)
  assert(state.simulate_edit("patch_file", { hunks = { { start_line = 1.5, end_line = 1, new_text = "z" } } }, two) == nil)
  assert(state.simulate_edit("patch_file", { hunks = { { start_line = 1, end_line = 2, new_text = "z" },
    { start_line = 2, end_line = 2, new_text = "w" } } }, two) == nil, "overlapping hunks previewed")
  assert(state.simulate_edit("patch_file", { hunks = { { start_line = 1, end_line = 1, new_text = "z",
    expected_old_text = "nope" } } }, two) == nil, "expected_old_text mismatch previewed")
  assert(state.simulate_edit("patch_file", { hunks = { { start_line = 2, end_line = 2, new_text = "z\n" } } }, two) == "x\nz")
  local p = tmp .. "/scratch.lua"
  mk(p, "real\n")
  local scratch = vim.api.nvim_create_buf(false, true)
  vim.bo[scratch].buftype = "nofile"
  vim.api.nvim_buf_set_name(scratch, p)
  assert(state.find_buf(p) == nil, "find_buf returned a nofile buffer")
  vim.api.nvim_buf_delete(scratch, { force = true })
  local real = vim.fn.bufadd(p); vim.fn.bufload(real)
  assert(state.find_buf(p) == real, "find_buf missed the file buffer")
  local uri = vim.api.nvim_create_buf(false, false)
  vim.api.nvim_buf_set_name(uri, "oil://" .. p)
  assert(state.find_buf("oil://" .. p) == nil, "find_buf matched a URI-named buffer")
  vim.api.nvim_buf_delete(uri, { force = true })
end)

it("the confirm preview for a second same-file edit applies the first edit", function()
  local a = tmp .. "/p.lua"
  mk(a, "alpha\n")
  reset()
  run({ { name = "edit_file", input = { path = a, old_string = "alpha", new_string = "beta" } },
    { name = "edit_file", input = { path = a, old_string = "beta", new_string = "gamma" } } })
  local c = _G.B.confirms
  assert(c[1].preview == nil, "first edit has no batch preview base: " .. vim.inspect(c[1].preview))
  assert(c[2].preview == "beta", "second preview base should include the first edit: " .. vim.inspect(c[2].preview))
  local new = state.simulate_edit("edit_file", c[2].input, c[2].preview)
  assert(new == "gamma", "simulated preview: " .. tostring(new))
end)

it("the log has a gate event per block and execution-only tool ms", function()
  reset()
  run({ { name = "mark", input = { id = 1, slow = 120 } }, { name = "mark", input = { id = 2 } } })
  local gates, tools = {}, {}
  for _, e in ipairs(_G.B.logs) do
    if e.ev == "gate" then gates[#gates + 1] = e end
    if e.ev == "tool" then tools[#tools + 1] = e end
  end
  assert(#gates == 2 and #tools == 2, vim.inspect(_G.B.logs))
  assert(tools[1].ms >= 100 and tools[2].ms < 100, "tool ms mixes in other calls: " .. vim.inspect(tools))
end)
