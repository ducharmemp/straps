-- straps/layers/files.lua — the FILES layer: buffered file I/O (read/write/
-- edit/patch), its concurrent-editor primitives, and the after-write hook.
-- Future prompt-fragment slot: fn.system_prompt_layer.files.

local M = {}

function M.register_tools()
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
  local hook_results, hook_errors = registry.call_hooks("hook.after_write", path, ctx)
  for _, extra in ipairs(hook_results) do
    if type(extra) == "string" and extra ~= "" then
      result = result .. "\n" .. extra
    end
  end
  for _, e in ipairs(hook_errors) do
    result = result .. "\n[hook " .. e.name .. " error: " .. e.err .. "]"
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
  local hook_results, hook_errors = registry.call_hooks("hook.after_write", path, ctx)
  for _, extra in ipairs(hook_results) do
    if type(extra) == "string" and extra ~= "" then
      result = result .. "\n" .. extra
    end
  end
  for _, e in ipairs(hook_errors) do
    result = result .. "\n[hook " .. e.name .. " error: " .. e.err .. "]"
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
  local hook_results, hook_errors = registry.call_hooks("hook.after_write", path, ctx)
  for _, extra in ipairs(hook_results) do
    if type(extra) == "string" and extra ~= "" then
      result = result .. "\n" .. extra
    end
  end
  for _, e in ipairs(hook_errors) do
    result = result .. "\n[hook " .. e.name .. " error: " .. e.err .. "]"
  end
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
end

function M.register_hooks()
  local registry = require("straps.registry")
  local define = registry.define_default

  -- --------------------------------------------------------- hook.after_write

  define({
    name = "hook.after_write",
    kind = "hook",
    doc = "Called as (path, ctx) after write_file, edit_file, or patch_file"
      .. " completes. If it"
      .. " returns a string, that string is appended to the tool result the"
      .. " agent sees. The default feeds the editor's own LSP back to the agent:"
      .. " it waits briefly (bounded, async) for the language server to re-lint"
      .. " the file it just changed, then returns any ERROR/WARN diagnostics so"
      .. " the agent sees breakage it caused without having to ask. No LSP client"
      .. " on the file, or no new diagnostics, returns nil (nothing appended)."
      .. " Turn it off with config.after_write_diagnostics = false, or redefine"
      .. " this hook (it is the canonical 'always do X after Y' seam — e.g. run"
      .. " an external linter instead and return its output). Additional"
      .. " subscribers can be added as hook.after_write.<suffix> entries"
      .. " without replacing this default — this entry plus every"
      .. " hook.after_write.<suffix> entry runs and their string results are"
      .. " all appended, in registration order.",
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
end

return M
