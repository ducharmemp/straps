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
  StrapsRoleUser = "Function",     -- the `you` role tag + leading rule segment
  StrapsRoleAgent = "Keyword",     -- the `Cinch` (agent) role tag + leading rule segment
  StrapsRoleSystem = "Comment",    -- the `system` tag (dim)
  StrapsTool = "Special",          -- ⚙ glyph + tool name
  StrapsToolOk = "DiagnosticOk",   -- ✓ on a good result
  StrapsToolError = "DiagnosticError", -- ✗ on is_error
  StrapsRule = "Comment",          -- the turn rules
  StrapsCardBorder = "Comment",    -- the expanded-tool box art
  StrapsWinbar = "StatusLine",     -- session-window winbar (model/effort/status)
  StrapsFileRef = "Underlined",    -- path:line[:col] under treesitter (apply_file_ref_match)
  -- Treesitter captures (queries/straps/highlights.scm). The targets must
  -- stay in lockstep with the `hi def link straps*Marker` block in
  -- syntax/straps.vim — the legacy engine keeps its own copy so a bare
  -- `:e file.straps` without the parser stays colored with no Lua involved.
  ["@straps.marker.system"] = "Title",
  ["@straps.marker.user"] = "Question",
  ["@straps.marker.assistant"] = "Function",
  ["@straps.marker.tool_use"] = "PreProc",
  ["@straps.marker.tool_result"] = "Comment",
  ["@straps.esc"] = "Special",
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
local effective_provider -- defined near picker helpers; session_status uses it earlier

-- byte length of the leading %%[straps:KIND]%% marker token on a line, or nil.
local function marker_len(line)
  local tok = line:match("^%%%%%[straps:[a-z_]+%]%%%%")
  return tok and #tok or nil
end

-- A horizontal rule run of n cells (>= 1); ch defaults to the light ─.
local function bar(n, ch)
  return string.rep(ch or "─", math.max(1, n))
end

local ROLE = {
  user = { label = "you", hl = "StrapsRoleUser", bar = "─" },
  assistant = { label = "Cinch", hl = "StrapsRoleAgent", bar = "━" },
  system = { label = "system", hl = "StrapsRoleSystem", bar = "─" },
}

-- Overlay chunk list for a role marker line, fixed ~RULE_WIDTH wide. The
-- leading segment and role word carry the role's StrapsRole* group and the
-- rule char differs per role (light ─ for you/system, heavy ━ for Cinch) so
-- user and agent turns read apart at a glance; the trailing run stays dim
-- StrapsRule.
local function role_overlay(role)
  local trailing = RULE_WIDTH - 5 - #role.label - 1
  return {
    { bar(4, role.bar) .. " ", role.hl },
    { role.label, role.hl },
    { " " .. bar(trailing, role.bar), "StrapsRule" },
  }
end

-- The block kinds that are conversation turns: the units the outline lists
-- and the `]]`/`[[` motions land on (turns themselves never fold).
local TURN_KIND = { user = true, assistant = true }

-- First content line of a block, trimmed and truncated to `max` display cells —
-- the human-readable gist of a turn, for the outline and the closed-fold text.
-- Text typed on the marker line itself is content (see state.match_marker), so
-- it wins; otherwise the first non-blank body line that is not scaffolding
-- (marker-like or %%[[esc]]-escaped) is used. "" when the block is empty.
local function block_headline(bufnr, blk, max)
  max = max or 60
  local mline = vim.api.nvim_buf_get_lines(bufnr, blk.marker_lnum - 1, blk.marker_lnum, false)[1] or ""
  local text = vim.trim(mline:match("^%%%%%[straps:[a-z_]+%]%%%% ?(.*)$") or "")
  if text == "" and blk.first_lnum <= blk.last_lnum then
    for _, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, blk.first_lnum - 1, blk.last_lnum, false)) do
      local t = vim.trim(l)
      if t ~= "" and not t:match("^%%%%%[") then
        text = t
        break
      end
    end
  end
  if vim.fn.strdisplaywidth(text) > max then
    text = vim.fn.strcharpart(text, 0, max - 1) .. "…"
  end
  return text
end

-- Extent of a conversation turn: the last line before the next turn marker
-- (or EOF). A turn owns the tool_use/tool_result blocks that follow it, so
-- the outline can count them. Returns last_lnum, tool_calls.
local function turn_extent(blocks, idx)
  local last, tools = blocks[idx].last_lnum, 0
  for i = idx + 1, #blocks do
    local b = blocks[i]
    if TURN_KIND[b.kind] then
      break
    end
    if b.kind == "tool_use" then
      tools = tools + 1
    end
    last = b.last_lnum
  end
  return last, tools
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
--- start_lnum (a system, tool_use or tool_result marker line — turns never
--- fold). Exposed for headless tests: it needs no window or real fold.
--- Returns {{text, hl}, ...}: a tool_use folds to `▸ <verb> <args>   ✓|✗`
--- (command-style via fn.tool_display — StrapsTool verb, dim StrapsRule
--- args); a dangling tool_result keeps `▸ ⚙ result …`.
--- StrapsToolOk/StrapsToolError on the mark.
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

-- Debounced render trigger: a per-buffer trailing uv timer coalesces a
-- streaming burst of nvim_buf_set_lines (one text_delta each, and each on its
-- own scheduled tick) into a SINGLE render pass ~30ms after the burst settles,
-- instead of a full re-render per delta chunk.
local render_timers = {}
local render_attached = {}
local RENDER_DEBOUNCE_MS = 30

local function cancel_render_timer(bufnr)
  local t = render_timers[bufnr]
  render_timers[bufnr] = nil
  if t and not t:is_closing() then
    pcall(function() t:stop(); t:close() end)
  end
end

local function schedule_render(bufnr)
  local t = render_timers[bufnr]
  if not t then
    t = vim.uv.new_timer()
    if not t then
      -- Handle exhaustion: fall back to a one-shot scheduled render.
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(bufnr) then
          require("straps.registry").try_call("fn.render", bufnr)
        end
      end)
      return
    end
    render_timers[bufnr] = t
  end
  -- (Re)arm the trailing timer; a fresh delta within the window pushes it out.
  t:stop()
  t:start(RENDER_DEBOUNCE_MS, 0, function()
    vim.schedule(function()
      cancel_render_timer(bufnr)
      if vim.api.nvim_buf_is_valid(bufnr) then
        require("straps.registry").try_call("fn.render", bufnr)
      end
    end)
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
        cancel_render_timer(b)
        render_attached[b] = nil
        return true
      end
      local ok, straps = pcall(require, "straps")
      if ok and type(straps) == "table" and straps.config and straps.config.render == false then
        cancel_render_timer(b)
        render_attached[b] = nil
        return true
      end
      schedule_render(b)
    end,
    on_detach = function(_, b)
      cancel_render_timer(b)
      render_attached[b] = nil
    end,
  })
end

--- Redraw every surface a straps status component can live on. :redrawstatus
--- covers statuslines and winbars but NOT the tabline (:help :redrawstatus), so
--- a hand-rolled tabline component would otherwise render frozen state. `all`
--- redraws every window's statusline rather than just the current one.
function M.redraw_status(all)
  pcall(vim.cmd, all and "redrawstatus!" or "redrawstatus")
  pcall(vim.cmd, "redrawtabline")
end

--- Set the per-buffer status flag ("running" | "idle") and redraw the
--- statusline. The loop calls this (or sets vim.b straps_status directly)
--- around a run; statuslines read vim.b.straps_status.
function M.set_status(bufnr, status)
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.b[bufnr].straps_status = status
    M.redraw_status()
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

-- Per-session findings lists (quickfix isolation) ---------------------------
-- The quickfix list is GLOBAL to the Neovim instance, so two concurrent
-- sessions populating it would stomp each other — and bulk_replace, which acts
-- on "the current list", could then edit another session's files. Fix: when a
-- session is on-screen, route its findings to that WINDOW's location list
-- (per-window, private); fall back to the global quickfix list only when the
-- session has no window (e.g. a windowless subagent), which is the pre-existing
-- global behavior and no worse than today.

--- The window showing session buffer `bufnr`, or nil. Non-floating, and
--- deterministic (lowest win id) so a grep and the later bulk_replace on the
--- same session resolve to the SAME window's location list.
function M.session_win(bufnr)
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    return nil
  end
  local wins = vim.fn.win_findbuf(bufnr)
  if type(wins) ~= "table" then
    return nil
  end
  table.sort(wins)
  for _, w in ipairs(wins) do
    if vim.api.nvim_win_is_valid(w)
        and vim.api.nvim_win_get_config(w).relative == "" then
      return w
    end
  end
  return nil
end

--- Set this session's findings list. `what` = { title, items }. Uses the
--- session window's location list when on-screen (isolated per session), else
--- the global quickfix list. `open` opens the matching list window when there
--- are entries. Returns "loclist" or "quickfix" (so callers can name the right
--- :lnext/:cnext navigation).
function M.set_locations(bufnr, what, open)
  local win = M.session_win(bufnr)
  local title = what.title
  local items = what.items or {}
  if win then
    pcall(vim.fn.setloclist, win, {}, " ", { title = title, items = items })
    if open and #items > 0 then
      pcall(vim.fn.win_execute, win, "lopen")
    end
    return "loclist"
  end
  pcall(vim.fn.setqflist, {}, " ", { title = title, items = items })
  if open and #items > 0 then
    pcall(function() vim.cmd("botright copen") end)
  end
  return "quickfix"
end

--- Read this session's findings list. Returns items(list), kind, win-or-nil.
function M.get_locations(bufnr)
  local win = M.session_win(bufnr)
  if win then
    return vim.fn.getloclist(win), "loclist", win
  end
  return vim.fn.getqflist(), "quickfix", nil
end

--- Run an ex substitution across this session's findings list: `:ldo` in its
--- window (private) when on-screen, else `:cdo` globally. `body` is the part
--- after the do-command, e.g. "s#a#b#ge | update". Returns ok, err, kind.
function M.locations_do(bufnr, body)
  local win = M.session_win(bufnr)
  if win then
    local ok, err = pcall(vim.fn.win_execute, win, "silent ldo " .. body)
    return ok, err, "loclist"
  end
  local ok, err = pcall(vim.cmd, "silent cdo " .. body)
  return ok, err, "quickfix"
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
--- Public so callers holding a live session bufnr (e.g. the running-agents
--- picker) can bring it on-screen with the full session wiring.
--- @param bufnr integer session transcript buffer
--- @param split_cmd string? the :split command to open the window with;
---   defaults to "split" (horizontal). Pass "vertical split" for a vsplit,
---   or any modifier chain ("botright vsplit", "leftabove split", ...). The
---   user commands derive this from <mods>, so `:vertical Straps` just works.
function M.show_session(bufnr, split_cmd)
  -- Project registry (trusted .straps.lua, if any), so project-defined tools
  -- exist for the session's first request and land after the builtins in seq
  -- order (append-only, cache-safe). pcall: opening a session must never fail
  -- because a project file is broken.
  pcall(require("straps").load_project_registry)
  vim.cmd(split_cmd and split_cmd ~= "" and split_cmd or "split")
  vim.api.nvim_win_set_buf(0, bufnr)
  -- Don't stomp a live status: a running subagent brought on-screen by the
  -- agents picker is still "running".
  if vim.b[bufnr].straps_status == nil then
    vim.b[bufnr].straps_status = "idle"
  end
  -- filetype=straps was set on bufnr before it had a window (new_session /
  -- open_session_file), so the FileType autocmd's vim.opt_local never had a
  -- window to land on; apply the fold options now that one exists.
  M.apply_fold_opts(bufnr)
  M.apply_file_ref_match(bufnr)
  -- Window-local winbar: show the session's active model/effort (and run
  -- phase) right on its own window, so "what am I talking to" is always
  -- visible without touching the user's global statusline. config.session_winbar
  -- = false opts out (some users reserve the winbar or dislike it).
  do
    local ok_s, s = pcall(require, "straps")
    local want = not (ok_s and type(s) == "table" and s.config and s.config.session_winbar == false)
    if want then
      vim.wo[0].winbar = "%{%v:lua.require'straps.ui'.session_winbar()%}"
    end
  end
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
  M.map_navigation(bufnr)
  vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(bufnr), 0 })
  return bufnr
end

--- Open a fresh session: a plain transcript buffer in a split, cursor on the
--- trailing (empty) user block. <CR> in normal mode sends it; while a run is
--- active <CR> prompts to steer instead. Ordinary vim editing works
--- throughout — including editing earlier history before sending.
--- @param split_cmd string? split command to open the window with (see
---   M.show_session); nil/"" → horizontal "split".
function M.open_session(split_cmd)
  local bufnr = require("straps.state").new_session()
  return M.show_session(bufnr, split_cmd)
end

--- Resume a durable session: same as open_session, but the transcript comes
--- from an existing *.straps file via open_session_file. path nil → the most
--- recent saved session (state.list_sessions()[1]); no saved sessions →
--- notify and fall through to a fresh session.
--- @param split_cmd string? split command to open the window with (see
---   M.show_session); nil/"" → horizontal "split".
function M.resume_session(path, split_cmd)
  local state = require("straps.state")
  if not path then
    local sessions = state.list_sessions()
    if not sessions[1] then
      vim.notify("straps: no saved sessions")
      return M.open_session(split_cmd)
    end
    path = sessions[1].path
  end
  local bufnr = state.open_session_file(path)
  -- A session whose Neovim died mid-tool is on disk with an unpaired tool_use,
  -- which the API rejects; pair it up so the resumed transcript can be sent.
  local healed = state.heal_interrupted(bufnr)
  if healed > 0 then
    vim.notify(("straps: this session was interrupted mid-run; marked %d unfinished"
      .. " tool call(s) as interrupted (:StrapsContinue to pick up)"):format(healed))
  end
  return M.show_session(bufnr, split_cmd)
end

--- Open a picker over state.list_sessions() ({ path, name, mtime }, newest
--- first) and resume_session() whichever one is picked. No saved sessions →
--- notify and fall through to a fresh session (mirrors resume_session()'s
--- own no-path fallback).
-- A compact relative age for a session mtime: "just now", "5m ago", "2h ago",
-- "3d ago", else an absolute date once it's a week or more old.
local function relative_time(mtime)
  local delta = os.time() - (mtime or 0)
  if delta < 0 then delta = 0 end
  if delta < 60 then
    return "just now"
  elseif delta < 3600 then
    return ("%dm ago"):format(math.floor(delta / 60))
  elseif delta < 86400 then
    return ("%dh ago"):format(math.floor(delta / 3600))
  elseif delta < 7 * 86400 then
    return ("%dd ago"):format(math.floor(delta / 86400))
  end
  return os.date("%Y-%m-%d", mtime)
end
M._relative_time = relative_time -- exposed for tests

-- The picker row for a saved session: its summary (durable title or first
-- prompt) when present, else the timestamped filename, followed by a
-- right-of-centre relative age. Kept in one place so pick_session and any
-- fuzzy-backend override format rows identically.
local function session_format_item(s)
  local label = (s.summary and s.summary ~= "") and s.summary or s.name
  return ("%s  ·  %s"):format(label, relative_time(s.mtime))
end
M._session_format_item = session_format_item

-- Rich session picker with a transcript preview pane, via snacks.nvim when it
-- exposes a full picker (Snacks.picker). Returns true when it drove the pick,
-- false to fall back to the plain vim.ui.select list. Each row fuzzy-matches on
-- the summary; the preview pane renders the transcript file itself. Exposed as
-- M._pick_session_rich so tests (and users without a preview-capable picker)
-- can override it to force the plain list path.
function M._pick_session_rich(sessions, on_choice)
  local ok_snacks, snacks = pcall(require, "snacks")
  if not (ok_snacks and type(snacks) == "table" and snacks.picker
    and type(snacks.picker.pick) == "function") then
    return false
  end
  local pok = pcall(function()
    local finder_items = {}
    for i, s in ipairs(sessions) do
      finder_items[#finder_items + 1] = {
        idx = i,
        text = session_format_item(s), -- what fuzzy-matches
        file = s.path, -- previewed + shows syntax as filetype=straps
        session = s,
      }
    end
    snacks.picker.pick({
      source = "straps sessions",
      title = "straps: resume session",
      items = finder_items,
      format = "text",
      preview = "file",
      confirm = function(picker, item)
        picker:close()
        if item and item.session then
          vim.schedule(function() on_choice(item.session) end)
        end
      end,
    })
  end)
  return pok
end

function M.pick_session()
  local state = require("straps.state")
  local sessions = state.list_sessions()
  if #sessions == 0 then
    vim.notify("straps: no saved sessions")
    return M.open_session()
  end
  local function resume(choice)
    if choice then
      M.resume_session(choice.path)
    end
  end
  -- Prefer a fuzzy picker with a live transcript preview; fall back to the
  -- plain vim.ui.select list (M.pick) when no rich backend is available.
  if M._pick_session_rich(sessions, resume) then
    return
  end
  M.pick(sessions, {
    prompt = "straps: resume session",
    format_item = session_format_item,
  }, resume)
end

--- Give a saved session a durable title (state.set_session_title), so the
--- resume picker shows it instead of the timestamp/first-prompt. `bufnr` is a
--- file-backed session buffer; `title` nil prompts for one (pre-filled with the
--- current title), "" clears it. No-op with a notice on an ephemeral session.
function M.rename_session(bufnr, title)
  local state = require("straps.state")
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_get_name(bufnr)
  if not path:match("%.straps$") or vim.fn.filereadable(path) == 0 then
    vim.notify("straps: not a saved session — nothing to rename", vim.log.levels.WARN)
    return
  end
  local function apply(t)
    if t == nil then
      return -- cancelled
    end
    if state.set_session_title(path, t) then
      vim.notify(t == "" and "straps: session title cleared"
        or ("straps: session titled " .. t))
    else
      vim.notify("straps: could not write session title", vim.log.levels.WARN)
    end
  end
  if title ~= nil then
    return apply(title)
  end
  vim.ui.input({
    prompt = "session title: ",
    default = state.session_title(path) or "",
  }, apply)
end

--- Full-text search across every saved transcript: grep session_dir/*.straps
--- for `pattern` and load the hits into the quickfix list (title
--- "straps: sessions /pattern/"), so :cnext/:cprev step through them and <CR>
--- opens the transcript at the matching line. Uses ripgrep when present, else
--- Vim's :vimgrep. Marker/escape lines are skipped so hits are conversation
--- content, not transcript scaffolding. Returns the number of matches.
function M.grep_sessions(pattern)
  local state = require("straps.state")
  if not pattern or pattern == "" then
    vim.notify("straps: :StrapsSearch needs a pattern", vim.log.levels.WARN)
    return 0
  end
  local dir = state.session_dir()
  if not dir then
    vim.notify("straps: no session dir to search", vim.log.levels.WARN)
    return 0
  end
  local files = vim.fn.glob(dir .. "/*.straps", false, true)
  if #files == 0 then
    vim.notify("straps: no saved sessions to search")
    return 0
  end

  local items = {}
  local seen_files = {}
  local function add_hit(path, lnum, text)
    -- Skip transcript scaffolding: marker lines and escaped lines.
    if text:match("^%%%%%[straps:") or text:match("^%%%%%[%[esc%]%]") then
      return
    end
    local abs = vim.fn.fnamemodify(path, ":p")
    local summary = seen_files[abs]
    if summary == nil then
      summary = state.session_summary(abs) or vim.fn.fnamemodify(abs, ":t")
      seen_files[abs] = summary
    end
    items[#items + 1] = {
      filename = abs,
      lnum = lnum,
      text = vim.trim(text),
    }
  end

  if vim.fn.executable("rg") == 1 then
    local out = vim.fn.systemlist({
      "rg", "--vimgrep", "--no-heading", "--color=never",
      "--", pattern, unpack(files),
    })
    if vim.v.shell_error <= 1 then -- 0 = matches, 1 = no matches
      for _, line in ipairs(out) do
        local f, l, _, t = line:match("^(.-):(%d+):(%d+):(.*)$")
        if f then
          add_hit(f, tonumber(l), t)
        end
      end
    end
  else
    -- Fallback: Vim's :vimgrep (magic regex). pcall: no matches errors E480.
    pcall(function()
      vim.fn.setqflist({}, "r")
      vim.cmd("silent noautocmd vimgrep /" .. pattern:gsub("/", "\\/")
        .. "/j " .. table.concat(vim.tbl_map(vim.fn.fnameescape, files), " "))
      for _, e in ipairs(vim.fn.getqflist()) do
        local name = vim.api.nvim_buf_get_name(e.bufnr)
        add_hit(name, e.lnum, e.text)
      end
    end)
  end

  if #items == 0 then
    vim.notify("straps: no session matches for /" .. pattern .. "/")
    vim.fn.setqflist({}, "r", { title = "straps: sessions /" .. pattern .. "/", items = {} })
    return 0
  end
  vim.fn.setqflist({}, "r", {
    title = "straps: sessions /" .. pattern .. "/",
    items = items,
  })
  vim.cmd("botright copen")
  return #items
end

--- A short label for a session buffer: its filename tail, or a synthetic name
--- for ephemeral (nofile) sessions. Public because fn.peer_agents labels the
--- same buffers for the agent that running_agents labels for the user — one
--- naming scheme, not two.
function M.session_label(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    return "buffer " .. bufnr
  end
  return vim.fn.fnamemodify(name, ":t")
end
local session_label = M.session_label

--- Snapshot of every currently-running agent, as
--- { bufnr, label, parent (bufnr|nil), parent_label (string|nil), depth,
---   task (string|nil) }, top-level agents first then by depth. "Agent" here
--- means a session buffer with an active run; a subagent is one whose
--- straps_parent points at another session buffer.
function M.running_agents()
  local bufs = require("straps.loop").running_sessions()
  local agents = {}
  for _, bufnr in ipairs(bufs) do
    local parent = vim.b[bufnr].straps_parent
    if type(parent) ~= "number" or not vim.api.nvim_buf_is_valid(parent) then
      parent = nil
    end
    agents[#agents + 1] = {
      bufnr = bufnr,
      label = session_label(bufnr),
      parent = parent,
      parent_label = parent and session_label(parent) or nil,
      depth = tonumber(vim.b[bufnr].straps_spawn_depth) or 0,
      task = vim.b[bufnr].straps_task,
    }
  end
  table.sort(agents, function(a, b)
    if a.depth ~= b.depth then
      return a.depth < b.depth
    end
    return a.bufnr < b.bufnr
  end)
  return agents
end

--- Picker over running agents; picking one brings its transcript on-screen
--- (M.show_session), so a running subagent is navigable to watch its output
--- live. Each row shows the session, its parent (for subagents), and the
--- one-line task the parent gave it.
function M.pick_agents()
  local agents = M.running_agents()
  if #agents == 0 then
    vim.notify("straps: no agents are running")
    return
  end
  M.pick(agents, {
    prompt = "straps: running agents",
    format_item = function(a)
      local parts = { a.label }
      if a.parent_label then
        parts[#parts + 1] = "◂ " .. a.parent_label
      end
      if a.task and a.task ~= "" then
        parts[#parts + 1] = a.task
      end
      local indent = string.rep("  ", a.depth)
      return indent .. table.concat(parts, "  ·  ")
    end,
  }, function(choice)
    if choice and vim.api.nvim_buf_is_valid(choice.bufnr) then
      M.show_session(choice.bufnr)
    end
  end)
end

--- Statusline component: a compact count of running agents, "" when none.
--- Format: "🤖 N" for N top-level runs, "🤖 N+M" when M subagents are also
--- active (M = agents with a parent). Drop it into a statusline with
--- %{v:lua.require'straps.ui'.agents_status()}.
function M.agents_status()
  local agents = M.running_agents()
  if #agents == 0 then
    return ""
  end
  local subs = 0
  for _, a in ipairs(agents) do
    if a.parent then
      subs = subs + 1
    end
  end
  local top = #agents - subs
  if subs > 0 then
    return ("🤖 %d+%d"):format(top, subs)
  end
  return ("🤖 %d"):format(top)
end

-- ── the agents buffer (straps://agents) ────────────────────────────────────
-- A single ordinary buffer listing ALL sessions — running, loaded-but-idle,
-- and saved-on-disk — with a tiny keymap grammar. Buffers are state
-- (invariant 1): the content is rendered from live state (all_sessions()) by
-- a redefinable registry fn (fn.agents_render, invariant 2).

local AGENTS_BUFNAME = "straps://agents"
local agents_ns = vim.api.nvim_create_namespace("straps_agents")
local AGENTS_RULE_WIDTH = 52 -- match the transcript renderer's rule width

-- Line -> entry map, keyed by agents bufnr -> { [lnum] = { kind, bufnr?, path? } }.
-- Module-level (NOT vim.b): vim.b cannot hold a sparse integer-keyed table
-- (msgpack conversion). Rebuilt on every render.
local agents_lines = {}

-- A trailing debounce timer for agents_refresh(), following schedule_render's
-- pattern. Module-level: one agents buffer at a time.
local agents_timer = nil

--- Every agent session, classified into three disjoint sets:
---   running — an active run (M.running_agents() rows).
---   loaded  — a straps_session buffer with no active run.
---   saved   — a *.straps transcript on disk with no loaded buffer.
--- A session is in exactly one set. Used by fn.agents_render.
function M.all_sessions()
  local loop = require("straps.loop")
  local state = require("straps.state")

  local running = M.running_agents()

  -- Names of every loaded valid buffer, to exclude their paths from `saved`.
  -- (Do NOT use vim.fn.bufnr(path): it does substring/pattern matching and
  -- can false-positive or throw on special chars.)
  local loaded_names = {}
  local loaded = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) then
      local name = vim.api.nvim_buf_get_name(b)
      if name ~= "" then
        loaded_names[vim.fn.fnamemodify(name, ":p")] = true
      end
      if vim.b[b].straps_session == true and not loop.running(b) then
        local file_backed = vim.bo[b].buftype == "" and name ~= ""
        loaded[#loaded + 1] = {
          bufnr = b,
          label = session_label(b),
          title = file_backed and state.session_title(name) or nil,
          info = M.session_info(b), -- may be nil when setup never ran
        }
      end
    end
  end

  local saved = {}
  for _, s in ipairs(state.list_sessions()) do
    if not loaded_names[vim.fn.fnamemodify(s.path, ":p")] then
      saved[#saved + 1] = s
    end
  end

  return { running = running, loaded = loaded, saved = saved }
end

-- One section rule line "━━ <name> ━━━…" at AGENTS_RULE_WIDTH; the leading and
-- trailing runs get StrapsRule. Returns the text; the caller sets the extmark.
local function agents_rule(name)
  local trailing = AGENTS_RULE_WIDTH - 3 - #name - 1
  return bar(2, "━") .. " " .. name .. " " .. bar(math.max(1, trailing), "━")
end

-- Implementation of fn.agents_render: rewrite ALL lines of the agents buffer
-- from live state, then redraw the straps_agents extmarks. Never leaves the
-- buffer modifiable — the body is pcall'd and modifiable is restored in a
-- guaranteed path.
function M._agents_render(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  vim.bo[bufnr].modifiable = true
  local ok, err = pcall(function()
    local sets = M.all_sessions()
    local lines = {}
    local map = {} -- lnum -> entry
    -- Deferred highlight ops: { row, col_start, col_end, hl } applied after the
    -- lines are set (extmarks need the line to exist).
    local hls = {}
    local function rule(name)
      lines[#lines + 1] = agents_rule(name)
      hls[#hls + 1] = { #lines - 1, 0, -1, "StrapsRule" }
    end

    local empty = #sets.running == 0 and #sets.loaded == 0 and #sets.saved == 0
    if empty then
      lines[#lines + 1] = "no agent sessions — :Straps starts one"
      hls[#hls + 1] = { 0, 0, -1, "StrapsRule" }
    else
      if #sets.running > 0 then
        rule("running")
        for _, a in ipairs(sets.running) do
          local indent = string.rep("  ", a.depth or 0)
          local info = M.session_info(a.bufnr)
          local model = (info and info.model_label) or nil
          local phase = vim.b[a.bufnr].straps_phase
          if phase == nil or phase == "" then
            phase = "running"
          end
          local glyph_col = #indent
          local parts = { a.label }
          if model then parts[#parts + 1] = model end
          parts[#parts + 1] = phase
          if a.task and a.task ~= "" then parts[#parts + 1] = a.task end
          local text = indent .. "▶ " .. table.concat(parts, "  ")
          lines[#lines + 1] = text
          local row = #lines - 1
          map[#lines] = { kind = "running", bufnr = a.bufnr }
          -- ▶ glyph -> StrapsTool; the label -> StrapsRoleAgent; the metadata
          -- (model + phase + task) -> dim StrapsRule.
          local glyph_byte = glyph_col + #"▶"
          hls[#hls + 1] = { row, glyph_col, glyph_byte, "StrapsTool" }
          local label_start = glyph_byte + 1 -- past the space
          local label_end = label_start + #a.label
          hls[#hls + 1] = { row, label_start, label_end, "StrapsRoleAgent" }
          hls[#hls + 1] = { row, label_end, -1, "StrapsRule" }
        end
      end

      if #sets.loaded > 0 then
        rule("loaded")
        for _, l in ipairs(sets.loaded) do
          local model = (l.info and l.info.model_label) or nil
          local parts = { l.label }
          if l.title and l.title ~= "" then parts[#parts + 1] = l.title end
          if model then parts[#parts + 1] = model end
          local text = "∙ " .. table.concat(parts, "  ")
          lines[#lines + 1] = text
          local row = #lines - 1
          map[#lines] = { kind = "loaded", bufnr = l.bufnr }
          hls[#hls + 1] = { row, 0, #"∙", "StrapsTool" }
          local label_start = #"∙" + 1
          local label_end = label_start + #l.label
          hls[#hls + 1] = { row, label_start, label_end, "StrapsRoleAgent" }
          hls[#hls + 1] = { row, label_end, -1, "StrapsRule" }
        end
      end

      if #sets.saved > 0 then
        rule("saved")
        for _, s in ipairs(sets.saved) do
          local label = (s.summary and s.summary ~= "") and s.summary or s.name
          local text = "  " .. label .. "  " .. relative_time(s.mtime)
          lines[#lines + 1] = text
          local row = #lines - 1
          map[#lines] = { kind = "saved", path = s.path }
          -- The age tail -> dim StrapsRule.
          local age_start = #("  " .. label .. "  ")
          hls[#hls + 1] = { row, age_start, -1, "StrapsRule" }
        end
      end
    end

    lines[#lines + 1] = "<CR> open   x stop   i steer   r rename   R refresh"
    hls[#hls + 1] = { #lines - 1, 0, -1, "StrapsRule" }

    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    -- Idempotent: clear the whole namespace before repopulating, so N renders
    -- leave exactly one render's worth of extmarks.
    vim.api.nvim_buf_clear_namespace(bufnr, agents_ns, 0, -1)
    for _, h in ipairs(hls) do
      local row, cs, ce, hl = h[1], h[2], h[3], h[4]
      pcall(vim.api.nvim_buf_set_extmark, bufnr, agents_ns, row, cs, {
        end_col = ce == -1 and nil or ce,
        end_row = ce == -1 and (row + 1) or nil,
        hl_group = hl,
      })
    end
    agents_lines[bufnr] = map
  end)
  vim.bo[bufnr].modifiable = false
  if not ok then
    error(err)
  end
end

-- The agents buffer, or nil: an exact-name match over loaded buffers (never
-- vim.fn.bufnr, which pattern-matches).
local function find_agents_buf()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b)
      and vim.api.nvim_buf_get_name(b) == AGENTS_BUFNAME then
      return b
    end
  end
  return nil
end

-- Re-render the agents buffer via the registry fn (redefinable).
local function agents_do_render(bufnr)
  require("straps.registry").try_call("fn.agents_render", bufnr)
end

--- Debounced re-render of the agents buffer, if one is open. Called on every
--- progress event of every run (loop.progress) and on BufEnter — cheap no-op
--- when no agents buffer exists.
function M.agents_refresh()
  local buf = find_agents_buf()
  if not buf then
    return
  end
  if not agents_timer then
    agents_timer = vim.uv.new_timer()
  end
  agents_timer:stop()
  agents_timer:start(100, 0, function()
    -- The timer callback runs in libuv context: schedule the actual render and
    -- re-check validity inside, exactly like schedule_render does.
    vim.schedule(function()
      local b = find_agents_buf()
      if b and vim.api.nvim_buf_is_valid(b) then
        agents_do_render(b)
      end
    end)
  end)
end

-- One INFO notify used by the keymaps when a key does not apply to a row.
local function agents_notify_not_running()
  vim.notify("straps: not a running agent", vim.log.levels.INFO)
end

-- The entry the line map resolves for a 1-based line, or nil. Exposed for tests.
function M._agents_line(bufnr, lnum)
  local map = agents_lines[bufnr]
  return map and map[lnum] or nil
end

-- The <CR>/x/i/r/R handlers, split out so tests can drive them directly.
function M._agents_key(bufnr, key)
  local map = agents_lines[bufnr]
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local entry = map and map[lnum] or nil
  if key == "R" then
    agents_do_render(bufnr)
    return
  end
  if key == "cr" then
    if not entry then return end
    -- A row can go stale between the last render and the keypress (the
    -- session buffer wiped, the transcript deleted): report and re-render
    -- instead of throwing or loading an empty buffer.
    if entry.kind == "running" or entry.kind == "loaded" then
      if not vim.api.nvim_buf_is_valid(entry.bufnr) then
        vim.notify("straps: that session buffer is gone", vim.log.levels.INFO)
        agents_do_render(bufnr)
        return
      end
      M.show_session(entry.bufnr)
    elseif entry.kind == "saved" then
      if vim.fn.filereadable(entry.path) ~= 1 then
        vim.notify("straps: transcript no longer exists", vim.log.levels.INFO)
        agents_do_render(bufnr)
        return
      end
      M.resume_session(entry.path)
    end
    M.agents_refresh()
  elseif key == "x" then
    if entry and entry.kind == "running" then
      -- loop.stop notifies its own no-run race itself; do not double-notify.
      require("straps.loop").stop(entry.bufnr)
      M.agents_refresh()
    else
      agents_notify_not_running()
    end
  elseif key == "i" then
    if entry and entry.kind == "running" then
      local target = entry.bufnr
      vim.ui.input({ prompt = "steer: " }, function(txt)
        if txt and txt ~= "" then
          require("straps.loop").steer(target, txt)
        end
      end)
    else
      agents_notify_not_running()
    end
  elseif key == "r" then
    if entry and entry.kind == "loaded" then
      M.rename_session(entry.bufnr)
    elseif entry and entry.kind == "saved" then
      local state = require("straps.state")
      local path = entry.path
      vim.ui.input({
        prompt = "session title: ",
        default = state.session_title(path) or "",
      }, function(txt)
        if txt ~= nil then
          state.set_session_title(path, txt)
          M.agents_refresh()
        end
      end)
      return
    elseif entry and entry.kind == "running" then
      vim.notify("straps: rename not supported for a running session", vim.log.levels.INFO)
      return
    end
    M.agents_refresh()
  end
end

--- Open (or reuse) the straps://agents buffer in a window and render it. The
--- split placement follows the same <mods>-derived plumbing as show_session.
function M.open_agents(split_cmd)
  local bufnr = find_agents_buf()
  if not bufnr then
    bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(bufnr, AGENTS_BUFNAME)
    vim.bo[bufnr].buftype = "nofile"
    vim.bo[bufnr].bufhidden = "hide"
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].modifiable = false
    vim.bo[bufnr].filetype = "strapsagents"

    local function map(lhs, key)
      vim.keymap.set("n", lhs, function() M._agents_key(bufnr, key) end,
        { buffer = bufnr, nowait = true, silent = true })
    end
    map("<CR>", "cr")
    map("x", "x")
    map("i", "i")
    map("r", "r")
    map("R", "R")

    local group = vim.api.nvim_create_augroup("StrapsAgentsBuf" .. bufnr, { clear = true })
    -- BufEnter catches saved/idle churn that emits no progress events.
    vim.api.nvim_create_autocmd("BufEnter", {
      group = group,
      buffer = bufnr,
      callback = function() M.agents_refresh() end,
    })
    -- The agents buffer uses BufWipeout for cleanup because nothing attaches to
    -- it (render_timers uses buf_attach's detach callback instead).
    vim.api.nvim_create_autocmd("BufWipeout", {
      group = group,
      buffer = bufnr,
      callback = function()
        if agents_timer and not agents_timer:is_closing() then
          pcall(function() agents_timer:stop(); agents_timer:close() end)
        end
        agents_timer = nil
        agents_lines[bufnr] = nil
      end,
    })
  end

  -- Reuse a window already showing it, else open one via the same split
  -- plumbing as show_session.
  local win
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(w) == bufnr then
      win = w
      break
    end
  end
  if win then
    vim.api.nvim_set_current_win(win)
  else
    vim.cmd(split_cmd and split_cmd ~= "" and split_cmd or "split")
    vim.api.nvim_win_set_buf(0, bufnr)
  end

  agents_do_render(bufnr)
  -- Cursor on the first row (line 1 is a section rule or the empty-state line;
  -- landing on line 1 is fine — no entry there is a no-op for the keymaps).
  pcall(vim.api.nvim_win_set_cursor, 0, { 1, 0 })
  return bufnr
end

--- Humanize a token count for display: 138879 -> "138.9k", 950 -> "950".
--- Public because every hand-written status component needs exactly this and
--- would otherwise reimplement it.
function M.human_tokens(n)
  n = tonumber(n) or 0
  if n >= 1000 then
    local s = string.format("%.1fk", n / 1000)
    s = s:gsub("%.0k$", "k")
    return s
  end
  return tostring(n)
end

--- Format the model/effort segment of a session_info table (see M.session_info).
--- Shared by session_status and session_winbar so the two never drift.
local function format_status(info)
  local out = " " .. info.model_label
  if info.effort and info.effort ~= "off" then
    out = out .. " · " .. info.effort
  end
  if info.overridden then
    out = out .. "*"
  end
  return out
end

--- Format the usage segment of a session_info table, "" when it has no usage.
local function format_usage(info)
  local u = info.usage
  if not u then
    return ""
  end
  local seg
  if info.context and info.context > 0 then
    seg = string.format("%s/%s (%d%%)",
      M.human_tokens(info.context_used), M.human_tokens(info.context), info.context_pct)
  else
    seg = M.human_tokens(info.context_used) .. " ctx"
  end
  if info.cache_pct then
    seg = seg .. string.format(" · cache %d%%", info.cache_pct)
  end
  return seg
end

--- Statusline component for a SESSION buffer: the provider-specific model and
--- effort that will be used for its next run. "" for non-session buffers (so it
--- disappears everywhere else). Format: " model" or " model · effort" (effort
--- omitted when "off"); a trailing "*" marks a session whose effective
--- provider/model/effort DIVERGES from the global config default. `bufnr`
--- defaults to the current buffer — pass it explicitly from a component that
--- runs outside the target window's context (lualine, heirline, a tabline).
--- Drop it into a statusline with
--- %{v:lua.require'straps.ui'.session_status()}.
function M.session_status(bufnr)
  local info = M.session_info(bufnr)
  if not info then
    return ""
  end
  return format_status(info)
end

--- A compact usage segment for a session buffer: context fill and cache hit
--- rate from the last response's token usage (vim.b.straps_usage, set by the
--- loop). "" when there is no usage yet or off a session buffer. `bufnr`
--- defaults to the current buffer. Kept self-contained so a manual statusline
--- can use it too.
function M.usage_status(bufnr)
  local info = M.session_info(bufnr)
  if not info then
    return ""
  end
  return format_usage(info)
end

--- Winbar for a session window: the active model/effort (session_status) plus
--- a right-aligned run status (running/idle). Auto-installed on session windows
--- unless config.session_winbar = false; also usable manually via
--- %{%v:lua.require'straps.ui'.session_winbar()%}. "" for non-session buffers.
--- `bufnr` defaults to the current buffer.
function M.session_winbar(bufnr)
  local info = M.session_info(bufnr)
  if not info then
    return ""
  end
  local left = "straps" .. format_status(info)
  local usage = format_usage(info)
  local mid = (usage ~= "") and (usage .. "  ") or ""
  local right = (info.status == "running") and "● running" or "○ idle"
  return "%#StrapsWinbar#" .. left .. "%=" .. mid .. right .. " "
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

--- Merge live-discovered models over the static config.models list. The static
--- list wins on hand-curated labels (the user picked those wording); live
--- discovery is authoritative for which models EXIST and their thinking tag
--- (fetched from the API's own capabilities). Order: configured entries first,
--- in their configured order, then any live-only models appended. A live entry
--- with no static counterpart brings its API display_name as the label.
local function merge_models(static_list, live_list)
  static_list = type(static_list) == "table" and static_list or {}
  local by_id, order = {}, {}
  local function norm(m)
    return type(m) == "table" and m or { id = m }
  end
  local function copy_model(m)
    local out = {}
    for k, v in pairs(m) do out[k] = v end
    return out
  end
  for _, m in ipairs(static_list) do
    m = norm(m)
    if type(m.id) == "string" and not by_id[m.id] then
      by_id[m.id] = copy_model(m)
      order[#order + 1] = m.id
    end
  end
  for _, m in ipairs(live_list or {}) do
    if type(m) == "table" and type(m.id) == "string" then
      local existing = by_id[m.id]
      if existing then
        -- Keep a hand-set label; fill gaps from the live entry.
        existing.label = existing.label or m.label
        if existing.thinking == nil then existing.thinking = m.thinking end
        if existing.context == nil then existing.context = m.context end
        if existing.max_output == nil then existing.max_output = m.max_output end
      else
        by_id[m.id] = copy_model(m)
        order[#order + 1] = m.id
      end
    end
  end
  local out = {}
  for _, id in ipairs(order) do
    out[#out + 1] = by_id[id]
  end
  return out
end
M._merge_models = merge_models -- exposed for tests

--- Model / effort selection is per-buffer when invoked ON a session buffer
--- (written to vim.b straps_model or straps_openai_model / straps_effort,
--- which fn.provider reads in preference to the global config), and sets the global config default
--- otherwise. These helpers centralize the "session buffer? scope it; else
--- global" decision and report the effective value for the picker's current-*
--- marker. Returns the target bufnr or nil (global).
local function session_target_buf()
  local bufnr = vim.api.nvim_get_current_buf()
  local ok = pcall(function() return vim.b[bufnr].straps_session end)
  if ok and vim.b[bufnr].straps_session then
    return bufnr
  end
  return nil
end

--- Effective provider for a target: per-buffer override, else config.provider
--- (if pinned in setup), else the persisted file, else "anthropic".
effective_provider = function(straps, bufnr)
  if bufnr then
    local p = vim.b[bufnr].straps_provider
    if p and p ~= "" then return p end
  end
  if straps.config.provider and straps.config.provider ~= "" then
    return straps.config.provider
  end
  local pref = require("straps.registry").try_call("fn.provider_pref")
  if type(pref) == "string" and pref ~= "" then return pref end
  return "anthropic"
end

--- Effective model for a target (per-buffer override else provider-specific global config).
local function effective_model(straps, bufnr)
  if bufnr then
    local p = effective_provider(straps, bufnr)
    local m = p == "openai" and vim.b[bufnr].straps_openai_model or vim.b[bufnr].straps_model
    if m and m ~= "" then return m end
  end
  if effective_provider(straps, bufnr) == "openai" then
    return straps.config.openai_model or "gpt-5"
  end
  return straps.config.model
end

--- Effective effort for a target (per-buffer override else global config).
local function effective_effort(straps, bufnr)
  if bufnr then
    local e = vim.b[bufnr].straps_effort
    if e and e ~= "" then return e end
  end
  return straps.config.effort
end

--- The entry in the active provider's model list matching `model`, or nil.
--- One scan shared by the label and context-window lookups, which want
--- different fields off the same entry.
local function model_entry(cfg, provider, model)
  local list = cfg[provider == "openai" and "openai_models" or "models"]
  if type(list) ~= "table" or not model then
    return nil
  end
  for _, m in ipairs(list) do
    if type(m) == "table" and m.id == model then
      return m
    end
  end
  return nil
end

--- Everything a status component could want about a session buffer, with the
--- per-buffer-override -> global-config fallback chain ALREADY RESOLVED, so a
--- caller never has to reimplement it from the raw vim.b vars.
---
--- Returns nil when `bufnr` (default: the current buffer) is not a valid
--- session buffer, so a component can early-out with "". Fields:
---   bufnr        the buffer this describes
---   provider     "anthropic" | "openai"
---   model        effective model id
---   model_label  its config label if listed, else the raw id (never nil)
---   effort       effective effort name ("off" when unset)
---   overridden   true when provider/model/effort DIVERGE from global config
---   status       "running" | "idle"
---   parent       parent session bufnr for a subagent, else nil
---   usage        last turn's token usage table, or nil when none yet
---   context_used billed input tokens = the current context fill (0 with no usage)
---   context      resolved context window, or nil when unknown
---   context_pct  rounded percent of `context` used, nil when context is unknown
---   cache_pct    rounded cache hit rate, nil when caching did nothing
---
--- Percentages are pre-rounded integers so every consumer renders the same
--- number a "%d" format would otherwise truncate differently.
function M.session_info(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  -- An external consumer (a lualine component caching a bufnr, a tabline over
  -- a closed tab) can easily hand us a dead buffer; vim.b on one THROWS, and a
  -- statusline expression that errors gets the option reset. Guard once here
  -- instead of pcall-wrapping every read below.
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.b[bufnr].straps_session ~= true then
    return nil
  end
  local ok, straps = pcall(require, "straps")
  if not ok or type(straps) ~= "table" or type(straps.config) ~= "table" then
    return nil
  end
  local cfg = straps.config

  local provider = effective_provider(straps, bufnr)
  -- effective_model can return nil (an unset config.model); the raw-id label
  -- fallback and the "?" placeholder keep every string field non-nil.
  local model = effective_model(straps, bufnr) or "?"
  local effort = effective_effort(straps, bufnr) or "off"
  local entry = model_entry(cfg, provider, model)
  local label = (entry and type(entry.label) == "string" and entry.label ~= "") and entry.label or model

  -- Divergence, not mere presence of an override: a per-buffer value equal to
  -- the global default is not a divergence and gets no marker.
  local global = { config = cfg }
  local overridden = provider ~= effective_provider(global, nil)
    or model ~= (effective_model(global, nil) or "?")
    or effort ~= (effective_effort(global, nil) or "off")

  local info = {
    bufnr = bufnr,
    provider = provider,
    model = model,
    model_label = label,
    effort = effort,
    overridden = overridden,
    status = vim.b[bufnr].straps_status or "idle",
    parent = nil,
    usage = nil,
    context_used = 0,
    context = tonumber(entry and entry.context) or tonumber(cfg.context_window),
    context_pct = nil,
    cache_pct = nil,
  }

  local parent = vim.b[bufnr].straps_parent
  if type(parent) == "number" and vim.api.nvim_buf_is_valid(parent) then
    info.parent = parent
  end

  -- Usage only counts once a response has reported a billed input side; the
  -- context axis is input_billed (fresh input + both cache tiers), not `input`.
  local u = vim.b[bufnr].straps_usage
  if type(u) == "table" and (tonumber(u.input_billed) or 0) > 0 then
    info.usage = u
    info.context_used = tonumber(u.input_billed)
    if info.context and info.context > 0 then
      info.context_pct = math.floor((info.context_used / info.context) * 100 + 0.5)
    end
    local cached = tonumber(u.cache_read) or 0
    if cached > 0 then
      info.cache_pct = math.floor((cached / info.context_used) * 100 + 0.5)
    end
  end

  return info
end
--- Open a picker over the available models; picking one sets the model
--- PER-BUFFER (vim.b straps_model) when run on a session buffer, else the
--- global straps.config.model. The list is config.models (the curated static
--- list) MERGED with a live GET /v1/models via fn.list_models, so the menu
--- reflects what the account can actually use (new models appear without a
--- config edit). A merged entry inherits the API's thinking tag so extended
--- thinking still works. On fetch failure the static list is used with a
--- notify — the picker never breaks. No-op if the straps config isn't loaded.
function M.pick_model()
  local ok, straps = pcall(require, "straps")
  if not ok or type(straps) ~= "table" then
    return notify_err("straps: config not available (call require('straps').setup() first)")
  end
  local target = session_target_buf()
  local provider = effective_provider(straps, target)
  local model_key = provider == "openai" and "openai_models" or "models"
  local static_list = type(straps.config[model_key]) == "table" and straps.config[model_key] or {}

  local live, err = require("straps.registry").try_call("fn.list_models", provider)
  if type(live) ~= "table" then
    if err then
      vim.notify("straps: live model discovery failed (" .. tostring(err)
        .. "); showing config." .. model_key, vim.log.levels.WARN)
    end
    live = nil
  end
  local models = merge_models(static_list, live)
  if #models == 0 then
    return notify_err("straps: no models available (config." .. model_key .. " empty and discovery failed)")
  end

  -- Persist the merged provider-specific list so provider calls can look up
  -- Anthropic thinking/context metadata and repeat pickers are instant offline.
  straps.config[model_key] = models

  local current_model = effective_model(straps, target)
  M.pick(models, {
    prompt = (target and "straps: select " or "straps: select ")
      .. provider .. " model" .. (target and " (this session)" or " (global)"),
    format_item = function(m)
      local id = type(m) == "table" and m.id or m
      local label = type(m) == "table" and m.label or nil
      local current = id == current_model
      return (current and "* " or "  ") .. (label or id)
    end,
  }, function(choice)
    if not choice then
      return
    end
    local id = type(choice) == "table" and choice.id or choice
    if target and vim.api.nvim_buf_is_valid(target) then
      if provider == "openai" then
        vim.b[target].straps_openai_model = id
      else
        vim.b[target].straps_model = id
      end
      vim.notify("straps: " .. provider .. " model = " .. tostring(id) .. " (this session)")
    else
      if provider == "openai" then
        straps.config.openai_model = id
      else
        straps.config.model = id
      end
      vim.notify("straps: " .. provider .. " model = " .. tostring(id))
    end
    M.redraw_status(true)
  end)
end

--- Open a picker over config.efforts ({ name, budget_tokens? }); picking one
--- sets the effort PER-BUFFER (vim.b straps_effort) when run on a session
--- buffer, else the global straps.config.effort. Effort controls extended
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
  local target = session_target_buf()
  local current_effort = effective_effort(straps, target)
  M.pick(efforts, {
    prompt = target and "straps: select effort (this session)" or "straps: select effort (global)",
    format_item = function(e)
      local current = e.name == current_effort
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
    if target and vim.api.nvim_buf_is_valid(target) then
      vim.b[target].straps_effort = choice.name
      vim.notify("straps: effort = " .. tostring(choice.name) .. " (this session)")
    else
      straps.config.effort = choice.name
      vim.notify("straps: effort = " .. tostring(choice.name))
    end
    M.redraw_status(true)
  end)
end

--- Open a picker over the available backends (anthropic / openai). On a session
--- buffer it sets the provider PER-BUFFER (vim.b straps_provider), session-only
--- like :StrapsModel. Otherwise it sets the GLOBAL default AND persists it to
--- $XDG_CONFIG_HOME/straps/provider (fn.provider_pref) so the choice survives
--- restarts — the durable twin of the key files in the same directory.
function M.pick_provider()
  local ok, straps = pcall(require, "straps")
  if not ok or type(straps) ~= "table" then
    return notify_err("straps: config not available (call require('straps').setup() first)")
  end
  local providers = { "anthropic", "openai" }
  local target = session_target_buf()
  local current = effective_provider(straps, target)
  M.pick(providers, {
    prompt = target and "straps: select provider (this session)" or "straps: select provider (global, persisted)",
    format_item = function(p)
      return (p == current and "* " or "  ") .. p
    end,
  }, function(choice)
    if not choice then
      return
    end
    if target and vim.api.nvim_buf_is_valid(target) then
      vim.b[target].straps_provider = choice
      vim.notify("straps: provider = " .. choice .. " (this session)")
      vim.schedule(function()
        vim.notify("straps: run :StrapsModel to pick this session's " .. choice .. " model")
      end)
    else
      straps.config.provider = choice
      local _, err = require("straps.registry").try_call("fn.provider_pref", choice)
      if err then
        vim.notify("straps: provider = " .. choice
          .. " (this Neovim only — could not persist: " .. tostring(err) .. ")",
          vim.log.levels.WARN)
      else
        vim.notify("straps: provider = " .. choice .. " (persisted)")
        vim.schedule(function()
          vim.notify("straps: run :StrapsModel to pick the global " .. choice .. " model")
        end)
      end
    end
    M.redraw_status(true)
  end)
end

--- :StrapsAuto — grant permission categories to THIS session (auto mode). A
--- grant writes a "cap:<category>" key into vim.b straps_allowed, which the
--- default hook.confirm honors to auto-allow every call fn.capability puts in
--- that category (no prompt). Must run on a session buffer. arg nil/"" reports
--- the current cap: grants; "off" clears them (leaving other keys, e.g.
--- editdir:, intact); otherwise a space/comma list of categories to grant.
function M.auto(arg)
  local buf = vim.api.nvim_get_current_buf()
  if not vim.b.straps_session then
    return vim.notify("straps: not a straps session buffer", vim.log.levels.ERROR)
  end

  local function grants_list()
    local set = vim.b[buf].straps_allowed
    if type(set) ~= "table" then return nil end
    local cats = {}
    for k in pairs(set) do
      local c = type(k) == "string" and k:match("^cap:(.*)$") or nil
      if c then cats[#cats + 1] = c end
    end
    table.sort(cats)
    return #cats > 0 and table.concat(cats, ", ") or nil
  end

  arg = arg or ""
  if arg == "" then
    return vim.notify("straps: auto grants: " .. (grants_list() or "none"))
  end

  -- vim.b tables are snapshots: copy, mutate, assign back (see grant() in
  -- hook.confirm for the idiom).
  local set = {}
  if type(vim.b[buf].straps_allowed) == "table" then
    for k, v in pairs(vim.b[buf].straps_allowed) do set[k] = v end
  end

  if arg == "off" then
    local cleared = grants_list()
    for k in pairs(set) do
      if type(k) == "string" and k:match("^cap:") then set[k] = nil end
    end
    vim.b[buf].straps_allowed = set
    return vim.notify("straps: auto grants cleared: " .. (cleared or "none"))
  end

  local grantable = require("straps.registry").try_call("fn.capability") or {}
  local is_grantable = {}
  for _, c in ipairs(grantable) do is_grantable[c] = true end
  local tokens = {}
  for tok in arg:gmatch("[^%s,]+") do tokens[#tokens + 1] = tok end
  for _, tok in ipairs(tokens) do
    if not is_grantable[tok] then
      return notify_err("straps: unknown auto category " .. vim.inspect(tok)
        .. " (valid: " .. table.concat(grantable, ", ") .. ")")
    end
  end
  for _, tok in ipairs(tokens) do set["cap:" .. tok] = true end
  vim.b[buf].straps_allowed = set
  vim.notify("straps: auto grants: " .. (grants_list() or "none"))
end

-- Only the MACHINERY folds: each tool_use fold swallows its following
-- tool_result, so one call collapses to a single colored summary line, and
-- the system block (long and rarely re-read) folds the same way. The
-- conversation itself — user/assistant turns — never folds, so closing one
-- tool call never hides the exchange around it. The default foldlevel of 0
-- starts every tool call collapsed.
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

--- Jump to the count'th next (dir=1) or previous (dir=-1) conversation turn
--- marker — the `]]` / `[[` motions on a session buffer. Lands on the marker
--- line (rendered as the role rule), opening just enough folds to see it, and
--- pushes the jumplist so ctrl-o comes back. Returns true when it moved.
function M.goto_turn(dir, count)
  local bufnr = vim.api.nvim_get_current_buf()
  local cur = vim.api.nvim_win_get_cursor(0)[1]
  local marks = {}
  for _, b in ipairs(require("straps.state").list_blocks(bufnr)) do
    if TURN_KIND[b.kind] then
      marks[#marks + 1] = b.marker_lnum
    end
  end
  local target
  for _ = 1, math.max(1, count or 1) do
    local from = target or cur
    local found
    if dir > 0 then
      for _, m in ipairs(marks) do
        if m > from then
          found = m
          break
        end
      end
    else
      for i = #marks, 1, -1 do
        if marks[i] < from then
          found = marks[i]
          break
        end
      end
    end
    if not found then
      break
    end
    target = found
  end
  if not target then
    return false
  end
  vim.cmd("normal! m'") -- jumplist entry, so ctrl-o returns
  vim.api.nvim_win_set_cursor(0, { target, 0 })
  pcall(vim.cmd, "normal! zv")
  return true
end

--- Outline the transcript: load every conversation turn into this session's
--- findings list as `<role>  <headline>`, so a long session is navigable by
--- what was said (:lnext/:cnext, or <CR> in the list window to jump). Bound to
--- `gO` on a session buffer — the stock outline key in :help/man buffers.
--- Returns the number of turns listed.
function M.outline(bufnr)
  bufnr = (bufnr and bufnr ~= 0) and bufnr or vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(bufnr)
  local blocks = require("straps.state").list_blocks(bufnr)
  local items = {}
  for i, b in ipairs(blocks) do
    if TURN_KIND[b.kind] then
      local _, tools = turn_extent(blocks, i)
      local head = block_headline(bufnr, b, 90)
      local suffix = tools > 0 and ("  · %d tool%s"):format(tools, tools == 1 and "" or "s") or ""
      items[#items + 1] = {
        bufnr = (name == "") and bufnr or nil,
        filename = (name ~= "") and name or nil,
        lnum = b.marker_lnum,
        col = 1,
        text = ("%-6s %s%s"):format(ROLE[b.kind].label, head, suffix),
      }
    end
  end
  if #items == 0 then
    vim.notify("straps: no turns to outline")
    return 0
  end
  M.set_locations(bufnr, { title = "straps: outline", items = items }, true)
  return #items
end

-- Buffer-local navigation for a session transcript: turn motions and the
-- outline. `]]`/`[[` are section motions in vim's own idiom (and unused in a
-- straps buffer); `gO` is the outline key :help and man.vim already use.
function M.map_navigation(bufnr)
  local function motion(dir)
    return function()
      M.goto_turn(dir, vim.v.count1)
    end
  end
  vim.keymap.set("n", "]]", motion(1), { buffer = bufnr, desc = "straps: next turn" })
  vim.keymap.set("n", "[[", motion(-1), { buffer = bufnr, desc = "straps: previous turn" })
  vim.keymap.set("n", "gO", function()
    M.outline(bufnr)
  end, { buffer = bufnr, desc = "straps: outline the transcript" })
end

--- Apply the straps fold options (foldmethod=expr + foldexpr + foldtext +
--- foldlevel from config.tools_expanded) to every window currently showing
--- bufnr. The default foldlevel is 0: tool calls and the system prompt
--- collapsed (`tools_expanded` opens them); conversation turns never fold.
---
--- Folding is window-local, so this must run once the buffer is
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

local function clear_file_ref_match(win)
  local id = vim.w[win].straps_file_ref_match
  if id then
    pcall(vim.fn.matchdelete, id, win)
    vim.w[win].straps_file_ref_match = nil
  end
end

-- The match lifecycle autocmds are registered on first use, not in setup():
-- matches are created on paths that never ran setup() (:Straps and `:e
-- file.straps` both work without it), and users who never touch a session
-- shouldn't pay a WinEnter callback forever.
local file_ref_lifecycle = false

local function register_file_ref_lifecycle()
  if file_ref_lifecycle then
    return
  end
  file_ref_lifecycle = true
  local grp = vim.api.nvim_create_augroup("StrapsFileRefMatch", { clear = true })
  -- A match is window-scoped and, unlike window-local options, stays with the
  -- window across buffer switches: without cleanup a window that once showed
  -- a session would underline path:line-shaped text in every buffer it shows
  -- afterwards. Remove it when a non-straps buffer enters the window; apply
  -- it when a straps buffer does. Both events are needed: BufWinEnter for a
  -- buffer switch inside a window, WinEnter for a new or revisited window
  -- (:split of a visible buffer fires only the latter).
  vim.api.nvim_create_autocmd({ "BufWinEnter", "WinEnter" }, {
    group = grp,
    callback = function(ev)
      local win = vim.api.nvim_get_current_win()
      if vim.api.nvim_win_get_buf(win) ~= ev.buf then
        return
      end
      if vim.bo[ev.buf].filetype == "straps" then
        M.apply_file_ref_match(ev.buf)
      else
        clear_file_ref_match(win)
      end
    end,
  })
  -- An in-place filetype change (`:set ft=text`, a modeline) fires neither of
  -- the events above; drop the match from every window showing the buffer.
  vim.api.nvim_create_autocmd("FileType", {
    group = grp,
    callback = function(ev)
      if ev.match ~= "straps" then
        for _, win in ipairs(vim.fn.win_findbuf(ev.buf)) do
          clear_file_ref_match(win)
        end
      end
    end,
  })
end

--- Underline path:line[:col] references in every window showing bufnr, but
--- only when the treesitter highlighter owns the buffer — under legacy syntax
--- the strapsFileRef rule in syntax/straps.vim already does this. matchadd is
--- window-local with the same set-while-hidden trap as the fold options (see
--- apply_fold_opts), so the ftplugin, show_session and the FileType autocmd
--- all call this, guarded per-window by the returned match id.
function M.apply_file_ref_match(bufnr)
  if not vim.treesitter.highlighter.active[bufnr] then
    return
  end
  register_file_ref_lifecycle()
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    if vim.w[win].straps_file_ref_match == nil then
      -- Same vim regex as strapsFileRef in syntax/straps.vim (and the Lua
      -- pattern in file_ref_at_cursor is its gf-side equivalent) — a change
      -- to what counts as a file ref must land in all three. Scope is wider
      -- than the legacy rule (window-wide, so marker lines and tool_use JSON
      -- bodies get underlines too): accepted, since gf works buffer-wide
      -- under both engines.
      vim.w[win].straps_file_ref_match = vim.fn.matchadd(
        "StrapsFileRef", [=[[[:alnum:]_./~-]\+:\d\+\%(:\d\+\)\=]=], 10, -1, { window = win })
    end
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
  -- fn.agents_render IS the whole agents-buffer presentation (the running /
  -- loaded / saved sections, keymap footer and highlights), redefinable via
  -- :StrapsEdit fn.agents_render. The logic lives in ui._agents_render (like
  -- fn.render -> ui._render).
  require("straps.registry").define_default({
    name = "fn.agents_render",
    kind = "fn",
    doc = "Render the agents buffer (straps://agents): the running / loaded / "
      .. "saved session sections, keymap footer and highlights, from live "
      .. "state (ui.all_sessions). Redefine to reshape or restyle the listing.",
    source = [[return function(bufnr) return require("straps.ui")._agents_render(bufnr) end]],
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
      M.apply_file_ref_match(ev.buf)
      M.map_file_refs(ev.buf)
      M.map_navigation(ev.buf)
    end,
  })
end

return M
