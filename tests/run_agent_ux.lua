-- tests/run_agent_ux.lua — the agent/editor coupling additions.
--   nvim --headless -l tests/run_agent_ux.lua
-- No network, no real LSP server. Covers: registration + schema of the new
-- editor tools (hover, workspace_symbols, rename_symbol, code_action, format,
-- context, show_user, help_search) and run_in_terminal; the graceful "no LSP
-- client" fallbacks; context reporting windows/cursor/selection; show_user
-- moving the user's view; help_search excerpting :help; run_in_terminal
-- round-tripping output through a real :terminal split; hook.confirm's new
-- auto-allows, code_action list-vs-apply gating, and the diff-preview split
-- being cleaned up after the dialog; fn.autocmd_bridge queueing a hook's
-- string return onto a session buffer.

local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(vim.fn.fnamemodify(here, ":p"), ":h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local failed = false
local function case(name, fn)
  local ok, err = pcall(fn)
  if ok then
    print("PASS  " .. name)
  else
    failed = true
    print("FAIL  " .. name .. ": " .. tostring(err))
  end
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

case("new tools registered with schemas; autocmd_bridge registered as fn", function()
  for _, n in ipairs({ "hover", "workspace_symbols", "rename_symbol", "code_action",
    "format", "context", "show_user", "help_search", "run_in_terminal" }) do
    local e = registry.get("tool." .. n)
    assert(e, "tool." .. n .. " not registered")
    assert(e.kind == "tool", "tool." .. n .. " wrong kind")
    assert(type(e.input_schema) == "table", "tool." .. n .. " missing input_schema")
  end
  local b = registry.get("fn.autocmd_bridge")
  assert(b and b.kind == "fn", "fn.autocmd_bridge not registered as fn")
end)

case("every tool schema JSON-encodes with object-shaped properties", function()
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

case("LSP tools degrade to clear messages with no client attached", function()
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

case("help_search finds tags and excerpts the best match's section", function()
  local out = registry.call("tool.help_search", { query = "quickfix" }, { bufnr = 0 })
  assert(out:find("matching tags:", 1, true), "tag list missing:\n" .. out:sub(1, 200))
  assert(out:find("quickfix", 1, true), "no quickfix tag matched")
  assert(out:find("-- :help ", 1, true), "excerpt header missing:\n" .. out:sub(1, 200))
end)

case("help_search reports no matches for nonsense", function()
  local out = registry.call("tool.help_search",
    { query = "straps-definitely-not-a-real-tag" }, { bufnr = 0 })
  assert(out:find("no help tags match", 1, true), "unexpected: " .. out:sub(1, 120))
end)

-- --------------------------------------------------------------------- context

case("context reports the focused window, cursor and visual selection", function()
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

case("context flags unsaved buffers", function()
  vim.api.nvim_buf_set_lines(0, 0, 1, false, { "line one EDITED" })
  local out = registry.call("tool.context", {}, { bufnr = 0 })
  assert(out:find("unsaved changes", 1, true), "unsaved flag missing:\n" .. out)
  assert(out:find("unsaved buffers: ", 1, true), "unsaved list missing:\n" .. out)
  vim.cmd("silent! write") -- clean up for later cases
end)

-- ------------------------------------------------------------------- show_user

case("show_user moves the user's view to path:line and reports it", function()
  local path = vim.fn.tempname() .. ".txt"
  write_file(path, "alpha\nbeta\ngamma\ndelta\n")
  local out = registry.call("tool.show_user", { path = path, line = 3 }, { bufnr = 0 })
  assert(out:find("showing", 1, true) and out:find(":3", 1, true),
    "unexpected result: " .. out)
  local cur = vim.api.nvim_get_current_buf()
  assert(vim.api.nvim_buf_get_name(cur) == vim.fn.fnamemodify(path, ":p"),
    "current window does not show the file")
  local pos = vim.api.nvim_win_get_cursor(0)
  assert(pos[1] == 3, "cursor should be on line 3, got " .. pos[1])
end)

case("show_user on a missing file returns an error string", function()
  local out = registry.call("tool.show_user",
    { path = vim.fn.tempname() .. "/nope.txt" }, { bufnr = 0 })
  assert(out:find("no such file", 1, true), "unexpected: " .. out)
end)

-- ------------------------------------------------------------- run_in_terminal

case("run_in_terminal streams through a real terminal split and returns output", function()
  local wins_before = #vim.api.nvim_list_wins()
  local out = drive(function(ctx)
    return registry.call("tool.run_in_terminal",
      { command = "echo STRAPS-TERM-OK && exit 0" }, ctx)
  end, 15000)
  assert(out:find("exit code: 0", 1, true), "exit code missing:\n" .. out:sub(1, 200))
  assert(out:find("STRAPS-TERM-OK", 1, true), "output missing:\n" .. out:sub(1, 400))
  assert(out:find("terminal split left open", 1, true), "left-open note missing")
  assert(#vim.api.nvim_list_wins() == wins_before + 1,
    "terminal split should still be open")
  vim.cmd("only") -- normalize windows for later cases
end)

case("run_in_terminal reports a nonzero exit code", function()
  local out = drive(function(ctx)
    return registry.call("tool.run_in_terminal", { command = "exit 3" }, ctx)
  end, 15000)
  assert(out:find("exit code: 3", 1, true), "expected exit code 3:\n" .. out:sub(1, 200))
  vim.cmd("only")
end)

case("run_in_terminal stops a job that exceeds timeout_ms", function()
  local t0 = vim.uv.hrtime()
  local out = drive(function(ctx)
    return registry.call("tool.run_in_terminal",
      { command = "sleep 30", timeout_ms = 400 }, ctx)
  end, 15000)
  local ms = (vim.uv.hrtime() - t0) / 1e6
  assert(out:find("stopped: exceeded timeout of 400 ms", 1, true),
    "timeout note missing:\n" .. out:sub(1, 200))
  assert(ms < 5000, "timeout did not stop the job promptly: " .. math.floor(ms) .. "ms")
  vim.cmd("only")
end)

case("run_in_terminal is killed by cancellation", function()
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

-- ---------------------------------------------------------------- hook.confirm

case("new read-only tools are auto-allowed; code_action gates on index", function()
  for _, n in ipairs({ "hover", "workspace_symbols", "context", "show_user", "help_search" }) do
    assert(registry.call("hook.confirm", n, {}, { bufnr = 0 }) == true,
      n .. " should be auto-allowed")
  end
  assert(registry.call("hook.confirm", "code_action",
    { path = "x", line = 1, col = 1 }, { bufnr = 0 }) == true,
    "code_action without index (list mode) should be auto-allowed")
  -- Applying (index set) must fall through to the prompt; headless confirm
  -- returns 0 -> denied.
  local allowed = registry.call("hook.confirm", "code_action",
    { path = "x", line = 1, col = 1, index = 1 }, { bufnr = 0 })
  assert(allowed ~= true, "code_action with index must not be auto-allowed")
  for _, n in ipairs({ "rename_symbol", "format", "run_in_terminal" }) do
    assert(registry.call("hook.confirm", n, {}, { bufnr = 0 }) ~= true,
      n .. " must not be auto-allowed")
  end
end)

case("confirm shows a diff preview for edit_file and cleans up the split", function()
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

case("ask_user routes options through vim.ui.select and shows content alongside", function()
  local seen = { items = nil, prompt = nil, content_visible = false, wins = 0 }
  local wins_before = #vim.api.nvim_list_wins()
  local real_select = vim.ui.select
  vim.ui.select = function(items, opts, on_choice)
    seen.items = items
    seen.prompt = opts and opts.prompt
    seen.wins = #vim.api.nvim_list_wins()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local b = vim.api.nvim_win_get_buf(win)
      local text = table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
      if text:find("PROPOSED-CONTENT", 1, true) then seen.content_visible = true end
    end
    on_choice(items[2], 2)
  end
  local ok, out = pcall(drive, function(ctx)
    return registry.call("tool.ask_user", {
      question = "Which approach?",
      options = { "Approach A", "Approach B" },
      content = "PROPOSED-CONTENT line\nmore",
    }, ctx)
  end)
  vim.ui.select = real_select
  assert(ok, "ask_user errored: " .. tostring(out))

  assert(out:find("user chose option 2: Approach B", 1, true), "unexpected: " .. out)
  assert(seen.prompt == "Which approach?", "question not used as prompt: " .. tostring(seen.prompt))
  assert(#seen.items == 3 and seen.items[3]:find("other", 1, true),
    "an 'other' entry should be appended: " .. vim.inspect(seen.items))
  assert(seen.content_visible, "content split not visible while the picker was up")
  assert(seen.wins == wins_before + 1, "content split window missing at pick time")
  assert(#vim.api.nvim_list_wins() == wins_before,
    "content split leaked after answering")
end)

case("ask_user 'other' choice falls through to free-text input", function()
  local real_select, real_input = vim.ui.select, vim.ui.input
  vim.ui.select = function(items, _, on_choice) on_choice(items[#items], #items) end
  vim.ui.input = function(_, on_confirm) on_confirm("my custom answer") end
  local ok, out = pcall(drive, function(ctx)
    return registry.call("tool.ask_user",
      { question = "Name?", options = { "foo", "bar" } }, ctx)
  end)
  vim.ui.select, vim.ui.input = real_select, real_input
  assert(ok, "ask_user errored: " .. tostring(out))
  assert(out:find("free text", 1, true) and out:find("my custom answer", 1, true),
    "unexpected: " .. out)
end)

case("ask_user without options is a free-text prompt; dismissal is reported", function()
  local real_input = vim.ui.input
  vim.ui.input = function(_, on_confirm) on_confirm("just typing") end
  local ok, out = pcall(drive, function(ctx)
    return registry.call("tool.ask_user", { question = "Anything?" }, ctx)
  end)
  vim.ui.input = real_input
  assert(ok, "ask_user errored: " .. tostring(out))
  assert(out:find("user answered: just typing", 1, true), "unexpected: " .. out)

  local real_select = vim.ui.select
  vim.ui.select = function(_, _, on_choice) on_choice(nil, nil) end
  ok, out = pcall(drive, function(ctx)
    return registry.call("tool.ask_user",
      { question = "Pick?", options = { "a", "b" } }, ctx)
  end)
  vim.ui.select = real_select
  assert(ok, "ask_user errored: " .. tostring(out))
  assert(out:find("dismissed the picker", 1, true), "unexpected: " .. out)
end)

case("ask_user is auto-allowed by hook.confirm", function()
  assert(registry.call("hook.confirm", "ask_user", { question = "?" }, { bufnr = 0 }) == true,
    "ask_user should be auto-allowed — it IS the user interaction")
end)

-- ------------------------------------------------------------------- undo_edit

case("undo_edit lists history, surgically reverts an edit, and redoes via to_seq", function()
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

case("undo_edit reports cleanly when there is nothing to undo", function()
  local path = vim.fn.tempname() .. ".txt"
  write_file(path, "pristine\n")
  local out = registry.call("tool.undo_edit", { path = path }, { bufnr = 0 })
  assert(out:find("nothing changed", 1, true), "unexpected: " .. out)
end)

case("revert_seq surgically reverts one edit while keeping later edits", function()
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

case("revert_seq refuses with a conflict when later edits overlap", function()
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

case("revert_seq refuses when the buffer has unsaved changes", function()
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

case("undo_edit reverts a PREVIOUS session's edit via 'undofile' persistence", function()
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

case("revert_seq handles a multi-hunk edit with a later edit interleaved", function()
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

case("undo_edit history is auto-allowed; an actual undo prompts", function()
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

case("'Always in <dir>' grants the parent directory, not neighbors with the same prefix", function()
  local base = vim.fn.tempname()
  vim.fn.mkdir(base .. "/aa", "p")
  vim.fn.mkdir(base .. "/aab", "p")
  local cbuf = vim.api.nvim_create_buf(true, false)
  local prompts = 0
  local real_confirm = vim.fn.confirm
  vim.fn.confirm = function() prompts = prompts + 1; return 3 end -- Always in <dir>

  -- First edit under /aa: prompts once, grant recorded.
  local allowed = registry.call("hook.confirm", "edit_file",
    { path = base .. "/aa/one.txt", old_string = "x", new_string = "y" }, { bufnr = cbuf })
  assert(allowed == true, "choice 3 should allow")
  assert(prompts == 1, "expected exactly one prompt, got " .. prompts)
  local set = vim.b[cbuf].straps_allowed
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

case("'Always all edits' grants every path for edit tools only", function()
  local cbuf = vim.api.nvim_create_buf(true, false)
  local real_confirm = vim.fn.confirm
  vim.fn.confirm = function() return 4 end -- Always all edits
  local allowed = registry.call("hook.confirm", "write_file",
    { path = vim.fn.tempname() .. "/a.txt", content = "c" }, { bufnr = cbuf })
  assert(allowed == true, "choice 4 should allow")
  assert(vim.b[cbuf].straps_allowed["editfiles:*"], "editfiles:* grant missing")

  vim.fn.confirm = function() return 0 end
  allowed = registry.call("hook.confirm", "edit_file",
    { path = "/anywhere/else.txt", old_string = "x", new_string = "y" }, { bufnr = cbuf })
  assert(allowed == true, "editfiles:* should cover any path")
  allowed = registry.call("hook.confirm", "run_in_terminal",
    { command = "echo hi" }, { bufnr = cbuf })
  assert(allowed ~= true, "editfiles:* leaked to a non-edit tool")
  vim.fn.confirm = real_confirm
end)

-- -------------------------------------------------------------- autocmd_bridge

case("autocmd_bridge queues a hook's string onto the session buffer", function()
  local session = state.new_session()
  registry.define({
    name = "hook.bridge_test",
    kind = "hook",
    doc = "test bridge hook",
    source = [[return function(args) return "BRIDGE-MSG-42 (" .. tostring(args.event) .. ")" end]],
  })
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

print(failed and "FAILED" or "ALL PASS")
os.exit(failed and 1 or 0)
