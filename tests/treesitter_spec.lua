-- tests/treesitter_spec.lua — the tree-sitter grammar (tree-sitter-straps/)
--   busted tests/treesitter_spec.lua
-- No network. Parses a transcript covering every marker form and asserts the
-- grammar's block boundaries agree with state.list_blocks (the grammar is
-- display-only; state.lua stays the parser of record — this test is the
-- contract between the two). Also asserts the injection/highlight queries
-- load, injected markdown/json trees materialize with the right ranges, and
-- the ftplugin starts the treesitter highlighter.
--
-- Parser acquisition: uses a `straps` parser already on rtp if present (the
-- flake check provides one); otherwise compiles the committed
-- tree-sitter-straps/src/parser.c with cc into a temp dir. Without either,
-- prints SKIP and exits 0 — a missing C compiler must not fail unrelated
-- local runs.

local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(vim.fn.fnamemodify(here, ":p"), ":h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
vim.fn.chdir(root)

-- With STRAPS_TS_REQUIRED set (the flake check sets it after installing the
-- parsers), a missing straps or json parser is a hard failure instead of a
-- skip/soft pass — a broken parser install must not leave CI green while the
-- grammar goes untested.
local required = vim.env.STRAPS_TS_REQUIRED ~= nil

-- Locate or build the parser. language.add reports a missing parser either by
-- returning nil or by erroring depending on version — check both. Local
-- builds are cached in stdpath("cache") keyed on the hash of parser.c, so
-- repeated runs don't pay the compile.
local ok_add, added = pcall(vim.treesitter.language.add, "straps")
if not (ok_add and added) then
  assert(not required, "STRAPS_TS_REQUIRED set but no straps parser on rtp")
  local src = root .. "/tree-sitter-straps/src/parser.c"
  local so = vim.fn.stdpath("cache")
    .. "/straps-test-parser-" .. vim.fn.sha256(table.concat(vim.fn.readfile(src), "\n")):sub(1, 16) .. ".so"
  if vim.fn.filereadable(so) == 0 then
    vim.fn.mkdir(vim.fn.fnamemodify(so, ":h"), "p")
    local out = vim.fn.system({
      "cc", "-shared", "-fPIC", "-O2", "-I", root .. "/tree-sitter-straps/src", src, "-o", so,
    })
    if vim.v.shell_error ~= 0 then
      print("SKIP  treesitter_spec: no straps parser on rtp and cc failed: " .. out)
      return
    end
  end
  local ok_built, built = pcall(vim.treesitter.language.add, "straps", { path = so })
  assert(ok_built and built, "compiled parser failed to load")
end


-- Every marker form state.lua's match_marker distinguishes: canonical blocks,
-- inline first-content with and without the leading space, tool attrs bare /
-- invalid JSON / no-space rest, an escaped marker-lookalike, a glued second
-- marker (rest of a marker line, so inline content — not a new block), an
-- invalid kind (plain content), garbage before the first marker, an empty
-- block, and an unterminated fence that must stay inside its own block. Every
-- (block kind, node) pair injections.scm captures appears at least once:
-- inline AND content for each prose kind, attrs AND content for tool_use,
-- attrs for tool_result.
local LINES = {
  "garbage before the first marker", -- 1
  "%%[straps:system]%% You are an agent.", -- 2: system inline (markdown)
  "System prose content.", -- 3: system content (markdown)
  "",
  "%%[straps:user]%%", -- 5
  "Hello **there**, see lua/straps/ui.lua:42", -- 6: user content (markdown)
  "",
  "%%[straps:assistant]%% Inline reply first.", -- 8: assistant inline (markdown)
  "## Heading", -- 9: assistant content (markdown)
  "",
  "```lua", -- 11: fence left unterminated on purpose
  "print('unterminated fence", -- 12
  "",
  "%%[straps:tool_use]%% {\"id\":\"t1\",\"name\":\"grep\"}", -- 14: tool_use attrs (json)
  "{\"pattern\":\"foo\"}", -- 15: tool_use content (json)
  "",
  "%%[straps:tool_use]%%junk-no-space", -- 17
  "%%[straps:tool_use]%%", -- 18: bare marker
  "%%[straps:tool_use]%% not valid json", -- 19
  "%%[straps:tool_result]%% {\"id\":\"t1\"}", -- 20: tool_result attrs (json)
  "%%[[esc]]%%[straps:user]%% escaped, still tool_result content", -- 21
  "plain result line", -- 22: tool_result content (never injected)
  "",
  "%%[straps:bogus]%% invalid kind, content of the block above", -- 24
  "%%[straps:user]%%%%[straps:assistant]%% glued marker is inline content", -- 25
  "%%[straps:user]%%no-space inline", -- 26: user inline (markdown)
  "%%[straps:assistant]%%", -- 27: empty block
}

local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, LINES)

local parser = assert(vim.treesitter.get_parser(buf, "straps"))
parser:parse(true)
local root_node = parser:trees()[1]:root()

it("transcript parses without errors", function()
  assert(not root_node:has_error(), "parse tree has errors: " .. root_node:sexpr())
end)

it("block boundaries agree with state.list_blocks", function()
  local expect = require("straps.state").list_blocks(buf)
  local got = {}
  for child in root_node:iter_children() do
    local t = child:type()
    if t:match("_block$") then
      local row = child:start()
      got[#got + 1] = { kind = t:gsub("_block$", ""), marker_lnum = row + 1 }
    else
      assert(t == "preamble", "unexpected top-level node: " .. t)
    end
  end
  assert(#got == #expect, ("block count: grammar %d vs list_blocks %d"):format(#got, #expect))
  for i, b in ipairs(expect) do
    assert(got[i].kind == b.kind,
      ("block %d kind: grammar %s vs list_blocks %s"):format(i, got[i].kind, b.kind))
    assert(got[i].marker_lnum == b.marker_lnum,
      ("block %d marker line: grammar %d vs list_blocks %d"):format(i, got[i].marker_lnum, b.marker_lnum))
  end
end)

it("highlights and injections queries load", function()
  assert(vim.treesitter.query.get("straps", "highlights"), "no highlights query")
  assert(vim.treesitter.query.get("straps", "injections"), "no injections query")
end)

it("prose injects markdown, tool bodies inject json, per block", function()
  local ranges = { markdown = {}, json = {} }
  parser:for_each_tree(function(tree, ltree)
    local lang = ltree:lang()
    if ranges[lang] then
      local srow, _, erow = tree:root():range()
      ranges[lang][#ranges[lang] + 1] = { srow + 1, erow + 1 }
    end
  end)
  local function covers(lang, lnum)
    for _, r in ipairs(ranges[lang]) do
      if lnum >= r[1] and lnum <= r[2] then
        return true
      end
    end
    return false
  end
  -- One assertion per injection alternative in injections.scm: the preamble,
  -- inline + content per prose kind, attrs + content for tool_use, attrs for
  -- tool_result.
  assert(covers("markdown", 1), "preamble not markdown")
  assert(covers("markdown", 2), "system inline not markdown")
  assert(covers("markdown", 3), "system content not markdown")
  assert(covers("markdown", 6), "user content not markdown")
  assert(covers("markdown", 26), "user inline not markdown")
  assert(covers("markdown", 8), "assistant inline not markdown")
  assert(covers("markdown", 9), "assistant content not markdown")
  -- Neovim bundles the markdown parsers but not json; without a json parser
  -- the injection has nothing to materialize with, so only assert when one is
  -- available (the flake check installs it; see checkPhase).
  local ok_json, has_json = pcall(vim.treesitter.language.add, "json")
  if ok_json and has_json then
    assert(covers("json", 14), "tool_use attrs not json")
    assert(covers("json", 15), "tool_use content not json")
    assert(covers("json", 20), "tool_result attrs not json")
  else
    assert(not required, "STRAPS_TS_REQUIRED set but no json parser on rtp")
    print("NOTE  json parser unavailable; tool-body injection not asserted")
  end
  -- The unterminated fence (line 11) must not leak past its block's last
  -- content line (12): per-block injection, not injection.combined.
  for _, r in ipairs(ranges.markdown) do
    assert(r[2] <= 12 or r[1] >= 25, "markdown region crosses a tool block: " .. r[1] .. "-" .. r[2])
  end
  -- tool_result content stays plain text.
  assert(not covers("markdown", 22) and not covers("json", 22), "tool_result content got injected")
end)

it("ftplugin starts the treesitter highlighter for filetype=straps", function()
  vim.cmd("filetype plugin on") -- headless -l runs with filetype plugins off
  local fbuf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, LINES)
  vim.bo[fbuf].filetype = "straps"
  assert(vim.treesitter.highlighter.active[fbuf], "highlighter not active after FileType")
end)

local function ref_match_count(win)
  local n = 0
  for _, m in ipairs(vim.fn.getmatches(win)) do
    if m.group == "StrapsFileRef" then
      n = n + 1
    end
  end
  return n
end

it("apply_file_ref_match underlines refs in windows showing the buffer", function()
  local ui = require("straps.ui")
  local fbuf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, LINES)
  vim.bo[fbuf].filetype = "straps"
  vim.api.nvim_win_set_buf(0, fbuf)
  ui.apply_file_ref_match(fbuf)
  local win = vim.api.nvim_get_current_win()
  local id = vim.w[win].straps_file_ref_match
  assert(id, "no match registered")
  local found = false
  for _, m in ipairs(vim.fn.getmatches(win)) do
    if m.id == id then
      found = m.group == "StrapsFileRef"
    end
  end
  assert(found, "match id not present with group StrapsFileRef")
  ui.apply_file_ref_match(fbuf)
  assert(ref_match_count(win) == 1, "matchadd not idempotent per window")
end)

-- Matches stay with a window across buffer switches (unlike window-local
-- options). The lifecycle autocmds are registered lazily by
-- apply_file_ref_match itself — deliberately no setup() call anywhere in this
-- file: :Straps and `:e file.straps` create matches without setup() ever
-- running, so the cleanup must work there too.

it("match does not leak into other buffers shown by the window", function()
  local fbuf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, LINES)
  vim.bo[fbuf].filetype = "straps"
  vim.cmd("buffer " .. fbuf)
  local win = vim.api.nvim_get_current_win()
  assert(ref_match_count(win) == 1, "match not applied on BufWinEnter")
  vim.cmd("enew")
  assert(ref_match_count(win) == 0, "match leaked into a non-straps buffer")
  assert(vim.w[win].straps_file_ref_match == nil, "stale guard var after leaving")
  vim.cmd("buffer " .. fbuf)
  assert(ref_match_count(win) == 1, "match not re-applied on returning")
end)

it("a split of the session window gets its own match", function()
  local fbuf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, LINES)
  vim.bo[fbuf].filetype = "straps"
  vim.cmd("buffer " .. fbuf)
  vim.cmd("split")
  local win = vim.api.nvim_get_current_win()
  assert(ref_match_count(win) == 1, "split window did not get the match")
  vim.cmd("close")
end)

it("an in-place filetype change away from straps drops the match", function()
  local fbuf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, LINES)
  vim.bo[fbuf].filetype = "straps"
  vim.cmd("buffer " .. fbuf)
  local win = vim.api.nvim_get_current_win()
  assert(ref_match_count(win) == 1, "match not applied")
  vim.bo[fbuf].filetype = "text" -- fires only FileType: no window/buffer event
  assert(ref_match_count(win) == 0, "match survived the filetype change")
  assert(vim.w[win].straps_file_ref_match == nil, "stale guard var after ft change")
  assert(vim.treesitter.highlighter.active[fbuf] == nil, "highlighter survived the ft change")
end)
