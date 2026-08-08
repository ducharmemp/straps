-- tests/run_agents_buffer.lua — the agents buffer (straps://agents): a single
-- ordinary buffer listing ALL sessions (running / loaded / saved) with a tiny
-- keymap grammar. Covers all_sessions() classification, fn.agents_render (a
-- redefinable registry fn), the module-table line map, the <CR>/x/i/r keymaps,
-- the two refresh seams (loop.progress + BufEnter) and the debounce.
--   nvim --headless -l tests/run_agents_buffer.lua
-- No network: fn.provider is redefined with scripted stubs. Plain asserts.

local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(vim.fn.fnamemodify(here, ":p"), ":h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

-- setup() is REQUIRED: fn.agents_render is registered in ui.setup().
local straps = require("straps").setup({})
straps.config.session_dir = vim.fn.tempname() -- hermetic: never the real data dir
require("straps.provider").register() -- fn.provider default (overridden below)

local ui = require("straps.ui")
local state = require("straps.state")
local loop = require("straps.loop")
local registry = require("straps.registry")

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

local function define(name, kind, doc, source)
  registry.define({ name = name, kind = kind, doc = doc, source = source })
end

-- Allow every confirm-gated call (loop start/stop paths never prompt in tests).
define("hook.confirm", "hook", "test: allow everything", "return function() return true end")

-- A provider that parks in ctx.await until cancelled — a genuinely RUNNING
-- session that never finishes on its own, so loop.running(bufnr) stays true.
local function define_parked_provider()
  define("fn.provider", "fn", "test: parks until cancelled", [==[
return function(req, ctx)
  ctx.await(function(resolve)
    ctx.on_cancel(function() resolve("killed") end)
    vim.defer_fn(function() resolve("timeout") end, 60000)
  end)
  if ctx.cancelled() then
    return { content = {}, stop_reason = "cancelled" }
  end
  return { stop_reason = "end_turn", content = { { type = "text", text = "done" } } }
end
]==])
end

-- Find the straps://agents buffer by exact name (the tool's own rule).
local function agents_buf()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b)
      and vim.api.nvim_buf_get_name(b) == "straps://agents" then
      return b
    end
  end
end

local function lines_of(bufnr)
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

local function has_line(bufnr, needle)
  for _, l in ipairs(lines_of(bufnr)) do
    if l:find(needle, 1, true) then return true end
  end
  return false
end

local function line_index(bufnr, needle)
  for i, l in ipairs(lines_of(bufnr)) do
    if l:find(needle, 1, true) then return i end
  end
end

-- ── Case 9 FIRST: zero sessions, before any session buffer exists ──────────
case("zero sessions renders the empty-state line", function()
  local buf = ui.open_agents("")
  assert(buf, "open_agents returned no buffer")
  assert(has_line(buf, "no agent sessions"), "missing empty-state line")
  assert(has_line(buf, "<CR> open"), "missing footer line")
  assert(vim.bo[buf].modifiable == false, "buffer left modifiable")
  -- Counterfactual: the empty-state text is what we assert on.
  local snap = table.concat(lines_of(buf), "\n")
  assert(snap:find("no agent sessions", 1, true), "empty-state assertion subject absent")
  -- Close it so later cases open a fresh one against real sessions.
  vim.cmd("bwipeout! " .. buf)
end)

-- Build the three kinds of session used across the rest of the suite.
-- saved: a file-backed transcript with a user block, then buffer wiped.
local saved_path
do
  local b = state.new_session()
  state.append(b, "user", nil, "a saved conversation prompt")
  saved_path = vim.api.nvim_buf_get_name(b)
  vim.cmd("bwipeout! " .. b)
end
-- loaded: a file-backed session buffer kept loaded, no run.
local loaded_buf = state.new_session()
-- running: a parked provider session.
define_parked_provider()
local running_buf = state.new_session()
state.append_text(running_buf, "keep running")
loop.start(running_buf)
assert(vim.wait(2000, function() return loop.running(running_buf) end, 10),
  "running session never started")

case("all_sessions classifies each session into exactly one set", function()
  local sets = ui.all_sessions()
  local function in_running(bn)
    for _, a in ipairs(sets.running) do if a.bufnr == bn then return true end end
    return false
  end
  local function in_loaded(bn)
    for _, l in ipairs(sets.loaded) do if l.bufnr == bn then return true end end
    return false
  end
  local function in_saved(p)
    local abs = vim.fn.fnamemodify(p, ":p")
    for _, s in ipairs(sets.saved) do
      if vim.fn.fnamemodify(s.path, ":p") == abs then return true end
    end
    return false
  end

  assert(in_running(running_buf), "running session not in .running")
  assert(not in_loaded(running_buf), "running session also in .loaded")

  assert(in_loaded(loaded_buf), "loaded session not in .loaded")
  assert(not in_running(loaded_buf), "loaded session also in .running")

  assert(in_saved(saved_path), "saved transcript not in .saved")
  -- Counterfactual: the saved path must NOT appear once a buffer loads it.
  -- (Membership-by-path is the assertion subject; verify exclusivity.)
  local loaded_names = {}
  for _, l in ipairs(sets.loaded) do
    loaded_names[vim.fn.fnamemodify(vim.api.nvim_buf_get_name(l.bufnr), ":p")] = true
  end
  assert(not loaded_names[vim.fn.fnamemodify(saved_path, ":p")],
    "saved path collided with a loaded buffer")
end)

case("render shows sections in order, omits empty, footer present, map resolves", function()
  local buf = ui.open_agents("")
  local ls = lines_of(buf)
  local ri = line_index(buf, "━━ running")
  local li = line_index(buf, "━━ loaded")
  local si = line_index(buf, "━━ saved")
  assert(ri and li and si, "a section header is missing")
  assert(ri < li and li < si, "sections out of running/loaded/saved order")
  assert(vim.bo[buf].modifiable == false, "buffer left modifiable")
  assert(ls[#ls]:find("<CR> open", 1, true), "footer not last line")

  -- The line map resolves a known saved row to the right entry.
  local abs = vim.fn.fnamemodify(saved_path, ":p")
  local resolved
  for lnum = si + 1, #ls do
    local e = ui._agents_line(buf, lnum)
    if e and e.kind == "saved" and vim.fn.fnamemodify(e.path, ":p") == abs then
      resolved = e
      break
    end
  end
  assert(resolved, "line map did not resolve the saved row to its path")

  -- And a running row resolves to the running bufnr.
  local run_resolved
  for lnum = ri + 1, li - 1 do
    local e = ui._agents_line(buf, lnum)
    if e and e.kind == "running" and e.bufnr == running_buf then
      run_resolved = e
      break
    end
  end
  assert(run_resolved, "line map did not resolve the running row to its bufnr")
end)

case("render is idempotent: two renders, identical lines and extmark count", function()
  local buf = ui.open_agents("")
  local ns = vim.api.nvim_create_namespace("straps_agents")
  registry.try_call("fn.agents_render", buf)
  local lines1 = table.concat(lines_of(buf), "\n")
  local marks1 = #vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})
  registry.try_call("fn.agents_render", buf)
  local lines2 = table.concat(lines_of(buf), "\n")
  local marks2 = #vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})
  assert(lines1 == lines2, "two renders produced different lines")
  assert(marks1 == marks2, "two renders produced different extmark counts ("
    .. marks1 .. " vs " .. marks2 .. ")")
  assert(marks1 > 0, "no extmarks drawn")
end)

case("<CR> on a saved row resumes it; on a loaded row shows it", function()
  local buf = ui.open_agents("")
  -- Put cursor on the saved row and fire <CR>.
  local abs = vim.fn.fnamemodify(saved_path, ":p")
  local ls = lines_of(buf)
  local si = line_index(buf, "━━ saved")
  local saved_lnum
  for lnum = si + 1, #ls do
    local e = ui._agents_line(buf, lnum)
    if e and e.kind == "saved" and vim.fn.fnamemodify(e.path, ":p") == abs then
      saved_lnum = lnum
      break
    end
  end
  assert(saved_lnum, "no saved row to test <CR>")

  -- Drive the handler with the cursor set, as the real keymap does.
  vim.api.nvim_win_set_cursor(0, { saved_lnum, 0 })
  -- Ensure the agents buffer is the current window/buffer for the handler.
  ui._agents_key(buf, "cr")

  -- A straps_session buffer for that path now exists and is displayed.
  local shown
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local b = vim.api.nvim_win_get_buf(w)
    if vim.fn.fnamemodify(vim.api.nvim_buf_get_name(b), ":p") == abs
      and vim.b[b].straps_session == true then
      shown = b
      break
    end
  end
  assert(shown, "saved <CR> did not open+display a session buffer for the path")

  -- Loaded row: show_session brings it on screen.
  local buf2 = ui.open_agents("")
  local li = line_index(buf2, "━━ loaded")
  local ls2 = lines_of(buf2)
  local loaded_lnum
  for lnum = li + 1, #ls2 do
    local e = ui._agents_line(buf2, lnum)
    if e and e.kind == "loaded" and e.bufnr == loaded_buf then
      loaded_lnum = lnum
      break
    end
  end
  assert(loaded_lnum, "no loaded row to test <CR>")
  vim.api.nvim_win_set_cursor(0, { loaded_lnum, 0 })
  ui._agents_key(buf2, "cr")
  local loaded_shown = false
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(w) == loaded_buf then loaded_shown = true end
  end
  assert(loaded_shown, "loaded <CR> did not display the session buffer")
end)

case("cr on a stale loaded row notifies and re-renders", function()
  -- A fresh loaded session, distinct from loaded_buf used by earlier cases.
  local session_buf = state.new_session()
  local buf = ui.open_agents("")

  -- Find the loaded row that resolves to this session buffer.
  local loaded_lnum
  for l = 1, vim.api.nvim_buf_line_count(buf) do
    local e = ui._agents_line(buf, l)
    if e and e.kind == "loaded" and e.bufnr == session_buf then
      loaded_lnum = l
      break
    end
  end
  assert(loaded_lnum, "no loaded row resolving to the new session buffer")

  vim.api.nvim_win_set_cursor(0, { loaded_lnum, 0 })

  -- Make the row stale WITHOUT re-rendering: the buffer is gone, the map isn't.
  vim.cmd("bwipeout! " .. session_buf)

  local msgs = {}
  local orig = vim.notify
  vim.notify = function(m) msgs[#msgs + 1] = tostring(m) end
  local ok = pcall(function()
    require("straps.ui")._agents_key(buf, "cr")
  end)
  vim.notify = orig

  assert(ok, "cr on a stale loaded row raised an error")
  local saw_gone = false
  for _, m in ipairs(msgs) do
    if m:find("gone", 1, true) then saw_gone = true end
  end
  assert(saw_gone, "cr on a stale loaded row did not notify about the gone buffer")

  -- The re-render rebuilt the map: no row resolves to the wiped bufnr.
  for l = 1, vim.api.nvim_buf_line_count(buf) do
    local e = ui._agents_line(buf, l)
    assert(not (e and e.bufnr == session_buf),
      "rebuilt map still resolves a row to the wiped bufnr")
  end
end)

case("x on the running row stops it", function()
  local buf = ui.open_agents("")
  local ri = line_index(buf, "━━ running")
  local li = line_index(buf, "━━ loaded")
  local run_lnum
  for lnum = ri + 1, (li or (#lines_of(buf) + 1)) - 1 do
    local e = ui._agents_line(buf, lnum)
    if e and e.kind == "running" and e.bufnr == running_buf then
      run_lnum = lnum
      break
    end
  end
  assert(run_lnum, "no running row to test x")
  assert(loop.running(running_buf), "precondition: run should still be active")
  vim.api.nvim_win_set_cursor(0, { run_lnum, 0 })
  ui._agents_key(buf, "x")
  assert(vim.wait(2000, function() return not loop.running(running_buf) end, 10),
    "x did not stop the running session")
end)

case("x and i on a non-running row notify without error", function()
  local buf = ui.open_agents("")
  -- Capture notifications.
  local notified = 0
  local orig = vim.notify
  vim.notify = function() notified = notified + 1 end
  local ok = pcall(function()
    -- Cursor on the footer line (no entry) — a non-running position.
    local ls = lines_of(buf)
    vim.api.nvim_win_set_cursor(0, { #ls, 0 })
    ui._agents_key(buf, "x")
    ui._agents_key(buf, "i")
  end)
  vim.notify = orig
  assert(ok, "x/i on a non-running row raised an error")
  assert(notified >= 2, "x/i on a non-running row did not notify (got " .. notified .. ")")
end)

case("refresh debounces back-to-back calls into one render", function()
  local buf = ui.open_agents("")
  _G.straps_agents_render_count = 0
  -- Wrap fn.agents_render with a counter that still calls the real renderer.
  define("fn.agents_render", "fn",
    "test: counting wrapper around the agents renderer", [==[
return function(bufnr)
  _G.straps_agents_render_count = (_G.straps_agents_render_count or 0) + 1
  return require("straps.ui")._agents_render(bufnr)
end
]==])
  local before = _G.straps_agents_render_count
  ui.agents_refresh()
  ui.agents_refresh()
  -- Debounce window is ~100ms; wait past it.
  vim.wait(400, function() return _G.straps_agents_render_count > before end, 10)
  assert(_G.straps_agents_render_count == before + 1,
    "two refreshes should coalesce to one render, got "
    .. (_G.straps_agents_render_count - before))
end)

case("loop progress seam refreshes the open agents buffer", function()
  local buf = ui.open_agents("")
  -- The counting wrapper from the previous case is still installed.
  local before = _G.straps_agents_render_count
  -- A scripted 1-turn session: emits text then ends, generating progress events.
  define("fn.provider", "fn", "test: one-turn text", [==[
return function(req, ctx)
  ctx.await(function(resolve) vim.defer_fn(resolve, 5) end)
  return { stop_reason = "end_turn", content = { { type = "text", text = "hi" } } }
end
]==])
  local b = state.new_session()
  state.append_text(b, "say hi")
  loop.start(b)
  assert(vim.wait(3000, function() return not loop.running(b) end, 10),
    "one-turn session did not finish")
  -- Let the trailing debounce fire.
  vim.wait(400, function() return _G.straps_agents_render_count > before end, 10)
  assert(_G.straps_agents_render_count > before,
    "progress events did not trigger an agents-buffer render")
end)

case("rows are capped to one legible line", function()
  -- A saved transcript whose first user block is ~2000 chars.
  local b = state.new_session()
  local long_prompt = string.rep("legibility ", 200)
  state.append(b, "user", nil, long_prompt)
  local long_path = vim.api.nvim_buf_get_name(b)
  vim.cmd("bwipeout! " .. b)

  local buf = ui.open_agents("")
  local abs = vim.fn.fnamemodify(long_path, ":p")
  local row_line
  for lnum = 1, vim.api.nvim_buf_line_count(buf) do
    local e = ui._agents_line(buf, lnum)
    if e and e.kind == "saved" and vim.fn.fnamemodify(e.path, ":p") == abs then
      row_line = lines_of(buf)[lnum]
      break
    end
  end
  assert(row_line, "no saved row found for the long-prompt transcript")
  assert(vim.fn.strdisplaywidth(row_line) <= 76,
    "capped row exceeds 76 cells: " .. vim.fn.strdisplaywidth(row_line))
  assert(row_line:find("…", 1, true), "capped row missing the truncation ellipsis")
  assert(row_line:match("just now$") or row_line:match("ago$"),
    "capped row does not end with the age tail: " .. row_line)
end)

case("agents window gets list options and cursor on a row", function()
  local buf = ui.open_agents("")
  local w = vim.api.nvim_get_current_win()
  assert(vim.wo[w].wrap == false, "window wrap should be false")
  assert(vim.wo[w].cursorline == true, "window cursorline should be true")
  local cursor_lnum = vim.api.nvim_win_get_cursor(w)[1]
  assert(ui._agents_line(buf, cursor_lnum) ~= nil,
    "cursor did not land on a row resolving through the line map")
end)

if failed then
  os.exit(1)
end
print("all agents-buffer tests passed")
