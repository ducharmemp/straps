-- Prefer the tree-sitter grammar when the straps parser is installed: real
-- markdown/JSON injection in the language tree (queries/straps/), and any
-- language-tree-driven markdown renderer the user has lights up on the
-- transcript. Starting the highlighter here also stops syntax/straps.vim from
-- loading for this buffer; without the parser the legacy syntax file applies.
if vim.b.did_ftplugin then
  return
end
vim.b.did_ftplugin = 1

local bufnr = vim.api.nvim_get_current_buf()
-- undo_ftplugin values are joined with `|` (ftplugin.vim runs `exe
-- b:undo_ftplugin`), and `:lua` swallows the bar as source, so a clause
-- appended after a `:lua` one fails with E5107. `:call` and plain Ex commands
-- honor the bar, matching core ftplugins (query.lua, markdown.lua).
local undo = {
  "setlocal foldmethod< foldexpr< foldtext< foldlevel< conceallevel< concealcursor<",
}

pcall(function()
  local ui = require("straps.ui")
  ui.apply_highlights()
  ui.map_session_keys(bufnr)
  for _, lhs in ipairs(ui.SESSION_KEYS) do
    undo[#undo + 1] = ("silent! call nvim_buf_del_keymap(0, 'n', '%s')"):format(lhs)
  end
  ui.apply_fold_opts(bufnr)
end)

local ok, added = pcall(vim.treesitter.language.add, "straps")
if ok and added then
  pcall(vim.treesitter.start)
  -- The legacy syntax file underlined path:line refs with zero setup; keep
  -- that true under treesitter for a plain `:e file.straps` (no-op for a
  -- session buffer that is not windowed yet — show_session covers those).
  pcall(function()
    require("straps.ui").apply_file_ref_match(bufnr)
  end)
  -- Detach on a filetype change away from straps, or the straps highlighter
  -- (and its injections) keeps painting the buffer under the new filetype.
  undo[#undo + 1] = "call v:lua.vim.treesitter.stop()"
end

vim.b.undo_ftplugin = table.concat(undo, " | ")
