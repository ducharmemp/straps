-- plugin/straps.lua — user commands. No heavy requires at load time;
-- everything is lazy-required inside callbacks.

if vim.g.loaded_straps then
  return
end
vim.g.loaded_straps = true

-- Session buffers act on themselves (via ui.resolve_session); anything else
-- gets a polite error.
local function resolve_session()
  local target = require("straps.ui").resolve_session(vim.api.nvim_get_current_buf())
  if not target then
    vim.notify(
      "straps: current buffer is not a straps session or input buffer (open one with :Straps)",
      vim.log.levels.ERROR
    )
  end
  return target
end

vim.api.nvim_create_user_command("Straps", function()
  require("straps.ui").open_session()
end, { desc = "straps: open a new session (transcript buffer)" })

vim.api.nvim_create_user_command("StrapsResume", function(opts)
  local ui = require("straps.ui")
  local arg = opts.args
  if opts.bang then
    return ui.pick_session() -- picker over all saved sessions
  end
  if arg == "" then
    return ui.resume_session() -- most recent
  end
  if vim.fn.filereadable(arg) == 1 then
    return ui.resume_session(vim.fn.fnamemodify(arg, ":p")) -- explicit path
  end
  -- Treat the arg as a session basename and resolve it to a full path.
  for _, s in ipairs(require("straps.state").list_sessions()) do
    if s.name == arg then
      return ui.resume_session(s.path)
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

vim.api.nvim_create_user_command("StrapsSend", function()
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

vim.api.nvim_create_user_command("StrapsSteer", function(opts)
  local bufnr = resolve_session()
  if not bufnr then
    return
  end
  local text = table.concat(opts.fargs, " ")
  if not require("straps.loop").steer(bufnr, text) then
    vim.notify("straps: no active run to steer — start one with :StrapsSend", vim.log.levels.INFO)
  end
end, { nargs = "+", desc = "straps: queue a steering message for the active run" })

vim.api.nvim_create_user_command("StrapsStop", function()
  local bufnr = resolve_session()
  if not bufnr then
    return
  end
  require("straps.loop").stop(bufnr)
end, { desc = "straps: cancel the active run in this session" })

vim.api.nvim_create_user_command("StrapsCompact", function()
  local bufnr = resolve_session()
  if not bufnr then
    return
  end
  local ok, summary = pcall(require("straps.registry").call, "fn.compact", bufnr)
  if ok then
    vim.notify("straps: " .. tostring(summary))
  else
    vim.notify("straps: compact failed: " .. tostring(summary), vim.log.levels.ERROR)
  end
end, { desc = "straps: compact old tool blocks in this session" })

vim.api.nvim_create_user_command("StrapsEdit", function(opts)
  require("straps.ui").open_entry(opts.args)
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

vim.api.nvim_create_user_command("StrapsRegistry", function()
  require("straps.ui").registry_list()
end, { desc = "straps: list registry entries" })

vim.api.nvim_create_user_command("StrapsHelp", function(opts)
  local tag = opts.args ~= "" and opts.args or "straps"
  vim.cmd("help " .. vim.fn.escape(tag, "\\ |\""))
end, {
  nargs = "?",
  complete = function(arglead)
    local tags = {
      "straps", "straps-commands", "straps-session", "straps-config",
      "straps-registry", "straps-tools", "straps-hooks", "straps-fn",
      "straps-skills", "straps-subagents", "straps-health",
    }
    return vim.tbl_filter(function(tag) return tag:find(arglead, 1, true) == 1 end, tags)
  end,
  desc = "straps: open :help straps (or a straps help tag)",
})

vim.api.nvim_create_user_command("StrapsAgents", function()
  require("straps.ui").pick_agents()
end, { desc = "straps: pick a running agent/subagent and open its transcript" })

vim.api.nvim_create_user_command("StrapsEval", function()
  require("straps.ui").eval_buffer()
end, { desc = "straps: execute the current buffer as Lua" })

vim.api.nvim_create_user_command("StrapsModel", function()
  require("straps.ui").pick_model()
end, { desc = "straps: pick the provider-specific model via a picker (snacks.nvim if available)" })

vim.api.nvim_create_user_command("StrapsEffort", function()
  require("straps.ui").pick_effort()
end, { desc = "straps: pick config.effort (extended-thinking budget) via a picker" })

vim.api.nvim_create_user_command("StrapsProvider", function()
  require("straps.ui").pick_provider()
end, { desc = "straps: pick the API backend (anthropic/openai); persists the global choice to ~/.config/straps/provider" })
