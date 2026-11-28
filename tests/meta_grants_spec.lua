local script = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(vim.fn.fnamemodify(script, ":p"), ":h:h")
vim.opt.runtimepath:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local straps = require("straps").setup({})
straps.config.session_dir = vim.fn.tempname()
straps.config.gzip = false
straps.config.permission_review = "modal"
local registry = require("straps.registry")
local state = require("straps.state")

local function gate(name, input, key)
  local b = state.new_session()
  state.persist(b)
  local meta = state.session_meta_path(vim.api.nvim_buf_get_name(b))
  if key then registry.grant(b, key(meta)) end
  local prompts = 0
  local real = vim.fn.confirm
  vim.fn.confirm = function() prompts = prompts + 1; return 2 end
  local ok, allowed = pcall(registry.call, "hook.confirm", name, input(meta), { bufnr = b })
  vim.fn.confirm = real
  vim.api.nvim_buf_delete(b, { force = true })
  assert(ok, tostring(allowed))
  return allowed, prompts
end

local function write(meta) return { path = meta, content = '{"title":"forged"}' } end
local function shell(meta) return { command = "printf x > " .. vim.fn.shellescape(meta) } end
local function lua(meta) return { code = "vim.fn.writefile({'x'}, " .. vim.inspect(meta) .. ")" } end
local function const(k) return function() return k end end

describe("grants that let an agent write a session's .meta without a prompt", function()
  it("prompts with no grant (control)", function()
    local allowed, prompts = gate("write_file", write, nil)
    assert.are_not.equal(true, allowed)
    assert.are.equal(1, prompts)
  end)
  for _, case in ipairs({
    { "editfiles:*", "write_file", write, const("editfiles:*") },
    { "editdir: over session_dir", "write_file", write, function(meta)
      return "editdir:" .. (vim.uv.fs_realpath(vim.fn.fnamemodify(meta, ":h")) or vim.fn.fnamemodify(meta, ":h")) end },
    { "cap:edit", "write_file", write, const("cap:edit") },
    { "cap:exec", "bash", shell, const("cap:exec") },
    { "cap:lua", "eval_lua", lua, const("cap:lua") },
    { "Always this tool for bash", "bash", shell, function() return registry.tool_grant_key("bash") end },
  }) do
    it(case[1] .. " allows " .. case[2] .. " on .meta without a prompt", function()
      local allowed, prompts = gate(case[2], case[3], case[4])
      assert.are.equal(true, allowed)
      assert.are.equal(0, prompts)
    end)
  end
  it("Always this tool for write_file still prompts", function()
    local allowed, prompts = gate("write_file", write, function() return registry.tool_grant_key("write_file") end)
    assert.are_not.equal(true, allowed)
    assert.are.equal(1, prompts)
  end)
  it("Always this tool for bulk_replace skips the prompt (the findings list decides what it edits)", function()
    local allowed, prompts = gate("bulk_replace", function() return { pattern = "a", replacement = "b" } end,
      function() return registry.tool_grant_key("bulk_replace") end)
    assert.are.equal(true, allowed)
    assert.are.equal(0, prompts)
  end)
end)
