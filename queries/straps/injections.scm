; Prose renders as markdown; tool bodies and marker attrs are JSON.
; include-children: a node's text_line/escaped_line children are part of the
; injected text — without it nvim excludes child ranges and the injection
; collapses to the newline gaps between lines (nothing at all for single-line
; content). It is a no-op for the childless inline/attrs tokens. Per-block
; regions, deliberately NOT injection.combined: an unterminated code fence in
; one turn must not bleed into the next. tool_result content stays plain text,
; matching syntax/straps.vim. The preamble (lines before the first marker) was
; markdown under the legacy engine too.

([
  (preamble) @injection.content
  (system_block (content) @injection.content)
  (user_block (content) @injection.content)
  (assistant_block (content) @injection.content)
  (system_block (inline) @injection.content)
  (user_block (inline) @injection.content)
  (assistant_block (inline) @injection.content)
 ]
 (#set! injection.language "markdown")
 (#set! injection.include-children))

([
  (tool_use_block (content) @injection.content)
  (tool_use_block (attrs) @injection.content)
  (tool_result_block (attrs) @injection.content)
 ]
 (#set! injection.language "json")
 (#set! injection.include-children))
