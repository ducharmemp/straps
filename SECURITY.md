# Security policy

## Reporting a vulnerability

Do not open a public issue for an unpatched vulnerability.

Use GitHub's private vulnerability reporting for this repository. Include the affected version, reproduction steps, impact, and any proposed fix.

## Security model

Straps is not a sandbox. Approved shell commands, Lua evaluation, file changes, and trusted `.straps.lua` files run with the Neovim process's user privileges.

Provider endpoints receive API credentials and complete conversation payloads. Configure custom endpoints only when you trust their operator.

Session transcripts persist under Neovim's data directory by default. They can contain prompts, source code, and tool output.
