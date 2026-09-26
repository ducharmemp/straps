-- Durable session tests: file-backed transcripts (state.session_dir / persist /
-- list_sessions / open_session_file), the new_session file-backing + ephemeral
-- fallback, and ui.resume_session. Fully hermetic — config.session_dir points
-- at a throwaway dir, so nothing touches the real data dir.
-- Run: busted tests/session_file_spec.lua

-- :p makes root absolute so a cwd-relative package.path can't break mid-test.
local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(here, ":p:h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

-- Runs `fn` at test time, in document order with the surrounding `it`s (the
-- old runner executed cases inline; busted collects first, then runs).
local function step(fn)
  local info = debug.getinfo(fn, "S")
  describe("step@" .. info.short_src .. ":" .. info.linedefined, function() setup(fn) end)
end


local straps = require("straps")
local state = require("straps.state")
-- Hermetic session dir; register the real provider so new_session uses the
-- real fn.system_prompt (new_session also has a fallback prompt if absent).
straps.config.session_dir = vim.fn.tempname()

-- Before the real provider registers, the registry is bare: this exercises
-- new_session's built-in fallback prompt.
local function case_fallback()
  local bufnr = require("straps.state").new_session()
  local parsed = require("straps.state").parse(bufnr)
  assert(parsed.system:find("You are Cinch, a coding agent running inside Neovim", 1, true),
    "fallback system prompt missing the Cinch identity line")
end
it("new_session falls back to the built-in identity line without fn.system_prompt", case_fallback)

step(function()
  require("straps.provider").register()
end)

local function read_file(path)
  local f = assert(io.open(path, "r"))
  local text = f:read("*a")
  f:close()
  return text
end

-- ------------------------------------------------- new_session writes a file
it("new_session writes a real file whose content == the buffer + system marker", function()
  local bufnr = state.new_session()
  local path = vim.api.nvim_buf_get_name(bufnr)
  assert(path:match("%.straps$"), "session buffer is not file-backed: " .. path)
  assert(vim.bo[bufnr].buftype == "", "durable session must have buftype=='' , got " .. vim.bo[bufnr].buftype)
  assert(vim.fn.filereadable(path) == 1, "session file not written to disk: " .. path)
  local disk = read_file(path)
  local buftext = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  assert(disk == buftext or disk == buftext .. "\n",
    "on-disk content differs from buffer lines")
  assert(disk:find("%%[straps:system]%%", 1, true), "system marker missing on disk")
end)

-- ---------------------------------------------------------- append persists
it("append persists a user block to disk", function()
  local bufnr = state.new_session()
  state.append(bufnr, "user", nil, "hello-from-disk-please")
  local disk = read_file(vim.api.nvim_buf_get_name(bufnr))
  assert(disk:find("hello-from-disk-please", 1, true), "appended text not persisted to disk")
end)

-- --------------------------------------------------- list_sessions ordering
it("list_sessions returns sessions, newest first", function()
  local saved = straps.config.session_dir
  -- Isolated so only A + B appear. Pre-create and canonicalize the dir:
  -- buffer names come back canonicalized (macOS /var -> /private/var) and
  -- the membership check below compares path strings.
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  straps.config.session_dir = assert(vim.uv.fs_realpath(dir))
  local a = state.new_session()
  local b = state.new_session()
  local pa, pb = vim.api.nvim_buf_get_name(a), vim.api.nvim_buf_get_name(b)
  local list = state.list_sessions()
  straps.config.session_dir = saved

  local paths = {}
  for _, s in ipairs(list) do
    paths[s.path] = true
  end
  assert(paths[pa], "session A missing from list_sessions")
  assert(paths[pb], "session B missing from list_sessions")

  local ma, mb = vim.fn.getftime(pa), vim.fn.getftime(pb)
  if ma ~= mb then
    assert(list[1].path == (mb > ma and pb or pa), "list_sessions not newest-first")
  else
    print("      note: A and B share getftime (1s resolution) — asserting set membership only")
  end
end)

-- ----------------------------------------------- open_session_file reloads
it("open_session_file reloads a written transcript, parse matches original", function()
  local bufnr = state.new_session()
  state.append(bufnr, "user", nil, "reload-check-content")
  local path = vim.api.nvim_buf_get_name(bufnr)
  local orig = state.parse(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  local re = state.open_session_file(path)
  assert(vim.b[re].straps_session == true, "reloaded buffer missing straps_session flag")
  assert(vim.bo[re].filetype == "straps", "reloaded buffer filetype != straps")
  assert(vim.deep_equal(state.parse(re), orig), "reparsed messages differ from original")
end)

-- --------------------------------------------------- wipe -> reopen resume
it("wipe -> reopen round-trip preserves the transcript", function()
  local bufnr = state.new_session()
  state.append(bufnr, "user", nil, "resume-me")
  local path = vim.api.nvim_buf_get_name(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  local re = state.open_session_file(path)
  local found = false
  for _, m in ipairs(state.parse(re).messages) do
    if m.role == "user" then
      for _, c in ipairs(m.content) do
        if type(c.text) == "string" and c.text:find("resume-me", 1, true) then
          found = true
        end
      end
    end
  end
  assert(found, "user message 'resume-me' not recovered after wipe + reopen")
end)

-- ---------------------------------------- unwritable session_dir fallback
it("new_session falls back to an ephemeral buffer when session_dir is unwritable", function()
  local saved = straps.config.session_dir
  local tmpfile = vim.fn.tempname()
  local f = assert(io.open(tmpfile, "w"))
  f:write("x")
  f:close()
  -- mkdir -p must fail: a path component (tmpfile) is a regular file.
  straps.config.session_dir = tmpfile .. "/sub"
  local ok, bufnr = pcall(state.new_session)
  straps.config.session_dir = saved

  assert(ok, "new_session threw instead of falling back: " .. tostring(bufnr))
  assert(bufnr and vim.api.nvim_buf_is_valid(bufnr), "no valid fallback buffer")
  assert(vim.bo[bufnr].buftype == "nofile", "fallback should be an ephemeral nofile buffer")
  local parsed = state.parse(bufnr)
  assert(parsed.system and parsed.system ~= "", "fallback buffer missing system content")
  assert(state.last_user_text(bufnr) ~= nil, "fallback buffer missing trailing user block")
end)

-- ------------------------------------------------- persist no-op on scratch
it("persist is a no-op (no error) on a plain scratch buffer", function()
  local scratch = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(scratch, 0, -1, false, { "just a scratch buffer" })
  local ok, err = pcall(state.persist, scratch)
  assert(ok, "persist threw on a scratch buffer: " .. tostring(err))
end)

-- ------------------------------------------------- ui.resume_session(path)
it("ui.resume_session(path) rebuilds the stack with the transcript content", function()
  local bufnr = state.new_session()
  state.append(bufnr, "user", nil, "ui-resume-content-xyz")
  local path = vim.api.nvim_buf_get_name(bufnr)
  local re = require("straps.ui").resume_session(path)
  assert(re and vim.api.nvim_buf_is_valid(re), "resume_session returned an invalid buffer")
  local text = table.concat(vim.api.nvim_buf_get_lines(re, 0, -1, false), "\n")
  assert(text:find("ui-resume-content-xyz", 1, true), "resumed transcript missing its content")
end)

it("ui.resume_session heals a transcript interrupted mid-tool", function()
  -- persist() runs at block boundaries, so a session whose Neovim died while a
  -- tool was in flight is on disk with a tool_use and no tool_result — a shape
  -- the API rejects. Resuming must repair it, or the resumed session cannot be
  -- sent at all.
  local bufnr = state.new_session()
  state.append(bufnr, "user", nil, "resume-heal-content")
  state.append(bufnr, "tool_use", { id = "z1", name = "bash" }, '{"command":"sleep 99"}')
  local path = vim.api.nvim_buf_get_name(bufnr)
  state.persist(bufnr)
  -- Wipe the buffer so resume_session reloads from the file, as a restart would.
  vim.api.nvim_buf_delete(bufnr, { force = true })

  local re = require("straps.ui").resume_session(path)
  local uses, results = 0, 0
  for _, m in ipairs(state.parse(re).messages) do
    for _, part in ipairs(m.content) do
      if part.type == "tool_use" then uses = uses + 1 end
      if part.type == "tool_result" then results = results + 1 end
    end
  end
  assert(uses == 1 and results == 1,
    "resumed transcript still unpaired: " .. uses .. " uses, " .. results .. " results")
  local parsed = state.parse(re)
  assert(parsed.messages[#parsed.messages].role == "user",
    "resumed transcript must not end on an assistant message (unsendable)")
  local text = table.concat(vim.api.nvim_buf_get_lines(re, 0, -1, false), "\n")
  assert(text:find("resume-heal-content", 1, true), "healing lost the original user message")
  -- The repair must reach the FILE, not just the buffer: the point is that the
  -- next restart resumes a sendable transcript, and heal's appends persist.
  local on_disk = table.concat(vim.fn.readfile(path), "\n")
  assert(on_disk:find("run interrupted before this tool finished", 1, true),
    "the healed result was not persisted to the transcript file")
end)

-- ------------------------------------------------------- ui.pick_session
it("ui.pick_session offers list_sessions() items and resumes the picked one", function()
  local saved = straps.config.session_dir
  -- Isolated so only this session appears. Pre-create and canonicalize the
  -- dir (macOS /var -> /private/var, see the list_sessions case) so the
  -- stub's path comparison can actually match and exercise the resume branch.
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  straps.config.session_dir = assert(vim.uv.fs_realpath(dir))
  local bufnr = state.new_session()
  state.append(bufnr, "user", nil, "pick-session-content-abc")
  local path = vim.api.nvim_buf_get_name(bufnr)

  local ui = require("straps.ui")
  local real_pick = ui.pick
  -- Force the plain vim.ui.select path so this stub is the picker under test
  -- (a preview-capable snacks picker may be on the rtp even headless).
  local real_rich = ui._pick_session_rich
  ui._pick_session_rich = function() return false end
  local seen_items, picked
  ui.pick = function(items, opts, on_choice)
    seen_items = items
    for _, s in ipairs(items) do
      if s.path == path then
        picked = s
        return on_choice(s)
      end
    end
    on_choice(nil)
  end
  local ok, err = pcall(ui.pick_session)
  ui.pick = real_pick
  ui._pick_session_rich = real_rich
  straps.config.session_dir = saved
  if not ok then
    error(err, 0)
  end

  assert(seen_items and #seen_items >= 1, "pick_session did not offer list_sessions() items")
  assert(picked, "list_sessions never offered the created session")
  local cur = vim.api.nvim_get_current_buf()
  assert(vim.api.nvim_buf_get_name(cur) == path,
    "current window does not show the resumed session")
  local text = table.concat(vim.api.nvim_buf_get_lines(cur, 0, -1, false), "\n")
  assert(text:find("pick-session-content-abc", 1, true), "resumed transcript missing its content")
end)

it("ui.pick_session falls back to open_session when there are no saved sessions", function()
  local saved = straps.config.session_dir
  straps.config.session_dir = vim.fn.tempname() -- empty dir: never populated
  vim.fn.mkdir(straps.config.session_dir, "p")

  local ui = require("straps.ui")
  local real_pick = ui.pick
  local pick_called = false
  ui.pick = function(_, _, on_choice)
    pick_called = true
    on_choice(nil)
  end
  local ok, bufnr = pcall(ui.pick_session)
  ui.pick = real_pick
  straps.config.session_dir = saved

  assert(ok, "pick_session threw: " .. tostring(bufnr))
  assert(not pick_called, "pick_session should not open a picker with zero saved sessions")
  assert(bufnr and vim.api.nvim_buf_is_valid(bufnr), "pick_session fallback did not return a valid buffer")
end)

-- ------------------------------------------- session_summary = first prompt
it("session_summary returns the first user prompt when no title is set", function()
  local bufnr = state.new_session()
  state.append(bufnr, "user", nil, "how do I search sessions?\nsecond line ignored")
  local path = vim.api.nvim_buf_get_name(bufnr)
  local summary = state.session_summary(path)
  assert(summary and summary:find("how do I search sessions", 1, true),
    "summary did not surface the first user prompt: " .. tostring(summary))
end)

it("session_summary is nil for a transcript with no user prompt yet", function()
  -- new_session appends a trailing EMPTY user block; that must not count.
  local bufnr = state.new_session()
  local path = vim.api.nvim_buf_get_name(bufnr)
  assert(state.session_summary(path) == nil,
    "empty trailing user block should yield no summary, got: " .. tostring(state.session_summary(path)))
end)

-- --------------------------------------------- durable titles (.meta files)
it("set_session_title / session_title round-trip via the companion .meta file", function()
  local bufnr = state.new_session()
  local path = vim.api.nvim_buf_get_name(bufnr)
  assert(state.session_title(path) == nil, "fresh session should have no title")
  assert(state.set_session_title(path, "My named session"), "set_session_title failed")
  assert(vim.fn.filereadable(path .. ".meta") == 1, "companion .meta file not written")
  assert(state.session_title(path) == "My named session", "title did not round-trip")
  -- Title wins over the first-prompt summary.
  state.append(bufnr, "user", nil, "an actual prompt")
  assert(state.session_summary(path) == "My named session",
    "session_summary should prefer the durable title over the prompt")
  -- Clearing removes the .meta file.
  assert(state.set_session_title(path, ""), "clearing title failed")
  assert(state.session_title(path) == nil, "title not cleared")
  assert(vim.fn.filereadable(path .. ".meta") == 0, ".meta file should be removed on clear")
end)

-- --------------------------------------------------- list_sessions summaries
it("list_sessions carries a per-session summary field", function()
  local savedir = straps.config.session_dir
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  straps.config.session_dir = assert(vim.uv.fs_realpath(dir))
  local b = state.new_session()
  state.append(b, "user", nil, "unique-summary-marker-42")
  local list = state.list_sessions()
  straps.config.session_dir = savedir
  local found
  for _, s in ipairs(list) do
    if s.summary and s.summary:find("unique-summary-marker-42", 1, true) then
      found = true
    end
  end
  assert(found, "list_sessions did not carry the first-prompt summary")
end)

-- --------------------------------------------------------- ui.rename_session
it("ui.rename_session with an explicit title writes it", function()
  local bufnr = state.new_session()
  local path = vim.api.nvim_buf_get_name(bufnr)
  require("straps.ui").rename_session(bufnr, "explicit title here")
  assert(state.session_title(path) == "explicit title here",
    "rename_session did not persist the explicit title")
end)

-- ---------------------------------------------------------- ui.grep_sessions
it("ui.grep_sessions loads content matches into the quickfix list", function()
  local savedir = straps.config.session_dir
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  straps.config.session_dir = assert(vim.uv.fs_realpath(dir))
  local b = state.new_session()
  state.append(b, "user", nil, "please find the needle xyzzy here")
  state.append(b, "assistant", nil, "unrelated content")
  local n = require("straps.ui").grep_sessions("xyzzy")
  local qf = vim.fn.getqflist({ title = 1, items = 1 })
  straps.config.session_dir = savedir

  assert(n >= 1, "grep_sessions found no matches for a known needle")
  assert(qf.title:find("xyzzy", 1, true), "quickfix title missing the pattern: " .. tostring(qf.title))
  local hit
  for _, it in ipairs(qf.items) do
    if it.text and it.text:find("xyzzy", 1, true) then hit = it end
  end
  assert(hit, "quickfix items missing the matching line")
end)

it("ui.grep_sessions skips transcript marker lines", function()
  local savedir = straps.config.session_dir
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  straps.config.session_dir = assert(vim.uv.fs_realpath(dir))
  local b = state.new_session()
  state.append(b, "user", nil, "some ordinary content")
  -- "straps:user" appears on every user marker line; a naive grep would hit
  -- the scaffolding. grep_sessions must skip marker lines.
  local n = require("straps.ui").grep_sessions("straps:user")
  straps.config.session_dir = savedir
  assert(n == 0, "grep_sessions matched transcript marker lines (should skip them): " .. n)
end)

it("relative_time buckets ages sensibly", function()
  local rt = require("straps.ui")._relative_time
  local now = os.time()
  assert(rt(now) == "just now", "0s should be 'just now'")
  assert(rt(now - 300):find("m ago"), "5m should be minutes")
  assert(rt(now - 7200):find("h ago"), "2h should be hours")
  assert(rt(now - 3 * 86400):find("d ago"), "3d should be days")
  assert(rt(now - 30 * 86400):match("%d%d%d%d%-"), "30d should be an absolute date")
end)
