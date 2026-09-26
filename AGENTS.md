# You are working on yourself

This repo is straps.nvim — the harness hosting you right now. The loop
that is calling you is `lua/straps/loop.lua`, the prompt you are reading
was assembled by `lua/straps/provider.lua`, and every tool you call was
registered from source under `lua/straps/layers/` and
`lua/straps/editor.lua` (dispatched by `lua/straps/tools.lua`). A bug you
introduce here is a bug in your own
machinery.

# Two copies of everything

Every default tool, hook and fn exists twice: as Lua source in this repo,
and as the registry entry your session is actually running. They are
connected only at setup time, so:

- Editing a file on disk does NOT change this session. Your running
  registry keeps the source it was defined with. Re-running `setup()`
  does not help either: Lua's module cache means the edited file is
  never re-read, and registration uses `define_default`, which skips
  entries that already exist — so even a brand-new entry added to a
  source file will not appear from re-running `setup()`.
- `registry_define` does NOT change the repo. A live redefinition is an
  experiment, not a delivered change, until the same source is in the
  file.
- `require("straps.xxx")` is a THIRD, separate cache from the registry:
  Lua resolves a module once via `package.path`/`runtimepath` and keeps it
  in `package.loaded`. Clearing `package.loaded["straps.xxx"]` and calling
  `require` again does NOT re-read your edit — it re-resolves from the
  SAME path, which is very often not this checkout at all (a plugin
  manager can point this Neovim at a pinned install elsewhere, e.g. a Nix
  store copy). Before attempting any live reload or demo, check which
  file this session is actually running:

      :lua =debug.getinfo(require("straps.loop").start, "S").source

  If that path is not under this repo, stop — no `require`/`package.loaded`
  trick will ever pick up an on-disk edit here. Mirror the change into the
  session's registry with `registry_define` instead (session-scoped,
  reversible), exactly as the flow below describes, and verify the on-disk
  edit headless.

The flow for changing a default: edit the source in the repo, verify
headless (below), and only then — if trying it live is useful — mirror
the new source into this session with `registry_define`.

# Verify headless, not on yourself

A fresh headless Neovim is the only clean reload of edited source, and
the tests provide exactly that. Each `tests/*_spec.lua` is a self-contained
busted spec, run by `nlua` inside a headless Neovim (the root `.busted`
selects both):

    busted tests/<area>_spec.lua

The header of each file states its exact run line. While iterating, run
the spec nearest your change; run the full set before calling the work
done. Run one busted process per file — loop over `tests/*_spec.lua` from
the repo root; a bare `busted` runs them all in ONE Neovim and they leak
state into each other. (`nix flake check` also runs them all, but against
the flake's tracked source, not your working tree.) Specs use
`step(function() ... end)` to sequence fixture code between `it` cases in
document order, so busted's `--shuffle`/`--sort`/`--lazy` are unsupported.

Hot-loading your edit into this session with `registry_define` is a live
experiment on the machinery mid-flight. Session scope makes it
reversible, but a broken `fn.provider`, loop fn, or `tool.edit_file`
breaks THIS session's ability to keep working — often surfacing as a
strange failure in a later, seemingly unrelated tool call. If your tools
start misbehaving right after a redefinition, suspect your own change
first. Never hot-load changes to `hook.confirm` or anything else on the
permission path; verify those headless only.

# Conventions

- `DESIGN.md` is the spec. The three invariants at its top — buffers are
  state, everything is late-bound, agents extend themselves — are
  load-bearing; a change that violates one is wrong even if every test
  passes. When a change alters behavior, update `DESIGN.md` and
  `README.md` in the same change.
- The system prompt itself lives as Lua strings in
  `lua/straps/provider.lua` (`SYSTEM_PROMPT_*_SRC`), including the
  project layer that put this file in front of you. That layer injects
  this file verbatim, capped at 20000 bytes — keep it well under.
  `tests/prompt_spec.lua` covers the assembly.
- Target Neovim >= 0.11, LuaJIT / Lua 5.1 semantics, no dependencies
  beyond `curl`. No plenary.
- Version control is jujutsu (`jj`), colocated with git. Use jj commands,
  and do not create commits, bookmarks or other VCS artifacts unless
  asked.
