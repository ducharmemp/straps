-- straps/editor.lua — editor-native tools (diagnostics, definition, references,
-- symbols, read_symbol). Tree-sitter tools are synchronous and need no server;
-- LSP tools run async through ctx.await with a bounded timeout so a wedged
-- server can never hang the run. Every tool degrades to a clear string, never
-- a Lua error. register() uses registry.define_default (no clobbering).

local M = {}

-- Shared Lua helpers prepended to every tool source. Each tool source is a
-- separate compiled chunk, so the helpers live in this prelude string and are
-- concatenated in; keeps buffer loading / position math / LSP plumbing DRY.
local PRELUDE = [==[
local uv = vim.uv or vim.loop

-- Load `path` into a buffer and resolve its filetype (so a linter/LSP can
-- attach and tree-sitter can pick a language). Returns bufnr, filetype.
local function load_buf(path)
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

-- Format a single LSP Location / LocationLink into "file:line:col".
local function add_loc(loc, out)
  if type(loc) ~= "table" then return end
  local uri = loc.uri or loc.targetUri
  local range = loc.range or loc.targetSelectionRange or loc.targetRange
  if uri and range and range.start then
    local file = vim.fn.fnamemodify(vim.uri_to_fname(uri), ":~:.")
    out[#out + 1] = string.format("%s:%d:%d", file, range.start.line + 1, range.start.character + 1)
  end
end

-- Collect locations from one client result (single Location, LocationLink, or
-- an array of them) into `out`.
local function collect_locations(result, out)
  if type(result) ~= "table" then return end
  if result.uri or result.targetUri or result.range or result.targetUri then
    add_loc(result, out)
  else
    for _, loc in ipairs(result) do add_loc(loc, out) end
  end
end

-- Dedup + sort a list of "file:line:col" strings and join with newlines.
local function join_sorted(list)
  local seen, out = {}, {}
  for _, s in ipairs(list) do
    if not seen[s] then seen[s] = true; out[#out + 1] = s end
  end
  table.sort(out)
  return table.concat(out, "\n")
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

-- Apply a WorkspaceEdit through buffers (native undo, like write_file /
-- edit_file: each touched buffer gets its own undo break first), then
-- :update every touched file. Returns the sorted list of touched files.
local function apply_workspace_edit_and_save(edit, enc)
  local uris = {}
  if type(edit.changes) == "table" then
    for uri in pairs(edit.changes) do uris[#uris + 1] = uri end
  end
  if type(edit.documentChanges) == "table" then
    for _, dc in ipairs(edit.documentChanges) do
      if type(dc) == "table" and dc.textDocument and dc.textDocument.uri then
        uris[#uris + 1] = dc.textDocument.uri
      end
    end
  end
  for _, uri in ipairs(uris) do
    local buf = vim.uri_to_bufnr(uri)
    pcall(vim.fn.bufload, buf)
    pcall(function()
      vim.api.nvim_buf_call(buf, function()
        vim.cmd("let &l:undolevels = &l:undolevels")
      end)
    end)
  end
  vim.lsp.util.apply_workspace_edit(edit, enc or "utf-16")
  local files, seen = {}, {}
  for _, uri in ipairs(uris) do
    local buf = vim.uri_to_bufnr(uri)
    if not seen[buf] then
      seen[buf] = true
      pcall(function()
        vim.api.nvim_buf_call(buf, function() vim.cmd("silent noautocmd update") end)
      end)
      files[#files + 1] = relname(vim.api.nvim_buf_get_name(buf), buf)
    end
  end
  table.sort(files)
  return files
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
      .. " also loads the reported diagnostics into Neovim's quickfix list (title"
      .. " 'straps: diagnostics'), so the user can jump through them with"
      .. " :cnext/:cprev; the returned text is unchanged. Parameters: path"
      .. " (optional) — file to inspect; omit to scan all loaded buffers; quickfix"
      .. " (optional boolean) — also populate the quickfix list.",
    input_schema = {
      type = "object",
      properties = {
        path = { type = "string", description = "File to inspect; omit for all loaded buffers." },
        quickfix = { type = "boolean", description = "Also populate the quickfix list with the diagnostics." },
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
      local okl, buf = pcall(load_buf, input.path)
      if not okl then return "diagnostics: cannot load " .. tostring(input.path) end
      bufs = { buf }
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
        require("straps.ui").set_locations(ctx and ctx.bufnr,
          { title = "straps: diagnostics", items = items }, false)
      end)
    end
    if #lines == 0 then return "no diagnostics" end
    return table.concat(lines, "\n")
  end)
  if not ok then return "diagnostics: " .. tostring(out) end
  return out
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
      .. " lookup of the symbol under the position; if that finds nothing,"
      .. " returns a clear 'no LSP client' message. Parameters: path (required);"
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
  local buf, ft = load_buf(input.path)
  local line0 = math.max(0, (tonumber(input.line) or 1) - 1)
  local col0 = math.max(0, (tonumber(input.col) or 1) - 1)

  local function fallback()
    local sym = symbol_at(buf, line0, col0)
    if sym and sym ~= "" then
      local okt, tags = pcall(vim.fn.taglist, "^" .. sym .. "$")
      if okt and type(tags) == "table" and #tags > 0 then
        local out = {}
        for _, t in ipairs(tags) do
          out[#out + 1] = string.format("%s\t%s", t.filename or "?", t.name or sym)
        end
        return "tags for " .. sym .. ":\n" .. table.concat(out, "\n")
      end
    end
    return "no LSP client for filetype " .. (ft ~= "" and ft or "?") .. " (and no tags)"
  end

  local params = {
    textDocument = { uri = vim.uri_from_bufnr(buf) },
    position = { line = line0, character = col0 },
  }
  local ok, res, err = pcall(lsp_request, ctx, buf, "textDocument/definition", params, 5000)
  if not ok then return "definition: " .. tostring(res) end
  if err == "noclient" then return fallback() end
  if err == "timeout" then return "definition: LSP request timed out" end

  local locs = {}
  each_result(res, function(result) collect_locations(result, locs) end)
  if #locs == 0 then return "no definition found" end
  return join_sorted(locs)
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
      .. " falls back to a tags lookup of the symbol, and otherwise returns a"
      .. " clear 'no LSP client' message. Parameters: path (required); line"
      .. " (required, 1-based); col (required, 1-based).",
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
  local buf, ft = load_buf(input.path)
  local line0 = math.max(0, (tonumber(input.line) or 1) - 1)
  local col0 = math.max(0, (tonumber(input.col) or 1) - 1)

  local function fallback()
    local sym = symbol_at(buf, line0, col0)
    if sym and sym ~= "" then
      local okt, tags = pcall(vim.fn.taglist, "^" .. sym .. "$")
      if okt and type(tags) == "table" and #tags > 0 then
        local out = {}
        for _, t in ipairs(tags) do
          out[#out + 1] = string.format("%s\t%s", t.filename or "?", t.name or sym)
        end
        return "tags for " .. sym .. ":\n" .. table.concat(out, "\n")
      end
    end
    return "no LSP client for filetype " .. (ft ~= "" and ft or "?") .. " (and no tags)"
  end

  local params = {
    textDocument = { uri = vim.uri_from_bufnr(buf) },
    position = { line = line0, character = col0 },
    context = { includeDeclaration = true },
  }
  local ok, res, err = pcall(lsp_request, ctx, buf, "textDocument/references", params, 5000)
  if not ok then return "references: " .. tostring(res) end
  if err == "noclient" then return fallback() end
  if err == "timeout" then return "references: LSP request timed out" end

  local locs = {}
  each_result(res, function(result) collect_locations(result, locs) end)
  if #locs == 0 then return "no references found" end
  return join_sorted(locs)
end
]==]),
  })

  -- ------------------------------------------------------------------ symbols

  define({
    name = "tool.symbols",
    kind = "tool",
    doc = "Produce a document outline for a file: its functions, methods,"
      .. " classes and similar top-level constructs. Prefers tree-sitter, so it"
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
  local buf, ft = load_buf(input.path)

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
  return "no tree-sitter parser or LSP for " .. (ft ~= "" and ft or "?")
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
      .. " read_file. If several symbols share the name, lists the matches"
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
  local buf, ft = load_buf(input.path)
  local want = input.name
  if type(want) ~= "string" or want == "" then
    return "read_symbol: name is required"
  end
  local parser = get_parser(buf, ft)
  if not parser then
    return "read_symbol: no tree-sitter parser for " .. (ft ~= "" and ft or "?")
  end
  local ok, out = pcall(function()
    local trees = parser:parse()
    if not trees or not trees[1] then
      return "read_symbol: could not parse " .. tostring(input.path)
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
    local body = vim.api.nvim_buf_get_lines(buf, s.sr - 1, s.er, false)
    local lines = {}
    for i, l in ipairs(body) do
      lines[#lines + 1] = string.format("  %d\t%s", s.sr + i - 1, l)
    end
    return table.concat(lines, "\n")
  end)
  if not ok then return "read_symbol: " .. tostring(out) end
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
  local buf, ft = load_buf(input.path)
  local line0 = math.max(0, (tonumber(input.line) or 1) - 1)
  local col0 = math.max(0, (tonumber(input.col) or 1) - 1)
  local params = {
    textDocument = { uri = vim.uri_from_bufnr(buf) },
    position = { line = line0, character = col0 },
  }
  local ok, res, err = pcall(lsp_request, ctx, buf, "textDocument/hover", params, 5000)
  if not ok then return "hover: " .. tostring(res) end
  if err == "noclient" then return "no LSP client for filetype " .. (ft ~= "" and ft or "?") end
  if err == "timeout" then return "hover: LSP request timed out" end
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
      .. " Parameters: query (required) — the symbol name or a prefix of it;"
      .. " path (optional) — a file of the target language, used to pick the"
      .. " LSP client; without it the first loaded buffer with a client is"
      .. " used.",
    input_schema = {
      type = "object",
      properties = {
        query = { type = "string", description = "Symbol name (or prefix) to search for." },
        path = { type = "string", description = "A file of the target language (picks the LSP client)." },
      },
      required = { "query" },
    },
    source = src([==[
return function(input, ctx)
  local query = input.query
  if type(query) ~= "string" then return "workspace_symbols: query is required" end
  local buf, ft
  if type(input.path) == "string" and input.path ~= "" then
    buf, ft = load_buf(input.path)
  else
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(b) and #vim.lsp.get_clients({ bufnr = b }) > 0 then
        buf = b
        break
      end
    end
    if not buf then
      return "workspace_symbols: no LSP client running — pass path to a file of the target language"
    end
  end
  local ok, res, err = pcall(lsp_request, ctx, buf, "workspace/symbol", { query = query }, 5000)
  if not ok then return "workspace_symbols: " .. tostring(res) end
  if err == "noclient" then return "no LSP client for filetype " .. (ft ~= "" and ft or "?") end
  if err == "timeout" then return "workspace_symbols: LSP request timed out" end
  local kinds = vim.lsp.protocol.SymbolKind or {}
  local seen, out = {}, {}
  each_result(res, function(result)
    for _, s in ipairs(result or {}) do
      local where = ""
      local loc = s.location
      if type(loc) == "table" and loc.uri then
        local file = vim.fn.fnamemodify(vim.uri_to_fname(loc.uri), ":~:.")
        if loc.range and loc.range.start then
          where = string.format("%s:%d:%d",
            file, loc.range.start.line + 1, loc.range.start.character + 1)
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
  if #out == 0 then return "no workspace symbols match " .. query end
  local total = #out
  if total > 200 then
    local capped = {}
    for i = 1, 200 do capped[i] = out[i] end
    capped[#capped + 1] = string.format("[truncated: showing 200 of %d matches; narrow the query]", total)
    out = capped
  end
  return table.concat(out, "\n")
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
      .. " every touched file is saved. This is a WRITE tool and prompts for"
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
    return "rename_symbol: new_name is required"
  end
  local buf, ft = load_buf(input.path)
  local line0 = math.max(0, (tonumber(input.line) or 1) - 1)
  local col0 = math.max(0, (tonumber(input.col) or 1) - 1)
  local params = {
    textDocument = { uri = vim.uri_from_bufnr(buf) },
    position = { line = line0, character = col0 },
    newName = new_name,
  }
  local ok, res, err = pcall(lsp_request, ctx, buf, "textDocument/rename", params, 10000)
  if not ok then return "rename_symbol: " .. tostring(res) end
  if err == "noclient" then
    return "no LSP client for filetype " .. (ft ~= "" and ft or "?")
      .. " — rename needs a language server (grep + bulk_replace is the textual fallback)"
  end
  if err == "timeout" then return "rename_symbol: LSP request timed out" end
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
    return "rename_symbol: server returned no edit — is the position on a renameable symbol?"
  end
  local okap, files = pcall(apply_workspace_edit_and_save, edit, enc)
  if not okap then return "rename_symbol: failed to apply edit: " .. tostring(files) end
  return string.format("renamed to %s across %d file%s:\n%s\n— undo with u in each buffer",
    new_name, #files, #files == 1 and "" or "s", table.concat(files, "\n"))
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
      .. " No attached/capable server: a plain filesystem move — never an"
      .. " error, since not every filetype has one. This is a WRITE tool and"
      .. " prompts for confirmation. Parameters: from (required, existing"
      .. " path); to (required, destination path; parent dirs are created)."
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
  if type(from) ~= "string" or from == "" then return "move_file: from is required" end
  if type(to) ~= "string" or to == "" then return "move_file: to is required" end

  local from_full = vim.fn.fnamemodify(from, ":p")
  if vim.fn.filereadable(from_full) ~= 1 then
    return "move_file: no such file: " .. relname(from_full)
  end
  local to_full = vim.fn.fnamemodify(to, ":p")
  if vim.fn.filereadable(to_full) == 1 then
    return "move_file: destination already exists: " .. relname(to_full)
  end

  local buf = load_buf(from_full) -- load first: LSP needs an attached buffer to ask
  local clients = wait_clients(ctx, buf)
  local mover -- the one client (if any) that supports will/didRenameFiles
  for _, c in ipairs(clients or {}) do
    local ok_s, supports = pcall(function()
      return c:supports_method("workspace/willRenameFiles")
    end)
    if ok_s and supports then mover = c; break end
  end

  local edit_note = ""
  if mover then
    local params = {
      files = { { oldUri = vim.uri_from_fname(from_full), newUri = vim.uri_from_fname(to_full) } },
    }
    local result, err = client_request(ctx, mover, "workspace/willRenameFiles", params, buf, 8000)
    if result and type(result) == "table" and (result.changes or result.documentChanges) then
      local okap, files = pcall(apply_workspace_edit_and_save, result, mover.offset_encoding)
      if okap then
        edit_note = string.format("; server updated %d reference file%s:\n%s",
          #files, #files == 1 and "" or "s", table.concat(files, "\n"))
      else
        edit_note = "; server returned an edit but it failed to apply: " .. tostring(files)
      end
    elseif err then
      edit_note = "; willRenameFiles request " .. tostring(err) .. " (moved anyway)"
    end
  end

  local ok_rn, rn_err = pcall(vim.lsp.util.rename, from_full, to_full, {})
  if not ok_rn then
    return "move_file: rename failed: " .. tostring(rn_err)
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

  return string.format("moved %s -> %s%s", relname(from_full), relname(to_full), edit_note)
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
      .. " move plainly, same as move_file. This is a WRITE tool and prompts"
      .. " for confirmation. Parameters: moves (required) — array of"
      .. " {from, to} objects.",
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
    return "move_files: moves must be a non-empty array of {from, to}"
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
    return "move_files: refusing the whole batch — fix these and retry:\n"
      .. table.concat(problems, "\n")
  end

  -- Bucket entries by the one client (per filetype, cached — files sharing a
  -- filetype share the same attached clients) that supports willRenameFiles,
  -- so each capable server gets ONE request covering all its files, not one
  -- request per file. Entries with no capable client just move plainly.
  local ft_clients = {}
  local buckets, bucket_order = {}, {}
  for _, e in ipairs(entries) do
    e.buf = load_buf(e.from)
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

  local server_files, seen_file = {}, {}
  local function note_files(files)
    for _, f in ipairs(files) do
      if not seen_file[f] then seen_file[f] = true; server_files[#server_files + 1] = f end
    end
  end
  local notes = {}

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
      local okap, files = pcall(apply_workspace_edit_and_save, result, bucket.client.offset_encoding)
      if okap then
        note_files(files)
      else
        notes[#notes + 1] = bucket.client.name .. ": edit returned but failed to apply: " .. tostring(files)
      end
    elseif err then
      notes[#notes + 1] = bucket.client.name .. ": willRenameFiles " .. tostring(err) .. " (moved anyway)"
    end
  end

  -- Validation already guaranteed every source exists and every destination
  -- is free, so each move is expected to succeed; a failure here still lets
  -- the loop finish the rest rather than losing track of remaining files.
  local moved, failed = {}, {}
  for _, e in ipairs(entries) do
    local ok_rn, rn_err = pcall(vim.lsp.util.rename, e.from, e.to, {})
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
        files_param[#files_param + 1] =
          { oldUri = vim.uri_from_fname(e.from), newUri = vim.uri_from_fname(e.to) }
      end
      pcall(function() bucket.client:notify("workspace/didRenameFiles", { files = files_param }) end)
    end
  end

  local out = { string.format("moved %d file%s:", #moved, #moved == 1 and "" or "s") }
  vim.list_extend(out, moved)
  if #failed > 0 then
    out[#out + 1] = string.format("%d move%s FAILED:", #failed, #failed == 1 and "" or "s")
    vim.list_extend(out, failed)
  end
  if #server_files > 0 then
    out[#out + 1] = string.format("server updated %d reference file%s:", #server_files, #server_files == 1 and "" or "s")
    vim.list_extend(out, server_files)
  end
  vim.list_extend(out, notes)
  return table.concat(out, "\n")
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
      .. " No attached/capable server: a plain filesystem delete, never an"
      .. " error. Any loaded buffer on the file is wiped after deletion."
      .. " This is a WRITE tool and prompts for confirmation. Parameters:"
      .. " path (required, existing file).",
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
  if type(path) ~= "string" or path == "" then return "delete_file: path is required" end

  local full = vim.fn.fnamemodify(path, ":p")
  if vim.fn.filereadable(full) ~= 1 then
    return "delete_file: no such file: " .. relname(full)
  end

  local existing_buf = vim.fn.bufnr(full)
  if existing_buf ~= -1 and vim.api.nvim_buf_is_loaded(existing_buf)
    and vim.bo[existing_buf].modified then
    return "delete_file: refusing — " .. relname(full)
      .. " has unsaved buffer changes (write or discard them first)"
  end

  local buf = load_buf(full)
  local clients = wait_clients(ctx, buf)
  local deleter
  for _, c in ipairs(clients or {}) do
    local ok_s, supports = pcall(function() return c:supports_method("workspace/willDeleteFiles") end)
    if ok_s and supports then deleter = c; break end
  end

  local edit_note = ""
  if deleter then
    local params = { files = { { uri = vim.uri_from_fname(full) } } }
    local result, err = client_request(ctx, deleter, "workspace/willDeleteFiles", params, buf, 8000)
    if result and type(result) == "table" and (result.changes or result.documentChanges) then
      local okap, files = pcall(apply_workspace_edit_and_save, result, deleter.offset_encoding)
      if okap then
        edit_note = string.format("; server updated %d reference file%s:\n%s",
          #files, #files == 1 and "" or "s", table.concat(files, "\n"))
      else
        edit_note = "; server returned an edit but it failed to apply: " .. tostring(files)
      end
    elseif err then
      edit_note = "; willDeleteFiles request " .. tostring(err) .. " (deleted anyway)"
    end
  end

  local ok_rm, succ, rm_err = pcall(os.remove, full)
  if not ok_rm or succ ~= true then
    return "delete_file: failed to delete: " .. tostring((not ok_rm and succ) or rm_err or "unknown error")
  end

  pcall(function()
    if vim.api.nvim_buf_is_loaded(buf) then vim.cmd("bwipeout! " .. buf) end
  end)

  if deleter then
    local ok_s2, supports_did = pcall(function() return deleter:supports_method("workspace/didDeleteFiles") end)
    if ok_s2 and supports_did then
      pcall(function()
        deleter:notify("workspace/didDeleteFiles", { files = { { uri = vim.uri_from_fname(full) } } })
      end)
    end
  end

  return string.format("deleted %s (not undo-tree reversible)%s", relname(full), edit_note)
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
      .. " This is a WRITE tool and prompts for confirmation. Parameters:"
      .. " paths (required) — array of existing file paths.",
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
    return "delete_files: paths must be a non-empty array of file paths"
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
        local existing_buf = vim.fn.bufnr(full)
        if existing_buf ~= -1 and vim.api.nvim_buf_is_loaded(existing_buf)
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
    return "delete_files: refusing the whole batch — fix these and retry:\n"
      .. table.concat(problems, "\n")
  end

  -- Bucket by the one client (per filetype) that supports willDeleteFiles,
  -- so each capable server gets ONE request covering all its files.
  local ft_clients = {}
  local buckets, bucket_order = {}, {}
  for _, e in ipairs(entries) do
    e.buf = load_buf(e.path)
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

  local server_files, seen_file = {}, {}
  local function note_files(files)
    for _, f in ipairs(files) do
      if not seen_file[f] then seen_file[f] = true; server_files[#server_files + 1] = f end
    end
  end
  local notes = {}

  for _, id in ipairs(bucket_order) do
    local bucket = buckets[id]
    local files_param = {}
    for _, e in ipairs(bucket.entries) do
      files_param[#files_param + 1] = { uri = vim.uri_from_fname(e.path) }
    end
    local result, err = client_request(ctx, bucket.client, "workspace/willDeleteFiles",
      { files = files_param }, bucket.entries[1].buf, 8000)
    if result and type(result) == "table" and (result.changes or result.documentChanges) then
      local okap, files = pcall(apply_workspace_edit_and_save, result, bucket.client.offset_encoding)
      if okap then
        note_files(files)
      else
        notes[#notes + 1] = bucket.client.name .. ": edit returned but failed to apply: " .. tostring(files)
      end
    elseif err then
      notes[#notes + 1] = bucket.client.name .. ": willDeleteFiles " .. tostring(err) .. " (deleted anyway)"
    end
  end

  -- Validation already confirmed every path exists; a failure here still
  -- lets the loop finish the rest rather than losing track of the remainder.
  local deleted, failed = {}, {}
  for _, e in ipairs(entries) do
    local ok_rm, succ, rm_err = pcall(os.remove, e.path)
    if ok_rm and succ == true then
      deleted[#deleted + 1] = relname(e.path)
      pcall(function()
        if vim.api.nvim_buf_is_loaded(e.buf) then vim.cmd("bwipeout! " .. e.buf) end
      end)
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
        files_param[#files_param + 1] = { uri = vim.uri_from_fname(e.path) }
      end
      pcall(function() bucket.client:notify("workspace/didDeleteFiles", { files = files_param }) end)
    end
  end

  local out = { string.format("deleted %d file%s (not undo-tree reversible):",
    #deleted, #deleted == 1 and "" or "s") }
  vim.list_extend(out, deleted)
  if #failed > 0 then
    out[#out + 1] = string.format("%d delete%s FAILED:", #failed, #failed == 1 and "" or "s")
    vim.list_extend(out, failed)
  end
  if #server_files > 0 then
    out[#out + 1] = string.format("server updated %d reference file%s:", #server_files, #server_files == 1 and "" or "s")
    vim.list_extend(out, server_files)
  end
  vim.list_extend(out, notes)
  return table.concat(out, "\n")
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
      .. " (required, 1-based); index (optional) — apply the Nth listed action.",
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
  local buf, ft = load_buf(input.path)
  local line0 = math.max(0, (tonumber(input.line) or 1) - 1)
  local col0 = math.max(0, (tonumber(input.col) or 1) - 1)
  -- Diagnostics overlapping the line, in original LSP shape when available —
  -- servers key their quick-fixes off this context.
  local diags = {}
  pcall(function()
    for _, d in ipairs(vim.diagnostic.get(buf, { lnum = line0 })) do
      local lsp = d.user_data and d.user_data.lsp
      if lsp then diags[#diags + 1] = lsp end
    end
  end)
  local pos = { line = line0, character = col0 }
  local params = {
    textDocument = { uri = vim.uri_from_bufnr(buf) },
    range = { start = pos, ["end"] = pos },
    context = { diagnostics = diags },
  }
  local ok, res, err = pcall(lsp_request, ctx, buf, "textDocument/codeAction", params, 5000)
  if not ok then return "code_action: " .. tostring(res) end
  if err == "noclient" then return "no LSP client for filetype " .. (ft ~= "" and ft or "?") end
  if err == "timeout" then return "code_action: LSP request timed out" end

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
    return string.format("code_action: index %d out of range (1-%d)", index, #actions)
  end
  local action = entry.action
  local client = vim.lsp.get_client_by_id(entry.client_id)
  if client and not action.edit and not action.command then
    local resolved = client_request(ctx, client, "codeAction/resolve", action, buf, 5000)
    if type(resolved) == "table" then action = resolved end
  end

  local did = {}
  if type(action.edit) == "table" then
    local okap, files = pcall(apply_workspace_edit_and_save, action.edit,
      client and client.offset_encoding)
    if not okap then return "code_action: failed to apply edit: " .. tostring(files) end
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
  if #did == 0 then return "code_action: action had no edit or command to apply" end
  return string.format("applied %q: %s — undo with u in each edited buffer",
    action.title or "?", table.concat(did, "; "))
end
]==]),
  })

  -- ------------------------------------------------------------------- format

  define({
    name = "tool.format",
    kind = "tool",
    doc = "Format a file (or a line range of it) with the attached LSP"
      .. " server's formatter, through the file's buffer — the result lands in"
      .. " native undo history (`u` reverts) and the file is saved. This is a"
      .. " WRITE tool and prompts for confirmation. Parameters: path"
      .. " (required); start_line / end_line (optional, 1-based, both or"
      .. " neither) — format only this range.",
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
  local buf, ft = load_buf(input.path)
  local clients = wait_clients(ctx, buf)
  if not clients or #clients == 0 then
    return "no LSP client for filetype " .. (ft ~= "" and ft or "?") .. " — nothing to format with"
  end
  local range = nil
  local sl, el = tonumber(input.start_line), tonumber(input.end_line)
  if sl and el then
    range = { start = { sl, 0 }, ["end"] = { el, 2147483647 } }
  end
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local ok, err = pcall(function()
    vim.api.nvim_buf_call(buf, function()
      vim.cmd("let &l:undolevels = &l:undolevels")
    end)
    vim.lsp.buf.format({ bufnr = buf, async = false, timeout_ms = 5000, range = range })
    vim.api.nvim_buf_call(buf, function() vim.cmd("silent noautocmd update") end)
  end)
  if not ok then return "format: " .. tostring(err) end
  if vim.api.nvim_buf_get_changedtick(buf) == tick then
    return "already formatted (no changes)"
  end
  return "formatted " .. relname(vim.api.nvim_buf_get_name(buf), buf)
    .. (range and string.format(" (L%d-%d)", sl, el) or "")
    .. " — undo with u in the buffer"
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
  local function is_session(b)
    local okv, v = pcall(function() return vim.b[b].straps_session end)
    return okv and v ~= nil and v ~= false
  end
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
        if #text > 2000 then text = text:sub(1, 2000) .. "..." end
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
    doc = "Point the user's editor at a location: open the file in a"
      .. " non-session window (reusing one that already shows it, else the"
      .. " first available, else a new split), move the cursor there, center"
      .. " the view, and flash a brief highlight on the line. Use it to land"
      .. " the user on the change or finding you want them to see; they can"
      .. " jump back with ctrl-o. Parameters: path (required); line (optional,"
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
    return "show_user: path is required"
  end
  local full = vim.fn.fnamemodify(path, ":p")
  if vim.fn.filereadable(full) == 0 then
    return "show_user: no such file: " .. path
  end
  local buf = vim.fn.bufadd(full)
  if not pcall(vim.fn.bufload, buf) then
    return "show_user: could not load " .. path
  end
  local function is_session(b)
    local okv, v = pcall(function() return vim.b[b].straps_session end)
    return okv and v ~= nil and v ~= false
  end
  local target
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == buf then target = win break end
  end
  if not target then
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if not is_session(vim.api.nvim_win_get_buf(win)) then target = win break end
    end
  end
  local ok, err = pcall(function()
    if target then
      vim.api.nvim_win_set_buf(target, buf)
    else
      vim.cmd("botright vsplit")
      target = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(target, buf)
    end
    vim.api.nvim_set_current_win(target)
    local line = math.max(1, math.min(tonumber(input.line) or 1, vim.api.nvim_buf_line_count(buf)))
    local col = math.max(0, (tonumber(input.col) or 1) - 1)
    vim.api.nvim_win_set_cursor(target, { line, col })
    vim.cmd("normal! zz")
    local ns = vim.api.nvim_create_namespace("straps_show_user")
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    vim.api.nvim_buf_set_extmark(buf, ns, line - 1, 0, {
      end_row = line, hl_group = "Visual", hl_eol = true,
    })
    vim.defer_fn(function()
      pcall(vim.api.nvim_buf_clear_namespace, buf, ns, 0, -1)
    end, 1500)
  end)
  if not ok then return "show_user: " .. tostring(err) end
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
    return "help_search: query is required"
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
    doc = "Ask the user a question through their own picker UI (vim.ui.select,"
      .. " so Telescope/fzf-lua/dressing pickers apply automatically). Use it"
      .. " to propose concrete options — approaches, fixes, names — instead of"
      .. " guessing or asking in prose. An option is a plain string, or a"
      .. " { label, preview, filetype } object when the choice is between"
      .. " competing implementations: put a sketch of what that option's code"
      .. " or outcome looks like in preview, so the user picks between things"
      .. " they can see. Previews render in a live preview pane beside the"
      .. " picker (snacks.nvim) or in labeled splits while the question is up."
      .. " An '(other: type your own answer)' entry is always appended (routed"
      .. " through vim.ui.input); without options: a free-text vim.ui.input"
      .. " prompt. content (optional) is displayed in a scratch split while"
      .. " the question is up — one proposal shared by the whole question —"
      .. " with optional filetype for highlighting; it closes when the user"
      .. " answers. The run blocks until the user responds; a dismissal is"
      .. " reported as such (do not re-ask the identical question)."
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
                  label = { type = "string", description = "Option text shown in the picker." },
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
            .. " an 'other' free-text entry is appended automatically.",
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
    return "ask_user: question is required"
  end

  -- Normalize options: plain strings, or { label, preview, filetype } objects
  -- for choices between competing implementations. previews[i] belongs to
  -- options[i]; input.filetype is the fallback highlight for every preview.
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

  -- Scratch-split plumbing, shared by the content pane and the fallback
  -- per-option previews. Every window opened for this question lands in
  -- `wins` and is closed the moment the user answers.
  local wins = {}
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
    local pbuf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(pbuf, 0, -1, false, lines)
    vim.bo[pbuf].bufhidden = "wipe"
    if type(ft) == "string" and ft ~= "" then
      pcall(function() vim.bo[pbuf].filetype = ft end)
    end
    return pbuf
  end
  local function done(result)
    for _, w in ipairs(wins) do pcall(vim.api.nvim_win_close, w, true) end
    return result
  end

  -- Optional content split, shown while the question is up (same pattern as
  -- the confirm diff preview) and closed as soon as the user answers.
  if type(input.content) == "string" and input.content ~= "" then
    pcall(function()
      local lines = capped_lines(input.content)
      local prev = vim.api.nvim_get_current_win()
      vim.cmd("botright " .. math.min(#lines + 1, 15) .. "split")
      local cwin = vim.api.nvim_get_current_win()
      wins[#wins + 1] = cwin
      vim.api.nvim_win_set_buf(cwin, scratch_buf(lines, default_ft))
      pcall(vim.api.nvim_set_current_win, prev)
      vim.cmd("redraw")
    end)
  end

  local function free_text(prefix)
    local typed = ctx.await(function(resolve)
      vim.ui.input({ prompt = question .. " " }, function(text) resolve(text) end)
    end)
    if typed == nil or typed == "" then
      return done("user dismissed the input without answering — do not re-ask the identical question")
    end
    return done("user answered" .. prefix .. ": " .. typed)
  end

  if #options == 0 then
    return free_text("")
  end

  local OTHER = "(other: type your own answer)"

  -- snacks.nvim path: options with previews become native picker items whose
  -- preview pane renders live as the selection moves (opts.preview =
  -- "preview" renders each item's own { text, ft }). Only taken when at
  -- least one option carries a preview — plain choices stay on
  -- vim.ui.select, whichever picker the user has wired to it.
  if next(previews) ~= nil then
    local ok_snacks, snacks = pcall(require, "snacks")
    local pick = ok_snacks and type(snacks) == "table"
      and type(snacks.picker) == "table" and snacks.picker.pick or nil
    if pick then
      -- Resolves { label = s } on a choice, { dismissed = true } on close
      -- without one, false when the pick call itself failed (then the
      -- split-based fallback below still asks the question).
      local res = ctx.await(function(resolve)
        local resolved = false
        local function finish(v)
          if not resolved then
            resolved = true
            resolve(v)
          end
        end
        local items = {}
        for i, label in ipairs(options) do
          local p = previews[i]
          items[#items + 1] = {
            text = label,
            preview = p and { text = p.text, ft = p.ft, loc = false }
              or { text = "(no preview for this option)", loc = false },
          }
        end
        items[#items + 1] = {
          text = OTHER,
          preview = { text = "(type your own answer)", loc = false },
        }
        local ok_pick = pcall(pick, {
          title = question,
          items = items,
          format = "text",
          preview = "preview",
          -- finish BEFORE close: closing fires on_close, and the first
          -- resolution must be the user's choice, not the dismissal.
          confirm = function(picker, item)
            finish(item and { label = item.text } or { dismissed = true })
            picker:close()
          end,
          on_close = function()
            finish({ dismissed = true })
          end,
        })
        if not ok_pick then
          finish(false)
        end
      end)
      if res ~= false then
        if type(res) ~= "table" or res.dismissed or res.label == nil then
          return done("user dismissed the picker without choosing — proceed on your best judgment or ask differently")
        end
        if res.label == OTHER then
          return free_text(" (free text)")
        end
        for i, o in ipairs(options) do
          if o == res.label then
            return done(string.format("user chose option %d: %s", i, o))
          end
        end
        return done("user chose: " .. res.label)
      end
      -- res == false: the snacks call itself failed; fall through to the
      -- split-based rendering below and ask via vim.ui.select instead.
    end

    -- No snacks (or snacks failed): show every option's preview at once in
    -- labeled splits — one bottom row, one vertical window per preview —
    -- while vim.ui.select is up. Best effort; the question works without
    -- them.
    pcall(function()
      local prev = vim.api.nvim_get_current_win()
      local height, panes = 3, {}
      for i = 1, #options do
        local p = previews[i]
        if p then
          local lines = capped_lines(p.text)
          height = math.max(height, math.min(#lines + 1, 15))
          panes[#panes + 1] = {
            buf = scratch_buf(lines, p.ft),
            label = i .. ": " .. options[i],
          }
        end
      end
      for n, pane in ipairs(panes) do
        if n == 1 then
          vim.cmd("botright " .. height .. "split")
        else
          vim.cmd("rightbelow vsplit")
        end
        local w = vim.api.nvim_get_current_win()
        wins[#wins + 1] = w
        vim.api.nvim_win_set_buf(w, pane.buf)
        -- winbar interprets % codes; the label is plain text.
        pcall(function() vim.wo[w].winbar = pane.label:gsub("%%", "%%%%") end)
      end
      pcall(vim.api.nvim_set_current_win, prev)
      vim.cmd("redraw")
    end)
  end

  local items = {}
  for _, o in ipairs(options) do items[#items + 1] = o end
  items[#items + 1] = OTHER
  local choice, idx = ctx.await(function(resolve)
    vim.ui.select(items, { prompt = question }, function(item, i) resolve(item, i) end)
  end)
  if choice == nil then
    return done("user dismissed the picker without choosing — proceed on your best judgment or ask differently")
  end
  if choice == OTHER then
    return free_text(" (free text)")
  end
  return done(string.format("user chose option %d: %s", idx, choice))
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
      .. " changes overlap it, and refuses if the buffer has unsaved user"
      .. " changes). After any change the buffer is saved to disk."
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
  local buf = load_buf(input.path)
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

  -- revert_seq: surgically reverse ONE undo block, keeping later edits.
  -- Capture the states around seq N (transient in-memory undo round-trip),
  -- diff them into inverse hunks, and apply those hunks to the CURRENT text
  -- as a strict patch — any hunk that cannot be located uniquely is a
  -- conflict and nothing is changed.
  if input.revert_seq ~= nil then
    local seq = tonumber(input.revert_seq)
    if not seq or seq < 1 then
      return "undo_edit: revert_seq must be a positive undo sequence number"
    end
    seq = math.floor(seq)

    -- Guard: the capture round-trip moves the buffer through undo states.
    -- With unsaved user changes in the buffer, refuse rather than risk
    -- interleaving with live typing.
    if vim.bo[buf].modified then
      return name .. ": buffer has unsaved changes — revert_seq transiently"
        .. " moves the buffer through undo states, so save or discard them first"
    end

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
      return string.format("%s: no undo state with seq %d (history=true lists them)", name, seq)
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
      return string.format(
        "%s: internal error capturing undo states — restore the buffer with to_seq=%d",
        name, cur_seq)
    end
    if not okc then
      return "undo_edit: could not capture undo states: " .. tostring(cerr)
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
        return string.format(
          "%s: cannot surgically revert seq %d — %s for the hunk near line %d"
            .. " (later changes overlap it). Fall back to to_seq time travel or edit_file.",
          name, seq, why, math.max(1, sa))
      end
      local insert = {}
      for i = sb, sb + cb - 1 do insert[#insert + 1] = before_lines[i] end
      reps[#reps + 1] = { start = start, remove = ca, insert = insert }
    end
    table.sort(reps, function(a, b) return a.start < b.start end)
    for i = 2, #reps do
      if reps[i].start < reps[i - 1].start + reps[i - 1].remove then
        return string.format(
          "%s: cannot surgically revert seq %d — its hunks map to overlapping"
            .. " regions of the current text. Fall back to to_seq time travel.",
          name, seq)
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
    if not oka then return "undo_edit: failed to apply the revert: " .. tostring(aerr) end
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
      return "undo_edit: to_seq must be a non-negative undo sequence number"
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
  if not ok then return "undo_edit: " .. tostring(err) end
  local after = tree().seq_cur
  if after == before then
    return string.format(
      "%s: nothing changed (already at seq %d — history=true shows the states)",
      name, before)
  end
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
      .. " non-session windows without stealing the user's focus. Read-only"
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
    return "show_diff: pass {path, content} or {left, right}"
  end

  local hunks = 0
  local ok, err = pcall(function()
    local lb = scratch_buf(vim.split(left, "\n", { plain = true }), ft, "straps://diff/" .. lname)
    local rb = scratch_buf(vim.split(right, "\n", { plain = true }), ft, "straps://diff/" .. rname)
    -- New content gets its own split so the user's current buffer is never
    -- replaced; the right side splits beside it.
    local lw = new_split_win()
    vim.api.nvim_win_set_buf(lw, lb)
    local cur = vim.api.nvim_get_current_win()
    pcall(function()
      vim.api.nvim_set_current_win(lw)
      vim.cmd("diffthis")
      vim.cmd("rightbelow vsplit")
      local rw = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(rw, rb)
      vim.cmd("diffthis")
      pcall(function() vim.wo[lw].winbar = lname end)
      pcall(function() vim.wo[rw].winbar = rname end)
    end)
    pcall(vim.api.nvim_set_current_win, cur)
  end)
  if not ok then return "show_diff: " .. tostring(err) end

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
      .. " without stealing focus. Read-only (creates a scratch buffer; touches"
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
    return "show_buffer: content is required"
  end
  local ft = type(input.filetype) == "string" and input.filetype or ""
  local title = type(input.title) == "string" and input.title ~= "" and input.title or nil
  local name = "straps://buffer/" .. (title or ("scratch-" .. os.time()))
  local nlines = 0
  local ok, err = pcall(function()
    local lines = vim.split(input.content, "\n", { plain = true })
    nlines = #lines
    local b = scratch_buf(lines, ft, name)
    local cmd = (input.split == "horizontal") and "botright split" or "botright vsplit"
    local win = new_split_win(cmd)
    vim.api.nvim_win_set_buf(win, b)
    if title then pcall(function() vim.wo[win].winbar = title end) end
  end)
  if not ok then return "show_buffer: " .. tostring(err) end
  return ("show_buffer: opened %d line%s%s%s")
    :format(nlines, nlines == 1 and "" or "s",
      ft ~= "" and (" (" .. ft .. ")") or "",
      title and (" — " .. title) or "")
end
]==]),
  })

  -- ------------------------------------------------------------ set_quickfix

  define({
    name = "tool.set_quickfix",
    kind = "tool",
    doc = "Load a list of locations into Neovim's quickfix list and open it, so"
      .. " the user can step through them with :cnext/:cprev. Use this for a set"
      .. " of file:line findings you assembled yourself (e.g. from reads and"
      .. " analysis) — grep already fills the quickfix list for searches, and"
      .. " run_quickfix does it for build/lint output, so reach for those first"
      .. " when they apply. Read-only with respect to files (only sets the"
      .. " quickfix list). Parameters: items (required) — an array of"
      .. " {path, line?, col?, text?}; title (optional) — the list title; open"
      .. " (optional, default true) — open the quickfix window.",
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
        title = { type = "string", description = "Quickfix list title." },
        open = { type = "boolean", description = "Open the quickfix window (default true)." },
      },
      required = { "items" },
    },
    source = src([==[
return function(input, ctx)
  input = input or {}
  if type(input.items) ~= "table" then
    return "set_quickfix: items must be an array of {path, line?, col?, text?}"
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
    return "set_quickfix: no valid items (each needs a `path`)"
  end
  local title = type(input.title) == "string" and input.title ~= "" and input.title
    or "straps: findings"
  local open = input.open
  if open == nil then open = true end
  -- Route to THIS session's findings list (its window's location list when
  -- on-screen — isolated from other sessions — else the global quickfix list).
  local list_kind = require("straps.ui").set_locations(ctx and ctx.bufnr,
    { title = title, items = qf }, open)
  local nav = (list_kind == "loclist") and ":lnext/:lprev" or ":cnext/:cprev"
  return ("set_quickfix: loaded %d entr%s (%s) — the user can step them with %s")
    :format(#qf, #qf == 1 and "y" or "ies", title, nav)
end
]==]),
  })
end

return M
