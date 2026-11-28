local script = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(script, ":p:h:h")
vim.opt.runtimepath:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

require("straps").setup({ session_dir = vim.fn.tempname(), render = true, stop_backstop_ms = 5000 })
local state, ui, loop = require("straps.state"), require("straps.ui"), require("straps.loop")
local api = vim.api
vim.cmd.source(vim.fn.fnameescape(root .. "/plugin/straps.lua"))

local function check(label, actual, expected)
  if vim.env.STRAPS_STEERING_COUNTERFACTUAL == label then expected = {} end
  assert(vim.deep_equal(actual, expected), label .. ": got " .. vim.inspect(actual))
end

local function key(keys)
  api.nvim_feedkeys(api.nvim_replace_termcodes(keys, true, false, true), "mx", false)
end

local function session()
  local buf = state.new_session()
  ui.show_session(buf, "none")
  return buf
end

local function draft(buf, lines)
  api.nvim_buf_set_lines(buf, state.draft_row(buf) + 1, -1, false, lines)
end

it("persists an unsent composer and excludes even marker-looking draft lines", function()
  local buf = session()
  state.seed_user(buf, "first request")
  state.append(buf, "assistant", nil, "partial response")
  local broker = state.parse(buf)
  local win = api.nvim_get_current_win()
  vim.cmd.StrapsSteer()
  check("one-window", vim.fn.winlayout(), { "leaf", win })
  local lines = { "  keep indentation", "%%[straps:user]%%", "", "last line" }
  draft(buf, lines)
  check("unsent", state.parse(buf), broker)
  state.append_text(buf, " reply\nsecond line", true)
  state.ensure_trailing_user(buf)
  local parsed = state.parse(buf)
  check("stream", parsed.messages[#parsed.messages].content[1].text, "partial response reply\nsecond line")
  local path = api.nvim_buf_get_name(buf)
  vim.cmd.enew()
  api.nvim_buf_delete(buf, {})
  local resumed = state.open_session_file(path)
  ui.show_session(resumed, "none")
  check("reload-draft", state.draft_text(resumed), table.concat(lines, "\n"))
  check("reload-transcript", state.parse(resumed), parsed)
end)

it("keeps the composer boundary through deletion, repair, undo and redo", function()
  local buf = session()
  state.seed_user(buf, "request")
  local before = state.transcript_lines(buf)
  local marker = "%%[straps:draft]%%"
  draft(buf, { marker, "unsent" })
  local row = #before
  local body = marker .. "\nunsent"
  local function verify(label, history, physical, text)
    check(label .. "-history", state.transcript_lines(buf), history)
    check(label .. "-marker", state.draft_row(buf), physical)
    check(label .. "-draft", state.draft_text(buf), text or body)
  end
  vim.cmd("let &l:undolevels = &l:undolevels")
  api.nvim_win_set_cursor(0, { row + 1, 0 })
  key("dd")
  verify("deleted", before, nil)
  vim.cmd.StrapsSteer()
  verify("repaired", before, row)
  key("u")
  verify("undo-repair", before, nil)
  key("u")
  verify("undo-delete", before, row)
  key("<C-r>")
  verify("redo-delete", before, nil)
  key("<C-r>")
  verify("redo-repair", before, row)
  state.append(buf, "assistant", nil, "response")
  local appended = vim.list_extend(vim.deepcopy(before), { "", "%%[straps:assistant]%%", "response" })
  verify("append-repair", appended, #appended)
  key("u")
  verify("undo-append", before, row)
  key("<C-r>")
  verify("redo-append", appended, #appended)
  local replaced = { "%%[straps:user]%%", "another request" }
  state.replace_transcript(buf, replaced)
  verify("replace-history", replaced, #replaced)
  key("u")
  verify("undo-replace", appended, #appended)
  key("<C-r>")
  verify("redo-replace", replaced, #replaced)
  api.nvim_win_set_cursor(0, { #replaced + 1, 0 })
  key("ofirst<Esc>")
  key("kdd")
  verify("open-below-delete", replaced, nil, "first\n" .. body)
  key("Onew first<Esc>")
  verify("open-above-after-delete", replaced, nil, "new first\nfirst\n" .. body)
end)
for _, mode in ipairs({ "write", "persist", "stream" }) do
  it("restores the draft separator on " .. mode .. " after an in-place reload", function()
    local buf = session()
    local notice = "[straps] from agent peer (buffer 42): draft text"
    local lines = { notice, "%%[straps:system]%%", "unsent" }
    draft(buf, lines)
    state.persist(buf)
    local before = state.transcript_lines(buf)
    vim.cmd("edit!")
    api.nvim_win_set_cursor(0, { #before + 1, 0 })
    key("dd")
    check(mode .. "-missing", state.draft_row(buf), nil)
    check(mode .. "-fold-draft", ui.foldexpr(#before + 2), 0)
    check(mode .. "-fold-user", ui.foldexpr(#before), 0)
    ui.progress(buf, { type = "start" })
    local marks = api.nvim_buf_get_extmarks(buf, api.nvim_create_namespace("straps_progress"), 0, -1, {})
    ui.progress(buf, { type = "done" })
    check(mode .. "-progress-history", marks[1] and marks[1][2], #before - 1)
    check(mode .. "-composing", require("straps.since_you_left").wants_output(buf), true)
    if mode == "write" then
      vim.cmd.write()
    elseif mode == "persist" then
      state.persist(buf)
    else
      state.append_text(buf, "response")
      before[#before + 1] = "response"
      check("stream-restored", state.draft_row(buf), #before)
      state.persist(buf)
    end
    vim.cmd("edit!")
    check(mode .. "-saved-history", state.transcript_lines(buf), before)
    check(mode .. "-saved-draft", state.draft_text(buf), table.concat(lines, "\n"))
  end)
end

it("repairs a hand-opened .straps file before writing it", function()
  vim.cmd("filetype plugin on")
  local path = vim.fn.tempname() .. ".straps"
  local history = { "%%[straps:user]%%", "request" }
  local body = "unsent"
  vim.fn.writefile(vim.list_extend(vim.deepcopy(history), { "%%[straps:draft]%%", body }), path)
  vim.cmd.edit(vim.fn.fnameescape(path))
  local buf = api.nvim_get_current_buf()
  check("hand-open-filetype", vim.bo[buf].filetype, "straps")
  check("hand-open-flag", vim.b[buf].straps_session, nil)
  api.nvim_win_set_cursor(0, { #history + 1, 0 })
  key("dd")
  vim.cmd.write()
  vim.cmd("edit!")
  check("hand-open-history", state.transcript_lines(buf), history)
  check("hand-open-draft", state.draft_text(buf), body)
  vim.fn.delete(path)
end)

local function slow_run()
  _G.__composer = { requests = {}, cancelled = 0, ended = {} }
  require("straps.registry").define({ name = "fn.provider", kind = "fn", source = [[
return function(req, ctx)
  local data = _G.__composer
  data.requests[#data.requests + 1] = req.messages
  local function answer()
    ctx.emit({ type = "text_delta", text = "response" })
    return { stop_reason = "end_turn", content = { { type = "text", text = "response" } } }
  end
  if #data.requests == 1 then
    ctx.await(function(resolve)
      data.resume = resolve
      ctx.on_cancel(function() data.cancelled = data.cancelled + 1 end)
    end)
  end
  return answer()
end
]] })
  local buf = session()
  local data = _G.__composer
  local group = api.nvim_create_augroup("ComposerLifecycleTest", { clear = true })
  api.nvim_create_autocmd("User", { group = group, pattern = "StrapsRunEnd", callback = function(ev)
    if ev.data.bufnr == buf then data.ended[#data.ended + 1] = ev.data.reason end
  end })
  draft(buf, { "initial request" })
  key("<CR>")
  assert(data.resume, "first provider request did not reach await")
  return buf, data
end

it("renders the same composer role and muted label during and after a run", function()
  local buf, data = slow_run()
  local ns = api.nvim_create_namespace("straps_render")
  local function display(label)
    local row = state.draft_row(buf)
    ui._render(buf)
    local headings = {}
    local history = {}
    for _, mark in ipairs(api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
      local details = mark[4]
      for _, chunk in ipairs(details.virt_text or {}) do
        if mark[2] >= row and (chunk[2] == "StrapsRoleUser" or chunk[1] == " · draft") then
          headings[#headings + 1] = { mark[2] - row, details.virt_text_pos, chunk }
        elseif mark[2] < row and chunk[1] == "you" and chunk[2] == "StrapsRoleUser" then
          history[#history + 1] = api.nvim_buf_get_lines(buf, mark[2] + 1, mark[2] + 2, false)[1]
        end
      end
    end
    check(label .. "-history", history, { "initial request" })
    check(label, headings, {
      { 0, "overlay", { "──── ", "StrapsRoleUser" } },
      { 0, "overlay", { "you", "StrapsRoleUser" } },
      { 0, "overlay", { " · draft", "StrapsRule" } },
    })
  end
  display("active-composer-style")
  data.resume()
  assert(vim.wait(1000, function() return not loop.running(buf) end))
  display("idle-composer-style")
end)

it("Enter queues only the composer body during a run", function()
  local buf, data = slow_run()
  draft(buf, { "queued body" })
  key("<CR>")
  check("active-enter-clears-draft", state.draft_text(buf), "")
  check("active-enter-waits-for-boundary", #data.requests, 1)
  data.resume()
  assert(vim.wait(1000, function() return not loop.running(buf) end))
  local sent = data.requests[2][#data.requests[2]]
  check("active-enter-sends-body", sent, { role = "user", content = { { type = "text", text = "queued body" } } })
end)

it("Shift-Enter waits for the old run, sends the snapshot once, and keeps newer text", function()
  local buf, data = slow_run()
  local win = api.nvim_get_current_win()
  key("<S-CR>")
  check("blank-does-not-stop", data.cancelled, 0)
  draft(buf, { "send now" })
  key("<S-CR>")
  vim.cmd.StrapsSendNow()
  key("<CR>")
  check("one-cancellation", data.cancelled, 1)
  check("wait-for-stop", { loop.running(buf), #data.requests, #data.ended }, { true, 1, 0 })
  check("snapshot-still-unsent", state.draft_text(buf), "send now")
  draft(buf, { "new unsent text" })
  api.nvim_win_set_cursor(win, { state.draft_row(buf) + 2, 6 })
  data.resume()
  assert(vim.wait(1000, function() return not loop.running(buf) and #data.ended == 2 end), "replacement run did not end")
  check("actual-finish", data.ended, { "cancelled", "ok" })
  check("one-replacement", #data.requests, 2)
  local request = vim.json.encode(data.requests[2])
  local _, occurrences = request:gsub("send now", "")
  check("one-copy", occurrences, 1)
  check("new-typing-not-sent", request:find("new unsent text", 1, true) ~= nil, false)
  check("new-typing-kept", state.draft_text(buf), "new unsent text")
  check("new-cursor-kept", api.nvim_win_get_cursor(win), { state.draft_row(buf) + 2, 6 })
end)

it("the command fallback starts after stop; an explicit Stop suppresses a pending restart", function()
  local buf, data = slow_run()
  draft(buf, { "pending" })
  vim.cmd.StrapsSendNow()
  check("fallback-cancellation", data.cancelled, 1)
  vim.cmd.StrapsStop()
  data.resume()
  assert(vim.wait(1000, function() return not loop.running(buf) end))
  vim.wait(20, function() return false end)
  check("no-restart", #data.requests, 1)
  check("stop-keeps-draft", state.draft_text(buf), "pending")
  vim.cmd.StrapsSendNow()
  check("fallback-idle-send", #data.requests, 2)
end)
