local M = {}
local api = vim.api
local ns = api.nvim_create_namespace("straps_turn_decoration")
local anchors = api.nvim_create_namespace("straps_turn_start")
local attached = {}

local function enabled()
  local cfg = require("straps").config
  return cfg.render ~= false and cfg.turn_decoration ~= false
end

local function pending(bufnr)
  local workbench = package.loaded["straps.workbench"]
  local edit = workbench and workbench.pending(bufnr)
  return edit or (require("straps.attention").permission_wait(bufnr) and {}), edit ~= nil
end

function M.wait_label(bufnr, dock)
  local active, edit = pending(bufnr)
  if enabled() then
    if edit then return "%#StrapsPermit#◆ waiting%* — Permission pending (:StrapsInspect / :StrapsPermission)  " end
    if active or dock then
      return "%#StrapsPermit#◆ waiting%*" .. (dock and " — Permission pending (:StrapsPermission)  " or "  ")
    end
  end
  if edit then return "Permission pending (:StrapsInspect / :StrapsPermission)  " end
  return dock and "Permission pending (:StrapsPermission)  " or ""
end

local function pending_row(bufnr, first, action)
  local completed, row = {}, nil
  local blocks = require("straps.state").list_blocks(bufnr)
  for i = #blocks, 1, -1 do
    local block = blocks[i]
    local r = block.marker_lnum - 1
    if r < first then break end
    local attrs = block.attrs or {}
    if attrs.id then
      if block.kind == "tool_result" then completed[attrs.id] = true end
      if block.kind == "tool_use" and not completed[attrs.id] and
          (action.call_id and attrs.id == action.call_id or not action.call_id and (not action.name or attrs.name == action.name)) then
        if row then return nil end
        row = r
      end
    end
  end
  return row
end

function M.rows(bufnr)
  local turn = attached[bufnr]
  if not turn or not enabled() then return end
  return turn.first, turn.last, turn.permit
end

function M.chunks(permit)
  if permit then return { { "◆ permit ", "StrapsPermit" } } end
  return { { "│", "StrapsTurnAccent" } }
end

local function refresh(bufnr)
  local turn = attached[bufnr]
  if not turn or not api.nvim_buf_is_loaded(bufnr) then return end
  local mark = api.nvim_buf_get_extmark_by_id(bufnr, anchors, 1, { details = true })
  local first = enabled() and mark[1] and not mark[3].invalid and mark[1] or nil
  local last = first and ((require("straps.state").draft_row(bufnr) or api.nvim_buf_line_count(bufnr)) - 1)
  local action = first and pending(bufnr)
  local permit = action and pending_row(bufnr, first, action) or nil
  local tick = api.nvim_buf_get_changedtick(bufnr)
  if first == turn.first and last == turn.last and permit == turn.permit and tick == turn.tick then return end
  local start = first
  if turn.tail_only and first == turn.first and permit == turn.permit and first then
    start = math.min(last, turn.last)
    api.nvim_buf_clear_namespace(bufnr, ns, start, -1)
  else
    api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  end
  turn.first, turn.last, turn.permit, turn.tick = first, last, permit, tick
  turn.tail_only = true
  if not start then return end
  for row = start, last do
    api.nvim_buf_set_extmark(bufnr, ns, row, 0, {
      virt_text = M.chunks(row == permit), virt_text_pos = "inline", right_gravity = false, undo_restore = false,
    })
  end
end

function M.redraw(bufnr)
  refresh(bufnr)
  local ok = api.nvim__redraw and pcall(api.nvim__redraw, { buf = bufnr, valid = false, winbar = true })
  if not ok then vim.cmd("redraw!") end
end

function M.begin(bufnr, row)
  if not enabled() then return end
  if vim.b[bufnr].straps_session ~= true then return end
  if not attached[bufnr] then
    local turn = {}
    attached[bufnr] = turn
    api.nvim_buf_attach(bufnr, false, {
      on_lines = function(_, buf, _, first)
        if attached[buf] ~= turn then return true end
        if not turn.last or first < turn.last then turn.tail_only = false end
        if turn.scheduled then return end
        turn.scheduled = true
        vim.schedule(function()
          turn.scheduled = false
          if attached[buf] == turn then refresh(buf) end
        end)
      end,
      on_detach = function(_, buf)
        if attached[buf] == turn then attached[buf] = nil end
      end,
    })
  end
  api.nvim_buf_set_extmark(bufnr, anchors, row, 0, {
    id = 1, end_row = row + 1, end_col = 0, invalidate = true, undo_restore = false,
  })
  refresh(bufnr)
end

function M.finish(bufnr)
  if not attached[bufnr] or not api.nvim_buf_is_loaded(bufnr) then return end
  api.nvim_buf_clear_namespace(bufnr, anchors, 0, -1)
  refresh(bufnr)
end

function M.setup()
  for buf in pairs(attached) do M.redraw(buf) end
end

return M
