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

-- The provider fn.provider would use outside a session buffer
-- (provider.resolve_provider with no buffer), plus the read error when the
-- provider pref file exists but cannot be read. The name may be unknown;
-- check_provider_name reports both, because fn.provider raises on them.
local function active_provider(config)
  local ok, provider, _, err = pcall(require("straps.provider").resolve_provider, nil, config)
  if not ok then return config.provider, tostring(provider) end
  return provider, err
end

-- Reports the active provider: an error for an unreadable pref file or an
-- unknown name, either of which makes every request fail in fn.provider.
-- Returns true and the name only for a known provider, so the key and model
-- sections run only then.
local function check_provider_name(config)
  health.start("straps: provider")
  local name, err = active_provider(config)
  local providers = require("straps.provider")
  if err then
    health.error(err .. "; every request will fail",
      { "fix the file's permissions or contents, or delete it and run :StrapsProvider" })
    return false
  end
  if not providers.is_provider(name) then
    health.error("unknown provider " .. tostring(name) .. "; every request will fail",
      { "set provider in setup{} or run :StrapsProvider; valid names: "
        .. table.concat(providers.provider_names(), ", ") })
    return false
  end
  health.ok("provider: " .. name)
  return true, name
end

-- llama-server needs a key only when it runs with --api-key, so a missing key
-- is reported as info. The key comes from fn.llamacpp_api_key when it is
-- registered, so a redefined key source is what gets reported.
local function check_llamacpp_key(config)
  health.start("straps: API key (llamacpp)")
  local providers = require("straps.provider")
  health.info("llamacpp_base_url: " .. providers.redact_url(providers.llamacpp_base_url(config)))
  local registry = try(function() return require("straps.registry") end)
  local key
  if registry and registry.get("fn.llamacpp_api_key") then
    local ok, got = pcall(registry.call, "fn.llamacpp_api_key",
      { base_url = require("straps.provider").llamacpp_base_url(config) })
    if not ok then
      health.error("fn.llamacpp_api_key raised", { tostring(got) })
      return
    end
    key = got
  else
    for _, name in ipairs({ "LLAMACPP_API_KEY", "LLAMA_API_KEY" }) do
      if not key and vim.env[name] and vim.env[name] ~= "" then key = vim.env[name] end
    end
  end
  if type(key) == "string" and key ~= "" then
    health.ok("API key set (" .. #key .. " chars), sent as Authorization: Bearer")
  else
    health.info("no API key (set $LLAMACPP_API_KEY or $LLAMA_API_KEY if llama-server runs with --api-key)")
  end
end

-- The API key, via fn.api_key / fn.openai_api_key when the registry is loaded
-- (so a redefined key source is what gets reported), else the same default
-- logic; llamacpp goes to check_llamacpp_key. Probes the provider
-- active_provider resolves. Never print the key: report only where it came
-- from.
local function check_api_key()
  local ok_straps, straps = pcall(require, "straps")
  local config = (ok_straps and type(straps) == "table" and rawget(straps, "config")) or {}
  local ok_name, provider = check_provider_name(config)
  if not ok_name then return end
  if provider == "llamacpp" then
    check_llamacpp_key(config)
    return
  end
  local openai = provider == "openai"

  local env_var = openai and "OPENAI_API_KEY" or "ANTHROPIC_API_KEY"
  local entry_name = openai and "fn.openai_api_key" or "fn.api_key"
  local file_name = openai and "openai_api_key" or "api_key"

  health.start("straps: API key (" .. (openai and "openai" or "anthropic") .. ")")
  local registry = try(function() return require("straps.registry") end)
  local entry = registry and registry.get(entry_name)
  if not entry then
    if openai and entry_name == "fn.openai_api_key" and (config.layers or {}).openai == false then
      health.info("openai layer disabled (setup{ layers = { openai = false } }) — skipping key check")
    else
      health.warn(entry_name .. " is not registered (setup() has not run yet)",
        { "Call require('straps').setup{} in your config." })
    end
  end

  if vim.env[env_var] and vim.env[env_var] ~= "" then
    health.ok("$" .. env_var .. " is set (" .. #vim.env[env_var] .. " chars)")
  else
    health.info("$" .. env_var .. " is not set")
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

  if openai and entry and config_home then
    local login = config_home .. "/straps/openai_oauth.json"
    local lst = try(function() return vim.uv.fs_stat(login) end)
    if lst and lst.type == "file" then
      if lst.mode % 64 ~= 0 then
        health.error(("%s is accessible by group/other (mode %03o)"):format(login, lst.mode % 4096),
          { "run: chmod 600 " .. login })
      end
      local cred = registry and try(function() return registry.call("fn.openai_oauth_credential") end)
      if type(cred) == "table" then
        if type(cred.client_id) ~= "string" or cred.client_id == "" then
          health.error("ChatGPT login at " .. login .. " has no client id", { "run :StrapsLogin openai" })
        else
          local sec = vim.uv.gettimeofday()
          local left = (tonumber(cred.expires) or 0) / 1000 - sec
          health.ok(("ChatGPT login: %s (access token %s)"):format(login,
            left > 0 and ("valid for " .. math.ceil(left / 60) .. " min") or "expired; refreshes on next request"))
        end
      end
    else
      health.info("no ChatGPT login (run :StrapsLogin openai to sign in)")
    end
  end

  -- The verdict that matters: does the registered entry actually yield a key?
  if entry then
    local ok, key, source = pcall(registry.call, entry_name, { refresh = false })
    if ok and type(key) == "string" and key ~= "" then
      health.ok(entry_name .. " resolves a key (" .. #key .. " chars"
        .. (source and (", source: " .. tostring(source)) or "") .. ")")
    else
      health.error(entry_name .. " did not return a key", { ok and "unknown error" or tostring(key) })
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

-- The global corpus (stdpath("config")/straps/init.lua) is executed Lua too,
-- but trusted implicitly (it is in the user's own config dir). Report only
-- whether it exists and is readable — there is no trust state to show.
local function check_global()
  local path = vim.fn.stdpath("config") .. "/straps/init.lua"
  health.start("straps: global corpus (" .. path .. ")")
  if vim.fn.filereadable(path) == 0 then
    health.info("no global corpus (optional; loaded for every session when present)")
    return
  end
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
  local chunk, err = load(content, "@" .. path)
  if not chunk then
    health.error("does not compile: " .. path, { tostring(err) })
    return
  end
  health.ok("present and compiles: " .. path
    .. "  (executed for every session, before any project .straps.lua)")
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
  local guard_names = {}
  for _, g in ipairs(registry.guard_entries()) do
    guard_names[#guard_names + 1] = g.name
  end
  health.ok(("%d tools, %d hooks, %d fns, %d skills, %d guards")
    :format(counts.tool, counts.hook, counts.fn, counts.skill, #guard_names))
  if #guard_names > 0 then
    health.info("guards (" .. (registry.guards_frozen() and "frozen" or "not yet frozen") .. "): "
      .. table.concat(guard_names, ", "))
  end
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

-- config.layers gates whole registration groups (see init.lua's layers
-- config). A layer left on but missing its sentinel entry means setup()
-- never ran or its registration failed; a layer turned off is expected
-- absence, not a fault.
local function check_layers()
  health.start("straps: layers")
  local cfg = config()
  local layers = cfg.layers or {}
  local registry = try(function() return require("straps.registry") end)
  local sentinels = {
    editor = "tool.definition",
    openai = "fn.provider_openai",
  }
  for _, name in ipairs({ "editor", "openai" }) do
    local enabled = layers[name] ~= false
    local sentinel = sentinels[name]
    local present = registry and registry.get(sentinel)
    if enabled and not present then
      health.error(name .. " layer enabled but entries missing — setup() not run, or registration failed")
    elseif enabled then
      health.ok(name .. " layer enabled (" .. sentinel .. " registered)")
    else
      health.info(name .. " layer disabled (setup{ layers = { " .. name .. " = false } })")
    end
  end
end

-- Model / effort: the two settings whose mismatch 400s a whole request.
local function check_model()
  health.start("straps: model")
  local cfg = config()
  local providers = require("straps.provider")
  local name = active_provider(cfg)
  if not providers.is_provider(name) then
    health.info("skipped: no known provider (see straps: provider)")
    return
  end
  local slot = providers.provider_slot(name)
  local model, model_err = providers.resolve_model(slot.name, nil, cfg)
  local entry = providers.model_entry(slot.name, model, cfg)
  if model_err then
    health.error(model_err .. "; every " .. slot.name .. " request will fail",
      { "fix or delete the file, or pick a model with :StrapsModel" })
  elseif not model then
    health.warn("config." .. slot.model_key .. " is unset",
      { "set " .. slot.model_key .. " in setup{} or run :StrapsModel" })
  else
    local style = slot.name ~= "openai" and ("thinking style: " .. tostring(entry and entry.thinking)) or nil
    local base_url = slot.name == "llamacpp" and providers.llamacpp_base_url(cfg) or cfg[slot.base_url_key]
    health.ok(slot.name .. " model: " .. model .. (base_url and ("  @ " .. providers.redact_url(base_url)) or ""))
    local effort = cfg.effort or "off"
    local applies, why = require("straps.provider").effort_applies(slot.name, entry, effort, cfg.efforts)
    if not entry then
      health.info(("model is not in config.%s — no thinking or reasoning is sent"
        .. " (effort = %s is inert for it)"):format(slot.models_key, effort))
    elseif effort == "off" then
      health.info("effort: off — no thinking or reasoning is sent" .. (style and (" (" .. style .. ")") or ""))
    elseif not applies then
      health.info(("effort = %s is inert for %s: %s"):format(effort, model, why))
    else
      health.ok(("effort: %s  (%s)"):format(effort, style or "reasoning"))
    end
  end
  -- max_tokens is nil by default (per-model max output, else default_max_tokens);
  -- that is the healthy state, not a warning. A value set explicitly is a hard
  -- cap and must be a positive number.
  local turns_info = "max_turns: " .. tostring(cfg.max_turns)
    .. ", stall_limit: " .. tostring(cfg.stall_limit)
  if cfg.max_tokens == nil then
    local model_max = slot.name ~= "openai" and entry and tonumber(entry.max_output) or nil
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
    { "Quitting Neovim now cancels them and kills their spawned processes;"
      .. " :StrapsStop on each buffer to end cleanly." })
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
  check_global()
  check_project()
  check_registry()
  check_layers()
  check_model()
  check_runs()
end

return M
