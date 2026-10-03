-- tests/reply_refs_spec.lua — hook.on_run_end.reply_refs. Run from the repo root:
--   busted tests/reply_refs_spec.lua
-- No network: fn.provider is scripted for the end-to-end case. Covers loading
-- the final reply's readable path:line refs into the session window's location
-- list, the reason/ref-count/window guards, and leaving any list the agent set
-- during the run alone while overwriting a stale one from before the run.

local script = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(vim.fn.fnamemodify(script, ":p"), ":h:h")
vim.opt.runtimepath:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
vim.fn.chdir(root)

local straps = require("straps").setup({})
straps.config.session_dir = vim.fn.tempname()

local registry = require("straps.registry")
local state = require("straps.state")
local loop = require("straps.loop")
local findings = require("straps.findings")

registry.define({
  name = "hook.confirm", kind = "hook", doc = "test: allow everything",
  source = "return function() return true end",
}, { scope = "global" })

local REPLY = table.concat({
  "Changed `lua/straps/loop.lua:10` and README.md:3:5 here.",
  "Also nope/missing.lua:4 and lua/straps/loop.lua:10 again.",
}, "\n")

local function session(reply)
  local b = state.new_session()
  state.append_text(b, "go")
  state.append(b, "assistant", nil, reply)
  vim.cmd("tabnew")
  vim.api.nvim_win_set_buf(0, b)
  vim.fn.setloclist(0, {}, "f")
  return b
end

local function title_of(b)
  local win = findings.session_win(b)
  return vim.fn.getloclist(win, { title = 1 }).title
end

local function run(b, reason, mid)
  registry.call_hooks("hook.on_run_start", { bufnr = b })
  if mid then mid() end
  registry.call_hooks("hook.on_run_end", { bufnr = b }, reason)
end

it("loads the reply's readable refs into the session loclist", function()
  local b = session(REPLY)
  run(b, "ok")
  local items = findings.get_locations(b)
  assert.are.equal("straps: reply refs", title_of(b))
  assert.are.equal(2, #items)
  assert.are.equal(root .. "/lua/straps/loop.lua", vim.api.nvim_buf_get_name(items[1].bufnr))
  assert.are.equal(10, items[1].lnum)
  assert.are.equal("Changed `lua/straps/loop.lua:10` and README.md:3:5 here.", items[1].text)
  assert.are.equal(root .. "/README.md", vim.api.nvim_buf_get_name(items[2].bufnr))
  assert.are.equal(3, items[2].lnum)
  assert.are.equal(5, items[2].col)
  assert.are.equal(items[1].text, items[2].text)
end)

it("sets nothing when the run was cancelled", function()
  local b = session(REPLY)
  run(b, "cancelled")
  assert.are.equal(0, #findings.get_locations(b))
  assert.are_not.equal("straps: reply refs", title_of(b))
end)

it("sets nothing for a reply with one ref", function()
  local b = session("Only lua/straps/loop.lua:10 and nope/missing.lua:4.")
  run(b, "ok")
  assert.are.equal(0, #findings.get_locations(b))
end)

it("leaves a list the agent set during the run alone", function()
  local b = session(REPLY)
  run(b, "ok", function()
    findings.set_locations(b, {
      title = "straps: grep foo",
      items = { { filename = root .. "/DESIGN.md", lnum = 1, text = "x" } },
    }, false)
  end)
  assert.are.equal("straps: grep foo", title_of(b))
  assert.are.equal(1, #findings.get_locations(b))
end)

it("leaves an agent list with a custom title alone", function()
  local b = session(REPLY)
  run(b, "ok", function()
    findings.set_locations(b, {
      title = "Refactor sites",
      items = { { filename = root .. "/DESIGN.md", lnum = 1, text = "x" } },
    }, false)
  end)
  assert.are.equal("Refactor sites", title_of(b))
  assert.are.equal(1, #findings.get_locations(b))
end)

it("leaves a list the agent re-set under the same title alone", function()
  local b = session(REPLY)
  local what = {
    title = "straps: grep foo",
    items = { { filename = root .. "/DESIGN.md", lnum = 1, text = "x" } },
  }
  findings.set_locations(b, what, false)
  run(b, "ok", function() findings.set_locations(b, what, false) end)
  assert.are.equal("straps: grep foo", title_of(b))
  assert.are.equal(1, #findings.get_locations(b))
end)

it("overwrites a stale straps: list from before the run", function()
  local b = session(REPLY)
  findings.set_locations(b, {
    title = "straps: grep foo",
    items = { { filename = root .. "/DESIGN.md", lnum = 1, text = "x" } },
  }, false)
  run(b, "ok")
  assert.are.equal("straps: reply refs", title_of(b))
  assert.are.equal(2, #findings.get_locations(b))
end)

it("never touches the global quickfix list for a windowless session", function()
  local b = state.new_session()
  state.append_text(b, "go")
  state.append(b, "assistant", nil, REPLY)
  vim.fn.setqflist({}, "f")
  vim.fn.setqflist({}, " ", { title = "user make", items = { { filename = root .. "/DESIGN.md", lnum = 1 } } })
  assert.is_nil(findings.session_win(b))
  run(b, "ok")
  assert.are.equal("user make", vim.fn.getqflist({ title = 1 }).title)
  assert.are.equal(1, #vim.fn.getqflist())
end)

it("strips the transcript escape prefix from entry text", function()
  local b = session("%%[straps:x]%% lua/straps/loop.lua:10\nREADME.md:3")
  run(b, "ok")
  local items = findings.get_locations(b)
  assert.are.equal(2, #items)
  assert.are.equal("%%[straps:x]%% lua/straps/loop.lua:10", items[1].text)
end)

it("fires at the end of a real run", function()
  registry.define({
    name = "fn.provider", kind = "fn", doc = "test provider",
    source = ([[
return function(req, ctx)
  local text = %q
  ctx.await(function(resolve)
    vim.defer_fn(function() ctx.emit({ type = "text_delta", text = text }); resolve(true) end, 5)
  end)
  return { content = { { type = "text", text = text } }, stop_reason = "end_turn" }
end]]):format(REPLY),
  }, { scope = "global" })
  local b = state.new_session()
  state.append_text(b, "go")
  vim.cmd("tabnew")
  vim.api.nvim_win_set_buf(0, b)
  loop.start(b)
  assert(vim.wait(10000, function() return not loop.running(b) end, 10), "run did not finish")
  vim.wait(100)
  assert.are.equal("straps: reply refs", title_of(b))
  assert.are.equal(2, #findings.get_locations(b))
end)
