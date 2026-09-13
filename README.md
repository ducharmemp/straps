# straps.nvim

A fully integrated, Neovim-oriented agent harness with editable conversations and malleable tooling.

Straps puts a coding agent inside the editor instead of beside it. Agents can inspect buffers, navigate through LSP and tree-sitter, edit files through native undo history, run commands, and show results in Neovim's own UI.

- **The conversation is a buffer.** Edit an earlier message or tool result, then continue from the transcript you see.
- **Tools meet the editor.** File edits respect unsaved buffers. Diagnostics, definitions, references, quickfix lists, diffs, terminals, and undo are first-class tools.
- **Tooling can adapt.** Tools, hooks, providers, and core functions live in a runtime registry. You or the agent can inspect and redefine them.
- **Improvements can persist.** Keep project-specific tools and knowledge in `.straps.lua`, or keep personal entries in your Neovim configuration.
- **Sessions can work together.** Agents can delegate work to subagents and coordinate through shared Neovim buffers.

## Requirements

- Neovim >= 0.11
- `curl` on `PATH`
- An Anthropic or OpenAI API key

Set a key in the environment:

```sh
export ANTHROPIC_API_KEY=...
# or
export OPENAI_API_KEY=...
```

You can instead store the first line of the key in:

- `$XDG_CONFIG_HOME/straps/api_key` for Anthropic
- `$XDG_CONFIG_HOME/straps/openai_api_key` for OpenAI

Key files must not be accessible by group or other users. With the default configuration directory:

```sh
chmod 600 ~/.config/straps/api_key
chmod 600 ~/.config/straps/openai_api_key
```

Ripgrep is optional. Straps has no required Lua dependencies.

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

1. Run `:Straps`.
2. Type a request in the session buffer.
3. Press `<CR>` in normal mode to send it.
4. Continue editing while the agent works. Press `<CR>` during a run to steer it.
5. Review and approve tool calls when prompted.

The transcript is the session state. You can use normal Vim editing to revise history before the next request.

Straps renders the transcript as a conversation and folds tool calls by default. The underlying text remains visible with `:set conceallevel=0`.

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

## Commands

| Command | Purpose |
| --- | --- |
| `:Straps` | Open a new session. |
| `:StrapsSend` | Send the current request or steer an active run. |
| `:StrapsStop` | Stop the active run. |
| `:StrapsContinue [instruction]` | Continue a stopped run. |
| `:StrapsResume[!] [session]` | Resume a saved session. `!` opens a picker. |
| `:StrapsProvider` | Choose Anthropic or OpenAI. In a session buffer, the choice affects that session. Elsewhere, it persists globally. |
| `:StrapsModel` | Choose a model for the active provider. |
| `:StrapsRegistry` | List registry entries. |
| `:StrapsEdit {name}` | Edit and redefine a registry entry. |
| `:StrapsHelp [tag]` | Open the reference documentation. |

## Security

Straps is not a sandbox. Approved commands, Lua, file changes, and trusted registry files run with your user privileges.

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
