# Feature Flag Guide

This guide covers how feature flags work in DuckDuckGo's iOS and macOS apps, how they connect to the remote privacy configuration, and the patterns to follow when adding or reviewing them.

For the cross-platform overview of feature flagging and the remote config system, see the [Feature Flagging Guide](https://github.com/duckduckgo/privacy-configuration/blob/main/docs/feature-flagging-guide.md) in the privacy-configuration repo.

## Architecture

Feature flagging uses two layers:

1. **Remote privacy configuration** -- JSON config files served per-platform (`ios-config.json`, `macos-config.json`) that define feature/sub-feature states, rollouts, targets, and cohorts.
2. **Client-side `FeatureFlag` enum** -- each app declares its own enum conforming to `FeatureFlagDescribing`. Each case maps (optionally) to a remote config feature or sub-feature.

The `DefaultFeatureFlagger` resolves the flag value at runtime by checking local overrides (internal users only), then the `source`, and finally falling back to `defaultValue`.

## The `FeatureFlagDescribing` Protocol

Every flag must implement four properties:

### `defaultValue: Bool`

The fallback used when remote config is unavailable or the flag has no remote state.

```swift
public var defaultValue: Bool {
    switch self {
    case .canScanUrlBasedSyncSetupBarcodes,
         .syncCreditCards,
         .tabSwitcherTrackerCount:
        true
    default:
        false
    }
}
```

Flags that should default to `true` (failsafe) are listed explicitly in a `case` group. All others fall through to `default: false`.

See [Choosing a default value](#choosing-a-default-value) for guidance on which to pick.

### `source: FeatureFlagSource`

Determines where the flag value comes from:

```swift
public var source: FeatureFlagSource {
    switch self {
    case .sync:
        return .remoteReleasable(.subfeature(SyncSubfeature.level0ShowSync))
    case .autofillCreditCards:
        return .remoteReleasable(.subfeature(AutofillSubfeature.autofillCreditCards))
    case .duckPlayerNativeUI:
        return .internalOnly()
    case .someFutureFeature:
        return .disabled
    }
}
```

| Source | Behaviour |
|---|---|
| `.remoteReleasable(.subfeature(...))` | Controlled by a remote config **sub-feature**. Supports rollouts, targets, and cohorts. **Use this for most flags.** |
| `.remoteReleasable(.feature(...))` | Controlled by a **top-level** remote config feature. **Avoid -- see warning below.** |
| `.remoteDevelopment(...)` | Same as `remoteReleasable` but only for internal users. External users always see `false`. |
| `.internalOnly()` | Always `true` for internal users, `false` for everyone else. No remote control. |
| `.disabled` | Always `false`. Placeholder for future work. |

> **Avoid `.remoteReleasable(.feature(...))`.**
>
> Mapping a client flag to a top-level parent feature means the flag **cannot use rollouts, targets, or cohorts** -- those are only supported on sub-features. This has caused incidents where engineers expected progressive rollout to work and it silently had no effect.
>
> Always prefer `.remoteReleasable(.subfeature(...))`. If no suitable sub-feature exists, add one to the relevant `PrivacyFeature` in `PrivacyFeature.swift`. Platform-generic flags should go under `iOSBrowserConfigSubfeature` or `MacOSBrowserConfigSubfeature`; domain-specific flags under their parent (e.g., `AIChatSubfeature`, `SyncSubfeature`).

### `supportsLocalOverriding: Bool`

Controls whether internal users can toggle the flag in the debug menu. Most flags list themselves in the `true` group explicitly; flags that should not be overridden (e.g., production pixels/metrics or security-critical paths) go in the `false` group:

```swift
public var supportsLocalOverriding: Bool {
    switch self {
    case .scamSiteProtection,
         .maliciousSiteProtection,
         .paidAIChat,
         // ... most flags return true ...
         .webExtensions:
        return true
    case .sync,
         .autofillCredentialInjecting,
         // ... flags that should not be overridden ...
         .crashReportOptInStatusResetting:
        return false
    }
}
```

### `cohortType: (any FeatureFlagCohortDescribing.Type)?`

Optional A/B test cohort type. Return `nil` if the flag does not have cohorts:

```swift
public var cohortType: (any FeatureFlagCohortDescribing.Type)? {
    switch self {
    case .someExperiment:
        SomeExperimentCohort.self
    default:
        nil
    }
}
```

## Choosing a Default Value

The `defaultValue` is the fallback when remote config is unreachable or the flag has no remote state.

### `false` (opt-in)

Use for **new or experimental** features that should not activate without an explicit remote config push:

- Feature stays off until you deliberately enable it remotely.
- If the config endpoint is down, no untested code path runs.
- Appropriate for anything that hasn't been fully validated in production.

### `true` (failsafe / kill-switch)

Use for **stable or already-shipping** features where you want the ability to disable remotely if problems arise:

- Users get the expected behaviour even if remote config fails.
- You retain a remote kill-switch without needing an app update.
- Appropriate when migrating existing always-on behaviour behind a flag, or for features that are ready to ship and only need a safety net.

For more on this pattern, see [Using failsafe feature flags](https://app.asana.com/0/0/1209498782498498/f).

## Checking a Flag at Runtime

```swift
// Simple boolean check
if featureFlagger.isFeatureOn(.yourFeatureName) {
    // feature-specific code
}

// With dependency injection
final class MyViewController {
    private let featureFlagger: FeatureFlagger

    init(featureFlagger: FeatureFlagger) {
        self.featureFlagger = featureFlagger
    }

    func setupUI() {
        if featureFlagger.isFeatureOn(.yourFeatureName) {
            setupNewUI()
        }
    }
}

// Resolving an experiment cohort
if let cohort = featureFlagger.resolveCohort(for: .someExperiment) as? SomeExperimentCohort {
    switch cohort {
    case .control:
        // control path
    case .treatment:
        // treatment path
    }
}
```

## File Locations

| What | Path |
|---|---|
| iOS feature flags | `iOS/Core/FeatureFlag.swift` |
| macOS feature flags | `macOS/LocalPackages/FeatureFlags/Sources/FeatureFlags/FeatureFlag.swift` |
| macOS flag categories | `macOS/LocalPackages/FeatureFlags/Sources/FeatureFlags/FeatureFlagCategory.swift` |
| PrivacyFeature / subfeature enums | `SharedPackages/BrowserServicesKit/Sources/PrivacyConfig/Features/PrivacyFeature.swift` |
| FeatureFlagger protocol & impl | `SharedPackages/BrowserServicesKit/Sources/PrivacyConfig/FeatureFlagger/FeatureFlagger.swift` |
| Local overrides | `SharedPackages/BrowserServicesKit/Sources/PrivacyConfig/FeatureFlagger/FeatureFlagLocalOverrides.swift` |
| Cursor rule for adding flags | `.cursor/rules/feature-flags-addition.mdc` |

## Adding a New Flag -- Checklist

1. Create an Asana task in the **Apple Feature Flags Registry**.
2. Add the `case` to the `FeatureFlag` enum (iOS and/or macOS) with an Asana link comment.
3. Set `defaultValue` -- add to the `true` group if failsafe; otherwise it falls through to `false`.
4. Set `source` -- use `.remoteReleasable(.subfeature(...))` in almost all cases.
5. Set `supportsLocalOverriding` -- `true` unless there is a specific reason not to.
6. If using a remote source, add the sub-feature case to the appropriate `PrivacySubfeature` enum in `PrivacyFeature.swift`.
7. If macOS, consider adding the flag to a category in `FeatureFlagCategory.swift`.
8. Coordinate with the privacy-configuration repo to ensure the sub-feature exists in the config.
9. Test both states via the debug menu.

## Related Documentation

- [Feature Flagging Guide (cross-platform)](https://github.com/duckduckgo/privacy-configuration/blob/main/docs/feature-flagging-guide.md)
- [Using failsafe feature flags](https://app.asana.com/0/0/1209498782498498/f)
- [Incremental Rollout Implementation Guide](https://github.com/duckduckgo/privacy-configuration/blob/main/docs/incremental-rollout-implementation-guide.md)
