-- tests/ask_spec.lua — :StrapsAsk in strict mode, the draft fold guard, @ file completion and @# symbol completion.
-- Run from the repo root: busted tests/ask_spec.lua </dev/null

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
require("straps").setup({ session_dir = vim.fn.tempname(), terminal_status = false })
vim.cmd("filetype plugin on")
vim.g.loaded_straps = nil
vim.cmd.runtime("plugin/straps.lua")
local api = vim.api
local registry, state, loop, ui, ask = require("straps.registry"), require("straps.state"), require("straps.loop"),
  require("straps.ui"), require("straps.ask")

local work = vim.fn.resolve(vim.fn.tempname())
vim.fn.mkdir(work, "p")
local home_cwd = vim.fn.getcwd()

local function wipe_sessions()
  for _, b in ipairs(api.nvim_list_bufs()) do
    if vim.b[b].straps_session then pcall(api.nvim_buf_delete, b, { force = true }) end
  end
end

local function source_file(name, lines)
  local path = work .. "/" .. name
  vim.fn.writefile(lines, path)
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  return api.nvim_get_current_buf(), path
end

local function session_in_split()
  local src_win = api.nvim_get_current_win()
  local buf = ui.open_session("split", { explicit_split = true })
  local win = api.nvim_get_current_win()
  api.nvim_set_current_win(src_win)
  return buf, win
end

before_each(function()
  vim.cmd("silent! tabonly!")
  vim.cmd("silent! only!")
  vim.cmd("enew!")
  wipe_sessions()
  vim.cmd("cd " .. vim.fn.fnameescape(work))
  _G.ask_steps = {}
  registry.define({ name = "fn.provider", kind = "fn", source = [=[return function(req, ctx)
    local step = table.remove(_G.ask_steps, 1)
    if type(step) == "function" then return step(req, ctx) end
    return step or { stop_reason = 'end_turn', content = {{ type = 'text', text = 'done' }} }
  end]=] })
end)

after_each(function()
  for _, b in ipairs(loop.running_sessions()) do loop.stop(b) end
  vim.wait(500, function() return #loop.running_sessions() == 0 end, 10)
  vim.cmd("cd " .. vim.fn.fnameescape(home_cwd))
end)

describe("strict :StrapsAsk", function()
  it("puts path:2-3, a three-backtick fence with the filetype, and the text into the draft", function()
    local src = source_file("sample.lua", { "one", "two", "three", "four" })
    local buf = session_in_split()
    api.nvim_set_current_buf(src)
    vim.cmd("2,3StrapsAsk explain these")
    assert.are.equal(buf, api.nvim_get_current_buf())
    assert.are.equal(table.concat({ "sample.lua:2-3", "```lua", "two", "three", "```", "explain these" }, "\n"),
      state.draft_text(buf))
    assert.same({ api.nvim_buf_line_count(buf), 0 }, api.nvim_win_get_cursor(0))
  end)

  it("appends after existing draft text with one blank line", function()
    local src = source_file("append.txt", { "alpha" })
    local buf = session_in_split()
    state.open_draft(buf)
    api.nvim_buf_set_lines(buf, state.draft_row(buf) + 1, -1, false, { "earlier", "" })
    api.nvim_set_current_buf(src)
    vim.cmd("StrapsAsk")
    assert.are.equal(table.concat({ "earlier", "", "append.txt:1-1", "```text", "alpha", "```" }, "\n"), state.draft_text(buf))
  end)

  it("lengthens the fence past the longest backtick run", function()
    local src = source_file("ticks.md", { "a ```` b", "``" })
    local buf = session_in_split()
    api.nvim_set_current_buf(src)
    vim.cmd("%StrapsAsk")
    local lines = vim.split(state.draft_text(buf), "\n", { plain = true })
    assert.are.equal("`````markdown", lines[2])
    assert.are.equal("`````", lines[5])
  end)

  it("uses the current line without a range", function()
    local src = source_file("cur.txt", { "first", "second", "third" })
    local buf = session_in_split()
    api.nvim_set_current_buf(src)
    api.nvim_win_set_cursor(0, { 2, 0 })
    vim.cmd("StrapsAsk")
    assert.are.equal(table.concat({ "cur.txt:2-2", "```text", "second", "```" }, "\n"), state.draft_text(buf))
  end)

  it("gives an unnamed buffer the [No Name] header", function()
    local buf = session_in_split()
    vim.cmd("enew")
    api.nvim_buf_set_lines(0, 0, -1, false, { "scratch" })
    vim.cmd("StrapsAsk")
    assert.are.equal("[No Name]:1-1", vim.split(state.draft_text(buf), "\n", { plain = true })[1])
  end)

  it("gives an :lcd source window an absolute path, also for a file under the :lcd directory", function()
    vim.fn.mkdir(work .. "/sub", "p")
    local _, path = source_file("sub/abs.txt", { "x" })
    local buf = session_in_split()
    vim.cmd("lcd " .. vim.fn.fnameescape(work .. "/sub"))
    vim.cmd("StrapsAsk")
    assert.are.equal(path .. ":1-1", vim.split(state.draft_text(buf), "\n", { plain = true })[1])
  end)

  it("quotes the transcript's own lines from a session buffer into the same session", function()
    local buf = session_in_split()
    local other = session_in_split()
    state.append(buf, "assistant", nil, "answer line")
    state.append(buf, "user", nil, "")
    local row
    for i, line in ipairs(api.nvim_buf_get_lines(buf, 0, -1, false)) do
      if line == "answer line" then row = i end
    end
    for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
      if api.nvim_win_get_buf(w) == buf then api.nvim_set_current_win(w) end
    end
    vim.cmd(row .. "StrapsAsk")
    assert(state.draft_text(buf):find("answer line", 1, true), state.draft_text(buf))
    assert.is_falsy((state.draft_text(other) or ""):find("answer line", 1, true))
  end)

  it("! sends when the session is idle", function()
    local src = source_file("send.txt", { "payload" })
    local buf = session_in_split()
    local seen
    _G.ask_steps[1] = function(req)
      seen = req.messages[#req.messages]
      return { stop_reason = "end_turn", content = { { type = "text", text = "ok" } } }
    end
    api.nvim_set_current_buf(src)
    vim.cmd("StrapsAsk! summarize")
    assert(vim.wait(3000, function() return seen ~= nil and not loop.running(buf) end, 10))
    local text = vim.inspect(seen)
    assert(text:find("send.txt:1-1", 1, true) and text:find("summarize", 1, true), text)
    assert.are.equal("", state.draft_text(buf))
  end)

  it("! steers when the session is running", function()
    local src = source_file("steer.txt", { "later" })
    local buf = session_in_split()
    _G.ask_steps[1] = function(_, ctx)
      ctx.await(function(done) _G.ask_wake = done end)
      return { stop_reason = "end_turn", content = { { type = "text", text = "ok" } } }
    end
    state.add_to_trailing_user(buf, "go")
    loop.start(buf)
    assert(vim.wait(2000, function() return _G.ask_wake ~= nil end, 10))
    local steered
    local real = loop.steer
    loop.steer = function(b, text) steered = text; return real(b, text) end
    api.nvim_set_current_buf(src)
    local ok, err = pcall(vim.cmd, "StrapsAsk! more")
    loop.steer = real
    assert(ok, err)
    assert.are.equal(table.concat({ "steer.txt:1-1", "```text", "later", "```", "more" }, "\n"), steered)
    _G.ask_wake()
    _G.ask_wake = nil
  end)

  it("targets the most recently focused session when no session window is visible", function()
    local a, a_win = session_in_split()
    local b, b_win = session_in_split()
    local c, c_win = session_in_split()
    api.nvim_set_current_win(a_win)
    api.nvim_set_current_win(c_win)
    api.nvim_set_current_win(b_win)
    vim.cmd("only")
    vim.cmd("enew")
    api.nvim_buf_set_lines(0, 0, -1, false, { "focus" })
    vim.cmd("StrapsAsk")
    assert(state.draft_text(b):find("focus", 1, true), state.draft_text(b))
    for _, other in ipairs({ a, c }) do assert.is_falsy((state.draft_text(other) or ""):find("focus", 1, true)) end
    assert.are.equal(b, api.nvim_get_current_buf())
  end)

  it("prefers the one visible session over a more recently focused hidden one", function()
    local a = session_in_split()
    local b, b_win = session_in_split()
    api.nvim_set_current_win(b_win)
    api.nvim_win_close(b_win, true)
    vim.cmd("enew")
    api.nvim_buf_set_lines(0, 0, -1, false, { "visible" })
    assert(vim.b[b].straps_last_focus > (vim.b[a].straps_last_focus or 0))
    vim.cmd("StrapsAsk")
    assert(state.draft_text(a):find("visible", 1, true), state.draft_text(a))
    assert.is_falsy((state.draft_text(b) or ""):find("visible", 1, true))
  end)

  it(":vertical opens a new session and shows a hidden one in a vertical split", function()
    source_file("vert.txt", { "side" })
    vim.cmd("vertical StrapsAsk first")
    local first = api.nvim_get_current_buf()
    assert.is_true(vim.b[first].straps_session)
    assert.are.equal("row", vim.fn.winlayout()[1])
    vim.cmd("only")
    vim.cmd("enew")
    vim.cmd("vertical StrapsAsk second")
    assert.are.equal(first, api.nvim_get_current_buf())
    assert.are.equal("row", vim.fn.winlayout()[1])
    assert(state.draft_text(first):find("second", 1, true), state.draft_text(first))
  end)

  it("quoting the stdin buffer at startup does not append the piped text again", function()
    local src = source_file("piped.txt", { "alpha", "beta" })
    vim.g.straps_stdin_buf = src
    local starting_v = setmetatable({ vim_did_enter = 0 }, { __index = vim.v })
    local starting_vim = setmetatable({ v = starting_v }, { __index = vim })
    setfenv(ui.open_session, setmetatable({ vim = starting_vim }, { __index = _G }))
    local ok, err = pcall(vim.cmd, "%StrapsAsk explain")
    setfenv(ui.open_session, _G)
    assert(ok, tostring(err))
    local buf = api.nvim_get_current_buf()
    assert.is_true(vim.b[buf].straps_session)
    assert.are.equal(table.concat({ "piped.txt:1-2", "```text", "alpha", "beta", "```", "explain" }, "\n"),
      state.last_user_text(buf))
    assert.is_nil(vim.g.straps_stdin_buf)
  end)

  it("opens a new session when none resolves", function()
    source_file("fresh.txt", { "new one" })
    vim.cmd("StrapsAsk start here")
    local buf = api.nvim_get_current_buf()
    assert.is_true(vim.b[buf].straps_session)
    assert.are.equal(table.concat({ "fresh.txt:1-1", "```text", "new one", "```", "start here" }, "\n"), state.last_user_text(buf))
  end)
end)

describe("draft fold guard", function()
  it("a quoted tool_use marker in the draft opens no fold and leaves the last tool fold ending above the trailing user marker", function()
    local buf, win = session_in_split()
    state.append(buf, "assistant", nil, "calling")
    state.append(buf, "tool_use", { id = "t1", name = "sample" }, "{}")
    state.append(buf, "tool_result", { id = "t1" }, "out")
    state.append(buf, "user", nil, "")
    local marker_row
    for i, line in ipairs(api.nvim_buf_get_lines(buf, 0, -1, false)) do
      if line:find("%[straps:tool_use%]") then marker_row = i end
    end
    api.nvim_set_current_win(win)
    vim.cmd(marker_row .. "," .. (marker_row + 1) .. "StrapsAsk")
    api.nvim_win_call(win, function()
      vim.cmd("normal! zx")
      vim.cmd("normal! zM")
    end)
    local draft = state.draft_row(buf)
    local last = api.nvim_buf_line_count(buf)
    assert(api.nvim_buf_get_lines(buf, draft, -1, false)[4]:find("%[straps:tool_use%]"))
    local closed = api.nvim_win_call(win, function()
      return { vim.fn.foldclosed(last), vim.fn.foldclosed(draft + 1), vim.fn.foldclosedend(marker_row) }
    end)
    assert.same({ -1, -1, draft - 1 }, closed)
  end)

  it("evaluates foldlevel in a .straps buffer without a draft marker", function()
    local path = work .. "/nodraft.straps"
    vim.fn.writefile({ "%%[straps:user]%%", "hello", "%%[straps:tool_use]%% {\"id\":\"x\",\"name\":\"y\"}", "{}" }, path)
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    assert.is_nil(state.draft_row(api.nvim_get_current_buf()))
    assert.has_no.errors(function() vim.fn.foldlevel(1) end)
    assert.are.equal(1, vim.fn.foldlevel(3))
  end)
end)

describe("@ completion", function()
  it("sets the omnifunc and completes @lu to files", function()
    vim.fn.writefile({}, work .. "/lumen.txt")
    vim.fn.mkdir(work .. "/lua_dir", "p")
    local buf = session_in_split()
    assert.are.equal("v:lua.require'straps.ask'.omnifunc", vim.bo[buf].omnifunc)
    for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
      if api.nvim_win_get_buf(w) == buf then api.nvim_set_current_win(w) end
    end
    state.open_draft(buf)
    local last = api.nvim_buf_line_count(buf)
    api.nvim_buf_set_lines(buf, last - 1, last, false, { "see @lu" })
    api.nvim_win_set_cursor(0, { last, 7 })
    assert.are.equal(5, ask.omnifunc(1, ""))
    assert.same({ "lua_dir/", "lumen.txt" }, ask.omnifunc(0, "lu"))
  end)

  it("returns -3 when no @ precedes the cursor", function()
    local buf = session_in_split()
    for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
      if api.nvim_win_get_buf(w) == buf then api.nvim_set_current_win(w) end
    end
    state.open_draft(buf)
    local last = api.nvim_buf_line_count(buf)
    api.nvim_buf_set_lines(buf, last - 1, last, false, { "plain" })
    api.nvim_win_set_cursor(0, { last, 5 })
    assert.are.equal(-3, ask.omnifunc(1, ""))
  end)
end)

describe("@# symbol completion", function()
  it("merges clients, inserts at the token column, survives streaming above, and drops on a line change", function()
    local fixture = root .. "/tests/fixtures/ask_symbols.lua"
    local result = vim.system({ vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-n",
      "-c", "luafile " .. vim.fn.fnameescape(fixture) }, { text = true }):wait(20000)
    assert(result.code == 0, (result.stdout or "") .. (result.stderr or ""))
  end)
end)

it("@ file completion does not expand a backtick command", function()
  local marker = vim.fn.tempname()
  local items = require("straps.ask").omnifunc(0, "`touch " .. marker .. "`")
  assert.same({}, items)
  assert.are.equal(0, vim.fn.filereadable(marker))
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  vim.fn.writefile({}, dir .. "/plain.txt")
  assert.same({ dir .. "/plain.txt" }, require("straps.ask").omnifunc(0, dir .. "/pl"))
end)

it("@ file completion returns nothing for an unbalanced brace", function()
  assert.same({}, require("straps.ask").omnifunc(0, "{a,b"))
end)
