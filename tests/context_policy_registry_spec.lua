local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(vim.fn.fnamemodify(here, ":p"), ":h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local registry = require("straps.registry")
local provider = require("straps.provider")
provider.register()
local default = registry.get("fn.context_plan")
local compact = registry.get("fn.compact")

local function input()
  return {
    version = 1, snapshot_id = "detached-snapshot", reason = "pressure", mode = "summary",
    before = { tokens = 900, limit = 1000, source = "estimate", exact = false }, target_tokens = 700,
    eligible = {
      { index = 1, first_block = 2, last_block = 5, mode = "summary", sources = { "archive-a" } },
      { index = 2, first_block = 8, last_block = 9, mode = "summary" },
    },
  }
end

it("registers an inspectable versioned default proposal", function()
  assert.same("fn", default.kind)
  assert.same({ version = 1, snapshot_id = "detached-snapshot", selections = { 1, 2 } },
    registry.call("fn.context_plan", input(), {}))
end)

it("preserves eligible order rather than sorting indices", function()
  local request = input()
  request.eligible[1].index, request.eligible[2].index = 2, 1
  assert.same({ 2, 1 }, registry.call("fn.context_plan", request, {}).selections)
end)

it("does not mutate or retain proposal data", function()
  local request = input()
  local original = vim.deepcopy(request)
  local proposal = registry.call("fn.context_plan", request, {})
  proposal.selections[1] = 99
  assert.same(original, request)
  assert.same({ 1, 2 }, registry.call("fn.context_plan", request, {}).selections)
end)

it("returns an empty proposal for no eligible intervals", function()
  local request = input()
  request.eligible = {}
  assert.same({}, registry.call("fn.context_plan", request, {}).selections)
end)

it("resolves a session override without replacing the global default", function()
  local bufnr = vim.api.nvim_create_buf(false, true)
  registry.ensure_scope(bufnr)
  registry.define({ name = "fn.context_plan", kind = "fn", source = [[
    return function(input, ctx)
      return { version = 1, snapshot_id = input.snapshot_id, selections = { 2 }, marker = ctx.marker }
    end
  ]] }, { scope = bufnr })
  registry.set_active_scope(bufnr)
  local proposal = registry.call("fn.context_plan", input(), { marker = "caller" })
  registry.set_active_scope(nil)
  vim.api.nvim_buf_delete(bufnr, { force = true })
  assert.same({ version = 1, snapshot_id = "detached-snapshot", selections = { 2 }, marker = "caller" }, proposal)
  assert.same(default.source, registry.get("fn.context_plan").source)
end)

it("retains an explicit global override across default registration", function()
  registry.define({ name = "fn.context_plan", kind = "fn", source = [[
    return function(input) return { version = 1, snapshot_id = input.snapshot_id, selections = {} } end
  ]] })
  provider.register()
  assert.same({}, registry.call("fn.context_plan", input(), {}).selections)
  registry.define(default)
end)

it("supports an explicit compact adapter only for an opted-in override", function()
  registry.define({ name = "fn.compact", kind = "fn", source = [[
    return function(bufnr, opts)
      if opts and opts.context_plan then
        local input = opts.context_plan
        return { version = 1, snapshot_id = input.snapshot_id, selections = { 2 } }
      end
      return "manual " .. tostring(bufnr)
    end
  ]] })
  registry.define({ name = "fn.context_plan", kind = "fn", source = [[
    return function(input, ctx)
      return require("straps.registry").call("fn.compact", nil, { context_plan = input })
    end
  ]] })
  local proposal = registry.call("fn.context_plan", input(), {})
  local manual = registry.call("fn.compact", 42)
  registry.define(default)
  registry.define(compact)
  assert.same({ version = 1, snapshot_id = "detached-snapshot", selections = { 2 } }, proposal)
  assert.same("manual 42", manual)
  assert.same(compact.source, registry.get("fn.compact").source)
end)
