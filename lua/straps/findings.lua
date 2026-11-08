local M = {}

M.STORE_KIND = "session store"

local store = {}
local tracking_ns = vim.api.nvim_create_namespace("straps_findings_tracking")

local function clear_marks(s)
  for _, m in pairs(s.marks) do
    pcall(vim.api.nvim_buf_del_extmark, m.buf, tracking_ns, m.id)
  end
end

local function current_items(s)
  for i, m in pairs(s.marks) do
    local ok, pos = pcall(vim.api.nvim_buf_get_extmark_by_id, m.buf, tracking_ns, m.id, {})
    if ok and pos[1] then s.items[i].lnum = pos[1] + 1 end
  end
  return s.items
end

local function is_session(bufnr)
  return type(bufnr) == "number" and bufnr > 0 and vim.api.nvim_buf_is_valid(bufnr)
    and vim.b[bufnr].straps_session == true
end

function M.session_win(bufnr)
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    return nil
  end
  local wins = vim.fn.win_findbuf(bufnr)
  if type(wins) ~= "table" then
    return nil
  end
  table.sort(wins)
  for _, w in ipairs(wins) do
    if vim.api.nvim_win_is_valid(w)
        and vim.api.nvim_win_get_config(w).relative == "" then
      return w
    end
  end
  return nil
end

local function normalize(items)
  local out = {}
  for _, it in ipairs(items) do
    local e = vim.deepcopy(it)
    if (type(e.bufnr) ~= "number" or e.bufnr == 0) and type(e.filename) == "string" and e.filename ~= "" then
      e.bufnr = vim.fn.bufadd(vim.fn.fnamemodify(e.filename, ":p"))
    end
    e.lnum = tonumber(e.lnum) or 0
    e.col = tonumber(e.col) or 0
    e.text = e.text or ""
    e.valid = (type(e.bufnr) == "number" and e.bufnr > 0) and 1 or 0
    out[#out + 1] = e
  end
  return out
end

local function mirror(bufnr, win)
  local s = store[bufnr]
  if s and win then
    pcall(vim.fn.setloclist, win, {}, "r", { title = s.title, items = current_items(s) })
  end
end

local function store_set(bufnr, title, items)
  if not store[bufnr] then
    local enter = vim.api.nvim_create_autocmd("BufWinEnter", {
      buffer = bufnr,
      callback = function() mirror(bufnr, M.session_win(bufnr)) end,
    })
    vim.api.nvim_create_autocmd("BufWipeout", {
      buffer = bufnr,
      once = true,
      callback = function()
        clear_marks(store[bufnr])
        store[bufnr] = nil
        pcall(vim.api.nvim_del_autocmd, enter)
      end,
    })
  end
  if store[bufnr] then clear_marks(store[bufnr]) end
  local s = { title = title, items = normalize(items), marks = {} }
  for i, e in ipairs(s.items) do
    local b = e.bufnr
    if type(b) == "number" and b > 0 and vim.api.nvim_buf_is_valid(b) and e.lnum > 0 then
      pcall(vim.fn.bufload, b)
      if e.lnum <= vim.api.nvim_buf_line_count(b) then
        s.marks[i] = { buf = b, id = vim.api.nvim_buf_set_extmark(b, tracking_ns, e.lnum - 1, 0,
          { right_gravity = false, undo_restore = true }) }
      end
    end
  end
  store[bufnr] = s
end

function M.stored(bufnr)
  local s = store[bufnr]
  if s then current_items(s) end
  return s
end

--- How the user steps a list of `kind`, for tool results.
function M.nav_hint(kind)
  if kind == "loclist" then return "the user can step them with :lnext/:lprev" end
  if kind == M.STORE_KIND then
    return "this session has no window, so they are kept in its private session store"
      .. " (bulk_replace reads them); the global quickfix list was not touched"
  end
  return "the user can step them with :cnext/:cprev"
end

local function keep_focus(fn)
  local prev = vim.api.nvim_get_current_win()
  pcall(fn)
  if vim.api.nvim_win_is_valid(prev) and vim.api.nvim_get_current_win() ~= prev then
    pcall(vim.api.nvim_set_current_win, prev)
  end
end

function M.set_locations(bufnr, what, open)
  local win = M.session_win(bufnr)
  local title = what.title
  local items = what.items or {}
  if is_session(bufnr) then
    store_set(bufnr, title, items)
    if win then
      mirror(bufnr, win)
      if open and #items > 0 then
        keep_focus(function() vim.fn.win_execute(win, "lopen") end)
      end
      return "loclist"
    end
    return M.STORE_KIND
  end
  if win then
    pcall(vim.fn.setloclist, win, {}, " ", { title = title, items = items })
    if open and #items > 0 then
      keep_focus(function() vim.fn.win_execute(win, "lopen") end)
    end
    return "loclist"
  end
  pcall(vim.fn.setqflist, {}, " ", { title = title, items = items })
  if open and #items > 0 then
    keep_focus(function() vim.cmd("botright copen") end)
  end
  return "quickfix"
end

--- Read this session's findings list. Returns items(list), kind, win-or-nil.
function M.get_locations(bufnr)
  if is_session(bufnr) then
    local win = M.session_win(bufnr)
    local s = store[bufnr]
    mirror(bufnr, win)
    return s and vim.deepcopy(current_items(s)) or {}, win and "loclist" or M.STORE_KIND, win
  end
  local win = M.session_win(bufnr)
  if win then return vim.fn.getloclist(win), "loclist", win end
  return vim.fn.getqflist(), "quickfix", nil
end

--- Run an ex command on the line of every entry in this session's findings
--- list, the way :ldo/:cdo would, without navigating any window: each entry's
--- buffer is edited through nvim_buf_call, the line is tracked by an extmark
--- (so earlier substitutions that add or remove lines do not shift later
--- entries), and the view of any window showing that buffer is restored.
--- `body` is the command after the range, e.g. "s#a#b#ge | update". Stops at
--- the first failing entry. Returns ok, err, kind.
function M.locations_do(bufnr, body)
  local items, kind, win = M.get_locations(bufnr)
  local ns = vim.api.nvim_create_namespace("straps_findings_do")
  local marks = {}
  for _, e in ipairs(items) do
    local b = e.bufnr
    if type(b) == "number" and b > 0 and vim.api.nvim_buf_is_valid(b) and (e.lnum or 0) > 0 then
      pcall(vim.fn.bufload, b)
      if e.lnum <= vim.api.nvim_buf_line_count(b) then
        marks[#marks + 1] = { buf = b, item = e, id = vim.api.nvim_buf_set_extmark(b, ns, e.lnum - 1, 0, { right_gravity = false }) }
      end
    end
  end
  local ok, err = true, nil
  local started = {}
  for _, m in ipairs(marks) do
    local pos = vim.api.nvim_buf_get_extmark_by_id(m.buf, ns, m.id, {})
    if pos and pos[1] then
      local row = pos[1] + 1
      ok, err = pcall(vim.api.nvim_buf_call, m.buf, function()
        local view = vim.fn.winsaveview()
        if not started[m.buf] then
          vim.cmd("let &l:undolevels = &l:undolevels")
          started[m.buf] = true
        else
          vim.cmd("silent! undojoin")
        end
        local okc, errc = pcall(vim.api.nvim_exec2, "silent keepjumps keeppatterns " .. row .. body, { output = true })
        vim.fn.winrestview(view)
        if not okc then error(errc, 0) end
      end)
      if not ok then break end
    end
  end
  for _, m in ipairs(marks) do
    local tracked, pos = pcall(vim.api.nvim_buf_get_extmark_by_id, m.buf, ns, m.id, {})
    if tracked and pos[1] then m.item.lnum = pos[1] + 1 end
    pcall(vim.api.nvim_buf_del_extmark, m.buf, ns, m.id)
  end
  if is_session(bufnr) and store[bufnr] then
    store[bufnr].items = items
    mirror(bufnr, M.session_win(bufnr))
  elseif kind == "loclist" then
    vim.fn.setloclist(win, {}, "r", { items = items })
  else
    vim.fn.setqflist({}, "r", { items = items })
  end
  return ok, err, kind
end

return M
