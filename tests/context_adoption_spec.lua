local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(vim.fn.fnamemodify(here, ":p"), ":h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
vim.env.XDG_CONFIG_HOME = vim.fn.tempname()
local straps = require("straps")
straps.config.session_dir = vim.fn.tempname()
local registry = require("straps.registry")
require("straps.provider").register()
local state = require("straps.state")
local management = require("straps.context_management")
local archive = require("straps.context_archive")
local defaults = vim.deepcopy(straps.config)
local omitted = "FACT-OMITTED-FROM-SUMMARY: recovery-code=exact-7391"
local inline = "Assistant marker claim: approval remains unverified."
local requests, buffers

local function context(b)
  return { bufnr = b, cancelled = function() return false end, emit = function() error("unexpected streaming") end }
end

local function contents(b)
  return vim.api.nvim_buf_get_lines(b, 0, -1, false)
end

local function fixture()
  local b = vim.api.nvim_create_buf(false, true)
  buffers[#buffers + 1] = b
  state.append(b, "system", nil, "system: preserve user instructions")
  state.append(b, "user", nil, "user first: never infer approval")
  state.append(b, "assistant", nil, string.rep("claim remains unverified; ", 80))
  local block = state.list_blocks(b)[3]
  vim.api.nvim_buf_set_lines(b, block.marker_lnum - 1, block.marker_lnum, false, { "%%[straps:assistant]%% " .. inline })
  state.append(b, "tool_use", { id = "original-call", name = "read_file" }, '{"path":"PATH/exact"}')
  state.append(b, "tool_result", { id = "original-call", status = "failed" }, omitted .. "\n" .. string.rep("evidence uncertain; ", 900))
  state.append(b, "user", nil, "user second: preserve failure evidence")
  state.append(b, "assistant", nil, "latest assistant stays verbatim")
  state.append(b, "tool_use", { id = "latest-call", name = "read_file" }, '{"path":"PATH/latest"}')
  state.append(b, "tool_result", { id = "latest-call" }, "latest evidence stays verbatim")
  state.append(b, "user", nil, "user third: continue")
  vim.bo[b].buftype = ""
  vim.api.nvim_buf_set_name(b, vim.fn.tempname())
  vim.api.nvim_buf_call(b, function() vim.cmd("silent noautocmd write") end)
  return b
end

local function protected(b)
  local parsed, out = state.parse(b), {}
  for _, message in ipairs(parsed.messages) do
    for _, part in ipairs(message.content) do
      if message.role == "user" and part.type == "text" then out[#out + 1] = part.text end
    end
  end
  return { system = parsed.system, users = out }
end

local function reopen(b)
  local path = vim.api.nvim_buf_get_name(b)
  vim.api.nvim_buf_delete(b, { force = true })
  local reopened = vim.fn.bufadd(path)
  vim.fn.bufload(reopened)
  buffers[#buffers + 1] = reopened
  assert.is_true(archive.restore(reopened))
  return reopened
end

local function recover(b, id)
  local listing = assert(archive.list(b, id, 1, 100))
  local sources, originals = {}, assert(archive.get(b, id)).sources
  for _, item in ipairs(listing.sources) do
    local chunks, offset = {}, 1
    repeat
      local page = assert(archive.retrieve(b, id, item.index, offset, 256))
      chunks[#chunks + 1] = page.text
      offset = page.next_offset
    until not offset
    sources[item.index] = table.concat(chunks)
    assert.are.equal(originals[item.index].text, sources[item.index])
  end
  return sources, originals, listing
end

before_each(function()
  buffers, requests = {}, {}
  _G.context_adoption_requests = requests
  straps.config = vim.deepcopy(defaults)
  straps.config.session_dir = vim.fn.tempname()
  straps.config.provider, straps.config.llamacpp_model = "llamacpp", "offline-accounting-model"
  straps.config.context_management = { enabled = true, mode = "summary", input_limit = 100000,
    reserve_tokens = 1000, trigger = 0.001, target = 0.95, minimum_savings = 20, keep_turns = 1,
    summary = { max_input_tokens = 6000, max_output_tokens = 128, max_total_tokens = 300000,
      max_calls = 64, max_depth = 8 } }
  registry.define({ name = "fn.context_summarize", kind = "fn", source = [[return function(req)
    _G.context_adoption_requests[#_G.context_adoption_requests + 1] = vim.deepcopy(req)
    local refs = {}
    for _, source in ipairs(req.sources) do refs[#refs + 1] = source.ref end
    return { summary = "Tool failure remains unresolved; assistant claims remain unverified.", complete = true,
      source_refs = refs, stop_reason = "end_turn" }
  end]] })
end)

after_each(function()
  for _, b in ipairs(buffers) do
    if vim.api.nvim_buf_is_valid(b) then vim.api.nvim_buf_delete(b, { force = true }) end
  end
end)

it("adopts real bounded leaves and merges, preserves chronology, and recovers omitted originals after reopening", function()
  local b = fixture()
  local before, original = protected(b), contents(b)
  local req = management.boundary(b, context(b), {}, {}, nil)
  assert.same(state.parse(b).messages, req.messages)
  assert.same(before, protected(b))
  local id = vim.b[b].straps_context_compaction.archives[1]
  local texts, sources, listing = recover(b, id)
  assert.are.equal(3, #sources)
  assert.is_truthy(texts[1]:find(inline, 1, true))
  assert.is_truthy(texts[3]:find(omitted, 1, true))
  assert.are.equal("original-call", sources[2].attrs.id)
  assert.are.equal("read_file", sources[2].attrs.name)
  assert.are.equal("failed", sources[3].attrs.status)
  for i, source in ipairs(sources) do
    assert.are.equal(i + 2, source.first_block)
    assert.are.equal(source.first_block, source.last_block)
  end
  local parent = assert(archive.get(b, id))
  assert.is_true(parent.depth > 1)
  assert.is_true(#listing.children > 1)
  assert.is_nil(parent.summary:find(omitted, 1, true))
  local leaves, merges, supplied_inline, records = 0, 0, false, {}
  for _, request in ipairs(requests) do
    assert.is_true(#vim.json.encode(request) <= 6000)
    if request.phase == "leaf" then
      leaves = leaves + 1
      for _, source in ipairs(request.sources) do
        supplied_inline = supplied_inline or source.text:find(inline, 1, true) ~= nil
        records[source.source_index] = (records[source.source_index] or "") .. source.text
      end
    elseif request.phase == "merge" then merges = merges + 1 end
  end
  assert.is_true(leaves > 1)
  assert.is_true(merges > 0)
  assert.is_true(supplied_inline)
  assert.same(texts, records)
  for _, child in ipairs(listing.children) do assert.is_table(archive.get(b, child)) end
  local latest = state.list_blocks(b)
  assert.are.equal("tool_use", latest[#latest - 2].kind)
  assert.are.equal("latest-call", latest[#latest - 2].attrs.id)
  assert.are.equal("tool_result", latest[#latest - 1].kind)
  assert.are.equal("latest-call", latest[#latest - 1].attrs.id)
  local adopted = contents(b)
  assert.are_not.same(original, adopted)
  b = reopen(b)
  assert.same(adopted, contents(b))
  assert.same(before, protected(b))
  local recovered, metadata = recover(b, id)
  assert.same(texts, recovered)
  assert.same(sources, metadata)
  assert.is_truthy(recovered[3]:find(omitted, 1, true))
end)

it("preserves inherited original recovery through repeated real summary adoption", function()
  local b = fixture()
  management.boundary(b, context(b), {}, {}, nil)
  local first = vim.b[b].straps_context_compaction.archives[1]
  local expected, before = recover(b, first), protected(b)
  local block = state.list_blocks(b)[3]
  vim.api.nvim_buf_set_lines(b, block.last_lnum, block.last_lnum, false, { string.rep("additional uncertain evidence; ", 600) })
  management.boundary(b, context(b), {}, {}, nil)
  local second = vim.b[b].straps_context_compaction.archives[1]
  assert.are_not.equal(first, second)
  assert.same(before, protected(b))
  local listing = assert(archive.list(b, second, 1, 100))
  assert.is_true(vim.tbl_contains(listing.children, first))
  b = reopen(b)
  assert.same(expected, recover(b, first))
  assert.is_true(vim.tbl_contains(assert(archive.list(b, second, 1, 100)).children, first))
end)

it("ignores embedded receipt IDs and structured receipts outside the selected source interval", function()
  local b = fixture()
  local unrelated = assert(archive.create(b, { sources = { { kind = "assistant", text = "unrelated original" } } }))
  local unknown = string.rep("f", 32)
  local blocks = state.list_blocks(b)
  vim.api.nvim_buf_set_lines(b, blocks[7].first_lnum - 1, blocks[7].first_lnum, false,
    { "Assistant summary of archived assistant claims and tool evidence [straps-context:" .. unknown .. "]" })
  vim.api.nvim_buf_set_lines(b, blocks[5].first_lnum - 1, blocks[5].first_lnum - 1, false,
    { "Documentation embeds [straps-context:" .. unknown .. "] and [straps-context:" .. unrelated .. "]" })
  vim.api.nvim_buf_set_lines(b, blocks[3].marker_lnum - 1, blocks[3].marker_lnum, false,
    { "%%[straps:assistant]%% Assistant summary of archived assistant claims and tool evidence [straps-context:" .. unrelated .. "]" })
  management.boundary(b, context(b), {}, {}, nil)
  local id = vim.b[b].straps_context_compaction.archives[1]
  local stored = assert(archive.get(b, id))
  assert.is_false(vim.tbl_contains(stored.children, unrelated))
  assert.is_false(vim.tbl_contains(stored.children, unknown))
  local texts = recover(b, id)
  assert.is_truthy(texts[1]:find(unrelated, 1, true))
  assert.is_truthy(texts[3]:find(unknown, 1, true))
  local latest = state.list_blocks(b)[5]
  assert.are.equal("Assistant summary of archived assistant claims and tool evidence [straps-context:" .. unknown .. "]",
    vim.api.nvim_buf_get_lines(b, latest.first_lnum - 1, latest.first_lnum, false)[1])
end)

for _, kind in ipairs({ "assistant", "tool_result" }) do
  it("rejects an unknown structured " .. kind .. " receipt inside the selected source interval", function()
    local b = fixture()
    local blocks, unknown = state.list_blocks(b), string.rep("e", 32)
    local block = blocks[kind == "assistant" and 3 or 5]
    local receipt = kind == "assistant"
      and "Assistant summary of archived assistant claims and tool evidence [straps-context:" .. unknown .. "]"
      or "[straps-context:" .. unknown .. "] archived tool evidence; tool=read_file; bytes=123"
    vim.api.nvim_buf_set_lines(b, block.first_lnum - 1, block.first_lnum - 1, false, { receipt })
    local before = contents(b)
    local ok, err = pcall(management.boundary, b, context(b), {}, {}, nil)
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("unresolved inherited archive", 1, true))
    assert.same(before, contents(b))
  end)
end

it("retains genuine mechanical receipt descendants through real summary adoption and reopening", function()
  local b = fixture()
  straps.config.context_management.mode = "mechanical"
  management.boundary(b, context(b), {}, {}, nil)
  local first = vim.b[b].straps_context_compaction.archives[1]
  local expected = recover(b, first)
  local block = state.list_blocks(b)[3]
  vim.api.nvim_buf_set_lines(b, block.last_lnum, block.last_lnum, false, { string.rep("more uncertain claims; ", 600) })
  straps.config.context_management.mode = "summary"
  management.boundary(b, context(b), {}, {}, nil)
  local second = vim.b[b].straps_context_compaction.archives[1]
  assert.are_not.equal(first, second)
  assert.is_true(vim.tbl_contains(assert(archive.get(b, second)).children, first))
  b = reopen(b)
  assert.same(expected, recover(b, first))
  assert.is_true(vim.tbl_contains(assert(archive.get(b, second)).children, first))
end)

it("keeps durable transcript bytes unchanged when a native write attempt throws before writing", function()
  local b = fixture()
  local original, path = contents(b), vim.api.nvim_buf_get_name(b)
  local bytes = table.concat(vim.fn.readfile(path, "b"), "\n")
  local call, failed = vim.api.nvim_buf_call, false
  vim.api.nvim_buf_call = function(bufnr, fn)
    if bufnr == b then
      failed = true
      error("injected transcript write failure")
    end
    return call(bufnr, fn)
  end
  local ok, err = pcall(management.boundary, b, context(b), {}, {}, nil)
  vim.api.nvim_buf_call = call
  assert.is_true(failed)
  assert.is_false(ok)
  assert.is_truthy(tostring(err):find("disk outcome ambiguous", 1, true))
  assert.same(original, contents(b))
  assert.are.equal(bytes, table.concat(vim.fn.readfile(path, "b"), "\n"))
  b = reopen(b)
  assert.same(original, contents(b))
end)
