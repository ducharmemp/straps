-- tests/run_after_write.lua — the default hook.after_write feeds LSP
-- diagnostics back into a write's result.
--   nvim --headless -l tests/run_after_write.lua
-- No network, no real language server. We stub vim.lsp.get_clients (so the
-- hook believes a server is attached) and seed diagnostics with
-- vim.diagnostic.set, then drive the hook directly and through write_file.

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
straps.config.session_dir = vim.fn.tempname()
-- Keep the wait short so the suite stays fast.
straps.config.after_write_diagnostics_ms = 150
local registry = require("straps.registry")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")

-- Stub the LSP client probe so the hook proceeds; restore between cases.
local real_get_clients = vim.lsp.get_clients
local function with_fake_client(fn)
  vim.lsp.get_clients = function() return { { name = "fake" } } end
  local ok, err = pcall(fn)
  vim.lsp.get_clients = real_get_clients
  if not ok then error(err) end
end

-- A minimal ctx: no coroutine, so the hook takes the vim.wait fallback path.
local function ctx_for(buf)
  return { bufnr = buf }
end

local ns = vim.api.nvim_create_namespace("straps_test_aw")

local function make_buf(path, lines)
  local f = assert(io.open(path, "w"))
  f:write(table.concat(lines, "\n") .. "\n")
  f:close()
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  return buf
end

case("no LSP client -> nil (nothing appended)", function()
  local path = tmp .. "/a.lua"
  local buf = make_buf(path, { "local x = 1" })
  vim.diagnostic.set(ns, buf, {
    { lnum = 0, col = 0, severity = vim.diagnostic.severity.ERROR, message = "boom", source = "s" },
  })
  -- real_get_clients returns {} for this buffer (no server attached)
  local out = registry.call("hook.after_write", path, ctx_for(buf))
  assert(out == nil, "expected nil with no client, got: " .. tostring(out))
end)

case("client + ERROR/WARN diagnostics -> formatted summary", function()
  local path = tmp .. "/b.lua"
  local buf = make_buf(path, { "local x = 1", "local y = 2" })
  vim.diagnostic.set(ns, buf, {
    { lnum = 0, col = 0, severity = vim.diagnostic.severity.ERROR, message = "boom", source = "tlint" },
    { lnum = 1, col = 2, severity = vim.diagnostic.severity.WARN, message = "careful" },
  })
  local out
  with_fake_client(function()
    out = registry.call("hook.after_write", path, ctx_for(buf))
  end)
  assert(type(out) == "string", "expected a string summary, got: " .. tostring(out))
  assert(out:find("diagnostics after write (2):", 1, true), "missing header: " .. out)
  assert(out:find("b.lua:1:1: ERROR boom [tlint]", 1, true), "missing error line: " .. out)
  assert(out:find("b.lua:2:3: WARN careful", 1, true), "missing warn line: " .. out)
  -- Sorted by line: ERROR (line 1) before WARN (line 2).
  assert(out:find("ERROR", 1, true) < out:find("WARN", 1, true), "not sorted by position")
end)

case("HINT/INFO only -> nil (below WARN threshold)", function()
  local path = tmp .. "/c.lua"
  local buf = make_buf(path, { "x" })
  vim.diagnostic.set(ns, buf, {
    { lnum = 0, col = 0, severity = vim.diagnostic.severity.HINT, message = "tidy" },
    { lnum = 0, col = 0, severity = vim.diagnostic.severity.INFO, message = "fyi" },
  })
  local out
  with_fake_client(function()
    out = registry.call("hook.after_write", path, ctx_for(buf))
  end)
  assert(out == nil, "HINT/INFO should not be reported, got: " .. tostring(out))
end)

case("clean file with a client -> nil", function()
  local path = tmp .. "/d.lua"
  local buf = make_buf(path, { "ok" })
  vim.diagnostic.set(ns, buf, {})
  local out
  with_fake_client(function()
    out = registry.call("hook.after_write", path, ctx_for(buf))
  end)
  assert(out == nil, "clean file should return nil, got: " .. tostring(out))
end)

case("config.after_write_diagnostics = false -> nil even with diagnostics", function()
  local path = tmp .. "/e.lua"
  local buf = make_buf(path, { "x" })
  vim.diagnostic.set(ns, buf, {
    { lnum = 0, col = 0, severity = vim.diagnostic.severity.ERROR, message = "boom" },
  })
  straps.config.after_write_diagnostics = false
  local out
  with_fake_client(function()
    out = registry.call("hook.after_write", path, ctx_for(buf))
  end)
  straps.config.after_write_diagnostics = true
  assert(out == nil, "disabled hook should return nil, got: " .. tostring(out))
end)

case("write_file appends the diagnostics summary to its result", function()
  local path = tmp .. "/f.lua"
  -- Pre-create + load the buffer so the fake client + seeded diagnostics apply
  -- to the same buffer write_file will write through.
  local buf = make_buf(path, { "old" })
  vim.diagnostic.set(ns, buf, {
    { lnum = 0, col = 0, severity = vim.diagnostic.severity.ERROR, message = "still broken", source = "x" },
  })
  local result
  with_fake_client(function()
    result = registry.call("tool.write_file",
      { path = path, content = "new content\n" }, ctx_for(buf))
  end)
  assert(type(result) == "string", "expected a result string")
  assert(result:find("wrote ", 1, true), "missing write confirmation: " .. result)
  assert(result:find("diagnostics after write", 1, true),
    "write_file did not append diagnostics: " .. result)
  assert(result:find("still broken", 1, true), "missing the diagnostic message: " .. result)
end)

case("hook never throws on an invalid buffer", function()
  local out = registry.call("hook.after_write", "/nonexistent/nope.lua", { bufnr = 0 })
  assert(out == nil, "expected nil for a path with no buffer, got: " .. tostring(out))
end)

if failed then
  os.exit(1)
end
print("ALL PASS")
