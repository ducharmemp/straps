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

## Start a session

Session windows show a model/status winbar. Leaving the buffer or window removes only the Straps expression and restores the prior local value. Returning to the session restores its winbar. Straps preserves the global winbar and user replacements; set `session_winbar = false` to disable the session bar.

1. Run `:Straps`.
2. Type a request in the session buffer.
3. Press `<CR>` in normal mode to send it.
4. Continue editing while the agent works. Press `<CR>` during a run to steer it.
5. Review and approve tool calls when prompted.

The transcript is the session state. You can use normal Vim editing to revise history before the next request.

Straps renders the transcript as a conversation and folds tool calls by default. The underlying text remains visible with `:set conceallevel=0`.

### From the shell

Start Neovim in a working session:

```sh
printf 'context for the task' | nvim - +'Straps! edit,exec -- fix the failing test'
```

`edit,exec` grants those permission categories to the session, the same set `:StrapsAuto` accepts (`edit`, `delete`, `exec`, `lua`, `net`, `spawn`; `all` grants every one; `registry_define` and agent-defined tools still prompt). The text after `--` is the request; piped stdin is appended to it. `!` sends the request at once. Each part is optional: `nvim +Straps` opens an empty session in the startup window. A plugin manager that loads straps on first use of the `Straps` command misses the piped text; load it at startup for the stdin form. See `:help :Straps`.

## Malleable tooling

The registry contains four entry types:

- `tool.*` gives the agent a callable capability.
- `hook.*` changes behavior at defined points.
- `fn.*` implements providers, prompts, rendering, and other core behavior.
- `skill.*` stores reusable knowledge that loads when needed.

Use `:StrapsRegistry` to browse entries. Use `:StrapsEdit {name}` to edit one as Lua. Writing that buffer redefines the entry immediately.

An agent can also define session-scoped entries while it works. Ask it to persist an entry when the improvement belongs in future sessions.

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
| `:StrapsSend` | Send the current request or steer an active run. |
| `:StrapsSteer {text}` | Queue `{text}` as steering for the active run. With no run, add it to the trailing user block. |
| `:StrapsStop` | Stop the active run. |
| `:StrapsAuto [off\|all\|{cats}]` | With no argument, choose category grants in a Snacks multi-select picker, or report grants without Snacks. Tab toggles; Enter applies the selection; Esc cancels. Explicit categories (or `all`) add grants; `off` clears category grants. |
| `:StrapsContinue [instruction]` | Continue a stopped run. |
| `:StrapsCompact` | Shrink old tool blocks in the current transcript. |
| `:StrapsResume[!] [session]` | Resume a saved session. `!` opens a picker. |
| `:StrapsRename [title]` | Give the current session a durable title for the resume picker. |
| `:StrapsSearch {pattern}` | Search every saved transcript and load the matches into the quickfix list. |
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

Commands that act on a session (`:StrapsSend`, `:StrapsSteer`, `:StrapsStop`, `:StrapsContinue`, `:StrapsCompact`, `:StrapsRename`, `:StrapsAuto`) also work from another window when exactly one session is visible in the tab. The model, effort and provider pickers use that session too; with no visible session or multiple visible sessions, they change global defaults. `:StrapsResume`, `:StrapsEdit`, `:StrapsRegistry` and `:StrapsAgents` accept window modifiers (`:vertical StrapsRegistry`).

In a session buffer (or any `*.straps` file), `<CR>` sends or steers, `gf` opens the `path:line` reference under the cursor, `]]` and `[[` move between conversation turns, and `gO` lists the turns in the location list.

## Agent dashboard

**`:StrapsAgents` keeps loaded agents in a parent/child tree, including children whose runs have finished.** Native folds collapse trees and the saved-transcript archive. Titles and tasks fit the dashboard window, with metadata omitted before titles in narrow splits. Refresh retains selection, scroll position, and folds; highlights use your colorscheme's linked groups.

Press `p` for a read-only detail split, or `P` to toggle follow-selection. Details show the assigned task, model, context, parent, status, and a bounded assistant-text preview. The preview searches the last 256 transcript lines and shows up to 12 assistant-text lines; open the transcript for older or longer text. `<CR>` opens the transcript; `<C-o>` returns to the dashboard. Use native window splits before `<CR>` when you want both views.

Send a targeted message with `i`; messaging an idle agent does not start it. Use `g<CR>` to start or continue, `x` to stop, `r` to rename its durable title, and `R` to force a summary rescan. `<F1>` opens the full key reference. Native search, Visual mode, and window commands remain available.

## Run events

Each session buffer carries `b:straps_status` ("running" or "idle"). `b:straps_run_reason` records the last observed run ending and clears when a new run starts. Every run fires the `User` autocmds `StrapsRunStart`, `StrapsRunEnd` and `StrapsStatusChanged`, so a statusline or bufferline can show when an agent finishes. See `:help straps-events` for the `data` fields and an example.

## Security

Straps is not a sandbox. Approved commands, Lua, file changes, and trusted registry files run with your user privileges.

Every tool call passes a guard chain you install in `stdpath("config")/straps/init.lua` and the agent cannot modify (`:help straps-guards`). No guard ships by default. A guard is a filter and a tripwire, not a boundary: an approved `eval_lua` or `bash` call runs in the same Lua state as the guard.

Subprocesses the tools `bash`, `run_in_terminal`, `run_quickfix`, `grep` and `fetch_url` start share one semaphore across every session in the Neovim, default 2 × CPU count (`max_subprocesses`), halved while the load average exceeds 2 × CPU count, so N sessions together do not start N times one session's processes. The limit, the counter and the admission mechanism are each a redefinable `fn` (`:help straps-subprocesses`). Outside the gate: the provider's `curl` and `gzip`, and whatever a gated command starts on its own (`xargs -P`, `parallel`, `for … & done`).

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
