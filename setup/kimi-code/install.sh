# Configure the Kimi CLI to route through OpenLLM — unified install / uninstall
# / state.
#
#   (no flag)  install: ensure the CLI + merge our managed regions into config.toml
#   -u         uninstall: strip the `# >>> openllm … <<<` managed regions
#   -s         state: print one JSON line {"installed":bool,"version":string|null}
#
# Run via `bash <file>` by the setup wrapper, which exports `$GATEWAY_ORIGIN` /
# `$API_KEY` and the `ensure_cli` / `ensure_dir` / `has_command` helpers. do_state
# is self-contained (no key, no inherited helpers).

KIMI_DIR="${KIMI_CODE_HOME:-$HOME/.kimi-code}"
CONFIG_FILE="$KIMI_DIR/config.toml"

do_install() {
  # Ensure the Kimi CLI is present before configuring it: reuse the existing
  # install if any, else run the official installer. (The daemon's isolated CLI is
  # just a symlink to this same binary — one install path, the non-isolated one.)
  ensure_cli "Kimi CLI" kimi \
    "$HOME/.kimi-code/bin/kimi" \
    "https://code.kimi.com/kimi-code/install.sh"

  ensure_dir "$KIMI_DIR"

  # No custom header to inject: the local daemon authenticates with the SAME
  # `sk-llm` key Kimi carries, and the gateway detects a live daemon from that
  # key's server-side activity — so it 307s subscription (kimi_code) hops to
  # THIS machine's daemon with no client header. See
  # `docs/proposals/daemon-control-via-neon-longpoll.md`.

  local DEFAULT_MODEL="ultra"

  # The Kimi CLI REQUIRES an explicit [models."<name>"] entry for every model it
  # routes to — `default_model = "ultra"` with no [models."ultra"] hard-fails:
  #   [config.invalid] Model "ultra" is not configured ... Add a [models."ultra"]
  #   entry with max_context_size.
  # Fetch a TOML block of [models.*] tables for YOUR activated models (fallback
  # chains + connected provider models), each with its real max_context_size.
  # Authenticated with your API key so it reflects your own chains.
  local models_block=""
  local models_tmp
  models_tmp=$(mktemp)
  if curl -fsS -H "Authorization: Bearer ${API_KEY}" \
       "${GATEWAY_ORIGIN}/api/setup/kimi-code/model-catalog" -o "$models_tmp" 2>/dev/null \
       && [ -s "$models_tmp" ]; then
    models_block=$(cat "$models_tmp")
  fi
  rm -f "$models_tmp"

  # Guarantee the default model is always defined, even if the fetch failed or
  # didn't include it — otherwise the CLI won't start.
  case "$models_block" in
    *"[models.\"${DEFAULT_MODEL}\"]"*) : ;;
    *) models_block="${models_block:+${models_block}

}[models.\"${DEFAULT_MODEL}\"]
provider = \"openllm\"
model = \"${DEFAULT_MODEL}\"
max_context_size = 262144" ;;
  esac

  # Our managed blocks. TOML requires top-level keys BEFORE any [table], so the
  # provider-selection keys and the provider table are two separate marked
  # regions: the selection is prepended (stays above every table), the tables
  # (provider + per-model) are appended (self-contained tables are always valid
  # at the end).
  local TOP_BLOCK="# >>> openllm (managed) >>>
default_provider = \"openllm\"
default_model = \"${DEFAULT_MODEL}\"
# <<< openllm (managed) <<<
"
  local TABLE_BLOCK="# >>> openllm provider (managed) >>>
[providers.openllm]
type = \"openai_legacy\"
base_url = \"${GATEWAY_ORIGIN}/v1\"
api_key = \"${API_KEY}\"
${models_block}
# <<< openllm provider (managed) <<<
"

  # Idempotent + TOML-safe merge. Strip any prior openllm-managed regions AND the
  # user's existing top-level default_provider/default_model (those before the
  # first [table]) so we never create duplicate keys; then PREPEND our selection
  # block and APPEND our provider table, preserving everything else.
  local cleaned
  # Write-once original backup (durable, kept forever) — distinct from the
  # per-run .openllm-bak rollback aid below, which is overwritten each install.
  if type backup_once >/dev/null 2>&1; then backup_once "$CONFIG_FILE" "setup/kimi-code"; fi
  if [ -f "$CONFIG_FILE" ]; then
    cp "$CONFIG_FILE" "$CONFIG_FILE.openllm-bak"
    cleaned=$(awk '
      /^# >>> openllm/ { skip=1 }
      skip==1 { if ($0 ~ /^# <<< openllm/) skip=0; next }
      /^[[:space:]]*\[/ { seen_table=1 }
      seen_table==0 && $0 ~ /^[[:space:]]*(default_provider|default_model)[[:space:]]*=/ { next }
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

  local model_count
  model_count=$(printf '%s\n' "$models_block" | grep -c '^\[models\.' 2>/dev/null || printf '0')
  echo "Kimi CLI configured."
  echo "  Provider: openllm → ${GATEWAY_ORIGIN}/v1 (type=openai_legacy)"
  echo "  Config:   $CONFIG_FILE"
  echo "  Model:    ${DEFAULT_MODEL} (default) · ${model_count} [models.*] entries written"
  echo "            Switch models in-session with /model, or set default_model above."
  echo "  Daemon:   the kimi_code subscription runs on your local daemon —"
  echo "            start it + connect; the gateway routes to it via your API key."
}

do_uninstall() {
  # Best-effort + idempotent: strips the `# >>> openllm … <<<` managed regions
  # install wrote (the selection keys + the [providers.openllm] / per-model
  # tables), leaving every other config.toml line intact. No-op when the config
  # is absent.
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

  echo "Kimi CLI OpenLLM configuration removed."
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
