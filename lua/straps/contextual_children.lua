local M = {}
local adapter, receipts

function M.install(value, options)
  assert(not adapter and require("straps.registry").trusted_setup_allowed(), "contextual children setup sealed")
  assert(type(value) == "table" and type(value.prepare) == "function" and type(value.attach) == "function"
    and type(value.rollback) == "function", "private child adapter required")
  assert(options and type(options.receipts) == "table" and type(options.receipts.construct) == "function",
    "private child prompt receipts required")
  adapter = { prepare = value.prepare, attach = value.attach, rollback = value.rollback, cancel = value.cancel }
  receipts = { construct = options.receipts.construct, construct_fork = options.receipts.construct_fork,
    close = options.receipts.close, discard_construction = options.receipts.discard_construction }
end

local function cleanup(child)
  pcall(adapter.rollback, child)
  if not vim.api.nvim_buf_is_valid(child) then return end
  local path, backed = vim.api.nvim_buf_get_name(child), vim.bo[child].buftype == ""
  vim.api.nvim_buf_delete(child, { force = true })
  if backed then
    for _, suffix in ipairs({ "", ".meta" }) do
      if vim.fn.filereadable(path .. suffix) == 1 then
        assert(vim.fn.delete(path .. suffix) == 0, "child rollback could not remove transcript")
      end
    end
  end
end

local function transaction(action, parent, options, body)
  if not adapter then return body(nil) end
  local registry = require("straps.registry")
  local normalized = vim.deepcopy(options)
  normalized.readonly = normalized.readonly and true or nil
  local plan = adapter.prepare(action, parent, normalized)
  local child, token, attached
  local tx = { start = action ~= "fork" }
  function tx.construct(prompt_options, fork_options)
    assert(not child, "child already allocated")
    if action == "fork" then
      if receipts.construct_fork then
        child = assert(receipts.construct_fork(vim.deepcopy(prompt_options), parent, vim.deepcopy(fork_options)))
      else child = require("straps.state").new_session(prompt_options) end
    else
      child, token = receipts.construct(vim.deepcopy(prompt_options), parent)
      assert(child and token, "trusted child prompt construction unavailable")
    end
    return child
  end
  function tx.attach(value)
    assert(value == child and not attached, "invalid child attachment")
    registry.ensure_scope(child, parent)
    if action == "fork" then
      assert(options.delegation == nil, "copied fork prompt requires explicit adoption before delegation")
      adapter.attach(plan, child, nil, nil)
    else adapter.attach(plan, child, vim.deepcopy(options.delegation), token) end
    attached = true
  end
  local ok, result = pcall(body, tx)
  if ok and not child and adapter.cancel then pcall(adapter.cancel, plan) end
  if ok and child and not attached then ok, result = false, "child was not attached before return" end
  if not ok then
    if adapter.cancel then pcall(adapter.cancel, plan) end
    if token and receipts.discard_construction then pcall(receipts.discard_construction, token) end
    if child then
      if receipts.close then pcall(receipts.close, child) end
      local cleaned, why = pcall(cleanup, child)
      if not cleaned then result = tostring(result) .. "; child rollback failed: " .. tostring(why) end
    end
    error(result, 0)
  end
  return result, tx.start == false and "adoption_required" or nil
end

function M.spawn(input, ctx, body)
  return transaction("spawn", ctx.bufnr, input, function(tx) return body(input, ctx, tx) end)
end

function M.fork(source, options, body)
  return transaction("fork", source, options, function(tx) return body(source, options, tx) end)
end

function M.delegation_schema()
  local properties = {}
  for _, key in ipairs({ "targets", "effects", "capabilities", "sources" }) do
    properties[key] = { type = "array", items = { type = "string" } }
  end
  return { type = "object", properties = properties, required = { "targets", "effects", "capabilities", "sources" },
    additionalProperties = false }
end

return M
