# Common mistakes — extended

Overflow rows from `SKILL.md` → `Common mistakes`. Load when a workflow step fails in a way the inline table doesn't cover. Asana-side mistakes (search options, auto-resolve, follower management) are the responsibility of the external scripts and live in [`external-scripts.md`](external-scripts.md); this file covers the skill's own surface area.

## Sentry queries

| Mistake | Fix |
|---|---|
| Filtering events by `release:DuckDuckGo@...` (single prefix) | Silently drops extension crashes (e.g. `com.duckduckgo.macos.vpn.network-extension@...`). Use `app_version:` for the event-matching query; use the full multi-prefix release list only for `firstRelease:`. |
| Confusing `app_version:` vs `firstRelease:` | `app_version:` = events whose version tag matches (cross-target). `firstRelease:` = issue's *first-ever* event was in one of these release strings (true regressions) — needs explicit release strings, so include all targets. |
| Forgetting `&project=<filter>` in errors.duckduckgo.com query URLs | The project filter is required for listing pages to render correctly; optional but recommended for single-issue URLs. |
| Linking Sentry short-IDs without the `APPLE-IOS-` / `APPLE-MACOS-` platform prefix in the URL path | The full short-ID is `APPLE-IOS-DF5F` or `APPLE-MACOS-BE7`, not `DF5F` / `BE7` alone. Use `https://errors.duckduckgo.com/organizations/ddg/issues/APPLE-IOS-DF5F` — the link **text** can shorten to the trailing portion (`DF5F`) for readability, but the URL path must carry the full prefixed short-ID or it may not resolve. Inconsistency within one report (some links prefixed, some not) is a tell that the model dropped the prefix mid-list. |
| Trusting the "culprit" field for blame when generic | Symbols like `value`, `NSBundle.module`, `__pthread_kill`, `objc_release`, `main` are not attributable. Skip them. |

## Tracking-task clustering + dedupe

The skill clusters issues by culprit and emits JSON so external scripts can dedupe against Asana. The skill itself does not query or write Asana — see [`external-scripts.md`](external-scripts.md) for the script-side rules.

| Mistake | Fix |
|---|---|
| Filing one cluster per Sentry short-ID for sibling issues | Group new issues by **culprit symbol** before emitting `analyze.json`. Multiple short-IDs with the same culprit collapse into ONE cluster whose `short_ids` array (and the eventual `custom_field_value` in `rca.json`) lists every short-ID comma-separated. Different culprits → different clusters even if they share a root cause. |
| Producing an `rca.json` entry for a cluster the augmented JSON already linked to an open Asana task | The `rca` mode reads `existing_asana_task` per cluster. Open tasks (or completed-with-future-fix-tag) do NOT need a new tracking task — they only contribute their `permalink_url` to the main report. Only `existing_asana_task: null` clusters get `mode: "create"`; completed-without-future-fix-tag get `mode: "reopen_append"`. |
| Producing a non-deterministic `cluster_id` between runs | Use `<severity>-<sha1(culprit + sorted_short_ids)[:8]>`. Re-runs of `analyze` against the same Sentry state must produce identical IDs so the user can manually edit the augmented JSON and replay later modes without breaking references. |
| Burying the tracking-task link at the end of the per-issue line in the main report | `summary` mode renders the main report body. Lead each HIGH/MEDIUM line with `Tracking · SHORT-ID(s) · stats · description`. LOW and Pre-existing entries (no tracking task) lead with the Sentry short-ID instead. |

## Severity / classification

| Mistake | Fix |
|---|---|
| Treating every iOS SIGKILL as a bug | Most SIGKILL+`main` crashes on iOS are Jetsam memory kills, not app bugs. LOW severity unless volume spikes or culprit is specific app code. |
| Skipping the `rca` subagent because the crash leaf is in libobjc / UIKit / Swift runtime | Look at the *full* trace, not just the leaf. If the trace has ≥3 first-party (DuckDuckGo) frames before reaching the OS leaf, dispatch the subagent — the root cause can absolutely be in app code (renamed `@IBAction`, over-released object, retain-cycle break, allocation pressure from a specific path) even when the fault surfaces inside `__sel_registerName`, `objc_msgSend`, `bmalloc`, or `WKWebView` internals. The "OS-frames-only" skip applies only when there are *no* first-party frames at all. |
| Skipping RCA because the cluster *looks* like Jetsam OOM (SIGKILL on `main` or similar OOM signature) before counting first-party frames | Count first-party frames first. A SIGKILL with a deep launch-path stacktrace — e.g. `Launching.makeStorageHandler → DataStore.openDatabase → GRDB DatabaseQueue.init → SQLite sqlite3Init → SQLCipher PBKDF2-HMAC-SHA512` — has ≥4 first-party frames and is HIGH/MEDIUM, not LOW. The `jetsam_oom` skip in step `a.6` only fires when the culprit is `main` AND `first_party_frame_count == 0` (Jetsam terminated the process before any app code ran). When app code is on the stack, the OOM is caused *by* something the app did — run RCA. |
| Emitting an `rca.json` task entry with no Root Cause Analysis section | If a subagent ran for the cluster, its output must populate `html_notes`. If you decided to skip the subagent under one of the legitimate skip rules, the cluster should not appear in `rca.json.tasks` at all (LOW/Pre-existing/Fix-shipped/1-event-carve-out clusters are omitted). A "concluded not actionable, here's why" RCA is a valid result; an empty body is not. |
| Attributing blame on pre-existing crashes (full names, initials, or assignee mentions) | Pre-existing entries list by user count and do **not** attribute blame at all. No "assigned to Kieran", no "(KS)", no "owned by frontend team". Pre-existing issues already have owners on their own tracking tasks; the daily summary records volume only. The blame columns (initials + PR links) apply to HIGH/MEDIUM new-in-version issues only. |
| Inventing skip rationales in the "Recommended next step" section | The Recommended-next-step block summarises *what was found and what to do about it*. It is not a place to retroactively justify omissions ("none warrant immediate tracking tasks given the 1-user threshold"). If a cluster was skipped, it must be for one of the five reasons in the `rca` subagent skip rules — and that reason belongs in the per-issue line, not as a release-wide policy. The 1-event carve-out is the only event-count-driven skip; if you find yourself writing a sentence that explains away why MEDIUMs with ≥2 events were dropped, stop: those MEDIUMs need tracking tasks. |
| Substituting a different version when the requested one returns no events | The user-supplied version is authoritative — match it literally. If `find_releases` returns no releases AND `list_issues` returns zero issues, take the crash-free short-circuit: emit `analyze.json` with `crash_free: true` and `crash_free_html_notes` populated; stop. Do NOT silently retarget to a previously-shipped version. Pre-release runs exist specifically to verify that internal-testing builds have no new crashes; substituting a different version files redundant tracking tasks against the wrong release and defeats the check. If a version looks like a typo, ask the user. |
| Running root-cause subagents serially | Dispatch them in parallel (single message, multiple Agent tool calls) — they're independent and waiting serially is wasteful. Skip subagents entirely when the culprit is generic or OS-only — there's nothing to analyze. Also skip when the augmented JSON routed the cluster to "fix already shipped" (existing_asana_task with `fix_version_compare: "gt"`). |

## PII

| Mistake | Fix |
|---|---|
| Writing full employee names into `html_notes` payloads | The skill never calls Asana directly, but the JSON it emits flows to a downstream Asana write via script #2 / #3. The DDG asana-exfiltration hook blocks full employee names on those writes — the skill must use initials + PR links in `html_notes`, exactly as if it were filing directly. If even initials get rejected by the script's Asana call, the user falls back to PR-number-only attribution by hand-editing the JSON before script #2 runs. Applies to the main report **and** the per-issue tracking-task bodies. |
