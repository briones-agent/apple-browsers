# Per-Site Autoplay Policy via Permissions

**Date:** 2026-03-19
**Branch:** dominik/autoplay-permissions
**Status:** Design

## Context

The `dominik/autoplay-permissions` branch adds a global autoplay policy setting in General Preferences with three modes: allow all media, block audio (default), and block all. The policy is applied per-navigation via `AutoplayPolicyTabExtension` using WebKit's private `_WKWebsiteAutoplayPolicy` API.

This design adds per-website overrides to the global setting, using the existing Permissions infrastructure (`PermissionType`, `PermissionManager`, `PermissionStore`).

## Design Decisions

- Per-site autoplay overrides are stored as a new `PermissionType.autoplayPolicy` case, reusing the existing CoreData-backed permission storage.
- The Permission Center is the only UI for managing per-site overrides (no Preferences management UI yet).
- Per-site overrides are burned with the fire button, consistent with all other permissions. `PermissionStore` burn logic is generic (clears all permission types) — no additional code needed.
- The Permission Center icon is shown on address bar hover (gated behind autoplay feature flag) for discoverability.

## Data Model

### New PermissionType Case

Add `case autoplayPolicy` to `PermissionType` with rawValue `"autoplay_policy"`.

Properties:
- `requiresSystemPermission`: `false`
- `canPersistGrantedDecision`: `true`
- `canPersistDeniedDecision`: `true`
- `icon`: speaker/autoplay icon from the design system
- `solidIcon`: `nil` (no active/in-use visual state)
- Not included in `permissionsUpdatedExternally` (static computed property with hardcoded array — no code change needed, just excluded by omission)
- `rawValue`: `"autoplay_policy"` (add case in both `rawValue` getter and `init?(rawValue:)` initializer)

### Decision Mapping

| `PersistedPermissionDecision` | Autoplay meaning       | `_WKWebsiteAutoplayPolicy` |
|-------------------------------|------------------------|-----------------------------|
| `.allow`                      | Video and audio        | `.allow`                    |
| `.ask`                        | Video with audio muted | `.allowWithoutSound`        |
| `.deny`                       | Never                  | `.deny`                     |
| No stored permission          | Use global default     | From `AutoplayPreferences`  |

## Permission Center UI

### Autoplay Row

- Always shown when the `autoplayPolicy` feature flag is on. Injected into the item list in `collectPermissions()` regardless of `usedPermissions` or persisted state.
- Label: "Autoplay"
- Dropdown with 4 options and custom labels:
  - "Use default" — removes per-site override, falls back to global setting
  - "Video and audio" — stores `.allow`
  - "Video with audio muted" — stores `.ask`
  - "Never" — stores `.deny`
- Default selection: "Use default" (no per-site override stored).
- Requires a custom enum (e.g. `AutoplayDecision` with cases `.useDefault`, `.allowAll`, `.audioMuted`, `.blockAll`) since "Use default" maps to `removePermission()` rather than `setPermission()`. A dedicated view (similar to `PopupPermissionRowView`) and handler method in the view model map this enum to `PermissionManager` calls.
- Show reload banner on change, consistent with other permissions. Although the policy technically applies per-navigation, a reload is the most immediate way for the user to see the effect.

### Permission Center Icon Visibility

Current behavior: icon shows when the address bar is not focused AND there are active/persisted permissions or page-initiated popups.

New behavior: pass `isMouseOverNavigationBar` as a new parameter to `shouldShowPermissionCenterButton` and include it in the return condition: `|| (isMouseOverNavigationBar && featureFlagger.isFeatureOn(.autoplayPolicy))`. This shows the icon on hover regardless of whether other permissions exist, but only when the address bar is not focused. Gated behind the autoplay feature flag.

## AutoplayPolicyTabExtension Changes

### Current Flow
1. Check `autoplayPolicy` feature flag
2. Read `autoplayPreferences.autoplayBlockingMode`
3. Convert to `_WKWebsiteAutoplayPolicy`, set on navigation preferences

### New Flow
1. Check `autoplayPolicy` feature flag (unchanged)
2. Extract domain from navigation action URL (use `host` with `droppingWwwPrefix()`, matching `PermissionManager`'s normalization)
3. Call `permissionManager.hasPermissionPersisted(forDomain: domain, permissionType: .autoplayPolicy)` to check if a per-site override exists
4. If `true`: read `permissionManager.permission(forDomain:permissionType:)` and map `.allow`/`.ask`/`.deny` to `_WKWebsiteAutoplayPolicy`
5. If `false`: fall back to global `autoplayPreferences.autoplayBlockingMode` (current behavior)
6. Set on navigation preferences, return `.next`

**Note:** The two-step check (step 3-4) is necessary because `PermissionManager.permission()` returns `.ask` by default when no permission is stored, which collides with the explicit `.ask` mapping for "Video with audio muted."

### New Dependency
`AutoplayPolicyTabExtension` gains a `PermissionManager` dependency. `TabExtensionDependencies` does not currently expose `permissionManager`, so pass it directly in the `AutoplayPolicyTabExtension` initializer call inside the `add {}` block in `TabExtensionsBuilder.swift`, sourced from the same provider that constructs `PermissionModel`.

## Files to Modify

| File | Change |
|------|--------|
| `PermissionType.swift` | Add `case autoplayPolicy`, rawValue, icon, persistence flags. Update exhaustive switches in `canPersistGrantedDecision` and `canPersistDeniedDecision` (4 switch sites: 2 methods x 2 feature flag branches each) |
| `PermissionCenterView.swift` | Add custom autoplay row with 4-option picker |
| `PermissionCenterViewModel.swift` | Handle autoplay: always present when flag on, map selections to PermissionManager |
| `AddressBarButtonsViewController.swift` | Pass `isMouseOverNavigationBar` to `TabViewModel.shouldShowPermissionCenterButton` (defined as extension in this file), update the boolean logic in the extension method, and update the caller at `updatePermissionCenterButton()` |
| `AutoplayPolicyTabExtension.swift` | Add PermissionManager dependency, per-site resolution |
| `TabExtensionsBuilder.swift` | Pass PermissionManager to AutoplayPolicyTabExtension |
| UserText / Strings | Add "Autoplay" (used as `localizedDescription` on the new `PermissionType` case), "Use default", and dropdown option labels |

## Files NOT Modified

| File | Reason |
|------|--------|
| `PermissionManager.swift` / `PermissionStore.swift` | Generic, handle any PermissionType |
| `PermissionModel.swift` | Autoplay doesn't use request/grant runtime flow |
| `PermissionAuthorizationQuery` / auth views | No user prompt for autoplay |
| `WKWebpagePreferencesExtension.swift` / `NavigationAction.swift` | WebKit bridge unchanged |

## Testing

- `AutoplayPolicyTabExtension` tests: verify per-site resolution (with override → uses override, without → falls back to global), including the `.ask` default vs explicit `.ask` distinction
- `PermissionCenterViewModel` tests: autoplay row always appears when feature flag is on, selection changes map correctly to `setPermission`/`removePermission`
- `PermissionType` tests: new case round-trips through `rawValue`/`init?(rawValue:)`

## Out of Scope

- Preferences UI for managing per-site autoplay overrides (separate future work)
- Changes to the WebKit bridge or navigation action layer
