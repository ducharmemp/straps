-- tests/run_editor.lua — editor-native tools (straps.editor).
--   nvim --headless -l tests/run_editor.lua
-- No network, no real LSP server. Covers: registration + schema; diagnostics
-- formatting (seeded via vim.diagnostic.set) and the empty case; tree-sitter
-- symbols/read_symbol on a Lua file (skipped-with-note if the lua parser is
-- unavailable headless); the graceful "no LSP client" fallback for
-- definition/references (driven through a real ctx.await); and that the five
-- names are in hook.confirm's auto-allow set.

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

-- Isolate any session writes (defensive; these tools don't create sessions).
require("straps").config.session_dir = vim.fn.tempname()

local registry = require("straps.registry")
require("straps.tools").register()  -- hook.confirm (with the auto-allow set)
require("straps.editor").register() -- editor-native tools

local unpack = unpack or table.unpack
local function pack(...) return { n = select("#", ...), ... } end

-- Minimal ctx.await driver: run a thunk that uses ctx.await inside a coroutine,
-- resolve resumes it via vim.schedule (as the loop does), then vim.wait for it.
local function drive(thunk, timeout_ms)
  local out, finished, co
  local ctx = {
    bufnr = 0,
    await = function(start)
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
  co = coroutine.create(function()
    out = thunk(ctx)
    finished = true
  end)
  local ok, err = coroutine.resume(co)
  if not ok then error(err) end
  vim.wait(timeout_ms or 8000, function() return finished end, 20)
  assert(finished, "drive: thunk did not finish within timeout")
  return out
end

local function write_file(path, text)
  local f = assert(io.open(path, "w"))
  f:write(text)
  f:close()
end

-- ---------------------------------------------------------------- registration

case("editor read-only tools registered as kind 'tool' with an input_schema", function()
  for _, n in ipairs({ "diagnostics", "diagnostic_at", "diagnostic_next", "lsp_status",
    "declaration", "definition", "type_definition", "implementation", "references",
    "tree_sitter_status", "node_at", "read_node", "symbols", "read_symbol",
    "fix_diagnostic" }) do
    local e = registry.get("tool." .. n)
    assert(e, "tool." .. n .. " not registered")
    assert(e.kind == "tool", "tool." .. n .. " wrong kind: " .. tostring(e.kind))
    assert(type(e.input_schema) == "table", "tool." .. n .. " missing input_schema")
    assert(e.input_schema.type == "object", "tool." .. n .. " schema not an object")
  end
end)

-- ------------------------------------------------------------------ diagnostics

case("diagnostics formats seeded diagnostics as file:line:col: SEVERITY message", function()
  local path = vim.fn.tempname() .. ".txt"
  write_file(path, "one\ntwo\nthree\n")
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  local ns = vim.api.nvim_create_namespace("straps_test_diag")
  vim.diagnostic.set(ns, buf, {
    { lnum = 0, col = 0, severity = vim.diagnostic.severity.ERROR, message = "boom", source = "tlint" },
    { lnum = 1, col = 2, severity = vim.diagnostic.severity.WARN, message = "careful" },
  })
  local out = registry.call("tool.diagnostics", { path = path }, { bufnr = 0 })
  assert(out:find(":1:1: ERROR boom [tlint]", 1, true), "error line missing:\n" .. out)
  assert(out:find(":2:3: WARN careful", 1, true), "warn line (1-based col) missing:\n" .. out)
end)

case("diagnostics with no diagnostics returns 'no diagnostics'", function()
  local path = vim.fn.tempname() .. ".txt"
  write_file(path, "clean\n")
  local out = registry.call("tool.diagnostics", { path = path }, { bufnr = 0 })
  assert(out == "no diagnostics", "expected 'no diagnostics', got: " .. tostring(out))
end)

case("diagnostic_at and diagnostic_next expose position-oriented diagnostics", function()
  local path = vim.fn.tempname() .. ".txt"
  write_file(path, "one\ntwo\nthree\n")
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  local ns = vim.api.nvim_create_namespace("straps_test_diag_nav")
  vim.diagnostic.set(ns, buf, {
    { lnum = 0, col = 0, end_lnum = 0, end_col = 3, severity = vim.diagnostic.severity.ERROR, message = "first" },
    { lnum = 2, col = 1, severity = vim.diagnostic.severity.WARN, message = "third" },
  })
  local at = registry.call("tool.diagnostic_at", { path = path, line = 1, col = 2 }, { bufnr = 0 })
  assert(at:find("ERROR first", 1, true), "diagnostic_at missed covering diagnostic: " .. at)
  local next_out = registry.call("tool.diagnostic_next", { path = path, line = 1, col = 3 }, { bufnr = 0 })
  assert(next_out:find(":3:2: WARN third", 1, true), "diagnostic_next wrong: " .. next_out)
  local prev_out = registry.call("tool.diagnostic_next", { path = path, line = 1, col = 1, direction = "prev" }, { bufnr = 0 })
  assert(prev_out:find("WARN third", 1, true), "diagnostic prev wrap wrong: " .. prev_out)
end)

case("fix_diagnostic reports no diagnostic before asking LSP", function()
  local path = vim.fn.tempname() .. ".txt"
  write_file(path, "clean\n")
  local out = drive(function(ctx)
    return registry.call("tool.fix_diagnostic", { path = path, line = 1, col = 1 }, ctx)
  end)
  assert(out == "fix_diagnostic: no diagnostic at that position", "unexpected: " .. tostring(out))
end)

-- --------------------------------------------------------- symbols / read_symbol

local lua_src = table.concat({
  "local M = {}",
  "",
  "local function alpha()",
  "  return 1",
  "end",
  "",
  "function M.beta(x)",
  "  return x + 1",
  "end",
  "",
  "return M",
}, "\n") .. "\n"

local lua_path = vim.fn.tempname() .. ".lua"
write_file(lua_path, lua_src)
local probe = vim.fn.bufadd(lua_path)
vim.fn.bufload(probe)
vim.bo[probe].filetype = "lua"
local has_lua_parser = pcall(vim.treesitter.get_parser, probe, "lua")

if not has_lua_parser then
  print("SKIP  symbols/read_symbol: no tree-sitter lua parser in this environment")
else
  case("symbols lists both functions with line ranges (tree-sitter)", function()
    local out = registry.call("tool.symbols", { path = lua_path }, { bufnr = 0 })
    assert(out:find("alpha", 1, true), "alpha missing from outline:\n" .. out)
    assert(out:find("M.beta", 1, true), "M.beta missing from outline:\n" .. out)
    assert(out:find("function", 1, true), "kind label missing:\n" .. out)
    assert(out:find("L%d+%-%d+"), "line range missing:\n" .. out)
  end)

  case("tree_sitter_status and node_at expose parser/node details", function()
    local status = registry.call("tool.tree_sitter_status", { path = lua_path }, { bufnr = 0 })
    assert(status:find("tree-sitter parser ready", 1, true), "status wrong:\n" .. status)
    assert(status:find("root=chunk", 1, true) or status:find("root=source_file", 1, true), "root missing:\n" .. status)
    local node = registry.call("tool.node_at", { path = lua_path, line = 3, col = 16 }, { bufnr = 0 })
    assert(node:find("function", 1, true) or node:find("identifier", 1, true), "node type missing:\n" .. node)
    assert(node:find("parents:", 1, true), "parent chain missing:\n" .. node)
  end)

  case("read_node returns an enclosing tree-sitter node with numbered lines", function()
    local out = registry.call("tool.read_node", {
      path = lua_path, line = 4, col = 9, ancestor = "function_declaration",
    }, { bufnr = 0 })
    assert(out:find("function_declaration", 1, true), "node header missing:\n" .. out)
    assert(out:find("local function alpha()", 1, true), "node text missing:\n" .. out)
    assert(out:match("\n%s*%d+\t"), "numbered lines missing:\n" .. out)
  end)

  case("read_symbol returns the body of a named function (numbered)", function()
    local out = registry.call("tool.read_symbol", { path = lua_path, name = "alpha" }, { bufnr = 0 })
    assert(out:find("local function alpha()", 1, true), "alpha body missing:\n" .. out)
    assert(out:find("return 1", 1, true), "alpha body incomplete:\n" .. out)
    assert(out:match("^%s*%d+\t"), "output not line-numbered like read_file:\n" .. out)
    assert(not out:find("M.beta", 1, true), "read_symbol leaked another symbol:\n" .. out)
  end)

  case("read_symbol on an unknown name returns the not-found message", function()
    local out = registry.call("tool.read_symbol", { path = lua_path, name = "nope" }, { bufnr = 0 })
    assert(out == "no symbol named nope in " .. lua_path,
      "unexpected not-found message: " .. tostring(out))
  end)
end

-- ------------------------------------------------ definition / references (no LSP)

case("definition with no LSP client returns the graceful fallback", function()
  local path = vim.fn.tempname() .. ".py"
  write_file(path, "x = 1\n")
  -- col 3 sits on '=', so there is no identifier under the position and no
  -- tags are consulted: we land straight on the no-client message.
  local out = drive(function(ctx)
    return registry.call("tool.definition", { path = path, line = 1, col = 3 }, ctx)
  end)
  assert(out:find("no LSP client", 1, true), "expected no-client fallback, got: " .. tostring(out))
  assert(out:find("python", 1, true), "fallback should name the filetype: " .. tostring(out))
end)

case("references with no LSP client returns the graceful fallback", function()
  local path = vim.fn.tempname() .. ".py"
  write_file(path, "y = 2\n")
  local out = drive(function(ctx)
    return registry.call("tool.references", { path = path, line = 1, col = 3 }, ctx)
  end)
  assert(out:find("no LSP client", 1, true), "expected no-client fallback, got: " .. tostring(out))
end)

case("declaration/type_definition/implementation no-client messages name the method", function()
  local path = vim.fn.tempname() .. ".py"
  write_file(path, "z = 3\n")
  for _, n in ipairs({ "declaration", "type_definition", "implementation" }) do
    local out = drive(function(ctx)
      return registry.call("tool." .. n, { path = path, line = 1, col = 1 }, ctx)
    end)
    assert(out:find("no LSP client", 1, true), n .. " fallback wrong: " .. tostring(out))
  end
end)

case("lsp_status reports no attached client for a file", function()
  local path = vim.fn.tempname() .. ".py"
  write_file(path, "z = 3\n")
  local out = drive(function(ctx)
    return registry.call("tool.lsp_status", { path = path }, ctx)
  end)
  assert(out:find("no LSP client attached", 1, true), "unexpected: " .. tostring(out))
  assert(out:find("python", 1, true), "should include filetype: " .. tostring(out))
end)

case("expanded editor read-only tools are auto-allowed by hook.confirm", function()
  for _, n in ipairs({ "diagnostic_at", "diagnostic_next", "lsp_status", "declaration",
    "type_definition", "implementation", "tree_sitter_status", "node_at", "read_node" }) do
    local allowed = registry.call("hook.confirm", n, {}, { bufnr = 0 })
    assert(allowed == true, n .. " should be auto-allowed")
  end
end)

-- ----------------------------------------------------------------- move_file

case("move_file: plain move (no LSP client) relocates the file, creating dirs", function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local from = dir .. "/a.txt"
  local to = dir .. "/sub/b.txt"
  write_file(from, "hello\nworld\n")

  local out = drive(function(ctx)
    return registry.call("tool.move_file", { from = from, to = to }, ctx)
  end)

  assert(out:find("moved", 1, true), "unexpected result: " .. tostring(out))
  assert(vim.fn.filereadable(from) == 0, "source should be gone")
  assert(vim.fn.filereadable(to) == 1, "destination should exist")
  assert(table.concat(vim.fn.readfile(to), "\n") == "hello\nworld", "content not preserved")
end)

case("move_file: missing source errors with a clear message", function()
  local out = drive(function(ctx)
    return registry.call("tool.move_file",
      { from = "/no/such/file.txt", to = "/tmp/whatever.txt" }, ctx)
  end)
  assert(out:find("no such file", 1, true), "unexpected message: " .. tostring(out))
end)

case("move_file: existing destination refuses rather than overwriting", function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local from, to = dir .. "/a.txt", dir .. "/b.txt"
  write_file(from, "a\n")
  write_file(to, "b\n")

  local out = drive(function(ctx)
    return registry.call("tool.move_file", { from = from, to = to }, ctx)
  end)

  assert(out:find("already exists", 1, true), "unexpected message: " .. tostring(out))
  assert(vim.fn.filereadable(from) == 1, "source should be untouched")
  assert(table.concat(vim.fn.readfile(to), "\n") == "b", "destination should be untouched")
end)

case("move_file requires both from and to", function()
  local out1 = drive(function(ctx) return registry.call("tool.move_file", { to = "x" }, ctx) end)
  assert(out1:find("from is required", 1, true), "missing from-required message: " .. tostring(out1))
  local out2 = drive(function(ctx) return registry.call("tool.move_file", { from = "x" }, ctx) end)
  assert(out2:find("to is required", 1, true), "missing to-required message: " .. tostring(out2))
end)

case("move_file is registered with the right schema and requires confirmation", function()
  local e = registry.get("tool.move_file")
  assert(e, "tool.move_file not registered")
  assert(type(e.fn) == "function", "tool.move_file did not compile")
  local req = e.input_schema and e.input_schema.required
  assert(req and vim.tbl_contains(req, "from") and vim.tbl_contains(req, "to"),
    "input_schema should require from and to")
  -- Unlike the read-only editor tools, move_file writes to disk: it must NOT
  -- be in hook.confirm's auto-allow set (headless vim.fn.confirm denies).
  local allowed = registry.call("hook.confirm", "move_file", { from = "a", to = "b" }, { bufnr = 0 })
  assert(allowed ~= true, "move_file should not be auto-allowed, got: " .. tostring(allowed))
end)

-- ---------------------------------------------------------------- move_files

case("move_files: plain batch (no LSP client) moves every file", function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local a, b = dir .. "/a.txt", dir .. "/b.txt"
  write_file(a, "A\n")
  write_file(b, "B\n")

  local out = drive(function(ctx)
    return registry.call("tool.move_files", { moves = {
      { from = a, to = dir .. "/moved/a.txt" },
      { from = b, to = dir .. "/moved/b.txt" },
    } }, ctx)
  end)

  assert(out:find("moved 2 files", 1, true), "unexpected result: " .. tostring(out))
  assert(vim.fn.filereadable(a) == 0, "a should be gone from its source")
  assert(vim.fn.filereadable(b) == 0, "b should be gone from its source")
  assert(vim.fn.filereadable(dir .. "/moved/a.txt") == 1, "a should exist at destination")
  assert(vim.fn.filereadable(dir .. "/moved/b.txt") == 1, "b should exist at destination")
end)

case("move_files: one invalid entry refuses the WHOLE batch (no partial move)", function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local c = dir .. "/c.txt"
  write_file(c, "C\n")

  local out = drive(function(ctx)
    return registry.call("tool.move_files", { moves = {
      { from = c, to = dir .. "/moved/c.txt" },
      { from = dir .. "/nope.txt", to = dir .. "/moved/nope.txt" },
    } }, ctx)
  end)

  assert(out:find("refusing the whole batch", 1, true), "unexpected result: " .. tostring(out))
  assert(out:find("no such file", 1, true), "should name the missing source: " .. tostring(out))
  assert(vim.fn.filereadable(c) == 1, "the VALID entry must not have moved either")
end)

case("move_files: two entries targeting the same destination are refused", function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  write_file(dir .. "/d1.txt", "D1\n")
  write_file(dir .. "/d2.txt", "D2\n")

  local out = drive(function(ctx)
    return registry.call("tool.move_files", { moves = {
      { from = dir .. "/d1.txt", to = dir .. "/same.txt" },
      { from = dir .. "/d2.txt", to = dir .. "/same.txt" },
    } }, ctx)
  end)

  assert(out:find("two entries target", 1, true), "unexpected result: " .. tostring(out))
  assert(vim.fn.filereadable(dir .. "/d1.txt") == 1, "d1 should be untouched")
  assert(vim.fn.filereadable(dir .. "/d2.txt") == 1, "d2 should be untouched")
end)

case("move_files: from == to in one entry is refused", function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local p = dir .. "/same.txt"
  write_file(p, "x\n")
  local out = drive(function(ctx)
    return registry.call("tool.move_files", { moves = { { from = p, to = p } } }, ctx)
  end)
  assert(out:find("same path", 1, true), "unexpected result: " .. tostring(out))
end)

case("move_files requires a non-empty moves array", function()
  local out1 = drive(function(ctx) return registry.call("tool.move_files", {}, ctx) end)
  assert(out1:find("non-empty array", 1, true), "missing message: " .. tostring(out1))
  local out2 = drive(function(ctx) return registry.call("tool.move_files", { moves = {} }, ctx) end)
  assert(out2:find("non-empty array", 1, true), "missing message: " .. tostring(out2))
end)

case("move_files is registered with the right schema and requires confirmation", function()
  local e = registry.get("tool.move_files")
  assert(e, "tool.move_files not registered")
  assert(type(e.fn) == "function", "tool.move_files did not compile")
  local req = e.input_schema and e.input_schema.required
  assert(req and vim.tbl_contains(req, "moves"), "input_schema should require moves")
  local allowed = registry.call("hook.confirm", "move_files", { moves = {} }, { bufnr = 0 })
  assert(allowed ~= true, "move_files should not be auto-allowed, got: " .. tostring(allowed))
end)

-- --------------------------------------------------------------- delete_file

case("delete_file: plain delete (no LSP client) removes the file", function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local p = dir .. "/a.txt"
  write_file(p, "A\n")

  local out = drive(function(ctx)
    return registry.call("tool.delete_file", { path = p }, ctx)
  end)

  assert(out:find("deleted", 1, true), "unexpected result: " .. tostring(out))
  assert(out:find("not undo-tree reversible", 1, true), "should warn it's not undoable: " .. tostring(out))
  assert(vim.fn.filereadable(p) == 0, "file should be gone")
end)

case("delete_file: missing file errors with a clear message", function()
  local out = drive(function(ctx)
    return registry.call("tool.delete_file", { path = "/no/such/file.txt" }, ctx)
  end)
  assert(out:find("no such file", 1, true), "unexpected message: " .. tostring(out))
end)

case("delete_file: refuses when the buffer has unsaved changes", function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local p = dir .. "/b.txt"
  write_file(p, "B\n")
  local buf = vim.fn.bufadd(p)
  vim.fn.bufload(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "MODIFIED" })

  local out = drive(function(ctx)
    return registry.call("tool.delete_file", { path = p }, ctx)
  end)

  assert(out:find("unsaved buffer changes", 1, true), "unexpected message: " .. tostring(out))
  assert(vim.fn.filereadable(p) == 1, "file should be untouched")
end)

case("delete_file requires path", function()
  local out = drive(function(ctx) return registry.call("tool.delete_file", {}, ctx) end)
  assert(out:find("path is required", 1, true), "missing path-required message: " .. tostring(out))
end)

case("delete_file is registered with the right schema and requires confirmation", function()
  local e = registry.get("tool.delete_file")
  assert(e, "tool.delete_file not registered")
  assert(type(e.fn) == "function", "tool.delete_file did not compile")
  local req = e.input_schema and e.input_schema.required
  assert(req and vim.tbl_contains(req, "path"), "input_schema should require path")
  local allowed = registry.call("hook.confirm", "delete_file", { path = "a" }, { bufnr = 0 })
  assert(allowed ~= true, "delete_file should not be auto-allowed, got: " .. tostring(allowed))
end)

-- -------------------------------------------------------------- delete_files

case("delete_files: plain batch (no LSP client) deletes every file", function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local a, b = dir .. "/a.txt", dir .. "/b.txt"
  write_file(a, "A\n")
  write_file(b, "B\n")

  local out = drive(function(ctx)
    return registry.call("tool.delete_files", { paths = { a, b } }, ctx)
  end)

  assert(out:find("deleted 2 files", 1, true), "unexpected result: " .. tostring(out))
  assert(vim.fn.filereadable(a) == 0, "a should be gone")
  assert(vim.fn.filereadable(b) == 0, "b should be gone")
end)

case("delete_files: one invalid entry refuses the WHOLE batch (no partial delete)", function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local c = dir .. "/c.txt"
  write_file(c, "C\n")

  local out = drive(function(ctx)
    return registry.call("tool.delete_files", { paths = { c, dir .. "/nope.txt" } }, ctx)
  end)

  assert(out:find("refusing the whole batch", 1, true), "unexpected result: " .. tostring(out))
  assert(vim.fn.filereadable(c) == 1, "the VALID entry must not have been deleted either")
end)

case("delete_files: a duplicate path in the batch is refused", function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local p = dir .. "/d.txt"
  write_file(p, "D\n")
  local out = drive(function(ctx)
    return registry.call("tool.delete_files", { paths = { p, p } }, ctx)
  end)
  assert(out:find("listed twice", 1, true), "unexpected result: " .. tostring(out))
  assert(vim.fn.filereadable(p) == 1, "file should be untouched")
end)

case("delete_files: an unsaved buffer among many entries refuses the whole batch", function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local a, b = dir .. "/a.txt", dir .. "/b.txt"
  write_file(a, "A\n")
  write_file(b, "B\n")
  local buf = vim.fn.bufadd(b)
  vim.fn.bufload(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "MODIFIED" })

  local out = drive(function(ctx)
    return registry.call("tool.delete_files", { paths = { a, b } }, ctx)
  end)

  assert(out:find("unsaved buffer changes", 1, true), "unexpected result: " .. tostring(out))
  assert(vim.fn.filereadable(a) == 1, "a must not be deleted either — whole batch refused")
  assert(vim.fn.filereadable(b) == 1, "b should be untouched")
end)

case("delete_files requires a non-empty paths array", function()
  local out1 = drive(function(ctx) return registry.call("tool.delete_files", {}, ctx) end)
  assert(out1:find("non-empty array", 1, true), "missing message: " .. tostring(out1))
  local out2 = drive(function(ctx) return registry.call("tool.delete_files", { paths = {} }, ctx) end)
  assert(out2:find("non-empty array", 1, true), "missing message: " .. tostring(out2))
end)

case("delete_files is registered with the right schema and requires confirmation", function()
  local e = registry.get("tool.delete_files")
  assert(e, "tool.delete_files not registered")
  assert(type(e.fn) == "function", "tool.delete_files did not compile")
  local req = e.input_schema and e.input_schema.required
  assert(req and vim.tbl_contains(req, "paths"), "input_schema should require paths")
  local allowed = registry.call("hook.confirm", "delete_files", { paths = {} }, { bufnr = 0 })
  assert(allowed ~= true, "delete_files should not be auto-allowed, got: " .. tostring(allowed))
end)

-- ----------------------------------------------------- hook.confirm auto-allow

case("core editor tools are auto-allowed by hook.confirm", function()
  for _, n in ipairs({ "diagnostics", "definition", "references", "symbols", "read_symbol" }) do
    local allowed = registry.call("hook.confirm", n, {}, { bufnr = 0 })
    assert(allowed == true, n .. " should be auto-allowed (no prompt), got: " .. tostring(allowed))
  end
end)

print(failed and "FAILED" or "ALL PASS")
os.exit(failed and 1 or 0)
