local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(vim.fn.fnamemodify(here, ":p"), ":h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
vim.env.XDG_CONFIG_HOME = vim.fn.tempname()
local straps = require("straps")
local registry = require("straps.registry")
require("straps.provider").register()
local summary = require("straps.context_summary")
local assertion = 0
local function check(value)
  assertion = assertion + 1
  if tonumber(vim.env.STRAPS_SUMMARY_COMPLETION_ASSERTION) == assertion then value = not value end
  assert(value, "summary completion assertion " .. assertion)
end
local sources = { { kind = "tool_result", text = "evidence", id = "source" } }
local ctx = { cancelled = function() return _G.summary_completion_cancelled end }
local function generate()
  return summary.generate(sources, nil, ctx)
end
before_each(function()
  straps.config.context_management = { input_limit = 100000 }
  _G.summary_completion_cancelled = false
  _G.summary_completion_response = { complete = true, stop_reason = "end_turn" }
  registry.define({ name = "fn.provider", kind = "fn", source = [[return function(req)
    local refs = {}
    for _, source in ipairs(vim.json.decode(req.messages[1].content[1].text)) do refs[#refs + 1] = source.ref end
    local response = vim.deepcopy(_G.summary_completion_response)
    response.content = response.content or { { type = "text", text = vim.json.encode({
      summary = "Evidence retained", complete = true, source_refs = refs }) } }
    if response.cancel then _G.summary_completion_cancelled = true end
    return response
  end]] })
end)
it("refuses valid structured summaries when the provider reports incomplete end_turn", function()
  _G.summary_completion_response.complete = false
  local candidate, err, failure = generate()
  check(candidate == nil)
  check(type(err) == "string" and err:find("context summary: incomplete response", 1, true) ~= nil)
  check(failure and failure.kind == "generation")
end)
it("accepts complete provider responses through the default summary adapter", function()
  for _, stop in ipairs({ "end_turn", "stop" }) do
    _G.summary_completion_response.stop_reason = stop
    local candidate = generate()
    check(candidate and candidate.summary == "Evidence retained")
  end
end)
it("retains compatibility with custom providers omitting completion metadata", function()
  _G.summary_completion_response.complete = nil
  local candidate = generate()
  check(candidate and candidate.summary == "Evidence retained")
end)
it("refuses truncated and tool terminal statuses", function()
  for _, stop in ipairs({ "max_tokens", "length", "tool_use", "cancelled" }) do
    _G.summary_completion_response.stop_reason = stop
    local candidate, err, failure = generate()
    check(candidate == nil)
    check(type(err) == "string" and err:find("context summary: incomplete response", 1, true) ~= nil)
    check(failure and failure.kind == "generation")
  end
end)
it("refuses tool content even with a complete terminal response", function()
  _G.summary_completion_response.content = { { type = "tool_use", name = "exec", input = {} } }
  local candidate, err, failure = generate()
  check(candidate == nil)
  check(type(err) == "string" and err:find("tool or non-text response refused", 1, true) ~= nil)
  check(failure and failure.kind == "generation")
end)
it("refuses cancellation after the provider returns a complete summary", function()
  _G.summary_completion_response.cancel = true
  local candidate, err, failure = generate()
  check(candidate == nil)
  check(type(err) == "string" and err:find("cancelled", 1, true) ~= nil)
  check(failure and failure.kind == "cancelled")
end)
