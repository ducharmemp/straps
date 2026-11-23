local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)
vim.cmd("filetype plugin on")
local api = vim.api
local straps = require("straps")
local state = require("straps.state")
local loop = require("straps.loop")
local evidence = require("straps.evidence")
local registry = require("straps.registry")
straps.setup({ session_dir = vim.fn.tempname(), blank_nudge_limit = 0 })

local claim = "The empty-input test passes after the reuse test."
local quote = "ok 2 - empty input"
local body = "ok 1 - reuse\n  " .. quote
local prose = "A recap. " .. claim .. " No other claim."
local prefix = "[[straps-evidence]] "
local function declaration(c, q)
  return prefix .. vim.json.encode({ claim = c or claim, quote = q or quote })
end

registry.define({ name = "fn.provider", kind = "fn", source = [[return function(req, ctx)
  return _G.evidence_test_provider(req, ctx)
end]] })

local function session(response, opts)
  opts = opts or {}
  local bufnr = state.new_session()
  api.nvim_set_current_buf(bufnr)
  if not opts.no_source then
    state.append(bufnr, "tool_use", { id = "call_one", name = "bash" }, "{}")
    state.append(bufnr, "tool_result", { id = "call_one", name = "bash" }, opts.body or body)
  end
  if opts.other then
    state.append(bufnr, "tool_use", { id = "call_two", name = "bash" }, "{}")
    state.append(bufnr, "tool_result", { id = "call_two", name = "bash" }, opts.other)
  end
  state.append(bufnr, "user", nil, "What passed?")
  local invoked
  _G.evidence_test_provider = function(req, ctx)
    invoked = req
    for i = 1, #response do ctx.emit({ type = "text_delta", text = response:sub(i, i) }) end
    return { complete = not opts.incomplete, stop_reason = "end_turn", content = { { type = "text", text = response } } }
  end
  loop.start(bufnr)
  assert.is_true(vim.wait(5000, function() return not loop.running(bufnr) end))
  assert.is_table(invoked)
  assert.are.equal("ok", vim.b[bufnr].straps_run_reason)
  local blocks = state.list_blocks(bufnr)
  local assistant, result
  for _, block in ipairs(blocks) do
    if block.kind == "assistant" then assistant = block end
    if block.kind == "tool_result" and not result then result = block end
  end
  local row = assistant.first_lnum
  local col = #"A recap. "
  api.nvim_win_set_cursor(0, { row, col })
  return bufnr, row, col, result, invoked
end

after_each(function()
  vim.cmd("silent! only!")
  local bufnr = api.nvim_get_current_buf()
  if vim.b[bufnr].straps_session then api.nvim_buf_delete(bufnr, { force = true }) end
end)

it("streams prose only, jumps to the exact folded output, and returns with Ctrl-O", function()
  local bufnr, row, col, result, req = session(prose .. "\n" .. declaration())
  assert.is_truthy(req.system:find(prefix, 1, true))
  local lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
  assert.are.equal(prose, lines[row])
  assert.is_nil(table.concat(lines, "\n"):find(prefix, 1, true))
  assert.are.equal("↳ gE evidence", evidence.winbar_hint())
  local win = api.nvim_get_current_win()
  vim.wo.foldmethod = "manual"
  vim.cmd("normal! zE")
  vim.cmd(("%d,%dfold"):format(result.marker_lnum, result.first_lnum + 1))
  assert.are.equal(result.marker_lnum, vim.fn.foldclosed(result.first_lnum + 1))
  vim.cmd("normal gE")
  assert.are.same({ result.first_lnum + 1, 2 }, api.nvim_win_get_cursor(win))
  assert.are.equal(-1, vim.fn.foldclosed(result.first_lnum + 1))
  assert.are.equal("", evidence.winbar_hint())
  vim.cmd("normal! \15")
  assert.are.same({ row, col }, api.nvim_win_get_cursor(win))
end)

it("renders the hint only for the winbar whose cursor is on the claim", function()
  local _, row, col = session(prose .. "\n" .. declaration())
  local ui = require("straps.ui")
  local claimed = api.nvim_get_current_win()
  vim.cmd("split")
  local other = api.nvim_get_current_win()
  api.nvim_win_set_cursor(other, { row, col + #claim + 1 })
  local function render(win)
    local previous = vim.g.statusline_winid
    vim.g.statusline_winid = win
    local rendered = ui.winbar()
    vim.g.statusline_winid = previous
    return rendered
  end
  assert.is_nil(render(other):find("↳ gE evidence", 1, true))
  assert.is_truthy(render(claimed):find("↳ gE evidence", 1, true))
end)

for _, case in ipairs({
  { "without a declaration", prose },
  { "malformed declarations", prose .. "\n" .. prefix .. "{broken" },
  { "claims absent from the answer", prose .. "\n" .. declaration("Made up.") },
  { "quotes absent from results", prose .. "\n" .. declaration(nil, "not in output") },
  { "duplicate quotes in the same result", prose .. "\n" .. declaration(), { body = body .. "\n" .. quote } },
  { "duplicate quotes in another result", prose .. "\n" .. declaration(), { other = quote } },
  { "duplicate claims in the answer", prose .. "\n" .. claim .. "\n" .. declaration() },
  { "duplicate declarations", prose .. "\n" .. declaration() .. "\n" .. declaration() },
  { "incomplete responses", prose .. "\n" .. declaration(), { incomplete = true } },
  { "legacy compaction stubs", prose .. "\n" .. declaration(), { body = "[compacted: was 100 bytes] " .. quote, other = "unrelated" } },
}) do
  it("does not offer a jump for " .. case[1], function()
    local bufnr = session(case[2], case[3])
    assert.are.equal("", evidence.winbar_hint())
    assert.is_false(evidence.jump())
    assert.is_nil(table.concat(api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n"):find(prefix, 1, true))
  end)
end

it("tracks insertions above the source and invalidates on source replacement without relocating", function()
  local bufnr, row, col, result = session(prose .. "\n" .. declaration())
  api.nvim_buf_set_lines(bufnr, 0, 0, false, { "" })
  api.nvim_win_set_cursor(0, { row + 1, col })
  assert.are.equal("↳ gE evidence", evidence.winbar_hint())
  assert.is_true(evidence.jump())
  assert.are.same({ result.first_lnum + 2, 2 }, api.nvim_win_get_cursor(0))
  api.nvim_buf_set_lines(bufnr, result.first_lnum, result.first_lnum + 1, false, { "not the original" })
  api.nvim_win_set_cursor(0, { row + 1, col })
  assert.are.equal("", evidence.winbar_hint())
  assert.is_false(evidence.jump())
end)

it("invalidates after the claim line is edited", function()
  local bufnr, row, col = session(prose .. "\n" .. declaration())
  api.nvim_buf_set_text(bufnr, row - 1, #prose, row - 1, #prose, { " changed" })
  api.nvim_win_set_cursor(0, { row, col })
  assert.are.equal("", evidence.winbar_hint())
end)

it("passes ordinary partial prefixes through and consumes malformed, overlong and excess declaration lines", function()
  local stream = evidence.stream()
  assert.are.equal("", evidence.filter(stream, "[[st"))
  assert.are.equal("[[start\n", evidence.filter(stream, "art\n"))
  assert.are.equal("", evidence.filter(stream, prefix .. string.rep("a", 4097) .. "\n"))
  assert.are.equal("", evidence.filter(stream, string.rep(prefix .. "{}\n", 12)))
  assert.are.equal(8, #stream.declarations)
  assert.are.equal("{}", stream.declarations[1])
  assert.are.equal("[[", evidence.filter(stream, "[[", true))
end)
