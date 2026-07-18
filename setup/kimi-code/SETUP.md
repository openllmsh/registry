---
version: 1.6.40
os: [osx, linux]
gateway_modes: [local, cloud]
name: Kimi CLI
description: Point the Kimi CLI at OpenLLM — adds an `openllm` provider to ~/.kimi-code/config.toml and selects it.
icon: terminal
config_var: OPENLLM_API_KEY
features: ["Local gateway mode by default — points the client at your local daemon (http://127.0.0.1:8787) when one is reachable at install time, so subscription models serve locally with no per-request cloud round trip; switch to cloud mode from the Integrations page (reinstalls with the cloud origin)", "Installs the Kimi CLI if it's missing — reuses your isolated daemon binary when present (no re-download), else runs the official installer", "Merges a [providers.openllm] block into ~/.kimi-code/config.toml (idempotent + non-destructive — backs up first, preserves your other providers)", "Sets base_url to your OpenLLM gateway (type=openai_legacy) + your API key", "Writes a [models.\"<id>\"] entry for every activated model (the Kimi CLI requires one per model, with max_context_size)", "When the local daemon is running, subscription (kimi_code) hops 307 to your machine automatically — detected from your API key, no extra header"]
requirements: ["awk (POSIX — preinstalled everywhere)"]
---

# Kimi CLI

Runs once on your machine. Adds an `openllm` provider to
`~/.kimi-code/config.toml` and makes it the active `default_provider`, so the
Kimi CLI talks to your OpenLLM gateway (OpenAI-compatible surface). When your
local daemon is running + keyed, subscription (`kimi_code`) hops are
307-redirected to your machine's daemon automatically — the gateway detects it
from your API key's activity, so no extra header is needed and the
subscription credential never touches OpenLLM's servers.

The merge is idempotent (re-run any time) and non-destructive: your existing
config is backed up to `config.toml.openllm-bak` and your other providers are
preserved.

## Model entries (no more "Model not configured")

Unlike most CLIs, the Kimi CLI **requires an explicit `[models."<name>"]`
entry for every model** it routes to. Pointing `default_model` at a model with
no table hard-fails at startup:

```
[config.invalid] Model "ultra" is not configured in config.toml.
Add a [models."ultra"] entry with max_context_size.
```

So the setup also fetches a block of `[models."<id>"]` tables — one per
activated model (every fallback chain like `ultra`/`plus`/`lite` + each
connected provider model) — each pointing at the managed `openllm` provider
with its real `max_context_size`. It's generated server-side from the single
source of truth behind `/v1/models`, so it never drifts. Re-run this setup any
time you add a chain or provider to refresh the list.

> The default model is `ultra`. Switch in-session with `/model`, or change
> `default_model` in the managed block — any id with a `[models.*]` entry works.
