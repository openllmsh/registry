---
version: 1.6.39-registry.8
os: [osx, linux]
name: OpenLLM Daemon
description: Install the local daemon that runs subscription providers (Claude Code, Codex, Kimi) on your machine — required for subscription-OAuth, never routes those credentials through the cloud.
icon: cpu
requires_key: true
features: ["Downloads + verifies the openllmd binary for your OS/arch against its published SHA-256 sidecar (a checksum, not a detached signature)", "Puts `openllmd` on your PATH so you can `openllmd start | stop | status` (with shell completion)", "Runs subscription inference locally via the official vendor CLIs' own credentials", "Background-installs any missing subscription CLI (Claude Code / Codex / Kimi / Grok) with its official installer — the daemon runs them but never installs them itself", "Installs a launch agent (macOS) / systemd user unit (Linux) so it runs headless — auto-restarts on crash and survives logout + reboot (enables linger on Linux)", "Pairs to the selected API key (written locally, mode 0600) — re-run any time to reconfigure with a different key"]
requirements: ["macOS or Linux (no Windows)", "curl + shasum/sha256sum for checksum verification"]
---

# OpenLLM Daemon

A small headless program that runs on your machine. It serves the
**subscription** providers (`claude_code`, `chatgpt`, `kimi_code`)
locally by delegating to each vendor's **official CLI** using that CLI's
own credentials and identity — so a subscription token never touches
OpenLLM's servers and nothing is forged.

The daemon dials OUT to the OpenLLM cloud over your API key — the
dashboard drives it (status, connect, install) through that channel, with
no browser→localhost connection. API-key (BYOK) providers keep running on
the hosted gateway as before; only subscription chains require the daemon.

After install the daemon runs in the background, paired to the API key you
selected, and the gateway routes that key's subscription models to it
automatically (detected from the key's activity). Open the dashboard's
Providers tab to connect each vendor. Re-run this installer with a
different key any time to re-pair the daemon.

Manage it from the terminal once installed:

- `openllmd start` — (re)start in self-restore mode (auto-restarts on crash,
  survives logout + reboot).
- `openllmd stop` — stop the daemon **and** disable all self-restore (it
  stays down until the next `openllmd start`).
- `openllmd status` — show service registration + run state.
- `openllmd --help` — full command list. Shell completion (bash/zsh/fish) is
  installed automatically; re-enable later with `openllmd completion install`.
