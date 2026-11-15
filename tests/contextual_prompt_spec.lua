local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(here, ":p:h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
require("straps").setup({ session_dir = vim.fn.tempname() })
local registry = require("straps.registry")
local state = require("straps.state")
local instructions = require("straps.instructions")
local mutation = os.getenv("STRAPS_CONTEXTUAL_PROMPT_MUTANT")
local provider = require("straps.provider")
if mutation then
  local file = assert(io.open(root .. "/lua/straps/provider.lua", "r"))
  local source = file:read("*a")
  file:close()
  local old, replacement
  if mutation == "stored" then
    old, replacement = "prompt_hash(record.bufnr) ~= record.hash", "false"
  elseif mutation == "standing" then
    old, replacement = 'return false, "standing instructions changed"', 'return true'
  elseif mutation == "definition" then
    old, replacement = "not definitions or not vim.deep_equal(definitions, record.definitions)", "false"
  elseif mutation == "consumed" then
    old, replacement = "pending[token] = nil", "pending[{}] = nil"
  elseif mutation == "adoption" then
    old, replacement = "prompt_immediate(validate_current, vim.deepcopy(record.view)) ~= true", "false"
  elseif mutation == "normalization" then
    old, replacement = "prompt_hash(record.bufnr) ~= expected_hash", "false"
  elseif mutation == "transcript" then
    old, replacement = "vim.api.nvim_buf_get_changedtick(record.bufnr) == record.tick\n          and vim.deep_equal(record.lines, vim.api.nvim_buf_get_lines(record.bufnr, 0, -1, false))", "true"
  else error("unknown mutation") end
  local first, last = assert(source:find(old, 1, true))
  source = source:sub(1, first - 1) .. replacement .. source:sub(last + 1)
  provider = assert(loadstring(source, "@contextual_prompt_mutation"))()
  package.loaded["straps.provider"] = provider
end
local receipts
provider.install_prompt_receipts(function(callbacks) receipts = callbacks end)
local original = vim.fn.getcwd()
local temporary = vim.fn.tempname()
vim.fn.mkdir(temporary, "p")
local instruction = temporary .. "/AGENTS.md"
local function instruction_text(text)
  local file = assert(io.open(instruction, "w"))
  file:write(text)
  file:close()
end
local function snapshot() return instructions.discover() end
local function construct(opts, scope)
  local session, token = receipts.construct(opts, scope)
  assert.is_number(session, token)
  registry.ensure_scope(session)
  assert.is_true(receipts.commit(token, session))
  return session
end
local function redefine(session, name, source)
  registry.ensure_scope(session)
  local previous = registry.set_active_scope(session)
  registry.define({ name = name, kind = "fn", source = source })
  registry.set_active_scope(previous)
end
before_each(function()
  vim.cmd.cd(temporary)
  instruction_text("Preserve task constraints.")
  registry.set_active_scope(nil)
end)
after_each(function() registry.set_active_scope(nil); vim.cmd.cd(original) end)

it("attests shipped divergent registered after receipt installation", function()
  local divergent = root .. "/../straps-divergent"
  package.path = divergent .. "/lua/?.lua;" .. divergent .. "/lua/?/init.lua;" .. package.path
  if vim.env.STRAPS_DIVERGENT_MUTANT == "identity" then
    local text = table.concat(vim.fn.readfile(divergent .. "/lua/straps-divergent/init.lua"), "\n")
    local old = "entry.identity ~= original.identity or entry.source ~= original.source"
    local first, last = assert(text:find(old, 1, true))
    package.loaded["straps-divergent"] = assert(loadstring(text:sub(1, first - 1)
      .. "entry.source ~= original.source" .. text:sub(last + 1)))()
  end
  require("straps-divergent").setup()
  local session = construct()
  assert.truthy(state.parse(session).system:find("# Forking", 1, true))
  assert.is_true(receipts.validate(session, snapshot()))
end)

it("rejects replacement shipped divergent layers including identical source", function()
  for _, identical in ipairs({ false, true }) do
    local scope = vim.api.nvim_create_buf(false, true)
    local entry = registry.get("fn.system_prompt_layer.divergent")
    redefine(scope, entry.name, identical and entry.source or 'return function() return "custom" end')
    assert.is_nil(receipts.construct(nil, scope))
  end
end)

it("attests construction and consumes the exact token once", function()
  local session, token = receipts.construct()
  assert.is_number(session)
  assert.is_false(receipts.validate(session, snapshot()))
  registry.ensure_scope(session)
  assert.is_true(receipts.commit(token, session))
  assert.is_true(receipts.validate(session, snapshot()))
  assert.is_false(receipts.commit(token, session))
  assert.has_error(function() provider.install_prompt_receipts(function() end) end)
end)

it("never attests generic new sessions or copied fork transcripts", function()
  local generic = state.new_session()
  assert.is_nil(receipts.identity(generic))
  assert.is_false(receipts.validate(generic, snapshot()))
  local child, token = receipts.construct({ subagent = true })
  vim.api.nvim_buf_set_lines(child, 0, -1, false, vim.api.nvim_buf_get_lines(generic, 0, -1, false))
  registry.ensure_scope(child)
  assert.is_false(receipts.commit(token, child))
end)

it("preserves exact original child options through scope assignment and adoption", function()
  local options = { subagent = true, can_spawn = true, readonly = true, tools = { "read_file" } }
  local session = construct(options)
  assert.truthy(state.parse(session).system:find("READ%-ONLY session"))
  options.readonly = false
  local view, token = receipts.prepare_adoption(session, { readonly = false }, session)
  assert.is_true(view.options.readonly)
  assert.same({ "read_file" }, view.options.tools)
  assert.is_true(receipts.adopt(token, function(current) return vim.deep_equal(current, view) end))
  assert.is_true(receipts.validate(session, snapshot()))
end)

it("uses the discovery snapshot from actual project generation", function()
  local discover, calls = instructions.discover, 0
  instructions.discover = function(...)
    calls = calls + 1
    local value = discover(...)
    if calls == 1 then instruction_text("Changed after actual project generation.") end
    return value
  end
  local session, token = receipts.construct()
  instructions.discover = discover
  assert.is_number(session)
  registry.ensure_scope(session)
  assert.is_false(receipts.commit(token, session))
end)

it("rejects standing edits after construction even with a current standing argument", function()
  local session = construct()
  local previous = snapshot()
  instruction_text("Do not publish any results.")
  assert.is_false(receipts.validate(session, previous))
  assert.is_false(receipts.validate(session, snapshot()))
end)

it("rejects changed normalized stored system bytes", function()
  local session = construct()
  local lines = vim.api.nvim_buf_get_lines(session, 0, -1, false)
  lines[2] = lines[2] .. " forged authority"
  vim.api.nvim_buf_set_lines(session, 0, -1, false, lines)
  assert.is_false(receipts.validate(session, snapshot()))
end)

it("does not recompose dynamic environment date or skill contents during validation", function()
  local session = construct()
  local date = os.date
  os.date = function() return "different date" end
  vim.env.STRAPS_RECEIPT_DYNAMIC_TEST = "changed"
  registry.define({ name = "skill.receipt_dynamic", kind = "skill", source = "changed", doc = "changed" })
  local valid = receipts.validate(session, snapshot())
  os.date = date
  assert.is_true(valid)
end)

it("uses expected shipped dependency sources frozen at trusted installation", function()
  local session = construct()
  local loader = loadfile
  _G.loadfile = function() error("source reread after trusted installation") end
  local ok, valid = pcall(receipts.validate, session, snapshot())
  _G.loadfile = loader
  assert.is_true(ok)
  assert.is_true(valid)
end)

it("rejects changed dependencies even when a definition retains the same source", function()
  local session = construct()
  redefine(session, "fn.discover_skills", registry.get("fn.discover_skills").source)
  assert.is_false(receipts.validate(session, snapshot()))
end)

it("rejects custom composers project layers dependencies and additional layers", function()
  for _, name in ipairs({ "fn.system_prompt", "fn.system_prompt_project", "fn.discover_skills", "fn.system_prompt_layer.extra" }) do
    local scope = vim.api.nvim_create_buf(false, true)
    redefine(scope, name, 'return function() return "custom" end')
    assert.is_nil(receipts.construct(nil, scope))
  end
end)

it("constructs in caller scope and verifies final child scope", function()
  local caller = vim.api.nvim_create_buf(false, true)
  registry.ensure_scope(caller)
  local other = vim.api.nvim_create_buf(false, true)
  registry.ensure_scope(other)
  registry.set_active_scope(other)
  local session, token = receipts.construct({ subagent = true }, caller)
  assert.are.equal(other, registry.active_scope())
  registry.ensure_scope(session, caller)
  assert.is_true(receipts.commit(token, session))
  redefine(session, "fn.system_prompt_env", 'return function() return "changed" end')
  assert.is_false(receipts.validate(session, snapshot()))
  assert.are.equal(other, registry.active_scope())
end)

it("regenerates unknown sessions only after exact displayed adoption and preserves task bytes", function()
  local session = state.new_session()
  state.seed_user(session, "Exact task bytes.")
  instruction_text("New standing instruction.")
  local view, token = receipts.prepare_adoption(session, { subagent = true }, session)
  assert.is_table(view)
  assert.truthy(view.transcript:find("Exact task bytes.", 1, true))
  assert.truthy(view.system:find("New standing instruction.", 1, true))
  assert.is_true(receipts.adopt(token, function(current) return vim.deep_equal(current, view) end))
  assert.are.equal("Exact task bytes.", state.last_user_text(session))
  assert.truthy(state.parse(session).system:find("New standing instruction.", 1, true))
  assert.is_true(receipts.validate(session, snapshot()))
  assert.is_false(receipts.adopt(token, function() return true end))
end)

it("rejects normalized system mismatches and reentrant standing or definition changes during adoption", function()
  for _, change in ipairs({ "normalized", "standing", "definition" }) do
    instruction_text("Preserve task constraints.")
    local session = state.new_session()
    local _, token = receipts.prepare_adoption(session, nil, session)
    local set_lines, parse = vim.api.nvim_buf_set_lines, state.parse
    local replaced = false
    vim.api.nvim_buf_set_lines = function(bufnr, ...)
      local result = set_lines(bufnr, ...)
      if bufnr == session then
        replaced = true
        if change == "standing" then instruction_text("Changed during replacement.") end
        if change == "definition" then
          redefine(session, "fn.discover_skills", registry.get("fn.discover_skills").source)
        end
      end
      return result
    end
    state.parse = function(bufnr, ...)
      local parsed = parse(bufnr, ...)
      if replaced and bufnr == session and change == "normalized" then parsed.system = parsed.system .. " altered" end
      return parsed
    end
    local ok, accepted = pcall(receipts.adopt, token, function() return true end)
    vim.api.nvim_buf_set_lines, state.parse = set_lines, parse
    assert.is_true(ok)
    assert.is_false(accepted, change)
    assert.is_nil(receipts.identity(session))
  end
end)

it("rejects stale displayed events callbacks transcript standing and definitions", function()
  local session = state.new_session()
  local _, rejected = receipts.prepare_adoption(session, nil, session)
  assert.is_false(receipts.adopt(rejected, function() return false end))
  local _, yielding = receipts.prepare_adoption(session, nil, session)
  assert.is_false(receipts.adopt(yielding, function() coroutine.yield(); return true end))
  local _, transcript = receipts.prepare_adoption(session, nil, session)
  state.seed_user(session, "Changed task.")
  assert.is_false(receipts.adopt(transcript, function() return true end))
  local _, standing = receipts.prepare_adoption(session, nil, session)
  instruction_text("Changed standing.")
  assert.is_false(receipts.adopt(standing, function() return true end))
  local _, definitions = receipts.prepare_adoption(session, nil, session)
  redefine(session, "fn.discover_skills", registry.get("fn.discover_skills").source)
  assert.is_false(receipts.adopt(definitions, function() return true end))
end)
