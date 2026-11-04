-- straps.state: the transcript buffer format. One session = one buffer; the
-- buffer is canonical state. Owns the block grammar, escaping, and the
-- parse to Anthropic-shaped messages. Buffer mutations assume the main loop
-- (callers schedule as needed).

local registry = require("straps.registry")
local uv = vim.uv

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

function M.utf8_cut(s, n)
  if #s <= n then
    return s
  end
  return s:sub(1, n + vim.str_utf_start(s, n + 1))
end

local REPLACEMENT = "\239\191\189"

local function seq_len(s, j)
  local c = s:byte(j)
  local len, lo, hi = 0, 0x80, 0xBF
  if c >= 0xC2 and c <= 0xDF then
    len = 2
  elseif c >= 0xE0 and c <= 0xEF then
    len = 3
    if c == 0xE0 then lo = 0xA0 elseif c == 0xED then hi = 0x9F end
  elseif c >= 0xF0 and c <= 0xF4 then
    len = 4
    if c == 0xF0 then lo = 0x90 elseif c == 0xF4 then hi = 0x8F end
  else
    return nil
  end
  local b = s:byte(j + 1)
  if not b or b < lo or b > hi then
    return nil
  end
  for k = j + 2, j + len - 1 do
    b = s:byte(k)
    if not b or b < 0x80 or b > 0xBF then
      return nil
    end
  end
  return len
end

function M.utf8_scrub(s)
  if not s:find("[\128-\255]") then
    return s
  end
  local out, i, start = {}, 1, 1
  while true do
    local j = s:find("[\128-\255]", i)
    if not j then
      break
    end
    local len = seq_len(s, j)
    if len then
      i = j + len
    else
      out[#out + 1] = s:sub(start, j - 1)
      out[#out + 1] = REPLACEMENT
      i = j + 1
      start = i
    end
  end
  if start == 1 then
    return s
  end
  out[#out + 1] = s:sub(start)
  return table.concat(out)
end

local NOTICE_PREFIX = "[straps] "
local AGENT_FRAME = "[straps] from agent %s (buffer %d): %s"

--- Classify a user block's content: nil for the user's own words,
--- { from = "harness" } for a harness notice, or
--- { from = "agent", bufnr = N, label = "..." } for a peer message built by
--- M.agent_message. Matches the RAW first non-blank line, untrimmed: parse
--- keeps leading whitespace, so an indented lookalike is the user's text to
--- the model and must stay the user's text on screen.
function M.notice_of(content)
  if type(content) ~= "string" then
    return nil
  end
  local first
  for _, line in ipairs(vim.split(content, "\n", { plain = true })) do
    if not line:match("^%s*$") then
      first = line
      break
    end
  end
  if not first or first:sub(1, #NOTICE_PREFIX) ~= NOTICE_PREFIX then
    return nil
  end
  local label, bufnr = first:match("^%[straps%] from agent (.-) %(buffer (%d+)%): ")
  if label then
    return { from = "agent", bufnr = tonumber(bufnr), label = label }
  end
  return { from = "harness" }
end

--- The content of a peer message: `[straps] from agent <label> (buffer N):
--- <text>`. The label is stamped here, at send time, so the block attributes
--- itself without any lookup — a buffer number alone names a different
--- session after a restart. A continuation line that itself starts with the
--- notice prefix is indented one space: only the first line of a message may
--- speak for its sender, so a body cannot imitate the harness or another
--- agent further down.
function M.agent_message(label, bufnr, text)
  local lines = vim.split(text, "\n", { plain = true })
  for i = 2, #lines do
    if lines[i]:sub(1, #NOTICE_PREFIX) == NOTICE_PREFIX then
      lines[i] = " " .. lines[i]
    end
  end
  return AGENT_FRAME:format(tostring(label), bufnr, table.concat(lines, "\n"))
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
  -- tool_use ids of the CURRENT assistant message, not yet answered. The API
  -- requires a tool_result's tool_use_id to name a tool_use in the immediately
  -- preceding assistant message, so the set resets whenever a NEW assistant
  -- message begins (an EMPTY assistant marker pushes nothing and so never
  -- resets — the pre-provider marker between a batch's use and result must
  -- not orphan the pair). Consumed on pairing, so a duplicate result for the
  -- same id is caught too.
  local open_tool_uses = {}
  local function push(role, part)
    local last = messages[#messages]
    if last and last.role == role then
      last.content[#last.content + 1] = part
    else
      if role == "assistant" then
        open_tool_uses = {} -- reset BEFORE the caller records this part's id
      end
      messages[#messages + 1] = { role = role, content = { part } }
    end
  end
  -- An orphaned tool_result (its tool_use lost — e.g. a stray edit deleted the
  -- marker line) would 400 at the API, so it is downgraded to plain user text.
  -- Downgrades are DEFERRED until the tool_result run they sit in ends, so the
  -- text never lands ahead of a valid tool_result in the same user message.
  local pending_orphans = {}
  local function flush_orphans()
    for _, text in ipairs(pending_orphans) do
      push("user", { type = "text", text = text })
    end
    pending_orphans = {}
  end

  for i = start, #blocks do
    local b = blocks[i]
    if b.kind ~= "tool_result" then
      flush_orphans()
    end
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
        open_tool_uses[id] = true
      end
    elseif b.kind == "tool_result" then
      local id = b.attrs and b.attrs.id
      -- Likewise, a tool_result with no id cannot be paired to a tool_use.
      if id then
        if open_tool_uses[id] then
          open_tool_uses[id] = nil
          push("user", {
            type = "tool_result",
            tool_use_id = id,
            content = b.content,
            is_error = (b.attrs and b.attrs.is_error) or false,
          })
        else
          -- Orphan: no open tool_use with this id (marker lost, duplicate
          -- result, or a result stranded past a later assistant message).
          pending_orphans[#pending_orphans + 1] =
            ("[straps: orphaned tool result (id %s) — its tool_use block is"
              .. " missing from the transcript]\n\n%s"):format(id, b.content)
        end
      end
    end
  end
  flush_orphans()

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
---
--- Cached per buffer on changedtick: foldtext asks for the index once per
--- closed fold on every redraw, and each call scanned the whole transcript.
--- The outer array is fresh on every call (sort or truncate it freely); the
--- block tables inside are shared until the buffer next changes, so callers
--- must treat them as read-only. Every mutation path (nvim_buf_set_lines,
--- set_text, undo, reload) bumps the tick and invalidates the entry.
local blocks_cache = {}

function M.list_blocks(bufnr)
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local hit = blocks_cache[bufnr]
  if not (hit and hit.tick == tick) then
    for b in pairs(blocks_cache) do
      if not vim.api.nvim_buf_is_valid(b) then
        blocks_cache[b] = nil
      end
    end
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
    hit = { tick = tick, blocks = blocks }
    blocks_cache[bufnr] = hit
  end
  local out = {}
  for i, b in ipairs(hit.blocks) do
    out[i] = b
  end
  return out
end

function M._blocks_cache_size()
  local n = 0
  for _ in pairs(blocks_cache) do
    n = n + 1
  end
  return n
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

-- Path of the companion metadata file (durable session title, pinned
-- provider and per-session model) for a transcript: "<name>.straps" ->
-- "<name>.straps.meta". JSON, best-effort.
local function meta_path(transcript_path)
  return transcript_path .. ".meta"
end

-- The decoded companion metadata table for a transcript. {} when the file is
-- absent, not readable or blank; {} plus a reason when its text is not a JSON
-- object, so the next write replaces it with the fields straps knows now.
local function read_meta(mp)
  if vim.fn.filereadable(mp) == 0 then return {} end
  local text = table.concat(vim.fn.readfile(mp), "\n")
  if vim.trim(text) == "" then return {} end
  local ok, decoded = pcall(vim.json.decode, text)
  if ok and type(decoded) == "table" and text:match("^%s*{") then return decoded end
  return {}, mp .. " is not a JSON object"
end

-- Set metadata fields, keeping the others; a false value clears its
-- field. The file is written to "<mp>.tmp" and renamed over mp, so a crash
-- mid-write leaves the old file; when no field remains, the file is removed.
local function write_meta_fields(mp, fields)
  local meta = read_meta(mp)
  for key, value in pairs(fields) do
    if value == false then meta[key] = nil else meta[key] = value end
  end
  if next(meta) == nil then
    if vim.fn.filereadable(mp) == 1 then assert(os.remove(mp)) end
    return
  end
  local tmp = mp .. ".tmp"
  if vim.fn.writefile({ vim.json.encode(meta) }, tmp) ~= 0 then error("cannot write " .. tmp) end
  local ok, err = vim.uv.fs_rename(tmp, mp)
  if not ok then
    os.remove(tmp)
    error(err)
  end
end
M._write_meta_fields = write_meta_fields -- exposed for tests

local function _canon_path(path)
  if not path or path == "" then return path end
  local abs = vim.fn.fnamemodify(path, ":p")
  return abs
end
local summary_cache = {}
local _cache_hits, _cache_misses, _cache_stores, _cache_prunes = 0, 0, 0, 0

local function _stat_fields(p)
  local st = p and uv.fs_stat(p) or nil
  if not st then
    return 0, 0, 0, 0, 0
  end
  local ms, mns = 0, 0
  if type(st.mtime) == "table" then
    ms = st.mtime.sec or 0
    mns = st.mtime.nsec or 0
  end
  local cs, cns = 0, 0
  if type(st.ctime) == "table" then
    cs = st.ctime.sec or 0
    cns = st.ctime.nsec or 0
  end
  return st.size or 0, ms, mns, cs, cns
end

local function _cache_key_stats(path)
  local t_size, t_ms, t_mns, t_cs, t_cns = _stat_fields(path)
  local mp = meta_path(path)
  local m_size, m_ms, m_mns, m_cs, m_cns = _stat_fields(mp)
  return t_size, t_ms, t_mns, t_cs, t_cns, m_size, m_ms, m_mns, m_cs, m_cns
end

function M.clear_session_summary_cache()
  summary_cache = {}
  _cache_hits, _cache_misses, _cache_stores, _cache_prunes = 0, 0, 0, 0
end

function M._session_summary_cache_stats()
  local n = 0
  for _ in pairs(summary_cache) do n = n + 1 end
  return { hits = _cache_hits, misses = _cache_misses, stores = _cache_stores, prunes = _cache_prunes, size = n }
end

local function _stream_first_prompt(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local in_user = false
  local first = nil
  local have_inline = false
  local body = {}
  local function has_content()
    return first ~= nil and first:match("%S") ~= nil
  end
  local function is_prompt()
    if not has_content() then return false end
    return not M.notice_of(first)
  end
  local ok, res = pcall(function()
    for line in f:lines() do
      local kind, _, inline = match_marker(line)
      if kind then
        if is_prompt() then
          break
        end
        in_user = (kind == "user")
        have_inline = false
        first = nil
        body = {}
        if in_user and inline and inline ~= "" then
          first = inline
          have_inline = true
          body[#body + 1] = inline
        end
      elseif in_user then
        local s = unescape_line(line)
        if not have_inline or s:match("%S") then
          if not first and s:match("%S") then
            first = s
          end
          body[#body + 1] = s
        end
      end
    end
    if not is_prompt() then
      return nil
    end
    local text = table.concat(body, "\n")
    text = vim.trim(text)
    text = text:gsub("%s+", " ")
    return text ~= "" and text or nil
  end)
  pcall(function() f:close() end)
  if ok then return res end
  return nil
end

--- The user-set title for a session transcript, or nil. Read from the
--- companion "<path>.meta" JSON file ({ title = "..." }). pcall-safe.
function M.session_title(path)
  local ap = _canon_path(path)
  local ok, title = pcall(function()
    local decoded = read_meta(meta_path(ap))
    if type(decoded.title) == "string" and decoded.title ~= "" then
      return decoded.title
    end
    return nil
  end)
  return ok and title or nil
end

--- Set (or clear, with nil/"") the durable title for a session transcript,
--- written to its companion "<path>.meta" JSON file. Returns true on success,
--- or false plus the error.
function M.set_session_title(path, title)
  local ap = _canon_path(path)
  local ok, err = pcall(function()
    write_meta_fields(meta_path(ap), { title = (title ~= nil and title ~= "") and title or false })
    summary_cache[ap] = nil
  end)
  if ok then return true end
  return false, tostring(err)
end

--- The pin saved for a session transcript, read from the companion
--- "<path>.meta" JSON file ({ provider, model, model_entry }). Returns the
--- provider, the model, a reason when the file is not a JSON object, and the
--- model's saved list entry; each is nil when absent. pcall-safe.
function M.session_pin(path)
  local ap = _canon_path(path)
  local ok, meta, why = pcall(read_meta, meta_path(ap))
  if not ok then return nil, nil, tostring(meta) end
  local function str(v) return (type(v) == "string" and v ~= "") and v or nil end
  local entry = type(meta.model_entry) == "table" and meta.model_entry or nil
  return str(meta.provider), str(meta.model), why, entry
end

--- Pin the session buffer's backend: provider, model (nil when none is
--- resolved yet) and the model's list entry (nil when unlisted). Sets vim.b
--- straps_provider and the provider slot's buf_model_var, and for a
--- file-backed buffer writes { provider, model, model_entry } to the
--- transcript's .meta file, which open_session_file restores. When the model
--- is unchanged and no entry is given, the saved entry is kept. A failed write
--- warns once until a write succeeds, because a resume would then use the
--- global provider. Returns true when the pin is set, false plus the error
--- when the .meta write failed, nil for a non-session buffer, and nil plus an
--- error for an unknown provider name (nothing is pinned).
function M.set_session_pin(bufnr, provider, model, entry)
  if type(provider) ~= "string" or provider == ""
    or not vim.api.nvim_buf_is_valid(bufnr) or vim.b[bufnr].straps_session ~= true then
    return nil
  end
  local providers = require("straps.provider")
  if not providers.is_provider(provider) then return nil, providers.unknown_provider_error(provider) end
  if type(model) ~= "string" or model == "" then model = nil end
  if type(entry) ~= "table" or entry.id ~= model then entry = nil end
  local saved = vim.b[bufnr].straps_pin_saved
  if entry == nil and type(saved) == "table" and saved.provider == provider and saved.model == model
    and type(saved.entry) == "string" then
    local ok_decode, kept = pcall(vim.json.decode, saved.entry)
    if ok_decode and type(kept) == "table" and kept.id == model then entry = kept end
  end
  vim.b[bufnr].straps_provider = provider
  if model then
    vim.b[bufnr][providers.provider_slot(provider).buf_model_var] = model
  end
  if vim.bo[bufnr].buftype ~= "" then return true end
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then return true end
  local mp = meta_path(_canon_path(name))
  local entry_json
  if entry then
    local ok_encode, encoded = pcall(vim.json.encode, entry)
    if ok_encode then entry_json = encoded else entry = nil end
  end
  if type(saved) == "table" and saved.provider == provider and saved.model == model and saved.entry == entry_json
    and saved.path == name and vim.fn.filereadable(mp) == 1 then
    return true
  end
  local ok, err = pcall(write_meta_fields, mp, { provider = provider, model = model or false, model_entry = entry or false })
  if ok then
    vim.b[bufnr].straps_pin_saved = { provider = provider, model = model, entry = entry_json, path = name }
    vim.b[bufnr].straps_pin_warned = nil
    return true
  end
  if not vim.b[bufnr].straps_pin_warned then
    vim.b[bufnr].straps_pin_warned = true
    vim.notify(("straps: could not save this session's provider to %s (%s); a resume will use the global provider")
      :format(mp, tostring(err)), vim.log.levels.WARN)
  end
  return false, tostring(err)
end
function M.codex_session_id(bufnr)
  local valid = bufnr and vim.api.nvim_buf_is_valid(bufnr)
  local id = valid and vim.b[bufnr].straps_codex_session_id or nil
  local mp
  if valid and vim.b[bufnr].straps_session == true and vim.bo[bufnr].buftype == "" then
    local name = vim.api.nvim_buf_get_name(bufnr)
    if name ~= "" then mp = meta_path(_canon_path(name)) end
  end
  if (type(id) ~= "string" or id == "") and mp then
    local stored = read_meta(mp).codex_session_id
    if type(stored) == "string" and stored ~= "" then id = stored end
  end
  if type(id) ~= "string" or id == "" then
    id = require("straps.oauth").uuid4()
    if mp then pcall(write_meta_fields, mp, { codex_session_id = id }) end
  end
  id = id:sub(1, 64)
  if valid then vim.b[bufnr].straps_codex_session_id = id end
  return id
end
--- A one-line summary of a transcript, read directly from disk (no buffer
--- load): the durable title when set, else the first non-empty user prompt,
--- else nil. Escaped/marker lines are unescaped; the summary is trimmed and
--- collapsed to a single line. pcall-safe; nil on any error.
function M.session_summary(path)
  local ap = _canon_path(path)
  local ok, summary = pcall(function()
    if vim.fn.filereadable(ap) == 0 then
      return nil
    end
    local t_size, t_ms, t_mns, t_cs, t_cns, m_size, m_ms, m_mns, m_cs, m_cns = _cache_key_stats(ap)
    local hit = summary_cache[ap]
    if hit and hit.t_size == t_size and hit.t_mtime_s == t_ms and hit.t_mtime_ns == t_mns
      and hit.t_ctime_s == t_cs and hit.t_ctime_ns == t_cns
      and hit.m_size == m_size and hit.m_mtime_s == m_ms and hit.m_mtime_ns == m_mns
      and hit.m_ctime_s == m_cs and hit.m_ctime_ns == m_cns then
      _cache_hits = _cache_hits + 1
      return hit.sum
    end
    _cache_misses = _cache_misses + 1
    local title = M.session_title(ap)
    local sum
    if title then
      sum = title
    else
      sum = _stream_first_prompt(ap)
    end
    summary_cache[ap] = {
      sum = sum,
      t_size = t_size, t_mtime_s = t_ms, t_mtime_ns = t_mns, t_ctime_s = t_cs, t_ctime_ns = t_cns,
      m_size = m_size, m_mtime_s = m_ms, m_mtime_ns = m_mns, m_ctime_s = m_cs, m_ctime_ns = m_cns,
    }
    _cache_stores = _cache_stores + 1
    return sum
  end)
  return ok and summary or nil
end

--- List *.straps transcripts in session_dir as
--- { {path, name, mtime, summary}, ... }, sorted most-recent first. `summary`
--- is the durable title or first user prompt (state.session_summary), nil when
--- the transcript has no prompt yet. pcall-safe; {} on any error or missing dir.
function M.list_sessions(opts)
  local ok, result = pcall(function()
    local dir = M.session_dir()
    if not dir then
      return {}
    end
    for p, _ in pairs(summary_cache) do
      if vim.startswith(p, dir .. "/") and not uv.fs_stat(p) then
        summary_cache[p] = nil
        _cache_prunes = _cache_prunes + 1
      end
    end
    local exclude = (type(opts) == "table" and type(opts.exclude) == "table") and opts.exclude or nil
    local entries = {}
    for _, p in ipairs(vim.fn.glob(dir .. "/*.straps", false, true)) do
      local abs = vim.fn.fnamemodify(p, ":p")
      if not (exclude and exclude[abs]) then
        entries[#entries + 1] = {
          path = abs,
          name = vim.fn.fnamemodify(abs, ":t"),
          mtime = vim.fn.getftime(abs),
          summary = M.session_summary(abs),
        }
      end
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
--- buffer options (buftype="", swapfile=false, filetype="straps",
--- fsync=false on 0.12+) and restores the pin from the transcript's .meta file
--- (session_pin): vim.b straps_provider when it is unset, the provider's model
--- variable when that is unset too, and the saved model entry into the
--- provider's model list. A .meta file that is not a JSON object restores
--- nothing and warns; the next successful request replaces it. A transcript
--- with assistant turns and no saved provider warns once that it will use the
--- global provider (a transcript copied without its .meta, or one older than
--- the pin). Does not modify content. Returns the bufnr.
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
  if vim.fn.has("nvim-0.12") == 1 then
    vim.bo[bufnr].fsync = false
  end
  local pinned, model, why, entry = M.session_pin(abspath)
  local current = vim.b[bufnr].straps_provider
  local has_provider = current ~= nil and current ~= ""
  if why then
    vim.b[bufnr].straps_pin_saved = nil
    vim.notify("straps: " .. why .. "; " .. (has_provider
      and ("this session keeps provider " .. current .. ", and its next successful request rewrites the file")
      or "this session uses the global provider, and its next successful request rewrites the file"),
      vim.log.levels.WARN)
  elseif pinned and not has_provider then
    vim.b[bufnr].straps_provider = pinned
    local providers = require("straps.provider")
    if model and providers.is_provider(pinned) then
      local var = providers.provider_slot(pinned).buf_model_var
      local have = vim.b[bufnr][var]
      if have == nil or have == "" then vim.b[bufnr][var] = model end
      local ok_straps, straps = pcall(require, "straps")
      if ok_straps and type(straps) == "table" then
        providers.merge_model_entry(pinned, entry, rawget(straps, "config"))
      end
    end
    vim.b[bufnr].straps_pin_saved = {
      provider = pinned, model = model, entry = entry and vim.json.encode(entry) or nil,
      path = vim.api.nvim_buf_get_name(bufnr),
    }
  elseif not pinned and not has_provider then
    local ok_loop, loop = pcall(require, "straps.loop")
    local running = ok_loop and type(loop.running) == "function" and loop.running(bufnr)
    local found = 0
    if not running then
      vim.api.nvim_buf_call(bufnr, function()
        found = vim.fn.search("\\V\\^" .. MARKER_PREFIX .. "assistant]%%", "nw")
      end)
    end
    if found > 0 then
      vim.notify("straps: " .. vim.fn.fnamemodify(abspath, ":t")
        .. " has no saved provider; it will use the global provider (pick one with :StrapsProvider)",
        vim.log.levels.WARN)
    end
  end
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

--- Fill the trailing EMPTY user block with text (the launch path: an
--- instruction from the command line, stdin piped into the session). Lines go
--- through escape_line like append's, so piped text that reads as a marker
--- cannot forge a block. Errors unless the last block is an empty user block.
function M.seed_user(bufnr, text)
  local blocks = parse_blocks(bufnr)
  local last = blocks[#blocks]
  if not (last and last.kind == "user" and last.content == "") then
    error("straps.state.seed_user: the transcript does not end on an empty user block", 0)
  end
  local lines = {}
  for _, l in ipairs(vim.split(text, "\n", { plain = true })) do
    lines[#lines + 1] = escape_line(l)
  end
  with_pin(bufnr, function()
    vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, lines)
  end)
  M.persist(bufnr)
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
-- On nvim >= 0.12, also sets fsync=false: the buffer is the state and the
-- file is a mirror rewritten at every block boundary, so persist()'s :write
-- need not fsync each time.
local function apply_session_opts(bufnr)
  vim.bo[bufnr].buftype = ""
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "straps"
  vim.b[bufnr].straps_session = true
  if vim.fn.has("nvim-0.12") == 1 then
    vim.bo[bufnr].fsync = false
  end
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
