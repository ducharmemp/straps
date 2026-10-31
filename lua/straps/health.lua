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

-- The API key section for the provider check_provider_name resolves: the
-- base URL, the slot's key_fn verdict (which source it returned, so a
-- redefined or reordered key fn is described as it runs), the ChatGPT
-- login's expiry and problems. A missing key is an error when key_required,
-- else info. Never print the key: report only where it came from.
local function check_api_key()
  local ok_straps, straps = pcall(require, "straps")
  local config = (ok_straps and type(straps) == "table" and rawget(straps, "config")) or {}
  local ok_name, provider = check_provider_name(config)
  if not ok_name then return end
  local providers = require("straps.provider")
  local slot = providers.provider_slot(provider)
  local base_url, url_err = providers.base_url(provider, config)

  health.start("straps: API key (" .. provider .. ")")
  if base_url then
    health.info(slot.base_url_key .. ": " .. providers.redact_url(base_url))
  else
    health.error(url_err .. "; every " .. provider .. " request will fail",
      { "set " .. slot.base_url_key .. " to a URL string in setup{}, or remove it for the default" })
  end
  local registry = try(function() return require("straps.registry") end)
  local entry = registry and registry.get(slot.key_fn)
  if not entry then
    if provider == "openai" and (config.layers or {}).openai == false then
      health.info("openai layer disabled (setup{ layers = { openai = false } }) — skipping key check")
    else
      health.warn(slot.key_fn .. " is not registered (setup() has not run yet)",
        { "Call require('straps').setup{} in your config." })
    end
    return
  end
  local login_cmd = ":StrapsLogin " .. provider .. " key"
  local store_err

  -- Problems with the stored key: a raise (mode, unreadable, bad content)
  -- or a path that holds no usable key.
  if not registry.get("fn.api_key_store") then
    health.warn("fn.api_key_store is not registered (setup() has not run yet)",
      { "Call require('straps').setup{} in your config." })
  else
    local ok, key, path = pcall(registry.call, "fn.api_key_store", provider)
    local st = ok and not key and path and try(function() return vim.uv.fs_stat(path) end)
    if not ok then
      store_err = tostring(key)
      health.error((store_err:gsub("^straps: ", "")))
    elseif st and st.type ~= "file" then
      health.warn(path .. " is a " .. st.type .. ", not a key file", { "remove it, then run " .. login_cmd })
    elseif st then
      health.warn("stored key file " .. path .. " has no key on its first line", { "put the key on its first line" })
    end
  end

  local dir = require("straps.oauth").config_dir()
  if provider == "openai" and dir then
    local login = dir .. "/" .. require("straps.oauth").LOGIN_FILE
    local lst = try(function() return vim.uv.fs_stat(login) end)
    if lst and lst.type == "file" then
      if lst.mode % 64 ~= 0 then
        health.error(("%s is accessible by group/other (mode %03o)"):format(login, lst.mode % 4096),
          { "run: chmod 600 " .. login })
      end
      local cred = try(function() return registry.call("fn.openai_oauth_credential") end)
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
    end
  end

  local ok, key, source = pcall(registry.call, slot.key_fn, { base_url = base_url, refresh = false })
  local hint = "run " .. login_cmd .. " or set $" .. table.concat(slot.key_env, " or $") .. " (read by the default " .. slot.key_fn .. ")"
  local from = source and (", source: " .. tostring(source)) or ""
  -- provider.clean_key is the rule requests apply (through auth_headers), so
  -- health cannot report OK for a key every request refuses.
  local clean, why
  if ok then clean, why = providers.clean_key(key) end
  if clean then
    health.ok(slot.key_fn .. " resolves a key (" .. #clean .. " chars" .. from .. ")")
  elseif ok and why ~= "empty" then
    health.error(slot.key_fn .. " resolves a key that requests refuse" .. (source and (" (source: " .. tostring(source) .. ")") or ""),
      { "the key has " .. why, "rewrite it: " .. hint })
  elseif not ok and store_err == tostring(key) then
    health.error(slot.key_fn .. " raised the stored key error above")
  elseif not ok and url_err and tostring(key) == "straps: " .. url_err then
    health.error(slot.key_fn .. " raised the base URL error above")
  elseif not ok then
    health.error(slot.key_fn .. " raised", { tostring(key) })
  elseif slot.key_required then
    health.error(slot.key_fn .. " returned no key", { hint })
  else
    health.info("no API key; requests send no auth header. If the server requires a key, " .. hint)
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
    local base_url = providers.base_url(slot.name, cfg)
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
