# straps.nvim

A minimal, extensible agent harness for Neovim. In the spirit of the `pi`
agent harness: a small, legible core you can read in an afternoon and reshape
at runtime.

Three invariants:

1. **Buffers are state.** The conversation transcript is a buffer in a
   parseable plain-text format. Every turn, the loop re-parses the buffer to
   build the API messages. Edit history, rewrite the system prompt, delete
   messages — the buffer is canonical.
2. **Everything is late-bound.** Tools, hooks, the provider, and the loop's
   key functions are registry entries stored as Lua source strings, compiled
   on define, and looked up by name at every call site. A redefinition takes
   effect on the very next call, even mid-run.
3. **Agents extend themselves.** The agent has registry introspection and
   `registry_define` as tools. The tool list is rebuilt from the registry on
   every provider call, so a tool the agent defines in turn N is callable in
   turn N+1.

## Requirements

- Neovim >= 0.11
- `curl` on PATH
- An API key for your provider:
  - **Anthropic** (default): `ANTHROPIC_API_KEY` in the environment, or written
    to `$XDG_CONFIG_HOME/straps/api_key` (`~/.config/straps/api_key` by default).
  - **OpenAI** (`provider = "openai"`): `OPENAI_API_KEY`, or written to
    `$XDG_CONFIG_HOME/straps/openai_api_key`.
  - In either case the key file must not be accessible by group/other —
    `chmod 600` it.

No other dependencies. No plenary.

Run `:checkhealth straps` to verify the install — it probes curl, the API key
(including a group/other-readable key file), a writable session dir, the
tree-sitter parser, the `.straps.lua` trust state and the loaded registry, and
runs even when `setup()` never ran. `:help straps` has the full reference.

## Install

With lazy.nvim:

```lua
{
  "matt/straps", -- placeholder; point at wherever this repo lives
  config = function()
    require("straps").setup({
      -- defaults shown; all optional
      model = "claude-sonnet-5",
      -- max_tokens defaults to nil = the model's own max output (else
      -- default_max_tokens); set a number to pin an explicit cap.
      default_max_tokens = 32000,
      max_turns = 128,
      stall_limit = 6,
      max_tool_result_bytes = 100000,
    })
  end,
}
```

`setup()` is idempotent: defaults are registered with `define_default`, which
skips names that already exist, so calling it again never clobbers anything
you (or the agent) redefined at runtime.

## Quickstart

1. `:Straps` opens a session: one ordinary buffer in a split, cursor on the
   trailing `%%[straps:user]%%` marker. There is no separate compose buffer —
   the transcript IS where you type. The window placement follows the standard
   command modifiers, so `:vertical Straps` opens a vertical split and
   `:botright Straps` a full-height one; `:StrapsResume` takes the same
   modifiers.
2. Type your message under that marker — as many lines as you like, normal
   vim editing throughout.
3. Press `<CR>` in normal mode (or run `:StrapsSend`) to send: the loop reads
   the trailing user block and starts a run.
4. While a run is active, the same `<CR>` steers it instead — you're prompted
   for a message that's queued and delivered at the next turn boundary.
5. Non-read-only tool calls prompt for confirmation; answer Yes, No, or
   "Always this tool" (remembered per session buffer). File edits offer
   finer grants instead: "Always in <parent dir>", "Always in this project
   <root>" (when a `.git`/`.jj`/`.straps.lua`/`.hg`/`.svn` marker is found
   above the file), and "Always all edits" — pick the project scope to stop
   re-approving edits directory by directory across the repo.
6. `:StrapsStop` cancels a run in flight; `:StrapsContinue` picks it back up
   (see [Continuing a stopped or interrupted run](#continuing-a-stopped-or-interrupted-run)).

Editing history is a feature, not a bug: the buffer is the canonical state,
so you can revise an earlier message, delete a tool call, or fix a typo
before sending — ordinary vim commands, no special mode.

### Steering

You can talk to a run in flight. Press `<CR>` in the session buffer while a
run is active and you'll get a `steer: ` prompt; `:StrapsSteer fix the tests
first` queues directly without the prompt. Steering messages are queued (in
`vim.b.straps_steering` on the session buffer) and appended to the transcript
as ordinary `%%[straps:user]%%` blocks at the next turn boundary — the buffer
is the request, so the model simply sees them as the latest user message. A
message queued while the model is streaming its final answer still gets
acted on: the loop notices the queue before finishing and makes one more
provider call.

### Continuing a stopped or interrupted run

`:StrapsStop` ends a run; `:StrapsContinue` starts it again where it left
off. There is no run state to save or restore, because the buffer already is
the state: cancellation leaves a well-formed transcript (every `tool_use`
that got appended has a paired `tool_result` — the loop stubs "run cancelled
before this tool executed" for calls it never ran), and the only reason you
can't just press `<CR>` is that the transcript now ends on the assistant-role
`[straps: run cancelled]` note, which no current model accepts as a prefill.
So `:StrapsContinue` appends a user block and sends — `:StrapsContinue focus
on the parser instead` to redirect while resuming, or bare for a generic
"continue where you left off". What restarts is the *run* bookkeeping, not the
conversation: a fresh `max_turns` budget, a fresh stall counter, fresh
blank-turn nudges.

A crash is the harder case. Transcripts persist at block boundaries, so if
Neovim dies while a tool is in flight, the file on disk holds a `tool_use`
whose `tool_result` was never written — and the API rejects an unpaired
`tool_use`, which would make that saved session permanently unsendable.
`:StrapsResume` therefore heals it on open (`state.heal_interrupted`): each
unfinished call gets an `is_error` result reading "run interrupted before this
tool finished", the trailing user block is restored, and it notifies you how
many calls it marked. Healing is deliberately narrow — it only fires when
nothing but tool blocks follows the orphan, which is exactly the shape an
interrupt leaves. A transcript you hand-edited into inconsistency (a
`tool_result` deleted from the middle of a conversation) is left untouched and
still fails loudly on send, because appending a result at the end would not
pair it anyway. And a session with a *live* run is never healed: a tool in
flight looks identical on disk to an interrupted one, and resuming can reach a
running buffer — while a subagent works, the newest saved session is that
child, which is exactly what bare `:StrapsResume` opens — so healing there
would tell the model a tool failed while it was still working, and the real
result would land afterwards.

### Progress

While a run is active, virtual text on the last line of the session buffer
shows the current phase and elapsed time — `⏳ thinking · 12s · receiving ·
<CR> steer · :StrapsStop stop`, or `⚙ bash · 3s · ...` while a tool runs. The
display is just the default `hook.on_progress`; the loop emits events
(`start`, `thinking`, `tool`, `tool_done`, `steer_queued`, `done`) through
that hook, and it also mirrors a short phase string into `vim.b.straps_phase`
for statuslines.

While waiting on the model, the indicator also carries a **liveness** readout
so a long silent prompt looks alive rather than frozen. The elapsed clock
ticks on a local timer regardless of the stream, so on its own it can't tell
"working" from "hung"; the liveness segment instead reflects *actual stream
activity* — the same last-byte signal the idle watchdog uses. A stream that's
alive but producing no visible text (keepalive pings, or extended thinking
that streams with its text omitted) reads `· receiving`; a genuinely stalled
one reads `· silent 8s` with the count growing toward `request_timeout_ms`,
at which point the watchdog ends the run. (This does not surface the model's
reasoning — thinking text is never written into the transcript, so it never
gets fed back into the next request.) To reroute progress somewhere else, redefine the hook:

```lua
require("straps").registry.define({
  name = "hook.on_progress",
  kind = "hook",
  doc = "Progress via vim.notify instead of virtual text.",
  source = [[return function(ev, ctx)
  if ev.type ~= "done" then vim.notify("straps: " .. ev.type .. " " .. (ev.name or "")) end
end]],
})
```

## The transcript format

A session buffer is a sequence of blocks. Each block starts with a marker
line and runs until the next marker:

```
%%[straps:system]%%
You are Cinch, a coding agent...

%%[straps:user]%%
add a linter hook

%%[straps:assistant]%%
I'll look at the registry first.

%%[straps:tool_use]%% {"id":"toolu_01","name":"registry_get"}
{
  "name": "tool.write_file"
}

%%[straps:tool_result]%% {"id":"toolu_01","is_error":false}
return function(input, ctx) ... end

%%[straps:user]%%
```

- Kinds: `system`, `user`, `assistant`, `tool_use`, `tool_result`.
  `tool_use` and `tool_result` markers carry compact JSON attrs.
- The buffer is re-parsed each turn, so **editing history by hand is
  supported**: delete a bad exchange, tweak the system block, rewrite a tool
  result. What you see is exactly what the model gets.
- Content lines that would collide with the marker syntax are escaped with a
  `%%[[esc]]` prefix; the parser strips it. You will rarely see this.
- `tool_use` / `tool_result` blocks are folded closed by default
  (`foldmethod=expr`); open them with `zo` / `zR` as usual. See
  [Navigating a session](#navigating-a-session).

### Rendering

The raw `%%[straps:KIND]%%` markers are the source of truth — parse, persist
and every API request read the real lines. On top of them straps draws a
**display-only** layer (`fn.render`): conceal, extmarks and folds, never a
change to the buffer text or `modified`. Color is *categorical*, not
decorative — a small mark per block type for glance-level pattern recognition,
never a wash or a background tint:

- Each `user` / `assistant` / `system` marker line is concealed and replaced
  by a colored turn rule — `──── you ─────…`, `━━━━ Cinch ━━━━━…`,
  `──── system ─────…` — so the transcript reads as a conversation. The agent
  is named **Cinch**, after the strap that pulls a harness tight. User and
  agent turns read apart at a glance: your rules use the light `─` bar, Cinch's
  use the heavy `━`, and the leading segment + role word take the role's
  color (trailing bars stay dim).
- A `tool_use` + `tool_result` pair folds to **one colored summary line**,
  `▸ <verb> <args>  ✓|✗` (green ✓ / red ✗ from the result's `is_error`) —
  the call rendered command-style by [`fn.tool_display`](#command-style-tool-calls),
  e.g. `▸ $ echo hi  ✓` or `▸ read init.lua  ✓`. Open the fold (`zo`) to see
  the full call inside a card (`╭─ <verb> <args> ─`, a `result` divider, `╰─`).

#### Navigating a session

A long session is a long buffer, so tool machinery folds away and two
navigation mappings step through the conversation. Nothing here is a new
mode — it is ordinary vim motions and folds over the ordinary transcript
buffer.

- **Only the machinery folds**: each `tool_use` + `tool_result` pair, and the
  (long, rarely re-read) system block. The default `foldlevel = 0` shows the
  conversation with tool calls collapsed; `zo` on one opens the full call,
  `zR` opens everything, `zM` closes the tool calls again. Conversation turns
  never fold, so closing a fold never hides an exchange.
- `]]` / `[[` jump to the next / previous turn, counts included (`3]]`), and
  push the jumplist so `ctrl-o` comes back. Tool blocks are never targets — the
  motion steps through the conversation, not the machinery.
- `gO` (the outline key `:help` and `man` already use) loads every turn into
  the session's [findings list](#the-findings-list) as `<role>  <headline>`, so
  you can find an exchange by what it was about: `:lnext` / `:lprev` to step,
  `<CR>` in the list window to jump.

All hues come from the active colorscheme through `hi default link`, so it is
catppuccin now and any scheme later. The groups (override any of them with your
own `hi link`; `default = true` means yours wins):

| group | default link | mark |
| --- | --- | --- |
| `StrapsRoleUser`   | `Function`        | the `you` role tag + leading rule segment |
| `StrapsRoleAgent`  | `Keyword`         | the `Cinch` (agent) role tag + leading rule segment |
| `StrapsRoleSystem` | `Comment`         | the `system` tag (dim) |
| `StrapsTool`       | `Special`         | `⚙` glyph + tool name |
| `StrapsToolOk`     | `DiagnosticOk`    | `✓` on a good result |
| `StrapsToolError`  | `DiagnosticError` | `✗` on `is_error` |
| `StrapsRule`       | `Comment`         | the turn rules |
| `StrapsCardBorder` | `Comment`         | the expanded-tool box art |

```lua
-- e.g. give tool calls a punchier color than Special:
vim.api.nvim_set_hl(0, "StrapsTool", { link = "Constant" })
```

The links are re-established on every `ColorScheme` event (many schemes clear
highlights on load), so a scheme switch keeps its straps colors.

Two knobs, both under `setup{}`:

- `render = true` — master switch. `false` skips the rendering wiring
  entirely: you get the raw markers.
- `tools_expanded = false` — set `true` to fold tool calls open by default
  (`foldlevel = 99` instead of the default `0`).

**Getting the raw markers back** without disabling anything: `:set
conceallevel=0` in the session window reveals the real marker lines under the
overlays. Because `fn.render` is an ordinary registry entry, you can also
reshape the whole presentation with `:StrapsEdit fn.render` and `:w`, or
redefine it to a no-op (`return function() end`) to turn it off at runtime.

#### Command-style tool calls

A tool call reads as an *action*, not a data blob: instead of showing the raw
JSON input, both the folded summary and the open card render the call as a
command line via `fn.tool_display(name, input) -> string`. `bash` becomes a
shell line (`$ echo hi`), reads/writes/greps become terse verbs. The caller
splits the string on its first space — the leading token (the verb) is the
colored mark (`StrapsTool`), the rest (the args) is dim (`StrapsRule`) — so a
`bash` call reads as a colored `$` prompt with a dim command, honoring the
"color on marks only" rule. The builtin formatters:

| tool | renders as |
| --- | --- |
| `bash` | `$ <command>` (first line; ` ⏎…` appended if multi-line) |
| `read_file` | `read <path>` (`:<offset>+<limit>` when set) |
| `write_file` | `write <path> (<N> lines)` |
| `edit_file` | `edit <path>` |
| `glob` | `glob <pattern>` |
| `grep` | `grep "<pattern>"` (` <path>` when set) |
| `registry_get` | `registry get <name>` |
| `registry_list` | `registry list [<kind>]` |
| `registry_define` | `define <name> (<kind>)` |
| `eval_lua` | `lua <code first line>` |
| *anything else* | `<name> <compact input preview>` |

Every branch guards against a missing or mis-typed input and falls back to the
default preview, so the display never errors. `fn.tool_display` is an ordinary
registry entry: `:StrapsEdit fn.tool_display` (and `:w`) to add a formatter for
a tool the agent defined, or to change the style — the next render picks it up.

### Syntax highlighting and markdown rendering

Transcript highlighting has two engines, chosen per buffer by whether the
`straps` tree-sitter parser (`tree-sitter-straps/`) is installed:

- **Parser absent**: the legacy regex syntax file (`syntax/straps.vim`),
  exactly as before.
- **Parser present**: `ftplugin/straps.lua` starts tree-sitter highlighting
  instead. The transcript's language tree then carries real **markdown** trees
  for prose blocks and **JSON** trees for tool bodies (`queries/straps/`), so
  fenced code in an agent reply gets its language's own highlighting, and any
  language-tree-driven markdown renderer lights up on the transcript with no
  straps involvement. The grammar is display-only — parsing for API requests
  is `state.lua` in both cases, and the buffer text is never touched.

  The markdown parsers ship with Neovim; a **json** parser does not, and
  without one tool bodies render plain. The Nix package ships `json.so`
  alongside the straps parser; elsewhere `:TSInstall json` (or your existing
  json parser) covers it.

Installing the parser:

- **Nix**: nothing to do — the flake's plugin package ships
  `parser/straps.so`. (It is also exposed as `packages.<system>.tree-sitter-straps`.)
- **nvim-treesitter** (`master` branch API; the `main` rewrite changed how
  parsers register — use the manual compile there): register it, then
  `:TSInstall straps`:

  ```lua
  require("nvim-treesitter.parsers").get_parser_configs().straps = {
    install_info = {
      url = "https://github.com/matt/straps", -- wherever this repo lives
      location = "tree-sitter-straps",
      files = { "src/parser.c" },
    },
  }
  ```

- **Manually**: compile the committed C and drop it on your runtimepath:

  ```sh
  mkdir -p ~/.local/share/nvim/site/parser
  cc -shared -fPIC -O2 -I tree-sitter-straps/src \
     tree-sitter-straps/src/parser.c -o ~/.local/share/nvim/site/parser/straps.so
  ```

For rendered markdown (headings, bullets, code-block backgrounds) install
[render-markdown.nvim](https://github.com/MeanderingProgrammer/render-markdown.nvim)
(or any renderer that walks the language tree) and enable it for the `straps`
filetype. The `win_options` below matter: the plugin resets window options
from the **global** defaults when leaving rendered mode, which would otherwise
reveal the raw `%%[straps:...]%%` markers while you type — these values
reproduce what straps sets for its session windows:

```lua
require("render-markdown").setup({
  file_types = { "straps" },
  win_options = {
    conceallevel = { default = 2, rendered = 3 },
    concealcursor = { default = "nc", rendered = "nc" },
  },
})
```

### Long sessions

The transcript IS the request: every turn re-parses the whole buffer, so a
long session grows the context sent to the API on each call. To prune, just
delete old `tool_use` / `tool_result` blocks (or whole exchanges) — it's
just a buffer, and the next turn sends exactly what remains. To *read* one,
`zM` collapses it to a list of exchanges and `gO` outlines it into the findings
list (see [Navigating a session](#navigating-a-session)). `max_turns`
caps the number of turns in a single run; a run that hits the cap says so
in the transcript (`[straps: stopped after N turns ...]`) and stops —
sending another message continues from where it left off.

### Caching and compaction

Prompt caching is on by default (`cache = true`). Each request places up to
four `cache_control: {"type": "ephemeral"}` breakpoints (Anthropic's maximum):
one on the last tool definition (so a fresh session can reuse the cached tool
prefix even though its system block embeds a new date/cwd/git state), one on
the system prompt (covering the tools+system prefix within a session), one on
the last content block of the last message, and — only on long conversations —
a fourth, intermediate marker ~15 content blocks back. That fourth breakpoint
keeps tool-heavy turns inside the server's ~20-block cache lookback window: a
single busy turn can add more than 20 blocks, and with only the tail marked
the previous turn's cache would fall out of range and silently miss. Together
they mean the transcript prefix replayed every turn extends the previous
turn's server-side cache instead of being reprocessed at full price. This is observable, not vibes: with
`config.log_file` set, `fn.log` response events include `input_tokens`,
`output_tokens`, `cache_read_input_tokens` and
`cache_creation_input_tokens` — in a warm session most input lands under
`cache_read_input_tokens`.

Self-extension is cache-friendly by construction. Tools are sent in
**registration order** (append-only), not alphabetically: a tool the agent
defines mid-session lands at the END of the list, so the existing tools
prefix still hits the cache — the server checks backward from each
breakpoint for the longest previously cached prefix. Only *redefining* an
existing tool's description or schema invalidates from that tool's position
onward, and redefining hooks or fns (the common self-extension: linter
hooks, confirm policy, the provider itself) never touches the request
prefix at all. `registry.dump()` preserves this ordering across restores.

For sessions with a human in the loop, consider `cache_ttl = "1h"`: the
default cache lives ~5 minutes, and reading a diff or thinking between
messages routinely exceeds that, turning your next message into a full
re-read. The 1-hour TTL costs more per write (2x vs 1.25x base input price)
and pays for itself after about three requests on the same prefix. No beta
header needed; ignored by servers without caching.

Compaction is editing, because the transcript IS the context.
`:StrapsCompact` calls `fn.compact`, whose default is mechanical, free and
deterministic: it keeps the system block, every user message, all assistant
text, and everything in the last `compact_keep_turns` assistant turns, then
shrinks older `tool_result` contents to a one-line
`[compacted: was N bytes] ...` stub and older bulky `tool_use` inputs to
`{}`. Blocks are never removed, so parsing, role alternation and tool
pairing stay intact.

Set `auto_compact_tokens` to compact automatically near your model's context
limit. This threshold, not `auto_compact_bytes`, is the one to reach for: with
caching on, a long transcript is already cheap (the unchanged prefix comes
back as a cache read at ~10% price each turn), so compaction is a
context-**window** tool, not a cost tool. Every compaction rewrites old
message blocks and so invalidates the whole messages cache tier on the next
request (tools and system survive), which you then pay to re-write once —
worth it only if the session keeps going long enough afterward to recoup that
through cheaper reads of the smaller prefix. So the trigger is deliberately
coarse: it fires near the limit, and a growth guard stops it re-running every
turn. `auto_compact_bytes` remains as a raw-size alternative. Watch it in
`fn.log`: a `compact` event, then one `cache_creation` spike, then `cache_read`
resuming at the smaller size.

Since `fn.compact` is just a registry entry, you can redefine it — a sketch
(not a drop-in) of an LLM-summarizing version:

```lua
require("straps").registry.define({
  name = "fn.compact", kind = "fn", doc = "LLM-summarizing compaction (sketch).",
  source = [==[
return function(bufnr, ctx)  -- run it from a tool so you have a live ctx
  local state = require("straps.state")
  local parsed = state.parse(bufnr)
  -- Cache tip: this provider call is a fork of the live session. Let the
  -- default fn.provider build system+tools as usual (it reuses the session's
  -- cached tools+system prefix), and pass no tools of your own — that keeps
  -- the summarization call itself a cache hit on everything but the tail.
  local resp = require("straps.registry").call("fn.provider", {
    system = "Summarize this conversation compactly; keep decisions and file paths.",
    messages = parsed.messages,
  }, ctx)
  -- ...rewrite the buffer: system block + summary as a user block +
  -- the last few turns verbatim; return a short summary string...
end
]==],
})
```

### Context surgery: the agent excising its own dead ends

`fn.compact` shrinks by age. `transcript_excise` lets the agent shrink by
*judgment* — pointing at the specific blocks that were a side quest or a wrong
path and taking them out of its own context window, mid-run. Same substrate:
the transcript buffer IS the request, re-parsed every turn, so a block excised
now stops being replayed from the next turn onward. The 40k tokens of a dead
exploration leave; the conclusion the agent wrote in its reply text stays.

It runs in two modes. Called with nothing, it lists the transcript's blocks —
number, kind, byte size, snippet, and what is locked — which is read-only and
needs no confirmation. Called with `blocks`/`range` plus a required `note`, it
replaces those blocks' contents with a one-line receipt and prompts for
confirmation like any write. With `session = <handle from spawn>` a parent does
it to a child, including a *running* one.

The safety properties are structural, not policy:

- **It cannot fabricate.** The only text the tool can write is
  `[excised: was N bytes — <note>]` (a `{"_excised": ...}` JSON stub for a
  `tool_use` input). There is no parameter for arbitrary replacement text, so
  an unmarked invented "observation" cannot be implanted — in itself or in a
  child. The human reading the transcript always sees what was removed and why.
- **It cannot delete a block**, only empty one, so tool_use/tool_result pairing
  and role alternation — everything the API requires — survive by construction.
- **It cannot touch the system block, or the turn in flight** (everything from
  the last `assistant` block on, which is where its own call lives).
- **It is one undoable step**: `undo_edit` on the transcript reverts a surgery
  as a unit, and the transcript is file-backed, so the receipt and the reversal
  both persist.

## Project registry: `.straps.lua`

A `.straps.lua` at the project root gives registry investments a place to
survive the session. It is plain Lua — a sequence of
`require("straps.registry").define{...}` calls; `registry.dump()` output is
valid content. When a session opens, straps finds the nearest `.straps.lua`
upward from the working directory and, if it is trusted, executes it — so
project-specific tools and hooks exist before the first request, appended
after the builtins (append-only, cache-friendly).

The trust model is direnv-style: the first time a `.straps.lua` is found,
and any time its content changes, straps prompts for confirmation before
executing it (defaulting to No — review the file first). Confirming records
the file's content hash in `stdpath("data")/straps/trusted.json`; the same
content then loads silently, and any edit makes it untrusted again.
Untrusted content is never executed silently, and the same content executes
at most once per Neovim session.

Save-back convention: when the agent builds something worth keeping — a
`tool.run_tests` for this repo, a linter hook — ask it to persist the
improvement. It renders the entry with `registry_get` (whose output is an
executable `define{...}` chunk) and appends that to `.straps.lua`; the file
write goes through the normal confirm, and you re-trust the changed file on
its next load.

An example `.straps.lua`:

```lua
require("straps.registry").define{
  name = "tool.run_tests",
  kind = "tool",
  doc = "Run this repo's test suite. Optional path: only tests under it.",
  input_schema = { type = "object", properties = { path = { type = "string" } } },
  source = [[return function(input)
    local cmd = input.path and ("make test TESTS=" .. input.path) or "make test"
    return vim.fn.system({ "bash", "-lc", cmd })
  end]],
}
```

## Skills — knowledge, not capability

A fourth entry kind, `skill.NAME`, stores prose instead of code: `source`
is the text itself (no Lua), `doc` is a one-line load trigger. An
extension — a tool, hook or fn — is capability: the agent defines one when
it needs to become more capable at doing something. A skill is knowledge:
it defines one when it learned something worth knowing next time — a
procedure discovered the hard way, an API whose real behavior contradicts
its docs.

Skills cost one listing line each in the system prompt (a `# Skills`
section, present only when skills exist); the body loads on demand via the
`skill` tool. They follow the same lifecycle as every other entry:
session-scoped by default, persisted by appending their `registry_get`
rendering to `.straps.lua`.

Two skills ship as builtins: `skill.showing_user`, the full presentation
guidance behind the core prompt's short `# Showing the user` stub (loaded
before building a hand-off view — findings lists, diff splits, live UI
components), and `skill.multiplayer`, the protocol for working alongside
another agent in the same Neovim (see [Agents that know about each
other](#agents-that-know-about-each-other)). Like every default they are
`define_default`'d, so your own redefinition of either survives `setup()`.

```lua
require("straps.registry").define{
  name = "skill.release_process",
  kind = "skill",
  doc = "Load before cutting a release.",
  source = [[1. bump the rockspec version FIRST (make dist reads it)
2. run `make dist` — plain make skips the manifest
3. tag only after CI is green: `git tag vX.Y.Z && git push --tags`]],
}
```

## Picking model, effort and provider

`:StrapsModel` and `:StrapsEffort` open a picker (uses `snacks.nvim`'s
`Snacks.picker.select` when installed, otherwise falls back to plain
`vim.ui.select`) over the model / effort list — no restart or reconnect
needed, since both are read fresh on every provider call.

**Picking the provider.** `:StrapsProvider` opens the same picker over the
backends — `anthropic` (the Anthropic Messages API) and `openai` (OpenAI Chat
Completions). Run it **on a session buffer** and it scopes the choice to that
session (`vim.b straps_provider`), like `:StrapsModel`. Run it anywhere else
and it sets the global default **and persists it** to
`$XDG_CONFIG_HOME/straps/provider` (`~/.config/straps/provider`, the same
directory as the API key files) — so the choice survives Neovim restarts.
`fn.provider` resolves, in order: `vim.b straps_provider` →
`config.provider` (when pinned in `setup{}`) → that file → `anthropic`.
Setting `provider` in `setup{}` pins it and wins over the file.

**Per-session model and effort.** Selection is scoped to the buffer you run
it on: invoke `:StrapsModel` / `:StrapsEffort` **on a session buffer** and it
sets that session's model/effort only (stored in `vim.b`, read by
`fn.provider` in preference to the global config) — so you can run Opus in
one session and a cheap model in another at the same time. Anthropic and
OpenAI session model overrides are separate (`b:straps_model` vs
`b:straps_openai_model`), so switching provider never reuses the other
provider's id. Invoke it anywhere else and it sets the provider-specific
global model (`config.model` or `config.openai_model`) / `config.effort`
default for new sessions. A subagent inherits its parent session's provider
and matching model override by default, and `spawn` takes explicit `provider`,
`model`, and `effort` args to override that. The active model/effort shows
in a window-local **winbar** on each session window (a trailing `*` marks a
session that diverges from the global default); set `config.session_winbar =
false` to hide it, or drop `%{%v:lua.require'straps.ui'.session_status()%}`
into your own statusline.

**The agent is told too.** The winbar informs *you*; `fn.model_note` informs
the model. Each turn, the loop appends a `# Model` section to that request's
system text naming the session's effective provider/model/effort — resolved
fresh per request, so retargeting a session mid-run with the pickers is
reflected on the very next turn. The note rides the request only: it is never
written into the transcript, so the buffer stays exactly the conversation.

Knowing its own model is half the decision; the **`models` tool** is the other
half. It lists the active provider's catalog — each id exactly as `spawn`'s
`model` argument takes it, with the capability/cost label from `config.models`
("most capable, slowest", "fastest, cheapest"), the context window, and the
effort names — marking the session's active model. Without it an agent has to
recall an id from training data, and a wrong guess is a 400 on the child's first
request. Read-only and auto-allowed; it reads the configured/discovered catalog
rather than making a network call, so `:StrapsModel` is still what refreshes it. This exists because a model
that cannot see its own capability cannot choose a subagent's: the note also
carries the reminder that `spawn` inherits the parent's model and effort unless
given explicit ones, so mechanical work can go to a cheaper child. A static
prompt line could not do this job — the system block is written once at session
creation, and `spawn` composes a child's prompt before stamping its model.

The same winbar also shows **live token usage** once the first response
arrives — the context fill (e.g. `47.0k/200k (24%)`) and the cache hit rate
(`cache 91%`), read from the last turn's `usage` on `vim.b.straps_usage`. The
context window comes from the active provider's model-list `context` field
(`config.models` or `config.openai_models`), or `config.context_window` as a
fallback; an unknown model with neither shows the raw token count.
`ui.usage_status()` is available for a manual statusline too, and
`ui.session_info()` hands you the same numbers unformatted (see
[Statusline](#statusline)).
The real token count also drives auto-compaction (`config.auto_compact_tokens`)
instead of a byte estimate.

**OpenAI effort is opt-in per model and omitted when tools are present.** Some
OpenAI models reject `reasoning_effort`, so straps does not send it merely
because `config.effort` is set. Add `reasoning = true` (or
`reasoning_effort = true`) to the matching `config.openai_models` entry when
that OpenAI model accepts the field; then the active `config.efforts` entry's
`level` is sent as `reasoning_effort` only on requests without function tools.
Untagged OpenAI models and tool-bearing requests receive no effort parameter.

`:StrapsModel` performs **live model discovery**: it queries `GET
/v1/models` (via `fn.list_models`) against **the backend you're actually
using** — it resolves the effective provider the same way `fn.provider`
does, so under the OpenAI provider you see GPT models, not Claude ones. It
merges the result over the provider-specific seed/cache (`config.models` for
Anthropic, `config.openai_models` for OpenAI), so the menu reflects what your
account can actually use; new models appear without a config edit. Your
hand-curated `label`s win; live-only models are appended (Anthropic supplies
a display name and a `thinking` tag inferred from its capabilities so
extended thinking still works; OpenAI's catalog has neither, so the id is the
label). If discovery fails (offline, bad key), it notifies and falls back to
the matching static list — the picker never breaks. The merged list is
written back to that provider's cache.

`:StrapsResume!` (bang) opens the same picker over
`state.list_sessions()` (newest first) and resumes whichever `*.straps`
transcript you pick — handy when you don't remember the exact name
`:StrapsResume <Tab>`-completion would need. No saved sessions falls back
to opening a fresh one, same as bare `:StrapsResume`.

Because a transcript's filename is only a timestamp, sessions are hard to
tell apart by name — so the picker identifies them by *content*. Each row
in `list_sessions()` carries a `summary`: the session's durable title if
one is set (`:StrapsRename`, stored in a companion `<transcript>.meta`
JSON file — the transcript itself stays pristine), otherwise the first
user prompt read straight off disk with no buffer load
(`state.session_summary`). The picker shows that plus a relative age
("2h ago", "3d ago", an absolute date past a week), and with snacks.nvim
present it fuzzy-matches the rows and previews the transcript live
(`ui._pick_session_rich`, overridable). `:StrapsSearch {pattern}` grep
the conversation content of every transcript (ripgrep, else `:vimgrep`;
transcript scaffolding skipped) into the quickfix list, so you can find a
session by what was *said* in it, not its name.

Extended thinking is model-generation-dependent, so `config.models` tags
each entry with which mechanism it speaks (`thinking = "adaptive"` or
`"budget"`; see the Configuration table below) and `fn.provider` sends the
matching shape for whatever `config.effort` names in `config.efforts`. An
unlisted or custom `config.model` gets no thinking block at all — safer
than guessing wrong and getting a 400.

```lua
require("straps").setup({
  models = {
    { id = "claude-opus-4-8", label = "Opus 4.8", thinking = "adaptive" },
    { id = "claude-sonnet-5", label = "Sonnet 5", thinking = "adaptive" },
  },
  efforts = {
    { name = "off" },
    { name = "high", level = "high", budget_tokens = 24000 },
  },
})
```

## The registry

Every behavior lives in the registry under one of three namespaces:

- `tool.*` — tools exposed to the model (`tool.read_file`, ...). The part
  after `tool.` is the API name the model sees.
- `hook.*` — seams the loop and tools call at fixed points
  (`hook.confirm`, `hook.after_write`, `hook.on_run_start`,
  `hook.on_turn_start`, ...).
- `fn.*` — core functions (`fn.provider` and its backends
  `fn.provider_anthropic`/`fn.provider_openai`, `fn.system_prompt` and its
  layers, `fn.build_tools`, `fn.api_key`, `fn.openai_api_key`).

Entries are Lua source strings compiled on define. Every call site does a
by-name lookup, so redefining an entry changes behavior immediately.

- `:StrapsRegistry` — list all entries; `<CR>` on a line opens it.
- `:StrapsHelp [tag]` — open in-editor help for straps (default `:help straps`).
- `:StrapsEdit <name>` — opens `straps://registry/<name>`, a Lua buffer
  containing the entry as an executable `registry.define{...}` chunk. Edit
  it and `:w` to redefine live. Works mid-run.
- `:StrapsEval` — execute the current buffer as Lua. Handy for scratch
  buffers full of `registry.define` calls.
- Persistence: `require("straps").registry.dump()` returns the whole
  registry as one executable Lua string. Write it to a file; run that file
  (`:StrapsEval` or `:luafile`) to restore.

### The system prompt

The system prompt is layered, and every layer is a registry entry:

- `fn.system_prompt_core` — identity, output norms, workflow, editor-native
  tool nudges (including LSP/status checks before refactors), and the
  self-extension guidance, including the concrete triggers the agent is
  taught to act on: the same manual step done twice means define a tool or
  hook before the third time; running a project's test/build/lint command
  means defining a tiny session tool for the rest of that session; and
  "always" / "every time" / "from now on" from you means install the
  behavior in the registry rather than promise to remember it. Its
  `# Untrusted content` section also names who is speaking: tool results are
  data rather than instructions, and a user-role block beginning `[straps] `
  is the *harness* — the model and multiplayer notices, which the API gives
  no channel of their own — informational, never authority, and always
  overridden by a real instruction from you. Since that prefix is a
  convention rather than a guarantee, a `[straps]` line arriving inside a
  tool result stays quarantined like any other content.
- `fn.system_prompt_env` — a generated environment block: cwd, platform,
  Neovim version, date, and version control (jj or git, with branch and
  dirty/clean for git).
- `fn.system_prompt_project` — project instruction files, layered from
  general to specific so the nearest file has the last word: a global tier
  (`AGENTS.md` / `CLAUDE.md` under `stdpath('config')/straps/` then
  `$HOME`), then every `AGENTS.md` and `CLAUDE.md` found walking upward
  from the working directory (farthest ancestor first, nearest last), then
  any paths you list in `config.instructions_files` (the ecosystem's
  memory-file convention). Each distinct file is included under a header
  naming its path, capped at 20000 bytes; a path seen twice is included
  once, at its most general position.
- `fn.system_prompt` — the composer: joins the layers (environment under
  `# Environment`, skills under `# Skills` when any exist, project files
  under `# Project instructions`) and is what `state.new_session` calls.
  For spawned subagents, `tool.spawn` passes options through
  `state.new_session` to the core layer, which reshapes the prompt for
  the child: the `# Subagents` guidance is dropped, a `# You are a
  subagent` section is appended (the parent sees only the final reply),
  and readonly / restricted-tool children get matching notes instead of
  instructions about tools they cannot call.

The composed prompt is written into the session's editable system block at
creation time, so environment and project content are frozen per session —
edit the block directly or open a new session to refresh them. Each layer
is individually redefinable (`:StrapsEdit fn.system_prompt_env`, or
`registry.define` in your config); because the composer looks the layers up
through the registry at call time, a redefined layer takes effect for the
next new session.

## Worked example: a linter hook

`tool.write_file` and `tool.edit_file` both fire `hook.after_write` with the
path just written. This is the canonical seam for "always do X after writes".

**By default it already does something useful:** after the agent writes a
file, the hook waits briefly for the attached language server to re-lint it and
appends any ERROR/WARN diagnostics to the tool result — so the agent sees
breakage it just caused, from the editor's own LSP, without being asked. A
write the agent makes comes back as e.g.:

```
wrote lua/straps/loop.lua (12 lines) — undo with u in the buffer
diagnostics after write (1):
lua/straps/loop.lua:312:9: ERROR undefined global 'tool_block' [lua_ls]
```

Turn it off with `after_write_diagnostics = false` in `setup()`, cap the wait
with `after_write_diagnostics_ms`, or replace it entirely — the rest of this
section shows redefining it to run an external linter instead.

### Version 1: ask the agent to do it

Type in a session:

> from now on, after every file write, run ruff on the file and show me the
> output

The agent knows (from its system prompt) that hooks are registry entries, so
it makes a `registry_define` tool call roughly like:

```json
{
  "name": "hook.after_write",
  "kind": "hook",
  "doc": "Run ruff on every written file, return its output.",
  "source": "return function(path, ctx)\n  local out = vim.system({ \"ruff\", \"check\", path }):wait()\n  return \"ruff:\\n\" .. (out.stdout or \"\") .. (out.stderr or \"\")\nend"
}
```

You approve the `registry_define` call once; from that point every write
appends ruff output to the tool result the agent sees. No re-prompting, no
"remember to lint" — the behavior is installed.

### Version 2: do it yourself in config

```lua
require("straps").setup()

require("straps").registry.define({
  name = "hook.after_write",
  kind = "hook",
  doc = "Run ruff on every written file, return its output.",
  source = [==[
return function(path, ctx)
  local out = vim.system({ "ruff", "check", path }):wait()
  return "ruff:\n" .. (out.stdout or "") .. (out.stderr or "")
end
]==],
})
```

Define it after `setup()`: `define` overrides the default no-op, and because
`setup()` uses `define_default`, restarting or re-running setup will not put
the no-op back on top of yours within a session.

## Redefining the provider

`fn.provider` is a **dispatcher** that selects a backend, in order:
`vim.b[bufnr].straps_provider` (per session) → `config.provider` (when set in
`setup{}`) → the choice persisted by `:StrapsProvider`
(`~/.config/straps/provider`) → `"anthropic"`. The backends are `"anthropic"`
(`fn.provider_anthropic`, the Anthropic Messages API) and `"openai"`
(`fn.provider_openai`, OpenAI's Chat Completions API — different auth header,
request/response shape and streaming format, translated to and from the same
internal block shape). Pick it with `:StrapsProvider`, pin it in
`setup{ provider = "openai" }`, or flip one session with
`vim.b[bufnr].straps_provider`. The OpenAI backend reads `fn.openai_api_key`
(`$OPENAI_API_KEY`, then `$XDG_CONFIG_HOME/straps/openai_api_key`), posts to
`config.openai_base_url`, and uses `config.openai_model` as the model id
(default `"gpt-5"`; it intentionally does not fall back to the Anthropic
`config.model`).

Each backend is itself a plain registry entry. To point one at a proxy,
`:StrapsEdit fn.provider_anthropic` (or `_openai`), change the endpoint, `:w`:

```lua
-- inside the entry's source, change:
local url = "https://api.anthropic.com/v1/messages"
-- to:
local url = "https://my-proxy.internal/v1/messages"
```

The next provider call — even the next turn of a run already in progress —
uses the new definition. `fn.api_key` / `fn.openai_api_key` are likewise
entries; the defaults try the env var, then
`$XDG_CONFIG_HOME/straps/{api_key,openai_api_key}` (refused unless `chmod 600`)
— redefine either if your key comes from somewhere else.

## Builtin tools

| Tool | Description |
| --- | --- |
| `read_file` | Read a file through its live Neovim buffer with numbered lines (offset/limit, capped ~2000 lines), so unsaved edits are visible just like edit/write paths. |
| `write_file` | Write a file (creates parent dirs) through its buffer, so the write enters the file's native undo history — revert with `u` / `:earlier` / undotree; fires `hook.after_write`. |
| `edit_file` | Exact-string replacement applied through the file's buffer as one undoable step (revert with `u` / undotree); matches against the live buffer, so unsaved edits are seen; fires `hook.after_write`. |
| `patch_file` | Structured line-range hunks (`start_line`, `end_line`, `new_text`, optional `expected_old_text`) applied through the live buffer as one undoable patch; use when ranges are known and exact-string matching is awkward. |
| `path_info` / `tree` | Bounded filesystem metadata and directory-tree inspection without shelling out. |
| `fetch_url` | Safe bounded http(s) fetch via curl: no ambient credentials, timeout/byte cap, optional redirects. Refuses internal/loopback/link-local hosts (SSRF guard) and pins redirects to http(s). |
| `bash` | Run a shell command via `bash -lc`; returns exit code, stdout, stderr, and kills output floods after a bounded per-stream capture. |
| `run_in_terminal` | Run a visible streaming `:terminal` command for long/interesting builds or tests. |
| `run_quickfix` | Run a build/test/lint command and parse its output into the session's findings list via native `errorformat`; returns a compact exit-code + parsed-locations summary. |
| `glob` | Expand a glob pattern (capped at 500 entries). |
| `grep` | Search file contents (`rg` if available, else `grep -rn`); also populates the session's findings list. |
| `bulk_replace` | Substitute across the session's current findings list via `:ldo`/`:cdo` (undoable, confirm-gated, supports `dry_run`). |
| `registry_list` | List registry entries: name, kind, doc, version. |
| `registry_get` | Return an entry's full definition as executable Lua. |
| `registry_define` | Define or redefine any registry entry. Tool API names are validated before they can reach a provider request. The self-extension tool. |
| `skill` | List/load prose knowledge entries (`skill.*`), distinct from capability entries (`tool.*`, `hook.*`, `fn.*`). |
| `eval_lua` | Execute Lua inside Neovim; returns `vim.inspect` of the results. |
| `help_search` | Search in-editor `:help` tags and excerpt the best match; use before writing Lua against Neovim APIs. |
| `spawn` / `spawn_wait` | Launch subagents in their own session buffers and collect their final answers. |
| `models` | List the models available to this session — ids for `spawn`, capability/cost labels, context windows, effort names — so a subagent's model is a choice rather than an inherited default. |
| `transcript_excise` | Context surgery: list the transcript's blocks, or excise a side quest / wrong path out of the agent's own context window (or a child's), leaving a visible receipt. |

`write_file`, `edit_file`, and `patch_file` apply their change through the
target file's buffer (loaded or reused if already open) and then write that
buffer, so every agent edit lands in the file's native undo history — you revert
it with `u`, `:earlier`, or undotree, right alongside your own edits, and an edit
to a file you have open with unsaved changes stacks on top of those changes
instead of clobbering them.

When agents compete — another Neovim instance or external process writes the
file on disk, or a concurrent session in the same Neovim edits the shared
buffer — the edit tools fail with an error that says so (naming the sibling
session and its task when it is one), telling the agent to re-read and reapply;
reads get a prepended note instead. Your own hand-edits are exempt: stacking on
your unsaved changes remains the behavior above, not a conflict.

### Editor-native tools

These use the editor straps lives in — its LSP clients and tree-sitter
parsers — instead of shelling out. Most are read-only (auto-allowed by
`hook.confirm`) and degrade to a clear message rather than erroring; applying a
`fix_diagnostic` action is a write and is confirm-gated.

| Tool | Description |
| --- | --- |
| `diagnostics` | LSP/linter diagnostics for a file (or all loaded buffers) as `file:line:col: SEVERITY message [source]`; `quickfix=true` loads them into the findings list. |
| `diagnostic_at` / `diagnostic_next` / `fix_diagnostic` | Position-oriented diagnostic helpers: inspect the diagnostic under a location, find the next/previous diagnostic, or list/apply diagnostic-specific fixes. |
| `lsp_status` | Report whether an LSP client is attached/enabled for a file, including common supported methods. |
| `declaration` / `definition` / `type_definition` / `implementation` | Navigate from `{path, line, col}` (1-based) via the attached LSP client; returns `file:line:col`, with `quickfix=true` to load locations into the findings list. |
| `references` | All references to the symbol at `{path, line, col}` via the attached LSP client; deduped/sorted `file:line:col`, with `quickfix=true` support. |
| `workspace_symbols` | Project-wide LSP symbol search; can also populate the findings list. |
| `hover` | Type/documentation hover text at a position. |
| `symbols` | Document outline of a file: `name  kind  L<start>-<end>` per symbol. |
| `tree_sitter_status` / `node_at` / `read_node` | Parser, node, parent-chain, and enclosing-source introspection for agent investigations of syntax structure without requiring an LSP server. |
| `read_symbol` | Read the source of a named function/class from a file (a targeted read, numbered like `read_file`). |

The LSP tools (`declaration`, `definition`, `type_definition`,
`implementation`, `references`, `hover`, `workspace_symbols`, and the fallback
in `symbols`) need an attached LSP client for the file's filetype; they wait
briefly for one to attach, bound every request with a timeout so a wedged server
can't hang a run, and fall back gracefully (a tags lookup where useful, then a
clear "no LSP client" message) when none is available. `lsp_status` is the quick
probe when the agent needs to know whether Neovim has a server for a file. The
tree-sitter tools (`symbols`, `read_symbol`) work with no server at all — they
parse the buffer directly and cover common languages, degrading to a clear
message for filetypes with no parser.

Alongside these, a few editor-native tools WRITE and so go through
`hook.confirm` like `write_file`/`edit_file`: `rename_symbol` (semantic
rename via `textDocument/rename`), `code_action` (list, then apply by index),
`format`, and `move_file`/`delete_file` — moves/renames or deletes a file on
disk, and when an LSP client is attached and supports the relevant
`workspace/will*Files` request, asks it first for a `WorkspaceEdit` fixing up
references elsewhere (e.g. import paths) before the filesystem change. Server
edits are guarded to stay under the current working
directory, applied through each touched buffer's native undo, and saved only
after the filesystem operation succeeds; the server is then notified via
`workspace/didRenameFiles`. The move itself goes through
`vim.lsp.util.rename`, so an open buffer on
the file is renamed in place (undo history intact) rather than orphaned.
No attached/capable server: a plain filesystem move, never an error.
`move_files` is the bulk form — one call, an array of `{from, to}` pairs.
The whole batch is validated up front (every source exists, every
destination is free, no path reused) and nothing moves if any entry is
invalid, so a single typo in a large batch can't leave a partial move.
Files sharing a capable LSP client are sent to that server in ONE batched
`workspace/willRenameFiles` request rather than one request per file.
`delete_files` is the bulk delete form, with the same whole-batch validation and
batched LSP notifications; deletion is intentionally not undo-tree reversible,
so it refuses files with unsaved buffer changes.

### Presentation tools

The editor is straps's display surface, so a few tools hand the user a real
Neovim view instead of flattening everything into transcript prose. All three
change no files — they open views or set the findings list — and so are
auto-allowed by `hook.confirm`, like `show_user`. They never steal focus.

| Tool | Description |
| --- | --- |
| `show_diff` | Open a real side-by-side **diff split** (`:diffthis`, native hunk highlighting). Either `{path, content}` to preview proposed contents against a file's current state, or `{left, right, filetype?}` to compare two arbitrary texts. |
| `show_buffer` | Open a **filetype'd scratch split** for generated or extracted content — a report, a table, sample code — so it arrives syntax-highlighted and searchable. `{content, filetype?, title?, split?}`. |
| `set_findings` | Load an agent-assembled list of `{path, line?, col?, text?}` locations into the **findings list** (see below) and open it. For findings you built yourself; `grep` and `run_quickfix` already fill the list for searches and build output. |

These are the tools behind the system prompt's guidance to match the medium to
the data's shape (a diff for two versions, a scratch buffer for a report, the
findings list for many locations) — the agent now has a tool for each instead
of hand-building the view with `eval_lua`.

### The findings list

straps wires its search tools into Neovim's own list machinery — a location
list per session, with the quickfix list as fallback — so results are
navigable with `:lnext`/`:lprev` (or `:cnext`/`:cprev`) and editable in bulk
with native Vim machinery.

**Per-session isolation.** The quickfix list is *global* to a Neovim instance,
so if straps wrote every session's findings there, two concurrent sessions
would stomp each other — and `bulk_replace`, which acts on "the current list",
could edit another session's files. To prevent that, each session routes its
findings to **its own window's location list** (which is per-window) when the
session is on-screen, falling back to the global quickfix list only when the
session has no window (e.g. a background subagent). So `grep`/`bulk_replace` in
one session never touch another's set. On-screen you navigate with
`:lnext`/`:lprev` (the location-list twins of `:cnext`/`:cprev`); the tool
results name whichever applies.

- **`grep` populates the findings list.** Every `grep` also loads its matches
  into the session's findings list (title `straps: grep <pattern>`) as a side
  effect — the returned text summary is unchanged. Jump through the hits with
  `:lnext`/`:cnext`. A search that genuinely matches nothing clears the list; a
  transient failure leaves any existing list untouched.
- **`diagnostics` can too.** Call it with `{ quickfix = true }` to also load the
  reported diagnostics into the findings list (title `straps: diagnostics`);
  without that flag the list is left alone.
- **`run_quickfix` turns a build/test/lint into a findings list.** `run_quickfix
  {command, errorformat?, title?, open?}` runs the command and parses its output
  through Vim's native `errorformat` (the one you pass, else the editor's
  `&errorformat`) into the session's findings list, then opens it — so a failing
  build or a linter run lands as navigable `file:line` entries in your editor
  instead of a wall of text in the transcript. Both stdout and stderr are
  parsed (compilers use stderr, many test runners stdout). The result the *agent*
  sees is a compact summary — exit code plus the parsed locations — which is far
  smaller than raw output, so it is the better choice than `bash`/
  `run_in_terminal` whenever a command emits compiler/linter-style diagnostics.
  A clean run empties the list (a passing build visibly clears a prior failure).
  It runs a command, so `hook.confirm` prompts, like `bash`. Example: `{ command
  = "luacheck lua/", errorformat = "%f:%l:%c: %m" }`.
- **`bulk_replace` edits across the findings set.** `bulk_replace {pattern,
  replacement, flags?, dry_run?}` runs `:ldo`/`:cdo
  s/<pattern>/<replacement>/<flags>
  | update` over the session's current findings list — a native multi-file
  substitute.
  Populate the list with `grep` first (an empty list is an error). Because
  `:cdo` edits each file through its buffer, every change enters that file's
  native undo history — revert it with `u`, `:earlier`, or undotree per buffer.
  The `pattern` is a **Vim** `:s` pattern (not rg/PCRE); the `e` flag is always
  ensured so a listed file with no match doesn't abort the run. It is a write
  tool, so `hook.confirm` prompts before it runs. Pass `{ dry_run = true }` to
  report how many entries and files *would* be edited without touching
  anything. A typical flow: `grep` for the old name, eyeball the matches with
  `:lopen` (or `:copen`), then `bulk_replace` to rename across all of them at
  once.

### Design choices with previews (`ask_user`)

When the agent needs your decision, `ask_user` puts concrete options in your
own picker (`vim.ui.select`, so Telescope/fzf-lua/dressing apply). An option
can be a plain string, or a `{ label, preview, filetype }` object — the agent
is prompted to attach a preview whenever the options are competing
implementations, so you choose between visible sketches of the code rather
than one-line summaries. With **snacks.nvim** installed, previewed options
open in snacks' native picker with a live preview pane that follows the
selection; without it, each preview appears in a labeled split (`1: <option>`)
alongside the plain `vim.ui.select` prompt, and every window closes the
moment you answer. The question itself is shown in a wrapped float across the
top of the editor rather than only as the picker's one-line title, so a long
question stays readable even when the picker covers the transcript. A
free-text "(other: type your own answer)" entry is
always appended, and the tool can still show a single shared `content` split
for context that isn't tied to one option.

## Configuration

| Key | Default | Meaning |
| --- | --- | --- |
| `provider` | unset (`nil`) | Which backend `fn.provider` dispatches to: `"anthropic"` or `"openai"`. `nil` means "not pinned here" — `fn.provider` then reads the choice persisted by `:StrapsProvider` (`~/.config/straps/provider`), falling back to `"anthropic"`. Setting it here pins the provider and wins over that file. Overridable per session buffer with `vim.b[bufnr].straps_provider`. |
| `model` | `"claude-sonnet-5"` | Anthropic model id. |
| `openai_base_url` | `"https://api.openai.com"` | Endpoint base for the OpenAI backend; point it at any OpenAI-compatible server or proxy. |
| `openai_model` | `"gpt-5"` | Model id sent when `provider = "openai"`; kept separate from the Anthropic `model` so switching providers never sends a Claude id to OpenAI. |
| `models` | see below | Anthropic picker seed/cache for `:StrapsModel`: `{ id, label?, thinking?, context?, max_output? }`. `thinking` is `"adaptive"` or `"budget"` (see Effort below); an unlisted/custom Anthropic `model` sends no thinking block at all. `max_output` is the model's maximum response tokens, used as the default `max_tokens` for that model (see `max_tokens` below). Live discovery merges the account's real Anthropic catalog over this list, filling `thinking`/`context`/`max_output` from the API. |
| `openai_models` | see below | OpenAI picker seed/cache for `:StrapsModel`, separate from `models` so switching providers never shows stale Claude ids under OpenAI or stale GPT ids under Anthropic. Add `reasoning = true` (or `reasoning_effort = true`) only for models that accept OpenAI's `reasoning_effort` request field. |
| `effort` | `"off"` | Name of the active entry in `config.efforts`; controls extended thinking. |
| `efforts` | see below | Picker choices for `:StrapsEffort`: `{ name, level?, budget_tokens? }`. For models tagged `thinking = "adaptive"` (e.g. `claude-sonnet-5`, `claude-opus-4-8`), `level` becomes `output_config.effort` (`"low"`/`"medium"`/`"high"`/`"max"`). For models tagged `thinking = "budget"` (e.g. `claude-haiku-4-5-20251001`, `claude-opus-4-5-20251101`), `budget_tokens` becomes `thinking.budget_tokens`. For OpenAI, `level` becomes `reasoning_effort` only when the matching `config.openai_models` entry opts in with `reasoning = true` or `reasoning_effort = true` and the request has no function tools; untagged OpenAI models and tool-bearing requests receive no effort field. `effort = "off"` sends no thinking/reasoning field. |
| `max_tokens` | `nil` | Response token cap per provider call. `nil` (default) uses the active model's own max output — the matching `config.models` entry's `max_output` (seeded, and refreshed by `:StrapsModel` discovery), else `default_max_tokens`. A number pins an explicit hard cap that wins over the per-model value, except that a budget-thinking request still bumps `max_tokens` above the cap when it would otherwise be ≤ `budget_tokens` (the API rejects that). The OpenAI backend has no per-model discovery, so it uses `max_tokens` else `default_max_tokens`. |
| `default_max_tokens` | `32000` | Fallback response cap used when `max_tokens` is `nil` and the active model has no known `max_output` (an unlisted/custom model, or before `:StrapsModel` discovers it); also the OpenAI default. Output tokens bill only as generated, so a high cap costs nothing unused. |
| `max_turns` | `128` | Hard ceiling on assistant turns per run — the backstop, not the primary spinning-catcher (that's `stall_limit`), hence generous. |
| `stall_limit` | `6` | Progress-aware soft stop: end the run after this many *consecutive* stalled turns — a turn is stalled when its every tool call errored, or when every call repeats a `(tool, input)` already made this run (a turn that also makes a new distinct call counts as progress). Catches an agent spinning without progress early and loudly (a distinct note, quoting the last error), instead of waiting for `max_turns`. Set `0` to disable and let `max_turns` alone bound runs. |
| `max_tool_result_bytes` | `100000` | Tool results larger than this are truncated with a note. |
| `base_url` | `"https://api.anthropic.com"` | Endpoint base for the Anthropic backend; point it at any Anthropic-compatible server or proxy. |
| `request_timeout_ms` | `300000` | Idle watchdog: if the response stream goes this long without any data, the request is killed and the run ends with an explanatory error instead of hanging. Raise it for slow local models. |
| `log_file` | unset | When set to a path, `fn.log` appends structured single-line JSON events there (requests/responses, turns, tool timings, run endings). Useful when a session dies mysteriously and you want to see what actually happened. |
| `cache` | `true` | Prompt caching: the provider marks `cache_control` breakpoints on the system prompt and the conversation tail so each turn's replayed prefix is a server-side cache hit. Set `false` for Anthropic-compatible servers that reject unknown fields. |
| `cache_ttl` | unset (`"5m"`) | Cache lifetime per breakpoint. Set `"1h"` for human-paced sessions where turns are often more than 5 minutes apart; costlier writes, break-even after ~3 requests. |
| `compact_keep_turns` | `2` | How many of the most recent assistant turns `fn.compact` leaves fully intact. |
| `instructions_files` | `{}` | Extra instruction files for `fn.system_prompt_project`, included last (after the layered global + upward `AGENTS.md`/`CLAUDE.md`). Paths, absolute or relative to the working directory; unreadable entries are skipped silently. |
| `auto_compact_tokens` | unset | When set, the loop runs `fn.compact` near this estimated token count (bytes ÷ ~3.5), with a growth guard so it fires coarsely rather than every turn. Set it near your model's context window. Unset = off. |
| `auto_compact_bytes` | unset | Raw-size alternative to `auto_compact_tokens`: compact when the transcript exceeds this many bytes. Unset = off: automatic history rewriting is opt-in. |
| `render` | `true` | Transcript rendering (`fn.render`): a display-only conceal + extmark + fold layer that gives each block a categorical colored mark and collapses tool calls to a one-line summary. Buffer text, `modified`, parse and persist are never touched. `false` skips the wiring (raw markers). See [Rendering](#rendering). |
| `tools_expanded` | `false` | Fold `tool_use`/`tool_result` blocks open by default when `true` (`foldlevel = 99`); otherwise the default `foldlevel = 0` keeps them closed (conversation turns never fold). See [Navigating a session](#navigating-a-session). |
| `session_winbar` | `true` | Show a window-local winbar on each session window with the active model/effort (per-buffer override else global) and run status. `false` hides it; `ui.session_status()` / `ui.session_winbar()` stay usable in a manual statusline either way. |

## Security

`bash`, `eval_lua`, `write_file`, `edit_file`, and `registry_define` are
gated by `hook.confirm`, which prompts you per call (read-only tools are
auto-allowed). Note the shape of the trust boundary: the agent *can* redefine
its own confirm hook — but doing that is itself a `registry_define` call,
which the current confirm hook makes you approve first. Read
`registry_define` inputs before saying yes, and be sparing with "Always this
tool" for it. None of this is sandboxing: an approved `bash` or `eval_lua`
call runs with your full user privileges inside your editor. If you want
real isolation, run Neovim in a container or sandbox.

## Statusline

Session buffers carry `vim.b.straps_status`, set to `"idle"` on creation and
maintained as `"running"` / `"idle"` by the loop around each run. A minimal
statusline recipe:

```lua
vim.o.statusline = "%f %h%m%r %{get(b:, 'straps_status', '')} %=%l,%c"
```

Or in lualine:

```lua
{ function() return vim.b.straps_status or "" end }
```

### Rolling your own component

The buffer variables above are *raw* state: a per-session override is often
unset, so reading `b:straps_model` alone tells you nothing about what the
session will actually use. `require("straps.ui").session_info(bufnr)` resolves
the whole override → global-config chain for you and returns everything the
built-in winbar renders, unformatted — or `nil` when `bufnr` is not a session
buffer (`bufnr` defaults to the current buffer):

```lua
local info = require("straps.ui").session_info()  -- nil off a session buffer
-- {
--   bufnr = 7,
--   provider = "anthropic",
--   model = "claude-sonnet-5",
--   model_label = "Sonnet 5 — balanced (default)",  -- config label, else the id
--   effort = "off",
--   overridden = false,   -- true when provider/model/effort DIVERGE from config
--   status = "running",   -- "running" | "idle"
--   parent = nil,         -- parent session bufnr, for a subagent
--   usage = { input_billed = 138879, cache_read = 137582, ... },  -- nil until the first response
--   context_used = 138879,  -- billed input tokens = the current context fill
--   context = 200000,       -- resolved window; nil when unknown
--   context_pct = 69,       -- pre-rounded ints; nil when not computable
--   cache_pct = 99,
-- }
```

So a lualine component showing model and context fill:

```lua
{ function()
    local info = require("straps.ui").session_info(vim.api.nvim_get_current_buf())
    if not info then return "" end
    return ("%s %s"):format(info.model_label, info.context_pct and info.context_pct .. "%%" or "")
  end }
```

`ui.human_tokens(n)` formats a token count the way the winbar does (`138879` →
`"138.9k"`), so a hand-written component does not have to reinvent it.

The three built-in components — `session_status()`, `usage_status()` and
`session_winbar()` — each take the same optional `bufnr`, so they work from
outside the target window too.

**Which buffer?** A window-local `statusline` or `winbar` resolves the right
session implicitly, so zero-arg calls do the right thing there. A **global
tabline** does not: `%{}` in a tabline (and `bufnr()` inside it) evaluates in
the *current* window's context, so a session's model vanishes from the tabline
as soon as you focus another window. For a tabline, either use a Lua component
framework that knows which window it is rendering (lualine, heirline) and pass
the bufnr explicitly, or show the buffer-independent `agents_status()` below.
### Running agents

`vim.b.straps_status` is per-buffer — it says whether _this_ session is
running. Subagents (`tool.spawn`) run in their own session buffers, hidden by
default, so a global "how many agents are working right now, and for whom"
readout is separate:

- `require("straps.ui").agents_status()` returns a compact count of every
  active run across all sessions — `"🤖 2"` for two top-level runs, `"🤖 1+3"`
  when three subagents are also active — and `""` when nothing is running. It
  is buffer-independent, so drop it into a global (not window-local)
  statusline:

  ```lua
  vim.o.statusline = "%f %h%m%r %{v:lua.require'straps.ui'.agents_status()} %=%l,%c"
  ```

  The loop redraws all statuslines when a run starts or ends, so the count
  updates even while you sit in an unrelated buffer.

- `:StrapsAgents` opens a picker over the running agents, each row showing the
  session, its parent (`◂ <parent>`, for subagents), and the one-line task it
  was spawned with. Picking one opens that transcript in a split so you can
  watch a subagent's output live and steer it. `require("straps.ui")` also
  exposes `pick_agents()` and the underlying `running_agents()` snapshot.

### Agents that know about each other

Those readouts tell *you* who is working. The agents get the same picture:

- The **`agents` tool** lists every other session in this Neovim — running or
  idle, how it relates to the caller (parent/child/sibling/peer), the task it
  was given, and the files it has written (read from the write stamps that
  power collision detection). It is read-only and auto-allowed.
- **`hook.on_run_start`** appends one user block to a session's transcript when
  another agent is running as it starts, pointing at that tool. It stays silent
  for a solo session, announces a given set of peers only once, and never
  appends to a transcript that has nothing else to send — so a session working
  alone gets no multiplayer notice at all. Redefine it to change or silence the
  notice.
- **`fn.model_note`** is the same idea for a session's own configuration
  rather than its neighbours, but it rides the request instead of the
  transcript: each turn the loop appends its `# Model` section to that
  request's system text, naming the effective provider/model/effort. See
  "Per-session model and effort" above.
- **`skill.multiplayer`** carries the protocol the notice points at: re-read
  and reapply after a `modified by another agent` error, keep the read→write
  gap short, leave a peer's half-finished work alone, and hand work off with
  `require("straps.loop").steer(<peer bufnr>, "<message>")` rather than racing.
- `fn.peer_agents(ctx_bufnr)` is the underlying snapshot if you want to build
  your own view of it.

All of this is **same-instance only**: sessions in a *different* Neovim share
nothing but disk, where the only signal is the on-disk divergence check.
