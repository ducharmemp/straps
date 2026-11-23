local script = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(script, ":p:h:h:h")
vim.opt.runtimepath:prepend(root)
vim.o.lines, vim.o.columns = 30, 100
vim.o.showmode = false

local api = vim.api
local session_dir = vim.fn.tempname()
local phase
local function expect(label, actual, expected)
  if vim.env.STRAPS_INSERT_COUNTERFACTUAL == phase .. ":" .. label then expected = {} end
  assert(vim.deep_equal(actual, expected), ("%s [%s]: expected %s, got %s"):format(phase, label,
    vim.inspect(expected), vim.inspect(actual)))
end

local function later()
  coroutine.yield()
end

local function await(label, predicate)
  for _ = 1, 200 do
    if predicate() then return end
    later()
  end
  error(phase .. ": timed out waiting for " .. label)
end

local function input(keys)
  api.nvim_input(keys)
  later()
end

local function screen_has(win, text)
  local top = api.nvim_win_get_position(win)[1] + 1
  for row = top, top + api.nvim_win_get_height(win) do
    local cells = {}
    for col = 1, vim.o.columns do cells[col] = vim.fn.screenstring(row, col) end
    if table.concat(cells):find(text, 1, true) then return true end
  end
  return false
end

local run = coroutine.create(function()
  require("straps").setup({ session_dir = session_dir, render = true, session_winbar = false, terminal_status = false })
  vim.cmd.runtime("plugin/straps.lua")
  local state, ui = require("straps.state"), require("straps.ui")
  local buf = state.new_session()
  state.seed_user(buf, table.concat(vim.fn.map(vim.fn.range(1, 60), "'passage ' . v:val"), "\n"))
  state.append(buf, "assistant", nil, "response")
  ui.show_session(buf, "none")
  vim.wo.foldenable = false
  local reader = api.nvim_get_current_win()
  local ns = api.nvim_create_namespace("straps.since_you_left")
  local function marks() return api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}) end

  phase = "open composer"
  vim.cmd.StrapsSteer()
  local draft = api.nvim_get_current_win()
  expect("one window", vim.fn.winlayout(), { "leaf", reader })
  expect("same window", draft, reader)

  local prefix = state.transcript_lines(buf)
  table.remove(prefix)
  local output = { "response" }
  local mark = {}
  local function check(text, row, col)
    expect("focus", api.nvim_get_current_win(), draft)
    expect("mode", api.nvim_get_mode().mode, "i")
    expect("draft text", state.draft_text(buf), text)
    expect("insertion cursor", api.nvim_win_get_cursor(draft), { #prefix + #output + row, col })
    expect("one window", vim.fn.winlayout(), { "leaf", reader })
    expect("buffer order", api.nvim_buf_get_lines(buf, 0, -1, false),
      vim.list_extend(vim.list_extend(vim.deepcopy(prefix), output), { "%%[straps:draft]%%", unpack(vim.split(text, "\n")) }))
    expect("unread", marks(), mark)
  end

  phase = "initial typing"
  input("iPlan: tail")
  await("typed text", function() return state.draft_text(buf) == "Plan: tail" end)
  check("Plan: tail", 2, 10)

  phase = "stream continuation"
  state.append_text(buf, " continues", true)
  output = { "response continues" }
  local first_mark = marks()[1]
  expect("first unread row", first_mark and first_mark[2], #prefix)
  mark = { first_mark }
  check("Plan: tail", 2, 10)

  phase = "move within line"
  input("<Left><Left><Left><Left>")
  check("Plan: tail", 2, 6)

  phase = "stream new lines at mid-line insertion point"
  state.append_text(buf, "\nmore output\nlast", true)
  output = { "response continues", "more output", "last" }
  check("Plan: tail", 2, 6)

  phase = "insert before existing text and add a line"
  input("keep <End><CR>nextx<BS>")
  check("Plan: keep tail\nnext", 3, 4)

  phase = "stream again with a multiline draft"
  state.append_text(buf, " chunk\nfinal output", true)
  output = { "response continues", "more output", "last chunk", "final output" }
  check("Plan: keep tail\nnext", 3, 4)

  phase = "resume composing at end"
  input("!")
  check("Plan: keep tail\nnext!", 3, 5)

  phase = "rendered composer"
  await("draft header on the screen", function()
    vim.cmd.redraw()
    return screen_has(draft, "── Draft · not sent ──")
  end)
  expect("concealed draft marker", screen_has(draft, "%%[straps:draft]%%"), false)
  expect("rendered draft text", screen_has(draft, "next!"), true)
  expect("draft not in transcript", table.concat(state.transcript_lines(buf), "\n"):find("Plan:", 1, true), nil)
  check("Plan: keep tail\nnext!", 3, 5)
end)

local function step()
  local ok, err = coroutine.resume(run)
  if not ok or coroutine.status(run) == "dead" then
    vim.fn.delete(session_dir, "rf")
    if not ok then
      io.stderr:write(debug.traceback(run, tostring(err)) .. "\n")
      vim.cmd("cquit 1")
    end
    vim.cmd("qa!")
  else
    vim.defer_fn(step, 5)
  end
end
vim.schedule(step)
