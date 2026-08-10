-- tests/run_reorg.lua — the layer-split mechanical invariant.
--   nvim --headless -l tests/run_reorg.lua
-- Guards the step-3 organizational reorg: tools.lua was split into
-- lua/straps/layers/* manifests dispatched in a fixed order, and each layer
-- (plus editor) gained an empty fn.system_prompt_layer.* prompt-fragment
-- skeleton registered AFTER every pre-split entry. The split must be
-- behavior-identical: entry seq order is the prompt-cache prefix, so the 36
-- pre-split builtin names must still appear in the SAME relative order, and
-- every layer skeleton must sort strictly AFTER all of them. The composer
-- (fn.system_prompt) already skips ""-returning fragments, so the assembled
-- prompt must equal exactly the "\n\n"-join of its non-empty sections — the
-- empty skeletons drop out and add no blank-run artifact.

local script = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(vim.fn.fnamemodify(script, ":p"), ":h:h")
vim.opt.runtimepath:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

require("straps").setup({})
local registry = require("straps.registry")

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

-- The 36 builtin entries tools.lua registered before the split, in seq order.
-- Generated once from the pre-split tree; the split must preserve this exact
-- relative order (interleaved layer groups included: fn.peer_agents sits
-- between the file tools and exec, spawn/spawn_wait between exec and the
-- session tool, the agents/models tools between fetch_url and permissions).
local REFERENCE = {
  "tool.read_file", "tool.write_file", "tool.edit_file", "tool.patch_file",
  "fn.reconcile_buf", "fn.check_writer", "fn.mark_seen",
  "fn.peer_agents",
  "tool.bash", "tool.run_in_terminal", "tool.run_quickfix",
  "tool.spawn", "tool.spawn_wait",
  "tool.transcript_excise",
  "tool.glob", "tool.path_info", "tool.tree", "tool.grep", "tool.bulk_replace",
  "tool.registry_list", "tool.registry_get", "tool.registry_define",
  "tool.skill", "tool.eval_lua",
  "tool.fetch_url",
  "tool.agents", "tool.models",
  "fn.capability", "fn.readonly_policy", "hook.confirm",
  "hook.after_write",
  "hook.on_run_start", "hook.on_turn_start", "fn.model_note", "hook.on_run_end",
  "fn.autocmd_bridge",
}

-- The prompt-fragment skeletons this reorg introduced, one per layer plus the
-- editor layer. (The core/env/skills/project fragments predate the reorg and
-- live in provider.lua before every reference name, so they are NOT asserted
-- here.)
local LAYER_SKELETONS = {
  "fn.system_prompt_layer.files", "fn.system_prompt_layer.search",
  "fn.system_prompt_layer.exec", "fn.system_prompt_layer.selfext",
  "fn.system_prompt_layer.net", "fn.system_prompt_layer.agents",
  "fn.system_prompt_layer.permissions", "fn.system_prompt_layer.session",
  "fn.system_prompt_layer.editor",
}

local function positions()
  local names = registry.names_by_seq()
  local pos = {}
  for i, n in ipairs(names) do pos[n] = i end
  return pos, names
end

case("every reference name is present, in the same relative order", function()
  local pos = positions()
  local last_name, last_pos = nil, 0
  for _, n in ipairs(REFERENCE) do
    local p = pos[n]
    assert(p, "reference entry missing after the split: " .. n)
    assert(p > last_pos, ("relative order broke: %s (seq %d) is not after %s (seq %d)")
      :format(n, p, tostring(last_name), last_pos))
    last_name, last_pos = n, p
  end
end)

case("every layer skeleton sorts strictly after every reference name", function()
  local pos = positions()
  -- The highest seq any reference name occupies.
  local max_ref = 0
  for _, n in ipairs(REFERENCE) do
    max_ref = math.max(max_ref, pos[n])
  end
  for _, s in ipairs(LAYER_SKELETONS) do
    local p = pos[s]
    assert(p, "layer skeleton missing: " .. s)
    for _, n in ipairs(REFERENCE) do
      assert(p > pos[n], ("skeleton %s (seq %d) does not sort after reference %s (seq %d)")
        :format(s, p, n, pos[n]))
    end
    assert(p > max_ref, ("skeleton %s (seq %d) is not past the last reference (seq %d)")
      :format(s, p, max_ref))
  end
end)

case("every layer skeleton is an fn that returns the empty string", function()
  for _, s in ipairs(LAYER_SKELETONS) do
    local e = registry.get(s)
    assert(e and e.kind == "fn", s .. " should be a registered fn")
    local out = registry.call(s)
    assert(out == "", s .. " should return the empty string, got " .. vim.inspect(out))
  end
end)

case("empty prompt fragments contribute nothing to the composition", function()
  -- The reorg's skeletons all return "". The composer joins only NON-empty
  -- sections with "\n\n", so the composed prompt must equal exactly the join
  -- of the non-empty layer fragments — the empty skeletons drop out and add no
  -- blank-run artifact. (An absolute "prompt contains no \n\n\n" is false for
  -- this repo: the injected # Project instructions content carries its own
  -- blank-line runs, so that assertion would test the project's memory files,
  -- not the reorg. Equality with the explicit join is the honest form.)
  local prompt = registry.call("fn.system_prompt", {})
  assert(type(prompt) == "string" and prompt ~= "", "system prompt should be a non-empty string")

  local parts = {}
  for _, name in ipairs(registry.names_by_seq("fn")) do
    if name:match("^fn%.system_prompt_layer%.") then
      local section = registry.call(name, {})
      if section and section ~= "" then
        parts[#parts + 1] = section
      end
    end
  end
  assert(prompt == table.concat(parts, "\n\n"),
    "composed prompt is not the \\n\\n-join of its non-empty fragments —"
      .. " an empty skeleton leaked into the composition")

  -- And directly: no layer skeleton contributes a section, so removing them
  -- from the iteration changes nothing.
  local n_nonempty = #parts
  local n_skeletons = 0
  for _, name in ipairs(registry.names_by_seq("fn")) do
    if name:match("^fn%.system_prompt_layer%.") and registry.call(name, {}) == "" then
      n_skeletons = n_skeletons + 1
    end
  end
  assert(n_skeletons >= #LAYER_SKELETONS,
    ("expected at least %d empty skeletons, found %d"):format(#LAYER_SKELETONS, n_skeletons))
  assert(n_nonempty > 0, "the prompt should still have real, non-empty sections")
end)

print(failed and "FAILED" or "ALL PASS")
os.exit(failed and 1 or 0)
