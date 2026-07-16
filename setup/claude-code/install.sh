# Configure Claude Code to use OpenLLM — unified install / uninstall / state.
#
#   (no flag)  install: ensure the CLI + write/merge our env keys into settings.json
#   -u         uninstall: strip ONLY the env keys install wrote
#   -s         state: print one JSON line {"installed":bool,"version":string|null}
#
# Run via `bash <file>` by the setup wrapper, which exports `$GATEWAY_ORIGIN` /
# `$API_KEY` and the `ensure_cli` / `ensure_dir` / `has_command` helpers. do_state
# is self-contained (no key, no inherited helpers) so the device-state walk can
# probe it cheaply.

CLAUDE_DIR="$HOME/.claude"
SETTINGS_FILE="$CLAUDE_DIR/settings.json"

do_install() {
  # Ensure the Claude Code CLI is present before configuring it, so pressing
  # "install" never leaves a configured-but-missing CLI: reuse the existing install
  # if any, else run the official installer. (The daemon's isolated CLI is just a
  # symlink to this same binary — there is one install path, the non-isolated one.)
  ensure_cli "Claude Code" claude \
    "$HOME/.local/bin/claude" \
    "https://claude.ai/install.sh"

  ensure_dir "$CLAUDE_DIR"

  # No custom header to inject: the local daemon authenticates with the SAME
  # `sk-llm` key Claude Code carries (`ANTHROPIC_API_KEY`), and the gateway
  # detects a live daemon from that key's server-side activity — so it 307s
  # subscription hops (claude_code) to THIS machine's daemon with no client
  # header. See `docs/proposals/daemon-control-via-neon-longpoll.md`.

  # Write a fresh settings.json containing ONLY our env keys. Used solely when no
  # settings.json exists yet — NEVER to replace a populated file (that would wipe
  # the user's hooks / permissions / model / statusLine / …).
  write_settings() {
    cat > "$SETTINGS_FILE" <<JSONEOF
{
  "env": {
    "ANTHROPIC_BASE_URL": "${GATEWAY_ORIGIN}",
    "ANTHROPIC_API_KEY": "${API_KEY}",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "ultra",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "plus",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "lite"
  }
}
JSONEOF
  }

  # Merge our env keys into an existing settings.json with jq, preserving every
  # other key. Returns non-zero (leaving the file untouched) if jq fails.
  merge_with_jq() {
    local tmp
    tmp=$(mktemp)
    if jq --arg key "$API_KEY" --arg url "${GATEWAY_ORIGIN}" \
       --arg opus "ultra" --arg sonnet "plus" --arg haiku "lite" '
      .env.ANTHROPIC_API_KEY = $key |
      .env.ANTHROPIC_BASE_URL = $url |
      .env.ANTHROPIC_DEFAULT_OPUS_MODEL = $opus |
      .env.ANTHROPIC_DEFAULT_SONNET_MODEL = $sonnet |
      .env.ANTHROPIC_DEFAULT_HAIKU_MODEL = $haiku
    ' "$SETTINGS_FILE" > "$tmp" 2>/dev/null; then
      # Write IN PLACE (not `mv`): under the daemon's OS sandbox settings.json
      # is a FILE-scoped grant — a cross-dir rename into ~/.claude needs
      # create-rights on the (ungranted) parent dir, so `mv` would EACCES, and
      # even a same-dir rename needs the ~/.claude dir granted (it isn't). So we
      # must `cat >` the granted file itself, which truncates BEFORE writing —
      # a mid-write failure (ENOSPC, revoked grant) would otherwise leave
      # settings.json empty. Guard it: back up the current contents first and
      # ROLL BACK on a failed write so the user never loses their config.
      local orig
      orig=$(mktemp)
      cat "$SETTINGS_FILE" > "$orig" 2>/dev/null || true
      if cat "$tmp" > "$SETTINGS_FILE"; then
        rm -f "$tmp" "$orig"
        return 0
      fi
      # Write failed partway — restore the original (best-effort; the file grant
      # covers this in-place write too) so it's left as-found, not truncated.
      cat "$orig" > "$SETTINGS_FILE" 2>/dev/null || true
      rm -f "$tmp" "$orig"
      return 1
    fi
    rm -f "$tmp"
    return 1
  }

  # Merge our env keys into an existing settings.json with python3 (the json
  # stdlib), preserving every other key. Fails closed: if the existing file does
  # NOT parse, it is left exactly as-is and a non-zero status is returned — we
  # never silently overwrite a populated-but-unparseable file.
  merge_with_python() {
    GATEWAY_ORIGIN="$GATEWAY_ORIGIN" API_KEY="$API_KEY" SETTINGS_FILE="$SETTINGS_FILE" \
    python3 - <<'PYEOF'
import json, os, sys

path = os.environ["SETTINGS_FILE"]
try:
    with open(path) as f:
        settings = json.load(f)
except Exception as e:
    print(f"Error: {path} exists but is not valid JSON — refusing to overwrite ({e}).", file=sys.stderr)
    print("  Fix or remove it, then re-run; your file was left untouched.", file=sys.stderr)
    sys.exit(1)

if not isinstance(settings, dict):
    print(f"Error: {path} is not a JSON object — refusing to overwrite.", file=sys.stderr)
    sys.exit(1)

env = settings.get("env")
if not isinstance(env, dict):
    env = {}
env["ANTHROPIC_BASE_URL"] = os.environ["GATEWAY_ORIGIN"]
env["ANTHROPIC_API_KEY"] = os.environ["API_KEY"]
env["ANTHROPIC_DEFAULT_OPUS_MODEL"] = "ultra"
env["ANTHROPIC_DEFAULT_SONNET_MODEL"] = "plus"
env["ANTHROPIC_DEFAULT_HAIKU_MODEL"] = "lite"
settings["env"] = env

with open(path, "w") as f:
    json.dump(settings, f, indent=2)
PYEOF
  }

  # Write-once backup of the pre-openllm settings.json (or an .absent marker
  # when it doesn't exist yet) so the user can always recover the original.
  # Guarded (errexit-safe): the helper is wrapper-injected, absent on a raw
  # standalone run. Best-effort — a backup failure never fails the install.
  if type backup_once >/dev/null 2>&1; then backup_once "$SETTINGS_FILE" "setup/claude-code" || true; fi

  if [ ! -f "$SETTINGS_FILE" ]; then
    # No existing config — a fresh write is safe.
    write_settings
  elif has_command jq; then
    if ! merge_with_jq; then
      if has_command python3; then
        # jq couldn't parse/merge — fall back to the python merger (which fails
        # closed on a genuinely unparseable file).
        merge_with_python
      else
        echo "Error: jq failed to update $SETTINGS_FILE — left untouched." >&2
        echo "  Your settings were NOT modified. Fix the file or install python3 and re-run." >&2
        exit 1
      fi
    fi
  elif has_command python3; then
    # merge_with_python exits non-zero (and leaves the file as-is) on a parse
    # error; propagate that under `set -e` so we never claim a false success.
    merge_with_python
  else
    # Neither merger available: do NOT clobber the user's existing settings.
    echo "Error: neither jq nor python3 found — cannot safely update $SETTINGS_FILE." >&2
    echo "  Refusing to overwrite your existing settings. Install jq or python3, then re-run." >&2
    echo "  Or add these keys under .env manually:" >&2
    echo "    ANTHROPIC_BASE_URL=${GATEWAY_ORIGIN}" >&2
    echo "    ANTHROPIC_API_KEY=<your sk-llm key>" >&2
    echo "    ANTHROPIC_DEFAULT_OPUS_MODEL=ultra, ANTHROPIC_DEFAULT_SONNET_MODEL=plus, ANTHROPIC_DEFAULT_HAIKU_MODEL=lite" >&2
    exit 1
  fi

  # If the user previously REJECTED this key in Claude Code's "do you want to
  # use this API key?" prompt, ~/.claude.json remembers it — Claude Code stores
  # the key's LAST 20 chars in `customApiKeyResponses.rejected` and silently
  # skips the prompt forever after. Clear ONLY the rejected entry — never
  # pre-approve — so the next launch re-prompts. Best-effort: a failure here
  # must NOT fail the install (the key is already configured above).
  clear_rejected_key() {
    local claude_json="$HOME/.claude.json"
    [ -f "$claude_json" ] || return 0
    local key_id
    # Claude Code's identifier is `apiKey.slice(-20)` — mirror it exactly.
    key_id=$(printf %s "$API_KEY" | tail -c 20)
    [ -n "$key_id" ] || return 0
    # Cheap pre-check: skip the rewrite entirely when the id isn't in the file.
    grep -qF "$key_id" "$claude_json" 2>/dev/null || return 0
    # About to modify ~/.claude.json — take the write-once original backup.
    if type backup_once >/dev/null 2>&1; then backup_once "$claude_json" "setup/claude-code"; fi
    if has_command jq; then
      local tmp
      tmp=$(mktemp)
      # Type-guard every step (jq `and` short-circuits): a bare `.a.b?` on a
      # non-object `.a` suppresses the error into EMPTY output (not null) while
      # still exiting 0 — which would let the write below truncate the file.
      # The `-s "$tmp"` check is the belt-and-suspenders for the same hazard.
      if jq --arg id "$key_id" '
        if type == "object"
           and ((.customApiKeyResponses | type) == "object")
           and ((.customApiKeyResponses.rejected | type) == "array")
        then .customApiKeyResponses.rejected |= map(select(. != $id))
        else . end
      ' "$claude_json" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
        # In-place write, not `mv` — like settings.json above, ~/.claude.json is
        # a FILE-scoped grant under the daemon's OS sandbox, so a rename would
        # EACCES. `cat >` truncates before writing; back up + roll back so a
        # mid-write failure never leaves the file emptied.
        local orig
        orig=$(mktemp)
        cat "$claude_json" > "$orig" 2>/dev/null || true
        if cat "$tmp" > "$claude_json"; then
          rm -f "$tmp" "$orig"
          return 0
        fi
        cat "$orig" > "$claude_json" 2>/dev/null || true
        rm -f "$tmp" "$orig"
        return 0
      fi
      rm -f "$tmp"
      # jq couldn't parse — fall through to python3.
    fi
    if has_command python3; then
      KEY_ID="$key_id" CLAUDE_JSON="$claude_json" python3 - <<'PYEOF' || true
import json, os

path = os.environ["CLAUDE_JSON"]
try:
    with open(path) as f:
        cfg = json.load(f)
except Exception:
    raise SystemExit(0)  # unparseable — leave untouched (best-effort)
if not isinstance(cfg, dict):
    raise SystemExit(0)
resp = cfg.get("customApiKeyResponses")
if not isinstance(resp, dict):
    raise SystemExit(0)
rejected = resp.get("rejected")
key_id = os.environ["KEY_ID"]
if not isinstance(rejected, list) or key_id not in rejected:
    raise SystemExit(0)
resp["rejected"] = [r for r in rejected if r != key_id]
# In-place write (open "w") — never temp+rename; the sandbox grant is
# file-scoped (same constraint as the settings.json merge above).
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
PYEOF
    fi
    return 0
  }
  clear_rejected_key || true

  echo "Claude Code configured."
  echo "  API base: ${GATEWAY_ORIGIN}"
  echo "  Settings: $SETTINGS_FILE"
  echo "  Daemon:   subscription models (claude_code) run on your local daemon —"
  echo "            start it + connect the provider; the gateway routes to it"
  echo "            automatically via your API key (no extra setup)."
}

do_uninstall() {
  # Best-effort + idempotent: strips ONLY the `env` keys install wrote
  # (`ANTHROPIC_BASE_URL`, `ANTHROPIC_API_KEY`, `ANTHROPIC_DEFAULT_{OPUS,SONNET,
  # HAIKU}_MODEL`) and leaves the rest of settings.json intact. No-op when the
  # file is absent.
  if [ ! -f "$SETTINGS_FILE" ]; then
    echo "  No settings.json found — nothing to undo."
  else
    if has_command jq; then
      local tmp
      tmp=$(mktemp)
      # Only overwrite + claim success if jq actually succeeded — otherwise clean
      # up the temp file and leave settings.json untouched (no false success).
      if jq '
        if .env then
          .env |= del(
            .ANTHROPIC_BASE_URL,
            .ANTHROPIC_API_KEY,
            .ANTHROPIC_DEFAULT_OPUS_MODEL,
            .ANTHROPIC_DEFAULT_SONNET_MODEL,
            .ANTHROPIC_DEFAULT_HAIKU_MODEL
          )
          | if (.env | length) == 0 then del(.env) else . end
        else . end
      ' "$SETTINGS_FILE" > "$tmp"; then
        # In-place write, not `mv` — settings.json is a FILE-scoped sandbox
        # grant; a cross-dir rename into ~/.claude would EACCES (see install).
        # `cat >` truncates before writing, so back up the original and ROLL
        # BACK on a failed write — otherwise "left untouched" would be a lie
        # (the file was already emptied).
        local orig
        orig=$(mktemp)
        cat "$SETTINGS_FILE" > "$orig" 2>/dev/null || true
        if cat "$tmp" > "$SETTINGS_FILE"; then
          rm -f "$tmp" "$orig"
          echo "  Removed OpenLLM keys from $SETTINGS_FILE"
        else
          cat "$orig" > "$SETTINGS_FILE" 2>/dev/null || true
          rm -f "$tmp" "$orig"
          echo "  Warning: could not write $SETTINGS_FILE — left untouched." >&2
        fi
      else
        rm -f "$tmp"
        echo "  Warning: jq failed — leaving settings.json untouched." >&2
      fi
    else
      echo "  Warning: jq not found — leaving settings.json untouched." >&2
      echo "  Manually remove the ANTHROPIC_* keys under .env from $SETTINGS_FILE" >&2
    fi
  fi

  echo "Claude Code OpenLLM configuration removed."
}

# Print one JSON line describing install state. Installed ⇔ our managed
# ANTHROPIC_BASE_URL env key is present in settings.json (the durable signal
# install writes). Exit 0 always; the JSON IS the payload. No key, no network.
# (The `diverged` flag is NOT computed here — the gateway's state wrapper
# injects it by comparing the install-time version stamp against the current
# bundle version.)
do_state() {
  local installed="false"
  if [ -f "$SETTINGS_FILE" ] && grep -q "ANTHROPIC_BASE_URL" "$SETTINGS_FILE" 2>/dev/null; then
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
