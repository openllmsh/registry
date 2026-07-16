# Configure Raycast AI to use OpenLLM — unified install / uninstall / state.
#
#   (no flag)  install: merge an `openllm` custom provider into providers.yaml
#   -u         uninstall: strip ONLY the `# >>> openllm … <<<` managed region
#   -s         state: print one JSON line {"installed":bool,"version":string|null}
#
# Run via `bash <file>` by the setup wrapper, which exports `$GATEWAY_ORIGIN` /
# `$API_KEY` and the `ensure_dir` / `has_command` helpers. do_state is
# self-contained (no key, no inherited helpers).
#
# Raycast's custom-provider feature reads a `providers.yaml`. There is no
# guaranteed hot-reload — the user restarts Raycast after install. We merge with
# awk (no YAML library needed — system python3 ships no PyYAML) using the same
# comment-delimited managed region as the codex/kimi setups.

# Raycast's config dir on macOS. `RAYCAST_PROVIDERS_FILE` overrides it for users
# whose "Reveal Providers Config" points elsewhere.
RAYCAST_DIR="${RAYCAST_CONFIG_DIR:-$HOME/.config/raycast}"
CONFIG_FILE="${RAYCAST_PROVIDERS_FILE:-$RAYCAST_DIR/ai/providers.yaml}"

BEGIN_MARK="# >>> openllm (managed) >>>"
END_MARK="# <<< openllm (managed) <<<"

# Emit a value as a YAML double-quoted scalar so YAML-special characters in
# $GATEWAY_ORIGIN / $API_KEY (`:`, `#`, `{`, a leading `@`/`*`/`&`, …) can never
# break the document. Escapes `\` then `"` — the only two chars that need it
# inside a double-quoted YAML scalar.
yaml_dq() {
  local v="$1"
  v="${v//\\/\\\\}"
  v="${v//\"/\\\"}"
  printf '"%s"' "$v"
}

# A minimal, valid fallback models block (the three fallback-chain aliases) used
# only when the gateway's per-user catalog fetch fails — Raycast requires >= 1
# model, so the provider must never be emitted model-less.
fallback_models_block() {
  cat <<'YAMLEOF'
      - id: "ultra"
        name: "Ultra"
        context: 200000
        abilities:
          temperature:
            supported: true
          vision:
            supported: true
          system_message:
            supported: true
          tools:
            supported: true
          reasoning_effort:
            supported: true
      - id: "plus"
        name: "Plus"
        context: 200000
        abilities:
          temperature:
            supported: true
          vision:
            supported: true
          system_message:
            supported: true
          tools:
            supported: true
          reasoning_effort:
            supported: true
      - id: "lite"
        name: "Lite"
        context: 128000
        abilities:
          temperature:
            supported: true
          vision:
            supported: true
          system_message:
            supported: true
          tools:
            supported: true
          reasoning_effort:
            supported: true
YAMLEOF
}

do_install() {
  ensure_dir "$(dirname "$CONFIG_FILE")"

  # Write-once original backup (durable, kept even on uninstall — unlike the
  # per-run .openllm-bak below). On a box that installed BEFORE this shipped,
  # the first backup taken may already contain our managed region (with the
  # key) — hence backup_once's 600/700 perms. The .absent marker records a
  # fresh-write install (no pre-existing providers.yaml).
  if type backup_once >/dev/null 2>&1; then backup_once "$CONFIG_FILE" "setup/raycast"; fi

  # Fetch a Raycast models block generated from YOUR activated models (fallback
  # chains + every connected provider model), each with its real context window
  # and abilities. Authenticated with your API key so it reflects your own
  # chains. Best-effort: if the fetch fails or is empty we fall back to the
  # ultra/plus/lite aliases so the provider always has the >= 1 model Raycast
  # requires.
  local models_block="" tmp_models
  tmp_models="$(mktemp)"
  if curl -fsS -H "Authorization: Bearer ${API_KEY}" \
       "${GATEWAY_ORIGIN}/api/setup/raycast/model-catalog" -o "$tmp_models" 2>/dev/null \
     && [ -s "$tmp_models" ]; then
    models_block="$(cat "$tmp_models")"
  fi
  rm -f "$tmp_models"
  if [ -z "$models_block" ]; then
    models_block="$(fallback_models_block)"
    echo "  Catalog: not fetched — using ultra/plus/lite fallback. Re-run to pull your full model list."
  fi

  # Assemble our managed provider entry (a single list item under `providers:`).
  # One `api_keys.default` bearer credential; no per-model `provider:` routing
  # needed. `base_url` ends in /v1 — Raycast appends /chat/completions itself.
  # base_url + the key are DOUBLE-QUOTED (via yaml_dq) so a value carrying a
  # YAML-special char (`:`, `#`, `{`, a leading `@`, …) can't break the document.
  local block_file
  block_file="$(mktemp)"
  {
    echo "$BEGIN_MARK"
    echo "  - id: openllm"
    echo "    name: OpenLLM"
    echo "    base_url: $(yaml_dq "${GATEWAY_ORIGIN}/v1")"
    echo "    api_keys:"
    echo "      default: $(yaml_dq "${API_KEY}")"
    echo "    models:"
    printf '%s\n' "$models_block"
    echo "$END_MARK"
  } > "$block_file"

  if [ ! -f "$CONFIG_FILE" ]; then
    # No existing config — write a fresh providers.yaml with just our block.
    {
      echo "providers:"
      cat "$block_file"
    } > "$CONFIG_FILE"
    rm -f "$block_file"
    echo "Raycast configured (new providers.yaml written)."
    print_summary
    return 0
  fi

  # Back up before touching an existing file.
  cp "$CONFIG_FILE" "$CONFIG_FILE.openllm-bak"

  # 1) Strip any prior openllm-managed region so re-runs never duplicate it.
  local cleaned
  cleaned="$(awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
    index($0, b) == 1 { skip = 1; next }
    skip == 1 { if (index($0, e) == 1) skip = 0; next }
    { print }
  ' "$CONFIG_FILE")"

  # 2) Insert our block. Match the FIRST top-level `providers:` line — with or
  #    without an inline value (`providers:`, `providers: []`, `providers: {}`,
  #    `providers:  # comment`) — rewrite that line to a canonical block-form
  #    `providers:` (dropping only an inline `[]`/`{}` sequence value; a trailing
  #    comment goes too) and insert our entry as its FIRST child. Block-form
  #    children that already followed are preserved (they stay indented after our
  #    block). awk writes a sentinel to a side file when it inserts so we can tell
  #    an in-place insert from the no-key case WITHOUT re-parsing. If there is no
  #    top-level `providers:` key at all, append a canonical section. Either way
  #    the block ends up present — the grep guard below rejects a silent skip.
  local merged sentinel
  sentinel="$(mktemp)"
  merged="$(printf '%s\n' "$cleaned" | awk -v blk="$block_file" -v sf="$sentinel" '
    BEGIN { done = 0 }
    done == 0 && /^providers:([[:space:]].*)?$/ {
      print "providers:"
      while ((getline line < blk) > 0) print line
      done = 1
      print "1" > sf
      next
    }
    { print }
  ')"
  if [ ! -s "$sentinel" ]; then
    # No top-level providers: key was found — append a canonical section.
    merged="$(printf '%s\nproviders:\n%s' "$merged" "$(cat "$block_file")")"
  fi
  rm -f "$sentinel" "$block_file"

  # Atomic replace so an interrupted write can't corrupt providers.yaml.
  local tmp
  tmp="$(mktemp)"
  # Guard against a silent skip: the managed block MUST be present in the result
  # before we claim success. `printf | grep` verifies it, then the atomic mv
  # lands it — we only print "Raycast configured." after both.
  if ! printf '%s\n' "$merged" | grep -qF "$BEGIN_MARK"; then
    rm -f "$tmp"
    echo "Error: failed to insert the openllm provider into $CONFIG_FILE — left untouched." >&2
    cp "$CONFIG_FILE.openllm-bak" "$CONFIG_FILE"
    exit 1
  fi
  if printf '%s\n' "$merged" > "$tmp" && mv "$tmp" "$CONFIG_FILE"; then
    echo "Raycast configured."
  else
    rm -f "$tmp"
    echo "Error: failed to update $CONFIG_FILE — restoring backup." >&2
    cp "$CONFIG_FILE.openllm-bak" "$CONFIG_FILE"
    exit 1
  fi
  print_summary
}

print_summary() {
  echo "  Provider: openllm → ${GATEWAY_ORIGIN}/v1 (OpenAI chat-completions)"
  echo "  Config:   $CONFIG_FILE"
  echo "  Backup:   $CONFIG_FILE.openllm-bak (if it existed)"
  echo "  Next:     enable Settings → AI → Custom Providers, then RESTART Raycast"
  echo "            (it doesn't reliably hot-reload). Use 'Manage Models' to enable them."
  echo "  Daemon:   subscription models (claude_code/chatgpt/kimi_code) run on your"
  echo "            local daemon — start it + connect; the gateway routes via your key."
}

do_uninstall() {
  # Best-effort + idempotent: strips the `# >>> openllm … <<<` managed region
  # install wrote, leaving every other provider intact. No-op when absent.
  if [ ! -f "$CONFIG_FILE" ]; then
    echo "  No providers.yaml found — nothing to undo."
    echo "Raycast OpenLLM configuration removed."
    return 0
  fi
  local cleaned tmp
  cleaned="$(awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
    index($0, b) == 1 { skip = 1; next }
    skip == 1 { if (index($0, e) == 1) skip = 0; next }
    { print }
  ' "$CONFIG_FILE")"
  # Normalize a now-childless `providers:` back to install-parity: when removing
  # our block leaves a bare `providers:` key with NO list items following it, a
  # YAML load reads it as null (a schema drift from what install wrote). Rewrite
  # it to an explicit empty sequence `providers: []` so the file stays valid +
  # matches the shape install produces. A `providers:` still followed by other
  # entries is left as block form (untouched).
  cleaned="$(printf '%s\n' "$cleaned" | awk '
    { lines[NR] = $0 }
    END {
      for (i = 1; i <= NR; i++) {
        if (lines[i] ~ /^providers:[[:space:]]*$/) {
          has_child = 0
          for (j = i + 1; j <= NR; j++) {
            if (lines[j] ~ /^[[:space:]]*$/) continue        # blank
            if (lines[j] ~ /^[[:space:]]*#/) continue        # comment
            if (lines[j] ~ /^[[:space:]]+/) { has_child = 1 } # indented → a child
            break
          }
          if (has_child == 0) { print "providers: []"; continue }
        }
        print lines[i]
      }
    }
  ')"
  tmp="$(mktemp)"
  if printf '%s\n' "$cleaned" > "$tmp" && mv "$tmp" "$CONFIG_FILE"; then
    echo "  Removed OpenLLM managed region from $CONFIG_FILE"
  else
    rm -f "$tmp"
    echo "  Warning: failed to update $CONFIG_FILE — left untouched." >&2
    return 1
  fi
  # Scrub the install-time backup: it holds a verbatim copy of a providers.yaml
  # that (on any re-install) already contained our `api_keys.default` bearer
  # token, and uninstall is exactly when that secret-at-rest should go. Best
  # effort — absent on a first-ever install (nothing to back up).
  if [ -f "$CONFIG_FILE.openllm-bak" ]; then
    rm -f "$CONFIG_FILE.openllm-bak"
    echo "  Removed backup $CONFIG_FILE.openllm-bak (held the API key)."
  fi
  echo "Raycast OpenLLM configuration removed."
  echo "  Restart Raycast for the change to take effect."
}

# Print one JSON line describing install state. Installed ⇔ our managed region
# marker is present in providers.yaml. Exit 0 always; the JSON IS the payload.
# No key, no network. Self-contained (no inherited helpers). (The `diverged`
# flag is injected by the gateway's state wrapper from the install-time
# version stamp.)
do_state() {
  local file="${RAYCAST_PROVIDERS_FILE:-${RAYCAST_CONFIG_DIR:-$HOME/.config/raycast}/ai/providers.yaml}"
  local installed="false"
  if [ -f "$file" ] && grep -q "^# >>> openllm" "$file" 2>/dev/null; then
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
