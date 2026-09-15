-- straps/tools.lua — the builtin-tool dispatcher.
-- Every builtin tool, hook and fn is defined in a LAYER manifest under
-- lua/straps/layers/ (files, agents, exec, session, search, selfext, net,
-- permissions), each an organizational grouping with its own future
-- prompt-fragment slot. This file's register() is a thin dispatcher: it calls
-- the layer register()s in the exact order that fixes each entry's seq — the
-- prompt-cache prefix and the registry.dump() ordering both depend on it — so
-- the call sequence below is load-bearing and must not be reordered. Each
-- entry is stored as a Lua source STRING and compiled by the registry, so any
-- of them can be redefined at runtime (including by the agent itself), and the
-- layers use registry.define_default: never clobbering user redefinitions.

local M = {}

function M.register()
  local files = require("straps.layers.files")
  local agents = require("straps.layers.agents")
  local exec = require("straps.layers.exec")
  local session = require("straps.layers.session")
  local search = require("straps.layers.search")
  local selfext = require("straps.layers.selfext")
  local net = require("straps.layers.net")
  local permissions = require("straps.layers.permissions")

  -- The call order below reproduces tools.lua's original single-function
  -- define order exactly (verified by a registry.dump() byte-diff). Because
  -- today's order interleaves the agents layer through the others, agents.lua
  -- is split into register_peers/register_spawn/register_tools/register_hooks
  -- called at the points where those groups originally sat.
  files.register_tools()      -- read_file, write_file, edit_file, patch_file, fn.reconcile_buf, fn.check_writer, fn.mark_seen
  agents.register_peers()     -- fn.peer_agents
  exec.register()             -- bash, run_in_terminal, run_quickfix
  agents.register_spawn()     -- spawn, spawn_wait
  session.register()          -- transcript_excise
  search.register()           -- glob, path_info, tree, grep, bulk_replace
  selfext.register()          -- registry_list, registry_get, registry_define, skill, eval_lua
  net.register()              -- fetch_url
  agents.register_tools()     -- agents, models
  permissions.register()      -- fn.capability, fn.readonly_policy, hook.confirm
  files.register_hooks()      -- hook.after_write
  agents.register_hooks()     -- hook.on_run_start, hook.on_turn_start, fn.model_note, hook.on_run_end, fn.autocmd_bridge, fn.session_notify, fn.spawn_notice, hook.on_run_end.notify_parent

  -- Skeleton pass: an empty prompt-fragment slot per layer, registered AFTER
  -- every entry above so the registry.dump() prefix stays byte-identical and
  -- the skeletons land at the tail. Each returns "" until that layer's
  -- guidance moves out of the core system prompt (fn.system_prompt already
  -- skips ""); the editor layer registers its own slot from editor.lua.
  local registry = require("straps.registry")
  local define = registry.define_default
  for _, layer in ipairs({
    "files", "search", "exec", "selfext", "net", "agents", "permissions", "session",
  }) do
    define({
      name = "fn.system_prompt_layer." .. layer,
      kind = "fn",
      doc = "Prompt fragment slot for the " .. layer .. " layer — returns ''"
        .. " until that layer's guidance moves out of the core prompt"
        .. " (organizational skeleton).",
      source = "return function() return \"\" end",
    })
  end
end

return M
