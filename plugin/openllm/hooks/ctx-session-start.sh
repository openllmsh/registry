#!/usr/bin/env bash
# claude-context SessionStart hook.
#
# If the project is in a git repo, fire-and-forget an index/sync against the
# plugin CLI so the codebase is ready by the time the user submits a prompt.
# Honors $CLAUDE_PROJECT_DIR (set by Claude Code) and falls back to PWD.
set -u

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
ROOT=$(git -C "$PROJECT_DIR" rev-parse --show-toplevel 2>/dev/null) || exit 0
[ -n "$ROOT" ] || exit 0

[ "${CLAUDE_CONTEXT_AUTO_INDEX:-1}" = "1" ] || exit 0

# Collection identity is the normalized 'origin' remote URL so that every user
# who checks out the same repo shares one index. Without a remote we can't
# build a stable identifier → skip indexing silently.
git -C "$ROOT" remote get-url origin >/dev/null 2>&1 || exit 0

OPENLLMC="${OPENLLMC_BIN:-$HOME/.openllm/bin/openllmc}"
[ -x "$OPENLLMC" ] || exit 0

STATE_DIR="${CLAUDE_CONTEXT_STATE_DIR:-$HOME/.claude/plugin-state/claude-context}"
mkdir -p "$STATE_DIR"
LOG="$STATE_DIR/auto-index.log"

# Fire-and-forget. Detached so the hook returns immediately.
nohup "$OPENLLMC" exec ctx index --path "$ROOT" \
    >>"$LOG" 2>&1 </dev/null &
disown 2>/dev/null || true

# Status line only — the tool-preference guidance lives in the managed
# ~/.claude/CLAUDE.md region written by install.sh, so repeating it here
# would duplicate it in every session's context.
cat <<EOF
This repository is indexed for semantic search (claude-context MCP).
Indexing/syncing $ROOT in background (log: $LOG).
EOF
