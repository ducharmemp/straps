local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(here, ":p:h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
require("straps").setup({ session_dir = vim.fn.tempname() })
local provider = require("straps.provider")
local mutation = vim.env.STRAPS_RETENTION_MUTANT
if mutation then
  local source = table.concat(vim.fn.readfile(root .. "/lua/straps/provider.lua"), "\n")
  local changes = {
    discard = { "adoptions[token] = nil\n    return existed", "return existed" },
    close = { "prompt_receipts[bufnr] = nil\n    for token", "for token" },
    superseded = { "for token, record in pairs(adoptions) do if record.bufnr == bufnr then adoptions[token] = nil end end\n    if not vim.api.nvim_buf_is_valid", "if not vim.api.nvim_buf_is_valid" },
  }
  local change = assert(changes[mutation])
  local first, last = assert(source:find(change[1], 1, true))
  package.loaded["straps.provider"] = assert(loadstring(source:sub(1, first - 1) .. change[2] .. source:sub(last + 1)))()
  provider = require("straps.provider")
end
local receipts
provider.install_prompt_receipts(function(value) receipts = value end)
local registry = require("straps.registry")
local state = require("straps.state")

it("discards rejected and superseded adoption tokens and closes prompt receipts", function()
  local session, construction = receipts.construct()
  assert.is_number(session, construction)
  registry.ensure_scope(session)
  assert.is_true(receipts.commit(construction, session))
  local _, rejected = receipts.prepare_adoption(session, nil, session)
  assert.is_true(receipts.discard_adoption(rejected))
  assert.is_false(receipts.discard_adoption(rejected))
  assert.is_false(receipts.adopt(rejected, function() return true end))
  local _, superseded = receipts.prepare_adoption(session, nil, session)
  local _, current = receipts.prepare_adoption(session, nil, session)
  assert.is_false(receipts.adopt(superseded, function() return true end))
  assert.is_true(receipts.discard_adoption(current))
  local _, closing = receipts.prepare_adoption(session, nil, session)
  receipts.close(session)
  assert.is_nil(receipts.identity(session))
  assert.is_false(receipts.adopt(closing, function() return true end))
  assert.is_false(receipts.validate(session, require("straps.instructions").discover()))
  assert.is_string(state.parse(session).system)
end)

it("discards construction tokens and retires pending tokens on close", function()
  local session, token = receipts.construct()
  registry.ensure_scope(session)
  assert.is_true(receipts.discard_construction(token))
  assert.is_false(receipts.commit(token, session))
  local closing, pending = receipts.construct()
  registry.ensure_scope(closing)
  receipts.close(closing)
  assert.is_false(receipts.commit(pending, closing))
end)
