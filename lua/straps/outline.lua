local state = require("straps.state")
local api = vim.api
local M = {}

local function first_prompt_line(buf, block)
  local marker = api.nvim_buf_get_lines(buf, block.marker_lnum - 1, block.marker_lnum, false)[1]
  local inline = marker:sub(#"%%[straps:user]%%" + 1):gsub("^ ", "", 1)
  if inline:find("%S") then return inline end
  for _, line in ipairs(api.nvim_buf_get_lines(buf, block.first_lnum - 1, block.last_lnum, false)) do
    line = line:gsub("^%%%%%[%[esc%]%]", "", 1)
    if line:find("%S") then return line end
  end
end

local function prompts(buf)
  local result = {}
  local blocks = state.list_blocks(buf)
  for i, block in ipairs(blocks) do
    if block.kind == "user" and i < #blocks then
      local text = first_prompt_line(buf, block)
      if text and not state.notice_of(text) then
        result[#result + 1] = { line = block.marker_lnum, text = vim.trim(text) }
      end
    end
  end
  return result
end

local readers = {}
local foldtext = "v:lua.require'straps.outline'.foldtext()"

function M.owns_folds(win, buf)
  for reader_win, reader in pairs(readers) do
    if reader.buf == buf and (win == reader_win or win == reader.origin) then return true end
  end
  return false
end

function M.foldtext()
  local win, buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
  local reader = readers[win]
  if not reader or reader.buf ~= buf then return vim.fn.getline(vim.v.foldstart) end
  local tick = api.nvim_buf_get_changedtick(buf)
  if tick ~= reader.tick then
    reader.headings = {}
    for number, prompt in ipairs(prompts(buf)) do
      reader.headings[prompt.line] = ("%d. %s"):format(number, prompt.text)
    end
    reader.tick = tick
  end
  return reader.headings[vim.v.foldstart] or vim.fn.getline(vim.v.foldstart)
end

local function close(win, reader)
  if #api.nvim_list_wins() == 1 then
    readers[win] = nil
    vim.cmd.normal({ args = { "zE" }, bang = true })
    local options = vim.wo[win][0]
    for key, value in pairs(reader.options) do options[key] = value end
    require("straps.ui").apply_fold_opts(reader.buf)
    return
  end
  api.nvim_win_close(win, false)
  if api.nvim_win_is_valid(reader.origin) and api.nvim_win_get_buf(reader.origin) == reader.buf then
    api.nvim_set_current_win(reader.origin)
  end
end

function M.toggle()
  local origin, buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
  if readers[origin] and readers[origin].buf == buf then return close(origin, readers[origin]) end
  if vim.bo[buf].filetype ~= "straps" then
    vim.notify("straps: open the session transcript before entering outline mode", vim.log.levels.WARN)
    return
  end
  local history = prompts(buf)
  if #history < 2 then
    vim.notify("straps: no earlier prompts to fold", vim.log.levels.INFO)
    return
  end
  for win, reader in pairs(readers) do
    if reader.origin == origin and reader.buf == buf and api.nvim_win_get_buf(win) == buf then
      api.nvim_set_current_win(win)
      return
    end
  end

  local view = vim.fn.winsaveview()
  vim.cmd("tab split")
  local win = api.nvim_get_current_win()
  local options = vim.wo[win][0]
  readers[win] = { buf = buf, origin = origin, options = { foldenable = options.foldenable, foldminlines = options.foldminlines } }
  api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function()
      vim.schedule(function()
        if api.nvim_win_is_valid(origin) and api.nvim_win_get_buf(origin) == buf
          and api.nvim_get_current_tabpage() == api.nvim_win_get_tabpage(origin) then
          api.nvim_set_current_win(origin)
          local cursor = api.nvim_win_get_cursor(origin)
          if cursor[1] == view.lnum and cursor[2] == view.col then vim.fn.winrestview(view) end
        end
        readers[win] = nil
      end)
    end,
  })
  options.foldmethod = "manual"
  options.foldtext = foldtext
  options.foldenable = true
  options.foldminlines = 0
  vim.cmd.normal({ args = { "zE" }, bang = true })
  for i = 1, #history - 1 do
    vim.cmd.fold({ range = { history[i].line, history[i + 1].line - 1 }, mods = { keepjumps = true } })
  end
  api.nvim_win_set_cursor(win, { history[1].line, 0 })
  vim.cmd.normal({ args = { "zt" }, bang = true })
end

return M
