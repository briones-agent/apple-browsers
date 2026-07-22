#!/usr/bin/env bash
#
# test-safari.sh — Safari (WebKit) page-load / LCP run against recorded network
# (Web Page Replay). The real-Safari counterpart to test-ddg.sh.
#
# WHY THIS DIFFERS FROM DDG (and Chrome):
#   Safari is Apple's app — we can't set a per-instance proxy the way we do for our
#   own WKWebView in DDG (webViewProxy / acceptInsecureCerts), and safaridriver does
#   not honour the WebDriver `proxy` capability. Chrome uses --host-resolver-rules;
#   Safari has no such knob. But Safari DOES read a proxy from its own prefs domain:
#     defaults write com.apple.Safari WebKit2HTTPProxy  http://127.0.0.1:PORT
#     defaults write com.apple.Safari WebKit2HTTPSProxy http://127.0.0.1:PORT
#   That is a PER-APP proxy — no root, and only Safari is affected. We point it at a
#   tiny local HTTP forward proxy (httpproxy.py) that funnels everything to WPR.
#
#   We deliberately do NOT use a machine-wide system SOCKS proxy (networksetup):
#   it needs root AND — proven on this VM — it drops the inbound SSH connection on
#   the first proxied navigation, so unattended SSH-driven runs are impossible with
#   it. The per-app proxy leaves SSH (and the rest of the box) untouched.
#
#   Safari is driven via safaridriver (W3C WebDriver) by safari-automation.py, and
#   emits LCP itself via a buffered PerformanceObserver — same as DDG, because
#   WebKit produces no Perfetto trace.
#
# CERT / TLS: WPR serves a self-signed cert; Safari validates TLS normally. WPR is
#   handed the ECDSA (P-256) root ONLY — its bundled RSA root is 1024-bit, which
#   Apple's TLS rejects ("illegal parameter" handshake failure). --no-archive-certificates
#   forces fresh leaves minted from that root at replay time. The ECDSA root must be
#   trusted ONCE in the System keychain (a GUI-only step; headless SSH trust is
#   impossible on macOS 26) — see commission-safari.sh.
#
# NO PER-RUN SUDO: the only privileged setup (trust the ECDSA cert, safaridriver
#   --enable, and ticking Safari > Develop > Allow Remote Automation) is one-time,
#   done by commission-safari.sh. This script itself needs no sudo, so it runs
#   unattended over plain SSH.
#
# NO TRAFFIC SHAPING (same as test-ddg.sh / test-chrome.sh): the proxy is
#   pass-through, so WPR replays at loopback speed. Compare Safari-vs-DDG-vs-Chrome
#   on THIS runner (same archives), NOT against the Windows runs.
#
# Prereqs: provision-macos.sh (wpr binary + archives dir); commission-safari.sh run
#   once (ECDSA cert trusted + safaridriver enabled + Allow Remote Automation);
#   httpproxy.py alongside this script; and the WPR ECDSA cert/key (set
#   WPR_CERT_FILE=ecdsa_cert.pem, WPR_KEY_FILE=ecdsa_key.pem).
#
# Usage:
#   ./test-safari.sh [--reps N] [--sites a.com,b.com] [--yes]
#
set -euo pipefail

# ---- config / args ---------------------------------------------------------
REPS="10"
SITES_OVERRIDE=""
ASSUME_YES="${ASSUME_YES:-}"

WPR_DIR="${WPR_DIR:-$HOME/Developer/mac-perf-runner/wpr-archives}"
WPR_BIN="${WPR_BIN:-$HOME/Developer/mac-perf-runner/bin/wpr}"
WPR_BASE_URL="${WPR_BASE_URL:-https://staticcdn.duckduckgo.com/d5c04536-5379-4709-8d19-d13fdd456ff6/performance-tests}"
# NOT 8080/8081 (the default the Chrome/DDG paths use): safaridriver's launchd XPC
# service `com.apple.WebDriver.HTTPService` squats *:8080 whenever automation is
# active, which would collide with WPR since WPR here starts AFTER safaridriver.
WPR_HTTP_PORT="${WPR_HTTP_PORT:-18080}"
WPR_HTTPS_PORT="${WPR_HTTPS_PORT:-18081}"
# The ECDSA (P-256) cert/key WPR serves. Defaults to ecdsa_cert.pem next to the
# binary; the RSA root must NOT be used (1024-bit, rejected by Apple TLS).
WPR_CERT_FILE="${WPR_CERT_FILE:-}"
WPR_KEY_FILE="${WPR_KEY_FILE:-}"

# Tiny local HTTP forward proxy in front of WPR (CONNECT -> WPR-https, absolute-form
# GET -> WPR-http). Replaces the SOCKS tsproxy the DDG path uses.
HTTPPROXY_PY="${HTTPPROXY_PY:-}"
PROXY_PORT="${PROXY_PORT:-9998}"

# Safari's prefs domain that the per-app proxy is written to.
SAFARI_DOMAIN="com.apple.Safari"

# safaridriver W3C server port (distinct from DDG's automation port).
SAFARIDRIVER_PORT="${SAFARIDRIVER_PORT:-8790}"

# Dwell after navigation before reading LCP (matches test-chrome.sh's 12s window),
# then the buffered-observer settle inside the browser.
LOAD_WINDOW_SECS="${LOAD_WINDOW_SECS:-12}"
LCP_SETTLE_MS="${LCP_SETTLE_MS:-600}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRIVER="${DRIVER:-$SCRIPT_DIR/safari-automation.py}"
[ -z "$HTTPPROXY_PY" ] && HTTPPROXY_PY="$SCRIPT_DIR/httpproxy.py"

while [ $# -gt 0 ]; do
  case "$1" in
    --reps)    REPS="$2"; shift 2 ;;
    --sites)   SITES_OVERRIDE="$2"; shift 2 ;;
    --yes|-y)  ASSUME_YES="1"; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

log() { printf '\n=== %s ===\n' "$1"; }

# Site list — identical to test-chrome.sh / test-ddg.sh so all three are
# directly comparable.
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

# story filename normalization, matching the other scripts ('+'->'_', '/'->'_').
normalize() { printf '%s' "$1" | tr '+/' '__'; }

# ---- process / system state we own -----------------------------------------
WPR_PID=""
HTTPPROXY_PID=""
SAFARIDRIVER_PID=""
WPR_LOG=""
HTTPPROXY_LOG=""
SAFARIDRIVER_LOG=""

CERT_FILE=""            # resolved WPR ECDSA cert, set in preflight
PROXY_APPLIED=""        # set once we've written the per-app proxy defaults

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

# ---- routing (per-app proxy, no sudo) --------------------------------------
# Point Safari at our HTTP forward proxy via its OWN prefs domain — no root, no
# machine-wide proxy, only Safari is affected (so SSH stays up). Requires the WPR
# ECDSA cert already trusted in the System keychain (one-time; commission-safari.sh).
apply_proxy_state() {
  defaults write "$SAFARI_DOMAIN" WebKit2HTTPProxy  "http://127.0.0.1:$PROXY_PORT"
  defaults write "$SAFARI_DOMAIN" WebKit2HTTPSProxy "http://127.0.0.1:$PROXY_PORT"
  PROXY_APPLIED="1"
}

restore_proxy_state() {
  [ -n "$PROXY_APPLIED" ] || return 0
  defaults delete "$SAFARI_DOMAIN" WebKit2HTTPProxy  2>/dev/null || true
  defaults delete "$SAFARI_DOMAIN" WebKit2HTTPSProxy 2>/dev/null || true
  PROXY_APPLIED=""
}

cleanup() {
  # Preserve the exit code that triggered the trap: this runs as an EXIT trap and
  # bash uses the trap's LAST command status as the script's exit code, so without
  # this a successful run would exit non-zero (the final guarded rm evaluates false
  # once stop_wpr has blanked WPR_LOG).
  local ec=$?
  # Stop driving/serving first, then undo the per-app proxy.
  kill_pid "$SAFARIDRIVER_PID"
  kill_pid "$HTTPPROXY_PID"
  kill_pid "$WPR_PID"
  restore_proxy_state
  [ -n "$SAFARIDRIVER_LOG" ] && rm -f "$SAFARIDRIVER_LOG"
  [ -n "$HTTPPROXY_LOG" ] && rm -f "$HTTPPROXY_LOG"
  [ -n "$WPR_LOG" ] && rm -f "$WPR_LOG"
  return $ec
}
trap cleanup EXIT

# ---- preflight -------------------------------------------------------------
resolve_cert() {
  CERT_FILE="$WPR_CERT_FILE"
  [ -z "$CERT_FILE" ] && [ -f "$(dirname "$WPR_BIN")/ecdsa_cert.pem" ] && CERT_FILE="$(dirname "$WPR_BIN")/ecdsa_cert.pem"
  if [ -z "$CERT_FILE" ] || [ ! -f "$CERT_FILE" ]; then
    echo "ERROR: WPR ECDSA cert not found. Set WPR_CERT_FILE to ecdsa_cert.pem —" >&2
    echo "       WPR must serve the P-256 ECDSA root; the bundled 1024-bit RSA root" >&2
    echo "       is rejected by Apple's TLS ('illegal parameter' handshake failure)." >&2
    exit 1
  fi
  [ -z "$WPR_KEY_FILE" ] && WPR_KEY_FILE="$(dirname "$CERT_FILE")/ecdsa_key.pem"
  if [ ! -f "$WPR_KEY_FILE" ]; then
    echo "ERROR: WPR ECDSA key not found at $WPR_KEY_FILE. Set WPR_KEY_FILE." >&2
    exit 1
  fi
}

preflight() {
  if [ ! -x "$WPR_BIN" ]; then
    echo "ERROR: wpr binary not found at $WPR_BIN. Run provision-macos.sh first." >&2
    exit 1
  fi
  if [ ! -f "$DRIVER" ]; then
    echo "ERROR: automation driver not found at $DRIVER." >&2
    exit 1
  fi
  if [ ! -f "$HTTPPROXY_PY" ]; then
    echo "ERROR: HTTP forward proxy not found at $HTTPPROXY_PY." >&2
    exit 1
  fi
  command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 not found." >&2; exit 1; }
  command -v safaridriver >/dev/null 2>&1 || { echo "ERROR: safaridriver not found." >&2; exit 1; }
  command -v defaults >/dev/null 2>&1 || { echo "ERROR: defaults not found." >&2; exit 1; }
  mkdir -p "$WPR_DIR"
  resolve_cert
}

confirm() {
  [ -n "$ASSUME_YES" ] && return 0
  cat >&2 <<EOF

⚠️  test-safari.sh will, for the duration of the run:
      • set a per-app proxy on Safari ($SAFARI_DOMAIN) -> 127.0.0.1:$PROXY_PORT -> WPR
    Only Safari is affected (no machine-wide proxy, no sudo). Requires the WPR ECDSA
    cert already trusted in the System keychain (one-time; run ./commission-safari.sh).
    The proxy setting is removed automatically on exit (including Ctrl-C).

EOF
  read -r -p "Proceed? [y/N] " ans
  case "$ans" in y|Y|yes|YES) ;; *) echo "Aborted." >&2; exit 1 ;; esac
}

# Wait for a TCP port on 127.0.0.1 to accept connections.
wait_for_port() {
  local port="$1" timeout="${2:-15}" i
  for ((i = 0; i < timeout * 2; i++)); do
    if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
      return 0
    fi
    sleep 0.5
  done
  return 1
}

# Fail loudly if a port is already taken (e.g. a stale wpr/httpproxy from a crashed
# run). Without this, wait_for_port would see the FOREIGN server answering, our own
# process would have quietly failed to bind, and the run would measure against the
# wrong server (or wrong archive) with no hint anything was off.
assert_port_free() {
  local port="$1" label="$2"
  if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
    echo "ERROR: port $port ($label) is already in use — likely a stale wpr/httpproxy" >&2
    echo "       from a previous run. Find and kill it, then re-run:" >&2
    echo "         lsof -nP -iTCP:$port -sTCP:LISTEN" >&2
    exit 1
  fi
}

# ---- WPR + HTTP proxy ------------------------------------------------------
fetch_archive() {
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
  assert_port_free "$WPR_HTTP_PORT" "wpr-http"
  assert_port_free "$WPR_HTTPS_PORT" "wpr-https"
  # ECDSA-only: the bundled RSA root is 1024-bit, which Apple's TLS rejects.
  # --no-archive-certificates forces fresh leaves minted from this root at replay
  # time instead of any (possibly RSA/expired) certs stored in the archive.
  "$WPR_BIN" replay \
    --http-port="$WPR_HTTP_PORT" \
    --https-port="$WPR_HTTPS_PORT" \
    --https-cert-file="$CERT_FILE" \
    --https-key-file="$WPR_KEY_FILE" \
    --no-archive-certificates \
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

start_httpproxy() {
  HTTPPROXY_LOG="$(mktemp)"
  assert_port_free "$PROXY_PORT" "httpproxy"
  python3 "$HTTPPROXY_PY" "$PROXY_PORT" "$WPR_HTTP_PORT" "$WPR_HTTPS_PORT" >"$HTTPPROXY_LOG" 2>&1 &
  HTTPPROXY_PID=$!
  if ! wait_for_port "$PROXY_PORT" 10; then
    echo "ERROR: httpproxy did not start on port $PROXY_PORT. Log:" >&2
    cat "$HTTPPROXY_LOG" >&2
    exit 1
  fi
}

# ---- safaridriver ----------------------------------------------------------
start_safaridriver() {
  # No sudo: safaridriver was enabled once by commission-safari.sh.
  SAFARIDRIVER_LOG="$(mktemp)"
  safaridriver -p "$SAFARIDRIVER_PORT" >"$SAFARIDRIVER_LOG" 2>&1 &
  SAFARIDRIVER_PID=$!
  if ! wait_for_port "$SAFARIDRIVER_PORT" 15; then
    echo "ERROR: safaridriver did not start on port $SAFARIDRIVER_PORT. Log:" >&2
    cat "$SAFARIDRIVER_LOG" >&2
    exit 1
  fi
  if ! python3 "$DRIVER" "$SAFARIDRIVER_PORT" check; then
    echo "ERROR: could not create a Safari WebDriver session." >&2
    echo "  Run ./commission-safari.sh once (safaridriver --enable + Safari > Develop >" >&2
    echo "  Allow Remote Automation), then re-run." >&2
    exit 1
  fi
}

# ---- measurement -----------------------------------------------------------
# Assert the navigation actually traversed the proxy (=> WPR served it), so a
# silent live-network fallback can't masquerade as a valid measurement.
proxy_saw_traffic() {
  local before="$1" after
  after="$(wc -l < "$HTTPPROXY_LOG" 2>/dev/null || echo 0)"
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
    echo "  $site: no WPR archive available; SKIPPING (Safari runs replay-only)." >&2
    return
  fi

  start_wpr "$archive"

  local -a vals=()
  local rep ts_before out lcp detail
  for ((rep = 1; rep <= REPS; rep++)); do
    # A fresh WebDriver session per rep gives Safari clean automation state
    # (assumed cold; safaridriver isolates automation sessions from normal
    # browsing — not independently verified here). WPR makes content identical
    # regardless, so this only affects cache warmth.
    ts_before="$(wc -l < "$HTTPPROXY_LOG" 2>/dev/null || echo 0)"
    out="$(python3 "$DRIVER" "$SAFARIDRIVER_PORT" measure "https://$site" "$LCP_SETTLE_MS" "$LOAD_WINDOW_SECS" 2>/dev/null || true)"
    lcp="$(printf '%s\n' "$out" | sed -n 's/^lcp_ms=//p' | tail -1)"
    detail="$(printf '%s\n' "$out" | sed -n 's/^detail=//p' | tail -1)"

    if ! proxy_saw_traffic "$ts_before"; then
      echo "  $site rep $rep: WARNING — no proxy traffic; navigation bypassed WPR. Dropping." >&2
      continue
    fi
    if [ -z "$lcp" ] || awk -v v="$lcp" 'BEGIN{exit !(v+0 <= 0)}'; then
      echo "  $site rep $rep: LCP not finalized ($lcp). Dropping. detail=$detail" >&2
      continue
    fi

    vals+=("$lcp")
    echo "  $site rep $rep: lcp_ms=$lcp  detail=$detail"
  done

  stop_wpr
  summarize_lcp "$site" "${vals[@]}"
}

# ---- run -------------------------------------------------------------------
run_safari() {
  log "Safari LCP run — ${#SITES[@]} sites, $REPS reps, ${LOAD_WINDOW_SECS}s window, per-app proxy on $SAFARI_DOMAIN -> 127.0.0.1:$PROXY_PORT -> WPR"
  start_httpproxy
  apply_proxy_state
  start_safaridriver

  local site
  for site in "${SITES[@]}"; do
    log "site: $site"
    measure_site "$site"
  done
}

# ---- main ------------------------------------------------------------------
preflight
confirm
run_safari
log "Done"
