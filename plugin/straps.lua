-- plugin/straps.lua — user commands. No heavy requires at load time;
-- everything is lazy-required inside callbacks.

if vim.g.loaded_straps then
  return
end
vim.g.loaded_straps = true

local function resolve_session()
  return require("straps.ui").require_session(vim.api.nvim_get_current_buf())
end

local function ensure_setup()
  if not require("straps.registry").get("fn.provider") then
    require("straps").setup()
  end
end

local function command(name, fn, opts)
  vim.api.nvim_create_user_command(name, function(o)
    ensure_setup()
    return fn(o)
  end, opts)
end

-- Turn a command's parsed <mods> into a :split command string, so window
-- placement modifiers (`:vertical`, `:botright`, `:leftabove`, …) prefixed to
-- our commands open the session window that way — `:vertical Straps` is a
-- vsplit. smods.split ("", "botright", "topleft", "belowright", "aboveleft")
-- is Neovim's parse of the placement; smods.vertical carries `:vertical`.
-- Anything unset falls through to a plain horizontal "split".
local function split_cmd_of(smods)
  local prefix = smods and smods.split ~= "" and smods.split or ""
  local verb = smods and smods.vertical and "vsplit" or "split"
  return (prefix ~= "" and (prefix .. " ") or "") .. verb
end

-- `nvim - +Straps`: stdin lands in a buffer before -c commands run; remember
-- which one so :Straps can seed the session with it. VimEnter clears the
-- record, so a later interactive :Straps never swallows the user's buffer.
local stdin_group = vim.api.nvim_create_augroup("straps_stdin", { clear = true })
vim.api.nvim_create_autocmd("StdinReadPost", {
  group = stdin_group,
  callback = function(ev) vim.g.straps_stdin_buf = ev.buf end,
})
vim.api.nvim_create_autocmd("VimEnter", {
  group = stdin_group,
  callback = function() vim.g.straps_stdin_buf = nil end,
})

-- `:Straps [categories] [-- instruction]`: the text before the first
-- whitespace-delimited `--` is permission categories (comma/space separated,
-- `all` = every grantable one); the text after it is the instruction, kept
-- verbatim apart from trimming. Returns cats (list), instruction (string|nil).
local function parse_straps_args(args)
  local padded = " " .. args .. " "
  local s, e = padded:find("%s%-%-%s")
  local cats_text, instruction
  if s then
    cats_text = padded:sub(1, s)
    instruction = vim.trim(padded:sub(e))
    if instruction == "" then instruction = nil end
  else
    cats_text = padded
  end
  local cats, all = {}, false
  for tok in cats_text:gmatch("[^%s,]+") do
    if tok == "all" then all = true else cats[#cats + 1] = tok end
  end
  if all then
    for _, c in ipairs(require("straps.ui").grantable_categories()) do
      cats[#cats + 1] = c
    end
  end
  return cats, instruction
end

command("Straps", function(opts)
  local cats, instruction = parse_straps_args(opts.args)
  require("straps.ui").open_session(split_cmd_of(opts.smods), {
    grants = cats,
    instruction = instruction,
    send = opts.bang,
    explicit_split = opts.smods.split ~= "" or opts.smods.vertical,
  })
end, {
  nargs = "*",
  bang = true,
  complete = function(arglead)
    ensure_setup()
    local items = require("straps.ui").grantable_categories()
    items = vim.list_extend({ "all", "--" }, items)
    return vim.tbl_filter(function(it) return it:find(arglead, 1, true) == 1 end, items)
  end,
  desc = "straps: open a new session (:vertical for a vsplit);"
    .. " [categories] pre-grant permissions, `-- text` seeds the request, ! sends it",
})

command("StrapsResume", function(opts)
  local ui = require("straps.ui")
  local arg = opts.args
  local split = split_cmd_of(opts.smods)
  if opts.bang then
    return ui.pick_session(split) -- picker over all saved sessions
  end
  if arg == "" then
    return ui.resume_session(nil, split) -- most recent
  end
  if vim.fn.filereadable(arg) == 1 then
    return ui.resume_session(vim.fn.fnamemodify(arg, ":p"), split) -- explicit path
  end
  -- Treat the arg as a session basename and resolve it to a full path.
  for _, s in ipairs(require("straps.state").list_sessions()) do
    if s.name == arg then
      return ui.resume_session(s.path, split)
    end
  end
  vim.notify("straps: no such session: " .. arg .. " (try :StrapsResume<Tab>)", vim.log.levels.WARN)
end, {
  nargs = "?",
  complete = function(arglead)
    local ok, state = pcall(require, "straps.state")
    if not ok then
      return {}
    end
    local names = {}
    for _, s in ipairs(state.list_sessions()) do
      if s.name:find(arglead, 1, true) == 1 then
        names[#names + 1] = s.name
      end
    end
    return names
  end,
  bang = true,
  desc = "straps: resume a saved session (no arg = most recent; ! = pick via picker)",
})

command("StrapsRename", function(opts)
  local ui = require("straps.ui")
  local target = resolve_session()
  if not target then
    return
  end
  -- No arg: prompt (pre-filled with current title). Arg: set it directly.
  ui.rename_session(target, opts.args ~= "" and opts.args or nil)
end, { nargs = "?", desc = "straps: give this session a durable title (no arg = prompt)" })

command("StrapsSearch", function(opts)
  require("straps.ui").grep_sessions(opts.args)
end, { nargs = "+", desc = "straps: full-text search across all saved session transcripts" })

command("StrapsSend", function()
  local bufnr = resolve_session()
  if not bufnr then
    return
  end
  local loop = require("straps.loop")
  if loop.running(bufnr) then
    vim.ui.input({ prompt = "steer: " }, function(txt)
      if txt and txt ~= "" then
        require("straps.loop").steer(bufnr, txt)
      end
    end)
  else
    loop.start(bufnr)
  end
end, { desc = "straps: send the trailing user block (or steer if a run is active)" })

command("StrapsSteer", function(opts)
  local bufnr = resolve_session()
  if not bufnr then
    return
  end
  local text = opts.args
  if not require("straps.loop").steer(bufnr, text) then
    require("straps.state").add_to_trailing_user(bufnr, text)
    vim.notify("straps: no active run; added the text to the trailing user block (send it with :StrapsSend)",
      vim.log.levels.WARN)
  end
end, { nargs = "+", desc = "straps: queue a steering message for the active run" })

command("StrapsStop", function()
  local bufnr = resolve_session()
  if not bufnr then
    return
  end
  require("straps.loop").user_stop(bufnr)
end, { desc = "straps: cancel the active run in this session" })

-- Continuing a STOPPED run, as opposed to :StrapsResume, which reopens a saved
-- transcript from disk. Nothing to restore: :StrapsStop already leaves the
-- transcript sendable (every tool_use paired). Appending a user block is the
-- whole mechanism — the buffer IS the run state.
command("StrapsContinue", function(opts)
  local bufnr = resolve_session()
  if not bufnr then
    return
  end
  local loop = require("straps.loop")
  if loop.running(bufnr) then
    vim.notify("straps: a run is already active — :StrapsStop it first, or :StrapsSteer it",
      vim.log.levels.WARN)
    return
  end
  require("straps.state").append(bufnr, "user", nil,
    opts.args ~= "" and opts.args or "[straps] Continue where you left off.")
  loop.start(bufnr)
end, { nargs = "?", desc = "straps: continue a stopped/interrupted run (optional instruction)" })

command("StrapsCompact", function()
  local bufnr = resolve_session()
  if not bufnr then
    return
  end
  local ok, summary = pcall(require("straps.registry").call, "fn.compact", bufnr)
  if ok then
    vim.notify("straps: " .. tostring(summary), vim.log.levels.INFO)
  else
    vim.notify("straps: compact failed: " .. tostring(summary), vim.log.levels.ERROR)
  end
end, { desc = "straps: compact old tool blocks in this session" })

command("StrapsEdit", function(opts)
  require("straps.ui").open_entry(opts.args, split_cmd_of(opts.smods))
end, {
  nargs = 1,
  complete = function(arglead)
    local ok, registry = pcall(require, "straps.registry")
    if not ok then
      return {}
    end
    return vim.tbl_filter(function(name)
      return name:find(arglead, 1, true) == 1
    end, registry.names())
  end,
  desc = "straps: edit a registry entry (:w to redefine)",
})

command("StrapsRegistry", function(opts)
  require("straps.ui").registry_list(split_cmd_of(opts.smods))
end, { desc = "straps: list registry entries" })

command("StrapsHelp", function(opts)
  local tag = opts.args ~= "" and opts.args or "straps"
  vim.cmd("help " .. vim.fn.escape(tag, "\\ |\""))
end, {
  nargs = "?",
  complete = function(arglead)
    local tags = {}
    for _, path in ipairs(vim.api.nvim_get_runtime_file("doc/tags", true)) do
      local ok, lines = pcall(vim.fn.readfile, path)
      for _, line in ipairs(ok and lines or {}) do
        local tag = line:match("^([^\t]+)\t")
        if tag and tag:match("^straps") and vim.startswith(tag, arglead) then
          tags[#tags + 1] = tag
        end
      end
    end
    table.sort(tags)
    return vim.fn.uniq(tags)
  end,
  desc = "straps: open :help straps (or a straps help tag)",
})

command("StrapsAgents", function(opts)
  require("straps.ui").open_agents(split_cmd_of(opts.smods))
end, { desc = "straps: open the agents buffer (running/loaded/saved sessions; :vertical for a vsplit)" })

command("StrapsEval", function()
  require("straps.ui").eval_buffer()
end, { desc = "straps: execute the current buffer as Lua" })

command("StrapsModel", function()
  require("straps.ui").pick_model()
end, { desc = "straps: pick the provider-specific model (per session on a session buffer; else global, persisted to ~/.config/straps/model_<provider>)" })

command("StrapsEffort", function()
  require("straps.ui").pick_effort()
end, { desc = "straps: pick config.effort (extended-thinking budget) via a picker" })

command("StrapsProvider", function()
  require("straps.ui").pick_provider()
end, { desc = "straps: pick the API backend (anthropic/openai/llamacpp); persists the global choice to ~/.config/straps/provider" })

local function provider_complete(arglead)
  local out = {}
  for _, name in ipairs(require("straps.provider").provider_names()) do
    if vim.startswith(name, arglead) then out[#out + 1] = name end
  end
  return out
end

command("StrapsLogin", function(opts)
  require("straps.ui").login(opts.fargs)
end, { nargs = "*", bang = true, complete = function(arglead, line)
  local after = line:match("StrapsLog%a*!?%s+(.*)$") or ""
  if not after:find("%s") then return provider_complete(arglead) end
  local first = after:match("^(%S+)%s+%S*$")
  if first and vim.tbl_contains(require("straps.provider").provider_names(), first) then
    local forms = first == "openai" and { "codex", "key" } or { "key" }
    return vim.tbl_filter(function(f) return vim.startswith(f, arglead) end, forms)
  end
  return {}
end, desc = "straps: store a provider credential (:StrapsLogin [provider [key]]; openai signs in with ChatGPT, openai codex signs in the way the Codex CLI does, then :StrapsLogin openai <redirect-url>; key stores an API key)" })

command("StrapsLogout", function(opts)
  require("straps.ui").logout(opts.fargs)
end, { nargs = "*", bang = true, complete = function(arglead, line)
  local after = line:match("StrapsLog%a*!?%s+(.*)$") or ""
  return after:find("%s") and {} or provider_complete(arglead)
end,
  desc = "straps: delete a provider's stored credentials (:StrapsLogout [provider])" })

command("StrapsAuto", function(opts)
  require("straps.ui").auto(opts.args)
end, { nargs = "?", complete = function(arglead)
  ensure_setup()
  local items = vim.list_extend({ "off", "all" }, require("straps.ui").grantable_categories())
  return vim.tbl_filter(function(it) return it:find(arglead, 1, true) == 1 end, items)
end, desc = "straps: grant permission categories to this session (auto mode; off, all, or a list)" })
