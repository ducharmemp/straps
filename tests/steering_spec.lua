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
