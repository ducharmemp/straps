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
require("straps.editor").register() -- the five editor tools

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

case("all five tools registered as kind 'tool' with an input_schema", function()
  for _, n in ipairs({ "diagnostics", "definition", "references", "symbols", "read_symbol" }) do
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

-- ----------------------------------------------------- hook.confirm auto-allow

case("the five editor tools are auto-allowed by hook.confirm", function()
  for _, n in ipairs({ "diagnostics", "definition", "references", "symbols", "read_symbol" }) do
    local allowed = registry.call("hook.confirm", n, {}, { bufnr = 0 })
    assert(allowed == true, n .. " should be auto-allowed (no prompt), got: " .. tostring(allowed))
  end
end)

print(failed and "FAILED" or "ALL PASS")
os.exit(failed and 1 or 0)
