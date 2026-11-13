-- straps/layers/exec.lua — the EXEC layer: shell execution (bash, the
-- windowless terminal runner and show_terminal, and the quickfix-parsing runner).
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
          cwd = vim.fn.getcwd(-1, -1),
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
    doc = "Run a shell command in a :terminal buffer that has NO window by default,"
      .. " so N agents running terminals do not clutter the user's layout. Use it for"
      .. " test suites, builds, and anything long-running; use bash for quick, quiet"
      .. " commands. The full terminal output is returned. The buffer is kept after"
      .. " the job exits (whatever the exit code; a call with no session buffer wipes"
      .. " it unless it is shown) and its number is in the result;"
      .. " this session keeps only its most recent terminal buffer — the next"
      .. " run_in_terminal wipes the previous one unless a window shows it. Pass"
      .. " show=true to open the terminal in a split at job start so the user can"
      .. " watch it stream live; otherwise call show_terminal when the user needs to"
      .. " see the output (a failure, something worth their eyes). If the job cannot"
      .. " start at all, the buffer is wiped and the tool errors."
      .. " Parameters: command (required) — shell command run via bash -lc;"
      .. " timeout_ms (optional, default 300000) — the job is stopped if it"
      .. " runs longer; show (optional, default false) — open the terminal in a"
      .. " split while it runs.",
    input_schema = {
      type = "object",
      properties = {
        command = { type = "string", description = "Shell command to run in the terminal buffer." },
        timeout_ms = { type = "integer", description = "Timeout in milliseconds (default 300000)." },
        show = { type = "boolean", description = "Open the terminal in a split while it runs (default false)." },
      },
      required = { "command" },
    },
    source = [==[
local function wipe(buf)
  if vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
end

local function shown(buf)
  return vim.api.nvim_buf_is_valid(buf) and #vim.fn.win_findbuf(buf) > 0
end

local function drop_last(sid)
  local prev = vim.b[sid].straps_last_terminal
  if type(prev) ~= "number" or not vim.api.nvim_buf_is_valid(prev) then return end
  if shown(prev) then
    vim.bo[prev].bufhidden = "wipe"
  else
    wipe(prev)
  end
end

return function(input, ctx)
  local cmd = input.command
  if type(cmd) ~= "string" or cmd == "" then
    error("run_in_terminal: command must be a non-empty string", 0)
  end
  local timeout_ms = tonumber(input.timeout_ms) or 300000
  local sid = ctx.bufnr
  if type(sid) ~= "number" or sid == 0 or not vim.api.nvim_buf_is_valid(sid) then sid = nil end
  local release = require("straps.registry").try_call("fn.subprocess_acquire", ctx,
    { tool = "run_in_terminal", bufnr = ctx.bufnr, cmd = cmd }) or function() end

  local ok_buf, term_buf = pcall(vim.api.nvim_create_buf, false, false)
  if not ok_buf then
    release()
    error("run_in_terminal: could not create the terminal buffer: " .. tostring(term_buf), 0)
  end
  vim.bo[term_buf].bufhidden = "hide"

  local timed_out, finished = false, false
  local show_err
  local code, start_err = ctx.await(function(resolve)
    local function on_exit(_, c)
      finished = true
      release()
      resolve(c)
    end
    local job = 0
    local cwd = vim.fn.getcwd(-1, -1)
    vim.api.nvim_buf_call(term_buf, function()
      local okj, j = pcall(vim.fn.jobstart, { "bash", "-lc", cmd },
        { term = true, cwd = cwd, width = vim.o.columns, height = 15, on_exit = on_exit })
      if okj and type(j) == "number" and j > 0 then
        job = j
      else
        local okt, t = pcall(vim.fn.termopen, { "bash", "-lc", cmd }, { cwd = cwd, on_exit = on_exit })
        if okt and type(t) == "number" and t > 0 then job = t end
      end
    end)
    if job <= 0 then
      release()
      resolve(nil, "could not start the terminal job")
      return
    end
    vim.b[term_buf].straps_terminal = { session = sid, command = cmd }
    if sid then
      drop_last(sid)
      if vim.b[sid].straps_last_terminal == nil then
        vim.api.nvim_create_autocmd("BufWipeout", {
          buffer = sid,
          once = true,
          callback = function() drop_last(sid) end,
        })
      end
      vim.b[sid].straps_last_terminal = term_buf
    end
    if input.show == true then
      local ok_show, e = pcall(require("straps.registry").call, "tool.show_terminal", { buffer = term_buf }, ctx)
      if not ok_show then show_err = tostring(e) end
    end
    vim.defer_fn(function()
      if not finished then
        timed_out = true
        pcall(vim.fn.jobstop, job)
        vim.defer_fn(function()
          if not finished then
            local ok_pid, pid = pcall(vim.fn.jobpid, job)
            pid = ok_pid and tonumber(pid)
            if pid then pcall(vim.uv.kill, -pid, 9) end
          end
        end, 2000)
      end
    end, timeout_ms)
    if ctx.on_cancel then
      ctx.on_cancel(function()
        pcall(vim.fn.jobstop, job)
        if not sid and vim.api.nvim_buf_is_valid(term_buf) then
          if shown(term_buf) then
            vim.bo[term_buf].bufhidden = "wipe"
          else
            vim.defer_fn(function()
              if not shown(term_buf) then wipe(term_buf) end
            end, 3000)
          end
        end
      end)
    end
  end)
  if start_err then
    wipe(term_buf)
    error("run_in_terminal: " .. start_err, 0)
  end

  local out_lines = {}
  pcall(function()
    out_lines = vim.api.nvim_buf_get_lines(term_buf, 0, -1, false)
  end)
  while #out_lines > 0 and out_lines[#out_lines]:match("^%s*$") do
    table.remove(out_lines)
  end

  local note
  if not vim.api.nvim_buf_is_valid(term_buf) then
    note = "[terminal buffer was wiped while the job ran]"
  elseif shown(term_buf) then
    if not sid then vim.bo[term_buf].bufhidden = "wipe" end
    note = ("[terminal buffer %d is shown in a window]"):format(term_buf)
  elseif sid then
    note = ("[terminal buffer %d has no window; show_terminal { buffer = %d } opens it]")
      :format(term_buf, term_buf)
  else
    wipe(term_buf)
    note = "[terminal buffer wiped: no session to keep it]"
  end
  if show_err then note = note .. "\n[show=true failed: " .. show_err .. "]" end

  return "exit code: " .. tostring(code)
    .. (timed_out and (" (stopped: exceeded timeout of " .. timeout_ms .. " ms)") or "")
    .. "\noutput:\n" .. table.concat(out_lines, "\n")
    .. "\n" .. note
end
]==],
  })

  -- ------------------------------------------------------------ show_terminal

  define({
    name = "tool.show_terminal",
    kind = "tool",
    doc = "Show the user a terminal buffer from run_in_terminal (which runs with no"
      .. " window) in a 15-line split at the bottom, scrolled to the end. Call it when"
      .. " the user needs to see the output: a failure, a result worth their eyes."
      .. " Focus stays where the user was; a later call reuses the window a previous"
      .. " call opened (tagged w:straps_view='terminal') instead of adding a split."
      .. " Read-only (opens a view; changes no files). Parameters: buffer (optional)"
      .. " — the terminal buffer number from a run_in_terminal result; defaults to"
      .. " this session's most recent terminal.",
    input_schema = {
      type = "object",
      properties = {
        buffer = { type = "integer", description = "Terminal buffer number (default: this session's last terminal)." },
      },
    },
    source = [==[
return function(input, ctx)
  input = input or {}
  local buf = tonumber(input.buffer)
  if buf == 0 then buf = nil end
  if not buf then
    local sid = ctx and ctx.bufnr
    if type(sid) == "number" and sid ~= 0 and vim.api.nvim_buf_is_valid(sid) then
      buf = vim.b[sid].straps_last_terminal
    end
    if type(buf) ~= "number" then
      error("show_terminal: this session has no terminal; pass buffer", 0)
    end
  end
  if not vim.api.nvim_buf_is_valid(buf) then
    error("show_terminal: buffer " .. buf .. " no longer exists", 0)
  end
  local info = vim.b[buf].straps_terminal
  if vim.bo[buf].buftype ~= "terminal" or type(info) ~= "table" then
    error("show_terminal: buffer " .. buf .. " is not a run_in_terminal buffer", 0)
  end
  local win
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.w[w].straps_view == "terminal"
      and type(vim.b[vim.api.nvim_win_get_buf(w)].straps_terminal) == "table" then
      win = w
      break
    end
  end
  if not win then
    local cur = vim.api.nvim_get_current_win()
    local ok, err = pcall(vim.cmd, "botright 15split")
    if not ok then error("show_terminal: could not open a split: " .. tostring(err), 0) end
    win = vim.api.nvim_get_current_win()
    pcall(vim.api.nvim_set_current_win, cur)
    local ok_set, set_err = pcall(vim.api.nvim_win_set_buf, win, buf)
    if not ok_set then
      pcall(vim.api.nvim_win_close, win, true)
      error("show_terminal: " .. tostring(set_err), 0)
    end
    vim.w[win].straps_view = "terminal"
  else
    local ok_set, set_err = pcall(vim.api.nvim_win_set_buf, win, buf)
    if not ok_set then error("show_terminal: " .. tostring(set_err), 0) end
  end
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  local command = tostring(info.command or "")
  pcall(function() vim.wo[win].winbar = (command:gsub("%%", "%%%%")) end)
  pcall(vim.api.nvim_win_set_cursor, win, { vim.api.nvim_buf_line_count(buf), 0 })
  return ("show_terminal: opened buffer %d — %s"):format(buf, command)
end
]==],
  })

  -- ------------------------------------------------------------- run_quickfix

  define({
    name = "tool.run_quickfix",
    kind = "tool",
    doc = "Run a shell command (a build, a test run, a linter, a typecheck) and"
      .. " parse its output into this session's findings list (the session"
      .. " window's location list when on-screen; a windowless session keeps it in"
      .. " a private session store and never touches the global quickfix list)"
      .. " through Vim's native errorformat, then open it without moving focus — so a failing build"
      .. " lands as :lnext/:lprev navigable"
      .. " file:line entries in the user's editor instead of a wall of"
      .. " text in the transcript. Use this instead of bash/run_in_terminal when"
      .. " the command emits compiler/linter-style diagnostics you want the user"
      .. " to step through. The result the agent sees is a compact summary: exit"
      .. " code and the parsed entries as `file:line:col: message` (capped),"
      .. " which is far smaller than raw output. Each output stream is capped at"
      .. " 262144 bytes before parsing (a note says when). The command runs in"
      .. " Neovim's global working directory. Parameters: command (required)"
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
    error("run_quickfix: command must be a non-empty string", 0)
  end
  local timeout_ms = tonumber(input.timeout_ms) or 300000
  local release = require("straps.registry").try_call("fn.subprocess_acquire", ctx,
    { tool = "run_quickfix", bufnr = ctx.bufnr, cmd = cmd }) or function() end

  local proc
  local finished, timed_out = false, false
  local stream_cap = 262144
  local streams, lens, capped = { out = {}, err = {} }, { out = 0, err = 0 }, false
  local function take(which, chunk)
    if not chunk or chunk == "" then return end
    local len = lens[which]
    if len >= stream_cap then capped = true; return end
    local keep = math.min(#chunk, stream_cap - len)
    local dst = streams[which]
    dst[#dst + 1] = require("straps.state").utf8_cut(chunk, keep)
    if keep < #chunk then capped = true end
    lens[which] = len + keep
  end
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
      {
        text = true,
        detach = true,
        cwd = vim.fn.getcwd(-1, -1),
        stdout = function(_, chunk) take("out", chunk) end,
        stderr = function(_, chunk) take("err", chunk) end,
      },
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
  local raw = table.concat(streams.out) .. table.concat(streams.err)
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
  -- window's location list when on-screen, its private store when windowless,
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
  local nav = require("straps.findings").nav_hint(list_kind)

  -- Compact summary for the agent: the exit code and the parsed locations,
  -- NOT the raw output (which is what the list is for). Cap the listing.
  local out = { "exit code: " .. tostring(res.code) }
  if timed_out then
    out[#out] = out[#out] .. " (killed: exceeded timeout of " .. timeout_ms .. " ms)"
  end
  if capped then
    out[#out + 1] = "output truncated at " .. stream_cap .. " bytes per stream; entries past the cut were not parsed"
  end
  if #valid == 0 then
    out[#out + 1] = list_kind .. ": no entries parsed (0 diagnostics)"
    if raw:match("%S") and not (type(input.errorformat) == "string" and input.errorformat ~= "") then
      out[#out + 1] = "note: output was non-empty but matched no errorformat entry —"
        .. " pass an explicit `errorformat` describing this command's output."
    end
  else
    out[#out + 1] = ("%s: %d entr%s (%s) — %s")
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
  -- A counting semaphore shared by the shell tools, grep and fetch_url bounds how many
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
      .. " (bash, run_in_terminal, run_quickfix, grep, fetch_url), across every session in"
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
      error("subprocess slot wait cancelled" .. (info and info.tool and (" (" .. info.tool .. ")") or ""), 0)
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
