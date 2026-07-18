---
version: 1.6.40
os: [osx, linux]
gateway_modes: [local, cloud]
name: Claude Code
description: Point Claude Code at OpenLLM — sets ANTHROPIC_BASE_URL + maps Opus/Sonnet/Haiku to ultra/plus/lite.
icon: terminal
config_var: OPENLLM_API_KEY
features: ["Local gateway mode by default — points the client at your local daemon (http://127.0.0.1:8787) when one is reachable at install time, so subscription models serve locally with no per-request cloud round trip; switch to cloud mode from the Integrations page (reinstalls with the cloud origin)", "Installs the Claude Code CLI if it's missing — reuses your isolated daemon binary when present (no re-download), else runs the official installer", "Merges into ~/.claude/settings.json (non-destructive — preserves your existing hooks, permissions, statusLine)", "Sets ANTHROPIC_BASE_URL to your OpenLLM gateway", "Defaults the model to ultra[1m] and maps Opus / Sonnet / Haiku → ultra / plus / lite tier aliases"]
requirements: ["jq OR python3 to merge into an existing settings.json (refuses rather than overwrite if neither is present)"]
---

# Claude Code

Runs once on your machine. The script merges OpenLLM's base URL +
your API key into `~/.claude/settings.json` so the Claude Code CLI
talks to your OpenLLM gateway from then on.
