-- tests/ui_fixes_spec.lua — user commands, keymaps, windows and highlights.
-- Run from the repo root: busted tests/ui_fixes_spec.lua

local script = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(vim.fn.fnamemodify(script, ":p"), ":h:h")
vim.opt.runtimepath:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local straps = require("straps").setup({})
straps.config.session_dir = vim.fn.tempname()
local registry = require("straps.registry")
local state = require("straps.state")
local loop = require("straps.loop")
local ui = require("straps.ui")
vim.cmd("source " .. vim.fn.fnameescape(root .. "/plugin/straps.lua"))

local function capture(fn)
  local notes, real = {}, vim.notify
  vim.notify = function(msg, level) notes[#notes + 1] = { msg = tostring(msg), level = level } end
  local ok, err = pcall(fn)
  vim.notify = real
  assert(ok, tostring(err))
  return notes
end

local function only_window()
  vim.cmd("silent! only!")
  vim.cmd("enew!")
end

local function session_in_split()
  only_window()
  local b = state.new_session()
  ui.show_session(b)
  return b
end

it("session winbars release the row on buffer leave and restore on return", function()
  only_window()
  local source = vim.api.nvim_get_current_buf()
  local session = state.new_session()
  vim.o.winbar = ""
  vim.api.nvim_set_option_value("winbar", "", { scope = "local" })
  ui.show_session(session, "none")
  local expr = vim.wo.winbar
  assert(expr:find("straps.ui'.winbar", 1, true))
  vim.api.nvim_win_set_buf(0, source)
  assert.are.equal("", vim.wo.winbar)
  vim.api.nvim_win_set_buf(0, session)
  assert.are.equal(expr, vim.wo.winbar)
  vim.wo.winbar = expr
  vim.api.nvim_win_set_buf(0, source)
  assert.are.equal("", vim.wo.winbar)
  vim.api.nvim_win_set_buf(0, session)
  vim.api.nvim_exec_autocmds("WinLeave", {})
  assert.are.equal("", vim.api.nvim_get_option_value("winbar", { scope = "local" }))
  vim.api.nvim_exec_autocmds("WinEnter", {})
  assert.are.equal(expr, vim.wo.winbar)
  vim.api.nvim_set_option_value("winbar", "custom local", { scope = "local" })
  vim.api.nvim_win_set_buf(0, source)
  assert.are.equal("", vim.wo.winbar)
  vim.api.nvim_win_set_buf(0, session)
  assert.are.equal("custom local", vim.wo.winbar)
  vim.api.nvim_set_option_value("winbar", "", { scope = "local" })
end)

it("session winbars preserve a replacement set in the departing ordinary buffer", function()
  only_window()
  local source = vim.api.nvim_get_current_buf()
  vim.o.winbar = ""
  vim.api.nvim_set_option_value("winbar", "", { scope = "local" })
  local session = state.new_session()
  ui.show_session(session, "none")
  local expr = vim.wo.winbar
  vim.api.nvim_win_set_buf(0, source)
  vim.api.nvim_win_set_buf(0, session)
  assert.are.equal(expr, vim.wo.winbar)
  vim.api.nvim_win_set_buf(0, source)
  vim.api.nvim_set_option_value("winbar", "changed custom", { scope = "local" })
  vim.api.nvim_win_set_buf(0, session)
  assert.are.equal("changed custom", vim.wo.winbar)
  vim.api.nvim_win_set_buf(0, source)
  assert.are.equal("changed custom", vim.wo.winbar)
  vim.api.nvim_win_set_buf(0, session)
  assert.are.equal("changed custom", vim.wo.winbar)
  vim.api.nvim_set_option_value("winbar", "", { scope = "local" })
end)

it("session winbars reinstall after clearing a restored ordinary-buffer replacement", function()
  only_window()
  local source = vim.api.nvim_get_current_buf()
  vim.o.winbar = ""
  vim.api.nvim_set_option_value("winbar", "", { scope = "local" })
  local session = state.new_session()
  ui.show_session(session, "none")
  local expr = vim.wo.winbar
  for cycle = 1, 3 do
    local custom = "source custom " .. cycle
    vim.api.nvim_win_set_buf(0, source)
    vim.api.nvim_set_option_value("winbar", custom, { scope = "local" })
    vim.api.nvim_win_set_buf(0, session)
    assert.are.equal(custom, vim.wo.winbar)
    vim.api.nvim_win_set_buf(0, source)
    assert.are.equal(custom, vim.wo.winbar)
    vim.api.nvim_set_option_value("winbar", "", { scope = "local" })
    vim.api.nvim_win_set_buf(0, session)
    assert.are.equal(expr, vim.wo.winbar)
    vim.api.nvim_win_set_buf(0, source)
    assert.are.equal("", vim.api.nvim_get_option_value("winbar", { scope = "local" }))
    vim.api.nvim_win_set_buf(0, session)
    assert.are.equal(expr, vim.wo.winbar)
  end
end)

it("session winbars restore the user's local and global values", function()
  only_window()
  local source = vim.api.nvim_get_current_buf()
  vim.o.winbar = "global bar"
  vim.api.nvim_set_option_value("winbar", "local bar", { scope = "local" })
  local session = state.new_session()
  ui.show_session(session, "none")
  vim.api.nvim_win_set_buf(0, source)
  assert.are.equal("global bar", vim.go.winbar)
  assert.are.equal("local bar", vim.api.nvim_get_option_value("winbar", { scope = "local" }))
  vim.go.winbar = "new global"
  vim.api.nvim_set_option_value("winbar", "", { scope = "local" })
  vim.api.nvim_win_set_buf(0, session)
  vim.api.nvim_win_set_buf(0, source)
  assert.are.equal("new global", vim.go.winbar)
  assert.are.equal("", vim.api.nvim_get_option_value("winbar", { scope = "local" }))
  vim.go.winbar = ""
end)

it("4: :StrapsEdit reuses the exact-name buffer, not a prefix match, and splits", function()
  only_window()
  local decoy = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(decoy, "straps://registry/tool.bash.extra")
  local wins = #vim.api.nvim_tabpage_list_wins(0)
  vim.cmd("StrapsEdit tool.bash")
  local b = vim.api.nvim_get_current_buf()
  assert.are_not.equal(decoy, b)
  assert.are.equal("straps://registry/tool.bash", vim.api.nvim_buf_get_name(b))
  assert.are.equal(wins + 1, #vim.api.nvim_tabpage_list_wins(0))
  vim.cmd("wincmd p")
  vim.cmd("StrapsEdit tool.bash")
  assert.are.equal(wins + 1, #vim.api.nvim_tabpage_list_wins(0))
  assert.are.equal(b, vim.api.nvim_get_current_buf())
end)

it("4/14: :vertical StrapsEdit and :vertical StrapsRegistry honor <mods>", function()
  only_window()
  vim.cmd("vertical StrapsRegistry")
  assert.are.equal("row", vim.fn.winlayout()[1])
  only_window()
  vim.cmd("vertical StrapsEdit fn.render")
  assert.are.equal("row", vim.fn.winlayout()[1])
end)

it("14: :StrapsResume! passes <mods> to the picked session's window", function()
  only_window()
  local b = state.new_session()
  local path = vim.api.nvim_buf_get_name(b)
  local real_rich, real_pick = ui._pick_session_rich, ui.pick
  ui._pick_session_rich = function() return false end
  ui.pick = function(items, _, on_choice)
    for _, s in ipairs(items) do
      if s.path == path then return on_choice(s) end
    end
  end
  local ok, err = pcall(vim.cmd, "vertical StrapsResume!")
  ui._pick_session_rich, ui.pick = real_rich, real_pick
  assert(ok, tostring(err))
  assert.are.equal("row", vim.fn.winlayout()[1])
end)

it("14: pick_agents passes split_cmd to show_session", function()
  only_window()
  local b = state.new_session()
  local real_running, real_pick = loop.running_sessions, ui.pick
  loop.running_sessions = function() return { b } end
  ui.pick = function(items, _, on_choice) on_choice(items[1]) end
  local ok, err = pcall(ui.pick_agents, "vsplit")
  loop.running_sessions, ui.pick = real_running, real_pick
  assert(ok, tostring(err))
  assert.are.equal("row", vim.fn.winlayout()[1])
end)

it("15: show_session focuses a window already showing the session", function()
  local b = session_in_split()
  local wins = #vim.api.nvim_tabpage_list_wins(0)
  vim.cmd("wincmd p")
  ui.show_session(b)
  assert.are.equal(wins, #vim.api.nvim_tabpage_list_wins(0))
  assert.are.equal(b, vim.api.nvim_get_current_buf())
end)

it("22: show_session keeps the user's foldlevel on a window already showing the session", function()
  local b = session_in_split()
  vim.wo[0][0].foldlevel = 5
  vim.cmd("wincmd p")
  ui.show_session(b)
  assert.are.equal(5, vim.wo[0].foldlevel)
end)

it("native session redisplay configures folds and preserves other windows' fold choices", function()
  only_window()
  local source = vim.api.nvim_get_current_buf()
  vim.wo[0][0].foldmethod = "manual"
  vim.wo[0][0].foldexpr = "0"
  local b = state.new_session()
  vim.api.nvim_buf_set_lines(b, 0, -1, false, {
    "%%[straps:tool_use]%%", "{}", "%%[straps:tool_result]%%", "first",
    "%%[straps:user]%%", "hi", "%%[straps:tool_use]%%", "{}",
    "%%[straps:tool_result]%%", "second", "%%[straps:user]%%", "bye",
  })
  ui.show_session(b)
  local original = vim.api.nvim_get_current_win()
  vim.wo[0][0].foldlevel = 1
  vim.cmd("normal! zR")
  vim.cmd("7foldclose")
  vim.wo[0][0].foldlevel = 0
  vim.cmd("1foldopen")
  local function check_choices()
    assert.are.equal(0, vim.wo[original].foldlevel)
    vim.api.nvim_win_call(original, function()
      assert.are.equal(-1, vim.fn.foldclosed(2))
      assert.are.equal(7, vim.fn.foldclosed(8))
    end)
  end
  vim.cmd("wincmd p")
  vim.cmd("vsplit")
  local target = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(target, b)
  assert.are.equal("expr", vim.wo[target].foldmethod)
  assert.are.equal("v:lua.require'straps.ui'.foldexpr(v:lnum)", vim.wo[target].foldexpr)
  assert.are.equal("v:lua.require'straps.ui'.foldtext()", vim.wo[target].foldtext)
  assert.are.equal(1, vim.fn.foldlevel(2))
  vim.cmd("normal! zM")
  assert.are.equal(1, vim.fn.foldclosed(2))
  check_choices()
  vim.api.nvim_set_current_win(original)
  check_choices()
  vim.api.nvim_set_current_win(target)
  vim.api.nvim_win_set_buf(target, source)
  assert.are.equal("manual", vim.wo[target].foldmethod)
  assert.are.equal("0", vim.wo[target].foldexpr)
  vim.api.nvim_win_set_buf(target, b)
  assert.are.equal(1, vim.fn.foldlevel(2))
  check_choices()
  vim.cmd("vsplit")
  assert.are.equal(1, vim.fn.foldlevel(2))
  check_choices()
end)

it("native session redisplay installs folds without setup", function()
  local script = vim.fn.tempname() .. ".lua"
  vim.fn.writefile(vim.split(([[
vim.opt.runtimepath:prepend(ROOT)
vim.cmd("filetype plugin on")
local source = vim.api.nvim_get_current_buf()
vim.wo[0][0].foldmethod = "manual"
vim.wo[0][0].foldexpr = "0"
local b = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_lines(b, 0, -1, false, {
  "%%[straps:tool_use]%%", "{}", "%%[straps:tool_result]%%", "result", "%%[straps:user]%%", "hi",
})
vim.api.nvim_win_set_buf(0, b)
vim.bo[b].filetype = "straps"
vim.cmd("vsplit")
vim.api.nvim_win_set_buf(0, source)
vim.cmd("vsplit")
vim.api.nvim_win_set_buf(0, b)
assert(vim.fn.foldlevel(2) == 1)
vim.cmd("normal! zM")
assert(vim.fn.foldclosed(2) == 1)
io.stdout:write("folds restored")
]]):gsub("ROOT", string.format("%q", root)), "\n"), script)
  local res = vim.system({ vim.v.progpath, "--headless", "-u", "NONE", "-l", script }, { text = true }):wait(20000)
  vim.fn.delete(script)
  assert.are.equal(0, res.code, res.stderr)
  assert.are.equal("folds restored", res.stdout)
end)

it("6: gf fallback failure is reported, not swallowed", function()
  local b = session_in_split()
  vim.api.nvim_buf_set_lines(b, -1, -1, false, { "no_such_file_qq.txt" })
  vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(b), 2 })
  local notes = capture(function() vim.cmd("normal gf") end)
  assert(#notes >= 1, "no notify on gf failure")
  assert.are.equal(vim.log.levels.WARN, notes[1].level)
  assert(notes[1].msg:find("E447", 1, true), notes[1].msg)
  vim.api.nvim_buf_set_lines(b, -2, -1, false, {})
end)

it("11: a hand-opened .straps file gets every session keymap, and undo_ftplugin removes them", function()
  only_window()
  local path = vim.fn.tempname() .. ".straps"
  vim.fn.writefile({ "%%[straps:user]%%", "hi" }, path)
  vim.cmd("filetype plugin on")
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  vim.bo.filetype = "straps"
  local b = vim.api.nvim_get_current_buf()
  assert.are.equal("straps", vim.bo[b].filetype)
  for _, lhs in ipairs(ui.SESSION_KEYS) do
    assert(vim.fn.maparg(lhs, "n", false, true).buffer == 1, lhs .. " not mapped")
  end
  assert.are.equal("expr", vim.wo[0].foldmethod)
  assert.is_true(vim.wo[0].linebreak)
  vim.bo[b].filetype = "text"
  for _, lhs in ipairs(ui.SESSION_KEYS) do
    assert(vim.fn.maparg(lhs, "n", false, true).buffer ~= 1, lhs .. " still mapped after ft change")
  end
  assert.are_not.equal("expr", vim.wo[0].foldmethod)
  assert.is_false(vim.wo[0].linebreak)
  assert.are.equal(vim.go.formatlistpat, vim.bo[b].formatlistpat)
  assert.are.equal(vim.go.omnifunc, vim.bo[b].omnifunc)
end)

it("8: :StrapsSteer with no run puts the text in the trailing user block and warns", function()
  local b = session_in_split()
  local notes = capture(function() vim.cmd("StrapsSteer look at  foo.lua") end)
  assert.are.equal("look at  foo.lua", state.last_user_text(b))
  assert.are.equal(vim.log.levels.WARN, notes[#notes].level)
  assert(notes[#notes].msg:find("trailing user block", 1, true), notes[#notes].msg)
  capture(function() vim.cmd("StrapsSteer second") end)
  assert.are.equal("look at  foo.lua\n\nsecond", state.last_user_text(b))
end)

it("9: an unknown :Straps category hints at `--`", function()
  local notes = capture(function() vim.cmd("Straps fix the bug") end)
  assert(notes[1].msg:find("after `--`", 1, true), notes[1].msg)
end)

it("10: :StrapsAuto completes from grantable categories and accepts all", function()
  local done = vim.fn.getcompletion("StrapsAuto ", "cmdline")
  for _, c in ipairs(ui.grantable_categories()) do
    assert(vim.tbl_contains(done, c), c .. " missing from completion: " .. vim.inspect(done))
  end
  assert(vim.tbl_contains(done, "all"), "all missing from completion")
  local b = session_in_split()
  capture(function() vim.cmd("StrapsAuto all") end)
  for _, c in ipairs(ui.grantable_categories()) do
    assert(registry.granted(b)["cap:" .. c], c .. " not granted by all")
  end
end)

it("17: StrapsAuto desc has the straps: prefix", function()
  assert(vim.api.nvim_get_commands({}).StrapsAuto.definition:find("^straps:"))
end)

it("18: every session-only command warns with one shared message off a session", function()
  only_window()
  for _, cmd in ipairs({ "StrapsSend", "StrapsSendNow", "StrapsSteer x", "StrapsStop", "StrapsContinue", "StrapsCompact",
    "StrapsRename t", "StrapsAuto" }) do
    local notes = capture(function() vim.cmd(cmd) end)
    assert.are.equal(1, #notes, cmd)
    assert.are.equal(ui.NOT_A_SESSION, notes[1].msg, cmd)
    assert.are.equal(vim.log.levels.WARN, notes[1].level, cmd)
  end
end)

it("26: session-only commands act on the single visible session window", function()
  local b = session_in_split()
  vim.cmd("wincmd p")
  assert.are_not.equal(b, vim.api.nvim_get_current_buf())
  capture(function() vim.cmd("StrapsSteer from elsewhere") end)
  assert.are.equal("from elsewhere", state.last_user_text(b))
  capture(function() vim.cmd("StrapsAuto edit") end)
  assert(registry.granted(b)["cap:edit"], "StrapsAuto did not reach the visible session")
  local other = state.new_session()
  vim.cmd("split")
  vim.api.nvim_win_set_buf(0, other)
  vim.cmd("wincmd b")
  vim.cmd("enew")
  local notes = capture(function() vim.cmd("StrapsStop") end)
  assert.are.equal(ui.NOT_A_SESSION, notes[1].msg)
end)

it("19: :StrapsStop with no run warns", function()
  session_in_split()
  local notes = capture(function() vim.cmd("StrapsStop") end)
  assert.are.equal(vim.log.levels.WARN, notes[1].level)
end)

it("19: resume with no saved sessions warns and says it opened a new session", function()
  local saved = straps.config.session_dir
  straps.config.session_dir = vim.fn.tempname()
  vim.fn.mkdir(straps.config.session_dir, "p")
  only_window()
  local notes = capture(function() vim.cmd("StrapsResume") end)
  straps.config.session_dir = saved
  assert.are.equal(vim.log.levels.WARN, notes[1].level)
  assert(notes[1].msg:find("opened a new session", 1, true), notes[1].msg)
end)

it("20: :StrapsHelp completes every straps tag in doc/tags", function()
  local done = vim.fn.getcompletion("StrapsHelp straps-", "cmdline")
  for _, tag in ipairs({ "straps-agents", "straps-steering", "straps-highlights", "straps-config-model" }) do
    assert(vim.tbl_contains(done, tag), tag .. " missing: " .. #done .. " candidates")
  end
end)

it("21: StrapsProgress and StrapsWinbarNC link, and the ColorScheme re-link exists without ui.setup", function()
  assert.are.equal("Comment", vim.api.nvim_get_hl(0, { name = "StrapsProgress", link = true }).link)
  assert.are.equal("WinBar", vim.api.nvim_get_hl(0, { name = "StrapsWinbar", link = true }).link)
  assert.are.equal("WinBarNC", vim.api.nvim_get_hl(0, { name = "StrapsWinbarNC", link = true }).link)
  pcall(vim.api.nvim_del_augroup_by_name, "StrapsUI")
  assert.are.equal(1, #vim.api.nvim_get_autocmds({ event = "ColorScheme" }))
  vim.cmd("hi clear")
  vim.api.nvim_exec_autocmds("ColorScheme", {})
  assert.are.equal("Comment", vim.api.nvim_get_hl(0, { name = "StrapsProgress", link = true }).link)
end)

it("21: the progress virtual text uses StrapsProgress", function()
  local b = session_in_split()
  ui.progress(b, { type = "thinking" })
  local marks = vim.api.nvim_buf_get_extmarks(b, -1, 0, -1, { details = true })
  local found
  for _, m in ipairs(marks) do
    for _, chunk in ipairs(m[4].virt_text or {}) do
      if chunk[2] == "StrapsProgress" then found = true end
    end
  end
  ui.progress(b, { type = "done" })
  assert(found, "no StrapsProgress chunk")
end)

it("23: a session provider pick sends one notify that names :StrapsModel", function()
  local b = session_in_split()
  local real_pick = ui.pick
  ui.pick = function(_, _, on_choice) on_choice("anthropic") end
  local notes = capture(function() ui.pick_provider() end)
  ui.pick = real_pick
  vim.wait(50)
  assert.are.equal(1, #notes)
  assert(notes[1].msg:find("(this session); run :StrapsModel", 1, true), notes[1].msg)
  assert.are.equal(vim.log.levels.INFO, notes[1].level)
  assert(vim.b[b].straps_session)
end)

it("24: documented config knobs exist in M.config with their consumers' defaults", function()
  local cfg = straps.config
  assert.are.equal(1, cfg.blank_nudge_limit)
  assert.are.equal(300000, cfg.request_timeout_ms)
  for _, k in ipairs({ "cache_ttl", "log_file", "auto_compact_tokens", "auto_compact_bytes" }) do
    assert.is_nil(cfg[k], k)
  end
  local src = table.concat(vim.fn.readfile(root .. "/lua/straps/init.lua"), "\n")
  for _, k in ipairs({ "blank_nudge_limit", "cache_ttl", "request_timeout_ms", "log_file", "auto_compact_tokens",
    "auto_compact_bytes" }) do
    assert(src:find("\n  " .. k .. " = ", 1, true), k .. " missing from M.config")
  end
end)

it("12: doc/straps.txt and README.md document every session keymap", function()
  local doc = table.concat(vim.fn.readfile(root .. "/doc/straps.txt"), "\n")
  local readme = table.concat(vim.fn.readfile(root .. "/README.md"), "\n")
  for _, lhs in ipairs({ "]]", "[[", "][", "[]", "gO", "g?", "gy" }) do
    assert(doc:find("\n\t" .. lhs .. "\t", 1, true), lhs .. " missing from doc mappings")
    assert(readme:find("`" .. lhs .. "`", 1, true), lhs .. " missing from README")
  end
end)

it("17: g? lists the session keys and Straps commands and closes back to the session", function()
  vim.cmd("filetype plugin on")
  local b = session_in_split()
  local session_win = vim.api.nvim_get_current_win()
  vim.cmd("normal g?")
  local win = vim.api.nvim_get_current_win()
  assert.are_not.equal(session_win, win)
  assert.are.equal("editor", vim.api.nvim_win_get_config(win).relative)
  local text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false), "\n")
  for _, needle in ipairs({ "<CR>", "gO", "gy", "g?", "][", "[]", ":StrapsAsk", ":StrapsPermission" }) do
    assert(text:find("\n  " .. needle .. " ", 1, true), needle .. " missing from the key reference:\n" .. text)
  end
  vim.cmd("normal q")
  assert.are.equal(session_win, vim.api.nvim_get_current_win())
  assert.is_false(vim.api.nvim_win_is_valid(win))
  vim.keymap.set("n", "zq", "<Nop>", { buffer = b, desc = require("straps.questions").KEY_DESC })
  vim.cmd("normal g?")
  local esc_win = vim.api.nvim_get_current_win()
  local listed = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(esc_win), 0, -1, false), "\n")
  assert.is_nil(listed:find("\n  zq ", 1, true), listed)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "mx", false)
  assert.are.equal(session_win, vim.api.nvim_get_current_win())
  assert.is_false(vim.api.nvim_win_is_valid(esc_win))
  vim.keymap.del("n", "zq", { buffer = b })
  vim.bo[b].filetype = "text"
  for _, lhs in ipairs({ "][", "g?" }) do
    assert(vim.fn.maparg(lhs, "n", false, true).buffer ~= 1, lhs .. " still mapped after ft change")
  end
end)

it("g? groups commands, drops the straps: prefix, and hides commands for disabled features", function()
  local b = session_in_split()
  local function reference()
    vim.cmd("normal g?")
    local win = vim.api.nvim_get_current_win()
    local text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false), "\n")
    vim.api.nvim_win_close(win, true)
    return text
  end
  local text = reference()
  for _, heading in ipairs({ "\nSession\n", "\nPermissions\n", "\nNavigation\n", "\nConfiguration\n", "\nRegistry\n" }) do
    assert(text:find(heading, 1, true), heading .. " heading missing:\n" .. text)
  end
  assert.is_nil(text:find("straps:", 1, true), text)
  assert.is_nil(text:find(":StrapsAdopt ", 1, true), text)
  assert.is_nil(text:find(":StrapsContextPin ", 1, true), text)
  assert.is_nil(text:find("\nContext\n", 1, true), text)
  local session_at = text:find("\nSession\n", 1, true)
  local permissions_at = text:find("\nPermissions\n", 1, true)
  local send_at = text:find("\n  :StrapsSend ", 1, true)
  assert(send_at > session_at and send_at < permissions_at, "StrapsSend is not under Session:\n" .. text)
  for line in text:gmatch("[^\n]+") do
    assert(vim.fn.strdisplaywidth(line) <= math.min(vim.o.columns - 4, 100), "line too wide: " .. line)
  end
  vim.b[b].straps_context_management = { enabled = true }
  text = reference()
  assert(text:find("\n  :StrapsContextPin ", 1, true), text)
  assert(text:find("\nContext\n", 1, true), text)
  vim.b[b].straps_context_management = nil
end)

it("every command plugin/straps.lua defines has a key-reference group", function()
  local source = table.concat(vim.fn.readfile(root .. "/plugin/straps.lua"), "\n")
  local found = 0
  for name in source:gmatch('command%("(Straps%w*)"') do
    found = found + 1
    assert(ui.COMMAND_GROUP[name], name .. " has no group in ui.COMMAND_GROUP")
  end
  assert(found >= 30, "found only " .. found .. " commands")
end)

describe("resume leaves an unmodified transcript unmodified", function()
  local function saved(lines)
    local path = vim.fn.tempname() .. ".straps"
    vim.fn.writefile(lines, path)
    return path
  end
  local fixtures = {
    ["no draft marker"] = { "%%[straps:user]%%", "hello", "%%[straps:assistant]%%", "hi" },
    ["a draft marker as the last line"] = { "%%[straps:user]%%", "hello", "%%[straps:assistant]%%", "hi",
      "%%[straps:draft]%%" },
    ["an interrupted tool call"] = { "%%[straps:user]%%", "go", '%%[straps:tool_use]%% {"id":"z1","name":"bash"}',
      '{"command":"sleep 99"}' },
  }
  for label, lines in pairs(fixtures) do
    it("with " .. label, function()
      only_window()
      local b
      capture(function() b = ui.resume_session(saved(lines)) end)
      assert(state.draft_row(b), "no draft line after resume")
      assert.is_false(vim.bo[b].modified)
      local count = vim.api.nvim_buf_line_count(b)
      vim.cmd("silent normal! u")
      assert(vim.api.nvim_buf_line_count(b) < count, "u did not undo the draft line")
      vim.api.nvim_buf_delete(b, { force = true })
    end)
  end

  it("restores the draft line after autoread reloads a rewritten session file", function()
    only_window()
    local path = saved(fixtures["no draft marker"])
    local b
    capture(function() b = ui.resume_session(path) end)
    vim.bo[b].autoread = true
    vim.fn.writefile({ "%%[straps:user]%%", "hello", "%%[straps:assistant]%%", "hi again" }, path)
    local later = os.time() + 5
    vim.uv.fs_utime(path, later, later)
    vim.cmd("checktime " .. b)
    assert.are.equal("hi again", vim.api.nvim_buf_get_lines(b, 3, 4, false)[1])
    assert(state.draft_row(b), "no draft line after reload")
    assert.is_false(vim.bo[b].modified)
    vim.api.nvim_buf_delete(b, { force = true })
  end)

  it("keeps an already-loaded, modified buffer modified (guard)", function()
    only_window()
    local path = saved(fixtures["no draft marker"])
    local b
    capture(function() b = ui.resume_session(path) end)
    vim.api.nvim_buf_set_lines(b, 1, 2, false, { "edited" })
    assert.is_true(vim.bo[b].modified)
    only_window()
    local again
    capture(function() again = ui.resume_session(path) end)
    assert.are.equal(b, again)
    assert.is_true(vim.bo[b].modified)
    vim.api.nvim_buf_delete(b, { force = true })
  end)

  it("leaves a new session modified after the draft line is added (guard)", function()
    only_window()
    local b = state.new_session()
    ui.show_session(b)
    assert.is_true(vim.bo[b].modified)
  end)
end)

it("16: the README command table has a row for every user command", function()
  local readme = table.concat(vim.fn.readfile(root .. "/README.md"), "\n")
  for name in pairs(vim.api.nvim_get_commands({})) do
    if name:match("^Straps") then
      assert(readme:find("| `:" .. name, 1, true), name .. " missing from README command table")
    end
  end
end)

it("13: commands run setup() lazily when the registry has no fn.provider", function()
  local cmd = { vim.v.progpath, "--headless", "--clean", "--cmd", "set rtp^=" .. root,
    "-c", "runtime plugin/straps.lua",
    "-c", "lua require('straps').config.session_dir = vim.fn.tempname()",
    "-c", "Straps",
    "-c", "lua io.stdout:write(tostring(require('straps.registry').get('fn.provider') ~= nil) .. ' '"
      .. " .. tostring(require('straps.registry').get('tool.bash') ~= nil))",
    "-c", "qa!" }
  local res = vim.system(cmd, { text = true }):wait(20000)
  assert.are.equal("true true", vim.trim(res.stdout or ""))
end)

describe("hand-opened transcripts render", function()
  local TRANSCRIPT = { "%%[straps:user]%%", "hello", "%%[straps:assistant]%%", "hi there" }

  local function child(order, body)
    local file = vim.fn.tempname() .. ".straps"
    vim.fn.writefile(TRANSCRIPT, file)
    local script = vim.fn.tempname() .. ".lua"
    local prelude = {
      "vim.opt.rtp:prepend(" .. vim.inspect(root) .. ")",
      "vim.cmd('runtime! ftdetect/straps.vim')",
      "local function setup() require('straps').setup({ session_dir = vim.fn.tempname() }) end",
      order == "setup_first" and "setup(); vim.cmd('filetype plugin on')"
        or order == "plugin_first" and "vim.cmd('filetype plugin on'); setup()"
        or "vim.cmd('filetype plugin on')",
      "local function marks(b) local ns = vim.api.nvim_get_namespaces().straps_render; return ns and #vim.api.nvim_buf_get_extmarks(b or 0, ns, 0, -1, {}) or 0 end",
      "local function settle() vim.wait(120, function() return false end, 10) end",
      "local out = {}",
      "local file = " .. vim.inspect(file),
    }
    vim.fn.writefile(vim.list_extend(prelude, vim.list_extend(body, {
      "io.stdout:write(vim.json.encode(out))",
      "vim.cmd('qa!')",
    })), script)
    local res = vim.system({ vim.v.progpath, "--headless", "--clean", "-l", script }, { text = true }):wait(20000)
    local ok, decoded = pcall(vim.json.decode, res.stdout or "")
    assert(ok, "child output: " .. tostring(res.stdout) .. "\n" .. tostring(res.stderr))
    return decoded, res
  end

  for _, order in ipairs({ "setup_first", "plugin_first", "no_setup" }) do
    it(order .. ": :edit conceals and renders, and :edit! sets conceal again", function()
      local out = child(order, {
        "vim.cmd.edit(file)",
        "settle()",
        "out.cl, out.marks = vim.wo.conceallevel, marks()",
        "vim.cmd('setlocal conceallevel=0')",
        "vim.cmd('edit!')",
        "settle()",
        "out.after_edit = vim.wo.conceallevel",
        "local before = marks()",
        "vim.api.nvim_buf_set_lines(0, -1, -1, false, { '%%[straps:user]%%', 'again', '%%[straps:assistant]%%', 'ok' })",
        "vim.wait(300, function() return marks() > before end, 10)",
        "out.rerendered = marks() > before",
      })
      assert.are.equal(2, out.cl)
      assert(out.marks > 0, vim.inspect(out))
      assert.are.equal(2, out.after_edit)
      assert.is_true(out.rerendered)
    end)
  end

  it(":setlocal conceallevel=0 survives window switches, a split and show_session", function()
    local out = child("setup_first", {
      "vim.cmd.edit(file)",
      "settle()",
      "vim.cmd('setlocal conceallevel=0')",
      "vim.cmd('vsplit')",
      "out.split = vim.wo.conceallevel",
      "vim.cmd('wincmd w')",
      "vim.cmd('wincmd w')",
      "out.switch = vim.wo.conceallevel",
      "_G.renders = 0",
      "require('straps.registry').define({ name = 'fn.render', kind = 'fn', source = 'return function(b) _G.renders = _G.renders + 1; return require([[straps.ui]])._render(b) end' })",
      "require('straps.ui').show_session(vim.api.nvim_get_current_buf(), 'none')",
      "out.show = vim.wo.conceallevel",
      "out.reshow_renders = _G.renders",
    })
    assert.are.equal(0, out.split)
    assert.are.equal(0, out.switch)
    assert.are.equal(0, out.show)
    assert.are.equal(1, out.reshow_renders)
  end)

  it(":set ft=text clears the render and stops the listener; :set ft=straps renders again", function()
    local out = child("setup_first", {
      "vim.cmd.edit(file)",
      "settle()",
      "vim.cmd('set ft=text')",
      "settle()",
      "out.text_marks = marks()",
      "vim.api.nvim_buf_set_lines(0, -1, -1, false, { '%%[straps:user]%%', 'more' })",
      "settle()",
      "out.edited_marks = marks()",
      "vim.cmd('set ft=straps')",
      "settle()",
      "out.cl, out.marks = vim.wo.conceallevel, marks()",
    })
    assert.are.equal(0, out.text_marks)
    assert.are.equal(0, out.edited_marks)
    assert.are.equal(2, out.cl)
    assert(out.marks > 0, vim.inspect(out))
  end)

  it("a hidden-loaded transcript shown with :b renders", function()
    local out = child("setup_first", {
      "local b = vim.fn.bufadd(file)",
      "vim.fn.bufload(b)",
      "vim.bo[b].buflisted = true",
      "vim.cmd('buffer ' .. b)",
      "settle()",
      "out.cl, out.marks = vim.wo.conceallevel, marks(b)",
    })
    assert.are.equal(2, out.cl)
    assert(out.marks > 0, vim.inspect(out))
  end)

  it("after setup, removing fn.render leaves a hand-opened transcript unrendered", function()
    local out = child("setup_first", {
      "require('straps.registry').remove('fn.render')",
      "vim.cmd.edit(file)",
      "settle()",
      "out.marks = marks()",
    })
    assert.are.equal(0, out.marks)
  end)

  it("render = false: :edit and show_session attach no listener that renders after render is turned back on", function()
    local out = child("setup_first", {
      "require('straps').config.render = false",
      "_G.renders = 0",
      "require('straps.registry').define({ name = 'fn.render', kind = 'fn', source = 'return function() _G.renders = _G.renders + 1 end' })",
      "vim.cmd.edit(file)",
      "settle()",
      "require('straps.ui').show_session(vim.api.nvim_get_current_buf(), 'none')",
      "settle()",
      "require('straps').config.render = true",
      "vim.api.nvim_buf_set_lines(0, -1, -1, false, { 'x' })",
      "settle()",
      "out.renders = _G.renders",
    })
    assert.are.equal(0, out.renders)
  end)

  it("a transcript reloaded while hidden renders and conceals again when shown with :buffer", function()
    local out = child("setup_first", {
      "vim.cmd.edit(file)",
      "settle()",
      "local b = vim.api.nvim_get_current_buf()",
      "out.before = marks(b)",
      "vim.cmd('setlocal conceallevel=0')",
      "vim.cmd('enew')",
      "vim.api.nvim_buf_call(b, function() vim.cmd('edit!') end)",
      "settle()",
      "vim.cmd('buffer ' .. b)",
      "settle()",
      "out.after = marks(b)",
      "out.cl = vim.wo.conceallevel",
    })
    assert(out.before > 0, vim.inspect(out))
    assert(out.after > 0, vim.inspect(out))
    assert.are.equal(2, out.cl)
  end)

  it(":edit! restores conceal in every window that shows the transcript", function()
    local out = child("setup_first", {
      "vim.cmd.edit(file)",
      "settle()",
      "vim.cmd('split')",
      "settle()",
      "local wins = vim.fn.win_findbuf(vim.api.nvim_get_current_buf())",
      "for _, w in ipairs(wins) do vim.wo[w].conceallevel = 0 end",
      "vim.cmd('edit!')",
      "settle()",
      "out.cl = {}",
      "for _, w in ipairs(wins) do out.cl[#out.cl + 1] = vim.wo[w].conceallevel end",
    })
    assert.are.same({ 2, 2 }, out.cl)
  end)

  it("a render already queued when the filetype changes away does not repaint", function()
    local out = child("setup_first", {
      "vim.cmd.edit(file)",
      "settle()",
      "local b = vim.api.nvim_get_current_buf()",
      "local t = vim.uv.new_timer()",
      "t:start(5, 0, function() vim.schedule(function() vim.bo[b].filetype = 'text' end) end)",
      "vim.api.nvim_buf_set_lines(b, -1, -1, false, { '%%[straps:user]%%', 'late' })",
      "vim.uv.sleep(80)",
      "settle()",
      "out.ft, out.marks = vim.bo[b].filetype, marks(b)",
    })
    assert.are.equal("text", out.ft)
    assert.are.equal(0, out.marks)
  end)

  it("re-resuming a session that is on screen renders once", function()
    local out = child("setup_first", {
      "_G.renders = 0",
      "require('straps.registry').define({ name = 'fn.render', kind = 'fn', source = 'return function(b) _G.renders = _G.renders + 1; return require([[straps.ui]])._render(b) end' })",
      "require('straps.ui').resume_session(file)",
      "settle()",
      "_G.renders = 0",
      "require('straps.ui').resume_session(file)",
      "out.renders = _G.renders",
      "settle()",
      "out.marks = marks()",
    })
    assert.are.equal(1, out.renders)
    assert(out.marks > 0, vim.inspect(out))
  end)

  it("a windowless session buffer is not rendered until a window shows it", function()
    local out = child("setup_first", {
      "_G.renders = 0",
      "require('straps.registry').define({ name = 'fn.render', kind = 'fn', source = 'return function(b) _G.renders = _G.renders + 1; return require([[straps.ui]])._render(b) end' })",
      "local b = require('straps.state').new_session()",
      "settle()",
      "vim.api.nvim_buf_set_lines(b, -1, -1, false, { 'x' })",
      "settle()",
      "out.hidden = _G.renders",
      "require('straps.ui').show_session(b, 'none')",
      "settle()",
      "out.shown, out.cl = _G.renders, vim.wo.conceallevel",
    })
    assert.are.equal(0, out.hidden)
    assert.are.equal(1, out.shown)
    assert.are.equal(2, out.cl)
  end)

  it("render = false: :edit and show_session call fn.render 0 times and attaches no listener", function()
    local out = child("setup_first", {
      "require('straps').config.render = false",
      "_G.renders = 0",
      "require('straps.registry').define({ name = 'fn.render', kind = 'fn', source = 'return function() _G.renders = _G.renders + 1 end' })",
      "vim.cmd.edit(file)",
      "settle()",
      "vim.api.nvim_buf_set_lines(0, -1, -1, false, { 'x' })",
      "require('straps.ui').show_session(vim.api.nvim_get_current_buf(), 'none')",
      "vim.api.nvim_buf_set_lines(0, -1, -1, false, { 'y' })",
      "settle()",
      "out.renders, out.cl = _G.renders, vim.wo.conceallevel",
    })
    assert.are.equal(0, out.renders)
    assert.are.equal(0, out.cl)
  end)

  it("a raising fn.render does not break :edit, and the listener still attaches", function()
    local out, res = child("setup_first", {
      "_G.renders = 0",
      "require('straps.registry').define({ name = 'fn.render', kind = 'fn', source = 'return function() _G.renders = _G.renders + 1; error(\"boom\") end' })",
      "_G.warnings = 0",
      "vim.notify = function() _G.warnings = _G.warnings + 1 end",
      "out.ok = pcall(vim.cmd.edit, file)",
      "settle()",
      "out.linebreak = vim.wo.linebreak",
      "local before = _G.renders",
      "vim.api.nvim_buf_set_lines(0, -1, -1, false, { 'x' })",
      "vim.wait(300, function() return _G.renders > before end, 10)",
      "out.rerendered = _G.renders > before",
      "vim.api.nvim_buf_set_lines(0, -1, -1, false, { 'y' })",
      "vim.wait(300, function() return false end, 10)",
      "out.warnings = _G.warnings",
    })
    assert.is_true(out.ok)
    assert.is_nil((res.stderr or ""):find("boom", 1, true), res.stderr)
    assert.are.equal(1, out.warnings)
    assert.is_true(out.linebreak)
    assert.is_true(out.rerendered)
  end)
end)

describe("draft marker survives insert-mode Enter at its end", function()
  for _, case in ipairs({
    { "A\rsecret draft\27" },
    { "Gddk$a\rsecret draft\27" },
    { "A\r%%[straps:user]%%\rsecret draft\27" },
    { "A\rsecret draft\27", reply = true },
    { "A\rsecret draft\27u\18", reply = true },
    { "A\rsecret draft\27uA\rsecret draft\27" },
  }) do
    local keys = case[1]
    it("keeps the typed text in the draft for " .. vim.inspect(keys) .. (case.reply and " after a reply" or ""), function()
      vim.cmd("only")
      local b = state.new_session()
      ui.show_session(b, "none")
      if case.reply then
        state.seed_user(b, "hi")
        state.append(b, "assistant", nil, "reply")
      end
      vim.api.nvim_buf_set_lines(b, -1, -1, false, { "draftline" })
      local row = state.draft_row(b)
      vim.api.nvim_win_set_cursor(0, { row + 1, 0 })
      vim.api.nvim_feedkeys(keys, "xt", false)
      state.repair_draft(b)
      local lines = state.transcript_lines(b)
      assert.are_not.equal("secret draft", lines[#lines])
      for _, line in ipairs(lines) do assert.are_not.equal("%%[straps:draft]%%", line) end
      assert(state.draft_text(b):find("secret draft", 1, true), state.draft_text(b))
      assert.are.equal(1, #vim.tbl_filter(function(l) return l == "%%[straps:draft]%%" end, vim.api.nvim_buf_get_lines(b, 0, -1, false)))
    end)
  end
end)

it("g? finishes when a command name is wider than the float", function()
  local name = "Straps" .. ("X"):rep(80)
  vim.api.nvim_create_user_command(name, function() end, { desc = "straps: probe" })
  local ok, err = pcall(function()
    vim.cmd("only")
    local b = state.new_session()
    ui.show_session(b, "none")
    vim.cmd("normal g?")
    local win = vim.api.nvim_get_current_win()
    local width = vim.api.nvim_win_get_width(win)
    local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
    vim.api.nvim_win_close(win, true)
    for _, line in ipairs(lines) do assert(vim.fn.strdisplaywidth(line) <= width, "line too wide: " .. line) end
  end)
  pcall(vim.api.nvim_del_user_command, name)
  assert(ok, tostring(err))
end)

for _, cols in ipairs({ 30, 24 }) do
it("g? keeps every line inside the float on a " .. cols .. "-column screen", function()
  local columns = vim.o.columns
  vim.api.nvim_create_user_command("StrapsWideProbe", function() end, { desc = ("\u{5bbd}"):rep(30) })
  vim.api.nvim_create_user_command("StrapsAVeryLongProbeCommandName", function() end, { desc = "probe" })
  local ok, err = pcall(function()
    vim.cmd("only")
    local b = state.new_session()
    ui.show_session(b, "none")
    vim.o.columns = cols
    vim.cmd("normal g?")
    local win = vim.api.nvim_get_current_win()
    local width = vim.api.nvim_win_get_width(win)
    local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
    vim.api.nvim_win_close(win, true)
    assert(width <= math.max(20, cols - 4), "float width " .. width)
    for _, line in ipairs(lines) do assert(vim.fn.strdisplaywidth(line) <= width, "line too wide: " .. line) end
    assert(table.concat(lines, "\n"):find("\n  :StrapsSend\n", 1, true), table.concat(lines, "\n"))
    assert(table.concat(lines, "\n"):find("\u{5bbd}", 1, true), "wide probe missing")
  end)
  vim.o.columns = columns
  pcall(vim.api.nvim_del_user_command, "StrapsWideProbe")
  pcall(vim.api.nvim_del_user_command, "StrapsAVeryLongProbeCommandName")
  assert(ok, tostring(err))
end)
end
