#!/usr/bin/env bash
#
# test-ddg.sh — DuckDuckGo macOS (WebKit) page-load / LCP run against recorded
# network (Web Page Replay). The WKWebView counterpart to test-chrome.sh.
#
# WHY THIS IS DIFFERENT FROM CHROME:
#   Chrome reaches WPR via --host-resolver-rules (remap every host to the WPR
#   ports) and needs no proxy. WKWebView has no host-resolver knob, so DDG is
#   pointed at a SOCKS5 proxy (standalone tsproxy) that redirects EVERY
#   destination to the local WPR origin and remaps 443->WPR-https / 80->WPR-http.
#   For that to work the browser must (both Debug/Review-gated launch options):
#     1. send all web traffic to the proxy  -> webViewProxy=host:port
#     2. accept WPR's self-signed cert       -> acceptInsecureCerts=true
#   DDG is driven directly through its AutomationServer (a Debug/Review HTTP
#   server on [::1]:PORT) — NOT crossbench — and emits LCP itself via a buffered
#   PerformanceObserver, because WebKit produces no Perfetto trace.
#
# SHARED WITH CHROME (data, not code): the wpr binary, the WPR archives, the
# WPR_BASE_URL, and the site list. A common.sh extraction is the intended next
# cleanup (see README); kept self-contained here so the working Chrome path is
# untouched while this is proven out.
#
# NO TRAFFIC SHAPING (same as test-chrome.sh): tsproxy runs pass-through, so WPR
# replays at loopback speed — deterministic, but faster than the Windows
# US-broadband-shaped runs. Don't compare DDG absolute values to Windows; DO
# compare DDG-vs-Chrome on THIS runner (same shaping, same archives).
#
# Prereqs: provision-macos.sh (wpr binary + archives dir), and an INSTALLED DDG
# Review or Debug build whose app supports the webViewProxy / acceptInsecureCerts
# launch options. Point DDG_APP at it (defaults to a Review build in /Applications).
#
# Usage:
#   ./test-ddg.sh [--reps N] [--sites a.com,b.com]
#
set -euo pipefail

# ---- config / args ---------------------------------------------------------
REPS="10"
SITES_OVERRIDE=""

WPR_DIR="${WPR_DIR:-$HOME/Developer/mac-perf-runner/wpr-archives}"
WPR_BIN="${WPR_BIN:-$HOME/Developer/mac-perf-runner/bin/wpr}"
WPR_BASE_URL="${WPR_BASE_URL:-https://staticcdn.duckduckgo.com/d5c04536-5379-4709-8d19-d13fdd456ff6/performance-tests}"
WPR_HTTP_PORT="${WPR_HTTP_PORT:-8080}"
WPR_HTTPS_PORT="${WPR_HTTPS_PORT:-8081}"
# Optional explicit WPR cert/key. If unset we look next to WPR_BIN and, failing
# that, let wpr use its own defaults (which is how it ran during bring-up).
WPR_CERT_FILE="${WPR_CERT_FILE:-}"
WPR_KEY_FILE="${WPR_KEY_FILE:-}"

# Standalone tsproxy (NOT crossbench's DEPS-pinned copy, which is Python-2-only).
# Fetched from catapult if missing. Runs under the system python3.
TSPROXY_PY="${TSPROXY_PY:-$HOME/Developer/mac-perf-runner/bin/tsproxy.py}"
TSPROXY_URL="${TSPROXY_URL:-https://chromium.googlesource.com/catapult/+/refs/heads/main/third_party/tsproxy/tsproxy.py?format=TEXT}"
PROXY_PORT="${PROXY_PORT:-9999}"

# DDG app + automation.
DDG_APP="${DDG_APP:-/Applications/DuckDuckGo Review.app}"
DDG_BUNDLE_ID="${DDG_BUNDLE_ID:-com.duckduckgo.macos.browser.review}"
AUTOMATION_PORT="${AUTOMATION_PORT:-8788}"

# Dwell after navigation before reading LCP (matches test-chrome.sh's 12s window),
# then the buffered-observer settle inside the browser.
LOAD_WINDOW_SECS="${LOAD_WINDOW_SECS:-12}"
LCP_SETTLE_MS="${LCP_SETTLE_MS:-600}"
READY_TIMEOUT_SECS="${READY_TIMEOUT_SECS:-45}"

# Clear the app's on-disk cache between reps so every rep is a cold load (and so
# every rep actually hits WPR). Set NO_CACHE_CLEAR=1 to keep the cache warm.
NO_CACHE_CLEAR="${NO_CACHE_CLEAR:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRIVER="${DRIVER:-$SCRIPT_DIR/ddg-automation.py}"

while [ $# -gt 0 ]; do
  case "$1" in
    --reps)    REPS="$2"; shift 2 ;;
    --sites)   SITES_OVERRIDE="$2"; shift 2 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

log() { printf '\n=== %s ===\n' "$1"; }

# Site list — identical to test-chrome.sh so the two are directly comparable.
SITES=(
  youtube.com wikipedia.org reddit.com amazon.com yelp.com
  weather.com yahoo.com apple.com fandom.com tripadvisor.com
  tiktok.com indeed.com spotify.com nih.gov espn.com
  walmart.com nytimes.com clevelandclinic.org ny.gov quora.com
  zillow.com mayoclinic.org
)
if [ -n "$SITES_OVERRIDE" ]; then
  IFS=',' read -r -a SITES <<< "$SITES_OVERRIDE"
fi

# story filename normalization, matching test-chrome.sh ('+'->'_', '/'->'_').
normalize() { printf '%s' "$1" | tr '+/' '__'; }

# ---- process lifecycle -----------------------------------------------------
WPR_PID=""
TSPROXY_PID=""
DDG_PID=""
WPR_LOG=""
TSPROXY_LOG=""

# Kill only PIDs we launched (never by name — a name match could hit an unrelated
# browser the operator is running).
kill_pid() {
  local pid="$1"
  [ -n "$pid" ] || return 0
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    for _ in 1 2 3 4 5 6; do
      kill -0 "$pid" 2>/dev/null || return 0
      sleep 0.5
    done
    kill -9 "$pid" 2>/dev/null || true
  fi
}

cleanup() {
  quit_ddg
  kill_pid "$TSPROXY_PID"
  kill_pid "$WPR_PID"
  [ -n "$TSPROXY_LOG" ] && rm -f "$TSPROXY_LOG"
  [ -n "$WPR_LOG" ] && rm -f "$WPR_LOG"
}
trap cleanup EXIT

# ---- preflight -------------------------------------------------------------
ensure_tsproxy() {
  [ -f "$TSPROXY_PY" ] && return 0
  echo "tsproxy not found at $TSPROXY_PY; fetching from catapult..." >&2
  mkdir -p "$(dirname "$TSPROXY_PY")"
  # gitiles serves source base64-encoded when ?format=TEXT.
  if curl -fLSs "$TSPROXY_URL" | python3 -c 'import base64,sys; sys.stdout.buffer.write(base64.b64decode(sys.stdin.read()))' > "$TSPROXY_PY.tmp" 2>/dev/null && [ -s "$TSPROXY_PY.tmp" ]; then
    mv "$TSPROXY_PY.tmp" "$TSPROXY_PY"
  else
    rm -f "$TSPROXY_PY.tmp"
    echo "ERROR: could not fetch tsproxy. Set TSPROXY_PY to a local copy." >&2
    exit 1
  fi
}

preflight() {
  if [ ! -x "$WPR_BIN" ]; then
    echo "ERROR: wpr binary not found at $WPR_BIN. Run provision-macos.sh first." >&2
    exit 1
  fi
  if [ ! -d "$DDG_APP" ]; then
    echo "ERROR: DDG app not found at $DDG_APP. Install a Review/Debug build and set DDG_APP." >&2
    exit 1
  fi
  DDG_EXEC="$DDG_APP/Contents/MacOS/$(defaults read "$DDG_APP/Contents/Info" CFBundleExecutable 2>/dev/null || echo DuckDuckGo)"
  if [ ! -x "$DDG_EXEC" ]; then
    echo "ERROR: DDG executable not found at $DDG_EXEC." >&2
    exit 1
  fi
  if [ ! -f "$DRIVER" ]; then
    echo "ERROR: automation driver not found at $DRIVER." >&2
    exit 1
  fi
  command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 not found." >&2; exit 1; }
  mkdir -p "$WPR_DIR"
  ensure_tsproxy
}

# Wait for a TCP port on 127.0.0.1 to accept connections.
wait_for_port() {
  local port="$1" timeout="${2:-15}" i
  for ((i = 0; i < timeout * 2; i++)); do
    if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
      exec 3>&- 3<&- 2>/dev/null || true
      return 0
    fi
    sleep 0.5
  done
  return 1
}

# ---- WPR + tsproxy ---------------------------------------------------------
fetch_archive() {
  # Echo the archive path on success, nothing on failure.
  local story="$1" normalized archive
  normalized="$(normalize "$story")"
  archive="$WPR_DIR/$normalized.wprgo"
  if curl -fLSs -o "$archive.tmp" "$WPR_BASE_URL/$normalized.wprgo" 2>/dev/null; then
    mv "$archive.tmp" "$archive"
    printf '%s' "$archive"
  else
    rm -f "$archive.tmp"
    [ -f "$archive" ] && printf '%s' "$archive"  # reuse a previously-downloaded one
  fi
}

start_wpr() {
  local archive="$1"
  WPR_LOG="$(mktemp)"
  local -a cert_args=()
  local cert="$WPR_CERT_FILE" key="$WPR_KEY_FILE"
  [ -z "$cert" ] && [ -f "$(dirname "$WPR_BIN")/wpr_cert.pem" ] && cert="$(dirname "$WPR_BIN")/wpr_cert.pem"
  [ -z "$key" ] && [ -f "$(dirname "$WPR_BIN")/wpr_key.pem" ] && key="$(dirname "$WPR_BIN")/wpr_key.pem"
  if [ -n "$cert" ] && [ -n "$key" ]; then
    cert_args=(--https_cert_file "$cert" --https_key_file "$key")
  fi
  "$WPR_BIN" replay \
    --http_port="$WPR_HTTP_PORT" \
    --https_port="$WPR_HTTPS_PORT" \
    "${cert_args[@]}" \
    "$archive" >"$WPR_LOG" 2>&1 &
  WPR_PID=$!
  if ! wait_for_port "$WPR_HTTPS_PORT" 15; then
    echo "ERROR: WPR did not start on port $WPR_HTTPS_PORT. Log:" >&2
    cat "$WPR_LOG" >&2
    exit 1
  fi
}

stop_wpr() {
  kill_pid "$WPR_PID"
  WPR_PID=""
  [ -n "$WPR_LOG" ] && rm -f "$WPR_LOG"
  WPR_LOG=""
}

start_tsproxy() {
  TSPROXY_LOG="$(mktemp)"
  # SOCKS5 on PROXY_PORT; redirect every destination to loopback WPR, remapping
  # 443->WPR-https and 80->WPR-http. No -r/-i/-o => no shaping (pass-through).
  python3 "$TSPROXY_PY" \
    --port "$PROXY_PORT" \
    --desthost 127.0.0.1 \
    --mapports "443:$WPR_HTTPS_PORT,80:$WPR_HTTP_PORT" \
    >"$TSPROXY_LOG" 2>&1 &
  TSPROXY_PID=$!
  if ! wait_for_port "$PROXY_PORT" 15; then
    echo "ERROR: tsproxy did not start on port $PROXY_PORT. Log:" >&2
    cat "$TSPROXY_LOG" >&2
    exit 1
  fi
}

# ---- DDG lifecycle ---------------------------------------------------------
DDG_EXEC=""

clear_ddg_cache() {
  [ -n "$NO_CACHE_CLEAR" ] && return 0
  local container="$HOME/Library/Containers/$DDG_BUNDLE_ID/Data/Library"
  # Only the .review/.debug container is ever touched here — never the public app.
  [ -d "$container/Caches" ] && rm -rf "$container/Caches" 2>/dev/null || true
  [ -d "$container/WebKit/NetworkCache" ] && rm -rf "$container/WebKit/NetworkCache" 2>/dev/null || true
}

launch_ddg() {
  # Launch options via the app's sandbox container defaults. (defaults write on
  # the bare suite only lands in the container once the app lives in /Applications.)
  defaults write "$DDG_BUNDLE_ID" automationPort -int "$AUTOMATION_PORT"
  defaults write "$DDG_BUNDLE_ID" webViewProxy -string "127.0.0.1:$PROXY_PORT"
  defaults write "$DDG_BUNDLE_ID" acceptInsecureCerts -bool true
  defaults write "$DDG_BUNDLE_ID" isOnboardingCompleted -string true

  open -a "$DDG_APP"

  # run_ddg() already killed any pre-existing instance of THIS build, so the
  # newest process whose command line is our full app executable path is the one
  # we just launched. Full-path match can't hit another (public) browser, and
  # WebKit's helper processes live under WebKit.framework, not this path.
  local i
  DDG_PID=""
  for ((i = 0; i < 20; i++)); do
    DDG_PID="$(pgrep -n -f "$DDG_EXEC" 2>/dev/null || true)"
    [ -n "$DDG_PID" ] && break
    sleep 0.5
  done

  if ! python3 "$DRIVER" "$AUTOMATION_PORT" wait-ready "$READY_TIMEOUT_SECS"; then
    echo "ERROR: DDG automation server never became ready on port $AUTOMATION_PORT." >&2
    echo "  Is this a Debug/Review build with automationPort support? Is another instance running?" >&2
    return 1
  fi
}

quit_ddg() {
  [ -n "$DDG_PID" ] || return 0
  python3 "$DRIVER" "$AUTOMATION_PORT" shutdown >/dev/null 2>&1 || true
  sleep 1
  kill_pid "$DDG_PID"
  DDG_PID=""
}

# ---- measurement -----------------------------------------------------------
# Assert the navigation actually traversed the proxy (=> WPR served it), so a
# silent live-network fallback can't masquerade as a valid measurement.
proxy_saw_traffic() {
  local before="$1" after
  after="$(wc -l < "$TSPROXY_LOG" 2>/dev/null || echo 0)"
  [ "$after" -gt "$before" ]
}

summarize_lcp() {
  local site="$1"; shift
  local -a vals=("$@")
  if [ "${#vals[@]}" -eq 0 ]; then
    echo "  $site: NO LCP VALUES (all reps failed or bypassed the proxy)"
    return
  fi
  printf '  %s: lcp_ms=[%s] ' "$site" "$(IFS=,; echo "${vals[*]}")"
  printf '%s\n' "${vals[@]}" | awk '{s+=$1; n++} END{printf "mean=%.1f n=%d\n", s/n, n}'
}

measure_site() {
  local site="$1" story archive
  story="navToLCP+$site"
  archive="$(fetch_archive "$story")"
  if [ -z "$archive" ]; then
    echo "  $site: no WPR archive available; SKIPPING (DDG runs replay-only)." >&2
    return
  fi

  start_wpr "$archive"

  local -a vals=()
  local rep ts_before lcp detail
  for ((rep = 1; rep <= REPS; rep++)); do
    clear_ddg_cache
    if ! launch_ddg; then
      quit_ddg
      continue
    fi

    ts_before="$(wc -l < "$TSPROXY_LOG" 2>/dev/null || echo 0)"
    python3 "$DRIVER" "$AUTOMATION_PORT" navigate "https://$site" >/dev/null || true
    sleep "$LOAD_WINDOW_SECS"

    detail="$(python3 "$DRIVER" "$AUTOMATION_PORT" lcp-detail "$LCP_SETTLE_MS" 2>/dev/null || true)"
    lcp="$(python3 "$DRIVER" "$AUTOMATION_PORT" lcp "$LCP_SETTLE_MS" 2>/dev/null || true)"

    if ! proxy_saw_traffic "$ts_before"; then
      echo "  $site rep $rep: WARNING — no proxy traffic; navigation bypassed WPR. Dropping." >&2
      quit_ddg
      continue
    fi
    if [ -z "$lcp" ] || awk -v v="$lcp" 'BEGIN{exit !(v+0 <= 0)}'; then
      echo "  $site rep $rep: LCP not finalized ($lcp). Dropping. detail=$detail" >&2
      quit_ddg
      continue
    fi

    vals+=("$lcp")
    echo "  $site rep $rep: lcp_ms=$lcp  detail=$detail"
    quit_ddg
  done

  stop_wpr
  summarize_lcp "$site" "${vals[@]}"
}

# ---- run -------------------------------------------------------------------
run_ddg() {
  log "DDG LCP run — ${#SITES[@]} sites, $REPS reps, ${LOAD_WINDOW_SECS}s window, proxy 127.0.0.1:$PROXY_PORT -> WPR"
  # Quit any pre-existing instance of THIS build (path-scoped) for a clean start.
  local existing
  existing="$(pgrep -f "$DDG_EXEC" 2>/dev/null || true)"
  for pid in $existing; do kill_pid "$pid"; done

  start_tsproxy

  local site
  for site in "${SITES[@]}"; do
    log "site: $site"
    measure_site "$site"
  done
}

# ---- main ------------------------------------------------------------------
preflight
run_ddg
log "Done"
