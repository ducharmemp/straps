local M = {}
local api = vim.api
local frames = {}
local expression = "%{v:lua.require'straps.ui'.ratchet_status()}"
local stock = api.nvim_get_option_info2("statusline", {}).default
local template = stock ~= "" and stock
  or "%<%f %h%w%m%r%=%{% &showcmdloc == 'statusline' ? '%-10.S ' : '' %}%{% &ruler ? '%-14.(%l,%c%V%) %P' : '' %}"
local format = (template:gsub("%%=", function() return "%=" .. expression .. " " end, 1))
local ready, updating

local function drawing(handle, tail, label)
  return " ◀━━━━━━━━━━⟦" .. handle .. "⟧" .. string.rep("═", tail) .. "╸" .. string.rep(" ", 16 - tail) .. " " .. label
end

function M.status(buf)
  if vim.b[buf].straps_session ~= true then return "" end
  local loop = package.loaded["straps.loop"]
  if loop and loop.running(buf) then return drawing("╱", 16, "running") end
  local frame = frames[buf]
  if not frame then return drawing("╱", 16, "idle   ") end
  if frame.index == 17 then return drawing("━", 0, "done   ") end
  return drawing(({ "╱", "│", "╲", "━" })[(frame.index - 1) % 4 + 1], 16 - 4 * math.floor((frame.index - 1) / 4), "done   ")
end

function M.start(buf)
  frames[buf] = nil
end

function M.finish(buf, success)
  frames[buf] = nil
  if not ready or not success or not api.nvim_buf_is_valid(buf) or vim.b[buf].straps_session ~= true then return end
  local frame = { index = 1 }
  frames[buf] = frame
  local function step()
    if frames[buf] ~= frame then return end
    frame.index = frame.index + 1
    if frame.index > 17 then frames[buf] = nil end
    vim.cmd.redrawstatus({ bang = true })
    if frames[buf] == frame then vim.defer_fn(step, frame.index == 17 and 650 or 75) end
  end
  vim.defer_fn(step, 75)
end

local function reconcile()
  if updating then return end
  updating = true
  local global = api.nvim_get_option_value("statusline", { scope = "global" })
  for _, win in ipairs(api.nvim_list_wins()) do
    local opts = { win = win, scope = "local" }
    local value = api.nvim_get_option_value("statusline", opts)
    local owned = value == format
    local want = global == stock and (stock ~= "" or vim.o.rulerformat == "")
      and vim.b[api.nvim_win_get_buf(win)].straps_session == true and api.nvim_win_get_config(win).relative == ""
    if want and (owned or value == "" or value == stock) and value ~= format then
      api.nvim_set_option_value("statusline", format, opts)
    elseif not want and owned then
      api.nvim_set_option_value("statusline", "", opts)
    end
  end
  updating = false
end

function M.setup()
  if ready then return end
  ready = true
  local group = api.nvim_create_augroup("StrapsRatchet", { clear = true })
  api.nvim_create_autocmd({ "BufWinEnter", "BufEnter", "WinEnter" }, { group = group, callback = reconcile })
  api.nvim_create_autocmd("WinNew", { group = group, callback = function() vim.schedule(reconcile) end })
  api.nvim_create_autocmd("OptionSet", { group = group, pattern = { "statusline", "rulerformat" }, callback = reconcile })
  api.nvim_create_autocmd("BufWipeout", { group = group, callback = function(ev) M.start(ev.buf) end })
  reconcile()
end

return M
