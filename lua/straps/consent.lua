local M = {}
local connected = false

local function copy(value)
  return vim.deepcopy(value)
end

local function canonical(value)
  if type(value) ~= "table" then return vim.json.encode(value) end
  local keys, parts = {}, {}
  for key in pairs(value) do keys[#keys + 1] = key end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  for _, key in ipairs(keys) do parts[#parts + 1] = canonical(key) .. ":" .. canonical(value[key]) end
  return "{" .. table.concat(parts, ",") .. "}"
end

local function family(binding, assessment)
  local decision = assessment.decision
  if type(decision) ~= "table" or type(decision.boundary) ~= "string" or decision.boundary == ""
      or type(decision.targets) ~= "table" or #decision.targets == 0
      or type(decision.effects) ~= "table" or #decision.effects == 0 then return nil end
  local targets, effects = copy(decision.targets), copy(decision.effects)
  table.sort(targets)
  table.sort(effects)
  return canonical({ binding.session_id, binding.task_id, binding.epoch, decision.boundary, targets, effects })
end

local function display(view, answer)
  local lines = { "Consent: inspect the complete request before choosing.",
    "y: approve once    q/Esc: reject    use normal editor navigation to inspect" }
  if view.scope then lines[#lines + 1] = "s: approve the displayed amended boundary; reassessment required" end
  vim.list_extend(lines, vim.split(vim.inspect(view), "\n", { plain = true }))
  local buffer = vim.api.nvim_create_buf(false, true)
  local window, group, disposed
  local function dispose()
    if disposed then return end
    disposed = true
    if group then pcall(vim.api.nvim_del_augroup_by_id, group) end
    if window and vim.api.nvim_win_is_valid(window) then pcall(vim.api.nvim_win_close, window, true) end
    if vim.api.nvim_buf_is_valid(buffer) then pcall(vim.api.nvim_buf_delete, buffer, { force = true }) end
  end
  local ok, reason = pcall(function()
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
    vim.bo[buffer].buftype = "nofile"
    vim.bo[buffer].bufhidden = "wipe"
    vim.bo[buffer].swapfile = false
    vim.bo[buffer].modifiable = false
    window = vim.api.nvim_open_win(buffer, true, { split = "below", height = math.min(20, #lines) })
    vim.wo[window].wrap = true
    local function choose(choice)
      return function()
        if disposed then return end
        dispose()
        answer(choice)
      end
    end
    for _, key in ipairs({ "q", "<Esc>" }) do
      vim.keymap.set("n", key, choose("reject"), { buffer = buffer, nowait = true })
    end
    vim.keymap.set("n", "y", choose("once"), { buffer = buffer, nowait = true })
    if view.scope then vim.keymap.set("n", "s", choose("scoped"), { buffer = buffer, nowait = true }) end
    group = vim.api.nvim_create_augroup("straps_consent_" .. buffer, { clear = true })
    vim.api.nvim_create_autocmd({ "BufWipeout", "WinClosed" }, {
      callback = function(event)
        if not disposed and (event.event == "BufWipeout" and event.buf == buffer
            or event.event == "WinClosed" and tonumber(event.match) == window) then
          dispose()
          answer("reject")
        end
      end,
      group = group,
    })
  end)
  if not ok then dispose(); error(reason, 0) end
  return dispose, window
end

function M.connect(options)
  local registry = require("straps.registry")
  if connected or registry.guards_frozen() or type(registry.any_tool_executing) ~= "function"
      or registry.any_tool_executing() then error("consent: trusted setup is closed", 0) end
  assert(type(options) == "table" and type(options.describe) == "function" and type(options.validate) == "function",
    "consent: describe and validate are required")
  local limit, expiry = options.max_pending or 16, options.expiry_ms or 300000
  assert(type(limit) == "number" and limit >= 1 and limit % 1 == 0, "consent: invalid queue limit")
  assert(type(expiry) == "number" and expiry > 0, "consent: invalid expiry")
  options = copy(options)
  connected = true
  local now = options.clock or function() return vim.uv.now() end
  local show = options.display or display
  local records, queue, rejected, active = setmetatable({}, { __mode = "k" }), {}, {}, nil
  local function receipt_binding(binding)
    binding.input, binding.targets = nil, nil
    for _, key in ipairs({ "definition", "tool" }) do
      if type(binding[key]) == "table" then
        binding[key].source, binding[key].doc, binding[key].input_schema = nil, nil, nil
      end
    end
    return binding
  end
  local function release(record)
    record.handle, record.context = nil, nil
    receipt_binding(record.binding)
    record.assessment.scope = nil
  end
  local pump
  local function terminal(record, status, reason)
    record.status, record.reason = status, reason
    local dispose, release_attention, release_entry = record.dispose, record.release_attention, record.release_entry
    record.dispose, record.release_attention, record.context = nil, nil, nil
    record.release_entry, record.entry = nil, nil
    if release_entry then pcall(release_entry) end
    if release_attention then pcall(release_attention) end
    if dispose then pcall(dispose) end
    if active == record then active = nil end
    if status ~= "approved" then
      for index = #queue, 1, -1 do if queue[index] == record then table.remove(queue, index) end end
    end
    local waiters = record.waiters
    record.waiters = {}
    if status ~= "approved" then release(record) end
    for _, done in ipairs(waiters) do done(status, reason) end
  end
  local function current(record, handle)
    if now() >= record.expires then return false, "expired" end
    local ok, valid, reason = pcall(options.validate, handle or record.handle, copy(record.binding))
    if not ok or valid ~= true then return false, reason or "binding changed" end
    return true
  end
  local function refresh(record)
    if record.status == "queued" or record.status == "displayed" or record.status == "approved" then
      local valid, reason = current(record)
      if not valid then terminal(record, reason == "expired" and "expired" or "invalidated", reason) end
    end
  end
  local function tool_label(record)
    local definition = record.binding and record.binding.definition
    local name = type(definition) == "table" and definition.name or nil
    return type(name) == "string" and (name:gsub("^tool%.", "")) or "call"
  end
  local function presenter_entry(record, fields)
    return vim.tbl_extend("force", { kind = "presenter", label = tool_label(record), expires = record.expires, clock = now }, fields)
  end
  local function would_defer(record)
    local context = record.context
    local bufnr = context and context.bufnr
    if show ~= display or not (context and context.await and context.on_cancel) then return false end
    if type(bufnr) ~= "number" or not vim.api.nvim_buf_is_valid(bufnr) or vim.b[bufnr].straps_session ~= true then
      return false
    end
    return require("straps.permission_review").mode() == "deferred"
  end
  local function defer_queued(record)
    if not would_defer(record) then return end
    local entry = presenter_entry(record, { status = "queued" })
    local release_entry = require("straps.dock").defer(record.context.bufnr, entry)
    if not release_entry then return end
    record.entry, record.release_entry = entry, release_entry
    record.release_attention = require("straps.attention").wait(record.context, "consent")
  end
  local function view(record)
    return copy({ binding = record.binding, assessment = record.assessment, status = record.status,
      reason = record.reason, lifetime = { expires = record.expires, milliseconds = expiry }, scope = record.assessment.scope })
  end
  local function decide(record, choice)
    if record.status ~= "displayed" or active ~= record then return end
    refresh(record)
    if record.status ~= "displayed" then pump(); return end
    if choice == "once" then
      terminal(record, "approved", "one call; classifier objections only")
    elseif choice == "scoped" and record.assessment.scope and options.amend_scope then
      local boundary = copy(record.assessment.scope)
      local ok, event = pcall(options.amend_scope, record.handle, boundary)
      if ok and type(event) == "table" and event.event_id and type(event.evidence) == "table" and #event.evidence > 0
          and canonical(event.boundary) == canonical(boundary) then
        for _, pending in pairs(records) do
          if pending.binding.session_id == record.binding.session_id then
            if pending ~= record then terminal(pending, "invalidated", "scope amended") end
          end
        end
        record.amendment = copy(event)
        terminal(record, "amended", "reassessment required")
      else
        terminal(record, "invalidated", "explicit amended boundary evidence required")
      end
    else
      rejected[record.family] = { session_id = record.binding.session_id, task_id = record.binding.task_id, epoch = record.binding.epoch }
      terminal(record, "rejected", "human rejected decision family")
    end
    pump()
  end
  pump = function()
    if active then refresh(active); if active then return end end
    while #queue > 0 do
      local record = table.remove(queue, 1)
      refresh(record)
      if record.status == "queued" then
        if rejected[record.family] then
          terminal(record, "denied", "decision family rejected; human reopen required")
        else
          active, record.status = record, "displayed"
          record.display_revision = (record.display_revision or 0) + 1
          local revision = record.display_revision
          if not record.release_attention then
            record.release_attention = require("straps.attention").wait(record.context, "consent")
          end
          local function present()
            return show(view(record), function(choice)
              if record.display_revision == revision then decide(record, choice) end
            end)
          end
          local close, window
          local function presenter()
            if window and vim.api.nvim_win_is_valid(window) then
              vim.api.nvim_set_current_win(window)
              return
            end
            refresh(record)
            if active ~= record then pump(); return end
            local shown, cleanup, win = pcall(present)
            if shown then close, window = cleanup, win else terminal(record, "invalidated", "consent display failed"); pump() end
          end
          local dock = require("straps.dock")
          local bufnr = record.context and record.context.bufnr
          local ok, dispose
          if record.entry then
            record.entry.status, record.entry.present = "displayed", presenter
            require("straps.permission_review").changed()
            ok, dispose = true, function()
              if close then close() end
            end
          elseif show == display and dock.visible(bufnr) then
            local release = dock.defer(bufnr, presenter_entry(record, { present = presenter }))
            ok, dispose = true, function()
              if release then release() end
              if close then close() end
            end
            if not release then ok, dispose = pcall(present) end
          else
            ok, dispose = pcall(present)
          end
          if ok and type(dispose) == "function" then
            if record.status == "displayed" then record.dispose = dispose else pcall(dispose) end
          end
          if not ok then terminal(record, "invalidated", "consent display failed") end
          if active then return end
        end
      end
    end
  end
  local adapter = {}
  function adapter.request(handle, assessment, ctx, opts)
    local record = records[handle]
    if not record then
      local ok, binding = pcall(options.describe, handle)
      if not ok or type(handle) ~= "table" or type(binding) ~= "table" or binding.session_id == nil
          or binding.task_id == nil or binding.epoch == nil then
        return "denied", "invalid call handle"
      end
      record = { handle = handle, binding = copy(binding), assessment = copy(assessment), context = ctx,
        status = "denied", expires = now() + expiry, waiters = {} }
      records[handle] = record
      local retained = setmetatable({ record }, { __mode = "v" })
      vim.defer_fn(function()
        local pending = retained[1]
        if pending then refresh(pending); pump() end
      end, expiry)
      record.family = family(binding, assessment)
      local count = 0
      for _, pending in pairs(records) do
        refresh(pending)
        if pending.status == "queued" or pending.status == "displayed" or pending.status == "approved" then count = count + 1 end
      end
      local valid, reason = current(record)
      if not valid then
        terminal(record, reason == "expired" and "expired" or "invalidated", reason)
        return record.status, record.reason
      end
      if not record.family then record.reason = "missing decision identity; human inspection required"
      elseif assessment.outcome ~= "ask" then record.reason = assessment.reason or "classifier denied; human inspection available"
      elseif rejected[record.family] and not (opts and opts.human_reopen == true) then
        record.reason = "decision family rejected; human reopen required"
      elseif count >= limit then record.reason = "consent queue full; human inspection available"
      else
        if opts and opts.human_reopen == true then rejected[record.family] = nil end
        if rejected[record.family] then record.reason = "decision family rejected; human reopen required"
        else
          record.status = "queued"
          queue[#queue + 1] = record
          defer_queued(record)
        end
      end
    end
    pump()
    refresh(record)
    if ctx and (record.status == "queued" or record.status == "displayed") then
      if ctx.on_cancel then ctx.on_cancel(function() adapter.invalidate(handle, "cancelled") end) end
      return ctx.await(function(done)
        if record.status == "queued" or record.status == "displayed" then
          record.waiters[#record.waiters + 1] = done
        else done(record.status, record.reason) end
      end)
    end
    if record.status == "denied" then release(record) end
    return record.status, record.reason
  end
  function adapter.inspect(handle)
    local record = records[handle]
    if not record then return nil end
    refresh(record)
    return view(record)
  end
  function adapter.status(handle)
    local record = records[handle]
    if not record then return nil end
    refresh(record)
    pump()
    return record.status, record.reason
  end
  function adapter.reopen(handle)
    local record = records[handle]
    if not record or record.status == "consumed" then return false end
    local ok, binding = pcall(options.describe, handle)
    if not ok or type(binding) ~= "table" then return false end
    local metadata = receipt_binding(copy(binding))
    if not vim.deep_equal(metadata, record.binding) or family(binding, record.assessment) ~= record.family then return false end
    local valid, reason = current({ handle = handle, binding = binding, expires = record.expires })
    if not valid then terminal(record, "invalidated", reason); return false end
    if not record.family then return false end
    local count = 0
    for _, pending in pairs(records) do
      refresh(pending)
      if pending.status == "queued" or pending.status == "displayed" or pending.status == "approved" then count = count + 1 end
    end
    if count >= limit then return false end
    if record.status == "queued" or record.status == "displayed" or record.status == "approved" then return false end
    rejected[record.family] = nil
    record.handle, record.binding = handle, copy(binding)
    record.status = "queued"
    queue[#queue + 1] = record
    pump()
    return true
  end
  function adapter.invalidate(handle, reason)
    local record = records[handle]
    if record and record.status ~= "consumed" then terminal(record, "invalidated", reason or "cancelled") end
    pump()
  end
  function adapter.invalidate_session(session, reason)
    for _, record in pairs(records) do
      if record.binding.session_id == session and record.status ~= "consumed" then
        terminal(record, "invalidated", reason or "session invalidated")
      end
    end
    pump()
  end
  function adapter.retire_session(session, reason)
    adapter.invalidate_session(session, reason or "session retired")
    for handle, record in pairs(records) do
      if record.binding.session_id == session then records[handle] = nil end
    end
    for key, decision in pairs(rejected) do if decision.session_id == session then rejected[key] = nil end end
  end
  function adapter.consume(handle)
    local record = records[handle]
    if not record then return false, "unknown consent" end
    refresh(record)
    if record.status ~= "approved" then return false, record.reason or record.status end
    terminal(record, "consumed", "executing once")
    return true
  end
  return adapter
end

return M
