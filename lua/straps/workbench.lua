local M = {}
local api = vim.api
local pending = {}

local function redraw(bufnr)
  pcall(vim.cmd, "redrawstatus!")
end

function M.pending(bufnr)
  local record = pending[bufnr]
  return record and vim.deepcopy(record.metadata) or nil
end

local function close_preview(record)
  local win, buf = record.win, record.buf
  record.win, record.buf, record.transcript = nil, nil, nil
  if win and api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == buf then
    pcall(api.nvim_win_close, win, true)
  end
  if buf and api.nvim_buf_is_valid(buf) then pcall(api.nvim_buf_delete, buf, { force = true }) end
end

local function diff_lines(record)
  local state = require("straps.state")
  local name, path = record.metadata.name, record.metadata.path
  local old = record.base and record.base(path)
  if type(old) ~= "string" then old = state.file_text(path) end
  local new = state.simulate_edit(name, record.input, old)
  if new == nil or new == old then return nil end
  local differ = (vim.text and vim.text.diff) or vim.diff
  local diff = differ(old .. "\n", new .. "\n", { ctxlen = 3 })
  if diff == "" then return nil end
  local lines = vim.split(diff, "\n", { plain = true, trimempty = true })
  if #lines > 200 then
    local more = #lines - 200
    lines = vim.list_slice(lines, 1, 200)
    lines[#lines + 1] = ("... (%d more diff lines)"):format(more)
  end
  return lines
end

function M.inspect()
  local transcript = api.nvim_get_current_win()
  local bufnr = api.nvim_win_get_buf(transcript)
  local record = pending[bufnr]
  if not record or record.deciding or require("straps.registry").any_tool_executing() then
    return false, "no pending edit to inspect in the current transcript"
  end
  if vim.fn.getcwd() ~= record.cwd then return false, "pending edit's execution directory changed" end
  if record.transcript == transcript and record.win and api.nvim_win_is_valid(record.win)
      and api.nvim_win_get_buf(record.win) == record.buf then
    return true
  end
  close_preview(record)
  local ok, lines = pcall(diff_lines, record)
  if not ok or not lines then return false, "no diff available for the pending edit" end
  local success = pcall(function()
    local buf = api.nvim_create_buf(false, true)
    record.buf = buf
    api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].modifiable = false
    vim.bo[buf].filetype = "diff"
    local cfg = { win = transcript, split = "below", height = math.min(#lines, 15) }
    local width = api.nvim_win_get_width(transcript)
    if width >= 100 then cfg = { win = transcript, split = "right", width = math.floor(width / 2) } end
    record.win = api.nvim_open_win(buf, false, cfg)
    record.transcript = transcript
  end)
  if not success then
    close_preview(record)
    return false, "could not open the pending edit diff"
  end
  return true
end

function M.confirm(name, input, ctx, call_id, present)
  local dock = require("straps.dock")
  local bufnr = ctx and ctx.bufnr
  if not (bufnr and bufnr > 0 and api.nvim_buf_is_valid(bufnr) and vim.b[bufnr].straps_session == true
      and ctx.await and ctx.on_cancel and coroutine.running()) then
    return dock.confirm(ctx, present)
  end
  if pending[bufnr] then return nil end
  local record = {
    metadata = { call_id = call_id, name = name, path = input.path },
    input = input,
    base = ctx.batch_preview,
    cwd = vim.fn.getcwd(),
  }
  local release_attention = require("straps.attention").wait(ctx, "permission")
  local ok, choice = ctx.await(function(done)
    pending[bufnr] = record
    local function finish(success, result)
      if pending[bufnr] ~= record then return end
      pending[bufnr] = nil
      record.release()
      release_attention()
      close_preview(record)
      redraw(bufnr)
      done(success, result)
    end
    record.release = dock.defer(bufnr, function()
      record.deciding = true
      local success, result = pcall(present)
      finish(success, result)
    end)
    ctx.on_cancel(function() finish(true, nil) end)
    redraw(bufnr)
  end)
  if not ok then error(choice, 0) end
  return choice
end

return M
