local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(here, ":p:h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local straps = require("straps")
straps.config.session_dir = vim.fn.tempname()
local registry = require("straps.registry")
local state = require("straps.state")
local loop = require("straps.loop")
local attention = require("straps.attention")
require("straps.tools").register()
require("straps.editor").register()
require("straps.provider").register()
registry.define({ name = "hook.on_progress", kind = "hook", source = "return function() end" })
registry.define({ name = "fn.provider", kind = "fn", source = [[return function(_, ctx)
  local fixture = _G.straps_terminal_options_fixture
  fixture.ctx = ctx
  if fixture.cancel_first then require("straps.loop").stop(ctx.bufnr) end
  fixture.result = require("straps.registry").call("tool.ask_user", fixture.input, ctx)
  ctx.emit({ type = "text_delta", text = "answered" })
  return { stop_reason = "end_turn", content = { { type = "text", text = "answered" } } }
end]] })

local count = 0
local function check(value, message)
  count = count + 1
  if tonumber(vim.env.STRAPS_OPTIONS_COUNTERFACTUAL) == count then value = not value end
  assert(value, "terminal options assertion " .. count .. ": " .. message)
end

local ns = vim.api.nvim_create_namespace("straps_ask_user")
local keys = { "j", "k", "<CR>", "<Esc>", "o", "<Down>", "<Up>", "1", "2" }
local real_send, real_input = vim.api.nvim_ui_send, vim.ui.input
local real_extmark, real_notify = vim.api.nvim_buf_set_extmark, vim.notify
local fixture

local function reports(expected)
  local want = {}
  for _, item in ipairs(expected) do
    local terminal = item == "done" or item == "idle" or item == "error"
    want[#want + 1] = "\27]7501;app=straps:id=" .. fixture.id .. ":state=" .. (terminal and "clear" or item) .. "\27\\"
    want[#want + 1] = "\27]7501;app=straps:state=" .. item .. "\27\\"
  end
  check(vim.deep_equal(fixture.sent, want), "exact task ID, state, kind and report order: " .. vim.inspect(fixture.sent))
end

local function mapping(lhs)
  return vim.api.nvim_buf_call(fixture.buf, function() return vim.fn.maparg(lhs, "n", false, true) end)
end

local function press(lhs)
  local m = mapping(lhs)
  check(type(m.callback) == "function" and m.desc == "straps: ask_user", "installed callback for " .. lhs)
  m.callback()
end

local function resources_restored()
  check(#vim.api.nvim_buf_get_extmarks(fixture.buf, ns, 0, -1, {}) == 0, "question extmarks removed")
  for _, lhs in ipairs(keys) do
    check(vim.deep_equal(mapping(lhs), fixture.maps[lhs]), "mapping restored for " .. lhs)
  end
  check(vim.deep_equal(vim.api.nvim_list_wins(), fixture.wins), "question windows closed")
  check(vim.deep_equal(vim.api.nvim_list_bufs(), fixture.bufs), "question scratch buffers deleted")
  check(vim.api.nvim_get_current_win() == fixture.user_win, "user window focus restored")
end

local function start(cancel_first, draw_error)
  fixture.cancel_first = cancel_first
  fixture.input = {
    question = "Pick?", content = "proposed content",
    options = { { label = "alpha", preview = "alpha preview" }, { label = "beta", preview = "beta preview" } },
  }
  if draw_error then
    vim.api.nvim_buf_set_extmark = function(buf, namespace, ...)
      if buf == fixture.buf and namespace == ns then
        fixture.draw_failed = true
        error("scripted initial draw failure")
      end
      return real_extmark(buf, namespace, ...)
    end
  end
  loop.start(fixture.buf)
  check(fixture.ctx ~= nil and loop.running(fixture.buf), "admitted loop suspended in actual ctx.await")
  fixture.id = (fixture.sent[1] or ""):match("^\27%]7501;app=straps:id=([^:]+):state=working\27\\$")
  check(fixture.id ~= nil and fixture.id:match("^straps/%d+%-%d+/" .. fixture.buf .. "$") ~= nil,
    "initial working report identifies the admitted session buffer")
end

local function blocked()
  reports({ "working", "blocked:kind=question" })
  check(#vim.api.nvim_buf_get_extmarks(fixture.buf, ns, 0, -1, {}) == 1, "options draw installed")
end

local function released()
  check(fixture.result == nil and loop.running(fixture.buf), "callback inspected before scheduled coroutine resume")
  reports({ "working", "blocked:kind=question", "working" })
end

local dismissed = "user dismissed the question without choosing — proceed on your best judgment or ask differently"
local function finished(result, cancelled, expected)
  check(vim.wait(1000, function() return not loop.running(fixture.buf) end, 10), "admitted loop completed")
  check(fixture.result == result, "exact ask_user result: " .. tostring(fixture.result))
  check(vim.b[fixture.buf].straps_run_reason == (cancelled and "cancelled" or "ok"), "exact run ending reason")
  reports(expected)
  resources_restored()
end

before_each(function()
  fixture = { sent = {}, maps = {}, original_wins = vim.api.nvim_list_wins(), original_bufs = vim.api.nvim_list_bufs() }
  _G.straps_terminal_options_fixture = fixture
  vim.api.nvim_ui_send = function(text) fixture.sent[#fixture.sent + 1] = text end
  vim.notify = function(message) fixture.notification = message end
  attention.setup(true)
  fixture.buf = state.new_session()
  state.append_text(fixture.buf, "question")
  for _, lhs in ipairs(keys) do
    vim.keymap.set("n", lhs, function() end, { buffer = fixture.buf, desc = "prior " .. lhs })
    fixture.maps[lhs] = mapping(lhs)
  end
  fixture.wins, fixture.bufs = vim.api.nvim_list_wins(), vim.api.nvim_list_bufs()
  fixture.user_win = vim.api.nvim_get_current_win()
end)

after_each(function()
  vim.api.nvim_buf_set_extmark, vim.ui.input = real_extmark, real_input
  if fixture and loop.running(fixture.buf) then
    loop.stop(fixture.buf)
    vim.wait(1000, function() return not loop.running(fixture.buf) end, 10)
  end
  attention.setup(false)
  vim.api.nvim_ui_send, vim.notify = real_send, real_notify
  if fixture then
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if not vim.tbl_contains(fixture.original_wins, win) then pcall(vim.api.nvim_win_close, win, true) end
    end
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if not vim.tbl_contains(fixture.original_bufs, buf) then pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
    end
  end
  _G.straps_terminal_options_fixture = nil
end)

it("releases options selection in the installed callback before loop resume", function()
  start()
  blocked()
  press("2")
  released()
  finished("user chose option 2: beta", false, { "working", "blocked:kind=question", "working", "done" })
end)

it("releases Escape dismissal in the installed callback before loop resume", function()
  start()
  blocked()
  press("<Esc>")
  released()
  finished(dismissed, false, { "working", "blocked:kind=question", "working", "done" })
end)

it("releases real loop cancellation before scheduled resume", function()
  start()
  blocked()
  loop.stop(fixture.buf)
  check(fixture.ctx.cancelled(), "actual loop context marked cancelled")
  released()
  finished(dismissed, true, { "working", "blocked:kind=question", "working", "idle" })
end)

it("dismisses initial draw failure without publishing a question wait", function()
  start(false, true)
  check(fixture.draw_failed == true, "initial options draw failed")
  check(fixture.notification:find("scripted initial draw failure", 1, true) ~= nil, "draw error reported")
  check(fixture.result == nil, "draw failure resolution scheduled through actual await")
  reports({ "working" })
  finished(dismissed, false, { "working", "done" })
end)

it("dismisses options with an already-cancelled actual loop context", function()
  start(true)
  check(fixture.ctx.cancelled(), "provider cancelled admitted run before question")
  check(fixture.result == nil, "already-cancelled dismissal awaits scheduled resume")
  reports({ "working" })
  finished(dismissed, true, { "working", "idle" })
end)

it("releases other selection before entering a distinct free-text wait", function()
  local answer
  vim.ui.input = function(_, callback) answer = callback end
  start()
  blocked()
  press("o")
  released()
  check(vim.wait(1000, function() return answer ~= nil end, 10), "free-text UI opened after options resume")
  resources_restored()
  reports({ "working", "blocked:kind=question", "working", "blocked:kind=question" })
  answer("custom")
  check(fixture.result == nil and loop.running(fixture.buf), "free-text callback inspected before resume")
  reports({ "working", "blocked:kind=question", "working", "blocked:kind=question", "working" })
  finished("user answered (free text): custom", false,
    { "working", "blocked:kind=question", "working", "blocked:kind=question", "working", "done" })
  print("terminal options assertions: " .. count)
end)
