# Contributing

## Requirements

Use Neovim 0.11 or newer. Put `curl` on `PATH`. Ripgrep is optional.

The tests run under [busted](https://github.com/lunarmodules/busted) with the
[nlua](https://github.com/mfussenegger/nlua) interpreter, which runs each spec
inside a headless Neovim. Install both for Lua 5.1 (Neovim's LuaJIT ABI):

```sh
luarocks --lua-version 5.1 install busted
luarocks --lua-version 5.1 install nlua
```

With Nix, `nix develop` provides both.

## Tests

Run one focused spec while you work:

```sh
busted tests/provider_spec.lua
```

Run every spec before you submit a change, one busted process per file:

```sh
fail=0
for spec in tests/*_spec.lua; do
  busted "$spec" || fail=1
done
exit "$fail"
```

Each spec assumes a fresh Neovim (buffers, autocmds, `PATH`, the registry
singleton), so do not run them in one process. The root `.busted` selects
`nlua` and the `tests/` directory. A spec's `step(...)` blocks sequence fixture
code between `it` cases in document order; `--shuffle`, `--sort`, `--lazy` and
`--repeat` break that order and are unsupported.

The tree-sitter spec builds its parser when a C compiler is available. CI requires the parser and JSON injection tests.

With Nix, run:

```sh
nix flake check
```

## Changes

Keep `DESIGN.md`, `README.md`, and `doc/straps.txt` consistent with behavior changes. Add focused tests for new behavior and regressions.
