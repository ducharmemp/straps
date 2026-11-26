-- straps/layers/permissions.lua — the PERMISSIONS layer: the capability
-- classifier, the read-only policy, and the default confirmation gate.
-- Future prompt-fragment slot: fn.system_prompt_layer.permissions.

local M = {}

function M.register()
  local registry = require("straps.registry")
  local define = registry.define_default

  -- ------------------------------------------------------------- fn.capability

  -- Single classifier for "which permission category a tool call falls into".
  -- Both fn.readonly_policy (read == auto-allowed) and the cap: grant checks in
  -- hook.confirm and spawn's child gate consult it, so the categories cannot
  -- drift apart. Called as (name, input) -> category string, or with no args
  -- to get the list of GRANTABLE categories.
  define({
    name = "fn.capability",
    kind = "fn",
    doc = "Classify a tool call (name, input) into a permission category, the"
      .. " single source of truth every permission check consults. Categories:"
      .. " read (view/list, always auto-allowed), edit (file writes), delete"
      .. " (not undo-reversible, its own category), exec (shell), lua (eval_lua and session executable extensions),"
      .. " net (fetch_url), define (global, protected or unclassified definitions; never grantable),"
      .. " spawn (subagents, send_message and watch_agent), and agent_tool"
      .. " (unknown global tools and operations requiring confirmation; never grantable). Session skills use read. Called with no args it"
      .. " returns the array of GRANTABLE categories { edit, delete, exec, lua,"
      .. " net, spawn }. Redefine it to add custom categories — e.g. classify"
      .. " bash inputs matching ^git%s into a \"vcs\" category. A tool.* entry's"
      .. " own capability field (settable only via registry.define, not"
      .. " tool.registry_define) takes precedence except for registry_define and protected session shadows.",
    source = [==[
return function(name, input)
  local grantable = { "edit", "delete", "exec", "lua", "net", "spawn" }
  if name == nil then return grantable end

  -- Entries may declare their own category (set only via trusted definition
  -- paths — registry.define from config/.straps.lua; tool.registry_define
  -- deliberately does not accept the field, so an agent-defined tool cannot
  -- self-declare "read").
  local e = require("straps.registry").get("tool." .. tostring(name))
  local extensions = require("straps.extension_policy")
  if e and e.scope ~= nil and extensions.protected(e.name) then return "define" end
  if name == "registry_define" then return extensions.definition_category(input) end
  if e and type(e.capability) == "string" then return e.capability end
  if e and e.scope ~= nil then return extensions.tool_category(e) end

  local read = {
    read_file = true, glob = true, tree = true, path_info = true, grep = true,
    registry_list = true, registry_get = true, skill = true,
    -- editor-native read-only tools (straps.editor)
    diagnostics = true, diagnostic_at = true, diagnostic_next = true,
    lsp_status = true,
    declaration = true, definition = true, type_definition = true,
    implementation = true, references = true,
    symbols = true, read_symbol = true, tree_sitter_status = true, node_at = true,
    read_node = true, hover = true,
    workspace_symbols = true, context = true, show_user = true,
    help_search = true,
    -- agents only lists other sessions' buffer-local state; it changes nothing.
    agents = true,
    -- models reads the configured catalog (no network, no writes).
    models = true,
    -- presentation tools: they open views / set the findings list but change
    -- no files, exactly like show_user.
    show_diff = true, show_buffer = true, show_terminal = true, set_findings = true,
    -- ask_user IS user interaction; gating it behind a confirm dialog would
    -- be asking permission to ask a question.
    ask_user = true,
  }
  if read[name] then return "read" end

  -- code_action / fix_diagnostic without an index only LIST available actions
  -- (read-only); applying one (index set) is a write.
  if name == "code_action" or name == "fix_diagnostic" then
    if type(input) ~= "table" or input.index == nil then return "read" end
    return "edit"
  end

  -- undo_edit with history=true only lists the undo states (read-only); an
  -- actual undo is a buffer+file change.
  if name == "undo_edit" then
    if type(input) == "table" and input.history == true then return "read" end
    return "edit"
  end

  -- transcript_excise with no blocks/range only lists the transcript's blocks
  -- (read-only); an actual excision rewrites the transcript, which is the most
  -- consequential write in the system and always prompts (the "agent_tool"
  -- fallthrough below, never grantable).
  if name == "transcript_excise" and type(input) == "table"
    and input.blocks == nil and input.range == nil then
    return "read"
  end

  local edit = {
    write_file = true, edit_file = true, patch_file = true, bulk_replace = true,
    format = true, rename_symbol = true, move_file = true, move_files = true,
  }
  if edit[name] then return "edit" end

  -- Deletion is not undo-reversible, so it is its own category.
  if name == "delete_file" or name == "delete_files" then return "delete" end

  if name == "bash" or name == "run_in_terminal" or name == "run_quickfix" then
    return "exec"
  end
  if name == "eval_lua" then return "lua" end
  if name == "fetch_url" then return "net" end
  -- send_message writes into another agent's session, and a watch can start
  -- this session's run: the same blast-radius class as starting one, so they
  -- share the spawn grant.
  if name == "spawn" or name == "spawn_wait" or name == "send_message"
    or name == "watch_agent" or name == "unwatch_agent" then
    return "spawn"
  end

  return "agent_tool"
end
]==],
  })

  -- ---------------------------------------------------------- fn.starts_segment

  define({
    name = "fn.starts_segment",
    kind = "fn",
    doc = "Called as (name, input) for every block after the first of a batch's"
      .. " gate run; true makes that block start a new segment, so every block before it is gated,"
      .. " executed and appended to the transcript before this block is gated. Default: true for a"
      .. " tool entry whose segment_break field is true (settable only via registry.define, like"
      .. " capability), so a tool that copies or reads the transcript (fork) sees the real results"
      .. " of the calls before it.",
    source = [==[
return function(name)
  local e = require("straps.registry").get("tool." .. tostring(name))
  return e ~= nil and e.segment_break == true
end
]==],
  })

  -- -------------------------------------------------------- fn.readonly_policy

  define({
    name = "fn.readonly_policy",
    kind = "fn",
    doc = "Return true if the tool call (name, input) is read-only: it opens"
      .. " views, lists things, or defines a session skill, but changes no files. Classification itself"
      .. " lives in fn.capability (read-only == the \"read\" category); this is"
      .. " the boolean wrapper used by the default hook.confirm. Child gates"
      .. " also allow lifecycle watches and parent-directed messages.",
    source = [==[
return function(name, input)
  return require("straps.registry").try_call("fn.capability", name, input) == "read"
end
]==],
  })

  -- ------------------------------------------------------------- hook.confirm

  define({
    name = "hook.confirm",
    kind = "hook",
    doc = "Confirmation gate called before every tool execution as"
      .. " (name, input, ctx, call_id?) -> allowed, reason, source. source \"hook\" marks a policy veto: the"
      .. " tool result reads \"blocked by hook.confirm: <reason>\"; any other refusal reads"
      .. " \"user denied: <reason>\". Default behavior: auto-allow"
      .. " the read-only tools, i.e. every call fn.capability classifies as read (read_file, glob,"
      .. " tree, path_info, grep, registry_list, registry_get, skill, diagnostics, diagnostic_at,"
      .. " diagnostic_next, lsp_status, declaration, definition, type_definition, implementation,"
      .. " references, symbols, read_symbol, tree_sitter_status, node_at, read_node, hover,"
      .. " workspace_symbols, context, show_user, help_search, agents, models, show_diff,"
      .. " show_buffer, show_terminal, set_findings, ask_user, code_action/fix_diagnostic in list mode i.e. without"
      .. " index, undo_edit in history mode, and transcript_excise in list mode"
      .. " i.e. without blocks/range);"
      .. " otherwise ask. Inside a run with permission_review = \"deferred\" (the default) the request waits in"
      .. " the corner float until reviewed in the review float (gy / :StrapsPermission; Yes is y and No is n,"
      .. " a file edit adds d (directory), p (project) and a (all edits), another edit-category tool adds a (this tool)"
      .. " and l (all edits), and any other tool except deletes and definitions adds a (this tool)); outside a run, or"
      .. " with \"modal\" outside the dock and session-buffer edits, it prompts via vim.fn.confirm; with \"modal\","
      .. " a request while the dock is visible or a session-buffer edit waits for gy / :StrapsPermission, which then prompts."
      .. " For session file edits (write_file, edit_file, patch_file),"
      .. " :StrapsInspect or i in the review float opens the proposed unified diff on demand; i closes the review"
      .. " float and leaves the request pending."
      .. " Inside a batch it uses ctx.batch_preview(path) when available."
      .. " The decision offers"
      .. " Yes / No / 'Always in <parent dir>' / 'Always in this project <root>'"
      .. " (shown only when a project root marker — .jj/.git/.straps.lua/.hg/.svn —"
      .. " is found above the file, and not identical to the parent dir) /"
      .. " 'Always all edits': the directory choice grants every future"
      .. " write_file/edit_file/patch_file whose path falls under that file's PARENT"
      .. " directory (not just that one file), the project choice grants every"
      .. " such edit anywhere under the detected project root, and 'Always all edits'"
      .. " (key editfiles:*) grants every future call in the edit category regardless of path:"
      .. " write_file, edit_file, patch_file, bulk_replace, rename_symbol, format, move_file(s),"
      .. " undo_edit and code_action/fix_diagnostic with an index."
      .. " Other edit-category tools get Yes / No / 'Always this tool' / 'Always all edits'"
      .. " and a field-per-line preview of their input (bulk_replace shows its pattern,"
      .. " replacement and the findings-list entry and file counts). delete_file/delete_files"
      .. " get Yes / No only, with a warning that deletion is not undo-reversible."
      .. " registry_define and define-category calls get Yes / No and ignore tool-name grants."
      .. " Other tools get Yes / No / 'Always this tool', scoped to the tool's current definition"
      .. " (registry.tool_grant_key: <name>@v<version>[@<bufnr>], so a redefinition or session shadow prompts again). All"
      .. " grants persist in the registry's per-session grant set (registry.granted). A cap:<category> key"
      .. " in that allow-set (written by :StrapsAuto or spawn's allow arg) silently"
      .. " permits every call fn.capability puts in that category. Redefine to"
      .. " change the policy.",
    source = [==[
return function(name, input, ctx, call_id)
  -- Read-only tool calls (the allowlist plus the list-mode exceptions) are
  -- auto-allowed. The policy lives in fn.readonly_policy so this hook and
  -- spawn's readonly-child gate share one definition.
  if require("straps.registry").try_call("fn.readonly_policy", name, input) then
    return true
  end

  local path_scoped = { write_file = true, edit_file = true, patch_file = true }
  local is_edit = path_scoped[name] and type(input) == "table" and type(input.path) == "string"
  local category = require("straps.registry").try_call("fn.capability", name, input)
  local is_edit_cap = category == "edit" and not is_edit
  local is_delete = category == "delete"
  local is_definition = name == "registry_define" or category == "define"

  local function parent_dir(path)
    local p = vim.fn.fnamemodify(path, ":p:h")
    return vim.uv.fs_realpath(p) or p
  end

  -- Walk up from the file's directory for a project marker so the user can
  -- authorize edits across the WHOLE repo in one grant, not one directory at
  -- a time. Returns nil when no marker is found (so the choice is hidden).
  local function project_root(path)
    local start = vim.fn.fnamemodify(path, ":p:h")
    local markers = { ".jj", ".git", ".straps.lua", ".hg", ".svn" }
    local found = vim.fs.find(markers, { upward = true, path = start })[1]
    if not found then return nil end
    local root = vim.fn.fnamemodify(found, ":h")
    return vim.uv.fs_realpath(root) or root
  end

  local function canonical_existing(path)
    local p = vim.fn.fnamemodify(path, ":p")
    local real = vim.uv.fs_realpath(p)
    if real then return real end
    local parent = vim.fn.fnamemodify(p, ":h")
    local base = vim.fn.fnamemodify(p, ":t")
    local parent_real = vim.uv.fs_realpath(parent)
    if parent_real then return parent_real .. "/" .. base end
    return p
  end

  local function under_dir(path, dir)
    local abspath = canonical_existing(path)
    local absdir = canonical_existing(dir)
    if absdir:sub(-1) ~= "/" then
      absdir = absdir .. "/"
    end
    return abspath:sub(1, #absdir) == absdir
  end

  -- The per-session grant set lives in the registry (not a buffer variable,
  -- which any Lua the agent runs could write).
  local allowed = {}
  pcall(function()
    if ctx and ctx.bufnr then allowed = require("straps.registry").granted(ctx.bufnr) end
  end)
  local have_allowed = next(allowed) ~= nil

  -- Category grants: "cap:<category>" keys in the allow-set (written by
  -- :StrapsAuto or tool.spawn's allow arg) silently permit every call that
  -- fn.capability classifies into that category. Only grantable categories
  -- are ever written as cap: keys, so honoring any present key is safe.
  if have_allowed then
    if category and allowed["cap:" .. tostring(category)] then
      return true
    end
    if is_edit_cap and allowed["editfiles:*"] then
      return true
    end
  end

  if is_edit then
    if have_allowed then
      if allowed["editfiles:*"] then
        return true
      end
      for k, v in pairs(allowed) do
        if v and type(k) == "string" then
          local dir = k:match("^editdir:(.*)$")
          if dir and under_dir(input.path, dir) then
            return true
          end
        end
      end
    end
  else
    if not is_definition and have_allowed and allowed[require("straps.registry").tool_grant_key(name)] then
      return true
    end
  end

  local function field_listing(t)
    if type(t) ~= "table" then return vim.inspect(t) end
    local keys = vim.tbl_keys(t)
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local rows = {}
    for _, k in ipairs(keys) do
      local v = t[k]
      local s = type(v) == "string" and v or vim.inspect(v, { newline = " ", indent = "" })
      if #s > 300 then s = s:sub(1, 300) .. ("... (%d more bytes)"):format(#s - 300) end
      rows[#rows + 1] = tostring(k) .. ": " .. s
    end
    if #rows > 30 then
      local n = #rows
      rows = vim.list_slice(rows, 1, 30)
      rows[#rows + 1] = ("... (%d more fields)"):format(n - 30)
    end
    return table.concat(rows, "\n")
  end

  local preview = field_listing(input)
  local shown_findings
  if name == "bulk_replace" and type(input) == "table" then
    shown_findings = require("straps.findings").signature(ctx and ctx.bufnr)
    local entries, files = 0, 0
    pcall(function()
      local items = require("straps.findings").get_locations(ctx and ctx.bufnr)
      local seen = {}
      for _, e in ipairs(items) do
        entries = entries + 1
        if type(e.bufnr) == "number" and e.bufnr > 0 and not seen[e.bufnr] then
          seen[e.bufnr] = true
          files = files + 1
        end
      end
    end)
    preview = ("pattern: %s\nreplacement: %s\nflags: %s\nwould substitute over %d findings-list entr%s across %d file%s")
      :format(tostring(input.pattern), tostring(input.replacement), tostring(input.flags or "ge"),
        entries, entries == 1 and "y" or "ies", files, files == 1 and "" or "s")
    if input.dry_run then preview = preview .. "\ndry_run: no files will change" end
  end
  if is_delete then
    preview = "Deletion is NOT undo-reversible: there is no buffer undo for a removed file.\n" .. preview
  end

  local dir, root
  local root_choice_idx, all_choice_idx
  local options
  if is_edit then
    dir = parent_dir(input.path)
    root = project_root(input.path)
    if root == dir then root = nil end
    local function esc(s) return (s:gsub("&", "&&")) end
    options = { { "&Yes", "yes", "y" }, { "&No", "no", "n" }, { "Always in &dir " .. esc(dir), "dir", "d" } }
    if root then
      options[#options + 1] = { "Always in this &project (" .. esc(root) .. ")", "project", "p" }
      root_choice_idx = #options
    end
    options[#options + 1] = { "Always &all edits", "all edits", "a" }
    all_choice_idx = #options
  elseif is_delete or is_definition then
    options = { { "&Yes", "yes", "y" }, { "&No", "no", "n" } }
  elseif is_edit_cap then
    options = { { "&Yes", "yes", "y" }, { "&No", "no", "n" }, { "&Always this tool", "always tool", "a" },
      { "Always a&ll edits", "all edits", "l" } }
    all_choice_idx = #options
  else
    options = { { "&Yes", "yes", "y" }, { "&No", "no", "n" }, { "&Always this tool", "always tool", "a" } }
  end
  local modal_choices, spec_choices = {}, {}
  for i, option in ipairs(options) do
    modal_choices[i] = option[1]
    spec_choices[i] = { label = option[2], key = option[3], index = i }
  end
  local choices = table.concat(modal_choices, "\n")

  local function present()
    return require("straps.attention").prompt(ctx, "permission", vim.fn.confirm,
      "straps: allow " .. tostring(name) .. "?\n" .. preview, choices, 2)
  end
  local body = preview
  if is_edit then
    local grants = "d: always in " .. dir
    if root then grants = grants .. "\np: always in this project " .. root end
    body = grants .. "\n\n" .. preview
  end
  local target
  local entry_schema = require("straps.registry").get("tool." .. tostring(name))
  local properties = type(entry_schema) == "table" and type(entry_schema.input_schema) == "table"
    and type(entry_schema.input_schema.properties) == "table" and entry_schema.input_schema.properties or {}
  for _, field in ipairs({ "path", "command", "pattern", "name" }) do
    if properties[field] ~= nil and type(input) == "table" and type(input[field]) == "string" then
      target = input[field]
      break
    end
  end
  local spec = {
    name = tostring(name),
    target = target,
    title = "allow " .. tostring(name),
    preview = body,
    choices = spec_choices,
    inspect = is_edit or nil,
  }
  local choice
  if is_edit then
    choice = require("straps.workbench").confirm(name, input, ctx, call_id, present, spec)
  else
    choice = require("straps.dock").confirm(ctx, present, spec)
  end

  if shown_findings and (choice == 1 or choice == 3 or choice == 4) then
    require("straps.findings").approve(ctx and ctx.bufnr, input, shown_findings)
  end

  if choice == 1 then
    return true
  end

  local function grant(key)
    local ok, err = pcall(function() require("straps.registry").grant(ctx.bufnr, key) end)
    if not ok then
      pcall(vim.notify, "straps: grant not recorded: " .. tostring(err), vim.log.levels.ERROR)
    end
  end

  if is_edit and choice == 3 then
    grant("editdir:" .. dir)
    return true
  end
  if is_edit and root_choice_idx and choice == root_choice_idx then
    grant("editdir:" .. root)
    return true
  end
  if (is_edit or is_edit_cap) and choice == all_choice_idx then
    grant("editfiles:*")
    return true
  end
  if not is_edit and not is_delete and not is_definition and choice == 3 then
    grant(require("straps.registry").tool_grant_key(name))
    return true
  end

  return false, "denied by the user"
end
]==],
  })
end

return M
