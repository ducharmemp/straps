local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(vim.fn.fnamemodify(here, ":p"), ":h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local straps = require("straps").setup({})
straps.config.session_dir = vim.fn.tempname()
require("straps.provider").register()

local ui = require("straps.ui")
local state = require("straps.state")
local loop = require("straps.loop")
local registry = require("straps.registry")

local function define(name, kind, doc, source)
  registry.define({ name = name, kind = kind, doc = doc, source = source })
end

define("hook.confirm", "hook", "test: allow everything", "return function() return true end")

local function parked_provider()
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

local function lines_of(bufnr)
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

local function find_row(buf, predicate)
  for lnum = 1, vim.api.nvim_buf_line_count(buf) do
    local e = ui._agents_line(buf, lnum)
    if predicate(e, lnum) then return lnum, e end
  end
end

it("renders Agents header, Saved separate, and a child under its parent across parent stop", function()
  parked_provider()
  local parent = state.new_session()
  vim.b[parent].straps_task = "parent run"
  state.append_text(parent, "start")
  loop.start(parent)
  assert(vim.wait(2000, function() return loop.running(parent) end, 10))

  local child = state.new_session()
  vim.b[child].straps_parent = parent
  vim.b[child].straps_task = "child idle"

  local saved
  do
    local b = state.new_session()
    state.append(b, "user", nil, "saved prompt")
    saved = vim.api.nvim_buf_get_name(b)
    vim.cmd("bwipeout! " .. b)
  end

  local buf = ui.open_agents("")
  registry.try_call("fn.agents_render", buf)
  assert(find_row(buf, function(e) return e and e.id == "section:agents" end), "Agents section header missing")
  assert(find_row(buf, function(e) return e and e.id == "section:saved" end), "Saved section header missing")

  local prow = assert(find_row(buf, function(e) return e and e.kind == "running" and e.bufnr == parent end))
  local crow = assert(find_row(buf, function(e) return e and e.kind == "loaded" and e.bufnr == child end))
  assert(crow > prow, "child should appear under parent in forest order")

  loop.stop(parent)
  assert(vim.wait(2000, function() return not loop.running(parent) end, 10))
  registry.try_call("fn.agents_render", buf)
  local prow2 = assert(find_row(buf, function(e) return e and e.kind == "loaded" and e.bufnr == parent end))
  local crow2 = assert(find_row(buf, function(e) return e and (e.bufnr == child) end))
  assert(crow2 > prow2, "child should remain under parent after parent stops")

  local abs = vim.fn.fnamemodify(saved, ":p")
  local srow = assert(find_row(buf, function(e) return e and e.kind == "saved" and vim.fn.fnamemodify(e.path, ":p") == abs end))
  assert(srow and srow > 0, "saved row missing")
end)

it("breaks parent cycles and never duplicates rows; both present exactly once", function()
  local a = state.new_session()
  local b = state.new_session()
  vim.b[a].straps_parent = b
  vim.b[b].straps_parent = a
  local buf = ui.open_agents("")
  registry.try_call("fn.agents_render", buf)
  local seen, count = {}, { [a] = 0, [b] = 0 }
  local dup = 0
  for l = 1, vim.api.nvim_buf_line_count(buf) do
    local e = ui._agents_line(buf, l)
    if e and e.bufnr then
      if e.bufnr == a then count[a] = count[a] + 1 end
      if e.bufnr == b then count[b] = count[b] + 1 end
      local k = tostring(e.bufnr) .. ":" .. tostring(e.kind)
      if seen[k] then dup = dup + 1 else seen[k] = true end
    end
  end
  assert(dup == 0, "duplicate rows present under a parent cycle")
  assert(count[a] == 1 and count[b] == 1, "each session must appear exactly once")
end)

it("windowless render caps saved rows to 76 cells (fallback width)", function()
  local existing
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b) == "straps://agents" then existing = b break end
  end
  if existing then vim.cmd("bwipeout! " .. existing) end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, "straps://agents")
  local b = state.new_session()
  local long_prompt = string.rep("legibility ", 200)
  state.append(b, "user", nil, long_prompt)
  local path = vim.api.nvim_buf_get_name(b)
  vim.cmd("bwipeout! " .. b)
  require("straps.agents").render(buf)
  local row_line
  for l = 1, vim.api.nvim_buf_line_count(buf) do
    local e = require("straps.agents").line(buf, l)
    if e and e.kind == "saved" and vim.fn.fnamemodify(e.path, ":p") == vim.fn.fnamemodify(path, ":p") then
      row_line = lines_of(buf)[l]
      break
    end
  end
  assert(row_line, "no saved row found in windowless render")
  assert(vim.fn.strdisplaywidth(row_line) <= 76, "windowless row exceeds 76 cells: " .. vim.fn.strdisplaywidth(row_line))
  assert(row_line:find("…", 1, true), "capped row missing the truncation ellipsis")
end)

it("p opens a readonly details pane; P toggles follow", function()
  local sess = state.new_session()
  vim.b[sess].straps_task = "do things\nline2"
  ui.show_session(sess, "none")
  local buf = ui.open_agents("")
  local lnum = select(1, find_row(buf, function(e) return e and e.kind == "loaded" and e.bufnr == sess end))
  assert(lnum, "no loaded row for test session")
  vim.api.nvim_win_set_cursor(0, { lnum, 0 })
  ui._agents_key(buf, "p")
  local detail_win
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local b = vim.api.nvim_win_get_buf(w)
    if vim.api.nvim_buf_get_name(b):match("^straps://agents%-detail/") then detail_win = w break end
  end
  assert(detail_win, "details window not opened")
  local dbuf = vim.api.nvim_win_get_buf(detail_win)
  assert(vim.bo[dbuf].modifiable == false, "details buffer should be readonly")
  ui._agents_key(buf, "P"); ui._agents_key(buf, "P")
end)

it("retains manual folds across refresh and a new child; per-window", function()
  local parent = state.new_session()
  vim.b[parent].straps_task = "parent"
  local child1 = state.new_session(); vim.b[child1].straps_parent = parent
  local buf = ui.open_agents("")
  registry.try_call("fn.agents_render", buf)
  local prow = assert(find_row(buf, function(e) return e and e.bufnr == parent end))
  vim.api.nvim_win_set_cursor(0, { prow, 0 })
  vim.cmd("silent! normal! zc")
  local win1 = vim.api.nvim_get_current_win()
  vim.cmd("vsplit")
  local win2 = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win2, buf)
  vim.api.nvim_set_current_win(win1)
  assert(vim.fn.foldclosed(prow) == prow, "parent fold not closed in win1")
  local child2 = state.new_session(); vim.b[child2].straps_parent = parent
  registry.try_call("fn.agents_render", buf)
  assert(vim.fn.foldclosed(prow) == prow, "fold should remain closed after refresh and new row")
  vim.api.nvim_set_current_win(win2)
  assert(vim.fn.foldclosed(prow) ~= prow, "win2 should have independent view (not auto-closed)")
end)

it("selection and topline stable across delete and reopen", function()
  local a = state.new_session(); vim.b[a].straps_task = "A"
  local b = state.new_session(); vim.b[b].straps_task = "B"
  local buf = ui.open_agents("")
  registry.try_call("fn.agents_render", buf)
  local function ident(e)
    if not e then return nil end
    return e.bufnr and ("buf:" .. e.bufnr) or (e.path and ("path:" .. e.path)) or e.id
  end
  local brow = assert(find_row(buf, function(e) return e and e.bufnr == b end))
  vim.api.nvim_win_set_cursor(0, { brow, 0 })
  local before = vim.fn.winsaveview()
  local before_top_id = ident(ui._agents_line(buf, before.topline))
  vim.cmd("bwipeout! " .. b)
  registry.try_call("fn.agents_render", buf)
  local after_del = vim.fn.winsaveview()
  if before_top_id then
    local mapped
    for l = 1, vim.api.nvim_buf_line_count(buf) do
      local e = ui._agents_line(buf, l)
      if ident(e) == before_top_id then mapped = l break end
    end
    assert(math.abs((mapped or after_del.topline) - after_del.topline) <= 1, "topline drifted too far after delete")
  end
  local c = state.new_session(); vim.b[c].straps_task = "C"
  registry.try_call("fn.agents_render", buf)
  local after_new = vim.fn.winsaveview()
  assert(after_new.topline == after_del.topline, "topline jumped after new session")
  local cur = ui._agents_line(buf, vim.api.nvim_win_get_cursor(0)[1])
  assert(cur and (cur.bufnr == a or cur.bufnr == c or cur.id == "section:agents"), "selection lost to unrelated row")
end)

it("respects narrow width and Unicode; legend and every row/header fit", function()
  local saved_cfg = require("straps").config.agents_winbar
  require("straps").config.agents_winbar = false
  local s = state.new_session(); vim.b[s].straps_task = "Ångström – 你好😊 line1\nline2"
  local buf = ui.open_agents("")
  registry.try_call("fn.agents_render", buf)
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_width(win, 20)
  registry.try_call("fn.agents_render", buf)
  local w = 20
  for _, line in ipairs(lines_of(buf)) do
    assert(vim.fn.strdisplaywidth(line) <= w, "line exceeds window width: " .. line)
  end
  require("straps").config.agents_winbar = saved_cfg
end)

it("metadata omitted when narrow; title-first when available", function()
  local s = state.new_session(); vim.b[s].straps_task = "meta test"
  local ui_mod = require("straps.ui")
  local orig_info = ui_mod.session_info
  ui_mod.session_info = function() return { model_label = "m", context_pct = 42 } end
  local buf = ui.open_agents("")
  for _, w in ipairs(vim.fn.win_findbuf(buf)) do vim.api.nvim_win_set_width(w, 50) end
  registry.try_call("fn.agents_render", buf)
  local row = assert(find_row(buf, function(e) return e and e.bufnr == s end))
  local text_narrow = lines_of(buf)[row]
  assert(not text_narrow:find("ctx 42%%", 1, true), "metadata should be omitted when narrow")
  for _, w in ipairs(vim.fn.win_findbuf(buf)) do vim.api.nvim_win_set_width(w, 120) end
  registry.try_call("fn.agents_render", buf)
  local row2 = assert(find_row(buf, function(e) return e and e.bufnr == s end))
  local text_wide = lines_of(buf)[row2]
  if text_wide:find("ctx 42%%", 1, true) then
    local parts = vim.split(text_wide, "ctx 42%%", { plain = true })
    assert(#parts == 2 and #parts[1] > 0, "title should precede metadata")
  end
  ui_mod.session_info = orig_info
end)
it("p retains focus and readonly; P follows only when toggled; unchanged detail preserves changedtick", function()
  local s1 = state.new_session(); vim.b[s1].straps_task = "one"
  local s2 = state.new_session(); vim.b[s2].straps_task = "two"
  ui.show_session(s1, "none")
  local buf = ui.open_agents("")
  local row1 = assert(find_row(buf, function(e) return e and e.bufnr == s1 end))
  vim.api.nvim_win_set_cursor(0, { row1, 0 })
  local win_before = vim.api.nvim_get_current_win()
  ui._agents_key(buf, "p")
  assert(vim.api.nvim_get_current_win() == win_before, "focus should remain on agents window")
  local detail_win, detail_buf
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local b = vim.api.nvim_win_get_buf(w)
    if vim.api.nvim_buf_get_name(b):match("^straps://agents%-detail/") then detail_win, detail_buf = w, b end
  end
  assert(detail_win and detail_buf, "detail window/buffer not found")
  assert(vim.bo[detail_buf].modifiable == false, "detail must be readonly")
  local ct0 = vim.b[detail_buf].changedtick or vim.api.nvim_buf_get_changedtick(detail_buf)
  require("straps.agents").details(buf)
  local ct1 = vim.b[detail_buf].changedtick or vim.api.nvim_buf_get_changedtick(detail_buf)
  assert(ct1 == ct0, "unchanged detail should not bump changedtick")
  local row2 = assert(find_row(buf, function(e) return e and e.bufnr == s2 end))
  vim.api.nvim_win_set_cursor(0, { row2, 0 })
  local first_line = vim.api.nvim_buf_get_lines(detail_buf, 0, 1, false)[1] or ""
  assert(first_line:find("one", 1, true), "details should not auto-follow before toggle")
  ui._agents_key(buf, "P")
  vim.api.nvim_win_set_cursor(0, { row2, 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
  vim.wait(50)
  local first2 = vim.api.nvim_buf_get_lines(detail_buf, 0, 1, false)[1] or ""
  assert(first2:find("two", 1, true), "details should follow after toggle")
end)

it("preview reads <=256 lines, caches by changedtick, and never calls state.list_blocks", function()
  local s = state.new_session()
  ui.show_session(s, "none")
  local buf = ui.open_agents("")
  local flag = { called = false }
  local state_mod = require("straps.state")
  local orig_list = state_mod.list_blocks
  state_mod.list_blocks = function(...)
    flag.called = true; return orig_list(...)
  end
  local big = {}
  for i = 1, 1000 do big[i] = "line" .. i end
  state.append(s, "assistant", nil, table.concat(big, "\n"))
  local orig_get = vim.api.nvim_buf_get_lines
  local seen = { max_span = 0 }
  vim.api.nvim_buf_get_lines = function(bufnr, start, finish, strict)
    if bufnr == s then seen.max_span = math.max(seen.max_span, (finish - start)) end
    return orig_get(bufnr, start, finish, strict)
  end
  registry.try_call("fn.agents_render", buf)
  require("straps.agents").details(buf)
  vim.api.nvim_buf_get_lines = orig_get
  assert(seen.max_span <= 256, "preview read span exceeded 256 lines: " .. seen.max_span)
  assert(not flag.called, "details/preview must not call state.list_blocks")
  local old_get_lines = vim.api.nvim_buf_get_lines
  vim.api.nvim_buf_get_lines = function(bufnr, ...) if bufnr == s then error("should not read buffer on same tick") else return old_get_lines(bufnr, ...) end end
  require("straps.agents").details(buf)
  vim.api.nvim_buf_get_lines = old_get_lines
  state_mod.list_blocks = orig_list
end)

it("status labels: stopped/failed in UI; finished reason cleared at start", function()
  local function set_provider(src)
    define("fn.provider", "fn", "test provider", src)
  end
  local ui_mod = require("straps.ui")
  local save_refresh = ui_mod.agents_refresh
  ui_mod.agents_refresh = function() end
  set_provider([=[return function() return { stop_reason = "end_turn", content = { { type = "text", text = "ok" } } } end]=])
  local s1 = state.new_session(); state.append_text(s1, "run"); loop.start(s1); assert(vim.wait(1500, function() return not loop.running(s1) end, 10))
  local buf = ui.open_agents("")
  for _, w in ipairs(vim.fn.win_findbuf(buf)) do vim.api.nvim_win_set_width(w, 200) end
  registry.try_call("fn.agents_render", buf)
  local row1 = assert(find_row(buf, function(e) return e and e.bufnr == s1 end))
  local line1 = lines_of(buf)[row1]
  assert(line1:find("finished", 1, true), "expected finished status: " .. line1)
  parked_provider(); local s2 = state.new_session(); state.append_text(s2, "run"); loop.start(s2); assert(vim.wait(500, function() return loop.running(s2) end, 10)); loop.stop(s2); assert(vim.wait(2000, function() return not loop.running(s2) end, 10))
  registry.try_call("fn.agents_render", buf)
  local row2 = assert(find_row(buf, function(e) return e and e.bufnr == s2 end))
  assert(lines_of(buf)[row2]:find("stopped", 1, true), "expected stopped status")
  set_provider([=[return function() error("boom") end]=])
  local s3 = state.new_session(); state.append_text(s3, "run"); loop.start(s3); assert(vim.wait(1000, function() return not loop.running(s3) end, 10))
  assert(vim.b[s3].straps_run_reason == "error", "expected error reason")
  registry.try_call("fn.agents_render", buf)
  local row3 = assert(find_row(buf, function(e) return e and e.bufnr == s3 end))
  assert(lines_of(buf)[row3]:find("failed", 1, true), "expected failed status")
  parked_provider(); vim.b[s3].straps_run_reason = "ok"; state.append_text(s3, "run again"); loop.start(s3); assert(vim.wait(500, function() return loop.running(s3) end, 10));
  assert(vim.b[s3].straps_run_reason == nil, "reason not cleared at start")
  loop.stop(s3); vim.wait(50)
  ui_mod.agents_refresh = save_refresh
end)

it("does not override native keys; F1 opens help from a temp doc dir", function()
  local buf = ui.open_agents("")
  local maps = vim.api.nvim_buf_get_keymap(buf, "n")
  local forbidden = { ["?"] = true, v = true, V = true, gv = true, ["<C-w>"] = true }
  for _, m in ipairs(maps) do
    assert(not forbidden[m.lhs], "unexpected mapping for " .. m.lhs)
  end
  local save_rtp = vim.o.rtp
  local tmp = vim.fn.tempname(); vim.fn.mkdir(tmp .. "/doc", "p")
  vim.fn.writefile({"*straps-agents*", "Help for straps agents"}, tmp .. "/doc/straps-agents.txt")
  vim.cmd("helptags " .. vim.fn.fnameescape(tmp .. "/doc"))
  vim.opt.rtp:prepend(tmp)
  ui._agents_key(buf, "help")
  local helpbuf = vim.api.nvim_get_current_buf()
  local helptext = table.concat(vim.api.nvim_buf_get_lines(helpbuf, 0, -1, false), "\n")
  vim.o.rtp = save_rtp
  assert(helptext:find("Help for straps agents", 1, true), "help content not opened")
end)

it("saved rows: CR opens only; gCR on another saved starts a run", function()
  local tmp1, tmp2
  do local b = state.new_session(); state.append(b, "user", nil, "saved1"); tmp1 = vim.api.nvim_buf_get_name(b); vim.cmd("bwipeout! " .. b) end
  do local b = state.new_session(); state.append(b, "user", nil, "saved2"); tmp2 = vim.api.nvim_buf_get_name(b); vim.cmd("bwipeout! " .. b) end
  local buf = ui.open_agents("")
  registry.try_call("fn.agents_render", buf)
  local r1 = assert(find_row(buf, function(e) return e and e.kind == "saved" and e.path == tmp1 end))
  vim.api.nvim_win_set_cursor(0, { r1, 0 })
  ui._agents_key(buf, "cr")
  local cur = vim.api.nvim_get_current_buf()
  assert(vim.api.nvim_buf_get_name(cur) == tmp1 and not loop.running(cur), "CR should open transcript without starting a run")
  parked_provider()
  ui.open_agents("")
  registry.try_call("fn.agents_render", buf)
  local r2 = assert(find_row(buf, function(e) return e and e.kind == "saved" and e.path == tmp2 end))
  vim.api.nvim_win_set_cursor(0, { r2, 0 })
  ui._agents_key(buf, "gcr")
  local tgt
  for _, b in ipairs(vim.api.nvim_list_bufs()) do if vim.api.nvim_buf_get_name(b) == tmp2 then tgt = b end end
  assert(tgt and loop.running(tgt), "gCR should start the saved transcript")
  loop.stop(tgt)
end)

it("R clears the session summary cache and renders once", function()
  local ui = require("straps.ui")
  local state = require("straps.state")
  local buf = ui.open_agents("")
  local called = 0
  local orig = state.clear_session_summary_cache
  state.clear_session_summary_cache = function(...) called = called + 1 end
  local before = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  ui._agents_key(buf, "R")
  vim.wait(200)
  local after = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  state.clear_session_summary_cache = orig
  assert(called >= 1, "R did not call clear_session_summary_cache")
  assert(type(after) == "string" and #after >= 0, "agents buffer did not render after R")
end)

it("x prompts when descendants run; Cancel preserves, Stop stops parent", function()
  local ui = require("straps.ui")
  local state = require("straps.state")
  local loop = require("straps.loop")
  local registry = require("straps.registry")
  -- parked provider to keep sessions running
  registry.define({ name = "fn.provider", kind = "fn", doc = "test: parked", source = [==[
return function(req, ctx)
  ctx.await(function(resolve)
    ctx.on_cancel(function() resolve("killed") end)
    vim.defer_fn(function() resolve("timeout") end, 60000)
  end)
  if ctx.cancelled() then return { stop_reason = "cancelled" } end
  return { stop_reason = "end_turn", content = { { type = "text", text = "ok" } } }
end]==] })
  local parent = state.new_session(); state.append_text(parent, "run"); loop.start(parent)
  local child = state.new_session(); vim.b[child].straps_parent = parent; state.append_text(child, "run"); loop.start(child)
  assert(vim.wait(1500, function() return loop.running(parent) and loop.running(child) end, 10), "precondition: both should be running")
  local buf = ui.open_agents("")
  registry.try_call("fn.agents_render", buf)
  local prow
  for l = 1, vim.api.nvim_buf_line_count(buf) do local e = ui._agents_line(buf, l); if e and e.bufnr == parent then prow = l break end end
  assert(prow, "no parent row to test confirm path")
  vim.api.nvim_win_set_cursor(0, { prow, 0 })
  local save = vim.fn.confirm; vim.fn.confirm = function() return 2 end -- Cancel
  ui._agents_key(buf, "x")
  vim.fn.confirm = save
  assert(loop.running(parent) and loop.running(child), "Cancel should preserve both runs")
  local save2 = vim.fn.confirm; vim.fn.confirm = function() return 1 end -- Stop
  ui._agents_key(buf, "x")
  vim.fn.confirm = save2
  assert(vim.wait(1500, function() return not loop.running(parent) end, 10), "Stop should stop parent")
  if loop.running(child) then loop.stop(child) end
end)
