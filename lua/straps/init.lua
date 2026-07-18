-- straps/init.lua — setup(), merged config, wiring.
-- Owns the plugin config table and the setup() entry point that registers
-- the default provider, tools, hooks and UI. Idempotent: registration uses
-- registry.define_default, so re-running setup never clobbers redefinitions.

local M = {}

M.config = {
  model = "claude-sonnet-5",
  max_tokens = 8192,
  max_turns = 64,
  max_tool_result_bytes = 100000,
  cache = true,
  compact_keep_turns = 2,
  -- Extra instruction files for fn.system_prompt_project, included verbatim
  -- after the auto-discovered AGENTS.md/CLAUDE.md. Paths, absolute or
  -- relative to cwd; unreadable entries are skipped silently.
  instructions_files = {},
  -- Directory for durable, file-backed session transcripts (*.straps).
  -- session_dir = nil means the computed default:
  -- stdpath("data")/straps/sessions (created on first use). Set it to an
  -- absolute path to relocate saved sessions. A literal nil stores nothing,
  -- so state.session_dir() falls back to the default — this line documents it.
  session_dir = nil,
  -- auto_compact_bytes intentionally absent (nil = off); vim.tbl_deep_extend
  -- ignores nil defaults anyway. Documented in the README.

  -- Transcript rendering (fn.render): a display-only layer over the raw
  -- %%[straps:KIND]%% marker buffer — conceal + extmarks + folds give each
  -- block a small categorical colored mark and collapse tool calls to a
  -- one-line summary. Buffer text, `modified`, parse and persist are never
  -- touched. render = false skips the wiring entirely (raw markers show;
  -- also reachable per-window with :set conceallevel=0). tools_expanded =
  -- true folds tool_use/tool_result blocks OPEN by default.
  render = true,
  tools_expanded = false,

  -- :StrapsModel picker choices. Each entry is { id, label?, thinking? }.
  -- `thinking` tags which extended-thinking mechanism the model speaks
  -- (checked against Anthropic's /v1/models capabilities.effort.supported):
  --   "adaptive" — thinking={type="adaptive"} + output_config={effort=...}
  --                (newer models: sonnet-5, opus-4-6..4-8, sonnet-4-6, ...)
  --   "budget"   — thinking={type="enabled", budget_tokens=...}
  --                (older models: opus-4-5, opus-4-1, sonnet-4-5, haiku-4-5)
  -- fn.provider reads the entry matching config.model to pick the right
  -- shape; an unlisted/custom model sends no thinking block at all (safest
  -- default — guessing wrong 400s the whole request). Picking one here sets
  -- config.model.
  models = {
    { id = "claude-opus-4-8", label = "Opus 4.8 — most capable, slowest", thinking = "adaptive" },
    { id = "claude-sonnet-5", label = "Sonnet 5 — balanced (default)", thinking = "adaptive" },
    { id = "claude-sonnet-4-6", label = "Sonnet 4.6", thinking = "adaptive" },
    { id = "claude-haiku-4-5-20251001", label = "Haiku 4.5 — fastest, cheapest", thinking = "budget" },
  },

  -- :StrapsEffort picker choices. `level` feeds output_config.effort for
  -- "adaptive" models; `budget_tokens` feeds thinking.budget_tokens for
  -- "budget" models (fn.provider picks whichever applies to config.model).
  -- Neither field (or effort = "off") means thinking is disabled.
  -- config.effort names the currently active entry (by `name`).
  effort = "off",
  efforts = {
    { name = "off" },
    { name = "low", level = "low", budget_tokens = 4000 },
    { name = "medium", level = "medium", budget_tokens = 10000 },
    { name = "high", level = "high", budget_tokens = 24000 },
  },
}

-- (path .. "\n" .. hash) -> true for every .straps.lua content already
-- executed in this Neovim session: the same content runs at most once.
local project_loaded = {}

local function trusted_store_path(opts)
  return (opts and opts.store_path)
    or (vim.fn.stdpath("data") .. "/straps/trusted.json")
end

-- pcall-safe store IO: a missing or corrupt store reads as empty; a failed
-- write is silently dropped (trust just gets asked for again next time).
local function read_trust_store(path)
  local ok, store = pcall(function()
    local f = io.open(path, "r")
    if not f then
      return nil
    end
    local text = f:read("*a")
    f:close()
    return vim.json.decode(text)
  end)
  return (ok and type(store) == "table") and store or {}
end

local function write_trust_store(path, store)
  pcall(function()
    local dir = vim.fn.fnamemodify(path, ":h")
    if dir ~= "" and vim.fn.isdirectory(dir) == 0 then
      vim.fn.mkdir(dir, "p")
    end
    local f = assert(io.open(path, "w"))
    f:write(vim.json.encode(store))
    f:close()
  end)
end

--- Load the nearest .straps.lua upward from cwd — the project registry:
--- plain Lua (registry.define calls; registry.dump() output is valid
--- content). direnv-style trust: content is executed only if its sha256
--- matches the trust store (stdpath("data")/straps/trusted.json), or the
--- user confirms via a prompt defaulting to No (headless: skipped), or
--- opts.trust_all is set (tests/automation). Confirming records the hash,
--- so the same content loads silently from then on; any edit re-prompts.
--- The same (path, hash) executes at most once per Neovim session.
--- opts.store_path overrides the trust store location (tests).
--- Returns loaded(bool), info(string). Never throws.
function M.load_project_registry(opts)
  opts = opts or {}
  local found = vim.fs.find(".straps.lua",
    { upward = true, path = vim.fn.getcwd(), type = "file" })[1]
  if not found then
    return false, "none"
  end
  local path = vim.fn.fnamemodify(found, ":p")

  local ok_read, content = pcall(function()
    local f = assert(io.open(path, "r"))
    local text = f:read("*a")
    f:close()
    return text
  end)
  if not ok_read or type(content) ~= "string" then
    return false, "unreadable: " .. path
  end

  local hash = vim.fn.sha256(content)
  local key = path .. "\n" .. hash
  if project_loaded[key] then
    return true, "already loaded: " .. path
  end

  local store_path = trusted_store_path(opts)
  local store = read_trust_store(store_path)
  if not (opts.trust_all == true or store[path] == hash) then
    local choice = 0
    pcall(function()
      choice = vim.fn.confirm(
        ("straps: found %s (not trusted or changed since last trust)."
          .. " Execute it? Review it first."):format(path),
        "&Yes\n&No", 2)
    end)
    if choice ~= 1 then
      pcall(vim.notify,
        "straps: skipped untrusted " .. path
          .. " (review it, then reopen the session and confirm to trust it)",
        vim.log.levels.WARN)
      return false, "untrusted: " .. path
    end
  end

  -- Trusted (stored hash, explicit Yes, or trust_all): record the hash so
  -- this exact content loads silently from now on, then execute it.
  store[path] = hash
  write_trust_store(store_path, store)

  local chunk, load_err = load(content, "@" .. path)
  if not chunk then
    pcall(vim.notify, "straps: " .. path .. " does not compile: "
      .. tostring(load_err), vim.log.levels.ERROR)
    return false, "load error: " .. tostring(load_err)
  end
  local ok_run, run_err = pcall(chunk)
  if not ok_run then
    pcall(vim.notify, "straps: error executing " .. path .. ": "
      .. tostring(run_err), vim.log.levels.ERROR)
    return false, "error: " .. tostring(run_err)
  end
  project_loaded[key] = true
  return true, "loaded: " .. path
end

--- Merge user opts into M.config and register all defaults.
--- Safe to call more than once: define_default skips existing entries,
--- so runtime redefinitions (yours or the agent's) survive.
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  require("straps.provider").register()
  require("straps.tools").register()
  require("straps.editor").register()
  require("straps.ui").setup()
  return M
end

-- Lazy accessors for user config files: require("straps").registry etc.
setmetatable(M, {
  __index = function(_, key)
    if key == "registry" then
      return require("straps.registry")
    elseif key == "state" then
      return require("straps.state")
    elseif key == "loop" then
      return require("straps.loop")
    end
  end,
})

return M
