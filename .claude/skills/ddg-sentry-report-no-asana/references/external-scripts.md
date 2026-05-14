# External script contracts

The skill performs Sentry analysis, root-cause investigation, and report assembly. Three external scripts (run by the user outside Claude Code) handle every Asana interaction:

1. **Script #1 — Asana lookup**: reads `analyze.json`, queries Asana for existing tracking tasks, writes `analyze.augmented.json`.
2. **Script #2 — task create / reopen / extend**: reads `rca.json`, performs Asana writes, writes `rca.created.json`.
3. **Script #3 — summary filer**: reads `summary.json` (or `analyze.json` when `crash_free: true`), files the subtask under today's Weekly Release DRI `<Weekday> status` subtask.

These scripts are not shipped with the skill. This document is the load-bearing contract for whoever implements them. Field names refer to the JSON in [`json-schemas.md`](json-schemas.md).

## Script #1 — Asana lookup

**Input:** `analyze.json` path.
**Output:** `analyze.augmented.json` (same shape; for each cluster, `existing_asana_task` is filled or stays `null`).

### Operations (per cluster)

For each cluster in `analyze.json.clusters`:

1. Run an Asana search keyed on the Sentry Crash Group ID custom field, scoped to the platform section:
   ```
   asana_search_tasks(
     workspace=137249556945,
     projects.any=analyze.json.sentry_crash_reports_project_gid,
     sections.any=analyze.json.platform_section_gid,
     custom_fields.<analyze.json.sentry_crash_group_custom_field_gid>.value=<short_id>,
     opt_fields="name,permalink_url,custom_fields,memberships.section.gid,tags,tags.name,completed",
     limit=20
   )
   ```
   Try each `cluster.short_ids` element until a hit is found. The Asana custom-field search is **substring-match** — split the returned `custom_fields` value on `,` and require **exact element match** against the short-ID. Substring hits (`APPLE-IOS-D6N` against `APPLE-IOS-D6N6`) are false positives.
2. If the platform section returns nothing, fall back to the `Untitled section` GID `1214294661819891` (pre-platform-split tasks). Never create tasks in this fallback section — that's script #2's concern; here it's read-only.
3. If the result task name starts with `[Duplicate]`, recurse: read the parent task GID, fetch the parent with the same `opt_fields`, and apply the gating logic to the parent.
4. Parse `tags`: any tag matching `^<platform>-app-release-(\d+\.\d+\.\d+)$` is a fix-version tag. Take the **highest** version among them and compare against the analysed `version_display` (left-pad each component if needed; numeric comparison).
5. Build the `existing_asana_task` payload:
   - `gid`, `url`: from the matched task (the parent task GID when `[Duplicate]` recursed).
   - `status`: `"open"` if not completed, `"completed"` if completed.
   - `fix_version_tag`: the highest matching tag string, or `null`.
   - `fix_version_compare`: `"gt"` if `fix_version_tag > version_display`, `"lte"` if `≤`, `"none"` if no tag.
   - `is_duplicate_link`: the parent GID if the immediate match was `[Duplicate]`; else `null`.
   - `merged_short_ids`: the current custom-field value split on `,` (whitespace-trimmed elements).
   - `needs_short_id_extension`: every short-ID in `cluster.short_ids` that is NOT already in `merged_short_ids`. Empty array when fully merged.
6. Write back the augmented JSON to `analyze.augmented.json` (preserve every other field unchanged).

### Required Asana opt_fields

Every `asana_get_task` call must include `tags,tags.name` — the DDG data-protection hook rejects calls without it (`RETRY REQUIRED`). Every `asana_search_tasks` call should include the full opt_fields list above so `completed` and `tags` are present in the response.

### Error handling

- Asana API error (network, auth) → fail fast with non-zero exit; do not write a partial augmented file. The user re-runs after fixing.
- Custom-field search returns ≥2 different tasks for the same short-ID → log a warning; pick the first non-`[Duplicate]` match. The custom field is conceptually unique per short-ID; multi-match implies manual data drift.

## Script #2 — task create / reopen / extend

**Input:** `rca.json` path.
**Output:** `rca.created.json` (one `results` entry per `rca.json.tasks` entry, in the same order).

### Operations (per task)

Branch on `task.mode`:

#### `create`

```
asana_create_task(
  name=task.name,
  project_id=task.project_gid,
  section_id=task.section_gid,
  custom_fields={ <task.sentry_crash_group_custom_field_gid>: task.custom_field_value },
  html_notes=task.html_notes,
)
```

Capture the returned GID + permalink. Write to `rca.created.json.results[i]` as `mode_executed: "create"`, `asana_task_gid`, `permalink_url`, `error: null`.

#### `reopen_append`

1. `asana_update_task(task_id=task.existing_task_gid, completed=false)`.
2. `asana_get_task(task_id=task.existing_task_gid, opt_fields="html_notes,tags,tags.name")` to read the existing body.
3. Concatenate: existing `html_notes` body content (between `<body>` and `</body>`) + `<hr/>` + `task.append_only_html_notes` body content. Wrap in `<body>...</body>`.
4. `asana_update_task(task_id=task.existing_task_gid, html_notes=<merged body>)`.
5. Write to `rca.created.json.results[i]` as `mode_executed: "reopen_append"`, `asana_task_gid: task.existing_task_gid`, `permalink_url` from step 2's response.

#### `extend_short_ids`

```
asana_update_task(
  task_id=task.existing_task_gid,
  custom_fields={ <sentry_crash_group_custom_field_gid>: task.existing_custom_field_value + "," + <missing IDs from rca.json> },
)
```

The skill emits the *list of additions*, not the merged value, in `task.custom_field_value` for `create` mode. For `extend_short_ids`, the script reconstructs the full new value by merging `task.existing_custom_field_value` with the additions captured during script #1. (Schema note: `rca.json.tasks[].custom_field_value` for `extend_short_ids` mode is the *full new value* including the existing IDs — the skill builds it from the augmented JSON.)

Write `mode_executed: "extend_short_ids"`, `asana_task_gid: task.existing_task_gid`, `permalink_url`.

### Required custom-field write

Every `asana_create_task` MUST set the Sentry Crash Group ID custom field (`1214294661819893`) to `task.custom_field_value`. Without it, future runs of script #1 will not find the task and will create duplicates.

### PII / hook handling

The DDG asana-exfiltration hook may reject writes that contain full employee names. The skill emits `html_notes` with initials + PR links only. If a hook block surfaces:

- Do not retry with modified params automatically.
- Surface the failure in `rca.created.json.results[i].error` with the rejected snippet.
- The user inspects, edits, and re-runs.

### Error handling

- Per-task failures must be captured in the `error` field of the corresponding `rca.created.json.results[i]` with `mode_executed: "failed"`. The script continues to the next task.
- Mode `summary` reads these errors and surfaces them in the main-report "Recommended next step" block.

## Script #3 — summary filer

**Input:** Either `summary.json` (regular run) or `analyze.json` with `crash_free: true` (crash-free run).
**Output:** Console-only — print the created subtask permalink.

### Operations

1. **Resolve the DRI task.** Use `weekly_release_dri_lookup.platform_project_gid` and `dri_task_name`:
   ```
   asana_search_tasks(
     workspace=137249556945,
     projects.any=<platform_project_gid>,
     text=<dri_task_name>,
     completed=false,
     opt_fields="name,assignee,assignee.name,created_at,permalink_url",
     limit=20,
   )
   ```
   Filter the returned list to **exact name match** (`name == dri_task_name`). The text filter is fuzzy — "🧰 Create a new release DRI task" entries must be discarded.

2. **Disambiguate when multiple match.** Apply in order:
   - If exactly one match has `assignee != null` → pick that one.
   - Otherwise (all assigned, or all unassigned) → pick the most recent `created_at`.

3. **Find today's `<Weekday> status` subtask.** Use the local weekday from the input file's `weekly_release_dri_lookup.weekday_status_keyword`:
   ```
   asana_get_task(
     task_id=<DRI_task_gid>,
     opt_fields="subtasks,subtasks.name,subtasks.completed,subtasks.permalink_url,tags,tags.name",
   )
   ```
   Pick the subtask whose `name` contains `weekday_status_keyword` case-insensitively. Prefer incomplete; if multiple incomplete match, pick most recent `created_at`.

4. **File the subtask.**
   ```
   asana_create_task(
     parent=<status_subtask_gid>,
     name=<input>.name | <input>.summary_name,
     html_notes=<input>.html_notes | <input>.crash_free_html_notes,
   )
   ```
   Use `name` + `html_notes` when reading `summary.json`; use `summary_name` + `crash_free_html_notes` when reading `analyze.json` with `crash_free: true`.

5. **Add the DRI as follower.**
   ```
   asana_add_task_followers(
     task_gid=<new_subtask_gid>,
     followers=<DRI_assignee_gid>,
   )
   ```
   Skip silently when the DRI task has no assignee. Do NOT follow per-issue tracking tasks created by script #2 — only the main summary subtask.

### Stop-and-ask cases

- Zero exact-name DRI matches → stop, print the platform project URL, ask the user to verify.
- No `<Weekday> status` subtask for today's weekday → stop, print the DRI task permalink + the subtask names that were checked, ask the user.
- Multiple ambiguous matches that the disambiguation rules don't resolve → stop and ask.

Never silently fall back to writing under the DRI task itself or under a different day's subtask.

## Cross-script invariants

- Every script writes its output atomically (`.tmp` → `rename`) so a partial run never leaves a half-baked file the next mode picks up.
- Every script validates `schema_version` and rejects unknown versions with a clear error message.
- Asana writes happen only in scripts #2 and #3. Script #1 is read-only.
- The skill's three modes never call any of these scripts. The user invokes them by hand between modes.
