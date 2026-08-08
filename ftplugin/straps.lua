-- Prefer the tree-sitter grammar when the straps parser is installed: real
-- markdown/JSON injection in the language tree (queries/straps/), and any
-- language-tree-driven markdown renderer the user has lights up on the
-- transcript. Starting the highlighter here also stops syntax/straps.vim from
-- loading for this buffer; without the parser this is a no-op and the legacy
-- syntax file applies exactly as before.
if vim.b.did_ftplugin then
  return
end
vim.b.did_ftplugin = 1

local ok, added = pcall(vim.treesitter.language.add, "straps")
if ok and added then
  pcall(vim.treesitter.start)
  -- The @straps.* capture groups and StrapsFileRef live in ui.lua's HL_LINKS;
  -- the legacy syntax file defines its own links on load, but under
  -- treesitter nothing else establishes them when setup() was never called
  -- (the plugin's commands work without it).
  pcall(function()
    local ui = require("straps.ui")
    ui.apply_highlights()
    -- The legacy syntax file underlined path:line refs with zero setup; keep
    -- that true under treesitter for a plain `:e file.straps` (no-op for a
    -- session buffer that is not windowed yet — show_session covers those).
    ui.apply_file_ref_match(vim.api.nvim_get_current_buf())
  end)
  -- Detach on a filetype change away from straps, or the straps highlighter
  -- (and its injections) keeps painting the buffer under the new filetype.
  -- Use a `:call` command, not `:lua`: undo_ftplugin values are joined with
  -- `|` (ftplugin.vim runs `exe b:undo_ftplugin`), and `:lua` swallows the
  -- bar as source, so a clause appended after a `:lua` one fails with E5107.
  -- `:call` honors the bar, matching core ftplugins (query.lua, markdown.lua).
  vim.b.undo_ftplugin = "call v:lua.vim.treesitter.stop()"
end
