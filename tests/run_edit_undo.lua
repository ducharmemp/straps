-- tests/run_edit_undo.lua — native-undo edits (tool.write_file, tool.edit_file).
--   nvim --headless -l tests/run_edit_undo.lua
-- Proves the reworked write/edit tools apply their change THROUGH the file's
-- buffer as a single undoable step: disk == buffer after a write, an in-buffer
-- `:undo` reverts the whole edit (and redo restores it), the 0-match / >1-match
-- error paths leave the file untouched, replace_all is one undoable step, an
-- already-open buffer with unsaved changes is matched live and stacked on, and
-- hook.after_write still fires into the result.

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
require("straps.tools").register()

-- These tools run entirely on the main loop and never touch ctx.await, so a
-- minimal ctx is enough.
local ctx = { bufnr = 0 }
local function write_file(input) return registry.call("tool.write_file", input, ctx) end
local function edit_file(input) return registry.call("tool.edit_file", input, ctx) end

-- Absolute-path buffer lookup / content helpers.
local function bufnr_for(path) return vim.fn.bufnr(vim.fn.fnamemodify(path, ":p")) end
local function buf_text(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end
local function disk_text(path)
  return table.concat(vim.fn.readfile(path), "\n")
end
local function seed_file(path, text)
  local f = assert(io.open(path, "w")); f:write(text); f:close()
end

-- --------------------------------------------------- write_file creates a file

case("write_file creates a new file: disk matches, buffer loaded, changedtick rose", function()
  local path = vim.fn.tempname() .. ".txt"
  assert(vim.fn.filereadable(path) == 0, "precondition: file should not exist yet")
  local result = write_file({ path = path, content = "alpha\nbeta\ngamma\n" })

  assert(vim.fn.filereadable(path) == 1, "file not created on disk")
  assert(disk_text(path) == "alpha\nbeta\ngamma", "disk content wrong: " .. disk_text(path))

  local buf = bufnr_for(path)
  assert(buf ~= -1, "no buffer exists for the written file")
  assert(vim.api.nvim_buf_is_loaded(buf), "buffer for the file is not loaded")
  assert(buf_text(buf) == "alpha\nbeta\ngamma", "buffer content wrong: " .. buf_text(buf))
  assert(vim.api.nvim_buf_get_changedtick(buf) > 0, "changedtick did not advance")
  assert(vim.bo[buf].modified == false, "buffer should be unmodified after the write")
  assert(result:find("undo with u", 1, true), "result should advertise undoability: " .. result)
  assert(result:find("(3 lines)", 1, true), "result should report 3 lines: " .. result)
end)

-- --------------------------------------- edit_file on an existing file: undo/redo

case("write_file then edit_file: a single in-buffer undo reverts the edit; redo restores", function()
  local path = vim.fn.tempname() .. ".txt"
  write_file({ path = path, content = "one\ntwo\nthree\n" })
  local buf = bufnr_for(path)
  local before = buf_text(buf)
  local tick0 = vim.api.nvim_buf_get_changedtick(buf)

  edit_file({ path = path, old_string = "two", new_string = "TWO-CHANGED" })
  local after = "one\nTWO-CHANGED\nthree"
  assert(buf_text(buf) == after, "buffer not edited: " .. buf_text(buf))
  assert(disk_text(path) == after, "disk not edited: " .. disk_text(path))
  assert(vim.api.nvim_buf_get_changedtick(buf) > tick0, "changedtick did not rise after edit")

  -- One undo must return the WHOLE edit to the pre-edit state (single step).
  vim.api.nvim_buf_call(buf, function() vim.cmd("silent undo") end)
  assert(buf_text(buf) == before, "one undo did not restore pre-edit content: " .. buf_text(buf))

  -- Redo restores the edit.
  vim.api.nvim_buf_call(buf, function() vim.cmd("silent redo") end)
  assert(buf_text(buf) == after, "redo did not restore the edit: " .. buf_text(buf))
end)

-- ----------------------------------------------------- error paths leave file be

case("edit_file 0-match errors and leaves the file unchanged", function()
  local path = vim.fn.tempname() .. ".txt"
  write_file({ path = path, content = "keep me\n" })
  local buf = bufnr_for(path)
  local ok, err = pcall(edit_file, { path = path, old_string = "not present", new_string = "x" })
  assert(not ok, "0-match edit should error")
  assert(tostring(err):find("old_string not found", 1, true), "wrong error: " .. tostring(err))
  assert(disk_text(path) == "keep me", "disk changed on a failed edit: " .. disk_text(path))
  assert(buf_text(buf) == "keep me", "buffer changed on a failed edit: " .. buf_text(buf))
end)

case("edit_file >1-match without replace_all errors and leaves the file unchanged", function()
  local path = vim.fn.tempname() .. ".txt"
  write_file({ path = path, content = "dup\ndup\ndup\n" })
  local buf = bufnr_for(path)
  local ok, err = pcall(edit_file, { path = path, old_string = "dup", new_string = "x" })
  assert(not ok, ">1-match edit should error without replace_all")
  assert(tostring(err):find("matches 3 times", 1, true), "wrong error: " .. tostring(err))
  assert(disk_text(path) == "dup\ndup\ndup", "disk changed on a failed edit: " .. disk_text(path))
  assert(buf_text(buf) == "dup\ndup\ndup", "buffer changed on a failed edit: " .. buf_text(buf))
end)

-- -------------------------------------------- replace_all: one undoable step

case("edit_file replace_all changes every occurrence in one undoable step", function()
  local path = vim.fn.tempname() .. ".txt"
  write_file({ path = path, content = "x foo\ny foo\nz foo\n" })
  local buf = bufnr_for(path)
  local before = buf_text(buf)
  local result = edit_file({ path = path, old_string = "foo", new_string = "BAR", replace_all = true })
  local after = "x BAR\ny BAR\nz BAR"
  assert(buf_text(buf) == after, "replace_all buffer wrong: " .. buf_text(buf))
  assert(disk_text(path) == after, "replace_all disk wrong: " .. disk_text(path))
  assert(result:find("(3 replacements)", 1, true), "result should report 3 replacements: " .. result)

  -- A single undo must revert ALL three replacements at once.
  vim.api.nvim_buf_call(buf, function() vim.cmd("silent undo") end)
  assert(buf_text(buf) == before, "one undo did not revert all replacements: " .. buf_text(buf))
end)

-- -------------------------------- already-open buffer with unsaved user changes

case("edit_file matches the live buffer and stacks on unsaved user changes", function()
  local path = vim.fn.tempname() .. ".txt"
  seed_file(path, "line1\nORIGINAL\nline3\n")

  -- User opens the file and makes an UNSAVED edit (a new line the disk lacks).
  local buf = vim.fn.bufadd(vim.fn.fnamemodify(path, ":p"))
  vim.fn.bufload(buf)
  vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "USER-UNSAVED-LINE" })
  assert(vim.bo[buf].modified, "precondition: buffer should be modified")
  -- The unsaved line is NOT on disk yet.
  assert(not disk_text(path):find("USER-UNSAVED-LINE", 1, true),
    "precondition: unsaved line must not be on disk yet")

  -- The agent edits text that only exists in the live buffer's current state,
  -- and its edit must stack on top of the user's unsaved change.
  edit_file({ path = path, old_string = "ORIGINAL", new_string = "AGENT-EDIT" })

  local content = buf_text(buf)
  assert(content:find("AGENT-EDIT", 1, true), "agent edit missing from buffer: " .. content)
  assert(content:find("USER-UNSAVED-LINE", 1, true),
    "pre-existing unsaved user edit was lost: " .. content)
  assert(not content:find("ORIGINAL", 1, true), "old text still present: " .. content)
  -- The write persisted the live buffer (unsaved line included) to disk.
  assert(disk_text(path):find("USER-UNSAVED-LINE", 1, true),
    "unsaved user line not persisted with the edit: " .. disk_text(path))
end)

-- ---------------------------------------------------- hook.after_write fires

case("hook.after_write still fires and its return is appended to the result", function()
  registry.define({
    name = "hook.after_write", kind = "hook", doc = "test marker",
    source = [[return function(path, ctx) return "AFTER_WRITE_MARKER:" .. path end]],
  })

  local path = vim.fn.tempname() .. ".txt"
  local wres = write_file({ path = path, content = "hi\n" })
  assert(wres:find("AFTER_WRITE_MARKER:", 1, true), "after_write marker missing from write_file result: " .. wres)

  local eres = edit_file({ path = path, old_string = "hi", new_string = "bye" })
  assert(eres:find("AFTER_WRITE_MARKER:", 1, true), "after_write marker missing from edit_file result: " .. eres)

  -- Restore the no-op so we don't affect any later suites sharing the registry.
  registry.define({
    name = "hook.after_write", kind = "hook", doc = "no-op",
    source = [[return function(path, ctx) end]],
  })
end)

if failed then
  print("FAILED")
  os.exit(1)
end
print("ALL PASS")
os.exit(0)
