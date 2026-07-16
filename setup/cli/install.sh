#!/usr/bin/env bash
# OpenLLM CLI (openllmc) — unified install / uninstall / state script.
#
#   (no flag)  install: download + verify the binary, put it on PATH
#   -u         uninstall: remove the binary + PATH symlink
#   -s         state: print one JSON line {"installed":bool,"version":string|null}
#
# The setup wrapper downloads + verifies the bundle, then runs THIS extracted
# script as a child `bash` process — self-contained: `$GATEWAY_ORIGIN` arrives
# as an exported env var; helpers are defined locally (a child bash does NOT
# inherit the wrapper's shell functions). Keyless (`requires_key: false`) —
# the binary itself needs a key only at MCP/api time, not to install.
#
# The `openllm` PLUGIN embeds this same ensure logic (`ensure_openllmc` in
# packages/registry/plugin/openllm/install.sh) so installing the plugin
# installs the CLI when missing; this standalone setup exists for
# CLI-only provisioning. Keep the two fetch/verify paths in lockstep.

has_command() {
  command -v "$1" &>/dev/null
}

ensure_dir() {
  mkdir -p "$1"
}

OPENLLM_DIR="${OPENLLM_DIR:-$HOME/.openllm}"
BIN_DIR="$OPENLLM_DIR/bin"
BIN_PATH="$BIN_DIR/openllmc"

do_install() {
  set -euo pipefail
  trap 'rc=$?; echo "openllmc install failed (exit $rc) at line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

  ensure_dir "$BIN_DIR"

  # --- detect os/arch → artifact suffix -------------------------------
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

  echo "Downloading openllmc (${suffix})..."
  # Stage INSIDE $BIN_DIR (same filesystem → atomic rename; roomy root disk,
  # not a tiny tmpfs). trap cleans on any exit. NOT `local`: the EXIT trap
  # fires after do_install's frame is gone, and under `set -u` expanding an
  # out-of-scope local in the trap would abort the cleanup itself (the daemon
  # installer uses the same non-local pattern).
  tmp_dl="$BIN_DIR/.openllmc.download.$$"
  tmp_bin="$BIN_DIR/.openllmc.bin.$$"
  tmp_sha="$BIN_DIR/.openllmc.sha.$$"
  trap 'rm -f "$tmp_dl" "$tmp_bin" "$tmp_sha"' EXIT
  # Show curl's progress bar on an interactive stderr (the usual `curl … | bash`
  # case keeps stderr on the tty); stay silent when piped/redirected (CI logs) so
  # machine output isn't polluted. Both follow redirects (-L) and fail closed
  # on HTTP errors (-f).
  if [ -t 2 ]; then
    curl -fL --progress-bar "$binary_url" -o "$tmp_dl" || { echo "Download failed: $binary_url (503 = no CLI release published yet)" >&2; exit 1; }
  else
    curl -fsSL "$binary_url" -o "$tmp_dl" || { echo "Download failed: $binary_url (503 = no CLI release published yet)" >&2; exit 1; }
  fi

  # The published asset is gzipped (`openllmc-<target>.gz`). Decompress; if the
  # payload isn't gzip, use it as-is. Either way the sha256 below verifies the
  # FINAL (decompressed) binary — what actually runs — so any bad/truncated
  # download fails closed there.
  if has_command gunzip && gunzip -c "$tmp_dl" > "$tmp_bin" 2>/dev/null; then
    : # decompressed a gzip asset
  else
    cp "$tmp_dl" "$tmp_bin" # not gzip (or no gunzip) — verify it as-is
  fi

  # --- verify the published checksum (refuse on mismatch) -------------
  local expected actual
  if curl -fsSL "$sha_url" -o "$tmp_sha" 2>/dev/null; then
    expected=$(cut -d' ' -f1 < "$tmp_sha")
    if has_command shasum; then
      actual=$(shasum -a 256 "$tmp_bin" | cut -d' ' -f1)
    elif has_command sha256sum; then
      actual=$(sha256sum "$tmp_bin" | cut -d' ' -f1)
    else
      echo "No shasum/sha256sum available to verify the download — refusing to install." >&2
      exit 1
    fi
    if [ "$expected" != "$actual" ]; then
      echo "Checksum mismatch — refusing to install." >&2
      echo "  expected: $expected" >&2
      echo "  actual:   $actual" >&2
      exit 1
    fi
    echo "Checksum verified."
  else
    echo "No published checksum at $sha_url — refusing to install unverified binary." >&2
    exit 1
  fi

  # --- install the verified binary into place -------------------------
  chmod 0755 "$tmp_bin"
  # macOS: strip quarantine + ad-hoc sign IFF unsigned (cross-compiled targets
  # aren't signed; Apple Silicon SIGKILLs an unsigned Mach-O).
  if [ "$os" = "darwin" ]; then
    xattr -dr com.apple.quarantine "$tmp_bin" 2>/dev/null || true
    if has_command codesign && ! codesign --verify "$tmp_bin" 2>/dev/null; then
      codesign --force --sign - "$tmp_bin" 2>/dev/null || \
        echo "Note: could not codesign openllmc; macOS may block it. Run: codesign --force --sign - $BIN_PATH" >&2
    fi
  fi
  mv "$tmp_bin" "$BIN_PATH"

  # --- PATH + shell completion (best-effort, via the binary itself) ------
  # `openllmc setup` symlinks onto PATH + installs completion — one command,
  # one implementation (src/setup-cmd.ts). BEST-EFFORT here: under the
  # daemon's sandbox the PATH dirs + shell rc files are deliberately
  # read-only (launcher-trojan / rc-tamper guards), so a daemon-driven
  # install skips it and the dashboard shows the command for the user to run
  # unsandboxed. The MCP mapping + hooks use the absolute $BIN_PATH, so a
  # skipped setup never breaks functionality.
  #
  # Write-once original backup of the shell rc files `openllmc setup` edits
  # (guarded — the helper is wrapper-injected, absent on a raw standalone run).
  # Best-effort: a backup failure never aborts the install (`set -euo` above).
  if type backup_once >/dev/null 2>&1; then
    local rc
    for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
      backup_once "$rc" "setup/cli" || true
    done
  fi
  if "$BIN_PATH" setup 2>/dev/null; then
    :
  else
    echo "Note: PATH/completion setup skipped (sandboxed install?) — run it yourself:"
    echo "  $BIN_PATH setup"
  fi

  echo
  echo "OpenLLM CLI installed: $("$BIN_PATH" version 2>/dev/null || echo openllmc)"
  echo "  openllmc mcp          the unified MCP server (stdio)"
  echo "  openllmc exec ctx …   hook verbs (index/search/status/index-docs)"
  echo "  openllmc api --spec   the embedded OpenAPI spec"
  echo "  openllmc setup        PATH symlink + shell completion (re-runnable)"
  echo "  openllmc self-update  converge to the gateway's pinned release"
  echo
  echo "Install the openllm plugin to wire it into Claude Code (MCP entry + hooks)."
}

do_uninstall() {
  set -euo pipefail
  local removed=0
  if [ -x "$BIN_PATH" ] || [ -f "$BIN_PATH" ]; then
    rm -f "$BIN_PATH"
    echo "  Removed $BIN_PATH"
    removed=1
  fi
  local cand
  for cand in "/usr/local/bin/openllmc" "$HOME/.local/bin/openllmc"; do
    # Only remove OUR symlink (pointing at BIN_PATH) — never a foreign binary.
    if [ -L "$cand" ] && [ "$(readlink "$cand")" = "$BIN_PATH" ]; then
      rm -f "$cand"
      echo "  Removed $cand"
    fi
  done
  # Strip the completion wiring `openllmc setup` may have added (rc lines are
  # marked `# openllmc-completion`; fish drops a static file).
  # Filter into a TEMP first, then atomically mv over the rc — never write
  # the rc in place (a failed backup + in-place `> "$rc"` truncates the
  # user's shell config with nothing to restore).
  local rc rc_tmp
  for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
    if [ -f "$rc" ] && grep -q 'openllmc-completion' "$rc" 2>/dev/null; then
      rc_tmp="$rc.openllmc-tmp.$$"
      # grep -v exits 1 when the OUTPUT is empty (every line matched) — that's
      # still a successful filter of a one-line rc, so accept 0 and 1.
      if grep -v 'openllmc-completion' "$rc" > "$rc_tmp" 2>/dev/null || [ $? -eq 1 ]; then
        mv "$rc_tmp" "$rc" && echo "  Removed completion line from $rc"
      else
        rm -f "$rc_tmp"
        echo "  Warning: could not rewrite $rc — remove the '# openllmc-completion' line manually." >&2
      fi
    fi
  done
  if [ -f "$HOME/.config/fish/completions/openllmc.fish" ]; then
    rm -f "$HOME/.config/fish/completions/openllmc.fish"
    echo "  Removed fish completion file"
  fi
  # Legacy: early CLI builds used a separate cli.env; config now lives in
  # the SHARED ~/.openllm/.env (owned by the daemon pairing — never removed
  # here, other tools read it too).
  if [ -f "$OPENLLM_DIR/cli.env" ]; then
    rm -f "$OPENLLM_DIR/cli.env"
    echo "  Removed legacy $OPENLLM_DIR/cli.env"
  fi
  if [ "$removed" = "1" ]; then
    echo "OpenLLM CLI uninstalled."
    echo "Note: if the openllm plugin is installed, its MCP entry now points at a missing binary — uninstall the plugin too, or reinstall the CLI."
  else
    echo "openllmc is not installed (nothing to remove)."
  fi
}

# Print one JSON line describing install state. Installed ⇔ the binary exists
# and is executable. Exit 0 always; the JSON IS the payload. No key, no
# network. (The `diverged` flag is injected by the gateway's state wrapper
# from the install-time version stamp.)
do_state() {
  local installed="false" version="null" v
  if [ -x "$BIN_PATH" ]; then
    installed="true"
    v=$("$BIN_PATH" version 2>/dev/null | sed -E 's/^openllmc v//') || v=""
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
