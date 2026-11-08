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
  vim.bo[b].filetype = "text"
  for _, lhs in ipairs(ui.SESSION_KEYS) do
    assert(vim.fn.maparg(lhs, "n", false, true).buffer ~= 1, lhs .. " still mapped after ft change")
  end
  assert.are_not.equal("expr", vim.wo[0].foldmethod)
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
  for _, cmd in ipairs({ "StrapsSend", "StrapsSteer x", "StrapsStop", "StrapsContinue", "StrapsCompact",
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
  for _, lhs in ipairs({ "]]", "[[", "gO" }) do
    assert(doc:find("\n\t" .. lhs .. "\t", 1, true), lhs .. " missing from doc mappings")
    assert(readme:find("`" .. lhs .. "`", 1, true), lhs .. " missing from README")
  end
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
