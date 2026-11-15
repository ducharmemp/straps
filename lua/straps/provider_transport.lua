local M = {}
local uv = vim.uv
local key_vars = { "ANTHROPIC_API_KEY", "OPENAI_API_KEY", "LLAMACPP_API_KEY", "LLAMA_API_KEY" }

function M.system(argv, opts, on_exit, system)
  opts = vim.tbl_extend("force", {}, opts or {})
  local env = opts.clear_env and vim.tbl_extend("force", {}, opts.env or {}) or vim.tbl_extend("force", vim.fn.environ(), opts.env or {})
  for _, name in ipairs(key_vars) do env[name] = nil end
  opts.clear_env, opts.env = true, env
  local command, headers = {}, {}
  local i = 1
  while i <= #argv do
    local value = argv[i + 1]
    if (argv[i] == "-H" or argv[i] == "--header") and type(value) == "string"
      and (value:lower():match("^authorization:") or value:lower():match("^x%-api%-key:") or value:lower():match("^chatgpt%-account%-id:")) then
      if value:find("[\r\n%z]") then error("provider transport: invalid authentication header", 0) end
      headers[#headers + 1] = value
      i = i + 2
    else
      command[#command + 1] = argv[i]
      i = i + 1
    end
  end
  local path
  local function cleanup()
    if path then uv.fs_unlink(path); path = nil end
  end
  if #headers > 0 then
    path = vim.fn.tempname()
    local fd = uv.fs_open(path, "wx", 384)
    if not fd then path = nil; error("provider transport: could not create private headers", 0) end
    local data = table.concat(headers, "\n") .. "\n"
    local written = uv.fs_write(fd, data, 0)
    local closed = uv.fs_close(fd)
    if written ~= #data or not closed then cleanup(); error("provider transport: could not write private headers", 0) end
    vim.list_extend(command, { "--header", "@" .. path })
  end
  if command[1]:match("curl$") and command[2] ~= "-q" then table.insert(command, 2, "-q") end
  local callback = on_exit and function(result)
    cleanup()
    on_exit(result)
  end or nil
  local ok, proc = pcall(system or vim.system, command, opts, callback)
  if not ok then cleanup(); error("provider transport: could not spawn process", 0) end
  return setmetatable({
    kill = function(_, signal)
      local killed, result = pcall(proc.kill, proc, signal)
      cleanup()
      if not killed then error("provider transport: could not stop process", 0) end
      return result
    end,
    wait = function(_, timeout)
      local waited, result = pcall(proc.wait, proc, timeout)
      cleanup()
      if not waited then error("provider transport: could not wait for process", 0) end
      return result
    end,
  }, { __index = proc })
end

return M
