#!/usr/bin/env bash
# openllm plugin — unified install / uninstall / state script. The ONE plugin:
# ensures the openllmc CLI binary, registers the single MCP server, merges the
# session hooks.
#
#   (no flag)  install: ensure openllmc + wire MCP (~/.claude.json) + hooks
#              (settings.json) + guidance region (~/.claude/CLAUDE.md)
#   -u         uninstall: remove the MCP server + strip hooks + remove the
#              CLAUDE.md region + delete plugin dir
#   -s         state: print one JSON line {"installed":bool,"version":string|null}
#
# The MCP entry MUST live in ~/.claude.json — Claude Code's MCP loader ignores
# settings.json. The hooks legitimately belong in settings.json.
set -euo pipefail

# --- Configuration from wrapper (install needs API_KEY + PLUGIN_SRC_DIR; the
#     uninstall/state paths need neither, so they validate inside do_install). ---
SETTINGS_DIR="${SETTINGS_DIR:-$HOME/.claude}"
PLUGIN_DIR="${PLUGIN_DIR:-$SETTINGS_DIR/plugins/openllm}"
PLUGIN_SRC_DIR="${PLUGIN_SRC_DIR:-}"
GATEWAY_ORIGIN="${GATEWAY_ORIGIN:-http://localhost:14041}"
SETTINGS_FILE="${SETTINGS_DIR}/settings.json"
# The user-scope MCP registry (~/.claude.json). Overridable for tests; merged
# IN PLACE with python3 — never via `claude mcp add-json`, whose temp+rename
# write the daemon sandbox's file-scoped grant cannot take.
CLAUDE_JSON_FILE="${CLAUDE_JSON_FILE:-$HOME/.claude.json}"

# The openllmc CLI binary — the runtime every tool group + hook runs through.
OPENLLM_DIR="${OPENLLM_DIR:-$HOME/.openllm}"
OPENLLMC_BIN="${OPENLLMC_BIN:-$OPENLLM_DIR/bin/openllmc}"

# Generic hook marker: EVERY hook this plugin has ever registered (any version)
# carries this path substring in its command. Install strips-then-re-adds and
# uninstall strips against it, so cleanup never depends on knowing which hook
# names a prior bundle wrote.
HOOKS_MARKER="openllm/hooks/"

# The user-level memory file Claude Code loads into every session. Guidance
# that used to be injected per-prompt by hooks now lives here inside a managed
# region so the agent reasons about tool usage instead of being pattern-matched
# into it. Markdown-safe markers (HTML comments — invisible when rendered).
CLAUDE_MD_FILE="${CLAUDE_MD_FILE:-$SETTINGS_DIR/CLAUDE.md}"
MD_BEGIN='<!-- >>> openllm (managed) >>> -->'
MD_END='<!-- <<< openllm (managed) <<< -->'

# The managed-region body. Kept tight — this text is loaded into every
# session's context.
read -r -d '' MD_GUIDANCE <<'EOF' || true
## OpenLLM tools (managed by the openllm plugin — do not edit this block)

### Semantic code search (claude-context)
- For conceptual codebase questions ("where is X handled?", "how does Y work?",
  "what code implements Z?") prefer `mcp__openllm__search_code` over Grep/Glob —
  it finds code by meaning, not exact string match. Iterate: refine the query
  and call again if the first pass is off.
- Use Grep/Glob for exact identifiers, regex, or filename patterns.
- When the user shares a documentation URL, index it with
  `mcp__openllm__index_docs`, then answer via `mcp__openllm__search_docs`.

### Cross-session memory (supermemory)
- `mcp__openllm__memory` (action: "save" | "forget") and `mcp__openllm__recall`
  are the SINGLE source of truth for remembering things across conversations.
  Do NOT use the file-based auto-memory path (`~/.claude/projects/<slug>/memory/`,
  `MEMORY.md`) — that backend is superseded by these tools.
- Projects are auto-scoped from the working directory; pass an explicit
  `project` only when discussing a different repo than the cwd.
- PROACTIVELY save when the user has CONCLUDED something: a stated preference or
  working-style rule, a fact about themselves/team/stack, explicit assent to a
  non-obvious proposal, corrective feedback, an external resource (ticket,
  channel, dashboard), or a goal/deadline/constraint not derivable from code.
  Do NOT save speculation, rejected proposals, ephemeral task state, or anything
  already in the repo/CLAUDE.md. Use "forget" (often paired with a save) when
  the user contradicts or supersedes a prior memory.
- Recall when the user references past work ("like we did before"), asks
  something that depends on prior context, or at the start of a non-trivial
  task — query once up front. A UserPromptSubmit hook auto-injects relevant
  memories on every prompt (a "[supermemory] Relevant saved memories" block)
  — when one is present, only re-query with a different angle.
- A background Stop hook also extracts confirmed conclusions after each
  exchange; explicit MCP saves always win over it.
EOF

has_cmd() { command -v "$1" >/dev/null 2>&1; }

# Write-once backup of a user file before our FIRST-EVER modification (guarded
# — the helper is wrapper-injected via BASH_FUNC_*, absent on a raw standalone
# run). Never overwrites; uninstall never deletes it. See the gateway's
# scriptPreamble (packages/api/lib/scripts.ts) for the implementation.
backup_user_file() {
    if type backup_once >/dev/null 2>&1; then backup_once "$1" "plugin/openllm"; fi
}

# --- ensure_openllmc: download + verify + atomically install the CLI binary --
# Mirrors the daemon binary install (packages/registry/setup/daemon/install.sh):
# gateway 302 → gzipped release asset, sha256 of the DECOMPRESSED binary from
# the committed manifest, atomic same-dir rename. Skips when the installed
# binary already reports the pinned version.
ensure_openllmc() {
    local uname_s uname_m os arch suffix binary_url sha_url
    uname_s=$(uname -s)
    uname_m=$(uname -m)
    case "$uname_s" in
        Darwin) os="darwin" ;;
        Linux)  os="linux" ;;
        *) echo "Unsupported OS: $uname_s (openllmc supports macOS + Linux only)" >&2; exit 1 ;;
    esac
    case "$uname_m" in
        arm64|aarch64) arch="arm64" ;;
        x86_64|amd64)  arch="x64-baseline" ;;
        *) echo "Unsupported arch: $uname_m" >&2; exit 1 ;;
    esac
    suffix="${os}-${arch}"
    binary_url="${GATEWAY_ORIGIN}/api/cli/binary/${suffix}"
    sha_url="${binary_url}.sha256"

    local bin_dir
    bin_dir=$(dirname "$OPENLLMC_BIN")
    mkdir -p "$bin_dir"

    # Fetch the pinned digest first — it doubles as the up-to-date check.
    local tmp_sha expected
    tmp_sha="$bin_dir/.openllmc.sha.$$"
    if ! curl -fsSL "$sha_url" -o "$tmp_sha" 2>/dev/null; then
        rm -f "$tmp_sha"
        echo "Error: no published openllmc checksum at $sha_url — cannot install the CLI." >&2
        echo "  (503 means no CLI release is published yet.)" >&2
        exit 1
    fi
    expected=$(cut -d' ' -f1 < "$tmp_sha")
    rm -f "$tmp_sha"

    # Already installed + matching digest? Done.
    if [ -x "$OPENLLMC_BIN" ]; then
        local current=""
        if has_cmd shasum; then
            current=$(shasum -a 256 "$OPENLLMC_BIN" | cut -d' ' -f1)
        elif has_cmd sha256sum; then
            current=$(sha256sum "$OPENLLMC_BIN" | cut -d' ' -f1)
        fi
        if [ "$current" = "$expected" ]; then
            echo "  openllmc already up to date ($("$OPENLLMC_BIN" version 2>/dev/null || echo unknown))"
            # Converge PATH/completion on re-install too (idempotent; silent
            # no-op under the sandbox — see the note at the end of this fn).
            "$OPENLLMC_BIN" setup >/dev/null 2>&1 || true
            return 0
        fi
    fi

    echo "  Downloading openllmc (${suffix})..."
    # Stage INSIDE the bin dir (same filesystem → atomic rename; roomy root
    # disk, not a tiny tmpfs). Cleaned on any exit.
    local tmp_dl tmp_bin
    tmp_dl="$bin_dir/.openllmc.download.$$"
    tmp_bin="$bin_dir/.openllmc.bin.$$"
    trap 'rm -f "'"$tmp_dl"'" "'"$tmp_bin"'"' RETURN
    # Progress bar on an interactive stderr (`curl … | bash` keeps stderr on the
    # tty); silent when piped/redirected so machine output isn't polluted. Both
    # follow redirects (-L) and fail closed on HTTP errors (-f).
    if [ -t 2 ]; then
        curl -fL --progress-bar "$binary_url" -o "$tmp_dl" || { echo "Download failed: $binary_url" >&2; exit 1; }
    else
        curl -fsSL "$binary_url" -o "$tmp_dl" || { echo "Download failed: $binary_url" >&2; exit 1; }
    fi

    # The published asset is gzipped; decompress (fall back to as-is when the
    # gateway served a raw binary). The sha256 verifies the FINAL binary.
    if has_cmd gunzip && gunzip -c "$tmp_dl" > "$tmp_bin" 2>/dev/null; then
        :
    else
        cp "$tmp_dl" "$tmp_bin"
    fi

    local actual
    if has_cmd shasum; then
        actual=$(shasum -a 256 "$tmp_bin" | cut -d' ' -f1)
    elif has_cmd sha256sum; then
        actual=$(sha256sum "$tmp_bin" | cut -d' ' -f1)
    else
        echo "No shasum/sha256sum available to verify the download — refusing to install." >&2
        exit 1
    fi
    if [ "$expected" != "$actual" ]; then
        echo "Checksum mismatch — refusing to install openllmc." >&2
        echo "  expected: $expected" >&2
        echo "  actual:   $actual" >&2
        exit 1
    fi

    chmod +x "$tmp_bin"
    # macOS: ad-hoc sign so Gatekeeper doesn't kill the unsigned binary.
    if [ "$os" = "darwin" ] && has_cmd codesign; then
        codesign --force -s - "$tmp_bin" >/dev/null 2>&1 || true
    fi
    mv -f "$tmp_bin" "$OPENLLMC_BIN"
    rm -f "$tmp_dl"
    echo "  openllmc installed → $OPENLLMC_BIN ($("$OPENLLMC_BIN" version 2>/dev/null || echo unknown))"

    # PATH + shell completion — BEST-EFFORT, same contract as the setup/cli
    # installer: a terminal (curl) install gets it automatically; under the
    # daemon sandbox the PATH dirs + rc files are read-only, so it degrades to
    # printing the command (the dashboard card shows it too, via post_install).
    # Functionality never depends on it — the MCP entry + hooks use $OPENLLMC_BIN.
    if "$OPENLLMC_BIN" setup 2>/dev/null; then
        :
    else
        echo "  Note: PATH/completion setup skipped (sandboxed install?) — run it yourself:"
        echo "    $OPENLLMC_BIN setup"
    fi
}

# --- CLAUDE.md managed region helpers ---------------------------------------
# Strip any existing managed region from $CLAUDE_MD_FILE and print the result.
# Line-anchored marker match (same awk pattern as setup/raycast) so user text
# mentioning the markers mid-line is never eaten.
_strip_md_region() {
    awk -v b="$MD_BEGIN" -v e="$MD_END" '
        index($0, b) == 1 { skip = 1; next }
        skip == 1 { if (index($0, e) == 1) skip = 0; next }
        { print }
    ' "$CLAUDE_MD_FILE"
}

# Returns 0 when the file contains the given marker at the START of a line —
# the same line-anchored semantics _strip_md_region uses, so a mid-line
# mention (e.g. the marker quoted in prose or a code block) never counts.
_md_has_marker_line() {
    awk -v m="$1" 'index($0, m) == 1 { found = 1; exit } END { exit !found }' \
        "$CLAUDE_MD_FILE"
}

# Returns 0 when the file has a begin marker but no end marker — a hand-edited
# region we must not touch (stripping to EOF would eat user content).
_md_region_unbalanced() {
    _md_has_marker_line "$MD_BEGIN" && ! _md_has_marker_line "$MD_END"
}

# Install path: (re)write the managed region, preserving user content. Returns
# non-zero when the write fails (e.g. sandboxed daemon without the grant).
write_claude_md_region() {
    local region existing merged
    region=$(printf '%s\n%s\n%s' "$MD_BEGIN" "$MD_GUIDANCE" "$MD_END")
    # Missing or empty file (the daemon sandbox pre-seeds an empty one so the
    # file-scoped grant has a target) → the region IS the file.
    if [ ! -s "$CLAUDE_MD_FILE" ]; then
        printf '%s\n' "$region" > "$CLAUDE_MD_FILE" 2>/dev/null || return 1
        return 0
    fi
    if _md_region_unbalanced; then
        echo "  Warning: $CLAUDE_MD_FILE has an unbalanced openllm managed region — leaving it untouched." >&2
        return 1
    fi
    # $(…) strips trailing newlines, so the user content arrives trimmed;
    # append the region separated by one blank line.
    existing=$(_strip_md_region) || return 1
    if [ -n "$existing" ]; then
        merged=$(printf '%s\n\n%s' "$existing" "$region")
    else
        merged="$region"
    fi
    printf '%s\n' "$merged" > "$CLAUDE_MD_FILE" 2>/dev/null || return 1
    return 0
}

# Uninstall path: remove the managed region. Deletes the file only when the
# strip leaves it empty (emptiness proves it held nothing but our region).
remove_claude_md_region() {
    [ -f "$CLAUDE_MD_FILE" ] || { echo "  No $CLAUDE_MD_FILE (nothing to remove)"; return 0; }
    if ! _md_has_marker_line "$MD_BEGIN"; then
        echo "  No openllm managed region in $CLAUDE_MD_FILE (nothing to remove)"
        return 0
    fi
    if _md_region_unbalanced; then
        echo "  Warning: $CLAUDE_MD_FILE has an unbalanced openllm managed region — leaving it untouched." >&2
        echo "  Remove the block starting at '$MD_BEGIN' manually if needed." >&2
        return 0
    fi
    local remaining
    remaining=$(_strip_md_region) || return 0
    if [ -z "$(printf '%s' "$remaining" | tr -d '[:space:]')" ]; then
        rm -f "$CLAUDE_MD_FILE"
        echo "  Removed $CLAUDE_MD_FILE (held only the openllm managed region)"
    else
        printf '%s\n' "$remaining" > "$CLAUDE_MD_FILE"
        echo "  Removed openllm managed region from $CLAUDE_MD_FILE"
    fi
}

do_install() {
    if [ -z "${API_KEY:-}" ]; then
        echo "Error: API_KEY is not set. Pass via the wrapper install script." >&2
        exit 1
    fi
    if [ -z "$PLUGIN_SRC_DIR" ]; then
        echo "Error: PLUGIN_SRC_DIR is not set." >&2
        exit 1
    fi

    for bin in curl python3; do
        if ! has_cmd "$bin"; then
            echo "Error: '$bin' is required but not found on PATH." >&2
            exit 1
        fi
    done

    local STATE_DIR="${SETTINGS_DIR}/plugin-state/claude-context"
    mkdir -p "$SETTINGS_DIR" "$STATE_DIR"

    # --- The CLI binary first: everything below points at it. ---
    ensure_openllmc

    # --- Persist the gateway config into the ONE shared env file -----------
    # ~/.openllm/.env is the single config source product-wide: the daemon
    # boots from it, openllmc resolves it, and the hooks source it. Writing it
    # here means NO secret is ever baked into ~/.claude.json or settings.json
    # — an uninstall/reinstall or a key rotation touches one file. Merge-
    # preserving (the daemon keeps its own keys in the same file), 0600.
    backup_user_file "${OPENLLM_DIR}/.env"
    OPENLLM_ENV_FILE="${OPENLLM_DIR}/.env" \
    GATEWAY_ORIGIN="$GATEWAY_ORIGIN" \
    API_KEY="$API_KEY" \
    python3 << 'PYEOF'
import os

path = os.environ["OPENLLM_ENV_FILE"]
updates = {
    "OPENLLM_CLOUD_ORIGIN": os.environ["GATEWAY_ORIGIN"],
    "OPENLLM_API_KEY": os.environ["API_KEY"],
}
lines = []
if os.path.exists(path):
    with open(path) as f:
        lines = f.read().split("\n")
out = []
for line in lines:
    t = line.strip()
    if not t or t.startswith("#") or "=" not in t:
        out.append(line)
        continue
    k = t.split("=", 1)[0].strip()
    if k in updates:
        out.append(f"{k}={updates.pop(k)}")
    else:
        out.append(line)
while out and not out[-1].strip():
    out.pop()
for k, v in updates.items():
    out.append(f"{k}={v}")
os.makedirs(os.path.dirname(path), exist_ok=True)
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    f.write("\n".join(out) + "\n")
os.chmod(path, 0o600)
PYEOF
    echo "  Gateway config written to ${OPENLLM_DIR}/.env (0600)"

    # --- Create settings.json if missing (hooks live here) ---
    backup_user_file "$SETTINGS_FILE"
    if [ ! -f "$SETTINGS_FILE" ]; then
        cat > "$SETTINGS_FILE" << 'EOF'
{
  "env": {},
  "permissions": { "allow": [], "deny": [], "ask": [] }
}
EOF
        echo "  Created settings.json"
    fi

    # --- Register the ONE MCP server in ~/.claude.json (in-place merge) ---
    # NOT `claude mcp add-json`: the CLI rewrites ~/.claude.json atomically
    # (sibling temp + rename), which the daemon's OS sandbox cannot allow —
    # ~/.claude.json is a FILE-scoped grant, and creating the temp needs
    # write rights on the ungranted $HOME, so the CLI's write silently never
    # lands (exit 0, no entry). Merge the user-scope `mcpServers` key with
    # python3 IN PLACE instead — same fail-closed posture as the settings.json
    # merges below: an existing-but-unparseable file is never overwritten.
    backup_user_file "$CLAUDE_JSON_FILE"
    OPENLLMC_BIN="$OPENLLMC_BIN" \
    STATE_DIR="$STATE_DIR" \
    python3 - "$CLAUDE_JSON_FILE" << 'PYEOF'
import json, os, sys

path = sys.argv[1]
if os.path.exists(path):
    try:
        with open(path) as f:
            cfg = json.load(f)
    except Exception as e:
        print(f"Error: {path} exists but is not valid JSON — refusing to overwrite ({e}).", file=sys.stderr)
        print("  Fix or remove it, then re-run; your file was left untouched.", file=sys.stderr)
        sys.exit(1)
    if not isinstance(cfg, dict):
        print(f"Error: {path} is not a JSON object — refusing to overwrite.", file=sys.stderr)
        sys.exit(1)
else:
    cfg = {}

servers = cfg.get("mcpServers")
if not isinstance(servers, dict):
    servers = {}
# No secrets in the MCP entry: openllmc resolves the gateway URL + API key
# from the shared ~/.openllm/.env natively (packages/cli/src/env.ts), so
# ~/.claude.json carries only the non-secret state-dir pointer.
servers["openllm"] = {
    "command": os.environ["OPENLLMC_BIN"],
    "args": ["mcp"],
    "env": {
        "CLAUDE_CONTEXT_STATE_DIR": os.environ["STATE_DIR"],
    },
}
cfg["mcpServers"] = servers

# In-place write (open "w" truncates + rewrites the granted file itself) —
# never a temp+rename, which the sandbox's file-scoped grant cannot take.
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
PYEOF
    echo "  Registered MCP server 'openllm' in $CLAUDE_JSON_FILE (user scope)"

    # --- Register hooks in settings.json ---
    # No secrets here either: the gateway URL + API key live in the shared
    # ~/.openllm/.env, which each hook sources (openllm-env.sh). The env
    # prefix carries only non-secret pointers (state dir, binary path).
    #
    # Strip-then-append: FIRST remove every hook carrying the generic marker
    # (whatever a prior bundle version registered — this is the upgrade path,
    # no per-name list), THEN append the current set fresh. Idempotent and
    # version-independent.
    OPENLLMC_BIN="$OPENLLMC_BIN" \
    HOOKS_MARKER="$HOOKS_MARKER" \
    python3 - "$SETTINGS_FILE" "$PLUGIN_SRC_DIR" "$STATE_DIR" << 'PYEOF'
import json, os, shlex, sys

settings_file, plugin_src, state_dir = sys.argv[1:4]
openllmc_bin = os.environ["OPENLLMC_BIN"]
marker = os.environ["HOOKS_MARKER"]

# Fail closed: a fresh skeleton is only safe when there is NO existing file.
# If settings.json exists but does not parse (a hand-edit trailing comma, a
# half-written save, …) we must NOT overwrite it — that would wipe every key
# the user had. Leave it untouched and abort.
if os.path.exists(settings_file):
    try:
        with open(settings_file, "r") as f:
            settings = json.load(f)
    except Exception as e:
        print(f"Error: {settings_file} exists but is not valid JSON — refusing to overwrite ({e}).", file=sys.stderr)
        print("  Your settings were left untouched. Fix or remove the file, then re-run.", file=sys.stderr)
        sys.exit(1)
    if not isinstance(settings, dict):
        print(f"Error: {settings_file} is not a JSON object — refusing to overwrite.", file=sys.stderr)
        sys.exit(1)
else:
    settings = {"env": {}, "permissions": {"allow": [], "deny": [], "ask": []}}

# 1) Strip EVERY openllm hook from EVERY group (generic marker match — removes
#    hooks registered by any prior version, including ones this version no
#    longer ships). Prune entries/groups left empty; user hooks untouched.
#    Defensive: non-dict entries and entries without a list-valued "hooks"
#    field aren't ours (we always write {"hooks": [...]}) — pass them through.
hooks = settings.get("hooks")
if isinstance(hooks, dict):
    for group_key in list(hooks.keys()):
        group = hooks[group_key]
        if not isinstance(group, list):
            continue
        new_group = []
        for entry in group:
            if not isinstance(entry, dict) or not isinstance(entry.get("hooks"), list):
                new_group.append(entry)
                continue
            kept = [h for h in entry["hooks"]
                    if not isinstance(h, dict)
                    or marker not in (h.get("command") or "")]
            if kept:
                new_entry = dict(entry)
                new_entry["hooks"] = kept
                new_group.append(new_entry)
        if new_group:
            hooks[group_key] = new_group
        else:
            del hooks[group_key]
    if not hooks:
        del settings["hooks"]

# 2) Append the current hooks fresh (the strip above guarantees no duplicates).
#    shlex.quote (not json.dumps): the command is evaluated by a shell, so
#    double quotes would let $/`/\ expand and an unquoted path would split on
#    spaces (e.g. a macOS home dir under /Users/First Last).
hook_env = {
    "CLAUDE_CONTEXT_STATE_DIR": state_dir,
    "OPENLLMC_BIN": openllmc_bin,
}
env_prefix = " ".join(f"{k}={shlex.quote(v)}" for k, v in hook_env.items())

def hook(name):
    return shlex.quote(os.path.join(plugin_src, "hooks", name))

settings.setdefault("hooks", {})

# claude-context — background index/sync on session start (fire-and-forget).
settings["hooks"].setdefault("SessionStart", []).append(
    {"hooks": [{"type": "command", "command": f"env {env_prefix} {hook('ctx-session-start.sh')}", "timeout": 30}]}
)
# claude-context — once-per-session decision-point nudge on grep-shaped tool
# calls (Grep/Glob, plus Bash running grep/rg). additionalContext only —
# never blocks; complements the always-loaded CLAUDE.md guidance region by
# landing at the moment the model actually picks a search tool.
settings["hooks"].setdefault("PreToolUse", []).append(
    {"matcher": "Grep|Glob|Bash", "hooks": [{"type": "command", "command": f"env {env_prefix} {hook('ctx-grep-nudge.sh')}", "timeout": 5}]}
)
# claude-context — throttled background re-index on file edits so the index
# tracks the code as it changes WITHIN a session (SessionStart alone leaves
# mid-session writes invisible to search_code). Fire-and-forget.
settings["hooks"].setdefault("PostToolUse", []).append(
    {"matcher": "Edit|Write|NotebookEdit", "hooks": [{"type": "command", "command": f"env {env_prefix} {hook('ctx-reindex-on-edit.sh')}", "timeout": 10}]}
)
# supermemory — auto-recall relevant memories on every prompt (similarity-
# gated; injects nothing when nothing matches). Functional data injection —
# the model can't recall what it doesn't know exists.
settings["hooks"].setdefault("UserPromptSubmit", []).append(
    {"hooks": [{"type": "command", "command": f"env {env_prefix} {hook('mem-recall-on-prompt.sh')}", "timeout": 10}]}
)
# supermemory — background extractor over the last exchange on Stop.
settings["hooks"].setdefault("Stop", []).append(
    {"hooks": [{"type": "command", "command": f"env {env_prefix} {hook('mem-extract-on-stop.sh')}", "timeout": 5}]}
)

with open(settings_file, "w") as f:
    json.dump(settings, f, indent=2)
print("  Registered openllm hooks in settings.json (ctx-session-start, ctx-grep-nudge, ctx-reindex-on-edit, mem-recall-on-prompt, mem-extract-on-stop)")
PYEOF

    # --- Ensure hook scripts are executable ---
    for h in ctx-session-start.sh ctx-grep-nudge.sh ctx-reindex-on-edit.sh mem-recall-on-prompt.sh mem-extract-on-stop.sh openllm-env.sh; do
        [ -f "${PLUGIN_SRC_DIR}/hooks/$h" ] && chmod +x "${PLUGIN_SRC_DIR}/hooks/$h"
    done

    # --- Write the managed guidance region into ~/.claude/CLAUDE.md ---
    # The per-prompt guidance hooks are gone; the agent instead reasons from
    # this always-loaded user-level memory block. Strip-then-append keeps
    # re-installs idempotent (exactly one region, always current). In-place
    # `> file` write — never temp+rename, which the daemon sandbox's
    # file-scoped grant cannot take. Best-effort: an old daemon without the
    # CLAUDE.md grant must not fail the whole install.
    backup_user_file "$CLAUDE_MD_FILE"
    if write_claude_md_region; then
        echo "  Wrote openllm guidance region to $CLAUDE_MD_FILE"
    else
        echo "  Warning: could not write $CLAUDE_MD_FILE — add this block manually:" >&2
        printf '%s\n%s\n%s\n' "$MD_BEGIN" "$MD_GUIDANCE" "$MD_END" >&2
    fi

    echo "Setup complete — restart Claude Code to load the openllm MCP server."
}

do_uninstall() {
    # --- Remove MCP server registration (direct in-place edit — see install) ---
    if [ -f "$CLAUDE_JSON_FILE" ] && has_cmd python3; then
        python3 - "$CLAUDE_JSON_FILE" << 'PYEOF' || true
import json, sys
path = sys.argv[1]
# Fail closed on an unparseable file — uninstall is best-effort.
try:
    with open(path) as f:
        cfg = json.load(f)
except Exception:
    print(f"  Warning: {path} did not parse — leaving it untouched.", file=sys.stderr)
    sys.exit(1)
servers = cfg.get("mcpServers") if isinstance(cfg, dict) else None
if isinstance(servers, dict) and "openllm" in servers:
    del servers["openllm"]
    if not servers:
        del cfg["mcpServers"]
    with open(path, "w") as f:
        json.dump(cfg, f, indent=2)
    print("  Removed mcpServers.openllm from " + path)
else:
    print("  MCP server not registered (nothing to remove)")
PYEOF
    else
        echo "  No $CLAUDE_JSON_FILE (or python3 missing); skipping MCP server removal"
    fi

    # --- Strip hooks from settings.json (generic marker — any version) ---
    if [ -f "$SETTINGS_FILE" ]; then
        if has_cmd python3; then
        HOOKS_MARKER="$HOOKS_MARKER" python3 - "$SETTINGS_FILE" << 'PYEOF'
import json, os, sys
settings_file = sys.argv[1]
marker = os.environ["HOOKS_MARKER"]
# Fail closed: if settings.json exists but does not parse we cannot know what
# to strip — and must NOT overwrite it. Uninstall is best-effort, clean exit.
try:
    with open(settings_file) as f:
        settings = json.load(f)
except Exception as e:
    print(f"  Warning: {settings_file} is not valid JSON — leaving it untouched ({e}).", file=sys.stderr)
    print("  Remove the openllm hook entries manually if needed.", file=sys.stderr)
    sys.exit(0)
if not isinstance(settings, dict):
    print(f"  Warning: {settings_file} is not a JSON object — leaving it untouched.", file=sys.stderr)
    sys.exit(0)

# One generic pass over EVERY group: drop any hook whose command carries the
# openllm marker (covers every hook any prior version registered), prune
# entries/groups left empty, and drop a now-empty top-level "hooks" key —
# user hooks are never touched. Defensive: non-dict entries and entries
# without a list-valued "hooks" field aren't ours — pass them through.
removed_groups = []
hooks = settings.get("hooks")
if isinstance(hooks, dict):
    for group_key in list(hooks.keys()):
        group = hooks[group_key]
        if not isinstance(group, list):
            continue
        new_group = []
        for entry in group:
            if not isinstance(entry, dict) or not isinstance(entry.get("hooks"), list):
                new_group.append(entry)
                continue
            kept_hooks = [h for h in entry["hooks"]
                          if not isinstance(h, dict)
                          or marker not in (h.get("command") or "")]
            if kept_hooks:
                new_entry = dict(entry)
                new_entry["hooks"] = kept_hooks
                new_group.append(new_entry)
            elif entry["hooks"]:
                removed_groups.append(group_key)
        if new_group:
            hooks[group_key] = new_group
        else:
            del hooks[group_key]
    if not hooks:
        del settings["hooks"]

with open(settings_file, "w") as f:
    json.dump(settings, f, indent=2)
if removed_groups:
    print(f"  Removed openllm hooks from: {', '.join(sorted(set(removed_groups)))}")
PYEOF
        else
            echo "  Warning: python3 not found — leaving settings.json hooks untouched." >&2
        fi
    fi

    # --- Remove the managed guidance region from ~/.claude/CLAUDE.md ---
    remove_claude_md_region

    if [ -d "$PLUGIN_DIR" ]; then
        local expected_plugin_dir="${SETTINGS_DIR}/plugins/openllm"
        if [ "$PLUGIN_DIR" != "$expected_plugin_dir" ] || [ "$PLUGIN_DIR" = "/" ]; then
            echo "Error: refusing to remove unexpected PLUGIN_DIR '$PLUGIN_DIR' (expected '$expected_plugin_dir')." >&2
            exit 1
        fi
        rm -rf -- "$PLUGIN_DIR"
        echo "  Removed $PLUGIN_DIR"
    fi

    echo "openllm plugin uninstalled."
    echo "Note: the openllmc binary (~/.openllm/bin/openllmc) is left in place; remove it manually if desired."
    echo "Note: original-config backups (if any) are kept under ~/.openllm/backups/plugin/openllm."
    echo "Note: indexed vectors + saved memories in the gateway DB are NOT deleted."
}

# Print one JSON line describing install state. Installed ⇔ the openllm MCP
# server is registered in ~/.claude.json — the durable config-side signal that
# exists for installs of EVERY plugin version (hook names change across
# versions; the MCP entry doesn't). Exit 0 always; the JSON IS the payload.
# No key, no network. (The `diverged` flag is NOT computed here — the
# gateway's state wrapper injects it by comparing the install-time version
# stamp against the current bundle version.)
do_state() {
    local installed="false"
    if [ -f "$CLAUDE_JSON_FILE" ] && has_cmd python3; then
        if python3 - "$CLAUDE_JSON_FILE" << 'PYEOF' 2>/dev/null
import json, sys
try:
    with open(sys.argv[1]) as f:
        cfg = json.load(f)
except Exception:
    sys.exit(1)
servers = cfg.get("mcpServers") if isinstance(cfg, dict) else None
sys.exit(0 if isinstance(servers, dict) and "openllm" in servers else 1)
PYEOF
        then
            installed="true"
        fi
    fi
    local version="null"
    if [ -x "$OPENLLMC_BIN" ]; then
        v=$("$OPENLLMC_BIN" version 2>/dev/null | sed -E 's/^openllmc v//') || v=""
        [ -n "$v" ] && version="\"$v\""
    fi
    printf '{"installed":%s,"version":%s}\n' "$installed" "$version"
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
