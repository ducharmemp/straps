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
      .. " (not undo-reversible, its own category), exec (shell), lua (eval_lua),"
      .. " net (fetch_url), define (registry_define — never grantable, a define"
      .. " grant could shadow hook.confirm), spawn (subagents), and other"
      .. " (agent-defined tools — never grantable). Called with no args it"
      .. " returns the array of GRANTABLE categories { edit, delete, exec, lua,"
      .. " net, spawn }. Redefine it to add custom categories — e.g. classify"
      .. " bash inputs matching ^git%s into a \"vcs\" category. A tool.* entry's"
      .. " own capability field (settable only via registry.define, not"
      .. " tool.registry_define) takes precedence over this classification.",
    source = [==[
return function(name, input)
  local grantable = { "edit", "delete", "exec", "lua", "net", "spawn" }
  if name == nil then return grantable end

  -- Entries may declare their own category (set only via trusted definition
  -- paths — registry.define from config/.straps.lua; tool.registry_define
  -- deliberately does not accept the field, so an agent-defined tool cannot
  -- self-declare "read").
  local e = require("straps.registry").get("tool." .. tostring(name))
  if e and type(e.capability) == "string" then return e.capability end

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
    show_diff = true, show_buffer = true, set_findings = true,
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
  -- consequential write in the system and always prompts (the "other"
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
  -- registry_define can shadow hook.confirm, so a define grant would be an
  -- everything grant: it is a category of its own and never grantable.
  if name == "registry_define" then return "define" end
  if name == "spawn" or name == "spawn_wait" then return "spawn" end

  -- Agent-defined tools: unknown, never grantable.
  return "other"
end
]==],
  })

  -- -------------------------------------------------------- fn.readonly_policy

  -- Thin wrapper over fn.capability: read-only == the "read" category. Both the
  -- default hook.confirm (to auto-allow them without a prompt) and spawn's
  -- readonly-child hook (to permit only these) consult it, so the policy
  -- cannot drift. Called as (name, input) -> boolean.
  define({
    name = "fn.readonly_policy",
    kind = "fn",
    doc = "Return true if the tool call (name, input) is read-only: it opens"
      .. " views or lists things but changes no files. Classification itself"
      .. " lives in fn.capability (read-only == the \"read\" category); this is"
      .. " the boolean wrapper hook.confirm and spawn's readonly-child gate use.",
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
      .. " (name, input, ctx) -> allowed, reason. Default behavior: auto-allow"
      .. " the read-only tools (read_file, glob, tree, path_info, grep, registry_list,"
      .. " registry_get, diagnostics, diagnostic_at, diagnostic_next, lsp_status,"
      .. " declaration, definition, type_definition, implementation, references,"
      .. " symbols, read_symbol, tree_sitter_status, node_at, read_node, hover,"
      .. " workspace_symbols, context, show_user,"
      .. " show_diff, show_buffer, set_findings, help_search, ask_user, agents,"
      .. " code_action/fix_diagnostic in list mode i.e. without"
      .. " index, undo_edit in history mode, and transcript_excise in list mode"
      .. " i.e. without blocks/range);"
      .. " otherwise prompt via vim.fn.confirm. For"
      .. " file-editing tools (write_file, edit_file, patch_file) a unified diff of the"
      .. " proposed change is shown in a scratch split while the dialog is up"
      .. " (closed after), and the prompt offers"
      .. " Yes / No / 'Always in <parent dir>' / 'Always in this project <root>'"
      .. " (shown only when a project root marker — .jj/.git/.straps.lua/.hg/.svn —"
      .. " is found above the file, and not identical to the parent dir) /"
      .. " 'Always all edits': the directory choice grants every future"
      .. " write_file/edit_file/patch_file whose path falls under that file's PARENT"
      .. " directory (not just that one file), the project choice grants every"
      .. " edit anywhere under the detected project root, and 'Always all edits'"
      .. " grants every future write_file/edit_file/patch_file call regardless of path."
      .. " Other tools get Yes / No / 'Always this tool', scoped to the tool name. All"
      .. " grants persist in the registry's per-session grant set (registry.granted). A cap:<category> key"
      .. " in that allow-set (written by :StrapsAuto or spawn's allow arg) silently"
      .. " permits every call fn.capability puts in that category. Redefine to"
      .. " change the policy.",
    source = [==[
-- NOTE: this hook runs inside the loop coroutine. vim.fn.confirm must run on
-- the main loop; because the loop driver resumes the coroutine via
-- vim.schedule, every resume (and therefore this call) is already on the main
-- loop, so calling vim.fn.confirm directly here is safe — no extra await/
-- schedule wrapper is needed.
return function(name, input, ctx)
  -- Read-only tool calls (the allowlist plus the list-mode exceptions) are
  -- auto-allowed. The policy lives in fn.readonly_policy so this hook and
  -- spawn's readonly-child gate share one definition.
  if require("straps.registry").try_call("fn.readonly_policy", name, input) then
    return true
  end

  -- File-editing tools (write_file, edit_file) get directory- and
  -- global-scoped "always allow" options instead of a single per-tool
  -- toggle, so the user can grant "everywhere under this directory" or
  -- "all edits, any path" without being forced to blanket-authorize every
  -- other tool too.
  local path_scoped = { write_file = true, edit_file = true, patch_file = true }
  local is_edit = path_scoped[name] and type(input) == "table" and type(input.path) == "string"

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
    local cap = require("straps.registry").try_call("fn.capability", name, input)
    if cap and allowed["cap:" .. tostring(cap)] then
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
    if have_allowed and allowed[name] then
      return true
    end
  end

  -- For file edits, render a real unified diff in a scratch split while the
  -- dialog is up — an informed approval instead of a raw JSON dump. Best
  -- effort: any failure just falls back to the plain input preview.
  local preview_win
  if is_edit then
    pcall(function()
      local old = ""
      pcall(function()
        local buf = vim.fn.bufadd(vim.fn.fnamemodify(input.path, ":p"))
        vim.fn.bufload(buf)
        old = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
      end)
      local new
      if name == "write_file" then
        -- The buffer join above has no trailing newline; normalize content
        -- the same way so the diff doesn't show a phantom last-line change.
        new = (input.content or ""):gsub("\n$", "")
      elseif name == "patch_file" then
        local lines = vim.split(old, "\n", { plain = true })
        local hunks = input.hunks
        if type(hunks) ~= "table" then return end
        local normalized = {}
        for _, h in ipairs(hunks) do
          local s, e = tonumber(h.start_line), tonumber(h.end_line)
          if not s or not e or type(h.new_text) ~= "string" then return end
          normalized[#normalized + 1] = { s = math.floor(s), e = math.floor(e), text = h.new_text }
        end
        table.sort(normalized, function(a, b) return a.s < b.s end)
        for i = #normalized, 1, -1 do
          local h = normalized[i]
          local repl = h.text == "" and {} or vim.split(h.text, "\n", { plain = true })
          if repl[#repl] == "" then table.remove(repl) end
          for j = h.e, h.s, -1 do table.remove(lines, j) end
          for j = #repl, 1, -1 do table.insert(lines, h.s, repl[j]) end
        end
        new = table.concat(lines, "\n")
      else -- edit_file: preview the same plain-text replacement the tool does
        local olds, news = input.old_string, input.new_string or ""
        if type(olds) ~= "string" or olds == "" then return end
        if not old:find(olds, 1, true) then return end
        if input.replace_all then
          local parts, idx = {}, 1
          while true do
            local s, e = string.find(old, olds, idx, true)
            if not s then break end
            parts[#parts + 1] = old:sub(idx, s - 1)
            parts[#parts + 1] = news
            idx = e + 1
          end
          parts[#parts + 1] = old:sub(idx)
          new = table.concat(parts)
        else
          local s, e = string.find(old, olds, 1, true)
          new = old:sub(1, s - 1) .. news .. old:sub(e + 1)
        end
      end
      local differ = (vim.text and vim.text.diff) or vim.diff
      local diff = differ(old .. "\n", new .. "\n", { ctxlen = 3 })
      if type(diff) ~= "string" or diff == "" then return end
      local dlines = vim.split(diff, "\n", { plain = true })
      if #dlines > 200 then
        local capped = {}
        for i = 1, 200 do capped[i] = dlines[i] end
        capped[#capped + 1] = ("... (%d more diff lines)"):format(#dlines - 200)
        dlines = capped
      end
      local pbuf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(pbuf, 0, -1, false, dlines)
      vim.bo[pbuf].filetype = "diff"
      vim.bo[pbuf].bufhidden = "wipe"
      local prev = vim.api.nvim_get_current_win()
      vim.cmd("botright " .. math.min(#dlines + 1, 15) .. "split")
      preview_win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(preview_win, pbuf)
      pcall(vim.api.nvim_set_current_win, prev)
      vim.cmd("redraw")
    end)
  end

  local preview = vim.inspect(input)
  if #preview > 800 then
    preview = preview:sub(1, 800) .. "..."
  end
  if preview_win then
    preview = "diff preview shown in the split below"
  end

  -- For edits the choices are, in order:
  --   1 Yes  2 No  3 Always in <parent dir>  [4 Always in this project <root>]
  --   last  Always all edits
  -- The project choice is only present when a root marker is found, so its
  -- index is dynamic; capture it rather than hard-coding.
  local dir, root
  local root_choice_idx, all_choice_idx
  local choices
  if is_edit then
    dir = parent_dir(input.path)
    root = project_root(input.path)
    -- Don't offer the project choice when it would be identical to the
    -- immediate parent (editing a file directly in the repo root).
    if root == dir then root = nil end
    choices = "&Yes\n&No\n&Always in " .. dir
    local idx = 3
    if root then
      idx = idx + 1
      root_choice_idx = idx
      choices = choices .. "\nAlways in this &project (" .. root .. ")"
    end
    idx = idx + 1
    all_choice_idx = idx
    choices = choices .. "\nAlways &all edits"
  else
    choices = "&Yes\n&No\n&Always this tool"
  end

  local choice = vim.fn.confirm(
    "straps: allow " .. tostring(name) .. "?\n" .. preview, choices, 2)

  if preview_win then
    pcall(vim.api.nvim_win_close, preview_win, true)
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
  if is_edit and choice == all_choice_idx then
    grant("editfiles:*")
    return true
  end
  if (not is_edit) and choice == 3 then
    grant(name)
    return true
  end

  return false, "denied via confirm dialog"
end
]==],
  })
end

return M
