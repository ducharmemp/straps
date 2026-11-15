local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(here, ":p:h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. package.path

local registry, assessed, bodies
before_each(function()
  package.loaded["straps.registry"] = nil
  package.loaded["straps.ceilings"] = nil
  local source = table.concat(vim.fn.readfile(root .. "/lua/straps/registry.lua"), "\n")
  local mutant = vim.env.STRAPS_INPUT_LIMIT_MUTANT
  if mutant and mutant ~= "" then
    local changes = {
      bytes_short = { "bytes > limits.max_bytes", "bytes >= limits.max_bytes" },
      bytes_long = { "bytes > limits.max_bytes", "bytes > limits.max_bytes + 1" },
      depth_short = { "depth > limits.max_depth", "depth >= limits.max_depth" },
      depth_long = { "depth > limits.max_depth", "depth > limits.max_depth + 1" },
      items_short = { "items > limits.max_items", "items >= limits.max_items" },
      items_long = { "items > limits.max_items", "items > limits.max_items + 2" },
      preflight = { "local bounded, reason = pcall(bounded_input, input, authorization.input_limits)", "local bounded, reason = true, nil" },
    }
    local change = assert(changes[mutant], "unknown input limit mutation")
    local first, last = assert(source:find(change[1], 1, true))
    source = source:sub(1, first - 1) .. change[2] .. source:sub(last + 1)
  end
  registry = assert(loadstring(source, "@" .. root .. "/lua/straps/registry.lua"))()
  registry.define({ name = "tool.sample", kind = "tool", source = "return function() _G.input_limit_body(); return true end" })
  assessed, bodies = 0, 0
  _G.input_limit_body = function() bodies = bodies + 1 end
end)
after_each(function() _G.input_limit_body = nil end)

for _, boundary in ipairs({
  { name = "encoded scalar bytes", limits = { max_bytes = 5, max_depth = 8, max_items = 100 }, at = "abc", over = "abcd", reason = "byte overflow" },
  { name = "aggregate table bytes", limits = { max_bytes = 18, max_depth = 8, max_items = 100 },
    at = { "abc", "abc" }, over = { "abc", "abcd" }, reason = "byte overflow" },
  { name = "nested value depth", limits = { max_bytes = 1000, max_depth = 3, max_items = 100 },
    at = { value = { value = true } }, over = { value = { value = { value = true } } }, reason = "structural overflow" },
  { name = "table key and value items", limits = { max_bytes = 1000, max_depth = 8, max_items = 5 },
    at = { true, true }, over = { true, { true } }, reason = "structural overflow" },
}) do
  it("accepts exact " .. boundary.name .. " limit and rejects the next input before assessment or execution", function()
    local controller = registry.setup_authorization({ input_limits = boundary.limits,
      execution_stamp = function(session) return { session = session } end,
      validate_stamp = function() return true end,
      assess = function() assessed = assessed + 1; return { decision = "allow" } end })
    controller.install_ceiling(1, {})
    local ctx = { bufnr = 1 }
    controller.begin_family(ctx)
    local accepted, preflight_reason = registry.preflight_tool_input(boundary.at)
    assert.is_true(accepted, preflight_reason)
    local refused, refusal = registry.preflight_tool_input(boundary.over)
    assert.is_false(refused)
    assert.matches(boundary.reason, refusal)
    assert.equals(0, assessed)
    assert.equals(0, bodies)
    local allowed, reason, run = registry.gate_tool("sample", boundary.at, ctx)
    assert.is_true(allowed, reason)
    assert.equals(1, assessed)
    assert.is_true(run(ctx))
    assert.equals(1, bodies)
    local denied, why, closure = registry.gate_tool("sample", boundary.over, ctx)
    assert.is_false(denied)
    assert.matches(boundary.reason, why)
    assert.is_nil(closure)
    assert.equals(1, assessed)
    assert.equals(1, bodies)
  end)
end
