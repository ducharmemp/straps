local M = {}
local ns = vim.api.nvim_create_namespace("straps_agents")
local dashboards = {}
local name = "straps://agents"
local keys = "<CR> open  p details  i message  g<CR> start  x stop  r rename  R refresh  <F1> help"
local timer

local function ui() return require("straps.ui") end
local function config() return require("straps").config end
local function fit(text, width)
  text = tostring(text or ""):gsub("%s+", " ")
  if width < 1 then return "" end
  if vim.fn.strdisplaywidth(text) <= width then return text end
  local n = math.min(vim.fn.strchars(text), width)
  while n > 0 and vim.fn.strdisplaywidth(vim.fn.strcharpart(text, 0, n) .. "…") > width do n = n - 1 end
  return vim.fn.strcharpart(text, 0, n) .. "…"
end

local function width(buf)
  local result = 76
  local wins = vim.fn.win_findbuf(buf)
  for i, win in ipairs(wins) do
    local info = vim.fn.getwininfo(win)[1]
    local size = math.max(1, vim.api.nvim_win_get_width(win) - (info and info.textoff or 0))
    result = i == 1 and size or math.min(result, size)
  end
  return result
end

local function legend(w)
  if vim.fn.strdisplaywidth(keys) <= w then return keys end
  return fit("<CR> open  p details  <F1> help", w)
end

local function identity(entry)
  if not entry then return nil end
  return entry.bufnr and ("buf:" .. entry.bufnr) or (entry.path and "path:" .. entry.path) or entry.id
end

local function data(buf)
  dashboards[buf] = dashboards[buf] or { map = {}, folds = {}, views = {}, preview = {} }
  return dashboards[buf]
end

local function status(buf)
  if require("straps.loop").running(buf) then
    local phase = vim.b[buf].straps_phase
    return phase and phase ~= "" and phase or "running"
  end
  local reason = vim.b[buf].straps_run_reason
  return ({ ok = "finished", cancelled = "stopped", error = "failed", max_turns = "turn limit", stalled = "stalled", blank = "blank" })[reason] or "idle"
end

local function title(buf)
  local path = vim.api.nvim_buf_get_name(buf)
  local durable = vim.bo[buf].buftype == "" and path ~= "" and require("straps.state").session_title(path)
  return durable or vim.b[buf].straps_task or ui().session_label(buf)
end

local function capture(buf, win)
  local st = data(buf)
  return vim.api.nvim_win_call(win, function()
    local view = vim.fn.winsaveview()
    local selected = identity(st.map[view.lnum])
    local top = identity(st.map[view.topline])
    local closed = {}
    local opened = {}
    local ordered = {}
    for _, fold in ipairs(st.folds) do ordered[#ordered + 1] = fold end
    table.sort(ordered, function(a, b)
      if a.first == b.first then return a.last > b.last end
      return a.first < b.first
    end)
    for _, fold in ipairs(ordered) do
      if vim.fn.foldclosed(fold.first) == fold.first and vim.fn.foldclosedend(fold.first) == fold.last then
        closed[fold.id] = true
        vim.cmd("silent! " .. fold.first .. "foldopen")
        opened[#opened + 1] = fold
      end
    end
    for i = #opened, 1, -1 do vim.cmd("silent! " .. opened[i].first .. "foldclose") end
    vim.fn.winrestview(view)
    return { view = view, selected = selected, top = top, closed = closed, initialized = true }
  end)
end

local function row_for(st, id, fallback)
  local best, distance
  for line, entry in pairs(st.map) do
    if identity(entry) == id then return line end
    if entry.bufnr or entry.path then
      local d = math.abs(line - fallback)
      if not distance or d < distance or (d == distance and line < best) then best, distance = line, d end
    end
  end
  return best or 1
end

local function restore(buf, win, snapshot, rebuild)
  local st = data(buf)
  vim.api.nvim_win_call(win, function()
    vim.wo[win][0].foldmethod = "manual"
    vim.wo[win][0].foldenable = true
    vim.wo[win][0].foldtext = "v:lua.require'straps.agents'.foldtext()"
    if rebuild then
      vim.cmd("silent! normal! zE")
      local ordered = {}
      for _, fold in ipairs(st.folds) do ordered[#ordered + 1] = fold end
      table.sort(ordered, function(a, b) return (a.last - a.first) < (b.last - b.first) end)
      for _, fold in ipairs(ordered) do
        if fold.last > fold.first then vim.cmd(("silent! %d,%dfold"):format(fold.first, fold.last)) end
      end
      vim.cmd("silent! normal! zR")
      for _, fold in ipairs(ordered) do
        if (snapshot and snapshot.closed[fold.id]) or (not snapshot and fold.id == "section:saved") then
          vim.cmd("silent! " .. fold.first .. "foldclose")
        end
      end
    end
    if snapshot then
      local view = vim.deepcopy(snapshot.view)
      view.lnum = row_for(st, snapshot.selected, view.lnum)
      view.topline = row_for(st, snapshot.top, view.topline)
      local text = vim.api.nvim_buf_get_lines(buf, view.lnum - 1, view.lnum, false)[1] or ""
      view.col = math.min(view.col, math.max(0, #text - 1))
      vim.fn.winrestview(view)
    else
      local first = row_for(st, nil, 1)
      vim.api.nvim_win_set_cursor(win, { first, 0 })
    end
    st.views[win] = capture(buf, win)
  end)
end

function M.foldtext()
  local text = vim.fn.getline(vim.v.foldstart)
  return fit(text .. "  · " .. (vim.v.foldend - vim.v.foldstart) .. " rows", width(vim.api.nvim_get_current_buf()))
end

function M.line(buf, line) return data(buf).map[line] end

local function forest(sets)
  local nodes = {}
  for _, kind in ipairs({ "running", "loaded" }) do
    for _, item in ipairs(sets[kind]) do nodes[item.bufnr] = { bufnr = item.bufnr, kind = kind, children = {} } end
  end
  local ids = {}
  for id in pairs(nodes) do ids[#ids + 1] = id end
  table.sort(ids)
  for _, id in ipairs(ids) do
    local parent = vim.b[id].straps_parent
    if nodes[parent] and parent ~= id then nodes[id].parent = parent end
  end
  for _, id in ipairs(ids) do
    local seen, current = {}, id
    while current and nodes[current] do
      if seen[current] then nodes[current].parent = nil; break end
      seen[current] = true
      current = nodes[current].parent
    end
  end
  local roots = {}
  for _, id in ipairs(ids) do
    local parent = nodes[id].parent
    if parent then nodes[parent].children[#nodes[parent].children + 1] = id else roots[#roots + 1] = id end
  end
  return nodes, roots
end

function M.render(buf)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  local st, w = data(buf), width(buf)
  local snapshots = {}
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if st.views[win] then snapshots[win] = capture(buf, win) end
  end
  local sets = ui().all_sessions()
  local lines, map, hls, folds = {}, {}, {}, {}
  local function add(text, entry, group)
    lines[#lines + 1] = fit(text, w)
    map[#lines] = entry
    if group then hls[#hls + 1] = { #lines - 1, group } end
    return #lines
  end
  if config().agents_winbar == false then add(legend(w), nil, "StrapsRule") end
  local nodes, roots = forest(sets)
  if #roots > 0 then
    local heading = add(("Agents · %d running · %d loaded"):format(#sets.running, #sets.loaded), { id = "section:agents" }, "StrapsRoleAgent")
    local function visit(id, depth)
      local node, state = nodes[id], status(id)
      local prefix = string.rep("  ", math.min(depth + 1, math.max(0, math.floor(w / 6)))) .. (#node.children > 0 and "▾ " or (node.kind == "running" and "▶ " or "∙ "))
      local info = ui().session_info(id) or {}
      local tail = state
      local metadata = info.context_pct and ("ctx " .. info.context_pct .. "%") or nil
      if metadata and w >= 60 then tail = metadata .. "  " .. tail end
      local room = w - vim.fn.strdisplaywidth(prefix) - vim.fn.strdisplaywidth(tail) - 2
      local text
      if room >= 8 then
        local label = fit(title(id), room)
        text = prefix .. label .. string.rep(" ", math.max(2, w - vim.fn.strdisplaywidth(prefix .. label .. tail))) .. tail
      else text = prefix .. title(id) end
      local first = add(text, { kind = node.kind, bufnr = id }, node.kind == "running" and "StrapsRoleAgent" or "Normal")
      for _, child in ipairs(node.children) do visit(child, depth + 1) end
      if #node.children > 0 then folds[#folds + 1] = { id = "buf:" .. id, first = first, last = #lines } end
    end
    for _, root in ipairs(roots) do visit(root, 0) end
    folds[#folds + 1] = { id = "section:agents", first = heading, last = #lines }
  end
  if #sets.saved > 0 then
    local heading = add("Saved · " .. #sets.saved, { id = "section:saved" }, "StrapsRoleAgent")
    for _, item in ipairs(sets.saved) do
      local age = ui()._relative_time(item.mtime)
      local room = w - vim.fn.strdisplaywidth(age) - 4
      local label = fit(item.summary or item.name, math.max(1, room))
      local text = room >= 8 and ("  " .. label .. string.rep(" ", math.max(2, w - 2 - vim.fn.strdisplaywidth(label .. age))) .. age) or ("  " .. (item.summary or item.name))
      add(text, { kind = "saved", path = item.path }, "Normal")
    end
    folds[#folds + 1] = { id = "section:saved", first = heading, last = #lines }
  end
  if #lines == 0 or (#roots == 0 and #sets.saved == 0) then add("no agent sessions — :Straps starts one", nil, "StrapsRule") end
  local changed = not vim.deep_equal(lines, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  local fold_changed = not vim.deep_equal(st.folds, folds)
  vim.bo[buf].modifiable = true
  local ok, err = pcall(function()
    if changed then vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines) end
    if changed or not vim.deep_equal(st.hls, hls) then
      vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
      for _, hl in ipairs(hls) do
        vim.api.nvim_buf_set_extmark(buf, ns, hl[1], 0, { end_row = hl[1] + 1, hl_group = hl[2] })
      end
    end
  end)
  vim.bo[buf].modifiable = false
  if not ok then error(err) end
  st.map, st.folds, st.hls = map, folds, hls
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do restore(buf, win, snapshots[win] or st.views[win], changed or fold_changed or not st.views[win]) end
  if st.detail and st.detail.follow then M.details(buf, st.detail.source) end
end

local function find()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf) == name then return buf end
  end
end

local function render(buf) require("straps.registry").try_call("fn.agents_render", buf) end

function M.refresh()
  local buf = find()
  if not buf or #vim.fn.win_findbuf(buf) == 0 then return end
  timer = timer or vim.uv.new_timer()
  timer:stop()
  timer:start(100, 0, function()
    vim.schedule(function()
      local current = find()
      if current and #vim.fn.win_findbuf(current) > 0 then render(current) end
    end)
  end)
end

local function preview(buf, st)
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  if st.preview[buf] and st.preview[buf].tick == tick then return st.preview[buf].lines end
  local count = vim.api.nvim_buf_line_count(buf)
  local start = math.max(0, count - 256)
  local tail = vim.api.nvim_buf_get_lines(buf, start, count, false)
  local first, last
  local ending = #tail
  for i = #tail, 1, -1 do
    local kind = tail[i]:match("^%%%%%[straps:([%w_]+)")
    if kind then
      if kind == "assistant" then first, last = i + 1, ending; break end
      ending = i - 1
    end
  end
  local lines = {}
  if first then
    for i = first, math.min(last, first + 11) do lines[#lines + 1] = fit(tail[i], 240) end
    if last >= first + 12 then lines[#lines + 1] = "…" end
  else lines = { start > 0 and "Assistant text is outside the last 256 lines; open the transcript." or "No assistant text yet." } end
  st.preview[buf] = { tick = tick, lines = lines }
  return lines
end

function M.details(buf, source)
  local st = data(buf)
  source = source or vim.api.nvim_get_current_win()
  if not vim.api.nvim_win_is_valid(source) or vim.api.nvim_win_get_buf(source) ~= buf then return end
  local detail = st.detail
  if not detail or not vim.api.nvim_win_is_valid(detail.win) or not vim.api.nvim_buf_is_valid(detail.buf) or vim.api.nvim_win_get_buf(detail.win) ~= detail.buf then
    local old = vim.api.nvim_get_current_win()
    vim.api.nvim_win_call(source, function() vim.cmd("botright vsplit") end)
    local win = vim.api.nvim_get_current_win()
    if win == old then
      for _, candidate in ipairs(vim.api.nvim_list_wins()) do if candidate ~= source and vim.api.nvim_win_get_buf(candidate) == buf then win = candidate end end
    end
    local scratch = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(scratch, "straps://agents-detail/" .. scratch)
    vim.bo[scratch].bufhidden = "wipe"
    vim.bo[scratch].filetype = "markdown"
    vim.api.nvim_win_set_buf(win, scratch)
    vim.wo[win][0].number, vim.wo[win][0].relativenumber = false, false
    vim.api.nvim_set_current_win(old)
    detail = { win = win, buf = scratch, follow = detail and detail.follow or false, source = source }
    st.detail = detail
  end
  detail.source = source
  local entry = st.map[vim.api.nvim_win_get_cursor(source)[1]]
  local lines = {}
  if entry and entry.bufnr and vim.api.nvim_buf_is_valid(entry.bufnr) then
    local target = entry.bufnr
    local info = ui().session_info(target) or {}
    lines = { title(target), "Status: " .. status(target), "Model: " .. (info.model_label or "?"), "Context: " .. (info.context_pct and (info.context_pct .. "%") or "unknown") }
    if info.parent then lines[#lines + 1] = "Parent: " .. ui().session_label(info.parent) end
    if vim.b[target].straps_task then
      lines[#lines + 1] = "Task:"
      local task = vim.split(vim.b[target].straps_task, "\n", { plain = true })
      for i = 1, math.min(16, #task) do lines[#lines + 1] = fit(task[i], 240) end
      if #task > 16 then lines[#lines + 1] = "…" end
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Latest assistant text (bounded preview):"
    for _, line in ipairs(preview(target, st)) do lines[#lines + 1] = line end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "<CR> transcript · i message · g<CR> start · r rename · <F1> help"
  elseif entry and entry.path then lines = { "Saved transcript", entry.path, "Open the transcript to inspect its content." }
  else lines = { "Select a session to inspect its details." } end
  for i, line in ipairs(lines) do lines[i] = fit(line, 240) end
  if not vim.deep_equal(lines, vim.api.nvim_buf_get_lines(detail.buf, 0, -1, false)) then
    vim.bo[detail.buf].modifiable = true
    vim.api.nvim_buf_set_lines(detail.buf, 0, -1, false, lines)
    vim.bo[detail.buf].modifiable = false
  end
end

local function selected(buf)
  local entry = data(buf).map[vim.api.nvim_win_get_cursor(0)[1]]
  if entry and entry.bufnr and not vim.api.nvim_buf_is_valid(entry.bufnr) then
    vim.notify("straps: that session buffer is gone", vim.log.levels.INFO)
    render(buf)
    return nil
  end
  return entry
end

function M.key(buf, key)
  if key == "R" then require("straps.state").clear_session_summary_cache(); render(buf); return end
  if key == "help" then vim.cmd("help straps-agents"); return end
  if key == "p" or key == "P" then
    M.details(buf)
    if key == "P" then local detail = data(buf).detail; if detail then detail.follow = not detail.follow end end
    return
  end
  local entry = selected(buf)
  if not entry or not (entry.bufnr or entry.path) then
    if key == "x" or key == "i" then vim.notify("straps: not a running agent", vim.log.levels.INFO) end
    return
  end
  if key == "cr" or key == "gcr" then
    if entry.path then
      if vim.fn.filereadable(entry.path) ~= 1 then vim.notify("straps: transcript no longer exists", vim.log.levels.INFO); render(buf); return end
      if key == "gcr" then entry = { bufnr = require("straps.state").open_session_file(entry.path) }
      else ui().resume_session(entry.path, "none"); return end
    end
    if key == "cr" then ui().show_session(entry.bufnr, "none")
    elseif not require("straps.loop").running(entry.bufnr) then require("straps.loop").start(entry.bufnr) end
    M.refresh()
  elseif key == "i" and entry.bufnr then
    local target = entry.bufnr
    vim.ui.input({ prompt = "Message " .. fit(title(target), 60) .. ": " }, function(text)
      if text and text:match("%S") then require("straps.registry").try_call("fn.session_notify", target, text); M.refresh() end
    end)
  elseif key == "r" then
    if entry.bufnr then ui().rename_session(entry.bufnr)
    else
      vim.ui.input({ prompt = "session title: ", default = require("straps.state").session_title(entry.path) or "" }, function(text)
        if text ~= nil then require("straps.state").set_session_title(entry.path, text); M.refresh() end
      end)
    end
  elseif key == "x" then
    local loop = require("straps.loop")
    if not entry.bufnr or not loop.running(entry.bufnr) then vim.notify("straps: not a running agent", vim.log.levels.INFO); return end
    local descendants = 0
    for _, child in ipairs(loop.running_sessions()) do
      local seen, current = {}, child
      while current and vim.api.nvim_buf_is_valid(current) and not seen[current] do
        seen[current] = true
        current = vim.b[current].straps_parent
        if current == entry.bufnr then descendants = descendants + 1; break end
      end
    end
    if descendants > 0 and vim.fn.confirm("Stop selected agent and " .. descendants .. " running descendants?", "&Stop\n&Cancel", 2) ~= 1 then return end
    loop.stop(entry.bufnr)
    M.refresh()
  end
end

function M.open(split)
  local buf = find()
  if not buf then
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, name)
    vim.bo[buf].bufhidden, vim.bo[buf].filetype, vim.bo[buf].modifiable = "hide", "strapsagents", false
    data(buf)
    for lhs, key in pairs({ ["<CR>"] = "cr", ["g<CR>"] = "gcr", x = "x", i = "i", r = "r", R = "R", p = "p", P = "P", ["<F1>"] = "help" }) do
      vim.keymap.set("n", lhs, function() M.key(buf, key) end, { buffer = buf, silent = true, nowait = true })
    end
    local group = vim.api.nvim_create_augroup("StrapsAgentsBuf" .. buf, { clear = true })
    vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter" }, { group = group, buffer = buf, callback = M.refresh })
    vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, { group = group, callback = M.refresh })
    vim.api.nvim_create_autocmd("BufLeave", { group = group, buffer = buf, callback = function()
      local win = vim.api.nvim_get_current_win()
      if vim.api.nvim_win_get_buf(win) == buf then data(buf).views[win] = capture(buf, win) end
    end })
    vim.api.nvim_create_autocmd("CursorMoved", { group = group, buffer = buf, callback = function()
      local detail = data(buf).detail
      if detail and detail.follow then M.details(buf) end
    end })
    vim.api.nvim_create_autocmd("BufWipeout", { group = group, buffer = buf, callback = function()
      if timer and not timer:is_closing() then timer:stop(); timer:close() end
      timer = nil
      local detail = dashboards[buf] and dashboards[buf].detail
      if detail and vim.api.nvim_win_is_valid(detail.win) then pcall(vim.api.nvim_win_close, detail.win, true) end
      dashboards[buf] = nil
    end })
  end
  local win
  for _, candidate in ipairs(vim.api.nvim_list_wins()) do if vim.api.nvim_win_get_buf(candidate) == buf then win = candidate; break end end
  if win then vim.api.nvim_set_current_win(win)
  else vim.cmd(split and split ~= "" and split or "split"); vim.api.nvim_win_set_buf(0, buf) end
  local winopts = vim.wo[vim.api.nvim_get_current_win()][0]
  winopts.wrap, winopts.cursorline, winopts.number, winopts.relativenumber = false, true, false, false
  winopts.signcolumn, winopts.foldcolumn = "no", "0"
  winopts.winbar = config().agents_winbar == false and "" or "%{%v:lua.require'straps.ui'.winbar()%}"
  render(buf)
  return buf
end

function M.winbar()
  local win = vim.g.statusline_winid
  if type(win) ~= "number" or not vim.api.nvim_win_is_valid(win) then win = vim.api.nvim_get_current_win() end
  local w = vim.api.nvim_win_get_width(win)
  return "%#StrapsWinbar#" .. fit(legend(w), w):gsub("%%", "%%%%")
end

return M
