# Example invocation

One end-to-end walkthrough of `/ddg-sentry-report-no-asana`. Useful when picking up the workflow cold or sanity-checking a real run. The user is responsible for running scripts #1, #2, and #3 by hand between modes — they are external to the skill.

## macOS 1.186, weekday Thursday

> "Use ddg-sentry-report-no-asana analyze for macOS 1.186."

### Mode `analyze`

1. Parse args: `--platform macos --version 1.186`. No `--time-range` → resolve via Bash:
   ```
   date +%u   →  4   (Thursday)
   date +%A   →  Thursday
   ```
   `<TIME_RANGE>` defaults to `24h`.

2. `find_releases(query="1.186")` → `DuckDuckGo@1.186.0`, `DuckDuckGo@1.186.1`, `com.duckduckgo.macos.vpn.network-extension@1.186.0`, `com.duckduckgo.macos.vpn.network-extension@1.186.1`, ... (keep all).

3. `list_issues(query="is:unresolved app_version:1.186.* lastSeen:-24h", sort="freq", limit=30)` → 18 unresolved issues.

4. `list_issues(query="is:unresolved firstRelease:[DuckDuckGo@1.186.0,...] lastSeen:-24h", sort="freq", limit=50)` → 5 new-in-1.186.x.

5. Classify the 5 new issues → 1 HIGH cluster (2 sibling SIGABRTs in `TabBarViewController.tabCollectionViewModel`), 2 MEDIUM (one with 4 historical events, one 1-event-carve-out), 1 LOW (Jetsam OOM on `main`), 1 Pre-existing (already firing for two months).

6. Compute `cluster_id` per cluster, eligibility, suspect file/line.

7. Rewrite all `ddg.sentry.io` URLs to `errors.duckduckgo.com/organizations/ddg/issues/<SHORT_ID>/?project=6`.

8. Write `analyze.json` to `${CLAUDE_JOB_DIR:-/tmp/ddg-sentry-report-no-asana}/macos-1.186/analyze.json`.

Sample (truncated):

```json
{
  "schema_version": 1,
  "generated_at": "2026-05-14T10:31:00Z",
  "platform": "macos",
  "version": "1.186.*",
  "version_display": "1.186",
  "time_range": "24h",
  "weekday": "Thursday",
  "release_strings": ["DuckDuckGo@1.186.0", "DuckDuckGo@1.186.1", "com.duckduckgo.macos.vpn.network-extension@1.186.0"],
  "platform_section_gid": "1214291024165659",
  "sentry_crash_reports_project_gid": "1214294661819890",
  "sentry_crash_group_custom_field_gid": "1214294661819893",
  "project_filter": 6,
  "sentry_org_slug": "ddg",
  "summary_name": "Sentry summary - macOS 1.186 - 2026-05-14",
  "crash_free": false,
  "crash_free_html_notes": null,
  "totals": { "unresolved_count": 18, "new_in_version_count": 5 },
  "sentry_links": {
    "unresolved_query_url": "https://errors.duckduckgo.com/organizations/ddg/issues/?project=6&query=is%3Aunresolved%20app_version%3A1.186.*&statsPeriod=24h",
    "first_release_query_url": "https://errors.duckduckgo.com/organizations/ddg/issues/?project=6&query=is%3Aunresolved%20firstRelease%3A%5B...%5D&statsPeriod=24h"
  },
  "weekly_release_dri_lookup": {
    "platform_project_gid": "1201037661562251",
    "dri_task_name": "macOS App Weekly Release DRI",
    "weekday_status_keyword": "Thursday status"
  },
  "clusters": [
    {
      "cluster_id": "high-9f3a2b8c",
      "severity": "high",
      "is_one_event_carve_out": false,
      "culprit": "TabBarViewController.tabCollectionViewModel",
      "exception_type": "EXC_CRASH",
      "short_ids": ["APPLE-MACOS-D6N6", "APPLE-MACOS-D7YC"],
      "users_total": 14,
      "events_total": 41,
      "events_alltime_sum": 41,
      "first_party_frame_count": 5,
      "rca_eligible": true,
      "rca_skip_reason": null,
      "sentry_links": { "...": "..." },
      "suspect": {
        "file": "macOS/DuckDuckGo/Tab/View/TabBarViewController.swift",
        "line": 312,
        "symbol": "TabBarViewController.tabCollectionViewModel"
      },
      "description_hint": "SIGABRT in TabBarViewController when tabCollectionViewModel is accessed during teardown.",
      "existing_asana_task": null
    }
  ]
}
```

The skill prints:

```
analyze.json written to /tmp/ddg-sentry-report-no-asana/macos-1.186/analyze.json
18 unresolved (5 new in 1.186.x) | HIGH=1, MEDIUM=2, LOW=1, PRE-EXISTING=1 | TIME_RANGE=24h
next step: run external script #1 with --input /tmp/ddg-sentry-report-no-asana/macos-1.186/analyze.json
```

### External script #1 (run by user)

```
$ script-1-asana-lookup --input /tmp/ddg-sentry-report-no-asana/macos-1.186/analyze.json
   → writes /tmp/ddg-sentry-report-no-asana/macos-1.186/analyze.augmented.json
```

Per the contract in `references/external-scripts.md`, the script:

- Queries Asana for each cluster's short-IDs in the macOS section of `Sentry Crash Reports`.
- For our HIGH cluster `high-9f3a2b8c`: no match → `existing_asana_task: null`.
- For one MEDIUM cluster: matches an existing open task `1207001234567890` that already lists both sibling short-IDs → `existing_asana_task: { status: "open", merged_short_ids: [...], needs_short_id_extension: [] }`. The cluster will be **skipped** by `rca`.
- For the other MEDIUM (1-event-carve-out): `existing_asana_task: null` (but the cluster is gated out of `rca.json` regardless).
- For LOW / Pre-existing: no Asana lookup is meaningful, but script #1 fills `existing_asana_task: null` for completeness.

### Mode `rca`

> "Use ddg-sentry-report-no-asana rca."

1. Load `analyze.augmented.json` from the default path. `schema_version: 1` OK.

2. Decide per-cluster action:
   - HIGH `high-9f3a2b8c`: `existing_asana_task: null`, severity HIGH, not carve-out → `create`.
   - MEDIUM (open existing): skip — already tracked, full short-ID coverage.
   - MEDIUM (1-event-carve-out): skip — `is_one_event_carve_out: true`.
   - LOW / Pre-existing: skip — severity below MEDIUM.

3. For the HIGH cluster only:
   - `grep TabBarViewController.tabCollectionViewModel` → confirm file/line.
   - `git blame -L 308,320 macOS/DuckDuckGo/Tab/View/TabBarViewController.swift` → recent change in PR #4812 by DK.
   - `git log -n 5 --since='2 months ago' macOS/DuckDuckGo/Tab/View/TabBarViewController.swift` → recent PRs.

4. Dispatch one general-purpose subagent for the HIGH cluster (since it's the only one with `mode in {create, reopen_append}` and `rca_eligible: true`). Single message, single Agent call (only one cluster — but the pattern handles N in parallel).

5. Render the cluster's `html_notes` from `templates/per-issue-tracking.html`, populated with the subagent's RCA + the PR attribution. Initials only ("DK"), no full name.

6. Write `rca.json`:

```json
{
  "schema_version": 1,
  "generated_at": "2026-05-14T11:02:00Z",
  "platform": "macos",
  "version_display": "1.186",
  "sentry_crash_reports_project_gid": "1214294661819890",
  "sentry_crash_group_custom_field_gid": "1214294661819893",
  "platform_section_gid": "1214291024165659",
  "tasks": [
    {
      "cluster_id": "high-9f3a2b8c",
      "mode": "create",
      "name": "EXC_CRASH TabBarViewController.tabCollectionViewModel",
      "custom_field_value": "APPLE-MACOS-D6N6,APPLE-MACOS-D7YC",
      "section_gid": "1214291024165659",
      "project_gid": "1214294661819890",
      "html_notes": "<body>Sentry crash:\n<a href=\"https://errors.duckduckgo.com/organizations/ddg/issues/APPLE-MACOS-D6N6/?project=6\">https://errors.duckduckgo.com/organizations/ddg/issues/APPLE-MACOS-D6N6/?project=6</a>\n\nLikely caused by <a href=\"https://github.com/duckduckgo/apple-browsers/pull/4812\">https://github.com/duckduckgo/apple-browsers/pull/4812</a>\n<hr/>\n<h2>Root Cause Analysis</h2>Access to a deallocated tab collection view model during view teardown — the binding outlives the controller by one runloop cycle...<h2>Call chain</h2><ol><li>...</li></ol><h2>Likely category</h2>real bug worth fixing<h2>Fix sketch</h2>Capture the model weakly in the binding closure.</body>",
      "existing_task_gid": null,
      "append_only_html_notes": null,
      "existing_custom_field_value": null
    }
  ]
}
```

Skill prints:

```
rca.json written to /tmp/ddg-sentry-report-no-asana/macos-1.186/rca.json
create=1, reopen_append=0, extend_short_ids=0, skipped=4
next step: run external script #2 with --input /tmp/ddg-sentry-report-no-asana/macos-1.186/rca.json
```

### External script #2 (run by user)

```
$ script-2-asana-create --input /tmp/ddg-sentry-report-no-asana/macos-1.186/rca.json
   → writes /tmp/ddg-sentry-report-no-asana/macos-1.186/rca.created.json
```

The script creates one Asana task (`mode: "create"`), captures the GID, writes:

```json
{
  "schema_version": 1,
  "generated_at": "2026-05-14T11:30:00Z",
  "results": [
    {
      "cluster_id": "high-9f3a2b8c",
      "mode_executed": "create",
      "asana_task_gid": "1207009876543210",
      "permalink_url": "https://app.asana.com/0/1214294661819890/1207009876543210",
      "error": null
    }
  ]
}
```

### Mode `summary`

> "Use ddg-sentry-report-no-asana summary."

1. Load `analyze.augmented.json` + `rca.created.json` from default paths.

2. Build permalink map:
   - `high-9f3a2b8c` → `https://app.asana.com/0/1214294661819890/1207009876543210` (from `rca.created.json`).
   - MEDIUM open-existing → `https://app.asana.com/0/1214294661819890/1207001234567890` (from `analyze.augmented.json.existing_asana_task.url`).
   - 1-event-carve-out MEDIUM → no permalink (terse line).
   - LOW / Pre-existing → no permalink.

3. Render `templates/main-report.html` with the sections populated. Each HIGH/MEDIUM line leads with the tracking-task link.

4. Write `summary.json`:

```json
{
  "schema_version": 1,
  "generated_at": "2026-05-14T11:45:00Z",
  "platform": "macOS",
  "version_display": "1.186",
  "date": "2026-05-14",
  "name": "Sentry summary - macOS 1.186 - 2026-05-14",
  "html_notes": "<body><strong>macOS Sentry review — releases 1.186.x</strong>...",
  "is_crash_free_report": false,
  "weekly_release_dri_lookup": {
    "platform_project_gid": "1201037661562251",
    "dri_task_name": "macOS App Weekly Release DRI",
    "weekday_status_keyword": "Thursday status"
  }
}
```

Skill prints:

```
summary.json written to /tmp/ddg-sentry-report-no-asana/macos-1.186/summary.json
HIGH=1, MEDIUM=2 (1 carve-out), LOW=1, PRE-EXISTING=1
next step: run external script #3 with --input /tmp/ddg-sentry-report-no-asana/macos-1.186/summary.json
```

### External script #3 (run by user)

```
$ script-3-file-summary --input /tmp/ddg-sentry-report-no-asana/macos-1.186/summary.json
   → resolves macOS App Weekly Release DRI → Thursday status subtask
   → creates the new subtask under it
   → adds the DRI as follower
   → prints https://app.asana.com/0/.../<new_subtask_gid>
```

End-to-end done. The user reads the new subtask in Asana the same way they would have under the parent skill — but the Sentry analysis happened in a session without an active trifecta lock, and the Asana writes are auditable in three named scripts the team can review and adjust independently.

## Crash-free variant (short-circuit)

If `analyze` detects `crash_free: true` (e.g. for an internal-testing build with no Sentry events yet), the user skips `rca` and `summary` entirely:

```
$ /ddg-sentry-report-no-asana analyze --platform macos --version 1.187
   → writes analyze.json with crash_free: true, crash_free_html_notes populated

$ script-3-file-summary --input /tmp/.../analyze.json
   → uses summary_name + crash_free_html_notes to file the subtask
```

Script #3 must accept either `summary.json` or an `analyze.json` with `crash_free: true` — see [`references/external-scripts.md`](references/external-scripts.md).
