---
version: 1.6.39-registry.8
os: [osx, linux]
name: Codex
description: Point the Codex CLI at OpenLLM — adds an `openllm` model_provider to ~/.codex/config.toml and selects it.
icon: terminal
config_var: OPENLLM_API_KEY
features: ["Installs the Codex CLI if it's missing — reuses your isolated daemon binary when present (no re-download), else runs the official installer", "Merges a [model_providers.openllm] block into ~/.codex/config.toml (idempotent + non-destructive — backs up first, preserves your other providers)", "Sets base_url to your OpenLLM gateway with wire_api=responses + your key, defaulting the model to the ultra fallback chain", "Fetches a model_catalog_json of your activated models so Codex stops warning 'model metadata not found' and sizes auto-compaction correctly", "When the local daemon is running, subscription (chatgpt) hops 307 to your machine automatically — detected from your API key, no extra header"]
requirements: ["awk (POSIX — preinstalled everywhere)"]
---

# Codex

Runs once on your machine. Adds an `openllm` provider to
`~/.codex/config.toml` and makes it the active `model_provider`, so the Codex
CLI talks to your OpenLLM gateway over the **Responses API**
(`wire_api = "responses"` → `/v1/responses`). When your local daemon is
running + keyed, subscription (ChatGPT / Codex) hops are 307-redirected to
your machine's daemon automatically — the gateway detects it from your API
key's activity, so no extra header is needed and the subscription credential
never touches OpenLLM's servers.

The merge is idempotent (re-run any time) and non-destructive: your existing
config is backed up to `config.toml.openllm-bak` and your other providers are
preserved.

> The key is written inline as `experimental_bearer_token` so the setup is
> self-contained (no shell-profile env var needed).

## Choosing a model

The setup flags **`ultra`** as the default `model` — the OpenLLM fallback
chain — so Codex routes there out of the box with no extra step.

To run a different model, pass **`-m <model>` before launch**:

```sh
codex -m anthropic/claude-opus-4-8      # any catalog id
codex -m chatgpt/gpt-5.5                 # a concrete subscription model
codex -m plus                            # another chain alias
```

Any OpenLLM v1 id works: concrete catalog ids (`anthropic/claude-opus-4-8`,
`chatgpt/gpt-5.5`, `alibaba/qwen3.6-plus`), chain aliases (`ultra`, `plus`), or
`custom:<entry>/<model>`. To change the default permanently, edit `model =` in
the managed block of `~/.codex/config.toml`.

> Codex's in-app **`/model` picker only lists OpenAI models** — it never
> queries `/v1/models`, so it won't show your gateway's catalog. Reaching any
> other OpenLLM model is done with `-m` at launch (or the `model =` line above),
> not the picker. The gateway's `/v1/responses` surface accepts any model
> string and resolves it through the same chain/catalog resolver as every other
> endpoint.

## Model metadata (no more "metadata not found" warning)

Codex resolves each model's context window and auto-compaction threshold from
its **own** bundled catalog, keyed by slug. It has no entry for our fallback
aliases (`ultra`, `plus`) or non-OpenAI ids (`anthropic/*`, `alibaba/*`,
`custom:*`), so it would otherwise warn:

```
Model metadata for `ultra` not found. Defaulting to fallback metadata;
this can degrade performance and cause issues.
```

…and then size auto-compaction against a wrong 272k window.

To fix this the setup also writes **`model_catalog_json`** to
`~/.codex/openllm-models.json` — a catalog generated server-side from *your*
activated models (every fallback chain + connected provider model), each slug
carrying its real context-window metadata. It's pulled from the single source
of truth behind `/v1/models`, so it never drifts. `chatgpt/*` ids are left out
on purpose — Codex already resolves those to its own built-in metadata.

Re-run this setup any time you add a chain or provider to refresh the catalog.

> Subscription models (`chatgpt/*`, `claude_code/*`, `kimi_code/*`) require the
> local daemon running + keyed; pure API-key models (`anthropic/*`,
> `alibaba/*`, …) serve directly with no daemon.
