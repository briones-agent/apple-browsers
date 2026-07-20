#!/usr/bin/env bash
#
# provision-macos.sh — install everything crossbench needs on a macOS perf runner.
#
# macOS counterpart to the provisioning half of windows-browser's
# runCrossbench.ps1 -action build (winget/choco -> brew).
# Idempotent: safe to run on every CI job; installs only what's missing.
#
# Prerequisites that must exist BEFORE this runs (they need sudo / a human once,
# so they belong in the runner image, not here):
#   - Xcode Command Line Tools  (xcode-select --install)
#   - Homebrew                  (/opt/homebrew, bootstrapped once)
# This script fails fast with instructions if either is missing.
#
# Must run AFTER the repo/submodule checkout, since it runs `poetry install`
# against CROSSBENCH_DIR.
#
# Usage: CROSSBENCH_DIR=/path/to/crossbench ./provision-macos.sh
#
set -euo pipefail

# Directory this script lives in (the versioned harness in apple-browsers). The
# fork-only crossbench extras and the cpu_freq patch travel alongside it and are
# healed into CROSSBENCH_DIR below, so a fresh crossbench clone can't silently
# lose them.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXTRAS_DIR="$SCRIPT_DIR/crossbench-extras"
CPU_FREQ_PATCH="$SCRIPT_DIR/patches/cpu_freq-attributeerror.patch"

# crossbench-upstream is the canonical checkout: the DDG fork's page-load flow
# uses Windows-only keyboard actions that crash on macOS. Fork-only extras the
# LCP run needs (navToLCP probe config + LCP SQL module) are copied into the
# upstream clone as untracked files.
CROSSBENCH_DIR="${CROSSBENCH_DIR:-$HOME/Developer/crossbench-upstream}"
PYTHON_VERSION="${PYTHON_VERSION:-3.11}"   # matches Windows (poetry env use 3.11)

# WPR (Web Page Replay) source, pinned to the same revision as crossbench's
# DEPS file (crossbench doesn't ship it; gclient would normally sync it).
WEBPAGEREPLAY_GIT="https://chromium.googlesource.com/webpagereplay"
WEBPAGEREPLAY_REV="b2b856131e36c99e9de9c419fe8ca02f857082ba"   # DEPS: webpagereplay_revision
# Where the wpr binary is built to. test-chrome.sh passes this to crossbench
# via --bin-override, which skips crossbench's own build machinery entirely.
WPR_BIN="${WPR_BIN:-$HOME/Developer/mac-perf-runner/bin/wpr}"

# Non-interactive: never prompt for confirmations (Homebrew honors these).
export NONINTERACTIVE=1
export HOMEBREW_NO_AUTO_UPDATE=1        # don't self-update mid-job (perf hygiene)
export HOMEBREW_NO_INSTALL_CLEANUP=1

log() { printf '\n=== %s ===\n' "$1"; }

# 1. Xcode Command Line Tools — brew and git depend on it. Headless install
#    needs sudo, so it must be pre-installed when imaging the runner.
log "Xcode Command Line Tools"
if ! xcode-select -p >/dev/null 2>&1; then
  echo "ERROR: Command Line Tools missing. Run 'xcode-select --install' on the runner first." >&2
  exit 1
fi
echo "present: $(xcode-select -p)"

# 2. Homebrew — must already be bootstrapped. Its first-time installer shells out
#    to sudo, which cannot run unattended on a password-sudo box, so we do NOT
#    auto-install it here; we fail fast instead.
log "Homebrew"
if ! command -v brew >/dev/null 2>&1; then
  if [ -x /opt/homebrew/bin/brew ]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"   # brew installed but not on PATH in this shell
  else
    echo "ERROR: Homebrew not found. Bootstrap it once on the runner:" >&2
    echo '  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"' >&2
    exit 1
  fi
fi
echo "brew: $(brew --version | head -1)"

# 3. Python + Poetry (brew manages its own prefix — no sudo needed)
log "Python ${PYTHON_VERSION} + Poetry"
brew list "python@${PYTHON_VERSION}" >/dev/null 2>&1 || brew install "python@${PYTHON_VERSION}"
command -v poetry >/dev/null 2>&1 || brew install poetry
PY_BIN="$(brew --prefix "python@${PYTHON_VERSION}")/bin/python${PYTHON_VERSION}"
echo "python: $("$PY_BIN" --version)"
echo "poetry: $(poetry --version)"

# 4. Google Chrome — baseline browser for the comparison run.
#    Chrome is deliberately NOT pinned: every run uses the latest stable so the
#    baseline tracks what users actually run. crossbench stamps the exact version
#    into each result, so a baseline step caused by a Chrome bump stays traceable.
#    A fresh install gets latest already; an existing install is upgraded here so
#    we don't drift behind (rather than relying on Keystone's background schedule).
log "Google Chrome"
# Explicit `brew update` first: HOMEBREW_NO_AUTO_UPDATE=1 (set above) freezes
# brew's cask index to the last tap sync, so an upgrade would never see a newer
# version.
brew update
if brew list --cask google-chrome >/dev/null 2>&1; then
  # brew-managed: upgrade to latest. --greedy because Chrome's cask is
  # auto_updates and a plain `brew upgrade` skips such casks.
  brew upgrade --cask --greedy google-chrome
else
  # Fresh machine, or Chrome present but not installed via brew (so brew can't
  # upgrade it). --force (re)installs the latest cask and brings it under brew
  # management, so subsequent runs take the upgrade path above.
  brew install --cask --force google-chrome
fi
echo "chrome: $('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' --version 2>/dev/null || echo 'version unavailable')"

# 5. screenresolution — pin the display for stable perf numbers
#    (the existing macos_performance_tests.yml CI does this too).
log "screenresolution"
if ! command -v screenresolution >/dev/null 2>&1; then
  brew install screenresolution || echo "WARNING: screenresolution install failed; display will not be pinned."
fi

# 6. WPR (recorded network, deterministic runs) — crossbench does NOT ship the
#    `wpr` binary, only a DEPS pin of its Go source. Clone the pinned source
#    (a poetry-only setup never runs gclient sync, which is what would normally
#    populate third_party/) and `go build` it ourselves; test-chrome.sh hands
#    the binary to crossbench via --bin-override, so crossbench's own build
#    machinery (scripts/build.py + a gclient-hermetic Go toolchain) is never
#    involved. The checkout must stay in third_party/webpagereplay: crossbench
#    also reads deterministic.js and the ecdsa key/cert from it at runtime.
#    NOTE: traffic shaping (speed=...) is intentionally NOT provisioned — it
#    needs third_party/tsproxy, whose pinned tsproxy.py is Python-2-only and
#    silently drops every connection under Python 3.
log "Go toolchain (builds the wpr binary)"
brew list go >/dev/null 2>&1 || brew install go
echo "go: $(go version)"

log "WebPageReplay source (pinned by crossbench DEPS) + wpr build"
WPR_SRC="$CROSSBENCH_DIR/third_party/webpagereplay"
if [ -d "$WPR_SRC/.git" ] && [ "$(git -C "$WPR_SRC" rev-parse HEAD 2>/dev/null)" = "$WEBPAGEREPLAY_REV" ]; then
  echo "webpagereplay: already at $WEBPAGEREPLAY_REV"
else
  rm -rf "$WPR_SRC"
  git clone --quiet "$WEBPAGEREPLAY_GIT" "$WPR_SRC"
  git -C "$WPR_SRC" -c advice.detachedHead=false checkout --quiet --detach "$WEBPAGEREPLAY_REV"
  echo "webpagereplay: checked out $WEBPAGEREPLAY_REV"
fi
mkdir -p "$(dirname "$WPR_BIN")"
# Same flags crossbench's build.py would use; incremental, sub-second when fresh.
go build -C "$WPR_SRC/src" -trimpath -buildvcs=false -o "$WPR_BIN" wpr.go
echo "wpr: $WPR_BIN"

# 7. Self-heal the fork-only crossbench extras + cpu_freq patch.
#    These are the pieces a plain `git clone` of crossbench does NOT provide but
#    the LCP run depends on. They live versioned next to this script and are
#    (re)installed into CROSSBENCH_DIR here, idempotently, so a fresh or updated
#    clone can never silently drop them:
#      - config/probe/perfetto/navToLCP.config.hjson       (the probe config)
#      - crossbench/probes/trace_processor/modules/ext/largestcontentfulpaint.sql
#        (the LCP SQL module; if missing, LCP silently returns no rows / -1)
#      - crossbench/plt/macos.py cpu_freq() AttributeError fix (psutil 7.2.1 on
#        arm64 raises AttributeError, which stock crossbench doesn't catch).
log "crossbench extras + cpu_freq patch (self-heal)"
if [ ! -f "$CROSSBENCH_DIR/cb.py" ]; then
  echo "ERROR: crossbench checkout not found at $CROSSBENCH_DIR (cb.py missing)." >&2
  echo "Clone it there first (e.g. git clone https://github.com/google/crossbench $CROSSBENCH_DIR)." >&2
  exit 1
fi
# Copy the extras, preserving their crossbench-relative paths. `cp -R <dir>/.`
# merges into the destination tree without clobbering unrelated files.
cp -R "$EXTRAS_DIR/." "$CROSSBENCH_DIR/"
echo "extras: installed navToLCP.config.hjson + largestcontentfulpaint.sql"
# Apply the cpu_freq patch idempotently. The one-line change is identical on
# upstream and the fork but sits at different line numbers, so we guard on the
# patched text rather than relying on `git apply` context matching.
MACOS_PY="$CROSSBENCH_DIR/crossbench/plt/macos.py"
if grep -q 'except (AttributeError, FileNotFoundError, SystemError, RuntimeError)' "$MACOS_PY"; then
  echo "cpu_freq patch: already applied"
elif grep -q 'except (FileNotFoundError, SystemError, RuntimeError) as e:' "$MACOS_PY"; then
  # In-place, line-number independent.
  perl -0pi -e 's/except \(FileNotFoundError, SystemError, RuntimeError\) as e:/except (AttributeError, FileNotFoundError, SystemError, RuntimeError) as e:/' "$MACOS_PY"
  echo "cpu_freq patch: applied"
else
  echo "WARNING: cpu_freq patch target not found in $MACOS_PY; crossbench may have changed upstream." >&2
  echo "         Reconcile patches/cpu_freq-attributeerror.patch against the new source." >&2
fi

# 8. crossbench Python deps.
#    NOTE: crossbench ships a git-tracked '.vpython3' marker that makes it re-exec
#    under Chromium's vpython instead of our poetry venv. It must be removed, but
#    that belongs in the RUN step (right before invoking cb.py), not here — a
#    checkout after provisioning would restore it. --no-root is intentionally
#    omitted: the crossbench package + cb entry point require the root install.
log "crossbench deps (poetry install)"
cd "$CROSSBENCH_DIR"
poetry env use "$PY_BIN"
poetry install

log "Provisioning complete"
