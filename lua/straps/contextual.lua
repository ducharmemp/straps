local M = {}
local installed = false
local statuses = {}
local divergent_controller
local divergent_classified

function M.install_divergent()
  local registry = require("straps.registry")
  assert(registry.trusted_setup_allowed(), "divergent category requires trusted setup")
  local divergent = package.loaded["straps-divergent"]
  if divergent_controller and divergent and type(divergent.install_contextual) == "function" then
    divergent.install_contextual(function(validate)
      local definitions = validate()
      if definitions and definitions["tool.fork"].identity ~= divergent_classified then
        divergent_classified = definitions["tool.fork"].identity
        divergent_controller.classify_ceiling(divergent_classified, "spawn")
      end
    end)
  end
end

local function copy(value) return vim.deepcopy(value) end

local function classify_defaults(registry, controller)
  local categories = {}
  local groups = {
    read = { "read_file", "glob", "tree", "path_info", "grep", "registry_list", "registry_get", "skill",
      "diagnostics", "diagnostic_at", "diagnostic_next", "lsp_status", "declaration", "definition", "type_definition",
      "implementation", "references", "symbols", "read_symbol", "tree_sitter_status", "node_at", "read_node", "hover",
      "workspace_symbols", "context", "show_user", "help_search", "agents", "models", "show_diff", "show_buffer",
      "show_terminal", "set_findings", "ask_user" },
    edit = { "write_file", "edit_file", "patch_file", "bulk_replace", "format", "rename_symbol", "move_file", "move_files" },
    delete = { "delete_file", "delete_files" }, exec = { "bash", "run_in_terminal", "run_quickfix" },
    lua = { "eval_lua" }, net = { "fetch_url" }, define = { "registry_define" },
    spawn = { "spawn", "spawn_wait", "send_message", "watch_agent", "unwatch_agent" },
  }
  for category, names in pairs(groups) do
    for _, name in ipairs(names) do categories["tool." .. name] = category end
  end
  categories["tool.code_action"] = function(input)
    return type(input) ~= "table" and "read" or input.index == nil and "read" or "edit"
  end
  categories["tool.fix_diagnostic"] = categories["tool.code_action"]
  categories["tool.undo_edit"] = function(input)
    return type(input) == "table" and input.history == true and "read" or "edit"
  end
  categories["tool.transcript_excise"] = function(input)
    return type(input) == "table" and input.blocks == nil and input.range == nil and "read" or "agent_tool"
  end
  for _, definition in ipairs(registry.trusted_default_tools()) do
    local category = categories[definition.name]
    if category then controller.classify_ceiling(definition.identity, category) end
  end
end

local function immediate(fn, ...)
  local co = coroutine.create(fn)
  local ok, value, reason = coroutine.resume(co, ...)
  if not ok or coroutine.status(co) ~= "dead" then return false, "trusted validation failed or yielded" end
  return value, reason
end

local function adoption_display(view, done)
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, vim.split(vim.inspect(view), "\n", { plain = true }))
  vim.bo[buffer].modifiable = false
  vim.bo[buffer].bufhidden = "wipe"
  local window = vim.api.nvim_open_win(buffer, true, { split = "below", height = 20 })
  local disposed, group
  local function dispose()
    if disposed then return end
    disposed = true
    if group then pcall(vim.api.nvim_del_augroup_by_id, group) end
    if vim.api.nvim_win_is_valid(window) then pcall(vim.api.nvim_win_close, window, true) end
    if vim.api.nvim_buf_is_valid(buffer) then pcall(vim.api.nvim_buf_delete, buffer, { force = true }) end
  end
  local function answer(accepted)
    if disposed then return end
    dispose()
    done(accepted)
  end
  vim.keymap.set("n", "y", function() answer(true) end, { buffer = buffer })
  for _, key in ipairs({ "n", "q", "<Esc>" }) do
    vim.keymap.set("n", key, function() answer(false) end, { buffer = buffer })
  end
  group = vim.api.nvim_create_augroup("straps_contextual_adopt_" .. buffer, { clear = true })
  vim.api.nvim_create_autocmd({ "BufWipeout", "WinClosed" }, { group = group, callback = function(event)
    if event.buf == buffer or event.event == "WinClosed" and tonumber(event.match) == window then answer(false) end
  end })
  return dispose
end

function M.setup(config)
  config = copy(config or {})
  if not config.enabled then return false end
  local registry = require("straps.registry")
  assert(not installed and registry.trusted_setup_allowed(), "contextual setup sealed")
  assert(type(config.limits) == "table", "explicit contextual input limits required")
  for _, name in ipairs({ "max_bytes", "max_depth", "max_items" }) do
    local value = config.limits[name]
    assert(type(value) == "number" and value > 0 and value < math.huge and value % 1 == 0, "invalid contextual input limit: " .. name)
  end
  assert(type(config.run_human) == "function", "trusted human scheduler required")
  local authorization = require("straps.authorization")
  local discover = config.discover or function() return require("straps.instructions").discover(config) end
  local compositions = {}
  local receipts = config.receipts or {}
  local core, controller, consent, assessor
  local assessor_factory = config.assessor_factory
  if config.install_assessor then
    config.install_assessor(function(factory)
      assert(assessor_factory == nil and type(factory) == "function", "private assessor factory required")
      assessor_factory = factory
    end)
  end
  local records, families, plans, reopening, subscriptions, adoptions = {}, {}, {}, {}, {}, {}
  local question_tickets = setmetatable({}, { __mode = "k" })
  local next_record = 0
  installed = true
  authorization.install_core(function(value) core = value end, { validate_ceiling = function(parent, child, subset)
      return controller.subset_ceiling(parent, child, copy(subset.capabilities))
    end,
    activate_ceiling = function(_, child, capabilities)
      controller.narrow_ceiling(child, { allow = copy(capabilities) })
      return true
    end,
  })

  local function refresh(bufnr)
    local snapshot = authorization.snapshot(bufnr)
    statuses[bufnr] = snapshot and { status = snapshot.status, session_id = snapshot.session_id,
      task_id = snapshot.task_id, epoch = snapshot.epoch } or nil
    return snapshot
  end
  local function composition(bufnr)
    if type(receipts.identity) ~= "function" then return nil end
    return immediate(receipts.identity, bufnr)
  end
  local function prompt_current(bufnr, standing)
    return type(receipts.validate) == "function" and immediate(receipts.validate, bufnr, copy(standing)) == true
  end
  local function unchanged(bufnr, stamp, ctx)
    if ctx and ctx.cancelled and ctx.cancelled() then return false, "operation cancelled" end
    if not vim.deep_equal(stamp, authorization.execution_stamp(bufnr)) then return false, "authorization changed" end
    local standing = immediate(discover)
    if type(standing) ~= "table" then return false, "standing discovery unavailable" end
    local snapshot = authorization.snapshot(bufnr)
    if not snapshot or not vim.deep_equal(snapshot.standing, standing) then return false, "standing instructions changed" end
    local identity = composition(bufnr)
    if identity == nil or not vim.deep_equal(identity, compositions[bufnr]) then return false, "instruction composition changed" end
    if not prompt_current(bufnr, standing) then return false, "persisted prompt changed or unavailable" end
    return true
  end
  local function current(bufnr, stamp)
    local valid, reason = unchanged(bufnr, stamp)
    if not valid then
      if reason == "standing instructions changed" or reason == "instruction composition changed" then
        authorization.suspend(bufnr)
        refresh(bufnr)
      end
      return false, reason
    end
    return authorization.validate_context_stamp(bufnr, stamp)
  end
  local function provider()
    if not config.disclosure or config.disclosure.approved ~= true then return nil, "provider disclosure unapproved" end
    if not assessor and assessor_factory then assessor = assessor_factory(copy(config.disclosure)) end
    if type(assessor) ~= "table" then return nil, "assessor unavailable" end
    return assessor
  end
  local function synthesize(bufnr, ctx)
    local captured = authorization.execution_stamp(bufnr)
    local valid, reason = unchanged(bufnr, captured, ctx)
    if not valid then return false, reason end
    local adapter, why = provider()
    if not adapter or type(adapter.synthesize) ~= "function" then return false, why or "synthesis unavailable" end
    if not unchanged(bufnr, captured, ctx) then return false, "synthesis context changed" end
    local ticket, snapshot = core.begin_synthesis(bufnr)
    local completed, spec, checks = pcall(adapter.synthesize, copy(snapshot), ctx)
    if not completed then core.abandon_synthesis(ticket); return false, tostring(spec) end
    if not unchanged(bufnr, captured, ctx) then core.abandon_synthesis(ticket); return false, "synthesis context changed" end
    if not spec then core.abandon_synthesis(ticket); return false, checks end
    local ok, published = pcall(core.publish_spec, ticket, spec, checks)
    refresh(bufnr)
    if not ok then return false, published end
    local expected = copy(captured)
    expected.status = "active"
    if not vim.deep_equal(expected, published) then return false, "unexpected synthesis revision" end
    return unchanged(bufnr, expected, ctx)
  end
  local function continue_submission(bufnr, ctx, enqueue, captured)
    if not unchanged(bufnr, captured, ctx) then return end
    synthesize(bufnr, ctx)
    local expected = copy(captured)
    local now = authorization.execution_stamp(bufnr)
    if now and now.status == "active" then expected.status = "active" end
    if unchanged(bufnr, expected, ctx) then enqueue() end
  end
  local function targets(binding)
    if type(config.resolve_targets) ~= "function" then
      return { unavailable = "resolver absent", binding = copy(binding), known = {}, unresolved = { "material target resolver unavailable" }, checks = {} }
    end
    local ok, value, reason = pcall(function() return immediate(config.resolve_targets, copy(binding)) end)
    if not ok or type(value) ~= "table" or type(value.known) ~= "table" or type(value.unresolved) ~= "table"
        or type(value.checks) ~= "table" then
      return { unavailable = not ok and "resolver exception" or value == nil and "resolver unavailable" or "resolver malformed",
        reason = tostring(not ok and value or reason), binding = copy(binding), known = {},
        unresolved = { "material target facts unavailable" }, checks = {} }
    end
    return copy(value)
  end
  local function target_comparison(value)
    local result = copy(value)
    if result.binding then result.binding.call_id = nil end
    if result.checks and result.checks.binding then result.checks.binding.call_id = nil end
    return result
  end
  local function target_current(record, human_override)
    local resolved = targets(record.binding)
    if not vim.deep_equal(resolved, record.targets) then return false, "target facts changed" end
    if record.targets.unavailable then return human_override == true, "material target facts unavailable" end
    if type(config.validate_targets) ~= "function" then return false, "target validation unavailable" end
    return immediate(config.validate_targets, copy(record.targets), copy(record.binding), { allow_unresolved = human_override == true })
  end
  local function validate_record(record)
    if not record or record.terminal then return false, "call terminal" end
    local valid, reason = current(record.binding.session, record.binding.stamp)
    if not valid then return false, reason end
    local active, unavailable = authorization.validate_stamp(record.binding.session, record.binding.stamp)
    if not active and not record.human_override then return false, unavailable end
    local target_ok, why = target_current(record, record.human_override)
    if target_ok ~= true then return false, why or "target facts changed" end
    return true
  end
  local function translate(decision)
    local outcome = decision.decision
    if outcome ~= "allow" and outcome ~= "ask" and outcome ~= "deny" then outcome = "deny" end
    return { outcome = outcome, reasons = copy(decision.reasons or {}), effects = copy(decision.effects or {}),
      source = copy(decision.source_ids or {}), source_ids = copy(decision.source_ids or {}),
      decision = copy(decision.decision_identity), failure = decision.failure, conflicts = copy(decision.conflicts),
      reason = decision.reason or (outcome == "deny" and "contextual authorization denied" or nil) }
  end
  local function assess(handle, binding, ctx)
    next_record = next_record + 1
    local record = { id = next_record, handle = handle, binding = copy(binding) }
    records[handle], records[record.id] = record, record
    record.targets = targets(binding)
    local adapter, reason = provider()
    local decision
    if not record.targets.unavailable and next(record.targets.unresolved) == nil and adapter and type(adapter.assess) == "function" then
      decision = adapter.assess(copy(binding), authorization.snapshot(binding.session), ctx, copy(record.targets))
    end
    if type(decision) ~= "table" then
      decision = { decision = "deny", failure = reason or "unassessed", reasons = {}, effects = {}, source_ids = {} }
    end
    record.assessment = translate(decision)
    if not record.assessment.decision then
      record.assessment.decision = { boundary = "exact-call:" .. binding.definition.identity .. ":" .. binding.call_id,
        targets = { "exact displayed call" }, effects = { "unassessed exact effects" } }
      record.exact_identity = true
    end
    record.assessment.uncertainty = copy(record.targets)
    record.policy_allow = record.assessment.outcome == "allow"
    record.consent_required = not record.policy_allow
    local original = reopening[ctx]
    if original then
      local valid = unchanged(binding.session, original.binding.stamp, ctx)
      local resolved = targets(original.binding)
      if not valid or not vim.deep_equal(resolved, original.targets)
          or not vim.deep_equal(binding.definition, original.binding.definition)
          or not vim.deep_equal(binding.input, original.binding.input)
          or binding.session_id ~= original.binding.session_id or binding.task_id ~= original.binding.task_id
          or binding.epoch ~= original.binding.epoch or binding.scope ~= original.binding.scope
          or binding.cwd ~= original.binding.cwd or binding.ceiling_revision ~= original.binding.ceiling_revision
          or not vim.deep_equal(binding.stamp, original.binding.stamp)
          or not vim.deep_equal(target_comparison(record.targets), target_comparison(original.targets))
          or not original.exact_identity and not vim.deep_equal(record.assessment.decision, original.assessment.decision) then return { decision = "deny" } end
      record.human_override = true
      record.assessment.decision = copy(original.assessment.decision)
      record.assessment.outcome = "ask"
    end
    if record.policy_allow and not original then return { decision = "allow" } end
    record.consent_required = true
    local status = consent.request(handle, record.assessment, ctx, original and { human_reopen = true } or nil)
    return { decision = status == "approved" and "allow" or "deny",
      reason = "contextual authorization denied; inspect with :StrapsAuthorization " .. record.id }
  end
  controller = registry.setup_authorization({ assess = assess, input_limits = copy(config.limits), execution_stamp = authorization.execution_stamp,
    validate_stamp = current,
    invalidate = function(handle, reason)
      local record = records[handle]
      if record then record.terminal = true; record.reason = reason; record.handle = nil; records[handle] = nil end
      consent.invalidate(handle, reason)
    end,
    consume = function(handle)
      local record = records[handle]
      local valid, reason = validate_record(record)
      if not valid then return false, reason end
      if record.consent_required then
        local consumed, why = consent.consume(handle)
        if not consumed then return false, why end
      end
      record.terminal, record.execution_started, record.handle = true, true, nil
      records[record.id] = { id = record.id, terminal = true, execution_started = true,
        binding = { session = record.binding.session, session_id = record.binding.session_id, task_id = record.binding.task_id,
          call_id = record.binding.call_id, definition = { name = record.binding.definition.name, identity = record.binding.definition.identity } } }
      records[handle] = nil
      return true
    end,
  })
  classify_defaults(registry, controller)
  divergent_controller = controller
  M.install_divergent()
  consent = require("straps.consent").connect({ describe = controller.describe,
    validate = function(handle, binding)
      local record = records[handle]
      if not record or not vim.deep_equal(record.binding, binding) then return false end
      local valid, reason = validate_record(record)
      if not valid then return false, reason end
      return controller.validate(handle, binding)
    end,
    display = config.consent_display, max_pending = config.max_pending, expiry_ms = config.expiry_ms,
  })

  local human, loop, questions, children = {}, {}, {}, {}
  local discard_adoption
  local function create_session(bufnr)
    core.create_session(bufnr)
    compositions[bufnr] = copy(composition(bufnr))
    subscriptions[bufnr] = authorization.subscribe(bufnr, function(stamp, reason)
      if discard_adoption then discard_adoption(bufnr) end
      for ticket, pending in pairs(question_tickets) do if pending.bufnr == bufnr then question_tickets[ticket] = nil end end
      if reason ~= "stopped" then
        for key, record in pairs(records) do if record.binding.session == bufnr then records[key] = nil end end
      end
      if reason == "stopped" then consent.invalidate_session(stamp.session_id, reason)
      else consent.retire_session(stamp.session_id, reason) end
      refresh(bufnr)
    end)
  end
  function human.create(bufnr, options)
    options = options or {}
    create_session(bufnr)
    controller.install_ceiling(bufnr, copy(options.ceiling or {}))
    if options.legacy or options.resume then authorization.suspend(bufnr) end
    refresh(bufnr)
  end
  discard_adoption = function(bufnr, expected)
    local pending = adoptions[bufnr]
    if expected and pending ~= expected then return end
    adoptions[bufnr] = nil
    if not pending then return end
    if type(receipts.discard_adoption) == "function" then pcall(receipts.discard_adoption, pending.token) end
    if pending.dispose then pcall(pending.dispose) end
  end
  local function retire_records(bufnr)
    discard_adoption(bufnr)
    for ticket, pending in pairs(question_tickets) do if pending.bufnr == bufnr then question_tickets[ticket] = nil end end
    for key, record in pairs(records) do
      if record.binding.session == bufnr then records[key] = nil end
    end
    for plan, pending in pairs(plans) do if pending.parent == bufnr then plans[plan] = nil end end
    local snapshot = authorization.snapshot(bufnr)
    if snapshot then consent.retire_session(snapshot.session_id, "task state retired") end
  end
  function human.adopt(bufnr, enqueue, ctx)
    discard_adoption(bufnr)
    local snapshot, standing = authorization.snapshot(bufnr), immediate(discover)
    if not snapshot or type(standing) ~= "table" then return false, "adoption context unavailable" end
    local captured = authorization.execution_stamp(bufnr)
    local selected = {}
    for _, event in ipairs(snapshot.events) do
      if event.task_id == snapshot.task_id then selected[#selected + 1] = event.id end
    end
    if #selected == 0 then return false, "no task events to adopt" end
    if type(receipts.prepare_adoption) ~= "function" or type(receipts.adopt) ~= "function" then
      return false, "prompt adoption unavailable"
    end
    local view, token = immediate(receipts.prepare_adoption, bufnr, nil, bufnr)
    if type(view) ~= "table" or token == nil then return false, "prompt adoption unavailable" end
    view = copy(view)
    view.instruction = "Review complete transcript, task events and standing instructions; y adopts, n rejects"
    view.task_id, view.events, view.stamp, view.standing = snapshot.task_id, copy(snapshot.events), copy(captured), copy(standing)
    local function displayed_current(freshctx)
      if freshctx and freshctx.cancelled and freshctx.cancelled() then return false end
      if not vim.deep_equal(standing, immediate(discover)) then return false end
      local now = authorization.snapshot(bufnr)
      return now ~= nil and vim.deep_equal(snapshot.events, now.events)
        and vim.deep_equal(captured, authorization.execution_stamp(bufnr))
    end
    local pending = { token = token }
    adoptions[bufnr] = pending
    if not displayed_current(ctx) then discard_adoption(bufnr); return false, "adoption context changed" end
    local dispose
    local callback_used = false
    local displayed, result = pcall(config.adopt or adoption_display, view, function(accepted)
      if callback_used or adoptions[bufnr] ~= pending then return end
      callback_used = true
      if not accepted then discard_adoption(bufnr); return end
      local scheduled, schedule_result = pcall(config.run_human, bufnr, function(freshctx)
        if adoptions[bufnr] ~= pending then return end
        local adopted = immediate(function()
          if not displayed_current(freshctx) then return false end
          local valid = receipts.adopt(token, function() return displayed_current(freshctx) end)
          if valid ~= true then return false end
          local identity = composition(bufnr)
          if identity == nil or not prompt_current(bufnr, standing) or not displayed_current(freshctx) then return false end
          compositions[bufnr] = copy(identity)
          core.adopt_task(bufnr, selected, standing)
          return true
        end)
        discard_adoption(bufnr, pending)
        if adopted ~= true then return end
        refresh(bufnr)
        continue_submission(bufnr, freshctx, enqueue, authorization.execution_stamp(bufnr))
      end)
      if not scheduled or schedule_result == false then discard_adoption(bufnr, pending) end
    end)
    if not displayed then discard_adoption(bufnr, pending); return false, tostring(result) end
    dispose = result
    if adoptions[bufnr] == pending then pending.dispose = dispose
    elseif type(dispose) == "function" then pcall(dispose) end
    if ctx and ctx.on_cancel then ctx.on_cancel(function() if adoptions[bufnr] == pending then discard_adoption(bufnr) end end) end
    return true, function() if adoptions[bufnr] == pending then discard_adoption(bufnr) end end
  end
  function human.submit(bufnr, text, enqueue, ctx)
    assert(type(text) == "string" and type(enqueue) == "function", "exact human submission required")
    local ticket = core.prepare_capture(bufnr, "instruction", { text = text })
    core.capture(ticket)
    local snapshot = refresh(bufnr)
    if not snapshot.standing or not authorization.observe_standing(bufnr, discover()) or snapshot.status == "suspended" then
      return human.adopt(bufnr, enqueue, ctx)
    end
    local captured = authorization.execution_stamp(bufnr)
    config.run_human(bufnr, function(freshctx) continue_submission(bufnr, freshctx, enqueue, captured) end)
    return true
  end
  function human.reset(bufnr) retire_records(bufnr); core.reset_task(bufnr); refresh(bufnr) end
  function human.inspect(id)
    if type(id) ~= "number" or id < 1 or id > 9007199254740991 or id % 1 ~= 0 then return nil end
    local record = records[id]
    if not record then return nil end
    return copy({ id = record.id, binding = record.binding, assessment = record.assessment,
      terminal = record.terminal, execution_started = record.execution_started == true, reason = record.reason })
  end
  function human.reopen(id, ctx)
    local record = records[id]
    if not record or not record.terminal or record.execution_started or record.replay_started
        or not ctx or ctx.bufnr ~= record.binding.session then
      return false, "decision cannot be reopened"
    end
    local valid, why = unchanged(record.binding.session, record.binding.stamp, ctx)
    if not valid then return false, why end
    local target_ok, target_reason = target_current(record, true)
    if target_ok ~= true then return false, target_reason or "target facts changed" end
    if type(config.replay) ~= "function" then return false, "replay unavailable; inspection only" end
    local used = false
    record.replay_started = true
    local accepted, why = config.replay(human.inspect(id), ctx, function(normal_confirm, replayctx)
      local already_used = used
      used = true
      if already_used or type(normal_confirm) ~= "function" or type(replayctx) ~= "table" or replayctx == ctx
          or replayctx.bufnr ~= record.binding.session then return false, "fresh replay context required" end
      if not unchanged(record.binding.session, record.binding.stamp, replayctx) then return false, "replay binding stale" end
      reopening[replayctx] = record
      local ok, allowed, reason, run = pcall(registry.gate_tool, record.binding.definition.name:sub(6),
        copy(record.binding.input), replayctx, { confirm = normal_confirm })
      reopening[replayctx] = nil
      if not ok then return false, "fresh gate failed" end
      return allowed, reason, run
    end)
    if accepted == false and not used then record.replay_started = nil end
    return accepted, why
  end
  function loop.begin(ctx)
    local family = controller.begin_family(ctx)
    families[ctx.bufnr] = families[ctx.bufnr] or {}
    families[ctx.bufnr][family] = true
    return family
  end
  loop.bind = controller.bind_context
  function loop.finish(family)
    for bufnr, owned in pairs(families) do
      if owned[family] then
        controller.cancel_family(family)
        owned[family] = nil
        if next(owned) == nil then families[bufnr] = nil end
        return true
      end
    end
    return false
  end
  function loop.stop(bufnr)
    discard_adoption(bufnr)
    for family in pairs(families[bufnr] or {}) do controller.cancel_family(family) end
    families[bufnr] = nil
    local snapshot = authorization.snapshot(bufnr)
    if not snapshot or snapshot.status == "closed" then return end
    authorization.stop(bufnr)
    refresh(bufnr)
  end
  function loop.close(bufnr)
    controller.retire_ceiling(bufnr)
    retire_records(bufnr)
    if subscriptions[bufnr] then subscriptions[bufnr](); subscriptions[bufnr] = nil end
    compositions[bufnr] = nil
    if type(receipts.close) == "function" then pcall(receipts.close, bufnr) end
    local snapshot = authorization.snapshot(bufnr)
    if not snapshot or snapshot.status == "closed" then return end
    loop.stop(bufnr)
    authorization.close(bufnr)
    refresh(bufnr)
  end
  function questions.prepare(bufnr, proposal, ctx)
    if not ctx or ctx.bufnr ~= bufnr or ctx.cancelled and ctx.cancelled() then return nil end
    local captured = authorization.execution_stamp(bufnr)
    if not captured then return nil end
    local ticket = {}
    question_tickets[ticket] = { bufnr = bufnr, proposal = copy(proposal), stamp = copy(captured), ctx = ctx }
    return ticket
  end
  function questions.answer(question_ticket, text, resolve, ctx, selection)
    local pending = question_tickets[question_ticket]
    question_tickets[question_ticket] = nil
    if not pending or pending.ctx ~= ctx or ctx.cancelled and ctx.cancelled()
        or not vim.deep_equal(pending.stamp, authorization.execution_stamp(pending.bufnr)) then
      resolve()
      return false, "question context changed"
    end
    selection = selection or { kind = "free_text" }
    local valid_selection = type(text) == "string" and text ~= "" and type(selection) == "table"
    if valid_selection and selection.kind == "option" then
      local index = selection.index
      local option = type(index) == "number" and index >= 1 and index < math.huge and index % 1 == 0
        and pending.proposal.options[index] or nil
      local label = type(option) == "table" and option.label or option
      valid_selection = option ~= nil and label == text and vim.deep_equal(selection, { kind = "option", index = index, option = option })
    elseif valid_selection then
      valid_selection = vim.deep_equal(selection, { kind = "free_text" })
    end
    if not valid_selection then resolve(); return false, "invalid answer selection" end
    local bufnr = pending.bufnr
    local ticket = core.prepare_capture(bufnr, "answer", { text = text, proposal = pending.proposal, selection = copy(selection), accepted = true })
    core.capture(ticket)
    refresh(bufnr)
    local captured = authorization.execution_stamp(bufnr)
    resolve()
    config.run_human(bufnr, function(freshctx)
      if not unchanged(bufnr, captured, freshctx) then return end
      local snapshot = authorization.snapshot(bufnr)
      if snapshot.status == "pending" and snapshot.standing then synthesize(bufnr, freshctx) end
    end)
    return true
  end
  function children.prepare(action, parent, options)
    local plan = controller.prepare_child(action, parent, copy(options))
    plans[plan] = { parent = parent, delegation = copy(options.delegation) }
    return plan
  end
  function children.cancel(plan) plans[plan] = nil end
  function children.attach(plan, child, subset, receipt_token)
    local pending = assert(plans[plan], "unknown child plan")
    assert(vim.deep_equal(subset, pending.delegation), "child delegation differs from approved input")
    plans[plan] = nil
    controller.attach_child(plan, child)
    create_session(child)
    local committed = receipt_token ~= nil and type(receipts.commit) == "function"
      and immediate(receipts.commit, receipt_token, child) == true
    if receipt_token ~= nil or subset then assert(committed, "child prompt receipt commit failed") end
    if committed then
      local identity = composition(child)
      local standing = immediate(discover)
      assert(identity ~= nil and type(standing) == "table" and prompt_current(child, standing), "child prompt receipt invalid")
      compositions[child] = copy(identity)
    end
    if subset then
      assert(type(core.activate_delegation) == "function", "delegation activation unavailable")
      core.activate_delegation(pending.parent, child, copy(subset))
    elseif not committed then
      authorization.suspend(child)
    end
    refresh(child)
    return true
  end
  function children.rollback(child)
    controller.retire_ceiling(child)
    loop.close(child)
  end
  local adapters = { human = human, loop = loop, questions = questions, children = children }
  for name, installer in pairs(config.install or {}) do
    assert(adapters[name] and type(installer) == "function", "invalid contextual installer")
    installer(adapters[name])
  end
  return true
end

function M.status(bufnr) return copy(statuses[bufnr]) end

return M
