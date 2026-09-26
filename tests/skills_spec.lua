-- tests/skills_spec.lua — skills: knowledge entries in the registry.
--   busted tests/skills_spec.lua
-- No network. A skill (kind="skill") stores prose, not Lua: definable via
-- tool.registry_define, loadable via tool.skill (with or without the
-- "skill." prefix), listed in the "# Skills" system-prompt layer, excluded
-- from the API tool list, and renderable for .straps.lua persistence.

local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(vim.fn.fnamemodify(here, ":p"), ":h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path


local registry = require("straps.registry")
require("straps.tools").register()
require("straps.provider").register()

-- Prose that is deliberately NOT valid Lua, with a long-bracket closer
-- inside to stress render()'s level picking.
local PROSE = "Release steps (found the hard way):\n"
  .. "1. bump version in ]==] rockspec\n"
  .. "2. run `make dist` — plain make skips the manifest\n"

it("builtin skill.showing_user ships with provider.register()", function()
  local e = registry.get("skill.showing_user")
  assert(e and e.kind == "skill", "builtin skill.showing_user missing")
  local out = registry.call("tool.skill", {}, {})
  assert(out:find("skill.showing_user", 1, true), "builtin skill absent from listing: " .. out)
end)

it("no skills: tool.skill lists nothing, prompt has no # Skills section", function()
  -- The builtins make skills non-empty by default; remove them all to test the
  -- empty state, restore afterwards via their own renderings.
  local restore = {}
  for _, name in ipairs(registry.names("skill")) do
    restore[#restore + 1] = registry.render(name)
    registry.remove(name, { scope = "global" })
  end
  assert(#restore > 0, "expected builtin skills to remove")
  local ok, err = pcall(function()
    local out = registry.call("tool.skill", {}, {})
    assert(out == "no skills defined", "expected empty listing, got: " .. out)
    -- The core prompt MENTIONS "# Skills" inline (self-extension section), so
    -- assert on the section header at line start, not the bare substring.
    local prompt = registry.call("fn.system_prompt")
    assert(not prompt:find("\n# Skills\n", 1, true), "prompt should omit # Skills when none exist")
  end)
  for _, rendered in ipairs(restore) do
    assert(load(rendered))() -- restore the builtins
  end
  assert(ok, err)
end)

it("registry_define accepts kind=skill with a prose (non-Lua) body", function()
  local out = registry.call("tool.registry_define", {
    name = "skill.release_process",
    kind = "skill",
    doc = "Load before cutting a release.",
    source = PROSE,
    scope = "global",
  }, {})
  assert(out:match("^defined skill%.release_process"), "define failed: " .. out)
end)

it("tool.skill loads the prose verbatim, with or without prefix", function()
  assert(registry.call("tool.skill", { name = "skill.release_process" }, {}) == PROSE)
  assert(registry.call("tool.skill", { name = "release_process" }, {}) == PROSE)
end)

it("tool.skill with no name lists the skill with its doc line", function()
  local out = registry.call("tool.skill", {}, {})
  assert(out:find("skill.release_process: Load before cutting a release.", 1, true),
    "listing missing skill, got: " .. out)
end)

it("unknown skill name returns a pointer, not an error", function()
  local out = registry.call("tool.skill", { name = "nope" }, {})
  assert(out:match("^skill: no skill named nope"), "got: " .. out)
end)

it("skills appear in the # Skills prompt layer", function()
  local prompt = registry.call("fn.system_prompt")
  assert(prompt:find("\n# Skills\n", 1, true), "prompt missing # Skills section")
  assert(prompt:find("- skill.release_process: Load before cutting a release.", 1, true),
    "prompt missing the skill line")
end)

it("skills are NOT in the API tool list", function()
  for _, t in ipairs(registry.call("fn.build_tools")) do
    assert(not tostring(t.name):find("release_process", 1, true),
      "skill leaked into API tools as " .. tostring(t.name))
  end
end)

it("render() round-trips a skill for .straps.lua persistence", function()
  local rendered = registry.render("skill.release_process")
  registry.remove("skill.release_process")
  assert(registry.get("skill.release_process") == nil, "remove failed")
  assert(load(rendered))()
  local e = registry.get("skill.release_process")
  assert(e and e.kind == "skill" and e.source == PROSE, "round-trip lost the body")
end)

it("registry.call on a skill returns its body (uniform call surface)", function()
  assert(registry.call("skill.release_process") == PROSE)
end)
