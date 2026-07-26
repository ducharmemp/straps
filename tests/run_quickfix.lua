-- tests/run_quickfix.lua — quickfix integration (straps.tools + straps.editor).
--   nvim --headless -l tests/run_quickfix.lua
-- No network. Covers: grep populating the quickfix list with correct
-- filename/lnum (and the text summary unchanged); grep's glob /
-- case_insensitive / fixed_string / context parameters (and context lines
-- staying out of the quickfix list); diagnostics {quickfix=true}
-- landing seeded diagnostics in the list (and leaving it untouched without the
-- flag); bulk_replace editing every file in a seeded quickfix list (undoably,
-- with a file count) via :cdo; its dry_run and empty-list paths.

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

case("grep populates the quickfix list with correct filename + lnum", function()
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

case("grep glob restricts to matching files; case_insensitive widens the match", function()
  local dir = grep_param_dir()
  local out = grep({ pattern = "needle", path = dir, glob = "*.lua", case_insensitive = true })
  assert(out:find("a.lua", 1, true), "expected a.lua match:\n" .. out)
  assert(not out:find("b.txt", 1, true), "glob '*.lua' should exclude b.txt:\n" .. out)
end)

case("grep is case-sensitive by default", function()
  local dir = grep_param_dir()
  local out = grep({ pattern = "needle", path = dir, glob = "*.lua" })
  assert(out == "no matches",
    "'needle' should not match 'Needle' without case_insensitive, got:\n" .. out)
end)

case("grep fixed_string matches metacharacters literally", function()
  local dir = grep_param_dir()
  -- As a regex, 'dot.star' would also match e.g. 'dotXstar'; as a fixed
  -- string it must match c.lua's literal 'dot.star' (and it must not be
  -- rejected as a bad pattern).
  local out = grep({ pattern = "dot.star", path = dir, fixed_string = true })
  assert(out:find("c.lua", 1, true), "fixed_string match missing:\n" .. out)
end)

case("grep context shows surrounding lines but keeps them out of the quickfix list", function()
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

case("diagnostics {quickfix=true} lands diagnostics in the qf list; off leaves it", function()
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

case("bulk_replace edits every file in the quickfix list (undoably) + reports count", function()
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

case("bulk_replace dry_run reports the would-edit count and changes nothing", function()
  local f1, f2 = seed_two_files()
  local out = registry.call("tool.bulk_replace",
    { pattern = "FOO", replacement = "BAR", dry_run = true }, { bufnr = 0 })

  assert(out:find("dry_run", 1, true), "expected a dry_run report, got:\n" .. out)
  assert(out:find("2 file", 1, true), "dry_run should report 2 files, got:\n" .. out)
  assert(read_file(f1):find("FOO", 1, true), "dry_run changed f1 on disk")
  assert(read_file(f2):find("FOO", 1, true), "dry_run changed f2 on disk")
  assert(not read_file(f1):find("BAR", 1, true), "dry_run wrote BAR into f1")
end)

case("bulk_replace with an empty quickfix list returns the error string", function()
  vim.fn.setqflist({}, "r") -- empty it
  local out = registry.call("tool.bulk_replace",
    { pattern = "FOO", replacement = "BAR" }, { bufnr = 0 })
  assert(out == "findings list is empty — run grep first to populate it",
    "unexpected empty-list message: " .. tostring(out))
end)

case("bulk_replace rejects Ex command separators in user-controlled fragments", function()
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

case("bulk_replace is NOT in hook.confirm's auto-allow set (it is a write)", function()
  -- read-only editor/search tools auto-allow (return true); bulk_replace must
  -- fall through to a prompt. Headless, vim.fn.confirm returns 0 -> denied.
  local allowed = registry.call("hook.confirm", "bulk_replace", { pattern = "a", replacement = "b" }, { bufnr = 0 })
  assert(allowed ~= true, "bulk_replace must not be auto-allowed by hook.confirm")
end)

-- ---------------------------------------------------------- session isolation

-- Two on-screen sessions must not stomp each other's findings list: each
-- session's grep goes to ITS window's location list, and bulk_replace on that
-- session edits only that session's files — never the global quickfix list.
case("concurrent sessions get isolated per-window findings lists", function()
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

  -- Each session sets its own findings list (as grep/set_quickfix do).
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

-- Windowless session (a subagent): falls back to the global quickfix list,
-- which is the pre-existing behavior (no worse than before).
case("windowless session falls back to the global quickfix list", function()
  local state = require("straps.state")
  vim.cmd("only")
  local s = state.new_session()
  -- Do NOT show it in any window.
  local ui = require("straps.ui")
  assert(ui.session_win(s) == nil, "expected no window for the hidden session")
  local kind = ui.set_locations(s, { title = "fallback",
    items = { { filename = "/tmp/x", lnum = 1, text = "y" } } }, false)
  assert(kind == "quickfix", "windowless session should use the global quickfix list")
  assert(vim.fn.getqflist({ title = 1 }).title == "fallback", "global list not set")
end)

print(failed and "FAILED" or "ALL PASS")
os.exit(failed and 1 or 0)
