# User Scripts Debug Menu — Remote Config Overrides

**Date:** 2026-03-23
**Branch:** juan/feature/user-scripts-debug-menu
**Status:** Approved

---

## Goal

Replace the Global section of `UserScriptsDebugMenu` with a remote config override mechanism. Instead of filtering user scripts by debug name at load time, disabling a feature mutates the live privacy config JSON to mark that feature as `"disabled"` and reloads all tabs through the normal `PrivacyConfigurationManager` code path.

---

## Background

The current implementation uses two mechanisms:

- **Per-tab:** `UserScripts.perTabDisabled: Set<String>` — filters scripts by `debugName` at WKUserScript install time
- **Global:** `UserScriptDisabledStore.shared.globallyDisabled: Set<String>` — same filter, applied across all tabs

The global approach bypasses the real feature-gate code path. A feature disabled via string filter still reads as "enabled" from `privacyConfig`, so any code that checks `privacyConfig.isEnabled(featureKey:)` is unaffected. The remote config override approach fixes this by disabling the feature at the config layer, which is what a real remote rollback would do.

---

## Scope

- **In scope:** Replace the Global section of `UserScriptsDebugMenu` + delete `UserScriptDisabledStore`
- **Out of scope:** Per-tab section (unchanged), tests (separate pass), persistence across restarts

---

## Components

### `PrivacyConfigOverrideStore` (new, replaces `UserScriptDisabledStore`)

```swift
@MainActor
final class PrivacyConfigOverrideStore {
    static let shared = PrivacyConfigOverrideStore()
    private(set) var overriddenFeatures: Set<String> = []
    private var originalConfigData: Data?

    func disableFeature(_ key: String, in manager: PrivacyConfigurationManaging)
    func enableFeature(_ key: String, in manager: PrivacyConfigurationManaging)
}
```

**State:**
- `originalConfigData` — snapshot of `manager.currentConfig` taken before the first override. May be embedded or fetched config, depending on what is active at that moment. Nil when no overrides are active. Always patch from this snapshot so overrides compose cleanly (no double-patching).
- `overriddenFeatures` — the set of feature keys currently forced to `"disabled"`

**Patching approach — raw JSON via `JSONSerialization`:**

`PrivacyConfigurationData.PrivacyFeature` is a class with immutable `let` properties. Although it has a public memberwise initializer, using it would require manually reconstructing all subfeature settings, rollout steps, cohorts, etc. Patching directly on the raw JSON dictionary is simpler and preserves all unknown fields without reconstruction:

```swift
// Pseudocode
var json = JSONSerialization.jsonObject(with: originalConfigData) as! [String: Any]
var features = json["features"] as! [String: Any]
for key in overriddenFeatures {
    if var feature = features[key] as? [String: Any] {
        feature["state"] = "disabled"
        features[key] = feature
    }
}
json["features"] = features
let patchedData = JSONSerialization.data(withJSONObject: json)
```

**`disableFeature`:**
1. If `originalConfigData` is nil, snapshot `manager.currentConfig`
2. Add key to `overriddenFeatures`
3. Patch `originalConfigData` using the approach above (all keys in `overriddenFeatures`)
4. Call `manager.reload(etag: "debug-override", data: patchedJSON)`
5. If `reload` returns `.embeddedFallback`: reset `overriddenFeatures` to empty and clear `originalConfigData` (store and manager are back to a clean state)

**`enableFeature`:**
1. Remove key from `overriddenFeatures`
2. If `overriddenFeatures` is now empty: call `manager.reload(etag: nil, data: nil)`, clear `originalConfigData`. This path always returns `.embedded` — no fallback guard needed.
3. Otherwise: re-apply remaining overrides to `originalConfigData` and call `manager.reload(etag: "debug-override", data: patchedJSON)`. Apply the same `.embeddedFallback` guard as `disableFeature`.

**Error handling:** If `JSONSerialization` fails to parse `originalConfigData` at any point, the operation is a no-op (state unchanged, no reload called). If `reload` returns `.embeddedFallback` (patched JSON was rejected by the parser — defensive only, should not occur), the store resets to empty state.

---

### `UserScriptsDebugMenu` (updated)

**Per-tab section:** No changes.

**Global section:**
- Title: `[Global — ContentScope features]`
- Items: enumerate feature keys from `privacyConfigurationManager.currentConfig` at menu-open time, parsed via `JSONSerialization` to get the top-level `features` dictionary
- **Exclusions:**
  - `trackerAllowlist` — not a standard feature; excluded by `ContentScopePrivacyConfigurationJSONGenerator`
  - `autoconsent` — excluded by `ContentScopePrivacyConfigurationJSONGenerator`
  - `macOSBrowserConfig` — these are native app feature flags, handled separately in the Feature Flags debug menu
  - `iOSBrowserConfig` — same reason
- Checked state: `PrivacyConfigOverrideStore.shared.overriddenFeatures.contains(key)` — sourced from the store, not from the `state` field in the enumerated JSON (which will be `"disabled"` for overridden features since `currentConfig` returns the patched data when overrides are active)
- Toggle action (both enable and disable): call `PrivacyConfigOverrideStore`, then call `reinstallUserScripts() + tab.reload()` for all tabs (same loop as current `toggleGlobal`)

**Important:** script reinstallation is driven entirely by the explicit `reinstallUserScripts() + tab.reload()` loop in the menu action. `PrivacyConfigurationManager.updatesPublisher` fires on `reload`, but `UserContentUpdating` does not subscribe to it — it only responds to `contentBlockerRulesManager.updatesPublisher`. The explicit loop is required on both enable and disable paths.

**`privacyConfigurationManager` access:** passed into `UserScriptsDebugMenu` at construction time (same manager instance used by `DefaultScriptSourceProvider`), not accessed directly from the app delegate inside the store.

---

### `UserScriptDisabledStore` (deleted)

File deleted. All references in `UserScripts.swift` and `UserScriptsDebugMenu.swift` updated or removed.

---

## Data Flow

```
User toggles feature in menu
        │
        ▼
PrivacyConfigOverrideStore.disableFeature / enableFeature
        │
        ├─ snapshot originalConfigData (first override only)
        ├─ patch raw JSON: features[key]["state"] = "disabled"
        └─ manager.reload(etag: "debug-override", data: patchedJSON)
                │
                └─ updatesPublisher fires (other observers notified,
                   e.g. DuckPlayer, SyncAdapters — NOT user script reinstallation)
        │
        ▼
UserScriptsDebugMenu toggle action:
  for each tab:
    await reinstallUserScripts()   ← reads manager.currentConfig lazily,
    tab.reload()                      picks up patched config at this point
```

`reinstallUserScripts()` calls `ContentScopePrivacyConfigurationJSONGenerator.privacyConfiguration`, which calls `privacyConfigurationManager.currentConfig` — this returns the patched data since `reload` has already been called.

---

## Edge Cases

| Scenario | Behaviour |
|---|---|
| JSON parse failure in store | No-op; `overriddenFeatures` and `originalConfigData` unchanged, no reload called |
| `reload` returns `.embeddedFallback` | Store resets to empty state (clears `overriddenFeatures` and `originalConfigData`); manager is on embedded config; menu items will uncheck on next open |
| App restart | Store is in-memory; real config loads normally on next launch |
| Background config refresh while overrides active | Fetcher overwrites `fetchedConfigData` with new remote data, silently dropping the override. The feature reverts to its remote-config state immediately. Menu items show stale checked state until the menu is reopened. Acceptable for a debug tool. |
| Feature key not present in original config | Patch loop skips it silently; no crash |
| Feature key disappears from live config after initial menu open | Item won't appear next time the menu opens; `overriddenFeatures` entry is harmless |

---

## Files Changed

| File | Change |
|---|---|
| `macOS/DuckDuckGo/Debug/UserScriptDisabledStore.swift` | Deleted |
| `macOS/DuckDuckGo/Debug/PrivacyConfigOverrideStore.swift` | New |
| `macOS/DuckDuckGo/Debug/UserScriptsDebugMenu.swift` | Updated global section; receives `privacyConfigurationManager` at init |
| `macOS/DuckDuckGo-macOS.xcodeproj/project.pbxproj` | Add `PrivacyConfigOverrideStore.swift` to build target; remove `UserScriptDisabledStore.swift` |
