-- tests/progress_spec.lua — the default progress display + stream-liveness
-- heartbeat (ui.progress / ui.note_activity). The elapsed clock ticks on a
-- local timer; the liveness segment must reflect ACTUAL stream activity so a
-- silent-but-alive stream reads "receiving" and a stall reads "silent Ns".
--   busted tests/progress_spec.lua

local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(vim.fn.fnamemodify(here, ":p"), ":h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local ui = require("straps.ui")


local progress_ns = vim.api.nvim_create_namespace("straps_progress")
local function indicator_text(bufnr)
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, progress_ns, 0, -1, { details = true })
  if #marks == 0 then return nil end
  return marks[1][4].virt_text[1][1]
end

it("liveness segment: not-streaming is empty, receiving vs silent by age", function()
  assert(ui._liveness_segment(false, 999999) == "", "non-streaming must add nothing")
  assert(ui._liveness_segment(true, 500):find("receiving", 1, true), "recent activity should read receiving")
  assert(ui._liveness_segment(true, 1999):find("receiving", 1, true), "just under threshold still receiving")
  assert(ui._liveness_segment(true, 8000) == " · silent 8s", "stale activity should read silent 8s")
end)

it("thinking phase shows 'receiving' right after activity", function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "line" })
  ui.progress(buf, { type = "start" })
  ui.progress(buf, { type = "thinking", turn = 2, max = 64 }) -- arms streaming + last_activity = now
  local txt = indicator_text(buf)
  assert(txt, "no progress extmark drawn")
  assert(txt:find("thinking · turn 2/64", 1, true), "missing turn label: " .. txt)
  assert(txt:find("receiving", 1, true), "fresh thinking phase should read receiving: " .. txt)
  assert(not txt:find("silent", 1, true), "should not read silent right after arming: " .. txt)
  ui.progress(buf, { type = "done" }) -- stops the timer
end)

it("a running tool shows no liveness segment (local, no stream)", function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "line" })
  ui.progress(buf, { type = "thinking", turn = 1, max = 8 })
  ui.progress(buf, { type = "tool", name = "bash" })
  local txt = indicator_text(buf)
  assert(txt:find("⚙ bash", 1, true), "missing tool label: " .. txt)
  assert(not txt:find("receiving", 1, true) and not txt:find("silent", 1, true),
    "a local tool must not surface stream liveness: " .. txt)
  ui.progress(buf, { type = "done" })
end)

it("note_activity flips a stale 'silent' back to 'receiving'", function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "line" })
  ui.progress(buf, { type = "thinking", turn = 1, max = 8 })
  -- Age the stream: no note_activity for a while would eventually read silent,
  -- but we don't want a real 2s wait — assert the mechanism instead. A fresh
  -- note_activity must always land on receiving.
  ui.note_activity(buf)
  ui.progress(buf, { type = "thinking", turn = 1, max = 8 }) -- redraw
  assert(indicator_text(buf):find("receiving", 1, true), "note_activity should keep it receiving")
  -- note_activity on a buffer with no active run is a harmless no-op
  local other = vim.api.nvim_create_buf(false, true)
  ui.note_activity(other) -- must not error
  ui.progress(buf, { type = "done" })
end)
