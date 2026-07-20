-- System prompt tests: the layered prompt (fn.system_prompt_core/_env/
-- _project composed by fn.system_prompt). Covers composition, AGENTS.md/
-- CLAUDE.md discovery, config.instructions_files, the 20000-byte cap,
-- late-bound layer redefinition, new_session pickup, and the env VCS line.
-- Run: nvim --headless -l tests/run_prompt.lua

local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(here, ":h:h")
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

local straps = require("straps").setup({})
-- Hermetic: durable sessions write under a throwaway dir, never the real data dir.
straps.config.session_dir = vim.fn.tempname()
local registry = require("straps.registry")
local state = require("straps.state")

local orig_cwd = vim.fn.getcwd()
local function cd(dir)
  vim.cmd("cd " .. vim.fn.fnameescape(dir))
end

local function write_file(path, text)
  local f = assert(io.open(path, "w"))
  f:write(text)
  f:close()
end

-- A deep, fresh tempdir: nothing straps-related upward except whatever
-- happens to live above the temp root (asserted against the tempdir only).
local tmp = vim.fn.tempname()
local deep = tmp .. "/isolated/prompt-test"
vim.fn.mkdir(deep, "p")

-- ------------------------------------------------------------- composition
case("fn.system_prompt composes core + env; project stays out of a bare dir", function()
  cd(deep)
  local ok, err = pcall(function()
    local prompt = registry.call("fn.system_prompt")
    assert(prompt:find("coding agent running inside Neovim", 1, true),
      "core identity phrase missing")
    assert(prompt:find("registry_define", 1, true), "self-extension material missing")
    assert(prompt:find("\n# Environment\n", 1, true), "# Environment section missing")
    assert(prompt:find("cwd: ", 1, true), "cwd line missing from env section")
    local v = vim.version()
    assert(prompt:find(("nvim: %d.%d.%d"):format(v.major, v.minor, v.patch), 1, true),
      "nvim version line missing from env section")
    -- Project isolation: whatever the project layer picked up (possibly a
    -- stray file above the temp root), it must not involve this tempdir.
    local project = registry.call("fn.system_prompt_project")
    assert(not project:find(deep, 1, true),
      "project layer mentions the bare tempdir: " .. project)
  end)
  cd(orig_cwd)
  assert(ok, err)
end)

-- ------------------------------------------------------------ project files
case("project layer includes AGENTS.md, CLAUDE.md and instructions_files", function()
  write_file(deep .. "/AGENTS.md", "agents-norm-marker")
  write_file(deep .. "/CLAUDE.md", "claude-memory-marker")
  local extra = tmp .. "/extra-instructions.md"
  write_file(extra, "extra-instructions-marker")

  cd(deep)
  local saved_extras = straps.config.instructions_files
  local ok, err = pcall(function()
    straps.config.instructions_files = { extra, tmp .. "/does-not-exist.md" }
    local project = registry.call("fn.system_prompt_project")
    assert(project:find("agents-norm-marker", 1, true), "AGENTS.md content missing")
    assert(project:find("claude-memory-marker", 1, true), "CLAUDE.md content missing")
    assert(project:find("## " .. deep .. "/AGENTS.md", 1, true), "AGENTS.md path header missing")
    assert(project:find("## " .. deep .. "/CLAUDE.md", 1, true), "CLAUDE.md path header missing")
    assert(project:find("extra-instructions-marker", 1, true),
      "instructions_files entry not included")
    assert(not project:find("does-not-exist", 1, true),
      "unreadable instructions_files entry should be skipped silently")
    -- The composer frames the section for the model.
    local prompt = registry.call("fn.system_prompt")
    assert(prompt:find("# Project instructions\n", 1, true), "composed section header missing")
    assert(prompt:find("project's memory files", 1, true), "framing sentence missing")
  end)
  straps.config.instructions_files = saved_extras
  cd(orig_cwd)
  assert(ok, err)
end)

-- -------------------------------------------------------------- truncation
case("files larger than 20000 bytes are capped with a truncation note", function()
  local big = ("x"):rep(30000)
  write_file(deep .. "/AGENTS.md", big)
  cd(deep)
  local ok, err = pcall(function()
    local project = registry.call("fn.system_prompt_project")
    assert(project:find("[straps: truncated]", 1, true), "truncation note missing")
    local section = project:match("## " .. vim.pesc(deep .. "/AGENTS.md") .. "\n(x*)")
    assert(section, "AGENTS.md section missing")
    assert(#section == 20000, "cap should be 20000 bytes, got " .. #section)
  end)
  write_file(deep .. "/AGENTS.md", "agents-norm-marker") -- restore for later cases
  cd(orig_cwd)
  assert(ok, err)
end)

-- ------------------------------------------------------------- late binding
case("composition is late-bound: redefining a layer changes fn.system_prompt", function()
  local orig = assert(registry.get("fn.system_prompt_env"), "fn.system_prompt_env missing")
  local orig_spec = {
    name = orig.name, kind = orig.kind, doc = orig.doc, source = orig.source,
  }
  local ok, err = pcall(function()
    registry.define({
      name = "fn.system_prompt_env",
      kind = "fn",
      doc = "test: static env layer",
      source = [[return function() return "ENV-OVERRIDE-MARKER" end]],
    })
    local prompt = registry.call("fn.system_prompt")
    assert(prompt:find("ENV-OVERRIDE-MARKER", 1, true),
      "composer did not pick up the redefined env layer")
  end)
  registry.define(orig_spec) -- restore the real layer
  assert(ok, err)
  assert(registry.call("fn.system_prompt_env"):find("cwd: ", 1, true),
    "env layer not restored after the override")
end)

-- --------------------------------------------------------------- new_session
case("new_session writes the composed prompt into the system block", function()
  cd(deep) -- AGENTS.md with agents-norm-marker is present here
  local ok, err = pcall(function()
    local bufnr = state.new_session()
    local parsed = state.parse(bufnr)
    assert(type(parsed.system) == "string" and parsed.system ~= "", "system block empty")
    assert(parsed.system:find("coding agent running inside Neovim", 1, true),
      "core layer missing from session system block")
    assert(parsed.system:find("agents-norm-marker", 1, true),
      "AGENTS.md content missing from session system block")
  end)
  cd(orig_cwd)
  assert(ok, err)
end)

-- ----------------------------------------------------------- self-extension
case("core layer carries the self-extension triggers and .straps.lua persistence", function()
  local core = registry.call("fn.system_prompt_core")
  assert(core:find(".straps.lua", 1, true), "core prompt does not mention .straps.lua")
  assert(core:find("twice", 1, true), "core prompt missing the done-it-twice trigger rule")
end)

-- ----------------------------------------------------------------- env VCS
-- Runs in a freshly init'd repo, not the straps checkout: a flake/tarball
-- copy of this source tree has no .git, so the checkout is not a reliable
-- fixture.
case("env layer reports version control from a git repo root", function()
  if vim.fn.executable("git") == 0 then
    return -- no git, nothing to detect
  end
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  vim.fn.system({ "git", "init", "-q", dir })
  cd(dir)
  local ok, err = pcall(function()
    local env = registry.call("fn.system_prompt_env")
    assert(env:find("vcs: ", 1, true), "vcs line missing:\n" .. env)
    assert(env:find("git", 1, true), "vcs line should mention git:\n" .. env)
  end)
  cd(orig_cwd)
  assert(ok, err)
end)

-- ------------------------------------------------------------ env top-level
case("env layer lists the top-level shape of cwd, dirs first", function()
  cd(root)
  local ok, err = pcall(function()
    local env = registry.call("fn.system_prompt_env")
    local line = env:match("top%-level: ([^\n]*)")
    assert(line, "top-level line missing:\n" .. env)
    assert(line:find("lua/", 1, true), "top-level should list lua/: " .. line)
    assert(line:find("tests/", 1, true), "top-level should list tests/: " .. line)
    assert(not line:find("%.git"), "hidden entries should be excluded: " .. line)
    -- Dirs come before files: lua/ must precede README.md.
    assert(line:find("lua/", 1, true) < line:find("README.md", 1, true),
      "dirs should be listed before files: " .. line)
  end)
  cd(orig_cwd)
  assert(ok, err)
end)

if failed then
  print("FAILED")
  os.exit(1)
end
print("ALL PASS")
os.exit(0)
