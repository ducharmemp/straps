-- straps/layers/session.lua — the SESSION layer: transcript surgery
-- (transcript_excise), loop-coupled context management for a session buffer.
-- Future prompt-fragment slot: fn.system_prompt_layer.session.

local M = {}

function M.register()
  local registry = require("straps.registry")
  local define = registry.define_default

  -- -------------------------------------------------------- transcript_excise

  -- Context surgery: the transcript buffer IS the request (loop.lua re-parses
  -- it every turn), so shrinking an old block's content shrinks what the model
  -- sees from the next turn onward. Same in-place technique as fn.compact —
  -- blocks are never removed, so tool_use/tool_result pairing and role
  -- alternation survive — but agent-directed and per-block instead of
  -- age-based. The tool CANNOT write arbitrary text into the transcript: the
  -- only thing it can put there is a marked receipt, so no unmarked fabricated
  -- observation can ever be implanted (in itself or in a child).
  define({
    name = "tool.transcript_excise",
    kind = "tool",
    doc = "Excise dead weight from a session transcript — your OWN context"
      .. " window, or a subagent's — reclaiming it from every later request."
      .. " The transcript buffer IS the request: it is re-parsed every turn, so"
      .. " a 40k-token side quest or wrong path you excise now stops being"
      .. " replayed from your next turn on, while the conclusion you keep in"
      .. " your reply text survives. Use it when a line of investigation is"
      .. " finished and wrong: state what you learned in your reply FIRST, then"
      .. " excise the blocks that produced it."
      .. " Two modes. LIST (no blocks/range): returns the block index —"
      .. " number, kind, byte size, a snippet, and which blocks are locked."
      .. " Read-only, so it needs no confirmation; call it first to choose"
      .. " targets. EXCISE (blocks and/or range, plus a required note):"
      .. " replaces the CONTENT of those blocks with a one-line receipt"
      .. " carrying your note and the byte count reclaimed. Blocks are never"
      .. " deleted and no text of your choosing is written — only the receipt —"
      .. " so the human reading the transcript always sees what was removed and"
      .. " why, and the message structure the API requires stays intact."
      .. " Locked and never excisable: the system block, and everything from"
      .. " the last assistant block onward (the turn in flight — this very"
      .. " call's own blocks). Excising is idempotent, one undoable step per"
      .. " call (revert with undo_edit on the transcript file). Parameters:"
      .. " session (optional) — a subagent buffer handle from spawn (must be"
      .. " your own child); omit to operate on your own transcript. blocks"
      .. " (optional) — array of block numbers from list mode. range (optional)"
      .. " — {from, to} inclusive block numbers. note (required to excise) — a"
      .. " short reason, written into the transcript as the receipt.",
    input_schema = {
      type = "object",
      properties = {
        session = {
          type = "integer",
          description = "Subagent buffer handle to operate on; omit for your own transcript.",
        },
        blocks = {
          type = "array",
          items = { type = "integer" },
          description = "Block numbers to excise (from list mode).",
        },
        range = {
          type = "object",
          properties = {
            from = { type = "integer", description = "First block number (inclusive)." },
            to = { type = "integer", description = "Last block number (inclusive)." },
          },
          required = { "from", "to" },
          description = "Inclusive block-number range to excise.",
        },
        note = {
          type = "string",
          description = "Why these blocks are being excised; becomes the visible receipt.",
        },
      },
    },
    source = [==[
return function(input, ctx)
  local state = require("straps.state")

  -- Target: this session's own transcript by default, else a validated
  -- descendant — same check spawn_wait makes, so an agent can only operate on
  -- a buffer it spawned, never an arbitrary buffer in the editor.
  local bufnr, is_child = ctx.bufnr, false
  if input.session ~= nil then
    local child = math.floor(tonumber(input.session) or -1)
    local ok_valid = child >= 0 and vim.api.nvim_buf_is_valid(child)
    local parent
    if ok_valid then pcall(function() parent = vim.b[child].straps_parent end) end
    if not (ok_valid and parent == ctx.bufnr) then
      error("transcript_excise: buffer " .. tostring(input.session)
        .. " is not a subagent of this session")
    end
    bufnr, is_child = child, true
  end
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    error("transcript_excise: no valid session buffer to operate on")
  end

  local blocks = state.list_blocks(bufnr)

  -- The turn in flight starts at the LAST assistant block: the loop appends an
  -- empty assistant marker before the provider call, then EVERY tool_use marker
  -- of the batch before executing any of them, and appends each result after.
  -- So this very call's tool_use block (and its siblings') sit at or after that
  -- index; excising one would orphan a tool_result, which the API rejects. The
  -- same line is what makes editing a RUNNING child safe — the provider streams
  -- text deltas into the tail block, and the tail is never eligible.
  local inflight = 0
  for i = #blocks, 1, -1 do
    if blocks[i].kind == "assistant" then
      inflight = i
      break
    end
  end

  local function region_lines(from_lnum, to_lnum)
    if to_lnum < from_lnum then return {} end
    return vim.api.nvim_buf_get_lines(bufnr, from_lnum - 1, to_lnum, false)
  end
  local function first_nonblank(lines)
    for _, l in ipairs(lines) do
      if l:match("%S") then return l end
    end
    return ""
  end

  -- The lines a receipt would replace. For user/assistant/system the marker
  -- line can carry the block's first content line inline (state.match_marker),
  -- and that text sits OUTSIDE list_blocks' content range — so those blocks are
  -- rewritten from the marker line down, with a bare marker restored. Tool
  -- markers must keep their attrs (id/name) or parse skips the block entirely.
  local function target_region(b)
    if b.kind == "tool_use" or b.kind == "tool_result" then
      return b.first_lnum, b.last_lnum, false
    end
    return b.marker_lnum, math.max(b.last_lnum, b.marker_lnum), true
  end

  -- Bytes the block actually costs: the content lines, plus any inline text on
  -- a prose marker line (never the marker prefix itself).
  local function block_bytes(b)
    local from_lnum, to_lnum, with_marker = target_region(b)
    local lines = region_lines(from_lnum, to_lnum)
    if with_marker and lines[1] then
      lines = vim.deepcopy(lines)
      lines[1] = lines[1]:gsub("^%%%%%[straps:[a-z_]+%]%%%%%s?", "")
    end
    return #table.concat(lines, "\n"), lines
  end

  local function already_excised(b)
    local content = region_lines(b.first_lnum, b.last_lnum)
    if b.kind == "tool_use" then
      local body = vim.trim(table.concat(content, "\n"))
      return body == "" or body == "{}" or body:find('"_excised"', 1, true) ~= nil
    end
    local first = first_nonblank(content)
    return first:find("^%[excised") ~= nil or first:find("^%[compacted: was ") ~= nil
  end

  local function locked(i)
    local b = blocks[i]
    if not b then return "no such block" end
    if b.kind == "system" then return "system prompt" end
    if inflight == 0 or i >= inflight then return "turn in flight" end
    return nil
  end

  -- Collect targets (blocks + range), deduped. Out-of-range numbers are dropped
  -- here rather than errored: a block number past the end is a stale index from
  -- an older listing, and the per-block report already says what was skipped.
  local want, seen = {}, {}
  local asked = false -- did the caller name ANY target? (list mode if not)
  local function add(i)
    asked = true
    i = math.floor(tonumber(i) or -1)
    if i >= 1 and i <= #blocks and not seen[i] then
      seen[i] = true
      want[#want + 1] = i
    end
  end
  if type(input.blocks) == "table" then
    for _, i in ipairs(input.blocks) do add(i) end
  end
  if type(input.range) == "table" then
    local from = math.floor(tonumber(input.range.from) or 0)
    local to = math.floor(tonumber(input.range.to) or 0)
    if from < 1 or to < from then
      error("transcript_excise: range must be {from, to} with 1 <= from <= to")
    end
    -- Clamp before iterating: an unbounded `to` would otherwise build a table
    -- of millions of indices before any of them was checked against #blocks.
    to = math.min(to, #blocks)
    for i = from, to do add(i) end
    asked = true -- a range past the end still means "excise", not "list"
  end

  -- ------------------------------------------------------------- list mode
  -- Only when the caller named no target at all. A target that filtered out
  -- (every number past the end of the transcript) is a failed excision and must
  -- report that, not silently return an index listing.
  if not asked then
    local out = {
      ("transcript buffer %d — %d blocks; the turn in flight starts at block %s")
        :format(bufnr, #blocks, inflight > 0 and tostring(inflight) or "?"),
      "   #  kind          bytes  content",
    }
    local reclaimable = 0
    for i, b in ipairs(blocks) do
      local nbytes = block_bytes(b)
      local why = locked(i)
      local tag = ""
      if why then
        tag = "[locked: " .. why .. "] "
      elseif already_excised(b) then
        tag = "[already excised] "
      else
        reclaimable = reclaimable + nbytes
      end
      local snippet = first_nonblank(region_lines(b.first_lnum, b.last_lnum))
        :gsub("%s+", " "):sub(1, 70)
      out[#out + 1] = ("%4d  %-12s %6d  %s%s"):format(i, b.kind, nbytes, tag, snippet)
    end
    out[#out + 1] = ("%d bytes excisable. To excise: transcript_excise with"
      .. " blocks/range and a note."):format(reclaimable)
    return table.concat(out, "\n")
  end

  -- ----------------------------------------------------------- excise mode
  local note = input.note
  if type(note) ~= "string" or not note:match("%S") then
    error("transcript_excise: note is required to excise — it is the receipt left"
      .. " in the transcript in place of what you removed")
  end
  -- A receipt is exactly one line: flattening the note is what keeps a note
  -- containing a marker-shaped line from splitting the block it lands in.
  -- Control characters are dropped (a NUL in a buffer line is not writable as
  -- itself), and the note is capped — a receipt longer than the content it
  -- replaces would make the transcript grow instead of shrink.
  note = note:gsub("%c", " "):gsub("%s+", " ")
  note = vim.trim(note)
  if #note > 200 then
    note = note:sub(1, 197) .. "..."
  end

  table.sort(want)
  local skipped = {}
  -- Plan every replacement against ONE snapshot, then apply it as ONE
  -- set_lines over the whole affected span (untouched lines inside the span are
  -- copied verbatim). That makes line-number staleness impossible — no second
  -- edit ever runs against shifted numbers — and the whole surgery is a single
  -- undoable step, so undo_edit reverts it as a unit.
  local edits = {}
  for _, i in ipairs(want) do
    local b = blocks[i]
    local why = locked(i)
    if why then
      skipped[#skipped + 1] = ("block %d: %s"):format(i, why)
    elseif already_excised(b) then
      skipped[#skipped + 1] = ("block %d: already excised"):format(i)
    else
      local nbytes = block_bytes(b)
      if nbytes == 0 then
        skipped[#skipped + 1] = ("block %d: already empty"):format(i)
      else
        -- Staleness assertion: the marker must still be where the snapshot said.
        -- If it is not, something else wrote to the transcript and every range
        -- in the snapshot is suspect — refuse rather than eat a neighbour.
        local marker = vim.api.nvim_buf_get_lines(bufnr,
          b.marker_lnum - 1, b.marker_lnum, false)[1] or ""
        if not marker:find("^%%%%%[straps:" .. b.kind .. "%]%%%%") then
          error(("transcript_excise: the transcript changed underneath us"
            .. " (block %d is no longer %s) — nothing was excised; list again")
            :format(i, b.kind))
        end
        local from_lnum, to_lnum, with_marker = target_region(b)
        local repl = {}
        local content
        if b.kind == "tool_use" then
          -- Stays decodable JSON so parse still yields a real input object, and
          -- the note survives into the request instead of vanishing.
          content = vim.json.encode({
            _excised = ("was %d bytes — %s"):format(nbytes, note),
          })
        else
          content = ("[excised%s: was %d bytes — %s]")
            :format(is_child and " by parent" or "", nbytes, note)
        end
        -- What actually prevents a note from injecting a block is the receipt
        -- FRAME plus the flattening above: the written line always begins with
        -- "[excised" or '{"_excised"', and is always exactly one line, so it can
        -- never read as a marker. escape_line is belt-and-braces for a future
        -- frame change (set_lines bypasses the escaping state.append applies).
        -- The marker line itself is emitted verbatim — it IS a marker, and
        -- escaping it would destroy the block.
        if with_marker then
          repl[#repl + 1] = "%%[straps:" .. b.kind .. "]%%"
        end
        repl[#repl + 1] = state.escape_line(content)
        -- Keep the blank separator line before the next marker if there was one.
        local tail = vim.api.nvim_buf_get_lines(bufnr, to_lnum - 1, to_lnum, false)[1]
        if tail and not tail:match("%S") then
          repl[#repl + 1] = ""
        end
        -- Never grow the transcript: on a block already smaller than its own
        -- receipt there is nothing to reclaim, and rewriting it would only cost
        -- bytes (and destroy readable content for no gain).
        if #table.concat(repl, "\n") >= nbytes then
          skipped[#skipped + 1] = ("block %d: smaller than its receipt"):format(i)
        else
          edits[#edits + 1] = { from = from_lnum, to = to_lnum, lines = repl, bytes = nbytes }
        end
      end
    end
  end

  local touched, before, after = 0, 0, 0
  if #edits > 0 then
    table.sort(edits, function(a, b) return a.from < b.from end)
    local span_from, span_to = edits[1].from, edits[#edits].to
    local buf_lines = vim.api.nvim_buf_get_lines(bufnr, span_from - 1, span_to, false)
    local by_start = {}
    for _, e in ipairs(edits) do by_start[e.from] = e end
    local new_lines = {}
    local lnum = span_from
    while lnum <= span_to do
      local e = by_start[lnum]
      if e then
        for _, l in ipairs(e.lines) do new_lines[#new_lines + 1] = l end
        touched = touched + 1
        before = before + e.bytes
        after = after + #table.concat(e.lines, "\n")
        lnum = e.to + 1
      else
        new_lines[#new_lines + 1] = buf_lines[lnum - span_from + 1]
        lnum = lnum + 1
      end
    end
    vim.api.nvim_buf_set_lines(bufnr, span_from - 1, span_to, false, new_lines)
    state.persist(bufnr) -- file-backed transcripts only; no-op otherwise
  end

  local out = {}
  if touched == 0 then
    out[#out + 1] = "excised nothing"
  else
    out[#out + 1] = ("excised %d block(s) from %s: %d -> %d bytes (receipt: %s)")
      :format(touched, is_child and ("subagent buffer " .. bufnr) or "your transcript",
        before, after, note)
    out[#out + 1] = "The excised content is gone from every later request;"
      .. " the receipts stay visible in the transcript."
  end
  for _, s in ipairs(skipped) do
    out[#out + 1] = "skipped " .. s
  end
  return table.concat(out, "\n")
end
]==],
  })
end

return M
