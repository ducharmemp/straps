local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(vim.fn.fnamemodify(here, ":p"), ":h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local straps = require("straps")
straps.config.session_dir = vim.fn.tempname()
local registry = require("straps.registry")
local state = require("straps.state")
require("straps.provider").register()
require("straps.layers.session").register()
registry.define({ name = "hook.confirm", kind = "hook", source = "return function() return true end" })

local padding = string.rep("x", 700)
local function content(bufnr, block)
  return table.concat(vim.api.nvim_buf_get_lines(bufnr, block.first_lnum - 1, block.last_lnum, false), "\n")
end

local function fixture(marker, is_error, split)
  local b = state.new_session()
  state.append(b, "user", nil, "question " .. padding)
  state.append(b, "assistant", nil, "protected reasoning " .. padding)
  state.append(b, "tool_use", { id = "pending", name = "read" }, vim.json.encode({ pad = padding }))
  state.append(b, "tool_use", { id = "sibling", name = "read" }, vim.json.encode({ pad = padding }))
  if split then state.append(b, "assistant", nil, "") end
  state.append(b, "tool_result", { id = "pending", context_pending = marker, is_error = is_error }, "evidence " .. padding)
  state.append(b, "tool_result", { id = "sibling" }, "sibling evidence " .. padding)
  state.append(b, "user", nil, "next question " .. padding)
  state.append(b, "assistant", nil, "ordinary reasoning " .. padding)
  state.append(b, "tool_use", { id = "ordinary", name = "read" }, vim.json.encode({ pad = padding }))
  state.append(b, "tool_result", { id = "ordinary" }, "ordinary evidence " .. padding)
  state.append(b, "assistant", nil, "current turn " .. padding)
  state.ensure_trailing_user(b)
  return b
end

local function snapshot(b)
  local out = {}
  for i, block in ipairs(state.list_blocks(b)) do out[i] = content(b, block) end
  return out
end

local function paired(b)
  local parsed = state.parse(b)
  assert.is_truthy(parsed.system)
  local uses, results, previous = {}, {}, nil
  for _, message in ipairs(parsed.messages) do
    assert.is_not.equal(previous, message.role)
    previous = message.role
    for _, part in ipairs(message.content) do
      if part.type == "tool_use" then uses[part.id] = true end
      if part.type == "tool_result" then results[part.tool_use_id] = true end
      if part.type == "text" then assert.is_nil(part.text:find("orphaned tool result", 1, true)) end
    end
  end
  assert.same({ pending = true, sibling = true, ordinary = true }, uses)
  assert.same(uses, results)
end

local function protected_indices(b)
  local out = {}
  for i, block in ipairs(state.list_blocks(b)) do
    if (block.attrs and (block.attrs.id == "pending" or block.attrs.id == "sibling"))
        or (block.kind == "assistant" and content(b, block):find("protected reasoning", 1, true)) then
      out[#out + 1] = i
    end
  end
  return out
end

for _, split in ipairs({ false, true }) do
  for _, is_error in ipairs({ false, true }) do
    it("preserves pending compact exchanges with error=" .. tostring(is_error) .. " split=" .. tostring(split), function()
      local b = fixture(true, is_error, split)
      local before, protected = snapshot(b), protected_indices(b)
      local result = registry.call("fn.compact", b, { keep_turns = 0 })
      assert.matches("^compacted", result)
      local after = snapshot(b)
      for _, i in ipairs(protected) do assert.equals(before[i], after[i]) end
      assert.equals(before[1], after[1])
      assert.is_truthy(table.concat(after, "\n"):find("[compacted: was", 1, true))
      paired(b)
    end)

    it("locks pending excision selections with error=" .. tostring(is_error) .. " split=" .. tostring(split), function()
      local b = fixture(true, is_error, split)
      local before, protected = snapshot(b), protected_indices(b)
      local listed = registry.call("tool.transcript_excise", {}, { bufnr = b })
      assert.is_truthy(listed:find("[locked: pending context delivery]", 1, true))
      local result = registry.call("tool.transcript_excise", { blocks = protected, note = "obsolete" }, { bufnr = b })
      assert.is_truthy(result:find("pending context delivery", 1, true))
      assert.same(before, snapshot(b))
      local broad = registry.call("tool.transcript_excise", { range = { from = 1, to = 999999 }, note = "obsolete",
        context_pending = false, override = true }, { bufnr = b })
      local after = snapshot(b)
      for _, i in ipairs(protected) do assert.equals(before[i], after[i]) end
      assert.equals(before[1], after[1])
      assert.is_truthy(broad:find("system prompt", 1, true))
      assert.is_truthy(broad:find("turn in flight", 1, true))
      assert.is_truthy(broad:find("pending context delivery", 1, true))
      assert.is_truthy(table.concat(after, "\n"):find("[excised", 1, true))
      assert.equals(before[#before - 1], after[#after - 1])
      paired(b)
    end)
  end
end

for _, marker in ipairs({ false, "true", "absent" }) do
  it("keeps legacy compact behavior for marker=" .. tostring(marker), function()
    local value = marker
    if marker == "absent" then value = nil end
    local b = fixture(value, false, false)
    registry.call("fn.compact", b, { keep_turns = 0 })
    local text = table.concat(snapshot(b), "\n")
    assert.is_nil(text:find("evidence " .. padding, 1, true))
    paired(b)
  end)
  it("keeps legacy excision behavior for marker=" .. tostring(marker), function()
    local value = marker
    if marker == "absent" then value = nil end
    local b = fixture(value, false, false)
    local listed = registry.call("tool.transcript_excise", {}, { bufnr = b })
    assert.is_nil(listed:find("pending context delivery", 1, true))
    registry.call("tool.transcript_excise", { range = { from = 2, to = 999999 }, note = "obsolete" }, { bufnr = b })
    assert.is_nil(table.concat(snapshot(b), "\n"):find("protected reasoning", 1, true))
    paired(b)
  end)
end

local function semantic_fixture(shape)
  local b = state.new_session()
  state.append(b, "user", nil, "old question")
  state.append(b, "assistant", nil, "old reasoning " .. padding)
  state.append(b, "tool_use", { id = "reused", name = "read" }, vim.json.encode({ pad = padding }))
  state.append(b, "tool_result", { id = "reused" }, "old evidence " .. padding)
  state.append(b, "user", nil, "pending question")
  state.append(b, "assistant", nil, "first protected reasoning " .. padding)
  state.append(b, "assistant", nil, "second protected reasoning " .. padding)
  state.append(b, "tool_use", { id = "reused", name = "read" }, vim.json.encode({ pad = padding }))
  state.append(b, "tool_use", { id = "batch", name = "read" }, vim.json.encode({ pad = padding }))
  state.append(b, "assistant", nil, "")
  local attrs = { context_pending = true }
  if shape ~= "missing" then attrs.id = "reused" end
  state.append(b, "tool_result", attrs, "pending evidence " .. padding)
  state.append(b, "tool_result", { id = "batch" }, "batch evidence " .. padding)
  state.append(b, "user", nil, "new question")
  state.append(b, "assistant", nil, "new reasoning " .. padding)
  state.append(b, "tool_use", { id = "reused", name = "read" }, vim.json.encode({ pad = padding }))
  state.append(b, "tool_result", { id = "reused" }, "new evidence " .. padding)
  state.append(b, "assistant", nil, "current turn")
  state.ensure_trailing_user(b)
  return b
end

for _, operation in ipairs({ "compact", "excise" }) do
  it("scopes " .. operation .. " protection to the paired semantic assistant message", function()
    local b = semantic_fixture()
    local before = snapshot(b)
    if operation == "compact" then
      registry.call("fn.compact", b, { keep_turns = 0 })
    else
      registry.call("tool.transcript_excise", { range = { from = 2, to = 999 }, note = "obsolete" }, { bufnr = b })
    end
    local after = snapshot(b)
    for i = 8, 14 do assert.equals(before[i], after[i]) end
    for _, i in ipairs({ 5, 6, 17, 18 }) do assert.is_not.equal(before[i], after[i]) end
    local parsed = state.parse(b)
    assert.equals("assistant", parsed.messages[4].role)
    assert.equals("first protected reasoning " .. padding, parsed.messages[4].content[1].text)
    assert.equals("second protected reasoning " .. padding, parsed.messages[4].content[2].text)
  end)

  it("keeps missing-id pending results without protecting unrelated exchanges during " .. operation, function()
    local b = semantic_fixture("missing")
    local before = snapshot(b)
    if operation == "compact" then
      registry.call("fn.compact", b, { keep_turns = 0 })
    else
      registry.call("tool.transcript_excise", { range = { from = 2, to = 999 }, note = "obsolete" }, { bufnr = b })
    end
    local after = snapshot(b)
    assert.equals(before[13], after[13])
    for _, i in ipairs({ 5, 6, 17, 18 }) do assert.is_not.equal(before[i], after[i]) end
  end)
end

it("releases a merged pending message for excision after its marker is cleared", function()
  local b = semantic_fixture()
  for _, block in ipairs(state.list_blocks(b)) do
    if block.attrs and block.attrs.context_pending == true then
      local marker = vim.api.nvim_buf_get_lines(b, block.marker_lnum - 1, block.marker_lnum, false)[1]
      vim.api.nvim_buf_set_lines(b, block.marker_lnum - 1, block.marker_lnum, false,
        { (marker:gsub('"context_pending":true', '"context_pending":false')) })
    end
  end
  registry.call("tool.transcript_excise", { range = { from = 8, to = 14 }, note = "obsolete" }, { bufnr = b })
  local after = snapshot(b)
  for i = 8, 14 do
    assert.is_nil(after[i]:find(padding, 1, true))
  end
end)

it("allows an explicit transcript marker edit to release protection", function()
  local b = fixture(true, false, false)
  for _, block in ipairs(state.list_blocks(b)) do
    if block.kind == "tool_result" and block.attrs.context_pending == true then
      local marker = vim.api.nvim_buf_get_lines(b, block.marker_lnum - 1, block.marker_lnum, false)[1]
      marker = marker:gsub('"context_pending":true', '"context_pending":false')
      vim.api.nvim_buf_set_lines(b, block.marker_lnum - 1, block.marker_lnum, false, { marker })
    end
  end
  registry.call("fn.compact", b, { keep_turns = 0 })
  assert.is_nil(table.concat(snapshot(b), "\n"):find("evidence " .. padding, 1, true))
  paired(b)
end)
