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
    doc = "Read a file from disk. Returns the content with 1-based line numbers"
      .. " in the form '  N<TAB>line'. Parameters: path (required) — absolute or"
      .. " cwd-relative path of the file to read; offset (optional, default 1) —"
      .. " 1-based line number to start reading from; limit (optional) — maximum"
      .. " number of lines to return. At most 2000 lines are returned per call;"
      .. " if the file has more, the output ends with a truncation note telling"
      .. " you the next offset to use.",
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
  local f, err = io.open(input.path, "r")
  if not f then
    error("read_file: cannot open " .. tostring(input.path) .. ": " .. tostring(err))
  end
  local text = f:read("*a") or ""
  f:close()
  local lines = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = line
  end
  -- Reading "content\n" yields a spurious trailing "" only when the file
  -- already ended in a newline; drop it.
  if #lines > 0 and lines[#lines] == "" and text:sub(-1) == "\n" then
    lines[#lines] = nil
  end
  local total = #lines
  local offset = math.max(1, tonumber(input.offset) or 1)
  local limit = math.min(tonumber(input.limit) or 2000, 2000)
  if offset > total then
    return string.format("read_file: %s has %d lines; offset %d is past the end", input.path, total, offset)
  end
  local last = math.min(total, offset + limit - 1)
  local out = {}
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
      .. " `:earlier`, or undotree. After writing, hook.after_write fires; if it"
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
    error("write_file: failed to write " .. tostring(path) .. ": " .. tostring(err))
  end

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
      .. " user can revert it with `u`, `:earlier`, or undotree. hook.after_write"
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

  -- --------------------------------------------------------------------- bash

  define({
    name = "tool.bash",
    kind = "tool",
    doc = "Run a shell command via `bash -lc` and return its result with"
      .. " clearly labeled sections: exit code, stdout, stderr. Never use this"
      .. " tool to search or read files: use the grep tool instead of shell"
      .. " grep/rg (it also populates the user's quickfix list), the glob tool"
      .. " instead of find/ls, and read_file instead of cat/head/tail."
      .. " Parameters:"
      .. " command (required) — the shell command line to execute; timeout_ms"
      .. " (optional, default 120000) — the process is killed if it runs longer"
      .. " than this many milliseconds (exit code 124 indicates a timeout)."
      .. " Refuses bare read/search/list commands (cat/head/tail/sed -n,"
      .. " grep/rg, ls/find/fd with no pipe or redirect) in favor of the"
      .. " vim-native read_file, grep, and glob tools.",
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
      redirect = "tool.grep (regex search, also populates the user's quickfix list)"
    elseif trimmed == "ls" or trimmed:match("^ls%s")
      or trimmed:match("^find%s+%S") or trimmed:match("^fd%s+%S") then
      redirect = "tool.glob (lists files matching a pattern)"
    end
    if redirect then
      return "bash: refusing plain read/search/list command (" .. trimmed ..
        "). Use " .. redirect .. " instead."
    end
  end

  local timeout_ms = tonumber(input.timeout_ms) or 120000
  local res = ctx.await(function(resolve)
    local proc = vim.system(
      { "bash", "-lc", cmd },
      { text = true, timeout = timeout_ms },
      function(out) resolve(out) end)
    if ctx.on_cancel then
      ctx.on_cancel(function() pcall(function() proc:kill(9) end) end)
    end
  end)
  local lines = { "exit code: " .. tostring(res.code) }
  if res.code == 124 then
    lines[#lines] = lines[#lines] .. " (killed: exceeded timeout of " .. timeout_ms .. " ms)"
  end
  lines[#lines + 1] = "stdout:"
  lines[#lines + 1] = res.stdout or ""
  lines[#lines + 1] = "stderr:"
  lines[#lines + 1] = res.stderr or ""
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

  -- -------------------------------------------------------------------- spawn

  define({
    name = "tool.spawn",
    kind = "tool",
    doc = "Run a subagent on a task in its OWN session buffer and return its"
      .. " final answer. The child is a full straps session: its transcript is"
      .. " a real buffer the user can open, watch and steer (show=true opens"
      .. " it in a split). The child inherits this session's registry view —"
      .. " your session-scoped tools included — but anything IT defines lands"
      .. " in its own scope and never leaks back. Use it to isolate context:"
      .. " the child burns its own transcript on a broad investigation and you"
      .. " receive only its final answer. The task must be COMPLETE and"
      .. " self-contained; the child sees none of this conversation."
      .. " Parameters: task (required); system (optional) — extra standing"
      .. " instructions, prepended to the task; tools (optional array of tool"
      .. " names) — the child sees only these tools; readonly (optional"
      .. " boolean) — the child may use only auto-allowed read-only tools,"
      .. " every write is denied without prompting; show (optional boolean) —"
      .. " open the child's transcript in a split; max_turns (optional,"
      .. " default 24); timeout_ms (optional, default 600000).",
    input_schema = {
      type = "object",
      properties = {
        task = { type = "string", description = "Complete, self-contained instructions for the subagent." },
        system = { type = "string", description = "Extra standing instructions for the child." },
        tools = {
          type = "array",
          items = { type = "string" },
          description = "Restrict the child to these tool names.",
        },
        readonly = { type = "boolean", description = "Read-only child: every write tool is denied." },
        show = { type = "boolean", description = "Open the child's transcript buffer in a split." },
        max_turns = { type = "integer", description = "Child turn budget (default 24)." },
        timeout_ms = { type = "integer", description = "Wall-clock cap in milliseconds (default 600000)." },
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

  local child = state.new_session()
  vim.b[child].straps_spawn_depth = depth + 1
  vim.b[child].straps_max_turns = math.floor(tonumber(input.max_turns) or 24)
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
  local auto = {
    read_file = true, glob = true, grep = true, registry_list = true,
    registry_get = true, diagnostics = true, definition = true,
    references = true, symbols = true, read_symbol = true, hover = true,
    workspace_symbols = true, context = true, help_search = true,
  }
  if auto[name] then return true end
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
  if input.show then
    pcall(function()
      local prev = vim.api.nvim_get_current_win()
      vim.cmd("botright vsplit")
      vim.api.nvim_win_set_buf(vim.api.nvim_get_current_win(), child)
      pcall(vim.api.nvim_set_current_win, prev)
    end)
  end

  -- Wait for the child's run to end; cancelling the parent stops the child.
  local timeout_ms = tonumber(input.timeout_ms) or 600000
  local finished = ctx.await(function(resolve)
    local start = vim.uv.now()
    local function poll()
      if not loop.running(child) then resolve(true); return end
      if vim.uv.now() - start >= timeout_ms then resolve(false); return end
      vim.defer_fn(poll, 100)
    end
    if ctx.on_cancel then
      ctx.on_cancel(function() pcall(loop.stop, child) end)
    end
    poll()
  end)
  if not finished then
    pcall(loop.stop, child)
    ctx.await(function(resolve) vim.defer_fn(resolve, 200) end)
  end

  -- The child's last assistant text IS its report to us.
  local answer = ""
  pcall(function()
    local msgs = state.parse(child).messages
    for i = #msgs, 1, -1 do
      if msgs[i].role == "assistant" then
        local parts = {}
        for _, p in ipairs(msgs[i].content) do
          if p.type == "text" then parts[#parts + 1] = p.text end
        end
        if #parts > 0 then
          answer = table.concat(parts, "\n")
          break
        end
      end
    end
  end)
  local name = vim.api.nvim_buf_get_name(child)
  local where = name ~= "" and vim.fn.fnamemodify(name, ":~:.") or ("buffer " .. child)
  return (finished and "subagent finished" or "subagent timed out (stopped)")
    .. " — transcript: " .. where .. "\n\n"
    .. (answer ~= "" and answer or "(no final answer text)")
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

  -- --------------------------------------------------------------------- grep

  define({
    name = "tool.grep",
    kind = "tool",
    doc = "Search file contents for a regular-expression pattern. Uses ripgrep"
      .. " (rg) when installed, otherwise falls back to `grep -rn`. Returns"
      .. " matching lines as file:line:text, capped at 100000 bytes with a"
      .. " truncation note. As a side effect it also populates Neovim's quickfix"
      .. " list (title 'straps: grep <pattern>'), so the user can jump through the"
      .. " matches with :cnext/:cprev and bulk-edit them with the bulk_replace"
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

  -- Populate the quickfix list from the matches so the user can :cnext/:cprev
  -- and bulk_replace over them. This is a pure side effect: the text summary
  -- returned below is unchanged. rg/grep emit `file:line:text`; parse that
  -- (also tolerate an optional `file:line:col:text` if a column is present).
  -- Context lines (from the context param) use `-` separators and `--` group
  -- dividers, so they fall through this match — only real matches enter the
  -- quickfix list.
  local title = "straps: grep " .. tostring(input.pattern)
  local function set_qf(items)
    pcall(vim.fn.setqflist, {}, " ", { title = title, items = items })
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
      -- A genuine zero-match search: reflect it by clearing the quickfix list.
      set_qf({})
      return "no matches"
    end
    -- A real failure: leave any existing quickfix list untouched.
    return string.format("grep failed (exit %d): %s", res.code, res.stderr or "")
  end

  -- Only replace the quickfix list when parsing actually yielded entries, so a
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
    doc = "Substitute text across the CURRENT quickfix list — the set the grep"
      .. " tool populates — as a single native multi-file edit. Runs Vim's"
      .. " `:cdo s/<pattern>/<replacement>/<flags> | update` over every quickfix"
      .. " entry, editing each file THROUGH its buffer so the changes enter each"
      .. " file's native undo history (revert with `u`, `:earlier`, or undotree in"
      .. " that buffer). Populate the quickfix list with the grep tool first; an"
      .. " empty quickfix list is an error. This is a WRITE tool and prompts for"
      .. " confirmation. Parameters: pattern (required) — a Vim :s search pattern"
      .. " (Vim regex, NOT rg/PCRE); replacement (required) — the replacement"
      .. " text (Vim :s syntax, e.g. \\1 backreferences); flags (optional, default"
      .. " 'ge') — :s flags; the 'e' flag is always ensured so a file in the list"
      .. " with no match does not abort the run; dry_run (optional) — when true,"
      .. " report how many quickfix entries and distinct files WOULD be edited"
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

  local qf = vim.fn.getqflist()
  if type(qf) ~= "table" or #qf == 0 then
    return "quickfix list is empty — run grep first to populate it"
  end

  -- Distinct files behind the quickfix entries (by resolved buffer number).
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
      "dry_run: would substitute over %d quickfix entr%s across %d file%s (no changes made)",
      #qf, #qf == 1 and "y" or "ies", #bufs, #bufs == 1 and "" or "s")
  end

  -- Use '#' as the :s delimiter and escape only that in pattern/replacement, so
  -- the pattern keeps its Vim-regex meaning and the delimiter can never be
  -- mistaken for a real character in the text.
  local pat = pattern:gsub("#", "\\#")
  local rep = replacement:gsub("#", "\\#")

  -- Always ensure the 'e' flag: :cdo aborts on the first error, and a file in
  -- the list with no match would otherwise raise E486 and stop the whole run.
  local flags = input.flags
  if type(flags) ~= "string" or flags == "" then flags = "ge" end
  if not flags:find("e", 1, true) then flags = flags .. "e" end

  -- Snapshot changedtick of each target buffer so we can count what actually
  -- changed (a substitute bumps changedtick; `update` writing does not).
  local ticks = {}
  for _, b in ipairs(bufs) do
    pcall(vim.fn.bufload, b)
    ticks[b] = vim.api.nvim_buf_get_changedtick(b)
  end

  local ex = string.format("silent cdo s#%s#%s#%s | update", pat, rep, flags)
  local ok, err = pcall(vim.cmd, ex)
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
    "bulk_replace: applied `s#%s#%s#%s` across the quickfix list; %d file%s changed"
    .. " — undo with u in each buffer",
    pat, rep, flags, changed, changed == 1 and "" or "s")
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

  -- ------------------------------------------------------------- hook.confirm

  define({
    name = "hook.confirm",
    kind = "hook",
    doc = "Confirmation gate called before every tool execution as"
      .. " (name, input, ctx) -> allowed, reason. Default behavior: auto-allow"
      .. " the read-only tools (read_file, glob, grep, registry_list,"
      .. " registry_get, diagnostics, definition, references, symbols,"
      .. " read_symbol, hover, workspace_symbols, context, show_user,"
      .. " help_search, ask_user, code_action in list mode i.e. without"
      .. " index, and undo_edit in history mode);"
      .. " otherwise prompt via vim.fn.confirm. For"
      .. " file-editing tools (write_file, edit_file) a unified diff of the"
      .. " proposed change is shown in a scratch split while the dialog is up"
      .. " (closed after), and the prompt offers"
      .. " Yes / No / 'Always in <parent dir>' / 'Always all edits': the"
      .. " directory choice grants every future write_file/edit_file whose"
      .. " path falls under that file's PARENT directory (not just that one"
      .. " file), and 'Always all edits' grants every future"
      .. " write_file/edit_file call regardless of path. Other tools get"
      .. " Yes / No / 'Always this tool', scoped to the tool name. All"
      .. " grants persist in vim.b[ctx.bufnr].straps_allowed. Redefine to"
      .. " change the policy.",
    source = [==[
-- NOTE: this hook runs inside the loop coroutine. vim.fn.confirm must run on
-- the main loop; because the loop driver resumes the coroutine via
-- vim.schedule, every resume (and therefore this call) is already on the main
-- loop, so calling vim.fn.confirm directly here is safe — no extra await/
-- schedule wrapper is needed.
return function(name, input, ctx)
  local auto = {
    read_file = true, glob = true, grep = true,
    registry_list = true, registry_get = true,
    -- editor-native read-only tools (straps.editor)
    diagnostics = true, definition = true, references = true,
    symbols = true, read_symbol = true, hover = true,
    workspace_symbols = true, context = true, show_user = true,
    help_search = true,
    -- ask_user IS user interaction; gating it behind a confirm dialog would
    -- be asking permission to ask a question.
    ask_user = true,
  }
  if auto[name] then
    return true
  end

  -- code_action without an index only LISTS the available actions
  -- (read-only); applying one (index set) is a write and falls through to
  -- the prompt.
  if name == "code_action" and (type(input) ~= "table" or input.index == nil) then
    return true
  end

  -- undo_edit with history=true only lists the undo states (read-only); an
  -- actual undo is a buffer+file change and falls through to the prompt.
  if name == "undo_edit" and type(input) == "table" and input.history == true then
    return true
  end

  -- File-editing tools (write_file, edit_file) get directory- and
  -- global-scoped "always allow" options instead of a single per-tool
  -- toggle, so the user can grant "everywhere under this directory" or
  -- "all edits, any path" without being forced to blanket-authorize every
  -- other tool too.
  local path_scoped = { write_file = true, edit_file = true }
  local is_edit = path_scoped[name] and type(input) == "table" and type(input.path) == "string"

  local function parent_dir(path)
    return vim.fn.fnamemodify(path, ":p:h")
  end

  local function under_dir(path, dir)
    local abspath = vim.fn.fnamemodify(path, ":p")
    local absdir = vim.fn.fnamemodify(dir, ":p")
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

  local dir
  local choices
  if is_edit then
    dir = parent_dir(input.path)
    choices = "&Yes\n&No\n&Always in " .. dir .. "\nAlways &all edits"
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
  if is_edit and choice == 4 then
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
      .. " agent sees. Ships as a no-op returning nil. This is the canonical"
      .. " 'always do X after Y' seam: e.g. redefine it to run a linter on the"
      .. " written file and return the diagnostics, and every write will"
      .. " automatically feed lint results back to the agent.",
    source = [==[
return function(path, ctx)
  -- no-op by default; redefine me (e.g. run a linter and return its output)
end
]==],
  })

  -- ------------------------------------------------------- hook.on_run_start

  define({
    name = "hook.on_run_start",
    kind = "hook",
    doc = "Called as (ctx) when an agent run starts, before the first provider"
      .. " call. No-op by default; redefine for setup, notifications, or"
      .. " per-run state.",
    source = [==[
return function(ctx)
  -- no-op by default
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
        return require("straps.registry").try_call(spec.entry, args)
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
