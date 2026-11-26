local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(here, ":p:h:h")
vim.opt.runtimepath:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local human, registry, state, loop, log, pending, core_human, core_loop, adoption, consent_displays, replayed, human_callbacks
local notify = vim.notify
local function last(kind)
  for i = #log, 1, -1 do if log[i][1] == kind then return log[i] end end
end
before_each(function()
  vim.cmd("only")
  for _, name in ipairs({ "contextual_human", "ui", "agents", "registry", "state", "loop", "steering" }) do package.loaded["straps." .. name] = nil end
  vim.g.loaded_straps = nil
  if vim.env.STRAPS_HUMAN_MUTANT == "command_reason" then
    local source = table.concat(vim.fn.readfile(root .. "/lua/straps/registry.lua"), "\n")
    local old = 'type(decision) == "table" and type(decision.reason) == "string" and decision.reason or "contextual authorization denied"'
    local first, final = assert(source:find(old, 1, true))
    package.loaded["straps.registry"] = assert(loadstring(source:sub(1, first - 1) .. '"contextual authorization denied"' .. source:sub(final + 1)))()
  end
  registry, state, loop = require("straps.registry"), require("straps.state"), require("straps.loop")
  require("straps").config.session_dir = vim.fn.tempname()
  registry.define({ name = "fn.provider", kind = "fn", source = "return function() error('provider must not run') end" })
  registry.define({ name = "fn.system_prompt", kind = "fn", source = "return function() return 'system' end" })
  log, pending = {}, {}
  vim.notify = function(message) log[#log + 1] = { "notify", message } end
  loop.start = function(buf) log[#log + 1] = { "start", buf } end
  loop.steer = function(buf, text) log[#log + 1] = { "steer", buf, text }; return true end
  loop.running = function() return false end
  local source = table.concat(vim.fn.readfile(root .. "/lua/straps/contextual_human.lua"), "\n")
  local draft_record = '      callbacks.draft(bufnr, instruction, data, state.last_user_text(bufnr))'
  local changes = {
    capture = { "return adapter.submit(bufnr, text, enqueue)", "return enqueue()" },
    stdin = { "then text = draft.instruction end", "then text = draft.displayed end" },
    commit = { "assert(receipts.commit(token, bufnr), \"prompt receipt commit failed\")", "" },
    dismissal = { "callback = function() used = true end", "callback = function() end" },
    revision = { "or revisions[bufnr] ~= revision", "or false" },
    adoption = { "if not accepted or not vim.api.nvim_buf_is_valid(bufnr)", "if false or not vim.api.nvim_buf_is_valid(bufnr)" },
    raw_adoption = { 'text = draft.instruction ~= "" and (draft.instruction .. "\\n\\n" .. draft.data) or draft.data', 'text = state.last_user_text(bufnr)' },
    raw_capture = { 'submit(bufnr, selected, function() end)', 'submit(bufnr, selected:match("^%s*(.-)%s*$"), function() end)' },
    command_id = { '    id = type(id) == "string" and id:match("^%d+$") and tonumber(id) or nil', '    id = nil' },
    command_validation = { 'if not id or id < 1 or id > 9007199254740991 or id % 1 ~= 0 then', 'if false then' },
    command_owner = { 'if not record or record.binding.session ~= bufnr then', 'if not record then' },
    command_reopen = { 'adapter.reopen(id, ctx)', 'adapter.reopen(id + 1, ctx)' },
    refusal_feedback = { 'if ok == false then vim.notify("straps: " .. tostring(reason or "authorization replay refused"), vim.log.levels.WARN) end', '' },
    command_reason = false,
    command_exact_id = false,
    ask_record = { draft_record .. '\n', '' },
    ask_record_late = { draft_record .. '\n      loop.start(bufnr)', '      loop.start(bufnr)\n' .. draft_record },
    stale_draft = { 'if draft and #state.list_blocks(bufnr) > draft.block_count then drafts[bufnr], draft = nil, nil end\n      if draft and text == draft.displayed',
      'if draft and text == draft.displayed' },
  }
  if vim.env.STRAPS_HUMAN_MUTANT and vim.env.STRAPS_HUMAN_MUTANT ~= "reload"
      and vim.env.STRAPS_HUMAN_MUTANT ~= "command_reason" and vim.env.STRAPS_HUMAN_MUTANT ~= "command_exact_id" then
    local change = assert(changes[vim.env.STRAPS_HUMAN_MUTANT])
    local first, final = assert(source:find(change[1], 1, true))
    source = source:sub(1, first - 1) .. change[2] .. source:sub(final + 1)
  end
  human = assert(loadstring(source, "@" .. root .. "/lua/straps/contextual_human.lua"))()
  package.loaded["straps.contextual_human"] = human
  local ui_source = table.concat(vim.fn.readfile(root .. "/lua/straps/ui.lua"), "\n")
  ui_source = ui_source:gsub("local starting = vim.v.vim_did_enter == 0", "local starting = true", 1)
  package.loaded["straps.ui"] = assert(loadstring(ui_source, "@" .. root .. "/lua/straps/ui.lua"))()
  local attach = human.attach
  human.attach = function(surface, consumer)
    return attach(surface, function(callbacks)
      if surface == "plugin" then human_callbacks = callbacks end
      return consumer(callbacks)
    end)
  end
  vim.cmd("source " .. vim.fn.fnameescape(root .. "/plugin/straps.lua"))
  for _, name in ipairs({ "contextual", "authorization", "consent" }) do package.loaded["straps." .. name] = nil end
  if vim.env.STRAPS_HUMAN_MUTANT == "command_exact_id" then
    local source = table.concat(vim.fn.readfile(root .. "/lua/straps/contextual.lua"), "\n")
    local old = '" .. record.id }'
    local first, final = assert(source:find(old, 1, true))
    package.loaded["straps.contextual"] = assert(loadstring(source:sub(1, first - 1) .. '" .. (record.id + 1) }' .. source:sub(final + 1)))()
  end
  adoption, consent_displays, replayed = nil, 0, nil
  require("straps.contextual").setup({ enabled = true, limits = { max_bytes = 1048576, max_depth = 40, max_items = 10000 }, disclosure = { approved = true },
    run_human = function(buf, fn) fn({ bufnr = buf }) end,
    receipts = { identity = function() return "receipt" end, validate = function() return true end,
      prepare_adoption = function() return {}, {} end, adopt = function(_, current) return current() end },
    discover = function() return { id = "standing", config_hash = "config", sources = {} } end,
    adopt = function(_, answer) adoption = answer end,
    consent_display = function(_, answer) consent_displays = consent_displays + 1; answer("reject") end,
    resolve_targets = function() return { known = {}, unresolved = {}, checks = {} } end,
    validate_targets = function() return true end,
    replay = function(record) replayed = record.id; return true end,
    assessor_factory = function() return {
      synthesize = function(snapshot)
        local spec = { schema_version = 1, task_id = snapshot.task_id, instruction_revision = snapshot.epoch }
        for _, key in ipairs({ "outcome", "mode", "targets", "effects", "constraints", "reserved_decisions", "latitude", "unresolved_scope" }) do
          spec[key] = { value = {}, sources = { snapshot.adopted[1] } }
        end
        return spec, { unsupported_authority = false, untrusted_authority = false, omitted_constraint = false,
          expanded_scope = false, lost_authorization = false, hidden_ambiguity = false }
      end,
      assess = function() return { decision = "deny", decision_identity = { id = "denied" } } end,
    } end,
    install = { human = function(adapter) core_human = adapter end, loop = function(adapter) core_loop = adapter end },
  })
  human.install({
    create = function(buf, opts) log[#log + 1] = { "create", buf, opts }; core_human.create(buf, opts) end,
    submit = function(buf, text, enqueue)
      core_human.submit(buf, text, enqueue)
      log[#log + 1] = { "submit", buf, text }
      pending[#pending + 1] = enqueue
    end,
    adopt = function(buf) log[#log + 1] = { "adopt", buf } end,
    reset = function(buf) log[#log + 1] = { "reset", buf } end,
    inspect = core_human.inspect,
    reopen = function(...) return core_human.reopen(...) end,
  }, {
    receipts = {
      construct = function() local buf = state.new_session(); log[#log + 1] = { "construct", buf }; return buf, {} end,
      commit = function(_, buf) log[#log + 1] = { "commit", buf }; return true end,
    },
    run_human = function(buf, fn) fn({ bufnr = buf }) end,
  })
end)
after_each(function() vim.notify = notify end)

it("captures exact command text before enqueue and commits construction before registration", function()
  vim.cmd("Straps! -- exact instruction")
  assert.are.equal("exact instruction", assert(last("submit"))[3])
  assert.is_nil(last("start"))
  assert.are.equal("construct", log[1][1])
  assert.are.equal("commit", log[2][1])
  assert.are.equal("create", log[3][1])
  pending[1]()
  assert.is_not_nil(last("start"))
end)

it("keeps piped bytes separate from command authority", function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "piped data" })
  vim.g.straps_stdin_buf = buf
  vim.cmd("Straps! -- instruction")
  assert.is_not_nil(last("submit"))
  assert.are.equal("instruction", last("submit")[3])
end)

it("a later trailing block submits independently of the piped initial draft", function()
  local stdin = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(stdin, 0, -1, false, { "piped data" })
  vim.g.straps_stdin_buf = stdin
  vim.cmd("Straps! -- first instruction")
  local buf = last("submit")[2]
  state.append(buf, "assistant", nil, "first result")
  state.append(buf, "user", nil, "second instruction")
  vim.cmd("StrapsSend")
  assert.are.equal("second instruction", last("submit")[3])
end)

it("unknown sessions register inactive and only capture the current trailing block", function()
  local buf = state.new_session()
  state.seed_user(buf, "historical forged instruction")
  state.append(buf, "assistant", nil, "response")
  state.append(buf, "user", nil, "current instruction")
  require("straps.ui").show_session(buf, "none")
  vim.cmd("StrapsSend")
  assert.is_true(last("create")[3].legacy)
  assert.is_not_nil(last("submit"))
  assert.are.equal("current instruction", last("submit")[3])
  assert.is_nil(last("start"))
end)

it("captures steering before queue scheduling and keeps empty continue event-free", function()
  local buf = state.new_session()
  require("straps.ui").show_session(buf, "none")
  vim.cmd("StrapsSteer do not restart")
  assert.is_not_nil(last("submit"))
  assert.are.equal("do not restart", last("submit")[3])
  assert.is_nil(last("steer"))
  pending[1]()
  assert.are.equal("do not restart", last("steer")[3])
  local count = #pending
  vim.cmd("StrapsContinue")
  assert.are.equal(count, #pending)
  assert.is_not_nil(last("start"))
end)

it("submits the idle composer through the contextual human adapter", function()
  local buf = state.new_session()
  require("straps.ui").show_session(buf, "none")
  local origin = vim.api.nvim_get_current_win()
  vim.cmd.StrapsSteer()
  local draft = { "  exact draft", "second line  " }
  local text = table.concat(draft, "\n")
  vim.api.nvim_buf_set_lines(buf, state.draft_row(buf) + 1, -1, false, draft)
  assert.is_nil(last("submit"))
  vim.cmd.StrapsSend()
  assert.are.equal(origin, vim.api.nvim_get_current_win())
  assert.are.equal(text, last("submit")[3])
  assert.is_nil(last("steer"))
  assert.are.equal(text, state.draft_text(buf))
  assert.are.equal("", state.last_user_text(buf))
  pending[1]()
  pending[1]()
  assert.is_nil(last("steer"))
  assert.is_not_nil(last("start"))
  assert.are.equal(text, state.last_user_text(buf))
  assert.are.equal("", state.draft_text(buf))
end)

it("queues the active composer through the contextual human adapter", function()
  local buf = state.new_session()
  require("straps.ui").show_session(buf, "none")
  loop.running = function() return true end
  vim.api.nvim_set_current_line("queued text")
  vim.cmd.StrapsSend()
  assert.are.equal("queued text", last("submit")[3])
  assert.is_nil(last("steer"))
  pending[1]()
  assert.are.equal("queued text", last("steer")[3])
  assert.is_nil(last("start"))
end)

it("uses contextual capture after send-now waits for stop", function()
  local buf = state.new_session()
  require("straps.ui").show_session(buf, "none")
  local active = true
  loop.running = function() return active end
  local finish
  loop.stop_then = function(_, cb) finish = cb end
  vim.api.nvim_set_current_line("captured at send")
  vim.cmd.StrapsSendNow()
  assert.is_nil(last("submit"))
  assert.is_nil(last("start"))
  active = false
  finish()
  assert.are.equal("captured at send", last("submit")[3])
  assert.is_nil(last("start"))
  assert.are.equal("", state.last_user_text(buf))
  pending[1]()
  assert.is_not_nil(last("start"))
  assert.are.equal("captured at send", state.last_user_text(buf))
end)

it("does not use composer submission to bypass piped-data adoption", function()
  local stdin = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(stdin, 0, -1, false, { "piped data" })
  vim.g.straps_stdin_buf = stdin
  vim.cmd.Straps()
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_set_current_line("new request")
  vim.cmd.StrapsSendNow()
  assert.is_nil(last("submit"))
  assert.is_nil(last("start"))
  assert.are.equal("new request", state.draft_text(buf))
end)
it("exact adoption displays bytes and rejection grants nothing", function()
  local buf = state.new_session()
  state.seed_user(buf, "data requiring adoption")
  require("straps.ui").show_session(buf, "none")
  vim.cmd("StrapsAdopt")
  local display = vim.api.nvim_get_current_buf()
  assert.is_nil(last("submit"))
  assert.are.equal("data requiring adoption", vim.api.nvim_buf_get_lines(display, 2, 3, false)[1])
  local reject = vim.fn.maparg("n", "n", false, true).callback
  reject()
  assert.is_nil(last("submit"))
  require("straps.ui").show_session(buf, "none")
  vim.cmd("StrapsAdopt")
  vim.fn.maparg("y", "n", false, true).callback()
  assert.are.equal("data requiring adoption", last("submit")[3])
end)

it("dismissal and task reset invalidate exact-adoption callbacks", function()
  local buf = state.new_session()
  state.seed_user(buf, "stale data")
  require("straps.ui").show_session(buf, "none")
  vim.cmd("StrapsAdopt")
  local display = vim.api.nvim_get_current_buf()
  local accept = vim.fn.maparg("y", "n", false, true).callback
  vim.api.nvim_buf_delete(display, { force = true })
  accept()
  assert.is_nil(last("submit"))
  require("straps.ui").show_session(buf, "none")
  vim.cmd("StrapsAdopt")
  accept = vim.fn.maparg("y", "n", false, true).callback
  require("straps.ui").show_session(buf, "none")
  vim.cmd("StrapsTaskReset")
  accept()
  assert.is_nil(last("submit"))
end)

it("adoption retains original piped boundary bytes", function()
  local stdin = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(stdin, 0, -1, false, { "", " piped data ", "" })
  vim.g.straps_stdin_buf = stdin
  vim.cmd("Straps -- instruction")
  vim.cmd("StrapsAdopt")
  vim.fn.maparg("y", "n", false, true).callback()
  assert.are.equal("instruction\n\n\n piped data \n", last("submit")[3])
end)

it("stdin-only adoption displays and captures exact boundary bytes in the core event", function()
  local raw = "\n \t\n piped data \n\t\n"
  local stdin = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(stdin, 0, -1, false, vim.split(raw, "\n", { plain = true }))
  vim.g.straps_stdin_buf = stdin
  vim.cmd("Straps")
  local buf = last("create")[2]
  assert.are.equal(" piped data ", state.last_user_text(buf))
  vim.cmd("StrapsAdopt")
  local display = vim.api.nvim_get_current_buf()
  assert.are.equal(raw, table.concat(vim.api.nvim_buf_get_lines(display, 2, -1, false), "\n"))
  vim.fn.maparg("y", "n", false, true).callback()
  assert.are.equal(raw, require("straps.authorization").snapshot(buf).events[1].payload.text)
end)

it("later equal-text adoption never restores an earlier piped draft", function()
  local stdin = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(stdin, 0, -1, false, { "", "piped data", "" })
  vim.g.straps_stdin_buf = stdin
  vim.cmd("Straps")
  local buf = last("create")[2]
  state.append(buf, "assistant", nil, "result")
  state.append(buf, "user", nil, "piped data")
  vim.cmd("StrapsAdopt")
  vim.fn.maparg("y", "n", false, true).callback()
  assert.are.equal("piped data", require("straps.authorization").snapshot(buf).events[1].payload.text)
end)

it("generic agents dispatch cannot capture while actual mapping does", function()
  local buf = state.new_session()
  state.seed_user(buf, "agent list instruction")
  local ui, agents = require("straps.ui"), require("straps.agents")
  ui.all_sessions = function() return { running = {}, loaded = { { bufnr = buf } }, saved = {} } end
  registry.define({ name = "fn.agents_render", kind = "fn", source = "return function(buf) require('straps.agents').render(buf) end" })
  local dashboard = agents.open()
  agents.render(dashboard)
  for line = 1, vim.api.nvim_buf_line_count(dashboard) do
    local entry = agents.line(dashboard, line)
    if entry and entry.bufnr == buf then vim.api.nvim_win_set_cursor(0, { line, 0 }); break end
  end
  agents.key(dashboard, "gcr")
  assert.is_nil(last("submit"))
  vim.fn.maparg("g<CR>", "n", false, true).callback()
  assert.are.equal("agent list instruction", last("submit")[3])
end)

it("retains the original private command callbacks when the plugin is sourced again after sealing", function()
  vim.cmd("Straps -- initial instruction")
  local buf = assert(last("create"))[2]
  assert.is_false(registry.trusted_setup_allowed())
  vim.g.loaded_straps = nil
  local plugin_source = table.concat(vim.fn.readfile(root .. "/plugin/straps.lua"), "\n")
  if vim.env.STRAPS_HUMAN_MUTANT == "reload" then
    plugin_source = plugin_source:gsub('if require%("straps%.contextual_human"%).attached%("plugin"%) then\n  return\nend', '', 1)
  end
  assert(loadstring(plugin_source, "@" .. root .. "/plugin/straps.lua"))()
  assert.is_true(vim.g.loaded_straps)
  assert.has_error(function() human.attach("plugin", function() error("replacement callback ran") end) end)
  assert.is_nil(last("submit"))
  state.append(buf, "assistant", nil, "initial result")
  state.append(buf, "user", nil, "instruction after reload")
  vim.cmd("StrapsSend")
  assert.are.equal("instruction after reload", assert(last("submit"))[3])
  assert.is_nil(last("start"))
  pending[1]()
  assert.are.equal(buf, assert(last("start"))[2])
end)

local function denied_command_session()
  registry.define({ name = "tool.command_denial", kind = "tool", source = "return function() error('denied tool executed') end" })
  vim.cmd("Straps -- local work")
  local buf = assert(last("create"))[2]
  core_human.submit(buf, "local work", function() end)
  assert.is_function(adoption)
  adoption(true)
  local ctx = { bufnr = buf }
  core_loop.begin(ctx)
  local allowed, reason = registry.gate_tool("command_denial", {}, ctx)
  assert.is_false(allowed)
  assert.are.equal(0, consent_displays)
  return buf, reason
end

it("inspects and reopens a real denied decision through numeric Ex command text", function()
  local buf = denied_command_session()
  vim.cmd("StrapsAuthorization 1")
  local display = vim.api.nvim_get_current_buf()
  assert.are_not.equal(buf, display)
  assert.matches("id = 1", table.concat(vim.api.nvim_buf_get_lines(display, 0, -1, false), "\n"), 1, true)
  require("straps.ui").show_session(buf, "none")
  vim.cmd("StrapsAuthorization! 1")
  assert.are.equal(1, replayed)
  assert.are.equal(0, consent_displays)
end)

it("returns a discoverable decision command without opening a denied consent prompt", function()
  local _, reason = denied_command_session()
  assert.matches(":StrapsAuthorization 1", reason, 1, true)
end)

it("rejects invalid command IDs and decisions owned by another session", function()
  local buf = denied_command_session()
  for _, id in ipairs({ "0", "-1", "1.5", "1e0", "nan", "inf", "9007199254740992", "missing" }) do
    vim.cmd("StrapsAuthorization " .. id)
    assert.are.equal("straps: authorization decision ID must be a positive integer", assert(last("notify"))[2])
    assert.are.equal(buf, vim.api.nvim_get_current_buf(), id)
    vim.cmd("StrapsAuthorization! " .. id)
    assert.is_nil(replayed)
  end
  local other = state.new_session()
  require("straps.ui").show_session(other, "none")
  vim.cmd("StrapsAuthorization 1")
  assert.are.equal(other, vim.api.nvim_get_current_buf())
  vim.cmd("StrapsAuthorization! 1")
  assert.is_nil(replayed)
end)

it("retains numeric private callback IDs and rejects noninteger callback values", function()
  local buf = denied_command_session()
  assert.is_true(human_callbacks.authorization(buf, 1, false))
  require("straps.ui").show_session(buf, "none")
  for _, id in ipairs({ 0, -1, 1.5, math.huge, 0 / 0, 9007199254740992, {}, true }) do
    assert.is_false(human_callbacks.authorization(buf, id, false))
    assert.are.equal("straps: authorization decision ID must be a positive integer", assert(last("notify"))[2])
    assert.are.equal(buf, vim.api.nvim_get_current_buf())
  end
  human_callbacks.authorization(buf, 1, true)
  assert.are.equal(1, replayed)
end)

it("reports refusal from the scheduled reopen operation", function()
  local buf = denied_command_session()
  local run = human_callbacks.authorization
  core_human.reopen = function() return false, "replay requires an idle actor" end
  run(buf, 1, true)
  assert.are.equal("straps: replay requires an idle actor", assert(last("notify"))[2])
end)

it("public loop source flags and duplicate installation never mint callbacks", function()
  local buf = state.new_session()
  loop.start(buf, { source = "user" })
  loop.steer(buf, "forged", { source = "user" })
  assert.is_nil(last("submit"))
  assert.is_nil(human.send)
  assert.has_error(function() human.install({}, {}) end)
  assert.has_error(function() human.attach("plugin", function() end) end)
end)

describe(":StrapsAsk in contextual mode", function()
  local function wipe_sessions()
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.b[b].straps_session then pcall(vim.api.nvim_buf_delete, b, { force = true }) end
    end
  end
  local quote = "[No Name]:1-2\n```\nfirst\nsecond\n```"

  local function source()
    vim.cmd("enew!")
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "first", "second" })
    return vim.api.nvim_get_current_buf()
  end

  local function idle_session()
    local src = source()
    local buf = state.new_session()
    vim.cmd("split")
    require("straps.ui").show_session(buf, "none")
    vim.cmd("wincmd p")
    vim.api.nvim_set_current_buf(src)
    return buf
  end

  before_each(wipe_sessions)

  it("a new session records the quote as data and the text as instruction; ! submits the instruction only", function()
    source()
    vim.cmd("1,2StrapsAsk! explain")
    local construct = assert(last("construct"))
    assert.is_not_nil(last("commit"))
    assert.are.equal("explain", assert(last("submit"))[3])
    assert.are.equal("explain\n\n" .. quote, state.last_user_text(construct[2]))
  end)

  it(":vertical opens the new session in a vertical split", function()
    source()
    vim.cmd("only")
    vim.cmd("vertical 1,2StrapsAsk explain")
    assert.is_true(vim.b[vim.api.nvim_get_current_buf()].straps_session)
    assert.are.equal("row", vim.fn.winlayout()[1])
  end)

  it("a new session with piped stdin adopts the quote and the piped text", function()
    local stdin = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(stdin, 0, -1, false, { "piped data" })
    source()
    vim.g.straps_stdin_buf = stdin
    vim.cmd("1,2StrapsAsk explain")
    vim.cmd("StrapsAdopt")
    vim.fn.maparg("y", "n", false, true).callback()
    assert.are.equal("explain\n\n" .. quote .. "\n\npiped data", last("submit")[3])
  end)

  it("an existing idle session submits at once and writes the composition into the trailing user block", function()
    local buf = idle_session()
    state.open_draft(buf)
    vim.api.nvim_buf_set_lines(buf, state.draft_row(buf) + 1, -1, false, { "keep me" })
    vim.cmd("1,2StrapsAsk explain")
    assert.are.equal(buf, last("submit")[2])
    assert.are.equal("explain", last("submit")[3])
    assert.is_nil(last("start"))
    pending[#pending]()
    assert.are.equal("explain\n\n" .. quote, state.last_user_text(buf))
    assert.are.equal(buf, last("start")[2])
    assert.are.equal("keep me", state.draft_text(buf))
  end)

  it("refuses an existing session whose request is still unsent", function()
    source()
    vim.cmd("1,2StrapsAsk old")
    local first = assert(last("construct"))[2]
    vim.cmd("wincmd p")
    source()
    local from = vim.api.nvim_get_current_win()
    vim.cmd("1StrapsAsk second ask")
    assert.are.equal(from, vim.api.nvim_get_current_win())
    assert.is_nil(last("submit"))
    assert(last("notify")[2]:find("unsent request", 1, true), last("notify")[2])
    assert.are.equal("old\n\n" .. quote, state.last_user_text(first))
  end)

  it("shows a hidden existing session it submits to", function()
    local buf = idle_session()
    vim.cmd("only")
    assert.are.equal(-1, vim.fn.bufwinid(buf))
    assert(vim.api.nvim_buf_is_loaded(buf))
    require("straps.ask").focused(buf)
    vim.cmd("1,2StrapsAsk explain")
    assert.are.equal(buf, last("submit")[2])
    assert.are_not.equal(-1, vim.fn.bufwinid(buf))
  end)

  it("refuses without text and when the session is running", function()
    local buf = idle_session()
    vim.cmd("1,2StrapsAsk")
    assert.is_nil(last("submit"))
    assert(last("notify")[2]:find("needs an instruction", 1, true), last("notify")[2])
    loop.running = function(b) return b == buf end
    vim.cmd("1,2StrapsAsk explain")
    assert.is_nil(last("submit"))
    assert(last("notify")[2]:find("needs an idle session", 1, true), last("notify")[2])
  end)

  it("when the run does not start, :StrapsSend submits the instruction only and :StrapsAdopt displays the composition", function()
    local buf = idle_session()
    vim.cmd("1,2StrapsAsk explain")
    pending[#pending]()
    vim.api.nvim_set_current_buf(buf)
    vim.cmd("StrapsSend")
    assert.are.equal("explain", last("submit")[3])
    vim.cmd("StrapsAdopt")
    local shown = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    assert(shown:find("explain\n\n" .. quote, 1, true), shown)
    vim.cmd("normal y")
    assert.are.equal("explain\n\n" .. quote, last("submit")[3])
    local _, count = last("submit")[3]:gsub("explain", "")
    assert.are.equal(1, count)
  end)

  it("refuses to send an edited composition", function()
    local buf = idle_session()
    vim.cmd("1,2StrapsAsk explain")
    pending[#pending]()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    for i = #lines, 1, -1 do
      if lines[i] == "second" then
        vim.api.nvim_buf_set_lines(buf, i - 1, i, false, { "edited" })
        break
      end
    end
    local submits = #vim.tbl_filter(function(e) return e[1] == "submit" end, log)
    vim.api.nvim_set_current_buf(buf)
    vim.cmd("StrapsSend")
    assert.are.equal(submits, #vim.tbl_filter(function(e) return e[1] == "submit" end, log))
    assert(last("notify")[2]:find("review edited piped data", 1, true), last("notify")[2])
  end)

  it("a run that ends inside loop.start leaves the next draft sendable", function()
    local buf = idle_session()
    loop.start = function(b)
      log[#log + 1] = { "start", b }
      state.append(b, "assistant", nil, "[error] provider failed")
      state.append(b, "user", nil, "")
    end
    vim.cmd("1,2StrapsAsk explain")
    pending[#pending]()
    state.open_draft(buf)
    vim.api.nvim_buf_set_lines(buf, state.draft_row(buf) + 1, -1, false, { "try again" })
    vim.api.nvim_set_current_buf(buf)
    local notices = #vim.tbl_filter(function(e) return e[1] == "notify" end, log)
    vim.cmd("StrapsSend")
    assert.are.equal("try again", last("submit")[3])
    assert.are.equal(notices, #vim.tbl_filter(function(e) return e[1] == "notify" end, log))
  end)
end)
