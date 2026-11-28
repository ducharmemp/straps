local M = {}
local api = vim.api
local active = {}
local ns = api.nvim_create_namespace("straps_eggs")
local poses = {
  { "▟██▙        ╭────╮        ▟██▙", "            │ ◌  │", "     ╶━━━━━━┥    ┝━━━━━━╴", "            ╰────╯" },
  { "    ▟██▙    ╭────╮    ▟██▙", "            │ ◌  │", "       ╶━━━━┥    ┝━━━━╴", "            ╰────╯" },
  { "        ▟██▙╭────╮▟██▙", "            │ ◌  │", "          ╶━┥    ┝━╴", "            ╰────╯" },
  { "        ▟██▙╭────╮▟██▙", "            │ ◌  │", "            ┣━[═]┫", "            ╰────╯" },
  { "        ▟██▙╭────╮▟██▙", "            │ ●  │", "            ┣━[═]┫", "            ╰────╯" },
}
local sprites = { "·", "∘", "✦" }
local width, height = 34, 5

local function shows(win, buf)
  return win and win ~= 0 and api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == buf
end

local function owns_float(art)
  return shows(art.win, art.buf) and api.nvim_win_get_config(art.win).relative ~= ""
end
local function clear(win, play)
  active[win] = nil
  for _, art in ipairs(play.art) do
    if owns_float(art) then pcall(api.nvim_win_close, art.win, true) end
    if api.nvim_buf_is_valid(art.buf) then
      if #vim.fn.win_findbuf(art.buf) == 0 then
        api.nvim_buf_delete(art.buf, { force = true })
      else
        vim.bo[art.buf].modifiable = true
        api.nvim_buf_set_lines(art.buf, 0, -1, false, { "" })
        vim.bo[art.buf].modifiable = false
      end
    end
  end
end

local function corner(win, buf, needed)
  if not shows(win, buf) or api.nvim_win_get_tabpage(win) ~= api.nvim_get_current_tabpage() then return end
  local attention = require("straps.attention")
  if attention.waiting(buf) or attention.wait_label(buf, require("straps.dock").has_permission(buf)) ~= "" then return end
  local config = api.nvim_win_get_config(win)
  if config.relative ~= "" then return end
  local row = vim.wo[win].winbar ~= "" and 1 or 0
  local col = api.nvim_win_get_width(win) - needed - 2
  if col >= 0 and api.nvim_win_get_height(win) >= height then return row, col end
end

local function config(win, row, col, w, h)
  return { relative = "win", win = win, row = row, col = col, width = w, height = h }
end

local function draw(win, play, frame, row, col)
  local firefly = play.kind == "firefly"
  local count = firefly and #sprites or 1
  for j = 1, count do
    local x, y, w, h = col, row, play.width, #poses[1]
    if firefly then
      local t = math.max(0, frame - 1 - (3 - j) * 2) / 23
      x = x + math.floor(t * (width - 3))
      y = y + math.floor(2 + 1.9 * math.sin(t * 3 * math.pi) + 0.5)
      w, h = 2, 1
    end
    local cfg = config(win, y, x, w, h)
    local art = play.art[j]
    if not art then
      art = { buf = api.nvim_create_buf(false, true) }
      play.art[j] = art
      vim.bo[art.buf].bufhidden = "wipe"
      local options = vim.tbl_extend("force", cfg, {
        style = "minimal", border = "none", noautocmd = true, focusable = false, mouse = false, zindex = 45,
      })
      art.win = api.nvim_open_win(art.buf, false, options)
      if not owns_float(art) then return false end
      vim.wo[art.win].wrap = false
      vim.wo[art.win].winhighlight = "NormalFloat:Normal"
    elseif not owns_float(art) then
      return false
    else
      api.nvim_win_set_config(art.win, cfg)
    end
    local lines = firefly and { (j == 3 and frame == 24) and "✷" or sprites[j] } or poses[frame]
    vim.bo[art.buf].modifiable = true
    api.nvim_buf_set_lines(art.buf, 0, -1, false, lines)
    vim.bo[art.buf].modifiable = false
    api.nvim_buf_clear_namespace(art.buf, ns, 0, -1)
    if firefly then
      api.nvim_buf_set_extmark(art.buf, ns, 0, 0, {
        end_col = #lines[1], hl_group = j == 3 and "DiagnosticWarn" or (j == 2 and "DiagnosticHint" or "Comment"),
      })
    elseif frame == #poses then
      local col_light = assert(lines[2]:find("●", 1, true)) - 1
      api.nvim_buf_set_extmark(art.buf, ns, 1, col_light, { end_col = col_light + #"●", hl_group = "DiagnosticOk" })
    end
  end
  return true
end

function M.play(kind)
  local firefly = kind == "firefly"
  if not firefly and kind ~= "exoskeleton" then return "usage: :StrapsEgg firefly|exoskeleton" end
  local win, buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
  if vim.b[buf].straps_session ~= true then return ":StrapsEgg requires a session window" end
  if active[win] then clear(win, active[win]) end
  local needed = width
  if not firefly then
    for _, pose in ipairs(poses) do
      for _, line in ipairs(pose) do needed = math.max(needed, vim.fn.strdisplaywidth(line)) end
    end
  end
  local row, col = corner(win, buf, needed)
  if not row then return "animation needs room in the session window and no pending prompt" end
  local play = { kind = kind, art = {}, width = needed }
  active[win] = play
  local last = firefly and 24 or #poses
  local function step(frame)
    if active[win] ~= play then return end
    row, col = corner(win, buf, needed)
    if frame <= last and row then
      local ok, shown = pcall(draw, win, play, frame, row, col)
      if ok and shown then
        vim.defer_fn(function() step(frame + 1) end, frame == last and (firefly and 130 or 650) or (firefly and 65 or 180))
        return true
      end
    end
    clear(win, play)
  end
  if not step(1) then return "could not open the animation" end
end

return M
