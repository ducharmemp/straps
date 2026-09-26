-- tests/tool_run_quickfix_spec.lua (tests/quickfix_spec.lua covers grep/bulk_replace) —
-- tool.run_quickfix parses command output into the quickfix list via
-- errorformat.
--   busted tests/tool_run_quickfix_spec.lua
-- No network. Runs real (trivial) shell commands and asserts on both the
-- resulting quickfix list and the compact summary the agent sees.

local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(vim.fn.fnamemodify(here, ":p"), ":h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path


local registry = require("straps.registry")
require("straps.tools").register()

-- A pumping ctx.await like the other tool suites use.
local ctx = {
  await = function(fn)
    local result, resolved = nil, false
    fn(function(...)
      result = { ... }
      resolved = true
    end)
    vim.wait(10000, function() return resolved end)
    return unpack(result or {})
  end,
}

local function run(input)
  return registry.call("tool.run_quickfix", input, ctx)
end

-- Real files so filenames resolve to buffers; a throwaway dir on rtp-agnostic
-- absolute paths.
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local fa = tmp .. "/a.c"
local fb = tmp .. "/b.c"
for _, f in ipairs({ fa, fb }) do
  local h = assert(io.open(f, "w"))
  h:write("line1\nline2\nline3\nline4\n")
  h:close()
end

local EFM = "%f:%l:%c: %m"

it("parses file:line:col output into the quickfix list, opens it", function()
  vim.fn.setqflist({}, "f") -- clear
  local out = run({
    command = ("printf '%%s\\n' '%s:2:5: undefined thing' 'noise noise' '%s:4:1: bad'")
      :format(fa, fb),
    errorformat = EFM,
    title = "straps: test build",
  })
  local qf = vim.fn.getqflist()
  assert(#qf == 2, "expected 2 valid entries, got " .. #qf .. " — summary: " .. out)
  assert(vim.api.nvim_buf_get_name(qf[1].bufnr):find("a.c", 1, true), "first entry not a.c")
  assert(qf[1].lnum == 2 and qf[1].col == 5, "first entry position wrong")
  assert(qf[2].lnum == 4 and qf[2].col == 1, "second entry position wrong")
  -- Summary is compact: exit code + parsed entries, not the raw noise line.
  assert(out:find("exit code: 0", 1, true), "missing exit code: " .. out)
  assert(out:find("quickfix: 2 entries", 1, true), "missing entry count: " .. out)
  assert(out:find("a.c:2:5: undefined thing", 1, true), "missing entry line: " .. out)
  assert(not out:find("noise noise", 1, true), "noise leaked into the summary: " .. out)
  -- The list title carries through.
  local title = vim.fn.getqflist({ title = 1 }).title
  assert(title == "straps: test build", "title not set: " .. tostring(title))
end)

it("clean run empties the list (0 diagnostics)", function()
  -- Seed a non-empty list, then a passing command clears it.
  vim.fn.setqflist({ { filename = fa, lnum = 1, text = "stale" } }, " ")
  local out = run({ command = "true", errorformat = EFM })
  assert(#vim.fn.getqflist() == 0, "clean run should have emptied the quickfix list")
  assert(out:find("no entries parsed", 1, true), "expected the 0-diagnostics note: " .. out)
end)

it("non-empty output that matches no efm hints at errorformat", function()
  vim.fn.setqflist({}, "f")
  local out = run({
    command = "printf '%s\\n' 'this is just prose, no locations'",
    errorformat = EFM,
  })
  assert(#vim.fn.getqflist() == 0, "prose should yield no entries")
  assert(out:find("no entries parsed", 1, true), "expected 0-diagnostics note: " .. out)
end)

it("captures diagnostics on stderr too", function()
  vim.fn.setqflist({}, "f")
  local out = run({
    command = ("printf '%%s\\n' '%s:3:2: from stderr' 1>&2; exit 1"):format(fa),
    errorformat = EFM,
  })
  local qf = vim.fn.getqflist()
  assert(#qf == 1, "expected 1 entry from stderr, got " .. #qf .. " — " .. out)
  assert(qf[1].lnum == 3, "stderr entry position wrong")
  assert(out:find("exit code: 1", 1, true), "should report the failing exit code: " .. out)
end)

it("open=false does not force the quickfix window (still populates)", function()
  vim.fn.setqflist({}, "f")
  local out = run({
    command = ("printf '%%s\\n' '%s:1:1: x'"):format(fa),
    errorformat = EFM,
    open = false,
  })
  assert(#vim.fn.getqflist() == 1, "list should still be populated with open=false")
  assert(out:find("quickfix: 1 entry", 1, true), "summary wrong: " .. out)
end)

it("empty command errors clearly", function()
  local ok, err = pcall(run, { command = "" })
  assert(not ok, "empty command should error")
  assert(tostring(err):find("non-empty string", 1, true), "unexpected error: " .. tostring(err))
end)

it("caps the summary listing but keeps the full list", function()
  vim.fn.setqflist({}, "f")
  -- 120 entries; summary caps at 100, list keeps all.
  local parts = {}
  for i = 1, 120 do
    parts[#parts + 1] = ("'%s:%d:1: e%d'"):format(fa, (i % 4) + 1, i)
  end
  local out = run({
    command = "printf '%s\\n' " .. table.concat(parts, " "),
    errorformat = EFM,
  })
  assert(#vim.fn.getqflist() == 120, "full list should have 120 entries")
  assert(out:find("120 more", 1, true) or out:find("more; see the quickfix", 1, true),
    "summary should note the cap: " .. out:sub(-200))
end)
