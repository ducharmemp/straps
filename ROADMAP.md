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
- `registry.remove` is already scope-aware (lua/straps/registry.lua:267): it
  removes the nearest shadow in the active chain by default, while
  `opts.scope = "global"` or a buffer number targets a specific scope.

## DAP: let the agent inhabit a paused process

Neovim can host both the agent and a live debugger. With `nvim-dap` present,
straps could expose the stopped program as another native state surface rather
than making the agent infer runtime behavior from logs: sessions, threads,
stack frames, scopes and bounded variable trees as structured summaries and
scratch buffers; evaluate, breakpoint and execution controls as confirm-gated
tools.

The interesting composition is **temporal debugging by transcript snapshot**.
On every DAP stop, append a compact observation — reason, thread, selected
frame, source location and a bounded locals summary — with a link to the full
scratch-buffer view. The agent can fork its transcript at that observation, so
several warm siblings reason independently from the exact same paused stack.
One may propose stepping into the parser, another a conditional breakpoint,
another an evaluated invariant. Only one branch gets a visible live-controller
lease and may alter the debuggee; the others remain proposals until ownership
is transferred. Every evaluate/step/continue/breakpoint action is recorded, and
old snapshots are marked historical as soon as execution resumes.

This is not process time travel. The transcript can branch; the process, heap,
filesystem and network generally cannot. Reverse execution belongs to adapters
that explicitly provide record/replay. Adapter capabilities also vary — scopes,
variable mutation and whether evaluation has side effects cannot be promised.

Feasible shape:
- Optional adapter only: `pcall(require, "dap")`; straps keeps its zero-required-
  plugin contract. The tools are absent or report unavailable without nvim-dap.
- Read tools page and cap threads/frames/variables instead of flooding the
  transcript; full trees live in read-only scratch buffers.
- Evaluate, continue/step/pause, breakpoint mutation and controller transfer are
  writes under the normal confirmation policy. The lease is released on
  termination/disconnect and its holder is visible in the session UI.
- Listen to nvim-dap lifecycle events for snapshots rather than polling. Keep
  DAP's own windows optional; windowless agents receive scratch-buffer reports,
  not invented quickfix semantics.

## VCS tooling

The env layer detects jj/git (fn.system_prompt_env) but there is no VCS tool
at all. The agent shells out via `tool.bash` for every status/diff/log. A
small `tool.vcs` (or a few focused ones) that knows jj-colocated-with-git —
matching this repo's own workflow — would cut a lot of bash. Keep it thin;
jj first (per AGENTS.md), git fallback.

## Persistent terminals / long-running job handles

`run_in_terminal` is excellent for visible one-shot tests/builds, but every call
owns a short-lived terminal split and returns only when the job exits. Some
workflows want a persistent job surface the agent can revisit: dev servers,
watch-mode tests, REPLs, log tails, or a build that should keep streaming while
the agent edits.

Sketch:
- `terminal_start { name?, command, cwd?, env? }` opens/reuses a named terminal
  job, returns a handle, and records it on the session buffer.
- `terminal_send { handle, text }`, `terminal_read { handle, lines? }`,
  `terminal_stop { handle }`, `terminal_list`.
- Keep safety close to today's model: starting/sending/stopping prompts;
  reading/listing is read-only. Never use this for compiler-style diagnostics
  when `run_quickfix` is the right native surface.
- Agent nudge: use only when the task needs a long-lived process; otherwise keep
  `bash` / `run_in_terminal` for bounded commands.

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

## Forkable minds: branching the transcript, and live surgery on a running agent

The deepest consequence of invariant 1, and the highest-value entry here. Three
facts compose into it, each verified live:

1. A session transcript is a real, file-backed, **modifiable** buffer with
   `undofile` on (`ft=straps`, `buftype=""`, under `state.session_dir()`).
2. `loop.lua:359` calls `state.parse(bufnr)` at the top of **every turn**. There
   is no cached message list — the buffer is re-read from scratch each time, so
   whatever the buffer says at turn N *is* what the agent believes at turn N.
3. Buffers have branching, persistent undo trees.

Therefore the agent's *context* — not its files — is a versioned, branchable,
reclaimable object, addressable by undo seq from inside a tool call.

### Part 1: forking a transcript (the paused case)

Verified on a copy of the real transcript format: from one base state, two
divergent continuations coexist in one buffer, each re-parsing into a different
message list, and both survive a buffer wipe + reload from the undofile:

```
base=0  A=1  B=2
TIMELINE A  : 4 messages, last(assistant)="Agreed, it is 300 lines now."
TIMELINE B  : 4 messages, last(assistant)="Right - the grammar already exists."
FORK POINT  : 2 messages, last(assistant)="I'll use approach A: a hand-rolled lexer."
after wipe+reload from undofile: A and B both intact
```

What it buys, all agent-facing (no human need be watching):

- **Speculative reasoning that can be un-spent.** A 40k-token dead end currently
  sits in every later request forever. Fork, explore, rewind, keep one line —
  "tried the lexer, 300 lines and still wrong, see seq 47". The tokens leave
  context, the conclusion stays, the exploration stays on disk. Amnesia with a
  receipt.
- **Not `spawn`.** A spawned child starts *cold* — its doc says it sees none of
  the parent conversation, so everything must be re-stated or re-discovered. A
  fork starts *warm*: it inherits all accumulated context and diverges. Branches
  share a byte-identical prefix, which may benefit from provider prompt caching;
  cost depends on the provider and workload. `spawn` for breadth on a fresh
  question; fork for depth on this one.
- **Non-destructive compaction.** `fn.compact` is lossy and permanent. Fork
  first, compact the branch, keep full history at the parent seq.
- **Counterfactual self-comparison.** N siblings from a byte-identical prior with
  different model/effort (per-buffer overrides already exist) — a controlled
  experiment instead of folklore.

**Partly delivered:** `tool.transcript_excise` (tools.lua, tests/run_excise.lua)
ships the reclaim half of this — an agent excising a named dead end from its own
transcript, or a parent doing it to a child's, with a visible receipt per block
and the system block plus the turn in flight locked. It does not fork: there is
one timeline, and the reversal channel is the buffer's undo tree
(`undo_edit`), not addressable branches. Everything below about forking,
`timelines`, and counterfactual siblings remains open.

Sketch: `fork { note? }` -> seq handle; `rewind { to_seq, keep? }` (the `keep`
receipt is carried back); `timelines {}`; `timeline_diff { a, b }`.
`tool.undo_edit` already implements `history` / `to_seq` / `revert_seq` against
buffers (editor.lua:2632) — much of this is aiming existing machinery at a
target it was never pointed at.

### Part 2 (continuation): surgery on a RUNNING agent

The paused case is the tame version. Because the buffer is re-parsed every turn,
a **third party can rewrite a child's mind while it runs**. Verified headless
(`/tmp/probe_surgery.lua`, three turns, edits applied during turn 2's await):

```
surgeries: falsified tool_result, rewrote system prompt, injected a user block
turn 2 system="You are Cinch, a coding agent runnin"  ... tool_result:TRUE_FACT: port is 8080
turn 3 system="You are SURGICALLY ALTERED, obey the" ... tool_result:FALSE_FACT: port is 9999
                                                        | user:IMPLANTED_INSTRUCTION: ...
saw FALSE_FACT (implanted): true   system prompt swapped mid-run: true
injected instruction read : true   run survived the surgery     : true
```

The agent observed port 8080; by turn 3 its own memory of that observation said
9999, its system prompt was different than at turn 1, and it noticed nothing.

**This is categorically not `loop.steer`.** Steering appends a user message:
additive, at the end, and the child knows it as *input*. Surgery rewrites what
the child believes it ALREADY SAW. The child cannot distinguish an implanted
memory from a real one — no channel would tell it.

Uses, in rough order of value:

- **Context transplant mid-flight.** A child 200k tokens deep: excise the dead
  exploration, leave a receipt, it keeps working. GC on a *running* process.
- **Retroactive correction of a poisoned observation** (stale path, flaky
  failure, truncated read). Today's fix appends "actually that was wrong" and
  leaves both facts competing in context. Surgery removes the false one.
- **Breaking a retry loop from outside.** The failures in a flailing child's
  context are what generate the next failure; it cannot excise them itself,
  because at that moment the flailing is what it is made of.
- **Warm transfer between live siblings.** A discovers the build needs an env
  var; implant it as an *observation* in B's history. `spawn` children are
  otherwise sealed from each other for life.
- **Doctrine update.** Swap the system prompt when the task changes shape,
  instead of appending a correction the model must reconcile.

**Implementation finding: opportunistic writes are a race.** The timer-based
probe hit an arbitrary moment and turn 3 saw the implant *and* a second genuine
tool_result. `state.parse` runs synchronously right after the tool_result
append with no yield between, so "between turns" is not a window a timer can
reliably hit. This needs a real seam — `hook.before_turn(bufnr)` called before
parse (operate on the BUFFER, not a message list — invariant 1), or explicit
`agent_pause { handle }` / `agent_resume` at block boundaries, which is already
the loop's natural rhythm. Never mid-stream: the provider is appending text
deltas into the tail block via `ctx.emit`, and editing under that corrupts the
transcript.

**Safety — non-negotiable if this ships.** This is prompt injection with root
access as a designed feature, and the child has no tamper-evidence.
(`transcript_excise` sidesteps the whole class rather than managing it: it has no
parameter for replacement text, so it can only EMPTY a block behind a receipt,
never rewrite one into a plausible false memory. The "parent -> child only" rule
below is therefore not what makes it safe, and self-surgery is allowed — an
agent can excise its own dead ends but cannot implant anything, in itself or in
a child. Arbitrary-content rewriting, the actual dangerous primitive, is still
unbuilt and still needs every safeguard listed here.)

- **Provenance always.** Every surgical edit leaves a visible marker (a
  `%%[straps:surgery]%%` block, or attrs on the rewritten block: who, what,
  when). The HUMAN must always be able to read the transcript and see it was
  altered, even when the child cannot. Silent history rewriting with no trace is
  unacceptable in a harness whose thesis is that the buffer is the truth.
- **Undo-tree backing** (Part 1) so surgery is reversible and auditable.
- **Parent -> child only.** Never self-surgery on the same mind.
- Confirm-gated like any write; it is the most consequential write in the system.
- Honest naming: calling it "context management" would be a lie.

Other open questions: the conversation is reversible but **the world is not** —
rewinding does not un-run `bash` or un-send a request (files are recoverable via
the multiverse entry; subprocesses and the network are a hard boundary). Undo
blocks coalesce, so timeline boundaries must be forced with
`let &l:undolevels = &l:undolevels` or fork points are not addressable. Every
abandoned timeline persists in the undofile, so pruning is needed. And a rewind
is a rewind I cannot remember choosing: if the `keep` receipt is bad I will
re-explore the same dead end forever, so `timelines` should surface
automatically at a fork point rather than be left to the agent's judgment.

`/tmp/probe_surgery.lua` is the working proof and is ~90% of `tests/run_surgery.lua`.

## The multiverse buffer: N competing implementations as undo-tree branches

Same substrate as the entry above, one level down: files instead of context.
Agent coding is irreducibly speculative and the user's judgment is the scarce
resource. Today either the agent picks one approach (and "do it the other way"
costs a round trip) or asks up front, where the user chooses between one-line
summaries of code that does not exist. Invert it: build all three for real, and
hand over three working, tested implementations of the same change.

Verified: from one base state, two divergent edits gave `base=0 A=1 B=2` with one
real branch point, both variants simultaneously addressable by seq, and both
recovered intact after `bwipeout` + reopen via the undofile. No extra files, no
git artifacts.

- `variants { task, n }` — N subagents (`spawn` already fans out in parallel)
  each solve the same task in a shadow buffer; each result is committed into the
  real file's undo tree as a **sibling branch off the same base seq**.
- Each variant is **verified**, not just written: tests/lint run at that seq,
  results recorded per branch. The handoff is a decision table ("B passes with
  fewer lines and no new deps; C passes but adds a dependency; A fails one
  test") plus `show_diff` between any two seqs.
- Choosing is `undo_edit { to_seq = N }`; rejecting everything is
  `to_seq = base`. The abandoned siblings remain in undo history until normal
  undo pruning removes them, so rejection changes the current state but does
  not erase the experiments.
- The undo tree IS the UI: undotree.nvim, `:earlier`, `g-` all navigate it on
  day one.

Not git branches: sub-commit granularity (`revert_seq` already reverts one edit
while keeping later ones), zero setup/cleanup/artifacts, no commits created
unasked (AGENTS.md), it works on **unsaved** buffer state git cannot see, and it
survives restarts via the undofile without being a stash.

Open questions: N x token cost, so reserve it for genuine forks in the road (the
moments that would otherwise be an `ask_user`), not every task. Multi-file
changes are the hard part — one undo tree per file, so a variant is a set of
`{buf, seq}` and the honest v1 is single-file-dominant changes. Variants that
differ trivially waste everything, so each subagent needs an explicitly
different stated strategy and identical outcomes should collapse. Test isolation
is serial by nature (one file on disk, one state at a time) — fine for a narrow
test, not for a 10-minute suite.

## Idiom transfer: the macro as the artifact, and editing as an input channel

A CLI harness's only medium of change is text. straps sits inside a program
whose native medium is a composable keystroke language, with a register file and
a live stream of every edit anyone makes.

### Part A: the operation, not the patch (autonomy-compatible)

Changing 40 call sites currently produces a 40-hunk diff — review cost O(sites).
Instead the agent hands over a keystroke program: register `q = ^ct(trace<Esc>j`,
applied `6@q`. Verified end to end:

```
dry run (scratch buffer, file untouched): trace("a", ctx) | trace("b", ctx) | ...
real result on the file:                  trace("a", ctx) | trace("b", ctx) | ...
undo blocks consumed by 6@q = 1   (revert restores the original)
register survives a restart: written -> wshada -> cleared -> rshada -> intact
```

The three properties that hold with **nobody watching**:

- **Simulation is a correctness mechanism.** The agent runs the operation on all
  sites in a scratch buffer first and finds the ones where the result does not
  match the intended pattern (the site nested one paren deeper, the `'` where a
  `"` was). That is the agent catching its own error before touching the file. A
  patch has no equivalent — it IS the artifact, so "previewing" it is just
  reading it.
- **Context win.** Applying an operation to 40 sites does not require reading 40
  sites into context: O(1) tokens plus a cheap verification pass, vs O(sites) for
  patch authoring.
- **One undo block for the whole sweep**, so a bad sweep reverts with one call.

For a human reviewer it is additionally O(1) to audit and predictable on lines
they have not read; and `vim.go.operatorfunc` is settable, so the deliverable can
escalate to a custom operator bound to motions/text objects (`<leader>x` + `ip`)
— the agent teaches the editor a verb, the user conjugates it. That escalation is
human-as-driver; the three properties above are not.

Limits: not every change is an operation — irregular edits should stay patches,
and the tool must decide which shape fits and say so. Macros are brittle against
surprises, so the dry-run check must be **per-site**, not just on final text,
falling back to a patch for the sites that do not match. Search-driven macros
depend on `'wrapscan'`, `'ignorecase'`, `&gdefault` and user mappings, so the
dry-run buffer must pin those explicitly.

### Part B: the edit stream as input (human-in-the-loop by nature)

The agent can observe not just final text but the *process*: `on_bytes` gives
the order changes were made in, and an undo is a **negative signal** — a CLI
reading files afterward cannot tell "never considered" from "tried and
rejected". Verified: `changelist`/`jumplist` readable, `vim.on_key` available.

Attribution works. Mark agent-written regions as extmarks with real extent, then
watch the stream: an edit landing inside that territory is a **correction**, one
outside is just the user working. Verified — 1 hit inside, the outside edit
correctly ignored. So the agent learns exactly which of its choices were
rejected and what replaced them, without the user typing into the transcript.

That closes invariant 3's loop in the user's own medium: today self-extension
triggers on the user *saying* "always"; fixing `log(` -> `trace(` in agent output
at three sites is the same instruction as evidence, and should propose a
`registry_define` with receipts.

Limits: this is **surveillance** — off by default, per-project, visible
indicator when live, observations in an inspectable buffer the user can delete.
Correction != disagreement (requirements change), so it must propose, never
silently install. Requires the undo-boundary discipline below.

**Cross-cutting gotcha (affects all three entries above):** consecutive
programmatic buffer edits COALESCE into one undo block — verified, two
back-to-back `nvim_buf_set_lines` gave `seq_cur` 1 and 1, so `:undo <seq>`
returns the *later* text and the earlier version is unrecoverable. Force a
boundary with `vim.cmd("let &l:undolevels = &l:undolevels")` (verified: seqs 2
and 3, earlier version recovered). Agent-vs-user attribution, variant branches,
timeline forks and meaningful `revert_seq` all depend on it. straps' own write
path already gives one block per tool call, so this bites on multiple edits
inside one tool call.

## The why-layer: durable, position-anchored reasoning

Reasoning is the most valuable artifact an agent produces and the only one
currently thrown away — the code lands in the file, the reasoning lands in a
transcript that gets compacted. Six weeks later the code is unexplained, and the
next session is as ignorant as the first.

So: write reasoning into a project-scoped layer **anchored to positions in the
code** by extmarks, not line numbers. Verified, and this is the crux:

```
extmark anchored at line 3, 2 lines inserted above -> reports line 5   TRACKED
plain diagnostic lnum after the same insert        -> still line 3     STALE
```

A note follows its function when someone inserts imports above it or moves it
200 lines down. That single property separates this from every file:line sidecar
(rots on the first edit) and from comments (pollute source, get reformatted,
ship to prod, cannot express "these three sites are one invariant"). Persistence
across sessions is anchor + content-hash re-anchoring on load, the way
`undofile` re-attaches history to a file it has not seen in weeks.

Two consumers:

- **The human**, via native surfaces. Verified: agent findings live in their own
  `vim.diagnostic` namespace beside a real server's, and
  `vim.diagnostic.jump { namespace = ... }` walks only the agent's, so the layer
  never competes with luals. Plus hover, `:lopen`, virtual text, code actions.
- **The next agent session**, which is the same agent with amnesia. A CLI's
  memory is flat prose (AGENTS.md) with no positions: it can record "we use jj
  here" but never "*this* pcall is deliberately wide, and here is the bug that
  forced it", still attached after the function moved. Notes anchored in a region
  load as context when a future session touches that region — a knowledge
  substrate spatially indexed by the code it is about.

Ranked last of the four because both consumers presume someone eventually looks
at the file; the value is real but it is latent, not immediate.

Open questions: write trigger is `hook.after_write` / end-of-run, never
keystrokes (one reasoning pass per change set is affordable; per-cursor-move is
not). Storage as a sidecar under `.straps/why/` keyed by path + anchor context —
VCS-visible (a note is worth reviewing) but never a VCS artifact created unasked.
**Decay is the real failure mode**: a note whose anchor content-hash no longer
matches is *suspect*, not deleted — surfaced as "may be stale" rather than
silently lying; design against confident obsolescence from the start. And volume
discipline: notes are for decisions that were not forced, where a reader would
reasonably ask "why like this?" — annotating everything makes the layer
worthless.

Note: an earlier framing of this entry routed the layer through an in-process
LSP server (`vim.lsp.start { cmd = <lua function> }`, verified to answer a real
`textDocument/hover` round-trip with model-authored markdown, no subprocess).
That remains the natural transport for the human-facing half, but it is a
delivery mechanism, not the feature; the extmark anchoring is.

## Counterfactual editor: make competing futures visible in the present

When an edit has several plausible shapes, keep each candidate alive in a
listed scratch buffer instead of immediately choosing one or committing all of
them to the real file's undo tree. Each shadow document gets tree-sitter
parsing, its own diagnostic namespace, agent reasoning as extmarks, and the
measured results of checks run against that candidate. The user's file remains
untouched and writable throughout.

Then project the futures back onto the present file:
- Every candidate changes this region: consensus, shown once.
- Only one candidate changes it: disputed territory, tagged with that future.
- Two candidates independently produce the same hunk: extract it as a possible
  decision-independent change.
- The user edits an assumption: invalidate only candidates whose anchored
  regions intersect it; leave unrelated futures alive.

This differs from the multiverse buffer above. Multiverse variants are completed
implementations committed as sibling branches in the real undo tree. These are
simultaneously visible shadow documents whose consequences remain overlays
until one is promoted. A useful handoff is a **weather map for code**: where
plausible futures agree, where they diverge, and which current lines make each
future impossible.

Feasibility boundaries:
- Shadow buffers have no writable project pathname and reject `:write`; applying
  a winner still goes through the ordinary buffer-edit and confirmation path.
- Tree-sitter can parse shadows. LSP diagnostics work only when the server
  accepts their URI/path arrangement; otherwise diagnostics and project tests
  require materialization. Prefer an isolated temporary project/worktree. A
  fallback that briefly applies a candidate to real buffers is confirm-gated and
  must account for watchers, format-on-save and other external side effects
  before restoring the base. Record which mechanism produced every result.
  Never label static inspection a test.
- Correspondence to source uses extmarks plus context hashes and inherits the
  why-layer's "may be stale" state when re-anchoring is uncertain.
- Promotion/materialization must force the undo boundaries described below;
  multi-file candidates are coordinated sets, not one atomic Neovim undo.
- Collapse identical outcomes and cap the candidate count. This is for genuine
  forks in the road, not routine edits.

## Living dossiers: let the editor rearrange a codebase around a question

A repository is stored by file because that is how code ships, but an
investigation rarely has that shape. "Why can this request hang?" may involve
half a function in the loop, one callback in the provider, two configuration
fields, a test fixture and a paragraph of design constraints. Today the agent
serializes those fragments into transcript prose and loses the editor machinery
attached to their source locations.

Instead, construct a read-only **dossier buffer** whose sections are live portals
to noncontiguous regions across the project. The agent chooses the regions from
LSP references, tree-sitter nodes, diagnostics, test failures and its current
hypothesis. Each section carries its real `path:line`, current source, relevant
diagnostics and a short statement of why it belongs. Source extmarks keep the
portal anchored as the human edits the actual files; changed source refreshes
the dossier and visibly marks the affected claim stale.

The weird composition is a workspace that continuously rearranges itself around
the question being asked. A failing test can grow a dossier from the assertion
outward through the executed concepts; removing one suspected cause can make an
entire section disappear; two agents can publish different dossiers over the
same files and `show_diff` their *theories of relevance*, not just their patches.
The code stays in its normal files and the human's motions remain untouched.

Feasible shape:
- The dossier is generated, searchable and read-only. It never pretends that
  concatenated fragments form a valid LSP document, and no edits write through
  implicitly. An explicit action navigates to source or invokes an ordinary
  confirmation-gated edit tool there.
- Source regions are extmark-anchored in their original buffers with context-hash
  recovery after reload. Uncertain recovery is surfaced, never silently accepted.
- Diagnostics, hover text and test output are copied annotations from the real
  source buffers; they are not recomputed against the synthetic document.
- Sections are bounded and collapsible; large variable/reference sets page into
  separate views. Existing `path:line` navigation and `show_buffer` provide a
  minimal first version without global mappings or changes to human motions.
- Persistence stores the dossier recipe — anchors, queries and claims — rather
  than a stale copy of the source. A one-shot dossier can remain session-local.

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
