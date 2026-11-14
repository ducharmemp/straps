-- tests/skill_dirs_spec.lua — SKILL.md discovery (fn.discover_skills) and its
-- two consumers, the "# Skills" prompt layer and tool.skill.
--   busted tests/skill_dirs_spec.lua
-- No network. HOME and XDG dirs point into a tempdir, so the default user
-- roots (~/.agents/skills, ~/.claude/skills, stdpath("config")/straps/skills)
-- resolve to fixtures; cwd moves between temp project dirs below that HOME.

local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(here, ":p:h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
tmp = assert(vim.uv.fs_realpath(tmp))
vim.api.nvim_create_autocmd("VimLeavePre", { callback = function() vim.fn.delete(tmp, "rf") end })
local home = tmp .. "/home"
vim.fn.mkdir(home, "p")
vim.env.HOME = home
vim.env.XDG_CONFIG_HOME = tmp .. "/xdg_config"
vim.env.XDG_DATA_HOME = tmp .. "/xdg_data"

local straps = require("straps")
local registry = require("straps.registry")
require("straps.tools").register()
require("straps.provider").register()

local function write(path, text)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end

local function skill_md(name, description, body)
  return "---\nname: " .. name .. "\ndescription: " .. description .. "\n---\n" .. (body or ("Body of " .. name .. ".\n"))
end

local function discover()
  return registry.call("fn.discover_skills")
end

local function has_diag(found, substr)
  for _, d in ipairs(found.diagnostics) do
    if d:find(substr, 1, true) then return true end
  end
  return false
end

local user_agents = home .. "/.agents/skills"
local user_claude = home .. "/.claude/skills"
local user_config = vim.fn.stdpath("config") .. "/straps/skills"
local proj = home .. "/proj"
local sub = proj .. "/sub"

write(user_agents .. "/plain/SKILL.md", skill_md("plain", "Plain description."))
write(user_agents .. "/quoted/SKILL.md", '---\nname: "quoted"\ndescription: \'Quoted: with colon.\'\n---\nq\n')
write(user_agents .. "/folded/SKILL.md",
  "---\nname: folded\ndescription: >-\n  Folded first line\n  folded second line\nlicense: MIT\n---\nf\n")
write(user_agents .. "/literal/SKILL.md", "---\nname: literal\ndescription: |\n  Literal one\n  literal two\n---\nl\n")
write(user_agents .. "/colon/SKILL.md", skill_md("colon", "Use this skill when: the user asks about PDFs"))
write(user_agents .. "/meta/SKILL.md",
  "---\nname: meta\ndescription: Top-level description.\nmetadata:\n  author: someone\n  description: nested must not win\n---\nm\n")
write(user_agents .. "/unclosed/SKILL.md", "---\nname: unclosed\ndescription: Never closed.\n")
write(tmp .. "/elsewhere/linked/SKILL.md", skill_md("linked", "Directory reached through a symlink."))
assert(vim.uv.fs_symlink(tmp .. "/elsewhere/linked", user_agents .. "/linked"))
write(user_agents .. "/crlf/SKILL.md", "\239\187\191---\r\nname: crlf\r\ndescription: CRLF description.\r\n---\r\nCRLF body.\r\n")
write(user_agents .. "/nofront/SKILL.md", "# no frontmatter\n")
write(user_agents .. "/nodesc/SKILL.md", "---\nname: nodesc\ndescription:\n---\nx\n")
write(user_agents .. "/badname/SKILL.md", skill_md("bad.name", "Has a dot."))
write(user_agents .. "/noname/SKILL.md", "---\ndescription: Name comes from the directory.\n---\nx\n")
write(user_agents .. "/mismatch/SKILL.md", skill_md("renamed", "Name differs from directory."))
write(user_agents .. "/Upper/SKILL.md", skill_md("Upper", "Uppercase name."))
write(user_agents .. "/plainwrap/SKILL.md",
  "---\nname: plainwrap\ndescription: first part\n  continued part\nlicense: MIT\n---\nx\n")
write(user_agents .. "/nextline/SKILL.md", "---\nname: nextline\ndescription:\n  Starts on the next line.\n---\nx\n")
write(user_agents .. "/indicator/SKILL.md", "---\nname: indicator\ndescription: >2-\n  Indented with indicator.\n---\nx\n")
write(user_agents .. "/mapdesc/SKILL.md", "---\nname: mapdesc\ndescription:\n  en: English\n---\nx\n")
write(user_agents .. "/blankgap/SKILL.md",
  "---\nname: blankgap\ndescription: first\n\n  second\nlicense: MIT\n---\nx\n")
write(user_agents .. "/blankend/SKILL.md", "---\nname: blankend\ndescription: only line\n\nlicense: MIT\n---\nx\n")
write(user_agents .. "/longbody/SKILL.md", "# Heading, no frontmatter\n" .. ("text\n"):rep(500))
write(user_agents .. "/ctldesc/SKILL.md", "---\nname: ctldesc\ndescription: Bell\7and escape\27here.\n---\nx\n")
write(user_agents .. "/longfront/SKILL.md", "---\nname: longfront\ndescription: Long.\n" .. ("k: v\n"):rep(400) .. "---\nx\n")
write(user_agents .. "/fitfront/SKILL.md", "---\nname: fitfront\ndescription: Fits.\n" .. ("k: v\n"):rep(396) .. "---\nx\n")
write(user_agents .. "/ctl\nchar/SKILL.md", skill_md("ctlchar", "Control character in path."))
write(user_agents .. "/selflink/real.md", "---\nname: selflink\ndescription: SKILL.md is a symlink.\n---\nSelf body.\n")
assert(vim.uv.fs_symlink(user_agents .. "/selflink/real.md", user_agents .. "/selflink/SKILL.md"))
write(user_agents .. "/frontonly/SKILL.md", "---\nname: frontonly\ndescription: Body is empty.\n---")
write(user_agents .. "/notfile/SKILL.md/inner.txt", "SKILL.md is a directory here\n")
assert(vim.uv.fs_symlink(user_agents .. "/plain", user_agents .. "/zz_plain_alias"))
write(user_agents .. "/README.md", "not a skill directory\n")
write(user_agents .. "/nosk/notes.md", "directory without SKILL.md\n")

write(user_agents .. "/shared/SKILL.md", skill_md("shared", "User agents version."))
write(user_claude .. "/shared/SKILL.md", skill_md("shared", "User claude version."))
write(user_config .. "/configured/SKILL.md", skill_md("configured", "From stdpath config."))
write(proj .. "/.claude/skills/shared/SKILL.md", skill_md("shared", "Project version."))
write(proj .. "/.claude/skills/nested/SKILL.md", skill_md("nested", "Farther ancestor version."))
write(sub .. "/.agents/skills/nested/SKILL.md", skill_md("nested", "Nearer ancestor version."))
write(user_claude .. "/homeproj/SKILL.md", skill_md("homeproj", "User tier only."))

write(tmp .. "/secret.txt", "---\nname: escape\ndescription: Escaped.\n---\nSECRET\n")
vim.fn.mkdir(user_agents .. "/escape", "p")
assert(vim.uv.fs_symlink(tmp .. "/secret.txt", user_agents .. "/escape/SKILL.md"))

local res = sub .. "/.agents/skills/withres"
write(res .. "/SKILL.md", skill_md("withres", "Has resources.", "Run scripts/run.sh.\n"))
write(res .. "/scripts/run.sh", "echo hi\n")
write(res .. "/references/REF.md", "ref\n")
write(res .. "/.git/HEAD", "ignored\n")
write(res .. "/node_modules/x/index.js", "ignored\n")
assert(vim.uv.fs_symlink(tmp .. "/secret.txt", res .. "/leak.txt"))
assert(vim.uv.fs_symlink(res .. "/scripts/run.sh", res .. "/inside_link.sh"))

local many = sub .. "/.agents/skills/many"
write(many .. "/SKILL.md", skill_md("many", "Has sixty files."))
for i = 1, 60 do
  write(("%s/assets/f%02d.txt"):format(many, i), "x")
end

local exact = sub .. "/.agents/skills/exact"
write(exact .. "/SKILL.md", skill_md("exact", "Exactly 2000 directory entries."))
for i = 1, 3 do
  write(("%s/f%d.txt"):format(exact, i), "x")
end
for i = 1, 1995 do
  vim.fn.mkdir(("%s/d/e%04d"):format(exact, i), "p")
end

vim.fn.chdir(sub)

local function with(settings, fn)
  local saved, cwd = {}, vim.fn.getcwd()
  for k, v in pairs(settings) do
    if k ~= "cwd" then
      saved[k] = { straps.config[k] }
      if v == vim.NIL then v = nil end
      straps.config[k] = v
    end
  end
  if settings.cwd then vim.fn.chdir(settings.cwd) end
  local ok, a, b = pcall(fn)
  vim.fn.chdir(cwd)
  for k, v in pairs(saved) do straps.config[k] = v[1] end
  assert(ok, a)
  return a, b
end

it("vim.uv.os_homedir() follows the redirected HOME", function()
  assert.are.equal(home, vim.uv.os_homedir())
end)

describe("frontmatter parser", function()
  local found
  setup(function() found = discover() end)

  it("reads a plain name and description", function()
    assert.are.equal("Plain description.", found.skills.plain.description)
  end)
  it("strips matching quotes and keeps colons in the value", function()
    assert.are.equal("Quoted: with colon.", found.skills.quoted.description)
  end)
  it("folds a >- block scalar into one line and stops at the next key", function()
    assert.are.equal("Folded first line folded second line", found.skills.folded.description)
  end)
  it("collapses a | block scalar into one line", function()
    assert.are.equal("Literal one literal two", found.skills.literal.description)
  end)
  it("keeps an unquoted value containing a colon whole", function()
    assert.are.equal("Use this skill when: the user asks about PDFs", found.skills.colon.description)
  end)
  it("ignores keys nested under a map", function()
    assert.are.equal("Top-level description.", found.skills.meta.description)
  end)
  it("accepts a BOM and CRLF line endings", function()
    assert.are.equal("CRLF description.", found.skills.crlf.description)
  end)
  it("joins indented continuation lines of a plain scalar and stops at the next key", function()
    assert.are.equal("first part continued part", found.skills.plainwrap.description)
  end)
  it("reads a plain scalar that starts on the next line", function()
    assert.are.equal("Starts on the next line.", found.skills.nextline.description)
  end)
  it("accepts a block scalar indentation indicator", function()
    assert.are.equal("Indented with indicator.", found.skills.indicator.description)
  end)
  it("joins a plain scalar across a blank line followed by an indented line", function()
    assert.are.equal("first second", found.skills.blankgap.description)
  end)
  it("ends a plain scalar at a blank line followed by a top-level key", function()
    assert.are.equal("only line", found.skills.blankend.description)
  end)
  it("reads a frontmatter that closes within 400 lines", function()
    assert.are.equal("Fits.", found.skills.fitfront.description)
  end)
  it("records realpaths for the file and directory", function()
    assert.are.equal(user_agents .. "/plain/SKILL.md", found.skills.plain.path)
    assert.are.equal(user_agents .. "/plain", found.skills.plain.dir)
    assert.are.equal(tmp .. "/elsewhere/linked/SKILL.md", found.skills.linked.path)
    assert.are.equal(tmp .. "/elsewhere/linked", found.skills.linked.dir)
  end)
end)

describe("skips and diagnostics", function()
  local found
  setup(function() found = discover() end)

  it("skips a SKILL.md without frontmatter", function()
    assert.is_nil(found.skills.nofront)
    assert.is_true(has_diag(found, "nofront/SKILL.md: no YAML frontmatter"))
  end)
  it("skips a SKILL.md whose frontmatter is never closed", function()
    assert.is_nil(found.skills.unclosed)
    assert.is_true(has_diag(found, "unclosed/SKILL.md: no YAML frontmatter"))
  end)
  it("skips an empty description", function()
    assert.is_nil(found.skills.nodesc)
    assert.is_true(has_diag(found, "nodesc/SKILL.md: empty or missing description"))
  end)
  it("treats a description that is a nested map as empty", function()
    assert.is_nil(found.skills.mapdesc)
    assert.is_true(has_diag(found, "mapdesc/SKILL.md: empty or missing description"))
  end)
  it("skips a name with characters outside [A-Za-z0-9_-]", function()
    assert.is_nil(found.skills["bad.name"])
    assert.is_true(has_diag(found, "name bad.name has characters outside"))
  end)
  it("falls back to the directory name when name is missing", function()
    assert.are.equal("Name comes from the directory.", found.skills.noname.description)
    assert.is_true(has_diag(found, "missing name; using directory name noname"))
  end)
  it("uses the frontmatter name when it differs from the directory, with a diagnostic", function()
    assert.is_not_nil(found.skills.renamed)
    assert.is_nil(found.skills.mismatch)
    assert.is_true(has_diag(found, "name renamed does not match directory mismatch"))
  end)
  it("loads a name that breaks the spec's lowercase rule, with a diagnostic", function()
    assert.is_not_nil(found.skills.Upper)
    assert.is_true(has_diag(found, "name Upper breaks the spec"))
  end)
  it("ignores files and directories without SKILL.md", function()
    assert.is_nil(found.skills["README.md"])
    assert.is_nil(found.skills.nosk)
  end)
  it("skips a SKILL.md symlinked outside its skill directory", function()
    assert.is_nil(found.skills.escape)
    assert.is_true(has_diag(found, "escape/SKILL.md resolves outside its skill directory"))
  end)
  it("skips a frontmatter longer than 400 lines, saying so", function()
    assert.is_nil(found.skills.longfront)
    assert.is_true(has_diag(found, "longfront/SKILL.md: frontmatter longer than 400 lines; skipped"))
  end)
  it("reports a long file without frontmatter as having no frontmatter", function()
    assert.is_nil(found.skills.longbody)
    assert.is_true(has_diag(found, "longbody/SKILL.md: no YAML frontmatter; skipped"))
    assert.is_false(has_diag(found, "longbody/SKILL.md: frontmatter longer"))
  end)
  it("replaces control characters in a description with spaces", function()
    assert.are.equal("Bell and escape here.", found.skills.ctldesc.description)
  end)
  it("skips a skill whose path contains a control character", function()
    assert.is_nil(found.skills.ctlchar)
    assert.is_true(has_diag(found, vim.inspect(user_agents .. "/ctl\nchar/SKILL.md")
      .. ": path contains a control character; skipped"))
    for _, d in ipairs(found.diagnostics) do
      assert.is_nil(d:find("\n", 1, true))
    end
  end)
  it("reports config lists of the wrong type and bad entries", function()
    local f = with({ skill_roots = "~/skills", skill_paths = { 42 } }, discover)
    assert.is_true(has_diag(f, "config.skill_roots is a string; expected a list of paths"))
    assert.is_true(has_diag(f, "config.skill_paths has a number entry; expected a non-empty path string"))
  end)
  it("skips a SKILL.md that is not a regular file", function()
    assert.is_nil(found.skills.notfile)
    assert.is_true(has_diag(found, "notfile/SKILL.md: not a regular file; skipped"))
  end)
  it("reports no shadowing when two entries resolve to the same SKILL.md", function()
    assert.are.equal(user_agents .. "/plain/SKILL.md", found.skills.plain.path)
    assert.is_false(has_diag(found, "skill plain: "))
  end)
  it("skips bad config root entries without losing the other roots", function()
    local f = with({ skill_roots = { 42, "", user_agents } }, discover)
    assert.are.equal("Plain description.", f.skills.plain.description)
  end)
end)

describe("precedence", function()
  local found
  setup(function() found = discover() end)

  it("scans stdpath('config')/straps/skills as a user root", function()
    assert.are.equal("From stdpath config.", found.skills.configured.description)
  end)
  it("~/.claude/skills beats ~/.agents/skills, with a diagnostic", function()
    local f = with({ cwd = home }, discover)
    assert.are.equal("User claude version.", f.skills.shared.description)
    assert.is_true(has_diag(f, "skill shared: " .. user_claude .. "/shared/SKILL.md shadows " .. user_agents))
  end)
  it("a project skill beats both user roots of the same name, with a diagnostic", function()
    assert.are.equal("Project version.", found.skills.shared.description)
    assert.is_true(has_diag(found, "skill shared: " .. proj .. "/.claude/skills/shared/SKILL.md shadows " .. user_claude))
  end)
  it("the nearer ancestor beats the farther one", function()
    assert.are.equal("Nearer ancestor version.", found.skills.nested.description)
  end)
  it("does not scan HOME itself as a project ancestor", function()
    assert.are.equal(user_claude .. "/homeproj/SKILL.md", found.skills.homeproj.path)
    local f = with({ skill_roots = {} }, discover)
    assert.is_nil(f.skills.homeproj)
  end)
  it("config.skill_paths roots are scanned last and win", function()
    write(tmp .. "/extra/shared/SKILL.md", skill_md("shared", "Extra path version."))
    local f = with({ skill_paths = { tmp .. "/extra" } }, discover)
    assert.are.equal("Extra path version.", f.skills.shared.description)
  end)
  it("config.skill_paths and skill_roots expand ~ and resolve relative paths", function()
    write(tmp .. "/rel/shared/SKILL.md", skill_md("shared", "Relative path version."))
    vim.fn.mkdir(tmp .. "/outside/deep", "p")
    local f = with({ cwd = tmp .. "/outside/deep", skill_roots = { "~/.claude/skills" }, skill_paths = { "../../rel" } },
      discover)
    assert.are.equal(user_claude .. "/homeproj/SKILL.md", f.skills.homeproj.path)
    assert.is_nil(f.skills.plain)
    assert.are.equal("Relative path version.", f.skills.shared.description)
  end)
  it("config.skill_roots replaces the user roots", function()
    local f = with({ skill_roots = {} }, discover)
    assert.is_nil(f.skills.plain)
    assert.is_not_nil(f.skills.nested)
  end)
  it("with cwd outside HOME, ancestors are scanned too", function()
    write(tmp .. "/outside/.agents/skills/outer/SKILL.md", skill_md("outer", "Outside HOME."))
    vim.fn.mkdir(tmp .. "/outside/deep", "p")
    local f = with({ cwd = tmp .. "/outside/deep" }, discover)
    assert.are.equal("Outside HOME.", f.skills.outer.description)
    assert.is_nil(f.skills.nested)
  end)
end)

describe("system prompt", function()
  it("lists a discovered skill with its file path", function()
    local prompt = registry.call("fn.system_prompt")
    assert.is_truthy(prompt:find("\n- plain (file: " .. user_agents .. "/plain/SKILL.md): Plain description.", 1, true))
  end)
  it("a registry skill.* entry shadows a discovered skill of the same name", function()
    registry.define({ name = "skill.plain", kind = "skill", doc = "Registry plain.", source = "registry body" },
      { scope = "global" })
    local ok, err = pcall(function()
      local prompt = registry.call("fn.system_prompt")
      assert.is_truthy(prompt:find("- skill.plain: Registry plain.", 1, true))
      assert.is_falsy(prompt:find("(file: " .. user_agents .. "/plain/SKILL.md)", 1, true))
      assert.are.equal("registry body", registry.call("tool.skill", { name = "plain" }, {}))
    end)
    registry.remove("skill.plain", { scope = "global" })
    assert(ok, err)
  end)
  it("with nothing discovered the skills layer is exactly the registry skill lines", function()
    vim.fn.mkdir(home .. "/empty", "p")
    local on = with({ cwd = home .. "/empty", skill_roots = {} }, function()
      return registry.call("fn.system_prompt_skills")
    end)
    local expected = {}
    for _, name in ipairs(registry.names("skill")) do
      expected[#expected + 1] = "- " .. name .. ": " .. registry.get(name).doc:match("^[^\n]*")
    end
    assert.are.equal(table.concat(expected, "\n"), on)
  end)
  it("config.skill_discovery = false lists no discovered skills", function()
    local found, layer = with({ skill_discovery = false }, function()
      return discover(), registry.call("fn.system_prompt_skills")
    end)
    assert.are.same({}, found.order)
    assert.is_falsy(layer:find("(file:", 1, true))
  end)
end)

describe("tool.skill", function()
  it("lists discovered skills after registry skills", function()
    local out = registry.call("tool.skill", {}, {})
    assert.is_truthy(out:find("skill.showing_user", 1, true))
    assert.is_truthy(out:find("\nplain (file: " .. user_agents .. "/plain/SKILL.md): Plain description.", 1, true))
  end)
  it("lists discovered skills when no registry skill exists", function()
    local restore = {}
    for _, name in ipairs(registry.names("skill")) do
      restore[#restore + 1] = registry.render(name)
      registry.remove(name, { scope = "global" })
    end
    local ok, out = pcall(registry.call, "tool.skill", {}, {})
    for _, rendered in ipairs(restore) do
      assert(load(rendered))()
    end
    assert(ok, out)
    assert.are_not.equal("no skills defined", out)
    assert.is_truthy(out:find("plain (file:", 1, true))
  end)
  it("loads the body without frontmatter, plus the footer", function()
    local out = registry.call("tool.skill", { name = "withres" }, {})
    assert.are.equal("Run scripts/run.sh.", out:match("^[^\n]*"))
    assert.is_falsy(out:find("description: Has resources.", 1, true))
    assert.is_truthy(out:find("\nSkill file: " .. res .. "/SKILL.md\n", 1, true))
    assert.is_truthy(out:find("\nSkill directory: " .. res .. "\n", 1, true))
    assert.is_truthy(out:find("Relative paths in this skill resolve against that directory.", 1, true))
  end)
  it("lists bundled files sorted, skipping SKILL.md, .git, node_modules and escaping symlinks", function()
    local out = registry.call("tool.skill", { name = "withres" }, {})
    local listing = out:match("Bundled files %(listed, not loaded%):\n(.*)$")
    assert.are.equal("  inside_link.sh\n  references/REF.md\n  scripts/run.sh", listing)
  end)
  it("loads with the skill. prefix and strips CRLF frontmatter", function()
    local out = registry.call("tool.skill", { name = "skill.crlf" }, {})
    assert.are.equal("CRLF body.", out:match("^[^\n]*"))
  end)
  it("returns an empty body when the closing --- is the last line", function()
    local out = registry.call("tool.skill", { name = "frontonly" }, {})
    assert.are.equal("\n\nSkill file: " .. user_agents .. "/frontonly/SKILL.md\n", out:match("^[^\n]*\n[^\n]*\n[^\n]*\n"))
  end)
  it("caps the bundled file listing at 50 and marks it truncated", function()
    local out = registry.call("tool.skill", { name = "many" }, {})
    local n = 0
    for _ in out:gmatch("\n  assets/f%d%d%.txt") do n = n + 1 end
    assert.are.equal(50, n)
    assert.is_truthy(out:find("assets/f50.txt", 1, true))
    assert.is_falsy(out:find("assets/f51.txt", 1, true))
    assert.is_truthy(out:find("\n  (listing truncated)", 1, true))
  end)
  it("loads a symlinked SKILL.md and lists its target but not SKILL.md", function()
    local out = registry.call("tool.skill", { name = "selflink" }, {})
    assert.are.equal("Self body.", out:match("^[^\n]*"))
    assert.are.equal("  real.md", out:match("Bundled files %(listed, not loaded%):\n(.*)$"))
  end)
  it("does not mark a walk of exactly 2000 entries as truncated", function()
    local out = registry.call("tool.skill", { name = "exact" }, {})
    assert.are.equal("  f1.txt\n  f2.txt\n  f3.txt", out:match("Bundled files %(listed, not loaded%):\n(.*)$"))
  end)
  it("marks the walk truncated when entries remain past 2000", function()
    vim.fn.mkdir(exact .. "/d/e1996", "p")
    finally(function() vim.fn.delete(exact .. "/d/e1996", "d") end)
    local out = registry.call("tool.skill", { name = "exact" }, {})
    assert.is_truthy(out:find("\n  (listing truncated)", 1, true))
  end)
  it("reports the discovery cwd when a name is not found", function()
    local out = registry.call("tool.skill", { name = "nope" }, {})
    assert.are.equal("skill: no skill named nope (call with no name to list; discovery cwd: " .. sub .. ")", out)
  end)
end)

describe("a raising fn.discover_skills", function()
  local rendered
  setup(function()
    rendered = registry.render("fn.discover_skills")
    registry.define({ name = "fn.discover_skills", kind = "fn", source = "return function() error('boom') end" },
      { scope = "global" })
  end)
  teardown(function()
    assert(load(rendered))()
  end)

  it("does not break state.new_session", function()
    straps.config.session_dir = tmp .. "/sessions"
    finally(function() straps.config.session_dir = nil end)
    local bufnr = require("straps.state").new_session()
    local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
    assert.is_truthy(text:find("skill.showing_user", 1, true))
    assert.is_falsy(text:find("(file:", 1, true))
  end)
  it("does not break tool.skill listing or loading", function()
    local out = registry.call("tool.skill", {}, {})
    assert.is_truthy(out:find("skill.showing_user", 1, true))
    assert.is_truthy(registry.call("tool.skill", { name = "plain" }, {}):find("^skill: no skill named plain"))
  end)
end)

describe("a malformed fn.discover_skills return", function()
  local rendered
  setup(function()
    rendered = registry.render("fn.discover_skills")
    registry.define({
      name = "fn.discover_skills",
      kind = "fn",
      source = "return function() return { skills = { x = {}, y = { path = 1 } }, order = { 'x', 'y', {} },"
        .. " diagnostics = 'bad' } end",
    }, { scope = "global" })
  end)
  teardown(function()
    assert(load(rendered))()
  end)

  it("does not break state.new_session and lists no file skills", function()
    straps.config.session_dir = tmp .. "/sessions"
    finally(function() straps.config.session_dir = nil end)
    local bufnr = require("straps.state").new_session()
    local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
    assert.is_truthy(text:find("skill.showing_user", 1, true))
    assert.is_falsy(text:find("(file:", 1, true))
  end)
  it("does not break tool.skill listing or loading", function()
    assert.is_falsy(registry.call("tool.skill", {}, {}):find("(file:", 1, true))
    assert.is_truthy(registry.call("tool.skill", { name = "x" }, {}):find("^skill: no skill named x"))
  end)
end)

describe(":checkhealth straps", function()
  local function health()
    local rec = {}
    local orig = {}
    for _, k in ipairs({ "start", "ok", "warn", "error", "info" }) do
      orig[k] = vim.health[k]
      vim.health[k] = function(msg) rec[#rec + 1] = { kind = k, msg = tostring(msg) } end
    end
    local ok, err = pcall(function()
      package.loaded["straps.health"] = nil
      require("straps.health").check()
    end)
    for k, v in pairs(orig) do vim.health[k] = v end
    assert(ok, err)
    return function(kind, substr)
      for _, r in ipairs(rec) do
        if r.kind == kind and r.msg:find(substr, 1, true) then return r end
      end
    end
  end

  it("reports discovered skills and diagnostics", function()
    local find = health()
    local count = #discover().order
    assert.is_not_nil(find("start", "straps: SKILL.md discovery"))
    assert.is_not_nil(find("ok", ("%d skills discovered from cwd %s"):format(count, sub)))
    assert.is_not_nil(find("info", "plain: " .. user_agents .. "/plain/SKILL.md"))
    assert.is_not_nil(find("warn", "nofront/SKILL.md: no YAML frontmatter"))
  end)
  it("reports a discovered skill shadowed by a registry entry", function()
    registry.define({ name = "skill.plain", kind = "skill", doc = "Registry plain.", source = "x" }, { scope = "global" })
    finally(function() registry.remove("skill.plain", { scope = "global" }) end)
    local find = health()
    assert.is_not_nil(find("info", "plain (" .. user_agents .. "/plain/SKILL.md) is shadowed by registry entry skill.plain"))
    assert.is_nil(find("info", "plain: " .. user_agents))
  end)
  it("reports skill_discovery = false and lists nothing", function()
    local find = with({ skill_discovery = false }, health)
    assert.is_not_nil(find("info", "config.skill_discovery = false"))
    assert.is_nil(find("ok", "discovered from cwd"))
  end)
  it("reports a raising or malformed fn.discover_skills as an error without throwing", function()
    local rendered = registry.render("fn.discover_skills")
    finally(function() assert(load(rendered))() end)
    registry.define({ name = "fn.discover_skills", kind = "fn", source = "return function() error('boom') end" },
      { scope = "global" })
    assert.is_not_nil(health()("error", "fn.discover_skills raised"))
    registry.define({ name = "fn.discover_skills", kind = "fn", source = "return function() return { skills = {} } end" },
      { scope = "global" })
    assert.is_not_nil(health()("error", "fn.discover_skills returned table, not"))
    registry.define({
      name = "fn.discover_skills",
      kind = "fn",
      source = "return function() return { skills = { x = {} }, order = { 'x', {} }, diagnostics = 'bad' } end",
    }, { scope = "global" })
    local find = health()
    assert.is_not_nil(find("ok", "0 skills discovered"))
    assert.is_not_nil(find("warn", "fn.discover_skills returned 2 malformed entries"))
    assert.is_nil(find("info", "x: "))
  end)
end)
