local M = {}

function M.protected(name)
  return name == "hook.confirm" or name == "fn.capability" or name == "fn.readonly_policy"
    or name == "tool.registry_define" or name == "hook.guard" or name:sub(1, 11) == "hook.guard."
end

function M.definition_category(input)
  if type(input) ~= "table" or type(input.name) ~= "string" or type(input.source) ~= "string"
    or (input.scope ~= nil and input.scope ~= "session") then return "define" end
  local kind = input.kind
  if kind ~= "tool" and kind ~= "hook" and kind ~= "fn" and kind ~= "skill" then return "define" end
  local suffix = input.name:match("^" .. kind .. "%.(.+)$")
  if not suffix or not suffix:match(kind == "tool" and "^[%w_%-]+$" or "^[%w_][%w_%.%-]*$")
    or M.protected(input.name) then return "define" end
  return kind == "skill" and "read" or "lua"
end

function M.tool_category(entry)
  if M.protected(entry.name) then return "define" end
  return entry.scope ~= nil and "lua" or "agent_tool"
end

return M
