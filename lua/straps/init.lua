-- straps/init.lua — setup(), merged config, wiring.
-- Owns the plugin config table and the setup() entry point that registers
-- the default provider, tools, hooks and UI. Idempotent: registration uses
-- registry.define_default, so re-running setup never clobbers redefinitions.

local M = {}

M.config = {
  -- Which backend fn.provider dispatches to: "anthropic" (the Anthropic
  -- Messages API via fn.provider_anthropic) or "openai" (OpenAI Chat
  -- Completions via fn.provider_openai). nil (the default) means "not pinned
  -- here" — fn.provider then reads the persisted choice written by
  -- :StrapsProvider ($XDG_CONFIG_HOME/straps/provider), falling back to
  -- "anthropic". Setting it here PINS the provider and wins over that file.
  -- Overridable per session buffer with vim.b[bufnr].straps_provider, so two
  -- sessions can talk to different backends. "openai" reads fn.openai_api_key
  -- ($OPENAI_API_KEY, then $XDG_CONFIG_HOME/straps/openai_api_key), posts to
  -- openai_base_url, and uses openai_model.
  provider = nil,
  openai_base_url = "https://api.openai.com",
  -- Model id sent when provider == "openai". Keep this separate from the
  -- Anthropic default `model` so selecting OpenAI never sends a Claude id.
  openai_model = "gpt-5",
  model = "claude-sonnet-5",
  -- Response token cap per provider call. nil (the default) means "not pinned
  -- here" — fn.provider then uses the active model's own max output: the
  -- `max_output` field of the matching config.models entry (seeded below,
  -- refreshed by :StrapsModel's live /v1/models discovery), else
  -- default_max_tokens. Setting a number PINS it as an explicit hard cap that
  -- wins over the per-model value — with one exception: a budget-thinking
  -- request whose budget_tokens meets or exceeds the cap still bumps above it,
  -- because the API rejects max_tokens <= budget_tokens. Left nil like
  -- auto_compact_bytes/session_dir below; vim.tbl_deep_extend ignores the nil.
  max_tokens = nil,
  -- Fallback response cap when config.max_tokens is nil AND the active model
  -- has no known max_output (an unlisted/custom model, or before :StrapsModel
  -- has discovered it). Also the OpenAI default (that backend has no per-model
  -- max-output discovery). 8192 was the old fixed default and is tight for
  -- adaptive thinking; output tokens bill only as generated, so a high cap
  -- costs nothing unused.
  default_max_tokens = 32000,
  max_turns = 128,
  -- Soft stop: end a run after this many CONSECUTIVE stalled turns — a turn is
  -- stalled when its every tool call errored, or it repeats a (tool,input)
  -- call already made this run. This is the real spinning-catcher; max_turns
  -- is only the hard backstop, hence generous. 0 disables the detector.
  stall_limit = 6,
  max_tool_result_bytes = 100000,
  cache = true,
  compact_keep_turns = 2,
  -- Default hook.after_write behaviour: after the agent writes a file, wait
  -- briefly for the attached LSP to re-lint it and feed any ERROR/WARN
  -- diagnostics back into the tool result — the editor-native version of
  -- "run a linter after every write". false turns it off (the hook returns
  -- nil); after_write_diagnostics_ms caps how long it waits for the server.
  after_write_diagnostics = true,
  after_write_diagnostics_ms = 800,
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

  -- Session-window winbar: a window-local status line on each session window
  -- showing the active model (per-buffer override else config.model), effort,
  -- and run status. false disables it (e.g. you reserve the winbar for
  -- something else); the ui.session_status() / ui.session_winbar() components
  -- stay available for a manual statusline either way.
  session_winbar = true,

  -- Agents-buffer winbar (:StrapsAgents): the keymap legend in a window-local
  -- winbar, so it is visible without scrolling past the saved rows. false
  -- moves the legend to the first buffer line instead.
  agents_winbar = true,

  -- :StrapsModel picker choices. Each entry is { id, label?, thinking?,
  -- context?, max_output? }. `max_output` is the model's maximum response
  -- tokens (Anthropic's /v1/models max_tokens); fn.provider uses it as the
  -- default max_tokens when config.max_tokens is nil, so a run never starves
  -- its answer on the old fixed 8192. `context` is the input window (winbar
  -- fill only). `thinking` tags which extended-thinking mechanism the model speaks
  -- (inferred from Anthropic's /v1/models capabilities.thinking.types):
  --   "adaptive" — thinking={type="adaptive"} + output_config={effort=...}
  --                (newer models: sonnet-5, opus-4-6..4-8, sonnet-4-6, ...)
  --   "budget"   — thinking={type="enabled", budget_tokens=...}
  --                (older models: opus-4-5, opus-4-1, sonnet-4-5, haiku-4-5)
  -- fn.provider reads the entry matching config.model to pick the right
  -- shape; an unlisted/custom model sends no thinking block at all (safest
  -- default — guessing wrong 400s the whole request). Picking one here sets
  -- config.model. This is a SEED, not an exhaustive menu: :StrapsModel does
  -- live discovery (fn.list_models -> GET /v1/models) and merges the account's
  -- real catalog over this list, keeping these curated labels/tags on top.
  models = {
    { id = "claude-opus-4-8", label = "Opus 4.8 — most capable, slowest", thinking = "adaptive", context = 200000, max_output = 128000 },
    { id = "claude-sonnet-5", label = "Sonnet 5 — balanced (default)", thinking = "adaptive", context = 200000, max_output = 128000 },
    { id = "claude-sonnet-4-6", label = "Sonnet 4.6", thinking = "adaptive", context = 200000, max_output = 128000 },
    { id = "claude-haiku-4-5-20251001", label = "Haiku 4.5 — fastest, cheapest", thinking = "budget", context = 200000, max_output = 64000 },
  },
  -- OpenAI model picker seed/cache, kept separate from Anthropic `models` so
  -- switching providers never shows or reuses the other provider's stale ids.
  openai_models = {
    { id = "gpt-5", label = "GPT-5" },
    { id = "gpt-5-mini", label = "GPT-5 mini" },
  },
  -- Fallback context window (tokens) for a model not found in the active
  -- provider's model list with a `context` field — used only to render the winbar's context-fill percentage
  -- (nothing is sent to the API). nil hides the percentage for unknown models.
  context_window = 200000,

  -- :StrapsEffort picker choices. `level` feeds output_config.effort for
  -- "adaptive" Anthropic models, thinking.budget_tokens for "budget"
  -- Anthropic models, and reasoning_effort for OpenAI models only when the
  -- matching config.openai_models entry opts in, the active effort has a
  -- level, and no function tools are present.
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

  -- Trusted (stored hash, explicit Yes, or trust_all): execute first, then
  -- record the hash only after this exact content successfully loads.
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
  store[path] = hash
  write_trust_store(store_path, store)
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
