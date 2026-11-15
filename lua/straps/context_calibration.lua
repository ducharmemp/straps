local M = {}
local records = {}

vim.api.nvim_create_autocmd("BufWipeout", {
  callback = function(event) records[event.buf] = nil end,
})

local function finite(value)
  return type(value) == "number" and value >= 0 and value < math.huge
end

local function valid_buffer(bufnr)
  return type(bufnr) == "number" and vim.api.nvim_buf_is_valid(bufnr)
    and vim.bo[bufnr].buftype == "" and vim.b[bufnr].straps_session == true
end

local function sources(provider)
  local registry = require("straps.registry")
  local expected = require("straps.provider").context_sources or {}
  local names = { "fn.provider", "fn.provider_" .. provider }
  if provider ~= "openai" then names[#names + 1] = "fn.anthropic_messages" end
  local hashes = {}
  for _, name in ipairs(names) do
    local entry = registry.get(name)
    if not entry or entry.source ~= expected[name] then return nil end
    hashes[#hashes + 1] = vim.fn.sha256(entry.source)
  end
  for _, name in ipairs({ "fn." .. provider .. "_api_key", "fn.openai_codex_request" }) do
    if name ~= "fn.openai_codex_request" or provider == "openai" then
      local entry = registry.get(name)
      if entry then hashes[#hashes + 1] = vim.fn.sha256(entry.source) end
    end
  end
  return hashes
end

function M.identity(prepared, endpoint, account)
  local hashes = sources(prepared.provider)
  if not hashes then return nil end
  return vim.fn.sha256(vim.json.encode({ prepared.provider, prepared.model, prepared.route,
    vim.fn.sha256(endpoint), vim.fn.sha256(account or ""), hashes }))
end

local function snapshot(prepared, identity)
  if type(prepared) ~= "table" or type(prepared.body) ~= "table" or type(identity) ~= "string" then return nil end
  if prepared.provider ~= "openai" and prepared.provider ~= "anthropic" and prepared.provider ~= "llamacpp" then return nil end
  local body = vim.deepcopy(prepared.body)
  local key = prepared.provider == "openai" and "input" or "messages"
  local messages = body[key]
  if type(messages) ~= "table" or not vim.islist(messages) then return nil end
  body[key] = nil
  return { static = body, messages = vim.deepcopy(messages), identity = identity,
    bytes = #require("straps.state").utf8_scrub(vim.json.encode(prepared.body)) }
end

local function content_prefix(before, after)
  if vim.deep_equal(before, after) then return true end
  if type(before) == "string" and type(after) == "string" then return after:sub(1, #before) == before end
  if type(before) ~= "table" or type(after) ~= "table" or not vim.islist(before) or not vim.islist(after)
    or #after < #before then return false end
  for i, value in ipairs(before) do
    if not vim.deep_equal(value, after[i]) then
      if i ~= #before or type(value) ~= "table" or type(after[i]) ~= "table" then return false end
      local old, new = vim.deepcopy(value), vim.deepcopy(after[i])
      local a, b = old.text, new.text
      old.text, new.text = nil, nil
      if not vim.deep_equal(old, new) or type(a) ~= "string" or type(b) ~= "string" or b:sub(1, #a) ~= a then return false end
    end
  end
  return true
end

local function prefix(before, after)
  if #after < #before then return false end
  for i, message in ipairs(before) do
    if not vim.deep_equal(message, after[i]) then
      if i ~= #before or type(message) ~= "table" or type(after[i]) ~= "table" or message.role == nil then return false end
      local old, new = vim.deepcopy(message), vim.deepcopy(after[i])
      local a, b = old.content, new.content
      old.content, new.content = nil, nil
      if not vim.deep_equal(old, new) or not content_prefix(a, b) then return false end
    end
  end
  return true
end

function M.observe(bufnr, prepared, usage, identity)
  if not valid_buffer(bufnr) or not require("straps.context_management").enabled(bufnr) or type(usage) ~= "table"
    or not finite(usage.input_tokens) then return end
  local total = usage.input_tokens
  for _, key in ipairs({ "cache_read_input_tokens", "cache_creation_input_tokens" }) do
    if usage[key] ~= nil then
      if not finite(usage[key]) then return end
      total = total + usage[key]
    end
  end
  if not finite(total) then return end
  local record = snapshot(prepared, identity)
  if not record then return end
  record.observed = total
  records[bufnr] = record
end

function M.estimate(bufnr, prepared, opts)
  if not valid_buffer(bufnr) or not require("straps.context_management").enabled(bufnr) then return nil end
  local before = records[bufnr]
  local after = snapshot(prepared, prepared.calibration_identity)
  if not before or not after or before.identity ~= after.identity or not vim.deep_equal(before.static, after.static)
    or not prefix(before.messages, after.messages) then return nil end
  opts = opts or {}
  local rate, margin = opts.bytes_per_token or 3, opts.safety_margin or 1.3
  if not finite(rate) or rate == 0 or not finite(margin) or margin < 1 then return nil end
  local delta = after.bytes - before.bytes
  if delta < 0 then return nil end
  return { tokens = before.observed + math.ceil(delta / rate * margin) + 64,
    source = "observed input + wire-byte delta estimate", exact = false, observed_input = before.observed,
    delta_bytes = delta, safety_margin = margin, calibration_identity = before.identity }
end

return M
