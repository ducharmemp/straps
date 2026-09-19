# Security policy

## Reporting a vulnerability

Do not open a public issue for an unpatched vulnerability.

Use GitHub's private vulnerability reporting for this repository. Include the affected version, reproduction steps, impact, and any proposed fix.

## Security model

Straps is not a sandbox. Approved shell commands, Lua evaluation, file changes, and trusted `.straps.lua` files run with the Neovim process's user privileges.

### Tool-call guards

`hook.guard.*` entries run before and after every tool call and before every registry define/remove. They are installed from `stdpath("config")/straps/init.lua`, frozen before the first run, and stored outside the registry's public surface, so the agent cannot define, redefine, remove, or shadow one through any tool. No guard ships; see `:help straps-guards`.

A guard enforces policy at the call site; it does not limit what already-approved code can do. Once the user approves an arbitrary `eval_lua` or `bash` call (or grants the `lua`/`exec` category), that code runs in the same Lua state and can reach the guard chain through `debug.*`, `ffi`, `package.loaded`, `load()` of an entry's `source`, the Neovim server socket (`$NVIM`), or by editing the session transcript. A hash-trusted `.straps.lua` has the same reach. Straps does not harden against these; a guard classifying `eval_lua`/`bash` input is where such attempts are visible. The transcript is not tamper-evident under those grants, so a guard verdict is enforcement at the call site only.

`stdpath("config")/straps/init.lua` loads with no trust prompt. Treat writes to it, and to the trust store under `stdpath("data")/straps/`, as privileged.

Provider endpoints receive API credentials and complete conversation payloads. Configure custom endpoints only when you trust their operator.

Session transcripts persist under Neovim's data directory by default. They can contain prompts, source code, and tool output.
