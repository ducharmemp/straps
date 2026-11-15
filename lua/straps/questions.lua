local M = {}
local prepare, answer

function M.install_contextual(adapter)
  assert(answer == nil and require("straps.registry").trusted_setup_allowed(), "questions setup sealed")
  assert(type(adapter) == "table" and type(adapter.prepare) == "function" and type(adapter.answer) == "function", "missing question callbacks")
  prepare, answer = adapter.prepare, adapter.answer
end

function M.ask(input, ctx)
  input = vim.deepcopy(input)
  local proposal = vim.deepcopy(input)
  if proposal.options == nil then proposal.options = {} end
  if input.options ~= nil and type(input.options) ~= "table" then error("ask_user: options must be a table", 0) end
  local question = input.question
  if type(question) ~= "string" or question == "" then error("ask_user: question is required", 0) end
  local bufnr = ctx.bufnr
  if bufnr == 0 or bufnr == nil then bufnr = vim.api.nvim_get_current_buf() end
  local ticket = prepare and prepare(bufnr, vim.deepcopy(proposal), ctx)
  local function cancelled()
    return type(ctx.cancelled) == "function" and ctx.cancelled()
  end
  local function complete(text, resolve, selection)
    if answer and not cancelled() and vim.api.nvim_buf_is_valid(bufnr) and vim.b[bufnr].straps_session then
      answer(ticket, text, resolve, ctx, selection)
    else
      resolve()
    end
  end
  local options, previews, source_indices = {}, {}, {}
  local default_ft = (type(input.filetype) == "string" and input.filetype ~= "") and input.filetype or nil
  if type(input.options) == "table" then
    for index, o in ipairs(input.options) do
      if type(o) == "string" and o ~= "" then
        options[#options + 1] = o
        source_indices[#options] = index
      elseif type(o) == "table" and type(o.label) == "string" and o.label ~= "" then
        options[#options + 1] = o.label
        source_indices[#options] = index
        if type(o.preview) == "string" and o.preview ~= "" then
          local ft = (type(o.filetype) == "string" and o.filetype ~= "") and o.filetype or default_ft
          previews[#options] = { text = o.preview, ft = ft }
        end
      end
    end
  end
  local attention = require("straps.attention")
  local function free_text(prefix)
    local release = attention.wait(ctx, "question")
    local resolved = false
    local ok_wait, typed = pcall(ctx.await, function(resolve)
      local function finish(v)
        if resolved then return end
        resolved = true
        release()
        if type(v) == "string" and v ~= "" and not cancelled() then
          complete(v, function() resolve(v) end, { kind = "free_text" })
        else
          resolve(nil)
        end
      end
      if type(ctx.on_cancel) == "function" then ctx.on_cancel(function() finish(nil) end) end
      if not resolved then vim.ui.input({ prompt = question .. " " }, function(text) finish(text) end) end
    end)
    resolved = true
    release()
    if not ok_wait then error(typed, 0) end
    if typed == nil or typed == "" then
      return "user dismissed the input without answering — do not re-ask the identical question"
    end
    return "user answered" .. prefix .. ": " .. typed
  end
  if #options == 0 then
    local content_win, content_buf
    if (type(input.content) == "string" and input.content ~= "") or #vim.split(question, "\n", { plain = true }) > 200 then
      content_buf = vim.api.nvim_create_buf(false, true)
      local text = question .. (type(input.content) == "string" and ("\n\n" .. input.content) or "")
      vim.api.nvim_buf_set_lines(content_buf, 0, -1, false, vim.split(text, "\n", { plain = true }))
      vim.cmd("botright split")
      content_win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(content_win, content_buf)
      vim.wo[content_win].winbar = "ask_user question and content"
    end
    local ok, result = pcall(free_text, "")
    if content_win then pcall(vim.api.nvim_win_close, content_win, true) end
    if content_buf then pcall(vim.api.nvim_buf_delete, content_buf, { force = true }) end
    if not ok then error(result, 0) end
    return result
  end
  if not vim.api.nvim_buf_is_valid(bufnr) or not vim.b[bufnr].straps_session then
    error("ask_user: no session buffer", 0)
  end
  local user_win = vim.api.nvim_get_current_win()
  local wins, bufs = {}, {}
  local function capped_lines(text)
    local lines = vim.split(text, "\n", { plain = true })
    return lines
  end
  local function scratch_buf(lines, ft)
    local b = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
    vim.bo[b].bufhidden = "hide"
    if type(ft) == "string" and ft ~= "" then pcall(function() vim.bo[b].filetype = ft end) end
    bufs[#bufs + 1] = b
    return b
  end
  local win = vim.fn.bufwinid(bufnr)
  if win == -1 then
    vim.cmd("botright split")
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, bufnr)
    wins[#wins + 1] = win
  end
  local function session_win()
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == bufnr then return win end
    local w = vim.fn.bufwinid(bufnr)
    if w ~= -1 then win = w end
    return w ~= -1 and w or nil
  end
  local function anchor_row()
    local blocks = require("straps.state").list_blocks(bufnr)
    local last_assistant
    for _, b in ipairs(blocks) do if b.kind == "assistant" then last_assistant = b end end
    local n = vim.api.nvim_buf_line_count(bufnr)
    if not last_assistant then return n - 1 end
    local next_marker = n + 1
    for _, b in ipairs(blocks) do
      if b.marker_lnum > last_assistant.marker_lnum and b.marker_lnum < next_marker then next_marker = b.marker_lnum end
    end
    local lines = vim.api.nvim_buf_get_lines(bufnr, last_assistant.marker_lnum - 1, next_marker - 1, false)
    local i = #lines
    while i > 1 and lines[i]:match("^%s*$") do i = i - 1 end
    return last_assistant.marker_lnum - 1 + i - 1
  end
  if (type(input.content) == "string" and input.content ~= "") or #vim.split(question, "\n", { plain = true }) > 200 then
    pcall(function()
      local text = question .. (type(input.content) == "string" and ("\n\n" .. input.content) or "")
      local lines = vim.split(text, "\n", { plain = true })
      vim.api.nvim_set_current_win(win)
      vim.cmd("botright " .. math.min(#lines + 1, 15) .. "split")
      local cwin = vim.api.nvim_get_current_win()
      wins[#wins + 1] = cwin
      vim.api.nvim_win_set_buf(cwin, scratch_buf(lines, default_ft))
      vim.wo[cwin].winbar = "ask_user content"
    end)
  end
  local pwin, pbufs = nil, {}
  if next(previews) ~= nil then
    pcall(function()
      vim.api.nvim_set_current_win(win)
      vim.cmd("rightbelow vsplit")
      pwin = vim.api.nvim_get_current_win()
      wins[#wins + 1] = pwin
      for i = 1, #options do
        local p = previews[i]
        pbufs[i] = scratch_buf(p and vim.split(p.text, "\n", { plain = true }) or { "(no preview for this option)" }, p and p.ft or nil)
      end
    end)
  end
  local ns = vim.api.nvim_create_namespace("straps_ask_user")
  local selected = 1
  local HINT = "j/k move · <CR> choose · 1-9 pick · o other · <Esc> dismiss"
  local function build_lines()
    local w = session_win()
    local width = math.max(20, (w and vim.api.nvim_win_get_width(w) or vim.o.columns) - 6)
    local vl = { { { " ", "Normal" } } }
    vl[#vl + 1] = { { "┌ ? ", "DiagnosticInfo" }, { ("question · %d options"):format(#options), "Title" } }
    for _, l in ipairs(capped_lines(question)) do
      if l == "" then vl[#vl + 1] = { { "│", "DiagnosticInfo" } } end
      while #l > 0 do
        local piece = l:sub(1, width)
        if #l > width then
          local cut = piece:match("^.*()%s") or (width + 1)
          piece = l:sub(1, cut - 1)
        end
        vl[#vl + 1] = { { "│ ", "DiagnosticInfo" }, { piece, "Normal" } }
        l = l:sub(#piece + 1):gsub("^%s+", "")
      end
    end
    vl[#vl + 1] = { { "│", "DiagnosticInfo" } }
    for i, o in ipairs(options) do
      local sel = i == selected
      vl[#vl + 1] = {
        { "│ ", "DiagnosticInfo" }, { sel and "▸ " or "  ", "DiagnosticOk" },
        { ("%d. "):format(i), sel and "Number" or "Comment" }, { o, sel and "CursorLineNr" or "Normal" },
        { previews[i] and "  ◧ preview →" or "", "Comment" },
      }
    end
    vl[#vl + 1] = { { "│ ", "DiagnosticInfo" }, { "  o. ", "Comment" }, { "(other: type your own answer)", "Comment" } }
    vl[#vl + 1] = { { "└ ", "DiagnosticInfo" }, { HINT, "Comment" } }
    return vl
  end
  local function draw()
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    local w = session_win()
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    vim.api.nvim_buf_set_extmark(bufnr, ns, anchor_row(), 0, { virt_lines = build_lines(), virt_lines_above = false })
    if pwin and vim.api.nvim_win_is_valid(pwin) and pbufs[selected] and vim.api.nvim_buf_is_valid(pbufs[selected]) then
      vim.api.nvim_win_set_buf(pwin, pbufs[selected])
      pcall(function()
        vim.wo[pwin].winbar = ("preview of option %d: %s"):format(selected, (options[selected]:gsub("%%", "%%%%")))
      end)
    end
    if w then
      pcall(vim.api.nvim_win_call, w, function()
        vim.api.nvim_win_set_cursor(w, { vim.api.nvim_buf_line_count(bufnr), 0 })
        vim.cmd("normal! zb")
      end)
    end
    vim.cmd("redraw")
  end
  local keys = { "j", "k", "<CR>", "<Esc>", "o", "<Down>", "<Up>" }
  for i = 1, math.min(9, #options) do keys[#keys + 1] = tostring(i) end
  local saved = {}
  vim.api.nvim_buf_call(bufnr, function()
    for _, lhs in ipairs(keys) do
      local m = vim.fn.maparg(lhs, "n", false, true)
      if type(m) == "table" and next(m) and m.buffer == 1 then saved[lhs] = m end
    end
  end)
  local function restore()
    pcall(vim.api.nvim_buf_clear_namespace, bufnr, ns, 0, -1)
    for _, lhs in ipairs(keys) do pcall(vim.keymap.del, "n", lhs, { buffer = bufnr }) end
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_call(bufnr, function()
        for _, m in pairs(saved) do pcall(vim.fn.mapset, "n", false, m) end
      end)
    end
    for _, w in ipairs(wins) do pcall(vim.api.nvim_win_close, w, true) end
    for _, b in ipairs(bufs) do pcall(vim.api.nvim_buf_delete, b, { force = true }) end
    if vim.api.nvim_win_is_valid(user_win) then pcall(vim.api.nvim_set_current_win, user_win) end
  end
  local release = function() end
  local resolved = false
  local ok_wait, res = pcall(ctx.await, function(resolve)
    local function finish(v)
      if resolved then return end
      resolved = true
      release()
      if v.idx and not cancelled() then
        local index = source_indices[v.idx]
        complete(options[v.idx], function() resolve(v) end, { kind = "option", index = index, option = vim.deepcopy(proposal.options[index]) })
      else
        resolve(v)
      end
    end
    local function map(lhs, fn)
      vim.keymap.set("n", lhs, function()
        local ok, err = pcall(fn)
        if not ok then vim.notify("ask_user: " .. tostring(err), vim.log.levels.ERROR) end
      end, { buffer = bufnr, nowait = true, desc = "straps: ask_user" })
    end
    local function move(d)
      selected = ((selected - 1 + d) % #options) + 1
      draw()
    end
    map("j", function() move(1) end)
    map("<Down>", function() move(1) end)
    map("k", function() move(-1) end)
    map("<Up>", function() move(-1) end)
    map("<CR>", function() finish({ idx = selected }) end)
    map("<Esc>", function() finish({ dismissed = true }) end)
    map("o", function() finish({ other = true }) end)
    for i = 1, math.min(9, #options) do map(tostring(i), function() finish({ idx = i }) end) end
    if type(ctx.on_cancel) == "function" then ctx.on_cancel(function() finish({ dismissed = true }) end) end
    pcall(vim.api.nvim_set_current_win, win)
    local ok_draw, err = pcall(draw)
    if not ok_draw then
      vim.notify("ask_user: " .. tostring(err), vim.log.levels.ERROR)
      finish({ dismissed = true })
    elseif not resolved then
      release = attention.wait(ctx, "question")
    end
  end)
  resolved = true
  release()
  restore()
  if not ok_wait then error(res, 0) end
  if type(res) ~= "table" or res.dismissed then
    return "user dismissed the question without choosing — proceed on your best judgment or ask differently"
  end
  if res.other then return free_text(" (free text)") end
  return string.format("user chose option %d: %s", res.idx, options[res.idx])
end

return M
