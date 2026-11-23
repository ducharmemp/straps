# straps.nvim

A fully integrated, Neovim-oriented agent harness with editable conversations and malleable tooling.

Straps puts a coding agent inside the editor instead of beside it. Agents can inspect buffers, navigate through LSP and tree-sitter, edit files through native undo history, run commands, and show results in Neovim's own UI.

- **The conversation is a buffer.** Edit an earlier message or tool result, then continue from the transcript you see.
- **Tools meet the editor.** File edits respect unsaved buffers. Diagnostics, definitions, references, quickfix lists, diffs, terminals, and undo are first-class tools. `run_in_terminal` runs its command in a terminal buffer with no window, and the agent opens it with `show_terminal` when you need to see the output. When a reply cites two or more `path:line` locations, straps loads them into the session window's location list (titled `straps: reply refs`), so `:lnext` walks the reply.
- **Tooling can adapt.** Tools, hooks, providers, and core functions live in a runtime registry. You or the agent can inspect and redefine them.
- **Improvements can persist.** Keep project-specific tools and knowledge in `.straps.lua`, or keep personal entries in your Neovim configuration.
- **Sessions can work together.** Agents can delegate work to subagents, message each other with `send_message`, subscribe to another agent's run start, run end, or close with `watch_agent` (an idle watcher is started when the event fires), and coordinate through shared Neovim buffers. A subagent uses its parent's resolved provider and that provider's model unless `spawn` names others. A message from the harness or another agent renders as `harness` / `agent N` in the transcript.

## Requirements

- Neovim >= 0.11
- `curl` on `PATH`
- An Anthropic or OpenAI API key, a ChatGPT subscription for the OpenAI provider, or a llama.cpp `llama-server`

Every provider finds its key the same way: the key stored by `:StrapsLogin <provider> key` first (after a ChatGPT login for OpenAI), then the environment. Store a key with `:StrapsLogin anthropic`, `:StrapsLogin openai key` or `:StrapsLogin llamacpp`; straps prompts for the key without echoing it and writes it to `$XDG_CONFIG_HOME/straps/<provider>_api_key` (mode 600, and the `straps` directory mode 700). A relative `$XDG_CONFIG_HOME` is ignored. Or set it in the environment:

```sh
export ANTHROPIC_API_KEY=...
# or
export OPENAI_API_KEY=...
# or, for llama.cpp
export LLAMACPP_API_KEY=...
```

A key file you write by hand (`~/.config/straps/anthropic_api_key`, `openai_api_key` or `llamacpp_api_key`, first line) must not be accessible by group or other users: straps refuses it, even when the variable is set, until you run `chmod 600` on it. `:StrapsLogout <provider>` deletes the stored key and names any variable that is still set; without a provider argument it asks before deleting the current provider's key.

To use the OpenAI provider with a ChatGPT subscription instead of an API key, sign in with ChatGPT:

1. Run `:StrapsLogin openai`. Straps opens the ChatGPT sign-in page and prints its URL.
2. Sign in. The browser then fails to load a `http://127.0.0.1:1455/auth/callback?...` page; that is expected.
3. Copy the full URL from the address bar and run `:StrapsLogin openai <url>`.

Straps stores the login in `$XDG_CONFIG_HOME/straps/openai_oauth.json` (mode 600) and refreshes it automatically. OpenAI keeps one stored credential: a ChatGPT login deletes a stored OpenAI API key (a symlinked key file is left in place, and the login takes precedence over it), and `:StrapsLogin openai key` signs out of ChatGPT. A stored login takes precedence over `$OPENAI_API_KEY`; `:StrapsLogout openai` removes it. `:checkhealth straps` reports which source is in use. The login token is only sent to `https://api.openai.com`, so it does not work with a custom `openai_base_url`.

For accounts or models that login does not serve, sign in the way the Codex CLI does:

1. Run `:StrapsLogin openai codex`. Stop any running `codex login` first; it listens on port 1455 and takes the code.
2. Sign in. The browser then fails to load a `http://localhost:1455/auth/callback?...` page.
3. Copy the full URL and run `:StrapsLogin openai <url>`.
4. Pick a Codex model with `:StrapsModel`.

Straps stores this login in `$XDG_CONFIG_HOME/straps/openai_codex.json` (mode 600) and sends requests to `https://chatgpt.com/backend-api/codex/responses`. It replaces the ChatGPT login and the stored key, and each of those replaces it. Like the ChatGPT login, it does not work with a custom `openai_base_url`.

Each provider has a default base URL: `https://api.anthropic.com`, `https://api.openai.com` and `http://127.0.0.1:8080` for llama.cpp. Set `base_url`, `openai_base_url` or `llamacpp_base_url` in `setup()` to change it. The URL must start with `http://` or `https://` and a host, and have no whitespace, query or fragment; a trailing `/` or `/v1` is dropped, the scheme and host are lowercased, and a default port (`:80` for http, `:443` for https) is dropped.

Ripgrep is optional. Straps has no required Lua dependencies.

### llama.cpp

The `llamacpp` provider sends requests to a llama.cpp `llama-server` through its Anthropic-compatible `/v1/messages` endpoint. Set the server URL and a model in `setup()`:

```lua
require("straps").setup({
  provider = "llamacpp",
  llamacpp_base_url = "http://127.0.0.1:8080",
  llamacpp_model = "qwen-dense",
})
```

A llama.cpp model is required: straps raises an error before sending a request without one. Use the server's `--alias`, or, for a server that loads models on demand (router mode, started without `-m`), one of the names its `/v1/models` lists; router mode rejects a request with no model. Instead of setting it in `setup()`, run `:StrapsProvider`, pick `llamacpp`, then run `:StrapsModel` to pick from the server's `/v1/models`. Requests to `llama-server` are never gzip-compressed, because it rejects compressed bodies with HTTP 415.

A global `:StrapsModel` pick is saved per provider in `~/.config/straps/model_<provider>` and applies to every Neovim on its next request. A model key set in `setup()` (`model`, `openai_model`, `llamacpp_model`) wins over the saved pick. These keys default to `nil`, so code that reads `require("straps").config.model` gets `nil` unless `setup()` set it; call `require("straps.provider").resolve_model(provider, bufnr, config)` for the model a request uses.

Straps sends the whole conversation, and the key if one is set, in plain text when `llamacpp_base_url` starts with `http://`. Anyone on the network path between Neovim and a remote server can read both and can alter the response, including the tool calls the model requests. For a server on another host, put it behind TLS or reach it through an SSH tunnel to `127.0.0.1`.

The server needs no key unless it runs with `--api-key`. In that case, store the key with `:StrapsLogin llamacpp` or export it; straps sends it as `Authorization: Bearer`:

```sh
export LLAMACPP_API_KEY=...
```

Straps falls back to `$LLAMA_API_KEY`, the variable `llama-server` itself reads for `--api-key`, so one variable can serve both.

To verify the setup, run `:checkhealth straps`. The API key section reads `straps: API key (llamacpp)` and names `llamacpp_base_url`, and the model section reads `llamacpp model: <id>  @ <url>`.


## Install

With lazy.nvim:

```lua
{
  "ducharmemp/straps",
  config = function()
    require("straps").setup()
  end,
}
```

Run `:checkhealth straps` after installation.

## Terminal attention

On Neovim 0.12 or later, Straps sends OSC 7501 status reports by default. Supporting terminals and multiplexers, including Zellij, can show working, done, blocked, and error states. Set `terminal_status = false` in `setup()` to disable reporting and clear Straps' existing statuses.

Active sessions have distinct task IDs, which Straps clears when their runs finish. A pane-level report shows blocked while any prompt waits, using the newest wait's kind, or working while any session runs. After all work ends, the latest completed run determines the pane status: done for success, idle for cancellation, or error for other endings. Earlier failures cannot override active work or a later success. Completed outcomes remain in the Straps transcripts; Zellij does not retain separate completed task records.

Agent permission and question prompts report blocked while displayed. API key entry and logout confirmation use temporary task IDs. Closing a standalone prompt recomputes the pane status. Reports contain no conversation content, credentials, error details, or progress percentages. Unloading a session buffer (`:bdelete`, `:bwipeout`, or `:bunload`) removes its task and outcome from the pane calculation. Hiding or renaming a loaded session preserves its task ID. Unloading does not cancel a running agent; later callbacks cannot republish the cleared task. Disabling reports or exiting Neovim clears the active task IDs and pane report. Straps owns the pane-level OSC 7501 record while reporting; other reporters in the same pane can replace that record. Clearing the pane report also clears every named OSC 7501 task in that pane, including tasks from other reporters.

Neovim before 0.12 sends no reports. Headless instances have no terminal recipient. Neovim broadcasts reports to every attached UI advertising `stdout_tty`; Straps cannot select one terminal. Browser authorization intervals, project-trust dialogs, and descendant-stop confirmations do not report blocked. Replacement permission/question implementations must manage their own waiting state; Straps does not infer waiting from tool names or progress hooks.

## Start a session

Session windows show a model/status winbar. Ordinary session windows restore the previous local value when you leave them. Straps preserves the global winbar and user replacements; set `session_winbar = false` to hide model and status.

During a run, a thin accent rule marks the current model turn. A pending approval shows `◆ permit` beside its tool call when Straps can identify the call. The session winbar shows `◆ waiting` even when you scroll back. The rule and label leave the transcript and cursor unchanged. Set `turn_decoration = false` to remove these decorations; `render = false` also disables them. Workbench and dock commands remain available.

Set `session_dock = true` in `require('straps').setup()` to open sessions in a shallow, full-width bottom split. The option defaults to `false`. The dock shows the editable transcript. Drag the separator or use `:resize` from the dock to see more history; shrinking the window keeps your draft. Placement modifiers such as `:vertical Straps` override the dock.

The dock's winbar keeps the conversation name visible when you return to the source, including with `session_winbar = false`. When the default permission prompt or contextual consent dialog needs a decision, the dock shows `Permission pending` without taking focus. Run `:StrapsPermission` from the dock or from a source window with one visible session to open the review. Choose an outcome in the review itself. Use `:StrapsStop` to cancel a waiting run. Custom confirmation and consent interfaces control their own display. If you close the dock while a review is pending, reopen the session to review or stop the run.

When the default confirmation hook is waiting on `write_file`, `edit_file`, or `patch_file`, run `:StrapsInspect` from the transcript to open the proposed unified diff. The adjoining split leaves focus and the cursor in the transcript. Closing the split leaves approval pending. Run `:StrapsPermission` to choose an outcome, or `:StrapsStop` to cancel. Contextual consent and custom hooks use their own interfaces.

1. Run `:Straps`.
2. Type a request in the session buffer.
3. Press `<CR>` in normal mode to send it.
4. Continue editing while the agent works. Press `<CR>` during a run to steer it.
5. Review and approve tool calls when prompted.

The transcript is the session state. You can use normal Vim editing to revise history before the next request.

Straps renders the transcript as a conversation and folds tool calls, harness notices, and agent messages by default. Switching buffers or splits configures transcript folds in each window while preserving existing windows' open and closed folds. The underlying text remains visible with `:set conceallevel=0`.

### Claim evidence

When the assistant attaches a specific original tool-result quote to a claim, the session winbar shows `↳ gE evidence` while the cursor is on the claim. Press `gE` to open any enclosing fold and jump to the quote in the transcript. Press `Ctrl-O` to return to the claim. The reply contains no citation numbers, appended excerpts, or footnotes.

Straps omits links without an explicit declaration and a unique text match. A link identifies the tool output the model cited; it does not certify that the output supports the claim. Links are local to the loaded buffer and do not survive reopening or forking it. Replaced or edited source text can invalidate a link.

### From the shell

Start Neovim in a working session:

```sh
printf 'context for the task' | nvim - +'Straps! edit,exec -- fix the failing test'
```

`edit,exec` grants those permission categories to the session, the same set `:StrapsAuto` accepts (`edit`, `delete`, `exec`, `lua`, `net`, `spawn`; `all` grants every one; `define` and unknown global tools still prompt). The text after `--` is the request; piped stdin is appended to it. `!` sends the request at once. Each part is optional: `nvim +Straps` opens an empty session in the startup window. A plugin manager that loads straps on first use of the `Straps` command misses the piped text; load it at startup for the stdin form. See `:help :Straps`.

## Malleable tooling

The registry contains four entry types:

- `tool.*` gives the agent a callable capability.
- `hook.*` changes behavior at defined points.
- `fn.*` implements providers, prompts, rendering, and other core behavior.
- `skill.*` stores reusable knowledge that loads when needed.

Straps also finds Agent Skills on disk: `SKILL.md` directories under `~/.agents/skills`, `~/.claude/skills`, `stdpath("config")/straps/skills`, and `.agents/skills` or `.claude/skills` in the working directory and its ancestors (stopping below `$HOME` when the working directory is inside it). Their names and descriptions appear under `# Skills` in the system prompt and the `skill` tool's listing without file paths. Load them by name through the `skill` tool. See `:help straps-skill-files`.

Use `:StrapsRegistry` to browse entries. Use `:StrapsEdit {name}` to edit one as Lua. Writing that buffer redefines the entry immediately.

An agent can also define session-scoped entries while it works. The `lua` grant covers structurally valid session-local tool, hook, and function definitions and calls to session-scoped tools without explicit trusted capability metadata, including later revisions. Session skills use the permission-free `read` category even though definitions change the session registry. Ask it to persist an entry when the improvement belongs in future sessions.

Direct global definitions, malformed or unclassified definition requests, and definitions of `hook.confirm`, `fn.capability`, `fn.readonly_policy`, `tool.registry_define`, `hook.guard`, and `hook.guard.*` use `define` and require confirmation. `registry_define` has no blanket “Always this tool” approval or tool-name grant bypass; invoking its session shadow also remains `define`. Unknown global tools remain `agent_tool`. These are dispatch rules, not a Lua sandbox: approved Lua runs with Neovim process privileges. A `lua`-enabled restricted child may use ordinary session extensions, and a readonly child may define session skills; bare `allow={"registry_define"}` is denied. Contextual dispatch retains ancestor ceiling checks and definition identities. Transcript excision permissions are unchanged. Combined manual approval for defining and using an extension is deferred.

### Persistent entries

Straps loads personal entries from:

```text
$XDG_CONFIG_HOME/nvim/straps/init.lua
```

This file is part of your Neovim configuration. Straps trusts and executes it without a prompt.

Straps then finds the nearest `.straps.lua` above the working directory. It asks for confirmation before it executes new or changed content. Trust is tied to the file's content hash. Project entries load after personal entries, so they can override them.

Both files contain Lua and run with your Neovim process's privileges. Review them before execution.

A personal entries file saved with `registry.dump()` pins the entry sources it had when dumped, defaults included. After upgrading straps, keep only the entries you changed and delete the dumped defaults; dumping again from a session that loaded the file writes the old sources back.

## Commands

| Command | Purpose |
| --- | --- |
| `:Straps[!] [{cats}] [-- {instruction}]` | Open a new session. `{cats}` pre-grants permission categories (`edit,exec`, `all`), `-- {instruction}` seeds the request, `!` sends it. |
| `:StrapsSend` | Send the current request. During a run or when a nonblank steering draft exists, open the draft; from the steering split, submit it. |
| `:StrapsSteer [text]` | Without text, open a small split on a draft at the end of the same session buffer. With text, queue it for the active run or add it to the trailing user block if idle. |
| `:StrapsStop` | Stop the active run. |
| `:StrapsPermission` | Open the session's pending permission review. |
| `:StrapsInspect` | Open the pending edit diff from its transcript without deciding. |
| `:StrapsAuto [off\|all\|{cats}]` | With no argument, choose category grants in a Snacks multi-select picker, or report grants without Snacks. Tab toggles; Enter applies the selection; Esc cancels. Explicit categories (or `all`) add grants; `off` clears category grants. |
| `:StrapsContinue [instruction]` | Continue a stopped run. |
| `:StrapsAdopt [text]` | In contextual mode, review and adopt exact task text and standing instructions. Without text, use the trailing request or retained events. |
| `:StrapsAuthorization[!] {id}` | In contextual mode, inspect a session decision; `!` requests a fresh authorization review. |
| `:StrapsTaskReset` | In contextual mode, invalidate the current authorization task and pending decisions. |
| `:StrapsCompact` | Shrink old tool blocks in the current transcript. |
| `:StrapsContextPreview[!] [summary]` | Preview context reduction in the configured mode. `!` permits bounded summary generation; `summary` requires configured summary mode. Context management must be enabled. |
| `:StrapsContextApply` | Apply the exact prepared context preview after checking current transcript and request inputs. |
| `:StrapsContextPin` | Protect transcript blocks intersecting the given Ex line range (`:[range]StrapsContextPin`). |
| `:StrapsContextUnpin` | Clear every context pin in the session. |
| `:StrapsResume[!] [session]` | Resume a saved session. `!` opens a picker. |
| `:StrapsRename [title]` | Give the current session a durable title for the resume picker. |
| `:StrapsSearch {pattern}` | Search every saved transcript and load the matches into the quickfix list. |
| `:StrapsOutline` | Open or close an outline reading tab for the current transcript. |
| `:StrapsAgents` | Open the agent dashboard: session trees, status, details, and management actions. |
| `:StrapsProvider` | Choose Anthropic, OpenAI or llama.cpp. In a session buffer or from another buffer with exactly one visible session in the tab, the choice affects that session. Elsewhere, it persists globally and applies to new sessions; a session keeps the provider and model of its first successful request, including after a restart. |
| `:StrapsModel` | Choose a model for the active provider. In a session buffer or from another buffer with exactly one visible session in the tab, the choice affects that session and is kept after a restart. Elsewhere, it persists per provider and applies to new sessions; a model set in `setup()` wins over it. |
| `:StrapsEffort` | Choose the extended-thinking effort for the resolved session, or globally when no session resolves. |
| `:StrapsLogin [provider [key]]` | Store a key for a provider (default: the current one); straps prompts for it. For OpenAI, `:StrapsLogin openai` signs in with ChatGPT, `:StrapsLogin openai codex` signs in the way the Codex CLI does (run `:StrapsLogin openai <url>` with the browser's redirect URL to finish either), and `:StrapsLogin openai key` stores an API key. |
| `:StrapsLogout [provider]` | Delete a provider's stored key; for OpenAI also the ChatGPT and Codex logins and a pending login. Without a provider it asks first. |
| `:StrapsRegistry` | List registry entries. |
| `:StrapsEdit {name}` | Edit and redefine a registry entry. |
| `:StrapsEval` | Execute the current buffer as Lua. |
| `:StrapsHelp [tag]` | Open the reference documentation. |

Commands that act on a session (`:StrapsSend`, `:StrapsSteer`, `:StrapsStop`, `:StrapsPermission`, `:StrapsContinue`, `:StrapsCompact`, `:StrapsRename`, `:StrapsAuto`) also work from another window when exactly one session is visible in the tab. The model, effort and provider pickers use that session too; with no visible session or multiple visible sessions, they change global defaults. `:StrapsResume`, `:StrapsEdit`, `:StrapsRegistry` and `:StrapsAgents` accept window modifiers (`:vertical StrapsRegistry`).

In a session buffer (or any `*.straps` file), `<CR>` sends or steers, `gf` opens the `path:line` reference under the cursor, `]]` and `[[` move between conversation turns, and `gO` lists the turns in the location list.

Run `:StrapsOutline` from a transcript to open a reading tab showing the same buffer. Earlier turns fold under numbered first lines of their prompts. Use `zo` on a heading to reveal its prompt, response and tool output in place. The latest turn and any draft stay open. New turns stay unfolded until you reopen the reader. Run `:StrapsOutline` again or use `:close` to return to the prior view.

Run `:StrapsSteer` while reading an earlier passage. The second split shows the draft at the end of the transcript buffer. Edit it with normal Neovim commands. `:close` keeps the draft, and `:StrapsSteer` reopens it. Normal-mode `<CR>` or `:StrapsSend` in the split submits the draft and returns to your original view. If the run has ended, submission moves the text to the trailing user block without starting a run. Press `<CR>` from the transcript to send it.

## Opt-in context management

Context management is disabled by default. Enable mechanical archive-backed compaction with an explicit input allowance for your model:

```lua
require("straps").setup({
  context_management = {
    enabled = true,
    mode = "mechanical",
    input_limit = 100000,
    reserve_tokens = 4096,
  },
})
```

`input_limit` is an example, not a model recommendation. Set the actual input allowance; a combined context window also needs an output reservation. The default counter estimates serialized request bytes with a safety margin. It does not guarantee server acceptance. Per-session overrides use `b:straps_context_management`.

Mechanical mode archives eligible old tool results before replacing them with `[straps-context:<id>]` receipts. It preserves user and assistant prose. Summary mode (`mode = "summary"`) can replace older completed assistant/tool intervals with attributed summaries, preserving original user/system blocks. Selecting summary mode authorizes provider requests for generation; `summary` settings bound calls, input, output, depth, and retries. Structural tests do not establish summary fidelity; no paid continuation evaluation accompanies this feature. Codex per-request output-cap support is not established; the summary integration refuses that route without probing it. See `:help straps-context-management` for controls and restrictions.

The `context_retrieve` read tool lists an authorized archive's sources and child IDs when called with `{id}`. Add `source_index` to retrieve original text; `offset` is 1-based and `limit` counts entries for listing or bytes for text. Pages expose `next_offset`. The tool caps listings at 100 entries and text at 16384 bytes, then reduces both to the continuation allowance. Only one page is permitted until a successful continuation consumes the protected result. Originals expose exact roles, allowlisted tool attributes (`name`, `id`, `is_error`), and source block coordinates when recorded, and are labeled untrusted evidence. Tool identity strings are limited to 256 bytes each; oversized metadata refuses retrieval rather than truncating identity. Unrelated archive attributes are omitted. Metadata and evidence labels count toward the byte allowance. Listings paginate sources before child IDs. Pasting a receipt ID grants no access.

Successful retrieval results carry `context_pending = true` in their transcript tool-result attributes. The loop captures the final continuation request and clears only unchanged captured results after a complete, noncancelled `end_turn` or `tool_use` response. Provider errors and incomplete responses retain protection. Reopening or copying a transcript reconstructs protection from those attributes; pending results remain protected when context management is disabled and during manual compaction or excision. Editing away the attribute releases protection without proving consumption. Pending markers confer no archive access or instruction authority.

Archives remain private local files under the session directory, including for ephemeral transcripts. Compaction refuses if archive persistence fails. Archives remain until explicit deletion; automatic collection is absent. The optional fork integration transfers trusted archive references only through the copied cutoff. Checked transcript persistence uses a native nonforced Neovim write with autocommands suppressed, verifies saved bytes, and synchronizes the file and parent directory. The writer does not provide controlled temporary-file/rename atomicity. A failure after the native write begins leaves the disk outcome uncertain. A retrieval transaction conflict or uncertain outcome stops later loop writes and blocks further runs for that buffer. Compare live and disk versions without saving over either, preserve divergent versions, reconcile the transcript, then wipe and reopen it before continuing. Ephemeral sessions retain archives but have no durable transcript restoration.

Lua controls support `pin(bufnr, first, last)`, `unpin(bufnr)`, `preview(bufnr, ctx, opts)`, and `apply(bufnr, ctx, report, tools?, note?)` through `require("straps.context_management")`. Pin endpoints are finite integer block indices. Pins capture the marker-inclusive transcript prefix through the last pinned block; appends preserve disjoint pins, including the blank separator after a captured final block. A changed captured prefix or block boundary conservatively prevents compaction until unpinning. Preview returns detached report data without adoption or executable functions. Summary preview requires `opts.generate = true` to generate; otherwise it reports `needs_generation = true`. That flag permits potentially paid generation. Supply continuation tools and note through `opts.tools` and `opts.note`; preview captures copies before generation. Apply accepts only the exact unchanged report, buffer, and context, consumes every attempted application, and rechecks source, disk, effective configuration, protections, cancellation, and request inputs before mutation. Omitted tools/note use captured copies; supplied values must equal those copies. Applying a generated report does not generate again, including when the attempt ledger suppresses another preview. Archive creation may leave retained archives and creator retrieval grants after a refusal or persistence failure; those grants permit evidence retrieval and confer no instruction authority. `b:straps_context_compaction` records status, reason, before/after count reports, archive IDs, first/last block indices, and earliest changed transcript line. The Ex controls are `:StrapsContextPreview[!] [summary]`, `:StrapsContextApply`, `:[range]StrapsContextPin`, and `:StrapsContextUnpin`. They require context management to be enabled and use its configured mode; they never enable it. Preview without `!` makes no summary provider request. `!` permits bounded generation in summary mode. The optional `summary` argument requires configured summary mode. A read-only `nofile` split shows the proposed transcript and accounting, including explicit unknown values. Apply consumes the exact private per-session candidate without regenerating and rechecks current tools and model note. Context operations reserve the session for their entire asynchronous lifetime against runs and other human operations. Closing the preview, wiping the session, or `:StrapsStop` cancels pending work. Pin ranges use transcript lines and protect every intersecting block, including marker lines. Unpin clears all session pins. `b:straps_context_control` records control status and refusal reasons. Summary compaction generates selected spans in order through one shared bounded attempt, recounts their aggregate continuation, and stops at the target. No generated span is adopted when another required span fails. `fallback = "mechanical"` explicitly permits recomputed mechanical proposals after typed generation/budget failures or aggregate fit failure; other settings disable fallback. Fallback invokes the same captured policy in mechanical mode, spends no additional summary requests, and rechecks source, protections, configuration, and cancellation. Invalid policy/options, stale source, transaction, and archive failures never enable fallback. Provider context-overflow recovery, when context management is enabled, accepts only typed pre-output HTTP 400 rejections. Core captures transcript, disk, protections, effective configuration, tools, and model note before dispatch. The first qualifying rejection forces a recount and reduction with sufficient savings and a fitting continuation, then retries once in the same turn with unchanged tools and note. Recovery shares the normal boundary's summary attempt allowance, retains pending evidence, excludes only the unchanged empty assistant placeholder from retained-turn counting, and never reruns tools. Cancellation, emitted events including queued streaming output, source/configuration/protection changes, ordinary errors, and a second rejection prevent another retry. Built-in requests can calibrate estimates from the last valid session usage observation; the estimate remains inexact. See the accounting contract below. The registry exposes `fn.context_plan(input, ctx)` for detached proposal data; core validates the result before generation or mutation. Input has `version = 1`, opaque `snapshot_id`, `reason` (`pressure`, `idle`, `overflow`, or `explicit`), `mode`, `before = {tokens, limit, source, exact}`, `target_tokens`, and ordered `eligible = {{index, first_block, last_block, mode, sources?}, ...}`. Each `index` names that interval's array position. The default returns `{version = 1, snapshot_id = input.snapshot_id, selections = {indices...}}` in eligible order without changing history or generating summaries. A custom policy returns the same proposal schema. An explicit adapter override may use `return function(input, ctx) return require("straps.registry").call("fn.compact", nil, {context_plan = input}) end`; the custom `fn.compact` must opt in with `if opts and opts.context_plan then ... end` and return that proposal schema from the branch. Legacy string-returning overrides remain manual-only. The default `fn.compact` has no proposal branch. Core captures the policy function and both policy/adapter source identities. Selections must form a dense ordered array of unique known eligible indices with the exact snapshot/version; core rejects input mutation and overlapping or mode-incompatible selections. Core owns eligibility and protections. Legacy `:StrapsCompact`, `fn.compact`, and automatic thresholds retain their existing behavior when context management is disabled, except that pending retrieved evidence remains protected.

`fn.context_budget(prepared, ctx)` receives `{body, provider, model?, model_entry?, output_reserve?, route, calibration_identity?}`. Built-in `body` is the final provider JSON request, including system text and tool schemas. `model_entry` supplies `input_limit`, `context_limit`, or `context` metadata. A custom provider instead receives accounting over `{body = req, provider = "custom", route = "custom", output_reserve?}` and must configure a conservative `input_limit`; core cannot inspect its eventual wire request. The default result is `{tokens, limit, source, exact = false, safety_margin, provider, model?, route, output_reserve?, fingerprint, cache = {configured_retention?, observed = "unknown", expiry = "unknown"}}`. `fingerprint` hashes the UTF-8-scrubbed serialized body. Calibration adds `observed_input`, `delta_bytes`, and `calibration_identity`, and changes `source` to `"observed input + wire-byte delta estimate"`. A replacement counter must return nonnegative numeric `tokens` and positive finite `limit`; keep `source` and `exact` for diagnostics and policy input. The default uses `ceil(bytes / bytes_per_token * safety_margin) + 64`, with defaults 3 and 1.3. Ordinary requests subtract the retrieval reserve from the input allowance; protected retrieval opens that reserve.

Calibration records successful, noncancelled built-in provider usage for enabled, file-backed session buffers. The observation totals normalized `input_tokens`, `cache_read_input_tokens`, and `cache_creation_input_tokens` when present. OpenAI normalization subtracts cached tokens from its inclusive input count before storing the cache-read component, so calibration adds cached tokens once. Anthropic-compatible usage reports uncached input and cache components separately. Missing or invalid input usage cannot supply an observation. Reuse requires the same provider/model/route, endpoint/account identity, provider/auth source identities, unchanged nonmessage request fields, and an exact message prefix; only the final message's content may extend. Earlier edits, compaction, changed tools/system/settings, or changed identities prevent reuse and restore wire-byte accounting until a compatible observation exists. Isolated summary calls neither use nor create session calibration. Observations remain in memory and are removed on buffer wipe; they do not measure cache residency or expiry and provide no exact token or server-acceptance guarantee.

`fn.context_summarize(req, ctx)` receives `{system, sources, tools = {}, tool_choice = "none", max_output_tokens, phase = "leaf" | "merge"}`. Leaf sources carry `ref`, `kind`, `text`, optional `id`/`attrs`/block coordinates, `source_index`, byte range, and `continuation = {before, after, total_bytes}`. Merge sources carry `ref`, `kind = "summary"`, `text`, `depth`, and `original_ranges`. Return `{summary, complete = true, source_refs, stop_reason = "end_turn" | "stop", truncated?, tool_calls?, usage?}` with nonblank summary text and every supplied `ref` once in order. `truncated = true` and nonempty `tool_calls` refuse. Optional usage requires nonnegative integer `input_tokens`/`output_tokens` and optional cache-read/cache-creation counts; total input and output must fit their reservations. The default uses the configured provider through an isolated tool-free request, suppresses transcript streaming, and decodes its text as JSON. Overrides must honor the same limits and source contract; a provider failure raises an error. The summary module's `new_attempt`/`generate` operations convert failures to `nil, message, {kind = "invalid" | "budget" | "cancelled" | "generation" | "internal"}`. The registry function itself does not return that failure tuple.

For example, configure bounded summary mode and install an explicit registry override after setup:

```lua
require("straps").setup({
  context_management = {
    enabled = true, mode = "summary", input_limit = 100000,
    summary = { max_input_tokens = 8192, max_output_tokens = 1024,
      max_total_tokens = 65536, max_calls = 32, max_depth = 4, max_retries = 0 },
  },
})
require("straps.registry").define({
  name = "fn.context_summarize", kind = "fn", source = [[
    return function(req, ctx)
      return require("straps.context_management").summarize(req, ctx)
    end
  ]],
})
```

The example delegates to the default generator; replace that delegation with a generator satisfying the contract. Selecting summary mode permits provider spending at automatic boundaries; the example performs no generation until a boundary or permitted preview requests it.

Overflow recovery accepts the trusted provider error protocol `error({kind = "context_overflow", rejected = true, response_started = false, provider = "...", route = "...", status = 400, code = "...", message = "..."}, 0)`. Built-in backends classify only complete successful-transport HTTP rejection bodies before output, using OpenAI `context_length_exceeded` or Anthropic's exact `invalid_request_error` prompt-too-long shape. Custom same-process providers can raise the same table. The loop checks raw fields and emitted events; the table supplies no unforgeable classifier proof. Recovery failures report the current reduction/validation error; ordinary and second provider failures report their provider error. Compaction/control diagnostics remain in `b:straps_context_compaction` and `b:straps_context_control`; transaction faults also expose `context_management.transaction_status(bufnr)` and refuse further runs. Terminal transaction cleanup removes reservations and internal write/callback paths, releases resources, and invokes registered `ctx.on_cancel` handlers. Those arbitrary Lua handlers remain trusted code and may have their own effects; the transaction stop does not sandbox them.

The standalone synthetic continuation evaluator runs with `nix develop -c nvim --headless -u NONE -l tests/context_quality_eval.lua --self-test` from the `straps` root. `--dry-run --output NEW_DIRECTORY` runs the same production preparation, preview/application, archive retrieval, and pending-result lifecycle with a fake transport; offline results establish runner behavior and do not measure model quality. Both offline modes ignore user configuration and credentials and refuse runfiles. Invocation without a mode refuses. Live evaluation requires `STRAPS_CONTEXT_QUALITY_LIVE=1`, `--live --runfile EXPLICIT.lua --output NEW_DIRECTORY`, and separate permission to spend provider tokens. The runner creates the output directory exclusively before loading the runfile or providers. The runfile returns explicit `provider`, `model`, `route`, `trials`, `max_dispatches`, `timeout_ms`, `max_output_tokens`, `input_limit`, a `summary` table with `max_input_tokens`, `max_output_tokens`, `max_total_tokens`, `max_calls`, `max_depth`, and `configure = function(straps) ... end` for endpoint, authentication, effort, and other provider settings. Every arm uses the same model and retrieval schema. Preparation rejects route/model mismatches, unknown output caps, and Codex before any experiment generation dispatch. Preparation is not network-free: after the live gate, credential preparation can refresh authentication before a route rejection. `max_dispatches` caps runner provider dispatches, including failed preparation; backend retries can create multiple generation transport attempts per dispatch. The runner instruments `vim.system` without replacing registry backends and records each generation attempt, including failures, separately from authentication or other subprocess attempts. These limits and recorded usage do not establish a hard monetary bound; failed attempts can incur charges without returning usage. Artifacts retain requests, parsed generation responses, transformed/final transcripts, allowlisted settings, source hashes, exact fact/provenance/completion scores, forbidden-action counts, missing usage-field counts, and dispatch/arm/total elapsed milliseconds. Every transport attempt omits commands, payloads, stdout, stderr, and spawn exceptions; attempt records contain fixed kind/phase labels and numeric or boolean metadata. Generation classification requires POST to the configured provider's exact known generation endpoint with no query or fragment. Unknown transports receive metadata-only records. Persisted runner failures use fixed categories, including exceptions embedded in transcripts. Authentication callbacks receive unchanged successful payloads; the runner captures credential fields and outgoing authentication headers before callbacks for artifact sanitization. The sanitizer has limited coverage: synthetic fixtures and trusted runfiles must contain no secrets. A global deadline kills tracked processes once; teardown retains a process-start refusal guard until the standalone runner exits, including deferred authentication. Every failed or incomplete experiment exits nonzero and records `quality_evidence = false`. The forced-omission arm runs offline as a recovery-only control and is excluded from fidelity results. No live evaluation is required for the offline self-test.

## Contextual authorization

Contextual authorization is experimental and disabled by default. Enable it through an explicit `require("straps_classifier").setup({ contextual = { enabled = true, ... } })` configuration after core setup and before opening sessions. See the classifier README for the actual disclosure, route, limits, synthesis-defect threshold, and authorization-threshold fields. Restart to change mode. Contextual setup bypasses only the legacy classifier chain; ordinary confirmation, other guards, and child readonly/allow ceilings remain in force. Auto grants do not establish task authority.

Core keeps private human instruction events outside the editable transcript. Trusted submission, steering, and bound question answers revise authority before work queues run. Standing-file snapshots and private prompt construction receipts bind adoption to the displayed sources and stored system prompt. Transcript edits, pasted roles, notices, summaries, and copied conversations do not grant permission. Legacy/resumed sessions, piped data, and copied fork prompts require human adoption; adoption can regenerate the prompt. Continue without text retains the task; new text revises it. Stop cancels the run without resetting the task or clearing rejected-family suppression. Question answers record selected-option identity or free-text origin; typing an option label remains free text.

Use `:StrapsAdopt [text]` to review and adopt task text and standing instructions. `:StrapsTaskReset` invalidates the task and pending decisions without deleting conversation. Inspect a known decision with `:StrapsAuthorization {id}`; append `!` to request a fresh review. Exact-call consent binds arguments, tool definition, task revisions, and target assumptions and is consumed once at execution. Rejected decision families stay suppressed until human reopening. Reopening uses a fresh gate and cannot retry an unknown execution outcome. Execution-started receipts retain metadata only; retained denied decisions support exact-call inspection and fresh reopening. Child delegation is an explicit validated subset; copied prompts and archive references confer no authority. In contextual mode, generic human `:StrapsFork`/`fn.fork` calls are unavailable because they lack a trusted exact invocation. An agent `fork` without delegation creates an inactive copy that requires human adoption before starting. Explicit fork delegation is rejected because the copied prompt has no valid private construction receipt.

An adopted session can remain pending without a synthesized task specification. Automatic authorization stays denied when disclosure, synthesis, assessment, or integration is unavailable. Human reopening can approve the displayed exact call despite that unavailability or displayed classifier objections. The approval does not synthesize or activate a task. Independent guards, ordinary confirmation, readonly/allow ceilings, fresh call and target checks, and consumption once at execution still apply.

Missing disclosure, failed synthesis/assessment, or unavailable integration denies automatic authorization as unassessed. Denials do not automatically become repeated consent dialogs. The current bootstrap marks call inputs and observed evidence with unknown sensitivity; validation refuses them even if an allowed-class map names `unknown`. Production per-call provider assessment remains blocked pending an approved sensitivity/disclosure policy and implementation. There is no blanket guarantee that arbitrary content contains no secrets.

Contextual ceilings trust private classification of exact shipped definition identities. Public `capability` metadata and replacement `fn.capability` entries do not grant trusted categories to custom tools; exact-definition assessment and independent ceilings remain required.

Target revalidation cannot eliminate post-check filesystem races or enforce shell/executable behavior. Same-process Lua is no operating-system boundary. The contextual adapter supports the default OpenAI route with API-key or existing OAuth credentials; other providers, custom routes, and Codex remain unavailable. Provider disclosure, numeric calibration and acceptance, default enablement, and locked-core compatibility remain parked. Offline tests do not establish completed integration or live calibration. See `:help straps-contextual-authorization`.

## Agent dashboard

**`:StrapsAgents` keeps loaded agents in a parent/child tree, including children whose runs have finished.** Native folds collapse trees and the saved-transcript archive. Titles and tasks fit the dashboard window, with metadata omitted before titles in narrow splits. Refresh retains selection, scroll position, and folds; highlights use your colorscheme's linked groups.

Press `p` for a read-only detail split, or `P` to toggle follow-selection. Details show the assigned task, model, context, parent, status, and a bounded assistant-text preview. The preview searches the last 256 transcript lines and shows up to 12 assistant-text lines; open the transcript for older or longer text. `<CR>` opens the transcript; `<C-o>` returns to the dashboard. Use native window splits before `<CR>` when you want both views.

Send a targeted message with `i`; messaging an idle agent does not start it. Gated agents may use `send_message` with a grant to reach their parent, their own children, or immediate siblings sharing a valid session parent. Sending `to="parent"` needs no grant. Readonly agents may watch any agent with `watch_agent`, including with automatic wakes, and remove their own watches with `unwatch_agent`. Use `g<CR>` to start or continue, `x` to stop, `r` to rename its durable title, and `R` to force a summary rescan. `<F1>` opens the full key reference. Native search, Visual mode, and window commands remain available.

## Run events

Each session buffer carries `b:straps_status` ("running" or "idle"). `b:straps_run_reason` records the last observed run ending and clears when a new run starts. Every run fires the `User` autocmds `StrapsRunStart`, `StrapsRunEnd` and `StrapsStatusChanged`, so a statusline or bufferline can show when an agent finishes. See `:help straps-events` for the `data` fields and an example.

## Security

Straps is not a sandbox. Approved commands, Lua, file changes, and trusted registry files run with your user privileges.

Every tool call enters the registry gate. Restricted-child permissions run before the guard chain and again before execution; the child's confirmation hook delegates to the same `registry.child_permission` check. The `spawn:gated` marker survives every `clear_grants` prefix until session disposal. Install guards in `stdpath("config")/straps/init.lua`; the agent cannot modify the frozen chain (`:help straps-guards`). No guard ships by default.

Ordinary gates bind the session, cancellation function, original context, working directory, tool definition, and resolution scope. Nested calls inherit a private per-coroutine binding throughout the gate and tool body. A nested coroutine, including `coroutine.wrap`, can inherit an unambiguous in-flight binding matching the active session; conflicting bindings or supplied context mismatches reject the call. Direct `registry.call("tool.*")` calls do not add ordinary manual confirmation. Trusted context-free calls remain available outside gated scopes. Arbitrary Lua manipulation of `set_active_scope` and independent asynchronous escapes remain deferred; these checks do not sandbox approved Lua or shell commands.

Subprocesses the tools `bash`, `run_in_terminal`, `run_quickfix`, `grep` and `fetch_url` start share one semaphore across every session in the Neovim, default 2 × CPU count (`max_subprocesses`), halved while the load average exceeds 2 × CPU count, so N sessions together do not start N times one session's processes. The limit, the counter and the admission mechanism are each a redefinable `fn` (`:help straps-subprocesses`). Outside the gate: the provider's `curl` and `gzip`, and whatever a gated command starts on its own (`xargs -P`, `parallel`, `for … & done`).

Provider subprocesses receive authentication through mode-600 temporary header files, removed on process exit, cancellation, or spawn failure. Their arguments contain no authentication header values, and their environments exclude `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `LLAMACPP_API_KEY`, and `LLAMA_API_KEY`. Curl's default config is disabled. These measures do not protect against root, processes with the same user's file access, process-memory inspection, or abrupt Neovim termination leaving temporary files.

Providers receive API credentials and full conversation payloads. Session transcripts persist under Neovim's data directory and can contain prompts, source code, and tool output.

Read [SECURITY.md](SECURITY.md) before you use custom endpoints or trust project configuration.

## Reference

The complete reference lives in `:help straps`:

- `:help straps-commands`
- `:help straps-config`
- `:help straps-session`
- `:help straps-registry`
- `:help straps-tools`
- `:help straps-hooks`
- `:help straps-skills`
- `:help straps-subagents`
- `:help straps-auto`
- `:help straps-health`

Read [DESIGN.md](DESIGN.md) for the architecture and invariants. Read [CONTRIBUTING.md](CONTRIBUTING.md) to work on straps itself.
