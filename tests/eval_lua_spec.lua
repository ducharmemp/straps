-- tests/eval_lua_spec.lua — output formatting of tool.eval_lua.
--   busted tests/eval_lua_spec.lua
-- No network. Registers the real tools (tools.register) and calls
-- tool.eval_lua directly, asserting on the formatted string it returns.
-- Locks down the legibility contract: strings verbatim, flat lists one per
-- line (numbered/aligned), maps via vim.inspect, multi-return labeling, and
-- the error / nil / load-error paths.

local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(vim.fn.fnamemodify(here, ":p"), ":h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path


local registry = require("straps.registry")
require("straps.tools").register() -- registers tool.eval_lua (and friends)

-- eval_lua's source doesn't touch ctx, but pass a stub so the contract
-- (input, ctx) is honored and a future dependency surfaces loudly.
local function ev(code)
  return registry.call("tool.eval_lua", { code = code }, {})
end

it("bare string prints verbatim (no quotes/escaping)", function()
  local out = ev([[return "plain \"quoted\" string\twith tab"]])
  assert(out == 'plain "quoted" string\twith tab',
    "string not verbatim, got: " .. vim.inspect(out))
end)

it("flat list: one element per line, numbered", function()
  local out = ev([[return { "alpha", "beta", "gamma" }]])
  assert(out == "  1 | alpha\n  2 | beta\n  3 | gamma",
    "unexpected flat-list format:\n" .. out)
end)

it("flat list numbers are right-aligned to the widest index", function()
  local out = ev([[local t = {} for i = 1, 10 do t[i] = "x" .. i end return t]])
  local first = out:match("^([^\n]*)")
  local last = out:match("([^\n]*)$")
  assert(first == "   1 | x1", "index 1 not padded to width 2, got: " .. vim.inspect(first))
  assert(last == "  10 | x10", "index 10 misaligned, got: " .. vim.inspect(last))
end)

it("flat list of mixed scalars (number/boolean/string)", function()
  local out = ev([[return { 10, true, "s", false }]])
  assert(out == "  1 | 10\n  2 | true\n  3 | s\n  4 | false",
    "unexpected mixed-scalar format:\n" .. out)
end)

it("empty list renders as an explicit marker", function()
  assert(ev([[return {}]]) == "{} (empty list)", "empty list not marked")
end)

it("map/associative table falls back to vim.inspect", function()
  local out = ev([[return { b = 2, a = 1 }]])
  -- vim.inspect sorts keys; assert structure without pinning whitespace hard.
  assert(out:find("a = 1", 1, true) and out:find("b = 2", 1, true),
    "map fields missing from inspect output:\n" .. out)
  assert(out:sub(1, 1) == "{", "map should be inspected as a table literal:\n" .. out)
end)

it("list containing a table is NOT treated as flat (uses vim.inspect)", function()
  local out = ev([[return { 1, { nested = true } } ]])
  assert(out:sub(1, 1) == "{" and out:find("nested", 1, true),
    "non-scalar list element should force vim.inspect:\n" .. out)
  assert(not out:find("| ", 1, true), "non-flat list must not use the numbered format:\n" .. out)
end)

it("single number returns via vim.inspect", function()
  assert(ev([[return 42]]) == "42", "number not formatted as 42")
end)

it("multiple return values are labeled and ordered", function()
  local out = ev([[return true, "second", { a = 1 }]])
  assert(out:find("-- value 1 --\ntrue", 1, true), "value 1 label/content wrong:\n" .. out)
  assert(out:find("-- value 2 --\nsecond", 1, true), "value 2 label/content wrong:\n" .. out)
  assert(out:find("-- value 3 --", 1, true), "value 3 label missing:\n" .. out)
  assert(out:find("-- value 1", 1, true) < out:find("-- value 2", 1, true),
    "values out of order:\n" .. out)
end)

it("single return value is NOT labeled", function()
  local out = ev([[return "solo"]])
  assert(out == "solo", "single value should be unadorned, got:\n" .. out)
end)

it("no return value yields nil", function()
  assert(ev([[local x = 1]]) == "nil", "no-return should be 'nil'")
end)

it("runtime error is reported, not raised", function()
  local out = ev([[error("boom")]])
  assert(out:find("error: ", 1, true) == 1, "runtime error not prefixed:\n" .. out)
  assert(out:find("boom", 1, true), "error message body missing:\n" .. out)
end)

it("compile error is reported as a load error", function()
  local out = ev([[this is not lua!!!]])
  assert(out:find("load error: ", 1, true) == 1, "compile error not reported as load error:\n" .. out)
end)

it("explicit nil return is preserved (n counts it)", function()
  -- `return nil` has one return value that is nil; res.n <= 1 path -> "nil".
  assert(ev([[return nil]]) == "nil", "explicit nil return mishandled")
end)
