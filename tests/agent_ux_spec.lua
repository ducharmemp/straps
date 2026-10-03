-- tests/agent_ux_spec.lua — the agent/editor coupling additions.
--   busted tests/agent_ux_spec.lua
-- No network, no real LSP server. Covers: registration + schema of the new
-- editor tools (hover, workspace_symbols, rename_symbol, code_action, format,
-- context, show_user, help_search) and run_in_terminal; the graceful "no LSP
-- client" fallbacks; context reporting windows/cursor/selection; show_user
-- moving the user's view; help_search excerpting :help; run_in_terminal
-- round-tripping output through a real :terminal split; ask_user's inline
-- virt_lines question, its keymaps and live preview split; hook.confirm's new
-- auto-allows, code_action list-vs-apply gating, and the diff-preview split
-- being cleaned up after the dialog; fn.autocmd_bridge queueing a hook's
-- string return onto a session buffer.

local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(vim.fn.fnamemodify(here, ":p"), ":h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

-- Runs `fn` at test time, in document order with the surrounding `it`s (the
-- old runner executed cases inline; busted collects first, then runs).
local function step(fn)
  local info = debug.getinfo(fn, "S")
  describe("step@" .. info.short_src .. ":" .. info.linedefined, function() setup(fn) end)
end


local straps = require("straps").setup({})
straps.config.session_dir = vim.fn.tempname() -- hermetic session writes

local registry = require("straps.registry")
local state = require("straps.state")

local unpack = unpack or table.unpack
local function pack(...) return { n = select("#", ...), ... } end

-- Minimal ctx.await driver (same shape as the loop's): coroutine + scheduled
-- resume, then vim.wait for completion.
local function drive(thunk, timeout_ms, ctx_extra)
  local out, finished, co
  local ctx = {
    bufnr = 0,
    await = function(start)
      local resolved = false
      start(function(...)
        if resolved then return end
        resolved = true
        local a = pack(...)
        vim.schedule(function()
          if coroutine.status(co) == "suspended" then
            local ok, e = coroutine.resume(co, unpack(a, 1, a.n))
            if not ok then finished = true; error(e) end
          end
        end)
      end)
      return coroutine.yield()
    end,
  }
  for k, v in pairs(ctx_extra or {}) do ctx[k] = v end
  co = coroutine.create(function()
    out = thunk(ctx)
    finished = true
  end)
  local ok, err = coroutine.resume(co)
  if not ok then error(err) end
  vim.wait(timeout_ms or 10000, function() return finished end, 20)
  assert(finished, "drive: thunk did not finish within timeout")
  return out
end

local function write_file(path, text)
  local f = assert(io.open(path, "w"))
  f:write(text)
  f:close()
end

-- ---------------------------------------------------------------- registration

it("new tools registered with schemas; autocmd_bridge registered as fn", function()
  for _, n in ipairs({ "hover", "workspace_symbols", "rename_symbol", "code_action",
    "format", "context", "show_user", "help_search", "run_in_terminal",
    "show_diff", "show_buffer", "set_findings" }) do
    local e = registry.get("tool." .. n)
    assert(e, "tool." .. n .. " not registered")
    assert(e.kind == "tool", "tool." .. n .. " wrong kind")
    assert(type(e.input_schema) == "table", "tool." .. n .. " missing input_schema")
  end
  local b = registry.get("fn.autocmd_bridge")
  assert(b and b.kind == "fn", "fn.autocmd_bridge not registered as fn")
end)

it("every tool schema JSON-encodes with object-shaped properties", function()
  local tools = registry.call("fn.build_tools")
  assert(#tools > 20, "expected the full tool list, got " .. #tools)
  local payload = vim.json.encode(tools)
  assert(not payload:find('"properties":[]', 1, true),
    "a tool schema encoded properties as an array — the API 400s on this")
  -- Also encode each schema individually so a failure names the tool.
  for _, t in ipairs(tools) do
    local enc = vim.json.encode(t.input_schema)
    assert(not enc:find('"properties":[]', 1, true),
      "tool " .. t.name .. " has array-shaped properties: " .. enc)
  end
end)

-- --------------------------------------------------------- no-LSP fallbacks

it("LSP tools degrade to clear messages with no client attached", function()
  local path = vim.fn.tempname() .. ".txt"
  write_file(path, "one two three\nfour five six\n")

  local out = drive(function(ctx)
    return registry.call("tool.hover", { path = path, line = 1, col = 1 }, ctx)
  end)
  assert(out:find("no LSP client", 1, true), "hover fallback wrong:\n" .. out)

  out = drive(function(ctx)
    return registry.call("tool.rename_symbol",
      { path = path, line = 1, col = 1, new_name = "x" }, ctx)
  end)
  assert(out:find("no LSP client", 1, true), "rename_symbol fallback wrong:\n" .. out)
  assert(out:find("bulk_replace", 1, true), "rename_symbol should point at the textual fallback")

  out = drive(function(ctx)
    return registry.call("tool.format", { path = path }, ctx)
  end)
  assert(out:find("no LSP client", 1, true), "format fallback wrong:\n" .. out)

  out = drive(function(ctx)
    return registry.call("tool.code_action", { path = path, line = 1, col = 1 }, ctx)
  end)
  assert(out:find("no LSP client", 1, true), "code_action fallback wrong:\n" .. out)

  out = drive(function(ctx)
    return registry.call("tool.workspace_symbols", { query = "anything" }, ctx)
  end)
  assert(out:find("no LSP client", 1, true), "workspace_symbols fallback wrong:\n" .. out)
end)

-- ----------------------------------------------------------------- help_search

it("help_search finds tags and excerpts the best match's section", function()
  local out = registry.call("tool.help_search", { query = "quickfix" }, { bufnr = 0 })
  assert(out:find("matching tags:", 1, true), "tag list missing:\n" .. out:sub(1, 200))
  assert(out:find("quickfix", 1, true), "no quickfix tag matched")
  assert(out:find("-- :help ", 1, true), "excerpt header missing:\n" .. out:sub(1, 200))
end)

it("help_search reports no matches for nonsense", function()
  local out = registry.call("tool.help_search",
    { query = "straps-definitely-not-a-real-tag" }, { bufnr = 0 })
  assert(out:find("no help tags match", 1, true), "unexpected: " .. out:sub(1, 120))
end)

-- --------------------------------------------------------------------- context

it("context reports the focused window, cursor and visual selection", function()
  local path = vim.fn.tempname() .. ".txt"
  write_file(path, "line one\nline two\nline three\nline four\n")
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_win_set_cursor(0, { 3, 2 })
  -- Seed a "last visual selection" over lines 2-3.
  vim.api.nvim_buf_set_mark(buf, "<", 2, 0, {})
  vim.api.nvim_buf_set_mark(buf, ">", 3, 3, {})

  local out = registry.call("tool.context", {}, { bufnr = 0 })
  assert(out:find("focused window:", 1, true), "focused window missing:\n" .. out)
  assert(out:find(":3:3", 1, true), "cursor position missing:\n" .. out)
  assert(out:find("last visual selection", 1, true), "selection missing:\n" .. out)
  assert(out:find("line two", 1, true), "selection text missing:\n" .. out)
end)

it("context flags unsaved buffers", function()
  vim.api.nvim_buf_set_lines(0, 0, 1, false, { "line one EDITED" })
  local out = registry.call("tool.context", {}, { bufnr = 0 })
  assert(out:find("unsaved changes", 1, true), "unsaved flag missing:\n" .. out)
  assert(out:find("unsaved buffers: ", 1, true), "unsaved list missing:\n" .. out)
  vim.cmd("silent! write") -- clean up for later cases
end)

-- ------------------------------------------------------------------- show_user

it("show_user moves the user's view to path:line and reports it", function()
  local path = vim.fn.tempname() .. ".txt"
  write_file(path, "alpha\nbeta\ngamma\ndelta\n")
  local out = registry.call("tool.show_user", { path = path, line = 3 }, { bufnr = 0 })
  assert(out:find("showing", 1, true) and out:find(":3", 1, true),
    "unexpected result: " .. out)
  local cur = vim.api.nvim_get_current_buf()
  -- realpath, not :p — buffer names come back canonicalized (macOS
  -- /var -> /private/var) and :p does not resolve symlinks.
  assert(vim.api.nvim_buf_get_name(cur) == assert(vim.uv.fs_realpath(path)),
    "current window does not show the file")
  local pos = vim.api.nvim_win_get_cursor(0)
  assert(pos[1] == 3, "cursor should be on line 3, got " .. pos[1])
end)

it("show_user on a missing file returns an error string", function()
  local out = registry.call("tool.show_user",
    { path = vim.fn.tempname() .. "/nope.txt" }, { bufnr = 0 })
  assert(out:find("no such file", 1, true), "unexpected: " .. out)
end)

-- ------------------------------------------------------------- run_in_terminal

it("run_in_terminal streams output and closes the split on success", function()
  local wins_before = #vim.api.nvim_list_wins()
  local out = drive(function(ctx)
    return registry.call("tool.run_in_terminal",
      { command = "echo STRAPS-TERM-OK && exit 0" }, ctx)
  end, 15000)
  assert(out:find("exit code: 0", 1, true), "exit code missing:\n" .. out:sub(1, 200))
  assert(out:find("STRAPS-TERM-OK", 1, true), "output missing:\n" .. out:sub(1, 400))
  assert(out:find("terminal split closed", 1, true), "closed note missing:\n" .. out:sub(1, 400))
  assert(#vim.api.nvim_list_wins() == wins_before,
    "terminal split should be closed after a successful command")
end)

it("run_in_terminal reports a nonzero exit code and leaves the split open", function()
  local wins_before = #vim.api.nvim_list_wins()
  local out = drive(function(ctx)
    return registry.call("tool.run_in_terminal", { command = "exit 3" }, ctx)
  end, 15000)
  assert(out:find("exit code: 3", 1, true), "expected exit code 3:\n" .. out:sub(1, 200))
  assert(out:find("terminal split left open", 1, true), "left-open note missing")
  assert(#vim.api.nvim_list_wins() == wins_before + 1,
    "terminal split should stay open after a failing command")
  vim.cmd("only") -- normalize windows for later cases
end)

it("run_in_terminal stops a job that exceeds timeout_ms", function()
  local wins_before = #vim.api.nvim_list_wins()
  local t0 = vim.uv.hrtime()
  local out = drive(function(ctx)
    return registry.call("tool.run_in_terminal",
      { command = "sleep 30", timeout_ms = 400 }, ctx)
  end, 15000)
  local ms = (vim.uv.hrtime() - t0) / 1e6
  assert(out:find("stopped: exceeded timeout of 400 ms", 1, true),
    "timeout note missing:\n" .. out:sub(1, 200))
  assert(ms < 5000, "timeout did not stop the job promptly: " .. math.floor(ms) .. "ms")
  assert(out:find("terminal split left open", 1, true), "left-open note missing")
  assert(#vim.api.nvim_list_wins() == wins_before + 1,
    "terminal split should stay open after a timeout")
  vim.cmd("only")
end)

it("run_in_terminal is killed by cancellation", function()
  local cancel_fns = {}
  -- Fire the registered cancel handlers shortly after the job starts, the
  -- way loop.stop does for a real run.
  vim.defer_fn(function()
    for _, fn in ipairs(cancel_fns) do pcall(fn) end
  end, 300)
  local t0 = vim.uv.hrtime()
  local out = drive(function(ctx)
    return registry.call("tool.run_in_terminal", { command = "sleep 30" }, ctx)
  end, 15000, {
    on_cancel = function(fn) cancel_fns[#cancel_fns + 1] = fn end,
  })
  local ms = (vim.uv.hrtime() - t0) / 1e6
  assert(#cancel_fns > 0, "tool never registered a cancel handler")
  assert(out:find("exit code:", 1, true), "cancelled job should still report its exit")
  assert(ms < 5000, "cancel did not stop the job promptly: " .. math.floor(ms) .. "ms")
  vim.cmd("only")
end)

-- Poll pgrep for up to `timeout_ms` for a pattern to disappear, to avoid a
-- race between the kill and the process table updating.
local function wait_for_dead(pattern, timeout_ms)
  local deadline = vim.uv.hrtime() + (timeout_ms or 2000) * 1e6
  while vim.uv.hrtime() < deadline do
    local out = vim.fn.system({ "pgrep", "-f", pattern })
    if vim.v.shell_error ~= 0 or out:match("^%s*$") then return true end
    vim.wait(100)
  end
  return false
end

-- A fractional sleep duration unique to THIS process makes the grandchild's
-- cmdline ("sleep 87.<pid>") collision-proof against a concurrent run of the
-- same suite (parallel CI, two checkouts): pgrep/pkill -f on it can neither
-- see nor kill another run's sleeps.
local kill_tag
step(function()
  kill_tag = tostring(vim.uv.os_getpid())
end)

it("bash cancel kills the whole process tree", function()
  local pat = "sleep 87." .. kill_tag
  local ok, err = pcall(function()
    local cancel_fns = {}
    vim.defer_fn(function()
      for _, fn in ipairs(cancel_fns) do pcall(fn) end
    end, 200)
    local t0 = vim.uv.hrtime()
    local out = drive(function(ctx)
      return registry.call("tool.bash",
        { command = pat .. "; echo done-marker-straps-a" }, ctx)
    end, 15000, {
      on_cancel = function(fn) cancel_fns[#cancel_fns + 1] = fn end,
    })
    local ms = (vim.uv.hrtime() - t0) / 1e6
    assert(#cancel_fns > 0, "tool never registered a cancel handler")
    assert(out:find("exit code:", 1, true), "cancelled command should still report its exit")
    assert(ms < 5000, "cancel did not stop the command promptly: " .. math.floor(ms) .. "ms")
    assert(wait_for_dead(pat, 2000), pat .. " survived the cancel")
  end)
  pcall(vim.fn.system, { "pkill", "-f", pat })
  assert(ok, tostring(err))
end)

it("bash timeout kills a surviving process tree", function()
  local pat = "sleep 88." .. kill_tag
  local ok, err = pcall(function()
    local t0 = vim.uv.hrtime()
    local out = drive(function(ctx)
      return registry.call("tool.bash",
        { command = pat .. "; echo never", timeout_ms = 500 }, ctx)
    end, 15000)
    local ms = (vim.uv.hrtime() - t0) / 1e6
    assert(out:find("exceeded timeout", 1, true), "timeout note missing:\n" .. out:sub(1, 200))
    assert(ms < 6000, "timeout did not stop the command promptly: " .. math.floor(ms) .. "ms")
    assert(wait_for_dead(pat, 2000), pat .. " survived the timeout")
  end)
  pcall(vim.fn.system, { "pkill", "-f", pat })
  assert(ok, tostring(err))
end)

it("run_in_terminal cleans up the split when the job cannot start", function()
  -- An extra window, with focus kept in it: with only two windows, closing
  -- the terminal split would land focus back on the right window by accident,
  -- so an explicit focus restore would be indistinguishable from luck.
  vim.cmd("new")
  local wins_before = #vim.api.nvim_list_wins()
  local win_before = vim.api.nvim_get_current_win()
  -- Force the start-failure path: both job starters report failure.
  local real_jobstart, real_termopen = vim.fn.jobstart, vim.fn.termopen
  vim.fn.jobstart = function() return -1 end
  vim.fn.termopen = function() return -1 end
  local dok, out = pcall(drive, function(ctx)
    local ok, err = pcall(registry.call, "tool.run_in_terminal", { command = "echo hi" }, ctx)
    return ok and "unexpectedly succeeded" or tostring(err)
  end, 15000)
  vim.fn.jobstart = real_jobstart
  vim.fn.termopen = real_termopen
  assert(dok, tostring(out))
  assert(out:find("could not start the terminal job", 1, true), "start error missing: " .. out)
  assert(#vim.api.nvim_list_wins() == wins_before,
    "split should be cleaned up when the job never starts")
  assert(vim.api.nvim_get_current_win() == win_before,
    "focus should return to the previous window")
  vim.cmd("only") -- normalize windows for later cases
end)

-- ---------------------------------------------------------------- hook.confirm

it("new read-only tools are auto-allowed; code_action gates on index", function()
  for _, n in ipairs({ "hover", "workspace_symbols", "context", "show_user", "help_search" }) do
    assert(registry.call("hook.confirm", n, {}, { bufnr = 0 }) == true,
      n .. " should be auto-allowed")
  end
  assert(registry.call("hook.confirm", "code_action",
    { path = "x", line = 1, col = 1 }, { bufnr = 0 }) == true,
    "code_action without index (list mode) should be auto-allowed")
  assert(registry.call("hook.confirm", "fix_diagnostic",
    { path = "x", line = 1, col = 1 }, { bufnr = 0 }) == true,
    "fix_diagnostic without index (list mode) should be auto-allowed")
  -- Applying (index set) must fall through to the prompt; headless confirm
  -- returns 0 -> denied.
  local allowed = registry.call("hook.confirm", "code_action",
    { path = "x", line = 1, col = 1, index = 1 }, { bufnr = 0 })
  assert(allowed ~= true, "code_action with index must not be auto-allowed")
  allowed = registry.call("hook.confirm", "fix_diagnostic",
    { path = "x", line = 1, col = 1, index = 1 }, { bufnr = 0 })
  assert(allowed ~= true, "fix_diagnostic with index must not be auto-allowed")
  for _, n in ipairs({ "rename_symbol", "format", "run_in_terminal" }) do
    assert(registry.call("hook.confirm", n, {}, { bufnr = 0 }) ~= true,
      n .. " must not be auto-allowed")
  end
end)

it("confirm shows a diff preview for edit_file and cleans up the split", function()
  local path = vim.fn.tempname() .. ".txt"
  write_file(path, "keep\nFOO here\nkeep\n")
  local wins_before = #vim.api.nvim_list_wins()

  -- Stub vim.fn.confirm to observe the moment the dialog is up: the preview
  -- split must exist THEN (with a diff of the proposed change in it), and the
  -- prompt must point at it instead of dumping JSON. Returns 0 (deny).
  local seen = { prompt = nil, wins = 0, diff = nil }
  local real_confirm = vim.fn.confirm
  vim.fn.confirm = function(msg)
    seen.prompt = msg
    seen.wins = #vim.api.nvim_list_wins()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local b = vim.api.nvim_win_get_buf(win)
      if vim.bo[b].filetype == "diff" then
        seen.diff = table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
      end
    end
    return 0
  end
  local ok, allowed = pcall(registry.call, "hook.confirm", "edit_file",
    { path = path, old_string = "FOO here", new_string = "BAR now" }, { bufnr = 0 })
  vim.fn.confirm = real_confirm
  assert(ok, "hook.confirm errored: " .. tostring(allowed))

  assert(allowed ~= true, "edit_file should be denied when confirm returns 0")
  assert(seen.wins == wins_before + 1, "preview split missing while dialog was up")
  assert(seen.prompt:find("diff preview shown in the split below", 1, true),
    "prompt should reference the preview, got:\n" .. tostring(seen.prompt))
  assert(seen.diff and seen.diff:find("-FOO here", 1, true)
    and seen.diff:find("+BAR now", 1, true),
    "preview is not a diff of the proposed change:\n" .. tostring(seen.diff))
  assert(#vim.api.nvim_list_wins() == wins_before,
    "diff preview split leaked: " .. #vim.api.nvim_list_wins() .. " wins")
end)

-- -------------------------------------------------------------------- ask_user

local function transcript_buf()
  local b = vim.api.nvim_create_buf(false, true)
  vim.b[b].straps_session = true
  state.append(b, "user", nil, "pick an approach")
  state.append(b, "assistant", nil, "thinking first\nLAST-ASSISTANT-LINE")
  state.append(b, "tool_use", { id = "ask1", name = "ask_user" },
    '{\n  "question": "Which?",\n  "options": ["A", "B"]\n}')
  vim.cmd("botright split")
  local w = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(w, b)
  return b, w
end

local function press(b, lhs)
  vim.api.nvim_buf_call(b, function()
    local m = vim.fn.maparg(lhs, "n", false, true)
    assert(m.callback, "no buffer map for " .. lhs)
    m.callback()
  end)
end

local function ask(b, input, during, ctx_extra)
  vim.schedule(during)
  local extra = { bufnr = b }
  for k, v in pairs(ctx_extra or {}) do extra[k] = v end
  return pcall(drive, function(ctx)
    return registry.call("tool.ask_user", input, ctx)
  end, 5000, extra)
end

local function ask_ns_marks(b)
  return vim.api.nvim_buf_get_extmarks(b, vim.api.nvim_create_namespace("straps_ask_user"),
    0, -1, { details = true })
end

it("ask_user renders inline under the last assistant line; 2 chooses; prior <CR> map restored", function()
  local b, w = transcript_buf()
  local prior_hit = false
  vim.keymap.set("n", "<CR>", function() prior_hit = true end, { buffer = b, desc = "prior-cr" })
  local wins_before = #vim.api.nvim_list_wins()
  local seen = {}
  local ok, out = ask(b, {
    question = "Which approach?",
    options = { "Approach A", "Approach B" },
    content = "PROPOSED-CONTENT line\nmore",
  }, function()
    seen.marks = ask_ns_marks(b)
    seen.wins = #vim.api.nvim_list_wins()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false), "\n")
      if text:find("PROPOSED-CONTENT", 1, true) then seen.content_visible = true end
    end
    vim.api.nvim_buf_call(b, function()
      seen.cr_desc = vim.fn.maparg("<CR>", "n", false, true).desc
    end)
    press(b, "2")
  end)
  assert(ok, "ask_user errored: " .. tostring(out))
  assert(out == "user chose option 2: Approach B", "unexpected: " .. out)

  local want_row
  for i, l in ipairs(vim.api.nvim_buf_get_lines(b, 0, -1, false)) do
    if l == "LAST-ASSISTANT-LINE" then want_row = i - 1 end
  end
  assert(seen.marks and #seen.marks == 1, "expected one virt_lines extmark: " .. vim.inspect(seen.marks))
  assert(seen.marks[1][2] == want_row,
    ("extmark on row %d, want last assistant row %d"):format(seen.marks[1][2], want_row))
  local flat = {}
  for _, vl in ipairs(seen.marks[1][4].virt_lines) do
    local parts = {}
    for _, chunk in ipairs(vl) do parts[#parts + 1] = chunk[1] end
    flat[#flat + 1] = table.concat(parts)
  end
  local text = table.concat(flat, "\n")
  assert(text:find("question · 2 options", 1, true), "header missing:\n" .. text)
  assert(text:find("Which approach?", 1, true), "question missing:\n" .. text)
  assert(text:find("▸ 1. Approach A", 1, true) and text:find("2. Approach B", 1, true),
    "options missing:\n" .. text)
  assert(text:find("o. (other: type your own answer)", 1, true), "other line missing:\n" .. text)
  assert(text:find("j/k move · <CR> choose · 1-9 pick · o other · <Esc> dismiss", 1, true),
    "hint missing:\n" .. text)
  assert(seen.cr_desc == "straps: ask_user", "<CR> not taken over: " .. tostring(seen.cr_desc))
  assert(seen.content_visible and seen.wins == wins_before + 1, "content split missing while asking")

  assert(#vim.api.nvim_list_wins() == wins_before, "content split leaked")
  assert(#ask_ns_marks(b) == 0, "virt_lines left behind")
  vim.api.nvim_buf_call(b, function()
    local m = vim.fn.maparg("<CR>", "n", false, true)
    assert(m.desc == "prior-cr", "prior <CR> map not restored: " .. vim.inspect(m))
    m.callback()
    assert(vim.fn.maparg("j", "n", false, true).buffer ~= 1, "j map left behind")
  end)
  assert(prior_hit, "restored <CR> callback is not the original")
  pcall(vim.api.nvim_win_close, w, true)
end)

it("ask_user <Esc> dismisses; cancellation also dismisses", function()
  local b, w = transcript_buf()
  local ok, out = ask(b, { question = "Pick?", options = { "a", "b" } },
    function() press(b, "<Esc>") end)
  assert(ok, "ask_user errored: " .. tostring(out))
  assert(out == "user dismissed the question without choosing — proceed on your best judgment or ask differently",
    "unexpected: " .. out)

  local cancel_fn
  ok, out = ask(b, { question = "Pick?", options = { "a", "b" } },
    function() cancel_fn() end, { on_cancel = function(fn) cancel_fn = fn end })
  assert(ok, "ask_user errored: " .. tostring(out))
  assert(out:find("dismissed the question", 1, true), "on_cancel did not dismiss: " .. out)
  assert(#ask_ns_marks(b) == 0, "virt_lines left behind after cancel")
  pcall(vim.api.nvim_win_close, w, true)
end)

it("ask_user previews swap in one split as j moves; preview buffers are deleted after", function()
  local b, w = transcript_buf()
  local wins_before = #vim.api.nvim_list_wins()
  local seen = {}
  local function snap(tag)
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local wb = vim.wo[win].winbar
      if wb:match("^preview of option") then
        local pb = vim.api.nvim_win_get_buf(win)
        seen[tag] = { winbar = wb, buf = pb, ft = vim.bo[pb].filetype,
          text = table.concat(vim.api.nvim_buf_get_lines(pb, 0, -1, false), "\n") }
      end
    end
    seen[tag .. "_wins"] = #vim.api.nvim_list_wins()
  end
  local ok, out = ask(b, {
    question = "Which implementation?",
    options = {
      { label = "Guard clause", preview = "GUARD-SKETCH", filetype = "lua" },
      { label = "100% push", preview = "PUSH-SKETCH" },
      "plain",
    },
    filetype = "markdown",
  }, function()
    snap("first")
    press(b, "j")
    snap("second")
    press(b, "j")
    snap("third")
    press(b, "k")
    press(b, "<CR>")
  end)
  assert(ok, "ask_user errored: " .. tostring(out))
  assert(out == "user chose option 2: 100% push", "unexpected: " .. out)
  assert(seen.first_wins == wins_before + 1, "expected exactly one preview split")
  assert(seen.first.winbar == "preview of option 1: Guard clause", seen.first.winbar)
  assert(seen.first.text == "GUARD-SKETCH" and seen.first.ft == "lua", vim.inspect(seen.first))
  assert(seen.second.winbar == "preview of option 2: 100%% push", seen.second.winbar)
  assert(seen.second.text == "PUSH-SKETCH" and seen.second.ft == "markdown", vim.inspect(seen.second))
  assert(seen.third.text:find("no preview", 1, true), vim.inspect(seen.third))
  assert(#vim.api.nvim_list_wins() == wins_before, "preview split leaked")
  for _, tag in ipairs({ "first", "second", "third" }) do
    assert(not vim.api.nvim_buf_is_valid(seen[tag].buf), "preview buffer not deleted: " .. tag)
  end
  pcall(vim.api.nvim_win_close, w, true)
end)

it("ask_user o goes to free-text input; opens a window when the buffer has none and closes it after", function()
  local b, w = transcript_buf()
  vim.api.nvim_win_close(w, true)
  local wins_before = #vim.api.nvim_list_wins()
  local real_input = vim.ui.input
  vim.ui.input = function(_, on_confirm) on_confirm("my custom answer") end
  local had_win
  local ok, out = ask(b, { question = "Name?", options = { "foo", "bar" } }, function()
    had_win = vim.fn.bufwinid(b) ~= -1
    press(b, "o")
  end)
  vim.ui.input = real_input
  assert(ok, "ask_user errored: " .. tostring(out))
  assert(had_win, "ask_user should open a window for a hidden session buffer")
  assert(out == "user answered (free text): my custom answer", "unexpected: " .. out)
  assert(#vim.api.nvim_list_wins() == wins_before, "the window ask_user opened leaked")
end)

it("ask_user refuses a buffer that is not a straps session", function()
  local b = vim.api.nvim_create_buf(false, true)
  local ok, out = ask(b, { question = "Pick?", options = { "a", "b" } }, function() end)
  assert(ok, "ask_user errored: " .. tostring(out))
  assert(out == "ask_user: no session buffer", "unexpected: " .. out)
  vim.api.nvim_buf_call(b, function()
    assert(vim.fn.maparg("j", "n", false, true).buffer ~= 1, "j map bound on a non-session buffer")
  end)
end)

it("ask_user keeps drawing after the session window is closed and reopened", function()
  local b, w = transcript_buf()
  local text_after
  local ok, out = ask(b, { question = "Pick?", options = { "a", "b" } }, function()
    vim.api.nvim_win_close(w, true)
    vim.cmd("botright split")
    vim.api.nvim_win_set_buf(0, b)
    press(b, "j")
    local flat = {}
    for _, vl in ipairs(ask_ns_marks(b)[1][4].virt_lines) do
      for _, chunk in ipairs(vl) do flat[#flat + 1] = chunk[1] end
    end
    text_after = table.concat(flat)
    press(b, "<CR>")
  end)
  assert(ok, "ask_user errored: " .. tostring(out))
  assert(out == "user chose option 2: b", "unexpected: " .. out)
  assert(text_after and text_after:find("▸ 2. b", 1, true), "selection not redrawn in the new window: " .. tostring(text_after))
  pcall(vim.api.nvim_win_close, vim.fn.bufwinid(b), true)
end)

it("ask_user survives the user closing the preview split", function()
  local b, w = transcript_buf()
  local ok, out = ask(b, {
    question = "Which?",
    options = { { label = "x", preview = "X" }, { label = "y", preview = "Y" } },
  }, function()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.wo[win].winbar:match("^preview of option") then vim.api.nvim_win_close(win, true) end
    end
    press(b, "j")
    press(b, "<CR>")
  end)
  assert(ok, "ask_user errored: " .. tostring(out))
  assert(out == "user chose option 2: y", "unexpected: " .. out)
  pcall(vim.api.nvim_win_close, w, true)
end)

it("ask_user restores the user's window after the answer", function()
  local b, w = transcript_buf()
  vim.cmd("botright split")
  local user_win = vim.api.nvim_get_current_win()
  local ok, out = ask(b, { question = "Pick?", options = { "a", "b" } }, function()
    assert(vim.api.nvim_get_current_win() == w, "focus should be on the session window while asking")
    press(b, "1")
  end)
  assert(ok, "ask_user errored: " .. tostring(out))
  assert(out == "user chose option 1: a", "unexpected: " .. out)
  assert(vim.api.nvim_get_current_win() == user_win, "user window not restored")
  pcall(vim.api.nvim_win_close, user_win, true)
  pcall(vim.api.nvim_win_close, w, true)
end)

it("ask_user without options is a free-text prompt; dismissal is reported", function()
  local real_input = vim.ui.input
  vim.ui.input = function(_, on_confirm) on_confirm("just typing") end
  local ok, out = pcall(drive, function(ctx)
    return registry.call("tool.ask_user", { question = "Anything?" }, ctx)
  end)
  assert(ok, "ask_user errored: " .. tostring(out))
  assert(out == "user answered: just typing", "unexpected: " .. out)
  vim.ui.input = function(_, on_confirm) on_confirm(nil) end
  ok, out = pcall(drive, function(ctx)
    return registry.call("tool.ask_user", { question = "Anything?" }, ctx)
  end)
  vim.ui.input = real_input
  assert(ok, "ask_user errored: " .. tostring(out))
  assert(out == "user dismissed the input without answering — do not re-ask the identical question",
    "unexpected: " .. out)
end)

it("ask_user is auto-allowed by hook.confirm", function()
  assert(registry.call("hook.confirm", "ask_user", { question = "?" }, { bufnr = 0 }) == true,
    "ask_user should be auto-allowed — it IS the user interaction")
end)

-- ------------------------------------------------------------------- undo_edit

it("undo_edit lists history, surgically reverts an edit, and redoes via to_seq", function()
  local path = vim.fn.tempname() .. ".txt"
  write_file(path, "alpha\nFOO\nomega\n")
  local function disk()
    local f = assert(io.open(path, "r"))
    local t = f:read("*a")
    f:close()
    return t
  end

  registry.call("tool.edit_file",
    { path = path, old_string = "FOO", new_string = "BAR" }, { bufnr = 0 })
  assert(disk():find("BAR", 1, true), "setup edit did not land on disk")

  local hist = registry.call("tool.undo_edit", { path = path, history = true }, { bufnr = 0 })
  assert(hist:find("seq 1", 1, true), "history missing the edit's state:\n" .. hist)
  assert(hist:find("current", 1, true), "history missing the current marker:\n" .. hist)

  local out = registry.call("tool.undo_edit", { path = path }, { bufnr = 0 })
  assert(out:find("moved from seq 1 to seq 0", 1, true), "unexpected undo result: " .. out)
  assert(disk():find("FOO", 1, true) and not disk():find("BAR", 1, true),
    "undo did not restore the original on disk:\n" .. disk())

  local redo_seq = out:match("to_seq=(%d+)")
  assert(redo_seq, "undo result missing the redo seq: " .. out)
  out = registry.call("tool.undo_edit",
    { path = path, to_seq = tonumber(redo_seq) }, { bufnr = 0 })
  assert(out:find("moved from seq 0 to seq 1", 1, true), "unexpected redo result: " .. out)
  assert(disk():find("BAR", 1, true), "redo did not reapply the edit on disk:\n" .. disk())
end)

it("undo_edit reports cleanly when there is nothing to undo", function()
  local path = vim.fn.tempname() .. ".txt"
  write_file(path, "pristine\n")
  local out = registry.call("tool.undo_edit", { path = path }, { bufnr = 0 })
  assert(out:find("nothing changed", 1, true), "unexpected: " .. out)
end)

it("revert_seq surgically reverts one edit while keeping later edits", function()
  local path = vim.fn.tempname() .. ".txt"
  write_file(path, "one\ntwo\nthree\nfour\nfive\n")
  local function disk()
    local f = assert(io.open(path, "r"))
    local t = f:read("*a")
    f:close()
    return t
  end
  -- seq 1: two -> TWO; seq 2: five -> FIVE (separate lines, no overlap).
  registry.call("tool.edit_file",
    { path = path, old_string = "two", new_string = "TWO" }, { bufnr = 0 })
  registry.call("tool.edit_file",
    { path = path, old_string = "five", new_string = "FIVE" }, { bufnr = 0 })
  assert(disk():find("TWO", 1, true) and disk():find("FIVE", 1, true), "setup edits missing")

  local out = registry.call("tool.undo_edit", { path = path, revert_seq = 1 }, { bufnr = 0 })
  assert(out:find("surgically reverted seq 1", 1, true), "unexpected result: " .. out)
  local now = disk()
  assert(now:find("two", 1, true) and not now:find("TWO", 1, true),
    "seq 1 not reverted on disk:\n" .. now)
  assert(now:find("FIVE", 1, true), "later edit (seq 2) was lost:\n" .. now)
end)

it("revert_seq refuses with a conflict when later edits overlap", function()
  local path = vim.fn.tempname() .. ".txt"
  write_file(path, "alpha\nbeta\ngamma\n")
  local function disk()
    local f = assert(io.open(path, "r"))
    local t = f:read("*a")
    f:close()
    return t
  end
  -- seq 1: beta -> BETA; seq 2 edits the SAME line: BETA -> BETA-MORE.
  registry.call("tool.edit_file",
    { path = path, old_string = "beta", new_string = "BETA" }, { bufnr = 0 })
  registry.call("tool.edit_file",
    { path = path, old_string = "BETA", new_string = "BETA-MORE" }, { bufnr = 0 })

  local out = registry.call("tool.undo_edit", { path = path, revert_seq = 1 }, { bufnr = 0 })
  assert(out:find("cannot surgically revert seq 1", 1, true), "expected a conflict: " .. out)
  assert(out:find("to_seq", 1, true), "conflict should point at the fallback: " .. out)
  assert(disk():find("BETA%-MORE"), "conflict must not change the file:\n" .. disk())
end)

it("revert_seq refuses when the buffer has unsaved changes", function()
  local path = vim.fn.tempname() .. ".txt"
  write_file(path, "aaa\nbbb\n")
  registry.call("tool.edit_file",
    { path = path, old_string = "aaa", new_string = "AAA" }, { bufnr = 0 })
  -- Simulate the user mid-edit: an unsaved buffer change.
  local buf = vim.fn.bufadd(vim.fn.fnamemodify(path, ":p"))
  vim.fn.bufload(buf)
  vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "bbb user-typing" })
  assert(vim.bo[buf].modified, "buffer should be modified for this test")

  local out = registry.call("tool.undo_edit", { path = path, revert_seq = 1 }, { bufnr = 0 })
  assert(out:find("unsaved changes", 1, true), "guard did not trip: " .. out)
  local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  assert(text:find("user%-typing") and text:find("AAA", 1, true),
    "guard must leave the buffer untouched:\n" .. text)
  vim.api.nvim_buf_call(buf, function() vim.cmd("silent! write") end) -- clean up
end)

it("undo_edit reverts a PREVIOUS session's edit via 'undofile' persistence", function()
  local undodir = vim.fn.tempname()
  vim.fn.mkdir(undodir, "p")
  local saved_uf, saved_ud = vim.o.undofile, vim.o.undodir
  vim.o.undofile = true
  vim.o.undodir = undodir

  local ok, err = pcall(function()
    local path = vim.fn.tempname() .. ".txt"
    write_file(path, "original\nkeep\n")
    registry.call("tool.edit_file",
      { path = path, old_string = "original", new_string = "EDITED" }, { bufnr = 0 })
    local f = assert(io.open(path, "r")); local d = f:read("*a"); f:close()
    assert(d:find("EDITED", 1, true), "setup edit missing")

    -- Simulate a new session with no memory: wipe the buffer entirely. The
    -- undo tree must come back from the undofile when the buffer reloads.
    local buf = vim.fn.bufadd(vim.fn.fnamemodify(path, ":p"))
    vim.cmd("bwipeout! " .. buf)

    local hist = registry.call("tool.undo_edit", { path = path, history = true }, { bufnr = 0 })
    assert(hist:find("seq 1", 1, true),
      "prior session's edit missing from reloaded history:\n" .. hist)

    local out = registry.call("tool.undo_edit", { path = path }, { bufnr = 0 })
    assert(out:find("moved from seq 1 to seq 0", 1, true), "unexpected: " .. out)
    f = assert(io.open(path, "r")); d = f:read("*a"); f:close()
    assert(d:find("original", 1, true) and not d:find("EDITED", 1, true),
      "cross-session revert did not land on disk:\n" .. d)
  end)
  vim.o.undofile = saved_uf
  vim.o.undodir = saved_ud
  assert(ok, err)
end)

it("revert_seq handles a multi-hunk edit with a later edit interleaved", function()
  local path = vim.fn.tempname() .. ".txt"
  write_file(path,
    "FOO one\nfiller-a\nfiller-b\nmid line\nFOO two\nfiller-c\nfiller-d\nFOO three\ntail\n")
  local function disk()
    local f = assert(io.open(path, "r")); local t = f:read("*a"); f:close(); return t
  end
  -- seq 1: one undo block, three spread-out hunks.
  registry.call("tool.edit_file",
    { path = path, old_string = "FOO", new_string = "BAR", replace_all = true }, { bufnr = 0 })
  -- seq 2: a later edit BETWEEN the hunks.
  registry.call("tool.edit_file",
    { path = path, old_string = "mid line", new_string = "MID-EDIT" }, { bufnr = 0 })
  assert(select(2, disk():gsub("BAR", "")) == 3 and disk():find("MID%-EDIT"), "setup wrong")

  local out = registry.call("tool.undo_edit", { path = path, revert_seq = 1 }, { bufnr = 0 })
  assert(out:find("surgically reverted seq 1", 1, true), "unexpected: " .. out)
  assert(out:find("3 hunks", 1, true), "should report 3 hunks: " .. out)
  local now = disk()
  assert(select(2, now:gsub("FOO", "")) == 3 and not now:find("BAR", 1, true),
    "all three hunks should revert:\n" .. now)
  assert(now:find("MID%-EDIT"), "interleaved later edit was lost:\n" .. now)
end)

it("undo_edit history is auto-allowed; an actual undo prompts", function()
  assert(registry.call("hook.confirm", "undo_edit", { path = "x", history = true },
    { bufnr = 0 }) == true, "history mode should be auto-allowed")
  assert(registry.call("hook.confirm", "undo_edit", { path = "x" },
    { bufnr = 0 }) ~= true, "undoing must not be auto-allowed")
  assert(registry.call("hook.confirm", "undo_edit", { path = "x", to_seq = 3 },
    { bufnr = 0 }) ~= true, "to_seq jumps must not be auto-allowed")
  assert(registry.call("hook.confirm", "undo_edit", { path = "x", revert_seq = 1 },
    { bufnr = 0 }) ~= true, "revert_seq must not be auto-allowed")
end)

-- ------------------------------------------------------- confirm edit grants

it("'Always in <dir>' grants the parent directory, not neighbors with the same prefix", function()
  local base = vim.fn.tempname()
  vim.fn.mkdir(base .. "/aa", "p")
  vim.fn.mkdir(base .. "/aab", "p")
  -- The hook records grants under canonical paths (fs_realpath), so compare
  -- against the canonical base (on macOS tempname says /var, realpath /private/var).
  base = vim.uv.fs_realpath(base) or base
  local cbuf = vim.api.nvim_create_buf(true, false)
  local prompts = 0
  local real_confirm = vim.fn.confirm
  vim.fn.confirm = function() prompts = prompts + 1; return 3 end -- Always in <dir>

  -- First edit under /aa: prompts once, grant recorded.
  local allowed = registry.call("hook.confirm", "edit_file",
    { path = base .. "/aa/one.txt", old_string = "x", new_string = "y" }, { bufnr = cbuf })
  assert(allowed == true, "choice 3 should allow")
  assert(prompts == 1, "expected exactly one prompt, got " .. prompts)
  local set = registry.granted(cbuf)
  assert(type(set) == "table" and set["editdir:" .. base .. "/aa"],
    "editdir grant missing: " .. vim.inspect(set))

  -- Second edit under the SAME dir (and a subdir): no prompt at all.
  vim.fn.confirm = function() prompts = prompts + 1; return 0 end -- would deny if asked
  allowed = registry.call("hook.confirm", "edit_file",
    { path = base .. "/aa/two.txt", old_string = "x", new_string = "y" }, { bufnr = cbuf })
  assert(allowed == true, "granted dir should auto-allow")
  allowed = registry.call("hook.confirm", "write_file",
    { path = base .. "/aa/sub/three.txt", content = "c" }, { bufnr = cbuf })
  assert(allowed == true, "grant should cover subdirectories and both edit tools")
  assert(prompts == 1, "auto-allowed edits must not prompt, prompts = " .. prompts)

  -- Prefix boundary: /aa granted must NOT cover /aab.
  allowed = registry.call("hook.confirm", "edit_file",
    { path = base .. "/aab/four.txt", old_string = "x", new_string = "y" }, { bufnr = cbuf })
  assert(allowed ~= true, "/aab must not match the /aa grant (prefix bug)")
  assert(prompts == 2, "the /aab edit should have prompted")

  -- The edit grant never leaks to non-edit tools.
  allowed = registry.call("hook.confirm", "bash",
    { command = "rm -rf " .. base }, { bufnr = cbuf })
  assert(allowed ~= true, "editdir grant leaked to bash")

  vim.fn.confirm = real_confirm
end)

it("'Always in <dir>' grant resolves symlinks before auto-allowing", function()
  local base = vim.fn.tempname()
  vim.fn.mkdir(base .. "/allowed", "p")
  vim.fn.mkdir(base .. "/outside", "p")
  local link = base .. "/allowed/link"
  local ok_link = pcall(vim.uv.fs_symlink, base .. "/outside", link, { dir = true })
  if not ok_link then
    print("SKIP  symlink creation unsupported")
    return
  end
  local cbuf = vim.api.nvim_create_buf(true, false)
  local real_confirm = vim.fn.confirm
  vim.fn.confirm = function() return 3 end
  local allowed = registry.call("hook.confirm", "edit_file",
    { path = base .. "/allowed/one.txt", old_string = "x", new_string = "y" }, { bufnr = cbuf })
  assert(allowed == true, "initial grant should allow")
  vim.fn.confirm = function() return 0 end
  allowed = registry.call("hook.confirm", "edit_file",
    { path = link .. "/escape.txt", old_string = "x", new_string = "y" }, { bufnr = cbuf })
  vim.fn.confirm = real_confirm
  assert(allowed ~= true, "symlink escape under granted dir must not auto-allow")
end)

it("'Always all edits' grants every path for edit tools only", function()
  local cbuf = vim.api.nvim_create_buf(true, false)
  local real_confirm = vim.fn.confirm
  vim.fn.confirm = function() return 4 end -- Always all edits
  local allowed = registry.call("hook.confirm", "write_file",
    { path = vim.fn.tempname() .. "/a.txt", content = "c" }, { bufnr = cbuf })
  assert(allowed == true, "choice 4 should allow")
  assert(registry.granted(cbuf)["editfiles:*"], "editfiles:* grant missing")

  vim.fn.confirm = function() return 0 end
  allowed = registry.call("hook.confirm", "edit_file",
    { path = "/anywhere/else.txt", old_string = "x", new_string = "y" }, { bufnr = cbuf })
  assert(allowed == true, "editfiles:* should cover any path")
  allowed = registry.call("hook.confirm", "run_in_terminal",
    { command = "echo hi" }, { bufnr = cbuf })
  assert(allowed ~= true, "editfiles:* leaked to a non-edit tool")
  vim.fn.confirm = real_confirm
end)

it("'Always in this project' grants the whole repo root, covering sibling dirs", function()
  local base = vim.fn.tempname()
  vim.fn.mkdir(base .. "/.git", "p")
  -- realpath only works on an existing path, so canonicalize AFTER mkdir
  -- (on macOS tempname says /var, realpath /private/var — and the hook
  -- records grants under canonical paths).
  local root = vim.uv.fs_realpath(base) or base
  vim.fn.mkdir(root .. "/lua/straps", "p")
  vim.fn.mkdir(root .. "/tests", "p")
  local cbuf = vim.api.nvim_create_buf(true, false)
  local prompts = 0
  local real_confirm = vim.fn.confirm
  -- The project choice sits at index 4 for a file under lua/straps (parent
  -- dir is index 3, project root index 4, all-edits index 5).
  vim.fn.confirm = function() prompts = prompts + 1; return 4 end

  local allowed = registry.call("hook.confirm", "edit_file",
    { path = root .. "/lua/straps/one.txt", old_string = "x", new_string = "y" },
    { bufnr = cbuf })
  assert(allowed == true, "project choice should allow")
  assert(prompts == 1, "expected one prompt, got " .. prompts)
  local set = registry.granted(cbuf)
  assert(type(set) == "table" and set["editdir:" .. root],
    "project-root grant missing: " .. vim.inspect(set))

  -- A file in a SIBLING directory of the repo must now auto-allow (this is
  -- the whole point: one grant covers the project, not one directory).
  vim.fn.confirm = function() prompts = prompts + 1; return 0 end -- deny if asked
  allowed = registry.call("hook.confirm", "write_file",
    { path = root .. "/tests/two.txt", content = "c" }, { bufnr = cbuf })
  assert(allowed == true, "sibling dir under the project root should auto-allow")
  assert(prompts == 1, "sibling-dir edit must not prompt, prompts = " .. prompts)

  -- Outside the project root: still prompts.
  allowed = registry.call("hook.confirm", "edit_file",
    { path = vim.fn.tempname() .. "/outside.txt", old_string = "x", new_string = "y" },
    { bufnr = cbuf })
  assert(allowed ~= true, "a path outside the project root must not auto-allow")

  vim.fn.confirm = real_confirm
end)

it("the project choice is absent when the file has no root marker above it", function()
  -- tempname() lives under /tmp with no .git/.jj/etc above it, so the edit
  -- prompt has only 3 real choices and 'Always all edits' stays at index 4.
  local cbuf = vim.api.nvim_create_buf(true, false)
  local real_confirm = vim.fn.confirm
  vim.fn.confirm = function() return 4 end -- would be project idx if it existed
  local allowed = registry.call("hook.confirm", "write_file",
    { path = vim.fn.tempname() .. "/a.txt", content = "c" }, { bufnr = cbuf })
  vim.fn.confirm = real_confirm
  assert(allowed == true, "choice 4 should allow")
  -- With no project marker, index 4 is 'Always all edits', not a project grant.
  assert(registry.granted(cbuf)["editfiles:*"],
    "index 4 should be 'all edits' when no project choice is offered: "
      .. vim.inspect(registry.granted(cbuf)))
end)

-- -------------------------------------------------------------- autocmd_bridge

it("autocmd_bridge queues a hook's string onto the session buffer", function()
  local session = state.new_session()
  local prev = registry.set_active_scope(session)
  registry.define({
    name = "hook.bridge_test",
    kind = "hook",
    doc = "test bridge hook",
    source = [[return function(args) return "BRIDGE-MSG-42 (" .. tostring(args.event) .. ")" end]],
  })
  registry.set_active_scope(prev)
  local id = registry.call("fn.autocmd_bridge", {
    event = "User",
    pattern = "StrapsBridgeTest",
    entry = "hook.bridge_test",
    bufnr = session,
  })
  assert(type(id) == "number", "bridge should return an autocmd id")

  vim.api.nvim_exec_autocmds("User", { pattern = "StrapsBridgeTest" })
  local found = vim.wait(2000, function()
    local text = table.concat(vim.api.nvim_buf_get_lines(session, 0, -1, false), "\n")
    return text:find("BRIDGE-MSG-42", 1, true) ~= nil
  end, 20)
  assert(found, "bridged message never landed in the session buffer")

  -- No run is active, so it must have landed as an ordinary user block.
  local text = table.concat(vim.api.nvim_buf_get_lines(session, 0, -1, false), "\n")
  assert(text:find("BRIDGE-MSG-42 (User)", 1, true), "autocmd args not passed to the hook")
  vim.api.nvim_del_autocmd(id)
end)

-- --------------------------------------------------------------- running agents

it("running_agents / agents_status reflect active runs and parentage", function()
  local loop = require("straps.loop")
  local ui = require("straps.ui")

  -- No runs yet: empty list, empty statusline component.
  assert(#ui.running_agents() == 0, "expected no agents at rest")
  assert(ui.agents_status() == "", "statusline should be empty with no agents")

  -- Two session buffers, tagged as a parent/child pair like tool.spawn does.
  local parent = state.new_session()
  local child = state.new_session()
  vim.b[child].straps_parent = parent
  vim.b[child].straps_spawn_depth = 1
  vim.b[child].straps_task = "investigate the widget"

  -- Fake the loop's run registry directly (no network): start real runs would
  -- fire the provider. running_sessions reads the private `runs` table, so we
  -- start and immediately stop-flag is not enough — inject via loop.start would
  -- call the provider. Instead simulate by monkeypatching running_sessions.
  local real = loop.running_sessions
  loop.running_sessions = function() return { parent, child } end
  local ok, err = pcall(function()
    local agents = ui.running_agents()
    assert(#agents == 2, "expected two agents, got " .. #agents)
    -- Top-level first (depth 0), then the subagent.
    assert(agents[1].bufnr == parent and agents[1].parent == nil,
      "first agent should be the top-level parent")
    assert(agents[2].bufnr == child, "second agent should be the child")
    assert(agents[2].parent == parent, "child's parent bufnr wrong")
    assert(agents[2].parent_label ~= nil, "child should carry a parent label")
    assert(agents[2].task == "investigate the widget", "child task not surfaced")
    assert(agents[2].depth == 1, "child depth wrong")

    -- Statusline: one top-level + one subagent -> "🤖 1+1".
    local status = ui.agents_status()
    assert(status:find("1+1", 1, true), "unexpected statusline: " .. status)
  end)
  loop.running_sessions = real
  assert(ok, err)
end)

it("agents_status drops a stale/invalid parent to a top-level count", function()
  local loop = require("straps.loop")
  local ui = require("straps.ui")
  local child = state.new_session()
  local dead = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_delete(dead, { force = true })
  vim.b[child].straps_parent = dead -- points at a wiped buffer

  local real = loop.running_sessions
  loop.running_sessions = function() return { child } end
  local ok, err = pcall(function()
    local agents = ui.running_agents()
    assert(agents[1].parent == nil, "invalid parent should be dropped")
    assert(ui.agents_status() == "🤖 1", "one top-level agent expected: "
      .. ui.agents_status())
  end)
  loop.running_sessions = real
  assert(ok, err)
end)

it("tool.spawn tags the child buffer with parent and task", function()
  -- spawn tags the child buffer, then fires loop.start and returns immediately
  -- (no await). Stub loop.start so no network happens; the tagging happens
  -- before loop.start regardless.
  local parent = state.new_session()
  local before = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do before[b] = true end

  local loop = require("straps.loop")
  local real_start = loop.start
  loop.start = function() end
  local ok, out = pcall(drive, function(ctx)
    ctx.bufnr = parent
    return registry.call("tool.spawn",
      { task = "  do   the    thing  ", timeout_ms = 2000 }, ctx)
  end, 8000)
  loop.start = real_start
  assert(ok, "spawn errored: " .. tostring(out))
  assert(out:find("subagent started", 1, true), "spawn should return a start handle: " .. tostring(out))

  -- Find the newly-created session buffer.
  local child
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if not before[b] and vim.b[b] and vim.b[b].straps_parent == parent then
      child = b
    end
  end
  assert(child, "spawn did not create a child tagged with straps_parent")
  assert(vim.b[child].straps_parent == parent, "child parent bufnr wrong")
  assert(vim.b[child].straps_task == "do the thing",
    "task not normalized/stored: " .. tostring(vim.b[child].straps_task))
end)

-- ------------------------------------------------- presentation tools

it("show_buffer opens a filetype'd scratch split without stealing focus", function()
  vim.cmd("only")
  local wins_before = #vim.api.nvim_list_wins()
  local focus_before = vim.api.nvim_get_current_win()
  local out = drive(function(ctx)
    return registry.call("tool.show_buffer",
      { content = "# Report\n\nrow one\nrow two", filetype = "markdown", title = "findings" }, ctx)
  end, 5000)
  assert(out:find("show_buffer: opened 4 lines", 1, true), "summary wrong: " .. out)
  assert(out:find("markdown", 1, true) and out:find("findings", 1, true), "summary missing ft/title: " .. out)
  assert(#vim.api.nvim_list_wins() == wins_before + 1, "should have opened one split")
  assert(vim.api.nvim_get_current_win() == focus_before, "show_buffer stole focus")
  -- The scratch buffer exists with the right filetype and content.
  local found
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b):find("straps://buffer/findings", 1, true) then found = b end
  end
  assert(found, "named scratch buffer not created")
  assert(vim.bo[found].filetype == "markdown", "scratch filetype wrong")
  vim.cmd("only")
end)

it("show_buffer requires content", function()
  local out = drive(function(ctx)
    return registry.call("tool.show_buffer", { filetype = "lua" }, ctx)
  end, 5000)
  assert(out:find("content is required", 1, true), "expected a content-required error: " .. out)
end)

it("show_diff (arbitrary texts) opens a two-window diff and counts hunks", function()
  vim.cmd("only")
  local wins_before = #vim.api.nvim_list_wins()
  local out = drive(function(ctx)
    return registry.call("tool.show_diff",
      { left = "a\nb\nc\n", right = "a\nB\nc\n", filetype = "text",
        left_label = "old", right_label = "new" }, ctx)
  end, 5000)
  assert(out:find("opened a diff split", 1, true), "summary wrong: " .. out)
  assert(out:find("old vs new", 1, true), "labels missing: " .. out)
  -- Two windows are now in 'diff' mode.
  local diffwins = 0
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.wo[w].diff then diffwins = diffwins + 1 end
  end
  assert(diffwins >= 2, "expected two diff windows, got " .. diffwins)
  assert(#vim.api.nvim_list_wins() >= wins_before + 1, "diff should add at least one window")
  vim.cmd("windo diffoff")
  vim.cmd("only")
end)

it("show_diff reports identical versions", function()
  vim.cmd("only")
  local out = drive(function(ctx)
    return registry.call("tool.show_diff", { left = "same\n", right = "same\n" }, ctx)
  end, 5000)
  assert(out:find("identical", 1, true), "expected identical note: " .. out)
  vim.cmd("windo diffoff")
  vim.cmd("only")
end)

it("show_diff without a valid mode returns a usage hint", function()
  local out = drive(function(ctx)
    return registry.call("tool.show_diff", { filetype = "lua" }, ctx)
  end, 5000)
  assert(out:find("pass {path, content} or {left, right}", 1, true), "usage hint missing: " .. out)
end)

it("set_findings loads locations and opens the findings list", function()
  vim.cmd("only")
  vim.fn.setqflist({}, "f")
  local out = drive(function(ctx)
    return registry.call("tool.set_findings", {
      items = {
        { path = root .. "/lua/straps/loop.lua", line = 10, col = 2, text = "here" },
        { path = root .. "/README.md", line = 1, text = "there" },
        { bogus = true }, -- no path: skipped
      },
      title = "straps: my findings",
    }, ctx)
  end, 5000)
  local qf = vim.fn.getqflist()
  assert(#qf == 2, "expected 2 valid entries, got " .. #qf .. " — " .. out)
  assert(qf[1].lnum == 10 and qf[1].col == 2, "first entry position wrong")
  assert(out:find("loaded 2 entries", 1, true), "summary wrong: " .. out)
  local title = vim.fn.getqflist({ title = 1 }).title
  assert(title == "straps: my findings", "title not set: " .. tostring(title))
  vim.cmd("cclose")
  vim.cmd("only")
end)

it("set_findings with no valid items reports it", function()
  local out = drive(function(ctx)
    return registry.call("tool.set_findings", { items = { { nope = 1 } } }, ctx)
  end, 5000)
  assert(out:find("no valid items", 1, true), "expected no-valid-items note: " .. out)
end)

it("hook.confirm auto-allows the presentation tools", function()
  for _, n in ipairs({ "show_diff", "show_buffer", "set_findings" }) do
    local allowed = registry.call("hook.confirm", n, {}, { bufnr = 0 })
    assert(allowed == true, n .. " should be auto-allowed (read-only view)")
  end
end)

it(":StrapsHelp command opens a straps help tag", function()
  vim.g.loaded_straps = nil
  vim.cmd("source " .. vim.fn.fnameescape(root .. "/plugin/straps.lua"))
  vim.cmd("silent! helptags " .. vim.fn.fnameescape(root .. "/doc"))
  vim.cmd("StrapsHelp straps-tools")
  assert(vim.bo.filetype == "help", "StrapsHelp should open a help buffer")
  assert(vim.api.nvim_buf_get_name(0):find("straps.txt", 1, true),
    "StrapsHelp did not open straps.txt")
  vim.cmd("quit")
end)
