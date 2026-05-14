---
name: ddg-sentry-report-no-asana
description: Invoke ONLY when the user explicitly runs `/ddg-sentry-report-no-asana` or names this skill by name (e.g. "use ddg-sentry-report-no-asana analyze for macOS 1.186"). Do NOT auto-invoke from symptom/intent matching. The skill orchestrates three modes (`analyze`, `rca`, `summary`) and exchanges JSON files with external Asana scripts run by the user between modes — it NEVER calls Asana MCP itself. If the user asks about Sentry triage without naming this skill or one of its modes, answer directly. Inputs: a mode keyword plus mode-specific args (analyze: --platform + --version; rca: --input; summary: --augmented + --tasks).
---

# ddg-sentry-report-no-asana

## Overview

Produces a structured Sentry crash triage report for a DuckDuckGo Apple release, split into three modes that emit JSON files between them. External scripts (run by the user outside Claude Code) consume those JSON files to read from and write to Asana. The skill itself **never calls Asana MCP** — no lookups, no creates, no updates — so the lethal-trifecta lock is not engaged at any point and the workflow can use Bash, WebFetch, and git operations freely throughout.

Triage quality matches the parent skill `ddg-sentry-report`: severity tiers (HIGH / MEDIUM / LOW / Pre-existing), cluster-grouping by culprit symbol, ≥3-first-party-frames RCA gating, initials + PR-links attribution. What's different is *who* talks to Asana: scripts #1, #2, and #3 do, the skill does not.

## Trifecta posture

This skill is trifecta-neutral. It never invokes Asana / Microsoft 365 / Slack MCPs. Only Sentry MCP tools are loaded. Bash, WebFetch, git, and subagent dispatch remain unrestricted across all three modes. Do not load Asana tools via ToolSearch — there is no mode in which this skill writes to Asana.

## Supporting files

- [`references/constants.md`](references/constants.md) — Sentry/Asana GIDs, slugs, project filters, release-string conventions. The Asana GIDs are pass-through data for the external scripts.
- [`references/json-schemas.md`](references/json-schemas.md) — full JSON shapes for the five handoff files (`analyze.json`, `analyze.augmented.json`, `rca.json`, `rca.created.json`, `summary.json`).
- [`references/external-scripts.md`](references/external-scripts.md) — contracts for the three external scripts (#1 Asana lookup, #2 task create/reopen/extend, #3 summary filer).
- [`references/common-mistakes-extended.md`](references/common-mistakes-extended.md) — overflow learnings beyond the inline table.
- [`templates/main-report.html`](templates/main-report.html), [`templates/crash-free.html`](templates/crash-free.html), [`templates/per-issue-tracking.html`](templates/per-issue-tracking.html) — `html_notes` bodies emitted in the JSON. Mirrored from the parent skill; keep in sync.
- [`examples.md`](examples.md) — end-to-end walkthrough.

## Cross-cutting: PII rules

The skill never writes to Asana directly, but the JSON it emits flows into Asana via scripts #2 and #3. Therefore the same PII rule applies to `html_notes` payloads: **initials + PR links only, never full names.** The DDG asana-exfiltration hook will block scripts #2/#3 writes that contain full employee names, even when the user is OK with them. If even initials get blocked downstream, the user falls back to PR-number-only attribution by hand-editing the JSON before re-running the script. Applies to the main report **and** the per-issue tracking-task bodies.

## Cross-cutting: Reporting tone

- **Anchor every finding and recommendation to `<TIME_RANGE>`.** The analysis only sees Sentry events whose latest occurrence falls inside the resolved window. Phrase positive findings as "No new regressions in the last `<TIME_RANGE>`" rather than "No new regressions in {version}"; the unscoped form reads as a release-wide claim that this report does not support.
- **Never write a release-readiness verdict.** No "ship it", "proceed with confidence", "release looks healthy". The skill produces a windowed Sentry summary, not a sign-off. If nothing actionable came up, say so directly ("No action items surfaced in the last `<TIME_RANGE>` window; continue monitoring as the release rolls out") and stop.
- **Don't invent skip rationales.** The Recommended-next-step block is not the place to retroactively justify omissions. If a cluster was skipped, the legitimate reason belongs in the per-cluster line.

## Mode dispatch

Slash form: `/ddg-sentry-report-no-asana <mode> <args>`.

| Mode | Required args | Optional args |
|---|---|---|
| `analyze` | `--platform <ios\|macos>`, `--version <X.Y\|X.Y.Z\|X.Y.*>` | `--time-range <24h\|72h\|7d\|...>`, `--output <path>` |
| `rca` | `--input <augmented.json>` | `--output <path>`, `--max-parallel <N>` (default 8) |
| `summary` | `--augmented <file>`, `--tasks <file>` | `--output <path>` |

**Missing-arg behaviour.** Stop and ask. Never auto-resolve. Never default `--platform` or `--version`. Never silently treat an unknown mode keyword as `analyze`. The skill's mode keyword is mandatory; if missing, ask which mode and list the three options.

**Bad-arg combinations.** Refuse with a clear error rather than silently ignoring. `analyze --input` → refuse. `rca --platform` → refuse. `summary` without both `--augmented` and `--tasks` → ask.

**Default file location.** If `--output` is omitted, write to `${CLAUDE_JOB_DIR:-/tmp/ddg-sentry-report-no-asana}/<platform>-<version>/<file>`. `mkdir -p` the directory at the start of every mode. Print the absolute output path at the end of every mode along with a one-line `next step:` hint naming the external script.

## Mode `analyze`

### a.0 Load MCP tools (via ToolSearch)

- Sentry: `mcp__sentry__find_projects`, `mcp__sentry__find_releases`, `mcp__sentry__list_issues`, `mcp__sentry__get_sentry_resource`

Do NOT load Asana tools. The mode emits JSON for script #1 to consume; it never queries Asana itself.

### a.1 Resolve `<TIME_RANGE>`

If the user supplied `--time-range`, use it verbatim (validate it's a Sentry-style relative duration: `<integer><h|d|w>`). If omitted, run `date +%u` via Bash to get today's weekday number; `1` (Monday) → default to `72h`, anything else (`2`–`7`) → default to `24h`. Hold the resolved value as `<TIME_RANGE>`. The time range never affects the crash-free check (a.2).

**Use `date` via Bash, not the conversation-context date.** Sessions cross day boundaries and users run from various time zones. Same applies to `date +%A` for `weekday`.

### a.2 Resolve releases + version filter (with crash-free short-circuit)

Call `find_releases(query="<version_display>")` (e.g. `1.186`) to enumerate all release strings matching the series — needed for `firstRelease:` in a.3. Keep **all** of them (main app + extensions; do not filter to a single prefix). For event matching, build the `app_version` filter from the user-supplied `--version`: a series like `1.186` or `1.186.*` becomes `app_version:1.186.*`, an exact version like `1.186.0` stays `app_version:1.186.0`.

**Match the user-supplied version literally.** Never substitute a different version. If you suspect a typo, ask the user; do not silently retarget.

**Crash-free short-circuit.** If `find_releases` returns no releases **and** a confirmation `list_issues(query="is:unresolved app_version:<version_filter>", sort="freq", limit=1)` returns zero issues, the version is a crash-free release. **Do not add `lastSeen:-<TIME_RANGE>` to this query** — the short-circuit asks "does this version have any Sentry data ever?", not "any data in the last X hours". Render `templates/crash-free.html` with `{version}` / `{platform}` / `{version_filter}` substitutions, store as `crash_free_html_notes`, set `crash_free: true` and `clusters: []`, populate `summary_name`, write `analyze.json`, and **STOP** — do not run a.3–a.7. Tell the user: "Crash-free release detected; skip Modes `rca` and `summary`. Run external script #3 directly on `analyze.json`."

### a.3 Two Sentry queries, sorted by `freq`

Both scoped to `<TIME_RANGE>`:

- All unresolved in the series: `is:unresolved app_version:1.186.* lastSeen:-<TIME_RANGE>` (wildcard) or `is:unresolved app_version:1.186.0 lastSeen:-<TIME_RANGE>` (exact) — limit 30+.
- New-in-series only: `is:unresolved firstRelease:[<all releases from a.2>] lastSeen:-<TIME_RANGE>` — limit 50+ (iOS routinely hits 60–70 new issues). Include extension releases or extension regressions will be missed.

Pass values **unquoted**. `app_version:"1.186.*"` and `lastSeen:"-24h"` both break matching. `list_issues` has no separate `statsPeriod` parameter — the time filter must live inside `query`.

### a.4 Classify severity

Use both user count and new-vs-pre-existing:

- 🔴 **HIGH:** new-in-version AND a visible cluster (≥3 issues in same subsystem) OR new-in-version with ≥10 users
- 🟡 **MEDIUM:** new-in-version, single Sentry issue (not a multi-issue cluster), <10 users, app-code culprit (regardless of event count — but see 1-event carve-out below)
- 🟢 **LOW:** new-in-version but OS-level, Swift-runtime internals, Jetsam OOM on `main`, or symbol-less
- ⚠️ **Pre-existing:** still firing but not new — record by user count, do not attribute blame

**1-event carve-out for MEDIUM.** When a new-in-version cluster has exactly 1 event **total** (sum of Sentry's `count` across every short-ID in the cluster, all-time — NOT just within `<TIME_RANGE>`), set `is_one_event_carve_out: true` on that cluster. Mode `rca` reads this flag and omits the cluster from `rca.json.tasks`; mode `summary` renders the cluster as a terse main-report line (Sentry short-ID + link + minimal stats + culprit — no `Tracking` link, no PR attribution, no description). A cluster with 1 event in `<TIME_RANGE>` but multiple historical events is a recurring crash and does NOT qualify.

**Low user count alone is NOT a skip reason.** A MEDIUM with 1 user but ≥2 events still gets a tracking task and RCA. The carve-out is keyed on `events_alltime_sum == 1`, not user count, not "low-volume". Do not generalise.

### a.5 Cluster by culprit symbol

Group new issues by culprit symbol. Multiple short-IDs with the same culprit (e.g. four SIGABRTs in `TabViewCell.updatePreviewToDisplay`) become **one** cluster whose `short_ids` array lists all sibling short-IDs. Different culprits → different clusters even if they share a root cause. Different exception types with meaningfully different call chains can also get separate clusters (e.g. `_ArrayBuffer._consumeAndCreateNew` SIGABRT vs `WKUserScript.init` bmalloc SIGTRAP — both OOM but distinct allocation sites).

### a.6 Compute `cluster_id`, RCA eligibility, suspect hint, description hint

Per cluster:

- **`cluster_id`:** deterministic — `<severity>-<sha1(culprit + sorted_short_ids)[:8]>`. Lets the user re-run any mode without breaking references in already-emitted files.
- **`rca_eligible`:** `true` iff the stacktrace contains ≥3 first-party (DuckDuckGo) frames AND severity is HIGH or MEDIUM (regardless of where the leaf is). Set `false` for LOW / Pre-existing / generic-culprit / no-first-party-frames / Jetsam OOM clusters; set `rca_skip_reason` accordingly (`"generic_culprit"` | `"no_first_party_frames"` | `"jetsam_oom"` | `"severity_below_medium"`).
- **`suspect.file` / `suspect.line` / `suspect.symbol`:** populated when culprit symbol is greppable to a single file/line. Used by `rca` mode's git blame. `null` for generic / OS-only culprits.
- **`description_hint`:** one sentence for the main-report line in `summary` mode.

The 1-event-carve-out clusters get `rca_eligible: false` and `rca_skip_reason: "one_event_carve_out"` (a sixth skip reason in this mode's vocabulary — `rca` mode treats this identically to other skip reasons: omit from `tasks`).

### a.7 URL rewriting (for the JSON sentry_links)

Every `https://ddg.sentry.io/issues/<SHORT_ID>` becomes `https://errors.duckduckgo.com/organizations/ddg/issues/<SHORT_ID>/?project=<PROJECT_FILTER>`. Query links use `/organizations/ddg/issues/?project=<PROJECT_FILTER>&query=...&statsPeriod=<TIME_RANGE>`. Single-issue URLs remain unfiltered (no `statsPeriod`).

### a.8 Write `analyze.json`

Render the full structure per [`references/json-schemas.md`](references/json-schemas.md). All clusters present (HIGH / MEDIUM / LOW / Pre-existing). Each cluster's `existing_asana_task` is `null` — script #1 fills those in.

Print to the user:
- Resolved `<TIME_RANGE>` and weekday.
- Total counts (unresolved, new-in-version).
- Cluster summary by severity.
- Absolute path to `analyze.json`.
- `next step: run external script #1 with --input <analyze.json> to produce <analyze.augmented.json>`.

## Mode `rca`

### r.0 Load MCP tools

- Sentry: `mcp__sentry__get_sentry_resource` (for stacktrace fetches inside subagents).

No Asana tools, ever.

### r.1 Read and validate input

Load `--input` (default: `${CLAUDE_JOB_DIR:-/tmp/ddg-sentry-report-no-asana}/<platform>-<version>/analyze.augmented.json`). Validate `schema_version == 1`. Refuse if any cluster is missing the `existing_asana_task` field (script #1 didn't run, or wrote a malformed file) — surface the missing `cluster_id`s in the refusal message.

### r.2 Decide per-cluster mode

For each cluster, decide the action using the decision matrix in [`references/json-schemas.md`](references/json-schemas.md):

| `existing_asana_task` | `status` | `fix_version_compare` | `needs_short_id_extension` | Decision |
|---|---|---|---|---|
| `null` | — | — | — | `create` (when severity is HIGH/MEDIUM and `is_one_event_carve_out: false`) |
| present | `open` | — | empty | skip (cluster gets a tracking link in `summary`, no Asana write) |
| present | `open` | — | non-empty | `extend_short_ids` |
| present | `completed` | `gt` | — | skip ("Fix already shipped" bucket in `summary`) |
| present | `completed` | `lte` or `none` | — | `reopen_append` |

When `is_duplicate_link` is set on `existing_asana_task`, apply the matrix to the parent task (script #1 reports the parent's fields directly in `existing_asana_task` when it recursed — the `is_duplicate_link` flag is informational for traceability).

Clusters with `is_one_event_carve_out: true` or `rca_eligible: false` are always **skipped** from `rca.json.tasks` regardless of the matrix. They still feed the main report in `summary` mode via the augmented JSON's permalinks (when one exists).

### r.3 Git blame for `create` and `reopen_append` clusters

Per cluster with `mode in {create, reopen_append}` AND `suspect != null`:

- `grep` the suspect symbol to confirm file + line (skip if `suspect.file/line` already populated).
- `git blame -L <line-range>` on that region.
- `git log -n 5 --since=<~2 months ago>` on the file for recent PRs.
- Capture PR numbers from commit subjects (GitHub auto-appends `(#NNNN)`).
- If the symbol is too generic — skip attribution (record as PR-number-only or no attribution).

### r.4 Root-cause analysis (subagents, in parallel)

For each cluster with `mode in {create, reopen_append}` AND `rca_eligible: true`:

- Dispatch one **general-purpose** subagent **in parallel** (single message, multiple `Agent` tool calls). Cap at `--max-parallel` (default 8).
- Brief each subagent with: short-ID, exception class + message, full stacktrace from `get_sentry_resource`, suspect PR(s) from r.3, and a concrete instruction to (a) trace the call chain backward to its origin in this repo, (b) identify the invariant being violated *or* explicitly rule out an app-code root cause if evidence points elsewhere, (c) return a short structured report (root-cause summary, numbered call chain 4–8 steps, likely category, optional fix sketch). Cap responses at ~250 words.

A "concluded not actionable, here's why" finding is a valid result. An empty Root Cause Analysis section is not — if the subagent returned nothing useful, write the cluster's `html_notes` with the legitimate-skip explanation instead of an empty section.

### r.5 Render `html_notes` per cluster

Use `templates/per-issue-tracking.html` as the body shape. Populate:
- The `<SHORT_ID>` / `<PROJECT_FILTER>` in the leading Sentry link (use the cluster's first short-ID; the custom field carries the rest).
- The `Likely caused by` line with the PR link from r.3, or omit the line entirely if no confident PR attribution.
- The `<h2>Root Cause Analysis</h2>` / `<h2>Call chain</h2>` / `<h2>Likely category</h2>` / `<h2>Fix sketch</h2>` sections from the subagent's output. The analysis section is compacted (no newlines between tags) per `asana-rich-text` rules; the leading content has intentional newlines around the `<a>` block.

For `reopen_append` mode, render an `append_only_html_notes` segment shaped as `<body><hr/><h2>Regression seen in <version_display></h2>...</body>` containing the fresh RCA. Script #2 merges this into the existing task's body.

For `extend_short_ids` mode, `html_notes` is `null` (no body write). Populate `existing_custom_field_value` with the augmented JSON's `merged_short_ids` (joined on `,`) and `custom_field_value` with the full new value (`merged_short_ids` + cluster's `short_ids`, deduped, joined on `,`).

### r.6 Write `rca.json`

Per [`references/json-schemas.md`](references/json-schemas.md). Print:
- Per-mode cluster count (`create`, `reopen_append`, `extend_short_ids`, skipped).
- Absolute path to `rca.json`.
- `next step: run external script #2 with --input <rca.json> to produce <rca.created.json>`.

## Mode `summary`

### s.0 Load MCP tools

None required. The mode only renders HTML and writes JSON.

### s.1 Read inputs

- `--augmented`: the file script #1 wrote (default `…/<platform>-<version>/analyze.augmented.json`).
- `--tasks`: the file script #2 wrote (default `…/<platform>-<version>/rca.created.json`).

Validate `schema_version == 1` on both. Build a per-cluster permalink map merging:
- Pre-existing Asana tasks: `cluster_id → existing_asana_task.url` from the augmented JSON.
- Newly created Asana tasks: `cluster_id → results[].permalink_url` from `rca.created.json`.

When `rca.created.json.results[i].error != null`, record the error against the cluster — it surfaces in the "Recommended next step" block.

### s.2 Render the main report

Use `templates/main-report.html` as the body shape. Sections:

1. Header: platform + version + review date + scope ("unresolved issues with events in DuckDuckGo@1.186.x whose latest event falls within the last `<TIME_RANGE>`").
2. Totals: from `analyze.augmented.json.totals`.
3. Full-list links: from `analyze.augmented.json.sentry_links`.
4. Legend (verbatim from template).
5. 🔴 HIGH section.
6. 🟡 MEDIUM section (main).
7. 🟡 MEDIUM "Fix already shipped in vX.Y.Z" subsection — clusters with `existing_asana_task.fix_version_compare: "gt"`.
8. 🟢 LOW section.
9. ⚠️ Pre-existing section.
10. Recommended next step.
11. Initials legend.

**Lead with tracking.** Each HIGH/MEDIUM line leads with the tracking-task link from the permalink map, then Sentry short-ID(s), then stats (users + events), then `description_hint`. LOW, Pre-existing, and 1-event-carve-out MEDIUM entries lead with the Sentry short-ID (no tracking link). 1-event MEDIUM entries are intentionally terse — short-ID + link + minimal stats (`1 user, 1 event`) + `<code>culprit</code>`, no PR attribution and no description.

The "Recommended next step" block is governed by the **Reporting tone** section above — anchor every claim to `<TIME_RANGE>`; no release-readiness verdicts. Link each action item to its tracking-task permalink. If `rca.created.json` reports any per-cluster `error`, surface them inline ("Tracking-task create failed for `<short_id>` — investigate the script #2 error before re-running.").

### s.3 Write `summary.json`

Per [`references/json-schemas.md`](references/json-schemas.md). Print:
- Counts by section.
- Absolute path to `summary.json`.
- `next step: run external script #3 with --input <summary.json> to file the subtask under today's <Weekday> status subtask`.

## Quick reference

- **Subtask name format:** `Sentry summary - <platform> <version> - <YYYY-MM-DD>` (e.g. `Sentry summary - macOS 1.186 - 2026-04-30`). Populated as `analyze.json.summary_name` and `summary.json.name`.
- **`html_notes` rules:** wrap in `<body>...</body>`. Use `<a href="...">` for plain links (not @-mentions). `<strong>`, `<em>`, `<code>`, `<hr>` supported. See the `asana-rich-text` skill for full syntax.
- **`cluster_id`:** `<severity>-<sha1(culprit + sorted_short_ids)[:8]>`. Deterministic across re-runs.
- **Default output directory:** `${CLAUDE_JOB_DIR:-/tmp/ddg-sentry-report-no-asana}/<platform>-<version>/`. `mkdir -p` at the start of every mode.
- **Crash-free path:** Mode `analyze` emits `analyze.json` with `crash_free: true` and `crash_free_html_notes` populated; user runs script #3 directly on that file, skipping `rca` and `summary`.

## Common mistakes

Top-bite rows. See [`references/common-mistakes-extended.md`](references/common-mistakes-extended.md) for the long tail.

### Boundary

| Mistake | Fix |
|---|---|
| Calling an Asana MCP tool from any mode of this skill | The skill is trifecta-neutral by design. Asana writes happen in external scripts #2 / #3, never here. If the user asks mid-run to "also create the Asana task", refuse — emit the JSON file the script consumes instead. |
| Loading Asana tools via ToolSearch "just in case" | Don't. No mode of this skill writes to Asana. Loading the tools doesn't trigger the trifecta lock, but it tempts the next prompt into calling them. |
| Defaulting `--platform` or `--version` when the user omits them | Stop and ask. Never auto-resolve. The parent skill resolves versions from Asana; this skill is the no-Asana variant and has no fallback. |

### Sentry queries

| Mistake | Fix |
|---|---|
| Passing `regionUrl=https://errors.duckduckgo.com` to Sentry MCP | Omit `regionUrl`. MCP only allows `sentry.io` hosts; it returns `ddg.sentry.io` URLs you rewrite client-side. |
| Quoting the `app_version` or `lastSeen` value (e.g. `app_version:"1.186.*"`, `lastSeen:"-24h"`) | Breaks matching. Pass values unquoted. |
| Forgetting the time-range filter on a.3 queries | Both `list_issues` calls in a.3 must include `lastSeen:-<TIME_RANGE>`. Without it, the queries return all-time data and the report becomes a mixed history dump. |
| Applying the time-range filter to the a.2 crash-free check | The crash-free short-circuit is a global "is there any data ever" question. Adding `lastSeen:` causes false crash-free readings when a version has events outside the window. |
| Hard-coding `&statsPeriod=7d` in URLs | Use the resolved `<TIME_RANGE>` value in `sentry_links` URLs so the linked Sentry view matches what the report analyzed. Single-issue URLs stay unfiltered. |

### Cluster + JSON output

| Mistake | Fix |
|---|---|
| Emitting a cluster per short-ID instead of grouping by culprit | Group new issues by culprit symbol before writing `analyze.json`. Sibling short-IDs become a single cluster with all IDs in `short_ids`. |
| Producing non-deterministic `cluster_id`s between runs | Use `<severity>-<sha1(culprit + sorted_short_ids)[:8]>`. Lets the user manually edit augmented JSON and replay. |
| Creating an `rca.json` task for a cluster with `existing_asana_task.status: "open"` and empty `needs_short_id_extension` | Skip it. Open tasks with full short-ID coverage need nothing from script #2 — they contribute only a permalink to the main report. |
| Including LOW / Pre-existing clusters in `rca.json.tasks` | Don't. Only HIGH and MEDIUM clusters (with `existing_asana_task: null` or `reopen_append` / `extend_short_ids` conditions) appear in `tasks`. |
| Emitting an empty `html_notes` because the subagent returned nothing useful | If the legitimate skip rules don't apply, the subagent must produce a "concluded not actionable, here's why" RCA. Empty body is not a valid output. |

### Severity / classification

| Mistake | Fix |
|---|---|
| Setting `is_one_event_carve_out: true` for a cluster with 1 event in `<TIME_RANGE>` but multiple historical events | The gate is keyed on **total** event count (`events_alltime_sum`), not windowed count. Recurring crashes resurfacing in the last 24h are full MEDIUM, not carve-out. |
| Substituting a different version when the requested one returns no events | Take the a.2 crash-free short-circuit and stop. The user-supplied version is authoritative. |
| Writing full employee names into `html_notes` | Hook will block at script #2 / #3 time. Use initials + PR links. Fallback: PR-number-only. |

### Reporting tone

| Mistake | Fix |
|---|---|
| Overstating coverage in the report's headlines or "Recommended next step" | Anchor every finding to `<TIME_RANGE>`: "No new regressions in the last 24h", not "Zero new regressions in {version}". Never write "ship it / proceed with confidence / release looks healthy" — those are sign-off statements, not summaries. |

## Examples

See [`examples.md`](examples.md) for an end-to-end walkthrough.
