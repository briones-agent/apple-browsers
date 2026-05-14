# JSON handoff schemas

The skill never calls Asana. It exchanges five JSON files with three external scripts:

```
analyze ──▶ analyze.json
              │
              ▼  (external script #1: Asana lookup)
            analyze.augmented.json
              │
              ▼
            rca ──▶ rca.json
                     │
                     ▼  (external script #2: create / reopen / extend tasks)
                   rca.created.json
                     │
                     ▼
                   summary ──▶ summary.json
                                │
                                ▼  (external script #3: file under DRI subtask)
```

All five files carry `schema_version: 1` at the top level. Scripts must reject unrecognized versions with a clear error rather than guess at field meanings. Bump the version on any breaking change to any of the schemas; bumping one file's schema bumps all of them (they share a version space).

## Field conventions

- All timestamps are ISO 8601 UTC (`Z`-suffixed).
- All GIDs are strings (Asana GIDs frequently exceed JS safe-int bounds; keeping them as strings avoids precision loss in any consumer).
- All `gid`-suffixed fields are Asana resource GIDs.
- All `*_url` fields are absolute URLs that resolve on the public web.
- Missing optional values are `null`, not omitted, unless explicitly noted.
- `platform` in `analyze.json` / `rca.json` is lowercase (`ios` / `macos`) — used for filters and section lookups. `summary.json.platform` is human-cased (`iOS` / `macOS`) — used in display strings. The `version_display` field follows the same split: lowercase forms use the literal version (`1.186`), human-cased forms use whatever the user supplied.

## `analyze.json` — emitted by Mode `analyze`

```jsonc
{
  "schema_version": 1,
  "generated_at": "2026-05-14T10:31:00Z",
  "platform": "macos",                            // "ios" | "macos"
  "version": "1.186.*",                           // value used in app_version filter
  "version_display": "1.186",                     // collapsed for headings
  "time_range": "24h",                            // "24h" | "72h" | "7d" | ...
  "weekday": "Thursday",                          // from `date +%A`
  "release_strings": [                            // every release returned by find_releases(query=<version_display>)
    "DuckDuckGo@1.186.0",
    "com.duckduckgo.macos.vpn.network-extension@1.186.0"
  ],
  "platform_section_gid": "1214291024165659",     // macOS = 1214291024165659, iOS = 1214290879396596
  "sentry_crash_reports_project_gid": "1214294661819890",
  "sentry_crash_group_custom_field_gid": "1214294661819893",
  "project_filter": 6,                            // Sentry URL filter: 6 = macOS, 8 = iOS
  "sentry_org_slug": "ddg",
  "summary_name": "Sentry summary - macOS 1.186 - 2026-05-14",

  "crash_free": false,                            // true → clusters is empty, crash_free_html_notes is populated
  "crash_free_html_notes": null,                  // string | null

  "totals": {
    "unresolved_count": 18,
    "new_in_version_count": 5
  },

  "sentry_links": {
    "unresolved_query_url": "https://errors.duckduckgo.com/organizations/ddg/issues/?project=6&query=is%3Aunresolved%20app_version%3A1.186.*&statsPeriod=24h",
    "first_release_query_url": "https://errors.duckduckgo.com/organizations/ddg/issues/?project=6&query=..."
  },

  "weekly_release_dri_lookup": {                  // informational hint for script #3
    "platform_project_gid": "1201037661562251",
    "dri_task_name": "macOS App Weekly Release DRI",
    "weekday_status_keyword": "Thursday status"
  },

  "clusters": [
    {
      "cluster_id": "high-9f3a2b8c",              // <severity>-<sha1(culprit + sorted_short_ids)[:8]>
      "severity": "high",                         // "high" | "medium" | "low" | "preexisting"
      "is_one_event_carve_out": false,            // medium-only: true ⇒ no Asana task; main-report-line only
      "culprit": "TabBarViewController.tabCollectionViewModel",
      "exception_type": "EXC_CRASH",
      "short_ids": ["APPLE-MACOS-D6N6", "APPLE-MACOS-D7YC"],
      "users_total": 14,
      "events_total": 41,                          // sum within the time window
      "events_alltime_sum": 41,                    // sum of Sentry's all-time `count` across short-IDs; gates carve-out
      "first_party_frame_count": 5,
      "rca_eligible": true,                       // false ⇒ rca mode omits this cluster from rca.json.tasks
      "rca_skip_reason": null,                    // "generic_culprit" | "no_first_party_frames" | "jetsam_oom" | null
      "sentry_links": {
        "issues": [
          {
            "short_id": "APPLE-MACOS-D6N6",
            "url": "https://errors.duckduckgo.com/organizations/ddg/issues/APPLE-MACOS-D6N6/?project=6",
            "users": 8,
            "events": 23
          },
          {
            "short_id": "APPLE-MACOS-D7YC",
            "url": "https://errors.duckduckgo.com/organizations/ddg/issues/APPLE-MACOS-D7YC/?project=6",
            "users": 6,
            "events": 18
          }
        ],
        "stacktrace_url": "https://errors.duckduckgo.com/organizations/ddg/issues/APPLE-MACOS-D6N6/events/<event_id>/?project=6"
      },
      "suspect": {                                 // null when culprit is generic / OS-only
        "file": "macOS/DuckDuckGo/Tab/View/TabBarViewController.swift",
        "line": 312,
        "symbol": "TabBarViewController.tabCollectionViewModel"
      },
      "description_hint": "SIGABRT in TabBarViewController when tabCollectionViewModel is accessed during teardown.",  // for the main-report line; one sentence

      "existing_asana_task": null                  // populated by script #1; see below
    }
  ]
}
```

## `analyze.augmented.json` — script #1 writes back

Same shape as `analyze.json`. For each cluster, `existing_asana_task` is filled (or stays `null`):

```jsonc
"existing_asana_task": {
  "gid": "1207001234567890",
  "url": "https://app.asana.com/0/1214294661819890/1207001234567890",
  "status": "open",                                // "open" | "completed"
  "fix_version_tag": null,                         // e.g. "macos-app-release-1.188.0" — highest version tag
  "fix_version_compare": "none",                   // "gt" | "lte" | "none"  — vs analysed version
  "is_duplicate_link": null,                       // when name starts with [Duplicate], the parent task gid; else null
  "merged_short_ids": ["APPLE-MACOS-D6N6", "APPLE-MACOS-D7YC", "APPLE-MACOS-D6MW"],  // current custom-field value, split
  "needs_short_id_extension": []                    // short-IDs from this cluster not yet in merged_short_ids
}
```

**Decision matrix used by Mode `rca`** (mirrors the parent skill's step-5 gate):

| `existing_asana_task` | `status` | `fix_version_compare` | `needs_short_id_extension` | `rca.json` mode |
|---|---|---|---|---|
| `null` | — | — | — | `create` (when cluster is HIGH/MEDIUM and not 1-event-carve-out) |
| present | `open` | — | empty | (cluster omitted from `rca.json.tasks`; permalink contributes to main report) |
| present | `open` | — | non-empty | `extend_short_ids` |
| present | `completed` | `gt` | — | (cluster omitted; "Fix already shipped" bucket in main report) |
| present | `completed` | `lte` or `none` | — | `reopen_append` |
| present (parent of `[Duplicate]`) | — | — | — | apply same matrix to the parent task |

## `rca.json` — emitted by Mode `rca`

```jsonc
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
      "mode": "create",                            // "create" | "reopen_append" | "extend_short_ids"
      "name": "EXC_CRASH TabBarViewController.tabCollectionViewModel",
      "custom_field_value": "APPLE-MACOS-D6N6,APPLE-MACOS-D7YC",
      "section_gid": "1214291024165659",
      "project_gid": "1214294661819890",

      "html_notes": "<body>Sentry crash:\n<a href=\"...\">...</a>\n...</body>",  // valid asana-rich-text; renders per templates/per-issue-tracking.html

      "existing_task_gid": null,                   // populated for reopen_append / extend_short_ids
      "append_only_html_notes": null,              // only for reopen_append: the new "Regression seen in <version>" segment
      "existing_custom_field_value": null          // only for extend_short_ids: the value before merge
    }
  ]
}
```

Clusters that are LOW, Pre-existing, "Fix already shipped" (existing task with `fix_version_compare: "gt"`), or hit the 1-event-carve-out do **not** appear in `tasks` — they only need a main-report line, no Asana write.

### `mode` semantics

- **`create`**: Cluster has no existing Asana task. Script #2 creates a new task with `name`, `project_gid`, `section_gid`, `custom_fields.<gid>=custom_field_value`, and `html_notes`.
- **`reopen_append`**: Cluster matches an existing completed task without a future-version fix tag (regression). Script #2 sets `completed=false`, reads existing `html_notes`, appends `append_only_html_notes` (with a `<hr/>` separator), and writes the merged body back. The skill emits only the append-only segment so script #2 can do the merge without re-rendering the full body.
- **`extend_short_ids`**: Cluster matches an existing open task that lacks some of the cluster's sibling short-IDs in its custom field. Script #2 updates only the custom field: `<gid>=<existing_custom_field_value>,<new_ids_comma_separated>`. No `html_notes` write.

## `rca.created.json` — script #2 writes back

```jsonc
{
  "schema_version": 1,
  "generated_at": "2026-05-14T11:30:00Z",
  "results": [
    {
      "cluster_id": "high-9f3a2b8c",
      "mode_executed": "create",                   // matches rca.json.tasks[].mode (or "skipped" / "failed")
      "asana_task_gid": "1207001234567890",
      "permalink_url": "https://app.asana.com/0/1214294661819890/1207001234567890",
      "error": null                                // human-readable string when mode_executed is "failed"
    }
  ]
}
```

Mode `summary` must surface any non-null `error` strings inline in the main-report "Recommended next step" block — silent omission would mask Asana-side failures.

## `summary.json` — emitted by Mode `summary`

```jsonc
{
  "schema_version": 1,
  "generated_at": "2026-05-14T11:45:00Z",
  "platform": "macOS",                             // human-cased for display
  "version_display": "1.186",
  "date": "2026-05-14",
  "name": "Sentry summary - macOS 1.186 - 2026-05-14",
  "html_notes": "<body><strong>macOS Sentry review — releases 1.186.x</strong>...</body>",  // valid asana-rich-text; renders per templates/main-report.html
  "is_crash_free_report": false,                   // mirrors analyze.json.crash_free
  "weekly_release_dri_lookup": {
    "platform_project_gid": "1201037661562251",
    "dri_task_name": "macOS App Weekly Release DRI",
    "weekday_status_keyword": "Thursday status"
  }
}
```

Script #3 resolves the DRI task + today's `<Weekday> status` subtask using `weekly_release_dri_lookup` and files `name` + `html_notes` as a new subtask.

## Crash-free passthrough

When `analyze.json.crash_free == true`:

- `clusters` is `[]`.
- `crash_free_html_notes` is populated (rendered from `templates/crash-free.html`).
- The user is instructed to skip Modes `rca` and `summary` and run script #3 directly on `analyze.json`.
- Script #3 must accept either `summary.json` or an `analyze.json` with `crash_free: true`. In the latter case it reads `summary_name` for the subtask name and `crash_free_html_notes` for the body.
