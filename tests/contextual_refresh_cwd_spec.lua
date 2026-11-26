-- tests/contextual_refresh_cwd_spec.lua — contextual consent refresh validates against the gate window's directory.
-- Run from the repo root: busted tests/contextual_refresh_cwd_spec.lua </dev/null

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
require("straps").setup({ session_dir = vim.fn.tempname(), terminal_status = false })
local straps = require("straps")
local default_discover = vim.env.STRAPS_REFRESH_DEFAULT_DISCOVER == "1"
straps.config.instructions_files = default_discover and {} or { "notes.md", "~/x" }
local registry, state, loop = require("straps.registry"), require("straps.state"), require("straps.loop")
local provider, instructions = require("straps.provider"), require("straps.instructions")
local targets, consent_mod, ui = require("straps.contextual_targets"), require("straps.consent"), require("straps.ui")
local api = vim.api

local receipts
provider.install_prompt_receipts(function(c) receipts = c end)
local adapter, handle
local connect = consent_mod.connect
consent_mod.connect = function(options)
  adapter = connect(options)
  local request = adapter.request
  adapter.request = function(h, ...) handle = h; return request(h, ...) end
  return adapter
end
local schedule, replay_call, human, accept
loop.install_human_operations(function(a, b) schedule, replay_call = a, b end)
local fields = { "outcome", "mode", "targets", "effects", "constraints", "reserved_decisions", "latitude", "unresolved_scope" }
local ok_setup = require("straps.contextual").setup({ enabled = true, limits = { max_bytes = 1048576, max_depth = 40, max_items = 10000 },
  run_human = schedule, replay = replay_call, disclosure = { approved = true }, receipts = receipts,
  discover = not default_discover and instructions.discover or nil,
  adopt = function(_, answer) accept = answer end,
  resolve_targets = targets.resolve, validate_targets = targets.validate,
  assessor_factory = function()
    return {
      synthesize = function(snapshot)
        local spec = { schema_version = 1, task_id = snapshot.task_id, instruction_revision = snapshot.epoch }
        for _, field in ipairs(fields) do spec[field] = { value = {}, sources = { snapshot.adopted[1] } } end
        spec.outcome.value, spec.mode.value = "local task", "implementation"
        return spec, { unsupported_authority = false, untrusted_authority = false, omitted_constraint = false,
          expanded_scope = false, lost_authorization = false, hidden_ambiguity = false }
      end,
      assess = function() return { decision = "ask", reasons = { "probe" }, effects = {}, source_ids = {} } end,
    }
  end,
  install = { loop = loop.install_contextual, human = function(a) human = a end },
})
registry.define({ name = "hook.confirm", kind = "hook", source = "return function() return true end" })
_G.refresh_calls = 0
_G.refresh_provider = function(_, ctx)
  _G.refresh_calls = _G.refresh_calls + 1
  if _G.refresh_calls == 1 then
    return { stop_reason = "tool_use", content = { { type = "tool_use", name = "read_file", id = "rf" .. _G.refresh_serial,
      input = { path = "notes.md" } } } }
  end
  ctx.emit({ type = "text_delta", text = "done" })
  return { stop_reason = "end_turn", content = { { type = "text", text = "done" } } }
end
registry.define({ name = "fn.provider", kind = "fn", source = "return function(...) return _G.refresh_provider(...) end" })
_G.refresh_serial = 0

local function wait_for(fn, what) assert(vim.wait(5000, fn, 5), "timed out: " .. what) end

local home_cwd = vim.fn.getcwd()
local sessions = {}

local function dirs()
  local dir = vim.fn.resolve(vim.fn.tempname())
  vim.fn.mkdir(dir, "p")
  local other = vim.fn.resolve(vim.fn.tempname())
  vim.fn.mkdir(other, "p")
  vim.fn.writefile({ "notes" }, dir .. "/notes.md")
  return dir, other
end

local function pending_consent(dir)
  _G.refresh_calls, _G.refresh_serial = 0, _G.refresh_serial + 1
  handle, accept = nil, nil
  vim.cmd("tabnew")
  vim.cmd("cd " .. vim.fn.fnameescape(dir))
  local session, token = receipts.construct(nil, nil)
  assert.is_number(session, tostring(token))
  sessions[#sessions + 1] = session
  registry.ensure_scope(session)
  assert.is_true(receipts.commit(token, session))
  ui.map_session_keys(session)
  api.nvim_set_current_buf(session)
  local gate_win = api.nvim_get_current_win()
  human.create(session)
  state.append_text(session, "read notes")
  local enqueued = 0
  human.submit(session, "read notes", function() enqueued = enqueued + 1 end)
  wait_for(function() return accept ~= nil end, "adoption display")
  accept(true)
  wait_for(function() return enqueued == 1 end, "enqueue")
  loop.start(session)
  wait_for(function() return handle ~= nil and adapter.status(handle) == "displayed" end, "consent displayed")
  return session, gate_win
end

local function not_suspended(session)
  return require("straps.contextual").status(session).status ~= "suspended"
end

local function consent_window()
  for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
    local line = api.nvim_buf_get_lines(api.nvim_win_get_buf(w), 0, 1, false)[1] or ""
    if line:find("Consent:", 1, true) == 1 then return w end
  end
end

after_each(function()
  for _, buf in ipairs(loop.running_sessions()) do loop.stop(buf) end
  if handle then pcall(adapter.invalidate, handle, "test cleanup") end
  vim.wait(500, function() return #loop.running_sessions() == 0 end, 10)
  vim.cmd("silent! tabonly!")
  vim.cmd("silent! only!")
  vim.cmd("enew!")
  for _, buf in ipairs(sessions) do
    if api.nvim_buf_is_valid(buf) then pcall(api.nvim_buf_delete, buf, { force = true }) end
  end
  sessions = {}
  vim.cmd("cd " .. vim.fn.fnameescape(home_cwd))
  handle, accept = nil, nil
end)

it("sets up contextual authorization", function()
  assert.is_true(ok_setup)
end)

it("keeps a pending consent displayed after :tcd in another tab, and gy there opens consent's split", function()
  local dir, other = dirs()
  local session = pending_consent(dir)
  vim.cmd("tab sbuffer " .. session)
  vim.cmd("tcd " .. vim.fn.fnameescape(other))
  assert.are.equal("displayed", adapter.status(handle))
  assert.is_true(not_suspended(session))
  vim.cmd("normal gy")
  assert(consent_window(), "consent split did not open")
  assert.are.equal("displayed", adapter.status(handle))
  assert.is_true(not_suspended(session))
end)

if not default_discover then
  it("invalidates when the gate window's own :lcd changes", function()
    local dir, other = dirs()
    local _, gate_win = pending_consent(dir)
    api.nvim_win_call(gate_win, function() vim.cmd("lcd " .. vim.fn.fnameescape(other)) end)
    assert.are.equal("invalidated", adapter.status(handle))
  end)

  it("falls back to the current window when the gate window is closed", function()
    local dir, other = dirs()
    local session, gate_win = pending_consent(dir)
    vim.cmd("split")
    api.nvim_win_close(gate_win, true)
    assert.are.equal("displayed", adapter.status(handle))
    vim.cmd("lcd " .. vim.fn.fnameescape(other))
    assert.are.equal("invalidated", adapter.status(handle))
    local _ = session
  end)

  it("approving from the other-cwd tab is refused at execution with the directory-changed result", function()
    local dir, other = dirs()
    local session = pending_consent(dir)
    vim.cmd("tab sbuffer " .. session)
    vim.cmd("tcd " .. vim.fn.fnameescape(other))
    vim.cmd("normal gy")
    local split = consent_window()
    assert(split)
    api.nvim_set_current_win(split)
    vim.cmd("normal y")
    wait_for(function() return not loop.running(session) end, "run end")
    local text = table.concat(api.nvim_buf_get_lines(session, 0, -1, false), "\n")
    assert(text:find("execution directory changed", 1, true), text)
  end)

  it("discover finds AGENTS.md upward from an explicit directory while the window is elsewhere", function()
    local dir, other = dirs()
    vim.fn.mkdir(dir .. "/sub", "p")
    vim.fn.writefile({ "agents" }, dir .. "/AGENTS.md")
    vim.cmd("cd " .. vim.fn.fnameescape(other))
    local snapshot = instructions.discover({ instructions_files = {} }, dir .. "/sub")
    local found = false
    for _, source in ipairs(snapshot.sources) do
      if source.path == dir .. "/AGENTS.md" then found = true end
    end
    assert(found, vim.inspect(snapshot.sources))
  end)

  it("joins a relative instructions file to the explicit directory and leaves ~ entries alone", function()
    local dir, other = dirs()
    local home = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(home, "p")
    vim.fn.writefile({ "home note" }, home .. "/x")
    local saved = vim.env.HOME
    vim.env.HOME = home
    vim.cmd("cd " .. vim.fn.fnameescape(other))
    local ok, snapshot = pcall(instructions.discover, { instructions_files = { "notes.md", "~/x" } }, dir)
    vim.env.HOME = saved
    assert(ok, tostring(snapshot))
    local paths = {}
    for _, source in ipairs(snapshot.sources) do paths[source.path] = true end
    assert(paths[dir .. "/notes.md"], vim.inspect(paths))
    assert(paths[home .. "/x"], vim.inspect(paths))
    assert.is_nil(paths[dir .. "/~/x"])
  end)

  it("target resolution against the binding cwd reports no cwd issue from another-cwd window", function()
    local dir, other = dirs()
    vim.cmd("cd " .. vim.fn.fnameescape(dir))
    local binding = { session = 1, session_id = "s", task_id = "t", scope = 1, cwd = dir, call_id = 1, input = { path = "notes.md" },
      definition = registry.get("tool.read_file") and vim.deepcopy({ name = "tool.read_file", kind = "tool",
        source = registry.get("tool.read_file").source, input_schema = registry.get("tool.read_file").input_schema }) }
    vim.cmd("tabnew")
    vim.cmd("tcd " .. vim.fn.fnameescape(other))
    local record = targets.resolve(binding, { cwd = binding.cwd })
    for _, issue in ipairs(record.unresolved) do assert.are_not.equal("cwd", issue.field) end
  end)
end
