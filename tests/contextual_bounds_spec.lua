local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(here, ":p:h:h")
vim.opt.runtimepath:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local registry, state, loop, controller, raw_input, raw_formats, bodies, original_encode, session_dir
local marker = "bounds-raw-input-must-not-be-rendered"
local function define(name, kind, source) registry.define({ name = name, kind = kind, source = source }) end

before_each(function()
  for _, name in ipairs({ "loop", "registry", "state", "contextual", "authorization", "consent" }) do package.loaded["straps." .. name] = nil end
  registry, state = require("straps.registry"), require("straps.state")
  local mutant = vim.env.STRAPS_BOUNDS_MUTANT
  if mutant and mutant ~= "" then
    local source = table.concat(vim.fn.readfile(root .. "/lua/straps/loop.lua"), "\n")
    local changes = {
      preflight = { "local bounded, reason = preflight_tool_input(block.input or {})", "local bounded, reason = true, nil" },
      refusal = { "if rejected_tool_inputs[block] then return false, rejected_tool_inputs[block] end", "if rejected_tool_inputs[block] then return registry.gate_tool(block.name, block.input or {}, ctx, { confirm = confirm_then_before_tool }) end" },
      retention = { "block = { type = \"tool_use\", id = block.id, name = block.name, input = {} }", "block = { type = \"tool_use\", id = block.id, name = block.name, input = block.input }" },
    }
    local change = assert(changes[mutant], "unknown bounds mutation")
    local first, last = assert(source:find(change[1], 1, true))
    source = source:sub(1, first - 1) .. change[2] .. source:sub(last + 1)
    package.loaded["straps.loop"] = assert(loadstring(source, "@" .. root .. "/lua/straps/loop.lua"))()
  end
  loop = require("straps.loop")
  session_dir = vim.fn.tempname()
  require("straps").config.session_dir = session_dir
  raw_formats, bodies = 0, 0
  controller = registry.setup_authorization({
    input_limits = { max_bytes = 1024, max_depth = 8, max_items = 64 },
    assess = function() return { decision = "allow" } end,
    execution_stamp = function() return { revision = 1 } end,
    validate_stamp = function() return true end,
  })
  loop.install_contextual({
    begin = controller.begin_family, bind = controller.bind_context, finish = controller.cancel_family,
    stop = function() end, close = function() end,
  })
  define("hook.confirm", "hook", "return function() return true end")
  define("fn.build_tools", "fn", "return function() return {} end")
  _G.contextual_bounds_body = function() bodies = bodies + 1; return "unexpected body" end
  define("tool.sample", "tool", "return function() return _G.contextual_bounds_body() end")
  original_encode = vim.json.encode
  vim.json.encode = function(value, ...)
    if type(value) == "string" and value:find(marker, 1, true) then raw_formats = raw_formats + 1 end
    return original_encode(value, ...)
  end
end)

after_each(function()
  vim.json.encode = original_encode
  _G.contextual_bounds_body, _G.contextual_bounds_provider = nil, nil
  vim.fn.delete(session_dir, "rf")
end)

local function exercise(input, accepted, parallel)
  raw_input = input
  local name, count = parallel and "read_file" or "sample", parallel and 2 or 1
  define("tool." .. name, "tool", "return function() return _G.contextual_bounds_body() end")
  local calls = 0
  _G.contextual_bounds_provider = function(_, ctx)
    calls = calls + 1
    if calls == 1 then
      local content = {}
      for index = 1, count do
        content[index] = { type = "tool_use", name = name, id = "oversized-input-" .. index, input = raw_input }
      end
      return { stop_reason = "tool_use", content = content }
    end
    ctx.emit({ type = "text_delta", text = "done" })
    return { stop_reason = "end_turn", content = { { type = "text", text = "done" } } }
  end
  define("fn.provider", "fn", "return function(...) return _G.contextual_bounds_provider(...) end")
  local buf = state.new_session()
  state.append_text(buf, "local task")
  controller.install_ceiling(buf, {})
  loop.start(buf)
  assert.is_true(vim.wait(3000, function() return not loop.running(buf) end, 5))
  local transcript = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  local observed = {
    bodies = bodies, raw_formats = raw_formats, raw_retained = transcript:find(marker, 1, true) ~= nil,
    clear_refusal = transcript:find("tool input", 1, true) ~= nil and transcript:find("overflow", 1, true) ~= nil,
    stack_error = transcript:find("stack overflow", 1, true) ~= nil,
  }
  local uses, results = {}, {}
  for _, message in ipairs(state.parse(buf).messages) do
    for _, part in ipairs(type(message.content) == "table" and message.content or {}) do
      if part.type == "tool_use" then uses[#uses + 1] = part end
      if part.type == "tool_result" then results[#results + 1] = part end
    end
  end
  vim.api.nvim_buf_delete(buf, { force = true })
  assert.equals(count, #uses)
  assert.equals(count, #results)
  for index = 1, count do
    assert.equals("oversized-input-" .. index, uses[index].id)
    assert.equals(name, uses[index].name)
    assert.equals(uses[index].id, results[index].tool_use_id)
    assert.same(accepted and input or {}, uses[index].input)
    assert.equals(not accepted, results[index].is_error == true)
  end
  if accepted then
    assert.equals(count, observed.bodies)
    assert.is_false(observed.clear_refusal)
    assert.same(input, uses[1].input)
  else
    assert.equals(0, observed.raw_formats)
    assert.is_false(observed.raw_retained)
    assert.equals(0, observed.bodies)
    assert.is_true(observed.clear_refusal)
    assert.is_false(observed.stack_error)
    assert.same({}, uses[1].input)
    assert.is_true(results[1].is_error)
  end
end

for _, parallel in ipairs({ false, true }) do
  describe(parallel and "parallel provider input" or "sequential provider input", function()
    it("refuses oversized provider tool input before rendering or transcript retention", function()
      exercise({ private = marker .. string.rep("x", 4096) }, false, parallel)
    end)

    it("refuses excessive provider tool items before formatting or transcript retention", function()
      local input = { private = marker }
      for index = 1, 100 do input[index] = true end
      exercise(input, false, parallel)
    end)

    it("refuses deep provider tool input before recursive formatting or transcript retention", function()
      local input = { private = marker }
      for _ = 1, 256 do input = { child = input } end
      exercise(input, false, parallel)
    end)

    it("preserves accepted provider input at the aggregate byte limit", function()
      exercise({ private = string.rep("x", 1009) }, true, parallel)
    end)

    it("preserves accepted provider input at the depth limit", function()
      local input = true
      for _ = 1, 7 do input = { child = input } end
      exercise(input, true, parallel)
    end)

    it("preserves accepted provider input at the table item boundary", function()
      local input = {}
      for index = 1, 31 do input[index] = true end
      exercise(input, true, parallel)
    end)
  end)
end

