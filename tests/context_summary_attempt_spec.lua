local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(vim.fn.fnamemodify(here, ":p"), ":h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local summary = require("straps.context_summary")
local registry = require("straps.registry")
local sources = { { kind = "tool_result", text = "evidence", id = "first" } }
local function provider(body)
  registry.define({ name = "fn.context_summarize", kind = "fn", source = "return function(req,ctx) " .. body .. " end" })
end
local valid = [[
  _G.summary_attempt_calls = _G.summary_attempt_calls + 1
  local refs = {}
  for _, source in ipairs(req.sources) do refs[#refs + 1] = source.ref end
  return { summary = "summary", complete = true, source_refs = refs, stop_reason = "end_turn" }
]]
local function attempt(opts, ctx)
  return assert(summary.new_attempt(opts, ctx))
end
local function failed(kind, candidate, err, failure)
  assert.is_nil(candidate)
  assert.equals("string", type(err))
  assert.same({ kind = kind }, failure)
end
before_each(function()
  _G.summary_attempt_calls = 0
  provider(valid)
end)

it("shares call limits across spans and returns cumulative detached usage snapshots", function()
  local a = attempt({ max_calls = 2 })
  local first = assert(a.generate(sources))
  local second = assert(a.generate({ { kind = "assistant", text = "later", id = "second" } }))
  assert.equals(1, first.usage.calls)
  assert.equals(2, second.usage.calls)
  assert.equals(1, #first.children)
  assert.equals(1, #second.children)
  assert.equals("second", second.sources[1].id)
  assert.is_not.equals(first.snapshot_id, second.snapshot_id)
  failed("budget", a.generate(sources))
  assert.equals(2, _G.summary_attempt_calls)
  local snapshot = a.snapshot()
  snapshot.usage.calls, snapshot.limits.max_calls = 0, 100
  assert.equals(2, a.snapshot().usage.calls)
  assert.equals(2, a.snapshot().limits.max_calls)
end)

it("shares reserved token limits across spans and keeps failed provider calls charged", function()
  local a = attempt({ max_output_tokens = 10, max_total_tokens = 220, count_request = function() return 100 end })
  provider('_G.summary_attempt_calls = _G.summary_attempt_calls + 1; error("unavailable")')
  failed("generation", a.generate(sources))
  assert.equals(1, a.snapshot().usage.calls)
  assert.equals(110, a.snapshot().usage.reserved_tokens)
  provider(valid)
  local candidate = assert(a.generate(sources))
  assert.equals(220, candidate.usage.reserved_tokens)
  failed("budget", a.generate(sources))
  assert.equals(2, _G.summary_attempt_calls)
end)

it("charges retries to shared call and reservation budgets", function()
  local a = attempt({ max_calls = 3, max_retries = 1, max_output_tokens = 10,
    count_request = function() return 100 end })
  provider('_G.summary_attempt_calls = _G.summary_attempt_calls + 1; return {complete=false}')
  failed("generation", a.generate(sources))
  assert.equals(2, a.snapshot().usage.calls)
  provider(valid)
  assert.equals(3, assert(a.generate(sources)).usage.calls)
  failed("budget", a.generate(sources))
  assert.equals(330, a.snapshot().usage.reserved_tokens)
  assert.equals(3, _G.summary_attempt_calls)
end)

it("keeps hierarchy depth per root while sharing failed root spend", function()
  local a = attempt({ max_depth = 1, max_input_tokens = 1400, max_output_tokens = 128 })
  failed("budget", a.generate({ { kind = "tool_result", text = string.rep("x", 1800) } }))
  local spent = a.snapshot().usage.calls
  assert.is_true(spent > 1)
  local candidate = assert(a.generate(sources))
  assert.equals(1, candidate.depth)
  assert.equals(spent + 1, candidate.usage.calls)
end)

it("classifies caller validation failures without provider calls", function()
  failed("invalid", summary.new_attempt({ max_calls = math.huge }))
  failed("invalid", summary.new_attempt({ count_request = true }))
  failed("invalid", summary.new_attempt(false))
  failed("invalid", summary.new_attempt(nil, false))
  failed("invalid", summary.new_attempt(nil, { cancelled = true }))
  failed("invalid", summary.generate({ { kind = "user", text = "protected" } }))
  failed("invalid", summary.generate(sources, { count_request = function() return -1 end }))
  assert.equals(0, _G.summary_attempt_calls)
  failed("invalid", summary.generate(sources, { count_output = function() return -1 end }))
  assert.equals(1, _G.summary_attempt_calls)
end)

it("keeps unexpected caller exceptions internal even when their text matches eligible failures", function()
  for _, message in ipairs({ "summary input budget exhausted", "invalid or incomplete summary output", "summary cancelled" }) do
    failed("internal", summary.generate(sources, { count_request = function() error(message) end }))
    failed("internal", summary.generate(sources, nil, { cancelled = function() error(message) end }))
  end
  failed("internal", summary.generate(sources, { count_output = function() error("counter failure") end }))
  assert.equals(1, _G.summary_attempt_calls)
end)

it("classifies provider output and provider exceptions as generation failures", function()
  for _, body in ipairs({ 'error("summary cancelled")', 'return {complete=false}',
    valid:gsub('complete = true', 'complete = true, tool_calls = "bad"'),
    (valid:gsub('complete = true', 'complete = true, usage = {input_tokens=-1,output_tokens=0}')) }) do
    provider(body)
    failed("generation", summary.generate(sources))
  end
end)

it("checks cancellation between spans and after generation without refunding spend", function()
  local cancel = false
  local a = attempt(nil, { cancelled = function() return cancel end, cancel_now = function() cancel = true end })
  assert(a.generate(sources))
  cancel = true
  failed("cancelled", a.generate(sources))
  assert.equals(1, _G.summary_attempt_calls)
  cancel = false
  provider('ctx.cancel_now(); ' .. valid)
  failed("cancelled", a.generate(sources))
  assert.equals(2, a.snapshot().usage.calls)
  assert.is_true(a.snapshot().usage.reserved_tokens > 0)
end)

it("retains source caps across accepted metadata and validates malformed metadata", function()
  for _, source in ipairs({
    { kind = "assistant", text = "x", attrs = { value = string.rep("x", 4194304) } },
    { kind = "assistant", text = "x", id = string.rep("x", 4194304) },
  }) do
    failed("budget", summary.generate({ source }))
  end
  failed("invalid", summary.generate({ { kind = "assistant", text = "x", attrs = { value = {} } } }))
  assert.equals(0, _G.summary_attempt_calls)
end)

it("copies attempt options and keeps one-shot generate budgets independent", function()
  local opts = { max_calls = 1 }
  local a = attempt(opts)
  opts.max_calls = 2
  assert(a.generate(sources))
  failed("budget", a.generate(sources))
  assert.equals(1, assert(summary.generate(sources, { max_calls = 1 })).usage.calls)
  assert.equals(1, assert(summary.generate(sources, { max_calls = 1 })).usage.calls)
end)
