local script = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(vim.fn.fnamemodify(script, ":p"), ":h:h")
vim.opt.runtimepath:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local straps = require("straps").setup({})
straps.config.session_dir = vim.fn.tempname()
local registry = require("straps.registry")
local state = require("straps.state")
local loop = require("straps.loop")

local function drive(bufnr, thunk)
  local finished, result, failure, co
  co = coroutine.create(function()
    local ok, value = pcall(thunk, {
      bufnr = bufnr,
      await = function(start)
        start(function(...)
          local args = { ... }
          vim.schedule(function() coroutine.resume(co, unpack(args)) end)
        end)
        return coroutine.yield()
      end,
    })
    if ok then result = value else failure = value end
    finished = true
  end)
  local ok, err = coroutine.resume(co)
  if not ok then error(err) end
  if not vim.wait(10000, function() return finished end, 10) then error("drive timed out") end
  if failure then error(failure) end
  return result
end

it("the default hook prompts for top-level watch and unwatch without grants", function()
  local parent = state.new_session()
  local original = vim.fn.confirm
  local prompts = 0
  vim.fn.confirm = function() prompts = prompts + 1; return 2 end
  local ok, err = pcall(function()
    for _, name in ipairs({ "watch_agent", "unwatch_agent" }) do
      local before = prompts
      local allowed = registry.call("hook.confirm", name, { to = "1" }, { bufnr = parent })
      assert(allowed ~= true and prompts == before + 1, name .. " must prompt and honor No")
    end
  end)
  vim.fn.confirm = original
  if not ok then error(err) end
end)

it("a readonly spawned child denies inherited scoped watch and unwatch replacements", function()
  registry.define({ name = "fn.provider", kind = "fn", source = [[
return function() return { stop_reason = "end_turn", content = { { type = "text", text = "done" } } } end
]] }, { scope = "global" })
  local parent = state.new_session()
  local builtin_output = drive(parent, function(ctx)
    return registry.call("tool.spawn", { task = "builtins", readonly = true }, ctx)
  end)
  local builtin_child = tonumber(builtin_output:match("buffer (%d+)"))
  if not builtin_child then error(builtin_output) end
  if not vim.wait(10000, function() return not loop.running(builtin_child) end, 10) then error("builtin child timed out") end
  local builtin_scope = registry.set_active_scope(builtin_child)
  for _, name in ipairs({ "watch_agent", "unwatch_agent" }) do
    local allowed = registry.call("hook.confirm", name, { to = tostring(parent) }, { bufnr = builtin_child })
    registry.set_active_scope(builtin_scope)
    assert(allowed == true, name .. " builtin must retain its grant-free exception")
    registry.set_active_scope(builtin_child)
  end
  registry.set_active_scope(builtin_scope)
  for _, name in ipairs({ "watch_agent", "unwatch_agent" }) do
    registry.define({ name = "tool." .. name, kind = "tool", source = "return function() return 'replacement' end" },
      { scope = parent })
  end
  local output = drive(parent, function(ctx)
    return registry.call("tool.spawn", { task = "readonly", readonly = true }, ctx)
  end)
  local child = tonumber(output:match("buffer (%d+)"))
  if not child then error(output) end
  if not vim.wait(10000, function() return not loop.running(child) end, 10) then error("child timed out") end
  local previous = registry.set_active_scope(child)
  local ok, err = pcall(function()
    for _, name in ipairs({ "watch_agent", "unwatch_agent" }) do
      local input = { to = tostring(parent) }
      assert(registry.get("tool." .. name).scope == parent and registry.call("fn.capability", name, input) == "agent_tool",
        name .. " replacement must resolve from the parent and classify as agent_tool")
      local allowed, reason = registry.call("hook.confirm", name, input, { bufnr = child })
      assert(allowed == false and tostring(reason):find("readonly subagent", 1, true),
        name .. " inherited replacement must be denied by the readonly gate")
    end
  end)
  registry.set_active_scope(previous)
  if not ok then error(err) end
end)
