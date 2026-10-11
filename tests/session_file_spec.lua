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

local function with_ui(body)
  return body(require("straps.ui"))
end

local straps = require("straps")
local state = require("straps.state")
-- Hermetic session dir; register the real provider so new_session uses the
-- real fn.system_prompt (new_session also has a fallback prompt if absent).
straps.config.session_dir = vim.fn.tempname()
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

-- --------------------------------------------------------------- fsync=false
it("session buffers set buffer-local fsync=false on nvim >= 0.12 without touching the global", function()
  local saved_fsync = vim.o.fsync
  local bufnr = state.new_session()
  assert(vim.bo[bufnr].buftype == "", "new_session must stay file-backed")
  if vim.fn.has("nvim-0.12") == 1 then
    assert(vim.bo[bufnr].fsync == false, "new_session must set buffer-local fsync=false")
    local re = state.open_session_file(vim.api.nvim_buf_get_name(bufnr))
    assert(vim.bo[re].fsync == false, "open_session_file must set buffer-local fsync=false")
    assert(vim.o.fsync == saved_fsync, "global fsync must be unchanged")
  else
    print("nvim < 0.12: fsync assertions skipped")
  end
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
  with_ui(function(ui)
    local bufnr = state.new_session()
    state.append(bufnr, "user", nil, "ui-resume-content-xyz")
    local path = vim.api.nvim_buf_get_name(bufnr)
    local re = ui.resume_session(path)
    assert(re and vim.api.nvim_buf_is_valid(re), "resume_session returned an invalid buffer")
    local text = table.concat(vim.api.nvim_buf_get_lines(re, 0, -1, false), "\n")
    assert(text:find("ui-resume-content-xyz", 1, true), "resumed transcript missing its content")
  end)
end)

it("ui.resume_session heals a transcript interrupted mid-tool", function()
  with_ui(function(ui)
    local bufnr = state.new_session()
    state.append(bufnr, "user", nil, "resume-heal-content")
    state.append(bufnr, "tool_use", { id = "z1", name = "bash" }, '{"command":"sleep 99"}')
    local path = vim.api.nvim_buf_get_name(bufnr)
    state.persist(bufnr)
    vim.api.nvim_buf_delete(bufnr, { force = true })

    local re = ui.resume_session(path)
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
    local on_disk = table.concat(vim.fn.readfile(path), "\n")
    assert(on_disk:find("run interrupted before this tool finished", 1, true),
      "the healed result was not persisted to the transcript file")
  end)
end)

-- ------------------------------------------------------- ui.pick_session
it("ui.pick_session offers list_sessions() items and resumes the picked one", function()
  with_ui(function(ui)
    local saved = straps.config.session_dir
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    straps.config.session_dir = assert(vim.uv.fs_realpath(dir))
    local bufnr = state.new_session()
    state.append(bufnr, "user", nil, "pick-session-content-abc")
    local path = vim.api.nvim_buf_get_name(bufnr)

    local real_pick = ui.pick
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
end)

it("ui.pick_session falls back to open_session when there are no saved sessions", function()
  with_ui(function(ui)
    local saved = straps.config.session_dir
    straps.config.session_dir = vim.fn.tempname()
    vim.fn.mkdir(straps.config.session_dir, "p")

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
end)

-- ---------------------------------------------------------- ui.grep_sessions
it("ui.grep_sessions loads content matches into the quickfix list", function()
  with_ui(function(ui)
    local savedir = straps.config.session_dir
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    straps.config.session_dir = assert(vim.uv.fs_realpath(dir))
    local b = state.new_session()
    state.append(b, "user", nil, "please find the needle xyzzy here")
    state.append(b, "assistant", nil, "unrelated content")
    local n = ui.grep_sessions("xyzzy")
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
end)

it("ui.grep_sessions skips transcript marker lines", function()
  with_ui(function(ui)
    local savedir = straps.config.session_dir
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    straps.config.session_dir = assert(vim.uv.fs_realpath(dir))
    local b = state.new_session()
    state.append(b, "user", nil, "some ordinary content")
    local n = ui.grep_sessions("straps:user")
    straps.config.session_dir = savedir
    assert(n == 0, "grep_sessions matched transcript marker lines (should skip them): " .. n)
  end)
end)

-- ------------------------------------------- session_summary behavior
it("session_summary caches and hits on a second call to the same path", function()
  local bufnr = state.new_session()
  state.append(bufnr, "user", nil, "cache-hit-one\ncache-hit-two")
  local path = vim.api.nvim_buf_get_name(bufnr)
  state.clear_session_summary_cache()
  local s1 = state.session_summary(path)
  local s2 = state.session_summary(path)
  local st = state._session_summary_cache_stats()
  assert(s1 and s2 and s2:find("cache-hit-two", 1, true), "multiline prompt should be collapsed, not truncated")
  assert(st.hits >= 1, "second call should hit the cache")
end)

it("session_summary returns the first user prompt when no title is set", function()
  local bufnr = state.new_session()
  state.append(bufnr, "user", nil, "how do I search sessions?\nsecond line included")
  local path = vim.api.nvim_buf_get_name(bufnr)
  local summary = state.session_summary(path)
  assert(summary and summary:find("how do I search sessions%? second line included"),
    "summary did not surface the full first user prompt: " .. tostring(summary))
end)

it("session_summary is nil for a transcript with no user prompt yet", function()
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
  state.append(bufnr, "user", nil, "an actual prompt")
  assert(state.session_summary(path) == "My named session",
    "session_summary should prefer the durable title over the prompt")
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
  with_ui(function(ui)
    local bufnr = state.new_session()
    local path = vim.api.nvim_buf_get_name(bufnr)
    ui.rename_session(bufnr, "explicit title here")
    assert(state.session_title(path) == "explicit title here",
      "rename_session did not persist the explicit title")
  end)
end)

-- ---------------------------------------- streaming: stops early and closes on error
it("session_summary streams only until the next marker and closes the file", function()
  local tmp = vim.fn.tempname() .. ".straps"
  local lines = {
    "%%[straps:system]%%", "sys", "",
    "%%[straps:user]%%", "the prompt here", "second line included",
    "%%[straps:assistant]%%", "assistant body", "TAIL-1", "TAIL-2",
  }
  vim.fn.writefile(lines, tmp)

  local real_open = io.open
  local opened, reads, closed = 0, 0, 0
  io.open = function(path, mode)
    if path ~= tmp then return real_open(path, mode) end
    opened = opened + 1
    local i = 0
    local obj = {}
    function obj:lines()
      return function()
        i = i + 1
        if i <= #lines then reads = reads + 1; return lines[i] end
        return nil
      end
    end
    function obj:close() closed = closed + 1 end
    return obj
  end

  state.clear_session_summary_cache()
  local sum = state.session_summary(tmp)
  io.open = real_open

  assert(sum == "the prompt here second line included", "summary did not reflect the first user prompt: " .. tostring(sum))
  assert(reads == 7, "stream did not stop at next marker; reads= " .. reads)
  assert(closed == 1 and opened == 1, "file not closed exactly once; opened=" .. opened .. " closed=" .. closed)
end)

it("session_summary closes the file when streaming errors", function()
  local tmp = vim.fn.tempname() .. ".straps"
  local lines = { "%%[straps:system]%%", "sys", "", "%%[straps:user]%%", "prefix", "RAISEERR", "suffix" }
  vim.fn.writefile(lines, tmp)
  local real_open = io.open
  local closed = 0
  io.open = function(path, mode)
    if path ~= tmp then return real_open(path, mode) end
    local i = 0
    local obj = {}
    function obj:lines()
      return function()
        i = i + 1
        if i > #lines then return nil end
        if lines[i] == "RAISEERR" then error("boom") end
        return lines[i]
      end
    end
    function obj:close() closed = closed + 1 end
    return obj
  end

  local ok, res = pcall(state.session_summary, tmp)
  io.open = real_open
  assert(ok and res == nil, "error during streaming should yield nil summary")
  assert(closed == 1, "file must be closed when streaming errors")
end)

-- ---------------------------------------- meta edits/removals and same-size titles
it("session_summary tracks external .meta edits/removals and same-size title changes", function()
  local b = state.new_session()
  local path = vim.api.nvim_buf_get_name(b)
  state.append(b, "user", nil, "first")
  local mp = path .. ".meta"
  vim.fn.writefile({ vim.json.encode({ title = "Alpha" }) }, mp)
  state.clear_session_summary_cache()
  assert(state.session_summary(path) == "Alpha", "external .meta title should be read")

  vim.fn.writefile({ vim.json.encode({ title = "Bravo" }) }, mp)
  assert(state.session_summary(path) == "Bravo", "same-size .meta change must refresh via times")

  os.remove(mp)
  local sum = state.session_summary(path)
  assert(sum == "first", "removing .meta should fall back to prompt; got " .. tostring(sum))
end)

-- ---------------------------------------- inline prompt on marker line
it("session_summary uses inline text on a user marker plus body lines as the first prompt", function()
  local tmp = vim.fn.tempname() .. ".straps"
  local lines = {
    "%%[straps:system]%%", "sys",
    "%%[straps:user]%% inline-here", "and body",
    "%%[straps:assistant]%%", "tail",
  }
  vim.fn.writefile(lines, tmp)
  state.clear_session_summary_cache()
  local sum = state.session_summary(tmp)
  assert(sum == "inline-here and body", "inline+body should be used; got " .. tostring(sum))
end)

-- ------------------------------------------- list_sessions exclude + pruning
it("list_sessions excludes before summary and prunes vanished cache entries under the current dir", function()
  local savedir = straps.config.session_dir
  local dirA = vim.fn.tempname(); vim.fn.mkdir(dirA, "p"); dirA = assert(vim.uv.fs_realpath(dirA))
  local dirB = vim.fn.tempname(); vim.fn.mkdir(dirB, "p"); dirB = assert(vim.uv.fs_realpath(dirB))

  straps.config.session_dir = dirA
  state.clear_session_summary_cache()
  local a1 = state.new_session(); state.append(a1, "user", nil, "A-one"); local pA1 = vim.api.nvim_buf_get_name(a1)
  local a2 = state.new_session(); state.append(a2, "user", nil, "A-two"); local pA2 = vim.api.nvim_buf_get_name(a2)
  assert(state.session_summary(pA1) and state.session_summary(pA2))

  straps.config.session_dir = dirB
  local b1 = state.new_session(); state.append(b1, "user", nil, "B-one"); local pB1 = vim.api.nvim_buf_get_name(b1)
  assert(state.session_summary(pB1))

  straps.config.session_dir = dirA
  state.clear_session_summary_cache()
  local ex = {}; ex[pA1] = true
  local list = state.list_sessions({ exclude = ex })
  local seen = {}; for _, s in ipairs(list) do seen[s.path] = true end
  assert(seen[pA2] and not seen[pA1], "excluded path should be omitted from list")
  local st = state._session_summary_cache_stats()
  assert(st.size == 1, "excluded entry must not populate cache (only one remaining computed)")

  assert(os.remove(pA2))
  local before = state._session_summary_cache_stats()
  _ = state.list_sessions()
  local after = state._session_summary_cache_stats()
  assert(after.prunes == before.prunes + 1 or after.size == (before.size - 1),
    "list_sessions should prune vanished entries under the current dir")

  straps.config.session_dir = savedir
end)

-- ------------------------------------------- relative_time buckets
it("relative_time buckets ages sensibly", function()
  with_ui(function(ui)
    local rt = ui._relative_time
    local now = os.time()
    assert(rt(now) == "just now", "0s should be 'just now'")
    assert(rt(now - 300):find("m ago"), "5m should be minutes")
    assert(rt(now - 7200):find("h ago"), "2h should be hours")
    assert(rt(now - 3 * 86400):find("d ago"), "3d should be days")
    assert(rt(now - 30 * 86400):match("%d%d%d%d%-"), "30d should be an absolute date")
  end)
end)

-- ------------------------------------------- notice first line = not a prompt
it("session_summary skips a user block whose first non-blank line is a harness/agent notice", function()
  local tmp = vim.fn.tempname() .. ".straps"
  local lines = {
    "%%[straps:system]%%", "sys",
    "%%[straps:user]%%", "[straps] Multiplayer: hello", "but this is body text",
    "%%[straps:assistant]%%", "tail",
  }
  vim.fn.writefile(lines, tmp)
  state.clear_session_summary_cache()
  local sum = state.session_summary(tmp)
  assert(sum == nil, "notice-looking first line must not count as a prompt; got " .. tostring(sum))
end)

-- ------------------------------------------- cache key: abs and rel are same
it("session_summary caches by absolute path (rel and abs hit the same entry)", function()
  local b = state.new_session()
  state.append(b, "user", nil, "absrel-one\nabsrel-two")
  local abs = vim.api.nvim_buf_get_name(b)
  local rel = vim.fn.fnamemodify(abs, ":.")
  state.clear_session_summary_cache()
  local _ = state.session_summary(abs)
  local _ = state.session_summary(rel)
  local st = state._session_summary_cache_stats()
  assert(st.size == 1 and st.hits >= 1, "abs+rel should share one cache entry; stats=" .. vim.inspect(st))
end)
it("session_summary does not re-open the transcript on a cache hit", function()
  local tmp = vim.fn.tempname() .. ".straps"
  local lines = {
    "%%[straps:system]%%", "sys", "",
    "%%[straps:user]%%", "first line", "second line",
  }
  vim.fn.writefile(lines, tmp)
  state.clear_session_summary_cache()
  local real_open = io.open
  local opened = 0
  io.open = function(path, mode)
    if path == tmp then opened = opened + 1 end
    return real_open(path, mode)
  end
  _ = state.session_summary(tmp)
  _ = state.session_summary(tmp)
  io.open = real_open
  assert(opened == 1, "io.open called on cache hit; opened=" .. opened)
end)

it("session_summary caches title and avoids re-reading .meta on a hit", function()
  local tmp = vim.fn.tempname() .. ".straps"
  local mp = tmp .. ".meta"
  vim.fn.writefile({"%%[straps:system]%%", "sys", "", "%%[straps:user]%%", "body"}, tmp)
  vim.fn.writefile({ vim.json.encode({ title = "CachedTitle" }) }, mp)
  state.clear_session_summary_cache()
  local real_readfile = vim.fn.readfile
  local reads = 0
  vim.fn.readfile = function(path)
    if path == mp then reads = reads + 1 end
    return real_readfile(path)
  end
  local s1 = state.session_summary(tmp)
  local s2 = state.session_summary(tmp)
  vim.fn.readfile = real_readfile
  assert(s1 == "CachedTitle" and s2 == "CachedTitle", "summary should use durable title; got " .. tostring(s1) .. ", " .. tostring(s2))
  assert(reads == 1, ".meta was re-read on cache hit; reads=" .. reads)
end)

it("session_summary refreshes when transcript content changes with same byte size", function()
  local tmp = vim.fn.tempname() .. ".straps"
  vim.fn.writefile({
    "%%[straps:system]%%", "sys", "",
    "%%[straps:user]%%", "alpha"
  }, tmp)
  state.clear_session_summary_cache()
  local a = state.session_summary(tmp)
  assert(a == "alpha", "precondition failed: got " .. tostring(a))
  vim.fn.writefile({
    "%%[straps:system]%%", "sys", "",
    "%%[straps:user]%%", "omega"
  }, tmp)
  local b = state.session_summary(tmp)
  assert(b == "omega", "summary did not refresh on same-size change; got " .. tostring(b))
end)

it("clear_session_summary_cache forces a re-read on next call", function()
  local tmp = vim.fn.tempname() .. ".straps"
  vim.fn.writefile({
    "%%[straps:system]%%", "sys", "",
    "%%[straps:user]%%", "one two"
  }, tmp)
  state.clear_session_summary_cache()
  local real_open = io.open
  local opened = 0
  io.open = function(path, mode)
    if path == tmp then opened = opened + 1 end
    return real_open(path, mode)
  end
  _ = state.session_summary(tmp)
  state.clear_session_summary_cache()
  _ = state.session_summary(tmp)
  io.open = real_open
  assert(opened == 2, "clear_session_summary_cache should force a fresh read; opened=" .. opened)
end)

it("clearing a durable title switches session_summary back to the first prompt", function()
  local b = state.new_session()
  local path = vim.api.nvim_buf_get_name(b)
  state.append(b, "user", nil, "prompt after title")
  assert(state.set_session_title(path, "KeepMe") and state.session_summary(path) == "KeepMe")
  assert(state.set_session_title(path, ""))
  local sum = state.session_summary(path)
  assert(sum == "prompt after title", "summary did not fall back to prompt after clear; got " .. tostring(sum))
end)

it("session_summary unescapes a body line that looks like a marker", function()
  local tmp = vim.fn.tempname() .. ".straps"
  vim.fn.writefile({
    "%%[straps:system]%%", "sys", "",
    "%%[straps:user]%%", "%%[[esc]]%%[straps:assistant]%% pretend this is text"
  }, tmp)
  state.clear_session_summary_cache()
  local sum = state.session_summary(tmp)
  assert(sum == "%%[straps:assistant]%% pretend this is text", "escaped content not unescaped; got " .. tostring(sum))
end)

it("session_summary skips a notice-looking first line and uses a later real prompt", function()
  local tmp = vim.fn.tempname() .. ".straps"
  vim.fn.writefile({
    "%%[straps:system]%%", "sys", "",
    "%%[straps:user]%%", "[straps] Multiplayer: hello", "still body that should be ignored",
    "%%[straps:user]%%", "second real prompt here"
  }, tmp)
  state.clear_session_summary_cache()
  local sum = state.session_summary(tmp)
  assert(sum == "second real prompt here", "later real prompt should be used; got " .. tostring(sum))
end)
