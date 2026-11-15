local M = {}
local registry = require("straps.registry")
local state = require("straps.state")
local pins, failures, retrievals = {}, {}, {}

vim.api.nvim_create_autocmd("BufWipeout", {
  callback = function(event) failures[event.buf] = nil end,
})

local function settings(bufnr)
  local cfg = require("straps").config.context_management or {}
  local override = bufnr and vim.b[bufnr].straps_context_management
  return type(override) == "table" and vim.tbl_deep_extend("force", cfg, override) or cfg
end

function M.enabled(bufnr)
  return settings(bufnr).enabled == true
end

local function cancelled(ctx)
  return ctx and ctx.cancelled and ctx.cancelled()
end

local function lines(bufnr)
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

local function fingerprint(value)
  return vim.fn.sha256(vim.json.encode(value))
end

function M.has_pending(bufnr)
  for _, block in ipairs(state.list_blocks(bufnr)) do
    if block.kind == "tool_result" and block.attrs.context_pending == true then return true end
  end
  return false
end

local function held(bufnr)
  return (retrievals[bufnr] or 0) > 0 or M.has_pending(bufnr)
end

function M.protect(bufnr)
  retrievals[bufnr] = (retrievals[bufnr] or 0) + 1
end

function M.release(bufnr)
  retrievals[bufnr] = nil
end

function M.consumed(bufnr)
  M.release(bufnr)
end

function M.pin(bufnr, first, last)
  local blocks, original = state.list_blocks(bufnr), lines(bufnr)
  assert(type(first) == "number" and type(last) == "number" and first >= 1 and last >= first
    and last < math.huge and first % 1 == 0 and last % 1 == 0 and blocks[last], "invalid pin range")
  local endpoint = blocks[last].last_lnum
  pins[bufnr] = pins[bufnr] or {}
  pins[bufnr][#pins[bufnr] + 1] = { first = first, last = last, prefix = vim.list_slice(original, 1, endpoint),
    endpoint = endpoint, final = last == #blocks }
end

function M.unpin(bufnr)
  pins[bufnr] = nil
end

local function positive(value)
  return type(value) == "number" and value > 0 and value < math.huge and value or nil
end

function M.retrieval_limit(bufnr)
  if held(bufnr) then return nil, "consume the protected retrieval before retrieving again" end
  if not M.enabled(bufnr) then return nil, "context management is disabled" end
  local budget = vim.b[bufnr].straps_context_budget
  if type(budget) ~= "table" or not positive(budget.limit) or type(budget.tokens) ~= "number"
    or budget.tokens > budget.limit then return nil, "no continuation allowance has been established" end
  local cfg = settings(bufnr)
  local reserve = positive(cfg.reserve_tokens) or 4096
  local bytes = math.floor(math.max(0, reserve - 128) * (positive(cfg.bytes_per_token) or 3)
    / (positive(cfg.safety_margin) or 1.3) / 6)
  if bytes < 128 then return nil, "retrieval reserve is too small" end
  return bytes
end

function M.account(prepared, ctx)
  local cfg = settings(ctx and ctx.bufnr)
  local entry = prepared.model_entry or {}
  local input_only = prepared.provider == "anthropic"
  local input_limit = positive(cfg.input_limit) or positive(entry.input_limit) or (input_only and positive(entry.context))
  local combined = positive(cfg.context_limit) or positive(entry.context_limit) or (not input_only and positive(entry.context))
  local reserve = positive(prepared.output_reserve) or positive(cfg.output_reserve)
  if combined then
    assert(reserve, "context management: combined context limit requires an explicit output reservation for this route")
    input_limit = math.min(input_limit or math.huge, combined - reserve)
  end
  assert(input_limit and input_limit > 0, "context management: unknown input allowance; configure input_limit or context_limit")
  if not (ctx and ctx.bufnr and held(ctx.bufnr)) then
    input_limit = input_limit - (positive(cfg.reserve_tokens) or 4096)
  end
  assert(input_limit > 0, "context management: retrieval reserve exhausts input allowance")
  local body = state.utf8_scrub(vim.json.encode(prepared.body))
  local margin = positive(cfg.safety_margin) or 1.3
  assert(margin >= 1, "context management: safety_margin must be at least 1")
  local count = math.ceil(#body / (positive(cfg.bytes_per_token) or 3) * margin) + 64
  local budget = { tokens = count, limit = input_limit, source = "wire-byte estimate", exact = false,
    safety_margin = margin, provider = prepared.provider, model = prepared.model, route = prepared.route,
    output_reserve = reserve, fingerprint = vim.fn.sha256(body),
    cache = { configured_retention = require("straps").config.cache_ttl, observed = "unknown", expiry = "unknown" } }
  if ctx and ctx.bufnr and cfg.enabled == true and not ctx.context_isolated and not ctx.context_summary then
    local observed = require("straps.context_calibration").estimate(ctx.bufnr, prepared,
      { bytes_per_token = positive(cfg.bytes_per_token) or 3, safety_margin = margin })
    if observed then
      for _, key in ipairs({ "tokens", "source", "exact", "observed_input", "delta_bytes", "calibration_identity" }) do
        budget[key] = observed[key]
      end
    end
  end
  return budget
end

function M.check(prepared, ctx)
  if not M.enabled(ctx and ctx.bufnr) then return end
  local budget = registry.call("fn.context_budget", prepared, ctx)
  assert(type(budget) == "table" and positive(budget.limit) and type(budget.tokens) == "number"
    and budget.tokens >= 0, "context management: invalid budget result")
  if ctx and ctx.bufnr then vim.b[ctx.bufnr].straps_context_budget = budget end
  assert(budget.tokens <= budget.limit, ("context management: request estimate %d exceeds input allowance %d (%s)")
    :format(budget.tokens, budget.limit, tostring(budget.source)))
  return budget
end

local function builtin()
  local sources = require("straps.provider").context_sources or {}
  local cfg = require("straps").config
  local provider = require("straps.provider").resolve_provider(registry.active_scope(), cfg)
  local names = { "fn.provider", "fn.provider_" .. tostring(provider) }
  if provider ~= "openai" then names[#names + 1] = "fn.anthropic_messages" end
  for _, name in ipairs(names) do
    local entry = registry.get(name)
    if not entry or entry.source ~= sources[name] then return false end
  end
  return true
end

local function prepare(req, ctx, guard)
  if guard then guard() end
  local standard = builtin()
  if guard then guard() end
  if standard then
    local prepctx = setmetatable({ context_prepare = true }, { __index = ctx })
    return registry.call("fn.provider", vim.deepcopy(req), prepctx)
  end
  assert(positive(settings(ctx.bufnr).input_limit),
    "context management: custom provider requires an explicit conservative input_limit")
  return { body = req, provider = "custom", route = "custom", output_reserve = settings(ctx.bufnr).output_reserve }
end

local function count(req, ctx, guard)
  local prepared = prepare(req, ctx, guard)
  if guard then guard() end
  local result = registry.call("fn.context_budget", prepared, ctx)
  assert(type(result) == "table" and positive(result.limit) and type(result.tokens) == "number"
    and result.tokens >= 0, "context management: invalid budget result")
  return result
end

local function request(bufnr, tools, note)
  local parsed = state.parse(bufnr)
  local system = parsed.system
  if type(note) == "string" and note ~= "" then system = (system and system ~= "") and (system .. "\n\n" .. note) or note end
  return { system = system, messages = parsed.messages, tools = tools }
end

local function scratch_request(text, tools, note)
  local scratch = vim.api.nvim_create_buf(false, true)
  local ok, result = pcall(function()
    vim.api.nvim_buf_set_lines(scratch, 0, -1, false, text)
    return request(scratch, tools, note)
  end)
  vim.api.nvim_buf_delete(scratch, { force = true })
  if not ok then error(result, 0) end
  return result
end

local function complete(blocks, first, last)
  local open, seen = {}, {}
  for i = first, last do
    local b = blocks[i]
    if b.kind == "tool_use" then
      if next(open) == nil then seen = {} end
      local id = b.attrs and b.attrs.id
      if not id or not b.attrs.name or seen[id] then return false end
      local ok, value = pcall(vim.json.decode, b.text)
      if not ok or type(value) ~= "table" then return false end
      open[id], seen[id] = true, true
    elseif b.kind == "tool_result" then
      local id = b.attrs and b.attrs.id
      if not id or not open[id] then return false end
      open[id] = nil
    elseif b.kind == "user" and next(open) then
      return false
    end
  end
  return next(open) == nil
end

local function source_blocks(bufnr, original, exclude_tail)
  local blocks = vim.deepcopy(state.list_blocks(bufnr))
  if exclude_tail then table.remove(blocks) end
  for i, b in ipairs(blocks) do
    b.index = i
    local content = vim.list_slice(original, b.first_lnum, b.last_lnum)
    if b.kind == "assistant" or b.kind == "user" or b.kind == "system" then
      local suffix = original[b.marker_lnum]:match("^%%%%%[straps:[a-z_]+%]%%%%(.*)$")
      local inline = suffix and suffix:gsub("^ ", "", 1)
      if inline and inline ~= "" then table.insert(content, 1, inline) end
    end
    b.text = table.concat(content, "\n")
  end
  return blocks
end

local function cutoff(blocks, keep)
  local seen = 0
  for i = #blocks, 1, -1 do
    if blocks[i].kind == "assistant" then
      seen = seen + 1
      if seen >= keep then return i - 1 end
    end
  end
  return 0
end

local function protected(bufnr, first, last)
  if held(bufnr) then return true end
  local original, blocks = lines(bufnr), state.list_blocks(bufnr)
  for _, pin in ipairs(pins[bufnr] or {}) do
    local block = blocks[pin.last]
    local boundary = block and (block.last_lnum == pin.endpoint or (pin.final and blocks[pin.last + 1]
      and block.last_lnum == pin.endpoint + 1 and original[pin.endpoint + 1] == ""))
    if not boundary or not vim.deep_equal(pin.prefix, vim.list_slice(original, 1, pin.endpoint))
      or (pin.first <= last and pin.last >= first) then return true end
  end
  return false
end

local function replacement_lines(text)
  local result = {}
  for _, line in ipairs(vim.split(text, "\n", { plain = true })) do result[#result + 1] = state.escape_line(line) end
  return result
end

local function render(original, replacements)
  local result = vim.deepcopy(original)
  for i = #replacements, 1, -1 do
    local item = replacements[i]
    for j = item.last, item.first, -1 do table.remove(result, j) end
    for j = #item.lines, 1, -1 do table.insert(result, item.first, item.lines[j]) end
  end
  return result
end

local function disk(path)
  if path == "" then return nil end
  local fd = vim.uv.fs_open(path, "r", 0)
  if not fd then
    local stat, err, code = vim.uv.fs_stat(path)
    if not stat and code == "ENOENT" then return false end
    error("context management: cannot open transcript persistence source: " .. tostring(err), 0)
  end
  local ok, data = pcall(function()
    local stat = assert(vim.uv.fs_fstat(fd))
    return assert(vim.uv.fs_read(fd, stat.size, 0))
  end)
  local closed, err = vim.uv.fs_close(fd)
  assert(ok and closed, "context management: cannot read transcript persistence source: " .. tostring(ok and err or data))
  return data
end

local check_saved_source
local transaction_faults = {}

function M.transaction_status(bufnr)
  return transaction_faults[bufnr]
end

local function fail_transaction(bufnr, status, err)
  transaction_faults[bufnr] = { status = status, error = tostring(err), terminal = true }
end

function M.persist_checked(bufnr, previous_disk)
  if vim.bo[bufnr].buftype ~= "" or vim.api.nvim_buf_get_name(bufnr) == "" then return true, "ephemeral" end
  local path = vim.api.nvim_buf_get_name(bufnr)
  local data, original = table.concat(lines(bufnr), "\n") .. "\n", lines(bufnr)
  local fd, directory, attempted
  local ok, err = pcall(function()
    check_saved_source(bufnr)
    assert(disk(path) == previous_disk, "transcript file changed during compaction")
    assert(vim.deep_equal(lines(bufnr), original), "live transcript changed before persistence")
    attempted = true
    vim.api.nvim_buf_call(bufnr, function() vim.cmd("silent noautocmd write") end)
    assert(vim.deep_equal(lines(bufnr), original), "live transcript changed during persistence")
    assert(disk(path) == data, "transcript write verification failed")
    fd = assert(vim.uv.fs_open(path, "r", 0))
    assert(vim.uv.fs_fsync(fd))
    assert(vim.uv.fs_close(fd))
    fd = nil
    directory = assert(vim.uv.fs_open(vim.fn.fnamemodify(path, ":h"), "r", 0))
    assert(vim.uv.fs_fsync(directory))
    assert(vim.uv.fs_close(directory))
    directory = nil
    assert(disk(path) == data, "transcript changed after persistence")
  end)
  if fd then pcall(vim.uv.fs_close, fd) end
  if directory then pcall(vim.uv.fs_close, directory) end
  if not ok then
    if attempted then fail_transaction(bufnr, "ambiguous", err) end
    return nil, tostring(err), attempted and "ambiguous" or "unchanged"
  end
  return true, "durable"
end

local function outcome(status, err, appended, persistence)
  return { status = status, error = err and tostring(err), terminal = status == "conflict" or status == "ambiguous",
    appended = appended == true, persistence = persistence }
end

local disk_conflicts = {}

vim.api.nvim_create_autocmd("BufWipeout", {
  callback = function(event)
    disk_conflicts[event.buf], transaction_faults[event.buf] = nil, nil
  end,
})

check_saved_source = function(bufnr)
  if vim.bo[bufnr].buftype ~= "" or vim.api.nvim_buf_get_name(bufnr) == "" then return end
  assert(not transaction_faults[bufnr], "transcript has an unresolved transaction failure")
  assert(not disk_conflicts[bufnr], "transcript has an unresolved external change")
  local autoread = vim.bo[bufnr].autoread
  vim.bo[bufnr].autoread = false
  local changed = vim.api.nvim_create_autocmd("FileChangedShell", {
    buffer = bufnr, callback = function()
      disk_conflicts[bufnr] = true
      vim.v.fcs_choice = ""
    end,
  })
  local ok, err = pcall(vim.cmd, "silent checktime " .. bufnr)
  vim.api.nvim_del_autocmd(changed)
  vim.bo[bufnr].autoread = autoread
  assert(ok, err)
  assert(not disk_conflicts[bufnr], "transcript changed outside the editor")
end

local function capture_source(bufnr)
  local ok, result = pcall(function()
    check_saved_source(bufnr)
    local path = vim.api.nvim_buf_get_name(bufnr)
    local previous_disk
    if vim.bo[bufnr].buftype == "" then previous_disk = disk(path) end
    return { bufnr = bufnr, path = path, buftype = vim.bo[bufnr].buftype, original = lines(bufnr), disk = previous_disk }
  end)
  if not ok then
    local status = disk_conflicts[bufnr] and "conflict" or "ambiguous"
    fail_transaction(bufnr, status, result)
    return nil, outcome(status, result)
  end
  return result
end

local function source_matches(source, expected)
  local ok, current = pcall(function()
    return vim.api.nvim_buf_get_name(source.bufnr) == source.path
      and vim.bo[source.bufnr].buftype == source.buftype
      and vim.deep_equal(lines(source.bufnr), expected)
      and (source.buftype ~= "" or disk(source.path) == source.disk)
  end)
  return ok and current, ok and nil or current
end

local function transaction(source, final, ctx, appended)
  local bufnr = source.bufnr
  local same, err = source_matches(source, source.original)
  if not same then return outcome(err and "ambiguous" or "conflict", err or "transcript changed before mutation") end
  local ok, stop = pcall(cancelled, ctx)
  same, err = source_matches(source, source.original)
  if not same then return outcome(err and "ambiguous" or "conflict", err or "transcript changed before mutation") end
  if not ok then return outcome("ambiguous", stop) end
  if stop then return outcome("error", "cancelled") end
  local mutated, mutation_err = pcall(vim.api.nvim_buf_set_lines, bufnr, 0, -1, false, final)
  if not mutated then
    same, err = source_matches(source, source.original)
    return outcome(same and "error" or "ambiguous", mutation_err)
  end
  local called, persisted, persist_err, persistence = pcall(M.persist_checked, bufnr, source.disk)
  if called and persisted then
    local checked, live = pcall(lines, bufnr)
    if not checked or not vim.deep_equal(live, final) then
      return outcome("conflict", "live transcript changed during persistence", appended)
    end
    local verified, saved = pcall(function()
      return source.buftype ~= "" or source.path == "" or disk(source.path) == table.concat(final, "\n") .. "\n"
    end)
    if not verified or not saved then return outcome("ambiguous", "cannot verify persisted transcript", appended) end
    return outcome("committed_live", nil, appended, persist_err)
  end
  if not called or persistence == "ambiguous" then
    return outcome("ambiguous", called and persist_err or persisted, appended)
  end
  same, err = source_matches(source, final)
  if not same then return outcome(err and "ambiguous" or "conflict", err or "transcript changed during failed persistence", appended) end
  local restored, restore_err = pcall(vim.api.nvim_buf_set_lines, bufnr, 0, -1, false, source.original)
  same, err = source_matches(source, source.original)
  if not restored or not same then return outcome("ambiguous", restore_err or err or "rollback could not be verified", appended) end
  return outcome("error", persist_err)
end

function M.append_result(bufnr, attrs, text, ctx)
  local source, err = capture_source(bufnr)
  if not source then return err end
  local ok, final = pcall(function()
    local marked = vim.deepcopy(attrs or {})
    marked.context_pending = true
    local result = vim.deepcopy(source.original)
    if #result == 1 and result[1] == "" then result = {} else result[#result + 1] = "" end
    result[#result + 1] = "%%[straps:tool_result]%% " .. vim.json.encode(marked)
    for _, line in ipairs(vim.split(text or "", "\n", { plain = true })) do result[#result + 1] = state.escape_line(line) end
    return result
  end)
  if not ok then return outcome("error", final) end
  local result = transaction(source, final, ctx, true)
  if result.status == "committed_live" then M.release(bufnr) end
  return result
end

local function pending_records(bufnr, original)
  local blocks, counts, records = state.list_blocks(bufnr), {}, {}
  for index, block in ipairs(blocks) do
    if block.kind == "tool_result" then
      local id = vim.json.encode(block.attrs.id or vim.NIL)
      counts[id] = (counts[id] or 0) + 1
      if block.attrs.context_pending == true then
        local last = block.last_lnum
        if index < #blocks and original[last] == "" then last = last - 1 end
        records[#records + 1] = { id = id, occurrence = counts[id], marker_lnum = block.marker_lnum,
          marker = original[block.marker_lnum], body = vim.list_slice(original, block.first_lnum, last),
          attrs = vim.deepcopy(block.attrs) }
      end
    end
  end
  return records, counts
end

function M.snapshot_pending(bufnr)
  local source, err = capture_source(bufnr)
  if not source then return nil, err end
  local ok, records, counts = pcall(pending_records, bufnr, source.original)
  if not ok then return nil, outcome("ambiguous", records) end
  source.pending, source.counts = records, counts
  return source
end

function M.consume_pending(capture, ctx)
  if type(capture) ~= "table" or type(capture.pending) ~= "table" then return outcome("conflict", "invalid pending capture") end
  local source, err = capture_source(capture.bufnr)
  if not source then return err end
  if source.path ~= capture.path or source.buftype ~= capture.buftype then return outcome("conflict", "transcript identity changed") end
  for index, line in ipairs(capture.original) do
    if source.original[index] ~= line then return outcome("conflict", "captured request transcript changed") end
  end
  if source.buftype == "" and source.path ~= "" and source.disk ~= capture.disk then
    local current = table.concat(source.original, "\n") .. "\n"
    local sent = table.concat(capture.original, "\n") .. "\n"
    if type(source.disk) ~= "string" or source.disk:sub(1, #sent) ~= sent or current:sub(1, #source.disk) ~= source.disk then
      return outcome("conflict", "persisted transcript diverged during response")
    end
  end
  local ok, records, counts = pcall(pending_records, source.bufnr, source.original)
  if not ok then return outcome("ambiguous", records) end
  local final = vim.deepcopy(source.original)
  for _, expected in ipairs(capture.pending) do
    local found
    for _, record in ipairs(records) do
      if record.id == expected.id and record.occurrence == expected.occurrence then found = record; break end
    end
    if not found or counts[expected.id] ~= capture.counts[expected.id] or found.marker ~= expected.marker
      or not vim.deep_equal(found.body, expected.body) then return outcome("conflict", "pending retrieval identity changed") end
    local attrs = vim.deepcopy(found.attrs)
    attrs.context_pending = nil
    final[found.marker_lnum] = "%%[straps:tool_result]%% " .. vim.json.encode(attrs)
  end
  if #capture.pending == 0 then return outcome("committed_live") end
  return transaction(source, final, ctx, false)
end

local function canonical(value)
  if type(value) ~= "table" then return value end
  local keys, result = vim.tbl_keys(value), {}
  table.sort(keys, function(a, b)
    if type(a) == type(b) then return a < b end
    return type(a) < type(b)
  end)
  for _, key in ipairs(keys) do result[#result + 1] = { key, canonical(value[key]) } end
  return result
end

local function resolution_keys(bufnr)
  local provider, cfg = require("straps.provider"), require("straps").config
  local keys = { provider = cfg.provider, buffer_provider = vim.b[bufnr].straps_provider,
    slots = provider.PROVIDERS, preferences = {}, effort = cfg.effort, efforts = cfg.efforts,
    buffer_effort = vim.b[bufnr].straps_effort, max_tokens = cfg.max_tokens,
    default_max_tokens = cfg.default_max_tokens, cache = cfg.cache, cache_ttl = cfg.cache_ttl }
  for _, slot in ipairs(provider.PROVIDERS) do
    keys[slot.model_key] = cfg[slot.model_key]
    keys[slot.models_key] = cfg[slot.models_key]
    keys[slot.buf_model_var] = vim.b[bufnr][slot.buf_model_var]
    keys[slot.name .. "_base_url"] = provider.base_url(slot.name, cfg)
  end
  for _, name in ipairs({ "fn.provider_pref", "fn.model_pref", "fn.provider", "fn.context_plan", "fn.compact",
    "fn.context_summarize", "fn.context_budget", "fn.provider_anthropic", "fn.provider_openai", "fn.provider_llamacpp",
    "fn.anthropic_messages", "fn.openai_codex_request", "fn.openai_api_key", "fn.anthropic_api_key",
    "fn.llamacpp_api_key", "fn.api_key_store" }) do
    local entry = registry.get(name)
    keys.preferences[name] = entry and entry.source
  end
  return vim.deepcopy(keys)
end

local function effective_identity(bufnr, guard)
  local provider = require("straps.provider")
  local cfg = require("straps").config
  local before = resolution_keys(bufnr)
  if guard then guard() end
  local route = provider.resolve_provider(bufnr, cfg)
  if guard then guard() end
  local model = provider.resolve_model(route, bufnr, cfg)
  if guard then guard() end
  local entry = provider.model_entry(route, model, cfg)
  if guard then guard() end
  assert(cfg == require("straps").config and vim.deep_equal(before, resolution_keys(bufnr)),
    "context management: provider resolution changed")
  if provider.is_provider(route) then
    local list = cfg[provider.provider_slot(route).models_key]
    for _, item in ipairs(type(list) == "table" and list or {}) do
      if type(item) == "table" and item.id == model then entry = item; break end
    end
  end
  local definitions = {}
  for _, name in ipairs({ "fn.provider", "fn.context_plan", "fn.compact", "fn.context_summarize", "fn.context_budget", "fn.provider_" .. tostring(route),
    "fn.anthropic_messages", "fn.openai_codex_request", "fn.openai_api_key", "fn.anthropic_api_key",
    "fn.llamacpp_api_key", "fn.api_key_store" }) do
    local entry = registry.get(name)
    definitions[name] = entry and entry.source
  end
  local management = vim.deepcopy(settings(bufnr))
  management.retry = nil
  return fingerprint(canonical({ route, model, entry, cfg.effort, cfg.efforts,
    cfg.max_tokens, cfg.default_max_tokens, provider.base_url(route, cfg), cfg.cache, cfg.cache_ttl,
    vim.b[bufnr].straps_effort, management, definitions }))
end

local function unchanged(bufnr, original, cfg, candidate)
  if not vim.api.nvim_buf_is_valid(bufnr)
    or not vim.deep_equal(lines(bufnr), original) or not vim.deep_equal(settings(bufnr), cfg) then return false end
  for _, proposal in ipairs(candidate.proposals) do
    if protected(bufnr, proposal.first_block, proposal.last_block, candidate.snapshot) then return false end
  end
  return true
end

local function eligible(bufnr, cfg, original, blocks, mode)
  local result = {}
  local last = cutoff(blocks, math.max(1, cfg.keep_turns or 2))
  if last < 1 or not complete(blocks, 1, #blocks) then return result end
  local function add(first, final)
    local sources = {}
    for i = first, final do
      sources[#sources + 1] = { kind = blocks[i].kind, text = blocks[i].text,
        attrs = vim.deepcopy(blocks[i].attrs), first_block = i, last_block = i }
    end
    result[#result + 1] = { index = #result + 1, first_block = first, last_block = final, mode = mode, sources = sources }
  end
  if mode == "mechanical" then
    for i = 1, last do
      local b = blocks[i]
      if b.kind == "tool_result" and not b.text:find("[straps-context:", 1, true) and not protected(bufnr, i, i) then add(i, i) end
    end
  elseif mode == "summary" then
    local first = 1
    while first <= last do
      local b = blocks[first]
      if b.kind == "assistant" or b.kind == "tool_use" or b.kind == "tool_result" then
        local final = first
        while final < last and blocks[final + 1].kind ~= "user" and blocks[final + 1].kind ~= "system" do final = final + 1 end
        if complete(blocks, first, final) and not protected(bufnr, first, final) then add(first, final) end
        first = final + 1
      else
        first = first + 1
      end
    end
  else
    error("context management: select mode mechanical or summary", 0)
  end
  return result
end

local function selections(policy, input, ctx, validate)
  local detached = vim.deepcopy(input)
  local result = policy(detached, ctx)
  validate()
  assert(vim.deep_equal(detached, input), "context management: policy mutated input")
  assert(type(result) == "table" and getmetatable(result) == nil and result.version == 1
    and result.snapshot_id == input.snapshot_id and type(result.selections) == "table"
    and getmetatable(result.selections) == nil, "context management: invalid policy result")
  local selected, previous, count = {}, 0, 0
  for key in pairs(result.selections) do
    assert(type(key) == "number" and key >= 1 and key % 1 == 0, "context management: invalid policy selections")
    count = count + 1
  end
  for i = 1, count do
    local index = result.selections[i]
    assert(type(index) == "number" and index % 1 == 0 and index > previous and input.eligible[index],
      "context management: invalid policy selection")
    local item = input.eligible[index]
    assert(item.mode == input.mode and (#selected == 0 or selected[#selected].last_block < item.first_block),
      "context management: overlapping policy selection")
    selected[#selected + 1], previous = item, index
  end
  return selected
end

local function propose(bufnr, ctx, cfg, original, blocks, snapshot, identity, before, tools, note, reason, validate, allowance, guard)
  local policy = assert(registry.bind("fn.context_plan"), "context management: missing policy")
  allowance = allowance or {}
  local function build(mode)
    local proposals, replacements = {}, {}
    local input = { version = 1, snapshot_id = snapshot, reason = reason or "explicit", mode = mode,
      before = { tokens = before.tokens, limit = before.limit, source = before.source, exact = before.exact },
      target_tokens = before.limit * (cfg.target or 0.7), eligible = eligible(bufnr, cfg, original, blocks, mode) }
    local selected = selections(policy, input, ctx, validate)
    assert(vim.deep_equal(input.eligible, eligible(bufnr, cfg, original, blocks, mode)),
      "context management: source protection changed")
    local function validate_selected()
      validate()
      for _, interval in ipairs(selected) do
        assert(not protected(bufnr, interval.first_block, interval.last_block), "context management: source protection changed")
      end
    end
    local attempt, attempted_keys = nil, {}
    for _, item in ipairs(selected) do
      validate_selected()
      local first, final, sources = item.first_block, item.last_block, item.sources
      local candidate, format
      if mode == "summary" then
        local content = {}
        for _, source in ipairs(sources) do content[#content + 1] = { source.kind, source.text, canonical(source.attrs) } end
        local key = fingerprint({ content, identity })
        local failed = failures[bufnr] or { keys = {}, count = 0 }
        failures[bufnr] = failed
        if failed.keys[key] and cfg.retry ~= true then
          if type(failed.keys[key]) == "string" then return nil, nil, failed.keys[key], "summary attempt suppressed" end
        else
          if not failed.keys[key] then
            assert(failed.count < 256, "context management: summary attempt history is full; wipe and reopen the buffer to reset")
            failed.count = failed.count + 1
          end
          failed.keys[key] = true
          attempted_keys[#attempted_keys + 1] = key
          if not attempt then
            local opts = vim.deepcopy(cfg.summary or {})
            opts.config_id = identity
            opts.validate = function() allowance.validate() end
            allowance.validate = validate_selected
            local err, failure
            attempt = allowance.attempt
            if not attempt then
              attempt, err, failure = require("straps.context_summary").new_attempt(opts, ctx)
              allowance.attempt = attempt
            end
            validate_selected()
            if not attempt then return nil, nil, failure and failure.kind or "internal", err end
          end
          allowance.validate = validate_selected
          local err, failure
          candidate, err, failure = attempt.generate(vim.deepcopy(sources))
          validate_selected()
          if not candidate then
            local kind = failure and failure.kind or "internal"
            failed.keys[key] = kind
            return nil, nil, kind, err
          end
          format = function(receipt)
            local out = { "%%[straps:assistant]%%" }
            vim.list_extend(out, replacement_lines("Assistant summary of archived assistant claims and tool evidence " .. receipt .. "\n" .. candidate.summary))
            return out
          end
        end
      else
        local b, name = blocks[first]
        for j = first - 1, 1, -1 do
          if blocks[j].kind == "tool_use" and blocks[j].attrs.id == b.attrs.id then name = blocks[j].attrs.name; break end
        end
        format = function(receipt)
          return { original[b.marker_lnum], receipt .. " archived tool evidence; tool=" .. tostring(name) .. "; bytes=" .. #b.text }
        end
      end
      if format then
        proposals[#proposals + 1] = { sources = sources, summary = candidate and candidate.summary,
          candidate = candidate, first_block = first, last_block = final }
        replacements[#replacements + 1] = { first = blocks[first].marker_lnum, last = blocks[final].last_lnum,
          lines = format("[straps-context:" .. string.rep("0", 64) .. "]"), format = format, proposal = #proposals }
        if mode == "summary" then
          local after = count(scratch_request(render(original, replacements), tools, note), ctx, guard)
          validate_selected()
          if after.tokens <= input.target_tokens and before.tokens - after.tokens >= (cfg.minimum_savings or 128) then
            return proposals, replacements
          end
        end
      end
    end
    if mode == "summary" and #proposals > 0 then
      local after = count(scratch_request(render(original, replacements), tools, note), ctx, guard)
      validate_selected()
      if after.tokens <= input.target_tokens or before.tokens - after.tokens < (cfg.minimum_savings or 128) then
        if cfg.fallback ~= "mechanical" or after.tokens <= input.target_tokens then return proposals, replacements end
      end
      if cfg.fallback == "mechanical" then
        for _, key in ipairs(attempted_keys) do failures[bufnr].keys[key] = "fit" end
      end
      return nil, nil, "fit", "protected content prevents compaction target"
    end
    return proposals, replacements
  end
  local proposals, replacements, kind, err = build(cfg.mode)
  if not proposals and cfg.mode == "summary" and cfg.fallback == "mechanical"
    and (kind == "generation" or kind == "budget" or kind == "fit") then
    validate()
    proposals, replacements = build("mechanical")
  end
  assert(proposals, "context management: " .. tostring(err))
  return proposals, replacements
end

local function archive_node(bufnr, candidate)
  local stored = {}
  for _, node in ipairs(candidate.children or {}) do
    local sources, children = {}, {}
    for _, record in ipairs(node.records or {}) do
      sources[#sources + 1] = vim.deepcopy(record)
      if stored[record.ref] then children[#children + 1] = stored[record.ref] end
    end
    local id, err = require("straps.context_archive").create(bufnr,
      { sources = sources, summary = node.summary, children = children, depth = node.depth,
        original_ranges = node.original_ranges, records = node.records, refs = node.refs })
    assert(id, "context management: archive creation failed: " .. tostring(err))
    stored[node.id] = id
  end
  local children = {}
  for _, node in ipairs(candidate.children or {}) do children[#children + 1] = stored[node.id] end
  local included, blocks = {}, state.list_blocks(bufnr)
  for _, source in ipairs(candidate.sources or {}) do
    local block = blocks[source.first_block]
    assert(block and source.last_block == source.first_block and block.kind == source.kind,
      "context management: invalid archive source interval")
    local first = vim.api.nvim_buf_get_lines(bufnr, block.first_lnum - 1, block.first_lnum, false)[1] or ""
    local ref
    if block.kind == "tool_result" then
      ref = first:match("^%[straps%-context:([^%]]+)%] archived tool evidence; tool=.-; bytes=%d+$")
    elseif block.kind == "assistant" then
      ref = first:match("^Assistant summary of archived assistant claims and tool evidence %[straps%-context:([^%]]+)%]$")
    end
    if ref and not included[ref] then
      local record, err = require("straps.context_archive").get(bufnr, ref)
      assert(record, "context management: unresolved inherited archive: " .. tostring(err))
      children[#children + 1], included[ref] = ref, true
    end
  end
  local id, err = require("straps.context_archive").create(bufnr,
    { sources = candidate.sources, summary = candidate.summary, children = children, depth = candidate.depth })
  assert(id, "context management: archive creation failed: " .. tostring(err))
  return id
end

local candidates = setmetatable({}, { __mode = "k" })

local function metrics(bufnr, status, reason, candidate, before, after, ids)
  local proposals = candidate and candidate.proposals or {}
  local replacements = candidate and candidate.replacements or {}
  vim.b[bufnr].straps_context_compaction = { status = status, reason = tostring(reason), before = before, after = after,
    archives = ids or {}, first_block = proposals[1] and proposals[1].first_block,
    last_block = proposals[#proposals] and proposals[#proposals].last_block,
    earliest_line = replacements[1] and replacements[1].first }
end

local function preview_candidate(bufnr, ctx, opts, internal)
    local candidate, before
    assert(type(ctx) == "table" and (ctx.bufnr == nil or ctx.bufnr == bufnr), "context management: context buffer mismatch")
    local source, err = capture_source(bufnr)
    assert(source, "context management: " .. tostring(err and err.error))
    local cfg = vim.deepcopy(settings(bufnr))
    local saved_pins, saved_held = vim.deepcopy(pins[bufnr]), held(bufnr)
    local tools, note = vim.deepcopy(opts.tools), vim.deepcopy(opts.note)
    local saved_configuration = resolution_keys(bufnr)
    local identity
    local original = source.original
    candidate = { original = original, snapshot = fingerprint(original), config = cfg, proposals = {}, replacements = {} }
    local function guard()
      assert(ctx.bufnr == nil or ctx.bufnr == bufnr, "context management: context buffer mismatch")
      assert(vim.deep_equal(saved_configuration, resolution_keys(bufnr)), "context management: provider configuration changed")
      assert(vim.deep_equal(tools, opts.tools) and vim.deep_equal(note, opts.note), "context management: request inputs changed")
      assert(vim.deep_equal(pins[bufnr], saved_pins) and held(bufnr) == saved_held,
        "context management: protection changed")
      assert(unchanged(bufnr, original, cfg, candidate), "context management: source, protection or configuration changed")
      assert(source_matches(source, original), "context management: persistence source changed")
    end
    local function validate()
      guard()
      local stop = cancelled(ctx)
      guard()
      local current_identity = effective_identity(bufnr, guard)
      assert(not stop, "context management: cancelled")
      assert(identity == current_identity, "context management: provider configuration changed")
      guard()
    end
    identity = effective_identity(bufnr, guard)
    validate()
    if M.enabled(bufnr) then before = count(request(bufnr, tools, note), ctx, guard) end
    validate()
    if cfg.mode == "summary" and opts.generate ~= true then
      candidate.needs_generation = true
    else
      candidate.proposals, candidate.replacements = propose(bufnr, ctx, cfg, original, source_blocks(bufnr, original, internal and internal.exclude_tail),
        candidate.snapshot, identity, before or { tokens = 0, limit = math.huge }, tools, note, opts.reason, validate, internal and internal.allowance, guard)
    end
    candidate.lines = render(original, candidate.replacements)
    validate()
    local report = vim.deepcopy(candidate)
    for _, replacement in ipairs(report.replacements) do replacement.format = nil end
    candidates[report] = { candidate = candidate, report = vim.deepcopy(report), ctx = ctx, bufnr = bufnr,
      source = source, identity = identity, configuration = saved_configuration, tools = tools, note = note }
    metrics(bufnr, "preview", candidate.needs_generation and "needs generation" or "candidate prepared", candidate, before)
    return report
end

function M.preview(bufnr, ctx, opts)
  local ok, result = pcall(preview_candidate, bufnr, ctx, opts or {})
  if not ok then
    metrics(bufnr, "refused", result)
    error(result, 0)
  end
  return result
end

function M.apply(bufnr, ctx, report, tools, note)
  local captured = type(report) == "table" and candidates[report] or nil
  if type(report) == "table" then candidates[report] = nil end
  local candidate = captured and captured.candidate
  local before, final_budget, ids = nil, nil, {}
  local ok, result = pcall(function()
    assert(captured, "context management: fabricated or used preview")
    assert(captured.bufnr == bufnr and captured.ctx == ctx and (ctx.bufnr == nil or ctx.bufnr == bufnr), "context management: preview context mismatch")
    assert(vim.deep_equal(report, captured.report), "context management: modified preview")
    assert(not candidate.needs_generation, "context management: preview requires generation")
    if tools == nil then tools = vim.deepcopy(captured.tools) end
    if note == nil then note = vim.deepcopy(captured.note) end
    local function guard()
      assert(ctx.bufnr == nil or ctx.bufnr == bufnr, "context management: context buffer mismatch")
      assert(vim.deep_equal(captured.configuration, resolution_keys(bufnr)), "context management: provider configuration changed")
      assert(vim.deep_equal(report, captured.report), "context management: modified preview")
      assert(M.enabled(bufnr), "context management: disabled")
      assert(vim.deep_equal(tools, captured.tools) and vim.deep_equal(note, captured.note), "context management: request inputs changed")
      assert(unchanged(bufnr, candidate.original, candidate.config, candidate),
        "context management: source, protection or configuration changed")
      assert(source_matches(captured.source, candidate.original), "context management: persistence source changed")
    end
    local function validate()
      guard()
      local stop = cancelled(ctx)
      guard()
      local current_identity = effective_identity(bufnr, guard)
      assert(not stop, "context management: cancelled")
      assert(captured.identity == current_identity, "context management: provider configuration changed")
      guard()
    end
    validate()
    local req = request(bufnr, tools, note)
    before = count(req, ctx, guard)
    local proposed = scratch_request(candidate.lines, tools, note)
    local after = count(proposed, ctx, guard)
    validate()
    if #candidate.replacements == 0 or before.tokens - after.tokens < (candidate.config.minimum_savings or 128) then
      assert(not candidate.require_reduction, "context management: overflow requires sufficient reduction")
      assert(before.tokens <= before.limit, "context management: compaction cannot recover sufficient input allowance")
      metrics(bufnr, "refused", #candidate.replacements == 0 and "no eligible replacement" or "insufficient savings", candidate, before, after)
      return req
    end
    assert(after.tokens <= after.limit, "context management: compacted request still exceeds input allowance")
    assert(after.tokens <= after.limit * (candidate.config.target or 0.7), "context management: protected content prevents compaction target")
    for i, proposal in ipairs(candidate.proposals) do
      local record = proposal.candidate or proposal
      if record.children then
        ids[i] = archive_node(bufnr, record)
      else
        local id, err = require("straps.context_archive").create(bufnr, proposal)
        assert(id, "context management: archive creation failed: " .. tostring(err))
        ids[i] = id
      end
    end
    validate()
    for _, replacement in ipairs(candidate.replacements) do
      replacement.lines = replacement.format("[straps-context:" .. ids[replacement.proposal] .. "]")
    end
    local final = render(candidate.original, candidate.replacements)
    local final_req = scratch_request(final, tools, note)
    final_budget = count(final_req, ctx, guard)
    assert(final_budget.tokens <= final_budget.limit, "context management: archived request exceeds input allowance")
    validate()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, final)
    local persisted, saved, err, persistence = pcall(M.persist_checked, bufnr, captured.source.disk)
    if not persisted or not saved then
      local restored, restore_err = pcall(vim.api.nvim_buf_set_lines, bufnr, 0, -1, false, candidate.original)
      local reason = persisted and err or saved
      local ambiguous = not persisted or persistence == "ambiguous"
      if ambiguous or not restored or disk_conflicts[bufnr] then
        fail_transaction(bufnr, disk_conflicts[bufnr] and "conflict" or "ambiguous", reason)
      end
      error("context management: transcript persistence failed; "
        .. (restored and "live transcript restored" or "live rollback failed: " .. tostring(restore_err))
        .. (ambiguous and "; disk outcome ambiguous" or "; disk unchanged") .. ": " .. tostring(reason), 0)
    end
    if not vim.deep_equal(lines(bufnr), final) then
      fail_transaction(bufnr, "conflict", "live transcript changed during persistence")
      error("context management: live transcript changed during persistence", 0)
    end
    metrics(bufnr, "applied", "explicit apply", candidate, before, final_budget, ids)
    vim.b[bufnr].straps_context_budget = final_budget
    return final_req
  end)
  if not ok then
    if vim.api.nvim_buf_is_valid(bufnr) then metrics(bufnr, "refused", result, candidate, before, final_budget, ids) end
    error(result, 0)
  end
  return result
end

local recoveries = setmetatable({}, { __mode = "k" })

function M.capture_recovery(bufnr, ctx, tools, note, allowance)
  assert(type(ctx) == "table" and (ctx.bufnr == nil or ctx.bufnr == bufnr), "context management: context buffer mismatch")
  local source, err = capture_source(bufnr)
  assert(source, "context management: " .. tostring(err and err.error))
  local saved = { source = source, ctx = ctx, tools = vim.deepcopy(tools), note = vim.deepcopy(note),
    config = vim.deepcopy(settings(bufnr)), configuration = resolution_keys(bufnr), pins = vim.deepcopy(pins[bufnr]), held = held(bufnr), allowance = allowance }
  local function guard()
    assert(ctx.bufnr == nil or ctx.bufnr == bufnr, "context management: context buffer mismatch")
    assert(vim.deep_equal(saved.configuration, resolution_keys(bufnr)), "context management: provider configuration changed")
    assert(M.enabled(bufnr) and vim.deep_equal(settings(bufnr), saved.config), "context management: recovery configuration changed")
    assert(vim.deep_equal(pins[bufnr], saved.pins) and held(bufnr) == saved.held, "context management: recovery protection changed")
    assert(vim.deep_equal(tools, saved.tools) and vim.deep_equal(note, saved.note), "context management: request inputs changed")
    assert(source_matches(source, source.original), "context management: recovery source changed")
  end
  guard()
  local stop = cancelled(ctx)
  guard()
  saved.identity = effective_identity(bufnr, guard)
  assert(not stop, "context management: cancelled")
  guard()
  local token = {}
  recoveries[token] = saved
  return token
end

function M.recover(token, ctx)
  local saved = recoveries[token]
  recoveries[token] = nil
  assert(saved and saved.ctx == ctx, "context management: invalid recovery")
  local bufnr, original = saved.source.bufnr, saved.source.original
  local function guard()
    assert(ctx.bufnr == nil or ctx.bufnr == bufnr, "context management: context buffer mismatch")
    assert(vim.deep_equal(saved.configuration, resolution_keys(bufnr)), "context management: provider configuration changed")
    assert(M.enabled(bufnr) and vim.deep_equal(settings(bufnr), saved.config),
      "context management: recovery configuration changed")
    assert(vim.deep_equal(pins[bufnr], saved.pins) and held(bufnr) == saved.held,
      "context management: recovery protection changed")
    assert(source_matches(saved.source, original), "context management: recovery source changed")
    assert(original[#original] == "%%[straps:assistant]%%", "context management: recovery placeholder changed")
  end
  local function validate()
    guard()
    local stop = cancelled(ctx)
    guard()
    local identity = effective_identity(bufnr, guard)
    assert(not stop, "context management: cancelled")
    assert(identity == saved.identity, "context management: recovery configuration changed")
    guard()
  end
  validate()
  local report = preview_candidate(bufnr, ctx, { generate = true, tools = saved.tools, note = saved.note, reason = "overflow" },
    { exclude_tail = true, allowance = saved.allowance })
  validate()
  local candidate = candidates[report].candidate
  candidate.require_reduction = true
  local req = M.apply(bufnr, ctx, report, saved.tools, saved.note)
  assert(vim.b[bufnr].straps_context_compaction.status == "applied", "context management: overflow requires reduction")
  original = lines(bufnr)
  saved.source = { bufnr = bufnr, path = saved.source.path, buftype = saved.source.buftype,
    original = original, disk = saved.source.buftype == "" and disk(saved.source.path) or nil }
  local expected_request = vim.deepcopy(req)
  return req, function()
    validate()
    assert(vim.deep_equal(req, expected_request), "context management: retry request changed")
  end
end

function M.boundary(bufnr, ctx, run, tools, note, allowance)
  assert(type(ctx) == "table" and (ctx.bufnr == nil or ctx.bufnr == bufnr), "context management: context buffer mismatch")
  local source, err = capture_source(bufnr)
  assert(source, "context management: " .. tostring(err and err.error))
  local cfg = vim.deepcopy(settings(bufnr))
  local configuration = resolution_keys(bufnr)
  local saved_tools, saved_note = vim.deepcopy(tools), vim.deepcopy(note)
  local saved_pins, saved_held = vim.deepcopy(pins[bufnr]), held(bufnr)
  local saved_context = ctx.bufnr
  local req = request(bufnr, tools, note)
  local expected_request = vim.deepcopy(req)
  local function guard()
    assert(ctx.bufnr == saved_context, "context management: context buffer mismatch")
    assert(vim.deep_equal(configuration, resolution_keys(bufnr)), "context management: provider configuration changed")
    assert(vim.deep_equal(cfg, settings(bufnr)), "context management: configuration changed")
    assert(vim.deep_equal(tools, saved_tools) and vim.deep_equal(note, saved_note)
      and vim.deep_equal(req, expected_request), "context management: request inputs changed")
    assert(vim.deep_equal(pins[bufnr], saved_pins) and held(bufnr) == saved_held, "context management: protection changed")
    assert(source_matches(source, source.original), "context management: boundary source changed")
  end
  guard()
  local stop = cancelled(ctx)
  guard()
  assert(not stop, "context management: cancelled")
  local before = count(req, ctx, guard)
  guard()
  vim.b[bufnr].straps_context_budget = before
  if held(bufnr) then
    metrics(bufnr, "refused", "protected retrieval", nil, before)
    assert(before.tokens <= before.limit, "context management: protected retrieval exceeds continuation allowance")
    return req
  end
  local now = vim.uv.hrtime() / 1e9
  local pressure = before.tokens > before.limit * (cfg.trigger or 0.85)
  local previous_request = vim.b[bufnr].straps_context_last_request
  local idle = cfg.idle_compaction == true and type(previous_request) == "number"
    and now - previous_request >= (cfg.idle_seconds or 300)
  vim.b[bufnr].straps_context_last_request = now
  if not pressure and not idle then
    metrics(bufnr, "unchanged", "below trigger", nil, before)
    return req
  end
  local report = preview_candidate(bufnr, ctx, { generate = true, tools = tools, note = note, reason = pressure and "pressure" or "idle" },
    { allowance = allowance })
  local final = M.apply(bufnr, ctx, report, tools, note)
  local recorded = vim.b[bufnr].straps_context_compaction
  if recorded.status == "applied" then
    recorded.reason = pressure and "pressure" or "idle"
    vim.b[bufnr].straps_context_compaction = recorded
  end
  return final
end
function M.summarize(req, ctx)
  assert(type(req) == "table" and type(req.sources) == "table", "context summary: missing sources")
  local input = { system = req.system,
    messages = { { role = "user", content = { { type = "text", text = vim.json.encode(req.sources) } } } },
    tools = {}, context_max_output = req.max_output_tokens }
  assert(positive(input.context_max_output), "context summary: missing output limit")
  local isolated = setmetatable({ context_isolated = true, emit = function() end }, { __index = ctx })
  local budget = count(input, isolated)
  assert(budget.tokens <= budget.limit, "context summary: provider input allowance exceeded")
  local prepared = prepare(input, isolated)
  assert(prepared.route ~= "codex", "context summary: Codex output-cap support has not been established for summary generation")
  local response = registry.call("fn.provider", input, isolated)
  assert(not cancelled(ctx), "context summary: cancelled")
  assert(type(response) == "table" and response.complete ~= false
    and (response.stop_reason == "end_turn" or response.stop_reason == "stop"),
    "context summary: incomplete response")
  local parts = {}
  for _, part in ipairs(response.content or {}) do
    assert(part.type == "text", "context summary: tool or non-text response refused")
    parts[#parts + 1] = part.text or ""
  end
  local decoded = vim.json.decode(table.concat(parts, ""))
  assert(type(decoded) == "table", "context summary: invalid structured response")
  decoded.stop_reason, decoded.usage = response.stop_reason, response.usage
  return decoded
end

return M
