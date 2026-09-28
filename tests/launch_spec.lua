-- tests/launch_spec.lua — launching straight into a session: the extended
-- `:Straps[!] [categories] [-- instruction]` command, stdin seeding of the
-- first user block, startup window reuse. Run from the repo root:
--   busted tests/launch_spec.lua
-- No network: fn.provider is stubbed per case. The startup-only paths (stdin
-- capture, window reuse) are exercised in a child headless nvim.

local script = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(vim.fn.fnamemodify(script, ":p"), ":h:h")
vim.opt.runtimepath:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local straps = require("straps").setup({})
straps.config.session_dir = vim.fn.tempname()
local registry = require("straps.registry")
local state = require("straps.state")
local loop = require("straps.loop")

vim.g.loaded_straps = nil
vim.cmd("source " .. vim.fn.fnameescape(root .. "/plugin/straps.lua"))

local function define(name, kind, doc, source)
  registry.define({ name = name, kind = kind, doc = doc, source = source })
end

local function must_not_call_provider()
  define("fn.provider", "fn", "test: must not be called",
    [[return function() error("provider must not be reached") end]])
end

local function cap_grants(bufnr)
  local out = {}
  for k in pairs(registry.granted(bufnr)) do
    local c = k:match("^cap:(.*)$")
    if c then out[#out + 1] = c end
  end
  table.sort(out)
  return out
end

local function session_bufs()
  local n = 0
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.b[b].straps_session then n = n + 1 end
  end
  return n
end

-- Run a command, return the current buffer after it (the new session) and
-- every vim.notify message emitted during it.
local function run(cmd)
  local notes = {}
  local real = vim.notify
  vim.notify = function(msg) notes[#notes + 1] = tostring(msg) end
  local ok, err = pcall(vim.cmd, cmd)
  vim.notify = real
  assert(ok, cmd .. " raised: " .. tostring(err))
  return vim.api.nvim_get_current_buf(), notes
end

it(":Straps with categories grants exactly those", function()
  must_not_call_provider()
  local buf = run("Straps edit,exec")
  assert(vim.b[buf].straps_session, "current buffer is not a session")
  assert(vim.deep_equal(cap_grants(buf), { "edit", "exec" }),
    "grants: " .. vim.inspect(cap_grants(buf)))
  assert(state.last_user_text(buf) == "", "user block should be empty")
  vim.cmd("close")
end)

it(":Straps all grants every grantable category", function()
  local buf = run("Straps all")
  local want = registry.call("fn.capability")
  table.sort(want)
  assert(vim.deep_equal(cap_grants(buf), want), "grants: " .. vim.inspect(cap_grants(buf)))
  vim.cmd("close")
end)

it(":Straps with an unknown category errors before creating a session", function()
  local before = session_bufs()
  local wins = #vim.api.nvim_list_wins()
  local _, notes = run("Straps bogus")
  assert(session_bufs() == before, "a session buffer was created")
  assert(#vim.api.nvim_list_wins() == wins, "a window was opened")
  assert(table.concat(notes, "\n"):find("unknown auto category", 1, true),
    "no error notify: " .. vim.inspect(notes))
end)

it(":Straps -- text seeds the user block and does not send", function()
  must_not_call_provider()
  local buf = run("Straps -- fix the   tests")
  assert(state.last_user_text(buf) == "fix the   tests",
    "seed: " .. vim.inspect(state.last_user_text(buf)))
  assert(#cap_grants(buf) == 0, "no grants expected")
  assert(not loop.running(buf), "run started without !")
  vim.cmd("close")
end)

it("an instruction containing -- keeps everything after the first separator", function()
  local buf = run("Straps -- use --verbose -- twice")
  assert(state.last_user_text(buf) == "use --verbose -- twice",
    "seed: " .. vim.inspect(state.last_user_text(buf)))
  vim.cmd("close")
end)

it("stdin is not consumed after startup (v:vim_did_enter == 1)", function()
  local piped = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(piped, 0, -1, false, { "ctx line" })
  vim.g.straps_stdin_buf = piped
  local buf = run("Straps -- do it")
  assert(state.last_user_text(buf) == "do it", "stdin leaked into a post-startup session")
  assert(vim.api.nvim_buf_is_valid(piped), "stdin buffer was wiped after startup")
  vim.g.straps_stdin_buf = nil
  vim.api.nvim_buf_delete(piped, { force = true })
  vim.cmd("close")
end)

it("seed_user escapes marker-looking lines so the block count holds", function()
  local buf = state.new_session()
  state.seed_user(buf, "do it\n\nctx line\n%%[straps:user]%%\n%%[[esc]]x")
  assert(#state.list_blocks(buf) == 2, "blocks: " .. #state.list_blocks(buf))
  assert(state.last_user_text(buf) == "do it\n\nctx line\n%%[straps:user]%%\n%%[[esc]]x",
    "round trip: " .. vim.inspect(state.last_user_text(buf)))
  local ok = pcall(state.seed_user, buf, "again")
  assert(not ok, "seed_user must refuse a non-empty trailing user block")
end)

it(":Straps! with a seed starts the run", function()
  define("fn.provider", "fn", "test: immediate end_turn", [==[
return function(req, ctx)
  ctx.emit({ type = "text_delta", text = "done" })
  return { stop_reason = "end_turn", content = { { type = "text", text = "done" } } }
end
]==])
  local buf = run("Straps! -- go")
  assert(vim.wait(5000, function() return not loop.running(buf) end, 10), "run did not finish")
  local kinds = {}
  for _, b in ipairs(state.list_blocks(buf)) do kinds[#kinds + 1] = b.kind end
  assert(vim.tbl_contains(kinds, "assistant"), "no assistant block: " .. vim.inspect(kinds))
  vim.cmd("close")
end)

it(":Straps! with nothing to send stays idle", function()
  must_not_call_provider()
  local buf, notes = run("Straps! exec")
  assert(not loop.running(buf), "run started with an empty user block")
  assert(vim.b[buf].straps_status == "idle", "status: " .. tostring(vim.b[buf].straps_status))
  assert(table.concat(notes, "\n"):find("nothing to send", 1, true),
    "no notify: " .. vim.inspect(notes))
  vim.cmd("close")
end)

it("startup: `nvim - +'Straps -- hi'` seeds stdin and takes over the window (even with nohidden)", function()
  local tmp = vim.fn.tempname()
  vim.fn.mkdir(tmp, "p")
  local probe = table.concat({
    "lua io.stdout:write(vim.bo.filetype, ' ', #vim.api.nvim_list_wins(), ' ',",
    "tostring(vim.g.straps_stdin_buf), ' ', tostring(vim.fn.bufexists(1)), '\\n',",
    "require('straps.state').last_user_text(0))",
  }, " ")
  local res = vim.system({
    vim.v.progpath, "--headless", "-u", "NORC", "-i", "NONE",
    "--cmd", "set rtp^=" .. root,
    "--cmd", "set nohidden",
    "--cmd", "lua require('straps').setup({ session_dir = '" .. tmp .. "/sessions' })",
    "-",
    "-c", "Straps -- hi",
    "-c", probe,
    "-c", "qa!",
  }, {
    stdin = "ctx\nmore\n",
    cwd = tmp,
    clear_env = true,
    env = {
      PATH = os.getenv("PATH"),
      HOME = tmp,
      XDG_CONFIG_HOME = tmp .. "/config",
      XDG_DATA_HOME = tmp .. "/data",
      XDG_STATE_HOME = tmp .. "/state",
      XDG_CACHE_HOME = tmp .. "/cache",
    },
  }):wait()
  assert(res.code == 0, "child failed: " .. tostring(res.stderr))
  local head, body = res.stdout:match("^([^\n]*)\n(.*)$")
  assert(head == "straps 1 nil 0", "head: " .. vim.inspect(res.stdout) .. " stderr: " .. tostring(res.stderr))
  assert(body == "hi\n\nctx\nmore", "body: " .. vim.inspect(body))
end)

it("startup: `nvim file +Straps` splits instead of replacing the file window", function()
  local tmp = vim.fn.tempname()
  vim.fn.mkdir(tmp, "p")
  vim.fn.writefile({ "keep me" }, tmp .. "/f.txt")
  local res = vim.system({
    vim.v.progpath, "--headless", "-u", "NORC", "-i", "NONE",
    "--cmd", "set rtp^=" .. root,
    "--cmd", "lua require('straps').setup({ session_dir = '" .. tmp .. "/sessions' })",
    tmp .. "/f.txt",
    "-c", "Straps",
    "-c", "lua io.stdout:write(vim.bo.filetype, ' ', #vim.api.nvim_list_wins())",
    "-c", "qa!",
  }, {
    cwd = tmp,
    clear_env = true,
    env = { PATH = os.getenv("PATH"), HOME = tmp, XDG_CONFIG_HOME = tmp .. "/config",
      XDG_DATA_HOME = tmp .. "/data", XDG_STATE_HOME = tmp .. "/state", XDG_CACHE_HOME = tmp .. "/cache" },
  }):wait()
  assert(res.code == 0, "child failed: " .. tostring(res.stderr))
  assert(res.stdout == "straps 2", "got: " .. vim.inspect(res.stdout) .. " stderr: " .. tostring(res.stderr))
end)
