" straps.vim — syntax highlighting for straps.nvim session buffers.
" Markers (%%[straps:kind]%% ...) get their own highlighting; body text is
" plain markdown; tool_use/tool_result bodies get real JSON highlighting.

if exists("b:current_syntax")
  finish
endif

" Prose (assistant/user text) is markdown. `syn include` pulls it in under
" its own cluster so it doesn't collide with our marker/JSON regions below.
syn include @strapsMarkdown syntax/markdown.vim
unlet! b:current_syntax

syn include @strapsJSON syntax/json.vim
unlet! b:current_syntax

" The escape prefix (%%[[esc]]...) that lets literal marker-looking content
" lines survive round-tripping; dim it so the escaped payload reads normally.
syn match strapsEscMarker "^%%\[\[esc\]\]" contained

" path:line[:col] references — press gf on one to jump there
" (ui.map_file_refs); underlined so they read as navigable. Same regex as
" apply_file_ref_match in lua/straps/ui.lua (the treesitter engine's copy) —
" change both together.
syn match strapsFileRef "[[:alnum:]_./~-]\+:\d\+\%(:\d\+\)\=" contained

" Prose blocks (system/user/assistant content) render as markdown. Defined
" BEFORE the marker matches below: in Vim syntax, when two non-contained
" items match at the same position, the later definition wins, so markers
" must come after this to take priority over the whole-line prose match.
syn match strapsProseLine "^.*$" contains=@strapsMarkdown,strapsEscMarker,strapsFileRef

" tool_use / tool_result bodies: JSON content up to (not including) the next
" marker line or end of buffer. Also defined before the marker matches so
" the markers themselves win on their own line.
syn region strapsToolUseBody
  \ start="^" end="^\ze%%\[straps:"
  \ contains=@strapsJSON,strapsEscMarker
  \ contained keepend

syn region strapsToolResultBody
  \ start="^" end="^\ze%%\[straps:"
  \ contains=strapsEscMarker,strapsFileRef
  \ contained keepend

" Marker lines: matched last (whole line) so they win over the prose/body
" regions above wherever they overlap.
syn match strapsSystemMarker    "^%%\[straps:system\]%%.*$"
syn match strapsUserMarker      "^%%\[straps:user\]%%.*$"
syn match strapsAssistantMarker "^%%\[straps:assistant\]%%.*$"
syn match strapsToolUseMarker    "^%%\[straps:tool_use\]%%.*$"     nextgroup=strapsToolUseBody skipnl
syn match strapsToolResultMarker "^%%\[straps:tool_result\]%%.*$" nextgroup=strapsToolResultBody skipnl

" Targets mirror the @straps.* entries in ui.lua's HL_LINKS (the treesitter
" engine's palette) — retheme a marker in both places.
hi def link strapsSystemMarker     Title
hi def link strapsUserMarker       Question
hi def link strapsAssistantMarker  Function
hi def link strapsToolUseMarker    PreProc
hi def link strapsToolResultMarker Comment
hi def link strapsEscMarker        Special
hi def link strapsFileRef          Underlined

let b:current_syntax = "straps"
