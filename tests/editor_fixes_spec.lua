-- tests/editor_fixes_spec.lua — editor.lua tool-failure convention and fixes:
-- position encoding, async format, write-path concurrency checks, rollback on
-- failed move/delete, tags fallback, diagnostic ranges, read_symbol cap,
-- show_diff/show_buffer window reuse, delete_file window/buffer handling.
--   busted tests/editor_fixes_spec.lua
-- An in-process fake LSP server (vim.lsp.start with a cmd function) records
-- requests and answers from per-method handlers.

local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(vim.fn.fnamemodify(here, ":p"), ":h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

require("straps").config.session_dir = vim.fn.tempname()

local registry = require("straps.registry")
require("straps.tools").register()
require("straps.editor").register()

local unpack = unpack or table.unpack
local function pack(...) return { n = select("#", ...), ... } end

local work = assert(vim.uv.fs_realpath(vim.fn.tempname():match("^(.*)/") or "/tmp"))
work = work .. "/editor_fixes_" .. tostring(vim.uv.hrtime())
vim.fn.mkdir(work, "p")
vim.fn.chdir(work)

local function drive(thunk, ctx_extra)
  local out, raised, finished, co
  local awaits = 0
  local ctx = {
    bufnr = 0,
    await = function(start)
      awaits = awaits + 1
      local resolved = false
      start(function(...)
        if resolved then return end
        resolved = true
        local a = pack(...)
        vim.schedule(function()
          if coroutine.status(co) == "suspended" then
            local ok, e = coroutine.resume(co, unpack(a, 1, a.n))
            if not ok then finished = true; error(e) end
          end
        end)
      end)
      return coroutine.yield()
    end,
  }
  for k, v in pairs(ctx_extra or {}) do ctx[k] = v end
  co = coroutine.create(function()
    local ok, r = pcall(thunk, ctx)
    if ok then out = r else raised = tostring(r) end
    finished = true
  end)
  local ok, err = coroutine.resume(co)
  if not ok then error(err) end
  vim.wait(8000, function() return finished end, 10)
  assert(finished, "drive: thunk did not finish")
  return out, raised, awaits
end

local function call(name, input, ctx_extra)
  return drive(function(ctx) return registry.call("tool." .. name, input, ctx) end, ctx_extra)
end

local function write(path, text)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local f = assert(io.open(path, "w")); f:write(text); f:close()
end
local function disk(path) return table.concat(vim.fn.readfile(path), "\n") end
local function buf_text(buf) return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n") end
local function load(path)
  local b = vim.fn.bufadd(path)
  vim.fn.bufload(b)
  return b
end

local server = { log = {}, handlers = {}, encoding = "utf-16" }
local function fake_cmd(dispatchers)
  local closing = false
  local id = 0
  return {
    request = function(method, params, callback)
      id = id + 1
      server.log[#server.log + 1] = { method = method, params = params }
      local result
      if method == "initialize" then
        result = { capabilities = {
          positionEncoding = server.encoding,
          hoverProvider = true,
          renameProvider = true,
          documentFormattingProvider = true,
          documentRangeFormattingProvider = true,
          codeActionProvider = true,
          workspace = { fileOperations = {
            willRename = { filters = { { pattern = { glob = "**" } } } },
            willDelete = { filters = { { pattern = { glob = "**" } } } },
          } },
        } }
      elseif server.handlers[method] then
        result = server.handlers[method](params)
      end
      vim.schedule(function() callback(nil, result) end)
      return true, id
    end,
    notify = function(method, params)
      server.log[#server.log + 1] = { method = method, params = params }
      return true
    end,
    is_closing = function() return closing end,
    terminate = function() closing = true end,
  }
end

local function attach(buf, encoding)
  server.encoding = encoding or "utf-16"
  local id = vim.lsp.start({ name = "fake-" .. server.encoding, cmd = fake_cmd, root_dir = work },
    { bufnr = buf, reuse_client = function(c, cfg) return c.name == cfg.name end })
  vim.wait(2000, function()
    local c = vim.lsp.get_client_by_id(id)
    return c and c.initialized
  end, 10)
  return id
end

local function last(method)
  for i = #server.log, 1, -1 do
    if server.log[i].method == method then return server.log[i].params end
  end
end

local function set_ft(buf, ft) vim.bo[buf].filetype = ft end

-- ------------------------------------------------------------------- finding 6

it("6: a missing path raises '<tool>: no such file' and creates no buffer", function()
  local missing = work .. "/nope_" .. tostring(vim.uv.hrtime()) .. ".lua"
  for _, n in ipairs({ "diagnostics", "symbols", "read_symbol", "node_at" }) do
    local _, raised = call(n, { path = missing, name = "x", line = 1, col = 1 })
    assert(raised and raised:find(n .. ": no such file: ", 1, true), n .. ": " .. tostring(raised))
  end
  assert(vim.fn.bufexists(missing) == 0, "a stray buffer was created for the missing path")
  local _, raised = call("diagnostic_at", { line = 1, col = 1 })
  assert(raised == "diagnostic_at: path is required", tostring(raised))
end)

-- ------------------------------------------------------------------- finding 8

it("8: diagnostic_at treats end_col as exclusive and matches zero-width diagnostics at start", function()
  local path = work .. "/diag.txt"
  write(path, "one two\n")
  local buf = load(path)
  local ns = vim.api.nvim_create_namespace("editor_fixes_diag")
  vim.diagnostic.set(ns, buf, {
    { lnum = 0, col = 0, end_lnum = 0, end_col = 3, severity = vim.diagnostic.severity.ERROR, message = "word" },
    { lnum = 0, col = 5, end_lnum = 0, end_col = 5, severity = vim.diagnostic.severity.WARN, message = "point" },
  })
  local at3 = call("diagnostic_at", { path = path, line = 1, col = 3 })
  assert(at3:find("ERROR word", 1, true), at3)
  local at4 = call("diagnostic_at", { path = path, line = 1, col = 4 })
  assert(at4 == "no diagnostic at that position", "end_col must be exclusive: " .. at4)
  local at6 = call("diagnostic_at", { path = path, line = 1, col = 6 })
  assert(at6:find("WARN point", 1, true), "zero-width diagnostic missed at its start: " .. at6)
  local fix4 = call("fix_diagnostic", { path = path, line = 1, col = 4 })
  assert(fix4 == "fix_diagnostic: no diagnostic at that position", "fix_diagnostic end_col: " .. tostring(fix4))
end)

-- ------------------------------------------------------------------- finding 7

it("7: tags fallback returns file:line:col and honors quickfix=true", function()
  local target = work .. "/tagged.py"
  write(target, "x = 1\ndef wanted():\n    pass\n")
  local tagsfile = work .. "/tags"
  write(tagsfile, "wanted\t" .. target .. "\t/^def wanted():$/;\"\tf\n")
  local saved = vim.o.tags
  vim.o.tags = tagsfile
  local user = work .. "/user.py"
  write(user, "wanted()\n")
  vim.fn.setqflist({}, "f")
  local out, raised = call("definition", { path = user, line = 1, col = 2, quickfix = true, open = false })
  vim.o.tags = saved
  assert(not raised, tostring(raised))
  assert(out:find("tagged.py:2:5", 1, true), "expected file:line:col: " .. out)
  assert(not out:find("\t", 1, true), "raw tag line leaked: " .. out)
  local qf = vim.fn.getqflist()
  assert(#qf == 1 and qf[1].lnum == 2 and qf[1].col == 5, "quickfix not populated: " .. vim.inspect(qf))
end)

-- ------------------------------------------------------------------- finding 5

it("5: position params convert byte columns to the client's offset encoding", function()
  local path = work .. "/multi.txt"
  write(path, "ääx\n")
  local buf = load(path)
  server.handlers["textDocument/hover"] = function() return { contents = "hi" } end
  local id = attach(buf, "utf-16")
  call("hover", { path = path, line = 1, col = 5 })
  assert(last("textDocument/hover").position.character == 2,
    "utf-16 character wrong: " .. vim.inspect(last("textDocument/hover").position))
  vim.lsp.stop_client(id, true)
  vim.wait(1000, function() return #vim.lsp.get_clients({ bufnr = buf }) == 0 end, 10)
  id = attach(buf, "utf-32")
  call("hover", { path = path, line = 1, col = 5 })
  assert(last("textDocument/hover").position.character == 2, "utf-32 character wrong")
  vim.lsp.stop_client(id, true)
  vim.wait(1000, function() return #vim.lsp.get_clients({ bufnr = buf }) == 0 end, 10)
  id = attach(buf, "utf-8")
  call("hover", { path = path, line = 1, col = 5 })
  assert(last("textDocument/hover").position.character == 4, "utf-8 character wrong")
  vim.lsp.stop_client(id, true)
  vim.wait(1000, function() return #vim.lsp.get_clients({ bufnr = buf }) == 0 end, 10)
end)

-- ------------------------------------------------------------------- finding 4

it("4: format sends formatting through ctx.await and applies the edits; one bound alone raises", function()
  local path = work .. "/fmt.txt"
  write(path, "a  b\nc\n")
  local buf = load(path)
  set_ft(buf, "fmttest")
  local id = attach(buf)
  server.handlers["textDocument/formatting"] = function()
    return { { range = { start = { line = 0, character = 1 }, ["end"] = { line = 0, character = 3 } }, newText = " " } }
  end
  registry.define({ name = "hook.after_write", kind = "hook", doc = "test",
    source = [[return function(path) return "AFTER:" .. path end]] })
  local out, raised, awaits = call("format", { path = path })
  assert(not raised, tostring(raised))
  assert(out:find("formatted", 1, true) and out:find("AFTER:", 1, true), out)
  assert(disk(path) == "a b\nc", "edit not applied and saved: " .. disk(path))
  assert(awaits >= 2, "formatting request did not go through ctx.await (awaits=" .. awaits .. ")")
  local _, r2 = call("format", { path = path, start_line = 1 })
  assert(r2 == "format: pass both start_line and end_line, or neither", tostring(r2))
  registry.define({ name = "hook.after_write", kind = "hook", doc = "no-op",
    source = [[return function() end]] })
  vim.lsp.stop_client(id, true)
  vim.wait(1000, function() return #vim.lsp.get_clients({ bufnr = buf }) == 0 end, 10)
end)

-- ------------------------------------------------------------------- finding 2

it("2: rename_symbol refuses another session's unseen write and stamps its own", function()
  local path = work .. "/ren.txt"
  write(path, "foo\n")
  local buf = load(path)
  set_ft(buf, "rentest")
  local id = attach(buf)
  server.handlers["textDocument/rename"] = function(p)
    return { changes = { [p.textDocument.uri] = {
      { range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 3 } }, newText = p.newName },
    } } }
  end
  local A = vim.api.nvim_create_buf(false, true)
  local B = vim.api.nvim_create_buf(false, true)
  vim.b[B].straps_task = "other"
  registry.call("tool.read_file", { path = path }, { bufnr = A })
  registry.call("tool.edit_file", { path = path, old_string = "foo", new_string = "bar" }, { bufnr = B })
  local _, raised = call("rename_symbol", { path = path, line = 1, col = 1, new_name = "baz" }, { bufnr = A })
  assert(raised and raised:find("rename_symbol: ", 1, true) and raised:find("another agent", 1, true),
    "expected a concurrent-writer refusal: " .. tostring(raised))
  assert(disk(path) == "bar", "refused rename must not change the file: " .. disk(path))
  registry.call("tool.read_file", { path = path }, { bufnr = A })
  local out, r2 = call("rename_symbol", { path = path, line = 1, col = 1, new_name = "baz" }, { bufnr = A })
  assert(not r2, tostring(r2))
  assert(out:find("renamed to baz", 1, true), out)
  assert(disk(path) == "baz", disk(path))
  local stamp = vim.b[buf].straps_last_writer
  assert(type(stamp) == "table" and stamp.session == A, "rename did not stamp the writer: " .. vim.inspect(stamp))
  vim.lsp.stop_client(id, true)
  vim.wait(1000, function() return #vim.lsp.get_clients({ bufnr = buf }) == 0 end, 10)
end)

-- ------------------------------------------------------------------- finding 3

it("3: failed move_file/delete_file roll back the server's reference edits", function()
  local ref = work .. "/ref/user.txt"
  write(ref, "import old\n")
  local rbuf = load(ref)
  local ro = work .. "/ro"
  local src = ro .. "/old.txt"
  write(src, "content\n")
  local sbuf = load(src)
  set_ft(sbuf, "movetest")
  local id = attach(sbuf)
  local edit = function()
    return { changes = { [vim.uri_from_fname(ref)] = {
      { range = { start = { line = 0, character = 7 }, ["end"] = { line = 0, character = 10 } }, newText = "new" },
    } } }
  end
  server.handlers["workspace/willRenameFiles"] = edit
  server.handlers["workspace/willDeleteFiles"] = edit
  vim.uv.fs_chmod(ro, tonumber("555", 8))
  local _, raised = call("move_file", { from = src, to = ro .. "/new.txt" })
  assert(raised and raised:find("move_file: rename failed", 1, true), tostring(raised))
  assert(raised:find("reference edits rolled back", 1, true), raised)
  assert(buf_text(rbuf) == "import old" and not vim.bo[rbuf].modified, "move rollback failed: " .. buf_text(rbuf))
  local _, r2 = call("delete_file", { path = src })
  assert(r2 and r2:find("delete_file: failed to delete", 1, true), tostring(r2))
  assert(r2:find("reference edits rolled back", 1, true), r2)
  assert(buf_text(rbuf) == "import old" and not vim.bo[rbuf].modified, "delete rollback failed: " .. buf_text(rbuf))
  assert(disk(ref) == "import old", "reference file must not be saved")
  vim.uv.fs_chmod(ro, tonumber("755", 8))
  vim.lsp.stop_client(id, true)
  vim.wait(1000, function() return #vim.lsp.get_clients({ bufnr = sbuf }) == 0 end, 10)
end)

-- ------------------------------------------------------------------ finding 13

it("13: delete_file keeps the user's windows open on the deleted file", function()
  vim.cmd("only")
  local keep = work .. "/keep.txt"
  local gone = work .. "/gone.txt"
  write(keep, "keep\n")
  write(gone, "gone\n")
  vim.cmd("edit " .. vim.fn.fnameescape(keep))
  vim.cmd("vsplit " .. vim.fn.fnameescape(gone))
  local w = vim.api.nvim_get_current_win()
  local n = #vim.api.nvim_list_wins()
  local out, raised = call("delete_file", { path = gone })
  assert(not raised, tostring(raised))
  assert(out:find("deleted", 1, true), out)
  assert(#vim.api.nvim_list_wins() == n and vim.api.nvim_win_is_valid(w), "a window was closed")
  assert(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w)) ~= assert(vim.uv.fs_realpath(work)) .. "/gone.txt",
    "window still shows the wiped buffer")
  vim.cmd("only")
end)

-- ------------------------------------------------------------------ finding 14

it("14: delete_file matches the buffer name exactly (no partial match)", function()
  local p = work .. "/exact.txt"
  local longer = work .. "/exact.txt.bak"
  write(p, "x\n")
  write(longer, "y\n")
  local lb = load(longer)
  vim.api.nvim_buf_set_lines(lb, 0, -1, false, { "unsaved" })
  local out, raised = call("delete_file", { path = p })
  assert(not raised, "delete refused because of another buffer: " .. tostring(raised))
  assert(out:find("deleted", 1, true), out)
  assert(vim.fn.filereadable(p) == 0)
  assert(vim.api.nvim_buf_is_valid(lb) and buf_text(lb) == "unsaved", "the other buffer was touched")
  vim.bo[lb].modified = false
end)

-- ---------------------------------------------------------------- finding 9/10

it("9/10: symbols doc names nesting; node_at doc states its cap; read_symbol caps at 1000 lines", function()
  assert(registry.get("tool.symbols").doc:find("every nesting depth", 1, true), "symbols doc")
  assert(not registry.get("tool.symbols").doc:find("top-level", 1, true), "symbols doc still says top-level")
  assert(registry.get("tool.node_at").doc:find("max 5000", 1, true), "node_at doc")
  local path = work .. "/big.lua"
  local lines = { "local function huge()" }
  for i = 1, 1200 do lines[#lines + 1] = "  local v" .. i .. " = " .. i end
  lines[#lines + 1] = "end"
  write(path, table.concat(lines, "\n") .. "\n")
  local b = load(path)
  set_ft(b, "lua")
  if not pcall(vim.treesitter.get_parser, b, "lua") then
    print("SKIP read_symbol cap: no lua parser")
    return
  end
  local out, raised = call("read_symbol", { path = path, name = "huge" })
  assert(not raised, tostring(raised))
  local n = select(2, out:gsub("\n", "\n")) + 1
  assert(n == 1001, "expected 1000 lines + note, got " .. n)
  assert(out:find("[truncated: showing 1000 of 1202 lines; read_file offset=1001", 1, true), out:sub(-200))
end)

-- ------------------------------------------------------------------ finding 12

it("12: show_diff and show_buffer reuse their tagged windows; winbar escapes %", function()
  vim.cmd("only")
  call("show_diff", { left = "a\n", right = "b\n" })
  local n = #vim.api.nvim_list_wins()
  call("show_diff", { left = "c\n", right = "d\n" })
  assert(#vim.api.nvim_list_wins() == n, "show_diff added windows on the second call")
  call("show_buffer", { content = "x", title = "100% done" })
  local m = #vim.api.nvim_list_wins()
  call("show_buffer", { content = "y", title = "50% more" })
  assert(#vim.api.nvim_list_wins() == m, "show_buffer added a window on the second call")
  local win
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.w[w].straps_view == "buffer" then win = w end
  end
  assert(win, "no tagged show_buffer window")
  assert(vim.wo[win].winbar == "50%% more", "winbar not escaped: " .. vim.wo[win].winbar)
  assert(buf_text(vim.api.nvim_win_get_buf(win)) == "y", "window buffer not replaced")
  vim.cmd("windo diffoff")
  vim.cmd("only")
end)

local function replacement(path, text)
  return { changes = { [vim.uri_from_fname(path)] = {
    { range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 3 } }, newText = text },
  } } }
end

for _, case in ipairs({
  { name = "rename_symbol", method = "textDocument/rename" },
  { name = "move_file", method = "workspace/willRenameFiles" },
  { name = "delete_file", method = "workspace/willDeleteFiles" },
  { name = "code_action", method = "textDocument/codeAction" },
  { name = "code_action", method = "codeAction/resolve" },
  { name = "fix_diagnostic", method = "textDocument/codeAction" },
  { name = "fix_diagnostic", method = "codeAction/resolve" },
}) do
  it(case.name .. " preserves pending-response user edits during " .. case.method, function()
    local path = work .. "/pending-" .. case.name .. case.method:gsub("/", "-")
    local ref = path .. "-ref"
    write(path, "old\n")
    write(ref, "old\n")
    local buf, rbuf = load(path), load(ref)
    attach(buf)
    if case.name == "fix_diagnostic" then
      vim.diagnostic.set(vim.api.nvim_create_namespace(path), buf, {
        { lnum = 0, col = 0, end_col = 3, message = "fix", severity = vim.diagnostic.severity.ERROR },
      })
    end
    local action_tool = case.name == "code_action" or case.name == "fix_diagnostic"
    server.handlers["textDocument/codeAction"] = function() return { { title = "fix", data = {} } } end
    server.handlers[case.method] = function()
      vim.api.nvim_buf_set_lines(rbuf, 0, -1, false, { "user edit" })
      local edit = replacement(ref, "new")
      if action_tool then
        local action = { title = "fix", edit = edit }
        return case.method == "textDocument/codeAction" and { action } or action
      end
      return edit
    end
    local input = { path = path, line = 1, col = 1, index = 1, new_name = "new" }
    if case.name == "move_file" then input = { from = path, to = path .. "-new" } end
    local _, err = call(case.name, input)
    assert(err and err:find("changed while awaiting server responses", 1, true), tostring(err))
    assert(buf_text(rbuf) == "user edit", "user text changed: " .. buf_text(rbuf))
    assert(vim.bo[rbuf].modified, "user edit no longer marked modified")
    assert(disk(ref) == "old", "user edit saved: " .. disk(ref))
    assert(vim.fn.filereadable(path) == 1, "source moved or deleted")
    assert(vim.fn.filereadable(path .. "-new") == 0, "destination created")
    vim.bo[rbuf].modified = false
  end)
end

for _, kind in ipairs({ "create", "rename", "delete" }) do
  it("rejects " .. kind .. " resource operations before applying any text or disk edits", function()
    local path = work .. "/resource-" .. kind
    local destination = path .. "-new"
    write(path, "old\n")
    local buf = load(path)
    attach(buf)
    local uri = vim.uri_from_fname(path)
    server.handlers["textDocument/rename"] = function()
      return { documentChanges = {
        { textDocument = { uri = uri, version = vim.NIL }, edits = replacement(path, "new").changes[uri] },
        { kind = kind, uri = kind == "create" and vim.uri_from_fname(destination) or uri,
          oldUri = uri, newUri = vim.uri_from_fname(destination) },
      } }
    end
    local _, err = call("rename_symbol", { path = path, line = 1, col = 1, new_name = "new" })
    assert(err and err:find("resource operations", 1, true), tostring(err))
    assert(buf_text(buf) == "old", buf_text(buf))
    assert(disk(path) == "old", "resource changed disk")
    assert(vim.fn.filereadable(destination) == 0, "resource created destination")
  end)
end

it("refuses formatting after the formatter changes the disk file", function()
  local path = work .. "/format-external"
  write(path, "old\n")
  local buf = load(path)
  attach(buf)
  local apply_text_edits = vim.lsp.util.apply_text_edits
  vim.lsp.util.apply_text_edits = function() error("stale formatting edit applied") end
  server.handlers["textDocument/formatting"] = function()
    write(path, "external change\n")
    return replacement(path, "new").changes[vim.uri_from_fname(path)]
  end
  local _, err = call("format", { path = path })
  vim.lsp.util.apply_text_edits = apply_text_edits
  assert(err and err:find("changed on disk", 1, true), tostring(err))
  assert(disk(path) == "external change", disk(path))
end)

for _, name in ipairs({ "delete_file", "delete_files" }) do
  it(name .. " refuses target edits during the server request", function()
    local path = work .. "/changed-" .. name
    local ref = path .. "-ref"
    write(path, "old\n")
    write(ref, "old\n")
    local buf, rbuf = load(path), load(ref)
    attach(buf)
    server.handlers["workspace/willDeleteFiles"] = function()
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "user edit" })
      return replacement(ref, "new")
    end
    local _, err = call(name, name == "delete_file" and { path = path } or { paths = { path } })
    assert(err and err:find("refusing", 1, true), tostring(err))
    assert(vim.fn.filereadable(path) == 1, "deleted changed target")
    assert(buf_text(buf) == "user edit", buf_text(buf))
    assert(buf_text(rbuf) == "old", buf_text(rbuf))
    assert(not vim.bo[rbuf].modified, "reference rollback left modified")
    vim.bo[buf].modified = false
  end)
end

for _, name in ipairs({ "move_files", "delete_files" }) do
  for _, concurrent in ipairs({ false, true }) do
    it(name .. (concurrent and " preserves user edits during later requests" or " rolls disjoint client edits back on filesystem failure"), function()
      local base = work .. "/batch-" .. name .. tostring(concurrent)
      local first, second, ref, ref2 = base .. "-a", base .. "-b", base .. "-ref", base .. "-ref2"
      write(first, "old\n"); write(second, "old\n"); write(ref, "old\n"); write(ref2, "old\n")
      local a, b, rbuf, rbuf2 = load(first), load(second), load(ref), load(ref2)
      set_ft(a, "batcha"); set_ft(b, "batchb")
      attach(a, "utf-16"); attach(b, "utf-8")
      local count, before_second = 0, nil
      local method = name == "move_files" and "workspace/willRenameFiles" or "workspace/willDeleteFiles"
      server.handlers[method] = function()
        count = count + 1
        if count == 2 then
          if concurrent then
            before_second = buf_text(rbuf)
            vim.api.nvim_buf_set_lines(rbuf, 0, -1, false, { "user edit" })
          end
        end
        return replacement(count == 1 and ref or ref2, count == 1 and "one" or "two")
      end
      local original = name == "move_files" and vim.lsp.util.rename or os.remove
      if name == "move_files" then vim.lsp.util.rename = function() error("forced failure") end
      else os.remove = function() return nil, "forced failure" end end
      local _, err = call(name, name == "move_files"
        and { moves = { { from = first, to = first .. "-new" }, { from = second, to = second .. "-new" } } }
        or { paths = { first, second } })
      if name == "move_files" then vim.lsp.util.rename = original else os.remove = original end
      assert(count == 2, "expected two clients, got " .. count)
      if concurrent then assert(before_second == "old", "reference edit applied before all requests completed") end
      assert(err and err:find(concurrent and "reference buffer changed" or "forced failure", 1, true), tostring(err))
      assert(buf_text(rbuf) == (concurrent and "user edit" or "old"), buf_text(rbuf))
      assert(vim.bo[rbuf].modified == concurrent, "reference modified state changed")
      assert(disk(ref) == "old", disk(ref))
      assert(buf_text(rbuf2) == "old", buf_text(rbuf2))
      assert(not vim.bo[rbuf2].modified, "second reference rollback left modified")
      assert(disk(ref2) == "old", disk(ref2))
      vim.bo[rbuf].modified = false
    end)
  end
end

for _, name in ipairs({ "move_files", "delete_files" }) do
  it(name .. " refuses client edits sharing a target before applying anything", function()
    local base = work .. "/shared-target-" .. name
    local first, second, ref = base .. "-a", base .. "-b", base .. "-ref"
    write(first, "first\n"); write(second, "second\n"); write(ref, "abc xyz\n")
    local a, b, rbuf = load(first), load(second), load(ref)
    set_ft(a, "shareda"); set_ft(b, "sharedb")
    attach(a, "utf-16"); attach(b, "utf-8")
    local count, applied = 0, 0
    local method = name == "move_files" and "workspace/willRenameFiles" or "workspace/willDeleteFiles"
    server.handlers[method] = function()
      count = count + 1
      local edit = {
        range = { start = { line = 0, character = count == 1 and 0 or 4 },
          ["end"] = { line = 0, character = count == 1 and 0 or 7 } },
        newText = count == 1 and "X" or "Q",
      }
      if count == 1 then return { changes = { [vim.uri_from_fname(ref)] = { edit } } } end
      return { documentChanges = { { textDocument = { uri = vim.uri_from_fname(ref) }, edits = { edit } } } }
    end
    local original = vim.lsp.util.apply_workspace_edit
    vim.lsp.util.apply_workspace_edit = function(...)
      applied = applied + 1
      return original(...)
    end
    local _, err = call(name, name == "move_files"
      and { moves = { { from = first, to = first .. "-new" }, { from = second, to = second .. "-new" } } }
      or { paths = { first, second } })
    vim.lsp.util.apply_workspace_edit = original
    assert(count == 2, "expected both client responses")
    assert(err and err:find("multiple WorkspaceEdits target the same buffer", 1, true), tostring(err))
    assert(applied == 0, "applied a reference edit before refusing")
    assert(buf_text(rbuf) == "abc xyz", buf_text(rbuf))
    assert(not vim.bo[rbuf].modified, "reference buffer modified")
    assert(disk(ref) == "abc xyz", disk(ref))
    assert(disk(first) == "first", "first source changed")
    assert(disk(second) == "second", "second source changed")
    assert(buf_text(a) == "first", "first source buffer changed")
    assert(buf_text(b) == "second", "second source buffer changed")
    assert(vim.api.nvim_buf_get_name(a) == first, "first source buffer renamed")
    assert(vim.api.nvim_buf_get_name(b) == second, "second source buffer renamed")
    assert(vim.fn.filereadable(first .. "-new") == 0, "first destination created")
    assert(vim.fn.filereadable(second .. "-new") == 0, "second destination created")
  end)
end

for _, name in ipairs({ "show_buffer", "show_diff" }) do
  it(name .. " preserves a normal file opened in its former presentation window", function()
    vim.cmd("only")
    local input = name == "show_buffer" and { content = "report" } or { left = "old", right = "new" }
    local _, err = call(name, input)
    assert(not err, tostring(err))
    local tag = name == "show_buffer" and "buffer" or "diff"
    local win
    for _, w in ipairs(vim.api.nvim_list_wins()) do if vim.w[w].straps_view == tag then win = w; break end end
    assert(win, "presentation window missing")
    local normal = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_win_set_buf(win, normal)
    local _, next_err = call(name, input)
    assert(not next_err, tostring(next_err))
    assert(vim.api.nvim_win_is_valid(win), "normal window closed")
    assert(vim.api.nvim_win_get_buf(win) == normal, "normal buffer replaced")
    vim.cmd("windo diffoff")
    vim.cmd("only")
  end)
end

for _, name in ipairs({ "delete_file", "delete_files" }) do
  for _, change in ipairs({ "disk", "saved buffer" }) do
    it(name .. " revalidates " .. change .. " changes before deletion", function()
      local path = work .. "/late-" .. name .. change
      write(path, "old\n")
      local buf = load(path)
      attach(buf)
      server.handlers["workspace/willDeleteFiles"] = function()
        if change == "disk" then write(path, "external replacement\n")
        else
          vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "saved replacement" })
          vim.api.nvim_buf_call(buf, function() vim.cmd("silent noautocmd write") end)
        end
      end
      local _, err = call(name, name == "delete_file" and { path = path } or { paths = { path } })
      assert(err, "changed target was accepted")
      assert(vim.fn.filereadable(path) == 1, "changed target was deleted")
      assert(disk(path) == (change == "disk" and "external replacement" or "saved replacement"), disk(path))
    end)
  end
end
