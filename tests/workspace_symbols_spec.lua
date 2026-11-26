-- tests/workspace_symbols_spec.lua — tool.workspace_symbols output against a fake LSP client, and editor.symbol_location.
-- Run from the repo root: busted tests/workspace_symbols_spec.lua </dev/null

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
          workspaceSymbolProvider = true,
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

local target = work .. "/multi.lua"
write(target, "local x = 1\nlocal é = 2; local target = 3\n")
local other = work .. "/uri_only.lua"
write(other, "return {}\n")
write(work .. "/query.lua", "return 1\n")
local query_buf = vim.fn.bufadd(work .. "/query.lua")
vim.fn.bufload(query_buf)
vim.bo[query_buf].filetype = "lua"
attach(query_buf, "utf-16")
server.handlers["workspace/symbol"] = function()
  return {
    { name = "target", kind = 13, location = { uri = vim.uri_from_fname(target),
      range = { start = { line = 1, character = 20 }, ["end"] = { line = 1, character = 26 } } } },
    { name = "module", kind = 2, location = { uri = vim.uri_from_fname(other) } },
  }
end

it("tool.workspace_symbols reports a byte column on a multibyte line and a path for a uri-only symbol", function()
  local out, raised = call("workspace_symbols", { query = "t", path = work .. "/query.lua" })
  assert.is_nil(raised)
  assert.are.equal(table.concat({
    "target  Variable  multi.lua:2:22",
    "module  Module  uri_only.lua",
  }, "\n"), out)
end)

it("tool.workspace_symbols with quickfix counts only ranged symbols as locations", function()
  local out, raised = call("workspace_symbols", { query = "t", path = work .. "/query.lua", quickfix = true, open = false })
  assert.is_nil(raised)
  assert(out:find(": 1 location(s)", 1, true), out)
end)

describe("editor.symbol_location", function()
  local editor = require("straps.editor")
  local ranged = { location = { uri = vim.uri_from_fname(target),
    range = { start = { line = 1, character = 20 }, ["end"] = { line = 1, character = 26 } } } }

  it("converts with the given encoding when the file is loaded", function()
    assert.same({ "multi.lua:2:22", true }, { editor.symbol_location(ranged, "utf-16", { load = true }) })
    assert.same({ "multi.lua:2:21", true }, { editor.symbol_location(ranged, "utf-8", { load = true }) })
  end)

  it("returns the path for a uri-only symbol and nil for a symbol without a location", function()
    assert.same({ "uri_only.lua", false }, { editor.symbol_location({ location = { uri = vim.uri_from_fname(other) } }, "utf-16") })
    assert.is_nil(editor.symbol_location({ name = "x" }, "utf-16"))
  end)

  it("with load = false returns path:line for an unloaded file and loads no buffer", function()
    local unloaded = work .. "/unloaded.lua"
    write(unloaded, "a\nb\n")
    local function loaded_count()
      local n = 0
      for _, b in ipairs(vim.api.nvim_list_bufs()) do if vim.api.nvim_buf_is_loaded(b) then n = n + 1 end end
      return n
    end
    local before, listed = loaded_count(), #vim.api.nvim_list_bufs()
    local symbol = { location = { uri = vim.uri_from_fname(unloaded), range = { start = { line = 1, character = 0 } } } }
    assert.same({ "unloaded.lua:2", true }, { editor.symbol_location(symbol, "utf-16", { load = false }) })
    assert.are.equal(before, loaded_count())
    assert.are.equal(listed, #vim.api.nvim_list_bufs())
    vim.fn.bufload(vim.fn.bufadd(target))
    assert.same({ "multi.lua:2:22", true }, { editor.symbol_location(ranged, "utf-16", { load = false }) })
  end)

  it("symbol_location returns nil for a uri without a scheme", function()
    local symbol = { location = { uri = "relative.lua", range = { start = { line = 0, character = 0 } } } }
    assert.is_nil(require("straps.editor").symbol_location(symbol, "utf-16", { load = false }))
  end)

  it("symbol_location gives the file alone for a range whose start has no line", function()
    local symbol = { location = { uri = vim.uri_from_fname(work .. "/a.lua"), range = { start = {} } } }
    assert.same({ "a.lua", false }, { require("straps.editor").symbol_location(symbol, "utf-16", { load = false }) })
  end)

  it("symbol_location gives column 1 for a loaded file when the range start has no character", function()
    vim.fn.bufload(vim.fn.bufadd(target))
    local symbol = { location = { uri = vim.uri_from_fname(target), range = { start = { line = 1 } } } }
    assert.same({ "multi.lua:2:1", true }, { editor.symbol_location(symbol, "utf-16", { load = false }) })
  end)
end)
