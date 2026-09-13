# Contributing

## Requirements

Use Neovim 0.11 or newer. Put `curl` on `PATH`. Ripgrep is optional.

## Tests

Run one focused test while you work:

```sh
nvim --headless -l tests/run_provider.lua
```

Run every test before you submit a change:

```sh
fail=0
for test in tests/run_*.lua; do
  nvim --headless -l "$test" || fail=1
done
exit "$fail"
```

The tree-sitter test builds its parser when a C compiler is available. CI requires the parser and JSON injection tests.

With Nix, run:

```sh
nix flake check
```

## Changes

Keep `DESIGN.md`, `README.md`, and `doc/straps.txt` consistent with behavior changes. Add focused tests for new behavior and regressions.
