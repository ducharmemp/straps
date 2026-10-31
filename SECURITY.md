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

Provider endpoints receive API credentials and complete conversation payloads. Configure custom endpoints only when you trust their operator. A `llamacpp_base_url` or other custom endpoint over `http://` sends the key and the conversation unencrypted, and anyone on the network path can read them or alter the response, including the tool calls it requests; reach a remote server over TLS or an SSH tunnel to `127.0.0.1`.

`:StrapsLogin anthropic`, `:StrapsLogin openai key` and `:StrapsLogin llamacpp` store an API key in `$XDG_CONFIG_HOME/straps/<provider>_api_key` (mode 600, directory 0700). Straps ignores a relative `$XDG_CONFIG_HOME` (the XDG spec requires it) and a relative `$HOME`, so the store never resolves inside the working directory. Straps sends the key to the provider's configured base URL. For llama.cpp that is `llamacpp_base_url`, a remote `http://` server included. A key file accessible by group or other, or whose key contains spaces, control characters or non-ASCII characters, is refused.

A key typed by mistake as a command argument is removed from command history, but Neovim's `:` register keeps that command line until you run another command line; it is not written to ShaDa.

A stored key also overrides a key in the provider's environment variable, including one meant for a different base URL: straps does not record which endpoint a stored key belongs to. `:StrapsLogin` names any set key variable that the stored key overrides, and `:checkhealth straps` reports the key's source (`stored`). A symlinked key file (for example one a secret manager links into place) is read through, but straps never replaces or deletes it.

`$XDG_CONFIG_HOME/straps/` holds secrets: the stored API keys and the ChatGPT login. Keep it out of a dotfiles repository or sync tool that tracks `~/.config`; mode 600 does not stop `git add`. The default permission layer classifies `read_file` and the other read tools as `read` for every path, the key files and `/proc/self/environ` included, so the model can read a stored key without a prompt and the key then enters the transcript and the provider request. Install a `hook.guard` (`:help straps-guards`) that denies reads under that directory if that matters to you.

`:StrapsLogin openai` stores a ChatGPT access token and refresh token in `$XDG_CONFIG_HOME/straps/openai_oauth.json` (mode 600, directory 0700) and uses `openai_oauth.lock` beside it to serialise refreshes across Neovim processes. The refresh token grants ongoing access to the ChatGPT account's API quota; treat the file like a private key. Straps sends the login token only to `https://api.openai.com` (a configured `https://api.openai.com/v1` counts as the same origin) and refuses it for a custom `openai_base_url`. OAuth codes, verifiers and refresh tokens go to curl on stdin, not argv. The bearer token for API requests is still passed in curl's argv, which other local users can read through `/proc`; the same holds for every provider key (`x-api-key` for Anthropic, the Bearer key for OpenAI and llama.cpp).

Session transcripts persist under Neovim's data directory by default. They can contain prompts, source code, and tool output.
