// Tree-sitter grammar for the straps transcript format (filetype=straps).
//
// Display-only: lua/straps/state.lua remains the sole parser used to build API
// messages, and DESIGN.md's Block grammar section is the spec. This grammar
// exists so the buffer's language tree carries the transcript structure —
// prose blocks inject markdown, tool bodies inject JSON (queries/straps/) —
// which gives treesitter highlighting and lets language-tree-driven markdown
// renderers work on straps buffers. tests/run_treesitter.lua pins this
// grammar's block boundaries to state.list_blocks().
//
// The format is line-oriented, so lexing is structured around lines: newlines
// live in `extras`, and every rest-of-line token is `token.immediate` so it
// cannot cross a line boundary. Anchoring markers to line starts falls out of
// that structure: mid-line marker text is always consumed by a text-line or
// rest-of-line token first. Lexical precedence tiers:
//
//   3  rest-of-marker-line and escaped-line payloads — always literal
//      content, even when they look like markers: match_marker's rest capture
//      is `(.*)$`, so a glued `%%[straps:user]%%%%[straps:assistant]%%` is
//      ONE user marker with inline content, and %%[[esc]]%%[straps:user]%% is
//      one escaped line
//   2  marker literals and the %%[[esc]] prefix — beat plain text lines
//   0  plain text lines
//
// Kept in agreement with state.lua's match_marker for non-canonical lines:
// rest-of-line after a tool marker is `attrs` whether or not it is valid JSON
// (validity is the injected JSON parser's concern), rest-of-line after a prose
// marker is inline first content, and a marker-lookalike with an unknown kind
// is a plain text line.

const marker = (kind) => token(prec(2, `%%[straps:${kind}]%%`));

module.exports = grammar({
  name: 'straps',

  extras: (_) => [/\n/],

  rules: {
    document: ($) => seq(optional($.preamble), repeat($._block)),

    // Lines before the first marker; ignored by the Lua parser.
    preamble: ($) => repeat1($._line),

    _block: ($) =>
      choice(
        $.system_block,
        $.user_block,
        $.assistant_block,
        $.tool_use_block,
        $.tool_result_block
      ),

    system_block: ($) => seq($.system_marker, optional($.inline), optional($.content)),
    user_block: ($) => seq($.user_marker, optional($.inline), optional($.content)),
    assistant_block: ($) => seq($.assistant_marker, optional($.inline), optional($.content)),
    tool_use_block: ($) => seq($.tool_use_marker, optional($.attrs), optional($.content)),
    tool_result_block: ($) => seq($.tool_result_marker, optional($.attrs), optional($.content)),

    system_marker: (_) => marker('system'),
    user_marker: (_) => marker('user'),
    assistant_marker: (_) => marker('assistant'),
    tool_use_marker: (_) => marker('tool_use'),
    tool_result_marker: (_) => marker('tool_result'),

    // Rest of the marker line: first content line (prose kinds) or JSON attrs
    // (tool kinds). state.lua writes attrs after one space, but hand-edited
    // no-space rests are still the same node. prec 3 (over the marker
    // literals): the rest is always literal, even when it is itself a glued
    // marker lookalike.
    inline: (_) => token.immediate(prec(3, /[^\n]+/)),
    attrs: (_) => token.immediate(prec(3, /[^\n]+/)),

    content: ($) => repeat1($._line),
    _line: ($) => choice($.escaped_line, $.text_line),

    escaped_line: ($) => seq($.esc_prefix, optional($.line_text)),
    esc_prefix: (_) => token(prec(2, '%%[[esc]]')),
    line_text: (_) => token.immediate(prec(3, /[^\n]+/)),
    text_line: (_) => /[^\n]+/,
  },
});
