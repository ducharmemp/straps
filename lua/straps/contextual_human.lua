local M = {}
local consumers, installed, deliveries = {}, false, {}

function M.attached(surface)
  return consumers[surface] ~= nil
end

function M.attach(surface, consumer)
  assert(not consumers[surface] and (not installed or require("straps.registry").trusted_setup_allowed()), "human UI capture sealed")
  assert(type(consumer) == "function", "human UI consumer required")
  consumers[surface] = consumer
  if installed then consumer(assert(deliveries[surface], "unknown human UI surface")) end
end

function M.install(adapter, options)
  local registry = require("straps.registry")
  assert(not installed and registry.trusted_setup_allowed(), "human setup sealed")
  options = options or {}
  local receipts = assert(options.receipts, "prompt receipts required")
  local run_human = assert(options.run_human, "human operation runner required")
  local state, loop = require("straps.state"), require("straps.loop")
  local known, drafts, revisions = {}, {}, {}
  local callbacks = {}
  local function register(bufnr, resume)
    if known[bufnr] then return end
    if require("straps.authorization").snapshot(bufnr) == nil then adapter.create(bufnr, { legacy = resume == true }) end
    known[bufnr] = true
  end
  local function submit(bufnr, text, enqueue)
    register(bufnr, true)
    revisions[bufnr] = (revisions[bufnr] or 0) + 1
    return adapter.submit(bufnr, text, enqueue)
  end
  function callbacks.construct(opts)
    local bufnr, token = receipts.construct(opts or {}, nil)
    registry.ensure_scope(bufnr)
    assert(receipts.commit(token, bufnr), "prompt receipt commit failed")
    register(bufnr, false)
    return bufnr
  end
  function callbacks.draft(bufnr, instruction, data, displayed)
    drafts[bufnr] = { instruction = instruction or "", data = data or "", displayed = displayed,
      block_count = #state.list_blocks(bufnr) }
  end
  function callbacks.resume(bufnr) register(bufnr, true) end
  function callbacks.send(bufnr)
    local text = state.last_user_text(bufnr)
    local draft = drafts[bufnr]
    if draft and #state.list_blocks(bufnr) > draft.block_count then drafts[bufnr], draft = nil, nil end
    if draft and draft.data ~= "" and text ~= draft.displayed then
      vim.notify("straps: review edited piped data with :StrapsAdopt before sending", vim.log.levels.WARN)
      return false
    end
    if draft and text == draft.displayed then text = draft.instruction end
    if not text or not text:match("%S") then
      vim.notify("straps: adopt piped data with :StrapsAdopt before sending", vim.log.levels.WARN)
      return false
    end
    if not draft or draft.data == "" then drafts[bufnr] = nil end
    return submit(bufnr, text, function() loop.start(bufnr) end)
  end
  function callbacks.steer(bufnr, text, enqueue)
    return submit(bufnr, text, enqueue or function()
      if not loop.steer(bufnr, text) then state.add_to_trailing_user(bufnr, text) end
    end)
  end
  function callbacks.continue(bufnr, text)
    local function enqueue()
      state.append(bufnr, "user", nil, text ~= "" and text or "[straps] Continue where you left off.")
      loop.start(bufnr)
    end
    if text ~= "" then return submit(bufnr, text, enqueue) end
    register(bufnr, true)
    enqueue()
  end
  function callbacks.adopt(bufnr, text)
    register(bufnr, true)
    if not text or text == "" then
      text = state.last_user_text(bufnr)
      local draft = drafts[bufnr]
      if draft and #state.list_blocks(bufnr) > draft.block_count then drafts[bufnr], draft = nil, nil end
      if draft and text == draft.displayed and draft.data ~= "" then
        text = draft.instruction ~= "" and (draft.instruction .. "\n\n" .. draft.data) or draft.data
      end
    end
    if text and text:match("%S") then
      local selected = text
      local tick = vim.api.nvim_buf_get_changedtick(bufnr)
      local revision = revisions[bufnr]
      local authority = require("straps.authorization")
      local stamp = vim.deepcopy(authority.execution_stamp(bufnr))
      local display = vim.api.nvim_create_buf(false, true)
      vim.bo[display].buftype, vim.bo[display].bufhidden = "nofile", "wipe"
      vim.api.nvim_buf_set_lines(display, 0, -1, false, vim.list_extend({ "Adopt this exact instruction? y accepts; n rejects", "" }, vim.split(selected, "\n", { plain = true })))
      vim.bo[display].modifiable = false
      local used = false
      local function finish(accepted)
        if used then return end
        used = true
        pcall(vim.api.nvim_buf_delete, display, { force = true })
        if not accepted or not vim.api.nvim_buf_is_valid(bufnr) or vim.api.nvim_buf_get_changedtick(bufnr) ~= tick
            or revisions[bufnr] ~= revision or not vim.deep_equal(stamp, authority.execution_stamp(bufnr)) then return end
        drafts[bufnr] = nil
        submit(bufnr, selected, function() end)
      end
      vim.api.nvim_create_autocmd("BufWipeout", { buffer = display, once = true, callback = function() used = true end })
      vim.keymap.set("n", "y", function() finish(true) end, { buffer = display })
      vim.keymap.set("n", "n", function() finish(false) end, { buffer = display })
      vim.cmd("botright split")
      vim.api.nvim_win_set_buf(0, display)
      return true
    end
    return adapter.adopt(bufnr, function() end)
  end
  function callbacks.reset(bufnr)
    register(bufnr, true)
    drafts[bufnr] = nil
    revisions[bufnr] = (revisions[bufnr] or 0) + 1
    adapter.reset(bufnr)
  end
  function callbacks.authorization(bufnr, id, reopen)
    if type(id) ~= "number" then
      id = type(id) == "string" and id:match("^%d+$") and tonumber(id) or nil
    end
    if not id or id < 1 or id > 9007199254740991 or id % 1 ~= 0 then
      vim.notify("straps: authorization decision ID must be a positive integer", vim.log.levels.WARN)
      return false
    end
    register(bufnr, true)
    local record = adapter.inspect(id)
    if not record or record.binding.session ~= bufnr then
      vim.notify("straps: no authorization decision for this session", vim.log.levels.WARN)
      return false
    end
    if reopen then
      return run_human(bufnr, function(ctx)
        local ok, reason = adapter.reopen(id, ctx)
        if ok == false then vim.notify("straps: " .. tostring(reason or "authorization replay refused"), vim.log.levels.WARN) end
      end)
    end
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype, vim.bo[buf].bufhidden = "nofile", "wipe"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(vim.inspect(record), "\n", { plain = true }))
    vim.bo[buf].modifiable = false
    vim.cmd("botright split")
    vim.api.nvim_win_set_buf(0, buf)
    return true
  end
  require("straps.ui")
  require("straps.agents")
  installed = true
  local open = consumers.ui and consumers.ui(callbacks)
  local command_callbacks = vim.tbl_extend("force", {}, callbacks, { open = open })
  deliveries = { ui = callbacks, plugin = command_callbacks, agents = callbacks }
  if consumers.plugin then consumers.plugin(command_callbacks) end
  if consumers.agents then consumers.agents(callbacks) end
  local group = vim.api.nvim_create_augroup("StrapsContextualHuman", { clear = true })
  vim.api.nvim_create_autocmd("BufWipeout", { group = group, callback = function(ev)
    known[ev.buf], drafts[ev.buf], revisions[ev.buf] = nil, nil, nil
  end })
end

return M
