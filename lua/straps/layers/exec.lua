-- straps/layers/exec.lua — the EXEC layer: shell execution (bash, the
-- terminal split, and the quickfix-parsing runner).
-- Future prompt-fragment slot: fn.system_prompt_layer.exec.

local M = {}

function M.register()
  local registry = require("straps.registry")
  local define = registry.define_default

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
      .. " (optional, default 120000) — the process tree is killed if it runs"
      .. " longer than this many milliseconds (the result notes the timeout)."
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
  local finished, timed_out = false, false
  -- proc:kill only signals the direct bash child; a compound command's
  -- grandchildren (and anything holding the stdout/stderr pipes open)
  -- survive and on_exit never fires. detach=true makes the child a process
  -- group leader (setsid), so vim.uv.kill(-pid, sig) can signal the whole
  -- tree. Fall back to proc:kill if the group signal fails outright.
  local function kill_tree(sig)
    if not (proc and proc.pid) then return end
    local ok = pcall(function() assert(vim.uv.kill(-proc.pid, sig)) end)
    if not ok then pcall(function() proc:kill(sig) end) end
  end
  local function stop_for_cap()
    kill_tree("sigkill")
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
        detach = true,
        stdout = function(_, chunk) take(stdout, "out", chunk) end,
        stderr = function(_, chunk) take(stderr, "err", chunk) end,
      },
      function(out)
        finished = true
        resolve(out)
      end)
    if ctx.on_cancel then
      ctx.on_cancel(function() kill_tree("sigkill") end)
    end
    -- opts.timeout only SIGTERMs the direct child, the same defect as
    -- proc:kill above, so the timeout is enforced by hand: SIGTERM the
    -- group, then SIGKILL it if it has not exited after a grace period.
    -- The finished guard keeps a stale timer from signalling a recycled pgid.
    vim.defer_fn(function()
      if finished then return end
      timed_out = true
      kill_tree("sigterm")
      vim.defer_fn(function()
        if not finished then kill_tree("sigkill") end
      end, 2000)
    end, timeout_ms)
  end)
  local lines = { "exit code: " .. tostring(res.code) }
  if timed_out then
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

  local proc
  local finished, timed_out = false, false
  -- Same process-tree defect as tool.bash: proc:kill/opts.timeout only
  -- signal the direct bash child, so a compound command's grandchildren
  -- survive and on_exit never fires. detach=true + vim.uv.kill(-pid, sig)
  -- signals the whole group.
  local function kill_tree(sig)
    if not (proc and proc.pid) then return end
    local ok = pcall(function() assert(vim.uv.kill(-proc.pid, sig)) end)
    if not ok then pcall(function() proc:kill(sig) end) end
  end
  local res = ctx.await(function(resolve)
    proc = vim.system(
      { "bash", "-lc", cmd },
      { text = true, detach = true },
      function(out)
        finished = true
        resolve(out)
      end)
    if ctx.on_cancel then
      ctx.on_cancel(function() kill_tree("sigkill") end)
    end
    vim.defer_fn(function()
      if finished then return end
      timed_out = true
      kill_tree("sigterm")
      vim.defer_fn(function()
        if not finished then kill_tree("sigkill") end
      end, 2000)
    end, timeout_ms)
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
      return require("straps.findings").set_locations(ctx and ctx.bufnr, { title = title, items = valid }, open)
    end)
    if ok and kind then list_kind = kind end
  end
  local nav = (list_kind == "loclist") and ":lnext/:lprev" or ":cnext/:cprev"

  -- Compact summary for the agent: the exit code and the parsed locations,
  -- NOT the raw output (which is what the list is for). Cap the listing.
  local out = { "exit code: " .. tostring(res.code) }
  if timed_out then
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
end

return M
