-- straps/health.lua — `:checkhealth straps`.
-- Owns the user-facing diagnosis of everything that can be wrong before a
-- session even starts: curl, the API key, a writable session dir, the
-- transcript parser, the .straps.lua trust state and the registry itself.
-- Read-only and never throws: every probe is pcall-wrapped, because the
-- whole point is to run when things are broken.

local M = {}

local health = vim.health

-- Every probe goes through this: a check that errors would take the report
-- down with it, which is exactly when the report is needed. Returns nil on
-- failure so callers can branch.
local function try(fn)
  local ok, res = pcall(fn)
  if ok then
    return res
  end
  return nil, tostring(res)
end

local function config()
  local ok, straps = pcall(require, "straps")
  if ok and type(straps) == "table" then
    return rawget(straps, "config") or {}
  end
  return {}
end

-- Is this Neovim new enough? DESIGN.md targets >= 0.11 (vim.system, vim.uv,
-- chunk-list foldtext).
local function check_nvim()
  health.start("straps: neovim")
  local v = vim.version()
  local s = ("%d.%d.%d"):format(v.major, v.minor, v.patch)
  if vim.fn.has("nvim-0.11") == 1 then
    health.ok("neovim " .. s .. " (>= 0.11 required)")
  else
    health.error("neovim " .. s .. " is too old",
      { "straps targets Neovim >= 0.11 (vim.system, vim.uv, chunk-list foldtext)." })
  end
end

-- curl is the only external dependency.
local function check_curl()
  health.start("straps: dependencies")
  local exe = vim.fn.exepath("curl")
  if exe ~= "" then
    local out = try(function()
      return vim.system({ "curl", "--version" }, { text = true }):wait(2000).stdout
    end)
    local first = out and vim.split(out or "", "\n")[1] or nil
    health.ok("curl: " .. exe .. (first and ("  (" .. first .. ")") or ""))
  else
    health.error("curl not found on PATH",
      { "fn.provider shells out to curl for the streaming request.",
        "Install curl, or redefine fn.provider to use another transport." })
  end
  -- Optional, but the whole editor-native tool set is thinner without them.
  local rg = vim.fn.exepath("rg")
  if rg ~= "" then
    health.ok("ripgrep: " .. rg .. "  (tool.grep uses it; falls back to grep -rn)")
  else
    health.info("ripgrep not found — tool.grep falls back to `grep -rn`")
  end
end

-- The API key, via fn.api_key / fn.openai_api_key when the registry is loaded
-- (so a redefined key source is what gets reported), else the same default
-- logic. Probes whichever provider config.provider selects. Never print the
-- key: report only where it came from.
local function check_api_key()
  local ok_straps, straps = pcall(require, "straps")
  local config = (ok_straps and type(straps) == "table" and rawget(straps, "config")) or {}
  local provider = config.provider
  if provider == nil or provider == "" then
    local ok_pref, pref = pcall(function()
      return require("straps.registry").try_call("fn.provider_pref")
    end)
    if ok_pref and type(pref) == "string" and pref ~= "" then provider = pref end
  end
  if provider ~= "openai" then provider = "anthropic" end
  local openai = provider == "openai"

  local env_var = openai and "OPENAI_API_KEY" or "ANTHROPIC_API_KEY"
  local entry_name = openai and "fn.openai_api_key" or "fn.api_key"
  local file_name = openai and "openai_api_key" or "api_key"

  health.start("straps: API key (" .. (openai and "openai" or "anthropic") .. ")")
  local registry = try(function() return require("straps.registry") end)
  local entry = registry and registry.get(entry_name)
  if not entry then
    health.warn(entry_name .. " is not registered (setup() has not run yet)",
      { "Call require('straps').setup{} in your config." })
  end

  if vim.env[env_var] and vim.env[env_var] ~= "" then
    health.ok("$" .. env_var .. " is set (" .. #vim.env[env_var] .. " chars)")
  else
    health.info("$" .. env_var .. " is not set — falling back to the key file")
  end

  -- The key file gets its own probe because its failure mode (mode 600) is
  -- the one users hit and cannot see.
  local config_home = vim.env.XDG_CONFIG_HOME
  if not config_home or config_home == "" then
    local home = vim.env.HOME
    config_home = (home and home ~= "") and (home .. "/.config") or nil
  end
  local path = config_home and (config_home .. "/straps/" .. file_name)
  local st = path and try(function() return vim.uv.fs_stat(path) end)
  if st and st.type == "file" then
    if st.mode % 64 ~= 0 then
      health.error(("%s is accessible by group/other (mode %03o)")
        :format(path, st.mode % 4096),
        { "run: chmod 600 " .. path })
    else
      health.ok("key file: " .. path .. " (mode 600)")
    end
  elseif path then
    health.info("no key file at " .. path)
  end

  -- The verdict that matters: does the registered entry actually yield a key?
  if entry then
    local key, err = try(function() return registry.call(entry_name) end)
    if type(key) == "string" and key ~= "" then
      health.ok(entry_name .. " resolves a key (" .. #key .. " chars)")
    else
      health.error(entry_name .. " did not return a key", { err or "unknown error" })
    end
  end
end

-- Where transcripts live, and whether we can actually write there — the
-- difference between durable sessions and the silent ephemeral fallback.
local function check_sessions()
  health.start("straps: sessions")
  local state = try(function() return require("straps.state") end)
  if not state then
    health.error("could not require straps.state")
    return
  end
  local cfg = config()
  local dir = state.session_dir()
  if not dir then
    health.error("session dir is not usable: "
      .. tostring(cfg.session_dir or (vim.fn.stdpath("data") .. "/straps/sessions")),
      { "New sessions degrade to ephemeral (nofile) buffers that vanish on exit.",
        "Set config.session_dir to a writable path." })
    return
  end
  if vim.fn.filewritable(dir) == 2 then
    local sessions = state.list_sessions()
    local newest = sessions[1]
        and (" — newest: " .. sessions[1].name
          .. " (" .. os.date("%Y-%m-%d %H:%M", sessions[1].mtime) .. ")")
      or ""
    health.ok(("session dir writable: %s  [%d transcript%s]%s")
      :format(dir, #sessions, #sessions == 1 and "" or "s", newest))
    if cfg.session_dir then
      health.info("(from config.session_dir)")
    end
  else
    health.error("session dir is not writable: " .. dir,
      { "New sessions degrade to ephemeral buffers; :StrapsResume will find nothing." })
  end
end

-- The transcript grammar has two implementations; the tree-sitter one is
-- optional but decides which highlighting engine a .straps buffer gets.
local function check_parser()
  health.start("straps: transcript rendering")
  local added = try(function() return vim.treesitter.language.add("straps") end)
  if added then
    health.ok("tree-sitter parser 'straps' available (markdown/JSON injection active)")
    for _, q in ipairs({ "highlights", "injections" }) do
      local got = try(function() return vim.treesitter.query.get("straps", q) end)
      if got then
        health.ok("query straps/" .. q .. ".scm found")
      else
        health.warn("query straps/" .. q .. ".scm missing")
      end
    end
  else
    health.info("no tree-sitter parser 'straps' — falling back to syntax/straps.vim",
      { "The fallback highlights fine; the parser adds markdown/JSON injection.",
        "Build it from tree-sitter-straps/ (generated src/ is committed)." })
  end
  local cfg = config()
  if cfg.render == false then
    health.info("config.render = false — the conceal/extmark layer is off (raw markers)")
  else
    health.ok("fn.render wiring enabled (config.render)")
  end
end

-- .straps.lua is executed Lua; its trust state is a security fact the user
-- should be able to read without digging in stdpath("data").
local function check_project()
  health.start("straps: project registry (.straps.lua)")
  local found = try(function()
    return vim.fs.find(".straps.lua",
      { upward = true, path = vim.fn.getcwd(), type = "file" })[1]
  end)
  if not found then
    health.info("no .straps.lua found upward from " .. vim.fn.getcwd())
    return
  end
  local path = vim.fn.fnamemodify(found, ":p")
  local content = try(function()
    local f = assert(io.open(path, "r"))
    local text = f:read("*a")
    f:close()
    return text
  end)
  if not content then
    health.warn("found but unreadable: " .. path)
    return
  end
  local hash = vim.fn.sha256(content)
  local store_path = vim.fn.stdpath("data") .. "/straps/trusted.json"
  local store = try(function()
    local f = io.open(store_path, "r")
    if not f then
      return {}
    end
    local text = f:read("*a")
    f:close()
    return vim.json.decode(text)
  end) or {}
  if type(store) ~= "table" then
    store = {}
  end
  if store[path] == hash then
    health.ok("trusted: " .. path .. "  (sha256 matches the trust store)")
  elseif store[path] then
    health.warn("CHANGED since it was trusted: " .. path,
      { "The next session will prompt before executing it. Review the diff first." })
  else
    health.warn("not trusted: " .. path,
      { "The next session will prompt before executing it. Review it first." })
  end
  health.info("trust store: " .. store_path)
end

-- The registry is the plugin: report what is actually loaded, and call out
-- entries that shadow a default (the user's own redefinitions).
local function check_registry()
  health.start("straps: registry")
  local registry = try(function() return require("straps.registry") end)
  if not registry then
    health.error("could not require straps.registry")
    return
  end
  local counts, redefined = {}, {}
  for _, kind in ipairs({ "tool", "hook", "fn", "skill" }) do
    local names = registry.names(kind)
    counts[kind] = #names
    for _, name in ipairs(names) do
      local e = registry.get(name)
      if e and (e.version or 1) > 1 then
        redefined[#redefined + 1] = name .. " v" .. e.version
      end
    end
  end
  if counts.tool == 0 then
    health.error("no tools registered — setup() has not run",
      { "Call require('straps').setup{} in your config." })
    return
  end
  health.ok(("%d tools, %d hooks, %d fns, %d skills")
    :format(counts.tool, counts.hook, counts.fn, counts.skill))
  -- The load-bearing entries: a missing one means a broken session, and this
  -- is cheaper to read than :StrapsRegistry.
  for _, name in ipairs({ "fn.provider", "fn.system_prompt", "fn.build_tools",
    "hook.confirm", "tool.read_file", "tool.write_file" }) do
    if not registry.get(name) then
      health.error("missing core entry: " .. name)
    end
  end
  if #redefined > 0 then
    health.info("redefined entries: " .. table.concat(redefined, ", "))
  end
  local cfg = config()
  if cfg.log_file then
    if vim.fn.filewritable(vim.fn.fnamemodify(cfg.log_file, ":h")) == 2 then
      health.ok("fn.log writing to " .. cfg.log_file)
    else
      health.warn("config.log_file is set but its directory is not writable: " .. cfg.log_file)
    end
  else
    health.info("config.log_file unset — fn.log is a no-op")
  end
end

-- Model / effort: the two settings whose mismatch 400s a whole request.
local function check_model()
  health.start("straps: model")
  local cfg = config()
  local model = cfg.model
  if not model then
    health.warn("config.model is unset (setup() has not run?)")
    return
  end
  local tag, listed
  for _, m in ipairs(cfg.models or {}) do
    if m.id == model then
      listed, tag = true, m.thinking
    end
  end
  health.ok("model: " .. model .. (cfg.base_url and ("  @ " .. cfg.base_url) or ""))
  local effort = cfg.effort or "off"
  if not listed then
    health.info(("model is not in config.models — no thinking block will be sent"
      .. " (effort = %s is inert for it)"):format(effort))
  elseif effort == "off" then
    health.info("effort: off — no thinking block sent (thinking style: "
      .. tostring(tag) .. ")")
  else
    health.ok(("effort: %s  (thinking style: %s)"):format(effort, tostring(tag)))
  end
  -- max_tokens is nil by default (per-model max output, else default_max_tokens);
  -- that is the healthy state, not a warning. A value set explicitly is a hard
  -- cap and must be a positive number.
  local turns_info = "max_turns: " .. tostring(cfg.max_turns)
    .. ", stall_limit: " .. tostring(cfg.stall_limit)
  if cfg.max_tokens == nil then
    local model_max
    for _, m in ipairs(cfg.models or {}) do
      if m.id == model then model_max = tonumber(m.max_output) end
    end
    local source = model_max and ("model max " .. model_max)
      or ("default_max_tokens " .. tostring(cfg.default_max_tokens))
    health.ok("max_tokens: auto (" .. source .. "), " .. turns_info)
  elseif (tonumber(cfg.max_tokens) or 0) <= 0 then
    health.warn("config.max_tokens is set but not a positive number")
  else
    health.ok("max_tokens: " .. cfg.max_tokens .. " (explicit cap), " .. turns_info)
  end
end

-- Running agents: a session that is still streaming when the user quits is
-- a real (and currently unguarded) way to lose work.
local function check_runs()
  health.start("straps: active sessions")
  local loop = try(function() return require("straps.loop") end)
  if not loop or not loop.running_sessions then
    health.info("no loop module loaded")
    return
  end
  local running = try(function() return loop.running_sessions() end) or {}
  if #running == 0 then
    health.ok("no runs in flight")
    return
  end
  health.warn(("%d run%s in flight"):format(#running, #running == 1 and "" or "s"),
    { "Quitting Neovim now cancels them; :StrapsStop on each buffer to end cleanly." })
  for _, bufnr in ipairs(running) do
    local name = try(function() return vim.api.nvim_buf_get_name(bufnr) end) or "?"
    health.info(("  buffer %d: %s"):format(bufnr, vim.fn.fnamemodify(name, ":t")))
  end
end

--- `:checkhealth straps` entry point.
function M.check()
  check_nvim()
  check_curl()
  check_api_key()
  check_sessions()
  check_parser()
  check_project()
  check_registry()
  check_model()
  check_runs()
end

return M
