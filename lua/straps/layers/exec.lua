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
      .. " clearly labeled sections: exit code, stdout, stderr. The command already"
      .. " runs in the project's working directory, so a leading `cd <project> &&` is"
      .. " unnecessary. Never use this tool to search, read, or inspect files: use"
      .. " grep instead of shell grep/rg (it caps results and populates this session's"
      .. " findings list), tree/path_info/glob instead of find/ls, and read_file"
      .. " (offset/limit) instead of cat/head/tail/sed -n/wc. For build/test/lint"
      .. " diagnostics, prefer run_quickfix. Parameters: command (required) — the"
      .. " shell command line; timeout_ms (optional, default 120000) — the process"
      .. " tree is killed after this many milliseconds. Refuses read/search/list"
      .. " commands (cat/head/tail/sed -n/wc, grep/rg, ls/find/fd/stat/file) run bare"
      .. " or piped only into head/tail/wc/sort/uniq/cut/tr, and bare curl/wget, even"
      .. " behind a leading `cd <dir> &&`; any redirect, `;`, `&&`, `||`, `$(`, sudo or"
      .. " other pipeline stage lets the command run. When the same command runs a"
      .. " second time in a session, the result ends with a note suggesting a"
      .. " dedicated tool via registry_define.",
    input_schema = {
      type = "object",
      properties = {
        command = { type = "string", description = "Shell command to run with bash -lc." },
        timeout_ms = { type = "integer", description = "Timeout in milliseconds (default 120000)." },
      },
      required = { "command" },
    },
    source = [==[
local run_counts = {}

local function strip_cd(s)
  for _, dir in ipairs({ '"[^"]*"', "'[^']*'", "[^%s;&|]+" }) do
    for _, sep in ipairs({ "&&", ";" }) do
      local rest = s:match("^cd%s+" .. dir .. "%s*" .. vim.pesc(sep) .. "%s*(.*)$")
      if rest then return rest end
    end
  end
  return s
end

local function head_redirect(s, piped)
  if s:match("^cat%s+%S")
    or s:match("^head%s+%S")
    or s:match("^tail%s+%S")
    or s:match("^sed%s+%-n%s")
    or s:match("^wc%s+%S") then
    return "tool.read_file (supports offset/limit, gives line numbers)"
  elseif s:match("^grep%s+%S") or s:match("^rg%s+%S") then
    return "tool.grep (regex search, caps results, also populates this session's findings list)"
  elseif s == "ls" or s:match("^ls%s")
    or s:match("^find%s+%S") or s:match("^fd%s+%S") then
    return "tool.tree or tool.glob (bounded file listings)"
  elseif s:match("^stat%s+%S") or s:match("^file%s+%S") then
    return "tool.path_info (filesystem metadata without shelling out)"
  elseif not piped and (s:match("^curl%s+https?://") or s:match("^wget%s+https?://")) then
    return "tool.fetch_url (bounded web fetch without ambient shell state)"
  end
end

local filters = { head = true, tail = true, wc = true, sort = true, uniq = true, cut = true, tr = true }

local function redirect_for(trimmed)
  local s = strip_cd(trimmed):gsub("'[^']*'", "''")
  if s:find("[><;&`$(]") or s:find("%f[%a]sudo%f[%A]") then return nil end
  local stages = vim.split(s, "|", { plain = true })
  for i, stage in ipairs(stages) do
    stage = vim.trim(stage)
    if stage == "" then return nil end
    if i > 1 and not filters[stage:match("^(%S+)")] then return nil end
    stages[i] = stage
  end
  return head_redirect(stages[1], #stages > 1)
end

local function note_run(bufnr, trimmed)
  if not bufnr or #trimmed < 12 then return nil end
  local key = bufnr
  local counts = run_counts[key]
  if not counts then
    counts = {}
    run_counts[key] = counts
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_create_autocmd("BufWipeout", {
        buffer = bufnr,
        once = true,
        callback = function() run_counts[key] = nil end,
      })
    end
  end
  counts[trimmed] = (counts[trimmed] or 0) + 1
  local n = counts[trimmed]
  if n < 2 then return nil end
  return "[straps: this exact command has run " .. n .. " times this session; registry_define"
    .. " a tool for it (e.g. tool.run_tests) so it stops costing a bash round trip]"
end

return function(input, ctx)
  local cmd = input.command or ""
  local trimmed = cmd:match("^%s*(.-)%s*$")
  local redirect = redirect_for(trimmed)
  if redirect then
    return "bash: refusing plain read/search/list command (" .. trimmed ..
      "). Use " .. redirect .. " instead."
  end
  local nudge = note_run(ctx.bufnr, trimmed)

  local timeout_ms = tonumber(input.timeout_ms) or 120000
  local cap = 262144
  local stdout, stderr = {}, {}
  local out_len, err_len = 0, 0
  local capped = false
  local proc
  local finished, timed_out = false, false
  local release = require("straps.registry").try_call("fn.subprocess_acquire", ctx,
    { tool = "bash", bufnr = ctx.bufnr, cmd = cmd }) or function() end
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
    dst[#dst + 1] = require("straps.state").utf8_cut(chunk, keep)
    if keep < #chunk then capped = true; stop_for_cap() end
    if len_name == "out" then out_len = len + keep else err_len = len + keep end
  end
  local res = ctx.await(function(resolve)
    local ok_spawn, spawned = pcall(function()
      return vim.system(
        { "bash", "-lc", cmd },
        {
          text = true,
          cwd = vim.fn.getcwd(),
          detach = true,
          stdout = function(_, chunk) take(stdout, "out", chunk) end,
          stderr = function(_, chunk) take(stderr, "err", chunk) end,
        },
        function(out)
          finished = true
          release()
          resolve(out)
        end)
    end)
    if not ok_spawn then
      finished = true
      release()
      resolve({ code = -1, stderr = "bash: could not spawn: " .. tostring(spawned) })
      return
    end
    proc = spawned
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
  lines[#lines + 1] = table.concat(stderr) .. (res.stderr or "")
  if nudge then lines[#lines + 1] = nudge end
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
  local release = require("straps.registry").try_call("fn.subprocess_acquire", ctx,
    { tool = "run_in_terminal", bufnr = ctx.bufnr, cmd = cmd }) or function() end

  local prev_win = vim.api.nvim_get_current_win()
  local ok_split, split_err = pcall(vim.cmd, "botright 15new")
  if not ok_split then
    release()
    error("run_in_terminal: could not open the terminal split: " .. tostring(split_err))
  end
  local term_buf = vim.api.nvim_get_current_buf()

  local timed_out, finished = false, false
  local code, start_err = ctx.await(function(resolve)
    local function on_exit(_, c)
      finished = true
      release()
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
      release()
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
  local release = require("straps.registry").try_call("fn.subprocess_acquire", ctx,
    { tool = "run_quickfix", bufnr = ctx.bufnr, cmd = cmd }) or function() end

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
    local ok_spawn, spawned = pcall(vim.system,
      { "bash", "-lc", cmd },
      { text = true, detach = true },
      function(out)
        finished = true
        release()
        resolve(out)
      end)
    if not ok_spawn then
      finished = true
      release()
      resolve({ code = -1, stdout = "", stderr = "", spawn_error = tostring(spawned) })
      return
    end
    proc = spawned
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
  if res.spawn_error then
    return "exit code: " .. tostring(res.code) .. " (could not spawn: " .. res.spawn_error .. ")"
  end

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

  -- --------------------------------------------------------- subprocess gate
  --
  -- A counting semaphore shared by the shell tools and grep bounds how many
  -- straps-launched processes run at once across every session in this
  -- Neovim. Four redefinable entries: fn.subprocess_in_flight reads the
  -- counter, fn.subprocess_limit is the policy (how many may run), fn.
  -- subprocess_threads derives rg's --threads from the same numbers, and fn.
  -- subprocess_acquire is the mechanism (counter, FIFO waiters, release). A
  -- plugin replaces any one of them; the default acquire consults the default
  -- limit at every admission, so the two compose through the registry.

  define({
    name = "fn.subprocess_in_flight",
    kind = "fn",
    doc = "Number of straps-launched subprocesses holding a slot right now"
      .. " (bash, run_in_terminal, run_quickfix, grep), across every session in"
      .. " this Neovim. A read accessor over registry.subprocess_state(), the"
      .. " counter fn.subprocess_acquire's take/release write; fn.subprocess_threads"
      .. " reads it, and a redefined fn.subprocess_limit can.",
    source = [==[
return function()
  return require("straps.registry").subprocess_state().in_flight
end
]==],
  })

  define({
    name = "fn.subprocess_limit",
    kind = "fn",
    doc = "Policy: how many straps-launched subprocesses may run at once."
      .. " Default config.max_subprocesses (nil => 2 * CPU count), halved while"
      .. " the 1-minute load average exceeds 2 * CPU count. Consulted at every"
      .. " admission, so a redefinition takes effect on the next waiter."
      .. " Redefine for session-count weighting, a time budget, or an external"
      .. " signal; return a number >= 1.",
    source = [==[
return function()
  local ncpu = vim.uv.available_parallelism() or 1
  local raw
  pcall(function() raw = require("straps").config.max_subprocesses end)
  local limit = math.floor(tonumber(raw) or (2 * ncpu))
  local load = vim.uv.loadavg() or 0
  if load > 2 * ncpu then
    limit = math.floor(limit / 2)
  end
  return math.max(1, limit)
end
]==],
  })

  define({
    name = "fn.subprocess_threads",
    kind = "fn",
    doc = "Thread count for a search process started now (grep passes it as"
      .. " rg --threads): CPU count divided by the slots in flight, floor 1."
      .. " A lone session gets every core; a fan-out shares them.",
    source = [==[
return function()
  local ncpu = vim.uv.available_parallelism() or 1
  local busy = require("straps.registry").try_call("fn.subprocess_in_flight") or 0
  return math.max(1, math.floor(ncpu / math.max(1, busy)))
end
]==],
  })

  define({
    name = "fn.subprocess_acquire",
    kind = "fn",
    doc = "Mechanism: take one subprocess slot, waiting (through ctx.await)"
      .. " while fn.subprocess_in_flight >= fn.subprocess_limit. Called as"
      .. " (ctx, info) with info = { tool, bufnr, cmd }; returns a release"
      .. " function that is idempotent and also registered via ctx.on_cancel,"
      .. " so a cancelled or backstop-resumed holder frees its slot. Release"
      .. " runs before the kill, so a process that survives its group kill runs"
      .. " uncounted and the gate stays open. FIFO admission; a parked waiter"
      .. " whose run was cancelled declines its slot, and a run cancelled between"
      .. " admission and resume errors instead of starting its process. Waiters"
      .. " admitted from a vim.system exit callback are admitted on the main loop"
      .. " in the global registry scope; admissions from a tool body run in that"
      .. " session's scope, so define fn.subprocess_limit globally. A ctx without"
      .. " await (direct registry.call) is admitted at once and may exceed the"
      .. " limit by one. Redefine for priority or"
      .. " per-session fairness; keep the (ctx, info) -> release contract. Tool"
      .. " bodies pcall the spawn and release on the error path, so a spawn that"
      .. " raises (EAGAIN) cannot leak the slot.",
    source = [==[
return function(ctx, info)
  local registry = require("straps.registry")
  local st = registry.subprocess_state()
  local function drain()
    local limit = registry.try_call("fn.subprocess_limit") or math.huge
    while st.in_flight < limit and #st.waiters > 0 do
      local admit = table.remove(st.waiters, 1)
      admit()
    end
  end
  local held = false
  local function release()
    if not held then return end
    held = false
    st.in_flight = st.in_flight - 1
    if #st.waiters > 0 then
      if vim.in_fast_event() then vim.schedule(drain) else drain() end
    end
  end
  local function take()
    held = true
    st.in_flight = st.in_flight + 1
  end
  drain()
  local limit = registry.try_call("fn.subprocess_limit") or math.huge
  if st.in_flight < limit and #st.waiters == 0 then
    take()
  elseif not (ctx and ctx.await) then
    take()
  else
    local waiter
    local function drop()
      for i, w in ipairs(st.waiters) do
        if w == waiter then table.remove(st.waiters, i) break end
      end
    end
    local admitted = ctx.await(function(resolve)
      waiter = function()
        if ctx.cancelled and ctx.cancelled() then
          resolve(false)
          return
        end
        take()
        resolve(true)
      end
      st.waiters[#st.waiters + 1] = waiter
      if ctx.on_cancel then
        ctx.on_cancel(function()
          drop()
          release()
          resolve(false)
        end)
      end
    end)
    if not admitted or (ctx.cancelled and ctx.cancelled()) then
      drop()
      release()
      error("subprocess slot wait cancelled" .. (info and info.tool and (" (" .. info.tool .. ")") or ""))
    end
  end
  if ctx and ctx.on_cancel then
    ctx.on_cancel(release)
  end
  return release
end
]==],
  })
end

return M
