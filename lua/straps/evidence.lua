local M = {}
local api = vim.api
local ns = api.nvim_create_namespace("straps.evidence")
local prefix = "[[straps-evidence]] "
local max_line, max_links = 4096, 8

M.prompt = [=[
When a sentence in your answer is supported by a specific line in an original tool result, you may attach evidence. After your prose, emit one line per link, for up to eight links, in this form:
[[straps-evidence]] {"claim":"exact sentence from your answer","quote":"exact distinctive text on one line of the tool result"}
Use exact, unique text on both sides. The result quote must support the claim and identify one occurrence across the tool results in your request. Omit the declaration if either side is ambiguous, absent, or would rely on a summary or archive receipt. Do not write citation markers, excerpts, or footnotes in your prose.
]=]

function M.stream()
  return { mode = "prefix", pending = "", declarations = {} }
end

function M.filter(stream, text, finish)
  local out = {}
  local i = 1
  local function flush_declaration()
    if stream.pending and #stream.declarations < max_links then
      stream.declarations[#stream.declarations + 1] = stream.pending
    end
    stream.pending = ""
  end
  while i <= #text do
    local newline = text:find("\n", i, true)
    local chunk = text:sub(i, newline and newline - 1 or #text)
    if stream.mode == "prefix" then
      local candidate = stream.pending .. chunk
      if #candidate < #prefix and prefix:sub(1, #candidate) == candidate and not newline then
        stream.pending = candidate
      elseif vim.startswith(candidate, prefix) then
        stream.mode = "declaration"
        stream.pending = ""
        chunk = candidate:sub(#prefix + 1)
      else
        stream.mode = "text"
        stream.pending = ""
        chunk = candidate
      end
    end
    if stream.mode == "text" then
      out[#out + 1] = chunk
      if newline then out[#out + 1] = "\n" end
    elseif stream.mode == "declaration" then
      if stream.pending and #stream.pending + #chunk <= max_line then
        stream.pending = stream.pending .. chunk
      else
        stream.pending = false
      end
      if newline then flush_declaration() end
    end
    if newline then stream.mode = "prefix" end
    i = newline and newline + 1 or #text + 1
  end
  if finish then
    if stream.mode == "declaration" then
      flush_declaration()
    elseif stream.mode == "prefix" then
      out[#out + 1] = stream.pending
    end
    stream.pending = ""
  end
  return table.concat(out)
end

local function immutable_range(bufnr, first, last)
  return api.nvim_buf_set_extmark(bufnr, ns, first, 0,
    { end_row = last - 1, end_col = #(api.nvim_buf_get_lines(bufnr, last - 1, last, false)[1] or ""),
      invalidate = true, undo_restore = false, right_gravity = true, end_right_gravity = false })
end

local function range_text(bufnr, first, last)
  return table.concat(api.nvim_buf_get_lines(bufnr, first, last, false), "\n")
end

local function unique(text, pattern)
  local first, last = text:find(pattern, 1, true)
  if first and not text:find(pattern, first + 1, true) then return first, last end
  return nil, nil, first ~= nil
end

local function single_line(value)
  return type(value) == "string" and value:find("%S") and not value:find("[%z\r\n]")
end

local function lines(text)
  return vim.split(text, "\n", { plain = true })
end

local function span(text, offset)
  local before = text:sub(1, offset - 1)
  local row = select(2, before:gsub("\n", ""))
  local col = #(before:match("[^\n]*$") or "")
  return row, col
end

local function original(content)
  local first = content:match("^[^\n]*")
  return not (vim.startswith(first, "[excised") or vim.startswith(first, "[compacted: was ")
    or vim.startswith(first, "[straps-context:") or vim.startswith(first, "UNTRUSTED ARCHIVED EVIDENCE."))
end

local function each_result(request, visit)
  for _, msg in ipairs(request.messages or {}) do
    if msg.role == "user" then
      for _, part in ipairs(msg.content or {}) do
        if part.type == "tool_result" and type(part.content) == "string" and visit(part) then return true end
      end
    end
  end
end

function M.has_original_results(request)
  return each_result(request, function(part) return part.content ~= "" and original(part.content) end)
end

function M.sources(request)
  local results = {}
  each_result(request, function(part)
    results[#results + 1] = { id = part.tool_use_id, content = part.content }
  end)
  return results
end

local function source_for(results, quote)
  local source, offset
  for _, part in ipairs(results) do
    local first, _, ambiguous = unique(part.content, quote)
    if ambiguous or (first and source) then return end
    if first then source, offset = part, first end
  end
  if source and type(source.id) == "string" and original(source.content) then return source, offset end
end

local function result_block(blocks, id)
  local result
  for _, block in ipairs(blocks) do
    if block.kind == "tool_result" and block.attrs and block.attrs.id == id then
      if result then return end
      result = block
    end
  end
  return result
end

local function resolve(bufnr, request, blocks, assistant, answer, declaration)
  local ok, link = pcall(vim.json.decode, declaration)
  if not ok or type(link) ~= "table" or not single_line(link.claim) or not single_line(link.quote) then return end
  local first = unique(answer, link.claim)
  local source, offset = source_for(request, link.quote)
  if not (first and source) then return end
  local result = result_block(blocks, source.id)
  if not result or result.marker_lnum >= assistant.marker_lnum then return end
  local start = result.first_lnum - 1
  while start < result.last_lnum and range_text(bufnr, start, start + 1):match("^%s*$") do start = start + 1 end
  local state = require("straps.state")
  local body = lines(source.content)
  local source_end = start + #body
  if source_end > result.last_lnum then return end
  local claim_row, claim_col = span(answer, first)
  local source_row, source_col = span(source.content, offset)
  local original_len = #body[source_row + 1]
  for i, line in ipairs(body) do body[i] = state.escape_line(line) end
  if range_text(bufnr, start, source_end) ~= table.concat(body, "\n")
    or not range_text(bufnr, source_end, result.last_lnum):match("^%s*$") then return end
  source_col = source_col + #body[source_row + 1] - original_len
  return {
    row = assistant.first_lnum - 1 + claim_row, col = claim_col, len = #link.claim,
    source_first = result.marker_lnum - 1, source_end = source_end,
    source_row = start + source_row - (result.marker_lnum - 1), source_col = source_col,
  }
end

local links = {}
local function attach(bufnr)
  if links[bufnr] then return links[bufnr] end
  local entry = {}
  links[bufnr] = entry
  api.nvim_buf_attach(bufnr, false, { on_detach = function() links[bufnr] = nil end })
  return entry
end

function M.bind(bufnr, request, marker, declarations)
  if #declarations == 0 then return end
  local blocks = require("straps.state").list_blocks(bufnr)
  local assistant = blocks[#blocks]
  if not assistant or assistant.kind ~= "assistant" or assistant.marker_lnum ~= marker then return end
  local answer = range_text(bufnr, assistant.first_lnum - 1, assistant.last_lnum)
  local candidates = {}
  for _, declaration in ipairs(declarations) do
    local link = resolve(bufnr, request, blocks, assistant, answer, declaration)
    if link then candidates[#candidates + 1] = link end
  end
  for _, link in ipairs(candidates) do
    local overlaps = false
    for _, other in ipairs(candidates) do
      if link ~= other and link.row == other.row and link.col < other.col + other.len and other.col < link.col + link.len then
        overlaps = true
      end
    end
    if not overlaps then
      local entry = attach(bufnr)
      local id = immutable_range(bufnr, link.row, link.row + 1)
      local exact = range_text(bufnr, link.row, link.row + 1)
      entry[id] = {
        col = link.col, len = link.len, line = exact, source_row = link.source_row, source_col = link.source_col,
        source = immutable_range(bufnr, link.source_first, link.source_end),
        source_hash = vim.fn.sha256(range_text(bufnr, link.source_first, link.source_end)),
      }
    end
  end
end

local function target(win, bufnr)
  win = win or api.nvim_get_current_win()
  if not api.nvim_win_is_valid(win) then return end
  bufnr = bufnr or api.nvim_win_get_buf(win)
  local entry = links[bufnr]
  if not entry or api.nvim_win_get_buf(win) ~= bufnr or vim.b[bufnr].straps_session ~= true then return end
  local cursor = api.nvim_win_get_cursor(win)
  local row, col = cursor[1] - 1, cursor[2]
  local marks = api.nvim_buf_get_extmarks(bufnr, ns, { row, 0 }, { row, -1 }, { details = true })
  for _, mark in ipairs(marks) do
    local link = entry[mark[1]]
    if link and not mark[4].invalid and mark[3] == 0 and col >= link.col and col < link.col + link.len
      and link.line == range_text(bufnr, row, row + 1) then
      local blocks = require("straps.state").list_blocks(bufnr)
      local source = api.nvim_buf_get_extmark_by_id(bufnr, ns, link.source, { details = true })
      if #source == 3 and not source[3].invalid and source[2] == 0 then
        local tick = api.nvim_buf_get_changedtick(bufnr)
        if link.checked ~= tick then
          local claim_block, source_valid
          for _, block in ipairs(blocks) do
            if block.marker_lnum <= row + 1 then claim_block = block end
            if block.marker_lnum == source[1] + 1 and block.kind == "tool_result" and source[3].end_row < block.last_lnum
              and range_text(bufnr, source[3].end_row + 1, block.last_lnum):match("^%s*$") then
              source_valid = true
            end
          end
          link.valid = source_valid and claim_block and claim_block.kind == "assistant" and claim_block.marker_lnum <= row
            and vim.fn.sha256(range_text(bufnr, source[1], source[3].end_row + 1)) == link.source_hash
          link.checked = tick
        end
        if link.valid then return { source[1] + 1 + link.source_row, link.source_col } end
      end
    end
  end
end

function M.winbar_hint(win, bufnr)
  return target(win, bufnr) and "↳ gE evidence" or ""
end

function M.jump()
  local dest = target()
  if not dest then return false end
  vim.cmd("normal! m'")
  api.nvim_win_set_cursor(0, dest)
  vim.cmd("normal! zv")
  return true
end

function M.map(bufnr)
  vim.keymap.set("n", "gE", function()
    if not M.jump() then vim.cmd("normal! " .. vim.v.count1 .. "gE") end
  end, { buffer = bufnr, desc = "straps: jump to claim evidence or preceding WORD end" })
end

return M
