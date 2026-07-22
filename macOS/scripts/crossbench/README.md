# macOS crossbench perf-runner harness

Scripts that turn a macOS box into a [crossbench](https://github.com/google/crossbench)
page-load / LCP perf runner for Chrome (the baseline browser for comparison
against the DDG macOS browser). This is the macOS counterpart of the
windows-browser `Scripts/runCrossbench.ps1` pipeline, and — like the Windows
one — it is **versioned in-repo**, not edited on the runner. The runner is a
checkout of this directory; `git pull` updates the harness.

## Layout

| Path | Purpose |
|------|---------|
| `commission-macos.sh` | One-time, human/sudo setup of a fresh box (CLT, Homebrew). |
| `commission-safari.sh` | One-time, human/GUI setup for the Safari path: trusts the WPR ECDSA root in the System keychain + enables safaridriver. Run once from the VM's GUI Terminal. |
| `provision-macos.sh` | Per-job, passwordless provisioning (brew formulae, Chrome, wpr build, poetry deps) + pins crossbench to a known revision + self-heals the crossbench extras & patch below. |
| `test-chrome.sh` | Runs the Chrome LCP suite over the top-sites list against recorded network (WPR) and summarises per-site LCP. |
| `test-ddg.sh` | Runs the same LCP suite for the DuckDuckGo macOS (WebKit) browser: drives it via its AutomationServer through a SOCKS5 proxy (tsproxy) in front of WPR, and summarises per-site LCP. |
| `test-safari.sh` | Runs the same LCP suite for **Safari** (WebKit): points Safari at WPR via a per-app proxy (its own `com.apple.Safari` prefs domain) in front of `httpproxy.py`, drives it via safaridriver (W3C WebDriver), summarises per-site LCP. Needs no per-run sudo. |
| `ddg-automation.py` | Minimal client for the DDG AutomationServer (navigate / execute / buffered-LCP probe) that `test-ddg.sh` drives. |
| `safari-automation.py` | Minimal stdlib W3C WebDriver client (new-session / navigate / async buffered-LCP probe) that `test-safari.sh` drives against safaridriver. |
| `httpproxy.py` | Tiny local HTTP forward proxy (CONNECT → WPR-https, absolute-form GET → WPR-http) that `test-safari.sh` points Safari at, replacing the SOCKS `tsproxy` for the Safari path. |
| `crossbench-extras/` | Fork-only crossbench files the LCP run needs but a plain clone doesn't ship. Mirrors crossbench-relative paths so provisioning copies them in place. |
| `patches/cpu_freq-attributeerror.patch` | Reference patch for the `crossbench/plt/macos.py` cpu_freq fix (applied idempotently by provision). |

### crossbench revision pin

`CROSSBENCH_DIR` is a checkout of upstream crossbench, and `provision-macos.sh`
force-checks it out to a pinned commit (`CROSSBENCH_REV` in the script) on
every run, rather than letting it drift to whatever the clone happens to be
on. Tip-of-tree crossbench is fragile: upstream can rename or refactor code
that the extras/patch below target, breaking provisioning with no warning.

The pin anchors to the `crossbench_revision` that Chromium's **current
stable** release branch vendors in its `DEPS` file — the closest thing to a
"known-good, shipped-through-a-release" revision. Chrome M150 stable
(`chromium refs/branch-heads/7871`) pins crossbench at
`7d52b4ffbc319a7d5a0e0a0ebff744e5281d60c5` (~Jun 1 2026). `WEBPAGEREPLAY_REV`
(same file) is read from the same DEPS pin, so the two stay coherent.

**Actually pinned commit is newer than that DEPS SHA**: the literal DEPS
rev predates `--bin-override` (added 16 days later, crossbench commit
`be14dbfb884747ea577e2e65b6a4a77d7ecd807d`, "Add --binary-override flag for
tool paths", Jun 17 2026), which `test-chrome.sh` needs to hand crossbench
the pre-built `wpr` binary without going through crossbench's own
hermetic-Go-toolchain build (which needs a `gclient sync` this harness never
runs). `CROSSBENCH_REV` is pinned to that commit instead — the oldest
post-DEPS commit that adds the flag — rather than the exact DEPS SHA.

To bump: pick a newer stable branch-head number from
[chromiumdash](https://chromiumdash.appspot.com/branches), read its `DEPS`
file (`https://chromium.googlesource.com/chromium/src/+/refs/branch-heads/<N>/DEPS`),
and check whether its `crossbench_revision` already postdates
`--bin-override` (a later Chrome stable may not need this workaround at
all). Copy the new `crossbench_revision` (and `webpagereplay_revision`)
values into `CROSSBENCH_REV` / `WEBPAGEREPLAY_REV`. Re-run provisioning and
re-verify the extras + cpu_freq patch still apply cleanly (grep-guarded, so
a WARNING means the target text changed upstream and the patch needs
reconciling), and that `test-chrome.sh` still runs (in case of another
similar gap between the DEPS SHA and a flag/behavior the harness relies on).

### The crossbench extras (load-bearing)

A plain `git clone` of crossbench does **not** provide these, and without them
the LCP run silently returns no rows / `-1`:

- `config/probe/perfetto/navToLCP.config.hjson` — the Perfetto probe config that
  defines the `lcp` metric from `PageLoadMetrics.NavigationToLargestContentfulPaint`.
- `crossbench/probes/trace_processor/modules/ext/largestcontentfulpaint.sql` —
  the trace_processor SQL module the metric references.
- `crossbench/plt/macos.py` cpu_freq patch — psutil 7.2.1 on Apple Silicon
  raises `AttributeError` from `cpu_freq()`, which stock crossbench doesn't catch;
  the patch adds it to the caught tuple.

`provision-macos.sh` installs all three into `CROSSBENCH_DIR` on every run
(idempotently), so a fresh or re-pulled crossbench clone can never lose them.

## The commission / provision / test split

1. **commission** (once, by a human, needs sudo): installs Xcode Command Line
   Tools and Homebrew. Run `./commission-macos.sh`. This is the only step that
   prompts for a password. For the **Safari** path, also run `./commission-safari.sh`
   once from the VM's GUI Terminal (trusts the WPR ECDSA cert + enables safaridriver;
   GUI-only, can't be done over SSH).
2. **provision** (every job, no password): `CROSSBENCH_DIR=... ./provision-macos.sh`
   installs python@3.11 + poetry, Google Chrome, screenresolution, the Go
   toolchain, builds the pinned `wpr` binary, pins the crossbench checkout to
   `CROSSBENCH_REV`, self-heals the crossbench extras + patch, and runs
   `poetry install`. Idempotent.
3. **test** (every job): `./test-chrome.sh [--reps N] [--sites a.com,b.com]`.
   Fetches WPR archives, runs crossbench per site with `--bin-override wpr=...`,
   and prints `lcp_ms=[...] mean=... n=...` per site.

## How the runner (VM) consumes this

The runner clones **only this branch/path** of apple-browsers into a dedicated
directory and runs the scripts from there — it is a checkout, not the source of
truth. Nobody edits the scripts on the runner anymore; `git pull` updates them.

Things that stay on the runner (data / binaries / clones, not harness source):

- `~/Developer/crossbench-upstream` — the crossbench checkout (`CROSSBENCH_DIR`).
  Upstream is canonical because the DDG fork's page-load flow uses Windows-only
  keyboard actions that crash on macOS.
- `~/Developer/mac-perf-runner/bin/wpr` — the built wpr binary (`WPR_BIN`).
- `~/Developer/mac-perf-runner/wpr-archives` — downloaded WPR archives (`WPR_DIR`).

All three are env-overridable defaults in the scripts, so the git-sourced copy
runs unchanged against the runner's existing data locations.

## Notes / known gaps

- No traffic shaping: crossbench shapes via `third_party/tsproxy`, whose
  DEPS-pinned `tsproxy.py` is Python-2-only and silently drops connections under
  Python 3. WPR therefore replays at loopback speed — deterministic, but faster
  than the Windows US-broadband-shaped runs. Don't compare absolute values.
- ClickHouse upload is stubbed (`upload_results`) — out of scope for now.

## How DDG is measured (`test-ddg.sh`)

DDG is WebKit/WKWebView: no Perfetto trace, and no `--host-resolver-rules`
equivalent to point it at WPR. So `test-ddg.sh` differs from the Chrome path:

- **Routing.** A standalone `tsproxy` runs as a SOCKS5 proxy that redirects
  every destination to loopback WPR and remaps `443`→WPR-https / `80`→WPR-http.
  The browser is pointed at it with two **Debug/Review-gated** launch options
  (`LaunchOptionsHandler`): `webViewProxy=host:port` and `acceptInsecureCerts=true`
  (WPR serves a self-signed cert). Neither option does anything on production
  builds. This is *not* crossbench's DEPS-pinned tsproxy (Python-2-only) — it's a
  current copy fetched from catapult, run under the system `python3`.
- **Driving.** The browser is driven directly through its AutomationServer
  (Debug/Review HTTP server on `[::1]:PORT`) via `ddg-automation.py` — not
  crossbench. LCP is read with a buffered `PerformanceObserver` (WebKit only
  reports LCP to a live observer).
- **Validity guards.** Each rep starts cold (the app's container cache is cleared
  and the app relaunched), and a rep is dropped unless the proxy actually saw
  traffic — so a silent live-network fallback can't masquerade as a result.
- **No shaping**, same as Chrome — compare DDG-vs-Chrome on the same runner, not
  DDG-vs-Windows.
- Shared with Chrome (data, not code): the wpr binary, WPR archives, `WPR_BASE_URL`,
  and the site list. A `common.sh` extraction is the intended next cleanup.

## How Safari is measured (`test-safari.sh`)

Safari is also WebKit, but unlike DDG it's Apple's app — we can't set a per-instance
proxy or cert knob from our code, and safaridriver ignores the WebDriver `proxy`
capability. But Safari reads a proxy from its **own prefs domain**, which is per-app
and needs no root:

- **Routing.** The script writes `WebKit2HTTPProxy` / `WebKit2HTTPSProxy` on
  `com.apple.Safari` (via `defaults write`) pointing Safari at a tiny local HTTP
  forward proxy, `httpproxy.py` (CONNECT → WPR-https, absolute-form GET → WPR-http).
  Only Safari is affected — no machine-wide proxy. An `EXIT` trap always removes the
  two defaults on exit (including error / Ctrl-C).
- **Why not the system SOCKS proxy.** A machine-wide `networksetup` SOCKS proxy
  (what an earlier version used) needs root AND — proven on this VM — drops the
  inbound SSH connection on the first proxied navigation, making unattended
  SSH-driven runs impossible. The per-app proxy leaves SSH and the rest of the box
  untouched.
- **Cert / TLS.** WPR serves the **ECDSA (P-256) root only**, with
  `--no-archive-certificates` (fresh leaves minted at replay time). Its bundled RSA
  root is **1024-bit**, which Apple's TLS rejects outright ("illegal parameter"
  handshake failure). The ECDSA root must be trusted **once** in the System keychain
  — a GUI-only step (headless SSH trust is impossible on macOS 26), done by
  `commission-safari.sh`.
- **Driving.** Safari is driven via **safaridriver** (`safaridriver -p PORT`, W3C
  WebDriver) by `safari-automation.py`. LCP is read with the same buffered
  `PerformanceObserver`, delivered through WebDriver's async-script channel.
- **No per-run sudo.** The only privileged setup — trust the ECDSA cert, `safaridriver
  --enable`, and tick Safari > Develop > **Allow Remote Automation** — is one-time,
  via `commission-safari.sh`. The test itself needs no sudo, so it runs unattended
  over plain SSH.
- **Validity guard.** Like DDG, a rep is dropped unless the proxy actually saw
  traffic, so a live-network fallback can't masquerade as a result.
- **No shaping**; compare Safari-vs-DDG-vs-Chrome on the same runner.
