-- tests/capability_spec.lua — per-entry capability metadata (Contract 3).
--   busted tests/capability_spec.lua
-- Covers: registry.define accepting/validating spec.capability, fn.capability
-- consulting a tool entry's own capability field before the hardcoded
-- classification, session shadows of builtins classified agent_tool, name
-- grants keyed to the entry version (registry.tool_grant_key), render()
-- round-tripping the field, and builtins keeping their hardcoded categories.

local script = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(vim.fn.fnamemodify(script, ":p"), ":h:h")
vim.opt.runtimepath:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local straps = require("straps").setup({})
straps.config.session_dir = vim.fn.tempname()

local registry = require("straps.registry")


local function define_tool(name, capability)
  return registry.define({
    name = "tool." .. name,
    kind = "tool",
    doc = "test tool " .. name,
    source = "return function(input) return 'ok' end",
    capability = capability,
  }, { scope = "global" })
end

it("capability='read' -> fn.capability and readonly_policy true", function()
  define_tool("t1", "read")
  assert(registry.call("fn.capability", "t1") == "read",
    "expected t1 capability read")
  assert(registry.call("fn.readonly_policy", "t1", {}) == true,
    "expected t1 readonly_policy true")
end)

it("capability='vcs' -> classified but never grantable", function()
  define_tool("t2", "vcs")
  assert(registry.call("fn.capability", "t2") == "vcs",
    "expected t2 capability vcs")
  assert(registry.call("fn.readonly_policy", "t2", {}) == false,
    "expected t2 readonly_policy false")
  local grantable = registry.call("fn.capability")
  local found = false
  for _, c in ipairs(grantable) do
    if c == "vcs" then found = true end
  end
  assert(not found, "vcs must not appear in the grantable list")
end)

it("undeclared tool -> agent_tool", function()
  registry.define({
    name = "tool.t3",
    kind = "tool",
    doc = "test tool t3",
    source = "return function(input) return 'ok' end",
  }, { scope = "global" })
  assert(registry.call("fn.capability", "t3") == "agent_tool",
    "expected t3 capability agent_tool")
end)

it("session shadow of a builtin without capability -> agent_tool, prompts under every grant", function()
  local state = require("straps.state")
  local buf = state.new_session()
  for _, c in ipairs(registry.call("fn.capability")) do registry.grant(buf, "cap:" .. c) end
  local prev = registry.set_active_scope(buf)
  local ok, err = pcall(function()
    registry.define({
      name = "tool.bash",
      kind = "tool",
      doc = "shadow",
      source = "return function(input) return 'shadowed' end",
    })
    registry.define({
      name = "tool.read_file",
      kind = "tool",
      doc = "shadow",
      source = "return function(input) return 'shadowed' end",
    })
    assert(registry.call("fn.capability", "bash", { command = "ls" }) == "agent_tool",
      "session shadow of bash should be agent_tool")
    assert(registry.call("fn.capability", "read_file", { path = "x" }) == "agent_tool",
      "session shadow of read_file should be agent_tool")
    assert(registry.call("fn.readonly_policy", "read_file", { path = "x" }) == false,
      "session shadow of read_file must not be read-only")

    local prompted = {}
    local saved = vim.fn.confirm
    vim.fn.confirm = function(msg)
      prompted[#prompted + 1] = msg:match("allow (%S+)%?")
      return 2
    end
    local allowed_bash = registry.call("hook.confirm", "bash", { command = "ls" }, { bufnr = buf })
    local allowed_read = registry.call("hook.confirm", "read_file", { path = "x" }, { bufnr = buf })
    vim.fn.confirm = saved
    assert(allowed_bash == false, "shadowed bash must not pass under cap:exec")
    assert(allowed_read == false, "shadowed read_file must not be auto-allowed")
    assert(vim.deep_equal(prompted, { "bash", "read_file" }),
      "both shadows should prompt: " .. vim.inspect(prompted))
  end)
  registry.set_active_scope(prev)
  assert(ok, err)
  assert(registry.call("fn.capability", "bash", { command = "ls" }) == "exec",
    "global bash stays exec outside the session scope")
end)

it("a name grant covers one definition: a session shadow or a redefinition prompts again", function()
  local state = require("straps.state")
  local buf = state.new_session()
  registry.define({
    name = "tool.t5",
    kind = "tool",
    doc = "test tool t5",
    source = "return function(input) return 'v1' end",
  }, { scope = "global" })
  local prev = registry.set_active_scope(buf)
  local ok, err = pcall(function()
    assert(registry.tool_grant_key("bash") == "bash@v1", "key names the version: " .. registry.tool_grant_key("bash"))
    assert(registry.tool_grant_key("no_such_tool") == "no_such_tool", "unknown tool keeps the bare name")

    local prompted = {}
    local saved = vim.fn.confirm
    vim.fn.confirm = function(msg)
      prompted[#prompted + 1] = msg:match("allow (%S+)%?")
      return 3
    end
    assert(registry.call("hook.confirm", "bash", { command = "ls" }, { bufnr = buf }) == true,
      "'Always this tool' allows the call")
    assert(registry.call("hook.confirm", "t5", {}, { bufnr = buf }) == true,
      "'Always this tool' allows the agent tool")
    assert(registry.granted(buf)["bash@v1"] and registry.granted(buf)["t5@v1"],
      "the grant set holds versioned keys: " .. vim.inspect(registry.granted(buf)))
    assert(registry.granted(buf)["bash"] == nil, "no bare-name key is written")
    vim.fn.confirm = function(msg)
      prompted[#prompted + 1] = msg:match("allow (%S+)%?")
      return 2
    end
    assert(registry.call("hook.confirm", "bash", { command = "ls" }, { bufnr = buf }) == true,
      "the same definition runs unprompted under the name grant")
    assert(registry.call("hook.confirm", "t5", {}, { bufnr = buf }) == true,
      "the same agent tool runs unprompted under the name grant")
    assert(vim.deep_equal(prompted, { "bash", "t5" }), "two prompts so far: " .. vim.inspect(prompted))

    registry.define({ name = "tool.bash", kind = "tool", doc = "shadow",
      source = "return function() return 'shadowed' end" })
    registry.define({ name = "tool.t5", kind = "tool", doc = "t5 again",
      source = "return function() return 'v2' end" })
    assert(registry.tool_grant_key("bash") == "bash@v2@" .. buf,
      "the shadow bumps the key: " .. registry.tool_grant_key("bash"))
    assert(registry.call("hook.confirm", "bash", { command = "ls" }, { bufnr = buf }) == false,
      "a session shadow of bash must not run under the old name grant")
    assert(registry.call("hook.confirm", "t5", {}, { bufnr = buf }) == false,
      "a redefined agent tool must not run under the old name grant")
    assert(vim.deep_equal(prompted, { "bash", "t5", "bash", "t5" }),
      "both redefinitions prompt: " .. vim.inspect(prompted))

    vim.fn.confirm = function(msg)
      prompted[#prompted + 1] = msg:match("allow (%S+)%?")
      return 3
    end
    assert(registry.call("hook.confirm", "t5", {}, { bufnr = buf }) == true, "'Always this tool' on the shadow")
    assert(registry.granted(buf)["t5@v2@" .. buf],
      "the shadow's grant carries the scope: " .. vim.inspect(registry.granted(buf)))
    assert(registry.remove("tool.t5"), "the session shadow is removed")
    registry.define({ name = "tool.t5", kind = "tool", doc = "t5 global v2",
      source = "return function() return 'g2' end" }, { scope = "global" })
    assert(registry.tool_grant_key("t5") == "t5@v2",
      "a global redefinition reaches the same version: " .. registry.tool_grant_key("t5"))
    vim.fn.confirm = function(msg)
      prompted[#prompted + 1] = msg:match("allow (%S+)%?")
      return 2
    end
    assert(registry.call("hook.confirm", "t5", {}, { bufnr = buf }) == false,
      "a global redefinition at the shadow's version must not run under the shadow's grant")
    vim.fn.confirm = saved
    assert(vim.deep_equal(prompted, { "bash", "t5", "bash", "t5", "t5", "t5" }),
      "prompts: " .. vim.inspect(prompted))
  end)
  registry.set_active_scope(prev)
  assert(ok, err)
end)

it("builtin write_file still edit", function()
  assert(registry.call("fn.capability", "write_file") == "edit",
    "expected write_file capability edit")
end)

it("builtin read_file still read", function()
  assert(registry.call("fn.capability", "read_file") == "read",
    "expected read_file capability read")
end)

it("render() emits capability and round-trips through execution", function()
  local rendered = registry.render("tool.t1")
  assert(rendered:find('capability = "read"', 1, true),
    "rendered chunk should contain capability = \"read\": " .. rendered)

  local swapped = rendered:gsub('name = "tool%.t1"', 'name = "tool.t1b"', 1)
  assert(swapped ~= rendered, "expected the name substitution to apply")

  local chunk, err = load(swapped, "test-render-t1b")
  assert(chunk, "rendered chunk failed to compile: " .. tostring(err))
  chunk()

  assert(registry.call("fn.capability", "t1b") == "read",
    "expected t1b (defined from rendered source) to keep capability read")
end)

it("registry.define with non-string capability errors", function()
  local ok, err = pcall(function()
    registry.define({
      name = "tool.t4",
      kind = "tool",
      doc = "test tool t4",
      source = "return function(input) return 'ok' end",
      capability = 42,
    }, { scope = "global" })
  end)
  assert(not ok, "expected registry.define to raise on non-string capability")
  assert(tostring(err):find("capability", 1, true),
    "error message should mention capability: " .. tostring(err))
end)
