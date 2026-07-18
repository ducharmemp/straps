-- straps/ui.lua — session windows, registry edit buffers, listing, eval,
-- session-buffer folding. Registry entries become editable Lua buffers
-- (straps://registry/<name>); :w re-executes them, which re-runs define.

local M = {}

local AUGROUP = "StrapsUI"
local REG_AUGROUP = "StrapsRegistryBuf" -- never cleared: holds per-buffer autocmds

local function notify_err(msg)
  vim.notify(msg, vim.log.levels.ERROR)
end

-- Transcript rendering ("quiet blocks"): a display-only layer over the raw
-- marker buffer. All hues come from the active colorscheme via `hi default
-- link` so it themes with catppuccin now and any scheme later. Nothing here
-- ever mutates buffer text or `modified` — it is extmarks, conceal and folds.

-- default=true so a user's own `hi link StrapsTool X` wins; re-applied on
-- ColorScheme because many schemes clear highlights on load.
local HL_LINKS = {
  StrapsRoleUser = "Function",     -- the `you` role tag
  StrapsRoleAgent = "Keyword",     -- the `agent` role tag
  StrapsRoleSystem = "Comment",    -- the `system` tag (dim)
  StrapsTool = "Special",          -- ⚙ glyph + tool name
  StrapsToolOk = "DiagnosticOk",   -- ✓ on a good result
  StrapsToolError = "DiagnosticError", -- ✗ on is_error
  StrapsRule = "Comment",          -- the turn rules
  StrapsCardBorder = "Comment",    -- the expanded-tool box art
}

--- (Re)establish the straps highlight groups as default links. Called from
--- setup() and on every ColorScheme so scheme switches re-link them; default
--- = true keeps a user's explicit `hi link` override in force.
function M.apply_highlights()
  for name, target in pairs(HL_LINKS) do
    vim.api.nvim_set_hl(0, name, { default = true, link = target })
  end
end

local render_ns = vim.api.nvim_create_namespace("straps_render")
local RULE_WIDTH = 52 -- fixed-ish width of the turn rules / card art

-- byte length of the leading %%[straps:KIND]%% marker token on a line, or nil.
local function marker_len(line)
  local tok = line:match("^%%%%%[straps:[a-z_]+%]%%%%")
  return tok and #tok or nil
end

-- A horizontal ─ run of n cells (>= 1).
local function bar(n)
  return string.rep("─", math.max(1, n))
end

local ROLE = {
  user = { label = "you", hl = "StrapsRoleUser" },
  assistant = { label = "agent", hl = "StrapsRoleAgent" },
  system = { label = "system", hl = "StrapsRoleSystem" },
}

-- Overlay chunk list for a role marker line: ──── <role> ─────… (StrapsRule
-- rule chars, the role word in its StrapsRole* group), fixed ~RULE_WIDTH wide.
local function role_overlay(role)
  local trailing = RULE_WIDTH - 5 - #role.label - 1
  return {
    { "──── ", "StrapsRule" },
    { role.label, role.hl },
    { " " .. bar(trailing), "StrapsRule" },
  }
end

-- Decode a tool_use block's content (pretty-printed JSON of the tool input)
-- into a Lua table. pcall-safe: returns {} on empty content or decode failure.
-- Both render surfaces (fold summary + expanded card header) need the input to
-- build the command-style fn.tool_display line.
local function decode_tool_input(bufnr, blk)
  if not blk or blk.first_lnum > blk.last_lnum then
    return {}
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, blk.first_lnum - 1, blk.last_lnum, false)
  local ok, decoded = pcall(vim.json.decode, table.concat(lines, "\n"))
  if ok and type(decoded) == "table" then
    return decoded
  end
  return {}
end

-- Ask fn.tool_display for a command-style one-liner for a tool call, then split
-- it on the FIRST space into a colored verb (StrapsTool) and dim args
-- (StrapsRule, leading space kept). pcall/try_call so a broken redefinition can
-- never break rendering — it falls back to the bare tool name. Single-token
-- displays are all-verb (empty args). Returns verb, args.
local function tool_display_parts(bufnr, blk, name)
  local input = decode_tool_input(bufnr, blk)
  local ok, disp = pcall(require("straps.registry").try_call, "fn.tool_display", name, input)
  local display = (ok and type(disp) == "string" and disp) or name
  local sp = display:find(" ", 1, true)
  if sp then
    return display:sub(1, sp - 1), display:sub(sp)
  end
  return display, ""
end

-- The tool_result block paired with the tool_use at blocks[idx] (matching id
-- when available, else the next tool_result), or nil.
local function paired_result(blocks, idx, id)
  for i = idx + 1, #blocks do
    local b = blocks[i]
    if b.kind == "tool_result" then
      if not id or not (b.attrs and b.attrs.id) or b.attrs.id == id then
        return b
      end
    end
  end
  return nil
end

--- Build the colored fold-summary chunk list for the fold starting at
--- start_lnum (a tool_use or tool_result marker line). Exposed for headless
--- tests: it needs no window or real fold. Returns {{text, hl}, ...}:
--- a tool_use folds to `▸ <verb> <args>   ✓|✗` (command-style via
--- fn.tool_display — StrapsTool verb, dim StrapsRule args); a dangling
--- tool_result keeps `▸ ⚙ result …`. StrapsToolOk/StrapsToolError on the mark.
function M._fold_summary(bufnr, start_lnum)
  local blocks = require("straps.state").list_blocks(bufnr)
  local idx, blk
  for i, b in ipairs(blocks) do
    if b.marker_lnum == start_lnum then
      idx, blk = i, b
      break
    end
  end
  -- The system block folds to a plain labelled summary (no ⚙/status), since it
  -- is a long, rarely-re-read prompt rather than a tool call.
  if blk and blk.kind == "system" then
    local nlines = math.max(0, (blk.last_lnum or blk.first_lnum) - blk.first_lnum + 1)
    return {
      { "▸ ", "StrapsRule" },
      { "system prompt", "StrapsRoleSystem" },
      { (" · %d lines"):format(nlines), "StrapsRule" },
    }
  end
  -- A tool_use folds to a command-style line: `▸ <verb> <args>   ✓|✗` — the
  -- verb (leading token of fn.tool_display) colored StrapsTool, the args dim
  -- StrapsRule. This replaces the old `⚙ <name>  <first input line>` view.
  if blk and blk.kind == "tool_use" then
    local name = (blk.attrs and blk.attrs.name) or "tool"
    local verb, args = tool_display_parts(bufnr, blk, name)
    local is_error, has_status = false, false
    local tr = paired_result(blocks, idx, blk.attrs and blk.attrs.id)
    if tr then
      is_error = (tr.attrs and tr.attrs.is_error) or false
      has_status = true
    end
    local chunks = {
      { "▸ ", "StrapsRule" },
      { verb, "StrapsTool" },
    }
    if args ~= "" then
      chunks[#chunks + 1] = { args, "StrapsRule" }
    end
    if has_status then
      chunks[#chunks + 1] = { "   ", "StrapsRule" }
      chunks[#chunks + 1] = { is_error and "✗" or "✓", is_error and "StrapsToolError" or "StrapsToolOk" }
    end
    return chunks
  end

  -- tool_result (a dangling result, or the fallback): keep the ⚙ label form.
  local name, detail, is_error, has_status = "tool", "", false, false
  if blk and blk.kind == "tool_result" then
    name = "result"
    detail = (blk.attrs and blk.attrs.id) or ""
    is_error = (blk.attrs and blk.attrs.is_error) or false
    has_status = true
  end
  local chunks = {
    { "▸ ", "StrapsRule" },
    { "⚙ " .. name, "StrapsTool" },
  }
  if detail ~= "" then
    chunks[#chunks + 1] = { "   " .. detail, "StrapsRule" }
  end
  if has_status then
    chunks[#chunks + 1] = { "   ", "StrapsRule" }
    chunks[#chunks + 1] = { is_error and "✗" or "✓", is_error and "StrapsToolError" or "StrapsToolOk" }
  end
  return chunks
end

--- foldtext function for session buffers (Neovim >= 0.10 renders the returned
--- chunk list with color). Reads v:foldstart in the current buffer.
function M.foldtext()
  return M._fold_summary(vim.api.nvim_get_current_buf(), vim.v.foldstart)
end

-- Conceal the leading marker token on a marker line (display-only).
local function conceal_marker(bufnr, row, line)
  local mlen = marker_len(line)
  if mlen then
    vim.api.nvim_buf_set_extmark(bufnr, render_ns, row, 0, {
      end_col = mlen,
      conceal = "",
    })
  end
end

-- Render one block's marks into render_ns. blocks is the full list (for
-- pairing tool_use with its tool_result when drawing the closing card rule).
local function render_block(bufnr, blk)
  local row = blk.marker_lnum - 1
  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
  if not line then
    return
  end
  local role = ROLE[blk.kind]
  if role then
    -- user / assistant / system: conceal the marker, overlay the turn rule.
    conceal_marker(bufnr, row, line)
    vim.api.nvim_buf_set_extmark(bufnr, render_ns, row, 0, {
      virt_text = role_overlay(role),
      virt_text_pos = "overlay",
      hl_mode = "combine",
    })
  elseif blk.kind == "tool_use" then
    -- Conceal the marker; draw the card header rule above it. (v1: card rules
    -- are always drawn — they read fine folded or open, since a closed fold
    -- hides the interior and shows only the colored foldtext.)
    conceal_marker(bufnr, row, line)
    local name = (blk.attrs and blk.attrs.name) or "tool"
    -- Command-style header: `╭─ <verb> <args> ─────` (fn.tool_display, same
    -- verb/args split as the fold summary). Left-anchored, no right border.
    local verb, args = tool_display_parts(bufnr, blk, name)
    local header = {
      { "╭─ ", "StrapsCardBorder" },
      { verb, "StrapsTool" },
    }
    if args ~= "" then
      header[#header + 1] = { args, "StrapsRule" }
    end
    local used = vim.fn.strdisplaywidth(verb .. args)
    header[#header + 1] = { " " .. bar(RULE_WIDTH - 4 - used), "StrapsCardBorder" }
    vim.api.nvim_buf_set_extmark(bufnr, render_ns, row, 0, {
      virt_lines_above = true,
      virt_lines = { header },
    })
  elseif blk.kind == "tool_result" then
    -- Conceal the marker; a `result` divider above and a closing rule after.
    conceal_marker(bufnr, row, line)
    vim.api.nvim_buf_set_extmark(bufnr, render_ns, row, 0, {
      virt_lines_above = true,
      virt_lines = { {
        { "├─ result ", "StrapsCardBorder" },
        { bar(RULE_WIDTH - 10), "StrapsCardBorder" },
      } },
    })
    local close_row = math.max(blk.first_lnum - 1, blk.last_lnum - 1)
    vim.api.nvim_buf_set_extmark(bufnr, render_ns, close_row, 0, {
      virt_lines_above = false,
      virt_lines = { { { "╰" .. bar(RULE_WIDTH - 1), "StrapsCardBorder" } } },
    })
  end
end

--- The render pass (fn.render delegates here). Idempotent: clears render_ns
--- and repopulates from state.list_blocks. Never mutates text or `modified`.
--- Skips everything (after clearing) when config.render == false; skips
--- unknown block kinds. Window-agnostic (extmarks are buffer-scoped); conceal
--- needs conceallevel=2, set when the session window opens.
function M._render(bufnr)
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, render_ns, 0, -1)
  local ok, straps = pcall(require, "straps")
  if ok and type(straps) == "table" and straps.config and straps.config.render == false then
    return
  end
  for _, blk in ipairs(require("straps.state").list_blocks(bufnr)) do
    render_block(bufnr, blk)
  end
end

-- Debounced render trigger: a per-buffer scheduled guard coalesces a
-- streaming burst of nvim_buf_set_lines into a single render pass.
local render_scheduled = {}
local render_attached = {}

local function schedule_render(bufnr)
  if render_scheduled[bufnr] then
    return
  end
  render_scheduled[bufnr] = true
  vim.schedule(function()
    render_scheduled[bufnr] = nil
    if vim.api.nvim_buf_is_valid(bufnr) then
      require("straps.registry").try_call("fn.render", bufnr)
    end
  end)
end

-- Attach the debounced renderer to a session buffer. buf_attach fires on BOTH
-- user edits and programmatic nvim_buf_set_lines (unlike TextChanged), so
-- appends and hand-edits both refresh. Idempotent per buffer; detaches when
-- the buffer is gone or rendering has been switched off.
function M._attach_render(bufnr)
  if render_attached[bufnr] then
    return
  end
  render_attached[bufnr] = true
  vim.api.nvim_buf_attach(bufnr, false, {
    on_lines = function(_, b)
      if not vim.api.nvim_buf_is_valid(b) then
        render_scheduled[b] = nil
        render_attached[b] = nil
        return true
      end
      local ok, straps = pcall(require, "straps")
      if ok and type(straps) == "table" and straps.config and straps.config.render == false then
        render_attached[b] = nil
        return true
      end
      schedule_render(b)
    end,
    on_detach = function(_, b)
      render_scheduled[b] = nil
      render_attached[b] = nil
    end,
  })
end

--- Set the per-buffer status flag ("running" | "idle") and redraw the
--- statusline. The loop calls this (or sets vim.b straps_status directly)
--- around a run; statuslines read vim.b.straps_status.
function M.set_status(bufnr, status)
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.b[bufnr].straps_status = status
    vim.cmd("redrawstatus")
  end
end

--- Resolve the session buffer a command should act on: a session buffer is
--- its own target, anything else resolves to nil.
function M.resolve_session(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if vim.b[bufnr].straps_session then
    return bufnr
  end
  return nil
end

-- Parse a path:line[:col] reference under the cursor. Returns path, line,
-- col (col may be nil) or nil when the cursor is not on one.
local function file_ref_at_cursor()
  local text = vim.api.nvim_get_current_line()
  local cur = vim.api.nvim_win_get_cursor(0)[2] + 1
  local init = 1
  while true do
    local s, e, path, lnum, col = text:find("([%w_%.%/~%-]+):(%d+):?(%d*)", init)
    if not s then
      return nil
    end
    if cur >= s and cur <= e then
      return path, tonumber(lnum), tonumber(col)
    end
    init = e + 1
  end
end

--- Open the path:line[:col] reference under the cursor in a non-session
--- window: reuse one already showing the file, else the first non-session
--- window, else a new split (same policy as tool.show_user). Returns true
--- when a reference was opened, false when the cursor is not on a readable
--- one — the gf mapping falls back to native gf then.
function M.open_file_ref()
  local path, lnum, col = file_ref_at_cursor()
  if not path then
    return false
  end
  local full = vim.fn.fnamemodify(path, ":p")
  if vim.fn.filereadable(full) == 0 then
    return false
  end
  local buf = vim.fn.bufadd(full)
  if not pcall(vim.fn.bufload, buf) then
    return false
  end
  local target
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == buf then
      target = win
      break
    end
  end
  if not target then
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local b = vim.api.nvim_win_get_buf(win)
      if not vim.b[b].straps_session
          and vim.api.nvim_win_get_config(win).relative == "" then
        target = win
        break
      end
    end
  end
  if not target then
    vim.cmd("botright vsplit")
    target = vim.api.nvim_get_current_win()
  end
  vim.api.nvim_win_set_buf(target, buf)
  vim.api.nvim_set_current_win(target)
  lnum = math.max(1, math.min(lnum or 1, vim.api.nvim_buf_line_count(buf)))
  pcall(vim.api.nvim_win_set_cursor, target, { lnum, math.max(0, (col or 1) - 1) })
  vim.cmd("normal! zz")
  return true
end

-- Buffer-local gf that understands the path:line references straps agents
-- are prompted to emit (and that grep results carry). Native gf remains the
-- fallback for plain paths without a :line suffix.
function M.map_file_refs(bufnr)
  vim.keymap.set("n", "gf", function()
    if not M.open_file_ref() then
      pcall(vim.cmd, "normal! gf")
    end
  end, { buffer = bufnr, desc = "straps: open file[:line[:col]] under cursor" })
end

-- Given a session transcript bufnr, open it in a split with its <CR> keymap
-- (send, or prompt to steer if a run is active) and idle status, after
-- loading the project registry. This is the whole "session stack" now: one
-- ordinary buffer, edited like any other — the transcript IS the input;
-- type your message under the trailing %%[straps:user]%% marker (anywhere,
-- really: editing earlier history is a feature) and press <CR>.
-- open_session and resume_session differ ONLY in how they obtain the
-- transcript bufnr (new_session vs open_session_file).
local function open_session_buffer(bufnr)
  -- Project registry (trusted .straps.lua, if any), so project-defined tools
  -- exist for the session's first request and land after the builtins in seq
  -- order (append-only, cache-safe). pcall: opening a session must never fail
  -- because a project file is broken.
  pcall(require("straps").load_project_registry)
  vim.cmd("split")
  vim.api.nvim_win_set_buf(0, bufnr)
  vim.b[bufnr].straps_status = "idle"
  -- filetype=straps was set on bufnr before it had a window (new_session /
  -- open_session_file), so the FileType autocmd's vim.opt_local never had a
  -- window to land on; apply the fold options now that one exists.
  M.apply_fold_opts(bufnr)
  -- Transcript rendering: window-local conceal so the marker overlays show,
  -- one render now, and a debounced renderer for future appends/edits. The
  -- whole presentation is fn.render — config.render = false skips the wiring
  -- (raw markers), and :set conceallevel=0 reveals them per window.
  local ok_straps, straps = pcall(require, "straps")
  if not (ok_straps and type(straps) == "table" and straps.config
      and straps.config.render == false) then
    vim.wo[0].conceallevel = 2
    vim.wo[0].concealcursor = "nc"
    require("straps.registry").try_call("fn.render", bufnr)
    M._attach_render(bufnr)
  end
  vim.keymap.set("n", "<CR>", function()
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
  end, { buffer = bufnr, desc = "straps: send / steer" })
  M.map_file_refs(bufnr)
  vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(bufnr), 0 })
  return bufnr
end

--- Open a fresh session: a plain transcript buffer in a split, cursor on the
--- trailing (empty) user block. <CR> in normal mode sends it; while a run is
--- active <CR> prompts to steer instead. Ordinary vim editing works
--- throughout — including editing earlier history before sending.
function M.open_session()
  local bufnr = require("straps.state").new_session()
  return open_session_buffer(bufnr)
end

--- Resume a durable session: same as open_session, but the transcript comes
--- from an existing *.straps file via open_session_file. path nil → the most
--- recent saved session (state.list_sessions()[1]); no saved sessions →
--- notify and fall through to a fresh session.
function M.resume_session(path)
  local state = require("straps.state")
  if not path then
    local sessions = state.list_sessions()
    if not sessions[1] then
      vim.notify("straps: no saved sessions")
      return M.open_session()
    end
    path = sessions[1].path
  end
  local bufnr = state.open_session_file(path)
  return open_session_buffer(bufnr)
end

--- Open a picker over state.list_sessions() ({ path, name, mtime }, newest
--- first) and resume_session() whichever one is picked. No saved sessions →
--- notify and fall through to a fresh session (mirrors resume_session()'s
--- own no-path fallback).
function M.pick_session()
  local state = require("straps.state")
  local sessions = state.list_sessions()
  if #sessions == 0 then
    vim.notify("straps: no saved sessions")
    return M.open_session()
  end
  M.pick(sessions, {
    prompt = "straps: resume session",
    format_item = function(s)
      return ("%s  (%s)"):format(s.name, os.date("%Y-%m-%d %H:%M", s.mtime))
    end,
  }, function(choice)
    if not choice then
      return
    end
    M.resume_session(choice.path)
  end)
end

-- BufWriteCmd for straps://registry/<name>: execute the buffer as Lua.
-- render() output is a registry.define{...} call, so :w redefines the entry.
local function write_entry_buffer(bufnr, name)
  local registry = require("straps.registry")
  local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  local chunk, load_err = load(text, "straps://registry/" .. name)
  if not chunk then
    notify_err("straps: " .. tostring(load_err))
    return
  end
  local ok, err = pcall(chunk)
  if not ok then
    notify_err("straps: " .. tostring(err))
    return
  end
  local entry = registry.get(name)
  local version = entry and entry.version or "?"
  vim.notify(("straps: redefined %s v%s"):format(name, version))
  vim.bo[bufnr].modified = false
end

--- Open (or reuse) the editable buffer for a registry entry.
function M.open_entry(name)
  local registry = require("straps.registry")
  if not registry.get(name) then
    notify_err("straps: no registry entry named " .. tostring(name))
    return
  end
  local bufname = "straps://registry/" .. name
  local bufnr = vim.fn.bufnr(bufname)
  local created = bufnr == -1
  if created then
    bufnr = vim.api.nvim_create_buf(false, false)
    vim.api.nvim_buf_set_name(bufnr, bufname)
  end
  -- Refresh from the registry unless the buffer holds unsaved edits.
  if created or not vim.bo[bufnr].modified then
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(registry.render(name), "\n"))
    vim.bo[bufnr].modified = false
  end
  vim.bo[bufnr].buftype = "acwrite"
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "lua"
  if created then
    local group = vim.api.nvim_create_augroup(REG_AUGROUP, { clear = false })
    vim.api.nvim_create_autocmd("BufWriteCmd", {
      group = group,
      buffer = bufnr,
      callback = function()
        write_entry_buffer(bufnr, name)
      end,
    })
  end
  vim.api.nvim_win_set_buf(0, bufnr)
  return bufnr
end

--- Scratch listing of all registry entries; <CR> opens the entry under cursor.
function M.registry_list()
  local registry = require("straps.registry")
  local lines = {}
  for _, name in ipairs(registry.names()) do
    local entry = registry.get(name)
    local doc = (entry.doc or ""):match("[^\n]*") or ""
    lines[#lines + 1] = string.format("%-36s %-5s v%-3d %s", name, entry.kind, entry.version, doc)
  end
  if #lines == 0 then
    lines = { "-- registry is empty; did you call require('straps').setup()?" }
  end
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].bufhidden = "wipe"
  vim.keymap.set("n", "<CR>", function()
    local name = vim.api.nvim_get_current_line():match("^(%S+)")
    if name and require("straps.registry").get(name) then
      M.open_entry(name)
    end
  end, { buffer = bufnr, desc = "straps: edit entry" })
  vim.cmd("split")
  vim.api.nvim_win_set_buf(0, bufnr)
  return bufnr
end

--- Execute the current buffer as a Lua chunk; notify results or error.
function M.eval_buffer()
  local bufnr = vim.api.nvim_get_current_buf()
  local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  local bufname = vim.api.nvim_buf_get_name(bufnr)
  if bufname == "" then
    bufname = "buffer " .. bufnr
  end
  local chunk, load_err = load(text, "straps:eval:" .. bufname)
  if not chunk then
    notify_err("straps: " .. tostring(load_err))
    return
  end
  local results = { pcall(chunk) }
  local ok = table.remove(results, 1)
  if not ok then
    notify_err("straps: eval error: " .. tostring(results[1]))
  elseif #results == 0 then
    vim.notify("straps: eval ok")
  else
    local parts = {}
    for i, r in ipairs(results) do
      parts[i] = vim.inspect(r)
    end
    vim.notify("straps: " .. table.concat(parts, ", "))
  end
end

-- Progress mechanism (policy is the redefinable hook.on_progress; this is
-- just the default display): a virt_text extmark on the session buffer's
-- last line plus a 500 ms timer refreshing the elapsed seconds.
local progress_ns = vim.api.nvim_create_namespace("straps_progress")
local progress_runs = {} -- bufnr -> { start = hrtime, label, timer }

local function progress_clear(bufnr)
  local st = progress_runs[bufnr]
  if not st then
    return
  end
  progress_runs[bufnr] = nil
  st.timer:stop()
  st.timer:close()
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, progress_ns, 0, -1)
  end
end

-- The elapsed clock ticks on a local timer regardless of the stream, so on
-- its own it cannot tell "alive" from "frozen". This segment reads the
-- last-byte time recorded by ctx.activity (the same signal the watchdog uses):
-- a silent-but-alive stream (pings, omitted thinking) shows "receiving", and a
-- genuine stall shows the silence grow — a real sign of life, not just a clock.
-- Only shown while waiting on the provider (streaming); a local tool produces
-- no stream bytes, so silence there is expected and not surfaced.
local function liveness_segment(streaming, silent_ms)
  if not streaming then
    return ""
  end
  if silent_ms < 2000 then
    return " · receiving"
  end
  return (" · silent %ds"):format(math.floor(silent_ms / 1000))
end
M._liveness_segment = liveness_segment -- exposed for tests

--- Record stream activity (called via ctx.activity from the provider's stdout
--- callback). Pure table write; no-op when no default-display run is active.
function M.note_activity(bufnr)
  local st = progress_runs[bufnr]
  if st then
    st.last_activity = vim.uv.hrtime()
  end
end

local function progress_draw(bufnr)
  local st = progress_runs[bufnr]
  if not st then
    return
  end
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return progress_clear(bufnr)
  end
  local now = vim.uv.hrtime()
  local secs = math.floor((now - st.start) / 1e9)
  local live = liveness_segment(st.streaming, (now - (st.last_activity or st.start)) / 1e6)
  local text = ("%s · %ds%s · <CR> steer · :StrapsStop stop"):format(st.label, secs, live)
  vim.api.nvim_buf_clear_namespace(bufnr, progress_ns, 0, -1)
  vim.api.nvim_buf_set_extmark(bufnr, progress_ns, vim.api.nvim_buf_line_count(bufnr) - 1, 0, {
    virt_text = { { text, "Comment" } },
    virt_text_pos = "eol",
  })
end

--- Default progress display for hook.on_progress events.
function M.progress(bufnr, ev)
  if type(ev) ~= "table" or not bufnr then
    return
  end
  if ev.type == "done" then
    return progress_clear(bufnr)
  end
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return progress_clear(bufnr)
  end
  local st = progress_runs[bufnr]
  if not st then
    st = { start = vim.uv.hrtime(), label = "⏳ thinking", timer = vim.uv.new_timer() }
    progress_runs[bufnr] = st
    st.timer:start(500, 500, vim.schedule_wrap(function()
      if progress_runs[bufnr] == st then
        progress_draw(bufnr) -- clears itself if the buffer went invalid
      end
    end))
  end
  if ev.type == "tool" then
    st.label = "⚙ " .. tostring(ev.name)
    st.streaming = false -- a local tool produces no stream bytes
  elseif ev.type == "thinking" then
    -- turn N/M makes turn burn visible during long runs (M = config.max_turns)
    if ev.turn and ev.max then
      st.label = ("⏳ thinking · turn %d/%d"):format(ev.turn, ev.max)
    else
      st.label = "⏳ thinking"
    end
    -- Now waiting on the provider: start the silence clock at request send so
    -- "silent Ns" is honest before the first byte, and reset it on activity.
    st.streaming = true
    st.last_activity = vim.uv.hrtime()
  elseif ev.type == "tool_done" then
    st.label = "⏳ thinking"
    st.streaming = false -- the next turn's "thinking" event re-arms it
  end -- start keeps the initial label; steer_queued keeps the current one
  progress_draw(bufnr)
end

-- Generic item picker: snacks.nvim's picker (via vim.ui.select-compatible
-- Snacks.picker.select) when present, else plain vim.ui.select. Keeps the
-- model/effort pickers below tiny and swappable — redefine M.pick (or just
-- reassign vim.ui.select yourself) to change the backend everywhere at once.
-- items: list of arbitrary values; opts: { prompt?, format_item? };
-- on_choice(item) is called with the chosen item, or nil if cancelled.
function M.pick(items, opts, on_choice)
  opts = opts or {}
  local ok_snacks, snacks = pcall(require, "snacks")
  local select_fn = (ok_snacks and type(snacks) == "table" and snacks.picker
    and snacks.picker.select) or vim.ui.select
  select_fn(items, {
    prompt = opts.prompt,
    format_item = opts.format_item,
  }, function(item)
    on_choice(item)
  end)
end

--- Open a picker over config.models ({ id, label? } or plain strings);
--- picking one sets straps.config.model. No-op (with a notify) if the
--- straps config isn't loaded or config.models is empty.
function M.pick_model()
  local ok, straps = pcall(require, "straps")
  if not ok or type(straps) ~= "table" then
    return notify_err("straps: config not available (call require('straps').setup() first)")
  end
  local models = straps.config.models
  if type(models) ~= "table" or #models == 0 then
    return notify_err("straps: config.models is empty")
  end
  M.pick(models, {
    prompt = "straps: select model",
    format_item = function(m)
      local id = type(m) == "table" and m.id or m
      local label = type(m) == "table" and m.label or nil
      local current = id == straps.config.model
      return (current and "* " or "  ") .. (label or id)
    end,
  }, function(choice)
    if not choice then
      return
    end
    local id = type(choice) == "table" and choice.id or choice
    straps.config.model = id
    vim.notify("straps: model = " .. tostring(id))
  end)
end

--- Open a picker over config.efforts ({ name, budget_tokens? }); picking one
--- sets straps.config.effort to that entry's name. Effort controls extended
--- thinking (fn.provider): budget_tokens absent/0 means thinking is off.
function M.pick_effort()
  local ok, straps = pcall(require, "straps")
  if not ok or type(straps) ~= "table" then
    return notify_err("straps: config not available (call require('straps').setup() first)")
  end
  local efforts = straps.config.efforts
  if type(efforts) ~= "table" or #efforts == 0 then
    return notify_err("straps: config.efforts is empty")
  end
  M.pick(efforts, {
    prompt = "straps: select effort",
    format_item = function(e)
      local current = e.name == straps.config.effort
      local bits = {}
      if e.level then
        bits[#bits + 1] = "level=" .. e.level
      end
      if type(e.budget_tokens) == "number" and e.budget_tokens > 0 then
        bits[#bits + 1] = "budget_tokens=" .. e.budget_tokens
      end
      local suffix = #bits > 0 and (" (" .. table.concat(bits, ", ") .. ")") or ""
      return (current and "* " or "  ") .. tostring(e.name) .. suffix
    end,
  }, function(choice)
    if not choice then
      return
    end
    straps.config.effort = choice.name
    vim.notify("straps: effort = " .. tostring(choice.name))
  end)
end

-- Foldexpr for session buffers. A tool_use marker opens a level-1 fold and the
-- following tool_result stays inside it, so one tool call collapses to a single
-- colored summary line (foldtext). The system block also folds (it is long and
-- rarely re-read): its marker opens a fold that runs until the next marker. Any
-- other marker (user / assistant) resets to level 0.
function M.foldexpr(lnum)
  local kind = vim.fn.getline(lnum):match("^%%%%%[straps:([%w_]+)%]%%%%")
  if kind == "tool_use" or kind == "system" then
    return ">1"
  elseif kind == "tool_result" then
    return "1"
  elseif kind then
    return 0
  end
  return "="
end

--- Apply the straps fold options (foldmethod=expr + foldexpr + foldtext +
--- foldlevel from config.tools_expanded) to every window currently showing
--- bufnr. Folding is window-local, so this must run once the buffer is
--- actually displayed — `vim.opt_local` from a FileType autocmd that fires
--- before the buffer is ever windowed (state.new_session/open_session_file
--- set filetype=straps on a still-hidden buffer) has no lasting effect, since
--- there is no window to attach the options to yet. Called both from the
--- FileType autocmd (covers `:e some.straps`, where the buffer is already
--- current when it fires) and from open_session_buffer (covers the common
--- new/resume-session path where filetype was set while hidden).
function M.apply_fold_opts(bufnr)
  local ok, straps = pcall(require, "straps")
  local expanded = ok and type(straps) == "table" and straps.config
    and straps.config.tools_expanded
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    vim.wo[win].foldmethod = "expr"
    vim.wo[win].foldexpr = "v:lua.require'straps.ui'.foldexpr(v:lnum)"
    vim.wo[win].foldtext = "v:lua.require'straps.ui'.foldtext()"
    vim.wo[win].foldlevel = expanded and 99 or 0
  end
end

-- Source for the fn.tool_display registry entry (compiled on define). A pure
-- function(name, input) -> string; wholly self-contained so it round-trips
-- through registry.render. The whole body is pcall-guarded: any branch throwing
-- degrades to the bare tool name, and every branch guards nil/mis-typed input.
local TOOL_DISPLAY_SRC = [==[
return function(name, input)
  local nm = type(name) == "string" and name or "tool"
  local ok, out = pcall(function()
    local inp = type(input) == "table" and input or {}
    local function str(v) return type(v) == "string" and v or nil end
    local function firstline(s)
      local nl = s:find("\n", 1, true)
      if nl then return s:sub(1, nl - 1), true end
      return s, false
    end
    local function preview()
      local keys = {}
      for k in pairs(inp) do keys[#keys + 1] = k end
      table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
      local p = ""
      for _, k in ipairs(keys) do
        local v = inp[k]
        local t = type(v)
        if t == "string" or t == "number" or t == "boolean" then
          p = (firstline(tostring(v)))
          break
        end
      end
      if #p > 50 then p = p:sub(1, 49) .. "…" end
      return p
    end
    local function default()
      local p = preview()
      if p ~= "" then return nm .. " " .. p end
      return nm
    end

    if nm == "bash" then
      local cmd = str(inp.command)
      if not cmd then return default() end
      local line, multi = firstline(cmd)
      return "$ " .. line .. (multi and " ⏎…" or "")
    elseif nm == "read_file" then
      local path = str(inp.path)
      if not path then return default() end
      local off, lim = inp.offset, inp.limit
      local suffix = ""
      if type(off) == "number" or type(lim) == "number" then
        suffix = ":" .. tostring(off or 0) .. "+" .. tostring(lim or 0)
      end
      return "read " .. path .. suffix
    elseif nm == "write_file" then
      local path = str(inp.path)
      if not path then return default() end
      local content = str(inp.content) or ""
      local n = content == "" and 0 or (select(2, content:gsub("\n", "\n")) + 1)
      return "write " .. path .. " (" .. n .. " lines)"
    elseif nm == "edit_file" then
      local path = str(inp.path)
      if not path then return default() end
      return "edit " .. path
    elseif nm == "glob" then
      local pat = str(inp.pattern)
      if not pat then return default() end
      return "glob " .. pat
    elseif nm == "grep" then
      local pat = str(inp.pattern)
      if not pat then return default() end
      local s = 'grep "' .. pat .. '"'
      local path = str(inp.path)
      if path then s = s .. " " .. path end
      return s
    elseif nm == "registry_get" then
      local n = str(inp.name)
      if not n then return default() end
      return "registry get " .. n
    elseif nm == "registry_list" then
      local kind = str(inp.kind)
      return "registry list" .. (kind and (" " .. kind) or "")
    elseif nm == "registry_define" then
      local n = str(inp.name)
      if not n then return default() end
      local kind = str(inp.kind)
      return "define " .. n .. (kind and (" (" .. kind .. ")") or "")
    elseif nm == "eval_lua" then
      local code = str(inp.code)
      if not code then return default() end
      return "lua " .. (firstline(code))
    end
    return default()
  end)
  if ok and type(out) == "string" then return out end
  return nm
end
]==]

--- Idempotent UI setup: folding for filetype=straps session buffers, plus
--- the default progress hook (a thin adapter; the mechanism lives above).
function M.setup()
  require("straps.registry").define_default({
    name = "hook.on_progress",
    kind = "hook",
    doc = "Default progress display: virt_text indicator on the session buffer. "
      .. "Redefine to reroute progress (vim.notify, fidget.nvim, ...).",
    source = [[return function(ev, ctx) return require("straps.ui").progress(ctx.bufnr, ev) end]],
  })
  -- fn.render IS the whole transcript presentation (conceal + extmarks +
  -- folds), redefinable via :StrapsEdit fn.render or turn-off-able to a no-op.
  -- The logic lives in ui._render (like hook.on_progress -> ui.progress).
  require("straps.registry").define_default({
    name = "fn.render",
    kind = "fn",
    doc = "Render the transcript: conceal raw markers, draw colored role rules "
      .. "and collapse tool calls to a summary. Display-only; never mutates "
      .. "buffer text. Redefine to reshape or no-op to show raw markers.",
    source = [[return function(bufnr) return require("straps.ui")._render(bufnr) end]],
  })
  -- fn.tool_display: a tool call -> a command-style one-liner (bash as `$ ...`,
  -- reads/writes/greps as terse verbs). Redefinable via :StrapsEdit
  -- fn.tool_display to add a formatter for an agent-defined tool or restyle.
  -- Defensive: input may be nil / wrong-shaped / missing keys — every branch
  -- guards and falls back to the default; a throw degrades to the tool name.
  require("straps.registry").define_default({
    name = "fn.tool_display",
    kind = "fn",
    doc = "Format a tool call (name, input) as a command-style one-liner: bash "
      .. "as `$ <command>`, read/write/edit/glob/grep/registry_*/eval_lua as "
      .. "terse verbs, unknown tools as `<name> <preview>`. The caller splits "
      .. "on the first space — verb colored (StrapsTool), args dim (StrapsRule).",
    source = TOOL_DISPLAY_SRC,
  })
  M.apply_highlights()
  local group = vim.api.nvim_create_augroup(AUGROUP, { clear = true })
  -- Many colorschemes clear highlights on load; re-link on ColorScheme so the
  -- straps groups survive a scheme switch (default = true keeps user overrides).
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = function()
      M.apply_highlights()
    end,
  })
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "straps",
    callback = function(ev)
      -- Only takes effect if ev.buf is showing in the current window (see
      -- apply_fold_opts). A session buffer's filetype is usually set before
      -- it is ever displayed (state.new_session/open_session_file), so
      -- open_session_buffer calls apply_fold_opts again once the buffer is
      -- actually in a window; this autocmd covers `:e some.straps` instead,
      -- where FileType fires with the buffer already current.
      M.apply_fold_opts(ev.buf)
      M.map_file_refs(ev.buf)
    end,
  })
end

return M
