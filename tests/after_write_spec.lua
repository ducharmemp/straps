local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(vim.fn.fnamemodify(here, ":p"), ":h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local straps = require("straps").setup({})
straps.config.session_dir = vim.fn.tempname()
straps.config.after_write_diagnostics_ms = 80
local registry = require("straps.registry")
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local ns = vim.api.nvim_create_namespace("straps_test_aw")
local serial = 0

local function make_buf(lines)
  serial = serial + 1
  local path = tmp .. "/file" .. serial .. ".lua"
  local f = assert(io.open(path, "w"))
  f:write(table.concat(lines or { "x" }, "\n") .. "\n")
  f:close()
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  return buf, path
end

local function snapshot(buf, path)
  return { bufnr = buf, path = path or vim.api.nvim_buf_get_name(buf),
    tick = vim.api.nvim_buf_get_changedtick(buf), uri = vim.uri_from_bufnr(buf) }
end

local function context()
  local ctx = { waits = 0, cancellations = {} }
  ctx.on_cancel = function(fn) ctx.cancellations[#ctx.cancellations + 1] = fn end
  ctx.cancel = function() for _, fn in ipairs(ctx.cancellations) do fn() end end
  ctx.await = function(subscribe)
    ctx.waits = ctx.waits + 1
    local done, value = false, nil
    subscribe(function(v) done, value = true, v end)
    assert(vim.wait(2000, function() return done end, 1), "diagnostics await did not resolve")
    return value
  end
  return ctx
end

local function diagnostic(message, severity, line, character)
  return { message = message, severity = severity or 1,
    range = { start = { line = line or 0, character = character or 0 },
      ["end"] = { line = line or 0, character = (character or 0) + 1 } } }
end

local function client(reply)
  local c = { id = 123, name = "fake", offset_encoding = "utf-16", requests = {}, cancelled = {},
    server_capabilities = { diagnosticProvider = {} } }
  function c:supports_method(method, buf)
    assert.equals("textDocument/diagnostic", method)
    assert.is_number(buf)
    return self.server_capabilities.diagnosticProvider ~= nil
  end
  function c:request(method, params, handler, buf)
    assert.equals(c, self)
    assert.equals("textDocument/diagnostic", method)
    assert.equals(vim.uri_from_bufnr(buf), params.textDocument.uri)
    local id = #self.requests + 1
    self.requests[id] = { params = params, handler = handler, bufnr = buf }
    if reply then reply(self, handler, buf, params) end
    return true, id
  end
  function c:cancel_request(id) self.cancelled[#self.cancelled + 1] = id end
  return c
end

local function with_clients(clients, fn)
  local real_get, real_set = vim.lsp.get_clients, vim.diagnostic.set
  local writes = 0
  vim.lsp.get_clients = function() return clients end
  vim.diagnostic.set = function(...) writes = writes + 1; return real_set(...) end
  local ok, err = pcall(fn)
  vim.lsp.get_clients, vim.diagnostic.set = real_get, real_set
  if not ok then error(err, 0) end
  assert.equals(0, writes, "pull results changed the diagnostic cache")
end

local function full(items)
  return client(function(_, handler) vim.schedule(function() handler(nil, { kind = "full", items = items }) end) end)
end

it("skips requests and awaits without pull support or an async context", function()
  local buf, path = make_buf()
  vim.diagnostic.set(ns, buf, { { lnum = 0, col = 0, severity = 1, message = "cached error" } })
  for _, clients in ipairs({ {}, { { id = 1, name = "push", supports_method = function() return false end } } }) do
    with_clients(clients, function()
      local ctx = context()
      assert.same({}, registry.call("fn.write_diagnostics", { snapshot(buf, path) }, ctx))
      assert.equals(0, ctx.waits)
    end)
  end
  local c = full({ diagnostic("fresh") })
  with_clients({ c }, function()
    assert.same({}, registry.call("fn.write_diagnostics", { snapshot(buf, path) }, {}))
    assert.equals(0, #c.requests)
    assert.is_nil(registry.call("hook.after_write", path, { bufnr = buf }))
    assert.equals(0, #c.requests)
  end)
end)

it("formats pull errors and warnings with UTF-16 positions and leaves cached diagnostics unchanged", function()
  local buf, path = make_buf({ "😀x", "second" })
  vim.diagnostic.set(ns, buf, { { lnum = 0, col = 0, severity = 1, message = "cached error" } })
  local warning = diagnostic("careful", 2, 0, 2)
  warning.source = "lint"
  local c = full({ diagnostic("later", 1, 1), diagnostic("hint", 4), warning, diagnostic("info", 3) })
  with_clients({ c }, function()
    local ctx = context()
    local out = registry.call("fn.write_diagnostics", { snapshot(buf, path) }, ctx)[buf]
    assert.equals(1, ctx.waits)
    assert.equals(1, #c.requests)
    assert.truthy(out:find("diagnostics after write (2):", 1, true))
    assert.truthy(out:find(":1:5: WARN careful [lint]", 1, true))
    assert.truthy(out:find(":2:1: ERROR later", 1, true))
    assert.is_true(out:find("careful", 1, true) < out:find("later", 1, true))
    assert.is_nil(out:find("cached error", 1, true))
    assert.is_nil(out:find("hint", 1, true))
    assert.is_nil(out:find("info", 1, true))
    assert.equals("cached error", vim.diagnostic.get(buf, { namespace = ns })[1].message)
  end)
end)

it("returns no summary for a clean report or reports below the warning threshold", function()
  for _, items in ipairs({ {}, { diagnostic("tidy", 4), diagnostic("fyi", 3) } }) do
    local buf, path = make_buf()
    local c = full(items)
    with_clients({ c }, function()
      local ctx = context()
      assert.same({}, registry.call("fn.write_diagnostics", { snapshot(buf, path) }, ctx))
      assert.equals(1, ctx.waits)
      assert.equals(1, #c.requests)
    end)
  end
end)

it("discards responses after the saved changedtick or URI changes", function()
  for _, change in ipairs({ "tick", "uri" }) do
    local buf, path = make_buf()
    local c = client(function(_, handler)
      vim.schedule(function()
        if change == "tick" then vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "changed" })
        else vim.api.nvim_buf_set_name(buf, path .. ".renamed") end
        handler(nil, { kind = "full", items = { diagnostic("stale") } })
      end)
    end)
    with_clients({ c }, function()
      local ctx = context()
      assert.same({}, registry.call("fn.write_diagnostics", { snapshot(buf, path) }, ctx))
      assert.equals(1, #c.requests)
    end)
  end
end)

it("retains completed reports at the cap and cancels outstanding requests without accepting late callbacks", function()
  local buf, path = make_buf()
  local ready, pending = full({ diagnostic("retained") }), client()
  with_clients({ ready, pending }, function()
    local ctx = context()
    local out = registry.call("fn.write_diagnostics", { snapshot(buf, path) }, ctx)
    assert.equals(1, ctx.waits)
    assert.truthy(out[buf]:find("retained", 1, true))
    assert.same({}, ready.cancelled)
    assert.same({ 1 }, pending.cancelled)
    local before = vim.deepcopy(out)
    pending.requests[1].handler(nil, { kind = "full", items = { diagnostic("late") } })
    assert.same(before, out)
  end)
end)

it("cancels outstanding pulls when the context stops and ignores their callbacks", function()
  local buf, path = make_buf()
  local ctx = context()
  local c = client(function() vim.schedule(ctx.cancel) end)
  with_clients({ c }, function()
    local out = registry.call("fn.write_diagnostics", { snapshot(buf, path) }, ctx)
    assert.equals(1, ctx.waits)
    assert.same({ 1 }, c.cancelled)
    assert.same({}, out)
    c.requests[1].handler(nil, { kind = "full", items = { diagnostic("after stop") } })
    assert.same({}, out)
  end)
end)

it("ignores unchanged reports and request errors", function()
  local buf, path = make_buf()
  local unchanged = client(function(_, handler) vim.schedule(function() handler(nil, { kind = "unchanged", resultId = "old" }) end) end)
  local failed = client(function(_, handler) vim.schedule(function() handler({ code = -1, message = "failed" }) end) end)
  with_clients({ unchanged, failed }, function()
    local ctx = context()
    assert.same({}, registry.call("fn.write_diagnostics", { snapshot(buf, path) }, ctx))
    assert.equals(1, ctx.waits)
    assert.same({}, unchanged.cancelled)
    assert.same({}, failed.cancelled)
  end)
end)

it("write_file appends the pulled summary and a disabled hook makes no requests", function()
  local buf, path = make_buf({ "old" })
  local c = full({ diagnostic("still broken") })
  with_clients({ c }, function()
    local ctx = context()
    ctx.bufnr = buf
    local result = registry.call("tool.write_file", { path = path, content = "new content\n" }, ctx)
    assert.truthy(result:find("wrote ", 1, true))
    assert.truthy(result:find("still broken", 1, true))
    assert.equals(1, ctx.waits)
    straps.config.after_write_diagnostics = false
    local ok, out = pcall(registry.call, "hook.after_write", path, ctx)
    straps.config.after_write_diagnostics = true
    assert.is_true(ok)
    assert.is_nil(out)
    assert.equals(1, #c.requests)
  end)
end)

it("passes static and dynamic diagnostic identifiers using both registration APIs", function()
  for _, version in ipairs({ "static", "0.12", "0.11" }) do
    local buf, path = make_buf()
    local c = full({})
    c.server_capabilities.diagnosticProvider.identifier = "static-id"
    if version == "0.12" then
      function c:_registration_provider(method)
        assert.equals(c, self)
        assert.equals("textDocument/diagnostic", method)
        return "diagnosticProvider"
      end
      function c:_get_registrations(provider, target)
        assert.equals("diagnosticProvider", provider)
        assert.equals(buf, target)
        return { { registerOptions = { identifier = "dynamic-id" } } }
      end
    elseif version == "0.11" then
      function c:_get_registration_options(method, target)
        assert.equals(c, self)
        assert.equals("textDocument/diagnostic", method)
        assert.equals(buf, target)
        return { identifier = "dynamic-id" }
      end
    end
    with_clients({ c }, function()
      registry.call("fn.write_diagnostics", { snapshot(buf, path) }, context())
      assert.equals(1, #c.requests)
      assert.equals(version == "static" and "static-id" or "dynamic-id", c.requests[1].params.identifier)
    end)
  end
end)

it("does not use a similarly named buffer or an invalid buffer", function()
  local buf, path = make_buf()
  local c = full({ diagnostic("decoy") })
  with_clients({ c }, function()
    assert.is_nil(registry.call("hook.after_write", path .. ".missing", context()))
    assert.is_nil(registry.call("hook.after_write", "/nonexistent/nope.lua", { bufnr = 0 }))
    assert.equals(0, #c.requests)
    assert.is_true(vim.api.nvim_buf_is_valid(buf))
  end)
end)
