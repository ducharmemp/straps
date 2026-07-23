; Marker and escape-prefix highlighting. The @straps.* captures are linked to
; the same groups syntax/straps.vim uses via HL_LINKS in lua/straps/ui.lua
; (ColorScheme-safe). Prose/tool body highlighting comes from injections.scm.

(system_marker) @straps.marker.system
(user_marker) @straps.marker.user
(assistant_marker) @straps.marker.assistant
(tool_use_marker) @straps.marker.tool_use
(tool_result_marker) @straps.marker.tool_result
(esc_prefix) @straps.esc
