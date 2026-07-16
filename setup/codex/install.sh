# Configure the Codex CLI to route through OpenLLM — unified install / uninstall
# / state.
#
#   (no flag)  install: ensure the CLI + merge our managed regions into config.toml
#   -u         uninstall: strip the `# >>> openllm … <<<` managed regions + catalog
#   -s         state: print one JSON line {"installed":bool,"version":string|null}
#
# Run via `bash <file>` by the setup wrapper, which exports `$GATEWAY_ORIGIN` /
# `$API_KEY` and the `ensure_cli` / `ensure_dir` / `has_command` helpers. do_state
# is self-contained (no key, no inherited helpers).

CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
CONFIG_FILE="$CODEX_DIR/config.toml"
MODELS_FILE="$CODEX_DIR/openllm-models.json"

do_install() {
  # Ensure the Codex CLI is present before configuring it: reuse the existing
  # install if any, else run the official installer. (The daemon's isolated CLI is
  # just a symlink to this same binary — one install path, the non-isolated one.)
  ensure_cli "Codex" codex \
    "$HOME/.local/bin/codex" \
    "https://chatgpt.com/codex/install.sh"

  ensure_dir "$CODEX_DIR"

  # No custom header to inject: the local daemon authenticates with the SAME
  # `sk-llm` key Codex carries, and the gateway detects a live daemon from that
  # key's server-side activity — so it 307s subscription (chatgpt) hops to THIS
  # machine's daemon with no client header. See
  # `docs/proposals/daemon-control-via-neon-longpoll.md`.

  # Fetch a Codex model catalog generated from YOUR activated models (fallback
  # chains like `ultra`/`plus` + every connected provider model), keyed by slug
  # with real context-window metadata. Without it Codex can't find metadata for
  # our alias / non-OpenAI slugs and warns "Model metadata for <slug> not found.
  # Defaulting to fallback metadata; this can degrade performance and cause
  # issues" — then auto-compacts against a wrong 272k window. Authenticated with
  # your API key so it reflects your own chains. Best-effort: if the fetch fails
  # we skip the `model_catalog_json` line so the config stays valid (re-run to
  # pick it up).
  local catalog_line=""
  if curl -fsS -H "Authorization: Bearer ${API_KEY}" \
       "${GATEWAY_ORIGIN}/api/setup/codex/model-catalog" -o "$MODELS_FILE.tmp" 2>/dev/null; then
    mv "$MODELS_FILE.tmp" "$MODELS_FILE"
    catalog_line="model_catalog_json = \"${MODELS_FILE}\"
"
  else
    rm -f "$MODELS_FILE.tmp"
  fi

  # TOML requires top-level keys BEFORE any [table], so the provider-selection
  # keys and the provider table are two separate marked regions: the selection
  # is prepended (stays above every table), the table is appended.
  local TOP_BLOCK="# >>> openllm (managed) >>>
model_provider = \"openllm\"
model = \"ultra\"
${catalog_line}# <<< openllm (managed) <<<
"
  local TABLE_BLOCK="# >>> openllm provider (managed) >>>
[model_providers.openllm]
name = \"OpenLLM\"
base_url = \"${GATEWAY_ORIGIN}/v1\"
wire_api = \"responses\"
experimental_bearer_token = \"${API_KEY}\"
# <<< openllm provider (managed) <<<
"

  # Idempotent + TOML-safe merge. Strip any prior openllm-managed regions AND the
  # user's existing top-level model_provider/model (those before the first
  # [table]) so we never create duplicate keys; then PREPEND our selection block
  # and APPEND our provider table, preserving everything else.
  local cleaned
  # Write-once original backup (durable, kept forever) — distinct from the
  # per-run .openllm-bak rollback aid below, which is overwritten each install.
  if type backup_once >/dev/null 2>&1; then backup_once "$CONFIG_FILE" "setup/codex"; fi
  if [ -f "$CONFIG_FILE" ]; then
    cp "$CONFIG_FILE" "$CONFIG_FILE.openllm-bak"
    cleaned=$(awk '
      /^# >>> openllm/ { skip=1 }
      skip==1 { if ($0 ~ /^# <<< openllm/) skip=0; next }
      /^[[:space:]]*\[/ { seen_table=1 }
      seen_table==0 && $0 ~ /^[[:space:]]*(model_provider|model)[[:space:]]*=/ { next }
      { print }
    ' "$CONFIG_FILE")
  else
    cleaned=""
  fi
  {
    printf '%s' "$TOP_BLOCK"
    [ -n "$cleaned" ] && printf '%s\n' "$cleaned"
    printf '%s' "$TABLE_BLOCK"
  } > "$CONFIG_FILE"

  echo "Codex configured."
  echo "  Provider: openllm → ${GATEWAY_ORIGIN}/v1 (wire_api=responses)"
  echo "  Config:   $CONFIG_FILE"
  echo "  Model:    ultra (default fallback chain)"
  echo "            Override per run with: codex -m <model>  (e.g. anthropic/claude-opus-4-8)"
  echo "            Codex's in-app /model picker only lists OpenAI models — use -m or edit"
  echo "            'model =' above to reach any OpenLLM catalog id / chain alias."
  if [ -n "$catalog_line" ]; then
    echo "  Catalog:  $MODELS_FILE (model_catalog_json — silences 'metadata not found')"
  else
    echo "  Catalog:  not fetched — Codex may warn 'model metadata not found'; re-run to add it."
  fi
  echo "  Daemon:   the chatgpt subscription runs on your local daemon —"
  echo "            start it + connect; the gateway routes to it via your API key."
}

do_uninstall() {
  # Best-effort + idempotent: strips the `# >>> openllm … <<<` managed regions
  # install wrote (the selection keys + the [model_providers.openllm] table) and
  # removes the fetched model catalog, leaving every other config.toml line
  # intact. No-op when the config is absent.
  if [ -f "$CONFIG_FILE" ]; then
    # Same region markers install emits — drop every openllm-managed block.
    local cleaned
    cleaned=$(awk '
      /^# >>> openllm/ { skip=1 }
      skip==1 { if ($0 ~ /^# <<< openllm/) skip=0; next }
      { print }
    ' "$CONFIG_FILE")
    # Atomic replace: write to a temp file then mv over the config, so an
    # interrupted write can't corrupt/truncate config.toml.
    local tmp
    tmp=$(mktemp)
    if printf '%s\n' "$cleaned" > "$tmp" && mv "$tmp" "$CONFIG_FILE"; then
      echo "  Removed OpenLLM managed regions from $CONFIG_FILE"
    else
      rm -f "$tmp"
      echo "  Warning: failed to update $CONFIG_FILE — left untouched." >&2
      return 1
    fi
  else
    echo "  No config.toml found — nothing to undo."
  fi

  if [ -f "$MODELS_FILE" ]; then
    rm -f "$MODELS_FILE"
    echo "  Removed model catalog: $MODELS_FILE"
  fi

  echo "Codex OpenLLM configuration removed."
}

# Print one JSON line describing install state. Installed ⇔ our managed region
# marker is present in config.toml (the durable signal install writes). Exit 0
# always; the JSON IS the payload. No key, no network. (The `diverged` flag is
# injected by the gateway's state wrapper from the install-time version stamp.)
do_state() {
  local installed="false"
  if [ -f "$CONFIG_FILE" ] && grep -q "^# >>> openllm" "$CONFIG_FILE" 2>/dev/null; then
    installed="true"
  fi
  printf '{"installed":%s,"version":null}\n' "$installed"
}

MODE="install"
while getopts "us" opt; do
  case "$opt" in
    u) MODE="uninstall" ;;
    s) MODE="state" ;;
    *) echo "usage: install.sh [-u|-s]" >&2; exit 2 ;;
  esac
done

case "$MODE" in
  install)   do_install ;;
  uninstall) do_uninstall ;;
  state)     do_state ;;
esac
