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
| `provision-macos.sh` | Per-job, passwordless provisioning (brew formulae, Chrome, wpr build, poetry deps) + self-heals the crossbench extras & patch below. |
| `test-chrome.sh` | Runs the Chrome LCP suite over the top-sites list against recorded network (WPR) and summarises per-site LCP. |
| `crossbench-extras/` | Fork-only crossbench files the LCP run needs but a plain clone doesn't ship. Mirrors crossbench-relative paths so provisioning copies them in place. |
| `patches/cpu_freq-attributeerror.patch` | Reference patch for the `crossbench/plt/macos.py` cpu_freq fix (applied idempotently by provision). |

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
   prompts for a password.
2. **provision** (every job, no password): `CROSSBENCH_DIR=... ./provision-macos.sh`
   installs python@3.11 + poetry, Google Chrome, screenresolution, the Go
   toolchain, builds the pinned `wpr` binary, self-heals the crossbench extras +
   patch, and runs `poetry install`. Idempotent.
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
- DDG (WebKit/WKWebView) LCP uses a different mechanism and will get its own
  `test-ddg.sh`; shared helpers should move to a `common.sh` when it lands.
