---
version: 1.6.39-registry.9
os: [osx, linux]
name: OpenLLM CLI
description: Install the openllmc CLI — the compiled extension runtime that serves the unified OpenLLM MCP server (native gateway API + code search + memory) and the hook subcommands the openllm plugin uses.
icon: terminal
requires_key: false
features: ["Downloads + verifies the openllmc binary for your OS/arch against its published SHA-256 sidecar (a checksum, not a detached signature)", "Adds `openllmc` to your PATH + installs shell completion (bash/zsh/fish) automatically on a terminal install — a one-click (dashboard) install runs sandboxed and skips it; run the setup command shown below afterwards", "Serves ONE MCP server exposing the full native gateway API (every OpenAPI operation), semantic code/docs search, and persistent memory", "Self-updates against the gateway's pinned release (checksum-gated atomic swap)", "No bun / node required — a self-contained compiled binary"]
requirements: ["macOS or Linux (no Windows)", "curl + shasum/sha256sum for checksum verification"]
post_install: ~/.openllm/bin/openllmc setup
---

# OpenLLM CLI

The `openllmc` binary — the single extension runtime behind the `openllm`
plugin. One compiled executable that serves the unified MCP server
(`openllmc mcp`: native gateway API tools generated from the OpenAPI spec,
claude-context code/docs search, supermemory recall) and the hook
subcommands (`openllmc ctx index|search|status|index-docs`) the plugin's
session hooks shell out to.

Installing the **openllm plugin** runs this install automatically
(`ensure_openllmc`) — use this setup directly when you want the CLI alone
(e.g. to script against the gateway API, or to pre-provision a machine
before installing the plugin).

The binary is downloaded from your gateway (`/api/cli/binary/<os>-<arch>`,
a 302 to the pinned GitHub release asset), gunzipped, verified against the
committed SHA-256 sidecar, and installed atomically to
`~/.openllm/bin/openllmc` (next to `openllmd`).

A **terminal (curl) install runs `openllmc setup` automatically** — PATH
symlink + shell completion, nothing else to do. A **daemon-driven install**
(the dashboard's Install button) runs sandboxed, where PATH dirs and shell
rc files are deliberately read-only, so setup is skipped there. Everything
still works (the MCP entry + hooks use the absolute path); to use
`openllmc` from your shell after a one-click install, run:

```sh
~/.openllm/bin/openllmc setup
```

It's idempotent — symlinks into `/usr/local/bin` or `~/.local/bin` and
wires completion into your shell rc. Re-run it any time.

Manage it from the terminal once installed:

- `openllmc mcp` — the unified MCP server over stdio (what
  `mcpServers.openllm` runs).
- `openllmc exec ctx <index|search|status|index-docs>` — the hook verbs.
- `openllmc setup` — PATH symlink + shell completion (idempotent).
- `openllmc api --spec` — print the embedded OpenAPI spec.
- `openllmc self-update` — converge to the gateway's pinned release.
- `openllmc version` — print the installed version.

Configuration comes from `LLM_GATEWAY_URL` / `LLM_GATEWAY_API_KEY` (env) or
the shared `~/.openllm/.env` (`OPENLLM_CLOUD_ORIGIN` / `OPENLLM_API_KEY` —
the same file the daemon pairing writes, so one pairing covers every tool).
The plugin install wires the env vars into the MCP entry for you.
