# Non-obvious constants

Reference material for `ddg-sentry-report-no-asana`. Load when you need a specific GID, project filter, or release-string convention. The skill itself never calls Asana MCP, so most of these constants exist to populate JSON for the external scripts that do.

## Sentry

- **Org slug:** `ddg`
- **Self-hosted host:** `errors.duckduckgo.com` — do NOT pass `regionUrl` to the MCP. The MCP rejects non-`sentry.io` hosts and returns `ddg.sentry.io` URLs which you must rewrite client-side.
- **Project filter in URLs:** macOS uses `project=6`, iOS uses `project=8`.
- **Short-IDs (e.g. `APPLE-MACOS-BE7`) resolve on both `ddg.sentry.io` and `errors.duckduckgo.com`** — no need to fetch numeric issue IDs.

## One version → multiple release strings

A given version (e.g. `1.186.1`) ships as several Sentry releases, one per target:

- macOS main app: `DuckDuckGo@1.186.1`
- macOS VPN extension: `com.duckduckgo.macos.vpn.network-extension@1.186.1` (and similar for other extensions)
- iOS main app: `ios@7.216.0`

Filtering by a single release prefix (`release:DuckDuckGo@...`) silently drops extension crashes. Use the `app_version` tag instead — it's set by the SDK on every event regardless of target, so a single `app_version:1.186.*` (or exact `app_version:1.186.0`) catches main app + extensions in one query. Keep the explicit release list only for `firstRelease:`, and include **all** releases returned by `find_releases(query="<version>")`, not just the main-app prefix.

## `list_issues` query syntax

Sentry's native syntax, not natural language. Key filters:

- `app_version:1.186.*` — events tagged with any version in the `1.186.x` series (wildcard, unquoted); use `app_version:1.186.0` for an exact version. Works across main app + extensions.
- `firstRelease:[DuckDuckGo@1.186.0,com.duckduckgo.macos.vpn.network-extension@1.186.0,...]` — issues *first seen* in these releases (new regressions); list must include every release string for the version, not just the main-app prefix.
- `is:unresolved` — exclude resolved.
- `lastSeen:-24h` — restrict to issues whose latest event falls inside the window. Pass values unquoted (`lastSeen:-24h`, not `lastSeen:"-24h"`).

## iOS noise classification

- **iOS SIGKILL noise:** Most iOS SIGKILL crashes with culprit `main` are Jetsam memory-pressure kills, not app bugs. Group these under LOW unless volume spikes or the culprit frame names specific app code. Don't attempt blame on them.

## Asana constants — used to populate JSON for external scripts

The skill itself never calls Asana, but the JSON handoff files include these constants so external scripts know which workspace / project / section / custom-field to target. Do not invoke Asana MCP tools with these — they are passed through as data only.

- **Workspace GID:** `137249556945` (referenced by all three external scripts).

### `Sentry Crash Reports` project (per-issue tracking tasks)

Project GID `1214294661819890`. Partitioned by platform:

- macOS section: `1214291024165659`
- iOS section: `1214290879396596`
- Fallback (`Untitled section`, no platform): `1214294661819891` — older tasks predating the split live here. External script #1 must query the platform section first and fall back to this when no platform-section match exists. Script #2 always **creates** new tasks in the platform section, never the fallback.

**Sentry Crash Group ID custom field:** `1214294661819893`. Comma-separated. A single tracking task can claim multiple Sentry short-IDs by listing them separated by commas (e.g. `APPLE-IOS-D6MW,APPLE-IOS-D6N6,APPLE-IOS-D7YC`). The Asana custom-field search is substring-match, so script #1 must split on `,` and require **exact element match** — substrings like `APPLE-IOS-D6N` matching `APPLE-IOS-D6N6` are false positives.

### Tracking-task fix-version tags

Closer adds a tag of the form `<platform>-app-release-X.Y.Z` (e.g. `macos-app-release-1.188.0`, `ios-app-release-7.220.0`) when the fix ships. Multiple tags may accumulate over time if the issue regressed and was fixed again. The **highest** version among these tags is the most recent claimed fix. Script #1 reports the highest tag and a `fix_version_compare` field (`gt` / `lte` / `none`) so the `rca` mode can branch without re-parsing tags.

### Weekly Release DRI tasks (script #3 target lookup)

Each platform has an Asana project containing a recurring "<platform> App Weekly Release DRI" task whose subtasks are the daily status updates ("Monday status", "Tuesday status", ...). Script #3 files the Sentry report subtask under today's status subtask.

- iOS: project `414709148257752` (`iOS App Development`), task name `iOS App Weekly Release DRI`
- macOS: project `1201037661562251` (`macOS App Development`), task name `macOS App Weekly Release DRI`

There can be multiple incomplete DRI tasks (e.g. one for the active release, one being prepared). Script #3 disambiguates as: prefer assigned over unassigned; if all assigned (or all unassigned), pick the one with the most recent `created_at`. The skill emits this hint inside `summary.json.weekly_release_dri_lookup` for traceability; script #3 owns the actual resolution.
