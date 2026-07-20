#!/usr/bin/env bash
#
# commission-macos.sh — ONE-TIME setup for a macOS crossbench perf runner.
#
# Run this once, by hand, as the runner's ADMIN user (not root), when first
# setting up the box. It performs the steps that require sudo / a human and so
# cannot run inside an unattended CI job:
#   - Xcode Command Line Tools
#   - Homebrew (bootstrap into /opt/homebrew)
#   - (optional) passwordless sudo for the runner user
#
# After this succeeds, provision-macos.sh handles everything else on every CI
# job with no password (brew formulae, Chrome/DDG app installs, poetry).
#
# Usage:
#   ./commission-macos.sh                  # Command Line Tools + Homebrew
#   NOPASSWD_SUDO=1 ./commission-macos.sh  # also grant THIS user NOPASSWD sudo
#                                          # (only needed if CI must self-install
#                                          #  brew inline, Windows-winget style)
#
set -euo pipefail

# Non-interactive: never prompt for Y/n confirmations. (The sudo password prompt
# below is a credential, not a confirmation, and is intentionally kept.)
export NONINTERACTIVE=1
export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_INSTALL_CLEANUP=1

log() { printf '\n=== %s ===\n' "$1"; }

[ "$(uname)" = "Darwin" ] || { echo "macOS only." >&2; exit 1; }
[ "$(id -u)" -ne 0 ] || { echo "Run as your normal admin user, not root/sudo." >&2; exit 1; }

# Prompt for the sudo password once, then keep the credential warm for the whole
# run so the long CLT / brew installs don't stall waiting for input.
log "sudo authorization"
sudo -v
( while true; do sudo -n true; sleep 50; kill -0 "$$" 2>/dev/null || exit; done ) 2>/dev/null &
KEEPALIVE_PID=$!
trap 'kill "$KEEPALIVE_PID" 2>/dev/null || true' EXIT

# 1. Xcode Command Line Tools (headless — the softwareupdate on-demand trick).
log "Xcode Command Line Tools"
if xcode-select -p >/dev/null 2>&1; then
  echo "present: $(xcode-select -p)"
else
  echo "Installing Command Line Tools headlessly…"
  TRIGGER=/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
  touch "$TRIGGER"
  # Prefer the '* Label:' form; fall back to the bare label for older macOS.
  PROD="$(softwareupdate -l 2>/dev/null \
          | awk -F': ' '/\* Label:.*Command Line Tools/{print $2}' | tail -n1)"
  [ -n "$PROD" ] || PROD="$(softwareupdate -l 2>/dev/null \
          | grep -oE 'Command Line Tools[^,]*' | tail -n1)"
  if [ -z "$PROD" ]; then
    rm -f "$TRIGGER"
    echo "ERROR: no Command Line Tools package found via softwareupdate." >&2
    echo "Fallback: run 'xcode-select --install' and complete the GUI dialog." >&2
    exit 1
  fi
  echo "Installing: $PROD"
  sudo softwareupdate -i "$PROD" --verbose
  rm -f "$TRIGGER"
  echo "present: $(xcode-select -p)"
fi

# 2. Homebrew (bootstrap into /opt/homebrew). The installer calls sudo itself;
#    creds are already cached, so NONINTERACTIVE won't stall on a password.
log "Homebrew"
if command -v brew >/dev/null 2>&1 || [ -x /opt/homebrew/bin/brew ]; then
  echo "present"
else
  echo "Bootstrapping Homebrew…"
  NONINTERACTIVE=1 /bin/bash -c \
    "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
# Put brew on this user's login-shell PATH (Apple Silicon prefix).
BREW_SHELLENV='eval "$(/opt/homebrew/bin/brew shellenv)"'
grep -qF "$BREW_SHELLENV" "$HOME/.zprofile" 2>/dev/null || echo "$BREW_SHELLENV" >> "$HOME/.zprofile"
eval "$(/opt/homebrew/bin/brew shellenv)"
echo "brew: $(brew --version | head -1)"

# 3. (optional) Passwordless sudo for the runner user — only if you want CI to be
#    able to self-install brew/pkgs inline. For a perf box that just runs
#    provision-macos.sh, this is NOT required (nothing at runtime needs sudo).
if [ "${NOPASSWD_SUDO:-0}" = "1" ]; then
  log "Passwordless sudo for $(whoami)"
  TMP="$(mktemp)"
  printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$(whoami)" > "$TMP"
  if sudo visudo -c -f "$TMP" >/dev/null; then
    sudo install -m 0440 -o root -g wheel "$TMP" /etc/sudoers.d/crossbench-runner
    echo "installed /etc/sudoers.d/crossbench-runner"
  else
    echo "ERROR: generated sudoers file failed validation; not installing." >&2
  fi
  rm -f "$TMP"
fi

log "Commissioning complete"
echo "Next: run provision-macos.sh (per-job provisioning) — it needs no password."
