-- tests/reconcile_spec.lua — concurrent-editor detection: out-of-band disk
-- changes and same-instance sibling-session writes surface to the agent as
-- errors (edits) or notes (reads), never as silent merges or W12 prompts.
--   busted tests/reconcile_spec.lua
-- Topology 1 (disk) is simulated with io.write behind the buffer's back;
-- topology 2 (same instance) with two scratch "session" buffers as ctx.bufnr.

local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(vim.fn.fnamemodify(here, ":p"), ":h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path


-- Isolate any session writes (defensive; these tools don't create sessions).
require("straps").config.session_dir = vim.fn.tempname()

local registry = require("straps.registry")
require("straps.tools").register()
require("straps.editor").register()

-- Two fake "sessions": ordinary loaded scratch-ish buffers standing in for
-- session transcript buffers (check_writer only needs valid bufnrs).
local function make_session(task)
  local b = vim.api.nvim_create_buf(false, true)
  if task then vim.b[b].straps_task = task end
  return b
end

local function bufnr_for(path) return vim.fn.bufnr(vim.fn.fnamemodify(path, ":p")) end
local function buf_text(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end
local function disk_text(path)
  return table.concat(vim.fn.readfile(path), "\n")
end
-- Out-of-band write: directly to disk, behind any loaded buffer's back.
local function disk_write(path, text)
  local f = assert(io.open(path, "w")); f:write(text); f:close()
end

local function tool(name, input, sess)
  return registry.call("tool." .. name, input, { bufnr = sess })
end

-- Fresh file + loaded buffer, read by `sess` so its seen tick is recorded.
local function seed(sess, text)
  local path = vim.fn.tempname() .. ".txt"
  disk_write(path, text)
  tool("read_file", { path = path }, sess)
  return path, bufnr_for(path)
end

-- ------------------------------------------------- disk change, unmodified

it("disk change under an unmodified buffer: edit tools error and the buffer reloads", function()
  local A = make_session()
  for _, name in ipairs({ "write_file", "edit_file", "patch_file" }) do
    local path, buf = seed(A, "orig line\n")
    disk_write(path, "EXTERNAL\n")
    local input = ({
      write_file = { path = path, content = "agent content\n" },
      edit_file = { path = path, old_string = "orig line", new_string = "agent" },
      patch_file = { path = path, hunks = { { start_line = 1, end_line = 1, new_text = "agent" } } },
    })[name]
    local ok, err = pcall(tool, name, input, A)
    assert(not ok, name .. " should error on a disk change")
    assert(tostring(err):find("changed on disk since its buffer was loaded", 1, true),
      name .. " wrong error: " .. tostring(err))
    assert(tostring(err):find("another agent or external process", 1, true),
      name .. " error must name a competing editor: " .. tostring(err))
    -- The reload refreshed the buffer; the failed edit touched nothing.
    assert(buf_text(buf) == "EXTERNAL", name .. ": buffer not reloaded: " .. buf_text(buf))
    assert(disk_text(path) == "EXTERNAL", name .. ": disk clobbered by failed edit: " .. disk_text(path))
  end
end)

it("recovery path: after the error, read then edit succeeds on the new content", function()
  local A = make_session()
  local path, buf = seed(A, "orig\n")
  disk_write(path, "EXTERNAL\n")
  local ok = pcall(tool, "edit_file", { path = path, old_string = "orig", new_string = "x" }, A)
  assert(not ok, "precondition: stale edit should error")
  local read = tool("read_file", { path = path }, A)
  assert(read:find("EXTERNAL", 1, true), "re-read must see the new content: " .. read)
  tool("edit_file", { path = path, old_string = "EXTERNAL", new_string = "EXTERNAL+agent" }, A)
  assert(disk_text(path) == "EXTERNAL+agent", "follow-up edit failed: " .. disk_text(path))
  assert(buf_text(buf) == "EXTERNAL+agent", "buffer mismatch: " .. buf_text(buf))
end)

-- --------------------------------------------------- disk change, modified

it("disk change under a MODIFIED buffer: conflict error, both sides kept", function()
  local A = make_session()
  for _, name in ipairs({ "write_file", "edit_file", "patch_file" }) do
    local path, buf = seed(A, "orig\n")
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "UNSAVED" })
    disk_write(path, "EXTERNAL\n")
    local input = ({
      write_file = { path = path, content = "agent\n" },
      edit_file = { path = path, old_string = "orig", new_string = "agent" },
      patch_file = { path = path, hunks = { { start_line = 1, end_line = 1, new_text = "agent" } } },
    })[name]
    local ok, err = pcall(tool, name, input, A)
    assert(not ok, name .. " should error on a modified-buffer conflict")
    assert(tostring(err):find("unsaved changes", 1, true), name .. " wrong error: " .. tostring(err))
    assert(disk_text(path) == "EXTERNAL", name .. ": disk clobbered: " .. disk_text(path))
    assert(buf_text(buf) == "orig\nUNSAVED", name .. ": unsaved edit lost: " .. buf_text(buf))
  end
end)

-- ------------------------------------------------------- read_file surfaces

it("read_file after a disk change: note + fresh content, no error", function()
  local A = make_session()
  local path = seed(A, "orig\n")
  disk_write(path, "EXTERNAL\n")
  local read = tool("read_file", { path = path }, A)
  assert(read:find("note:", 1, true), "read should carry a note: " .. read)
  assert(read:find("changed on disk", 1, true), "note should say what happened: " .. read)
  assert(read:find("EXTERNAL", 1, true), "read should return the new content: " .. read)
  -- Seen tick was refreshed: an edit right after the read succeeds.
  tool("edit_file", { path = path, old_string = "EXTERNAL", new_string = "ok" }, A)
end)

it("read_file with a modified buffer + disk change: conflict note, buffer content returned", function()
  local A = make_session()
  local path, buf = seed(A, "orig\n")
  vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "UNSAVED" })
  disk_write(path, "EXTERNAL\n")
  local read = tool("read_file", { path = path }, A)
  assert(read:find("note:", 1, true), "read should carry a note: " .. read)
  assert(read:find("unsaved changes", 1, true), "note should describe the conflict: " .. read)
  assert(read:find("UNSAVED", 1, true), "buffer must stay the source of truth: " .. read)
  assert(not read:find("EXTERNAL", 1, true), "conflict read must NOT show disk content: " .. read)
end)

-- ------------------------------------------------------------ deleted file

it("file deleted out-of-band: edit errors with the deletion message", function()
  local A = make_session()
  local path, buf = seed(A, "orig\n")
  os.remove(path)
  local ok, err = pcall(tool, "edit_file", { path = path, old_string = "orig", new_string = "x" }, A)
  assert(not ok, "edit of a deleted file should error")
  assert(tostring(err):find("deleted on disk", 1, true), "wrong error: " .. tostring(err))
  assert(buf_text(buf) == "orig", "buffer should keep last-known content: " .. buf_text(buf))
  assert(vim.fn.filereadable(path) == 0, "failed edit must not recreate the file")
end)

-- ------------------------------------------------- same-instance detection

it("sibling session's write is an error naming that session and task", function()
  local A, B = make_session(), make_session("refactor parser")
  local path = seed(A, "orig\n")
  tool("write_file", { path = path, content = "from B\n" }, B)
  local ok, err = pcall(tool, "edit_file", { path = path, old_string = "from B", new_string = "x" }, A)
  assert(not ok, "A's edit over B's unseen write should error")
  assert(tostring(err):find("modified by another agent", 1, true), "wrong error: " .. tostring(err))
  assert(tostring(err):find("session " .. B, 1, true), "error must name session B: " .. tostring(err))
  assert(tostring(err):find('task: "refactor parser"', 1, true), "error must carry B's task: " .. tostring(err))
  -- Recovery: A reads (note + tick), then edits fine.
  local read = tool("read_file", { path = path }, A)
  assert(read:find("note:", 1, true), "A's re-read should carry a note: " .. read)
  assert(read:find("modified by another agent", 1, true), "note should attribute the change: " .. read)
  tool("edit_file", { path = path, old_string = "from B", new_string = "from B + A" }, A)
  assert(disk_text(path) == "from B + A", "A's post-read edit failed: " .. disk_text(path))
end)

it("sibling session with NO task: error omits the task clause", function()
  local A, B = make_session(), make_session(nil)
  local path = seed(A, "orig\n")
  tool("write_file", { path = path, content = "from B\n" }, B)
  local ok, err = pcall(tool, "edit_file", { path = path, old_string = "from B", new_string = "x" }, A)
  assert(not ok, "A's edit should error")
  assert(tostring(err):find("session " .. B, 1, true), "error must name session B: " .. tostring(err))
  -- Pin the exact clause shape: session number, closing paren, no task text.
  assert(tostring(err):find("(session " .. B .. ")", 1, true),
    "taskless clause should be just the session: " .. tostring(err))
  assert(not tostring(err):find("task:", 1, true), "no task clause when B has no task: " .. tostring(err))
end)

it("edit_file stamps on success: a third session sees the edit as A's", function()
  local A, C = make_session("task A"), make_session()
  local path = seed(A, "orig\n")
  tool("read_file", { path = path }, C) -- C observes the original state
  tool("edit_file", { path = path, old_string = "orig", new_string = "edited by A" }, A)
  local ok, err = pcall(tool, "write_file", { path = path, content = "from C\n" }, C)
  assert(not ok, "C's write over A's unseen edit should error")
  assert(tostring(err):find("session " .. A, 1, true), "error must name session A: " .. tostring(err))
  assert(tostring(err):find('task: "task A"', 1, true), "error must carry A's task: " .. tostring(err))
end)

it("fail-open: writing a file this session never read is not checked", function()
  local A, B = make_session(), make_session()
  local path = seed(B, "orig\n")
  tool("write_file", { path = path, content = "from B\n" }, B)
  -- A never read the file: no seen tick, so no check — write succeeds.
  tool("write_file", { path = path, content = "from A\n" }, A)
  assert(disk_text(path) == "from A", "unseen-file write should succeed: " .. disk_text(path))
end)

-- --------------------------------------- user edits keep stacking (feature)

it("user hand-edit (no stamp): edit stacks on top, no error", function()
  local A = make_session()
  local path, buf = seed(A, "line1\nline2\n")
  -- Unstamped buffer change = user typing (documented live-buffer feature).
  vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "USER-LINE" })
  tool("edit_file", { path = path, old_string = "line2", new_string = "line2-edited" }, A)
  assert(buf_text(buf) == "line1\nline2-edited\nUSER-LINE",
    "edit should stack on the user's unsaved line: " .. buf_text(buf))
end)

it("stale stamp (user edited after a sibling's write): edit stacks, no error", function()
  local A, B = make_session(), make_session()
  local path, buf = seed(A, "orig\n")
  tool("write_file", { path = path, content = "from B\n" }, B)
  -- User keystroke after B's write: tick moves past B's stamp.
  vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "USER-LINE" })
  tool("edit_file", { path = path, old_string = "from B", new_string = "stacked" }, A)
  assert(buf_text(buf) == "stacked\nUSER-LINE",
    "edit should stack over user-masked change: " .. buf_text(buf))
end)

-- ----------------------------------------------------------------- undo_edit

it("undo_edit: disk change is an error in all three write modes; history still lists", function()
  local A = make_session()
  local path, buf = seed(A, "v1\n")
  tool("edit_file", { path = path, old_string = "v1", new_string = "v2" }, A)
  disk_write(path, "EXTERNAL\n")
  -- Iteration 1 detects via checktime; Vim consumes the staleness there, so
  -- iterations 2-3 exercise the remembered (sticky) conflict flag.
  for _, input in ipairs({
    { path = path, steps = 1 },
    { path = path, to_seq = 1 },
    { path = path, revert_seq = 2 },
  }) do
    local res = tool("undo_edit", input, A)
    assert(res:find("another agent or external process", 1, true),
      "undo_edit should refuse: " .. res)
    assert(res:find("undo tree does not include", 1, true), "wrong message: " .. res)
  end
  -- No reload happened (no_reload): buffer keeps its content, tree intact.
  assert(buf_text(buf) == "v2", "buffer must not reload under undo_edit: " .. buf_text(buf))
  local hist = tool("undo_edit", { path = path, history = true }, A)
  assert(hist:find("seq 1", 1, true), "history must still list: " .. hist)
  assert(buf_text(buf) == "v2", "history listing must not mutate: " .. buf_text(buf))
end)

it("sticky conflict: undo_edit's no_reload conflict survives into edit_file, which recovers", function()
  -- Vim consumes checktime staleness once FileChangedShell handles it; the
  -- fn remembers the conflict on the buffer so a LATER tool still sees it.
  local A = make_session()
  local path, buf = seed(A, "v1\n")
  tool("edit_file", { path = path, old_string = "v1", new_string = "v2" }, A)
  disk_write(path, "EXTERNAL\n")
  local res = tool("undo_edit", { path = path, steps = 1 }, A)
  assert(res:find("another agent or external process", 1, true), "undo_edit should refuse: " .. res)
  -- edit_file next: the remembered conflict resolves via a safe reload and
  -- still errors (the edit was computed against stale content).
  local ok, err = pcall(tool, "edit_file", { path = path, old_string = "v2", new_string = "x" }, A)
  assert(not ok, "edit after a remembered conflict should error")
  assert(tostring(err):find("changed on disk", 1, true), "wrong error: " .. tostring(err))
  assert(buf_text(buf) == "EXTERNAL", "safe reload should have re-synced the buffer: " .. buf_text(buf))
  -- Recovery: read then edit works.
  tool("read_file", { path = path }, A)
  tool("edit_file", { path = path, old_string = "EXTERNAL", new_string = "recovered" }, A)
  assert(disk_text(path) == "recovered", "recovery edit failed: " .. disk_text(path))
end)

it("undo_edit: sibling session's write errors with the session-specific message", function()
  local A, B = make_session(), make_session("other work")
  local path = seed(A, "v1\n")
  tool("edit_file", { path = path, old_string = "v1", new_string = "v2" }, A)
  tool("edit_file", { path = path, old_string = "v2", new_string = "v3" }, B)
  local res = tool("undo_edit", { path = path, steps = 1 }, A)
  assert(res:find("another session", 1, true), "should name a sibling session: " .. res)
  assert(res:find("session " .. B, 1, true), "should name session B: " .. res)
  assert(res:find("states are in the undo tree", 1, true), "wrong message: " .. res)
end)

it("undo_edit stamps its write: sibling's next edit errors naming this session", function()
  local A, B = make_session("undoing"), make_session()
  local path = seed(A, "v1\n")
  tool("edit_file", { path = path, old_string = "v1", new_string = "v2" }, A)
  tool("read_file", { path = path }, B) -- B observes v2
  local res = tool("undo_edit", { path = path, steps = 1 }, A)
  assert(res:find("moved from seq", 1, true), "undo should succeed: " .. res)
  local ok, err = pcall(tool, "edit_file", { path = path, old_string = "v1", new_string = "x" }, B)
  assert(not ok, "B's edit over A's unseen undo should error")
  assert(tostring(err):find("session " .. A, 1, true), "error must name session A: " .. tostring(err))
end)

-- ------------------------------------------------------------- regressions

it("no external change, single session: tools behave as before", function()
  local A = make_session()
  local path, buf = seed(A, "one\ntwo\n")
  tool("edit_file", { path = path, old_string = "two", new_string = "TWO" }, A)
  tool("patch_file", { path = path, hunks = { { start_line = 1, end_line = 1, new_text = "ONE" } } }, A)
  tool("write_file", { path = path, content = "rewritten\n" }, A)
  assert(disk_text(path) == "rewritten", "sequential edits should all land: " .. disk_text(path))
  local res = tool("undo_edit", { path = path, steps = 1 }, A)
  assert(res:find("moved from seq", 1, true), "undo_edit should work: " .. res)
  assert(buf_text(buf) == "ONE\nTWO", "undo should restore the patched state: " .. buf_text(buf))
end)

it("timestamp-only change (touch): no error, edit proceeds", function()
  -- Vim reports fcs_reason == "time" when the mtime moved but the content is
  -- identical; that is not a competing editor.
  local A = make_session()
  local path = seed(A, "content\n")
  vim.fn.system({ "touch", "-t", "01010101", path })
  tool("edit_file", { path = path, old_string = "content", new_string = "edited" }, A)
  assert(disk_text(path) == "edited", "edit after touch should land: " .. disk_text(path))
end)

it("file created on disk under a new-file buffer: clear error, no clobber", function()
  -- checktime cannot see never-edited buffers, so this races through to the
  -- write itself; E13 is rewrapped as a competing-editor message.
  local A = make_session()
  local path = vim.fn.tempname() .. ".txt"
  local buf = vim.fn.bufadd(vim.fn.fnamemodify(path, ":p"))
  vim.fn.bufload(buf) -- buffer for a file that does not exist yet
  disk_write(path, "EXTERNAL\n") -- another process creates it
  local ok, err = pcall(tool, "write_file", { path = path, content = "agent\n" }, A)
  assert(not ok, "write over an externally created file should error")
  assert(tostring(err):find("created on disk by another agent or external process", 1, true),
    "wrong error: " .. tostring(err))
  assert(disk_text(path) == "EXTERNAL", "external content clobbered: " .. disk_text(path))
end)

it("minimal ctx (bufnr = 0): tools run without errors, checks fail open", function()
  local ctx0 = { bufnr = 0 }
  local path = vim.fn.tempname() .. ".txt"
  registry.call("tool.write_file", { path = path, content = "a\n" }, ctx0)
  registry.call("tool.edit_file", { path = path, old_string = "a", new_string = "b" }, ctx0)
  registry.call("tool.read_file", { path = path }, ctx0)
  assert(disk_text(path) == "b", "minimal-ctx edits should work: " .. disk_text(path))
end)
