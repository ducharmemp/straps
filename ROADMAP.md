# straps.nvim — roadmap

Ideated but not yet built. Each entry is self-contained enough to pick up
cold. Ordered roughly by value-per-line, not commitment. Delete an entry
when it ships (and fold its design into DESIGN.md).

## Input: ranged `:StrapsAsk` + `@file`/`@symbol` completion

The push direction from editor to transcript is missing. `tool.context`
already *reports* the last visual selection (lua/straps/editor.lua:1542), but
nothing lets the user shove a selection or a file reference INTO the session.

- **Ranged send.** A command with `{ range = true }` — e.g. `:StrapsAsk` —
  that takes the visual selection (or `o.line1..o.line2`) from the CURRENT
  (non-session) file and appends it to the newest session as a fenced block
  with a `path:line-line` header, optionally followed by a prompt line via
  `vim.ui.input`. No existing command takes a range (verified: every
  `nvim_create_user_command` in plugin/straps.lua except `:StrapsResume!` is
  range-less). Sketch:

  ```lua
  vim.api.nvim_create_user_command("StrapsAsk", function(o)
    -- o.line1..o.line2 from the current file -> fenced block into the
    -- newest/most-recent session buffer, path:line header, then optional
    -- vim.ui.input prompt line. Reuse state.append(bufnr, "user", ...).
  end, { range = true, nargs = "?" })
  ```

  Lands in the transcript as:

  ```
  lua/straps/loop.lua:327-341
  ```lua
  for i, block in ipairs(tool_blocks) do
  ...
  ```
  why is this O(n^2)?
  ```

- **`@file` / `@symbol` completion in the session buffer.** An `omnifunc` (or
  a completion source) on the session buffer that expands `@<path>` from the
  project (glob) and `@<symbol>` via workspace symbols, so the user pulls
  context in without leaving the buffer. There is currently no completion of
  any kind on the session buffer (no `omnifunc`/`completefunc`, no cmp/blink
  source — verified absent).

Design notes / open questions:
- Which session does a ranged send target off a non-session buffer? Most
  recent by mtime (state.list_sessions()[1]) is the obvious default; a `!`
  variant could pick.
- Keep it native: reuse `state.append` and the `path:line` ref format the
  `gf` mapping already understands (ui.lua:436), so a pushed ref is
  round-trippable back to the file.

## Registry undo: version history, diff, rollback

The registry is the one thing with no undo. Redefining an entry bumps
`version` and discards the old source (lua/straps/registry.lua:171-182). For a
system whose thesis is "redefine everything at runtime", that is the missing
safety net.

- Keep a bounded ring of previous `{source, doc, input_schema, ts}` on the
  entry.
- `registry_history { name }`, `registry_diff { name, from, to }` (unified
  diff of the two sources), `registry_rollback { name, to }` (redefine from a
  stored source — a new version).
- `:StrapsHistory <name>` opening the diff in a split.
- Related gap: `registry.remove` drops GLOBAL entries only — a session-scoped
  shadow cannot be removed (hit live this session when tool.todo got
  shadowed). Consider a scope-aware remove at the same time.

## VCS tooling

The env layer detects jj/git (fn.system_prompt_env) but there is no VCS tool
at all. The agent shells out via `tool.bash` for every status/diff/log. A
small `tool.vcs` (or a few focused ones) that knows jj-colocated-with-git —
matching this repo's own workflow — would cut a lot of bash. Keep it thin;
jj first (per AGENTS.md), git fallback.

## Findings-list isolation for WINDOWLESS sessions

Shipped: on-screen sessions route grep/bulk_replace/etc. to their window's
*location* list (per-window, private), falling back to the global quickfix list
when the session has no window (ui.lua `session_win`/`set_locations`/
`get_locations`/`locations_do`). Residual gap: a location list cannot exist
without a window, so **windowless subagents still share the global quickfix
list** and two concurrent ones could stomp each other's bulk_replace target.

This is inherent, not a bug to design around: the location/quickfix list IS the
native surface — `:cdo`, `:cfdo`, `:cnext`/`:lnext` and every quickfix-aware
plugin operate on it, so the list must stay the source of truth. (A rejected
idea: store findings in `vim.b.straps_findings` and treat the list as a display
mirror — WRONG, it orphans `:cdo`/`:cfdo`/native navigation from the real set.)

Given that, the only real options are:
- **Accept it.** Windowless subagents rarely run grep→bulk_replace interactively,
  and the on-screen main session (the common case) is already isolated. Cheapest,
  and honest.
- **Give a windowless session a real window on demand.** A location list needs a
  window; before writing findings, ensure the session buffer has one — even in a
  separate/background tabpage the user isn't focused on — so it gets a genuine,
  native, per-window location list the agent's bulk_replace and the user's
  `:ldo`/`:cfdo` both see. Heavier (window/tab lifecycle to manage), but keeps
  everything native.

Leaning toward "accept it" unless windowless-subagent bulk edits become a real
pattern.

## Cost in dollars

Now that token usage is threaded onto `vim.b.straps_usage` (loop.lua) and
rendered in the winbar (ui.usage_status), a price table × tokens gives a
per-session cost readout. A `config.model_prices` map { id -> { input,
output, cache_read, cache_write } per Mtok } and a `$x.xx` winbar segment.
Optional; usage/context % is the more useful signal and already shipped.

## (rejected) Quit guard for running agents

Considered and dropped. A QuitPre/ExitPre hook can only veto a *polite* `:qa`
(by dirtying a buffer, or erroring in the handler — both verified); `:qa!`,
`kill -9`, and crashes bypass it entirely, so it is a false sense of safety.
The real protection is durability, which already exists: the session buffer
is file-backed and `state.persist` writes it at every block boundary
(state.append / ensure_trailing_user), so an abrupt exit loses at most the
in-flight assistant text since the last block, never the conversation.
`:checkhealth straps` already reports runs in flight for the curious.
