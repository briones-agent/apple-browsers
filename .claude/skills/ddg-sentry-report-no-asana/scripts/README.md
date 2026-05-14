# External scripts for `ddg-sentry-report-no-asana`

Four Python 3 scripts that handle every Asana interaction for the skill. Each can be invoked from the command line OR imported as a module from an orchestrator (e.g. a wrapper around Claude Agent SDK that runs the skill modes in between).

## Install

```bash
python3 -m pip install -r requirements.txt
```

Only dependency: `requests`. Python 3.10+.

## Authentication

All three scripts require an Asana Personal Access Token in the `ASANA_ACCESS_TOKEN` environment variable:

```bash
export ASANA_ACCESS_TOKEN="2/..."
```

If unset, the scripts exit with a clear error message. There is no fallback — the orchestrator must pass the env var explicitly.

## Scripts

### `resolve_version` (script #0)

Resolves the version to analyse from `(platform, release-type)` via Asana — the parent `ddg-sentry-report` skill did this lookup inline; the no-Asana variant pushes it out so the agent loop stays Sentry-only.

```bash
python3 -m scripts.resolve_version --platform macos --release-type public
# → 1.186
```

Programmatic:

```python
from scripts.resolve_version import run
version = run(platform="macos", release_type="public")  # → "1.186"
```

Branches by `--release-type`:

- `public`: newest open `<platform> X.Y.Z is now public` task in Apple Deployments / Deployments (last 2 weeks), dropping tasks created within the last 12h (a brand-new release task may not have Sentry events yet).
- `internal`: newest open `<platform> App Release X.Y.Z` task in Apple Releases / `<platform>` section, `is_subtask=false`. On Monday UTC, drops the newest and takes the next-newest (internal code freeze creates a fresh task at 01:00 UTC every Monday).

Exits 2 with a stop-and-ask message when the filter is empty or Monday-UTC has only one candidate.

### `asana_lookup` (script #1)

Augments `analyze.json` with existing-task data from the `Sentry Crash Reports` project.

```bash
python3 -m scripts.asana_lookup \
  --input  /tmp/ddg-sentry-report-no-asana/macos-1.186/analyze.json \
  --output /tmp/ddg-sentry-report-no-asana/macos-1.186/analyze.augmented.json
```

Programmatic:

```python
from scripts.asana_lookup import run
run(input_path="...", output_path="...")
```

### `asana_write` (script #2)

Reads `rca.json` and performs the create / reopen+append / extend-short-ids operations on Asana.

```bash
python3 -m scripts.asana_write \
  --input  /tmp/ddg-sentry-report-no-asana/macos-1.186/rca.json \
  --output /tmp/ddg-sentry-report-no-asana/macos-1.186/rca.created.json
```

Per-task failures are captured in the output `results[].error` and never raise — the script always exits 0 unless a structural error (bad JSON, missing token, schema mismatch) occurs.

### `asana_file_summary` (script #3)

Reads `summary.json` (or `analyze.json` when `crash_free: true`) and files the new subtask under the platform's Weekly Release DRI today's `<Weekday> status` subtask.

```bash
python3 -m scripts.asana_file_summary \
  --input /tmp/ddg-sentry-report-no-asana/macos-1.186/summary.json
```

Stops with a non-zero exit if the DRI / status subtask can't be resolved unambiguously (asks the operator to pick).

## CLI flags shared across all three

| Flag | Default | Effect |
|---|---|---|
| `--input PATH` | — (required) | Input JSON file |
| `--output PATH` | derived from `--input` | Output JSON file (scripts #1 and #2 only) |
| `--dry-run` | off | Print planned operations; never call Asana |
| `--verbose` | off | DEBUG-level logging |

## Programmatic orchestration

Typical flow for a Python orchestrator driving Claude Agent SDK:

```python
from claude_agent_sdk import run_skill  # hypothetical
from scripts import asana_lookup, asana_write, asana_file_summary, resolve_version

version = resolve_version.run(platform="macos", release_type="public")  # e.g. "1.186"
job_dir = f"/tmp/ddg-sentry-report-no-asana/macos-{version}"

run_skill("ddg-sentry-report-no-asana", args=["analyze", "--platform", "macos",
                                              "--version", version,
                                              "--output", f"{job_dir}/analyze.json"])

asana_lookup.run(f"{job_dir}/analyze.json", f"{job_dir}/analyze.augmented.json")

run_skill("ddg-sentry-report-no-asana", args=["rca",
                                              "--input", f"{job_dir}/analyze.augmented.json",
                                              "--output", f"{job_dir}/rca.json"])

asana_write.run(f"{job_dir}/rca.json", f"{job_dir}/rca.created.json")

run_skill("ddg-sentry-report-no-asana", args=["summary",
                                              "--augmented", f"{job_dir}/analyze.augmented.json",
                                              "--tasks",     f"{job_dir}/rca.created.json",
                                              "--output",    f"{job_dir}/summary.json"])

asana_file_summary.run(f"{job_dir}/summary.json")
```

If `analyze.json` carries `crash_free: true`, the orchestrator skips the `rca` and `summary` runs and calls `asana_file_summary.run("…/analyze.json")` directly — that script understands both inputs.

## Tests

```bash
python3 -m unittest discover -s scripts/tests
```

Tests cover the pure decision logic (tag parsing, fix-version comparison, custom-field merge, [Duplicate] handling) without hitting the live Asana API.
