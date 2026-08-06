-- straps/tools.lua — registers all builtin tools and default hooks.
-- Every entry is stored as a Lua source STRING and compiled by the registry,
-- so any of them can be redefined at runtime (including by the agent itself).
-- register() uses registry.define_default: it never clobbers user redefinitions.

local M = {}

function M.register()
  local registry = require("straps.registry")
  local define = registry.define_default

  -- ---------------------------------------------------------------- read_file

  define({
    name = "tool.read_file",
    kind = "tool",
    doc = "Read a file through its Neovim buffer, so open unsaved changes are"
      .. " the source of truth (matching edit/write paths). A note is prepended"
      .. " when the file changed on disk since load or was modified by another"
      .. " session (a competing editor). Returns the content with"
      .. " 1-based line numbers in the form '  N<TAB>line'. Parameters: path"
      .. " (required) — absolute or cwd-relative path of the file to read; offset"
      .. " (optional, default 1) — 1-based line number to start reading from; limit"
      .. " (optional) — maximum number of lines to return. At most 2000 lines are"
      .. " returned per call; if the file has more, the output ends with a truncation"
      .. " note telling you the next offset to use.",
    input_schema = {
      type = "object",
      properties = {
        path = { type = "string", description = "Path of the file to read." },
        offset = { type = "integer", description = "1-based line number to start from (default 1)." },
        limit = { type = "integer", description = "Maximum number of lines to return (capped at 2000)." },
      },
      required = { "path" },
    },
    source = [==[
return function(input, ctx)
  local path = input.path
  if type(path) ~= "string" or path == "" then
    error("read_file: path must be a non-empty string")
  end
  local full = vim.fn.fnamemodify(path, ":p")
  local existing = vim.fn.bufnr(full)
  if existing == -1 and vim.fn.filereadable(full) ~= 1 then
    error("read_file: cannot open " .. tostring(path) .. ": no such file")
  end
  local buf = vim.fn.bufadd(full)
  if not buf or buf == 0 then
    error("read_file: could not create a buffer for " .. tostring(path))
  end
  local ok_load, load_err = pcall(vim.fn.bufload, buf)
  if not ok_load then
    error("read_file: could not load " .. tostring(path) .. " (is it a directory?): " .. tostring(load_err))
  end

  -- Concurrent-editor checks: reads surface a competing editor as a NOTE,
  -- not an error — a safe reload refreshes the content below; a modified
  -- buffer stays the source of truth and is returned as-is.
  local registry = require("straps.registry")
  local notes = {}
  local st, rerr = registry.call("fn.reconcile_buf", buf)
  if st == nil then
    notes[#notes + 1] = "note: " .. input.path .. " " .. tostring(rerr)
  elseif st == "reloaded" then
    notes[#notes + 1] = "note: " .. input.path .. " changed on disk since it was"
      .. " last loaded — an external process or another agent is editing it;"
      .. " reloaded, this read returns the new content"
  end
  local wok, werr = registry.call("fn.check_writer", ctx and ctx.bufnr, buf)
  if wok == nil then
    notes[#notes + 1] = "note: " .. input.path .. " " .. tostring(werr)
  end
  registry.call("fn.mark_seen", ctx and ctx.bufnr, buf, false)

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local total = #lines
  local offset = math.max(1, tonumber(input.offset) or 1)
  local limit = math.min(tonumber(input.limit) or 2000, 2000)
  if offset > total then
    local msg = string.format("read_file: %s has %d lines; offset %d is past the end", input.path, total, offset)
    if #notes > 0 then msg = table.concat(notes, "\n") .. "\n" .. msg end
    return msg
  end
  local last = math.min(total, offset + limit - 1)
  local out = {}
  for _, n in ipairs(notes) do out[#out + 1] = n end
  for i = offset, last do
    out[#out + 1] = string.format("  %d\t%s", i, lines[i])
  end
  if last < total then
    out[#out + 1] = string.format(
      "[truncated: showing lines %d-%d of %d; call read_file again with offset=%d to continue]",
      offset, last, total, last + 1)
  end
  return table.concat(out, "\n")
end
]==],
  })

  -- --------------------------------------------------------------- write_file

  define({
    name = "tool.write_file",
    kind = "tool",
    doc = "Write content to a file, creating parent directories as needed and"
      .. " overwriting the file if it exists. The write goes THROUGH the file's"
      .. " Neovim buffer (loaded/created as needed and reused if already open, so"
      .. " unsaved user changes are respected): the whole buffer is replaced in a"
      .. " single undoable step and then written to disk, so the change lands in"
      .. " the file's native undo history — the user can revert it with `u`,"
      .. " `:earlier`, or undotree. Fails with a clear error when the file"
      .. " changed under this session (another agent or external process is"
      .. " editing it) — re-read the file and reapply the change. After writing,"
      .. " hook.after_write fires; if it"
      .. " returns a string (e.g. linter output), it is appended to the tool"
      .. " result. Parameters: path (required) — destination file path; content"
      .. " (required) — the complete new file contents.",
    input_schema = {
      type = "object",
      properties = {
        path = { type = "string", description = "Destination file path." },
        content = { type = "string", description = "Complete file contents to write." },
      },
      required = { "path", "content" },
    },
    source = [==[
return function(input, ctx)
  local registry = require("straps.registry")
  local path = input.path
  if type(path) ~= "string" or path == "" then
    error("write_file: path must be a non-empty string")
  end
  local full = vim.fn.fnamemodify(path, ":p")
  local dir = vim.fn.fnamemodify(full, ":h")
  if dir ~= "" and dir ~= "." and vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, "p")
  end

  -- Get (or create) the file's buffer and load it, WITHOUT wiping an already
  -- open buffer: bufadd returns the existing bufnr if the file is open, and
  -- bufload is a no-op when it is already loaded (unsaved user changes stay).
  local bok, buf = pcall(vim.fn.bufadd, full)
  if not bok or not buf or buf == 0 then
    error("write_file: could not create a buffer for " .. tostring(path) .. ": " .. tostring(buf))
  end
  local lok, lerr = pcall(vim.fn.bufload, buf)
  if not lok then
    error("write_file: could not load " .. tostring(path) .. " (is it a directory?): " .. tostring(lerr))
  end

  -- Concurrent-editor checks: a disk change under the buffer or another
  -- session's unseen write is an ERROR for the agent to react to (re-read,
  -- reapply) — never a merge. A safe reload only refreshes what the next
  -- read returns; this write never lands on content the caller has not seen.
  local st, rerr = registry.call("fn.reconcile_buf", buf)
  if st == nil then
    error("write_file: " .. tostring(path) .. " " .. tostring(rerr))
  elseif st == "reloaded" then
    error("write_file: " .. tostring(path) .. " changed on disk since its buffer"
      .. " was loaded — another agent or external process is editing this file;"
      .. " the buffer has been reloaded from disk, re-read the file and reapply"
      .. " your change if it still applies")
  end
  local wok, werr = registry.call("fn.check_writer", ctx and ctx.bufnr, buf)
  if wok == nil then
    error("write_file: " .. tostring(path) .. " " .. tostring(werr))
  end

  -- Split content into buffer lines. A trailing "\n" in the content maps to the
  -- file's final EOL (the buffer's implicit trailing newline), NOT an extra
  -- blank line; content with no trailing newline is written without one.
  local content = input.content or ""
  local lines = vim.split(content, "\n", { plain = true })
  local eol = true
  if content ~= "" and lines[#lines] == "" then
    table.remove(lines) -- drop the "" produced by the trailing newline
  else
    eol = false -- no trailing newline in the requested content
  end

  local ok, err = pcall(function()
    vim.bo[buf].fixendofline = false
    vim.bo[buf].endofline = eol
    vim.api.nvim_buf_call(buf, function()
      -- Break the undo sequence so this write is its OWN undo block (does not
      -- coalesce with an earlier programmatic change to the same buffer), then
      -- replace the whole buffer in one undoable step and persist it.
      vim.cmd("let &l:undolevels = &l:undolevels")
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      vim.cmd("silent noautocmd write")
    end)
  end)
  if not ok then
    -- E13: the buffer was created for a then-nonexistent file and something
    -- else created it on disk meanwhile (checktime cannot see never-edited
    -- buffers). Same competing-editor situation, same guidance.
    if tostring(err):find("E13", 1, true) then
      error("write_file: " .. tostring(path) .. " was created on disk by another"
        .. " agent or external process since this buffer was opened — re-read"
        .. " the file and reapply your change if it still applies")
    end
    error("write_file: failed to write " .. tostring(path) .. ": " .. tostring(err))
  end

  registry.call("fn.mark_seen", ctx and ctx.bufnr, buf, true)

  local n = vim.api.nvim_buf_line_count(buf)
  local result = string.format(
    "wrote %s (%d line%s) — undo with u in the buffer", path, n, n == 1 and "" or "s")
  local extra = registry.try_call("hook.after_write", path, ctx)
  if type(extra) == "string" and extra ~= "" then
    result = result .. "\n" .. extra
  end
  return result
end
]==],
  })

  -- ---------------------------------------------------------------- edit_file

  define({
    name = "tool.edit_file",
    kind = "tool",
    doc = "Edit a file by exact plain-text replacement. old_string is matched"
      .. " literally (no regex or Lua patterns) against the file's CURRENT buffer"
      .. " contents (so unsaved user edits are seen). Errors if old_string is not"
      .. " found, or if it occurs more than once and replace_all is not true —"
      .. " include enough surrounding context to make it unique. The edit is"
      .. " applied through the file's buffer as a single undoable step and then"
      .. " written to disk, so it lands in the file's native undo history — the"
      .. " user can revert it with `u`, `:earlier`, or undotree. Fails with a"
      .. " clear error when the file changed under this session (another agent"
      .. " or external process is editing it) — re-read and reapply."
      .. " hook.after_write"
      .. " fires (its string return, if any, is appended to the result)."
      .. " Parameters: path (required); old_string (required) — exact text to"
      .. " replace; new_string (required) — replacement text; replace_all"
      .. " (optional, default false) — replace every occurrence.",
    input_schema = {
      type = "object",
      properties = {
        path = { type = "string", description = "Path of the file to edit." },
        old_string = { type = "string", description = "Exact text to find (plain text, no patterns)." },
        new_string = { type = "string", description = "Text to replace it with." },
        replace_all = { type = "boolean", description = "Replace all occurrences (default false)." },
      },
      required = { "path", "old_string", "new_string" },
    },
    source = [==[
return function(input, ctx)
  local registry = require("straps.registry")
  local path = input.path
  local old, new = input.old_string, input.new_string or ""
  if type(path) ~= "string" or path == "" then
    error("edit_file: path must be a non-empty string")
  end
  if type(old) ~= "string" or old == "" then
    error("edit_file: old_string must be a non-empty string")
  end
  local full = vim.fn.fnamemodify(path, ":p")

  -- Load (or reuse) the file's buffer; the buffer's current lines are the
  -- haystack, so an already-open buffer's unsaved edits are matched as-is.
  local bok, buf = pcall(vim.fn.bufadd, full)
  if not bok or not buf or buf == 0 then
    error("edit_file: could not create a buffer for " .. tostring(path) .. ": " .. tostring(buf))
  end
  local lok, lerr = pcall(vim.fn.bufload, buf)
  if not lok then
    error("edit_file: could not load " .. tostring(path) .. " (is it a directory?): " .. tostring(lerr))
  end

  -- Concurrent-editor checks BEFORE reading the haystack: a disk change or
  -- another session's unseen write is an ERROR for the agent (re-read,
  -- reapply) — never a merge; the edit never matches against stale content.
  local st, rerr = registry.call("fn.reconcile_buf", buf)
  if st == nil then
    error("edit_file: " .. tostring(path) .. " " .. tostring(rerr))
  elseif st == "reloaded" then
    error("edit_file: " .. tostring(path) .. " changed on disk since its buffer"
      .. " was loaded — another agent or external process is editing this file;"
      .. " the buffer has been reloaded from disk, re-read the file and reapply"
      .. " your change if it still applies")
  end
  local wok, werr = registry.call("fn.check_writer", ctx and ctx.bufnr, buf)
  if wok == nil then
    error("edit_file: " .. tostring(path) .. " " .. tostring(werr))
  end

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local text = table.concat(lines, "\n")

  -- Count occurrences with plain-text find (no Lua patterns).
  local count, pos = 0, 1
  while true do
    local s, e = string.find(text, old, pos, true)
    if not s then break end
    count = count + 1
    pos = e + 1
  end
  if count == 0 then
    error("edit_file: old_string not found in " .. path)
  end
  if count > 1 and not input.replace_all then
    error(string.format(
      "edit_file: old_string matches %d times in %s; add more context to make it unique, or set replace_all=true",
      count, path))
  end

  -- Map a 0-based byte offset in `text` (lines joined by "\n") to a buffer
  -- (row, col) position, both 0-based, col in bytes within the line.
  local function pos_of(off)
    local row = 0
    while row < #lines do
      local llen = #lines[row + 1]
      if off <= llen then
        return row, off
      end
      off = off - llen - 1 -- consume the line and its joining newline
      row = row + 1
    end
    return row, off
  end

  local ok, err = pcall(function()
    vim.api.nvim_buf_call(buf, function()
      -- Break the undo sequence so this edit is its OWN undo block; then apply
      -- the replacement as a single undoable change and persist the buffer.
      vim.cmd("let &l:undolevels = &l:undolevels")
      if input.replace_all then
        -- Rebuild the whole text once and set every line in a single undoable
        -- step, so one `u` reverts all replacements.
        local parts, idx = {}, 1
        while true do
          local s, e = string.find(text, old, idx, true)
          if not s then break end
          parts[#parts + 1] = text:sub(idx, s - 1)
          parts[#parts + 1] = new
          idx = e + 1
        end
        parts[#parts + 1] = text:sub(idx)
        local out = table.concat(parts)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(out, "\n", { plain = true }))
      else
        -- Single occurrence: a precise set_text over just the matched byte range.
        local s, e = string.find(text, old, 1, true)
        local srow, scol = pos_of(s - 1)
        local erow, ecol = pos_of(e)
        vim.api.nvim_buf_set_text(buf, srow, scol, erow, ecol, vim.split(new, "\n", { plain = true }))
      end
      vim.cmd("silent noautocmd write")
    end)
  end)
  if not ok then
    error("edit_file: failed to apply edit to " .. tostring(path) .. ": " .. tostring(err))
  end

  registry.call("fn.mark_seen", ctx and ctx.bufnr, buf, true)

  local n = input.replace_all and count or 1
  local result = string.format(
    "edited %s (%d replacement%s) — undo with u in the buffer",
    path, n, n == 1 and "" or "s")
  local extra = registry.try_call("hook.after_write", path, ctx)
  if type(extra) == "string" and extra ~= "" then
    result = result .. "\n" .. extra
  end
  return result
end
]==],
  })

  -- --------------------------------------------------------------- patch_file

  define({
    name = "tool.patch_file",
    kind = "tool",
    doc = "Apply one or more structured line-range hunks to a file through its"
      .. " live Neovim buffer. Each hunk is {start_line, end_line, new_text,"
      .. " expected_old_text?}: 1-based inclusive lines to replace; for insertion,"
      .. " set end_line to start_line-1. Hunks are validated for overlap/staleness,"
      .. " buffer edit, saved to disk, and hook.after_write fires. Fails with a"
      .. " clear error when the file changed under this session (another agent"
      .. " or external process is editing it) — re-read and reapply. This is the"
      .. " structured alternative to exact-string edit_file when line ranges are"
      .. " already known. Parameters: path (required); hunks (required array).",
    input_schema = {
      type = "object",
      properties = {
        path = { type = "string", description = "Path of the file to patch." },
        hunks = {
          type = "array",
          description = "Line hunks: {start_line, end_line, new_text}. Use end_line=start_line-1 for insertion.",
          items = {
            type = "object",
            properties = {
              start_line = { type = "integer", description = "1-based first line to replace, or insertion point." },
              end_line = { type = "integer", description = "1-based last line to replace; may be start_line-1 for insertion." },
              new_text = { type = "string", description = "Replacement text for this range." },
              expected_old_text = { type = "string", description = "Optional exact text expected in the live buffer range before patching." },
            },
            required = { "start_line", "end_line", "new_text" },
          },
        },
      },
      required = { "path", "hunks" },
    },
    source = [==[
return function(input, ctx)
  local registry = require("straps.registry")
  local path = input.path
  if type(path) ~= "string" or path == "" then
    error("patch_file: path must be a non-empty string")
  end
  if type(input.hunks) ~= "table" or #input.hunks == 0 then
    error("patch_file: hunks must be a non-empty array")
  end
  local full = vim.fn.fnamemodify(path, ":p")
  local bok, buf = pcall(vim.fn.bufadd, full)
  if not bok or not buf or buf == 0 then
    error("patch_file: could not create a buffer for " .. tostring(path) .. ": " .. tostring(buf))
  end
  local lok, lerr = pcall(vim.fn.bufload, buf)
  if not lok then
    error("patch_file: could not load " .. tostring(path) .. " (is it a directory?): " .. tostring(lerr))
  end

  -- Concurrent-editor checks BEFORE validating ranges: a disk change or
  -- another session's unseen write is an ERROR for the agent (re-read,
  -- reapply) — never a merge; hunks never apply to stale line numbers.
  local st, rerr = registry.call("fn.reconcile_buf", buf)
  if st == nil then
    error("patch_file: " .. tostring(path) .. " " .. tostring(rerr))
  elseif st == "reloaded" then
    error("patch_file: " .. tostring(path) .. " changed on disk since its buffer"
      .. " was loaded — another agent or external process is editing this file;"
      .. " the buffer has been reloaded from disk, re-read the file and reapply"
      .. " your change if it still applies")
  end
  local wok, werr = registry.call("fn.check_writer", ctx and ctx.bufnr, buf)
  if wok == nil then
    error("patch_file: " .. tostring(path) .. " " .. tostring(werr))
  end

  local line_count = vim.api.nvim_buf_line_count(buf)
  local hunks, problems = {}, {}
  for i, h in ipairs(input.hunks) do
    local s, e = tonumber(h.start_line), tonumber(h.end_line)
    local text = h.new_text
    if not s or not e or type(text) ~= "string" then
      problems[#problems + 1] = ("#%d: needs integer start_line/end_line and string new_text"):format(i)
    elseif s < 1 or e < s - 1 then
      problems[#problems + 1] = ("#%d: invalid range %s-%s"):format(i, tostring(s), tostring(e))
    elseif s > line_count + 1 or e > line_count then
      problems[#problems + 1] = ("#%d: range %d-%d outside file with %d lines"):format(i, s, e, line_count)
    else
      hunks[#hunks + 1] = {
        idx = i,
        s = math.floor(s),
        e = math.floor(e),
        text = text,
        expected = type(h.expected_old_text) == "string" and h.expected_old_text or nil,
      }
    end
  end
  table.sort(hunks, function(a, b) return a.s < b.s end)
  for i = 2, #hunks do
    if hunks[i].s <= hunks[i - 1].e then
      problems[#problems + 1] = ("#%d overlaps #%d"):format(hunks[i].idx, hunks[i - 1].idx)
    end
  end
  local live_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local function slice_lines(lines, first, last)
    local out = {}
    for i = first, last do out[#out + 1] = lines[i] end
    return out
  end
  for _, h in ipairs(hunks) do
    if h.expected ~= nil then
      local actual = ""
      if h.e >= h.s then
        actual = table.concat(slice_lines(live_lines, h.s, h.e), "\n")
      end
      local expected = h.expected:gsub("\n$", "")
      if actual ~= expected then
        problems[#problems + 1] = ("#%d: expected_old_text mismatch at %d-%d"):format(h.idx, h.s, h.e)
      end
    end
  end
  if #problems > 0 then
    error("patch_file: refused:\n" .. table.concat(problems, "\n"))
  end

  local function split_replacement(text)
    if text == "" then return {} end
    local lines = vim.split(text, "\n", { plain = true })
    if lines[#lines] == "" then table.remove(lines) end
    return lines
  end

  local ok, err = pcall(function()
    vim.api.nvim_buf_call(buf, function()
      vim.cmd("let &l:undolevels = &l:undolevels")
      for i = #hunks, 1, -1 do
        local h = hunks[i]
        vim.api.nvim_buf_set_lines(buf, h.s - 1, h.e, false, split_replacement(h.text))
      end
      vim.cmd("silent noautocmd write")
    end)
  end)
  if not ok then
    error("patch_file: failed to apply patch to " .. tostring(path) .. ": " .. tostring(err))
  end
  registry.call("fn.mark_seen", ctx and ctx.bufnr, buf, true)

  local result = string.format("patched %s (%d hunk%s) — undo with u in the buffer",
    path, #hunks, #hunks == 1 and "" or "s")
  local extra = registry.try_call("hook.after_write", path, ctx)
  if type(extra) == "string" and extra ~= "" then result = result .. "\n" .. extra end
  return result
end
]==],
  })

  -- --------------------------------------------------------- fn.reconcile_buf

  -- Detection primitive for out-of-band DISK changes under a loaded file
  -- buffer (another Neovim instance, a shell tool, a formatter). The buffered
  -- write tools call it before editing so a stale buffer is surfaced to the
  -- agent as an error instead of a W12 prompt or a silent overwrite. The fn
  -- only detects and refreshes; policy (error vs note) lives at each call
  -- site. A registry fn rather than a local because tool sources are separate
  -- compiled chunks (no shared upvalues) and late-binding is the house style.
  define({
    name = "fn.reconcile_buf",
    kind = "fn",
    doc = "Detect an out-of-band disk change under a loaded file buffer."
      .. " Called as (buf, opts?) -> status, err: 'clean' (disk unchanged or"
      .. " nothing to do), 'reloaded' (disk changed, buffer was unmodified,"
      .. " buffer re-read from disk so subsequent reads see reality), or"
      .. " nil + error message (conflict: modified buffer, deleted file, or"
      .. " opts.no_reload suppressing the reload — buffer kept as-is).",
    source = [==[
return function(buf, opts)
  -- Unmodified + changed on disk: reload so later reads see reality, return
  -- "reloaded" (callers decide whether that is an error), unless
  -- opts.no_reload — then report a conflict instead (used by undo_edit,
  -- where a reload would mutate the undo tree it navigates).
  -- Modified + changed on disk, or file deleted: keep the buffer, nil + err.
  opts = opts or {}
  if not vim.api.nvim_buf_is_loaded(buf) then return "clean" end
  if vim.bo[buf].buftype ~= "" then return "clean" end

  local function conflict_err(deleted)
    if deleted then
      return nil, "deleted on disk; its buffer still holds the last-known content"
    end
    return nil, "changed on disk"
      .. (vim.bo[buf].modified and " while its buffer has unsaved changes;"
        .. " resolve in the buffer (or discard) before editing through it"
        or "; buffer not reloaded")
  end

  -- Sticky conflict: Vim CONSUMES the staleness once FileChangedShell has
  -- handled it — a second :checktime reports nothing — so a detected
  -- conflict is remembered on the buffer and only cleared when the buffer
  -- actually re-syncs with disk (re-read or written, via the autocmds
  -- below, or the safe reload here once the buffer is no longer modified).
  if vim.b[buf].straps_conflict then
    local name = vim.api.nvim_buf_get_name(buf)
    local gone = name == "" or vim.fn.filereadable(name) == 0
    if gone or vim.bo[buf].modified or opts.no_reload then
      return conflict_err(gone)
    end
    -- No longer modified and reloads are allowed: re-sync from disk. The
    -- reload lands as a NEW undo state when 'undoreload' permits (default:
    -- files under 10000 lines), so u usually still works.
    local okr = pcall(function()
      vim.api.nvim_buf_call(buf, function() vim.cmd("silent noautocmd edit!") end)
    end)
    if not okr then return conflict_err(false) end
    vim.b[buf].straps_conflict = nil
    pcall(vim.api.nvim_del_augroup_by_name, "straps_reconcile_" .. buf)
    return "reloaded"
  end

  local conflict, reloaded, deleted, benign = false, false, false, false
  local au = vim.api.nvim_create_autocmd("FileChangedShell", {
    buffer = buf,
    callback = function()
      -- "deleted": fcs_choice=reload does not work for a deleted file; a
      -- later write would recreate it from buffer content the caller never
      -- chose to assert — treat as conflict.
      if vim.v.fcs_reason == "deleted" then
        vim.v.fcs_choice = "" -- keep buffer, no prompt
        conflict, deleted = true, true
      elseif vim.bo[buf].modified or opts.no_reload then
        vim.v.fcs_choice = "" -- keep buffer, no prompt
        conflict = true
      else
        -- "time" (touch) / "mode" (chmod): content is identical (Vim
        -- compares before reporting "time"), so the reload below only
        -- re-syncs Vim's recorded stat — report it as "clean", no error.
        benign = vim.v.fcs_reason == "time" or vim.v.fcs_reason == "mode"
        vim.v.fcs_choice = "reload"
        reloaded = true
      end
    end,
  })
  -- 'autoread' (on by default) makes checktime reload an unmodified buffer
  -- WITHOUT firing FileChangedShell — the callback above would never run and
  -- a real reload would be invisible. Suppress it buffer-locally so the
  -- autocmd is always the decision point ('autoread' is global-local;
  -- "setlocal autoread<" restores the global-following state).
  vim.api.nvim_buf_call(buf, function()
    vim.cmd("setlocal noautoread")
    -- checktime with a buffer argument: bare :checktime scans ALL buffers
    -- and would fire FileChangedShell for buffers we do not own.
    pcall(vim.cmd, "checktime " .. buf)
    vim.cmd("setlocal autoread<")
  end)
  pcall(vim.api.nvim_del_autocmd, au)
  if conflict then
    -- Remember the (now consumed) conflict; clear it when the buffer truly
    -- re-syncs with disk: re-read (user :e/:e!) or written (user :w!).
    vim.b[buf].straps_conflict = true
    local grp = vim.api.nvim_create_augroup("straps_reconcile_" .. buf, { clear = true })
    vim.api.nvim_create_autocmd({ "BufReadPost", "BufWritePost" }, {
      group = grp,
      buffer = buf,
      callback = function()
        vim.b[buf].straps_conflict = nil
        pcall(vim.api.nvim_del_augroup_by_name, "straps_reconcile_" .. buf)
      end,
    })
    return conflict_err(deleted)
  end
  if benign then return "clean" end
  return reloaded and "reloaded" or "clean"
end
]==],
  })

  -- ---------------------------------------------------------- fn.check_writer

  -- Detection primitive for SAME-instance concurrent sessions, which share
  -- buffers so disk never diverges and fn.reconcile_buf cannot see them.
  -- Each session records the changedtick it last observed per file buffer
  -- (vim.b[session].straps_seen_ticks, keyed by file bufnr as a string —
  -- vim.b tables are msgpack round-tripped); each buffered write stamps the
  -- file buffer with the writing session (vim.b[file].straps_last_writer).
  -- A tick change NOT matching a straps write stamp is treated as user
  -- editing — edit tools deliberately stack on unsaved user changes.
  define({
    name = "fn.check_writer",
    kind = "fn",
    doc = "Detect a concurrent straps session's write to a file buffer."
      .. " Called as (ctx_bufnr, buf) -> ok, err: true when this session has"
      .. " no recorded view of the buffer, the buffer is unchanged since"
      .. " observed, or the latest change is not another session's stamped"
      .. " write; nil + error message when another session's write is the"
      .. " latest change (the message names that session and its task).",
    source = [==[
return function(ctx_bufnr, buf)
  -- Fail open on a missing/invalid session buffer (tests drive tools with
  -- ctx = { bufnr = 0 }; the real loop always passes the session bufnr).
  if type(ctx_bufnr) ~= "number" or ctx_bufnr <= 0
    or not vim.api.nvim_buf_is_valid(ctx_bufnr) then
    return true
  end
  if not vim.api.nvim_buf_is_loaded(buf) then return true end
  local seen = vim.b[ctx_bufnr].straps_seen_ticks
  local seen_tick = type(seen) == "table" and seen[tostring(buf)] or nil
  if seen_tick == nil then return true end -- never observed: no check
  local tick = vim.b[buf].changedtick
  if tick == seen_tick then return true end
  local stamp = vim.b[buf].straps_last_writer
  if type(stamp) ~= "table" or stamp.tick ~= tick then
    return true -- latest change is not a stamped straps write: user editing
  end
  if stamp.session == ctx_bufnr then return true end
  local who = "session " .. tostring(stamp.session)
  if type(stamp.task) == "string" and stamp.task ~= "" then
    who = who .. ', task: "' .. stamp.task .. '"'
  end
  return nil, "modified by another agent (" .. who .. ") since this session"
    .. " last read it — re-read the file and reapply your change if it still applies"
end
]==],
  })

  -- ------------------------------------------------------------- fn.mark_seen

  -- Bookkeeping counterpart to fn.check_writer, shared by every tool that
  -- reads or writes through a file buffer (tool sources are separate chunks,
  -- so shared code lives in the registry). Records the buffer's current
  -- changedtick in the session's seen-tick map; with wrote=true also stamps
  -- the file buffer with this session as the last writer.
  define({
    name = "fn.mark_seen",
    kind = "fn",
    doc = "Record that a session observed (or wrote) a file buffer's current"
      .. " state. Called as (ctx_bufnr, buf, wrote). Updates the session's"
      .. " straps_seen_ticks map; when wrote is true, also sets the file"
      .. " buffer's straps_last_writer stamp {session, tick, task}. Tolerates"
      .. " an invalid/absent session buffer (no-op).",
    source = [==[
return function(ctx_bufnr, buf, wrote)
  if not vim.api.nvim_buf_is_loaded(buf) then return end
  -- Fail open on a missing/invalid session buffer (tests drive tools with
  -- ctx = { bufnr = 0 }): nothing recorded, nothing stamped — an unstamped
  -- change reads as user editing to other sessions.
  if type(ctx_bufnr) ~= "number" or ctx_bufnr <= 0
    or not vim.api.nvim_buf_is_valid(ctx_bufnr) then
    return
  end
  local tick = vim.b[buf].changedtick
  if wrote then
    local task = vim.b[ctx_bufnr].straps_task
    vim.b[buf].straps_last_writer = {
      session = ctx_bufnr,
      tick = tick,
      task = type(task) == "string" and task or nil,
    }
  end
  -- vim.b tables are msgpack round-tripped: string keys, reassign to mutate.
  local seen = vim.b[ctx_bufnr].straps_seen_ticks
  if type(seen) ~= "table" then seen = {} end
  seen[tostring(buf)] = tick
  vim.b[ctx_bufnr].straps_seen_ticks = seen
end
]==],
  })

  -- ------------------------------------------------------------ fn.peer_agents

  -- The awareness counterpart to fn.check_writer: that fn tells an agent about
  -- a neighbour at the moment they collide, this one tells it they exist at
  -- all. Same-instance only — sessions in another Neovim share nothing but
  -- disk, where the only signal is fn.reconcile_buf's divergence check.
  define({
    name = "fn.peer_agents",
    kind = "fn",
    doc = "Describe every OTHER straps session in this Neovim. Called as"
      .. " (ctx_bufnr) -> list of { bufnr, label, running, parent, relation"
      .. " ('parent'|'child'|'sibling'|'peer'), task, depth, files }, running"
      .. " sessions first then by bufnr. Sessions are found by scanning buffers"
      .. " for b:straps_session, so IDLE ones are included (loop.running_sessions"
      .. " sees only active runs); files are the paths each peer last wrote,"
      .. " read from the b:straps_last_writer stamps fn.mark_seen leaves.",
    source = [==[
return function(ctx_bufnr)
  -- vim.b on an invalid buffer throws; every read here is pcall-wrapped, the
  -- same defensive idiom editor.lua's is_session uses.
  local function bvar(b, name)
    local ok, v = pcall(function() return vim.b[b][name] end)
    if ok then return v end
  end
  local function valid(b)
    return type(b) == "number" and b > 0 and vim.api.nvim_buf_is_valid(b)
  end

  local running = {}
  pcall(function()
    for _, b in ipairs(require("straps.loop").running_sessions()) do
      running[b] = true
    end
  end)

  -- Which files each session most recently wrote, from the write stamps
  -- fn.mark_seen leaves on the FILE buffers. Numbers survive vim.b's msgpack
  -- round trip (fn.check_writer compares stamp.session to a bufnr the same way).
  local wrote = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if valid(b) then
      local stamp = bvar(b, "straps_last_writer")
      if type(stamp) == "table" and type(stamp.session) == "number" then
        local name = vim.api.nvim_buf_get_name(b)
        if name ~= "" then
          local list = wrote[stamp.session] or {}
          list[#list + 1] = vim.fn.fnamemodify(name, ":.")
          wrote[stamp.session] = list
        end
      end
    end
  end

  local my_parent = valid(ctx_bufnr) and bvar(ctx_bufnr, "straps_parent") or nil
  if not valid(my_parent) then my_parent = nil end

  local out = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if b ~= ctx_bufnr and valid(b) and bvar(b, "straps_session") == true then
      local parent = bvar(b, "straps_parent")
      if not valid(parent) then parent = nil end
      local relation = "peer"
      if parent == ctx_bufnr then
        relation = "child"
      elseif b == my_parent then
        relation = "parent"
      elseif parent ~= nil and parent == my_parent then
        relation = "sibling"
      end
      local label = "buffer " .. tostring(b)
      pcall(function() label = require("straps.ui").session_label(b) end)
      local task = bvar(b, "straps_task")
      out[#out + 1] = {
        bufnr = b,
        label = label,
        running = running[b] == true,
        parent = parent,
        relation = relation,
        task = type(task) == "string" and task or nil,
        depth = tonumber(bvar(b, "straps_spawn_depth")) or 0,
        files = wrote[b] or {},
      }
    end
  end
  table.sort(out, function(a, b)
    if a.running ~= b.running then return a.running end
    return a.bufnr < b.bufnr
  end)
  return out
end
]==],
  })

  -- --------------------------------------------------------------------- bash

  define({
    name = "tool.bash",
    kind = "tool",
    doc = "Run a shell command via `bash -lc` and return its result with"
      .. " clearly labeled sections: exit code, stdout, stderr. Never use this"
      .. " tool to search, read, or inspect files: use the grep tool instead of shell"
      .. " grep/rg (it also populates this session's findings list), tree/path_info/glob"
      .. " instead of find/ls, and read_file instead of cat/head/tail. For a"
      .. " build/test/lint command whose output is compiler/linter-style"
      .. " diagnostics, prefer run_quickfix — it parses them into this session's"
      .. " findings list and returns a compact summary instead of a wall of text."
      .. " Parameters:"
      .. " command (required) — the shell command line to execute; timeout_ms"
      .. " (optional, default 120000) — the process is killed if it runs longer"
      .. " than this many milliseconds (exit code 124 indicates a timeout)."
      .. " Refuses bare read/search/list/stat/fetch commands (cat/head/tail/sed -n,"
      .. " grep/rg, ls/find/fd/stat/file, curl/wget with no pipe or redirect) in favor"
      .. " of the vim-native read_file, grep, tree/path_info, and fetch_url tools.",
    input_schema = {
      type = "object",
      properties = {
        command = { type = "string", description = "Shell command to run with bash -lc." },
        timeout_ms = { type = "integer", description = "Timeout in milliseconds (default 120000)." },
      },
      required = { "command" },
    },
    source = [==[
return function(input, ctx)
  local cmd = input.command or ""
  -- Redirect plain read/search/list commands to the vim-native tools. Only
  -- bare invocations are refused: any pipe, redirect, or shell logic means
  -- the command does more than the dedicated tool could, so it runs.
  local trimmed = cmd:match("^%s*(.-)%s*$")
  local has_shell_logic = trimmed:find("[|><;&`$(]") or trimmed:find("%f[%a]sudo%f[%A]")
  if not has_shell_logic then
    local redirect
    if trimmed:match("^cat%s+%S")
      or trimmed:match("^head%s+%S")
      or trimmed:match("^tail%s+%S")
      or trimmed:match("^sed%s+%-n%s") then
      redirect = "tool.read_file (supports offset/limit, gives line numbers)"
    elseif trimmed:match("^grep%s+%S") or trimmed:match("^rg%s+%S") then
      redirect = "tool.grep (regex search, also populates this session's findings list)"
    elseif trimmed == "ls" or trimmed:match("^ls%s")
      or trimmed:match("^find%s+%S") or trimmed:match("^fd%s+%S") then
      redirect = "tool.tree or tool.glob (bounded file listings)"
    elseif trimmed:match("^stat%s+%S") or trimmed:match("^file%s+%S") then
      redirect = "tool.path_info (filesystem metadata without shelling out)"
    elseif trimmed:match("^curl%s+https?://") or trimmed:match("^wget%s+https?://") then
      redirect = "tool.fetch_url (bounded web fetch without ambient shell state)"
    end
    if redirect then
      return "bash: refusing plain read/search/list command (" .. trimmed ..
        "). Use " .. redirect .. " instead."
    end
  end

  local timeout_ms = tonumber(input.timeout_ms) or 120000
  local cap = 262144
  local stdout, stderr = {}, {}
  local out_len, err_len = 0, 0
  local capped = false
  local proc
  local function stop_for_cap()
    if proc then pcall(function() proc:kill(9) end) end
  end
  local function take(dst, len_name, chunk)
    if not chunk or chunk == "" then return end
    local len = (len_name == "out") and out_len or err_len
    if len >= cap then capped = true; stop_for_cap(); return end
    local keep = math.min(#chunk, cap - len)
    dst[#dst + 1] = chunk:sub(1, keep)
    if keep < #chunk then capped = true; stop_for_cap() end
    if len_name == "out" then out_len = len + keep else err_len = len + keep end
  end
  local res = ctx.await(function(resolve)
    proc = vim.system(
      { "bash", "-lc", cmd },
      {
        text = true,
        timeout = timeout_ms,
        stdout = function(_, chunk) take(stdout, "out", chunk) end,
        stderr = function(_, chunk) take(stderr, "err", chunk) end,
      },
      function(out) resolve(out) end)
    if ctx.on_cancel then
      ctx.on_cancel(function() pcall(function() proc:kill(9) end) end)
    end
  end)
  local lines = { "exit code: " .. tostring(res.code) }
  if res.code == 124 then
    lines[#lines] = lines[#lines] .. " (killed: exceeded timeout of " .. timeout_ms .. " ms)"
  end
  if capped then
    lines[#lines + 1] = "output truncated at " .. cap .. " bytes per stream"
  end
  lines[#lines + 1] = "stdout:"
  lines[#lines + 1] = table.concat(stdout)
  lines[#lines + 1] = "stderr:"
  lines[#lines + 1] = table.concat(stderr)
  return table.concat(lines, "\n")
end
]==],
  })

  -- ---------------------------------------------------------- run_in_terminal

  define({
    name = "tool.run_in_terminal",
    kind = "tool",
    doc = "Run a shell command in a visible :terminal split so the user can"
      .. " WATCH the output stream live — use it for test suites, builds, and"
      .. " anything long-running or interesting; use bash for quick, quiet"
      .. " commands. Focus stays where the user was; the split keeps streaming."
      .. " The full terminal output is also returned. When the command exits 0"
      .. " the split is closed automatically (kept only if it cannot be closed,"
      .. " e.g. it is the last window — the result note says which happened);"
      .. " on failure or timeout it is left open for inspection (the user"
      .. " closes it with :q). If the job cannot start at all, the empty split"
      .. " is cleaned up and the tool errors."
      .. " Parameters: command (required) — shell command run via bash -lc;"
      .. " timeout_ms (optional, default 300000) — the job is stopped if it"
      .. " runs longer.",
    input_schema = {
      type = "object",
      properties = {
        command = { type = "string", description = "Shell command to run in the terminal split." },
        timeout_ms = { type = "integer", description = "Timeout in milliseconds (default 300000)." },
      },
      required = { "command" },
    },
    source = [==[
return function(input, ctx)
  local cmd = input.command
  if type(cmd) ~= "string" or cmd == "" then
    error("run_in_terminal: command must be a non-empty string")
  end
  local timeout_ms = tonumber(input.timeout_ms) or 300000

  local prev_win = vim.api.nvim_get_current_win()
  vim.cmd("botright 15new")
  local term_buf = vim.api.nvim_get_current_buf()

  local timed_out, finished = false, false
  local code, start_err = ctx.await(function(resolve)
    local function on_exit(_, c)
      finished = true
      resolve(c)
    end
    -- nvim 0.11+: jobstart {term=true}; older: termopen. Both must run with
    -- the fresh scratch buffer current, so start BEFORE restoring focus.
    local job = 0
    local okj, j = pcall(vim.fn.jobstart, { "bash", "-lc", cmd },
      { term = true, on_exit = on_exit })
    if okj and type(j) == "number" and j > 0 then
      job = j
    else
      local okt, t = pcall(vim.fn.termopen, { "bash", "-lc", cmd }, { on_exit = on_exit })
      if okt and type(t) == "number" and t > 0 then job = t end
    end
    if job <= 0 then
      resolve(nil, "could not start the terminal job")
      return
    end
    pcall(vim.api.nvim_set_current_win, prev_win)
    vim.defer_fn(function()
      if not finished then
        timed_out = true
        pcall(vim.fn.jobstop, job)
        -- jobstop sends SIGTERM; a child trapping/ignoring it survives and
        -- the split would keep running while we report a timeout. Escalate to
        -- SIGKILL on the process group after a short grace period.
        vim.defer_fn(function()
          if not finished then
            local pid = tonumber(vim.fn.jobpid(job))
            if pid then pcall(vim.uv.kill, -pid, 9) end
          end
        end, 2000)
      end
    end, timeout_ms)
    if ctx.on_cancel then
      ctx.on_cancel(function() pcall(vim.fn.jobstop, job) end)
    end
  end)
  if start_err then
    -- The job never started, so the split holds nothing to inspect: close it,
    -- wipe its buffer, and put the user back where they were (focus was never
    -- restored on this path — the job had to start with the split current).
    for _, win in ipairs(vim.fn.win_findbuf(term_buf)) do
      pcall(vim.api.nvim_win_close, win, true)
    end
    if vim.api.nvim_buf_is_valid(term_buf) then
      pcall(vim.api.nvim_buf_delete, term_buf, { force = true })
    end
    pcall(vim.api.nvim_set_current_win, prev_win)
    error("run_in_terminal: " .. start_err)
  end

  local out_lines = {}
  pcall(function()
    out_lines = vim.api.nvim_buf_get_lines(term_buf, 0, -1, false)
  end)
  while #out_lines > 0 and out_lines[#out_lines]:match("^%s*$") do
    table.remove(out_lines)
  end

  -- On success there is nothing left to inspect: close the split and wipe the
  -- terminal buffer. Failures and timeouts keep it open for the user. If a
  -- window survives (e.g. the split became the last window, which cannot be
  -- closed), keep the buffer too so what it shows stays inspectable.
  local closed = false
  if code == 0 and not timed_out then
    for _, win in ipairs(vim.fn.win_findbuf(term_buf)) do
      pcall(vim.api.nvim_win_close, win, true)
    end
    closed = #vim.fn.win_findbuf(term_buf) == 0
    if closed and vim.api.nvim_buf_is_valid(term_buf) then
      pcall(vim.api.nvim_buf_delete, term_buf, { force = true })
    end
  end

  return "exit code: " .. tostring(code)
    .. (timed_out and (" (stopped: exceeded timeout of " .. timeout_ms .. " ms)") or "")
    .. "\noutput:\n" .. table.concat(out_lines, "\n")
    .. (closed and "\n[terminal split closed]"
      or "\n[terminal split left open — the user can close it with :q]")
end
]==],
  })

  -- ------------------------------------------------------------- run_quickfix

  define({
    name = "tool.run_quickfix",
    kind = "tool",
    doc = "Run a shell command (a build, a test run, a linter, a typecheck) and"
      .. " parse its output into this session's findings list (the session"
      .. " window's location list when on-screen, else the global quickfix list)"
      .. " through Vim's native errorformat, then open it — so a failing build"
      .. " lands as :lnext/:lprev (or :cnext/:cprev when it fell back) navigable"
      .. " file:line entries in the user's editor instead of a wall of"
      .. " text in the transcript. Use this instead of bash/run_in_terminal when"
      .. " the command emits compiler/linter-style diagnostics you want the user"
      .. " to step through. The result the agent sees is a compact summary: exit"
      .. " code and the parsed entries as `file:line:col: message` (capped),"
      .. " which is far smaller than raw output. Parameters: command (required)"
      .. " — the shell command, run via bash -lc; errorformat (optional) — a Vim"
      .. " 'errorformat' string describing the output (e.g."
      .. " \"%f:%l:%c: %m\" for `file:line:col: message`); when omitted, the"
      .. " editor's current &errorformat is used. title (optional) — findings"
      .. " list title. timeout_ms (optional, default 300000). open (optional,"
      .. " default true) — open the findings list window when there are entries.",
    input_schema = {
      type = "object",
      properties = {
        command = { type = "string", description = "Shell command to run with bash -lc." },
        errorformat = { type = "string", description = "Vim 'errorformat' describing the command output; omit to use the editor's current &errorformat." },
        title = { type = "string", description = "Findings list title (default: the command)." },
        timeout_ms = { type = "integer", description = "Timeout in milliseconds (default 300000)." },
        open = { type = "boolean", description = "Open the findings list window when there are entries (default true)." },
      },
      required = { "command" },
    },
    source = [==[
return function(input, ctx)
  local cmd = input.command
  if type(cmd) ~= "string" or cmd == "" then
    error("run_quickfix: command must be a non-empty string")
  end
  local timeout_ms = tonumber(input.timeout_ms) or 300000

  local res = ctx.await(function(resolve)
    local proc = vim.system(
      { "bash", "-lc", cmd },
      { text = true, timeout = timeout_ms },
      function(out) resolve(out) end)
    if ctx.on_cancel then
      ctx.on_cancel(function() pcall(function() proc:kill(9) end) end)
    end
  end)

  -- Diagnostics land on either stream (compilers use stderr, many test
  -- runners stdout); feed both, in that order, to the errorformat parser.
  local raw = (res.stdout or "") .. (res.stderr or "")
  local lines = vim.split(raw, "\n", { plain = true })
  while #lines > 0 and lines[#lines] == "" do
    table.remove(lines)
  end

  local title = (type(input.title) == "string" and input.title ~= "" and input.title)
    or ("straps: " .. cmd)
  -- Parse with the native errorformat machinery: the given efm, else the
  -- editor's current &errorformat. getqflist({lines, efm}) never touches the
  -- real list, so we can filter to valid entries before setting it.
  local parse_opts = { lines = lines, title = title }
  if type(input.errorformat) == "string" and input.errorformat ~= "" then
    parse_opts.efm = input.errorformat
  end
  local parsed = vim.fn.getqflist(parse_opts)
  local all = parsed.items or {}
  local valid = {}
  for _, it in ipairs(all) do
    -- valid==1 means the efm matched a real location; drop noise lines.
    if it.valid == 1 and (it.bufnr and it.bufnr > 0 or it.filename) then
      valid[#valid + 1] = it
    end
  end

  -- Replace THIS session's findings list with the valid entries (session
  -- window's location list when on-screen — isolated from other sessions —
  -- else the global quickfix list). A genuine empty result clears it, so a
  -- passing build visibly empties a prior failure's list.
  local open = input.open
  if open == nil then open = true end
  local list_kind = "quickfix"
  do
    local ok, kind = pcall(function()
      return require("straps.ui").set_locations(ctx and ctx.bufnr, { title = title, items = valid }, open)
    end)
    if ok and kind then list_kind = kind end
  end
  local nav = (list_kind == "loclist") and ":lnext/:lprev" or ":cnext/:cprev"

  -- Compact summary for the agent: the exit code and the parsed locations,
  -- NOT the raw output (which is what the list is for). Cap the listing.
  local out = { "exit code: " .. tostring(res.code) }
  if res.code == 124 then
    out[#out] = out[#out] .. " (killed: exceeded timeout of " .. timeout_ms .. " ms)"
  end
  if #valid == 0 then
    out[#out + 1] = list_kind .. ": no entries parsed (0 diagnostics)"
    if raw:match("%S") and not (type(input.errorformat) == "string" and input.errorformat ~= "") then
      out[#out + 1] = "note: output was non-empty but matched no errorformat entry —"
        .. " pass an explicit `errorformat` describing this command's output."
    end
  else
    out[#out + 1] = ("%s: %d entr%s (%s) — the user can step them with %s")
      :format(list_kind, #valid, #valid == 1 and "y" or "ies", title, nav)
    local cap = 100
    for i = 1, math.min(#valid, cap) do
      local it = valid[i]
      local name = it.filename
      if (not name or name == "") and it.bufnr and it.bufnr > 0 then
        name = vim.api.nvim_buf_get_name(it.bufnr)
      end
      name = name and vim.fn.fnamemodify(name, ":.") or "?"
      local typ = (it.type and it.type ~= "") and (it.type .. " ") or ""
      out[#out + 1] = string.format("%s:%d:%d: %s%s",
        name, it.lnum or 0, it.col or 0, typ, (it.text or ""):gsub("^%s+", ""))
    end
    if #valid > cap then
      out[#out + 1] = ("[... %d more; see the %s list]"):format(#valid - cap, list_kind)
    end
  end
  return table.concat(out, "\n")
end
]==],
  })

  -- -------------------------------------------------------------------- spawn

  define({
    name = "tool.spawn",
    kind = "tool",
    doc = "Launch a subagent on a task in its OWN session buffer and return"
      .. " IMMEDIATELY with a handle — the subagent runs concurrently while you"
      .. " keep working. Call spawn N times (batch the calls in one turn) to fan"
      .. " out N subagents that all run in parallel, then collect their answers"
      .. " with spawn_wait. The child is a full straps session: its transcript"
      .. " is a real buffer the user can open, watch and steer (show=true opens"
      .. " it in a split). The child inherits this session's registry view —"
      .. " your session-scoped tools included — but anything IT defines lands"
      .. " in its own scope and never leaks back. Use it to isolate context:"
      .. " the child burns its own transcript on a broad investigation and you"
      .. " receive only its final answer (via spawn_wait). The task must be"
      .. " COMPLETE and self-contained; the child sees none of this"
      .. " conversation. Returns the child's handle (buffer number) to pass to"
      .. " spawn_wait. Parameters: task (required); system (optional) — extra"
      .. " standing instructions, prepended to the task; provider (optional) —"
      .. " child backend, inherited from this session/global default when unset; tools (optional array"
      .. " of tool names) — the child sees only these tools; readonly (optional"
      .. " boolean) — the child may use only auto-allowed read-only tools,"
      .. " every write is denied without prompting; show (optional boolean) —"
      .. " open the child's transcript in a split; max_turns (optional,"
      .. " default 24); model (optional) — run the child on this model id"
      .. " instead of the session's; effort (optional) — extended-thinking"
      .. " effort name for the child; timeout_ms (optional, default 600000) —"
      .. " enforced by spawn_wait.",
    input_schema = {
      type = "object",
      properties = {
        task = { type = "string", description = "Complete, self-contained instructions for the subagent." },
        system = { type = "string", description = "Extra standing instructions for the child." },
        provider = { type = "string", enum = { "anthropic", "openai" }, description = "Provider for the child (default: this session's provider/global default)." },
        tools = {
          type = "array",
          items = { type = "string" },
          description = "Restrict the child to these tool names.",
        },
        readonly = { type = "boolean", description = "Read-only child: every write tool is denied." },
        show = { type = "boolean", description = "Open the child's transcript buffer in a split." },
        max_turns = { type = "integer", description = "Child turn budget (default 24)." },
        model = { type = "string", description = "Model id for the child (default: this session's model)." },
        effort = { type = "string", description = "Extended-thinking effort name for the child (default: this session's effort)." },
        timeout_ms = { type = "integer", description = "Wall-clock cap in milliseconds (default 600000), enforced by spawn_wait." },
      },
      required = { "task" },
    },
    source = [==[
return function(input, ctx)
  local task = input.task
  if type(task) ~= "string" or task == "" then
    error("spawn: task must be a non-empty string")
  end
  local registry = require("straps.registry")
  local state = require("straps.state")
  local loop = require("straps.loop")

  -- Depth guard: subagents do not spawn sub-subagents unless the user
  -- raises config.max_spawn_depth.
  local depth = 0
  pcall(function() depth = vim.b[ctx.bufnr].straps_spawn_depth or 0 end)
  local max_depth = 1
  pcall(function()
    max_depth = require("straps").config.max_spawn_depth or 1
  end)
  if depth >= max_depth then
    return "spawn: refused — subagent depth limit (" .. max_depth
      .. ") reached; do this work yourself"
  end

  -- Compose the child's prompt for its actual shape: no # Subagents section,
  -- a # You are a subagent section, plus readonly / tool-restriction notes.
  local child = state.new_session({
    subagent = true,
    readonly = input.readonly and true or nil,
    tools = (type(input.tools) == "table" and #input.tools > 0) and input.tools or nil,
  })
  vim.b[child].straps_spawn_depth = depth + 1
  vim.b[child].straps_max_turns = math.floor(tonumber(input.max_turns) or 24)
  -- Timeout is stored for spawn_wait to enforce (spawn itself returns at once).
  -- Stamp the start time too, so the deadline measures the child's real
  -- lifetime, not just the time spent inside spawn_wait.
  vim.b[child].straps_spawn_timeout_ms = tonumber(input.timeout_ms) or 600000
  vim.b[child].straps_spawn_started_ms = vim.uv.now()
  -- Provider / model / effort: explicit spawn args win; else inherit the
  -- PARENT's per-buffer overrides if it has them (so a subagent matches its
  -- session by default), else leave unset so fn.provider falls back globally.
  do
    local pp, pm, pom, pe
    pcall(function()
      pp = vim.b[ctx.bufnr].straps_provider
      pm = vim.b[ctx.bufnr].straps_model
      pom = vim.b[ctx.bufnr].straps_openai_model
      pe = vim.b[ctx.bufnr].straps_effort
    end)
    local provider = input.provider or pp
    local model = input.model or ((provider == "openai") and pom or pm)
    local effort = input.effort or pe
    if type(provider) == "string" and provider ~= "" then vim.b[child].straps_provider = provider end
    if type(model) == "string" and model ~= "" then
      if provider == "openai" then vim.b[child].straps_openai_model = model else vim.b[child].straps_model = model end
    end
    if type(effort) == "string" and effort ~= "" then vim.b[child].straps_effort = effort end
  end
  -- Parentage lets ui.pick_agents / the statusline show the spawn tree: who
  -- launched this subagent, and a one-line description of its task.
  vim.b[child].straps_parent = ctx.bufnr
  vim.b[child].straps_task = (task:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")):sub(1, 80)
  -- Chain the child's registry scope under THIS session: it reads our
  -- session-scoped entries; its own defines shadow privately.
  registry.ensure_scope(child, ctx.bufnr)

  if type(input.tools) == "table" and #input.tools > 0 then
    vim.b[child].straps_tool_filter = input.tools
  end
  if input.readonly then
    registry.define({
      name = "hook.confirm",
      kind = "hook",
      doc = "spawn: readonly child — allow read-only tools, deny everything else.",
      source = [[
return function(name, tin, tctx)
  -- Permit exactly the read-only tool calls (fn.readonly_policy is the shared
  -- definition; see hook.confirm), deny every write.
  if require("straps.registry").try_call("fn.readonly_policy", name, tin) then
    return true
  end
  return false, "readonly subagent: " .. tostring(name) .. " is not allowed"
end
]],
    }, { scope = child })
  end

  local header = task
  if type(input.system) == "string" and input.system ~= "" then
    header = input.system .. "\n\n" .. task
  end
  state.append_text(child, header)

  loop.start(child)
  -- If the parent run is cancelled before the matching spawn_wait, nothing
  -- else would stop this child; register a cancel handler so it is not
  -- orphaned (spawn_wait installs its own for the wait window).
  if ctx and ctx.on_cancel then
    ctx.on_cancel(function()
      pcall(function()
        if vim.api.nvim_buf_is_valid(child) and loop.running(child) then
          loop.stop(child)
        end
      end)
    end)
  end
  if input.show then
    pcall(function()
      local prev = vim.api.nvim_get_current_win()
      vim.cmd("botright vsplit")
      vim.api.nvim_win_set_buf(vim.api.nvim_get_current_win(), child)
      pcall(vim.api.nvim_set_current_win, prev)
    end)
  end

  -- Fire-and-return: the child is now running on its own coroutine. Report its
  -- handle so the parent can launch more (they run concurrently) and later
  -- collect answers with spawn_wait. Cancelling the parent while children are
  -- outstanding is handled by spawn_wait's cancel handler.
  local name = vim.api.nvim_buf_get_name(child)
  local where = name ~= "" and vim.fn.fnamemodify(name, ":~:.") or ("buffer " .. child)
  return ("subagent started — buffer %d, transcript: %s\n"
    .. "collect its answer with spawn_wait{ buffers = { %d } }"):format(child, where, child)
end
]==],
  })

  -- ---------------------------------------------------------------- spawn_wait

  define({
    name = "tool.spawn_wait",
    kind = "tool",
    doc = "Wait for one or more subagents (started with spawn) to finish and"
      .. " return their final answers. Pass the buffer handles spawn returned;"
      .. " all are awaited CONCURRENTLY, so waiting on N children costs the"
      .. " time of the slowest, not the sum. Each child's own timeout_ms (set"
      .. " at spawn) is enforced here; a child that overruns is stopped and"
      .. " reported as timed out. Cancelling the parent run stops every"
      .. " outstanding child. Returns one section per child: its handle, task,"
      .. " status (finished/timed out), and its final answer text."
      .. " Parameters: buffers (required) — array of subagent buffer numbers"
      .. " returned by spawn.",
    input_schema = {
      type = "object",
      properties = {
        buffers = {
          type = "array",
          items = { type = "integer" },
          description = "Subagent buffer numbers returned by spawn.",
        },
      },
      required = { "buffers" },
    },
    source = [==[
return function(input, ctx)
  local state = require("straps.state")
  local loop = require("straps.loop")

  local bufs = input.buffers
  if type(bufs) ~= "table" or #bufs == 0 then
    error("spawn_wait: buffers must be a non-empty array of subagent buffer numbers")
  end
  -- Normalize + validate: only wait on live buffers that this session spawned
  -- (straps_parent == us). Unknown/invalid handles are reported, never awaited.
  local children, bad = {}, {}
  for _, b in ipairs(bufs) do
    local child = math.floor(tonumber(b) or -1)
    local ok_valid = child >= 0 and vim.api.nvim_buf_is_valid(child)
    local parent
    if ok_valid then pcall(function() parent = vim.b[child].straps_parent end) end
    if ok_valid and parent == ctx.bufnr then
      children[#children + 1] = child
    else
      bad[#bad + 1] = child
    end
  end

  -- Await ALL outstanding children in a SINGLE await: one poll loop checks
  -- every child, so the wait costs the slowest child, not the sum. Each child
  -- carries its own deadline (straps_spawn_timeout_ms, stamped by spawn); a
  -- child past its deadline is stopped and marked timed out. Cancelling the
  -- parent stops every child at once.
  local timed_out = {}
  if #children > 0 then
    ctx.await(function(resolve)
      local starts = {}
      for _, c in ipairs(children) do
        -- Deadline is measured from the child's spawn (straps_spawn_started_ms),
        -- so time the parent spent working before calling spawn_wait counts
        -- against the child's timeout. Fall back to now if the stamp is missing.
        local started = vim.uv.now()
        pcall(function() started = vim.b[c].straps_spawn_started_ms or started end)
        starts[c] = started
      end
      local function poll()
        local pending = false
        for _, c in ipairs(children) do
          if loop.running(c) then
            local limit = 600000
            pcall(function() limit = vim.b[c].straps_spawn_timeout_ms or 600000 end)
            if vim.uv.now() - starts[c] >= limit then
              timed_out[c] = true
              pcall(loop.stop, c)
            else
              pending = true
            end
          end
        end
        if pending then vim.defer_fn(poll, 100) else resolve(true) end
      end
      if ctx.on_cancel then
        ctx.on_cancel(function()
          for _, c in ipairs(children) do pcall(loop.stop, c) end
        end)
      end
      poll()
    end)
    -- A stopped child (timed-out/cancelled) needs a beat to unwind its run;
    -- and a just-finished child may have a final streamed text_delta still
    -- scheduled (emit is vim.schedule'd, so it can trail the run-done signal).
    -- One settle tick lets both land before we read the answers.
    ctx.await(function(resolve) vim.defer_fn(resolve, 200) end)
  end

  -- The child's last assistant text IS its report to us.
  local function answer_of(child)
    local answer = ""
    pcall(function()
      local msgs = state.parse(child).messages
      for i = #msgs, 1, -1 do
        if msgs[i].role == "assistant" then
          local parts = {}
          for _, p in ipairs(msgs[i].content) do
            if p.type == "text" then parts[#parts + 1] = p.text end
          end
          if #parts > 0 then answer = table.concat(parts, "\n"); break end
        end
      end
    end)
    return answer
  end

  local out = {}
  for _, child in ipairs(children) do
    local nm = vim.api.nvim_buf_get_name(child)
    local where = nm ~= "" and vim.fn.fnamemodify(nm, ":~:.") or ("buffer " .. child)
    local task = ""
    pcall(function() task = vim.b[child].straps_task or "" end)
    local answer = answer_of(child)
    local status = timed_out[child] and "timed out (stopped)" or "finished"
    out[#out + 1] = ("## subagent (buffer %d) — %s\ntask: %s\ntranscript: %s\n\n%s")
      :format(child, status, task ~= "" and task or "(none)", where,
        answer ~= "" and answer or "(no final answer text)")
  end
  for _, b in ipairs(bad) do
    out[#out + 1] = ("## buffer %d — not a subagent of this session (skipped)"):format(b)
  end
  return table.concat(out, "\n\n")
end
]==],
  })

  -- -------------------------------------------------------- transcript_excise

  -- Context surgery: the transcript buffer IS the request (loop.lua re-parses
  -- it every turn), so shrinking an old block's content shrinks what the model
  -- sees from the next turn onward. Same in-place technique as fn.compact —
  -- blocks are never removed, so tool_use/tool_result pairing and role
  -- alternation survive — but agent-directed and per-block instead of
  -- age-based. The tool CANNOT write arbitrary text into the transcript: the
  -- only thing it can put there is a marked receipt, so no unmarked fabricated
  -- observation can ever be implanted (in itself or in a child).
  define({
    name = "tool.transcript_excise",
    kind = "tool",
    doc = "Excise dead weight from a session transcript — your OWN context"
      .. " window, or a subagent's — reclaiming it from every later request."
      .. " The transcript buffer IS the request: it is re-parsed every turn, so"
      .. " a 40k-token side quest or wrong path you excise now stops being"
      .. " replayed from your next turn on, while the conclusion you keep in"
      .. " your reply text survives. Use it when a line of investigation is"
      .. " finished and wrong: state what you learned in your reply FIRST, then"
      .. " excise the blocks that produced it."
      .. " Two modes. LIST (no blocks/range): returns the block index —"
      .. " number, kind, byte size, a snippet, and which blocks are locked."
      .. " Read-only, so it needs no confirmation; call it first to choose"
      .. " targets. EXCISE (blocks and/or range, plus a required note):"
      .. " replaces the CONTENT of those blocks with a one-line receipt"
      .. " carrying your note and the byte count reclaimed. Blocks are never"
      .. " deleted and no text of your choosing is written — only the receipt —"
      .. " so the human reading the transcript always sees what was removed and"
      .. " why, and the message structure the API requires stays intact."
      .. " Locked and never excisable: the system block, and everything from"
      .. " the last assistant block onward (the turn in flight — this very"
      .. " call's own blocks). Excising is idempotent, one undoable step per"
      .. " call (revert with undo_edit on the transcript file). Parameters:"
      .. " session (optional) — a subagent buffer handle from spawn (must be"
      .. " your own child); omit to operate on your own transcript. blocks"
      .. " (optional) — array of block numbers from list mode. range (optional)"
      .. " — {from, to} inclusive block numbers. note (required to excise) — a"
      .. " short reason, written into the transcript as the receipt.",
    input_schema = {
      type = "object",
      properties = {
        session = {
          type = "integer",
          description = "Subagent buffer handle to operate on; omit for your own transcript.",
        },
        blocks = {
          type = "array",
          items = { type = "integer" },
          description = "Block numbers to excise (from list mode).",
        },
        range = {
          type = "object",
          properties = {
            from = { type = "integer", description = "First block number (inclusive)." },
            to = { type = "integer", description = "Last block number (inclusive)." },
          },
          required = { "from", "to" },
          description = "Inclusive block-number range to excise.",
        },
        note = {
          type = "string",
          description = "Why these blocks are being excised; becomes the visible receipt.",
        },
      },
    },
    source = [==[
return function(input, ctx)
  local state = require("straps.state")

  -- Target: this session's own transcript by default, else a validated
  -- descendant — same check spawn_wait makes, so an agent can only operate on
  -- a buffer it spawned, never an arbitrary buffer in the editor.
  local bufnr, is_child = ctx.bufnr, false
  if input.session ~= nil then
    local child = math.floor(tonumber(input.session) or -1)
    local ok_valid = child >= 0 and vim.api.nvim_buf_is_valid(child)
    local parent
    if ok_valid then pcall(function() parent = vim.b[child].straps_parent end) end
    if not (ok_valid and parent == ctx.bufnr) then
      error("transcript_excise: buffer " .. tostring(input.session)
        .. " is not a subagent of this session")
    end
    bufnr, is_child = child, true
  end
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    error("transcript_excise: no valid session buffer to operate on")
  end

  local blocks = state.list_blocks(bufnr)

  -- The turn in flight starts at the LAST assistant block: the loop appends an
  -- empty assistant marker before the provider call, then EVERY tool_use marker
  -- of the batch before executing any of them, and appends each result after.
  -- So this very call's tool_use block (and its siblings') sit at or after that
  -- index; excising one would orphan a tool_result, which the API rejects. The
  -- same line is what makes editing a RUNNING child safe — the provider streams
  -- text deltas into the tail block, and the tail is never eligible.
  local inflight = 0
  for i = #blocks, 1, -1 do
    if blocks[i].kind == "assistant" then
      inflight = i
      break
    end
  end

  local function region_lines(from_lnum, to_lnum)
    if to_lnum < from_lnum then return {} end
    return vim.api.nvim_buf_get_lines(bufnr, from_lnum - 1, to_lnum, false)
  end
  local function first_nonblank(lines)
    for _, l in ipairs(lines) do
      if l:match("%S") then return l end
    end
    return ""
  end

  -- The lines a receipt would replace. For user/assistant/system the marker
  -- line can carry the block's first content line inline (state.match_marker),
  -- and that text sits OUTSIDE list_blocks' content range — so those blocks are
  -- rewritten from the marker line down, with a bare marker restored. Tool
  -- markers must keep their attrs (id/name) or parse skips the block entirely.
  local function target_region(b)
    if b.kind == "tool_use" or b.kind == "tool_result" then
      return b.first_lnum, b.last_lnum, false
    end
    return b.marker_lnum, math.max(b.last_lnum, b.marker_lnum), true
  end

  -- Bytes the block actually costs: the content lines, plus any inline text on
  -- a prose marker line (never the marker prefix itself).
  local function block_bytes(b)
    local from_lnum, to_lnum, with_marker = target_region(b)
    local lines = region_lines(from_lnum, to_lnum)
    if with_marker and lines[1] then
      lines = vim.deepcopy(lines)
      lines[1] = lines[1]:gsub("^%%%%%[straps:[a-z_]+%]%%%%%s?", "")
    end
    return #table.concat(lines, "\n"), lines
  end

  local function already_excised(b)
    local content = region_lines(b.first_lnum, b.last_lnum)
    if b.kind == "tool_use" then
      local body = vim.trim(table.concat(content, "\n"))
      return body == "" or body == "{}" or body:find('"_excised"', 1, true) ~= nil
    end
    local first = first_nonblank(content)
    return first:find("^%[excised") ~= nil or first:find("^%[compacted: was ") ~= nil
  end

  local function locked(i)
    local b = blocks[i]
    if not b then return "no such block" end
    if b.kind == "system" then return "system prompt" end
    if inflight == 0 or i >= inflight then return "turn in flight" end
    return nil
  end

  -- Collect targets (blocks + range), deduped. Out-of-range numbers are dropped
  -- here rather than errored: a block number past the end is a stale index from
  -- an older listing, and the per-block report already says what was skipped.
  local want, seen = {}, {}
  local asked = false -- did the caller name ANY target? (list mode if not)
  local function add(i)
    asked = true
    i = math.floor(tonumber(i) or -1)
    if i >= 1 and i <= #blocks and not seen[i] then
      seen[i] = true
      want[#want + 1] = i
    end
  end
  if type(input.blocks) == "table" then
    for _, i in ipairs(input.blocks) do add(i) end
  end
  if type(input.range) == "table" then
    local from = math.floor(tonumber(input.range.from) or 0)
    local to = math.floor(tonumber(input.range.to) or 0)
    if from < 1 or to < from then
      error("transcript_excise: range must be {from, to} with 1 <= from <= to")
    end
    -- Clamp before iterating: an unbounded `to` would otherwise build a table
    -- of millions of indices before any of them was checked against #blocks.
    to = math.min(to, #blocks)
    for i = from, to do add(i) end
    asked = true -- a range past the end still means "excise", not "list"
  end

  -- ------------------------------------------------------------- list mode
  -- Only when the caller named no target at all. A target that filtered out
  -- (every number past the end of the transcript) is a failed excision and must
  -- report that, not silently return an index listing.
  if not asked then
    local out = {
      ("transcript buffer %d — %d blocks; the turn in flight starts at block %s")
        :format(bufnr, #blocks, inflight > 0 and tostring(inflight) or "?"),
      "   #  kind          bytes  content",
    }
    local reclaimable = 0
    for i, b in ipairs(blocks) do
      local nbytes = block_bytes(b)
      local why = locked(i)
      local tag = ""
      if why then
        tag = "[locked: " .. why .. "] "
      elseif already_excised(b) then
        tag = "[already excised] "
      else
        reclaimable = reclaimable + nbytes
      end
      local snippet = first_nonblank(region_lines(b.first_lnum, b.last_lnum))
        :gsub("%s+", " "):sub(1, 70)
      out[#out + 1] = ("%4d  %-12s %6d  %s%s"):format(i, b.kind, nbytes, tag, snippet)
    end
    out[#out + 1] = ("%d bytes excisable. To excise: transcript_excise with"
      .. " blocks/range and a note."):format(reclaimable)
    return table.concat(out, "\n")
  end

  -- ----------------------------------------------------------- excise mode
  local note = input.note
  if type(note) ~= "string" or not note:match("%S") then
    error("transcript_excise: note is required to excise — it is the receipt left"
      .. " in the transcript in place of what you removed")
  end
  -- A receipt is exactly one line: flattening the note is what keeps a note
  -- containing a marker-shaped line from splitting the block it lands in.
  -- Control characters are dropped (a NUL in a buffer line is not writable as
  -- itself), and the note is capped — a receipt longer than the content it
  -- replaces would make the transcript grow instead of shrink.
  note = note:gsub("%c", " "):gsub("%s+", " ")
  note = vim.trim(note)
  if #note > 200 then
    note = note:sub(1, 197) .. "..."
  end

  table.sort(want)
  local skipped = {}
  -- Plan every replacement against ONE snapshot, then apply it as ONE
  -- set_lines over the whole affected span (untouched lines inside the span are
  -- copied verbatim). That makes line-number staleness impossible — no second
  -- edit ever runs against shifted numbers — and the whole surgery is a single
  -- undoable step, so undo_edit reverts it as a unit.
  local edits = {}
  for _, i in ipairs(want) do
    local b = blocks[i]
    local why = locked(i)
    if why then
      skipped[#skipped + 1] = ("block %d: %s"):format(i, why)
    elseif already_excised(b) then
      skipped[#skipped + 1] = ("block %d: already excised"):format(i)
    else
      local nbytes = block_bytes(b)
      if nbytes == 0 then
        skipped[#skipped + 1] = ("block %d: already empty"):format(i)
      else
        -- Staleness assertion: the marker must still be where the snapshot said.
        -- If it is not, something else wrote to the transcript and every range
        -- in the snapshot is suspect — refuse rather than eat a neighbour.
        local marker = vim.api.nvim_buf_get_lines(bufnr,
          b.marker_lnum - 1, b.marker_lnum, false)[1] or ""
        if not marker:find("^%%%%%[straps:" .. b.kind .. "%]%%%%") then
          error(("transcript_excise: the transcript changed underneath us"
            .. " (block %d is no longer %s) — nothing was excised; list again")
            :format(i, b.kind))
        end
        local from_lnum, to_lnum, with_marker = target_region(b)
        local repl = {}
        local content
        if b.kind == "tool_use" then
          -- Stays decodable JSON so parse still yields a real input object, and
          -- the note survives into the request instead of vanishing.
          content = vim.json.encode({
            _excised = ("was %d bytes — %s"):format(nbytes, note),
          })
        else
          content = ("[excised%s: was %d bytes — %s]")
            :format(is_child and " by parent" or "", nbytes, note)
        end
        -- What actually prevents a note from injecting a block is the receipt
        -- FRAME plus the flattening above: the written line always begins with
        -- "[excised" or '{"_excised"', and is always exactly one line, so it can
        -- never read as a marker. escape_line is belt-and-braces for a future
        -- frame change (set_lines bypasses the escaping state.append applies).
        -- The marker line itself is emitted verbatim — it IS a marker, and
        -- escaping it would destroy the block.
        if with_marker then
          repl[#repl + 1] = "%%[straps:" .. b.kind .. "]%%"
        end
        repl[#repl + 1] = state.escape_line(content)
        -- Keep the blank separator line before the next marker if there was one.
        local tail = vim.api.nvim_buf_get_lines(bufnr, to_lnum - 1, to_lnum, false)[1]
        if tail and not tail:match("%S") then
          repl[#repl + 1] = ""
        end
        -- Never grow the transcript: on a block already smaller than its own
        -- receipt there is nothing to reclaim, and rewriting it would only cost
        -- bytes (and destroy readable content for no gain).
        if #table.concat(repl, "\n") >= nbytes then
          skipped[#skipped + 1] = ("block %d: smaller than its receipt"):format(i)
        else
          edits[#edits + 1] = { from = from_lnum, to = to_lnum, lines = repl, bytes = nbytes }
        end
      end
    end
  end

  local touched, before, after = 0, 0, 0
  if #edits > 0 then
    table.sort(edits, function(a, b) return a.from < b.from end)
    local span_from, span_to = edits[1].from, edits[#edits].to
    local buf_lines = vim.api.nvim_buf_get_lines(bufnr, span_from - 1, span_to, false)
    local by_start = {}
    for _, e in ipairs(edits) do by_start[e.from] = e end
    local new_lines = {}
    local lnum = span_from
    while lnum <= span_to do
      local e = by_start[lnum]
      if e then
        for _, l in ipairs(e.lines) do new_lines[#new_lines + 1] = l end
        touched = touched + 1
        before = before + e.bytes
        after = after + #table.concat(e.lines, "\n")
        lnum = e.to + 1
      else
        new_lines[#new_lines + 1] = buf_lines[lnum - span_from + 1]
        lnum = lnum + 1
      end
    end
    vim.api.nvim_buf_set_lines(bufnr, span_from - 1, span_to, false, new_lines)
    state.persist(bufnr) -- file-backed transcripts only; no-op otherwise
  end

  local out = {}
  if touched == 0 then
    out[#out + 1] = "excised nothing"
  else
    out[#out + 1] = ("excised %d block(s) from %s: %d -> %d bytes (receipt: %s)")
      :format(touched, is_child and ("subagent buffer " .. bufnr) or "your transcript",
        before, after, note)
    out[#out + 1] = "The excised content is gone from every later request;"
      .. " the receipts stay visible in the transcript."
  end
  for _, s in ipairs(skipped) do
    out[#out + 1] = "skipped " .. s
  end
  return table.concat(out, "\n")
end
]==],
  })

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
      return require("straps.ui").set_locations(ctx and ctx.bufnr, { title = title, items = items }, false)
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
  local ui = require("straps.ui")
  local qf, list_kind = ui.get_locations(ctx and ctx.bufnr)
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
  local ok, err = ui.locations_do(ctx and ctx.bufnr, body)
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

  -- ------------------------------------------------------------ registry_list

  define({
    name = "tool.registry_list",
    kind = "tool",
    doc = "List all registry entries visible to THIS session (global plus"
      .. " session-scoped shadows), one per line formatted as"
      .. " 'name (kind, vN[, session]): first line of doc'. The version N"
      .. " increments each time an entry is redefined; a 'session' tag marks"
      .. " entries scoped to this session. Parameters: kind (optional) —"
      .. " filter to only 'tool', 'hook', or 'fn' entries.",
    input_schema = {
      type = "object",
      properties = {
        kind = {
          type = "string",
          enum = { "tool", "hook", "fn" },
          description = "Only list entries of this kind.",
        },
      },
      required = {},
    },
    source = [==[
return function(input, ctx)
  local registry = require("straps.registry")
  local lines = {}
  for _, name in ipairs(registry.names(input and input.kind or nil)) do
    local e = registry.get(name)
    if e then
      local doc = tostring(e.doc or ""):match("^[^\n]*") or ""
      lines[#lines + 1] = string.format("%s (%s, v%d%s): %s",
        e.name, e.kind, e.version or 1, e.scope and ", session" or "", doc)
    end
  end
  if #lines == 0 then
    return "no registry entries" .. (input and input.kind and (" of kind " .. input.kind) or "")
  end
  return table.concat(lines, "\n")
end
]==],
  })

  -- ------------------------------------------------------------- registry_get

  define({
    name = "tool.registry_get",
    kind = "tool",
    doc = "Fetch the full definition of one registry entry as an executable Lua"
      .. " chunk: a require('straps.registry').define{...} call including doc,"
      .. " input_schema, and the complete Lua source. Use this to inspect how"
      .. " any tool/hook/fn works before redefining it. Parameters: name"
      .. " (required) — full entry name, e.g. 'tool.write_file' or 'hook.confirm'.",
    input_schema = {
      type = "object",
      properties = {
        name = { type = "string", description = "Full registry entry name, e.g. 'tool.bash'." },
      },
      required = { "name" },
    },
    source = [==[
return function(input, ctx)
  local registry = require("straps.registry")
  if not registry.get(input.name) then
    error("registry_get: no entry named " .. tostring(input.name))
  end
  return registry.render(input.name)
end
]==],
  })

  -- ---------------------------------------------------------- registry_define

  define({
    name = "tool.registry_define",
    kind = "tool",
    doc = "Call this whenever something learned should persist beyond the"
      .. " current exchange — define or redefine a registry entry, THE"
      .. " self-extension tool. An extension (tool/hook/fn) is capability:"
      .. " define one when you need to become more capable at doing something."
      .. " A skill is knowledge, not capability: define one to store prose you"
      .. " will want loaded before doing something again. New tools become"
      .. " callable on your next turn; redefinitions of existing"
      .. " tools/hooks/fns (including the provider and hook.confirm) take effect"
      .. " on the very next call. Parameters: name (required) — full name like"
      .. " 'tool.run_tests', 'hook.after_write', 'fn.provider', or"
      .. " 'skill.release_process'; for tools the"
      .. " part after 'tool.' is the API name and must match ^[a-zA-Z0-9_-]+$;"
      .. " kind (required) — 'tool', 'hook', 'fn', or 'skill'; doc (optional) — for tools"
      .. " this is the LLM-facing description, for skills the one-line trigger"
      .. " ('when to load this'); input_schema (optional, tools only) — JSON"
      .. " Schema for the tool's input, passed as a JSON-encoded STRING (e.g."
      .. " '{\"type\":\"object\",\"properties\":{...},\"required\":[...]}');"
      .. " source (required) — for tool/hook/fn, Lua source whose chunk returns"
      .. " function(input, ctx); for skills, the prose body itself (no Lua);"
      .. " scope (optional, default 'session') —"
      .. " 'session' entries exist only for THIS session (and its subagents),"
      .. " shadow any global entry of the same name, and vanish when the"
      .. " session closes; 'global' affects every session in this Neovim —"
      .. " use it only when the user asked for that. Persist an entry across"
      .. " Neovim restarts by appending its registry_get rendering to"
      .. " .straps.lua. Returns 'defined <name> v<version> (scope)'.",
    input_schema = {
      type = "object",
      properties = {
        name = { type = "string", description = "Full entry name, e.g. 'tool.run_tests'." },
        kind = { type = "string", enum = { "tool", "hook", "fn", "skill" }, description = "Entry kind." },
        doc = { type = "string", description = "Description; for tools the LLM-facing tool description, for skills the one-line load trigger." },
        input_schema = { type = "string", description = "JSON Schema for tool input, as a JSON string (tools only)." },
        source = { type = "string", description = "tool/hook/fn: Lua source whose chunk returns function(input, ctx). skill: the prose body itself." },
        scope = { type = "string", enum = { "session", "global" }, description = "Entry scope (default 'session')." },
      },
      required = { "name", "kind", "source" },
    },
    source = [==[
return function(input, ctx)
  local registry = require("straps.registry")
  local kind = input.kind
  if kind ~= "tool" and kind ~= "hook" and kind ~= "fn" and kind ~= "skill" then
    error("registry_define: kind must be 'tool', 'hook', 'fn', or 'skill' (got " .. tostring(kind) .. ")")
  end
  local schema = nil
  if input.input_schema ~= nil and input.input_schema ~= "" then
    if type(input.input_schema) ~= "string" then
      error("registry_define: input_schema must be a JSON-encoded string")
    end
    local ok, decoded = pcall(vim.json.decode, input.input_schema)
    if not ok then
      error("registry_define: input_schema is not valid JSON: " .. tostring(decoded))
    end
    schema = decoded
  end
  local opts = nil
  if input.scope == "global" then
    opts = { scope = "global" }
  end
  -- Default (no scope / "session"): registry.define writes to the active
  -- session scope — invisible to other sessions, gone when this one closes.
  local entry = registry.define({
    name = input.name,
    kind = kind,
    doc = input.doc,
    input_schema = schema,
    source = input.source,
  }, opts)
  return "defined " .. entry.name .. " v" .. tostring(entry.version)
    .. (entry.scope and " (session scope — shadows global, dies with this session)"
      or " (global scope — all sessions)")
end
]==],
  })

  -- -------------------------------------------------------------------- skill

  define({
    name = "tool.skill",
    kind = "tool",
    doc = "Load a skill — a named piece of stored knowledge (prose) — into"
      .. " the conversation. Skills that existed at session start are listed"
      .. " under '# Skills' in the system prompt; call with no name to list"
      .. " every skill currently defined, including ones defined mid-session."
      .. " Parameters: name (optional) — the skill to load, with or without"
      .. " the 'skill.' prefix; omit to list.",
    input_schema = {
      type = "object",
      properties = {
        name = {
          type = "string",
          description = "Skill to load, e.g. 'release_process' or 'skill.release_process'. Omit to list all skills.",
        },
      },
    },
    source = [==[
return function(input, ctx)
  local registry = require("straps.registry")
  local name = input and input.name
  if name == nil or name == "" then
    local lines = {}
    for _, n in ipairs(registry.names("skill")) do
      local e = registry.get(n)
      local doc = tostring(e.doc or ""):match("^[^\n]*") or ""
      lines[#lines + 1] = n .. (doc ~= "" and (": " .. doc) or "")
    end
    if #lines == 0 then
      return "no skills defined"
    end
    return table.concat(lines, "\n")
  end
  local entry = registry.get(name)
  if not (entry and entry.kind == "skill") then
    entry = registry.get("skill." .. name)
  end
  if not entry or entry.kind ~= "skill" then
    return "skill: no skill named " .. tostring(name) .. " (call with no name to list)"
  end
  return entry.source
end
]==],
  })

  -- ----------------------------------------------------------------- eval_lua

  define({
    name = "tool.eval_lua",
    kind = "tool",
    doc = "Evaluate Lua code inside the running Neovim instance, with full"
      .. " access to vim.* and the straps modules. The code is compiled with"
      .. " load() and run under pcall; use 'return <expr>' to produce output."
      .. " Results are formatted for legibility: a returned string prints"
      .. " verbatim; a flat list/array prints one element per line (numbered);"
      .. " other tables fall back to vim.inspect. Multiple return values are"
      .. " shown in order. Dangerous by design — gated by hook.confirm."
      .. " Parameters: code (required) — a Lua chunk.",
    input_schema = {
      type = "object",
      properties = {
        code = { type = "string", description = "Lua chunk to evaluate; use 'return ...' to produce output." },
      },
      required = { "code" },
    },
    source = [==[
return function(input, ctx)
  local chunk, err = load(input.code, "straps:eval_lua")
  if not chunk then
    return "load error: " .. tostring(err)
  end
  local function pack(...) return { n = select("#", ...), ... } end
  local res = pack(pcall(chunk))
  if not res[1] then
    return "error: " .. tostring(res[2])
  end
  if res.n <= 1 then
    return "nil"
  end

  local islist = vim.islist or vim.tbl_islist

  -- Is this a "flat" list — a pure array whose elements are all scalars
  -- (string/number/boolean)? Those read badly under vim.inspect (a wall of
  -- quoted, comma-joined items), so we render them one per line instead.
  local function is_flat_list(v)
    if type(v) ~= "table" or not islist(v) then
      return false
    end
    for _, item in ipairs(v) do
      local t = type(item)
      if t ~= "string" and t ~= "number" and t ~= "boolean" then
        return false
      end
    end
    return true
  end

  -- Format one returned value:
  --   string     -> verbatim (no surrounding quotes / escaping)
  --   flat list  -> one element per line, "  N | value"
  --   everything -> vim.inspect
  local function format_value(v)
    if type(v) == "string" then
      return v
    elseif is_flat_list(v) then
      if #v == 0 then
        return "{} (empty list)"
      end
      local out = {}
      local width = #tostring(#v)
      for i, item in ipairs(v) do
        local num = string.format("%" .. width .. "d", i)
        local shown = type(item) == "string" and item or vim.inspect(item)
        out[#out + 1] = "  " .. num .. " | " .. shown
      end
      return table.concat(out, "\n")
    else
      return vim.inspect(v)
    end
  end

  local parts = {}
  for i = 2, res.n do
    local formatted = format_value(res[i])
    -- With more than one return value, label each so they don't run together
    -- ambiguously (especially when a value is a multi-line block).
    if res.n > 2 then
      parts[#parts + 1] = ("-- value %d --\n%s"):format(i - 1, formatted)
    else
      parts[#parts + 1] = formatted
    end
  end
  return table.concat(parts, "\n")
end
]==],
  })

  -- ---------------------------------------------------------------- fetch_url

  define({
    name = "tool.fetch_url",
    kind = "tool",
    doc = "Fetch an http(s) URL with curl using a timeout and byte cap. It sends"
      .. " no cookies or credentials, follows redirects only when follow_redirects"
      .. " is true, and returns status/headers/body. Use for public docs or small"
      .. " artifacts, not secrets. Parameters: url (required); max_bytes (optional,"
      .. " default 200000, max 1000000); timeout_ms (optional, default 10000);"
      .. " follow_redirects (optional boolean).",
    input_schema = {
      type = "object",
      properties = {
        url = { type = "string", description = "http(s) URL to fetch." },
        max_bytes = { type = "integer", description = "Maximum body bytes (default 200000, max 1000000)." },
        timeout_ms = { type = "integer", description = "Timeout in milliseconds (default 10000)." },
        follow_redirects = { type = "boolean", description = "Follow redirects (default false)." },
      },
      required = { "url" },
    },
    source = [==[
return function(input, ctx)
  local url = input.url
  if type(url) ~= "string" or not url:match("^https?://") then
    error("fetch_url: url must start with http:// or https://")
  end
  -- Basic SSRF guard: refuse obviously-internal hosts. Extract the host from
  -- the authority (strip userinfo, port, and IPv6 brackets), lowercase it.
  local function host_of(u)
    local authority = u:match("^https?://([^/?#]+)") or ""
    authority = authority:gsub("^[^@]*@", "")          -- strip userinfo
    local h = authority:match("^%[([^%]]+)%]") or authority:match("^([^:]+)")
    return (h or ""):lower()
  end
  local function is_internal(h)
    if h == "" then return false end
    if h == "localhost" or h:match("%.localhost$") then return true end
    if h == "0.0.0.0" or h == "::1" or h == "::" then return true end
    -- IPv4 literal ranges: loopback, private, link-local (incl. cloud metadata).
    local a, b = h:match("^(%d+)%.(%d+)%.%d+%.%d+$")
    a, b = tonumber(a), tonumber(b)
    if a then
      if a == 127 then return true end            -- 127.0.0.0/8 loopback
      if a == 10 then return true end             -- 10.0.0.0/8
      if a == 169 and b == 254 then return true end -- 169.254.0.0/16 link-local / metadata
      if a == 172 and b >= 16 and b <= 31 then return true end -- 172.16.0.0/12
      if a == 192 and b == 168 then return true end -- 192.168.0.0/16
    end
    -- IPv6 unique-local (fc00::/7) and link-local (fe80::/10).
    if h:match("^f[cd]") or h:match("^fe[89ab]") then return true end
    return false
  end
  if is_internal(host_of(url)) then
    error("fetch_url: refusing to fetch an internal/loopback/link-local host ("
      .. host_of(url) .. ")")
  end
  if vim.fn.executable("curl") ~= 1 then
    return "fetch_url: curl is not executable"
  end
  local max_bytes = math.min(math.max(tonumber(input.max_bytes) or 200000, 1), 1000000)
  local timeout_ms = tonumber(input.timeout_ms) or 10000
  local cmd = { "curl", "--disable", "--silent", "--show-error", "--include", "--max-time", tostring(math.ceil(timeout_ms / 1000)) }
  if input.follow_redirects then
    cmd[#cmd + 1] = "--location"
    -- Never let a redirect downgrade the protocol or reach non-http(s) schemes
    -- (e.g. file://, gopher://) — a common SSRF pivot.
    cmd[#cmd + 1] = "--proto-redir"; cmd[#cmd + 1] = "=http,https"
  end
  cmd[#cmd + 1] = "--"; cmd[#cmd + 1] = url
  local chunks, n, capped, proc = {}, 0, false, nil
  local res = ctx.await(function(resolve)
    proc = vim.system(cmd, {
      text = true,
      timeout = timeout_ms,
      stdout = function(_, chunk)
        if not chunk or chunk == "" then return end
        if n >= max_bytes then capped = true; if proc then pcall(function() proc:kill(9) end) end; return end
        local keep = math.min(#chunk, max_bytes - n)
        chunks[#chunks + 1] = chunk:sub(1, keep)
        n = n + keep
        if keep < #chunk then capped = true; if proc then pcall(function() proc:kill(9) end) end end
      end,
    }, function(out) resolve(out) end)
    if ctx.on_cancel then ctx.on_cancel(function() pcall(function() proc:kill(9) end) end) end
  end)
  local body = table.concat(chunks)
  local lines = { "exit code: " .. tostring(res.code) }
  if capped then lines[#lines + 1] = "body truncated at " .. tostring(max_bytes) .. " bytes" end
  if res.stderr and res.stderr ~= "" then lines[#lines + 1] = "stderr:\n" .. res.stderr end
  lines[#lines + 1] = body
  return table.concat(lines, "\n")
end
]==],
  })

  -- ------------------------------------------------------------------- agents

  -- Defined LAST among this file's tools: seq order is append-only for
  -- prompt-cache stability (see fn.build_tools), so a new tool goes at the end
  -- of the list rather than into the middle of it.
  define({
    name = "tool.agents",
    kind = "tool",
    doc = "List the other straps agent sessions running in this Neovim — who"
      .. " else is working, whether they are running or idle, how they relate to"
      .. " you (parent/child/sibling), the task they were given, and which files"
      .. " they have written. Call it when a run starts alongside other agents"
      .. " (the multiplayer notice points here), before editing a file a peer may"
      .. " be in, or after an edit tool reports 'modified by another agent'. Peers"
      .. " share this Neovim's buffers, so their unsaved edits are already in the"
      .. " files you read. Agents in a DIFFERENT Neovim are invisible here. Read-only."
      .. " No parameters.",
    input_schema = {
      type = "object",
      properties = vim.empty_dict(),
      required = {},
    },
    source = [==[
return function(input, ctx)
  local registry = require("straps.registry")
  local me = ctx and ctx.bufnr
  local peers = registry.call("fn.peer_agents", me) or {}
  local mine = "buffer " .. tostring(me)
  pcall(function() mine = require("straps.ui").session_label(me) end)
  if #peers == 0 then
    return "you are the only straps agent in this Neovim (this session: "
      .. mine .. "). Note: agents running in a DIFFERENT Neovim instance are"
      .. " invisible here."
  end
  local lines = { ("%d other agent(s) in this Neovim; this session: %s")
    :format(#peers, mine) }
  for _, p in ipairs(peers) do
    local parts = { ("  %s [%s, %s]"):format(p.label, p.relation,
      p.running and "running" or "idle") }
    if p.task then parts[#parts + 1] = "task: " .. p.task end
    if #p.files > 0 then
      local files = p.files
      local shown = table.concat(files, ", ", 1, math.min(#files, 5))
      if #files > 5 then shown = shown .. (", +%d more"):format(#files - 5) end
      parts[#parts + 1] = "wrote: " .. shown
    end
    lines[#lines + 1] = table.concat(parts, "  ·  ")
  end
  lines[#lines + 1] = "Buffers are shared: a peer's unsaved edits are already in"
    .. " what you read, and your edit tools will refuse a file whose latest"
    .. " change is a peer's write. Load skill.multiplayer for the protocol."
  return table.concat(lines, "\n")
end
]==],
  })

  -- ------------------------------------------------------------------ models

  -- The other half of model awareness. hook.on_turn_start tells an agent what
  -- it IS running; without a catalog it still cannot choose a subagent's model,
  -- because a model id has to be produced exactly and a wrong guess 400s the
  -- child's first request. The capability labels in config.models were written
  -- for precisely this comparison and had no reader until now.
  define({
    name = "tool.models",
    kind = "tool",
    doc = "List the models available to this session, so a subagent's model is"
      .. " a choice rather than an inherited default. Returns each model's id"
      .. " (what spawn's `model` argument takes, exactly), its label — which"
      .. " carries the capability/cost hint, e.g. 'most capable, slowest' vs"
      .. " 'fastest, cheapest' — and its context window, plus the effort names"
      .. " spawn's `effort` argument accepts. The session's active model is"
      .. " marked. Call it before fanning out work: mechanical children"
      .. " (searching, collecting, reformatting) belong on a cheap fast model,"
      .. " judgment children on a strong one. Lists the configured and"
      .. " previously discovered catalog for the ACTIVE provider (no network"
      .. " call); :StrapsModel refreshes it from the provider's API."
      .. " Read-only. No parameters.",
    input_schema = {
      type = "object",
      properties = vim.empty_dict(),
    },
    source = [==[
return function(input, ctx)
  local ok_straps, straps = pcall(require, "straps")
  if not ok_straps or type(straps) ~= "table" or type(straps.config) ~= "table" then
    return "straps config not available"
  end
  local cfg = straps.config

  -- Resolve the session's own provider/model the same way fn.provider will, so
  -- the marked entry is the one this session would actually send.
  local info
  pcall(function() info = require("straps.ui").session_info(ctx and ctx.bufnr) end)
  local provider = (info and info.provider)
    or (cfg.provider ~= "" and cfg.provider)
    or require("straps.registry").try_call("fn.provider_pref")
    or "anthropic"
  local current = info and info.model

  local list = cfg[provider == "openai" and "openai_models" or "models"]
  if type(list) ~= "table" or #list == 0 then
    return "no models configured for provider " .. tostring(provider)
      .. " (run :StrapsModel to discover the account's catalog)"
  end

  local lines = { ("models available to this session (provider: %s)"):format(provider) }
  for _, m in ipairs(list) do
    if type(m) == "table" and type(m.id) == "string" then
      local parts = { ("  %s%s"):format(m.id == current and "* " or "  ", m.id) }
      if type(m.label) == "string" and m.label ~= "" and m.label ~= m.id then
        parts[#parts + 1] = m.label
      end
      local ctx_tokens = tonumber(m.context)
      if ctx_tokens then
        parts[#parts + 1] = ("context %dk"):format(math.floor(ctx_tokens / 1000))
      end
      lines[#lines + 1] = table.concat(parts, "  ·  ")
    end
  end
  lines[#lines + 1] = "(* = this session's active model)"

  local efforts = {}
  if type(cfg.efforts) == "table" then
    for _, e in ipairs(cfg.efforts) do
      if type(e) == "table" and type(e.name) == "string" then efforts[#efforts + 1] = e.name end
    end
  end
  if #efforts > 0 then
    lines[#lines + 1] = "effort names: " .. table.concat(efforts, ", ")
      .. ((info and info.effort) and ("  (this session: " .. info.effort .. ")") or "")
  end
  lines[#lines + 1] = "Pass an id verbatim as spawn's `model`, and an effort name as"
    .. " `effort`; omitting them copies this session's."
  return table.concat(lines, "\n")
end
]==],
  })
  -- -------------------------------------------------------- fn.readonly_policy

  -- Single source of truth for "which tool calls are read-only". Both the
  -- default hook.confirm (to auto-allow them without a prompt) and spawn's
  -- readonly-child hook (to permit only these) consult it, so the policy
  -- cannot drift between the two. Called as (name, input) -> boolean.
  define({
    name = "fn.readonly_policy",
    kind = "fn",
    doc = "Return true if the tool call (name, input) is read-only: it opens"
      .. " views or lists things but changes no files. The read-only allowlist"
      .. " plus the list-mode exceptions (code_action/fix_diagnostic without an"
      .. " index, undo_edit with history=true, transcript_excise without"
      .. " blocks/range) live here so hook.confirm and"
      .. " spawn's readonly-child gate share one policy.",
    source = [==[
return function(name, input)
  local auto = {
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
  if auto[name] then return true end

  -- code_action / fix_diagnostic without an index only LIST available actions
  -- (read-only); applying one (index set) is a write.
  if (name == "code_action" or name == "fix_diagnostic")
    and (type(input) ~= "table" or input.index == nil) then
    return true
  end

  -- undo_edit with history=true only lists the undo states (read-only); an
  -- actual undo is a buffer+file change.
  if name == "undo_edit" and type(input) == "table" and input.history == true then
    return true
  end

  -- transcript_excise with no blocks/range only lists the transcript's blocks
  -- (read-only); an actual excision rewrites the transcript, which is the most
  -- consequential write in the system and always prompts.
  if name == "transcript_excise" and type(input) == "table"
    and input.blocks == nil and input.range == nil then
    return true
  end

  return false
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
      .. " grants persist in vim.b[ctx.bufnr].straps_allowed. Redefine to"
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

  -- Read the per-buffer allow-set defensively: it may be nil, and ctx.bufnr
  -- may not name a valid buffer.
  local ok, allowed = pcall(function()
    return ctx and ctx.bufnr and vim.b[ctx.bufnr].straps_allowed or nil
  end)
  local have_allowed = ok and type(allowed) == "table"

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
    local set = {}
    if have_allowed then
      for k, v in pairs(allowed) do set[k] = v end
    end
    set[key] = true
    pcall(function() vim.b[ctx.bufnr].straps_allowed = set end)
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

  -- --------------------------------------------------------- hook.after_write

  define({
    name = "hook.after_write",
    kind = "hook",
    doc = "Called as (path, ctx) after write_file or edit_file completes. If it"
      .. " returns a string, that string is appended to the tool result the"
      .. " agent sees. The default feeds the editor's own LSP back to the agent:"
      .. " it waits briefly (bounded, async) for the language server to re-lint"
      .. " the file it just changed, then returns any ERROR/WARN diagnostics so"
      .. " the agent sees breakage it caused without having to ask. No LSP client"
      .. " on the file, or no new diagnostics, returns nil (nothing appended)."
      .. " Turn it off with config.after_write_diagnostics = false, or redefine"
      .. " this hook (it is the canonical 'always do X after Y' seam — e.g. run"
      .. " an external linter instead and return its output).",
    source = [==[
return function(path, ctx)
  -- Editor-native lint feedback: after the edit (which already sent the LSP a
  -- didChange via the buffer's on_lines callbacks), wait for diagnostics to
  -- settle and report the file's ERROR/WARN. Every failure path returns nil so
  -- a write is never turned into an error by its own feedback loop.
  local ok, out = pcall(function()
    local cfg = {}
    local sok, straps = pcall(require, "straps")
    if sok and type(straps) == "table" and rawget(straps, "config") then
      cfg = straps.config
    end
    if cfg.after_write_diagnostics == false then return nil end

    local buf = vim.fn.bufnr(path)
    if buf < 0 or not vim.api.nvim_buf_is_valid(buf)
      or not vim.api.nvim_buf_is_loaded(buf) then
      return nil
    end
    -- No language server attached -> nothing to report (the file may just be a
    -- filetype with no server, which is not a problem).
    local get_clients = vim.lsp.get_clients or vim.lsp.get_active_clients
    if #(get_clients({ bufnr = buf }) or {}) == 0 then return nil end

    local timeout = tonumber(cfg.after_write_diagnostics_ms) or 800

    -- Wait for a DiagnosticChanged on this buffer (the server's re-lint), with
    -- a hard cap. Prefer ctx.await (yields the coroutine, never blocks the UI);
    -- fall back to vim.wait if the hook is somehow called outside a run.
    local function settle(finish_after)
      local settled, aug, tmr = false, nil, nil
      local function finish()
        if settled then return end
        settled = true
        if aug then pcall(vim.api.nvim_del_autocmd, aug) end
        if tmr then pcall(function() tmr:stop(); tmr:close() end) end
        finish_after()
      end
      aug = vim.api.nvim_create_autocmd("DiagnosticChanged", {
        callback = function(args)
          -- Debounce: diagnostics often arrive in a short burst; take the last.
          if args.buf == buf then vim.defer_fn(finish, 120) end
        end,
      })
      tmr = vim.defer_fn(finish, timeout)
      if ctx and ctx.on_cancel then ctx.on_cancel(finish) end
    end

    if ctx and ctx.await then
      ctx.await(function(resolve) settle(resolve) end)
    else
      local done = false
      settle(function() done = true end)
      vim.wait(timeout + 200, function() return done end, 30)
    end

    if not vim.api.nvim_buf_is_valid(buf) then return nil end
    local sev = vim.diagnostic.severity
    local names = { [sev.ERROR] = "ERROR", [sev.WARN] = "WARN" }
    local diags = vim.diagnostic.get(buf, { severity = { min = sev.WARN } }) or {}
    if #diags == 0 then return nil end
    table.sort(diags, function(a, b)
      if (a.lnum or 0) ~= (b.lnum or 0) then return (a.lnum or 0) < (b.lnum or 0) end
      return (a.col or 0) < (b.col or 0)
    end)
    local rel = vim.fn.fnamemodify(path, ":.")
    local lines = { ("diagnostics after write (%d):"):format(#diags) }
    for _, d in ipairs(diags) do
      local source = (d.source and d.source ~= "") and (" [" .. d.source .. "]") or ""
      lines[#lines + 1] = string.format("%s:%d:%d: %s %s%s",
        rel, (d.lnum or 0) + 1, (d.col or 0) + 1,
        names[d.severity] or "WARN", tostring(d.message or ""), source)
    end
    return table.concat(lines, "\n")
  end)
  if not ok then return nil end
  return out
end
]==],
  })

  -- ------------------------------------------------------- hook.on_run_start

  define({
    name = "hook.on_run_start",
    kind = "hook",
    doc = "Called as (ctx) when an agent run starts, before the first provider"
      .. " call. Default behavior: when OTHER sessions in this Neovim have"
      .. " active runs, append one user block telling the agent it is not alone"
      .. " (it can then call the agents tool and load skill.multiplayer)."
      .. " Silent when no peer is running, when the same peer set was already"
      .. " announced to this session, and when the transcript has nothing else"
      .. " to send — so a solo session gets no multiplayer notice at all."
      .. " Redefine for setup, notifications, or per-run state.",
    source = [==[
return function(ctx)
  local bufnr = ctx and ctx.bufnr
  if type(bufnr) ~= "number" or not vim.api.nvim_buf_is_valid(bufnr) then return end
  local registry = require("straps.registry")
  local state = require("straps.state")

  local peers = registry.try_call("fn.peer_agents", bufnr) or {}
  local live = {}
  for _, p in ipairs(peers) do
    if p.running then live[#live + 1] = p end
  end
  if #live == 0 then return end

  -- Announce a peer SET once, not once per run: a long session working
  -- alongside the same neighbour would otherwise accumulate an identical note
  -- in its persisted transcript every turn-loop start, and replay all of them.
  local sig = {}
  for _, p in ipairs(live) do sig[#sig + 1] = p.bufnr .. ":" .. p.relation end
  sig = table.concat(sig, ",")
  local ok_seen, seen = pcall(function() return vim.b[bufnr].straps_peers_noted end)
  if ok_seen and seen == sig then return end

  -- The note must never be the ONLY thing in the request: on a transcript with
  -- no other messages it would defeat the loop's "nothing to send" guard and
  -- spend a real API call announcing the neighbours to no purpose.
  local ok_parsed, parsed = pcall(state.parse, bufnr)
  if not ok_parsed or not parsed or #parsed.messages == 0 then return end

  local who = {}
  for _, p in ipairs(live) do
    who[#who + 1] = p.label .. " (" .. p.relation
      .. (p.task and (", " .. p.task) or "") .. ")"
  end
  pcall(state.append, bufnr, "user", nil,
    ("[straps] Multiplayer: %d other agent(s) working in this Neovim right now — %s."
      .. " You share their buffers. Call the agents tool for what they have"
      .. " touched, and load skill.multiplayer before editing anything they"
      .. " might be in."):format(#live, table.concat(who, ", ")))
  pcall(function() vim.b[bufnr].straps_peers_noted = sig end)
end
]==],
  })

  -- ------------------------------------------------------ hook.on_turn_start

  -- Model self-awareness. The winbar has always shown the user which model a
  -- session runs on; the agent itself had no way to know. It cannot live in the
  -- system prompt: that block is composed ONCE at session creation
  -- (state.new_session), so :StrapsModel / :StrapsEffort mid-session would make
  -- it a lie — and tool.spawn composes a child's prompt BEFORE stamping the
  -- child's model, so a static line would name the wrong model for every
  -- subagent. Hence a transcript notice, on the multiplayer-notice pattern:
  -- append when it changes, stay silent when it does not.
  define({
    name = "hook.on_turn_start",
    kind = "hook",
    doc = "Called as (ctx, turn) at the top of every turn, before the"
      .. " transcript is parsed for the next request. Default behavior: tell"
      .. " the agent which provider/model/effort it is running on, and"
      .. " re-announce when that CHANGES mid-session (the :StrapsModel /"
      .. " :StrapsEffort pickers can retarget a session between turns) — so an"
      .. " agent can match a subagent's capability to its task instead of"
      .. " defaulting to its own. Silent on every turn where the effective"
      .. " provider/model/effort is unchanged, so a session that never"
      .. " switches models carries exactly one such block. Also silent when"
      .. " the transcript has nothing else to send, and when its tail is not"
      .. " user-role (appending there would mask the loop's 'last turn added"
      .. " nothing to respond to' diagnostic); both defer the notice rather"
      .. " than dropping it. Redefine for per-turn budget checks, telemetry,"
      .. " or to silence the notice.",
    source = [==[
return function(ctx, turn)
  local bufnr = ctx and ctx.bufnr
  if type(bufnr) ~= "number" or not vim.api.nvim_buf_is_valid(bufnr) then return end
  local state = require("straps.state")

  -- ui.session_info resolves the vim.b-override -> global-config chain for
  -- provider/model/effort (the same chain fn.provider uses to build the
  -- request), and returns nil for a non-session buffer.
  local ok_info, info = pcall(function() return require("straps.ui").session_info(bufnr) end)
  if not ok_info or type(info) ~= "table" then return end

  -- The signature IS the description: "provider|model|effort" renders the old
  -- side of a change notice without a second stored variable.
  local sig = table.concat({ info.provider, info.model, info.effort }, "|")
  local prev
  pcall(function() prev = vim.b[bufnr].straps_model_noted end)
  if prev == sig then return end -- the common case: no parse, no append

  -- Guard, as in hook.on_run_start: a notice must never be the ONLY thing in
  -- the request, or it defeats the loop's "nothing to send" guard and spends a
  -- real API call announcing the model to no purpose.
  local ok_parsed, parsed = pcall(state.parse, bufnr)
  if not ok_parsed or not parsed or #parsed.messages == 0 then return end
  -- And it must not turn an assistant-role tail into a user-role one: the loop
  -- diagnoses that tail as "the last turn added nothing to respond to", and a
  -- notice appended over it would convert a caught error into a wasted round
  -- trip. Like the guard above, this one does NOT record the signature, so the
  -- notice is deferred to a turn that can carry it, not lost.
  if parsed.messages[#parsed.messages].role ~= "user" then return end

  -- Resume: vim.b dies with the buffer, but the notice is persisted in the
  -- session file — so a reopened transcript would announce a second, identical
  -- time, once per resume, forever. The transcript is the canonical state
  -- (DESIGN.md's first invariant), so recover the last announced signature FROM
  -- it when vim.b has none. Both notice shapes end in the same
  -- "<model> · provider <p> · effort <e>" triple; the change shape carries it
  -- after the final "-> ", and the first shape may render the model as
  -- "<label> (<id>)", whose id is the last parenthesized group.
  if prev == nil then
    local last
    for _, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
      if line:find("^%[straps%] Model") then last = line end
    end
    if last then
      local body = last:match("%-> (.*)$") or last:match("^%[straps%] Model: (.*)$") or ""
      local m, p, e = body:match("^(.-) · provider (%S+) · effort ([^%s.]+)%.")
      if m then
        m = m:match("^.*%s%((.-)%)$") or m -- "<label> (<id>)" -> id
        prev = table.concat({ p, m, e }, "|")
        pcall(function() vim.b[bufnr].straps_model_noted = prev end)
        if prev == sig then return end -- already announced, before this resume
      end
    end
  end

  -- Anchor the OUTER fields and let the model absorb the middle: a custom or
  -- proxied model id may itself contain the "|" delimiter, and a non-greedy
  -- split would then report the wrong text on the old side of a change notice.
  local function describe(s)
    local p, m, e = s:match("^([^|]*)|(.*)|([^|]*)$")
    if not m then return s end
    return ("%s · provider %s · effort %s"):format(m, p, e)
  end

  local text
  if prev == nil then
    local shown = info.model_label ~= info.model
      and ("%s (%s)"):format(info.model_label, info.model) or info.model
    text = ("[straps] Model: %s · provider %s · effort %s."):format(
      shown, info.provider, info.effort)
  else
    text = ("[straps] Model changed mid-session: %s -> %s."):format(
      describe(prev), describe(sig))
  end
  -- Carried in the notice, not only in the prompt's # Subagents section: that
  -- section is dropped for subagents, so a nested spawner would never read it.
  text = text .. " Subagents inherit this model and effort unless you pass"
    .. " spawn an explicit model / effort — call the models tool for the ids"
    .. " you can pass, and match the child's capability to its task rather"
    .. " than defaulting to your own."
  pcall(state.append, bufnr, "user", nil, text)
  pcall(function() vim.b[bufnr].straps_model_noted = sig end)
  return nil
end
]==],
  })

  -- --------------------------------------------------------- hook.on_run_end

  define({
    name = "hook.on_run_end",
    kind = "hook",
    doc = "Called as (ctx) when an agent run ends (normally, on error, or after"
      .. " cancellation). No-op by default; redefine for teardown or"
      .. " notifications.",
    source = [==[
return function(ctx)
  -- no-op by default
end
]==],
  })

  -- ---------------------------------------------------------- autocmd bridge

  define({
    name = "fn.autocmd_bridge",
    kind = "fn",
    doc = "Bridge Neovim autocmd events back into a session — the 'editor"
      .. " talks to the agent' seam. Call as (spec) with spec = { event ="
      .. " 'BufWritePost' (or a list), pattern = optional autocmd pattern,"
      .. " entry = 'hook.NAME' (a registry entry called with the autocmd args"
      .. " table), bufnr = session buffer number }. Whenever the event fires,"
      .. " the entry runs; if it returns a non-empty string, that string is"
      .. " queued onto the session as a user message: steering if a run is"
      .. " active, an ordinary user block otherwise. Returns the autocmd id"
      .. " (remove with vim.api.nvim_del_autocmd). Example: bridge"
      .. " DiagnosticChanged to a hook that reports new errors, and the agent"
      .. " hears about breakage as the user saves.",
    source = [==[
return function(spec)
  assert(type(spec) == "table", "autocmd_bridge: spec table required")
  assert(spec.event, "autocmd_bridge: spec.event is required")
  assert(type(spec.entry) == "string", "autocmd_bridge: spec.entry (registry entry name) is required")
  local session = spec.bufnr
  assert(type(session) == "number", "autocmd_bridge: spec.bufnr (session buffer) is required")
  return vim.api.nvim_create_autocmd(spec.event, {
    group = vim.api.nvim_create_augroup("straps_bridge_" .. session, { clear = false }),
    pattern = spec.pattern,
    callback = function(args)
      local ok, s = pcall(function()
        local registry = require("straps.registry")
        local prev = registry.set_active_scope(session)
        local ok_call, out = pcall(registry.try_call, spec.entry, args)
        registry.set_active_scope(prev)
        if not ok_call then error(out) end
        return out
      end)
      if ok and type(s) == "string" and s ~= "" then
        vim.schedule(function()
          if not vim.api.nvim_buf_is_valid(session) then return end
          local loop = require("straps.loop")
          if loop.running(session) then
            loop.steer(session, s)
          else
            pcall(require("straps.state").append, session, "user", nil, s)
          end
        end)
      end
    end,
  })
end
]==],
  })
end

return M
