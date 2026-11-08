-- tests/quickfix_spec.lua — quickfix integration (straps.tools + straps.editor).
--   busted tests/quickfix_spec.lua
-- No network. Covers: grep populating the quickfix list with correct
-- filename/lnum (and the text summary unchanged); grep's glob /
-- case_insensitive / fixed_string / context parameters (and context lines
-- staying out of the quickfix list); diagnostics {quickfix=true}
-- landing seeded diagnostics in the list (and leaving it untouched without the
-- flag); bulk_replace editing every file in a seeded quickfix list (undoably,
-- with a file count); its dry_run and empty-list paths; locations_do
-- restoring the session window's buffer + view; the windowless-session store;
-- focus kept when a list opens; c/n flag rejection; grep's open parameter.

local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(vim.fn.fnamemodify(here, ":p"), ":h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path


-- Isolate any session writes (defensive; these tools don't create sessions).
require("straps").config.session_dir = vim.fn.tempname()

local registry = require("straps.registry")
require("straps.tools").register()  -- grep, bulk_replace, hook.confirm
require("straps.editor").register() -- diagnostics

local unpack = unpack or table.unpack
local function pack(...) return { n = select("#", ...), ... } end

-- Minimal ctx.await driver (grep uses ctx.await + vim.system): run a thunk in a
-- coroutine; resolve resumes it via vim.schedule (as the loop does).
local function drive(thunk, timeout_ms)
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
  co = coroutine.create(function()
    out = thunk(ctx)
    finished = true
  end)
  local ok, err = coroutine.resume(co)
  if not ok then error(err) end
  vim.wait(timeout_ms or 8000, function() return finished end, 20)
  assert(finished, "drive: thunk did not finish within timeout")
  return out
end

local function write_file(path, text)
  local f = assert(io.open(path, "w"))
  f:write(text)
  f:close()
end

local function read_file(path)
  local f = assert(io.open(path, "r"))
  local t = f:read("*a")
  f:close()
  return t
end

-- basename -> lnum map over the current quickfix list.
local function qf_by_basename()
  local m = {}
  for _, e in ipairs(vim.fn.getqflist()) do
    local name = vim.fn.bufname(e.bufnr)
    if name ~= "" then
      m[vim.fn.fnamemodify(name, ":t")] = e.lnum
    end
  end
  return m
end

-- ------------------------------------------------------------------------ grep

it("grep populates the quickfix list with correct filename + lnum", function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  write_file(dir .. "/one.txt", "alpha\nNEEDLE here\nbeta\n")   -- match on line 2
  write_file(dir .. "/two.txt", "NEEDLE first line\n")          -- match on line 1

  vim.fn.setqflist({}, "r") -- start from an empty list
  local out = drive(function(ctx)
    return registry.call("tool.grep", { pattern = "NEEDLE", path = dir }, ctx)
  end)

  -- The text summary the model sees is unchanged (still the matches).
  assert(out:find("NEEDLE", 1, true), "grep text summary lost the matches:\n" .. out)

  local by = qf_by_basename()
  assert(by["one.txt"] == 2, "one.txt should be at lnum 2 in qf, got " .. tostring(by["one.txt"]))
  assert(by["two.txt"] == 1, "two.txt should be at lnum 1 in qf, got " .. tostring(by["two.txt"]))
  assert(#vim.fn.getqflist() == 2, "expected exactly 2 quickfix entries")

  local title = vim.fn.getqflist({ title = true }).title
  assert(title == "straps: grep NEEDLE", "unexpected qf title: " .. tostring(title))
end)

-- ------------------------------------------------------------- grep parameters

-- One shared tree for the parameter cases: a .lua file with a capitalized
-- needle, a .txt file with a lowercase one, and a file whose text contains a
-- regex metacharacter literally.
local function grep_param_dir()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  write_file(dir .. "/a.lua", "before\nNeedle = 1\nafter\n")
  write_file(dir .. "/b.txt", "needle in txt\n")
  write_file(dir .. "/c.lua", "dot.star literal\n")
  return dir
end

local function grep(input)
  return drive(function(ctx)
    return registry.call("tool.grep", input, ctx)
  end)
end

it("grep glob restricts to matching files; case_insensitive widens the match", function()
  local dir = grep_param_dir()
  local out = grep({ pattern = "needle", path = dir, glob = "*.lua", case_insensitive = true })
  assert(out:find("a.lua", 1, true), "expected a.lua match:\n" .. out)
  assert(not out:find("b.txt", 1, true), "glob '*.lua' should exclude b.txt:\n" .. out)
end)

it("grep is case-sensitive by default", function()
  local dir = grep_param_dir()
  local out = grep({ pattern = "needle", path = dir, glob = "*.lua" })
  assert(out == "no matches",
    "'needle' should not match 'Needle' without case_insensitive, got:\n" .. out)
end)

it("grep fixed_string matches metacharacters literally", function()
  local dir = grep_param_dir()
  -- As a regex, 'dot.star' would also match e.g. 'dotXstar'; as a fixed
  -- string it must match c.lua's literal 'dot.star' (and it must not be
  -- rejected as a bad pattern).
  local out = grep({ pattern = "dot.star", path = dir, fixed_string = true })
  assert(out:find("c.lua", 1, true), "fixed_string match missing:\n" .. out)
end)

it("grep context shows surrounding lines but keeps them out of the quickfix list", function()
  local dir = grep_param_dir()
  vim.fn.setqflist({}, "r")
  local out = grep({ pattern = "Needle", path = dir, context = 1 })
  assert(out:find("before", 1, true) and out:find("after", 1, true),
    "context lines missing from text summary:\n" .. out)
  local qf = vim.fn.getqflist()
  assert(#qf == 1, "expected exactly 1 quickfix entry (no context lines), got " .. #qf)
  assert(qf[1].lnum == 2, "match should be at lnum 2, got " .. tostring(qf[1].lnum))
end)

-- ----------------------------------------------------------------- diagnostics

it("diagnostics {quickfix=true} lands diagnostics in the qf list; off leaves it", function()
  local path = vim.fn.tempname() .. ".txt"
  write_file(path, "one\ntwo\nthree\n")
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  local ns = vim.api.nvim_create_namespace("straps_test_qf_diag")
  vim.diagnostic.set(ns, buf, {
    { lnum = 0, col = 0, severity = vim.diagnostic.severity.ERROR, message = "boom-diag" },
  })

  -- A sentinel list: calling diagnostics WITHOUT quickfix must not touch it.
  vim.fn.setqflist({}, "r", { items = { { text = "SENTINEL" } } })
  registry.call("tool.diagnostics", { path = path }, { bufnr = 0 })
  local after = vim.fn.getqflist()
  assert(#after == 1 and after[1].text == "SENTINEL",
    "diagnostics without quickfix should leave the list untouched")

  -- With quickfix=true it replaces the list with the diagnostics.
  registry.call("tool.diagnostics", { path = path, quickfix = true }, { bufnr = 0 })
  local qf = vim.fn.getqflist()
  local found = false
  for _, e in ipairs(qf) do
    if e.text == "boom-diag" and e.lnum == 1 then found = true end
  end
  assert(found, "seeded diagnostic missing from quickfix list")
  local title = vim.fn.getqflist({ title = true }).title
  assert(title == "straps: diagnostics", "unexpected qf title: " .. tostring(title))
end)

-- ---------------------------------------------------------------- bulk_replace

-- Seed a quickfix list pointing at two fresh temp files, both containing FOO.
local function seed_two_files()
  local f1 = vim.fn.tempname() .. ".txt"
  local f2 = vim.fn.tempname() .. ".txt"
  write_file(f1, "FOO line\nsecond\n")
  write_file(f2, "another FOO here\n")
  vim.fn.setqflist({}, "r", {
    items = {
      { filename = f1, lnum = 1, col = 1, text = "FOO line" },
      { filename = f2, lnum = 1, col = 1, text = "another FOO here" },
    },
  })
  return f1, f2
end

it("bulk_replace edits every file in the quickfix list (undoably) + reports count", function()
  local f1, f2 = seed_two_files()
  local out = registry.call("tool.bulk_replace",
    { pattern = "FOO", replacement = "BAR" }, { bufnr = 0 })

  -- Both files changed on disk.
  assert(read_file(f1):find("BAR", 1, true), "f1 not substituted on disk:\n" .. read_file(f1))
  assert(read_file(f2):find("BAR", 1, true), "f2 not substituted on disk:\n" .. read_file(f2))
  assert(not read_file(f1):find("FOO", 1, true), "f1 still has FOO on disk")

  -- Reports the file count.
  assert(out:find("2 file", 1, true), "expected '2 files changed' in result, got:\n" .. out)
  assert(out:find("undo", 1, true), "result should note it is undoable:\n" .. out)

  -- The edit went through the buffer, so an in-buffer undo reverts it.
  local buf = vim.fn.bufadd(f1)
  vim.fn.bufload(buf)
  vim.api.nvim_buf_call(buf, function() vim.cmd("silent undo") end)
  local reverted = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  assert(reverted:find("FOO", 1, true), "undo did not revert the substitute in the buffer:\n" .. reverted)
  assert(not reverted:find("BAR", 1, true), "buffer still shows BAR after undo:\n" .. reverted)
end)

it("bulk_replace dry_run reports the would-edit count and changes nothing", function()
  local f1, f2 = seed_two_files()
  local out = registry.call("tool.bulk_replace",
    { pattern = "FOO", replacement = "BAR", dry_run = true }, { bufnr = 0 })

  assert(out:find("dry_run", 1, true), "expected a dry_run report, got:\n" .. out)
  assert(out:find("2 file", 1, true), "dry_run should report 2 files, got:\n" .. out)
  assert(read_file(f1):find("FOO", 1, true), "dry_run changed f1 on disk")
  assert(read_file(f2):find("FOO", 1, true), "dry_run changed f2 on disk")
  assert(not read_file(f1):find("BAR", 1, true), "dry_run wrote BAR into f1")
end)

it("bulk_replace with an empty quickfix list returns the error string", function()
  vim.fn.setqflist({}, "r") -- empty it
  local out = registry.call("tool.bulk_replace",
    { pattern = "FOO", replacement = "BAR" }, { bufnr = 0 })
  assert(out == "findings list is empty — run grep first to populate it",
    "unexpected empty-list message: " .. tostring(out))
end)

it("bulk_replace rejects Ex command separators in user-controlled fragments", function()
  seed_two_files()
  local ok, err = pcall(registry.call, "tool.bulk_replace",
    { pattern = "FOO", replacement = "BAR | edit /tmp/owned" }, { bufnr = 0 })
  assert(not ok and tostring(err):find("must not contain", 1, true),
    "replacement separator should be rejected, got: " .. tostring(err))
  ok, err = pcall(registry.call, "tool.bulk_replace",
    { pattern = "FOO", replacement = "BAR", flags = "ge | qall!" }, { bufnr = 0 })
  assert(not ok and tostring(err):find("flags contain", 1, true),
    "flag separator should be rejected, got: " .. tostring(err))
end)

it("bulk_replace is NOT in hook.confirm's auto-allow set (it is a write)", function()
  -- read-only editor/search tools auto-allow (return true); bulk_replace must
  -- fall through to a prompt. Headless, vim.fn.confirm returns 0 -> denied.
  local allowed = registry.call("hook.confirm", "bulk_replace", { pattern = "a", replacement = "b" }, { bufnr = 0 })
  assert(allowed ~= true, "bulk_replace must not be auto-allowed by hook.confirm")
end)

-- ---------------------------------------------------------- session isolation

-- Two on-screen sessions must not stomp each other's findings list: each
-- session's grep goes to ITS window's location list, and bulk_replace on that
-- session edits only that session's files — never the global quickfix list.
it("concurrent sessions get isolated per-window findings lists", function()
  local state = require("straps.state")
  -- Build two files, one per "session".
  local dir = vim.fn.tempname(); vim.fn.mkdir(dir, "p")
  local fa, fb = dir .. "/sa.txt", dir .. "/sb.txt"
  for _, f in ipairs({ fa, fb }) do
    local h = assert(io.open(f, "w")); h:write("target\ntarget\n"); h:close()
  end

  -- Two session buffers, each in its own window.
  vim.cmd("only")
  local sa = state.new_session()
  vim.api.nvim_set_current_buf(sa)
  local wa = vim.api.nvim_get_current_win()
  vim.cmd("vsplit")
  local sb = state.new_session()
  vim.api.nvim_set_current_buf(sb)
  local wb = vim.api.nvim_get_current_win()

  -- Put a stomping value in the GLOBAL quickfix list — neither session should
  -- touch it.
  vim.fn.setqflist({}, " ", { title = "global-untouched",
    items = { { filename = "/nope", lnum = 1, text = "x" } } })

  local ui = require("straps.ui")
  assert(ui.session_win(sa) == wa, "session_win(sa) wrong")
  assert(ui.session_win(sb) == wb, "session_win(sb) wrong")

  -- Each session sets its own findings list (as grep/set_findings do).
  ui.set_locations(sa, { title = "A", items = { { filename = fa, lnum = 1, col = 1, text = "target" } } }, false)
  ui.set_locations(sb, { title = "B", items = { { filename = fb, lnum = 1, col = 1, text = "target" } } }, false)

  -- Isolation: each window's location list holds only its own file; the global
  -- quickfix list is untouched.
  assert(vim.fn.getloclist(wa)[1].bufnr ~= 0, "A loclist empty")
  assert(vim.fn.getqflist({ title = 1 }).title == "global-untouched",
    "global quickfix list was stomped by a session")
  local la = vim.fn.getloclist(wa, { title = 1 }).title
  local lb = vim.fn.getloclist(wb, { title = 1 }).title
  assert(la == "A" and lb == "B", "loclists crossed: A=" .. la .. " B=" .. lb)

  -- bulk_replace on session A edits ONLY A's file, reading A's loclist.
  local out = registry.call("tool.bulk_replace",
    { pattern = "target", replacement = "HIT" }, { bufnr = sa })
  assert(out:find("loclist", 1, true), "bulk_replace should report the loclist: " .. out)
  assert(table.concat(vim.fn.readfile(fa), ","):find("HIT", 1, true), "A's file not edited")
  assert(not table.concat(vim.fn.readfile(fb), ","):find("HIT", 1, true),
    "B's file was edited by A's bulk_replace — isolation failed")

  vim.cmd("only")
end)

-- :ldo NAVIGATES the window it runs in through every loclist entry, so an ldo
-- through the on-screen SESSION window would leave that window showing the last
-- edited file — the transcript scrolls out of view mid-run. locations_do must
-- snapshot the window's buffer + view before the substitution and restore them
-- after, so bulk_replace's edits land but the session window never moves.
it("bulk_replace preserves the session window's buffer and view across :ldo", function()
  local state = require("straps.state")
  local ui = require("straps.ui")
  vim.cmd("only")

  -- A session buffer, shown in the current window, scrolled to a known view.
  local sess = state.new_session()
  vim.api.nvim_set_current_buf(sess)
  local win = vim.api.nvim_get_current_win()
  assert(ui.session_win(sess) == win, "session not on-screen")
  -- Give the transcript enough lines that a scroll position is meaningful.
  vim.bo[sess].modifiable = true
  local filler = {}
  for i = 1, 200 do filler[i] = "transcript line " .. i end
  vim.api.nvim_buf_set_lines(sess, 0, -1, false, filler)
  vim.api.nvim_win_set_cursor(win, { 120, 3 })
  vim.api.nvim_win_call(win, function() vim.cmd("normal! zz") end)
  local view_before = vim.api.nvim_win_call(win, vim.fn.winsaveview)

  -- The findings list points at a DIFFERENT file — the one :ldo will visit.
  local dir = vim.fn.tempname(); vim.fn.mkdir(dir, "p")
  local f = dir .. "/edited.txt"
  do local h = assert(io.open(f, "w")); h:write("target\ntarget\n"); h:close() end
  ui.set_locations(sess, { title = "L",
    items = { { filename = f, lnum = 1, col = 1, text = "target" } } }, false)

  local out = registry.call("tool.bulk_replace",
    { pattern = "target", replacement = "HIT" }, { bufnr = sess })

  -- The substitution landed (counterfactual anchor: without :ldo running, this
  -- fails, so the restore below is proven to sit on top of a real edit).
  assert(out:find("loclist", 1, true), "expected the loclist path: " .. out)
  assert(table.concat(vim.fn.readfile(f), ","):find("HIT", 1, true),
    "bulk_replace did not edit the target file")

  -- The session window still shows the transcript, at the same view.
  assert(vim.api.nvim_win_is_valid(win), "session window was destroyed")
  assert(vim.api.nvim_win_get_buf(win) == sess,
    "session window was left showing another buffer after :ldo (buf "
      .. vim.api.nvim_win_get_buf(win) .. " != session " .. sess .. ")")
  local view_after = vim.api.nvim_win_call(win, vim.fn.winsaveview)
  assert(view_after.lnum == view_before.lnum and view_after.topline == view_before.topline
      and view_after.col == view_before.col,
    ("session window view moved: before {lnum=%d,topline=%d,col=%d} after {lnum=%d,topline=%d,col=%d}")
      :format(view_before.lnum, view_before.topline, view_before.col,
        view_after.lnum, view_after.topline, view_after.col))

  vim.cmd("only")
end)

it("windowless session keeps its findings in a private store and never touches the global quickfix list", function()
  local state = require("straps.state")
  local findings = require("straps.findings")
  vim.cmd("only")
  local s = state.new_session()
  assert(findings.session_win(s) == nil, "expected no window for the hidden session")
  vim.fn.setqflist({}, " ", { title = "user make", items = { { filename = "/tmp/user", lnum = 1, text = "u" } } })
  local wins = #vim.api.nvim_list_wins()
  local kind = findings.set_locations(s, { title = "private",
    items = { { filename = "/tmp/x", lnum = 1, text = "y" } } }, true)
  assert.are.equal(findings.STORE_KIND, kind)
  assert.are.equal("user make", vim.fn.getqflist({ title = 1 }).title)
  assert.are.equal(wins, #vim.api.nvim_list_wins())
  local items, gkind = findings.get_locations(s)
  assert.are.equal(findings.STORE_KIND, gkind)
  assert.are.equal(1, #items)
  assert.are.equal("/tmp/x", vim.api.nvim_buf_get_name(items[1].bufnr))
  assert.are.equal("private", findings.stored(s).title)
end)

it("grep in a windowless session says the list is private and bulk_replace edits through the store", function()
  local state = require("straps.state")
  vim.cmd("only")
  local s = state.new_session()
  local dir = vim.fn.tempname(); vim.fn.mkdir(dir, "p")
  write_file(dir .. "/w.txt", "keep\nSTOREHIT\nkeep\n")
  vim.fn.setqflist({}, " ", { title = "user make", items = {} })
  local out = drive(function(ctx)
    ctx.bufnr = s
    return registry.call("tool.grep", { pattern = "STOREHIT", path = dir }, ctx)
  end)
  assert.truthy(out:find("private session store", 1, true))
  assert.are.equal("user make", vim.fn.getqflist({ title = 1 }).title)
  local res = registry.call("tool.bulk_replace", { pattern = "STOREHIT", replacement = "DONE" }, { bufnr = s })
  assert.truthy(res:find("1 file changed", 1, true), res)
  assert.are.equal("keep\nDONE\nkeep\n", read_file(dir .. "/w.txt"))
end)

it("opening the findings list never moves focus", function()
  local state = require("straps.state")
  local findings = require("straps.findings")
  vim.cmd("only")
  local s = state.new_session()
  vim.api.nvim_set_current_buf(s)
  local swin = vim.api.nvim_get_current_win()
  vim.cmd("vsplit")
  vim.cmd("enew")
  local user = vim.api.nvim_get_current_win()
  assert(user ~= swin)
  findings.set_locations(s, { title = "L", items = { { filename = "/tmp/x", lnum = 1, text = "y" } } }, true)
  assert.are.equal(user, vim.api.nvim_get_current_win())
  local loc_open = false
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.fn.getwininfo(w)[1].loclist == 1 then loc_open = true end
  end
  assert.is_true(loc_open)
  vim.cmd("only")
  findings.set_locations(nil, { title = "Q", items = { { filename = "/tmp/x", lnum = 1, text = "y" } } }, true)
  assert.are.equal(user, vim.api.nvim_get_current_win())
  vim.cmd("cclose")
  vim.cmd("only")
end)

it("bulk_replace through the global list leaves the user's window and jumplist alone", function()
  vim.cmd("only")
  vim.cmd("enew")
  local user_win = vim.api.nvim_get_current_win()
  local user_buf = vim.api.nvim_get_current_buf()
  local jumps_before = #vim.fn.getjumplist()[1]
  vim.fn.setreg("/", "usersearch")
  local f1, f2 = seed_two_files()
  local out = registry.call("tool.bulk_replace", { pattern = "FOO", replacement = "QUX" }, { bufnr = 0 })
  assert.truthy(out:find("2 files changed", 1, true), out)
  assert.truthy(read_file(f1):find("QUX", 1, true))
  assert.truthy(read_file(f2):find("QUX", 1, true))
  assert.are.equal(user_win, vim.api.nvim_get_current_win())
  assert.are.equal(user_buf, vim.api.nvim_win_get_buf(user_win))
  assert.are.equal(jumps_before, #vim.fn.getjumplist()[1])
  assert.are.equal("usersearch", vim.fn.getreg("/"))
end)

it("bulk_replace rejects flags c and n, even in dry_run", function()
  seed_two_files()
  for _, f in ipairs({ "gc", "gn" }) do
    for _, dry in ipairs({ false, true }) do
      local ok, err = pcall(registry.call, "tool.bulk_replace",
        { pattern = "FOO", replacement = "BAR", flags = f, dry_run = dry }, { bufnr = 0 })
      assert.is_false(ok)
      assert.truthy(tostring(err):find("^bulk_replace: flags c %(confirm each match%) and n"), tostring(err))
    end
  end
end)

it("session findings survive visibility changes without reviving stale lists", function()
  local findings = require("straps.findings")
  vim.cmd("only")
  local s = require("straps.state").new_session()
  local other = vim.api.nvim_create_buf(true, false)
  local function seed(text)
    findings.set_locations(s, { title = text, items = { { filename = "/tmp/visibility", lnum = 1, text = text } } }, false)
  end
  seed("hidden")
  vim.api.nvim_set_current_buf(s)
  local win = vim.api.nvim_get_current_win()
  assert.are.equal("hidden", vim.fn.getloclist(win)[1] and vim.fn.getloclist(win)[1].text)
  assert.are.equal("hidden", findings.get_locations(s)[1].text)
  seed("visible")
  vim.api.nvim_set_current_buf(other)
  assert.are.equal("visible", findings.get_locations(s)[1].text)
  seed("new hidden")
  vim.api.nvim_set_current_buf(s)
  assert.are.equal("new hidden", vim.fn.getloclist(win)[1].text)
  assert.are.equal("new hidden", findings.get_locations(s)[1].text)
  seed("latest visible")
  vim.api.nvim_set_current_buf(other)
  assert.are.equal("latest visible", findings.get_locations(s)[1].text)
  vim.api.nvim_buf_delete(s, { force = true })
  assert.is_nil(findings.stored(s))
end)

it("bulk_replace rejects inherited substitute flags after n and c were seeded", function()
  for _, inherited in ipairs({ "n", "c" }) do
    local f1, f2 = seed_two_files()
    local seed = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(seed, 0, -1, false, { "seed" })
    vim.api.nvim_buf_call(seed, function() vim.cmd("silent! s/absent/nope/" .. inherited .. "e") end)
    for _, dry in ipairs({ false, true }) do
      local ok, err = pcall(registry.call, "tool.bulk_replace",
        { pattern = "FOO", replacement = "BAR", flags = "&", dry_run = dry }, { bufnr = 0 })
      assert.is_false(ok)
      assert.truthy(tostring(err):find("flags contain unsupported characters", 1, true))
      assert.are.equal("FOO line\nsecond\n", read_file(f1))
      assert.are.equal("another FOO here\n", read_file(f2))
    end
    vim.api.nvim_buf_delete(seed, { force = true })
  end
end)

it("bulk_replace tracks later findings through multiline replacements and preserves undo", function()
  local path = vim.fn.tempname() .. ".txt"
  write_file(path, "FOO first\nkeep\nFOO last\n")
  vim.fn.setqflist({}, "r", { items = {
    { filename = path, lnum = 1 }, { filename = path, lnum = 3 },
  } })
  local out = registry.call("tool.bulk_replace", { pattern = "FOO", replacement = "BAR\\rADDED" }, { bufnr = 0 })
  assert.truthy(out:find("1 file changed", 1, true))
  assert.are.equal("BAR\nADDED first\nkeep\nBAR\nADDED last\n", read_file(path))
  local buf = vim.fn.bufadd(path)
  local function undo_lines()
    vim.api.nvim_buf_call(buf, function() vim.cmd("silent undo") end)
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  end
  assert.are.same({ "FOO first", "keep", "FOO last" }, undo_lines())
end)

it("bulk_replace gives consecutive timer calls separate per-buffer undo blocks", function()
  local path = vim.fn.tempname() .. ".txt"
  write_file(path, "FOO first\nkeep\nFOO last\n")
  vim.fn.setqflist({}, "r", { items = {
    { filename = path, lnum = 1 }, { filename = path, lnum = 3 },
  } })
  local function replace(pattern, replacement)
    local finished, failure = false, nil
    vim.defer_fn(function()
      local ok, err = pcall(registry.call, "tool.bulk_replace", { pattern = pattern, replacement = replacement }, { bufnr = 0 })
      if not ok then failure = err end
      finished = true
    end, 1)
    assert.is_true(vim.wait(2000, function() return finished end, 10))
    assert.is_nil(failure)
  end
  replace("FOO", "BAR")
  replace("BAR", "DONE")
  local buf = vim.fn.bufadd(path)
  assert.are.same({ "DONE first", "keep", "DONE last" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  vim.api.nvim_buf_call(buf, function() vim.cmd("silent undo") end)
  assert.are.same({ "BAR first", "keep", "BAR last" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  vim.api.nvim_buf_call(buf, function() vim.cmd("silent undo") end)
  assert.are.same({ "FOO first", "keep", "FOO last" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
end)

it("bulk_replace persists multiline finding positions for consecutive calls in visible and hidden sessions", function()
  local findings = require("straps.findings")
  for _, visible in ipairs({ false, true }) do
    local s = require("straps.state").new_session()
    if visible then vim.api.nvim_set_current_buf(s) end
    local path = vim.fn.tempname() .. ".txt"
    write_file(path, "FOO first\nkeep\nFOO last\n")
    findings.set_locations(s, { title = "multiline", items = {
      { filename = path, lnum = 1 }, { filename = path, lnum = 3 },
    } }, false)
    registry.call("tool.bulk_replace", { pattern = "FOO", replacement = "BAR\\rADDED" }, { bufnr = s })
    local items = findings.get_locations(s)
    assert.are.equal(1, items[1].lnum)
    assert.are.equal(4, items[2].lnum)
    registry.call("tool.bulk_replace", { pattern = "BAR", replacement = "DONE" }, { bufnr = s })
    assert.are.equal("DONE\nADDED first\nkeep\nDONE\nADDED last\n", read_file(path))
    vim.api.nvim_buf_delete(s, { force = true })
  end
end)

for _, visible in ipairs({ false, true }) do
  it("bulk_replace restores finding rows after native undo in a " .. (visible and "visible" or "hidden") .. " session", function()
    local findings = require("straps.findings")
    local s = require("straps.state").new_session()
    if visible then vim.api.nvim_set_current_buf(s) end
    local path = vim.fn.tempname() .. ".txt"
    write_file(path, "FOO first\nkeep\nFOO last\n")
    findings.set_locations(s, { title = "undo multiline", items = {
      { filename = path, lnum = 1 }, { filename = path, lnum = 3 },
    } }, false)
    registry.call("tool.bulk_replace", { pattern = "FOO", replacement = "BAR\\rADDED" }, { bufnr = s })
    local buf = vim.fn.bufadd(path)
    assert.are.equal(4, findings.get_locations(s)[2].lnum)
    vim.api.nvim_buf_call(buf, function() vim.cmd("silent undo") end)
    assert.are.same({ "FOO first", "keep", "FOO last" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    assert.are.equal(3, findings.get_locations(s)[2].lnum)
    if visible then assert.are.equal(3, vim.fn.getloclist(findings.session_win(s))[2].lnum) end
    registry.call("tool.bulk_replace", { pattern = "FOO", replacement = "DONE" }, { bufnr = s })
    assert.are.equal("DONE first\nkeep\nDONE last\n", read_file(path))
    vim.api.nvim_buf_delete(s, { force = true })
  end)
end

it("session finding tracking marks are removed on reset and wipe", function()
  local findings = require("straps.findings")
  local s = require("straps.state").new_session()
  local path = vim.fn.tempname() .. ".txt"
  write_file(path, "FOO\n")
  local ns = vim.api.nvim_create_namespace("straps_findings_tracking")
  local function seed()
    findings.set_locations(s, { title = "cleanup", items = { { filename = path, lnum = 1 } } }, false)
  end
  seed()
  local buf = vim.fn.bufadd(path)
  assert.are.equal(1, #vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}))
  findings.set_locations(s, { title = "empty", items = {} }, false)
  assert.are.equal(0, #vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}))
  seed()
  vim.api.nvim_buf_delete(s, { force = true })
  assert.are.equal(0, #vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}))
  assert.is_nil(findings.stored(s))
end)

it("locations_do persists moved findings after a partial failure", function()
  local findings = require("straps.findings")
  local s = require("straps.state").new_session()
  local path = vim.fn.tempname() .. ".txt"
  write_file(path, "FOO first\nkeep\nFOO last\n")
  findings.set_locations(s, { title = "partial", items = {
    { filename = path, lnum = 1 }, { filename = path, lnum = 2 }, { filename = path, lnum = 3 },
  } }, false)
  local ok = findings.locations_do(s, "s/FOO/BAR\\rADDED/ | update")
  assert.is_false(ok)
  local items = findings.get_locations(s)
  assert.are.equal(1, items[1].lnum)
  assert.are.equal(3, items[2].lnum)
  assert.are.equal(4, items[3].lnum)
  registry.call("tool.bulk_replace", { pattern = "FOO", replacement = "DONE" }, { bufnr = s })
  assert.are.equal("BAR\nADDED first\nkeep\nDONE last\n", read_file(path))
  local buf = vim.fn.bufadd(path)
  vim.api.nvim_buf_call(buf, function() vim.cmd("silent undo") end)
  vim.api.nvim_buf_call(buf, function() vim.cmd("silent undo") end)
  assert.are.equal(3, findings.get_locations(s)[3].lnum)
  registry.call("tool.bulk_replace", { pattern = "FOO", replacement = "FINAL" }, { bufnr = s })
  assert.are.equal("FINAL first\nkeep\nFINAL last\n", read_file(path))
  vim.api.nvim_buf_delete(s, { force = true })
end)

it("grep does not open the findings list by default; open=true opens it without moving focus", function()
  local state = require("straps.state")
  vim.cmd("only")
  local s = state.new_session()
  vim.api.nvim_set_current_buf(s)
  local swin = vim.api.nvim_get_current_win()
  local dir = vim.fn.tempname(); vim.fn.mkdir(dir, "p")
  write_file(dir .. "/o.txt", "OPENME\n")
  local function loclist_wins()
    local n = 0
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.fn.getwininfo(w)[1].loclist == 1 then n = n + 1 end
    end
    return n
  end
  drive(function(ctx) ctx.bufnr = s; return registry.call("tool.grep", { pattern = "OPENME", path = dir }, ctx) end)
  assert.are.equal(0, loclist_wins())
  assert.are.equal(1, #vim.fn.getloclist(swin))
  drive(function(ctx) ctx.bufnr = s; return registry.call("tool.grep", { pattern = "OPENME", path = dir, open = true }, ctx) end)
  assert.are.equal(1, loclist_wins())
  assert.are.equal(swin, vim.api.nvim_get_current_win())
  vim.cmd("only")
end)
