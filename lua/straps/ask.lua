local M = {}
local api = vim.api

local function header(src, first, last)
  local name = api.nvim_buf_get_name(src)
  local path = "[No Name]"
  if name ~= "" then
    path = vim.fn.getcwd() == vim.fn.getcwd(-1, -1) and vim.fn.fnamemodify(name, ":.") or vim.fn.fnamemodify(name, ":p")
  end
  return ("%s:%d-%d"):format(path, first, last)
end

function M.quote(src, first, last)
  local lines = api.nvim_buf_get_lines(src, first - 1, last, false)
  local longest = 0
  for _, line in ipairs(lines) do
    for run in line:gmatch("`+") do longest = math.max(longest, #run) end
  end
  local fence = ("`"):rep(math.max(3, longest + 1))
  local out = { header(src, first, last), fence .. vim.bo[src].filetype }
  vim.list_extend(out, lines)
  out[#out + 1] = fence
  return table.concat(out, "\n")
end

local focus_clock = 0
function M.focused(bufnr)
  focus_clock = focus_clock + 1
  vim.b[bufnr].straps_last_focus = focus_clock
end

function M.target(bufnr)
  local ui = require("straps.ui")
  local found = ui.resolve_session(bufnr)
  if found then return found end
  local best, at = nil, 0
  for _, b in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_loaded(b) and vim.b[b].straps_session then
      local focus = vim.b[b].straps_last_focus or 0
      if focus > at then best, at = b, focus end
    end
  end
  return best
end

local function show(bufnr, split)
  local win
  for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
    if api.nvim_win_get_buf(w) == bufnr then win = w end
  end
  if win then api.nvim_set_current_win(win) else require("straps.ui").show_session(bufnr, split) end
  api.nvim_win_set_cursor(0, { api.nvim_buf_line_count(bufnr), 0 })
end

local function fill_draft(bufnr, text)
  local state = require("straps.state")
  state.open_draft(bufnr)
  local row = state.draft_row(bufnr)
  local existing = api.nvim_buf_get_lines(bufnr, row + 1, -1, false)
  while #existing > 0 and not existing[#existing]:match("%S") do existing[#existing] = nil end
  if #existing > 0 then existing[#existing + 1] = "" end
  vim.list_extend(existing, vim.split(text, "\n", { plain = true }))
  api.nvim_buf_set_lines(bufnr, row + 1, -1, false, existing)
end

local function warn(msg)
  vim.notify("straps: " .. msg, vim.log.levels.WARN)
end

function M.run(opts, human, split, explicit_split)
  split = split or "split"
  local src = api.nvim_get_current_buf()
  local data = M.quote(src, opts.line1, opts.line2)
  local text = vim.trim(opts.args or "")
  local bufnr = M.target(src)
  local loop = require("straps.loop")
  if human then
    if not bufnr then
      return human.open(split, { instruction = text ~= "" and text or nil, data = data, send = opts.bang,
        explicit_split = explicit_split, data_buf = src })
    end
    if text == "" then return warn(":StrapsAsk needs an instruction in contextual mode (:StrapsAsk explain this)") end
    if loop.running(bufnr) then return warn(":StrapsAsk needs an idle session in contextual mode; wait for the run to end") end
    if (require("straps.state").last_user_text(bufnr) or ""):match("%S") then
      return warn(":StrapsAsk needs the session's unsent request sent or cleared first in contextual mode")
    end
    show(bufnr, split)
    return human.ask(bufnr, text, data, function(composition)
      require("straps.state").add_to_trailing_user(bufnr, composition)
    end)
  end
  local composed = text ~= "" and (data .. "\n" .. text) or data
  if not bufnr then
    return require("straps.ui").open_session(split, { instruction = composed, send = opts.bang,
      explicit_split = explicit_split, data_buf = src })
  end
  fill_draft(bufnr, composed)
  show(bufnr, split)
  if opts.bang then require("straps.steering").send(bufnr, nil) end
end

local ns = api.nvim_create_namespace("straps_ask_symbols")
local pending

local function symbol_items(results)
  local merged = {}
  for _, result in ipairs(results) do
    for _, symbol in ipairs(result.symbols) do
      if #merged >= 200 then break end
      merged[#merged + 1] = { symbol = symbol, encoding = result.encoding }
    end
  end
  local kinds = vim.lsp.protocol.SymbolKind or {}
  local editor = require("straps.editor")
  local items, seen = {}, {}
  for _, entry in ipairs(merged) do
    local where = editor.symbol_location(entry.symbol, entry.encoding, { load = false })
    if where and not seen[where] then
      seen[where] = true
      items[#items + 1] = { word = "@" .. where, abbr = tostring(entry.symbol.name or "?") .. "  " .. where,
        menu = kinds[entry.symbol.kind] or "", dup = 1 }
    end
  end
  return items
end

local function request_symbols(col0, partial)
  if pending then pending() end
  local buf = api.nvim_get_current_buf()
  local row = api.nvim_win_get_cursor(0)[1] - 1
  local mark = api.nvim_buf_set_extmark(buf, ns, row, col0, {})
  local results, finished, cancel = {}, false, nil
  local function finish(complete)
    if finished then return end
    finished = true
    if pending == cancel then pending = nil end
    if not api.nvim_buf_is_valid(buf) then return end
    local pos = api.nvim_buf_get_extmark_by_id(buf, ns, mark, {})
    api.nvim_buf_del_extmark(buf, ns, mark)
    if not complete or not pos[1] or api.nvim_get_current_buf() ~= buf then return end
    local token = "@#" .. partial
    local cursor = api.nvim_win_get_cursor(0)
    if api.nvim_get_mode().mode:sub(1, 1) ~= "i" or cursor[1] - 1 ~= pos[1] or cursor[2] < pos[2] + #token then return end
    if api.nvim_get_current_line():sub(pos[2] + 1, pos[2] + #token) ~= token then return end
    vim.fn.complete(pos[2] + 1, symbol_items(results))
  end
  cancel = function() finish(false) end
  pending = cancel
  local clients = vim.lsp.get_clients({ method = "workspace/symbol" })
  local waiting = #clients
  if waiting == 0 then return vim.schedule(function() finish(true) end) end
  for i, client in ipairs(clients) do
    results[i] = { symbols = {}, encoding = client.offset_encoding or "utf-16" }
    local attached = next(client.attached_buffers or {}) or buf
    local ok, sent = pcall(client.request, client, "workspace/symbol", { query = partial }, function(err, result)
      if not err and type(result) == "table" then results[i].symbols = result end
      waiting = waiting - 1
      if waiting == 0 then vim.schedule(function() finish(true) end) end
    end, attached)
    if not ok or not sent then
      waiting = waiting - 1
      if waiting == 0 then vim.schedule(function() finish(true) end) end
    end
  end
  vim.defer_fn(function() finish(true) end, 1000)
end

function M.omnifunc(findstart, base)
  if findstart ~= 1 then
    if type(base) ~= "string" or base:find("`", 1, true) then return {} end
    local ok, items = pcall(vim.fn.getcompletion, base, "file")
    return ok and items or {}
  end
  local before = api.nvim_get_current_line():sub(1, api.nvim_win_get_cursor(0)[2])
  local symbol = before:match(".*()@#%S*$")
  if symbol then
    request_symbols(symbol - 1, before:sub(symbol + 2))
    return -3
  end
  local file = before:match(".*()@%S*$")
  if file then return file end
  return -3
end

return M
