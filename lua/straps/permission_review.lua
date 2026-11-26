local M = {}
local api = vim.api

local entries = {}
local seq = 0
local list = {}
local review = {}
local ns = api.nvim_create_namespace("straps_permission_review")
local marked = {}
local timer
local scheduled = false
local lifecycle = false

function M.mode()
  local straps = package.loaded["straps"]
  local config = type(straps) == "table" and rawget(straps, "config") or nil
  return type(config) == "table" and config.permission_review == "modal" and "modal" or "deferred"
end

local function single_line(value)
  if value == nil then return "" end
  local text = type(value) == "string" and value or tostring(value)
  local line = vim.fn.strtrans(((text:match("^[^\r\n]*") or ""):gsub("%z", "^@")))
  return type(line) == "string" and line or ""
end

local function session_label(bufnr)
  if not api.nvim_buf_is_valid(bufnr) then return "buffer " .. bufnr end
  return single_line(require("straps.ui").session_label(bufnr))
end

local function minutes_left(entry)
  if type(entry.expires) ~= "number" or type(entry.clock) ~= "function" then return nil end
  local ok, now = pcall(entry.clock)
  if not ok or type(now) ~= "number" then return nil end
  return math.max(0, math.ceil((entry.expires - now) / 60000))
end

local function request_text(entry)
  if entry.kind == "presenter" then
    local parts = { "consent " .. single_line(entry.label or "call") }
    if entry.status == "queued" then parts[#parts + 1] = "queued" end
    local minutes = minutes_left(entry)
    if minutes then parts[#parts + 1] = ("expires in %dm"):format(minutes) end
    return table.concat(parts, " · ")
  end
  local spec = entry.spec
  if type(spec) == "table" and spec.name ~= nil then
    local text = "allow " .. single_line(spec.name)
    if spec.target then text = text .. " " .. single_line(spec.target) end
    return text
  end
  return "allow (custom hook.confirm)"
end

local function truncate(text, width)
  if vim.fn.strdisplaywidth(text) <= width then return text end
  local out, used, room = {}, 0, width - vim.fn.strdisplaywidth("…")
  for _, char in ipairs(vim.fn.split(text, "\\zs")) do
    local cells = vim.fn.strdisplaywidth(char)
    if used + cells > room then break end
    out[#out + 1], used = char, used + cells
  end
  return table.concat(out) .. "…"
end

local function is_descendant(bufnr, ancestor)
  local current, hops = bufnr, 0
  while type(current) == "number" and api.nvim_buf_is_valid(current) and hops < 64 do
    local ok, parent = pcall(function() return vim.b[current].straps_parent end)
    if not ok or type(parent) ~= "number" then return false end
    if parent == ancestor then return true end
    current, hops = parent, hops + 1
  end
  return false
end

local FOOTER = " :StrapsPermission / gy review "

local function close_window(handle)
  if handle and api.nvim_win_is_valid(handle) then pcall(api.nvim_win_close, handle, true) end
end

local function scratch(buf)
  if buf and api.nvim_buf_is_valid(buf) then return buf end
  buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].modifiable = false
  return buf
end

local function set_lines(buf, lines)
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

local function tabline_rows()
  local stal = vim.o.showtabline
  if stal == 2 or (stal == 1 and #api.nvim_list_tabpages() > 1) then return 1 end
  return 0
end

local function render_list()
  local rows = {}
  for _, entry in ipairs(entries) do
    if api.nvim_buf_is_valid(entry.bufnr) then
      rows[#rows + 1] = "◆ " .. session_label(entry.bufnr) .. " · " .. request_text(entry)
    end
  end
  if #rows == 0 then
    close_window(list.win)
    list.win = nil
    return
  end
  local cap = math.max(20, vim.o.columns - 4)
  local width = vim.fn.strdisplaywidth(FOOTER)
  for _, row in ipairs(rows) do width = math.max(width, vim.fn.strdisplaywidth(row)) end
  width = math.min(width, cap, math.max(1, vim.o.columns - 2))
  local shown = {}
  local max_rows = math.max(1, math.min(8, vim.o.lines - 6))
  for i, row in ipairs(rows) do
    if i > max_rows then
      shown[#shown] = truncate(("… %d more"):format(#rows - max_rows + 1), width)
      break
    end
    shown[#shown + 1] = truncate(row, width)
  end
  list.buf = scratch(list.buf)
  set_lines(list.buf, shown)
  local cfg = {
    relative = "editor",
    anchor = "NE",
    row = tabline_rows(),
    col = vim.o.columns,
    width = width,
    height = #shown,
    style = "minimal",
    border = "single",
    focusable = false,
    zindex = 200,
    footer = truncate(FOOTER, width),
    footer_pos = "right",
  }
  local tab = api.nvim_get_current_tabpage()
  if list.win and api.nvim_win_is_valid(list.win) and api.nvim_win_get_tabpage(list.win) == tab then
    api.nvim_win_set_config(list.win, cfg)
    return
  end
  close_window(list.win)
  cfg.noautocmd = true
  list.win = api.nvim_open_win(list.buf, false, cfg)
end

local function waiting_line(entry)
  return { { "◆ waiting: " .. request_text(entry) .. " · gy review", "StrapsPermit" } }
end

local function anchor(bufnr)
  local state = require("straps.state")
  local draft = state.draft_row(bufnr)
  if draft then return draft, true end
  local blocks = state.list_blocks(bufnr)
  local first
  for i = #blocks, 1, -1 do
    local b = blocks[i]
    if b.kind == "tool_use" then
      first = b
    elseif first and b.kind ~= "tool_result" then
      break
    end
  end
  if first then return math.max(0, first.marker_lnum - 2), false end
  return math.max(0, api.nvim_buf_line_count(bufnr) - 1), false
end

local function render_lines()
  for bufnr in pairs(marked) do
    if api.nvim_buf_is_valid(bufnr) then api.nvim_buf_clear_namespace(bufnr, ns, 0, -1) end
    marked[bufnr] = nil
  end
  local done = {}
  for _, entry in ipairs(entries) do
    local bufnr = entry.bufnr
    if not done[bufnr] and api.nvim_buf_is_valid(bufnr) and vim.b[bufnr].straps_session == true then
      done[bufnr] = true
      local row, above = anchor(bufnr)
      api.nvim_buf_set_extmark(bufnr, ns, row, 0, { virt_lines = { waiting_line(entry) }, virt_lines_above = above })
      marked[bufnr] = true
    end
  end
end

local function consent_timer()
  local needed = false
  for _, entry in ipairs(entries) do
    if entry.kind == "presenter" and entry.expires then needed = true end
  end
  if needed and not timer then
    timer = vim.uv.new_timer()
    timer:start(30000, 30000, function() M.changed() end)
  elseif not needed and timer then
    timer:stop()
    timer:close()
    timer = nil
  end
end

local function render()
  render_list()
  render_lines()
  consent_timer()
end

local function notify_failure(err)
  local entry = entries[1]
  local who = entry and session_label(entry.bufnr) or "a session"
  pcall(vim.notify, ("straps: permission request pending in %s; run :StrapsPermission (display failed: %s)")
    :format(who, tostring(err)), vim.log.levels.WARN)
end

M._render = render

local function register_lifecycle()
  if lifecycle then return end
  lifecycle = true
  api.nvim_create_autocmd({ "TabEnter", "TabClosed", "VimResized" }, {
    group = api.nvim_create_augroup("StrapsPermissionReview", { clear = true }),
    callback = function(ev)
      if ev.event == "VimResized" and review.layout and review.win and api.nvim_win_is_valid(review.win) then
        pcall(api.nvim_win_set_config, review.win, review.layout())
      end
      if #entries > 0 then M.changed() end
    end,
  })
end

function M.changed()
  if scheduled then return end
  scheduled = true
  vim.schedule(function()
    scheduled = false
    local ok, err = pcall(M._render)
    if not ok then notify_failure(err) end
  end)
end

function M.add(entry)
  seq = seq + 1
  entry.seq = seq
  entries[#entries + 1] = entry
  register_lifecycle()
  M.changed()
end

local function close_review()
  local win = review.win
  review.win, review.entry, review.prev, review.layout = nil, nil, nil, nil
  close_window(win)
end

function M.remove(entry)
  for i, active in ipairs(entries) do
    if active == entry then
      table.remove(entries, i)
      break
    end
  end
  if review.entry == entry then close_review() end
  M.changed()
end

function M.entries()
  return vim.list_slice(entries, 1, #entries)
end

function M.list_window()
  return list.win and api.nvim_win_is_valid(list.win) and list.win or nil
end

function M.review_window()
  return review.win and api.nvim_win_is_valid(review.win) and review.win or nil
end

local function resolve(target)
  if target then
    for _, entry in ipairs(entries) do
      if entry.bufnr == target then return entry end
    end
    for _, entry in ipairs(entries) do
      if is_descendant(entry.bufnr, target) then return entry end
    end
  end
  return entries[1]
end

local function blocked()
  return require("straps.registry").tool_body_running_here()
end

local function in_cmdwin()
  if vim.fn.getcmdwintype() == "" then return false end
  pcall(vim.notify, "straps: leave the command-line window to review the permission request", vim.log.levels.WARN)
  return true
end

local open_entry

local function open_or_notify(entry)
  local ok, reason = open_entry(entry)
  if not ok and reason then pcall(vim.notify, "straps: " .. reason, vim.log.levels.WARN) end
  return ok
end

local function inspect_window(entry)
  local prev = review.prev
  if prev and api.nvim_win_is_valid(prev) and api.nvim_win_get_config(prev).relative == "" then return prev end
  local fallback
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    if api.nvim_win_get_config(win).relative == "" then
      if api.nvim_win_get_buf(win) == entry.bufnr then return win end
      fallback = fallback or win
    end
  end
  return fallback
end

local function decide(entry, index)
  if blocked() or entry.decided then return end
  entry.decided = true
  close_review()
  M.remove(entry)
  entry.done(index)
end

local function step(entry, delta)
  local index
  for i, active in ipairs(entries) do
    if active == entry then index = i end
  end
  if not index or #entries < 2 or in_cmdwin() then return end
  local target = entries[(index - 1 + delta) % #entries + 1]
  close_review()
  open_or_notify(target)
end

local function footer_for(spec, cap)
  local full, keys = {}, {}
  for _, choice in ipairs(spec.choices or {}) do
    full[#full + 1] = single_line(choice.key) .. " " .. single_line(choice.label)
    keys[#keys + 1] = single_line(choice.key)
  end
  local text = " " .. table.concat(full, " · ") .. " "
  if vim.fn.strdisplaywidth(text) > cap then text = " " .. table.concat(keys, " · ") .. " " end
  return text
end

local function guarded(fn)
  return function()
    if blocked() then return end
    local ok, err = pcall(fn)
    if not ok then pcall(vim.notify, "straps: permission review failed: " .. tostring(err), vim.log.levels.ERROR) end
  end
end

local FIXED_KEYS = { "i", "<Tab>", "<S-Tab>", "<CR>", "q", "<Esc>", "gy" }
local reserved_keys = {}
for _, lhs in ipairs(FIXED_KEYS) do
  if lhs:sub(1, 1) ~= "<" then reserved_keys[lhs:sub(1, 1)] = true end
end

local function open_review(entry)
  local spec = entry.spec
  local lines = {}
  for _, line in ipairs(vim.split(type(spec.preview) == "string" and spec.preview or "", "\n", { plain = true })) do
    lines[#lines + 1] = vim.fn.strtrans((line:gsub("%z", "^@")))
  end
  if #lines == 0 then lines = { "" } end
  local title = " " .. single_line(spec.title or ("allow " .. tostring(spec.name))) .. " · " .. session_label(entry.bufnr) .. " "
  local content = vim.fn.strdisplaywidth(title)
  for _, line in ipairs(lines) do content = math.max(content, vim.fn.strdisplaywidth(line)) end
  local function layout()
    local cap = math.max(1, vim.o.columns - 2)
    local width = math.min(math.max(content, vim.fn.strdisplaywidth(footer_for(spec, cap)), 20), cap)
    local function measure()
      local rows = 0
      for _, line in ipairs(lines) do rows = rows + math.max(1, math.ceil(vim.fn.strdisplaywidth(line) / width)) end
      return rows, math.max(1, math.min(rows, vim.o.lines - 6))
    end
    local rows, height = measure()
    local footer = footer_for(spec, width)
    if rows > height then
      local shown = (" %d of %d rows shown, scroll ·"):format(height, rows)
      width = math.min(cap, math.max(width, vim.fn.strdisplaywidth(shown .. footer_for(spec, cap - vim.fn.strdisplaywidth(shown)))))
      rows, height = measure()
      shown = (" %d of %d rows shown, scroll ·"):format(height, rows)
      footer = rows > height and truncate(shown .. footer_for(spec, width - vim.fn.strdisplaywidth(shown)), width)
        or footer_for(spec, width)
    end
    return {
      relative = "editor",
      row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
      col = math.max(0, math.floor((vim.o.columns - width) / 2) - 1),
      width = width,
      height = height,
      border = "single",
      title = truncate(title, width),
      footer = footer,
      zindex = 250,
    }
  end
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  local prev = api.nvim_get_current_win()
  local ok, win = pcall(function()
    return api.nvim_open_win(buf, false, vim.tbl_extend("force", layout(), { style = "minimal" }))
  end)
  if not ok then
    pcall(api.nvim_buf_delete, buf, { force = true })
    return false, "cannot open the permission review: " .. tostring(win)
  end
  vim.wo[win][0].wrap = true
  vim.wo[win].winfixbuf = true
  review.win, review.entry, review.prev, review.layout = win, entry, prev, layout
  local function map(lhs, fn)
    vim.keymap.set("n", lhs, guarded(fn), { buffer = buf, nowait = true, desc = "straps: permission review" })
  end
  for _, choice in ipairs(spec.choices or {}) do
    if type(choice.key) == "string" and choice.key:match("^[%w%p]$") then
      map(choice.key, function() decide(entry, choice.index) end)
    end
  end
  local handlers = {
    ["<Tab>"] = function() step(entry, 1) end,
    ["<S-Tab>"] = function() step(entry, -1) end,
    ["<CR>"] = function() end,
    q = function() close_review() end,
    ["<Esc>"] = function() close_review() end,
    gy = function()
      local prev_buf = review.prev and api.nvim_win_is_valid(review.prev) and api.nvim_win_get_buf(review.prev)
      local target = resolve(prev_buf and require("straps.ui").resolve_session(prev_buf))
      if target ~= entry then
        close_review()
        open_or_notify(target)
      end
    end,
  }
  if spec.inspect then
    handlers.i = function()
      local ok_inspect, reason = require("straps.workbench").inspect(entry.bufnr, inspect_window(entry))
      if not ok_inspect then
        vim.notify("straps: " .. tostring(reason), vim.log.levels.INFO)
        return
      end
      close_review()
    end
  end
  for _, lhs in ipairs(FIXED_KEYS) do
    if handlers[lhs] then map(lhs, handlers[lhs]) end
  end
  api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      if review.win == win then review.win, review.entry, review.prev, review.layout = nil, nil, nil, nil end
    end,
  })
  local entered, err = pcall(api.nvim_set_current_win, win)
  if not entered and api.nvim_get_current_win() ~= win then
    close_review()
    return false, "cannot open the permission review: " .. tostring(err)
  end
  return true
end


local function reviewable_spec(spec)
  if type(spec) ~= "table" or type(spec.choices) ~= "table" or #spec.choices == 0 then return false end
  local seen = {}
  for _, choice in ipairs(spec.choices) do
    if type(choice) ~= "table" or type(choice.key) ~= "string" or not choice.key:match("^[%w%p]$") then return false end
    if reserved_keys[choice.key] or seen[choice.key] then return false end
    seen[choice.key] = true
  end
  return true
end

local function run_present(entry)
  local ok, err = pcall(entry.present)
  if not ok then return false, "the permission request's presenter failed: " .. tostring(err) end
  return true
end

open_entry = function(entry)
  if not entry then return false end
  if in_cmdwin() then return true end
  if entry.kind == "presenter" then
    if entry.status == "queued" then
      for _, other in ipairs(entries) do
        if other.kind == "presenter" and other.present and other ~= entry then
          pcall(vim.notify, "straps: this consent is queued behind the active consent; opening that one",
            vim.log.levels.INFO)
          return run_present(other)
        end
      end
      pcall(vim.notify, "straps: this consent is queued behind a consent already displayed", vim.log.levels.INFO)
      return true
    end
    if entry.present then return run_present(entry) end
    return false
  end
  if entry.mode == "deferred" and reviewable_spec(entry.spec) and entry.done then
    close_review()
    return open_review(entry)
  end
  if entry.present then return run_present(entry) end
  return false
end

function M.review(target)
  if blocked() then return false, "review is refused while a tool body runs" end
  if review.win and api.nvim_win_is_valid(review.win) then
    if in_cmdwin() then return true end
    if api.nvim_win_get_tabpage(review.win) == api.nvim_get_current_tabpage() then
      local ok, err = pcall(api.nvim_set_current_win, review.win)
      if not ok and api.nvim_get_current_win() ~= review.win then
        return false, "cannot focus the permission review: " .. tostring(err)
      end
      return true
    end
    close_review()
  end
  return open_entry(resolve(target))
end

function M.review_or_notify(target)
  local ok, reason = M.review(target)
  if not ok then
    vim.notify("straps: " .. (reason or "no permission request to review"), reason and vim.log.levels.WARN or vim.log.levels.INFO)
  end
end

return M
