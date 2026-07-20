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
- `ANTHROPIC_API_KEY` in the environment

No other dependencies. No plenary.

## Install

With lazy.nvim:

```lua
{
  "matt/straps", -- placeholder; point at wherever this repo lives
  config = function()
    require("straps").setup({
      -- defaults shown; all optional
      model = "claude-sonnet-5",
      max_tokens = 8192,
      max_turns = 64,
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
   the transcript IS where you type.
2. Type your message under that marker — as many lines as you like, normal
   vim editing throughout.
3. Press `<CR>` in normal mode (or run `:StrapsSend`) to send: the loop reads
   the trailing user block and starts a run.
4. While a run is active, the same `<CR>` steers it instead — you're prompted
   for a message that's queued and delivered at the next turn boundary.
5. Non-read-only tool calls prompt for confirmation; answer Yes, No, or
   "Always this tool" (remembered per session buffer).
6. `:StrapsStop` cancels a run in flight.

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
You are a coding agent...

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
  (`foldmethod=expr`); open them with `zo` / `zR` as usual.

### Rendering

The raw `%%[straps:KIND]%%` markers are the source of truth — parse, persist
and every API request read the real lines. On top of them straps draws a
**display-only** layer (`fn.render`): conceal, extmarks and folds, never a
change to the buffer text or `modified`. Color is *categorical*, not
decorative — a small mark per block type for glance-level pattern recognition,
never a wash or a background tint:

- Each `user` / `assistant` / `system` marker line is concealed and replaced
  by a colored turn rule — `──── you ─────…`, `──── agent ─────…`,
  `──── system ─────…` — so the transcript reads as a conversation.
- A `tool_use` + `tool_result` pair folds to **one colored summary line**,
  `▸ <verb> <args>  ✓|✗` (green ✓ / red ✗ from the result's `is_error`) —
  the call rendered command-style by [`fn.tool_display`](#command-style-tool-calls),
  e.g. `▸ $ echo hi  ✓` or `▸ read init.lua  ✓`. Open the fold (`zo`) to see
  the full call inside a card (`╭─ <verb> <args> ─`, a `result` divider, `╰─`).

All hues come from the active colorscheme through `hi default link`, so it is
catppuccin now and any scheme later. The groups (override any of them with your
own `hi link`; `default = true` means yours wins):

| group | default link | mark |
| --- | --- | --- |
| `StrapsRoleUser`   | `Function`        | the `you` role tag |
| `StrapsRoleAgent`  | `Keyword`         | the `agent` role tag |
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
- `tools_expanded = false` — set `true` to fold tool calls open by default.

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

### Long sessions

The transcript IS the request: every turn re-parses the whole buffer, so a
long session grows the context sent to the API on each call. To prune, just
delete old `tool_use` / `tool_result` blocks (or whole exchanges) — it's
just a buffer, and the next turn sends exactly what remains. `max_turns`
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

## Picking model and effort

`:StrapsModel` and `:StrapsEffort` open a picker (uses `snacks.nvim`'s
`Snacks.picker.select` when installed, otherwise falls back to plain
`vim.ui.select`) over `config.models` / `config.efforts` and set
`config.model` / `config.effort` on selection — no restart or reconnect
needed, since both are read fresh on every provider call.

`:StrapsResume!` (bang) opens the same picker over
`state.list_sessions()` (newest first) and resumes whichever `*.straps`
transcript you pick — handy when you don't remember the exact name
`:StrapsResume <Tab>`-completion would need. No saved sessions falls back
to opening a fresh one, same as bare `:StrapsResume`.

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
  (`hook.confirm`, `hook.after_write`, `hook.on_run_start`, ...).
- `fn.*` — core functions (`fn.provider`, `fn.system_prompt` and its
  layers, `fn.build_tools`, `fn.api_key`).

Entries are Lua source strings compiled on define. Every call site does a
by-name lookup, so redefining an entry changes behavior immediately.

- `:StrapsRegistry` — list all entries; `<CR>` on a line opens it.
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

- `fn.system_prompt_core` — identity, output norms, workflow, and the
  self-extension guidance, including the concrete triggers the agent is
  taught to act on: the same manual step done twice means define a tool or
  hook before the third time, and "always" / "every time" / "from now on"
  from you means install the behavior in the registry rather than promise
  to remember it.
- `fn.system_prompt_env` — a generated environment block: cwd, platform,
  Neovim version, date, and version control (jj or git, with branch and
  dirty/clean for git).
- `fn.system_prompt_project` — project instruction files: the nearest
  `AGENTS.md` and the nearest `CLAUDE.md` found upward from the working
  directory are discovered automatically (the ecosystem's memory-file
  convention), plus any paths you list in `config.instructions_files`.
  Each file is included under a header naming its path, capped at 20000
  bytes.
- `fn.system_prompt` — the composer: joins the three layers (environment
  under `# Environment`, project files under `# Project instructions`)
  and is what `state.new_session` calls.

The composed prompt is written into the session's editable system block at
creation time, so environment and project content are frozen per session —
edit the block directly or open a new session to refresh them. Each layer
is individually redefinable (`:StrapsEdit fn.system_prompt_env`, or
`registry.define` in your config); because the composer looks the layers up
through the registry at call time, a redefined layer takes effect for the
next new session.

## Worked example: a linter hook

`tool.write_file` and `tool.edit_file` both fire `hook.after_write` with the
path just written. It ships as a no-op. This is the canonical seam for
"always do X after writes".

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

The provider is just `fn.provider`. `:StrapsEdit fn.provider`, change the
endpoint (for example to point at a proxy), `:w`:

```lua
-- inside the entry's source, change:
local url = "https://api.anthropic.com/v1/messages"
-- to:
local url = "https://my-proxy.internal/v1/messages"
```

The next provider call — even the next turn of a run already in progress —
uses the new definition. `fn.api_key` is likewise an entry; redefine it if
your key comes from somewhere other than `$ANTHROPIC_API_KEY`.

## Builtin tools

| Tool | Description |
| --- | --- |
| `read_file` | Read a file with numbered lines (offset/limit, capped ~2000 lines). |
| `write_file` | Write a file (creates parent dirs) through its buffer, so the write enters the file's native undo history — revert with `u` / `:earlier` / undotree; fires `hook.after_write`. |
| `edit_file` | Exact-string replacement applied through the file's buffer as one undoable step (revert with `u` / undotree); matches against the live buffer, so unsaved edits are seen; fires `hook.after_write`. |
| `bash` | Run a shell command via `bash -lc`; returns exit code, stdout, stderr. |
| `glob` | Expand a glob pattern (capped at 500 entries). |
| `grep` | Search file contents (`rg` if available, else `grep -rn`); also populates the quickfix list. |
| `bulk_replace` | Substitute across the current quickfix list via `:cdo` (undoable, confirm-gated, supports `dry_run`). |
| `registry_list` | List registry entries: name, kind, doc, version. |
| `registry_get` | Return an entry's full definition as executable Lua. |
| `registry_define` | Define or redefine any registry entry. The self-extension tool. |
| `eval_lua` | Execute Lua inside Neovim; returns `vim.inspect` of the results. |

`write_file` and `edit_file` apply their change through the target file's
buffer (loaded or reused if already open) and then write that buffer, so every
agent edit lands in the file's native undo history — you revert it with `u`,
`:earlier`, or undotree, right alongside your own edits, and an edit to a file
you have open with unsaved changes stacks on top of those changes instead of
clobbering them.

### Editor-native tools

These use the editor straps lives in — its LSP clients and tree-sitter
parsers — instead of shelling out. All are read-only (auto-allowed by
`hook.confirm`) and degrade to a clear message rather than erroring.

| Tool | Description |
| --- | --- |
| `diagnostics` | LSP/linter diagnostics for a file (or all loaded buffers) as `file:line:col: SEVERITY message [source]`. |
| `definition` | Go-to-definition of the symbol at `{path, line, col}` (1-based) via the attached LSP client; returns `file:line:col`. |
| `references` | All references to the symbol at `{path, line, col}` via the attached LSP client; deduped/sorted `file:line:col`. |
| `symbols` | Document outline of a file: `name  kind  L<start>-<end>` per symbol. |
| `read_symbol` | Read the source of a named function/class from a file (a targeted read, numbered like `read_file`). |

The LSP tools (`definition`, `references`, and the fallback in `symbols`) need
an attached LSP client for the file's filetype; they wait briefly for one to
attach, bound every request with a timeout so a wedged server can't hang a run,
and fall back gracefully (a tags lookup, then a clear "no LSP client" message)
when none is available. The tree-sitter tools (`symbols`, `read_symbol`) work
with no server at all — they parse the buffer directly and cover common
languages, degrading to a clear message for filetypes with no parser.

### Quickfix

straps wires its search tools into Neovim's own quickfix list, so results are
navigable with `:cnext`/`:cprev` and editable in bulk with native Vim
machinery.

- **`grep` populates the quickfix list.** Every `grep` also loads its matches
  into the quickfix list (title `straps: grep <pattern>`) as a side effect —
  the returned text summary is unchanged. Jump through the hits with `:cnext`
  and `:cprev`. A search that genuinely matches nothing clears the list; a
  transient failure leaves any existing list untouched.
- **`diagnostics` can too.** Call it with `{ quickfix = true }` to also load the
  reported diagnostics into the quickfix list (title `straps: diagnostics`);
  without that flag the list is left alone.
- **`bulk_replace` edits across the quickfix set.** `bulk_replace {pattern,
  replacement, flags?, dry_run?}` runs `:cdo s/<pattern>/<replacement>/<flags>
  | update` over the current quickfix list — a native multi-file substitute.
  Populate the list with `grep` first (an empty list is an error). Because
  `:cdo` edits each file through its buffer, every change enters that file's
  native undo history — revert it with `u`, `:earlier`, or undotree per buffer.
  The `pattern` is a **Vim** `:s` pattern (not rg/PCRE); the `e` flag is always
  ensured so a listed file with no match doesn't abort the run. It is a write
  tool, so `hook.confirm` prompts before it runs. Pass `{ dry_run = true }` to
  report how many entries and files *would* be edited without touching
  anything. A typical flow: `grep` for the old name, eyeball the matches with
  `:copen`, then `bulk_replace` to rename across all of them at once.

## Configuration

| Key | Default | Meaning |
| --- | --- | --- |
| `model` | `"claude-sonnet-5"` | Anthropic model id. |
| `models` | see below | Picker choices for `:StrapsModel`: `{ id, label?, thinking? }`. `thinking` is `"adaptive"` or `"budget"` (see Effort below); an unlisted/custom `model` sends no thinking block at all. |
| `effort` | `"off"` | Name of the active entry in `config.efforts`; controls extended thinking. |
| `efforts` | see below | Picker choices for `:StrapsEffort`: `{ name, level?, budget_tokens? }`. For models tagged `thinking = "adaptive"` (e.g. `claude-sonnet-5`, `claude-opus-4-8`), `level` becomes `output_config.effort` (`"low"`/`"medium"`/`"high"`/`"max"`). For models tagged `thinking = "budget"` (e.g. `claude-haiku-4-5-20251001`, `claude-opus-4-5-20251101`), `budget_tokens` becomes `thinking.budget_tokens`. These two mechanisms are mutually exclusive per model generation — sending the wrong one is a 400 — so pick whichever field applies to your model. `effort = "off"` sends no thinking block. |
| `max_tokens` | `8192` | `max_tokens` per provider call. |
| `max_turns` | `64` | Maximum assistant turns per run. |
| `max_tool_result_bytes` | `100000` | Tool results larger than this are truncated with a note. |
| `base_url` | `"https://api.anthropic.com"` | Endpoint base for the default provider; point it at any Anthropic-compatible server or proxy. |
| `request_timeout_ms` | `300000` | Idle watchdog: if the response stream goes this long without any data, the request is killed and the run ends with an explanatory error instead of hanging. Raise it for slow local models. |
| `log_file` | unset | When set to a path, `fn.log` appends structured single-line JSON events there (requests/responses, turns, tool timings, run endings). Useful when a session dies mysteriously and you want to see what actually happened. |
| `cache` | `true` | Prompt caching: the provider marks `cache_control` breakpoints on the system prompt and the conversation tail so each turn's replayed prefix is a server-side cache hit. Set `false` for Anthropic-compatible servers that reject unknown fields. |
| `cache_ttl` | unset (`"5m"`) | Cache lifetime per breakpoint. Set `"1h"` for human-paced sessions where turns are often more than 5 minutes apart; costlier writes, break-even after ~3 requests. |
| `compact_keep_turns` | `2` | How many of the most recent assistant turns `fn.compact` leaves fully intact. |
| `instructions_files` | `{}` | Extra instruction files for `fn.system_prompt_project`, included after the auto-discovered `AGENTS.md`/`CLAUDE.md`. Paths, absolute or relative to the working directory; unreadable entries are skipped silently. |
| `auto_compact_tokens` | unset | When set, the loop runs `fn.compact` near this estimated token count (bytes ÷ ~3.5), with a growth guard so it fires coarsely rather than every turn. Set it near your model's context window. Unset = off. |
| `auto_compact_bytes` | unset | Raw-size alternative to `auto_compact_tokens`: compact when the transcript exceeds this many bytes. Unset = off: automatic history rewriting is opt-in. |
| `render` | `true` | Transcript rendering (`fn.render`): a display-only conceal + extmark + fold layer that gives each block a categorical colored mark and collapses tool calls to a one-line summary. Buffer text, `modified`, parse and persist are never touched. `false` skips the wiring (raw markers). See [Rendering](#rendering). |
| `tools_expanded` | `false` | Fold `tool_use`/`tool_result` blocks open by default when `true` (closed otherwise). |

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
