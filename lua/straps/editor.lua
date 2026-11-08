-- straps/editor.lua — editor-native tools (diagnostics, definition, references,
-- symbols, read_symbol). Tree-sitter tools are synchronous and need no server;
-- LSP tools run async through ctx.await with a bounded timeout so a wedged
-- server can never hang the run. A genuine failure (no such file, refusal, no
-- LSP client, invalid input) raises error("<tool>: ...", 0) so the loop marks
-- the result is_error; an empty-but-valid result ("no diagnostics", "no
-- references found") is a returned string. register() uses
-- registry.define_default (no clobbering).

local M = {}

-- Shared Lua helpers prepended to every tool source. Each tool source is a
-- separate compiled chunk, so the helpers live in this prelude string and are
-- concatenated in; keeps buffer loading / position math / LSP plumbing DRY.
-- Includes tags_fallback (the no-LSP-client tag lookup shared by definition and
-- references) and is_session (used by window/buffer-scanning tools).
local PRELUDE = [==[
local uv = vim.uv or vim.loop

-- Load `path` into a buffer and resolve its filetype (so a linter/LSP can
-- attach and tree-sitter can pick a language). Returns bufnr, filetype.
local function load_buf(path, tool)
  tool = tool or "load_buf"
  if type(path) ~= "string" or path == "" then error(tool .. ": path is required", 0) end
  if vim.fn.filereadable(vim.fn.fnamemodify(path, ":p")) ~= 1 then
    error(tool .. ": no such file: " .. path, 0)
  end
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  local ft = vim.bo[buf].filetype
  if ft == nil or ft == "" then
    local m = vim.filetype.match({ buf = buf })
      or (name ~= "" and vim.filetype.match({ filename = name }))
    if m and m ~= "" then
      ft = m
      pcall(function() vim.bo[buf].filetype = ft end)
    end
  end
  -- Best-effort filetype-detect autocmd too (some setups attach linters on it).
  pcall(function()
    vim.api.nvim_buf_call(buf, function() vim.cmd("silent! filetype detect") end)
  end)
  return buf, vim.bo[buf].filetype or ft or ""
end

-- Path shown to the model: home-relative / cwd-relative, or a buffer tag.
local function relname(name, buf)
  if name and name ~= "" then return vim.fn.fnamemodify(name, ":~:.") end
  return "buffer " .. tostring(buf)
end

-- The identifier under a 0-based (line, col) position in a loaded buffer.
local function symbol_at(buf, line0, col0)
  local l = (vim.api.nvim_buf_get_lines(buf, line0, line0 + 1, false) or {})[1] or ""
  local c = col0 + 1 -- 1-based byte index into the line
  if c < 1 then c = 1 end
  local s = c
  while s > 1 and l:sub(s - 1, s - 1):match("[%w_]") do s = s - 1 end
  local e = c
  while e <= #l and l:sub(e, e):match("[%w_]") do e = e + 1 end
  return l:sub(s, e - 1)
end

-- Convert an LSP (line, character) position to a 1-based byte column. LSP
-- `character` is a UTF-16 code-unit offset by default; read_file and the
-- quickfix list use byte columns, so a line with multibyte characters before
-- the symbol would otherwise report the wrong column. Reads the target line
-- from its buffer (loading it if needed) and maps the offset with
-- vim.str_byteindex; falls back to character+1 if anything is unavailable.
local function lsp_char_to_byte_col(uri, line0, char0, encoding)
  local ok, col = pcall(function()
    local fname = vim.uri_to_fname(uri)
    local buf = vim.fn.bufadd(fname)
    if not vim.api.nvim_buf_is_loaded(buf) then vim.fn.bufload(buf) end
    local text = vim.api.nvim_buf_get_lines(buf, line0, line0 + 1, false)[1]
    if not text then return char0 + 1 end
    -- str_byteindex(text, encoding, index, strict?) on 0.11+; older signature
    -- is (text, index, use_utf16). Guard both.
    local enc = encoding == "utf-8" and "utf-8" or (encoding == "utf-32" and "utf-32" or "utf-16")
    local byte
    local ok2, b = pcall(vim.str_byteindex, text, enc, char0, false)
    if ok2 and type(b) == "number" then
      byte = b
    else
      byte = select(1, vim.str_byteindex(text, char0, enc ~= "utf-8"))
    end
    return byte + 1
  end)
  return (ok and type(col) == "number") and col or (char0 + 1)
end

-- Format a single LSP Location / LocationLink into "file:line:col".
local function add_loc(loc, out, encoding)
  if type(loc) ~= "table" then return end
  local uri = loc.uri or loc.targetUri
  local range = loc.range or loc.targetSelectionRange or loc.targetRange
  if uri and range and range.start then
    local file = vim.fn.fnamemodify(vim.uri_to_fname(uri), ":~:.")
    local col = lsp_char_to_byte_col(uri, range.start.line, range.start.character, encoding)
    out[#out + 1] = string.format("%s:%d:%d", file, range.start.line + 1, col)
  end
end

-- Collect locations from one client result (single Location, LocationLink, or
-- an array of them) into `out`.
local function collect_locations(result, out, encoding)
  if type(result) ~= "table" then return end
  if result.uri or result.targetUri or result.range or result.targetUri then
    add_loc(result, out, encoding)
  else
    for _, loc in ipairs(result) do add_loc(loc, out, encoding) end
  end
end

-- Dedup + sort a list of "file:line:col" strings and join with newlines.
local function sorted_unique(list)
  local seen, out = {}, {}
  for _, s in ipairs(list) do
    if not seen[s] then seen[s] = true; out[#out + 1] = s end
  end
  table.sort(out)
  return out
end

local function join_sorted(list)
  return table.concat(sorted_unique(list), "\n")
end

local function loc_string_to_item(s)
  local file, line, col = s:match("^(.-):(%d+):(%d+)$")
  if not file then return nil end
  return { filename = file, lnum = tonumber(line), col = tonumber(col), text = s }
end

local function maybe_set_locations(ctx, input, title, locs)
  if not (input and input.quickfix) then return nil end
  local items = {}
  for _, s in ipairs(sorted_unique(locs)) do
    local item = loc_string_to_item(s)
    if item then items[#items + 1] = item end
  end
  local ok, kind = pcall(function()
    return require("straps.findings").set_locations(ctx and ctx.bufnr,
      { title = title, items = items }, input.open ~= false)
  end)
  return ok and kind or "quickfix"
end

local function location_output(ctx, input, title, locs, empty)
  if #locs == 0 then
    maybe_set_locations(ctx, input, title, {})
    return empty
  end
  local kind = maybe_set_locations(ctx, input, title, locs)
  local out = join_sorted(locs)
  if kind then
    out = out .. "\n" .. kind .. ": " .. tostring(#sorted_unique(locs)) .. " location(s)"
  end
  return out
end

-- Wait (up to ~1s) for an LSP client to attach to `buf`; returns the client
-- list (possibly empty). Goes through ctx.await so the coroutine driver is
-- never blocked.
local function wait_clients(ctx, buf)
  return ctx.await(function(resolve)
    local start = uv.now()
    local function poll()
      local ok, cs = pcall(vim.lsp.get_clients, { bufnr = buf })
      if ok and cs and #cs > 0 then resolve(cs); return end
      if uv.now() - start >= 1000 then resolve({}); return end
      vim.defer_fn(poll, 50)
    end
    poll()
  end)
end

-- The offset_encoding of the first LSP client attached to `buf` ("utf-16" if
-- none), used to convert LSP character offsets to byte columns.
local function buf_offset_encoding(buf)
  local ok, cs = pcall(vim.lsp.get_clients, { bufnr = buf })
  if ok and cs and cs[1] and cs[1].offset_encoding then
    return cs[1].offset_encoding
  end
  return "utf-16"
end

-- Wait for an LSP client on `buf`, then run one request through ctx.await
-- with a bounded timeout. Returns:
--   results_map            -- on success (client_id -> { err, result })
--   nil, "noclient"        -- no client attached within the wait window
--   nil, "timeout"         -- client present but request exceeded timeout_ms
local function lsp_request(ctx, buf, method, params, timeout_ms)
  local clients = wait_clients(ctx, buf)
  if not clients or #clients == 0 then
    return nil, "noclient"
  end
  local res, err = ctx.await(function(resolve)
    local done = false
    vim.defer_fn(function()
      if not done then done = true; resolve(nil, "timeout") end
    end, timeout_ms)
    local ok = pcall(function()
      vim.lsp.buf_request_all(buf, method, params, function(results)
        if not done then done = true; resolve(results) end
      end)
    end)
    if not ok and not done then done = true; resolve(nil, "timeout") end
  end)
  if err == "timeout" then return nil, "timeout" end
  return res
end

-- Iterate the per-client results of buf_request_all, tolerating both the
-- { [id] = { err, result } } and the older { [id] = <result> } shapes.
local function each_result(res, fn)
  for _, r in pairs(res or {}) do
    if type(r) == "table" and r.result ~= nil then
      fn(r.result)
    elseif type(r) == "table" and r.err ~= nil then
      -- error entry; skip
    else
      fn(r)
    end
  end
end

-- Unwrap one entry of a buf_request_all results map, tolerating both the
-- { err, result } and the older bare-result shapes. Returns result or nil.
local function result_of(r)
  if type(r) == "table" and r.result ~= nil then return r.result end
  if type(r) == "table" and r.err ~= nil then return nil end
  return r
end

-- One request against a SPECIFIC client (resolve/executeCommand must not fan
-- out). Compat: nvim 0.11 method-call style with a plain-call fallback.
local function client_request(ctx, client, method, params, buf, timeout_ms)
  return ctx.await(function(resolve)
    local done = false
    vim.defer_fn(function()
      if not done then done = true; resolve(nil, "timeout") end
    end, timeout_ms or 5000)
    local function cb(err, result)
      if not done then done = true; resolve(result, err and tostring(err.message or err) or nil) end
    end
    local ok = pcall(function() return client:request(method, params, cb, buf) end)
    if not ok then
      ok = pcall(function() return client.request(method, params, cb, buf) end)
    end
    if not ok and not done then
      done = true
      resolve(nil, "request failed")
    end
  end)
end

local function workspace_root()
  return (vim.uv.fs_realpath(vim.fn.getcwd()) or vim.fn.fnamemodify(vim.fn.getcwd(), ":p")):gsub("/+$", "")
end

local function uri_path(uri)
  if type(uri) ~= "string" or not uri:match("^file://") then
    return nil, "non-file URI in WorkspaceEdit: " .. tostring(uri)
  end
  local ok, fname = pcall(vim.uri_to_fname, uri)
  if not ok or type(fname) ~= "string" or fname == "" then
    return nil, "invalid file URI in WorkspaceEdit: " .. tostring(uri)
  end
  local full = vim.fn.fnamemodify(fname, ":p")
  local real = vim.uv.fs_realpath(full)
  if not real then
    local parent = vim.uv.fs_realpath(vim.fn.fnamemodify(full, ":h"))
    if parent then real = parent .. "/" .. vim.fn.fnamemodify(full, ":t") end
  end
  return real or full
end

local function workspace_edit_uris(edit)
  local uris = {}
  if type(edit.changes) == "table" then
    for uri in pairs(edit.changes) do uris[#uris + 1] = uri end
  end
  if type(edit.documentChanges) == "table" then
    for _, dc in ipairs(edit.documentChanges) do
      if type(dc) == "table" and dc.textDocument and dc.textDocument.uri then
        uris[#uris + 1] = dc.textDocument.uri
      elseif type(dc) == "table" and dc.kind == "rename" then
        uris[#uris + 1] = dc.oldUri; uris[#uris + 1] = dc.newUri
      elseif type(dc) == "table" and (dc.kind == "create" or dc.kind == "delete") then
        uris[#uris + 1] = dc.uri
      end
    end
  end
  return uris
end

local function guard_workspace_edit(edit)
  for _, dc in ipairs(edit.documentChanges or {}) do
    if dc.kind then return nil, "WorkspaceEdit resource operations are not supported: " .. tostring(dc.kind) end
  end
  local root = workspace_root()
  for _, uri in ipairs(workspace_edit_uris(edit)) do
    local path, err = uri_path(uri)
    if not path then return nil, err end
    if path ~= root and path:sub(1, #root + 1) ~= root .. "/" then
      return nil, "WorkspaceEdit touches outside cwd: " .. relname(path)
    end
  end
  return true
end

local function find_buf(full)
  local real = vim.uv.fs_realpath(full) or full
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(b)
    if name ~= "" and (name == full or name == real or vim.uv.fs_realpath(name) == real) then
      return b
    end
  end
  return nil
end

local function wipe_buf_keep_windows(buf)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  for _, w in ipairs(vim.fn.win_findbuf(buf)) do
    local alt = vim.api.nvim_win_call(w, function() return vim.fn.bufnr("#") end)
    if alt > 0 and alt ~= buf and vim.api.nvim_buf_is_valid(alt) and vim.bo[alt].buflisted then
      pcall(vim.api.nvim_win_set_buf, w, alt)
    else
      pcall(vim.api.nvim_win_set_buf, w, vim.api.nvim_create_buf(true, false))
    end
  end
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
end

local function byte_to_lsp_char(buf, line0, col0, enc)
  local text = vim.api.nvim_buf_get_lines(buf, line0, line0 + 1, false)[1] or ""
  local idx = math.min(col0, #text)
  local ok, c = pcall(vim.str_utfindex, text, enc or "utf-16", idx, false)
  if ok and type(c) == "number" then return c end
  return col0
end

local function position_params(buf, line0, col0, extra)
  return function(client)
    local p = {
      textDocument = { uri = vim.uri_from_bufnr(buf) },
      position = { line = line0, character = byte_to_lsp_char(buf, line0, col0, client and client.offset_encoding) },
    }
    for k, v in pairs(extra or {}) do p[k] = v end
    return p
  end
end

local function check_target_buf(ctx, tool, buf)
  local registry = require("straps.registry")
  local label = relname(vim.api.nvim_buf_get_name(buf), buf)
  local st, rerr = registry.call("fn.reconcile_buf", buf)
  if st == nil then
    error(tool .. ": " .. label .. " " .. tostring(rerr), 0)
  elseif st == "reloaded" then
    error(tool .. ": " .. label .. " changed on disk since its buffer was loaded — another"
      .. " agent or external process is editing this file; the buffer has been reloaded"
      .. " from disk, re-read the file and retry", 0)
  end
  local wok, werr = registry.call("fn.check_writer", ctx and ctx.bufnr, buf)
  if wok == nil then error(tool .. ": " .. label .. " " .. tostring(werr), 0) end
end

local function buffer_versions()
  local versions = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then versions[buf] = vim.api.nvim_buf_get_changedtick(buf) end
  end
  return versions
end

local function validate_workspace_edits(ctx, tool, pending, versions)
  local targets = {}
  for _, p in ipairs(pending) do
    local ok, err = guard_workspace_edit(p.edit)
    if not ok then error(tool .. ": " .. tostring(err), 0) end
    for _, uri in ipairs(workspace_edit_uris(p.edit)) do
      local path = uri_path(uri)
      if targets[path] and targets[path] ~= p then
        error(tool .. ": refusing batch — multiple WorkspaceEdits target the same buffer: " .. relname(path), 0)
      end
      targets[path] = p
    end
  end
  for _, p in ipairs(pending) do
    for _, uri in ipairs(workspace_edit_uris(p.edit)) do
      local buf = vim.uri_to_bufnr(uri)
      if vim.api.nvim_buf_is_loaded(buf) and vim.api.nvim_buf_get_changedtick(buf) ~= versions[buf] then
        error(tool .. ": reference buffer changed while awaiting server responses — retry", 0)
      end
      vim.fn.bufload(buf)
      check_target_buf(ctx, tool, buf)
      versions[buf] = vim.api.nvim_buf_get_changedtick(buf)
    end
  end
end

local function validate_delete_targets(ctx, tool, entries)
  for _, e in ipairs(entries) do
    check_target_buf(ctx, tool, e.buf)
    if vim.bo[e.buf].modified or vim.api.nvim_buf_get_changedtick(e.buf) ~= e.tick then
      error(tool .. ": refusing — " .. relname(e.path) .. " changed while awaiting deletion — retry", 0)
    end
  end
end

local function after_writes(ctx, bufs)
  local registry = require("straps.registry")
  local extras = {}
  for _, buf in ipairs(bufs) do
    if vim.api.nvim_buf_is_loaded(buf) then
      registry.call("fn.mark_seen", ctx and ctx.bufnr, buf, true)
      local results, errors = registry.call_hooks("hook.after_write", vim.api.nvim_buf_get_name(buf), ctx)
      for _, r in ipairs(results) do
        if type(r) == "string" and r ~= "" then extras[#extras + 1] = r end
      end
      for _, e in ipairs(errors) do
        extras[#extras + 1] = "[hook " .. e.name .. " error: " .. e.err .. "]"
      end
    end
  end
  return extras
end

local function undo_seq(buf)
  local s = 0
  vim.api.nvim_buf_call(buf, function() s = vim.fn.undotree().seq_cur end)
  return s
end

local function rollback_workspace_edit(applied)
  local stuck = {}
  for _, s in ipairs(applied and applied.snaps or {}) do
    if vim.api.nvim_buf_is_loaded(s.buf) then
      local ok = pcall(function()
        vim.api.nvim_buf_call(s.buf, function() vim.cmd("silent undo " .. s.seq) end)
      end)
      if ok and undo_seq(s.buf) == s.seq then
        if not s.modified then vim.bo[s.buf].modified = false end
      else
        stuck[#stuck + 1] = relname(vim.api.nvim_buf_get_name(s.buf), s.buf)
      end
    end
  end
  return stuck
end

-- Apply a WorkspaceEdit through buffers (native undo, like write_file /
-- edit_file: each touched buffer gets its own undo break first) WITHOUT
-- saving. Every touched buffer passes check_target_buf first; a failed apply
-- is rolled back. Returns { bufs, snaps } for save_workspace_edit or
-- rollback_workspace_edit. Raises "<tool>: ...".
local function apply_workspace_edit(ctx, tool, edit, enc)
  local ok_guard, guard_err = guard_workspace_edit(edit)
  if not ok_guard then error(tool .. ": " .. tostring(guard_err), 0) end
  local bufs, seen = {}, {}
  for _, uri in ipairs(workspace_edit_uris(edit)) do
    local buf = vim.uri_to_bufnr(uri)
    if not seen[buf] then
      seen[buf] = true
      pcall(vim.fn.bufload, buf)
      bufs[#bufs + 1] = buf
    end
  end
  for _, buf in ipairs(bufs) do check_target_buf(ctx, tool, buf) end
  local applied = { bufs = bufs, snaps = {} }
  for _, buf in ipairs(bufs) do
    pcall(function()
      vim.api.nvim_buf_call(buf, function() vim.cmd("let &l:undolevels = &l:undolevels") end)
    end)
    applied.snaps[#applied.snaps + 1] = { buf = buf, seq = undo_seq(buf), modified = vim.bo[buf].modified }
  end
  local ok, err = pcall(vim.lsp.util.apply_workspace_edit, edit, enc or "utf-16")
  if not ok then
    local stuck = rollback_workspace_edit(applied)
    error(tool .. ": failed to apply edit: " .. tostring(err)
      .. (#stuck > 0 and ("; could not roll back, left modified: " .. table.concat(stuck, ", ")) or ""), 0)
  end
  return applied
end

local function save_workspace_edit(ctx, applied)
  local files, extras = {}, {}
  for _, buf in ipairs(applied.bufs) do
    local ok, err = pcall(function()
      vim.api.nvim_buf_call(buf, function() vim.cmd("silent noautocmd update") end)
    end)
    local label = relname(vim.api.nvim_buf_get_name(buf), buf)
    files[#files + 1] = label
    if not ok then extras[#extras + 1] = "failed to save " .. label .. ": " .. tostring(err) end
  end
  table.sort(files)
  vim.list_extend(extras, after_writes(ctx, applied.bufs))
  return files, extras
end

local function file_labels(applied)
  local files = {}
  for _, buf in ipairs(applied and applied.bufs or {}) do
    files[#files + 1] = relname(vim.api.nvim_buf_get_name(buf), buf)
  end
  table.sort(files)
  return files
end

local function with_extras(text, extras)
  if extras and #extras > 0 then return text .. "\n" .. table.concat(extras, "\n") end
  return text
end

-- Node types treated as outline entries, mapped to a kind label. Kept small
-- but language-general (lua / js / ts / python / go / rust).
local SYMBOL_KINDS = {
  -- lua
  function_declaration = "function",
  function_definition = "function",
  -- javascript / typescript
  function_expression = "function",
  generator_function_declaration = "function",
  method_definition = "method",
  class_declaration = "class",
  interface_declaration = "interface",
  -- python
  class_definition = "class",
  -- go
  method_declaration = "method",
  type_declaration = "type",
  type_spec = "type",
  -- rust
  function_item = "function",
  struct_item = "struct",
  enum_item = "enum",
  trait_item = "trait",
  impl_item = "impl",
}

-- Best-effort name of an outline node: the "name" field, else the first
-- identifier-ish child, else "<anonymous>".
local function node_name(node, buf)
  local ok, fields = pcall(function() return node:field("name") end)
  if ok and fields and fields[1] then
    local t = vim.treesitter.get_node_text(fields[1], buf)
    return (t or ""):match("^[^\n]*") or ""
  end
  for child in node:iter_children() do
    local ct = child:type()
    if ct:find("identifier") or ct == "name" then
      local t = vim.treesitter.get_node_text(child, buf)
      return (t or ""):match("^[^\n]*") or ""
    end
  end
  return "<anonymous>"
end

-- Walk the tree collecting outline entries { name, kind, sr, er } (1-based).
local function walk_symbols(node, buf, out)
  for child in node:iter_children() do
    local kind = SYMBOL_KINDS[child:type()]
    if kind then
      local sr, _, er, _ = child:range()
      out[#out + 1] = { name = node_name(child, buf), kind = kind, sr = sr + 1, er = er + 1 }
    end
    walk_symbols(child, buf, out)
  end
end

-- Try to get a tree-sitter parser for buf; returns parser or nil.
local function get_parser(buf, ft)
  local lang = ft
  local ok_l, mapped = pcall(vim.treesitter.language.get_lang, ft)
  if ok_l and mapped then lang = mapped end
  local ok, parser = pcall(vim.treesitter.get_parser, buf, lang)
  if ok and parser then return parser end
  ok, parser = pcall(vim.treesitter.get_parser, buf)
  if ok and parser then return parser end
  return nil
end

-- A window for BRAND-NEW content (a generated buffer, a diff side): always a
-- fresh split so it never replaces the file the user is reading. Focus is not
-- moved. Returns the new window id.
local function new_split_win(cmd)
  local cur = vim.api.nvim_get_current_win()
  vim.cmd(cmd or "botright vsplit")
  local w = vim.api.nvim_get_current_win()
  pcall(vim.api.nvim_set_current_win, cur)
  return w
end

-- A throwaway scratch buffer with content + filetype, named for legibility.
local function scratch_buf(lines, ft, name)
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].buftype = "nofile"
  vim.bo[b].bufhidden = "wipe"
  vim.bo[b].swapfile = false
  if type(ft) == "string" and ft ~= "" then pcall(function() vim.bo[b].filetype = ft end) end
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  if type(name) == "string" and name ~= "" then
    pcall(vim.api.nvim_buf_set_name, b, name)
  end
  return b
end

-- Unified diff between two strings, via vim.text.diff (0.11+) or vim.diff.
-- Returns the diff text (may be "" when identical).
local function unified_diff(old, new, ctxlen)
  local differ = (vim.text and vim.text.diff) or vim.diff
  local d = differ((old or "") .. "\n", (new or "") .. "\n", { ctxlen = ctxlen or 3 })
  return type(d) == "string" and d or ""
end

local function tag_location(t, sym)
  local file = t.filename
  if type(file) ~= "string" or file == "" then return nil end
  local full = vim.fn.fnamemodify(file, ":p")
  local okr, lines = pcall(vim.fn.readfile, full)
  if not okr then return nil end
  local cmd = tostring(t.cmd or "")
  local lnum = tonumber(cmd:match("^%s*(%d+)"))
  if not lnum then
    local pat = cmd:match("^/(.*)/;?\"?$") or cmd:match("^%?(.*)%?;?\"?$") or ""
    local anchored_start = pat:sub(1, 1) == "^"
    local anchored_end = pat:sub(-1) == "$" and pat:sub(-2, -2) ~= "\\"
    if anchored_start then pat = pat:sub(2) end
    if anchored_end then pat = pat:sub(1, -2) end
    pat = pat:gsub("\\([/?\\])", "%1")
    for i, l in ipairs(lines) do
      local hit
      if anchored_start and anchored_end then hit = l == pat
      elseif anchored_start then hit = l:sub(1, #pat) == pat
      elseif anchored_end then hit = l:sub(-#pat) == pat
      else hit = l:find(pat, 1, true) ~= nil end
      if hit then lnum = i; break end
    end
  end
  if not lnum then return nil end
  local col = ((lines[lnum] or ""):find(sym, 1, true)) or 1
  return string.format("%s:%d:%d", relname(full), lnum, col)
end

-- No-LSP-client fallback for a position-based navigation tool: look the symbol
-- under the cursor up in the tags files and return its locations through
-- location_output (file:line:col, quickfix honored). With no tags, raises the
-- standard "<tool>: no LSP client ... (and no tags)" error. Shared by
-- definition and references, which degrade identically.
local function tags_fallback(ctx, input, tool, buf, ft, line0, col0)
  local sym = symbol_at(buf, line0, col0)
  if sym and sym ~= "" then
    local okt, tags = pcall(vim.fn.taglist, "^" .. sym .. "$")
    if okt and type(tags) == "table" and #tags > 0 then
      local locs = {}
      for _, t in ipairs(tags) do
        local loc = tag_location(t, sym)
        if loc then locs[#locs + 1] = loc end
      end
      if #locs > 0 then
        return "no LSP client; tags for " .. sym .. ":\n"
          .. location_output(ctx, input, "straps: " .. tool .. " (tags)", locs, "")
      end
    end
  end
  error(tool .. ": no LSP client for filetype " .. (ft ~= "" and ft or "?") .. " (and no tags)", 0)
end

local function diag_covers(d, line0, col0)
  local dl0, dc0 = d.lnum or 0, d.col or 0
  local de0 = d.end_lnum or dl0
  local dec0 = d.end_col or (dc0 + 1)
  if de0 == dl0 and dec0 <= dc0 then return line0 == dl0 and col0 == dc0 end
  return (line0 > dl0 or (line0 == dl0 and col0 >= dc0))
    and (line0 < de0 or (line0 == de0 and col0 < dec0))
end

local function no_client(tool, ft, extra)
  error(tool .. ": no LSP client for filetype " .. (ft ~= "" and ft or "?") .. (extra or ""), 0)
end

-- True if buffer b is a straps session transcript (marked with b:straps_session).
-- Tools that scan windows/buffers use it to skip their own session buffer.
local function is_session(b)
  local okv, v = pcall(function() return vim.b[b].straps_session end)
  return okv and v ~= nil and v ~= false
end
]==]

-- Build a full tool source: the shared prelude followed by the tool body.
local function src(body)
  return PRELUDE .. "\n" .. body
end

function M.register()
  local registry = require("straps.registry")
  local define = registry.define_default

  -- -------------------------------------------------------------- diagnostics

  define({
    name = "tool.diagnostics",
    kind = "tool",
    doc = "Report Neovim diagnostics (LSP/linter warnings and errors). With"
      .. " `path`, loads that file's buffer and returns its diagnostics; without"
      .. " a path, returns diagnostics across all loaded file buffers. Each"
      .. " diagnostic is one line: 'file:line:col: SEVERITY message [source]'"
      .. " with 1-based line/col and SEVERITY one of ERROR/WARN/INFO/HINT."
      .. " Returns 'no diagnostics' when there are none. With quickfix=true it"
      .. " also loads the reported diagnostics into this session's findings list"
      .. " (the session window's location list when on-screen, else the global"
      .. " quickfix list; title 'straps: diagnostics'), so the user can jump"
      .. " through them with :lnext/:lprev (or :cnext/:cprev when it fell back);"
      .. " the returned text is unchanged. Parameters: path"
      .. " (optional) — file to inspect; omit to scan all loaded buffers; quickfix"
      .. " (optional boolean) — also populate the findings list.",
    input_schema = {
      type = "object",
      properties = {
        path = { type = "string", description = "File to inspect; omit for all loaded buffers." },
        quickfix = { type = "boolean", description = "Also populate this session's findings list with the diagnostics." },
      },
      required = {},
    },
    source = src([==[
return function(input, ctx)
  local ok, out = pcall(function()
    local sev = vim.diagnostic.severity
    local names = {
      [sev.ERROR] = "ERROR", [sev.WARN] = "WARN",
      [sev.INFO] = "INFO", [sev.HINT] = "HINT",
    }
    local bufs = {}
    if input and type(input.path) == "string" and input.path ~= "" then
      bufs = { (load_buf(input.path, "diagnostics")) }
    else
      for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(b)
          and vim.api.nvim_buf_get_name(b) ~= ""
          and not (pcall(function() return vim.b[b].straps_session end) and vim.b[b].straps_session) then
          bufs[#bufs + 1] = b
        end
      end
    end
    local types = {
      [sev.ERROR] = "E", [sev.WARN] = "W",
      [sev.INFO] = "I", [sev.HINT] = "N",
    }
    local lines, items = {}, {}
    for _, buf in ipairs(bufs) do
      local name = vim.api.nvim_buf_get_name(buf)
      local diags = vim.diagnostic.get(buf) or {}
      for _, d in ipairs(diags) do
        local severity = names[d.severity] or "UNKNOWN"
        local source = (d.source and d.source ~= "") and (" [" .. d.source .. "]") or ""
        lines[#lines + 1] = string.format("%s:%d:%d: %s %s%s",
          relname(name, buf), (d.lnum or 0) + 1, (d.col or 0) + 1,
          severity, tostring(d.message or ""), source)
        items[#items + 1] = {
          bufnr = buf,
          lnum = (d.lnum or 0) + 1,
          col = (d.col or 0) + 1,
          type = types[d.severity] or "",
          text = tostring(d.message or ""),
        }
      end
    end
    -- Optionally land the reported diagnostics in this session's findings list
    -- (its window's location list when on-screen — isolated from other
    -- sessions — else the global quickfix list). A side effect for
    -- :lnext/:cnext; the returned text below is unchanged.
    if input and input.quickfix then
      pcall(function()
        require("straps.findings").set_locations(ctx and ctx.bufnr,
          { title = "straps: diagnostics", items = items }, false)
      end)
    end
    if #lines == 0 then return "no diagnostics" end
    return table.concat(lines, "\n")
  end)
  if not ok then
    local msg = tostring(out)
    error(msg:sub(1, 13) == "diagnostics: " and msg or ("diagnostics: " .. msg), 0)
  end
  return out
end
]==]),
  })

  -- ----------------------------------------------------------- diagnostic_at

  define({
    name = "tool.diagnostic_at",
    kind = "tool",
    doc = "Report diagnostics covering a specific file position. Returns matching"
      .. " diagnostics as file:line:col: SEVERITY message [source], or a clear"
      .. " no-diagnostic message. Use before code_action when fixing a specific"
      .. " diagnostic. Parameters: path, line, col (all required).",
    input_schema = {
      type = "object",
      properties = {
        path = { type = "string", description = "File to inspect." },
        line = { type = "integer", description = "1-based line." },
        col = { type = "integer", description = "1-based column." },
      },
      required = { "path", "line", "col" },
    },
    source = src([==[
return function(input, ctx)
  local buf = load_buf(input.path, "diagnostic_at")
  local line0 = math.max(0, (tonumber(input.line) or 1) - 1)
  local col0 = math.max(0, (tonumber(input.col) or 1) - 1)
  local sev = vim.diagnostic.severity
  local names = { [sev.ERROR] = "ERROR", [sev.WARN] = "WARN", [sev.INFO] = "INFO", [sev.HINT] = "HINT" }
  local name = vim.api.nvim_buf_get_name(buf)
  local out = {}
  for _, d in ipairs(vim.diagnostic.get(buf) or {}) do
    local dl0, dc0 = d.lnum or 0, d.col or 0
    if diag_covers(d, line0, col0) then
      local source = (d.source and d.source ~= "") and (" [" .. d.source .. "]") or ""
      out[#out + 1] = string.format("%s:%d:%d: %s %s%s",
        relname(name, buf), dl0 + 1, dc0 + 1, names[d.severity] or "UNKNOWN", tostring(d.message or ""), source)
    end
  end
  if #out == 0 then return "no diagnostic at that position" end
  return table.concat(out, "\n")
end
]==]),
  })

  -- --------------------------------------------------------- diagnostic_next

  define({
    name = "tool.diagnostic_next",
    kind = "tool",
    doc = "Find the next or previous diagnostic in a file relative to a position."
      .. " Returns one location as file:line:col: SEVERITY message [source]."
      .. " Parameters: path, line, col; direction ('next' default or 'prev');"
      .. " severity optional (ERROR/WARN/INFO/HINT); wrap optional boolean.",
    input_schema = {
      type = "object",
      properties = {
        path = { type = "string", description = "File to inspect." },
        line = { type = "integer", description = "1-based line." },
        col = { type = "integer", description = "1-based column." },
        direction = { type = "string", description = "'next' (default) or 'prev'." },
        severity = { type = "string", description = "Optional severity filter: ERROR/WARN/INFO/HINT." },
        wrap = { type = "boolean", description = "Wrap around file ends (default true)." },
      },
      required = { "path", "line", "col" },
    },
    source = src([==[
return function(input, ctx)
  local buf = load_buf(input.path, "diagnostic_next")
  local line0 = math.max(0, (tonumber(input.line) or 1) - 1)
  local col0 = math.max(0, (tonumber(input.col) or 1) - 1)
  local sev = vim.diagnostic.severity
  local names = { [sev.ERROR] = "ERROR", [sev.WARN] = "WARN", [sev.INFO] = "INFO", [sev.HINT] = "HINT" }
  local want = type(input.severity) == "string" and sev[input.severity:upper()] or nil
  local diags = vim.diagnostic.get(buf, want and { severity = want } or nil) or {}
  table.sort(diags, function(a, b)
    if (a.lnum or 0) == (b.lnum or 0) then return (a.col or 0) < (b.col or 0) end
    return (a.lnum or 0) < (b.lnum or 0)
  end)
  if #diags == 0 then return "no diagnostics" end
  local dir = input.direction == "prev" and "prev" or "next"
  local chosen
  if dir == "next" then
    for _, d in ipairs(diags) do
      if (d.lnum or 0) > line0 or ((d.lnum or 0) == line0 and (d.col or 0) > col0) then chosen = d; break end
    end
    if not chosen and input.wrap ~= false then chosen = diags[1] end
  else
    for i = #diags, 1, -1 do
      local d = diags[i]
      if (d.lnum or 0) < line0 or ((d.lnum or 0) == line0 and (d.col or 0) < col0) then chosen = d; break end
    end
    if not chosen and input.wrap ~= false then chosen = diags[#diags] end
  end
  if not chosen then return "no " .. dir .. " diagnostic" end
  local source = (chosen.source and chosen.source ~= "") and (" [" .. chosen.source .. "]") or ""
  return string.format("%s:%d:%d: %s %s%s", relname(vim.api.nvim_buf_get_name(buf), buf),
    (chosen.lnum or 0) + 1, (chosen.col or 0) + 1, names[chosen.severity] or "UNKNOWN",
    tostring(chosen.message or ""), source)
end
]==]),
  })

  -- ----------------------------------------------------------- fix_diagnostic

  define({
    name = "tool.fix_diagnostic",
    kind = "tool",
    doc = "List or apply code actions for the diagnostic at a file position."
      .. " Without index, it lists fixes for diagnostics covering the position"
      .. " (read-only). With index=N, applies the Nth action via the same LSP"
      .. " WorkspaceEdit path as code_action (write, confirm-gated). Rejects WorkspaceEdit"
      .. " create/rename/delete resource operations and edits to buffers changed during requests. Parameters:"
      .. " path, line, col, index?",
    input_schema = {
      type = "object",
      properties = {
        path = { type = "string", description = "File containing the diagnostic." },
        line = { type = "integer", description = "1-based line." },
        col = { type = "integer", description = "1-based column." },
        index = { type = "integer", description = "Apply the Nth fix from the listing (omit to list)." },
      },
      required = { "path", "line", "col" },
    },
    source = src([==[
return function(input, ctx)
  local buf, ft = load_buf(input.path, "fix_diagnostic")
  local line0 = math.max(0, (tonumber(input.line) or 1) - 1)
  local col0 = math.max(0, (tonumber(input.col) or 1) - 1)
  local covering = {}
  for _, d in ipairs(vim.diagnostic.get(buf) or {}) do
    if diag_covers(d, line0, col0) then
      local dl0, dc0 = d.lnum or 0, d.col or 0
      local de0 = d.end_lnum or dl0
      local dec0 = d.end_col or (dc0 + 1)
      covering[#covering + 1] = (d.user_data and d.user_data.lsp) or {
        range = { start = { line = dl0, character = dc0 }, ["end"] = { line = de0, character = dec0 } },
        bytes = true,
        severity = d.severity,
        source = d.source,
        message = d.message,
      }
    end
  end
  if #covering == 0 then return "fix_diagnostic: no diagnostic at that position" end
  local params = function(client)
    local enc = client and client.offset_encoding
    local diags = {}
    for i, c in ipairs(covering) do
      if c.bytes then
        local s, e = c.range.start, c.range["end"]
        diags[i] = {
          range = {
            start = { line = s.line, character = byte_to_lsp_char(buf, s.line, s.character, enc) },
            ["end"] = { line = e.line, character = byte_to_lsp_char(buf, e.line, e.character, enc) },
          },
          severity = c.severity, source = c.source, message = c.message,
        }
      else
        diags[i] = c
      end
    end
    return {
      textDocument = { uri = vim.uri_from_bufnr(buf) },
      range = diags[1].range,
      context = { diagnostics = diags, only = { "quickfix" } },
    }
  end
  local versions = buffer_versions()
  local ok, res, err = pcall(lsp_request, ctx, buf, "textDocument/codeAction", params, 5000)
  if not ok then error("fix_diagnostic: " .. tostring(res), 0) end
  if err == "noclient" then no_client("fix_diagnostic", ft) end
  if err == "timeout" then error("fix_diagnostic: LSP request timed out", 0) end
  local cids = {}
  for cid in pairs(res or {}) do cids[#cids + 1] = cid end
  table.sort(cids)
  local actions = {}
  for _, cid in ipairs(cids) do
    local result = result_of(res[cid])
    for _, a in ipairs(type(result) == "table" and result or {}) do
      actions[#actions + 1] = { action = a, client_id = cid }
    end
  end
  if #actions == 0 then return "fix_diagnostic: no fixes available for diagnostic" end
  local index = tonumber(input.index)
  if not index then
    local lines = {}
    for i, entry in ipairs(actions) do
      local a = entry.action
      lines[#lines + 1] = string.format("%d. %s%s", i, a.title or "?",
        a.kind and ("  [" .. a.kind .. "]") or "")
    end
    lines[#lines + 1] = "(call again with index=N to apply one)"
    return table.concat(lines, "\n")
  end
  local entry = actions[index]
  if not entry then error(string.format("fix_diagnostic: index %d out of range (1-%d)", index, #actions), 0) end
  local action = entry.action
  local client = vim.lsp.get_client_by_id(entry.client_id)
  if client and not action.edit and not action.command then
    local resolved = client_request(ctx, client, "codeAction/resolve", action, buf, 5000)
    if type(resolved) == "table" then action = resolved end
  end
  local did, extras = {}, {}
  if type(action.edit) == "table" then
    validate_workspace_edits(ctx, "fix_diagnostic", { { edit = action.edit } }, versions)
    local applied = apply_workspace_edit(ctx, "fix_diagnostic", action.edit, client and client.offset_encoding)
    local files
    files, extras = save_workspace_edit(ctx, applied)
    did[#did + 1] = "edited " .. table.concat(files, ", ")
  end
  local cmd = action.command
  if type(cmd) == "string" then cmd = { command = cmd } end
  if type(cmd) == "table" and cmd.command and client then
    local _, cerr = client_request(ctx, client, "workspace/executeCommand",
      { command = cmd.command, arguments = cmd.arguments }, buf, 5000)
    did[#did + 1] = cerr and ("command " .. cmd.command .. " failed: " .. cerr) or ("ran command " .. cmd.command)
  end
  if #did == 0 then error("fix_diagnostic: action had no edit or command to apply", 0) end
  return with_extras(string.format("applied %q: %s — undo with u in each edited buffer",
    action.title or "?", table.concat(did, "; ")), extras)
end
]==]),
  })

  -- --------------------------------------------------------- declaration/etc.

  local function location_tool(api_name, method, label)
    define({
      name = "tool." .. api_name,
      kind = "tool",
      doc = label .. " for the symbol at a position via the attached LSP client"
        .. " (" .. method .. "). Returns target location(s) as 'file:line:col'."
        .. " With quickfix=true it also loads locations into this session's"
        .. " findings list. Parameters: path (required); line/col (required,"
        .. " 1-based); quickfix/open (optional).",
      input_schema = {
        type = "object",
        properties = {
          path = { type = "string", description = "File containing the symbol." },
          line = { type = "integer", description = "1-based line of the symbol." },
          col = { type = "integer", description = "1-based column of the symbol." },
          quickfix = { type = "boolean", description = "Also populate this session's findings list with the locations." },
          open = { type = "boolean", description = "Open the findings list when quickfix=true (default true)." },
        },
        required = { "path", "line", "col" },
      },
      source = src(([[
local TOOL = %q
return function(input, ctx)
  local buf, ft = load_buf(input.path, TOOL)
  local line0 = math.max(0, (tonumber(input.line) or 1) - 1)
  local col0 = math.max(0, (tonumber(input.col) or 1) - 1)
  local params = position_params(buf, line0, col0)
  local ok, res, err = pcall(lsp_request, ctx, buf, %q, params, 5000)
  if not ok then error(TOOL .. ": " .. tostring(res), 0) end
  if err == "noclient" then no_client(TOOL, ft) end
  if err == "timeout" then error(TOOL .. ": LSP request timed out", 0) end
  local locs = {}
  local enc = buf_offset_encoding(buf)
  each_result(res, function(result) collect_locations(result, locs, enc) end)
  return location_output(ctx, input, "straps: " .. TOOL, locs, "no %s found")
end
]]):format(api_name, method, (api_name:gsub("_", " ")))),
    })
  end

  location_tool("declaration", "textDocument/declaration", "Go to declaration")
  location_tool("type_definition", "textDocument/typeDefinition", "Go to type definition")
  location_tool("implementation", "textDocument/implementation", "Go to implementation")

  -- --------------------------------------------------------------- lsp_status

  define({
    name = "tool.lsp_status",
    kind = "tool",
    doc = "Report whether Neovim LSP clients are attached/enabled for a file."
      .. " Loads the file's buffer, waits briefly for clients to attach, and lists"
      .. " each client name/id plus whether it supports common navigation methods."
      .. " Read-only. Parameters: path (required) — file to inspect.",
    input_schema = {
      type = "object",
      properties = {
        path = { type = "string", description = "File whose LSP attachment/status to inspect." },
      },
      required = { "path" },
    },
    source = src([==[
return function(input, ctx)
  local buf, ft = load_buf(input.path, "lsp_status")
  local clients = wait_clients(ctx, buf)
  if not clients or #clients == 0 then
    return "no LSP client attached for " .. relname(vim.api.nvim_buf_get_name(buf), buf)
      .. " (filetype " .. (ft ~= "" and ft or "?") .. ")"
  end
  local methods = {
    "textDocument/definition", "textDocument/declaration",
    "textDocument/typeDefinition", "textDocument/implementation",
    "textDocument/references", "textDocument/hover",
    "textDocument/signatureHelp", "textDocument/codeAction",
    "textDocument/formatting", "textDocument/rename",
  }
  local out = { string.format("%d LSP client%s attached to %s (filetype %s):",
    #clients, #clients == 1 and "" or "s", relname(vim.api.nvim_buf_get_name(buf), buf), ft ~= "" and ft or "?") }
  for _, c in ipairs(clients) do
    local caps = {}
    for _, m in ipairs(methods) do
      local ok, yes = pcall(function() return c:supports_method(m) end)
      if ok and yes then caps[#caps + 1] = m:gsub("^textDocument/", "") end
    end
    out[#out + 1] = string.format("- %s (id %s): %s", c.name or "?", tostring(c.id),
      #caps > 0 and table.concat(caps, ", ") or "no common textDocument capabilities reported")
  end
  return table.concat(out, "\n")
end
]==]),
  })

  -- --------------------------------------------------------------- definition

  define({
    name = "tool.definition",
    kind = "tool",
    doc = "Go to the definition of the symbol at a position, using the attached"
      .. " LSP client (textDocument/definition). Returns the target location(s)"
      .. " as 'file:line:col'. If no LSP client is attached, falls back to a tags"
      .. " lookup of the symbol under the position (same 'file:line:col' shape);"
      .. " if that finds nothing, fails with 'no LSP client'. With quickfix=true it also"
      .. " loads locations into this session's findings list. Parameters: path"
      .. " (required); line (required, 1-based); col (required, 1-based);"
      .. " quickfix/open (optional).",
    input_schema = {
      type = "object",
      properties = {
        path = { type = "string", description = "File containing the symbol." },
        line = { type = "integer", description = "1-based line of the symbol." },
        col = { type = "integer", description = "1-based column of the symbol." },
        quickfix = { type = "boolean", description = "Also populate this session's findings list with the locations." },
        open = { type = "boolean", description = "Open the findings list when quickfix=true (default true)." },
      },
      required = { "path", "line", "col" },
    },
    source = src([==[
return function(input, ctx)
  local buf, ft = load_buf(input.path, "definition")
  local line0 = math.max(0, (tonumber(input.line) or 1) - 1)
  local col0 = math.max(0, (tonumber(input.col) or 1) - 1)

  local params = position_params(buf, line0, col0)
  local ok, res, err = pcall(lsp_request, ctx, buf, "textDocument/definition", params, 5000)
  if not ok then error("definition: " .. tostring(res), 0) end
  if err == "noclient" then return tags_fallback(ctx, input, "definition", buf, ft, line0, col0) end
  if err == "timeout" then error("definition: LSP request timed out", 0) end

  local locs = {}
  local enc = buf_offset_encoding(buf)
  each_result(res, function(result) collect_locations(result, locs, enc) end)
  return location_output(ctx, input, "straps: definition", locs, "no definition found")
end
]==]),
  })

  -- --------------------------------------------------------------- references

  define({
    name = "tool.references",
    kind = "tool",
    doc = "Find all references to the symbol at a position via the attached LSP"
      .. " client (textDocument/references, including the declaration). Returns a"
      .. " deduped, sorted list of 'file:line:col'. If no LSP client is attached,"
      .. " falls back to a tags lookup of the symbol (same 'file:line:col' shape),"
      .. " and otherwise fails with 'no LSP client'. With quickfix=true it also loads locations"
      .. " into this session's findings list. Parameters: path (required); line"
      .. " (required, 1-based); col (required, 1-based); quickfix/open (optional).",
    input_schema = {
      type = "object",
      properties = {
        path = { type = "string", description = "File containing the symbol." },
        line = { type = "integer", description = "1-based line of the symbol." },
        col = { type = "integer", description = "1-based column of the symbol." },
        quickfix = { type = "boolean", description = "Also populate this session's findings list with the locations." },
        open = { type = "boolean", description = "Open the findings list when quickfix=true (default true)." },
      },
      required = { "path", "line", "col" },
    },
    source = src([==[
return function(input, ctx)
  local buf, ft = load_buf(input.path, "references")
  local line0 = math.max(0, (tonumber(input.line) or 1) - 1)
  local col0 = math.max(0, (tonumber(input.col) or 1) - 1)

  local params = position_params(buf, line0, col0, { context = { includeDeclaration = true } })
  local ok, res, err = pcall(lsp_request, ctx, buf, "textDocument/references", params, 5000)
  if not ok then error("references: " .. tostring(res), 0) end
  if err == "noclient" then return tags_fallback(ctx, input, "references", buf, ft, line0, col0) end
  if err == "timeout" then error("references: LSP request timed out", 0) end

  local locs = {}
  local enc = buf_offset_encoding(buf)
  each_result(res, function(result) collect_locations(result, locs, enc) end)
  return location_output(ctx, input, "straps: references", locs, "no references found")
end
]==]),
  })

  -- --------------------------------------------------------- tree_sitter_status

  define({
    name = "tool.tree_sitter_status",
    kind = "tool",
    doc = "Report whether tree-sitter can parse a file: detected filetype, mapped"
      .. " language, parser availability, root node type, and top-level child count."
      .. " Read-only. Parameters: path (required).",
    input_schema = {
      type = "object",
      properties = { path = { type = "string", description = "File to inspect." } },
      required = { "path" },
    },
    source = src([==[
return function(input, ctx)
  local buf, ft = load_buf(input.path, "tree_sitter_status")
  local lang = ft
  local ok_l, mapped = pcall(vim.treesitter.language.get_lang, ft)
  if ok_l and mapped then lang = mapped end
  local parser = get_parser(buf, ft)
  if not parser then
    return "no tree-sitter parser for " .. relname(vim.api.nvim_buf_get_name(buf), buf)
      .. " (filetype " .. (ft ~= "" and ft or "?") .. ", language " .. (lang ~= "" and lang or "?") .. ")"
  end
  local ok, trees = pcall(function() return parser:parse() end)
  if not ok or not trees or not trees[1] then error("tree_sitter_status: tree-sitter parser exists but parse failed", 0) end
  local root = trees[1]:root()
  local children = 0
  for _ in root:iter_children() do children = children + 1 end
  return string.format("tree-sitter parser ready for %s: filetype=%s language=%s root=%s top_level_children=%d",
    relname(vim.api.nvim_buf_get_name(buf), buf), ft ~= "" and ft or "?", lang ~= "" and lang or "?", root:type(), children)
end
]==]),
  })

  -- ------------------------------------------------------------- node_at

  define({
    name = "tool.node_at",
    kind = "tool",
    doc = "Inspect the tree-sitter node at a file position. Returns the smallest"
      .. " named node, its range, parent chain, and capped source text. Read-only."
      .. " Parameters: path, line, col; max_text_bytes optional (default 500, max 5000).",
    input_schema = {
      type = "object",
      properties = {
        path = { type = "string", description = "File to inspect." },
        line = { type = "integer", description = "1-based line." },
        col = { type = "integer", description = "1-based column." },
        max_text_bytes = { type = "integer", description = "Maximum node text bytes (default 500, max 5000)." },
      },
      required = { "path", "line", "col" },
    },
    source = src([==[
return function(input, ctx)
  local buf, ft = load_buf(input.path, "node_at")
  local parser = get_parser(buf, ft)
  if not parser then error("node_at: no tree-sitter parser for " .. (ft ~= "" and ft or "?"), 0) end
  local ok, trees = pcall(function() return parser:parse() end)
  if not ok or not trees or not trees[1] then error("node_at: parse failed", 0) end
  local root = trees[1]:root()
  local line0 = math.max(0, (tonumber(input.line) or 1) - 1)
  local col0 = math.max(0, (tonumber(input.col) or 1) - 1)
  local node = root:named_descendant_for_range(line0, col0, line0, col0)
  if not node then error("node_at: no named node at that position", 0) end
  local sr, sc, er, ec = node:range()
  local chain, cur = {}, node
  while cur do
    chain[#chain + 1] = cur:type()
    cur = cur:parent()
  end
  local text = vim.treesitter.get_node_text(node, buf) or ""
  local cap = math.min(math.max(tonumber(input.max_text_bytes) or 500, 0), 5000)
  if #text > cap then text = require("straps.state").utf8_cut(text, cap) .. "\n[truncated: node text exceeded " .. cap .. " bytes]" end
  return string.format("%s  L%d:%d-L%d:%d\nparents: %s\ntext:\n%s",
    node:type(), sr + 1, sc + 1, er + 1, ec + 1, table.concat(chain, " <- "), text)
end
]==]),
  })

  -- ------------------------------------------------------------- read_node

  define({
    name = "tool.read_node",
    kind = "tool",
    doc = "Read source for the tree-sitter node at a position, optionally climbing"
      .. " to an ancestor type (for example function_declaration or class_definition)."
      .. " Returns numbered lines like read_file. Read-only. Parameters: path, line,"
      .. " col; ancestor optional; max_lines optional (default 200, max 1000).",
    input_schema = {
      type = "object",
      properties = {
        path = { type = "string", description = "File to inspect." },
        line = { type = "integer", description = "1-based line." },
        col = { type = "integer", description = "1-based column." },
        ancestor = { type = "string", description = "Optional ancestor node type to climb to." },
        max_lines = { type = "integer", description = "Maximum lines to return (default 200, max 1000)." },
      },
      required = { "path", "line", "col" },
    },
    source = src([==[
return function(input, ctx)
  local buf, ft = load_buf(input.path, "read_node")
  local parser = get_parser(buf, ft)
  if not parser then error("read_node: no tree-sitter parser for " .. (ft ~= "" and ft or "?"), 0) end
  local ok, trees = pcall(function() return parser:parse() end)
  if not ok or not trees or not trees[1] then error("read_node: parse failed", 0) end
  local root = trees[1]:root()
  local line0 = math.max(0, (tonumber(input.line) or 1) - 1)
  local col0 = math.max(0, (tonumber(input.col) or 1) - 1)
  local node = root:named_descendant_for_range(line0, col0, line0, col0)
  if not node then error("read_node: no named node at that position", 0) end
  if type(input.ancestor) == "string" and input.ancestor ~= "" then
    local want, cur = input.ancestor, node
    while cur and cur:type() ~= want do cur = cur:parent() end
    if not cur then error("read_node: no ancestor of type " .. want .. " from node " .. node:type(), 0) end
    node = cur
  end
  local sr, _, er, _ = node:range()
  local max_lines = math.min(math.max(tonumber(input.max_lines) or 200, 1), 1000)
  local last = math.min(er + 1, sr + max_lines)
  local body = vim.api.nvim_buf_get_lines(buf, sr, last, false)
  local out = { string.format("%s  L%d-%d", node:type(), sr + 1, er + 1) }
  for i, l in ipairs(body) do out[#out + 1] = string.format("  %d\t%s", sr + i, l) end
  if er + 1 > last then out[#out + 1] = string.format("[truncated: showing %d of %d lines]", max_lines, er - sr + 1) end
  return table.concat(out, "\n")
end
]==]),
  })

  -- ------------------------------------------------------------------ symbols

  define({
    name = "tool.symbols",
    kind = "tool",
    doc = "Produce a document outline for a file: its functions, methods,"
      .. " classes and similar constructs at every nesting depth (nested"
      .. " functions and methods included). Prefers tree-sitter, so it"
      .. " works without any LSP server; falls back to LSP documentSymbol if no"
      .. " tree-sitter parser is available. Each symbol is one line:"
      .. " 'name  kind  L<start>-<end>' (1-based line range). Parameters: path"
      .. " (required) — the file to outline.",
    input_schema = {
      type = "object",
      properties = {
        path = { type = "string", description = "File to outline." },
      },
      required = { "path" },
    },
    source = src([==[
return function(input, ctx)
  local buf, ft = load_buf(input.path, "symbols")

  -- Prefer tree-sitter (no server needed).
  local parser = get_parser(buf, ft)
  if parser then
    local ok, out = pcall(function()
      local trees = parser:parse()
      if not trees or not trees[1] then return nil end
      local root = trees[1]:root()
      local syms = {}
      walk_symbols(root, buf, syms)
      if #syms == 0 then return "no symbols found in " .. relname(vim.api.nvim_buf_get_name(buf), buf) end
      local lines = {}
      for _, s in ipairs(syms) do
        lines[#lines + 1] = string.format("%s  %s  L%d-%d", s.name, s.kind, s.sr, s.er)
      end
      return table.concat(lines, "\n")
    end)
    if ok and out then return out end
  end

  -- Fall back to LSP documentSymbol.
  local params = { textDocument = { uri = vim.uri_from_bufnr(buf) } }
  local ok, res, err = pcall(lsp_request, ctx, buf, "textDocument/documentSymbol", params, 5000)
  if ok and err == nil and res then
    local kinds = vim.lsp.protocol.SymbolKind or {}
    local lines = {}
    local function walk(list)
      for _, s in ipairs(list or {}) do
        local range = s.range or (s.location and s.location.range)
        local kind = kinds[s.kind] or tostring(s.kind or "?")
        if range and range.start then
          lines[#lines + 1] = string.format("%s  %s  L%d-%d",
            s.name or "?", kind, range.start.line + 1, (range["end"] or range.start).line + 1)
        end
        if s.children then walk(s.children) end
      end
    end
    walk(res and (function() local m = {}; each_result(res, function(r) for _, x in ipairs(r or {}) do m[#m+1]=x end end); return m end)() or {})
    if #lines > 0 then return table.concat(lines, "\n") end
  end
  error("symbols: no tree-sitter parser or LSP for " .. (ft ~= "" and ft or "?"), 0)
end
]==]),
  })

  -- -------------------------------------------------------------- read_symbol

  define({
    name = "tool.read_symbol",
    kind = "tool",
    doc = "Read the source text of a named symbol (function, method, class, ...)"
      .. " from a file using tree-sitter — a targeted read instead of the whole"
      .. " file. Returns the symbol's lines with 1-based line numbers, like"
      .. " read_file, capped at 1000 lines with a truncation note. If several"
      .. " symbols share the name, lists the matches"
      .. " ('name  L<start>-<end>') so you can pick; if none match, says so."
      .. " Parameters: path (required); name (required) — the symbol name.",
    input_schema = {
      type = "object",
      properties = {
        path = { type = "string", description = "File containing the symbol." },
        name = { type = "string", description = "Name of the function/class to read." },
      },
      required = { "path", "name" },
    },
    source = src([==[
return function(input, ctx)
  local want = input.name
  if type(want) ~= "string" or want == "" then
    error("read_symbol: name is required", 0)
  end
  local buf, ft = load_buf(input.path, "read_symbol")
  local parser = get_parser(buf, ft)
  if not parser then
    error("read_symbol: no tree-sitter parser for " .. (ft ~= "" and ft or "?"), 0)
  end
  local ok, out = pcall(function()
    local trees = parser:parse()
    if not trees or not trees[1] then
      error("read_symbol: could not parse " .. tostring(input.path), 0)
    end
    local syms = {}
    walk_symbols(trees[1]:root(), buf, syms)
    local matches = {}
    for _, s in ipairs(syms) do
      if s.name == want then matches[#matches + 1] = s end
    end
    if #matches == 0 then
      return "no symbol named " .. want .. " in " .. tostring(input.path)
    end
    if #matches > 1 then
      local lines = { "multiple symbols named " .. want .. " — specify by reading a range:" }
      for _, s in ipairs(matches) do
        lines[#lines + 1] = string.format("%s  L%d-%d", s.name, s.sr, s.er)
      end
      return table.concat(lines, "\n")
    end
    local s = matches[1]
    local last = math.min(s.er, s.sr - 1 + 1000)
    local body = vim.api.nvim_buf_get_lines(buf, s.sr - 1, last, false)
    local lines = {}
    for i, l in ipairs(body) do
      lines[#lines + 1] = string.format("  %d\t%s", s.sr + i - 1, l)
    end
    if s.er > last then
      lines[#lines + 1] = string.format("[truncated: showing 1000 of %d lines; read_file offset=%d for the rest]",
        s.er - s.sr + 1, last + 1)
    end
    return table.concat(lines, "\n")
  end)
  if not ok then
    local msg = tostring(out)
    error(msg:sub(1, 13) == "read_symbol: " and msg or ("read_symbol: " .. msg), 0)
  end
  return out
end
]==]),
  })

  -- -------------------------------------------------------------------- hover

  define({
    name = "tool.hover",
    kind = "tool",
    doc = "Type information and documentation for the symbol at a position,"
      .. " via the attached LSP client (textDocument/hover) — one call instead"
      .. " of a grep-and-read hunt when you just need a signature or type."
      .. " Returns the hover text as markdown/plain lines, or a clear 'no LSP"
      .. " client' / 'no hover info' message. Parameters: path (required);"
      .. " line (required, 1-based); col (required, 1-based).",
    input_schema = {
      type = "object",
      properties = {
        path = { type = "string", description = "File containing the symbol." },
        line = { type = "integer", description = "1-based line of the symbol." },
        col = { type = "integer", description = "1-based column of the symbol." },
      },
      required = { "path", "line", "col" },
    },
    source = src([==[
return function(input, ctx)
  local buf, ft = load_buf(input.path, "hover")
  local line0 = math.max(0, (tonumber(input.line) or 1) - 1)
  local col0 = math.max(0, (tonumber(input.col) or 1) - 1)
  local params = position_params(buf, line0, col0)
  local ok, res, err = pcall(lsp_request, ctx, buf, "textDocument/hover", params, 5000)
  if not ok then error("hover: " .. tostring(res), 0) end
  if err == "noclient" then no_client("hover", ft) end
  if err == "timeout" then error("hover: LSP request timed out", 0) end
  local out = {}
  each_result(res, function(result)
    if type(result) == "table" and result.contents then
      local okc, lines = pcall(vim.lsp.util.convert_input_to_markdown_lines, result.contents)
      if okc and type(lines) == "table" then
        for _, l in ipairs(lines) do out[#out + 1] = l end
      end
    end
  end)
  while out[1] == "" do table.remove(out, 1) end
  while #out > 0 and out[#out] == "" do table.remove(out) end
  if #out == 0 then return "no hover info at that position" end
  return table.concat(out, "\n")
end
]==]),
  })

  -- -------------------------------------------------------- workspace_symbols

  define({
    name = "tool.workspace_symbols",
    kind = "tool",
    doc = "Find a symbol project-wide by (partial) name via the LSP"
      .. " (workspace/symbol) — the step BEFORE definition/references when you"
      .. " do not yet know which file a symbol lives in. Returns one line per"
      .. " match: 'name  kind  file:line:col', deduped and capped at 200."
      .. " With quickfix=true it also loads symbol locations into this session's"
      .. " findings list. Parameters: query (required) — the symbol name or a"
      .. " prefix of it; path (optional) — a file of the target language, used to"
      .. " pick the LSP client; without it the first loaded buffer with a client is"
      .. " used; quickfix/open (optional).",
    input_schema = {
      type = "object",
      properties = {
        query = { type = "string", description = "Symbol name (or prefix) to search for." },
        path = { type = "string", description = "A file of the target language (picks the LSP client)." },
        quickfix = { type = "boolean", description = "Also populate this session's findings list with symbol locations." },
        open = { type = "boolean", description = "Open the findings list when quickfix=true (default true)." },
      },
      required = { "query" },
    },
    source = src([==[
return function(input, ctx)
  local query = input.query
  if type(query) ~= "string" then error("workspace_symbols: query is required", 0) end
  local buf, ft
  if type(input.path) == "string" and input.path ~= "" then
    buf, ft = load_buf(input.path, "workspace_symbols")
  else
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(b) and #vim.lsp.get_clients({ bufnr = b }) > 0 then
        buf = b
        break
      end
    end
    if not buf then
      error("workspace_symbols: no LSP client running — pass path to a file of the target language", 0)
    end
  end
  local ok, res, err = pcall(lsp_request, ctx, buf, "workspace/symbol", { query = query }, 5000)
  if not ok then error("workspace_symbols: " .. tostring(res), 0) end
  if err == "noclient" then no_client("workspace_symbols", ft) end
  if err == "timeout" then error("workspace_symbols: LSP request timed out", 0) end
  local kinds = vim.lsp.protocol.SymbolKind or {}
  local seen, out, locs = {}, {}, {}
  local enc = buf_offset_encoding(buf)
  each_result(res, function(result)
    for _, s in ipairs(result or {}) do
      local where = ""
      local loc = s.location
      if type(loc) == "table" and loc.uri then
        local file = vim.fn.fnamemodify(vim.uri_to_fname(loc.uri), ":~:.")
        if loc.range and loc.range.start then
          local col = lsp_char_to_byte_col(loc.uri, loc.range.start.line, loc.range.start.character, enc)
          where = string.format("%s:%d:%d",
            file, loc.range.start.line + 1, col)
          locs[#locs + 1] = where
        else
          where = file
        end
      end
      local line = string.format("%s  %s  %s",
        s.name or "?", kinds[s.kind] or tostring(s.kind or "?"), where)
      if not seen[line] then
        seen[line] = true
        out[#out + 1] = line
      end
    end
  end)
  if #out == 0 then
    maybe_set_locations(ctx, input, "straps: workspace_symbols " .. query, {})
    return "no workspace symbols match " .. query
  end
  local total = #out
  if total > 200 then
    local capped = {}
    for i = 1, 200 do capped[i] = out[i] end
    capped[#capped + 1] = string.format("[truncated: showing 200 of %d matches; narrow the query]", total)
    out = capped
  end
  local kind = maybe_set_locations(ctx, input, "straps: workspace_symbols " .. query, locs)
  local text = table.concat(out, "\n")
  if kind then text = text .. "\n" .. kind .. ": " .. tostring(#sorted_unique(locs)) .. " location(s)" end
  return text
end
]==]),
  })

  -- ------------------------------------------------------------ rename_symbol

  define({
    name = "tool.rename_symbol",
    kind = "tool",
    doc = "Semantically rename the symbol at a position across the whole"
      .. " project via the LSP (textDocument/rename) — unlike bulk_replace it"
      .. " renames the SYMBOL, not the text, so same-named identifiers of other"
      .. " things are untouched. The returned WorkspaceEdit is applied through"
      .. " each file's buffer (native undo: `u` in each touched buffer) and"
      .. " every touched file is saved. Rejects WorkspaceEdit create/rename/delete"
      .. " resource operations and edits to buffers changed during requests. This is a WRITE tool and prompts for"
      .. " confirmation. Parameters: path (required); line (required, 1-based);"
      .. " col (required, 1-based) — position of the symbol; new_name"
      .. " (required).",
    input_schema = {
      type = "object",
      properties = {
        path = { type = "string", description = "File containing the symbol." },
        line = { type = "integer", description = "1-based line of the symbol." },
        col = { type = "integer", description = "1-based column of the symbol." },
        new_name = { type = "string", description = "The new name for the symbol." },
      },
      required = { "path", "line", "col", "new_name" },
    },
    source = src([==[
return function(input, ctx)
  local new_name = input.new_name
  if type(new_name) ~= "string" or new_name == "" then
    error("rename_symbol: new_name is required", 0)
  end
  local buf, ft = load_buf(input.path, "rename_symbol")
  local line0 = math.max(0, (tonumber(input.line) or 1) - 1)
  local col0 = math.max(0, (tonumber(input.col) or 1) - 1)
  local params = position_params(buf, line0, col0, { newName = new_name })
  local versions = buffer_versions()
  local ok, res, err = pcall(lsp_request, ctx, buf, "textDocument/rename", params, 10000)
  if not ok then error("rename_symbol: " .. tostring(res), 0) end
  if err == "noclient" then
    no_client("rename_symbol", ft, " — rename needs a language server (grep + bulk_replace is the textual fallback)")
  end
  if err == "timeout" then error("rename_symbol: LSP request timed out", 0) end
  local edit, enc
  for cid, r in pairs(res or {}) do
    local result = result_of(r)
    if type(result) == "table" then
      edit = result
      local c = vim.lsp.get_client_by_id(cid)
      enc = c and c.offset_encoding
      break
    end
  end
  if not edit then
    error("rename_symbol: server returned no edit — is the position on a renameable symbol?", 0)
  end
  validate_workspace_edits(ctx, "rename_symbol", { { edit = edit } }, versions)
  local applied = apply_workspace_edit(ctx, "rename_symbol", edit, enc)
  local files, extras = save_workspace_edit(ctx, applied)
  return with_extras(string.format("renamed to %s across %d file%s:\n%s\n— undo with u in each buffer",
    new_name, #files, #files == 1 and "" or "s", table.concat(files, "\n")), extras)
end
]==]),
  })

  -- ------------------------------------------------------------- move_file

  define({
    name = "tool.move_file",
    kind = "tool",
    doc = "Move/rename a file on disk. If a language server is attached to"
      .. " it and supports workspace/willRenameFiles, the server is asked"
      .. " FIRST for a WorkspaceEdit fixing up references elsewhere (e.g."
      .. " import paths) — applied through each touched buffer (native undo)"
      .. " before the file itself moves. The move/rename then goes through"
      .. " vim.lsp.util.rename (renames any open buffer in place, keeping its"
      .. " undo history, and moves its undofile) so open buffers never go"
      .. " stale, and workspace/didRenameFiles notifies the server afterward."
      .. " No attached/capable server: a plain filesystem move, since not"
      .. " every filetype has one. If the move fails, the server's reference"
      .. " edits are undone in their buffers and nothing is saved. This is a WRITE tool and"
      .. " prompts for confirmation. Parameters: from (required, existing"
      .. " path); to (required, destination path; parent dirs are created)."
      .. " Rejects WorkspaceEdit create/rename/delete resource operations and edits to buffers changed during requests."
      .. " For renaming a SYMBOL rather than a file, use rename_symbol.",
    input_schema = {
      type = "object",
      properties = {
        from = { type = "string", description = "Existing file path to move." },
        to = { type = "string", description = "Destination path (parent dirs created)." },
      },
      required = { "from", "to" },
    },
    source = src([==[
return function(input, ctx)
  local from, to = input.from, input.to
  if type(from) ~= "string" or from == "" then error("move_file: from is required", 0) end
  if type(to) ~= "string" or to == "" then error("move_file: to is required", 0) end

  local from_full = vim.fn.fnamemodify(from, ":p")
  if vim.fn.filereadable(from_full) ~= 1 then
    error("move_file: no such file: " .. relname(from_full), 0)
  end
  local to_full = vim.fn.fnamemodify(to, ":p")
  if vim.fn.filereadable(to_full) == 1 then
    error("move_file: destination already exists: " .. relname(to_full), 0)
  end

  local buf = load_buf(from_full, "move_file")
  local clients = wait_clients(ctx, buf)
  local mover
  for _, c in ipairs(clients or {}) do
    local ok_s, supports = pcall(function()
      return c:supports_method("workspace/willRenameFiles")
    end)
    if ok_s and supports then mover = c; break end
  end

  local edit_note = ""
  local applied
  if mover then
    local params = {
      files = { { oldUri = vim.uri_from_fname(from_full), newUri = vim.uri_from_fname(to_full) } },
    }
    local versions = buffer_versions()
    local result, err = client_request(ctx, mover, "workspace/willRenameFiles", params, buf, 8000)
    if result and type(result) == "table" and (result.changes or result.documentChanges) then
      validate_workspace_edits(ctx, "move_file", { { edit = result } }, versions)
      applied = apply_workspace_edit(ctx, "move_file", result, mover.offset_encoding)
    elseif err then
      edit_note = "; willRenameFiles request " .. tostring(err) .. " (moved anyway)"
    end
  end

  local ok_rn, rn_err = pcall(vim.lsp.util.rename, from_full, to_full, {})
  if ok_rn and (vim.fn.filereadable(to_full) ~= 1 or vim.fn.filereadable(from_full) == 1) then
    ok_rn, rn_err = false, "file was not moved"
  end
  if not ok_rn then
    local msg = "move_file: rename failed: " .. tostring(rn_err)
    if applied then
      local stuck = rollback_workspace_edit(applied)
      msg = msg .. (#stuck > 0
        and ("; reference edits could not be rolled back, left modified and unsaved: " .. table.concat(stuck, ", "))
        or "; reference edits rolled back")
    end
    error(msg, 0)
  end
  local extras = {}
  if applied then
    local files
    files, extras = save_workspace_edit(ctx, applied)
    edit_note = string.format("; server updated %d reference file%s:\n%s",
      #files, #files == 1 and "" or "s", table.concat(files, "\n"))
  end

  if mover then
    local ok_s2, supports_did = pcall(function()
      return mover:supports_method("workspace/didRenameFiles")
    end)
    if ok_s2 and supports_did then
      pcall(function()
        mover:notify("workspace/didRenameFiles", {
          files = { { oldUri = vim.uri_from_fname(from_full), newUri = vim.uri_from_fname(to_full) } },
        })
      end)
    end
  end

  return with_extras(string.format("moved %s -> %s%s", relname(from_full), relname(to_full), edit_note), extras)
end
]==]),
  })

  -- ------------------------------------------------------------ move_files

  define({
    name = "tool.move_files",
    kind = "tool",
    doc = "Bulk version of move_file: move/rename several files in one call."
      .. " The WHOLE batch is validated first (every source exists, every"
      .. " destination is free, no path used as both a source and a"
      .. " destination) and nothing moves if any entry is invalid — a typo"
      .. " in entry 5 of 20 never leaves a partial move. For files with an"
      .. " attached LSP client that supports workspace/willRenameFiles, ALL"
      .. " of that client's files are sent in ONE batched request (not one"
      .. " request per file) and the returned WorkspaceEdit(s) — e.g. import"
      .. " path fixups — are applied through buffers (native undo) before"
      .. " any file moves; workspace/didRenameFiles then notifies each"
      .. " client, batched the same way. Files with no capable client just"
      .. " move plainly, same as move_file. If any move fails, every server"
      .. " reference edit is undone in its buffer, nothing is saved, and the"
      .. " call fails listing what moved and what did not. This is a WRITE tool and prompts"
      .. " for confirmation. Parameters: moves (required) — array of"
      .. " {from, to} objects. Rejects WorkspaceEdit create/rename/delete resource"
      .. " operations, edits to buffers changed during requests, and batches whose"
      .. " returned WorkspaceEdits share a target buffer, even if their ranges differ.",
    input_schema = {
      type = "object",
      properties = {
        moves = {
          type = "array",
          description = "Files to move: [{from, to}, ...].",
          items = {
            type = "object",
            properties = {
              from = { type = "string", description = "Existing file path." },
              to = { type = "string", description = "Destination path (parent dirs created)." },
            },
            required = { "from", "to" },
          },
        },
      },
      required = { "moves" },
    },
    source = src([==[
return function(input, ctx)
  local moves = input.moves
  if type(moves) ~= "table" or #moves == 0 then
    error("move_files: moves must be a non-empty array of {from, to}", 0)
  end

  -- Validate the WHOLE batch before touching disk: collect every problem
  -- rather than stopping at the first, so one tool call surfaces all of them.
  local entries, problems = {}, {}
  local from_seen, to_seen = {}, {}
  for i, m in ipairs(moves) do
    if type(m) ~= "table" or type(m.from) ~= "string" or m.from == ""
      or type(m.to) ~= "string" or m.to == "" then
      problems[#problems + 1] = ("#%d: needs from and to"):format(i)
    else
      local from_full = vim.fn.fnamemodify(m.from, ":p")
      local to_full = vim.fn.fnamemodify(m.to, ":p")
      if from_full == to_full then
        problems[#problems + 1] = ("#%d: from and to are the same path (%s)"):format(i, relname(from_full))
      elseif vim.fn.filereadable(from_full) ~= 1 then
        problems[#problems + 1] = ("#%d: no such file: %s"):format(i, relname(from_full))
      elseif vim.fn.filereadable(to_full) == 1 then
        problems[#problems + 1] = ("#%d: destination already exists: %s"):format(i, relname(to_full))
      elseif from_seen[from_full] then
        problems[#problems + 1] = ("#%d: %s is moved twice in this batch"):format(i, relname(from_full))
      elseif to_seen[to_full] then
        problems[#problems + 1] = ("#%d: two entries target %s"):format(i, relname(to_full))
      else
        from_seen[from_full], to_seen[to_full] = true, true
        entries[#entries + 1] = { from = from_full, to = to_full }
      end
    end
  end
  if #problems > 0 then
    error("move_files: refusing the whole batch — fix these and retry:\n"
      .. table.concat(problems, "\n"), 0)
  end

  -- Bucket entries by the one client (per filetype, cached — files sharing a
  -- filetype share the same attached clients) that supports willRenameFiles,
  -- so each capable server gets ONE request covering all its files, not one
  -- request per file. Entries with no capable client just move plainly.
  local ft_clients = {}
  local buckets, bucket_order = {}, {}
  for _, e in ipairs(entries) do
    e.buf = load_buf(e.from, "move_files")
    local ft = vim.bo[e.buf].filetype or ""
    if ft_clients[ft] == nil then
      ft_clients[ft] = wait_clients(ctx, e.buf) or false
    end
    local mover
    for _, c in ipairs(ft_clients[ft] or {}) do
      local ok_s, supports = pcall(function() return c:supports_method("workspace/willRenameFiles") end)
      if ok_s and supports then mover = c; break end
    end
    if mover then
      if not buckets[mover.id] then
        buckets[mover.id] = { client = mover, entries = {} }
        bucket_order[#bucket_order + 1] = mover.id
      end
      table.insert(buckets[mover.id].entries, e)
    end
  end

  local versions = buffer_versions()
  local pending = {}
  local notes = {}
  local applied_all = {}
  local function rollback_all()
    local stuck = {}
    for i = #applied_all, 1, -1 do vim.list_extend(stuck, rollback_workspace_edit(applied_all[i])) end
    return stuck
  end

  for _, id in ipairs(bucket_order) do
    local bucket = buckets[id]
    local files_param = {}
    for _, e in ipairs(bucket.entries) do
      files_param[#files_param + 1] =
        { oldUri = vim.uri_from_fname(e.from), newUri = vim.uri_from_fname(e.to) }
    end
    local result, err = client_request(ctx, bucket.client, "workspace/willRenameFiles",
      { files = files_param }, bucket.entries[1].buf, 8000)
    if result and type(result) == "table" and (result.changes or result.documentChanges) then
      pending[#pending + 1] = { edit = result, encoding = bucket.client.offset_encoding }
    elseif err then
      notes[#notes + 1] = bucket.client.name .. ": willRenameFiles " .. tostring(err) .. " (moved anyway)"
    end
  end

  validate_workspace_edits(ctx, "move_files", pending, versions)
  for _, p in ipairs(pending) do
    local okap, applied = pcall(apply_workspace_edit, ctx, "move_files", p.edit, p.encoding)
    if not okap then
      local stuck = rollback_all()
      error(tostring(applied) .. (#stuck > 0 and ("; rollback failed: " .. table.concat(stuck, ", ")) or ""), 0)
    end
    applied_all[#applied_all + 1] = applied
  end

  local moved, failed = {}, {}
  for _, e in ipairs(entries) do
    local ok_rn, rn_err = pcall(vim.lsp.util.rename, e.from, e.to, {})
    if ok_rn and (vim.fn.filereadable(e.to) ~= 1 or vim.fn.filereadable(e.from) == 1) then
      ok_rn, rn_err = false, "file was not moved"
    end
    if ok_rn then
      moved[#moved + 1] = string.format("%s -> %s", relname(e.from), relname(e.to))
    else
      failed[#failed + 1] = string.format("%s -> %s: %s", relname(e.from), relname(e.to), tostring(rn_err))
    end
  end

  for _, id in ipairs(bucket_order) do
    local bucket = buckets[id]
    local ok_s, supports_did = pcall(function() return bucket.client:supports_method("workspace/didRenameFiles") end)
    if ok_s and supports_did then
      local files_param = {}
      for _, e in ipairs(bucket.entries) do
        if vim.fn.filereadable(e.to) == 1 then
          files_param[#files_param + 1] =
            { oldUri = vim.uri_from_fname(e.from), newUri = vim.uri_from_fname(e.to) }
        end
      end
      if #files_param > 0 then
        pcall(function() bucket.client:notify("workspace/didRenameFiles", { files = files_param }) end)
      end
    end
  end

  local out = { string.format("moved %d file%s:", #moved, #moved == 1 and "" or "s") }
  vim.list_extend(out, moved)
  if #failed > 0 then
    out[#out + 1] = string.format("%d move%s FAILED:", #failed, #failed == 1 and "" or "s")
    vim.list_extend(out, failed)
    if #applied_all > 0 then
      local stuck = rollback_all()
      out[#out + 1] = #stuck > 0
        and ("server reference edits could not be rolled back, left modified and unsaved: " .. table.concat(stuck, ", "))
        or "server reference edits rolled back (none saved); fix references for the moved files by hand"
    end
    vim.list_extend(out, notes)
    error("move_files: " .. table.concat(out, "\n"), 0)
  end
  local server_files, seen_file, extras = {}, {}, {}
  for _, a in ipairs(applied_all) do
    local files, ex = save_workspace_edit(ctx, a)
    for _, f in ipairs(files) do
      if not seen_file[f] then seen_file[f] = true; server_files[#server_files + 1] = f end
    end
    vim.list_extend(extras, ex)
  end
  if #server_files > 0 then
    out[#out + 1] = string.format("server updated %d reference file%s:", #server_files, #server_files == 1 and "" or "s")
    vim.list_extend(out, server_files)
  end
  vim.list_extend(out, notes)
  return with_extras(table.concat(out, "\n"), extras)
end
]==]),
  })

  -- ----------------------------------------------------------- delete_file

  define({
    name = "tool.delete_file",
    kind = "tool",
    doc = "Delete a file from disk. UNLIKE write_file/edit_file/move_file,"
      .. " this is NOT undo-tree reversible — there is no buffer undo for"
      .. " 'the file is gone'; recovery is whatever the user's own backup or"
      .. " VCS provides. Refuses if the file's buffer has unsaved changes"
      .. " (delete that file's buffer or write it first) rather than"
      .. " silently discarding them. If a language server is attached and"
      .. " supports workspace/willDeleteFiles, it is asked FIRST for a"
      .. " WorkspaceEdit (e.g. removing now-dangling imports elsewhere) —"
      .. " applied through buffers (native undo) before the file itself is"
      .. " removed; workspace/didDeleteFiles notifies the server afterward."
      .. " No attached/capable server: a plain filesystem delete. If the"
      .. " delete fails, the server's reference edits are undone in their"
      .. " buffers and nothing is saved. Any loaded buffer on the file is wiped"
      .. " after deletion; windows showing it switch to the alternate buffer"
      .. " (or an empty one) instead of closing."
      .. " This is a WRITE tool and prompts for confirmation. Parameters:"
      .. " path (required, existing file). Rejects WorkspaceEdit create/rename/delete"
      .. " resource operations and edits to buffers changed during requests.",
    input_schema = {
      type = "object",
      properties = {
        path = { type = "string", description = "Existing file path to delete." },
      },
      required = { "path" },
    },
    source = src([==[
return function(input, ctx)
  local path = input.path
  if type(path) ~= "string" or path == "" then error("delete_file: path is required", 0) end

  local full = vim.fn.fnamemodify(path, ":p")
  if vim.fn.filereadable(full) ~= 1 then
    error("delete_file: no such file: " .. relname(full), 0)
  end

  local existing_buf = find_buf(full)
  if existing_buf and vim.api.nvim_buf_is_loaded(existing_buf)
    and vim.bo[existing_buf].modified then
    error("delete_file: refusing — " .. relname(full)
      .. " has unsaved buffer changes (write or discard them first)", 0)
  end

  local buf = load_buf(full, "delete_file")
  local targets = { { path = full, buf = buf, tick = vim.api.nvim_buf_get_changedtick(buf) } }
  local clients = wait_clients(ctx, buf)
  local deleter
  for _, c in ipairs(clients or {}) do
    local ok_s, supports = pcall(function() return c:supports_method("workspace/willDeleteFiles") end)
    if ok_s and supports then deleter = c; break end
  end

  local edit_note = ""
  local applied
  if deleter then
    local params = { files = { { uri = vim.uri_from_fname(full) } } }
    local versions = buffer_versions()
    local result, err = client_request(ctx, deleter, "workspace/willDeleteFiles", params, buf, 8000)
    if result and type(result) == "table" and (result.changes or result.documentChanges) then
      validate_workspace_edits(ctx, "delete_file", { { edit = result } }, versions)
      applied = apply_workspace_edit(ctx, "delete_file", result, deleter.offset_encoding)
    elseif err then
      edit_note = "; willDeleteFiles request " .. tostring(err) .. " (deleted anyway)"
    end
  end

  local valid, validation_err = pcall(validate_delete_targets, ctx, "delete_file", targets)
  if not valid then
    local stuck = applied and rollback_workspace_edit(applied) or {}
    error(tostring(validation_err) .. (#stuck > 0 and ("; rollback failed: " .. table.concat(stuck, ", ")) or ""), 0)
  end
  local ok_rm, succ, rm_err = pcall(os.remove, full)
  if not ok_rm or succ ~= true then
    local msg = "delete_file: failed to delete: " .. tostring((not ok_rm and succ) or rm_err or "unknown error")
    if applied then
      local stuck = rollback_workspace_edit(applied)
      msg = msg .. (#stuck > 0
        and ("; reference edits could not be rolled back, left modified and unsaved: " .. table.concat(stuck, ", "))
        or "; reference edits rolled back")
    end
    error(msg, 0)
  end
  local extras = {}
  if applied then
    local files
    files, extras = save_workspace_edit(ctx, applied)
    edit_note = string.format("; server updated %d reference file%s:\n%s",
      #files, #files == 1 and "" or "s", table.concat(files, "\n"))
  end

  wipe_buf_keep_windows(buf)

  if deleter then
    local ok_s2, supports_did = pcall(function() return deleter:supports_method("workspace/didDeleteFiles") end)
    if ok_s2 and supports_did then
      pcall(function()
        deleter:notify("workspace/didDeleteFiles", { files = { { uri = vim.uri_from_fname(full) } } })
      end)
    end
  end

  return with_extras(string.format("deleted %s (not undo-tree reversible)%s", relname(full), edit_note), extras)
end
]==]),
  })

  -- ---------------------------------------------------------- delete_files

  define({
    name = "tool.delete_files",
    kind = "tool",
    doc = "Bulk version of delete_file: delete several files in one call."
      .. " UNLIKE write_file/edit_file/move_file, deletion is NOT undo-tree"
      .. " reversible. The WHOLE batch is validated first (every path"
      .. " exists, no duplicates, no unsaved buffer changes on any of them)"
      .. " and nothing is deleted if any entry is invalid. For files with an"
      .. " attached LSP client that supports workspace/willDeleteFiles, ALL"
      .. " of that client's files are sent in ONE batched request (not one"
      .. " per file) and the returned WorkspaceEdit(s) are applied through"
      .. " buffers (native undo) before any file is removed;"
      .. " workspace/didDeleteFiles then notifies each client, also batched."
      .. " If any delete fails, every server reference edit is undone in its"
      .. " buffer, nothing is saved, and the call fails listing what was and"
      .. " was not deleted. Windows showing a deleted file switch to the"
      .. " alternate buffer (or an empty one) instead of closing."
      .. " This is a WRITE tool and prompts for confirmation. Parameters:"
      .. " paths (required) — array of existing file paths. Rejects WorkspaceEdit"
      .. " create/rename/delete resource operations, edits to buffers changed during requests,"
      .. " and batches whose returned WorkspaceEdits share a target buffer, even if their ranges differ.",
    input_schema = {
      type = "object",
      properties = {
        paths = {
          type = "array",
          description = "Existing file paths to delete.",
          items = { type = "string" },
        },
      },
      required = { "paths" },
    },
    source = src([==[
return function(input, ctx)
  local paths = input.paths
  if type(paths) ~= "table" or #paths == 0 then
    error("delete_files: paths must be a non-empty array of file paths", 0)
  end

  -- Validate the WHOLE batch before touching disk, collecting every problem.
  local entries, problems, seen = {}, {}, {}
  for i, p in ipairs(paths) do
    if type(p) ~= "string" or p == "" then
      problems[#problems + 1] = ("#%d: not a valid path"):format(i)
    else
      local full = vim.fn.fnamemodify(p, ":p")
      if seen[full] then
        problems[#problems + 1] = ("#%d: %s is listed twice"):format(i, relname(full))
      elseif vim.fn.filereadable(full) ~= 1 then
        problems[#problems + 1] = ("#%d: no such file: %s"):format(i, relname(full))
      else
        local existing_buf = find_buf(full)
        if existing_buf and vim.api.nvim_buf_is_loaded(existing_buf)
          and vim.bo[existing_buf].modified then
          problems[#problems + 1] = ("#%d: %s has unsaved buffer changes"):format(i, relname(full))
        else
          seen[full] = true
          entries[#entries + 1] = { path = full }
        end
      end
    end
  end
  if #problems > 0 then
    error("delete_files: refusing the whole batch — fix these and retry:\n"
      .. table.concat(problems, "\n"), 0)
  end

  -- Bucket by the one client (per filetype) that supports willDeleteFiles,
  -- so each capable server gets ONE request covering all its files.
  local ft_clients = {}
  local buckets, bucket_order = {}, {}
  for _, e in ipairs(entries) do
    e.buf = load_buf(e.path, "delete_files")
    e.tick = vim.api.nvim_buf_get_changedtick(e.buf)
    local ft = vim.bo[e.buf].filetype or ""
    if ft_clients[ft] == nil then
      ft_clients[ft] = wait_clients(ctx, e.buf) or false
    end
    local deleter
    for _, c in ipairs(ft_clients[ft] or {}) do
      local ok_s, supports = pcall(function() return c:supports_method("workspace/willDeleteFiles") end)
      if ok_s and supports then deleter = c; break end
    end
    if deleter then
      if not buckets[deleter.id] then
        buckets[deleter.id] = { client = deleter, entries = {} }
        bucket_order[#bucket_order + 1] = deleter.id
      end
      table.insert(buckets[deleter.id].entries, e)
    end
  end

  local versions = buffer_versions()
  local pending = {}
  local notes = {}
  local applied_all = {}
  local function rollback_all()
    local stuck = {}
    for i = #applied_all, 1, -1 do vim.list_extend(stuck, rollback_workspace_edit(applied_all[i])) end
    return stuck
  end

  for _, id in ipairs(bucket_order) do
    local bucket = buckets[id]
    local files_param = {}
    for _, e in ipairs(bucket.entries) do
      files_param[#files_param + 1] = { uri = vim.uri_from_fname(e.path) }
    end
    local result, err = client_request(ctx, bucket.client, "workspace/willDeleteFiles",
      { files = files_param }, bucket.entries[1].buf, 8000)
    if result and type(result) == "table" and (result.changes or result.documentChanges) then
      pending[#pending + 1] = { edit = result, encoding = bucket.client.offset_encoding }
    elseif err then
      notes[#notes + 1] = bucket.client.name .. ": willDeleteFiles " .. tostring(err) .. " (deleted anyway)"
    end
  end

  validate_workspace_edits(ctx, "delete_files", pending, versions)
  validate_delete_targets(ctx, "delete_files", entries)
  for _, p in ipairs(pending) do
    local okap, applied = pcall(apply_workspace_edit, ctx, "delete_files", p.edit, p.encoding)
    if not okap then
      local stuck = rollback_all()
      error(tostring(applied) .. (#stuck > 0 and ("; rollback failed: " .. table.concat(stuck, ", ")) or ""), 0)
    end
    applied_all[#applied_all + 1] = applied
  end
  local valid, validation_err = pcall(validate_delete_targets, ctx, "delete_files", entries)
  if not valid then
    local stuck = rollback_all()
    error(tostring(validation_err) .. (#stuck > 0 and ("; rollback failed: " .. table.concat(stuck, ", ")) or ""), 0)
  end

  local deleted, failed = {}, {}
  for _, e in ipairs(entries) do
    local ok_rm, succ, rm_err = pcall(os.remove, e.path)
    if ok_rm and succ == true then
      deleted[#deleted + 1] = relname(e.path)
      wipe_buf_keep_windows(e.buf)
    else
      failed[#failed + 1] = relname(e.path) .. ": "
        .. tostring((not ok_rm and succ) or rm_err or "unknown error")
    end
  end

  for _, id in ipairs(bucket_order) do
    local bucket = buckets[id]
    local ok_s, supports_did = pcall(function() return bucket.client:supports_method("workspace/didDeleteFiles") end)
    if ok_s and supports_did then
      local files_param = {}
      for _, e in ipairs(bucket.entries) do
        if vim.fn.filereadable(e.path) ~= 1 then
          files_param[#files_param + 1] = { uri = vim.uri_from_fname(e.path) }
        end
      end
      if #files_param > 0 then
        pcall(function() bucket.client:notify("workspace/didDeleteFiles", { files = files_param }) end)
      end
    end
  end

  local out = { string.format("deleted %d file%s (not undo-tree reversible):",
    #deleted, #deleted == 1 and "" or "s") }
  vim.list_extend(out, deleted)
  if #failed > 0 then
    out[#out + 1] = string.format("%d delete%s FAILED:", #failed, #failed == 1 and "" or "s")
    vim.list_extend(out, failed)
    if #applied_all > 0 then
      local stuck = rollback_all()
      out[#out + 1] = #stuck > 0
        and ("server reference edits could not be rolled back, left modified and unsaved: " .. table.concat(stuck, ", "))
        or "server reference edits rolled back (none saved); fix references to the deleted files by hand"
    end
    vim.list_extend(out, notes)
    error("delete_files: " .. table.concat(out, "\n"), 0)
  end
  local server_files, seen_file, extras = {}, {}, {}
  for _, a in ipairs(applied_all) do
    local files, ex = save_workspace_edit(ctx, a)
    for _, f in ipairs(files) do
      if not seen_file[f] then seen_file[f] = true; server_files[#server_files + 1] = f end
    end
    vim.list_extend(extras, ex)
  end
  if #server_files > 0 then
    out[#out + 1] = string.format("server updated %d reference file%s:", #server_files, #server_files == 1 and "" or "s")
    vim.list_extend(out, server_files)
  end
  vim.list_extend(out, notes)
  return with_extras(table.concat(out, "\n"), extras)
end
]==]),
  })

  -- -------------------------------------------------------------- code_action

  define({
    name = "tool.code_action",
    kind = "tool",
    doc = "LSP code actions (quick-fixes, auto-imports, refactors) at a"
      .. " position. Without index: LIST the available actions, numbered — this"
      .. " is read-only and auto-allowed. With index=N: APPLY the Nth action"
      .. " from that same listing (resolving it with the server if needed);"
      .. " applying is a write, goes through confirm, edits land in each"
      .. " buffer's native undo history, and touched files are saved. Pairs"
      .. " with the diagnostics tool: read the diagnostic, apply its suggested"
      .. " fix. Parameters: path (required); line (required, 1-based); col"
      .. " (required, 1-based); index (optional) — apply the Nth listed action."
      .. " Rejects WorkspaceEdit create/rename/delete resource operations and edits"
      .. " to buffers changed during requests or resolution.",
    input_schema = {
      type = "object",
      properties = {
        path = { type = "string", description = "File to get actions for." },
        line = { type = "integer", description = "1-based line." },
        col = { type = "integer", description = "1-based column." },
        index = { type = "integer", description = "Apply the Nth action from the listing (omit to list)." },
      },
      required = { "path", "line", "col" },
    },
    source = src([==[
return function(input, ctx)
  local buf, ft = load_buf(input.path, "code_action")
  local line0 = math.max(0, (tonumber(input.line) or 1) - 1)
  local col0 = math.max(0, (tonumber(input.col) or 1) - 1)
  local diags = {}
  pcall(function()
    for _, d in ipairs(vim.diagnostic.get(buf, { lnum = line0 })) do
      local lsp = d.user_data and d.user_data.lsp
      if lsp then diags[#diags + 1] = lsp end
    end
  end)
  local params = function(client)
    local pos = { line = line0, character = byte_to_lsp_char(buf, line0, col0, client and client.offset_encoding) }
    return {
      textDocument = { uri = vim.uri_from_bufnr(buf) },
      range = { start = pos, ["end"] = pos },
      context = { diagnostics = diags },
    }
  end
  local versions = buffer_versions()
  local ok, res, err = pcall(lsp_request, ctx, buf, "textDocument/codeAction", params, 5000)
  if not ok then error("code_action: " .. tostring(res), 0) end
  if err == "noclient" then no_client("code_action", ft) end
  if err == "timeout" then error("code_action: LSP request timed out", 0) end

  -- Flatten per-client results, keeping the owning client for apply/resolve.
  -- Stable order: sort client ids so index=N means the same action across the
  -- list call and the apply call.
  local cids = {}
  for cid in pairs(res or {}) do cids[#cids + 1] = cid end
  table.sort(cids)
  local actions = {}
  for _, cid in ipairs(cids) do
    local result = result_of(res[cid])
    for _, a in ipairs(type(result) == "table" and result or {}) do
      actions[#actions + 1] = { action = a, client_id = cid }
    end
  end
  if #actions == 0 then return "no code actions available at that position" end

  local index = tonumber(input.index)
  if not index then
    local lines = {}
    for i, entry in ipairs(actions) do
      local a = entry.action
      lines[#lines + 1] = string.format("%d. %s%s", i, a.title or "?",
        a.kind and ("  [" .. a.kind .. "]") or "")
    end
    lines[#lines + 1] = "(call again with index=N to apply one)"
    return table.concat(lines, "\n")
  end

  local entry = actions[index]
  if not entry then
    error(string.format("code_action: index %d out of range (1-%d)", index, #actions), 0)
  end
  local action = entry.action
  local client = vim.lsp.get_client_by_id(entry.client_id)
  if client and not action.edit and not action.command then
    local resolved = client_request(ctx, client, "codeAction/resolve", action, buf, 5000)
    if type(resolved) == "table" then action = resolved end
  end

  local did, extras = {}, {}
  if type(action.edit) == "table" then
    validate_workspace_edits(ctx, "code_action", { { edit = action.edit } }, versions)
    local applied = apply_workspace_edit(ctx, "code_action", action.edit, client and client.offset_encoding)
    local files
    files, extras = save_workspace_edit(ctx, applied)
    did[#did + 1] = "edited " .. table.concat(files, ", ")
  end
  local cmd = action.command
  if type(cmd) == "string" then cmd = { command = cmd } end
  if type(cmd) == "table" and cmd.command and client then
    local _, cerr = client_request(ctx, client, "workspace/executeCommand",
      { command = cmd.command, arguments = cmd.arguments }, buf, 5000)
    did[#did + 1] = cerr
      and ("command " .. cmd.command .. " failed: " .. cerr)
      or ("ran command " .. cmd.command)
  end
  if #did == 0 then error("code_action: action had no edit or command to apply", 0) end
  return with_extras(string.format("applied %q: %s — undo with u in each edited buffer",
    action.title or "?", table.concat(did, "; ")), extras)
end
]==]),
  })

  -- ------------------------------------------------------------------- format

  define({
    name = "tool.format",
    kind = "tool",
    doc = "Format a file (or a line range of it) with the attached LSP"
      .. " server's formatter (textDocument/formatting or rangeFormatting,"
      .. " async), through the file's buffer — the result lands in"
      .. " native undo history (`u` reverts) and the file is saved. Fails when"
      .. " the file changed under this session (another agent or external"
      .. " process). hook.after_write fires. This is a"
      .. " WRITE tool and prompts for confirmation. Parameters: path"
      .. " (required); start_line / end_line (optional, 1-based, both or"
      .. " neither; one without the other is an error) — format only this range.",
    input_schema = {
      type = "object",
      properties = {
        path = { type = "string", description = "File to format." },
        start_line = { type = "integer", description = "1-based first line of the range." },
        end_line = { type = "integer", description = "1-based last line of the range." },
      },
      required = { "path" },
    },
    source = src([==[
return function(input, ctx)
  local sl, el = tonumber(input.start_line), tonumber(input.end_line)
  if (sl == nil) ~= (el == nil) then
    error("format: pass both start_line and end_line, or neither", 0)
  end
  local buf, ft = load_buf(input.path, "format")
  if sl then
    local n = vim.api.nvim_buf_line_count(buf)
    if sl < 1 or el < sl or el > n then
      error(string.format("format: invalid range L%d-%d (file has %d lines)", sl, el, n), 0)
    end
  end
  local method = sl and "textDocument/rangeFormatting" or "textDocument/formatting"
  local clients = wait_clients(ctx, buf)
  if not clients or #clients == 0 then
    no_client("format", ft, " — nothing to format with")
  end
  local client
  for _, c in ipairs(clients) do
    local oks, yes = pcall(function() return c:supports_method(method, buf) end)
    if oks and yes then client = c; break end
  end
  if not client then
    error("format: no attached LSP client supports " .. method, 0)
  end
  check_target_buf(ctx, "format", buf)
  local enc = client.offset_encoding or "utf-16"
  local params = {
    textDocument = { uri = vim.uri_from_bufnr(buf) },
    options = { tabSize = vim.bo[buf].shiftwidth > 0 and vim.bo[buf].shiftwidth or vim.bo[buf].tabstop,
      insertSpaces = vim.bo[buf].expandtab },
  }
  if sl then
    local last = vim.api.nvim_buf_get_lines(buf, el - 1, el, false)[1] or ""
    params.range = {
      start = { line = sl - 1, character = 0 },
      ["end"] = { line = el - 1, character = byte_to_lsp_char(buf, el - 1, #last, enc) },
    }
  end
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local edits, rerr = client_request(ctx, client, method, params, buf, 5000)
  if rerr then error("format: " .. method .. " " .. tostring(rerr), 0) end
  if type(edits) ~= "table" or #edits == 0 then
    return "already formatted (no changes)"
  end
  check_target_buf(ctx, "format", buf)
  if vim.api.nvim_buf_get_changedtick(buf) ~= tick then
    error("format: " .. relname(vim.api.nvim_buf_get_name(buf), buf)
      .. " changed while the formatter ran — retry", 0)
  end
  local ok, err = pcall(function()
    vim.api.nvim_buf_call(buf, function()
      vim.cmd("let &l:undolevels = &l:undolevels")
    end)
    vim.lsp.util.apply_text_edits(edits, buf, enc)
    vim.api.nvim_buf_call(buf, function() vim.cmd("silent noautocmd update") end)
  end)
  if not ok then error("format: " .. tostring(err), 0) end
  if vim.api.nvim_buf_get_changedtick(buf) == tick then
    return "already formatted (no changes)"
  end
  local extras = after_writes(ctx, { buf })
  return with_extras("formatted " .. relname(vim.api.nvim_buf_get_name(buf), buf)
    .. (sl and string.format(" (L%d-%d)", sl, el) or "")
    .. " — undo with u in the buffer", extras)
end
]==]),
  })

  -- ------------------------------------------------------------------ context

  define({
    name = "tool.context",
    kind = "tool",
    doc = "What is the user looking at right now? Reports every window (the"
      .. " focused one first) with its file, cursor position and visible line"
      .. " range; the last visual selection in the user's file (with its text);"
      .. " buffers with unsaved changes; and the alternate file. Call this when"
      .. " the user says 'this', 'here', or otherwise refers to something by"
      .. " their attention rather than by name. Read-only. No parameters.",
    -- No parameters: omit `properties` entirely — an empty Lua {} would
    -- JSON-encode as [] and 400 the whole request (fn.build_tools also
    -- guards against this).
    input_schema = { type = "object" },
    source = src([==[
return function(input, ctx)
  local lines = {}
  local cur_win = vim.api.nvim_get_current_win()
  local wins = vim.api.nvim_list_wins()
  table.sort(wins, function(a, b)
    if a == cur_win then return true end
    if b == cur_win then return false end
    return a < b
  end)
  local attention
  for _, win in ipairs(wins) do
    local b = vim.api.nvim_win_get_buf(win)
    if is_session(b) then
      lines[#lines + 1] = (win == cur_win and "focused " or "")
        .. "window: [straps session buffer]"
    else
      local okc, cur = pcall(vim.api.nvim_win_get_cursor, win)
      cur = okc and cur or { 1, 0 }
      local first = vim.fn.line("w0", win)
      local last = vim.fn.line("w$", win)
      lines[#lines + 1] = string.format("%swindow: %s:%d:%d (visible L%d-%d%s)",
        win == cur_win and "focused " or "",
        relname(vim.api.nvim_buf_get_name(b), b), cur[1], cur[2] + 1, first, last,
        vim.bo[b].modified and ", unsaved changes" or "")
      if not attention then attention = b end
    end
  end
  if attention then
    pcall(function()
      local s = vim.api.nvim_buf_get_mark(attention, "<")
      local e = vim.api.nvim_buf_get_mark(attention, ">")
      if s[1] > 0 and e[1] >= s[1] then
        local sel = vim.api.nvim_buf_get_lines(attention, s[1] - 1, e[1], false)
        local text = table.concat(sel, "\n")
        if #text > 2000 then text = require("straps.state").utf8_cut(text, 2000) .. "..." end
        lines[#lines + 1] = string.format("last visual selection in %s (L%d-%d):\n%s",
          relname(vim.api.nvim_buf_get_name(attention), attention), s[1], e[1], text)
      end
    end)
  end
  local dirty = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].modified
      and vim.api.nvim_buf_get_name(b) ~= "" and not is_session(b) then
      dirty[#dirty + 1] = relname(vim.api.nvim_buf_get_name(b), b)
    end
  end
  if #dirty > 0 then
    lines[#lines + 1] = "unsaved buffers: " .. table.concat(dirty, ", ")
  end
  local alt = vim.fn.expand("#")
  if alt ~= "" then
    lines[#lines + 1] = "alternate file: " .. vim.fn.fnamemodify(alt, ":~:.")
  end
  if #lines == 0 then return "no windows open" end
  return table.concat(lines, "\n")
end
]==]),
  })

  -- ---------------------------------------------------------------- show_user

  define({
    name = "tool.show_user",
    kind = "tool",
    doc = "Point the user's editor at a location: show the file in a"
      .. " non-session window (reusing one that already shows it, else a new"
      .. " split), move that window's cursor there (setting a jumplist entry),"
      .. " center the view, and flash a brief highlight on the line. Keyboard"
      .. " focus stays in the window the user is in, so typing is never"
      .. " redirected. Use it to land"
      .. " the user on the change or finding you want them to see; in that"
      .. " window ctrl-o jumps back. Parameters: path (required); line (optional,"
      .. " 1-based); col (optional, 1-based).",
    input_schema = {
      type = "object",
      properties = {
        path = { type = "string", description = "File to show." },
        line = { type = "integer", description = "1-based line to land on." },
        col = { type = "integer", description = "1-based column to land on." },
      },
      required = { "path" },
    },
    source = src([==[
return function(input, ctx)
  local path = input.path
  if type(path) ~= "string" or path == "" then
    error("show_user: path is required", 0)
  end
  local full = vim.fn.fnamemodify(path, ":p")
  if vim.fn.filereadable(full) == 0 then
    error("show_user: no such file: " .. path, 0)
  end
  local buf = vim.fn.bufadd(full)
  if not pcall(vim.fn.bufload, buf) then
    error("show_user: could not load " .. path, 0)
  end
  local user_win = vim.api.nvim_get_current_win()
  local target
  if vim.api.nvim_win_get_buf(user_win) == buf then target = user_win end
  if not target then
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_get_buf(win) == buf then target = win break end
    end
  end
  local ok, err = pcall(function()
    if not target then
      local anchor = user_win
      if is_session(vim.api.nvim_win_get_buf(user_win)) then
        for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
          if not is_session(vim.api.nvim_win_get_buf(win))
            and vim.api.nvim_win_get_config(win).relative == "" then
            anchor = win
            break
          end
        end
      end
      vim.api.nvim_set_current_win(anchor)
      vim.cmd(anchor == user_win and "botright vsplit" or "aboveleft split")
      target = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(target, buf)
    end
    local line = math.max(1, math.min(tonumber(input.line) or 1, vim.api.nvim_buf_line_count(buf)))
    local col = math.max(0, (tonumber(input.col) or 1) - 1)
    vim.api.nvim_win_call(target, function()
      vim.cmd("normal! m'")
      vim.api.nvim_win_set_cursor(target, { line, col })
      vim.cmd("normal! zz")
    end)
    local ns = vim.api.nvim_create_namespace("straps_show_user")
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    vim.api.nvim_buf_set_extmark(buf, ns, line - 1, 0, {
      end_row = line, hl_group = "Visual", hl_eol = true,
    })
    vim.defer_fn(function()
      pcall(vim.api.nvim_buf_clear_namespace, buf, ns, 0, -1)
    end, 1500)
  end)
  if vim.api.nvim_win_is_valid(user_win) then pcall(vim.api.nvim_set_current_win, user_win) end
  if not ok then error("show_user: " .. tostring(err), 0) end
  return string.format("showing %s:%d to the user",
    vim.fn.fnamemodify(full, ":~:."), tonumber(input.line) or 1)
end
]==]),
  })

  -- -------------------------------------------------------------- help_search

  define({
    name = "tool.help_search",
    kind = "tool",
    doc = "Search Neovim's :help (every doc/tags on the runtimepath, plugins"
      .. " included) by tag substring. Returns the matching tag names plus an"
      .. " excerpt of the best match's help section — use it to look up vim/"
      .. " nvim APIs, options and plugin docs before writing Lua against them."
      .. " Read-only; touches no windows. Parameters: query (required) — tag"
      .. " substring, e.g. 'nvim_buf_set_lines' or 'autocmd'.",
    input_schema = {
      type = "object",
      properties = {
        query = { type = "string", description = "Help tag substring to search for." },
      },
      required = { "query" },
    },
    source = src([==[
return function(input, ctx)
  local query = input.query
  if type(query) ~= "string" or query == "" then
    error("help_search: query is required", 0)
  end
  local lq = query:lower()
  local matches = {} -- { tag, file (absolute), }
  for _, tagsfile in ipairs(vim.api.nvim_get_runtime_file("doc/tags", true)) do
    local dir = vim.fn.fnamemodify(tagsfile, ":h")
    local f = io.open(tagsfile, "r")
    if f then
      for line in f:lines() do
        local tag, file = line:match("^([^\t]+)\t([^\t]+)\t")
        if tag and tag:lower():find(lq, 1, true) then
          matches[#matches + 1] = { tag = tag, file = dir .. "/" .. file }
        end
      end
      f:close()
    end
  end
  if #matches == 0 then return "no help tags match " .. query end
  table.sort(matches, function(a, b)
    -- exact match first, then shorter (more specific) tags
    local ax, bx = a.tag == query, b.tag == query
    if ax ~= bx then return ax end
    if #a.tag ~= #b.tag then return #a.tag < #b.tag end
    return a.tag < b.tag
  end)

  local best = matches[1]
  local excerpt
  local f = io.open(best.file, "r")
  if f then
    local all = {}
    for line in f:lines() do all[#all + 1] = line end
    f:close()
    local anchor = "*" .. best.tag .. "*"
    for i, line in ipairs(all) do
      if line:find(anchor, 1, true) then
        excerpt = table.concat(all, "\n", i, math.min(#all, i + 30))
        break
      end
    end
  end

  local shown = math.min(#matches, 20)
  local names = {}
  for i = 1, shown do names[#names + 1] = matches[i].tag end
  local out = {
    "matching tags: " .. table.concat(names, ", ")
      .. (#matches > shown and (" (+" .. (#matches - shown) .. " more)") or ""),
  }
  if excerpt then
    out[#out + 1] = ""
    out[#out + 1] = ("-- :help %s (%s) --"):format(best.tag, vim.fn.fnamemodify(best.file, ":~:."))
    out[#out + 1] = excerpt
  end
  return table.concat(out, "\n")
end
]==]),
  })

  -- ----------------------------------------------------------------- ask_user

  define({
    name = "tool.ask_user",
    kind = "tool",
    doc = "Ask the user a question INLINE in the session transcript: the"
      .. " question and numbered options render as virtual lines under the"
      .. " last assistant block, so the conversation above stays visible. Use"
      .. " it to propose concrete options — approaches, fixes, names — instead"
      .. " of guessing or asking in prose. Keys in the session window while"
      .. " the question is up: j/k move, <CR> chooses, 1-9 choose by number,"
      .. " o types a free-text answer (vim.ui.input), <Esc> dismisses. An"
      .. " option is a plain string, or a { label, preview, filetype } object"
      .. " when the choice is between competing implementations: put a sketch"
      .. " of what that option's code or outcome looks like in preview, so the"
      .. " user picks between things they can see; the selected option's"
      .. " preview renders live in a split beside the session window. Without"
      .. " options: a free-text vim.ui.input prompt. content (optional) is"
      .. " displayed in a scratch split while the question is up — one"
      .. " proposal shared by the whole question — with optional filetype for"
      .. " highlighting; it closes when the user answers. The run blocks until"
      .. " the user responds; a dismissal is reported as such (do not re-ask"
      .. " the identical question)."
      .. " Parameters: question (required); options (optional array of"
      .. " strings or { label, preview, filetype } objects); content"
      .. " (optional); filetype (optional — highlights content, and is the"
      .. " default filetype for option previews).",
    input_schema = {
      type = "object",
      properties = {
        question = { type = "string", description = "The question to ask the user." },
        options = {
          type = "array",
          items = {
            anyOf = {
              { type = "string" },
              {
                type = "object",
                properties = {
                  label = { type = "string", description = "Option text shown in the question." },
                  preview = {
                    type = "string",
                    description = "Sketch of what choosing this option looks like — code, a diff, a plan.",
                  },
                  filetype = { type = "string", description = "Filetype for highlighting this option's preview." },
                },
                required = { "label" },
              },
            },
          },
          description = "Choices to offer, as strings or { label, preview, filetype } objects;"
            .. " a free-text 'other' answer is always reachable with o.",
        },
        content = { type = "string", description = "Content shown in a scratch split while the question is up." },
        filetype = {
          type = "string",
          description = "Filetype for highlighting the content split; also the default for option previews.",
        },
      },
      required = { "question" },
    },
    source = src([==[
return function(input, ctx)
  local question = input.question
  if type(question) ~= "string" or question == "" then
    error("ask_user: question is required", 0)
  end

  local options, previews = {}, {}
  local default_ft = (type(input.filetype) == "string" and input.filetype ~= "")
    and input.filetype or nil
  if type(input.options) == "table" then
    for _, o in ipairs(input.options) do
      if type(o) == "string" and o ~= "" then
        options[#options + 1] = o
      elseif type(o) == "table" and type(o.label) == "string" and o.label ~= "" then
        options[#options + 1] = o.label
        if type(o.preview) == "string" and o.preview ~= "" then
          local ft = (type(o.filetype) == "string" and o.filetype ~= "")
            and o.filetype or default_ft
          previews[#options] = { text = o.preview, ft = ft }
        end
      end
    end
  end

  local function free_text(prefix)
    local typed = ctx.await(function(resolve)
      local resolved = false
      local function finish(v)
        if resolved then return end
        resolved = true
        resolve(v)
      end
      if type(ctx.on_cancel) == "function" then
        ctx.on_cancel(function() finish(nil) end)
      end
      vim.ui.input({ prompt = question .. " " }, function(text) finish(text) end)
    end)
    if typed == nil or typed == "" then
      return "user dismissed the input without answering — do not re-ask the identical question"
    end
    return "user answered" .. prefix .. ": " .. typed
  end

  if #options == 0 then
    return free_text("")
  end

  local bufnr = ctx.bufnr
  if bufnr == 0 or bufnr == nil then
    bufnr = vim.api.nvim_get_current_buf()
  end
  if not vim.api.nvim_buf_is_valid(bufnr) or not vim.b[bufnr].straps_session then
    error("ask_user: no session buffer", 0)
  end
  local user_win = vim.api.nvim_get_current_win()

  local wins, bufs = {}, {}
  local function capped_lines(text)
    local lines = vim.split(text, "\n", { plain = true })
    if #lines > 200 then
      local capped = {}
      for i = 1, 200 do capped[i] = lines[i] end
      capped[#capped + 1] = ("... (%d more lines)"):format(#lines - 200)
      lines = capped
    end
    return lines
  end
  local function scratch_buf(lines, ft)
    local b = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
    vim.bo[b].bufhidden = "hide"
    if type(ft) == "string" and ft ~= "" then
      pcall(function() vim.bo[b].filetype = ft end)
    end
    bufs[#bufs + 1] = b
    return b
  end

  local win = vim.fn.bufwinid(bufnr)
  if win == -1 then
    vim.cmd("botright split")
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, bufnr)
    wins[#wins + 1] = win
  end
  local function session_win()
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == bufnr then return win end
    local w = vim.fn.bufwinid(bufnr)
    if w ~= -1 then win = w end
    return w ~= -1 and w or nil
  end

  local function anchor_row()
    local blocks = require("straps.state").list_blocks(bufnr)
    local last_assistant
    for _, b in ipairs(blocks) do
      if b.kind == "assistant" then last_assistant = b end
    end
    local n = vim.api.nvim_buf_line_count(bufnr)
    if not last_assistant then return n - 1 end
    local next_marker = n + 1
    for _, b in ipairs(blocks) do
      if b.marker_lnum > last_assistant.marker_lnum and b.marker_lnum < next_marker then
        next_marker = b.marker_lnum
      end
    end
    local lines = vim.api.nvim_buf_get_lines(bufnr, last_assistant.marker_lnum - 1, next_marker - 1, false)
    local i = #lines
    while i > 1 and lines[i]:match("^%s*$") do i = i - 1 end
    return last_assistant.marker_lnum - 1 + i - 1
  end

  if type(input.content) == "string" and input.content ~= "" then
    pcall(function()
      local lines = capped_lines(input.content)
      vim.api.nvim_set_current_win(win)
      vim.cmd("botright " .. math.min(#lines + 1, 15) .. "split")
      local cwin = vim.api.nvim_get_current_win()
      wins[#wins + 1] = cwin
      vim.api.nvim_win_set_buf(cwin, scratch_buf(lines, default_ft))
      vim.wo[cwin].winbar = "ask_user content"
    end)
  end

  local pwin, pbufs = nil, {}
  if next(previews) ~= nil then
    pcall(function()
      vim.api.nvim_set_current_win(win)
      vim.cmd("rightbelow vsplit")
      pwin = vim.api.nvim_get_current_win()
      wins[#wins + 1] = pwin
      for i = 1, #options do
        local p = previews[i]
        pbufs[i] = scratch_buf(p and capped_lines(p.text) or { "(no preview for this option)" },
          p and p.ft or nil)
      end
    end)
  end

  local ns = vim.api.nvim_create_namespace("straps_ask_user")
  local selected = 1
  local HINT = "j/k move · <CR> choose · 1-9 pick · o other · <Esc> dismiss"

  local function build_lines()
    local w = session_win()
    local width = math.max(20, (w and vim.api.nvim_win_get_width(w) or vim.o.columns) - 6)
    local vl = { { { " ", "Normal" } } }
    vl[#vl + 1] = { { "┌ ? ", "DiagnosticInfo" },
      { ("question · %d options"):format(#options), "Title" } }
    for _, l in ipairs(capped_lines(question)) do
      if l == "" then vl[#vl + 1] = { { "│", "DiagnosticInfo" } } end
      while #l > 0 do
        local piece = l:sub(1, width)
        if #l > width then
          local cut = piece:match("^.*()%s") or (width + 1)
          piece = l:sub(1, cut - 1)
        end
        vl[#vl + 1] = { { "│ ", "DiagnosticInfo" }, { piece, "Normal" } }
        l = l:sub(#piece + 1):gsub("^%s+", "")
      end
    end
    vl[#vl + 1] = { { "│", "DiagnosticInfo" } }
    for i, o in ipairs(options) do
      local sel = i == selected
      vl[#vl + 1] = {
        { "│ ", "DiagnosticInfo" },
        { sel and "▸ " or "  ", "DiagnosticOk" },
        { ("%d. "):format(i), sel and "Number" or "Comment" },
        { o, sel and "CursorLineNr" or "Normal" },
        { previews[i] and "  ◧ preview →" or "", "Comment" },
      }
    end
    vl[#vl + 1] = { { "│ ", "DiagnosticInfo" }, { "  o. ", "Comment" },
      { "(other: type your own answer)", "Comment" } }
    vl[#vl + 1] = { { "└ ", "DiagnosticInfo" }, { HINT, "Comment" } }
    return vl
  end

  local function draw()
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    local w = session_win()
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    vim.api.nvim_buf_set_extmark(bufnr, ns, anchor_row(), 0,
      { virt_lines = build_lines(), virt_lines_above = false })
    if pwin and vim.api.nvim_win_is_valid(pwin) and pbufs[selected]
      and vim.api.nvim_buf_is_valid(pbufs[selected]) then
      vim.api.nvim_win_set_buf(pwin, pbufs[selected])
      pcall(function()
        vim.wo[pwin].winbar = ("preview of option %d: %s"):format(selected,
          (options[selected]:gsub("%%", "%%%%")))
      end)
    end
    if w then
      pcall(vim.api.nvim_win_call, w, function()
        vim.api.nvim_win_set_cursor(w, { vim.api.nvim_buf_line_count(bufnr), 0 })
        vim.cmd("normal! zb")
      end)
    end
    vim.cmd("redraw")
  end

  local keys = { "j", "k", "<CR>", "<Esc>", "o", "<Down>", "<Up>" }
  for i = 1, math.min(9, #options) do keys[#keys + 1] = tostring(i) end
  local saved = {}
  vim.api.nvim_buf_call(bufnr, function()
    for _, lhs in ipairs(keys) do
      local m = vim.fn.maparg(lhs, "n", false, true)
      if type(m) == "table" and next(m) and m.buffer == 1 then saved[lhs] = m end
    end
  end)

  local function restore()
    pcall(vim.api.nvim_buf_clear_namespace, bufnr, ns, 0, -1)
    for _, lhs in ipairs(keys) do pcall(vim.keymap.del, "n", lhs, { buffer = bufnr }) end
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_call(bufnr, function()
        for _, m in pairs(saved) do pcall(vim.fn.mapset, "n", false, m) end
      end)
    end
    for _, w in ipairs(wins) do pcall(vim.api.nvim_win_close, w, true) end
    for _, b in ipairs(bufs) do pcall(vim.api.nvim_buf_delete, b, { force = true }) end
    if vim.api.nvim_win_is_valid(user_win) then pcall(vim.api.nvim_set_current_win, user_win) end
  end

  local ok_wait, res = pcall(ctx.await, function(resolve)
    local resolved = false
    local function finish(v)
      if resolved then return end
      resolved = true
      resolve(v)
    end
    local function map(lhs, fn)
      vim.keymap.set("n", lhs, function()
        local ok, err = pcall(fn)
        if not ok then
          vim.notify("ask_user: " .. tostring(err), vim.log.levels.ERROR)
        end
      end, { buffer = bufnr, nowait = true, desc = "straps: ask_user" })
    end
    local function move(d)
      selected = ((selected - 1 + d) % #options) + 1
      draw()
    end
    map("j", function() move(1) end)
    map("<Down>", function() move(1) end)
    map("k", function() move(-1) end)
    map("<Up>", function() move(-1) end)
    map("<CR>", function() finish({ idx = selected }) end)
    map("<Esc>", function() finish({ dismissed = true }) end)
    map("o", function() finish({ other = true }) end)
    for i = 1, math.min(9, #options) do
      map(tostring(i), function() finish({ idx = i }) end)
    end
    if type(ctx.on_cancel) == "function" then
      ctx.on_cancel(function() finish({ dismissed = true }) end)
    end
    pcall(vim.api.nvim_set_current_win, win)
    local ok_draw, err = pcall(draw)
    if not ok_draw then
      vim.notify("ask_user: " .. tostring(err), vim.log.levels.ERROR)
    end
  end)

  restore()
  if not ok_wait then error(res, 0) end
  if type(res) ~= "table" or res.dismissed then
    return "user dismissed the question without choosing — proceed on your best judgment or ask differently"
  end
  if res.other then
    return free_text(" (free text)")
  end
  return string.format("user chose option %d: %s", res.idx, options[res.idx])
end
]==]),
  })

  -- ---------------------------------------------------------------- undo_edit

  define({
    name = "tool.undo_edit",
    kind = "tool",
    doc = "Surgically undo changes in a file through Vim's native undo tree —"
      .. " no git/jj involved. Every straps edit is its own undo block, so a"
      .. " single edit reverts cleanly; and because the tree is read back from"
      .. " disk when a buffer loads (when the user has 'undofile' enabled),"
      .. " edits made by a PREVIOUS session are still revertible even though"
      .. " you have no memory of making them. Modes: history=true lists the"
      .. " undo states (seq, timestamp, saved/current markers; indented"
      .. " entries are branches) — read-only and auto-allowed; steps=N rewinds"
      .. " N changes (default 1); to_seq=N jumps to the exact state N — which"
      .. " is also how you REDO: jump forward to the seq the undo result"
      .. " reported; revert_seq=N surgically reverses JUST edit N while"
      .. " keeping every later edit applied (git-revert semantics on an undo"
      .. " block: strict patch, refuses with a conflict message if later"
      .. " changes overlap it). Write modes (steps, to_seq, revert_seq) refuse"
      .. " when the buffer has unsaved user changes, when the file changed on disk or a"
      .. " sibling session edited the buffer — re-inspect history before"
      .. " rewinding. After any change the buffer is saved to disk."
      .. " Parameters: path (required); history (optional boolean); steps"
      .. " (optional); to_seq (optional); revert_seq (optional).",
    input_schema = {
      type = "object",
      properties = {
        path = { type = "string", description = "File whose undo tree to inspect or rewind." },
        history = { type = "boolean", description = "List the undo states instead of undoing." },
        steps = { type = "integer", description = "Rewind this many changes (default 1)." },
        to_seq = { type = "integer", description = "Jump to this exact undo state (enables redo)." },
        revert_seq = { type = "integer", description = "Surgically revert just this edit, keeping later edits." },
      },
      required = { "path" },
    },
    source = src([==[
return function(input, ctx)
  local buf = load_buf(input.path, "undo_edit")
  local name = relname(vim.api.nvim_buf_get_name(buf), buf)

  local function tree()
    local t
    vim.api.nvim_buf_call(buf, function() t = vim.fn.undotree() end)
    return type(t) == "table" and t or { entries = {}, seq_cur = 0 }
  end

  if input.history then
    local t = tree()
    local lines = {}
    local function walk(entries, depth)
      for _, e in ipairs(entries or {}) do
        local marks = {}
        if e.seq == t.seq_cur then marks[#marks + 1] = "current" end
        if e.save then marks[#marks + 1] = "saved" end
        lines[#lines + 1] = string.format("%sseq %d  %s%s",
          string.rep("  ", depth), e.seq,
          os.date("%Y-%m-%d %H:%M:%S", e.time),
          #marks > 0 and ("  [" .. table.concat(marks, ", ") .. "]") or "")
        if e.alt then walk(e.alt, depth + 1) end
      end
    end
    walk(t.entries, 0)
    if #lines == 0 then
      return name .. ": no undo history in this Neovim session"
        .. " (the user can set 'undofile' to persist history across sessions)"
    end
    table.insert(lines, 1, string.format(
      "%s: undo states (current: seq %d; seq 0 is the state the buffer was loaded with):",
      name, t.seq_cur))
    lines[#lines + 1] = "(to_seq=N jumps to a state; revert_seq=N surgically reverts just that edit)"
    return table.concat(lines, "\n")
  end

  -- Concurrent-editor checks (write modes only — listing history above stays
  -- read-only under a conflict). no_reload always: a reload would mutate the
  -- very undo tree this tool navigates, and error-first semantics mean there
  -- is nothing to reload for.
  local registry = require("straps.registry")
  local st, rerr = registry.call("fn.reconcile_buf", buf, { no_reload = true })
  if st == nil then
    error("undo_edit: " .. name .. " " .. tostring(rerr) .. " — another agent or external"
      .. " process is editing this file; its undo tree does not include that change", 0)
  end
  local wok, werr = registry.call("fn.check_writer", ctx and ctx.bufnr, buf)
  if wok == nil then
    local stamp = vim.b[buf].straps_last_writer
    local who = "session " .. tostring(type(stamp) == "table" and stamp.session or "?")
    if type(stamp) == "table" and type(stamp.task) == "string" and stamp.task ~= "" then
      who = who .. ', task: "' .. stamp.task .. '"'
    end
    error("undo_edit: " .. name .. ": another session (" .. who .. ") has edited this buffer"
      .. " since this session last read it — its states are in the undo tree;"
      .. " re-read the file and re-inspect history=true before rewinding", 0)
  end

  if vim.bo[buf].modified then
    error("undo_edit: " .. name .. ": buffer has unsaved changes — undoing would"
      .. " discard or interleave with them and then save; save or discard them first", 0)
  end

  -- revert_seq: surgically reverse ONE undo block, keeping later edits.
  -- Capture the states around seq N (transient in-memory undo round-trip),
  -- diff them into inverse hunks, and apply those hunks to the CURRENT text
  -- as a strict patch — any hunk that cannot be located uniquely is a
  -- conflict and nothing is changed.
  if input.revert_seq ~= nil then
    local seq = tonumber(input.revert_seq)
    if not seq or seq < 1 then
      error("undo_edit: revert_seq must be a positive undo sequence number", 0)
    end
    seq = math.floor(seq)
    local t = tree()
    local cur_seq = t.seq_cur
    local found = false
    local function find(entries)
      for _, e in ipairs(entries or {}) do
        if e.seq == seq then found = true; return end
        if e.alt then find(e.alt) end
      end
    end
    find(t.entries)
    if not found then
      error(string.format("undo_edit: %s: no undo state with seq %d (history=true lists them)", name, seq), 0)
    end

    -- Snapshot: current text, text after edit N, text before edit N (its
    -- parent state — one step earlier from N, correct across branches).
    local text_cur, text_after, text_before
    local okc, cerr = pcall(function()
      vim.api.nvim_buf_call(buf, function()
        local function grab()
          return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
        end
        text_cur = grab()
        vim.cmd("silent undo " .. seq)
        text_after = grab()
        vim.cmd("silent earlier 1")
        text_before = grab()
        vim.cmd("silent undo " .. cur_seq)
      end)
    end)
    local restored = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    if restored ~= text_cur then
      error(string.format(
        "undo_edit: %s: internal error capturing undo states — restore the buffer with to_seq=%d",
        name, cur_seq), 0)
    end
    if not okc then
      error("undo_edit: could not capture undo states: " .. tostring(cerr), 0)
    end

    local after_lines = vim.split(text_after, "\n", { plain = true })
    local before_lines = vim.split(text_before, "\n", { plain = true })
    local cur_lines = vim.split(text_cur, "\n", { plain = true })

    local differ = (vim.text and vim.text.diff) or vim.diff
    local hunks = differ(text_after .. "\n", text_before .. "\n", { result_type = "indices" })
    if type(hunks) ~= "table" or #hunks == 0 then
      return string.format("%s: seq %d made no textual change — nothing to revert", name, seq)
    end

    local function find_matches(pattern)
      local hits = {}
      for i = 1, #cur_lines - #pattern + 1 do
        local m = true
        for j = 1, #pattern do
          if cur_lines[i + j - 1] ~= pattern[j] then m = false; break end
        end
        if m then hits[#hits + 1] = i end
      end
      return hits
    end

    -- Locate one hunk's a-side block in the current text: try with 3 context
    -- lines from the after-state, shrinking when nearby later edits broke the
    -- context — but ALWAYS requiring a unique match. Returns the block's
    -- 1-based start index in cur_lines (for pure insertions, the index to
    -- insert before), or nil + reason.
    local function locate(sa, ca)
      local a_start = ca > 0 and sa or sa + 1
      local min_ctx = ca > 0 and 0 or 1 -- an insertion needs at least one anchor line
      for ctx = 3, min_ctx, -1 do
        local pattern, pre_n = {}, 0
        for i = math.max(1, a_start - ctx), a_start - 1 do
          pattern[#pattern + 1] = after_lines[i]
          pre_n = pre_n + 1
        end
        for i = a_start, a_start + ca - 1 do
          pattern[#pattern + 1] = after_lines[i]
        end
        for i = a_start + ca, math.min(#after_lines, a_start + ca + ctx - 1) do
          pattern[#pattern + 1] = after_lines[i]
        end
        if #pattern > 0 then
          local hits = find_matches(pattern)
          if #hits == 1 then
            return hits[1] + pre_n
          end
          if #hits > 1 then
            return nil, "ambiguous match" -- less context can only match more
          end
        end
      end
      return nil, "no matching text"
    end

    local reps = {}
    for _, h in ipairs(hunks) do
      local sa, ca, sb, cb = h[1], h[2], h[3], h[4]
      local start, why = locate(sa, ca)
      if not start then
        error(string.format(
          "undo_edit: %s: cannot surgically revert seq %d — %s for the hunk near line %d"
            .. " (later changes overlap it). Fall back to to_seq time travel or edit_file.",
          name, seq, why, math.max(1, sa)), 0)
      end
      local insert = {}
      for i = sb, sb + cb - 1 do insert[#insert + 1] = before_lines[i] end
      reps[#reps + 1] = { start = start, remove = ca, insert = insert }
    end
    table.sort(reps, function(a, b) return a.start < b.start end)
    for i = 2, #reps do
      if reps[i].start < reps[i - 1].start + reps[i - 1].remove then
        error(string.format(
          "undo_edit: %s: cannot surgically revert seq %d — its hunks map to overlapping"
            .. " regions of the current text. Fall back to to_seq time travel.",
          name, seq), 0)
      end
    end

    -- Apply bottom-up in Lua, then set the whole buffer in ONE undoable step
    -- (the revert itself becomes a single undo block) and save.
    for i = #reps, 1, -1 do
      local r = reps[i]
      for _ = 1, r.remove do table.remove(cur_lines, r.start) end
      for j = #r.insert, 1, -1 do table.insert(cur_lines, r.start, r.insert[j]) end
    end
    local oka, aerr = pcall(function()
      vim.api.nvim_buf_call(buf, function()
        vim.cmd("let &l:undolevels = &l:undolevels")
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, cur_lines)
        vim.cmd("silent noautocmd update")
      end)
    end)
    if not oka then error("undo_edit: failed to apply the revert: " .. tostring(aerr), 0) end
    registry.call("fn.mark_seen", ctx and ctx.bufnr, buf, true)
    return string.format(
      "%s: surgically reverted seq %d (%d hunk%s), later edits kept, saved —"
        .. " the revert is itself one undo block (u reverts it)",
      name, seq, #reps, #reps == 1 and "" or "s")
  end

  local before = tree().seq_cur
  local cmd
  if input.to_seq ~= nil then
    local seq = tonumber(input.to_seq)
    if not seq or seq < 0 then
      error("undo_edit: to_seq must be a non-negative undo sequence number", 0)
    end
    cmd = "undo " .. math.floor(seq)
  else
    local steps = math.max(1, math.floor(tonumber(input.steps) or 1))
    cmd = "earlier " .. steps
  end
  local ok, err = pcall(function()
    vim.api.nvim_buf_call(buf, function()
      vim.cmd("silent " .. cmd)
      vim.cmd("silent noautocmd update")
    end)
  end)
  if not ok then error("undo_edit: " .. tostring(err), 0) end
  local after = tree().seq_cur
  if after == before then
    return string.format(
      "%s: nothing changed (already at seq %d — history=true shows the states)",
      name, before)
  end
  registry.call("fn.mark_seen", ctx and ctx.bufnr, buf, true)
  return string.format(
    "%s: moved from seq %d to seq %d and saved — redo by calling again with to_seq=%d",
    name, before, after, before)
end
]==]),
  })

  -- --------------------------------------------------------------- show_diff

  define({
    name = "tool.show_diff",
    kind = "tool",
    doc = "Show the user a diff in a real side-by-side diff split (Vim's"
      .. " :diffthis, so hunks are highlighted natively) — two versions of"
      .. " something to compare, not prose describing the change. Two modes:"
      .. " (1) proposed-vs-current: pass {path, content} to diff `content`"
      .. " against the file's CURRENT contents on disk/buffer (e.g. preview an"
      .. " edit before making it); (2) arbitrary texts: pass {left, right,"
      .. " filetype?, left_label?, right_label?} to diff two strings. Opens in"
      .. " non-session windows without stealing the user's focus; a later call"
      .. " reuses the diff windows a previous call opened (tagged"
      .. " w:straps_view='diff') instead of adding splits. Read-only"
      .. " (shows a view; changes no files). Returns a one-line confirmation"
      .. " with the hunk count. Parameters: path + content, OR left + right"
      .. " (with optional filetype and labels).",
    input_schema = {
      type = "object",
      properties = {
        path = { type = "string", description = "File to diff `content` against (proposed-vs-current mode)." },
        content = { type = "string", description = "Proposed new contents for `path`." },
        left = { type = "string", description = "Left-hand text (arbitrary-texts mode)." },
        right = { type = "string", description = "Right-hand text (arbitrary-texts mode)." },
        filetype = { type = "string", description = "Filetype for syntax highlighting in arbitrary-texts mode." },
        left_label = { type = "string", description = "Window label for the left side." },
        right_label = { type = "string", description = "Window label for the right side." },
      },
      required = {},
    },
    source = src([==[
return function(input, ctx)
  input = input or {}
  local left, right, ft, lname, rname

  if type(input.path) == "string" and input.path ~= "" then
    -- Proposed-vs-current: current contents (buffer if loaded, else disk).
    local full = vim.fn.fnamemodify(input.path, ":p")
    local buf = vim.fn.bufadd(full)
    pcall(vim.fn.bufload, buf)
    left = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    right = (type(input.content) == "string" and input.content or ""):gsub("\n$", "")
    ft = vim.bo[buf].filetype
    if ft == nil or ft == "" then
      local m = vim.filetype.match({ filename = full })
      if m and m ~= "" then ft = m end
    end
    lname = input.left_label or (relname(full, buf) .. " (current)")
    rname = input.right_label or (relname(full, buf) .. " (proposed)")
  elseif type(input.left) == "string" and type(input.right) == "string" then
    left, right = input.left, input.right
    ft = type(input.filetype) == "string" and input.filetype or ""
    lname = input.left_label or "left"
    rname = input.right_label or "right"
  else
    error("show_diff: pass {path, content} or {left, right}", 0)
  end

  local hunks = 0
  local ok, err = pcall(function()
    local lb = scratch_buf(vim.split(left, "\n", { plain = true }), ft)
    local rb = scratch_buf(vim.split(right, "\n", { plain = true }), ft)
    vim.b[lb].straps_view = "diff"
    vim.b[rb].straps_view = "diff"
    local cur = vim.api.nvim_get_current_win()
    local views = {}
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.w[w].straps_view == "diff" and vim.b[vim.api.nvim_win_get_buf(w)].straps_view == "diff" then
        views[#views + 1] = w
      end
    end
    table.sort(views, function(a, b)
      local pa, pb = vim.api.nvim_win_get_position(a), vim.api.nvim_win_get_position(b)
      if pa[2] ~= pb[2] then return pa[2] < pb[2] end
      return pa[1] < pb[1]
    end)
    local lw, rw = views[1], views[2]
    for i = 3, #views do pcall(vim.api.nvim_win_close, views[i], true) end
    if not lw then
      lw = new_split_win()
    end
    vim.api.nvim_win_set_buf(lw, lb)
    pcall(function()
      vim.api.nvim_set_current_win(lw)
      if not rw then
        vim.cmd("rightbelow vsplit")
        rw = vim.api.nvim_get_current_win()
      end
      vim.api.nvim_win_set_buf(rw, rb)
      vim.w[lw].straps_view = "diff"
      vim.w[rw].straps_view = "diff"
      for _, w in ipairs({ lw, rw }) do
        vim.api.nvim_win_call(w, function() vim.cmd("diffthis") end)
      end
      pcall(vim.api.nvim_buf_set_name, lb, "straps://diff/" .. lname)
      pcall(vim.api.nvim_buf_set_name, rb, "straps://diff/" .. rname)
      pcall(function() vim.wo[lw].winbar = (lname:gsub("%%", "%%%%")) end)
      pcall(function() vim.wo[rw].winbar = (rname:gsub("%%", "%%%%")) end)
    end)
    pcall(vim.api.nvim_set_current_win, cur)
  end)
  if not ok then error("show_diff: " .. tostring(err), 0) end

  if left == right then
    return "show_diff: the two versions are identical (no differences)"
  end
  -- Count hunks from the unified diff (for the agent's confirmation line).
  local diff = unified_diff(left, right, 0)
  for _ in diff:gmatch("\n@@") do hunks = hunks + 1 end
  if diff:match("^@@") then hunks = hunks + 1 end
  return ("show_diff: opened a diff split (%d hunk%s) — %s vs %s")
    :format(hunks, hunks == 1 and "" or "s", lname, rname)
end
]==]),
  })

  -- ------------------------------------------------------------- show_buffer

  define({
    name = "tool.show_buffer",
    kind = "tool",
    doc = "Show the user generated or extracted content in a filetype'd scratch"
      .. " split — a report, a table, a data extract, sample code — so it"
      .. " arrives syntax-highlighted and searchable in their editor instead of"
      .. " scrolling past in the transcript. Opens in a non-session window"
      .. " without stealing focus; a later call replaces the buffer in the"
      .. " window a previous call opened (tagged w:straps_view='buffer')"
      .. " instead of adding a split. Read-only (creates a scratch buffer; touches"
      .. " no files). Returns a one-line confirmation. Parameters: content"
      .. " (required) — the text to display; filetype (optional) — for"
      .. " highlighting, e.g. 'markdown', 'lua', 'json'; title (optional) — a"
      .. " name for the scratch buffer; split (optional) — 'vertical' (default)"
      .. " or 'horizontal'.",
    input_schema = {
      type = "object",
      properties = {
        content = { type = "string", description = "Text to display in the scratch buffer." },
        filetype = { type = "string", description = "Filetype for syntax highlighting." },
        title = { type = "string", description = "Name for the scratch buffer." },
        split = { type = "string", description = "'vertical' (default) or 'horizontal'." },
      },
      required = { "content" },
    },
    source = src([==[
return function(input, ctx)
  input = input or {}
  if type(input.content) ~= "string" then
    error("show_buffer: content is required", 0)
  end
  local ft = type(input.filetype) == "string" and input.filetype or ""
  local title = type(input.title) == "string" and input.title ~= "" and input.title or nil
  local name = "straps://buffer/" .. (title or ("scratch-" .. os.time()))
  local nlines = 0
  local ok, err = pcall(function()
    local lines = vim.split(input.content, "\n", { plain = true })
    nlines = #lines
    local b = scratch_buf(lines, ft)
    vim.b[b].straps_view = "buffer"
    local win
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.w[w].straps_view == "buffer" and vim.b[vim.api.nvim_win_get_buf(w)].straps_view == "buffer" then
        win = w; break
      end
    end
    if not win then
      local cmd = (input.split == "horizontal") and "botright split" or "botright vsplit"
      win = new_split_win(cmd)
      vim.w[win].straps_view = "buffer"
    end
    vim.api.nvim_win_set_buf(win, b)
    pcall(vim.api.nvim_buf_set_name, b, name)
    pcall(function() vim.wo[win].winbar = title and (title:gsub("%%", "%%%%")) or "" end)
  end)
  if not ok then error("show_buffer: " .. tostring(err), 0) end
  return ("show_buffer: opened %d line%s%s%s")
    :format(nlines, nlines == 1 and "" or "s",
      ft ~= "" and (" (" .. ft .. ")") or "",
      title and (" — " .. title) or "")
end
]==]),
  })

  -- ------------------------------------------------------------ set_findings

  define({
    name = "tool.set_findings",
    kind = "tool",
    doc = "Load a list of locations into this session's findings list (the"
      .. " session window's location list when on-screen, else the global"
      .. " quickfix list) and open it, so the user can step through them with"
      .. " :lnext/:lprev (or :cnext/:cprev when it fell back). Use this for a set"
      .. " of file:line findings you assembled yourself (e.g. from reads and"
      .. " analysis) — grep already fills the findings list for searches, and"
      .. " run_quickfix does it for build/lint output, so reach for those first"
      .. " when they apply. Read-only with respect to files (only sets the"
      .. " findings list). Parameters: items (required) — an array of"
      .. " {path, line?, col?, text?}; title (optional) — the list title; open"
      .. " (optional, default true) — open the findings list window.",
    input_schema = {
      type = "object",
      properties = {
        items = {
          type = "array",
          description = "Locations to load: {path, line?, col?, text?} objects.",
          items = {
            type = "object",
            properties = {
              path = { type = "string" },
              line = { type = "integer" },
              col = { type = "integer" },
              text = { type = "string" },
            },
            required = { "path" },
          },
        },
        title = { type = "string", description = "Findings list title." },
        open = { type = "boolean", description = "Open the findings list window (default true)." },
      },
      required = { "items" },
    },
    source = src([==[
return function(input, ctx)
  input = input or {}
  if type(input.items) ~= "table" then
    error("set_findings: items must be an array of {path, line?, col?, text?}", 0)
  end
  local qf = {}
  for _, it in ipairs(input.items) do
    if type(it) == "table" and type(it.path) == "string" and it.path ~= "" then
      qf[#qf + 1] = {
        filename = vim.fn.fnamemodify(it.path, ":p"),
        lnum = tonumber(it.line) or 0,
        col = tonumber(it.col) or 0,
        text = type(it.text) == "string" and it.text or "",
      }
    end
  end
  if #qf == 0 then
    error("set_findings: no valid items (each needs a `path`)", 0)
  end
  local title = type(input.title) == "string" and input.title ~= "" and input.title
    or "straps: findings"
  local open = input.open
  if open == nil then open = true end
  -- Route to THIS session's findings list (its window's location list when
  -- on-screen — isolated from other sessions — else the global quickfix list).
  local list_kind = require("straps.findings").set_locations(ctx and ctx.bufnr,
    { title = title, items = qf }, open)
  local nav = (list_kind == "loclist") and ":lnext/:lprev" or ":cnext/:cprev"
  return ("set_findings: loaded %d entr%s (%s) — the user can step them with %s")
    :format(#qf, #qf == 1 and "y" or "ies", title, nav)
end
]==]),
  })

  -- Prompt fragment slot for the editor layer — registered here (at the END of
  -- editor.lua's register()) rather than in the tools.lua skeleton pass, since
  -- editor.lua is already its own layer manifest. Returns "" until the editor
  -- guidance moves out of the core prompt (organizational skeleton).
  define({
    name = "fn.system_prompt_layer.editor",
    kind = "fn",
    doc = "Prompt fragment slot for the editor layer — returns '' until that"
      .. " layer's guidance moves out of the core prompt (organizational"
      .. " skeleton).",
    source = "return function() return \"\" end",
  })
end

return M
