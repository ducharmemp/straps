-- straps.state: the transcript buffer format. One session = one buffer; the
-- buffer is canonical state. Owns the block grammar, escaping, and the
-- parse to Anthropic-shaped messages. Buffer mutations assume the main loop
-- (callers schedule as needed).

local registry = require("straps.registry")

local M = {}

local MARKER_PREFIX = "%%[straps:"
local ESC_PREFIX = "%%[[esc]]"
local KINDS = {
  system = true,
  user = true,
  assistant = true,
  tool_use = true,
  tool_result = true,
}

-- A content line that would read as a marker (or as an escape) gets the
-- escape prefix prepended on append; parse strips exactly one prefix.
local function escape_line(line)
  if vim.startswith(line, MARKER_PREFIX) or vim.startswith(line, ESC_PREFIX) then
    return ESC_PREFIX .. line
  end
  return line
end

--- Escape one content line for the transcript, exactly as append does. Public
--- because writers that bypass append — anything editing block content in
--- place with nvim_buf_set_lines — must apply the same escaping, or a line
--- that reads as a marker splits the block it was written into.
function M.escape_line(line)
  return escape_line(line)
end

local function unescape_line(line)
  if vim.startswith(line, ESC_PREFIX) then
    return line:sub(#ESC_PREFIX + 1)
  end
  return line
end

-- Returns kind, attrs, inline for a marker line, or nil if the line isn't a
-- marker. Only tool markers carry JSON attrs; for user/assistant/system any
-- trailing text is treated as the block's first content line (people type
-- directly on the prompt marker line), never silently dropped.
local function match_marker(line)
  local kind, rest = line:match("^%%%%%[straps:([a-z_]+)%]%%%%(.*)$")
  if not kind or not KINDS[kind] then
    return nil
  end
  if kind == "tool_use" or kind == "tool_result" then
    local attrs = nil
    local json = rest:match("^ (.+)$")
    if json then
      local ok, decoded = pcall(vim.json.decode, json)
      if ok and type(decoded) == "table" then
        attrs = decoded
      end
    end
    return kind, attrs, nil
  end
  local inline = rest:gsub("^ ", "", 1)
  return kind, nil, inline ~= "" and inline or nil
end

-- Buffer lines -> { {kind, attrs, content}, ... }. Total: garbage before the
-- first marker is ignored; content is trimmed of leading/trailing blank lines.
local function parse_blocks(bufnr)
  local blocks = {}
  local cur = nil
  for _, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    local kind, attrs, inline = match_marker(line)
    if kind then
      cur = { kind = kind, attrs = attrs, lines = { inline } }
      blocks[#blocks + 1] = cur
    elseif cur then
      cur.lines[#cur.lines + 1] = unescape_line(line)
    end
  end
  for _, b in ipairs(blocks) do
    local lines = b.lines
    local first, last = 1, #lines
    while first <= last and lines[first]:match("^%s*$") do first = first + 1 end
    while last >= first and lines[last]:match("^%s*$") do last = last - 1 end
    b.content = table.concat(lines, "\n", first, last)
    b.lines = nil
  end
  return blocks
end

--- Parse the transcript into { system = string|nil, messages = message[] }
--- shaped for the Anthropic Messages API. Runs of assistant + tool_use blocks
--- and runs of tool_result blocks each collapse into one message; adjacent
--- same-role messages are merged (the API requires alternation).
function M.parse(bufnr)
  local blocks = parse_blocks(bufnr)
  local system = nil
  local start = 1
  if blocks[1] and blocks[1].kind == "system" then
    system = blocks[1].content
    start = 2
  end

  local messages = {}
  local function push(role, part)
    local last = messages[#messages]
    if last and last.role == role then
      last.content[#last.content + 1] = part
    else
      messages[#messages + 1] = { role = role, content = { part } }
    end
  end

  for i = start, #blocks do
    local b = blocks[i]
    if b.kind == "user" then
      if b.content ~= "" then -- empty user block (the prompt area) is dropped
        push("user", { type = "text", text = b.content })
      end
    elseif b.kind == "assistant" then
      if b.content ~= "" then -- empty assistant text is omitted
        push("assistant", { type = "text", text = b.content })
      end
    elseif b.kind == "tool_use" then
      local id = b.attrs and b.attrs.id
      local name = b.attrs and b.attrs.name
      -- A tool_use with no id/name (marker attrs failed to decode) is invalid
      -- to the API; skip it rather than ship a null-id block that 400s.
      if id and name then
        local ok, input = pcall(vim.json.decode, b.content ~= "" and b.content or "{}")
        if not ok then
          input = vim.empty_dict()
        end
        push("assistant", {
          type = "tool_use",
          id = id,
          name = name,
          input = input,
        })
      end
    elseif b.kind == "tool_result" then
      local id = b.attrs and b.attrs.id
      -- Likewise, a tool_result with no id cannot be paired to a tool_use.
      if id then
        push("user", {
          type = "tool_result",
          tool_use_id = id,
          content = b.content,
          is_error = (b.attrs and b.attrs.is_error) or false,
        })
      end
    end
  end

  return { system = system, messages = messages }
end

--- Public block index for compaction & friends (1-based):
--- { {kind, attrs, marker_lnum, first_lnum, last_lnum}, ... }.
--- The content range excludes the marker line itself; last_lnum is the last
--- line before the NEXT marker (or EOF), so the blank separator line the
--- writer puts before the next marker — and any other trailing blank lines —
--- ARE included in the range. Compact implementations replace the whole
--- range, so that's fine. Empty content => first_lnum > last_lnum.
--- Reuses the marker matcher; parse behavior is unchanged.
function M.list_blocks(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local blocks = {}
  for lnum, line in ipairs(lines) do
    local kind, attrs = match_marker(line)
    if kind then
      if blocks[#blocks] then
        blocks[#blocks].last_lnum = lnum - 1
      end
      blocks[#blocks + 1] = {
        kind = kind,
        attrs = attrs,
        marker_lnum = lnum,
        first_lnum = lnum + 1,
        last_lnum = #lines,
      }
    end
  end
  return blocks
end

-- Windows showing bufnr with the cursor on the last line stay pinned to the
-- new bottom after a mutation.
local function with_pin(bufnr, mutate)
  local last = vim.api.nvim_buf_line_count(bufnr)
  local pinned = {}
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    if vim.api.nvim_win_get_cursor(win)[1] == last then
      pinned[#pinned + 1] = win
    end
  end
  mutate()
  local new_last = vim.api.nvim_buf_line_count(bufnr)
  for _, win in ipairs(pinned) do
    vim.api.nvim_win_set_cursor(win, { new_last, 0 })
  end
end

local function buffer_is_blank(bufnr)
  return vim.api.nvim_buf_line_count(bufnr) == 1
    and vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] == ""
end

--- Directory holding file-backed session transcripts. config.session_dir when
--- set, else stdpath("data")/straps/sessions. Ensures it exists (mkdir -p).
--- pcall-safe: returns the dir, or nil if it can't be created.
function M.session_dir()
  local ok, dir = pcall(function()
    local d
    local sok, straps = pcall(require, "straps")
    if sok and type(straps) == "table" and rawget(straps, "config")
      and straps.config.session_dir then
      d = straps.config.session_dir
    else
      d = vim.fn.stdpath("data") .. "/straps/sessions"
    end
    vim.fn.mkdir(d, "p")
    if vim.fn.isdirectory(d) == 0 then
      error("session_dir is not a directory: " .. tostring(d))
    end
    -- Resolve symlinks (e.g. macOS TMPDIR: /var/folders/... -> /private/var/
    -- folders/...) so every path this module builds from the dir agrees with
    -- vim.fn.bufadd's buffer name, which nvim already resolves internally.
    -- Without this, new_session()'s path and list_sessions()'s glob(dir/*)
    -- can describe the same file with two different strings, and any
    -- string-equality comparison between them (ui.all_sessions' loaded/saved
    -- exclusion, tests) silently fails to match.
    return vim.uv.fs_realpath(d) or d
  end)
  if ok then
    return dir
  end
  return nil
end

--- Best-effort write of a file-backed session buffer to its file. No-op unless
--- the buffer is normal (buftype == ""), has a name, and is valid — so the
--- scratch buffers tests build directly are never touched. noautocmd keeps the
--- write from firing user autocmds / LSP / our own hooks. Never throws.
function M.persist(bufnr)
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    return
  end
  if vim.bo[bufnr].buftype ~= "" then
    return
  end
  if vim.api.nvim_buf_get_name(bufnr) == "" then
    return
  end
  -- Nothing to write if the buffer is already in sync with its file; skip the
  -- write so we do not churn the file's mtime (which reorders list_sessions)
  -- on no-op block boundaries.
  if not vim.bo[bufnr].modified then
    return
  end
  pcall(vim.api.nvim_buf_call, bufnr, function()
    vim.cmd("silent noautocmd write")
  end)
end

-- Path of the companion metadata file (durable session titles) for a
-- transcript: "<name>.straps" -> "<name>.straps.meta". JSON, best-effort.
local function meta_path(transcript_path)
  return transcript_path .. ".meta"
end

--- The user-set title for a session transcript, or nil. Read from the
--- companion "<path>.meta" JSON file ({ title = "..." }). pcall-safe.
function M.session_title(path)
  local ok, title = pcall(function()
    local mp = meta_path(path)
    if vim.fn.filereadable(mp) == 0 then
      return nil
    end
    local raw = table.concat(vim.fn.readfile(mp), "\n")
    local decoded = vim.json.decode(raw)
    if type(decoded) == "table" and type(decoded.title) == "string"
      and decoded.title ~= "" then
      return decoded.title
    end
    return nil
  end)
  return ok and title or nil
end

--- Set (or clear, with nil/"") the durable title for a session transcript,
--- written to its companion "<path>.meta" JSON file. Returns true on success.
function M.set_session_title(path, title)
  local ok = pcall(function()
    local mp = meta_path(path)
    if title == nil or title == "" then
      if vim.fn.filereadable(mp) == 1 then
        os.remove(mp)
      end
      return
    end
    vim.fn.writefile({ vim.json.encode({ title = title }) }, mp)
  end)
  return ok
end

--- A one-line summary of a transcript, read directly from disk (no buffer
--- load): the durable title when set, else the first non-empty user prompt,
--- else nil. The first user block is typically past a long system prompt, so
--- the whole file is read; the scan stops as soon as that block is captured.
--- Escaped/marker lines are unescaped; the summary is trimmed and collapsed
--- to a single line. pcall-safe; nil on any error.
function M.session_summary(path)
  local title = M.session_title(path)
  if title then
    return title
  end
  local ok, summary = pcall(function()
    if vim.fn.filereadable(path) == 0 then
      return nil
    end
    local lines = vim.fn.readfile(path)
    local in_user, collected = false, {}
    local function has_content()
      for _, c in ipairs(collected) do
        if c:match("%S") then return true end
      end
      return false
    end
    for _, line in ipairs(lines) do
      local kind = match_marker(line)
      if kind then
        if has_content() then
          break -- first non-empty user block ended
        end
        in_user = (kind == "user")
        collected = {} -- reset across empty user/other blocks
      elseif in_user then
        collected[#collected + 1] = unescape_line(line)
      end
    end
    local text = vim.trim(table.concat(collected, " "))
    text = text:gsub("%s+", " ")
    return text ~= "" and text or nil
  end)
  return ok and summary or nil
end

--- List *.straps transcripts in session_dir as
--- { {path, name, mtime, summary}, ... }, sorted most-recent first. `summary`
--- is the durable title or first user prompt (state.session_summary), nil when
--- the transcript has no prompt yet. pcall-safe; {} on any error or missing dir.
function M.list_sessions()
  local ok, result = pcall(function()
    local dir = M.session_dir()
    if not dir then
      return {}
    end
    local entries = {}
    for _, p in ipairs(vim.fn.glob(dir .. "/*.straps", false, true)) do
      local abs = vim.fn.fnamemodify(p, ":p")
      entries[#entries + 1] = {
        path = abs,
        name = vim.fn.fnamemodify(abs, ":t"),
        mtime = vim.fn.getftime(abs),
        summary = M.session_summary(abs),
      }
    end
    table.sort(entries, function(a, b)
      return a.mtime > b.mtime
    end)
    return entries
  end)
  if ok and type(result) == "table" then
    return result
  end
  return {}
end

--- Open an existing transcript file as a session buffer. Reuses the buffer if
--- one already names the path, else bufadd + bufload; applies the session
--- buffer options. Does not modify content. Returns the bufnr.
function M.open_session_file(path)
  local abspath = vim.fn.fnamemodify(path, ":p")
  local bufnr = vim.fn.bufnr(abspath)
  if bufnr == -1 then
    bufnr = vim.fn.bufadd(abspath)
    vim.fn.bufload(bufnr)
  end
  vim.bo[bufnr].buftype = ""
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "straps"
  vim.b[bufnr].straps_session = true
  return bufnr
end

--- Append a block: marker line (+ compact-JSON attrs), then escaped content.
function M.append(bufnr, kind, attrs, text)
  local marker = MARKER_PREFIX .. kind .. "]%%"
  if attrs then
    marker = marker .. " " .. vim.json.encode(attrs)
  end
  local lines = { marker }
  if text ~= nil and text ~= "" then
    for _, l in ipairs(vim.split(text, "\n", { plain = true })) do
      lines[#lines + 1] = escape_line(l)
    end
  end
  with_pin(bufnr, function()
    if buffer_is_blank(bufnr) then
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    else
      table.insert(lines, 1, "") -- one blank line before each marker
      vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, lines)
    end
  end)
  -- Block boundary: persist a file-backed buffer (no-op on scratch buffers).
  M.persist(bufnr)
end

--- Append raw text at the buffer tail (streaming deltas into the current
--- block); text may contain "\n".
function M.append_text(bufnr, text)
  with_pin(bufnr, function()
    local row = vim.api.nvim_buf_line_count(bufnr) - 1
    local tail = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
    local pieces = vim.split(text, "\n", { plain = true })
    local mk, _, minline = match_marker(tail)
    if mk and not minline then
      -- current block is empty: never glue text onto a bare marker line
      vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, pieces)
    else
      vim.api.nvim_buf_set_text(bufnr, row, #tail, row, #tail, pieces)
    end
  end)
end

--- Append an empty user marker unless the last block already is one.
function M.ensure_trailing_user(bufnr)
  local blocks = parse_blocks(bufnr)
  local last = blocks[#blocks]
  if last and last.kind == "user" and last.content == "" then
    M.persist(bufnr) -- block boundary reached with nothing to append
    return
  end
  M.append(bufnr, "user", nil, "") -- appends + persists
end

--- Repair a transcript that was interrupted mid-tool (Neovim killed, or the
--- process died, while a tool was in flight): persist() runs at block
--- boundaries, so the file can hold a tool_use whose tool_result was never
--- appended, and the API rejects an unpaired tool_use. Appends an error
--- tool_result for each such block so the transcript is sendable again, then
--- restores the trailing user block (the tail was a tool marker, so there was
--- nowhere to type). Returns the number of results appended.
---
--- Only a TRAILING orphan run is healed — one where nothing but tool blocks
--- follows the first unpaired tool_use, which is exactly the shape an interrupt
--- leaves. An orphan with later user/assistant conversation after it is a
--- hand-mangled transcript, not an interrupted one: appending a result at the
--- end would not pair it (the result must sit in the user message immediately
--- following its tool_use), so it is left alone to fail loudly at send.
--- A session with a live run is likewise left alone; see the guard below.
function M.heal_interrupted(bufnr)
  -- Never heal a session that is still RUNNING: a tool in flight looks exactly
  -- like an interrupted one (its tool_use is written, its result is not), and
  -- resuming can land on a live buffer — open_session_file reuses the loaded
  -- buffer for a path, and while a subagent runs the newest saved session is
  -- that running child, which is what bare :StrapsResume picks. Healing there
  -- would tell the model a tool failed while it is still working, and the real
  -- result lands afterwards, leaving two results for one tool_use_id.
  local ok_loop, loop = pcall(require, "straps.loop")
  if ok_loop and loop.running(bufnr) then
    return 0
  end
  local blocks = M.list_blocks(bufnr)
  local paired = {} -- tool_use id -> true once a tool_result answers it
  for _, b in ipairs(blocks) do
    local id = b.attrs and b.attrs.id
    if id and b.kind == "tool_result" then
      paired[id] = true
    end
  end
  -- First unpaired tool_use, and whether only tool blocks follow it.
  local first_orphan
  for i, b in ipairs(blocks) do
    local id = b.attrs and b.attrs.id
    if b.kind == "tool_use" and id and not paired[id] then
      first_orphan = i
      break
    end
  end
  if not first_orphan then
    return 0
  end
  for i = first_orphan, #blocks do
    local kind = blocks[i].kind
    if kind ~= "tool_use" and kind ~= "tool_result" then
      return 0 -- conversation resumed after the orphan: not an interrupt
    end
  end
  local n = 0
  for i = first_orphan, #blocks do
    local b = blocks[i]
    local id = b.attrs and b.attrs.id
    if b.kind == "tool_use" and id and not paired[id] then
      M.append(bufnr, "tool_result", { id = id, is_error = true },
        "run interrupted before this tool finished")
      paired[id] = true
      n = n + 1
    end
  end
  M.ensure_trailing_user(bufnr)
  return n
end

--- Content of the trailing user block, or nil if the last block isn't user.
function M.last_user_text(bufnr)
  local blocks = parse_blocks(bufnr)
  local last = blocks[#blocks]
  if last and last.kind == "user" then
    return last.content
  end
  return nil
end

local session_n = 0

-- Apply the durable session buffer options (buftype="" so :w / persist work).
local function apply_session_opts(bufnr)
  vim.bo[bufnr].buftype = ""
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "straps"
  vim.b[bufnr].straps_session = true
end

--- Create a durable, file-backed session buffer: buffer name = an absolute
--- <date>-<n>.straps path under session_dir(), buftype="" so :w works; then
--- system block + trailing empty user marker, persisted to disk. If the dir
--- can't be created/written, degrade to an ephemeral nofile buffer
--- (straps://session/n, notify once) so the harness still runs.
--- @param opts table? forwarded to fn.system_prompt (e.g. { subagent = true,
---   readonly = true, tools = {...} } from tool.spawn, so the composed
---   prompt can adapt to the child's shape).
function M.new_session(opts)
  session_n = session_n + 1
  local bufnr
  local dir = M.session_dir()
  if dir then
    local ok = pcall(function()
      local fname = os.date("%Y%m%d-%H%M%S") .. "-" .. session_n .. ".straps"
      local path = vim.fn.fnamemodify(dir .. "/" .. fname, ":p")
      local b = vim.fn.bufadd(path)
      vim.fn.bufload(b)
      apply_session_opts(b)
      bufnr = b
    end)
    if not ok then
      bufnr = nil
    end
  end
  if not bufnr then
    -- Ephemeral fallback: no persistence, but the harness still runs.
    bufnr = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(bufnr, "straps://session/" .. session_n)
    vim.bo[bufnr].buftype = "nofile"
    vim.bo[bufnr].bufhidden = "hide"
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].filetype = "straps"
    vim.b[bufnr].straps_session = true
    pcall(vim.notify,
      "straps: session dir unavailable — using an ephemeral (unsaved) transcript",
      vim.log.levels.WARN)
  end

  -- fn.system_prompt is registered by provider.register(); fall back so a
  -- bare registry (e.g. in tests) still yields a usable session.
  local prompt = registry.try_call("fn.system_prompt", opts)
    or "You are Cinch, a coding agent running inside Neovim via straps.nvim."
  M.append(bufnr, "system", nil, prompt) -- persists (block boundary)
  M.ensure_trailing_user(bufnr) -- persists
  return bufnr
end

return M
