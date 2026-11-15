local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(vim.fn.fnamemodify(here, ":p"), ":h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
local transport = require("straps.provider_transport")
local mutation = vim.env.PROVIDER_TRANSPORT_MUTATION
if mutation then
  local source = table.concat(vim.fn.readfile(root .. "/lua/straps/provider_transport.lua"), "\n")
  local targets = {
    argv = { 'command[#command + 1] = argv[i]', 'command[#command + 1] = argv[i]' },
    env = { 'for _, name in ipairs(key_vars) do env[name] = nil end', 'local ignored = true' },
    permissions = { '"wx", 384', '"wx", 420' },
    cleanup = { 'uv.fs_unlink(path); path = nil', 'path = nil' },
  }
  if mutation == "argv" then
    targets.argv = { 'headers[#headers + 1] = value', 'headers[#headers + 1] = value; command[#command + 1] = "-H"; command[#command + 1] = value' }
  end
  local target = assert(targets[mutation])
  local first, last = assert(source:find(target[1], 1, true))
  transport = assert(loadstring(source:sub(1, first - 1) .. target[2] .. source:sub(last + 1)))()
end

local keys = { "ANTHROPIC_API_KEY", "OPENAI_API_KEY", "LLAMACPP_API_KEY", "LLAMA_API_KEY" }
local saved, paths = {}, {}
before_each(function()
  for _, key in ipairs(keys) do saved[key] = vim.env[key]; vim.env[key] = "environment-secret" end
end)
after_each(function()
  for _, key in ipairs(keys) do vim.env[key] = saved[key] end
  for _, path in ipairs(paths) do vim.uv.fs_unlink(path) end
  paths = {}
end)

local function invoke(mode)
  local captured, callback, path, received
  local body = "\0binary\255body\n"
  local function system(argv, opts, done)
    captured, callback = { argv = argv, opts = opts }, done
    for i, arg in ipairs(argv) do
      if arg == "--header" and argv[i + 1]:sub(1, 1) == "@" then path = argv[i + 1]:sub(2); paths[#paths + 1] = path end
    end
    assert(path)
    received = table.concat(vim.fn.readfile(path), "\n")
    captured.mode = vim.uv.fs_stat(path).mode % 512
    if mode == "spawn" then error("spawn failure") end
    return {
      kill = function() return true end,
      wait = function() return { code = 0 } end,
    }
  end
  local called = false
  local ok, proc = pcall(transport.system, { "curl", "-H", "Authorization: Bearer secret-token", "-H", "x-api-key: secret-key",
    "-H", "chatgpt-account-id: secret-account", "--data-binary", "@-", "https://example.invalid" },
    { stdin = body }, function() called = true end, system)
  return { ok = ok, proc = proc, captured = captured, path = path, received = received, body = body,
    finish = function() callback({ code = 0 }); assert.is_true(called) end }
end

it("keeps authentication out of argv and preserves private header contents and binary stdin", function()
  local result = invoke()
  assert.is_true(result.ok)
  local argv = table.concat(result.captured.argv, "\n")
  for _, secret in ipairs({ "secret-token", "secret-key", "secret-account" }) do assert.is_nil(argv:find(secret, 1, true)) end
  assert.equals("Authorization: Bearer secret-token\nx-api-key: secret-key\nchatgpt-account-id: secret-account", result.received)
  assert.equals(result.body, result.captured.opts.stdin)
  assert.equals("-q", result.captured.argv[2])
  assert.equals(384, result.captured.mode)
  result.finish()
  assert.is_nil(vim.uv.fs_stat(result.path))
end)

it("removes provider key variables from the child environment without changing Neovim", function()
  local result = invoke()
  assert.is_true(result.captured.opts.clear_env)
  for _, key in ipairs(keys) do
    assert.is_nil(result.captured.opts.env[key])
    assert.equals("environment-secret", vim.env[key])
  end
  assert.equals(vim.env.PATH, result.captured.opts.env.PATH)
  result.finish()
end)

for _, mode in ipairs({ "spawn", "kill", "wait" }) do
  it("removes the private file on " .. mode, function()
    local result = invoke(mode)
    if mode == "spawn" then assert.is_false(result.ok)
    elseif mode == "kill" then result.proc:kill(9)
    else result.proc:wait(100) end
    assert.is_nil(vim.uv.fs_stat(result.path))
  end)
end

it("rejects authentication header injection before spawning", function()
  local started = false
  local ok = pcall(transport.system, { "curl", "-H", "Authorization: Bearer key\r\nInjected: yes" }, {}, nil,
    function() started = true end)
  assert.is_false(ok)
  assert.is_false(started)
end)
