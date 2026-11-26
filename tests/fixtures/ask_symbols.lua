local script = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(script, ":p:h:h:h")
vim.opt.runtimepath:prepend(root)
vim.o.lines, vim.o.columns = 30, 100

local api = vim.api
local session_dir = vim.fn.tempname()
local work = vim.fn.resolve(vim.fn.tempname())
vim.fn.mkdir(work, "p")
vim.fn.chdir(work)
local phase

local function expect(label, actual, expected)
  if vim.env.STRAPS_ASK_COUNTERFACTUAL == phase .. ":" .. label then expected = { counterfactual = true } end
  assert(vim.deep_equal(actual, expected), ("%s [%s]: expected %s, got %s"):format(phase, label,
    vim.inspect(expected), vim.inspect(actual)))
end

local function later() coroutine.yield() end

local function input(keys)
  api.nvim_input(keys)
  later()
end

local answers, delays, refuse = {}, {}, {}

local function fake(name)
  return function()
    local closing = false
    return {
      request = function(method, params, callback)
        local result
        if method == "initialize" then
          result = { capabilities = { workspaceSymbolProvider = true, positionEncoding = name == "one" and "utf-8" or nil } }
        elseif method == "workspace/symbol" then
          if refuse[name] then return false end
          result = answers[name] and answers[name](params.query) or {}
        end
        local delay = method == "workspace/symbol" and delays[name] or 0
        if type(delay) == "function" then delay = delay(params.query) end
        vim.defer_fn(function() callback(nil, result) end, delay)
        return true, 1
      end,
      notify = function() return true end,
      is_closing = function() return closing end,
      terminate = function() closing = true end,
    }
  end
end

local function symbol(name, file, line, character)
  local loc = { uri = vim.uri_from_fname(work .. "/" .. file) }
  character = character or 0
  if line then loc.range = { start = { line = line, character = character }, ["end"] = { line = line, character = character + 1 } } end
  return { name = name, kind = 12, location = loc }
end

local function words()
  local out = {}
  for _, item in ipairs(vim.fn.complete_info({ "items" }).items) do out[#out + 1] = item.word end
  table.sort(out)
  return out
end

local function loaded_count()
  local n = 0
  for _, b in ipairs(api.nvim_list_bufs()) do if api.nvim_buf_is_loaded(b) then n = n + 1 end end
  return n
end

local function wait_pum(label)
  for _ = 1, 300 do
    if vim.fn.pumvisible() == 1 then return end
    later()
  end
  error(phase .. ": no completion menu for " .. label)
end

local run = coroutine.create(function()
  require("straps").setup({ session_dir = session_dir, terminal_status = false })
  vim.cmd.runtime("plugin/straps.lua")
  vim.o.completeopt = "menuone,noinsert"
  local state, ui = require("straps.state"), require("straps.ui")
  for _, file in ipairs({ "alpha.lua", "beta.lua", "gamma.lua" }) do vim.fn.writefile({ "x", "y", "z" }, work .. "/" .. file) end
  vim.fn.writefile({ "return 1" }, work .. "/anchor.lua")
  vim.cmd("edit " .. work .. "/anchor.lua")
  local anchor = api.nvim_get_current_buf()
  for _, name in ipairs({ "one", "two" }) do
    local id = vim.lsp.start({ name = name, cmd = fake(name), root_dir = work }, { bufnr = anchor })
    for _ = 1, 200 do
      local c = vim.lsp.get_client_by_id(id)
      if c and c.initialized then break end
      later()
    end
  end
  answers.one = function() return { symbol("target_one", "alpha.lua", 2) } end
  answers.two = function() return { symbol("target_two", "beta.lua", 0), symbol("module", "gamma.lua") } end

  local buf = ui.open_session("split", { explicit_split = true })
  local win = api.nvim_get_current_win()
  state.open_draft(buf)
  local function reset_line(text)
    vim.cmd("stopinsert")
    later()
    local last = api.nvim_buf_line_count(buf)
    api.nvim_buf_set_lines(buf, last - 1, last, false, { text })
    api.nvim_win_set_cursor(win, { last, #text })
  end

  phase = "merged at column 0"
  local before = loaded_count()
  reset_line("")
  input("A@#tar<C-x><C-o>")
  wait_pum("column 0")
  expect("words", words(), { "@alpha.lua:3", "@beta.lua:1", "@gamma.lua" })
  expect("no loads", loaded_count(), before)
  input("<C-n><C-y>")
  local accepted = api.nvim_buf_get_lines(buf, -2, -1, false)[1]
  expect("inserted at column 0", vim.tbl_contains({ "@alpha.lua:3", "@beta.lua:1", "@gamma.lua" }, accepted), true)

  phase = "mid-line"
  reset_line("see ")
  input("A@#tar<C-x><C-o>")
  wait_pum("mid-line")
  input("<C-n><C-y>")
  local line = api.nvim_buf_get_lines(buf, -2, -1, false)[1]
  expect("token replaced", vim.tbl_contains({ "see @alpha.lua:3", "see @beta.lua:1", "see @gamma.lua" }, line), true)

  phase = "streaming above"
  delays.one, delays.two = 200, 200
  reset_line("")
  input("A@#tar<C-x><C-o>")
  local draft_marker = state.draft_row(buf)
  api.nvim_buf_set_lines(buf, draft_marker - 1, draft_marker - 1, false, { "streamed 1", "streamed 2" })
  wait_pum("streaming")
  expect("words", words(), { "@alpha.lua:3", "@beta.lua:1", "@gamma.lua" })
  input("<C-e>")

  phase = "one slow client"
  delays.one, delays.two = 0, 300
  reset_line("")
  input("A@#tar<C-x><C-o>")
  wait_pum("one slow client")
  expect("words", words(), { "@alpha.lua:3", "@beta.lua:1", "@gamma.lua" })
  input("<C-e>")
  delays.one, delays.two = 200, 200

  phase = "token edited"
  reset_line("")
  input("A@#tar<C-x><C-o>")
  input("<BS><BS><BS>")
  local edited = vim.uv.now()
  while vim.uv.now() - edited < 400 do later() end
  expect("no menu", vim.fn.pumvisible(), 0)

  phase = "token replaced with text of the same length"
  local saved_one, saved_two = delays.one, delays.two
  delays.one, delays.two = 300, 300
  reset_line("")
  input("A@#tar<C-x><C-o>")
  input("<BS><BS><BS>xyz")
  local replaced = vim.uv.now()
  while vim.uv.now() - replaced < 600 do later() end
  expect("no menu", vim.fn.pumvisible(), 0)
  expect("line unchanged", api.nvim_buf_get_lines(buf, -2, -1, false)[1], "@#xyz")
  delays.one, delays.two = saved_one, saved_two

  phase = "moved off the line"
  reset_line("")
  local last = api.nvim_buf_line_count(buf)
  api.nvim_buf_set_lines(buf, last, last, false, { "@#tar" })
  api.nvim_win_set_cursor(win, { last, 0 })
  input("A@#tar<C-x><C-o>")
  input("<Down>")
  local waited = vim.uv.now()
  while vim.uv.now() - waited < 400 do later() end
  expect("no menu", vim.fn.pumvisible(), 0)
  local marks = api.nvim_buf_get_extmarks(buf, api.nvim_create_namespace("straps_ask_symbols"), 0, -1, {})
  expect("mark removed", #marks, 0)

  phase = "capped at 200"
  delays.one, delays.two = 0, 0
  local many = answers.one
  answers.one = function()
    local out = {}
    for i = 0, 249 do out[#out + 1] = symbol("many", "alpha.lua", i % 150) end
    return out
  end
  local editor = require("straps.editor")
  local convert, conversions = editor.symbol_location, 0
  editor.symbol_location = function(...)
    conversions = conversions + 1
    return convert(...)
  end
  reset_line("")
  input("A@#tar<C-x><C-o>")
  wait_pum("capped")
  editor.symbol_location = convert
  expect("count", #words(), 150)
  expect("conversions", conversions, 200)
  input("<C-e>")
  answers.one = many

  phase = "a new request cancels the pending one"
  delays.one = function(query) return query == "ta" and 400 or 0 end
  delays.two = function(query) return query == "ta" and 400 or 0 end
  answers.one = function(query) return { symbol(query, "alpha.lua", #query) } end
  answers.two = function() return {} end
  reset_line("")
  input("A@#ta<C-x><C-o>")
  input("r<C-x><C-o>")
  wait_pum("second request")
  local second = vim.uv.now()
  while vim.uv.now() - second < 600 do later() end
  expect("words", words(), { "@alpha.lua:4" })
  input("<C-e>")
  answers.one = many

  phase = "a refused request does not wait for the timeout"
  delays.one, delays.two = 0, 0
  refuse.two = true
  reset_line("")
  local started = vim.uv.now()
  input("A@#tar<C-x><C-o>")
  wait_pum("refused")
  expect("before the timeout", vim.uv.now() - started < 700, true)
  expect("words", words(), { "@alpha.lua:3" })
  input("<C-e>")
  refuse.two = false

  phase = "moved left on the line"
  delays.one, delays.two = 200, 200
  reset_line("")
  input("A@#tar<C-x><C-o>")
  input("<Home>")
  local moved = vim.uv.now()
  while vim.uv.now() - moved < 400 do later() end
  expect("no menu", vim.fn.pumvisible(), 0)
  expect("line unchanged", api.nvim_buf_get_lines(buf, -2, -1, false)[1], "@#tar")

  phase = "a loaded file uses the client's position encoding"
  delays.one, delays.two = 0, 0
  vim.fn.writefile({ "aé target" }, work .. "/enc.lua")
  vim.cmd("badd " .. work .. "/enc.lua")
  vim.fn.bufload(vim.fn.bufnr(work .. "/enc.lua"))
  answers.one = function() return { symbol("target", "enc.lua", 0, 4) } end
  answers.two = function() return {} end
  reset_line("")
  input("A@#tar<C-x><C-o>")
  wait_pum("encoding")
  expect("words", words(), { "@enc.lua:1:5" })
  input("<C-e>")
  answers.one = many

  phase = "left insert mode with the cursor at the token end"
  delays.one, delays.two = 200, 200
  reset_line(" x")
  api.nvim_win_set_cursor(win, { api.nvim_buf_line_count(buf), 0 })
  vim.v.errmsg = ""
  input("i@#tar<C-x><C-o>")
  input("<Esc>l")
  local left = vim.uv.now()
  while vim.uv.now() - left < 500 do later() end
  expect("normal mode", api.nvim_get_mode().mode, "n")
  expect("cursor at the token end", api.nvim_win_get_cursor(win)[2], 5)
  expect("no error", vim.v.errmsg, "")
  expect("line unchanged", api.nvim_buf_get_lines(buf, -2, -1, false)[1], "@#tar x")

  phase = "another buffer is current when the answer arrives"
  delays.one, delays.two = 300, 300
  reset_line("")
  local row = api.nvim_buf_line_count(buf)
  input("A@#tar<C-x><C-o>")
  vim.cmd("stopinsert")
  later()
  vim.cmd("new")
  local other = api.nvim_get_current_buf()
  local filler = {}
  for i = 1, row - 1 do filler[i] = "" end
  filler[row] = "@#tar"
  api.nvim_buf_set_lines(other, 0, -1, false, filler)
  api.nvim_win_set_cursor(0, { row, 0 })
  input("A")
  local switched = vim.uv.now()
  while vim.uv.now() - switched < 600 do later() end
  expect("insert mode in the other buffer", { api.nvim_get_mode().mode, api.nvim_get_current_buf() }, { "i", other })
  expect("no menu", vim.fn.pumvisible(), 0)
  vim.cmd("stopinsert")
  later()
  api.nvim_buf_delete(other, { force = true })
  api.nvim_set_current_win(win)

  phase = "the buffer is wiped while a request is pending"
  delays.one, delays.two = 300, 300
  vim.cmd("stopinsert")
  later()
  vim.cmd("new")
  local scratch = api.nvim_get_current_buf()
  vim.bo[scratch].omnifunc = "v:lua.require'straps.ask'.omnifunc"
  vim.v.errmsg = ""
  input("i@#tar<C-x><C-o>")
  vim.cmd("stopinsert")
  later()
  api.nvim_buf_delete(scratch, { force = true })
  local wiped = vim.uv.now()
  while vim.uv.now() - wiped < 500 do later() end
  expect("no error", vim.v.errmsg, "")
  api.nvim_set_current_win(win)

  phase = "a silent client is cut off at 1 s"
  delays.one, delays.two = 0, 5000
  reset_line("")
  started = vim.uv.now()
  input("A@#tar<C-x><C-o>")
  wait_pum("timeout")
  local elapsed = vim.uv.now() - started
  expect("after the timeout", elapsed >= 900 and elapsed < 2500, true)
  expect("words", words(), { "@alpha.lua:3" })
  input("<C-e>")
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
