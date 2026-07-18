-- tests/run_skills.lua — skills: knowledge entries in the registry.
--   nvim --headless -l tests/run_skills.lua
-- No network. A skill (kind="skill") stores prose, not Lua: definable via
-- tool.registry_define, loadable via tool.skill (with or without the
-- "skill." prefix), listed in the "# Skills" system-prompt layer, excluded
-- from the API tool list, and renderable for .straps.lua persistence.

local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(vim.fn.fnamemodify(here, ":p"), ":h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local failed = false
local function case(name, fn)
  local ok, err = pcall(fn)
  if ok then
    print("PASS  " .. name)
  else
    failed = true
    print("FAIL  " .. name .. ": " .. tostring(err))
  end
end

local registry = require("straps.registry")
require("straps.tools").register()
require("straps.provider").register()

-- Prose that is deliberately NOT valid Lua, with a long-bracket closer
-- inside to stress render()'s level picking.
local PROSE = "Release steps (found the hard way):\n"
  .. "1. bump version in ]==] rockspec\n"
  .. "2. run `make dist` — plain make skips the manifest\n"

case("no skills: tool.skill lists nothing, prompt has no # Skills section", function()
  local out = registry.call("tool.skill", {}, {})
  assert(out == "no skills defined", "expected empty listing, got: " .. out)
  local prompt = registry.call("fn.system_prompt")
  assert(not prompt:find("# Skills", 1, true), "prompt should omit # Skills when none exist")
end)

case("registry_define accepts kind=skill with a prose (non-Lua) body", function()
  local out = registry.call("tool.registry_define", {
    name = "skill.release_process",
    kind = "skill",
    doc = "Load before cutting a release.",
    source = PROSE,
    scope = "global",
  }, {})
  assert(out:match("^defined skill%.release_process"), "define failed: " .. out)
end)

case("tool.skill loads the prose verbatim, with or without prefix", function()
  assert(registry.call("tool.skill", { name = "skill.release_process" }, {}) == PROSE)
  assert(registry.call("tool.skill", { name = "release_process" }, {}) == PROSE)
end)

case("tool.skill with no name lists the skill with its doc line", function()
  local out = registry.call("tool.skill", {}, {})
  assert(out:find("skill.release_process: Load before cutting a release.", 1, true),
    "listing missing skill, got: " .. out)
end)

case("unknown skill name returns a pointer, not an error", function()
  local out = registry.call("tool.skill", { name = "nope" }, {})
  assert(out:match("^skill: no skill named nope"), "got: " .. out)
end)

case("skills appear in the # Skills prompt layer", function()
  local prompt = registry.call("fn.system_prompt")
  assert(prompt:find("# Skills", 1, true), "prompt missing # Skills section")
  assert(prompt:find("- skill.release_process: Load before cutting a release.", 1, true),
    "prompt missing the skill line")
end)

case("skills are NOT in the API tool list", function()
  for _, t in ipairs(registry.call("fn.build_tools")) do
    assert(not tostring(t.name):find("release_process", 1, true),
      "skill leaked into API tools as " .. tostring(t.name))
  end
end)

case("render() round-trips a skill for .straps.lua persistence", function()
  local rendered = registry.render("skill.release_process")
  registry.remove("skill.release_process")
  assert(registry.get("skill.release_process") == nil, "remove failed")
  assert(load(rendered))()
  local e = registry.get("skill.release_process")
  assert(e and e.kind == "skill" and e.source == PROSE, "round-trip lost the body")
end)

case("registry.call on a skill returns its body (uniform call surface)", function()
  assert(registry.call("skill.release_process") == PROSE)
end)

if failed then
  vim.cmd("cquit 1")
end
vim.cmd("quit")
