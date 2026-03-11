# App Store Update Check Race Condition Fix

**Date:** 2026-03-11
**Scope:** `macOS/LocalPackages/AppUpdater`
**Issues addressed:** Rate limiting bypass, concurrent in-flight checks, missing error-path gate reset

---

## Background

`AppStoreUpdateController` checks the CDN for a newer version on every `NSWindow.didResignKeyNotification` and at init. Three bugs allow spurious or duplicate CDN fetches and potentially duplicate update notifications:

1. **Rate limiting is permanently bypassed when no update has ever been found.**
   `canStartNewCheck` short-circuits on `latestUpdate == nil`, ignoring `lastUpdateCheckTime` entirely. Since `latestUpdate` is never set when the CDN returns "no update", every window-resign fires a CDN request for users already on the latest version.

2. **Multiple concurrent checks can slip through the gate.**
   `@UpdateCheckActor` suspends at the network `await`. While Task A waits for the CDN response, Task B runs, reads the still-`nil` `latestUpdate`, and also passes `canStartNewCheck`. Both tasks complete independently and both call `showUpdateNotificationIfNeeded`.

3. **The error path never resets the gate.**
   `recordCheckTime()` is only called in the success path. A failed CDN fetch leaves `lastUpdateCheckTime` unchanged, so the next automatic check is not rate-limited.

---

## Design

### `UpdateCheckState` (3 changes)

#### Remove `latestUpdate` parameter from `canStartNewCheck`

The parameter was a proxy for "has a check ever run", but `lastUpdateCheckTime` already captures this correctly — it is `nil` on the very first check, so the `if let lastCheck` guard naturally allows it through. Removing the parameter eliminates both the incorrect short-circuit and the cross-actor read of a `@Published` property.

**Before:**
```swift
public func canStartNewCheck(updater: ..., latestUpdate: Update?, minimumInterval: ...) -> Bool {
    if let updater = updater, !updater.canCheckForUpdates { return false }
    guard latestUpdate != nil else { return true }  // ← bypasses rate limit
    if let lastCheck = lastUpdateCheckTime,
       Date().timeIntervalSince(lastCheck) < minimumInterval { return false }
    return true
}
```

**After:**
```swift
public func canStartNewCheck(updater: ..., minimumInterval: ...) -> Bool {
    guard !isCheckInProgress else { return false }
    if let updater = updater, !updater.canCheckForUpdates { return false }
    if let lastCheck = lastUpdateCheckTime,
       Date().timeIntervalSince(lastCheck) < minimumInterval { return false }
    return true
}
```

#### Add `isCheckInProgress` flag

```swift
private var isCheckInProgress = false
```

Checked first in `canStartNewCheck`. Ensures only one check runs at a time regardless of await suspension points.

#### Replace `recordCheckTime()` with `beginCheck()` / `endCheck()`

```swift
public func beginCheck() {
    isCheckInProgress = true
}

public func endCheck() {
    isCheckInProgress = false
    lastUpdateCheckTime = Date()
}
```

`endCheck()` atomically clears the in-flight flag and records check time. This replaces `recordCheckTime()`.

---

### `AppStoreUpdateController.performUpdateCheck` (2 changes)

**1. Call `beginCheck()` immediately after the gate passes:**

```swift
guard await updateCheckState.canStartNewCheck(updater: updaterChecker) else { return }
await updateCheckState.beginCheck()
```

**2. Call `endCheck()` in both paths:**

Success path — replace `await updateCheckState.recordCheckTime()`:
```swift
await updateCheckState.endCheck()
```

Error path — add at end of `catch` block:
```swift
await updateCheckState.endCheck()
```

---

### Call site update in `checkForUpdateSkippingRollout`

Remove the `latestUpdate:` argument:
```swift
// Before
guard await updateCheckState.canStartNewCheck(updater: updaterChecker, latestUpdate: latestUpdate, minimumInterval: 0) else { ... }

// After
guard await updateCheckState.canStartNewCheck(updater: updaterChecker, minimumInterval: 0) else { ... }
```

User-initiated checks pass with `minimumInterval: 0` (time check always passes), but are still blocked by `isCheckInProgress` if a check is already running — correct behaviour.

---

## Files changed

| File | Change |
|------|--------|
| `Sources/AppUpdaterShared/UpdateCheckState.swift` | Remove `latestUpdate` param, add `isCheckInProgress`, add `beginCheck()`/`endCheck()`, remove `recordCheckTime()` |
| `Sources/AppStoreAppUpdater/AppStoreUpdateController.swift` | Update two `canStartNewCheck` call sites, add `beginCheck()`, replace `recordCheckTime()` with `endCheck()`, add `endCheck()` in catch |
| `Tests/AppStoreAppUpdaterTests/` (existing tests) | Update `canStartNewCheck` call sites to remove `latestUpdate:` argument |

---

## Tests to add

- `canStartNewCheck` returns `false` while `isCheckInProgress` is `true`
- `canStartNewCheck` respects rate limiting when no update has ever been found (no `latestUpdate` bypass)
- `endCheck` clears `isCheckInProgress` and allows a subsequent check
- Error path calls `endCheck` (gate is reset after a failed CDN fetch)
