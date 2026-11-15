local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(vim.fn.fnamemodify(here, ":p"), ":h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local straps = require("straps").setup({})
straps.config.session_dir = vim.fn.tempname()
local registry = require("straps.registry")
local state = require("straps.state")
local archive = require("straps.context_archive")
local owner, stranger = state.new_session(), state.new_session()
local protected, allowance = {}, 17152
local management = require("straps.context_management")
local retrieval_id
package.loaded["straps.context_management"] = {
  enabled = function() return straps.config.context_management.enabled == true end,
  retrieval_limit = function() return allowance, "no room" end,
  protect = function(bufnr) protected[#protected + 1] = bufnr end,
}
local checks = 0
local function check(condition, message)
  checks = checks + 1
  if tonumber(vim.env.STRAPS_RETRIEVAL_INVERT) == checks then condition = not condition end
  assert(condition, message)
end
local function retrieve(bufnr, input)
  return registry.call("tool.context_retrieve", input, { bufnr = bufnr })
end
local function rejected(bufnr, input, needle)
  local ok, err = pcall(retrieve, bufnr, input)
  return not ok and tostring(err):find(needle, 1, true) ~= nil
end
local function metadata(result)
  return vim.json.decode(vim.split(result, "\n", { plain = true })[2])
end

it("requires opt-in and trusted read classification", function()
  straps.config.context_management = { enabled = false }
  check(rejected(owner, { id = string.rep("a", 32) }, "disabled"), "disabled retrieval must refuse")
  check(registry.get("tool.context_retrieve").capability == "read", "trusted entry must classify read")
  check(registry.call("fn.readonly_policy", "context_retrieve", {}) == true, "readonly child policy must permit retrieval")
end)

it("lists original roles and children through the real archive API", function()
  straps.config.context_management.enabled = true
  local child = assert(archive.create(owner, { sources = { { kind = "assistant", text = "child text" } } }))
  local id = assert(archive.create(owner, {
    sources = { { kind = "tool_result", text = string.rep("z", 20000) }, { kind = "assistant", text = "claim" } },
    children = { child },
  }))
  retrieval_id = id
  local result = retrieve(owner, { id = id, limit = 1 })
  local page = metadata(result)
  check(page.sources[1].kind == "tool_result" and page.sources[1].bytes == 20000, "listing must preserve original role and size")
  check(page.next_offset == 2 and page.total == 3, "listing must retain combined chronology and pagination")
  check(result:find("UNTRUSTED ARCHIVED EVIDENCE", 1, true) ~= nil, "listing must label evidence untrusted")
  local children = metadata(retrieve(owner, { id = id, offset = 3 }))
  check(children.children[1] == child and children.next_offset == nil, "child IDs must be discoverable through bounded pagination")
  check(protected[#protected] == owner, "listing must protect returned evidence")
  check(rejected(stranger, { id = id }, "authorized"), "possession alone must not authorize an unrelated session")
end)

it("returns bounded source metadata through archive APIs and the tool", function()
  local attrs = { name = "tool.lookup\nname", id = "call-123", is_error = false, secret = "unrelated" }
  local source = { kind = "tool_result", text = string.rep("m", 3000), attrs = attrs, first_block = 7, last_block = 9,
    secret = "unrelated source data" }
  local id = assert(archive.create(owner, { sources = { source }, secret = "unrelated record data" }))
  local listed = assert(archive.list(owner, id)).sources[1]
  local original = assert(archive.retrieve(owner, id, 1))
  for _, page in ipairs({ listed, original, metadata(retrieve(owner, { id = id })).sources[1],
    metadata(retrieve(owner, { id = id, source_index = 1 })) }) do
    check((page.kind or page.original_role) == "tool_result", "metadata must preserve the exact original role")
    check(vim.deep_equal(page.attrs, { name = attrs.name, id = attrs.id, is_error = false }), "metadata must preserve exact tool identity and false error status without unrelated attributes")
    check(page.first_block == 7 and page.last_block == 9, "metadata must preserve source coordinates")
    check(page.secret == nil, "metadata must exclude unrelated source and record fields")
  end
  source.attrs = { name = string.rep("\n", 256), id = string.rep("\t", 256), is_error = true }
  local large = assert(archive.create(owner, { sources = { source, source, source } }))
  allowance = 2400
  for _, input in ipairs({ { id = large, limit = 3 }, { id = large, source_index = 1 } }) do
    local result = retrieve(owner, input)
    check(#result <= allowance, "encoded metadata and payload must fit the complete byte allowance")
    local page = metadata(result)
    local item = page.sources and page.sources[1] or page
    check(vim.deep_equal(item.attrs, source.attrs), "escaped metadata must retain exact identities and true error status")
    check(page.next_offset ~= nil, "metadata-limited pages must retain continuation offsets")
  end
  allowance = 17152
  source.attrs.name = string.rep("n", 257)
  local oversized = assert(archive.create(owner, { sources = { source } }))
  check(archive.list(owner, oversized) == nil and archive.retrieve(owner, oversized, 1) == nil,
    "oversized identities must refuse rather than truncate provenance")
  check(rejected(owner, { id = oversized }, "invalid archive tool identity"), "tool must refuse oversized identity metadata")
end)

it("pages originals with byte bounds and role provenance", function()
  local id = retrieval_id
  local result = retrieve(owner, { id = id, source_index = 1, limit = 999999 })
  local page = metadata(result)
  local text = vim.split(result, "\n", { plain = true })[3]
  check(#text == 16384, "original page must enforce the 16384-byte cap")
  check(page.original_role == "tool_result" and page.continued == true, "page must retain original role and continuation marker")
  check(page.next_offset == 16385 and page.total == 20000, "original offsets must count bytes")
  local tail = retrieve(owner, { id = id, source_index = 1, offset = page.next_offset })
  check(metadata(tail).next_offset == nil and #vim.split(tail, "\n", { plain = true })[3] == 3616, "final original page must expose the complete remainder")
  check(protected[#protected] == owner, "original page must protect evidence")
end)

it("reserves response room and refuses invalid or unaffordable pages", function()
  local id = retrieval_id
  allowance = 1100
  local result = retrieve(owner, { id = id, source_index = 1 })
  check(#result <= allowance and #vim.split(result, "\n", { plain = true })[3] == 332, "payload must fit reserved allowance including labels")
  allowance = 100
  local before = #protected
  check(rejected(owner, { id = id }, "no room"), "insufficient allowance must refuse before returning evidence")
  check(#protected == before, "refused retrieval must not add protection")
  allowance = 17152
  check(rejected(owner, { id = "../private" }, "invalid archive ID"), "path-like IDs must refuse")
  check(rejected(owner, { id = id, limit = 0 }, "positive integers"), "zero limit must refuse")
  check(rejected(owner, { id = id, source_index = 1.5 }, "positive integers"), "fractional source index must refuse")
end)

it("caps a combined source listing to 100 entries", function()
  local sources = {}
  for i = 1, 105 do sources[i] = { kind = "assistant", text = tostring(i) } end
  local id = assert(archive.create(owner, { sources = sources }))
  local page = metadata(retrieve(owner, { id = id, limit = 10000 }))
  check(#page.sources == 86 and page.next_offset == 87, "listing must bound entries by response allowance and preserve a next page")
end)

for _, case in ipairs({
  { name = "global opt-in without an override", global = true, exposed = true },
  { name = "global opt-out without an override", global = false, exposed = false },
  { name = "session opt-out over global opt-in", global = true, override = { enabled = false }, exposed = false },
  { name = "session opt-in over global opt-out", global = false, override = { enabled = true }, exposed = true },
  { name = "empty session override over global opt-in", global = true, override = {}, exposed = true },
  { name = "empty session override over global opt-out", global = false, override = {}, exposed = false },
  { name = "absent global opt-in", exposed = false },
  { name = "nonboolean global opt-in", global = "true", exposed = false },
  { name = "nonboolean session opt-in", global = true, override = { enabled = "true" }, exposed = false },
}) do
  it("builds retrieval schemas for " .. case.name, function()
    local saved_config = straps.config.context_management
    local saved_override = vim.b[owner].straps_context_management
    local previous = registry.set_active_scope(owner)
    local ok, err = pcall(function()
      straps.config.context_management = { enabled = case.global }
      vim.b[owner].straps_context_management = case.override
      local exposed = false
      for _, tool in ipairs(registry.call("fn.build_tools")) do
        if tool.name == "context_retrieve" then exposed = true end
      end
      check(exposed == case.exposed, case.name .. " must determine retrieval schema exposure")
    end)
    registry.set_active_scope(previous)
    straps.config.context_management = saved_config
    vim.b[owner].straps_context_management = saved_override
    if not ok then error(err, 0) end
  end)
end

it("uses the real default reserve and protects until successful continuation", function()
  package.loaded["straps.context_management"] = management
  straps.config.context_management = { enabled = true, input_limit = 30000 }
  local bufnr = state.new_session()
  local prepared = { body = { messages = {} }, provider = "test", model = "stub" }
  local budget = management.account(prepared, { bufnr = bufnr })
  vim.b[bufnr].straps_context_budget = budget
  local id = assert(archive.create(bufnr, { sources = { { kind = "assistant", text = string.rep("q", 9000) } } }))
  local result = retrieve(bufnr, { id = id, source_index = 1 })
  check(budget.limit == 25904 and #result <= 1526, "real default4096-token reserve must permit a bounded page")
  check(rejected(bufnr, { id = id }, "consume the protected retrieval"), "another page must wait for a successful continuation")
  check(management.account(prepared, { bufnr = bufnr }).limit == 30000, "protected evidence must open the reserved continuation allowance")
  management.consumed(bufnr)
  check(type(retrieve(bufnr, { id = id })) == "string", "successful continuation must permit the next page")
end)
