#!/usr/bin/env bash
#
# test-chrome.sh — run the crossbench page-load / LCP test for Chrome (baseline).
#
# macOS counterpart to the RUN half of windows-browser's runCrossbench.ps1
# -action run, for the Chrome comparison baseline. Stock crossbench drives Chrome
# and extracts LCP from a Perfetto trace (the Chromium event
# PageLoadMetrics.NavigationToLargestContentfulPaint) via the navToLCP probe
# config, over a fixed top-sites list against recorded network (Web Page Replay)
# for determinism, and summarises per-site results.
#
# DDG is measured by a SEPARATE script (test-ddg.sh, TBD): the macOS DDG browser
# is WebKit/WKWebView with no Perfetto trace — it emits LCP itself, a completely
# different mechanism. Shared helpers (site list, WPR fetch, output format) should
# move into a common.sh once test-ddg.sh exists.
#
# Prereqs: run provision-macos.sh first (installs poetry + crossbench deps).
#
# Usage:
#   ./test-chrome.sh [--reps N] [--sites a.com,b.com]
#
set -euo pipefail

# ---- config / args ---------------------------------------------------------
REPS="10"
SITES_OVERRIDE=""
# crossbench-upstream is canonical: the DDG fork's page-load flow uses
# Windows-only keyboard actions that crash on macOS. The fork-only files this
# run needs (config/probe/perfetto/navToLCP.config.hjson and
# crossbench/probes/trace_processor/modules/ext/largestcontentfulpaint.sql)
# are copied into the upstream clone as untracked files.
CROSSBENCH_DIR="${CROSSBENCH_DIR:-$HOME/Developer/crossbench-upstream}"
WPR_DIR="${WPR_DIR:-$HOME/Developer/mac-perf-runner/wpr-archives}"
# wpr binary built by provision-macos.sh; handed to crossbench via
# --bin-override so crossbench never runs its own webpagereplay build.
WPR_BIN="${WPR_BIN:-$HOME/Developer/mac-perf-runner/bin/wpr}"
PROBE_CONFIG="config/probe/perfetto/navToLCP.config.hjson"
SUITE="navToLCP"          # LCP focus; navToFCP exists in the ps1 as a sibling
LOAD_WINDOW="12s"         # matches runCrossbench.ps1 (--url=<site>,12s)
WPR_BASE_URL="https://staticcdn.duckduckgo.com/d5c04536-5379-4709-8d19-d13fdd456ff6/performance-tests"

while [ $# -gt 0 ]; do
  case "$1" in
    --reps)    REPS="$2"; shift 2 ;;
    --sites)   SITES_OVERRIDE="$2"; shift 2 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

log() { printf '\n=== %s ===\n' "$1"; }

# Site list, copied verbatim from runCrossbench.ps1 $navToSites.
# (imdb / merriam-webster / britannica intentionally omitted there.)
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

# ---- preflight -------------------------------------------------------------
preflight() {
  if ! command -v poetry >/dev/null 2>&1; then
    echo "ERROR: poetry not found. Run provision-macos.sh first." >&2
    exit 1
  fi
  if [ ! -f "$CROSSBENCH_DIR/cb.py" ]; then
    echo "ERROR: crossbench not found at $CROSSBENCH_DIR (cb.py missing)." >&2
    echo "Set CROSSBENCH_DIR or clone crossbench-upstream there." >&2
    exit 1
  fi
  if [ ! -x "$WPR_BIN" ]; then
    echo "ERROR: wpr binary not found at $WPR_BIN. Run provision-macos.sh first." >&2
    exit 1
  fi
}

# normalized story filename: 'navToLCP+youtube.com' -> 'navToLCP_youtube.com'
# ('+' -> '_', '/' -> '_'), matching Get-Normalized-Filename in the ps1.
normalize() { printf '%s' "$1" | tr '+/' '__'; }

# crossbench --network arg for a WPR archive. Notes:
# - No spaces: the arg is deliberately unquoted at the call site (so an empty
#   value vanishes); spaces inside it would word-split into broken args.
# - NO speed/traffic shaping: crossbench shapes via third_party/tsproxy, which
#   is Python-2-only at the DEPS-pinned revision — under our Python 3.11 venv
#   the SOCKS handshake dies in a bare `except: pass`, the browser is pointed
#   at a black-hole proxy, and nothing loads (verified with curl --socks5).
#   Without a shaper crossbench maps ports via --host-resolver-rules instead,
#   which works. WPR replays at loopback speed: deterministic, but faster than
#   Windows' US-broadband-shaped runs — don't compare absolute values to them.
wpr_network_arg() {
  printf -- '--network={type:"wpr",path:"%s"}' "$1"
}

# Fetch the WPR archive for a story and echo the crossbench --network arg for it,
# or echo nothing (live network) if the archive can't be fetched. Mirrors the
# download-or-fall-back-to-live logic in Invoke-Crossbench.
fetch_network_arg() {
  local story="$1" normalized archive
  normalized="$(normalize "$story")"
  archive="$WPR_DIR/$normalized.wprgo"
  mkdir -p "$WPR_DIR"
  if curl -fLSs -o "$archive.tmp" "$WPR_BASE_URL/$normalized.wprgo" 2>/dev/null; then
    mv "$archive.tmp" "$archive"
    wpr_network_arg "$archive"
  else
    rm -f "$archive.tmp"
    # No archive: reuse a previously downloaded one if present, else live.
    if [ -f "$archive" ]; then
      wpr_network_arg "$archive"
    else
      echo "WARNING: no WPR archive for $story; using LIVE network (results will be noisy)." >&2
      printf ''
    fi
  fi
}

# Parse a crossbench RESULTS dir: for every per-iteration v2_metrics.textproto,
# pull the first `double_value:` — the LCP metric, which trace_processor emits
# in NANOSECONDS — and convert to ms. An iteration whose LCP never finalized
# (missing --about-blank-duration) is emitted as `double_value: -1`; count
# those separately instead of parsing them as timings.
summarize_lcp() {
  local results_path="$1" site="$2"
  local -a vals=()
  local f v unfinalized=0
  while IFS= read -r f; do
    # `|| true`: under set -e/pipefail a no-match grep would abort the script.
    v="$(grep -Eo 'double_value: -?[0-9]+(\.[0-9]+)?' "$f" | head -1 | awk '{print $2}' || true)"
    [ -z "$v" ] && continue
    if awk -v v="$v" 'BEGIN{exit !(v < 0)}'; then
      unfinalized=$((unfinalized + 1))
      continue
    fi
    vals+=("$(awk -v ns="$v" 'BEGIN{printf "%.1f", ns / 1000000}')")  # ns -> ms
    # Only per-iteration files live under a trace_processor/ dir. crossbench also
    # writes story-level MERGED copies of v2_metrics.textproto (identical dupes),
    # which would inflate the iteration count n on multi-story / low-rep runs.
  done < <(find "$results_path" -path '*/trace_processor/v2_metrics.textproto' 2>/dev/null)

  if [ "$unfinalized" -gt 0 ]; then
    echo "  WARNING: $site: $unfinalized iteration(s) with unfinalized LCP (-1)." >&2
  fi
  if [ "${#vals[@]}" -eq 0 ]; then
    echo "  $site: NO LCP VALUES PARSED (check trace / 30s cap issue)"
    return
  fi
  printf '  %s: lcp_ms=[%s] ' "$site" "$(IFS=,; echo "${vals[*]}")"
  printf '%s\n' "${vals[@]}" | awk '{s+=$1; n++} END{printf "mean=%.1f n=%d\n", s/n, n}'
}

# ---- ClickHouse upload (OUT OF SCOPE — stub) ------------------------------
upload_results() {
  local results_path="$1" site="$2"
  # TODO: upload per-iteration LCP to ClickHouse for parity with the Windows
  # pipeline (testId "Crossbench.${SUITE}+${site}", browserType, commit, runId,
  # browser version). The Windows uploader is a C#/.NET project; decide whether
  # to reuse it cross-platform (dotnet runs on macOS) or replace with a small
  # uploader here. No-op for now.
  :
}

# ---- run -------------------------------------------------------------------
run_chrome() {
  log "Chrome LCP run — $SUITE, ${#SITES[@]} sites, $REPS reps, ${LOAD_WINDOW} window"
  cd "$CROSSBENCH_DIR"
  # .vpython3 is git-tracked and makes crossbench re-exec under Chromium vpython
  # instead of our poetry venv; removal belongs here (run step), not provisioning.
  rm -f .vpython3

  local site story network_arg out results_path
  for site in "${SITES[@]}"; do
    story="${SUITE}+${site}"
    log "site: $site"
    network_arg="$(fetch_network_arg "$story")"

    out="$(mktemp)"
    # --about-blank-duration is REQUIRED: navigating to about:blank after each
    # page forces Chromium to finalize LCP; without it every value comes out -1.
    # shellcheck disable=SC2086  # network_arg must word-split (empty => omitted)
    poetry run python ./cb.py \
      loading \
      --browser=chrome-stable \
      --probe-config="$PROBE_CONFIG" \
      --repetitions="$REPS" \
      --url="$site,$LOAD_WINDOW" \
      --about-blank-duration=2s \
      --bin-override "wpr=$WPR_BIN" \
      $network_arg \
      --debug \
      --env-validation=skip 2>&1 | tee "$out" || echo "WARN: crossbench exited non-zero for $site" >&2

    # `|| true`: under set -e/pipefail a no-match grep would abort the script.
    results_path="$(grep -E '^RESULTS: ' "$out" | tail -1 | sed -E 's/^RESULTS: //' || true)"
    if [ -n "$results_path" ] && [ -d "$results_path" ]; then
      summarize_lcp "$results_path" "$site"
      upload_results "$results_path" "$site"
    else
      echo "  $site: no RESULTS path in crossbench output"
    fi
    rm -f "$out"
  done
}

# ---- main ------------------------------------------------------------------
preflight
run_chrome
log "Done"
