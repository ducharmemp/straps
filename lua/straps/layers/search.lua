-- straps/layers/search.lua — the SEARCH layer: filesystem discovery (glob,
-- path_info, tree), content search (grep) and its bulk-edit companion.
-- Future prompt-fragment slot: fn.system_prompt_layer.search.

local M = {}

function M.register()
  local registry = require("straps.registry")
  local define = registry.define_default

  -- --------------------------------------------------------------------- glob

  define({
    name = "tool.glob",
    kind = "tool",
    doc = "Expand a file glob pattern and return matching paths, one per line,"
      .. " capped at 500 entries (a truncation note is added if more matched)."
      .. " Uses Neovim glob() semantics: * matches within a path component, **"
      .. " matches recursively, ? matches one character, [abc] matches a set."
      .. " Parameters: pattern (required) — e.g. 'lua/**/*.lua'.",
    input_schema = {
      type = "object",
      properties = {
        pattern = { type = "string", description = "Glob pattern, e.g. 'src/**/*.ts'." },
      },
      required = { "pattern" },
    },
    source = [==[
return function(input, ctx)
  local matches = vim.fn.glob(input.pattern, false, true)
  if #matches == 0 then
    return "no matches for pattern: " .. tostring(input.pattern)
  end
  local total = #matches
  local out = {}
  for i = 1, math.min(total, 500) do
    out[#out + 1] = matches[i]
  end
  if total > 500 then
    out[#out + 1] = string.format("[truncated: showing 500 of %d matches]", total)
  end
  return table.concat(out, "\n")
end
]==],
  })

  -- ----------------------------------------------------------------- path_info

  define({
    name = "tool.path_info",
    kind = "tool",
    doc = "Inspect filesystem metadata for one or more paths without shelling out."
      .. " Returns type, size, permissions, mtime, symlink target, and whether a"
      .. " loaded buffer has unsaved changes. Read-only. Parameters: paths"
      .. " (required array of paths).",
    input_schema = {
      type = "object",
      properties = {
        paths = { type = "array", description = "Paths to inspect.", items = { type = "string" } },
      },
      required = { "paths" },
    },
    source = [==[
return function(input, ctx)
  if type(input.paths) ~= "table" or #input.paths == 0 then
    return "path_info: paths must be a non-empty array"
  end
  local out = {}
  for _, p in ipairs(input.paths) do
    if type(p) == "string" and p ~= "" then
      local full = vim.fn.fnamemodify(p, ":p")
      local stat = vim.uv.fs_lstat(full)
      if not stat then
        out[#out + 1] = p .. ": missing"
      else
        local target = ""
        if stat.type == "link" then
          local ok, t = pcall(vim.uv.fs_readlink, full)
          if ok and t then target = " -> " .. t end
        end
        local buf = vim.fn.bufnr(full)
        local mod = ""
        if buf ~= -1 and vim.api.nvim_buf_is_loaded(buf) then
          mod = vim.bo[buf].modified and " loaded modified" or " loaded clean"
        end
        out[#out + 1] = string.format("%s: %s%s size=%s mode=%o mtime=%s%s",
          p, stat.type or "?", target, tostring(stat.size or 0), stat.mode or 0,
          stat.mtime and tostring(stat.mtime.sec) or "?", mod)
      end
    end
  end
  if #out == 0 then return "path_info: no valid paths" end
  return table.concat(out, "\n")
end
]==],
  })

  -- ---------------------------------------------------------------------- tree

  define({
    name = "tool.tree",
    kind = "tool",
    doc = "List a bounded directory tree without shelling out. Honors optional"
      .. " max_depth (default 2, max 6), max_entries (default 200, max 1000),"
      .. " and hidden (default false). Read-only. Parameters: path (optional,"
      .. " default '.').",
    input_schema = {
      type = "object",
      properties = {
        path = { type = "string", description = "Directory to list (default '.')." },
        max_depth = { type = "integer", description = "Maximum depth (default 2, max 6)." },
        max_entries = { type = "integer", description = "Maximum entries (default 200, max 1000)." },
        hidden = { type = "boolean", description = "Include dotfiles/directories (default false)." },
      },
      required = {},
    },
    source = [==[
return function(input, ctx)
  local root = vim.fn.fnamemodify(input.path or ".", ":p")
  local stat = vim.uv.fs_stat(root)
  if not stat then return "tree: no such path: " .. tostring(input.path or ".") end
  if stat.type ~= "directory" then return "tree: not a directory: " .. tostring(input.path or ".") end
  local max_depth = math.min(math.max(tonumber(input.max_depth) or 2, 0), 6)
  local max_entries = math.min(math.max(tonumber(input.max_entries) or 200, 1), 1000)
  local include_hidden = input.hidden == true
  local out, count, truncated = { vim.fn.fnamemodify(root, ":~:.") .. "/" }, 0, false
  local function children(dir)
    local items = {}
    local fs = vim.uv.fs_scandir(dir)
    if not fs then return items end
    while true do
      local name, typ = vim.uv.fs_scandir_next(fs)
      if not name then break end
      if include_hidden or name:sub(1, 1) ~= "." then
        items[#items + 1] = { name = name, type = typ or "?" }
      end
    end
    table.sort(items, function(a, b)
      if a.type == b.type then return a.name < b.name end
      return a.type == "directory"
    end)
    return items
  end
  local function walk(dir, prefix, depth)
    if depth >= max_depth or truncated then return end
    local items = children(dir)
    for i, it in ipairs(items) do
      if count >= max_entries then truncated = true; return end
      count = count + 1
      local last = i == #items
      local branch = last and "└── " or "├── "
      local next_prefix = prefix .. (last and "    " or "│   ")
      local suffix = it.type == "directory" and "/" or ""
      out[#out + 1] = prefix .. branch .. it.name .. suffix
      if it.type == "directory" then walk(dir .. "/" .. it.name, next_prefix, depth + 1) end
      if truncated then return end
    end
  end
  walk(root:gsub("/+$", ""), "", 0)
  if truncated then out[#out + 1] = string.format("[truncated: showing %d entries; raise max_entries or narrow path]", count) end
  return table.concat(out, "\n")
end
]==],
  })

  -- --------------------------------------------------------------------- grep

  define({
    name = "tool.grep",
    kind = "tool",
    doc = "Search file contents for a regular-expression pattern. Uses ripgrep"
      .. " (rg) when installed, otherwise falls back to `grep -rn`. Returns"
      .. " matching lines as file:line:text, capped at 100000 bytes with a"
      .. " truncation note. As a side effect it also populates this session's"
      .. " findings list (the session window's location list when on-screen, else"
      .. " the global quickfix list; title 'straps: grep <pattern>'), so the user"
      .. " can jump through the matches with :lnext/:lprev (or :cnext/:cprev when"
      .. " it fell back) and bulk-edit them with the bulk_replace"
      .. " tool. Parameters: pattern (required) — regex in rg/grep syntax; path"
      .. " (optional, default '.') — file or directory to search; glob (optional)"
      .. " — only search files matching this glob, e.g. '*.lua'; case_insensitive"
      .. " (optional, default false); fixed_string (optional, default false) —"
      .. " treat pattern as a literal string, not a regex; context (optional) —"
      .. " show this many lines around each match.",
    input_schema = {
      type = "object",
      properties = {
        pattern = { type = "string", description = "Regex pattern to search for." },
        path = { type = "string", description = "File or directory to search (default '.')." },
        glob = { type = "string", description = "Only search files matching this glob, e.g. '*.lua'." },
        case_insensitive = { type = "boolean", description = "Match case-insensitively (default false)." },
        fixed_string = { type = "boolean", description = "Treat pattern as a literal string, not a regex (default false)." },
        context = { type = "integer", description = "Lines of context to show around each match." },
      },
      required = { "pattern" },
    },
    source = [==[
return function(input, ctx)
  local context = tonumber(input.context)
  local cmd
  if vim.fn.executable("rg") == 1 then
    cmd = { "rg", "--line-number", "--no-heading", "--color=never" }
    if input.case_insensitive then cmd[#cmd + 1] = "-i" end
    if input.fixed_string then cmd[#cmd + 1] = "-F" end
    if context and context > 0 then
      cmd[#cmd + 1] = "-C"
      cmd[#cmd + 1] = tostring(math.floor(context))
    end
    if type(input.glob) == "string" and input.glob ~= "" then
      cmd[#cmd + 1] = "-g"
      cmd[#cmd + 1] = input.glob
    end
  else
    cmd = { "grep", "-rn" }
    if input.case_insensitive then cmd[#cmd + 1] = "-i" end
    if input.fixed_string then cmd[#cmd + 1] = "-F" end
    if context and context > 0 then
      cmd[#cmd + 1] = "-C"
      cmd[#cmd + 1] = tostring(math.floor(context))
    end
    if type(input.glob) == "string" and input.glob ~= "" then
      cmd[#cmd + 1] = "--include=" .. input.glob
    end
  end
  cmd[#cmd + 1] = "--"
  cmd[#cmd + 1] = input.pattern
  cmd[#cmd + 1] = input.path or "."
  local res = ctx.await(function(resolve)
    local proc = vim.system(cmd, { text = true }, function(out) resolve(out) end)
    if ctx.on_cancel then
      ctx.on_cancel(function() pcall(function() proc:kill(9) end) end)
    end
  end)
  local out = res.stdout or ""

  -- Populate the session's findings list from the matches so the user can step
  -- them and bulk_replace over them. This is a pure side effect: the text summary
  -- returned below is unchanged. rg/grep emit `file:line:text`; parse that
  -- (also tolerate an optional `file:line:col:text` if a column is present).
  -- Context lines (from the context param) use `-` separators and `--` group
  -- dividers, so they fall through this match — only real matches enter the
  -- findings list.
  local title = "straps: grep " .. tostring(input.pattern)
  -- Route to THIS session's findings list (its window's location list when
  -- on-screen — private to the session — else the global quickfix list).
  local set_kind = "quickfix"
  local function set_qf(items)
    local ok, kind = pcall(function()
      return require("straps.findings").set_locations(ctx and ctx.bufnr, { title = title, items = items }, false)
    end)
    if ok and kind then set_kind = kind end
  end
  local function parse_items(text)
    local items = {}
    for line in (text .. "\n"):gmatch("(.-)\n") do
      if line ~= "" then
        local file, lnum, rest = line:match("^(.-):(%d+):(.*)$")
        if file and file ~= "" then
          items[#items + 1] = {
            filename = file,
            lnum = tonumber(lnum),
            col = 1,
            text = rest,
          }
        end
      end
    end
    return items
  end

  if out == "" then
    -- Both rg and grep exit 1 on "no matches"; anything else is a real error.
    if res.code == 1 or res.code == 0 then
      -- A genuine zero-match search: reflect it by clearing the findings list.
      set_qf({})
      return "no matches"
    end
    -- A real failure: leave any existing findings list untouched.
    return string.format("grep failed (exit %d): %s", res.code, res.stderr or "")
  end

  -- Only replace the findings list when parsing actually yielded entries, so a
  -- parse hiccup on a non-empty result can't clobber a good existing list.
  local items = parse_items(out)
  if #items > 0 then
    set_qf(items)
  end

  local cap = 100000
  if #out > cap then
    out = out:sub(1, cap) .. "\n[truncated: output exceeded " .. cap .. " bytes; narrow the pattern or path]"
  end
  return out
end
]==],
  })

  -- ------------------------------------------------------------- bulk_replace

  define({
    name = "tool.bulk_replace",
    kind = "tool",
    doc = "Substitute text across the CURRENT findings list — the set the grep"
      .. " tool populates for THIS session — as a single native multi-file edit."
      .. " Runs Vim's `:ldo`/`:cdo s/<pattern>/<replacement>/<flags> | update`"
      .. " over every entry, editing each file THROUGH its buffer so the changes"
      .. " enter each"
      .. " file's native undo history (revert with `u`, `:earlier`, or undotree in"
      .. " that buffer). Populate the list with the grep tool first; an"
      .. " empty list is an error. (Each session has its OWN findings list when"
      .. " on-screen, so concurrent sessions never edit each other's target set.)"
      .. " This is a WRITE tool and prompts for"
      .. " confirmation. Parameters: pattern (required) — a Vim :s search pattern"
      .. " (Vim regex, NOT rg/PCRE); replacement (required) — the replacement"
      .. " text (Vim :s syntax, e.g. \\1 backreferences); flags (optional, default"
      .. " 'ge') — :s flags; the 'e' flag is always ensured so a file in the list"
      .. " with no match does not abort the run; dry_run (optional) — when true,"
      .. " report how many findings-list entries and distinct files WOULD be edited"
      .. " without changing anything. Returns the number of files changed.",
    input_schema = {
      type = "object",
      properties = {
        pattern = { type = "string", description = "Vim :s search pattern (Vim regex)." },
        replacement = { type = "string", description = "Replacement text (Vim :s syntax)." },
        flags = { type = "string", description = ":s flags (default 'ge'; 'e' is always ensured)." },
        dry_run = { type = "boolean", description = "Report the would-edit count without changing files." },
      },
      required = { "pattern", "replacement" },
    },
    source = [==[
return function(input, ctx)
  local pattern = input.pattern
  local replacement = input.replacement
  if type(pattern) ~= "string" or pattern == "" then
    error("bulk_replace: pattern must be a non-empty string")
  end
  if type(replacement) ~= "string" then
    error("bulk_replace: replacement must be a string")
  end

  -- Read THIS session's findings list: its window's location list when the
  -- session is on-screen (private, so concurrent sessions never stomp each
  -- other's target set), else the global quickfix list.
  local findings = require("straps.findings")
  local qf, list_kind = findings.get_locations(ctx and ctx.bufnr)
  if type(qf) ~= "table" or #qf == 0 then
    return "findings list is empty — run grep first to populate it"
  end

  -- Distinct files behind the findings-list entries (by resolved buffer number).
  local bufs, seen = {}, {}
  for _, e in ipairs(qf) do
    local b = e.bufnr
    if type(b) == "number" and b ~= 0 and not seen[b] then
      seen[b] = true
      bufs[#bufs + 1] = b
    end
  end

  if input.dry_run then
    return string.format(
      "dry_run: would substitute over %d %s entr%s across %d file%s (no changes made)",
      #qf, list_kind, #qf == 1 and "y" or "ies", #bufs, #bufs == 1 and "" or "s")
  end

  local function reject_cmd_chars(label, value)
    if value:find("\n", 1, true) or value:find("\r", 1, true)
      or value:find("|", 1, true) then
      error("bulk_replace: " .. label .. " must not contain newline or |")
    end
  end
  reject_cmd_chars("pattern", pattern)
  reject_cmd_chars("replacement", replacement)

  -- Use '#' as the :s delimiter and escape only that in pattern/replacement, so
  -- the pattern keeps its Vim-regex meaning and the delimiter can never be
  -- mistaken for a real character in the text.
  local pat = pattern:gsub("#", "\\#")
  local rep = replacement:gsub("#", "\\#")

  -- Always ensure the 'e' flag: :cdo aborts on the first error, and a file in
  -- the list with no match would otherwise raise E486 and stop the whole run.
  local flags = input.flags
  if type(flags) ~= "string" or flags == "" then flags = "ge" end
  if not flags:match("^[&cegijklmnpr#]*$") then
    error("bulk_replace: flags contain unsupported characters")
  end
  if not flags:find("e", 1, true) then flags = flags .. "e" end

  -- Snapshot changedtick of each target buffer so we can count what actually
  -- changed (a substitute bumps changedtick; `update` writing does not).
  local ticks = {}
  for _, b in ipairs(bufs) do
    pcall(vim.fn.bufload, b)
    ticks[b] = vim.api.nvim_buf_get_changedtick(b)
  end

  local body = string.format("s#%s#%s#%s | update", pat, rep, flags)
  local ok, err = findings.locations_do(ctx and ctx.bufnr, body)
  if not ok then
    -- Never leak a raw Vim error as the tool result; wrap it clearly.
    return "bulk_replace: substitution failed: " .. tostring(err)
  end

  local changed = 0
  for _, b in ipairs(bufs) do
    if vim.api.nvim_buf_is_valid(b) then
      if vim.api.nvim_buf_get_changedtick(b) ~= ticks[b] then
        changed = changed + 1
      end
    end
  end

  return string.format(
    "bulk_replace: applied `s#%s#%s#%s` across the %s list; %d file%s changed"
    .. " — undo with u in each buffer",
    pat, rep, flags, list_kind, changed, changed == 1 and "" or "s")
end
]==],
  })
end

return M
