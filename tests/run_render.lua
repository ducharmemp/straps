-- tests/run_render.lua — the transcript rendering layer (fn.render + themed
-- highlight groups + colored fold summaries). Rendering is display-only:
-- extmarks, conceal and folds over the untouched marker buffer. These assert
-- on nvim_buf_get_extmarks(details=true) and the exposed chunk builders, so
-- most cases need no real window/fold.
--   nvim --headless -l tests/run_render.lua

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

local straps = require("straps").setup({})
-- Hermetic: this suite builds session buffers; keep them off the real data dir.
straps.config.session_dir = vim.fn.tempname()
local ui = require("straps.ui")
local registry = require("straps.registry")
local state = require("straps.state")

ui.setup() -- registers fn.render + the highlight groups (setup already ran it,
-- but this documents the requirement and is idempotent via define_default)

local render_ns = vim.api.nvim_create_namespace("straps_render")

-- Build a scripted transcript in a straps buffer. Returns bufnr and a table of
-- the 1-based line numbers of a few landmark lines for row-precise asserts.
local TRANSCRIPT = {
  "%%[straps:system]%%",       -- 1
  "You are Cinch, a coding agent.",   -- 2
  "",                          -- 3
  "%%[straps:user]%%",         -- 4
  "hello there",               -- 5 (message body)
  "",                          -- 6
  "%%[straps:assistant]%%",    -- 7
  "I'll run a command.",       -- 8
  "",                          -- 9
  '%%[straps:tool_use]%% {"id":"t1","name":"bash"}', -- 10
  "{",                         -- 11
  '  "command": "echo hi"',    -- 12
  "}",                         -- 13
  "",                          -- 14
  '%%[straps:tool_result]%% {"id":"t1","is_error":false}', -- 15
  "hi",                        -- 16
  "",                          -- 17
  '%%[straps:tool_use]%% {"id":"t2","name":"grep"}', -- 18
  "{",                         -- 19
  '  "pattern": "boom"',       -- 20
  "}",                         -- 21
  "",                          -- 22
  '%%[straps:tool_result]%% {"id":"t2","is_error":true}', -- 23
  "no matches",                -- 24
}
local LN = {
  system_marker = 1,
  user_marker = 4,
  user_body = 5,
  assistant_marker = 7,
  tool_use_ok = 10,
  tool_result_ok = 15,
  tool_use_err = 18,
}

local function make_buf()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "straps"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, TRANSCRIPT)
  return buf
end

local function marks_on_row(buf, lnum)
  return vim.api.nvim_buf_get_extmarks(buf, render_ns,
    { lnum - 1, 0 }, { lnum - 1, -1 }, { details = true })
end

-- ------------------------------------------------------------ highlight groups
case("highlight groups resolve to their default link targets", function()
  local want = {
    StrapsRoleUser = "Function",
    StrapsRoleAgent = "Keyword",
    StrapsRoleSystem = "Comment",
    StrapsTool = "Special",
    StrapsToolOk = "DiagnosticOk",
    StrapsToolError = "DiagnosticError",
    StrapsRule = "Comment",
    StrapsCardBorder = "Comment",
  }
  for name, target in pairs(want) do
    local hl = vim.api.nvim_get_hl(0, { name = name, link = true })
    assert(hl.link == target,
      ("%s links to %s, want %s"):format(name, tostring(hl.link), target))
  end
end)

case("a user `hi link` override survives re-apply (default = true)", function()
  vim.api.nvim_set_hl(0, "StrapsTool", { link = "Constant" })
  ui.apply_highlights() -- re-link defaults; must not clobber the user override
  local hl = vim.api.nvim_get_hl(0, { name = "StrapsTool", link = true })
  assert(hl.link == "Constant", "user override lost, got " .. tostring(hl.link))
  -- restore the default so later cases see the shipped link
  vim.api.nvim_set_hl(0, "StrapsTool", { default = true, link = "Special" })
end)

-- ------------------------------------------------------------------ fn.render
local buf = make_buf()
local before_text = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
local before_modified = vim.bo[buf].modified
local before_parse = vim.inspect(state.parse(buf))
registry.call("fn.render", buf)

case("marker lines carry a conceal extmark and a role-rule overlay", function()
  for _, spec in ipairs({
    { lnum = LN.user_marker, word = "you", hl = "StrapsRoleUser" },
    { lnum = LN.assistant_marker, word = "Cinch", hl = "StrapsRoleAgent" },
    { lnum = LN.system_marker, word = "system", hl = "StrapsRoleSystem" },
  }) do
    local marks = marks_on_row(buf, spec.lnum)
    assert(#marks > 0, "no render marks on marker line " .. spec.lnum)
    local saw_conceal, saw_overlay = false, false
    for _, m in ipairs(marks) do
      local d = m[4]
      if d.conceal ~= nil then
        saw_conceal = true
      end
      if d.virt_text and d.virt_text_pos == "overlay" then
        for _, chunk in ipairs(d.virt_text) do
          if chunk[1] == spec.word and chunk[2] == spec.hl then
            saw_overlay = true
          end
        end
      end
    end
    assert(saw_conceal, "no conceal mark on " .. spec.word .. " marker")
    assert(saw_overlay, "no overlay with " .. spec.word .. "/" .. spec.hl)
  end
end)

case("role rules read apart: per-role bar char + role-colored lead", function()
  local function overlay_chunks(lnum)
    for _, m in ipairs(marks_on_row(buf, lnum)) do
      local d = m[4]
      if d.virt_text and d.virt_text_pos == "overlay" then
        return d.virt_text
      end
    end
  end
  local user = overlay_chunks(LN.user_marker)
  local agent = overlay_chunks(LN.assistant_marker)
  local system = overlay_chunks(LN.system_marker)
  assert(user and agent and system, "missing role-rule overlay on a marker line")
  assert(user[1][1]:find("─", 1, true) and not user[1][1]:find("━", 1, true),
    "user lead must use the light ─ bar")
  assert(agent[1][1]:find("━", 1, true) and not agent[1][1]:find("─", 1, true),
    "agent lead must use the heavy ━ bar")
  assert(system[1][1]:find("─", 1, true) and not system[1][1]:find("━", 1, true),
    "system lead must use the light ─ bar")
  assert(user[1][2] == "StrapsRoleUser",
    "user lead must carry StrapsRoleUser, got " .. tostring(user[1][2]))
  assert(agent[1][2] == "StrapsRoleAgent",
    "agent lead must carry StrapsRoleAgent, got " .. tostring(agent[1][2]))
  assert(system[1][2] == "StrapsRoleSystem",
    "system lead must carry StrapsRoleSystem, got " .. tostring(system[1][2]))
  assert(agent[3][1]:find("━", 1, true) and not agent[3][1]:find("─", 1, true),
    "agent trailing run must keep the heavy ━ bar")
  assert(user[3][1]:find("─", 1, true) and not user[3][1]:find("━", 1, true),
    "user trailing run must keep the light ─ bar")
  assert(system[3][1]:find("─", 1, true) and not system[3][1]:find("━", 1, true),
    "system trailing run must keep the light ─ bar")
  assert(user[3][2] == "StrapsRule" and agent[3][2] == "StrapsRule" and system[3][2] == "StrapsRule",
    "trailing bars must stay dim StrapsRule")
end)

case("message body lines carry no render extmark", function()
  assert(#marks_on_row(buf, LN.user_body) == 0,
    "user body line has a render extmark (color must live only on marks)")
end)

case("tool marker lines are concealed with a command-style card header", function()
  local marks = marks_on_row(buf, LN.tool_use_ok)
  local saw_conceal, saw_verb, saw_args, saw_gear = false, false, false, false
  for _, m in ipairs(marks) do
    local d = m[4]
    if d.conceal ~= nil then saw_conceal = true end
    if d.virt_lines then
      for _, vl in ipairs(d.virt_lines) do
        for _, chunk in ipairs(vl) do
          -- header is now `╭─ $ echo hi ────`: verb `$` (StrapsTool), args
          -- ` echo hi` (StrapsRule), border art (StrapsCardBorder). No ⚙.
          if chunk[1] == "$" and chunk[2] == "StrapsTool" then saw_verb = true end
          if chunk[1]:find("echo hi", 1, true) and chunk[2] == "StrapsRule" then saw_args = true end
          if chunk[1]:find("⚙", 1, true) then saw_gear = true end
        end
      end
    end
  end
  assert(saw_conceal, "tool_use marker not concealed")
  assert(saw_verb, "card header missing command verb ($ / StrapsTool)")
  assert(saw_args, "card header missing dim args (echo hi / StrapsRule)")
  assert(not saw_gear, "card header must no longer show the ⚙ glyph")
end)

case("fn.render is idempotent", function()
  local function snapshot()
    local all = vim.api.nvim_buf_get_extmarks(buf, render_ns, 0, -1, { details = true })
    local out = {}
    for _, m in ipairs(all) do
      out[#out + 1] = { m[2], m[3], vim.inspect(m[4]) }
    end
    return out
  end
  local a = snapshot()
  registry.call("fn.render", buf)
  local b = snapshot()
  assert(vim.deep_equal(a, b), "extmark set changed across two renders")
end)

case("render leaves buffer text, modified and parse unchanged", function()
  assert(vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), before_text),
    "render mutated buffer text")
  assert(vim.bo[buf].modified == before_modified, "render changed the modified flag")
  assert(vim.inspect(state.parse(buf)) == before_parse, "parse differs after render")
end)

-- --------------------------------------------------------------- fold summary
case("fold summary is a command-style colored chunk list — ok result", function()
  -- bash tool_use at line 10 with {"command":"echo hi"} now folds to
  -- `▸ $ echo hi   ✓`: `$` verb (StrapsTool), ` echo hi` args (StrapsRule).
  local chunks = ui._fold_summary(buf, LN.tool_use_ok)
  local saw_verb, saw_args, saw_ok = false, false, false
  for _, c in ipairs(chunks) do
    if c[1] == "$" and c[2] == "StrapsTool" then saw_verb = true end
    if c[1]:find("echo hi", 1, true) and c[2] == "StrapsRule" then saw_args = true end
    if c[1] == "✓" and c[2] == "StrapsToolOk" then saw_ok = true end
    if c[1] == "✗" then error("ok result shows an error mark") end
    if c[1]:find("⚙", 1, true) then error("bash summary must not show the ⚙ glyph") end
  end
  assert(saw_verb, "summary missing $ verb / StrapsTool")
  assert(saw_args, "summary missing echo hi args / StrapsRule")
  assert(saw_ok, "summary missing ✓ / StrapsToolOk")
end)

case("fold summary reads is_error from the tool_result — error case", function()
  -- grep tool_use at line 18 (is_error) folds to `▸ grep "boom"   ✗`.
  local chunks = ui._fold_summary(buf, LN.tool_use_err)
  local saw_verb, saw_err = false, false
  for _, c in ipairs(chunks) do
    if c[1] == "grep" and c[2] == "StrapsTool" then saw_verb = true end
    if c[1] == "✗" and c[2] == "StrapsToolError" then saw_err = true end
    if c[1] == "✓" then error("error result shows an ok mark") end
    if c[1]:find("⚙", 1, true) then error("grep summary must not show the ⚙ glyph") end
  end
  assert(saw_verb, "summary missing grep verb / StrapsTool")
  assert(saw_err, "summary missing ✗ / StrapsToolError")
end)

-- --------------------------------------------------------- fn.tool_display
case("fn.tool_display renders each builtin as a command-style line", function()
  local td = function(name, input) return registry.call("fn.tool_display", name, input) end
  local want = {
    { "bash", { command = "echo hi" }, "$ echo hi" },
    { "bash", { command = "echo hi\necho bye" }, "$ echo hi ⏎…" },
    { "read_file", { path = "foo.lua" }, "read foo.lua" },
    { "read_file", { path = "foo.lua", offset = 10, limit = 20 }, "read foo.lua:10+20" },
    { "write_file", { path = "foo.lua", content = "l1\nl2" }, "write foo.lua (2 lines)" },
    { "edit_file", { path = "foo.lua" }, "edit foo.lua" },
    { "glob", { pattern = "**/*.lua" }, "glob **/*.lua" },
    { "grep", { pattern = "boom" }, 'grep "boom"' },
    { "grep", { pattern = "boom", path = "lua/" }, 'grep "boom" lua/' },
    { "registry_get", { name = "tool.bash" }, "registry get tool.bash" },
    { "registry_list", {}, "registry list" },
    { "registry_define", { name = "hook.after_write", kind = "hook" }, "define hook.after_write (hook)" },
    { "eval_lua", { code = "return 1 + 1\nmore" }, "lua return 1 + 1" },
  }
  for _, w in ipairs(want) do
    local got = td(w[1], w[2])
    assert(got == w[3], ("%s -> %q, want %q"):format(w[1], tostring(got), w[3]))
  end
  -- unknown/agent-defined tool: falls back to name + a compact preview.
  local unknown = td("my_tool", { alpha = "value" })
  assert(type(unknown) == "string" and unknown:find("my_tool", 1, true),
    "unknown tool display should contain the name, got " .. tostring(unknown))
end)

case("fn.tool_display is defensive: bad/missing input never errors", function()
  local td = function(name, input) return registry.call("fn.tool_display", name, input) end
  for _, input in ipairs({ vim.empty_dict(), {}, }) do
    local ok, out = pcall(td, "bash", input)
    assert(ok and type(out) == "string", "bash with empty input should return a string")
  end
  local ok_nil, out_nil = pcall(td, "bash", nil)
  assert(ok_nil and type(out_nil) == "string", "bash with nil input should return a string")
  local ok_wt, out_wt = pcall(td, "read_file", "not-a-table")
  assert(ok_wt and type(out_wt) == "string", "wrong-typed input should return a string")
end)

case("a broken fn.tool_display redefinition can't break fn.render", function()
  local reg = require("straps.registry")
  local original = reg.get("fn.tool_display").source
  reg.define({
    name = "fn.tool_display",
    kind = "fn",
    source = "return function() error('boom') end",
  })
  local buf2 = make_buf()
  local ok = pcall(function()
    -- render must not throw even though the formatter always errors...
    registry.call("fn.render", buf2)
    -- ...and the fold summary falls back to the bare tool name (no crash).
    local chunks = ui._fold_summary(buf2, LN.tool_use_ok)
    local saw_verb = false
    for _, c in ipairs(chunks) do
      if c[1] == "bash" and c[2] == "StrapsTool" then saw_verb = true end
    end
    assert(saw_verb, "broken formatter should fall back to the tool name verb")
  end)
  reg.define({ name = "fn.tool_display", kind = "fn", source = original }) -- restore
  assert(ok, "broken fn.tool_display propagated an error into rendering")
end)

case("redefining fn.tool_display changes the next fold summary (late-bound)", function()
  local reg = require("straps.registry")
  local original = reg.get("fn.tool_display").source
  reg.define({ name = "fn.tool_display", kind = "fn", source = "return function() return 'XX' end" })
  local chunks = ui._fold_summary(buf, LN.tool_use_ok)
  local saw_xx = false
  for _, c in ipairs(chunks) do
    if c[1] == "XX" and c[2] == "StrapsTool" then saw_xx = true end
  end
  assert(saw_xx, "redefined fn.tool_display not picked up by the next _fold_summary")
  -- restore the shipped formatter
  reg.define({ name = "fn.tool_display", kind = "fn", source = original })
  local restored = ui._fold_summary(buf, LN.tool_use_ok)
  local saw_dollar = false
  for _, c in ipairs(restored) do
    if c[1] == "$" and c[2] == "StrapsTool" then saw_dollar = true end
  end
  assert(saw_dollar, "restore of fn.tool_display failed")
end)

-- ------------------------------------------------------------- config.render
case("config.render = false places no extmarks", function()
  local prev = straps.config.render
  straps.config.render = false
  local b2 = make_buf()
  registry.call("fn.render", b2)
  local marks = vim.api.nvim_buf_get_extmarks(b2, render_ns, 0, -1, {})
  straps.config.render = prev
  assert(#marks == 0, "render placed " .. #marks .. " extmarks with render=false")
end)

-- --------------------------------------------------------------- foldexpr/text
case("foldexpr merges a tool_use/tool_result pair into one fold", function()
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor", width = 40, height = 20, row = 1, col = 1,
  })
  vim.wo[win].foldmethod = "expr"
  vim.wo[win].foldexpr = "v:lua.require'straps.ui'.foldexpr(v:lnum)"
  vim.wo[win].foldlevel = 0 -- tool machinery closed (the default)
  vim.cmd("normal! zx")
  -- The tool_result marker line belongs to the fold opened at the tool_use.
  assert(vim.fn.foldlevel(LN.tool_use_ok) == 1, "tool_use should open a level-1 fold")
  assert(vim.fn.foldlevel(LN.tool_result_ok) == 1, "tool_result should stay in the fold")
  assert(vim.fn.foldclosed(LN.tool_result_ok) == vim.fn.foldclosed(LN.tool_use_ok),
    "tool_use and tool_result are not in the same fold")
  assert(vim.fn.foldclosed(LN.tool_use_ok) == LN.tool_use_ok,
    "at the default foldlevel the tool call should be closed")
  -- ... while the conversation itself never folds.
  assert(vim.fn.foldlevel(LN.user_marker) == 0, "user marker must not open a fold")
  assert(vim.fn.foldlevel(LN.assistant_marker) == 0, "assistant marker must not open a fold")
  assert(vim.fn.foldclosed(LN.user_body) == -1, "user turn should never be folded")
  -- zM must not swallow the conversation either: turns have no folds to close.
  vim.cmd("normal! zM")
  assert(vim.fn.foldclosed(LN.user_marker) == -1, "zM must not hide the conversation")
  vim.api.nvim_win_close(win, true)
end)

case("outline headline prefers text typed on the marker line itself", function()
  -- block_headline feeds M.outline (gO); turns no longer fold, so assert the
  -- marker-line preference through the outline's loclist text.
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, {
    "%%[straps:user]%% typed on the marker", "body line",
  })
  vim.cmd("split")
  local w = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(w, b)
  assert(ui.outline(b) == 1, "expected one turn in the outline")
  local text = vim.fn.getloclist(w)[1].text
  assert(text:find("typed on the marker", 1, true), "inline marker text should be the headline: " .. text)
  assert(not text:find("body line", 1, true), "body should not win over inline text: " .. text)
  vim.api.nvim_win_close(w, true)
end)

case("system block folds to a labelled summary (not shown inline in full)", function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "%%[straps:system]%%", "line one", "line two", "line three",
    "%%[straps:user]%%", "hi",
  })
  local chunks = ui._fold_summary(buf, 1) -- system marker is line 1
  local text, hls = "", {}
  for _, c in ipairs(chunks) do text = text .. c[1]; hls[c[2]] = true end
  assert(text:find("system prompt", 1, true), "system summary missing label: " .. text)
  assert(text:find("3 lines", 1, true), "system summary should count content lines: " .. text)
  assert(hls["StrapsRoleSystem"], "system label should use StrapsRoleSystem")
  assert(not text:find("⚙", 1, true), "system summary must not look like a tool call")
  -- foldexpr reads the current buffer via getline(), so make it current
  vim.api.nvim_set_current_buf(buf)
  assert(ui.foldexpr(1) == ">1", "system marker should open a level-1 fold")
  assert(ui.foldexpr(5) == 0, "the following user marker must not open a fold")
end)

case("the system block starts folded closed", function()
  local sbuf = vim.api.nvim_create_buf(false, true)
  vim.bo[sbuf].filetype = "straps"
  vim.api.nvim_buf_set_lines(sbuf, 0, -1, false, {
    "%%[straps:system]%%", "sys one", "sys two", "",
    "%%[straps:user]%%", "hello", "",
    "%%[straps:assistant]%%", "hi", "",
  })
  vim.cmd("split")
  local w = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(w, sbuf)
  ui.apply_fold_opts(sbuf)
  assert(vim.fn.foldclosed(1) == 1, "the system block should start closed, got " .. vim.fn.foldclosed(1))
  assert(vim.fn.foldclosed(5) == -1, "the conversation should still start open")
  -- It must stay closed as the transcript grows (appends are the normal case).
  vim.api.nvim_buf_set_lines(sbuf, -1, -1, false, { "%%[straps:user]%%", "more" })
  assert(vim.fn.foldclosed(1) == 1, "the system fold should survive an append")
  -- zR still opens everything; zM never touches the conversation (no turn folds).
  vim.cmd("normal! zR")
  assert(vim.fn.foldclosed(1) == -1, "zR should open the system fold")
  vim.cmd("normal! zM")
  assert(vim.fn.foldclosed(5) == -1, "zM must not collapse conversation turns")
  vim.api.nvim_win_close(w, true)
end)

case("a transcript with no system block folds sanely too", function()
  local nbuf = vim.api.nvim_create_buf(false, true)
  vim.bo[nbuf].filetype = "straps"
  vim.api.nvim_buf_set_lines(nbuf, 0, -1, false, { "%%[straps:user]%%", "hello" })
  vim.cmd("split")
  local w = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(w, nbuf)
  ui.apply_fold_opts(nbuf)
  -- Turns never fold, so the conversation is never collapsed on you at open.
  assert(vim.fn.foldclosed(1) == -1, "a leading user turn must not start closed")
  vim.api.nvim_win_close(w, true)
end)

-- ------------------------------------------------------------- turn navigation
case("]] / [[ step between conversation turns", function()
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor", width = 60, height = 20, row = 1, col = 1,
  })
  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  assert(ui.goto_turn(1, 1), "forward motion should move")
  assert(vim.api.nvim_win_get_cursor(win)[1] == LN.user_marker,
    "first ]] should land on the user turn, got " .. vim.api.nvim_win_get_cursor(win)[1])
  assert(ui.goto_turn(1, 1), "second forward motion should move")
  assert(vim.api.nvim_win_get_cursor(win)[1] == LN.assistant_marker,
    "second ]] should land on the assistant turn")
  -- count is honored, and tool markers are never targets.
  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  assert(ui.goto_turn(1, 2), "count-2 motion should move")
  assert(vim.api.nvim_win_get_cursor(win)[1] == LN.assistant_marker,
    "2]] should skip to the second turn")
  assert(ui.goto_turn(-1, 1), "backward motion should move")
  assert(vim.api.nvim_win_get_cursor(win)[1] == LN.user_marker, "[[ should go back one turn")
  assert(ui.goto_turn(-1, 1) == false, "no turn before the first: should decline")
  vim.api.nvim_win_set_cursor(win, { LN.assistant_marker, 0 })
  assert(ui.goto_turn(1, 1) == false, "no turn after the last: should decline")
  vim.api.nvim_win_close(win, true)
end)

case("gO outlines the transcript into the findings list", function()
  -- A real split, not a float: set_locations only routes to a window's private
  -- location list for non-floating session windows (ui.session_win).
  vim.cmd("split")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  local n = ui.outline(buf)
  assert(n == 2, "expected 2 turns in the outline, got " .. tostring(n))
  local items = vim.fn.getloclist(win)
  assert(#items == 2, "loclist should hold the turns, got " .. #items)
  assert(items[1].lnum == LN.user_marker, "first entry should point at the user marker")
  assert(items[1].text:find("you", 1, true) and items[1].text:find("hello there", 1, true),
    "first entry should read as role + headline: " .. items[1].text)
  assert(items[2].lnum == LN.assistant_marker, "second entry should point at the assistant marker")
  assert(items[2].text:find("2 tools", 1, true),
    "assistant entry should note its tool calls: " .. items[2].text)
  assert(vim.fn.getloclist(win, { title = 0 }).title == "straps: outline", "outline should title its list")
  vim.api.nvim_win_close(win, true)
end)

-- state.new_session/open_session_file set filetype=straps on a buffer that
-- has no window yet, so the FileType autocmd's vim.opt_local (window-local
-- fold options) had nothing to attach to; a session opened via
-- ui.open_session() ended up with foldmethod=manual and no folds at all.
-- open_session_buffer must re-apply the fold options once the buffer is
-- actually in a window.
case("ui.open_session()'s window actually gets fold options and navigation maps", function()
  local sbuf = ui.open_session()
  local w = vim.fn.win_findbuf(sbuf)[1]
  assert(w, "open_session should leave the buffer in a window")
  assert(vim.wo[w].foldmethod == "expr", "foldmethod should be expr, got " .. vim.wo[w].foldmethod)
  assert(vim.wo[w].foldexpr ~= "", "foldexpr should be set")
  assert(vim.wo[w].foldlevel == 0,
    "tools_expanded defaults false: foldlevel should be 0 (tools closed), got "
    .. vim.wo[w].foldlevel)
  local maps = {}
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(sbuf, "n")) do maps[m.lhs] = true end
  for _, lhs in ipairs({ "]]", "[[", "gO" }) do
    assert(maps[lhs], "session buffer should map " .. lhs)
  end
  vim.api.nvim_win_close(w, true)
end)

-- A window option in Neovim carries TWO values: a per-(window, buffer) one
-- (`&l:`, what `:setlocal` writes) and a per-window one (`&g:`, what `:set`
-- writes in addition). straps used the plain `vim.wo[w].opt = v`, which is
-- `:set`, so the transcript's options landed on the per-window value too. That
-- value outlives the session buffer in that window: a split off the session
-- window, or any file swapped into it (gf, :edit, <C-o>), then folded by the
-- straps foldexpr with conceallevel=2 — the user's source file wearing the
-- transcript's fold rules, which reads as "my folds broke". `vim.wo[w][0]` is
-- `:setlocal`: per-(window, buffer) only. Every window-option write in straps
-- must use that form, and these cases assert on the per-window value directly,
-- since that is the dimension the bug lived in.
local function per_window(win, name)
  return vim.api.nvim_win_call(win, function() return vim.fn.eval("&g:" .. name) end)
end
local function per_window_buffer(win, name)
  return vim.api.nvim_win_call(win, function() return vim.fn.eval("&l:" .. name) end)
end

-- Each case sets EVERY option it checks to a user value that differs from the
-- straps one, or the assertion cannot fail: a user global that already equals
-- what straps writes (foldlevel 0, relativenumber false) pins nothing.
case("session window options are per-(window,buffer), never per-window", function()
  local user = { foldmethod = "indent", foldexpr = "0", foldtext = "foldtext()",
    foldlevel = 7, conceallevel = 0, concealcursor = "" }
  local prev = {}
  for name, val in pairs(user) do
    prev[name] = vim.api.nvim_get_option_value(name, { scope = "global" })
    vim.api.nvim_set_option_value(name, val, { scope = "global" })
  end

  local sbuf = ui.open_session()
  local w = vim.fn.win_findbuf(sbuf)[1]
  assert(w, "open_session should leave the buffer in a window")
  -- The straps options ARE applied, on the per-(window, buffer) value...
  assert(per_window_buffer(w, "foldmethod") == "expr",
    "session window should fold by expr, got " .. tostring(per_window_buffer(w, "foldmethod")))
  assert(tostring(per_window_buffer(w, "foldexpr")):find("straps", 1, true),
    "session window should use the straps foldexpr, got " .. tostring(per_window_buffer(w, "foldexpr")))
  assert(tostring(per_window_buffer(w, "foldtext")):find("straps", 1, true),
    "session window should use the straps foldtext, got " .. tostring(per_window_buffer(w, "foldtext")))
  assert(per_window_buffer(w, "foldlevel") == 0,
    "tools_expanded defaults false: foldlevel should be 0, got " .. tostring(per_window_buffer(w, "foldlevel")))
  assert(per_window_buffer(w, "conceallevel") == 2,
    "session window should conceal markers, got " .. tostring(per_window_buffer(w, "conceallevel")))
  assert(per_window_buffer(w, "concealcursor") == "nc",
    "session window should set concealcursor, got " .. tostring(per_window_buffer(w, "concealcursor")))
  -- ...and every per-window value still holds the USER's setting, so none of
  -- them can follow the window onto another buffer.
  for name, want in pairs(user) do
    assert(per_window(w, name) == want,
      ("per-window '%s' leaked: %s (user set %s)"):format(name,
        tostring(per_window(w, name)), tostring(want)))
  end

  for name, val in pairs(prev) do
    vim.api.nvim_set_option_value(name, val, { scope = "global" })
  end
  vim.api.nvim_win_close(w, true)
end)

case("agents window options are per-(window,buffer), never per-window", function()
  local user = { wrap = true, cursorline = false, number = true,
    relativenumber = true, signcolumn = "yes", foldcolumn = "4" }
  local straps_side = { wrap = 0, cursorline = 1, number = 0,
    relativenumber = 0, signcolumn = "no", foldcolumn = "0" }
  local prev = {}
  for name, val in pairs(user) do
    prev[name] = vim.api.nvim_get_option_value(name, { scope = "global" })
    vim.api.nvim_set_option_value(name, val, { scope = "global" })
  end

  local abuf = ui.open_agents()
  local w = vim.fn.win_findbuf(abuf)[1]
  assert(w, "open_agents should leave the buffer in a window")
  for name, want in pairs(straps_side) do
    assert(per_window_buffer(w, name) == want,
      ("agents window should set %s=%s, got %s"):format(name, tostring(want),
        tostring(per_window_buffer(w, name))))
  end
  for name, val in pairs(user) do
    local want = (val == true and 1) or (val == false and 0) or val
    assert(per_window(w, name) == want,
      ("per-window '%s' leaked: %s (user set %s)"):format(name,
        tostring(per_window(w, name)), tostring(want)))
  end

  for name, val in pairs(prev) do
    vim.api.nvim_set_option_value(name, val, { scope = "global" })
  end
  vim.api.nvim_win_close(w, true)
end)

-- The two cases above cover the windows a test can open and inspect. The
-- remaining write sites (editor.lua's ask_user float) live behind a blocking
-- picker, so they are pinned statically instead: every window-option write in
-- the plugin's own source must use the `vim.wo[...][0]` form. This also catches
-- a NEW site added later, which a per-window case never would.
case("every window-option write in the source uses the :setlocal form", function()
  local offenders = {}
  for _, rel in ipairs({ "lua/straps/ui.lua", "lua/straps/editor.lua", ".straps.lua" }) do
    local path = root .. "/" .. rel
    if vim.fn.filereadable(path) == 1 then
      for lnum, line in ipairs(vim.fn.readfile(path)) do
        -- `vim.wo[<idx>].<opt> =` with no `[0]` between them is the `:set`
        -- form. Skip comment lines: the doc-comments here spell the rule out
        -- using the very form they warn against.
        local code = not line:match("^%s*%-%-")
        local opt = code and line:match("vim%.wo%[[^%]]*%]%.([%w_]+)%s*=[^=]")
        local ok_opt, info = false, nil
        if opt then
          ok_opt, info = pcall(vim.api.nvim_get_option_info2, opt, {})
        end
        if ok_opt and info then
          -- A global-local option (winbar, statusline) is already :setlocal
          -- under this form, so it is not an offender.
          if info.scope == "win" and not info.global_local then
            offenders[#offenders + 1] = ("%s:%d %s"):format(rel, lnum, opt)
          end
        end
      end
    end
  end
  assert(#offenders == 0,
    "window options written with the :set form (use vim.wo[w][0]): "
    .. table.concat(offenders, ", "))
end)

print(failed and "FAILED" or "ALL PASS")
os.exit(failed and 1 or 0)
