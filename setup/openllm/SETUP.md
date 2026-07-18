---
version: 1.6.39-registry.8
os: [osx, linux]
name: openllm
description: The OpenLLM extension — one MCP server (via the openllmc CLI) exposing the full native gateway API, semantic code/docs search, and persistent memory, plus five background hooks and an always-loaded guidance block in ~/.claude/CLAUDE.md.
type: cli
extensions: [claude-code]
post_install: ~/.openllm/bin/openllmc setup
---

## What it does

Installs the **openllmc CLI** (`~/.openllm/bin/openllmc`, a compiled
binary — no bun required) and registers ONE MCP server in `~/.claude.json`
(`mcpServers.openllm` → `openllmc mcp`) exposing three tool groups:

- **Native gateway API** — every operation in the OpenLLM OpenAPI spec
  (models, stats, keys, config, image generation, …), generated from the
  same Effect Schema the gateway serves at `/api/swagger`. Coverage tracks
  the spec automatically. Mutating operations carry explicit consent copy.
- **claude-context** — semantic code + docs search: `index_codebase`,
  `search_code`, `clear_index`, `get_indexing_status`, `index_docs`,
  `search_docs`, and friends. Chunks are embedded gateway-side (host-paid
  Bedrock Titan v2 @ 1024-d) into Neon pgvector scoped to your user id.
- **supermemory** — persistent cross-session memory: `memory`
  (save/forget with project + team destinations), `recall`, `whoAmI`.

## Hooks

Merged into `~/.claude/settings.json`. The pattern-matched guidance/
trigger hooks were replaced by the CLAUDE.md guidance region below (the
agent reasons about when to use the tools instead of being pattern-matched
into it). What remains is FUNCTIONAL: background data-plane work (index,
extract, recall) plus one decision-point nudge — the guidance region alone
competes with the harness's built-in steering toward Grep/Glob, so a
once-per-session `additionalContext` reminder lands exactly where the
model picks a search tool (never blocks the call):

| Hook | Event | Purpose |
|---|---|---|
| `openllm/hooks/ctx-session-start.sh` | SessionStart | fire-and-forget `openllmc ctx index` of the repo |
| `openllm/hooks/ctx-grep-nudge.sh` | PreToolUse (`Grep\|Glob\|Bash`) | once-per-session `search_code` reminder on grep-shaped calls |
| `openllm/hooks/ctx-reindex-on-edit.sh` | PostToolUse (`Edit\|Write\|NotebookEdit`) | throttled background re-index so the index tracks mid-session edits |
| `openllm/hooks/mem-recall-on-prompt.sh` | UserPromptSubmit | similarity-gated auto-recall of saved memories into context |
| `openllm/hooks/mem-extract-on-stop.sh` | Stop | conversation-grounded save/forget extractor |

Both install and uninstall strip hooks by the generic `openllm/hooks/`
command substring — so upgrading from (or uninstalling) **any** prior
extension version removes its hooks too, without the script knowing their
names. User hooks are never touched.

## Guidance region (`~/.claude/CLAUDE.md`)

Install writes a managed block into the user-level `CLAUDE.md` (loaded into
every Claude Code session) with the tool-usage guidance that hooks used to
inject per prompt: prefer `search_code` for conceptual codebase questions,
index/search docs URLs, and route cross-session memory through the
`memory`/`recall` MCP tools instead of file-based auto-memory.

The block is delimited by markdown-safe markers:

```
<!-- >>> openllm (managed) >>> -->
…
<!-- <<< openllm (managed) <<< -->
```

Re-installs replace the region in place (never duplicate); everything
outside the markers is preserved verbatim. Uninstall removes the region and
deletes the file only when nothing else is left in it.

## Wiring

```bash
GATEWAY_ORIGIN=__GATEWAY_URL__
API_KEY=__API_KEY__
```

The install script downloads `openllmc` from
`GET /api/cli/binary/<os>-<arch>` (302 → the pinned GitHub release asset),
verifies the decompressed binary against the committed sha256 sidecar, and
installs it atomically. The gateway URL + API key are persisted ONCE into
the shared `~/.openllm/.env` (`OPENLLM_CLOUD_ORIGIN` / `OPENLLM_API_KEY`,
0600) — the same file the daemon boots from — and the CLI + hooks resolve
them from there: **no secret is baked into `~/.claude.json` or
`settings.json`**. Rotating the key or re-pointing the gateway is a
one-file change. The CLI self-updates against the gateway's pinned release
(`openllmc self-update`).

## Environment

| Var | Required | Default |
|---|---|---|
| `OPENLLM_CLOUD_ORIGIN` (shared `.env`) | yes | written by install |
| `OPENLLM_API_KEY` (shared `.env`) | yes | written by install |
| `LLM_GATEWAY_URL` / `LLM_GATEWAY_API_KEY` (process env) | no | override the shared file |
| `CLAUDE_CONTEXT_STATE_DIR` | no | `~/.claude/plugin-state/claude-context` |
| `CLAUDE_CONTEXT_GREP_NUDGE` | no | `1` — set `0` to disable the PreToolUse nudge |
| `CLAUDE_CONTEXT_REINDEX_ON_EDIT` | no | `1` — set `0` to disable mid-session re-indexing |
| `CLAUDE_CONTEXT_REINDEX_INTERVAL` | no | `120` — min seconds between edit-triggered re-indexes per repo |
| `SUPERMEMORY_AUTO_RECALL` | no | `1` — set `0` to disable per-prompt auto-recall |
| `SUPERMEMORY_RECALL_MIN_SIMILARITY` | no | `0.25` — min similarity to inject a recalled memory (v1.2.1: was `0.50`, which filtered nearly all real hits; live scores for relevant-but-paraphrased prompts sit ~0.28–0.35, irrelevant queries top out ~0.13) |
| `SUPERMEMORY_RECALL_TIMEOUT` | no | `5.0` — recall search timeout in seconds (v1.2.1: was hardcoded `2.5`, blown by gateway cold starts) |

## Memory encryption & vault rotation

Saved memories are AES-256-GCM encrypted at rest under your vault DEK —
the same key every `sk-llm-…` API key carries — so any key minted from
the same recovery phrase reads them (a memory saved through key A is
readable through key B). This is at-rest encryption, not zero-knowledge:
memory text transits the gateway (and the embedding service) inside the
request, and the embedding vector itself stays plaintext for semantic
search — someone with database access could learn what a memory is
*about*, though not its wording. Rotating your recovery phrase
**permanently deletes all saved memories** (they are encrypted under the
old vault and cannot be carried across a rotation).

## Uninstall

```
curl -fsSL <pointer script_url> | bash -s -- -u
```

Removes the `mcpServers.openllm` entry from `~/.claude.json`, strips every
openllm hook (from **any** prior version, via the generic `openllm/hooks/`
marker) from `~/.claude/settings.json`, removes the managed guidance region
from `~/.claude/CLAUDE.md` (preserving user content; the file is deleted
only when the region was all it held), and deletes the extension dir. The
`openllmc` binary is left in place (other tools may use it); remove it with
`rm -rf ~/.openllm/bin/openllmc` if desired. Indexed vectors and saved
memories in the gateway DB are NOT deleted.
