---
version: 1.0.1
name: Raycast
description: Point Raycast AI at OpenLLM — adds an `openllm` custom provider to Raycast's providers.yaml with every activated model.
icon: raycast
config_var: OPENLLM_API_KEY
features: ["Merges an `openllm` provider into Raycast's providers.yaml (idempotent + non-destructive — backs up first, preserves your other custom providers)", "Sets base_url to your OpenLLM gateway (OpenAI chat-completions wire) + your API key as the default bearer credential", "Declares every activated model (each fallback chain + connected provider model) with its real context window — Raycast doesn't auto-discover from /v1/models, so each must be listed", "Derives per-model abilities (vision / tools / reasoning_effort / temperature / system_message) from the gateway catalog so Raycast routes each model correctly"]
requirements: ["macOS with Raycast (custom AI providers require a Raycast Pro / Advanced AI plan)", "python3 OR the config written fresh — used to locate + merge providers.yaml safely", "Enable Settings → AI → Custom Providers in Raycast, then restart Raycast after install to load the models"]
---

# Raycast

Runs once on your machine. Adds an `openllm` custom AI provider to Raycast's
`providers.yaml` so Raycast AI (Quick AI, AI Chat, AI Commands) talks to your
OpenLLM gateway over the OpenAI chat-completions surface.

Raycast's custom-provider feature does **not** auto-discover models from
`/v1/models`, so the setup declares each of your activated models explicitly —
every fallback chain (`ultra`, `plus`, `lite`) plus each connected provider
model — with its real context window and abilities (vision / tools /
reasoning_effort / temperature / system_message) pulled from the gateway's
single source of truth. Re-run any time you add a chain or provider to refresh
the list.

The merge is idempotent (re-run any time) and non-destructive: your existing
`providers.yaml` is backed up to `providers.yaml.openllm-bak` and your other
custom providers are preserved.

## Enabling + reloading

Custom AI providers are behind a Raycast setting:

1. Open **Raycast → Settings → AI** and enable **Custom Providers**.
2. Run this setup (installs the `openllm` provider into `providers.yaml`).
3. **Restart Raycast** — it does not reliably hot-reload the file. Then use the
   **Manage Models** command to confirm the OpenLLM models appear and enable the
   ones you want.

> Requires a Raycast plan that includes custom AI providers. Subscription
> models (`chatgpt/*`, `claude_code/*`, `kimi_code/*`) also require the local
> daemon running + keyed; pure API-key models serve directly.

## Config location

The setup writes to Raycast's config dir (`~/.config/raycast/ai/providers.yaml`
on macOS). If Raycast reports a different location, open **Settings → AI →
Custom Providers → Reveal Providers Config** to find it and re-run from there.
