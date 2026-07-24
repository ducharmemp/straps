# straps.nvim — design spec

A minimal, complete harness for coding agents inside Neovim — a small,
legible core (in the spirit of the `pi` agent harness) where **everything
is redefinable at runtime** and **buffers are the state**.

Three invariants (do not violate):

1. **Buffers are state.** The conversation transcript IS a buffer in a parseable
   format. Each turn, the loop re-parses the buffer to build API messages. The
   user (or the agent) can edit history, edit the system prompt, delete
   messages — the buffer is canonical. Registry entries are exposed as editable
   Lua buffers.
2. **Everything is late-bound and redefinable.** All tools, hooks, the provider,
   and the key loop functions are entries in a registry, stored as *Lua source
   strings*, compiled on define, and looked up by name at every call site.
   Redefining an entry takes effect on the very next call — even mid-run.
3. **The agent can extend itself.** The agent has registry introspection and
   `registry_define` as tools. The tool list sent to the API is rebuilt from
   the registry on every provider call, so a tool the agent defines in turn N
   is callable in turn N+1.

Target: Neovim >= 0.11 (use `vim.system`, `vim.json`, `vim.schedule`,
`vim.fn.confirm`). LuaJIT / Lua 5.1 semantics. Zero external dependencies
except `curl` on PATH. No plenary.

## File layout

```
lua/straps/init.lua        -- setup(), config, wires everything together
lua/straps/registry.lua    -- the late-bound registry (heart of the plugin)
lua/straps/state.lua       -- transcript buffer format: create/append/parse
lua/straps/provider.lua    -- registers fn.provider (Anthropic SSE via curl)
lua/straps/loop.lua        -- coroutine agent loop
lua/straps/tools.lua       -- registers all builtin tools + default hooks
lua/straps/ui.lua          -- registry edit buffers, listing, keymaps, folds
plugin/straps.lua          -- user commands (guarded, no heavy requires at load)
syntax/straps.vim          -- legacy syntax highlighting (no-parser fallback)
ftplugin/straps.lua        -- starts treesitter when the straps parser exists
queries/straps/            -- highlight + injection queries (markdown/JSON)
tree-sitter-straps/        -- the transcript grammar (generated src/ committed)
tests/run_registry_state.lua
tests/run_loop.lua
README.md
```

All modules return a table `M`. `provider.lua`, `tools.lua` expose
`M.register()` which defines their registry entries; `init.setup()` calls these.
Nothing registers at `require` time except `registry.lua`'s own module table.

---

## registry.lua

```lua
local registry = require("straps.registry")

registry.define{
  name = "tool.write_file",     -- namespaced: "tool." | "hook." | "fn."
  kind = "tool",                -- "tool" | "hook" | "fn"
  doc  = "Write content to a file. Calls hook.after_write when done.",
  input_schema = { ... },       -- JSON Schema as a Lua table; tools only
  source = [==[
return function(input, ctx)
  -- ...
end
]==],
}
```

- `define(spec) -> entry`. Validates: `name` (string), `kind` (one of three),
  `source` (string). Compiles with `load(spec.source, "straps:" .. spec.name)`;
  the chunk MUST return a function; otherwise `define` raises a descriptive
  error and the previous entry (if any) is left untouched. Stores
  `{ name, kind, doc, input_schema, source, fn, version }` where `version`
  increments on each redefine. After a successful (re)define, if an entry named
  `hook.on_define` exists, call it as `(entry)` inside `pcall` (never let it
  break define).
- `get(name) -> entry | nil`
- `call(name, ...) -> ...` — looks up at call time, errors clearly if missing.
- `try_call(name, ...) -> nil | ...` — returns nil (no error) if the entry does
  not exist; used for optional hooks. Errors inside the fn still propagate.
- `names(kind?) -> string[]` — sorted.
- `remove(name)`
- `render(name) -> string` — the entry as an executable Lua chunk (see ui.lua):
  a `require("straps.registry").define{ ... }` call with the source embedded in
  a `[==[ ]==]` long string (bump `=` count if the source contains `]==]`).
- `dump() -> string` — `render` of every entry concatenated; executing it
  restores the registry. This is the persistence story.

Namespacing convention: tools are `tool.<api_name>` where `<api_name>` (the
part after `tool.`) is what the LLM sees and must match `^[a-zA-Z0-9_-]+$`.

## state.lua — transcript buffer format

One session = one buffer. Name `straps://session/<n>`, `buftype=nofile`,
`bufhidden=hide`, `swapfile=false`, `filetype=straps`, `vim.b.straps_session = true`.

### Block grammar

A block starts with a **marker line** and runs until the next marker or EOF:

```
%%[straps:KIND]%%[ one-space + compact-JSON-attrs]
<content lines>
```

`KIND` ∈ `system | user | assistant | tool_use | tool_result`.
Attrs: `tool_use` → `{"id":"...","name":"..."}`; `tool_result` →
`{"id":"...","is_error":true|false}`; others none.

- `tool_use` content = pretty-printed JSON of the tool input.
- Content is trimmed of leading/trailing blank lines on parse; the writer puts
  one blank line before each marker for readability.
- **Escaping:** a content line that starts with `%%[straps:` is written with
  the prefix `%%[[esc]]` prepended; the parser strips exactly that prefix once.
  Apply on append, strip on parse. (Also escape lines starting with `%%[[esc]]`
  itself the same way, so it round-trips.)

Example transcript:

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

This grammar has a second, display-only implementation: the tree-sitter
grammar in `tree-sitter-straps/` (with `queries/straps/` injecting markdown
into prose content and JSON into tool bodies). It exists so treesitter
highlighting and language-tree-driven markdown renderers work on the
transcript; it never feeds parsing — `state.lua` is the parser of record for
API messages in all cases. `tests/run_treesitter.lua` pins the two
implementations' block boundaries to each other.

### Parse → Anthropic messages

`state.parse(bufnr) -> { system = string|nil, messages = message[] }` where
messages are Anthropic Messages API shaped:

- `system` block (first, at most one) → `system` string.
- `user` text block → `{ role="user", content={{type="text", text=...}} }`.
  Empty trailing user block (the prompt area) is dropped.
- A run of `assistant` + `tool_use` blocks → ONE
  `{ role="assistant", content={ {type="text",...}?, {type="tool_use", id=, name=, input=<decoded json>}... } }`.
  Empty assistant text → omit the text part.
- A run of `tool_result` blocks → ONE
  `{ role="user", content={ {type="tool_result", tool_use_id=, content=..., is_error=...}... } }`.
- Adjacent same-role messages must be merged (API requires alternation).

### API

- `state.new_session() -> bufnr` — creates buffer with the system block
  (from `registry.call("fn.system_prompt")`) and a trailing empty user marker.
- `state.parse(bufnr)` — as above. Must be a total function: garbage lines
  before the first marker are ignored.
- `state.append(bufnr, kind, attrs_or_nil, text)` — append a block, escaping
  content. If a window shows the buffer with cursor on the last line, keep it
  pinned to bottom.
- `state.append_text(bufnr, text)` — append raw text to the buffer tail
  (streaming deltas into the current block; must handle text containing "\n").
- `state.ensure_trailing_user(bufnr)` — append an empty user marker if the
  last block isn't an empty user block.
- `state.last_user_text(bufnr) -> string|nil` — content of trailing user block.

## Durable sessions (file-backed transcript + resume)

Sessions are durable by default: the transcript buffer is backed by a real
file, so it survives a restart, and resume is just reopening that file. The
transcript format is already plain text, so buffer content == file content.

- Directory: `config.session_dir` or default
  `vim.fn.stdpath("data") .. "/straps/sessions"`; mkdir -p on first use.
- Filename: `<os.date %Y%m%d-%H%M%S>-<session_n>.straps` (the counter
  disambiguates same-second sessions); absolute path. `.straps` extension so
  an ftdetect rule can map hand-opened files to `filetype=straps`.
- `state.session_dir()` — ensure + return the dir (config-aware, pcall-safe).
- `state.new_session()` — now file-backed: buffer name = the path,
  `buftype=""` (normal, so `:w` works), swapfile=false, bufhidden=hide,
  filetype=straps, `vim.b.straps_session=true`; append system + trailing user
  as today; then persist. **Fallback:** if the dir can't be created/written
  (pcall fails), degrade to today's ephemeral buffer (buftype=nofile,
  `straps://session/n`) so the harness still runs — notify once.
- `state.persist(bufnr)` — best-effort write of a file-backed buffer to its
  file via `nvim_buf_call` + `silent noautocmd write` (noautocmd so it can't
  fire user autocmds / LSP / our own hooks). **No-op unless the buffer is
  file-backed** (`buftype == ""` and has a name) — so the scratch buffers the
  tests create directly are never touched. pcall-wrapped.
- Persist is called from `state.append` and `state.ensure_trailing_user`
  (block boundaries), NOT from `append_text` (per-delta streaming). A crash
  mid-stream loses only the in-flight assistant text since the last block; the
  loop's end-of-run `ensure_trailing_user` persists the finished turn.
- `state.list_sessions()` — `{ {path, name, mtime}, ... }` for `*.straps` in
  session_dir, sorted mtime desc; pcall-safe, empty on error.
- `state.open_session_file(path)` — reuse the buffer if one already names the
  path (`vim.fn.bufnr(path) ~= -1`), else `bufadd`+`bufload`; apply the
  session buffer setup (buftype="", swapfile=false, filetype=straps,
  straps_session=true); return bufnr. Does not modify content.

**ui.lua** — `open_session()` is unchanged in spirit (new_session is now
durable; the `<CR>` keymap, folding, load_project_registry all stay). Add
`resume_session(path?)`: same split, but opens the transcript via
`state.open_session_file` instead of new_session; path nil → most recent from
list_sessions (none → notify + fall through to a new session). Still runs
load_project_registry.

**plugin/straps.lua** — `:StrapsResume [path]`: resume_session; completion
lists session basenames (resolve basename → full path); no arg → most recent.
`:Straps` stays "new session".

**ftdetect** — `ftdetect/straps.vim` (or an autocmd): `*.straps` → setf straps,
so a file opened with `:e` gets folding via ui.setup's FileType autocmd.

**config (init.lua)** — add `session_dir = nil` (nil → computed default);
document.

**Tests — isolation is mandatory.** Every test that creates a session
(new_session / ui.open_session) must set `require("straps").config.session_dir`
to a fresh `vim.fn.tempname()` near the top, so runs never write to the real
data dir and stay hermetic. `state.persist` already no-ops on the scratch
buffers built with nvim_create_buf. New suite `tests/run_session_file.lua`:
new_session writes a file whose content equals the buffer and contains the
system marker; append persists to disk; list_sessions returns it newest-first;
open_session_file reloads a written transcript into a straps_session buffer
that parses to the same messages; a wipe→reopen round-trip preserves the
transcript; new_session with an unwritable session_dir falls back to a usable
ephemeral buffer without error; persist is a no-op (no error) on a scratch
buffer; ui.resume_session(path) headless rebuilds the stack with the content.

## loop.lua — the agent loop

```lua
loop.start(bufnr)   -- error/notify if a run is already active for bufnr
loop.stop(bufnr)    -- request cancel: flips flag, invokes registered cancel fns
loop.running(bufnr) -> bool
```

The run executes inside a coroutine. `ctx` (passed to provider, tools, hooks):

```lua
ctx = {
  bufnr = bufnr,
  await = function(start)  -- start(resolve) begins async work;
    -- yields the coroutine; resolve(...) resumes it (driver wraps resume in
    -- vim.schedule so resolve is safe from any callback context).
    -- resolve must be called exactly once. await returns resolve's args.
  end,
  emit = function(ev) end, -- provider streaming events, see provider.lua
  on_cancel = function(fn) end, -- register cancel handler (e.g. kill curl);
                                -- handlers cleared after each await completes
  cancelled = function() -> bool,
}
```

Run algorithm (each numbered step goes through the registry so it's swappable):

1. `registry.call("hook.on_run_start", ctx)` via `try_call`.
2. Loop up to `config.max_turns` times:
   a. `parsed = state.parse(bufnr)`
   b. `tools = registry.call("fn.build_tools")` — maps every `tool.*` entry to
      `{ name = api_name, description = entry.doc, input_schema = entry.input_schema or {type="object"} }`.
   c. `resp = registry.call("fn.provider", { system=parsed.system, messages=parsed.messages, tools=tools }, ctx)`
      Before the provider call, append an empty `assistant` block marker; the
      provider emits `text_delta` events which the loop appends via
      `state.append_text`. (If the response has no text, the empty assistant
      block is harmless — parse omits empty text.)
   d. For each `tool_use` block in `resp.content`:
      - `state.append(bufnr, "tool_use", {id=, name=}, pretty_json(input))`
      - `allowed, reason = registry.call("hook.confirm", name, input, ctx)`
        If not allowed → tool_result with `is_error=true`, content
        `"user denied: " .. (reason or "")`, continue to next tool_use.
      - `registry.try_call("hook.before_tool", name, input, ctx)`
      - `ok, result = pcall(registry.call, "tool." .. name, input, ctx)`
        (unknown tool → error path). Result: string, or table (json-encode),
        or nil → "ok". Truncate results > `config.max_tool_result_bytes`
        (default 100_000) with a note.
      - `result = registry.try_call("hook.after_tool", name, input, result, ok, ctx) or result`
      - `state.append(bufnr, "tool_result", {id=, is_error=not ok}, tostring(result))`
   e. Stall check (progress-aware soft stop): classify the turn — stalled when
      it issued tool calls AND either every call errored or any call repeats a
      `(tool, input)` already made this run (inputs canonicalized via
      `pretty_json`, so key order doesn't matter). `run.stall` counts
      CONSECUTIVE stalled turns; a productive turn resets it to 0. When it
      reaches `config.stall_limit` (default 6, 0 disables), end the run with
      reason `"stalled"` and a loud, distinct note (below). This measures the
      spinning `max_turns` was only ever a proxy for.
   f. `resp.stop_reason == "tool_use"` → continue loop; else break.
3. `registry.try_call("hook.on_run_end", ctx)`; `state.ensure_trailing_user(bufnr)`;
   clear the running flag (also on error — wrap the whole run body, append an
   `assistant` block with the error message on failure so the user sees it).
4. Cancellation: checked between turns and between tool calls; provider's
   cancel fn kills curl. A cancelled run ends cleanly with a note appended.

### Steering (mid-run user messages)

- Queue: `vim.b[bufnr].straps_steering` — a list of strings (buffer state).
- `loop.steer(bufnr, text)`: if a run is active, push onto the queue (read
  vim.b, copy, write back — vim.b tables are snapshots), emit progress event
  `{type="steer_queued"}`, notify "steering queued". If no run is active,
  return false (callers fall back to `loop.start`).
- Draining (single helper): pop all queued strings and
  `state.append(bufnr, "user", nil, text)` each, clear the queue. Called at
  two points in `run_turns`:
  1. top of every turn iteration, before `state.parse` — so the next request
     naturally includes the steering text (the buffer IS the request);
  2. when a turn ends with `stop_reason ~= "tool_use"`: drain; if anything
     was drained, CONTINUE the loop (another provider call) instead of
     finishing — a message typed while the model streamed its final answer
     still gets acted on. `max_turns` still bounds total iterations.
- UI: `<CR>` / `:StrapsSend` on a session buffer with an active run prompt
  via `vim.ui.input({prompt = "steer: "})` and call `loop.steer` (empty/nil
  input = no-op). `:StrapsSteer {text}` (nargs=+) queues directly.

### One buffer, no compose split

The session is a single ordinary buffer — no second "compose" window. Message
authoring happens directly under the trailing `%%[straps:user]%%` marker, the
same buffer the loop reads and appends to. This keeps the whole interaction
as close to normal vim as possible: no separate input mode, no synced pair of
buffers to keep straight, and — deliberately — editing earlier history before
you send is a first-class feature, not an accident of the buffer being
mutable. It follows directly from invariant 1 (buffers are state): there is
only one buffer, so there is only one place to look and only one place to
edit.

- `ui.open_session()` opens the transcript in a single `split`, sets the
  `<CR>` keymap (send, or prompt to steer if a run is active — see above),
  and puts the cursor on the last line.
- Sending (`<CR>` normal mode on the session buffer, or `:StrapsSend` there):
  if a run is active, prompt via `vim.ui.input({prompt = "steer: "})` and
  queue; otherwise `loop.start(bufnr)`, which parses the buffer as-is — the
  trailing user block (or whatever the user left there) IS the message. An
  empty trailing block errors with a clear "nothing to send" message rather
  than silently doing nothing — both when the conversation is empty and when
  it would leave the transcript ending on an assistant message (newer models
  reject a request ending on an assistant message — unsupported prefill).
- Target resolution for `:StrapsSend`/`:StrapsSteer`/`:StrapsStop`: current
  buffer must be a session buffer (`vim.b.straps_session`); else polite error.

### Progress

- The loop emits events through `pcall(registry.try_call, "hook.on_progress",
  ev, ctx)` (progress must never break a run) and mirrors a short phase
  string into `vim.b[bufnr].straps_phase`:
  - `{type="start"}` at run start
  - `{type="thinking", turn=n}` before each provider call
  - `{type="tool", name=name}` before a tool executes
  - `{type="tool_done", name=name, is_error=b}` after
  - `{type="steer_queued"}` from loop.steer
  - `{type="done", reason="ok"|"error"|"cancelled"}` at run end (always)
- Default `hook.on_progress` (define_default in ui.setup()) is a thin
  adapter calling `require("straps.ui").progress(ctx.bufnr, ev)` — policy is
  the redefinable hook; mechanism lives in ui.lua:
  - a namespaced extmark (`straps_progress`) with `virt_text` on the last
    line of the session buffer, e.g. `⏳ thinking · 12s · <CR> steer ·
    :StrapsStop stop` / `⚙ bash · 3s · ...`;
  - a per-buffer 500 ms uv timer (schedule_wrapped, validity-guarded)
    refreshes the elapsed seconds; timer + extmark are torn down on
    `done`, buffer wipe, or invalid buffer.
- Redefining `hook.on_progress` (e.g. to vim.notify or fidget.nvim) replaces
  the policy without touching ui.lua; the README shows this.

### Run endings must be loud; long runs must be legible

- `run_turns` returns a reason: "ok" | "cancelled" | "max_turns" | "stalled".
  Exhausting `config.max_turns` (the hard backstop, default 128) appends a
  visible assistant note — `[straps: stopped after N turns (config.max_turns)
  — send a message to continue]` — never a silent end. The `"stalled"` ending
  is the progress-aware soft stop: after `config.stall_limit` consecutive
  turns that made no apparent progress (all calls errored, or repeated an
  earlier call), it appends a DISTINCT note naming `config.stall_limit` and
  quoting the last error (or noting the repetition), so a stuck agent is
  caught early and legibly rather than burning the whole `max_turns` budget.
  `max_turns` is deliberately generous because the stall detector, not the
  ceiling, is now the thing that catches spinning. The cleanup wrapper feeds
  the reason (or "error") into the `done` progress event.
- The `thinking` progress event carries `max = cfg.max_turns`; the default
  virt text shows `turn 12/64` so turn burn is visible during long runs.
- `fn.log` (define_default in provider.register()): structured single-line
  JSON appended to `config.log_file` when set (default nil → no-op). Called
  via `pcall(registry.try_call, "fn.log", ev)`:
  - loop: `{ev="run_start"}`, `{ev="turn", turn, messages}`,
    `{ev="tool", name, ms, is_error}`, `{ev="run_end", reason, turns}`
  - provider: `{ev="request", bytes, model}`, `{ev="response", ms, ok,
    status?, stop_reason?}`
  Every entry gets `ts` (os.date "%H:%M:%S") and `buf`. Being a registry
  entry, it is redefinable like everything else.
- README documents `config.log_file` and a "Long sessions" note: context is
  the transcript, so pruning old tool results is just deleting buffer lines.

## provider.lua — registers `fn.provider` (+ `fn.api_key`, `fn.list_models`, `fn.build_tools`, `fn.system_prompt`)

`fn.provider` source: `function(req, ctx) -> { content = blocks, stop_reason = s }`

- POST `https://api.anthropic.com/v1/messages` with headers `x-api-key`
  (from `registry.call("fn.api_key")`, default entry reads
  `vim.env.ANTHROPIC_API_KEY`, falling back to the first line of
  `$XDG_CONFIG_HOME/straps/api_key` — `~/.config/straps/api_key` when
  `XDG_CONFIG_HOME` is unset — refusing a group/other-accessible key file,
  distinct error for a present-but-unreadable file, error with clear message
  if neither source yields a key),
  `anthropic-version: 2023-06-01`, `content-type: application/json`.
- Body: `{ model=config.model, max_tokens=config.max_tokens, stream=true,
  system=req.system (omit if nil), messages=req.messages, tools=req.tools (omit if empty) }`.
  NOTE (LuaJIT): empty Lua tables encode as `{}` not `[]` — omit empty arrays,
  and ensure `input` for tool_use with no args decodes to an object
  (`vim.json.decode("{}")`; use `vim.empty_dict()` where an empty OBJECT is
  required in encoding).
- Streaming: spawn `curl -sS --no-buffer -X POST ... --data @-` (pass body on
  stdin to avoid argv length limits) via `vim.system` with a stdout callback.
  Buffer partial lines; parse SSE (`event:`/`data:` lines). Handle:
  `content_block_start` (text | tool_use), `content_block_delta`
  (`text_delta` → `ctx.emit{type="text_delta", text=...}`;
  `input_json_delta` → accumulate partial_json), `content_block_stop`
  (tool_use: `input = vim.json.decode(partial ~= "" and partial or "{}")`),
  `message_delta` (capture stop_reason), `message_stop` (resolve),
  `error` (reject), ignore `ping`. All emits/resolve via the resolve mechanics
  of `ctx.await`; register curl kill via `ctx.on_cancel`.
- Non-2xx or curl failure → error with status + response body (which arrives
  as a plain JSON body, not SSE — detect and surface it).
- HTTP 429/529 → retry with backoff, max 3 attempts (sleep via
  `vim.defer_fn` + await, not blocking).
- `config.base_url` (default `https://api.anthropic.com`) prefixes
  `/v1/messages` so Anthropic-compatible servers/proxies are a config knob.
- Idle watchdog: `config.request_timeout_ms` (default 300000) — a uv timer
  armed at spawn and reset on every stdout chunk. On expiry it kills curl AND
  resolves the await immediately with a descriptive error (never wait for the
  exit callback: children inheriting stdio can delay it indefinitely). This is
  what prevents an open-but-silent stream from hanging a run forever.

`fn.system_prompt` default source returns the default system prompt (below).

### Live model discovery (`fn.list_models`)

`fn.list_models() -> models | (nil, err)` — a synchronous `curl GET
{base_url}/v1/models?limit=1000` (same `x-api-key`/`anthropic-version` headers
as `fn.provider`, key from `fn.api_key`). Maps each returned model to a picker
entry `{ id, label = display_name, thinking }`. The `thinking` tag is inferred
from the API's own `capabilities.thinking.types`:
`adaptive.supported` → `"adaptive"`, else `enabled.supported` → `"budget"`,
else `nil` (no thinking block). This is the SAME tag `fn.provider` reads to
choose between the two incompatible thinking mechanisms, so a discovered model
gets extended thinking correctly without a hand-written config entry. It never
throws — any failure (no key, curl error, non-2xx, unparseable body) returns
`(nil, errmsg)` so the picker can fall back to the static `config.models`.

`ui.pick_model` calls it and MERGES the result over `config.models`: configured
entries keep their curated `label` and lead the list in configured order; any
live-only model (e.g. a newly released one) is appended with its API
display_name. The merged list is written back to `config.models` so
`fn.provider`'s thinking-tag lookup finds discovered models and repeat pickers
are instant. Fetch failure → notify + the static list; the picker never breaks.

### Prompt caching (cache_control breakpoints)

Default ON via `config.cache = true` (set false for strict compat servers
that reject unknown fields). When on, the provider marks the standard
breakpoints so the replayed prefix becomes a server-side cache hit:

- `body.system` switches to array form:
  `{{ type="text", text=req.system, cache_control={type="ephemeral"} }}` —
  one breakpoint covering the tools+system prefix (request order is tools,
  system, messages).
- The LAST content block of the LAST message gets
  `cache_control = {type="ephemeral"}` — the moving conversation breakpoint;
  each turn's prefix extends the previous turn's cache. (parse() builds fresh
  tables every turn, so mutating them is safe.) Valid on text, tool_use and
  tool_result blocks alike.
- The LAST tool definition also gets a breakpoint: tools lead the prefix, so
  this lets a new session (whose env layer changes the system block) still
  reuse the cached tool definitions.
- **Append-only tool ordering**: registry entries carry a monotonic `seq`
  stamped at first define and preserved across redefines; `fn.build_tools`
  orders by `registry.names_by_seq("tool")`, and `registry.dump()` is
  seq-ordered so restores keep the order. A newly defined tool is appended
  at the end of the tools array, so the existing prefix still matches the
  previous cache (the server checks ~20 blocks back from each breakpoint).
  Redefining an existing tool invalidates only from its position onward;
  hook/fn redefinitions never touch the prefix.
- `config.cache_ttl` (unset = 5m default): "1h" adds `ttl` to every
  breakpoint (GA, no beta header; 2x write cost, break-even ~3 requests) —
  for human-paced sessions where turns exceed the 5-minute default TTL.
- Fourth breakpoint (long conversations only): a trailing intermediate marker
  at a message boundary ~15 content blocks back from the tail. Anthropic
  breakpoints look back only ~20 blocks for a cached prefix, so a tool-heavy
  turn (>20 blocks) would silently miss with only the tail marked. Self-
  limiting: short conversations never accumulate enough blocks to place it.
  Uses the 4th of 4 allowed breakpoints (tools, system, tail, intermediate).
- Usage visibility: capture `usage` from the `message_start` event
  (input_tokens, cache_read_input_tokens, cache_creation_input_tokens) and
  include it in the `fn.log` response event — caching effectiveness must be
  observable, not vibes.

### Compaction (the transcript is the context, so compaction is editing)

- `fn.compact` — a registry entry (define_default in provider.register()):
  `(bufnr, opts?) -> summary string`. The DEFAULT is mechanical, free and
  deterministic — no LLM call:
  - Keep intact: the system block, every user block, every assistant text
    block, and everything belonging to the last `opts.keep_turns` (default 2,
    or `config.compact_keep_turns`) assistant turns.
  - Every OLDER tool_result block's content is replaced with a one-line stub:
    `[compacted: was <N> bytes] <first content line, truncated to ~80 chars>`
    (never emit a line starting with the marker or escape prefix).
  - Every older tool_use block's content (the pretty JSON input) is replaced
    with `{}` when larger than ~200 bytes (stays valid JSON for parse).
  - Returns e.g. `"compacted 14 blocks, 61.2KB -> 3.1KB"`; no-op returns a
    "nothing to compact" string. Must leave the transcript parseable with
    alternating roles (tool_use/tool_result pairing intact — only contents
    shrink, blocks are never removed).
  - LLM-summarizing compaction is a REDEFINITION users or the agent can
    apply; the README sketches it (call fn.provider with a summarize prompt).
- `state.list_blocks(bufnr) -> { {kind, attrs, marker_lnum, first_lnum,
  last_lnum}, ... }` (1-based, content range excludes the marker line;
  empty content → first_lnum > last_lnum). Public helper so compact
  implementations never re-derive the grammar.
- `:StrapsCompact` — resolve_session target, `registry.call("fn.compact",
  bufnr)`, notify the summary.
- Auto-compaction: `config.auto_compact_tokens` (preferred) or
  `auto_compact_bytes` (default both nil = off). The loop checks size at the
  top of each turn (already reading the buffer there); token estimate =
  bytes/3.5. Because each compaction rewrites old message blocks and
  invalidates the messages cache tier, the trigger is COARSE: a per-run growth
  guard (`run.last_compact_bytes`, require ~20% growth since the last compact)
  stops it re-firing every turn when keep_turns content alone exceeds the
  threshold. With caching on, compaction is a context-window tool, not a cost
  tool — set the token threshold near the model's limit. Logs via fn.log
  `{ev="compact", est_tokens, ...}`. Off by default.

### Self-extension activation (prompt) + project registry (.straps.lua)

The machinery exists; these changes make the agent actually USE it, and give
its investments a place to survive the session.

**Core-prompt additions (fn.system_prompt_core):**
- Trigger rules, verbatim intent: done the same manual step twice → define a
  tool/hook before the third time; user says "always" / "every time" /
  "from now on" → that IS a registry_define, not something to remember; a
  tool failing the same way twice → redefine the tool, don't work around it.
- Session-start ritual: first task in a repository → work out build/test/
  lint commands and register them as tools (tool.run_tests, tool.lint)
  instead of retyping bash strings.
- Workflow checkpoint appended to the locate→read→edit→verify loop: "after
  verifying, ask: did I do anything manually that a hook could do
  automatically next time? If yes, install it now."
- Second worked example (different shape from the after_write hook): a full
  registry_define of tool.run_tests wrapping a repo's test command with an
  optional path-filter input.
- Persistence: a trusted `.straps.lua` at the project root is loaded
  automatically; to keep an improvement across sessions, render it with
  registry_get and append the definition to `.straps.lua` (file writes go
  through the normal confirm).
- Calibration: automate observed repetition, not anticipated repetition;
  keep entries small and single-purpose; NEVER loosen hook.confirm or any
  safety policy on your own initiative.

**tool.registry_define doc:** prepend the when-clause "Call this whenever a
behavior should persist beyond the current exchange — " before the existing
mechanics (trigger language in the tool doc itself lifts usage).

**.straps.lua auto-load (init.lua) — direnv-style trust:**
- `M.load_project_registry(opts?) -> loaded(bool), info(string)`. Finds the
  NEAREST `.straps.lua` upward from cwd (vim.fs.find, upward=true). No file →
  false, "none".
- Trust store: `stdpath("data") .. "/straps/trusted.json"`, a JSON map of
  absolute path -> sha256 of file content (vim.fn.sha256). pcall-safe
  read/write; corrupt store treated as empty.
- If the file's current hash matches the stored hash (or `opts.trust_all`,
  for tests/automation): execute via `load(content, "@" .. path)` + pcall;
  errors are vim.notify'd and returned, never thrown. Track (path, hash)
  in-memory so the same content executes at most once per nvim session.
- Untrusted or changed: `vim.fn.confirm("straps: found <path> (not trusted
  or changed since last trust). Execute it? Review it first.", "&Yes\n&No",
  2)`; Yes → persist hash + execute; anything else (incl. headless 0) →
  skip, notify once. NEVER execute untrusted content silently.
- Called from `ui.open_session()` (pcall-wrapped) BEFORE state.new_session,
  so project-defined tools exist for the session's first request and land
  after builtins in seq order (append-only, cache-safe).
- The file itself is plain Lua — `registry.define` calls; `registry.dump()`
  output is valid content. README documents the save-back convention.

## tools.lua — builtin tools (each ~focused; all defined via source strings)

API names (registry names prefixed `tool.`):

- `read_file {path, offset?, limit?}` — numbered lines, cap ~2000 lines.
- `write_file {path, content}` — mkdir -p parent, write; if a buffer holds the
  file, `:checktime` it; then `registry.try_call("hook.after_write", path, ctx)`
  and if it returns a string, append it to the tool result. **`hook.after_write`
  ships as a no-op returning nil** — this is the canonical seam for the
  "auto-run a linter after writes" example.
- `edit_file {path, old_string, new_string, replace_all?}` — exact-match edit;
  error if 0 or (when not replace_all) >1 matches (plain-text find, no
  patterns). Also fires `hook.after_write`.
- `bash {command, timeout_ms?}` — `vim.system({"bash","-lc",cmd})` through
  `ctx.await`; returns exit code + stdout + stderr; default timeout 120s.
- `glob {pattern}` — `vim.fn.glob(pattern, false, true)`, cap 500 entries.
- `grep {pattern, path?}` — prefer `rg` if executable, else `grep -rn`, cap
  output.
- `registry_list {kind?}` — names + kind + doc + version, one per line.
- `registry_get {name}` — returns `registry.render(name)` (full definition).
- `registry_define {name, kind, doc?, input_schema?, source}` — calls
  `registry.define`; `input_schema` arrives as a JSON **string** (schema-of-
  schemas is a tarpit) and is decoded before define. Returns
  "defined <name> v<version>". This is THE self-extension tool: new tools and
  redefinitions of any tool/hook/fn, including the provider and confirm hook.
- `eval_lua {code}` — `load` + pcall, returns `vim.inspect` of results.
  Dangerous by design; gated by `hook.confirm`.
- `spawn {task, system?, tools?, readonly?, show?, max_turns?, model?, effort?, timeout_ms?}`
  — creates a child session buffer (`state.new_session`), chains its registry
  scope under the parent (`registry.ensure_scope`), stamps parentage/task/model/
  effort/timeout vim.b vars, seeds the task, `loop.start`s it, and **returns
  IMMEDIATELY** with the child's buffer handle — it does NOT await. The child
  runs concurrently on its own coroutine. This makes N-way parallelism a matter
  of issuing N `spawn` calls (their children all run at once) instead of one
  blocking call per child run serially.
- `spawn_wait {buffers}` — awaits the named child buffers (validated: live +
  `straps_parent == ctx.bufnr`) in a SINGLE poll loop, so the wait costs the
  slowest child, not the sum. Each child's `straps_spawn_timeout_ms` (stamped by
  `spawn`) is enforced against its `straps_spawn_started_ms` (so time the parent
  spent before calling spawn_wait counts against the child) — an overrunning
  child is `loop.stop`ped and marked timed out; cancelling the parent stops
  every outstanding child. Returns one `## subagent (buffer N)` section per
  child (status + task + transcript path + the child's last assistant text).
  `fn.build_tools` hides BOTH `spawn` and `spawn_wait` at the spawn depth limit.

Default hooks registered here:

- `hook.confirm(name, input, ctx) -> allowed, reason` — auto-allow the
  read-only set `{read_file, glob, grep, registry_list, registry_get}`;
  for everything else `vim.fn.confirm("straps: allow <name>?\n<preview of input>", "&Yes\n&No\n&Always this tool", ...)`
  — "Always" adds the name to an allow-set stored in
  `vim.b[ctx.bufnr].straps_allowed` (buffer state, on theme). Must be called
  on the main loop (wrap in a scheduled await, since we're inside a coroutine
  driven from callbacks).
- `hook.after_write` — no-op (`return function() end` with a doc explaining
  the linter idiom).
- `hook.on_run_start` / `hook.on_run_end` — no-ops.

## System prompt: layered, composed, each layer redefinable

The established harness shape: a harness-owned core prompt + injected
environment context + project memory files. In straps each layer is a registry entry
(define_default in provider.register()), composed by `fn.system_prompt` —
which stays the single entry `state.new_session` calls, so wholesale
redefinition still works and the result still lands in the editable system
block at session creation (env/project content is frozen per session; edit
the block or start a new session to refresh — document this):

- `fn.system_prompt_core()` — the base prompt (below).
- `fn.system_prompt_env()` — generated environment block, one `key: value`
  per line: cwd, platform (`vim.uv.os_uname().sysname`), nvim version, date
  (%Y-%m-%d), and version control: detect `.jj` / `.git` upward from cwd;
  when git, add current branch (`git rev-parse --abbrev-ref HEAD`) and a
  dirty/clean note from `git status --porcelain` line count. All external
  calls via `vim.system({...}):wait(500)` wrapped in pcall — the block
  degrades gracefully to fewer lines, never errors.
- `fn.system_prompt_project()` — ecosystem memory files: the NEAREST
  `AGENTS.md` and the NEAREST `CLAUDE.md` found upward from cwd
  (`vim.fs.find(..., {upward = true})`, two separate searches), plus any
  explicit paths in `config.instructions_files` (list, default {}). Each
  included file is fenced with a header naming its path; each capped at
  20000 bytes with a truncation note; unreadable/missing files are silently
  skipped. Returns "" when nothing found.
- `fn.system_prompt()` — joins core, env (under a `# Environment` heading),
  and project (under `# Project instructions` with a sentence telling the
  agent these come from the project's memory files and must be followed)
  with blank lines; skips empty layers. Composition calls the other three
  through `registry.call`, so redefining any single layer takes effect for
  the next new session.

### Core prompt content (fn.system_prompt_core) — second pass

Written for agent-ability and ecosystem norms; concise, imperative:

- Identity: Cinch, a coding agent inside Neovim via straps.nvim; the
  transcript is an editable buffer; the user sees tool calls and streamed
  text live. (The name is not explained in the prompt itself: a cinch is
  the strap that pulls a harness tight.)
- Output norms (ecosystem standard): be concise and direct; no preamble or
  postamble around actions; reference code as `path:line`; report outcomes
  factually — never claim success that was not observed; if a command fails,
  show what failed.
- Workflow: locate (glob/grep) → read (read_file) before any edit; prefer
  edit_file for surgical changes, write_file for new files; after changing
  code, verify with bash (tests, build, or running the thing); make the
  smallest change that solves the problem; match the surrounding code style.
- Editor-agent powers (this is what distinguishes straps from a terminal
  agent): files the user has open may have unsaved changes; writes reload
  their buffers automatically. `eval_lua` runs INSIDE the user's Neovim —
  use it to read diagnostics (`vim.diagnostic.get(0)` etc.), inspect open
  buffers/windows, jump the user somewhere, or query LSP; prefer it over
  shelling out when the editor already knows the answer.
- Permissions: some tool calls prompt the user for approval; a denial comes
  back as a tool error — respect it, adjust the approach, do not retry the
  identical call. Genuinely ambiguous scope goes through `ask_user`; when the
  options are competing implementations, each is passed as `{ label, preview }`
  with a sketch of that option's code, so the user picks between visible
  sketches rather than one-line summaries (rendered by the snacks picker's
  live preview pane when snacks.nvim is installed, labeled splits otherwise).
- Presentation norms (`# Showing the user`): the editor is the display
  surface — match the medium to the data's shape: show_user for one location,
  the quickfix list for many (grep already fills it), diff splits for
  comparisons, filetype'd scratch buffers for generated content,
  extmarks/virtual text for line-pinned notes, and for editor MECHANISM
  itself (a statusline/winbar/tabline component, keymap, option, highlight
  group) wiring the real thing onto a real window/buffer live rather than
  describing it in prose. `eval_lua` builds any view Neovim can express and
  presentation is a first-class use of it; views are for hand-off (end of a
  task, not every intermediate search; a closing recap referencing 4+
  file:line locations builds the view first), supplement the reply text
  rather than replace it, and superseded ones get cleaned up while the final
  hand-off view stays open.
- Self-extension (kept, tightened): every tool/hook/fn is a registry entry;
  registry_list/registry_get to inspect, registry_define to add or redefine;
  redefinitions are immediate, new tools callable next turn; sources are
  chunks returning `function(input, ctx)`; the hook.after_write linter idiom
  as the worked example — encode persistent behaviors into hooks instead of
  remembering to repeat them.
- Project instructions from AGENTS.md/CLAUDE.md, when present, appear in a
  later section and take precedence over general guidance here.

## Transcript rendering ("Quiet blocks") — fn.render + themed highlights

Presentation layer over the untouched marker buffer. The `%%[straps:KIND]%%`
markers stay the source of truth (parse, persist, request all read real
lines); rendering is display-only extmarks + conceal + folds, and it is a
redefinable registry entry so it can be swapped or turned off at runtime.

Design intent (from the user): color is CATEGORICAL, not decorative — a small
mark per block type for glance-level pattern recognition, never a wash or a
background tint. Nothing hidden in grey-by-default; a collapsed tool keeps a
colored one-line summary. All hues come from the active colorscheme via
`hi default link`, so it is catppuccin now and any scheme later.

### Highlight groups (ui.setup defines; re-applied on ColorScheme)

`nvim_set_hl(0, name, { default = true, link = <target> })` — `default=true`
so a user's own `hi link` wins; re-run on the `ColorScheme` event because many
schemes clear highlights on load.

| group | default link | mark |
| --- | --- | --- |
| StrapsRoleUser  | Function        | the `you` role tag + leading rule segment |
| StrapsRoleAgent | Keyword         | the `Cinch` (agent) role tag + leading rule segment |
| StrapsRoleSystem| Comment         | the `system` tag (dim) |
| StrapsTool      | Special         | `⚙` glyph + tool name |
| StrapsToolOk    | DiagnosticOk    | `✓` on a good result |
| StrapsToolError | DiagnosticError | `✗` on `is_error` |
| StrapsRule      | Comment         | the turn rules |
| StrapsCardBorder| Comment         | the expanded-tool box art |
| StrapsWinbar    | StatusLine      | session-window winbar |
| StrapsFileRef   | Underlined      | path:line refs (treesitter engine) |
| @straps.marker.system      | Title    | marker line, treesitter engine |
| @straps.marker.user        | Question | marker line, treesitter engine |
| @straps.marker.assistant   | Function | marker line, treesitter engine |
| @straps.marker.tool_use    | PreProc  | marker line, treesitter engine |
| @straps.marker.tool_result | Comment  | marker line, treesitter engine |
| @straps.esc                | Special  | `%%[[esc]]` prefix, treesitter engine |

The `@straps.*` targets mirror the `hi def link straps*Marker` block in
`syntax/straps.vim` so both highlighting engines look alike; the ftplugin also
applies these links, so they exist even when `setup()` never ran.

### fn.render(bufnr) — the render pass (define_default in ui.setup's register)

Clears the straps-render namespace and repopulates by walking
`state.list_blocks(bufnr)`. Per block:

- **user / assistant / system marker line** → a `conceal=""` extmark hiding the
  raw marker text, plus an `overlay` `virt_text` at col 0 drawing a turn rule
  (fixed ~52-col): light `─` rules for user and system (`──── you ─────…`,
  `──── system ─────…`), a heavy `━` rule for the assistant
  (`━━━━ Cinch ━━━━━…`, labeled Cinch). The rule char differs per role and the
  leading segment + role word take the StrapsRole* color while trailing bars
  stay dim StrapsRule — a bounded categorical mark, not a wash, sized so user
  and agent turns delineate at a glance. The blank line the writer puts before
  each marker gives vertical separation.
- **tool_use + tool_result run** → left to the fold (below); the marker lines
  are concealed so the open state is clean.
- Rendering is window-agnostic (extmarks are buffer-scoped); conceal needs the
  window opt `conceallevel=2`, `concealcursor=nc` set when the session window
  opens.

Trigger: `nvim_buf_attach(bufnr, false, { on_lines = <schedule render> })`
installed when the session buffer opens — buf_attach fires on BOTH user edits
and programmatic `nvim_buf_set_lines` (unlike TextChanged), so appends and
hand-edits both refresh. Debounce with a per-buffer scheduled guard so a
streaming burst coalesces into one render. Also render once on open.

Idempotent: clears before repopulating, so N renders == 1 render's extmarks.

### Collapse (folds + colored foldtext)

tool_use/tool_result blocks fold (existing foldexpr). Default closed
(`foldlevel=0`) unless `config.tools_expanded`. `foldtext` is a function
returning a **chunk list** `{{text,hl},...}` (Neovim ≥0.10) so the collapsed
summary is colored, NOT hidden grey:
`▸ ⚙ <tool_name>   <first input line / id>   ✓|✗` — StrapsTool on the glyph +
name, StrapsToolOk/Error on the status mark, StrapsRule on the rest.

Expanded tool (fold open): a `virt_lines` header rule above the tool_use
(`╭─ ⚙ <name> ─────`, StrapsCardBorder + StrapsTool) and a closing rule after
the tool_result (`╰────`), with a `result` divider rule before the
tool_result. **No right-hand border / no full 4-sided box** — right-edge
alignment across variable-width content is fragile (the Option-B pitfall);
left-anchored top/divider/bottom rules give the card feel robustly.

### Command-style tool display (fn.tool_display)

Tool calls currently render their input as pretty JSON (`{ "command": "echo hi" }`)
— a data blob. Instead present each call the way it reads as an action: bash as
a shell line, reads/writes/greps as terse verbs.

- `fn.tool_display(name, input) -> string` — registry entry (define_default in
  ui.setup), dispatches on tool name, returns a command-style one-liner.
  Defensive: `input` may be nil / wrong-shaped / missing keys — every branch
  guards and any failure falls back to the default. Builtins:
  - bash → `$ <command first line>` (append ` ⏎…` if multi-line)
  - read_file → `read <path>` (+ `:<offset>+<limit>` when present)
  - write_file → `write <path> (<N> lines)` (N = line count of content)
  - edit_file → `edit <path>`
  - glob → `glob <pattern>` · grep → `grep "<pattern>"` (+ ` <path>`)
  - registry_get → `registry get <name>` · registry_list → `registry list [kind]`
  - registry_define → `define <name> (<kind>)` · eval_lua → `lua <code first line>`
  - default (unknown/agent-defined tool) → `<name> <compact input preview>`
    (roughly today's behaviour; never errors).
- **Coloring rule (honors "color on marks only"):** the caller splits the
  returned string on the FIRST space — the leading token (`$`, `read`, `grep`,
  the verb) is the colored mark (StrapsTool); the remainder (args) is dim
  (StrapsRule). Single-token displays are all-verb. So bash reads as a colored
  `$` prompt + dim command, not a wash.

Wire into both render surfaces, replacing the old `⚙ <name>  <first input line>`:
- `_fold_summary` (the collapsed default view): decode the tool_use block's JSON
  content, call fn.tool_display, render `▸ <verb> <args>   ✓|✗`.
- the expanded card header (`render_block` tool_use): `╭─ <verb> <args> ─────`.
- Add a helper to decode a tool_use block's content to a table (pcall, {} on
  failure) since both sites need the input.
- v1 leaves the expanded JSON body as raw detail (fully terminal-rendering the
  multi-line body is blocked by conceal not removing lines — a possible v2).
  The default (folded) view is command-style, which is the win.

Redefinable like everything: `:StrapsEdit fn.tool_display` to add a formatter
for an agent-defined tool or change the style.

### Redefinable + off switch

- `fn.render` is a registry entry → `:StrapsEdit fn.render` + `:w` reshapes the
  whole presentation live, like every other entry.
- Raw markers: `:set conceallevel=0` (window) shows the real text under the
  overlays, or redefine `fn.render` to a no-op. Document both.
- Never mutate buffer text or `modified`; extmarks/conceal are display-only, so
  parse, persist (buftype="" durable buffers), and `:w` are unaffected.

### config (init.lua)

- `render = true` — master switch; false skips fn.render wiring (raw markers).
- `tools_expanded = false` — fold tools open by default when true.

### Tests — tests/run_render.lua

Build a session buffer with a scripted transcript (user, assistant, a
tool_use+tool_result pair, system). Then, without a real window where
possible, assert on `nvim_buf_get_extmarks(buf, ns, ..., {details=true})`:
- marker lines carry a conceal extmark and an overlay virt_text: a lead rule
  segment + role word in StrapsRoleUser/Agent/System, a dim StrapsRule
  trailing run, and per-role bar chars (light `─` for user/system, heavy `━`
  for the assistant) on lead and trailing alike.
- message body lines carry NO straps-render extmark (color only on marks).
- fn.render is idempotent (same extmark set after two runs).
- the foldtext function (exposed for test) returns a colored chunk list with
  StrapsTool + StrapsToolOk for a good result, StrapsToolError for is_error.
- highlight groups exist and resolve to their link target
  (`nvim_get_hl(0,{name=...,link=true})`), and a user `hi link StrapsTool X`
  survives a re-apply (default=true).
- `config.render=false` → fn.render wiring is skipped / no extmarks placed.
- rendering leaves buffer text and `modified` unchanged, and `state.parse`
  returns the same messages with or without a render pass.
Existing suites must all still pass.

## ui.lua + plugin/straps.lua

- `:Straps` — new session buffer in a split; buffer-local normal-mode `<CR>`
  → `loop.start`; `q` does NOT get mapped (users own their keys).
- `:StrapsSend` (current straps buffer), `:StrapsStop`.
- `:StrapsEdit <name>` (completion from `registry.names()`) — opens
  `straps://registry/<name>` scratch-acwrite buffer containing
  `registry.render(name)`, `filetype=lua`; `BufWriteCmd` executes the buffer
  content as Lua (which re-runs `define`), notifies "redefined <name> v<n>",
  sets nomodified. This works generically because render output is executable.
- `:StrapsRegistry` — scratch listing, `<CR>` on a line opens `:StrapsEdit`.
- `:StrapsEval` — execute current buffer as Lua (eval-buffer).
- `:StrapsAgents` — picker over running agents (`ui.pick_agents`). Rows show
  the session, its parent (`◂ <parent>`, for subagents spawned via
  `tool.spawn`), and the one-line task; picking one brings that transcript
  on-screen with `ui.show_session` (the public form of the old
  `open_session_buffer`), so a running subagent is navigable to watch/steer.
  Backed by `ui.running_agents()` (a snapshot built from
  `loop.running_sessions()` + the child's `straps_parent`/`straps_task`
  buffer vars, which `tool.spawn` sets) and `ui.agents_status()` (the
  statusline component, `""` when idle, `🤖 N` / `🤖 N+M` otherwise).
- Statusline hints: `vim.b[bufnr].straps_status` = "running"|"idle" (+ redraw)
  is the PER-buffer state; `ui.agents_status()` is the buffer-independent
  cross-session count (loop does a `redrawstatus!` on run start/end so a
  subagent starting in the background updates the parent's statusline).
- Per-buffer model / effort: `fn.provider` reads `vim.b[bufnr].straps_model`
  and `vim.b[bufnr].straps_effort` in preference to `config.model` /
  `config.effort`, so two sessions can run different models at once (and a
  subagent can differ from its parent — `tool.spawn` accepts `model`/`effort`
  args and otherwise inherits the parent's override). `ui.pick_model` /
  `ui.pick_effort` write `vim.b` when invoked ON a session buffer, else the
  global config default. `ui.session_status()` renders the effective
  model/effort for the current session buffer (`""` elsewhere), with a trailing
  `*` when a per-buffer override diverges from the global default;
  `ui.session_winbar()` wraps it with a running/idle indicator and is
  auto-installed as a window-local `winbar` on session windows
  (`config.session_winbar = false` opts out).
- Folding for the session buffer: foldexpr folding each `tool_use`/`tool_result`
  block (marker line = fold start, level 1), `foldlevel=0` so results start
  closed. Keep it ~20 lines.
- plugin/straps.lua defines commands lazily (`require` inside callbacks),
  guards double-load with `vim.g.loaded_straps`.

## init.lua

```lua
require("straps").setup{
  model = "claude-sonnet-5",
  max_tokens = 8192,
  max_turns = 64,
  max_tool_result_bytes = 100000,
}
```

`M.config` holds merged config. `setup()`: merge opts, then
`provider.register()`, `tools.register()`, `ui.setup()`. Idempotent (re-running
setup must not clobber user redefinitions: `register()` fns must skip entries
that already exist with version > 1... simpler rule: `register()` uses
`registry.define_default(spec)` — a registry helper that defines ONLY if the
name is absent. Add `define_default` to registry.lua.)
Expose `M.registry`, `M.state`, `M.loop` for user config files.

## Tests (plain asserts, run with `nvim --headless -l tests/<f>.lua`; exit 0/1, print PASS/FAIL per case)

- `run_registry_state.lua`: define/call; redefine changes behavior at existing
  call sites (late binding); bad source rejected & old entry kept; render→
  execute round-trip; dump/restore; transcript: new_session → append user/
  assistant/tool_use/tool_result → parse produces correct Anthropic messages
  (roles merged, ids intact); escaping round-trips a content line that starts
  with `%%[straps:`; empty trailing user dropped.
- `run_loop.lua`: register a stub `fn.provider` (redefine it — this IS the
  architecture test) that scripts two turns: (1) returns a tool_use for a stub
  tool `ping`, (2) returns plain text "done". Stub `hook.confirm` to
  auto-allow. Run `loop.start`, wait via `vim.wait` for completion, assert the
  transcript contains the tool_result and final text, and assert that
  redefining `tool.ping` between turn 1 and 2 (from inside the stub provider)
  would be picked up... (simpler: redefine `tool.ping` BEFORE the run's second
  ping call in a 3-turn script and assert both results differ). Also test
  loop.stop mid-await.

## Native Neovim integration

Make the harness use the editor it lives in. Three workstreams, built in order.

### 1. Editor-native tools (lua/straps/editor.lua, M.register())

New tools in a dedicated module (register() called from init.setup, mirroring
tools/provider). LSP calls are async through ctx.await; tree-sitter tools are
synchronous and need no server, so they are the reliable core. Every tool
degrades gracefully (no client / no parser → a clear message, never an error).
Positions: read_file emits 1-based lines; LSP is 0-based — convert at the seam.

- `diagnostics {path?}` — `vim.diagnostic.get` for path's buffer (bufadd+load
  it) or all loaded straps-relevant buffers when omitted. Returns one line per
  diagnostic: `file:line:col: SEVERITY message [source]`. (Workstream 3 adds a
  quickfix option.)
- `definition {path, line, col}` — load buffer, wait briefly for an LSP client
  (LspAttach is async), `vim.lsp.buf_request` textDocument/definition, resolve
  with the location(s) as `file:line:col`. No client → fall back to
  `taglist(symbol_under_pos)` if a tags file exists, else "no LSP for <ft>".
- `references {path, line, col}` — textDocument/references, same shape; can feed
  quickfix (ws3).
- `symbols {path}` — document outline. Prefer tree-sitter (a locals/@function
  query via `vim.treesitter`) so it works with no LSP; fall back to LSP
  documentSymbol. Returns `name  kind  L<start>-<end>` per symbol.
- `read_symbol {path, name}` — tree-sitter: find the named function/class node,
  return its source text (targeted read instead of the whole file). Ambiguous
  name → list the matches.

All are read-only except none; `hook.confirm` auto-allows the read-only set
(add these names to it). Async LSP tools use ctx.await + a timeout so a wedged
server can't hang the run.

### 2. Native-undo edits (tools.lua: write_file, edit_file)

Apply agent edits THROUGH the file's buffer so they enter its native undo tree
— the user reverts with `u` / `:earlier` / undotree, not just git.

- Load the target into a buffer (`vim.fn.bufadd(path)` + `bufload`), or reuse
  the already-open buffer. Apply the change with `nvim_buf_set_text` /
  `nvim_buf_set_lines` (one undoable edit), then persist by writing THAT buffer
  (`nvim_buf_call(buf, () -> silent noautocmd write)`), leaving modified=false
  and the undo history intact.
- edit_file: exact-match on the buffer's current lines (not a fresh disk read),
  replace via set_text, write. Same 0/1/replace_all error semantics as today.
- write_file: mkdir parents, set all lines (undoable single step), write.
- hook.after_write still fires; its return still appends to the result.
- Already-open buffer with unsaved user changes: the edit stacks on top and the
  write persists the buffer — document this (the agent is editing the live
  buffer, which is the point). A modified user buffer is matched against as-is.
- Result string notes it's undoable (e.g. "wrote foo.lua (undo with u in the
  buffer)").
- Tests: after edit_file, the buffer changedtick rose, an in-buffer `:undo`
  restores the prior content, disk matches the buffer, and a not-yet-open file
  is created + loaded + undoable.

### 3. Quickfix + cdo (tools.lua grep + diagnostics + new bulk_replace)

- `grep`: after searching, ALSO populate the quickfix list — parse rg/grep
  `file:line:col:text` (or `file:line:text`) into `setqflist` entries with a
  title (`straps: grep <pattern>`), and still return the text summary. Results
  become `:cnext`/`:cprev` navigable; `hook.on_progress`-independent.
- `diagnostics`: add `{ quickfix = true }` → also `vim.diagnostic.setqflist`.
- `bulk_replace {pattern, replacement, flags?}` — NEW write tool. Runs
  `:cdo s/<pattern>/<replacement>/<flags||ge> | update` across the CURRENT
  quickfix list (the set grep just made), so it's a native multi-file edit that
  goes through buffers → undoable (ties into ws2). Empty quickfix → error
  ("run grep first to populate the quickfix list"). Escape the delimiter in
  pattern/replacement. Return the count of files changed. Gated by hook.confirm
  (it writes). Optional `{ dry_run = true }` → report matches without editing.
- Tests: grep populates a non-empty quickfix list with correct file/lnum;
  bulk_replace over a seeded qf list edits the files (undoably) and reports the
  count; empty-qf and dry_run paths.

## Style

- Plain Lua, no OO ceremony. Small functions. LuaJIT-safe (no goto needed,
  5.1 stdlib + vim.*). Every module header: 2-4 comment lines saying what it
  owns. Keep total core (registry+state+loop) under ~600 lines if possible.
  `vim.json.encode/decode` everywhere; never build JSON by string concat.
- All buffer mutations from async contexts must go through `vim.schedule` /
  scheduled awaits. Buffers may be mutated only on the main loop.
