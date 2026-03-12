# macOS Lifecycle Methods → State Machine — Design Spec

## Goal

Move all setup logic from `applicationWillFinishLaunching` and `applicationDidFinishLaunching` into state machine handlers, making AppDelegate's lifecycle callbacks thin one-line dispatchers. This continues the Phase 2 migration by completing the state machine's responsibility for app initialization.

## Context

After Sub-project 1, dependency creation lives in `Launching.init()` and AppDelegate has ~90 forwarding properties. But `applicationWillFinishLaunching` (~50 lines) and `applicationDidFinishLaunching` (~140 lines) still contain substantial setup logic that should live in state handlers. The iOS app has already completed this migration — its AppDelegate lifecycle methods are single-line dispatchers.

## Revised Event Flow

### Current Flow
1. `AppDelegate.init()` → creates state machine, dispatches `.willFinishLaunching` + `.didFinishLaunching` → state is `.launching`
2. `applicationWillFinishLaunching` → ~50 lines of setup (reinstall detection, update controller, VPN handlers, UI swizzles)
3. `applicationDidFinishLaunching` → ~140 lines of setup (sync, bookmarks, history, web extensions, window opening, etc.)
4. `applicationDidBecomeActive` → dispatches `.didBecomeActive` → transitions Launching → Foreground

### New Flow
1. `AppDelegate.init()` → creates state machine with `Initializing()` (crash handlers + PixelKit now in `init()`), dispatches `.didFinishLaunching` → state is `.launching`
2. `applicationWillFinishLaunching` → dispatches `.willFinishLaunching` → `Launching.handleWillFinishLaunching()` runs ~50 lines
3. `applicationDidFinishLaunching` → dispatches `.appDidFinishLaunching` → transitions Launching → Foreground, `Foreground.onTransition()` runs ~140 lines
4. `applicationDidBecomeActive` → dispatches `.didBecomeActive` → `Foreground.didReturn()`

### Key Changes
- **`Initializing.handleWillFinishLaunching()`** is removed — its crash handler + PixelKit code moves to `Initializing.init()`
- **`AppDelegate.init()` changes:** Previously dispatched both `.willFinishLaunching` and `.didFinishLaunching`. Now dispatches only `.didFinishLaunching`. This is safe because crash handler + PixelKit setup moved to `Initializing.init()`, so no `.willFinishLaunching` handling is needed during `init()`.
- **`.willFinishLaunching` event** is repurposed: no longer handled by Initializing (no-op there), now handled by Launching
- **New `.appDidFinishLaunching` event** triggers Launching → Foreground transition (replacing `.didBecomeActive` for that role)
- **`.didBecomeActive`** no longer triggers a state transition; in Foreground it calls `didReturn()`
- **`applicationDidBecomeActive` body stays on AppDelegate.** Only the state machine dispatch (`appStateMachine.handle(.didBecomeActive)`) is added. The existing logic (quit survey pixel, daily pixels, autoconsent pixel, sync initialization, etc.) remains on AppDelegate — migrating it is out of scope.
- **`didFinishLaunching` flag** stays on AppDelegate, set in `applicationDidFinishLaunching` after the state machine dispatch. The `guard didFinishLaunching` check in `applicationDidBecomeActive` remains unchanged.

## State Machine Changes

### Events (AppStateMachine.Event)
```
Before:                          After:
- .willFinishLaunching           - .willFinishLaunching  (now handled by Launching)
- .didFinishLaunching            - .didFinishLaunching   (unchanged: Initializing → Launching)
- .didBecomeActive               - .appDidFinishLaunching (NEW: Launching → Foreground)
                                 - .didBecomeActive      (no longer transitions; calls didReturn)
```

### State Transitions
```
Before:                                    After:
Initializing --.willFinishLaunching-->     Initializing (no-op for .willFinishLaunching)
  stays Initializing, calls handler
Initializing --.didFinishLaunching-->      Initializing --.didFinishLaunching--> Launching (unchanged)
  Launching
Launching --.didBecomeActive-->            Launching --.willFinishLaunching--> stays Launching,
  Foreground (onTransition)                  calls handleWillFinishLaunching()
                                           Launching --.appDidFinishLaunching--> Foreground (onTransition)
                                           Foreground --.didBecomeActive--> calls didReturn()
```

### Protocol Changes

**InitializingHandling:**
```swift
// Before:
init()
mutating func handleWillFinishLaunching()
func makeLaunchingState() throws -> any LaunchingHandling

// After:
init()  // crash handlers + PixelKit setup move here
func makeLaunchingState() throws -> any LaunchingHandling
// handleWillFinishLaunching() removed from protocol
```

**LaunchingHandling:**
```swift
// Before:
func makeForegroundState() throws -> any ForegroundHandling

// After:
func handleWillFinishLaunching()  // NEW
func makeForegroundState() throws -> any ForegroundHandling
```

**ForegroundHandling** and **TerminatingHandling**: Unchanged.

## Launching.handleWillFinishLaunching()

Receives the code currently in `AppDelegate.applicationWillFinishLaunching`. All dependencies are already available via `self.dependencies`.

### Code that moves in:
1. **Startup profiler measurement** — wraps the method in `startupProfiler.startMeasuring(.appWillFinishLaunching)`
2. **Reinstall detection** — `DefaultReinstallUserDetection(keyValueStore:).checkForReinstallingUser()`
3. **User agent setup** — `APIRequest.Headers.setUserAgent(...)`
4. **State restoration manager creation** — `AppStateRestorationManager(...)`, stored into `dependencies.services.stateRestorationManager`
5. **Update controller initialization** — calls equivalent of `initializeUpdateController()`, stored into `dependencies.services.updateController`
6. **App icon changer** — `AppIconChanger(...)`, stored into `dependencies.services.appIconChanger`
7. **VPN event handling** — creates `VPNSubscriptionEventsHandler`, stored on Launching (not in AppDependencies — only used in `Foreground.onTransition()` to call `startMonitoring()`)
8. **Freemium DBP** — `dependencies.services.freemiumDBPFeature.subscribeToDependencyUpdates()`
9. **UI framework tweaks** — NSPopover swizzle, window tabbing disable, SwiftUI context menu fix

### Properties set during handleWillFinishLaunching:
- `dependencies.services.stateRestorationManager` (mutating through `var` sub-container)
- `dependencies.services.updateController` (mutating through `var` sub-container)
- `dependencies.services.appIconChanger` (mutating through `var` sub-container)
- `self.vpnSubscriptionEventHandler` (stored on Launching, not in AppDependencies)

### Private methods that move from AppDelegate to Launching:
- `initializeUpdateController()` — creates AppStore or Sparkle update controller

## Foreground.onTransition()

Receives the code currently in `AppDelegate.applicationDidFinishLaunching`. All dependencies available via `self.dependencies`.

### Code that moves in (in order):
1. **Guard for environment** — `guard AppVersion.runType.requiresEnvironment else { return }`
2. **`didFinishLaunching` flag** — `defer { didFinishLaunching = true }` (moves to AppDelegate or Foreground property)
3. **Startup profiler** — `measureSequence(initialStep: .appDidFinishLaunchingBeforeRestoration)`
4. **Subscription loading** — `await subscriptionManager.loadInitialData()`
5. **VPN app events** — create `VPNAppEventsHandler` locally (its dependencies — `pinningManager`, `subscriptionManager`, `featureFlagOverridesPublishingHandler` — are all in AppDependencies), then call `.applicationDidFinishLaunching()`
6. **Content loading** — history coordinator, HTTPS upgrade, bookmark manager
7. **Lottie config** — `LottieConfiguration.shared.renderingEngine = .mainThread`
8. **Configuration manager start** — `configurationManager.start()`
9. **First launch detection** — ATB check, set `firstLaunchDate`
10. **Web extensions setup** — calls equivalent of `setupWebExtensions()`
11. **VPN upsell visibility** — `vpnUpsellVisibilityManager.setup(...)`
12. **Variant cleanup & assignment** — `AtbAndVariantCleanup.cleanup()`, `DefaultVariantManager().assignVariantIfNeeded`
13. **Statistics loader** — `StatisticsLoader.shared.load()`
14. **Sync startup** — calls equivalent of `startupSync()`
15. **State restoration** — `stateRestorationManager.applicationDidFinishLaunching()`
16. **URL event handling** — `urlEventHandler.applicationDidFinishLaunching()`
17. **Auto-clear handler** — `setUpAutoClearHandler()` equivalent
18. **Bitwarden communication** — `bitwardenManager?.initCommunication()`
19. **Window opening** — conditional `WindowsManager.openNewWindow(...)`
20. **Grammar features** — `grammarFeaturesManager.manage()`
21. **Theme application** — `applyPreferredTheme()` equivalent
22. **Crash reporting** — `await crashReporting.start()`
23. **Notification subscriptions** — email, data import, internal user, update controller
24. **Failed compilations pixel** — `fireFailedCompilationsPixelIfNeeded()`
25. **UserDefaults cleanup** — `UserDefaultsWrapper<Any>.clearRemovedKeys()`
26. **VPN subscription event monitoring** — `vpnSubscriptionEventHandler?.startMonitoring()`
27. **Notification center delegate** — `UNUserNotificationCenter.current().delegate = self` (stays on AppDelegate)
28. **Data broker protection** — `DataBrokerProtectionAppEvents(...).applicationDidFinishLaunching()`
29. **TipKit** — `TipKitAppEventHandler(...).appDidFinishLaunching()`
30. **Autofill pixel reporter** — `setUpAutofillPixelReporter()` equivalent
31. **Passwords menu bar** — `setUpPasswordsMenuBarVisibility()` equivalent
32. **Remote messaging** — `remoteMessagingClient?.startRefreshingRemoteMessages()`
33. **Deprecated messaging cleanup** — `DefaultSurveyRemoteMessagingStorage.surveys().removeStoredMessagesIfNecessary()`
34. **Crash handlers pixel** — fire pixel if crashed during setup
35. **Freemium DBP polling** — `DefaultFreemiumDBPScanResultPolling(...).startPollingOrObserving()`
36. **Wide events** — `wideEventService.sendPendingEvents()`
37. **User churn** — `userChurnScheduler.start()`
38. **Memory monitor** — `memoryUsageMonitor.enableIfNeeded(...)`
39. **Automation server** — `startAutomationServerIfNeeded()` equivalent
40. **Launch pixel** — `PixelKit.fire(GeneralPixel.launch, ...)`

### Properties set during onTransition:

**On Foreground (new stored properties):**
- `vpnSubscriptionEventHandler` — passed from Launching
- `freemiumDBPScanResultPolling`
- `automationServer`
- `webExtensionManager`, `webExtensionFeatureFlagHandler`, `darkReaderFeatureSettings`, `darkReaderCancellables`
- `autofillPixelReporter`, `passwordsStatusBarMenu`, `passwordsMenuBarCancellable`
- `aiChatSyncCleaner`
- Cancellables: `emailCancellables`, `isInternalUserSharingCancellable`, `isSyncInProgressCancellable`, `syncFeatureFlagsCancellable`, `screenLockedCancellable`, `updateProgressCancellable`

**On dependencies (mutating through var sub-containers):**
- `dependencies.services.syncService`
- `dependencies.services.syncDataProviders`
- `dependencies.services.autoClearHandler`

### Private methods that move from AppDelegate to Foreground:
- `setupWebExtensions()` + `initializeWebExtensions()` + `syncEmbeddedExtensions()`
- `startupSync()` + `subscribeToSyncFeatureFlags()` + `subscribeSyncQueueToScreenLockedNotifications()`
- `setUpAutoClearHandler()`
- `setUpAutofillPixelReporter()`
- `setUpPasswordsMenuBarVisibility()`
- `subscribeToEmailProtectionStatusNotifications()`
- `subscribeToDataImportCompleteNotification()`
- `subscribeToInternalUserChanges()`
- `subscribeToUpdateControllerChanges()`
- `startAutomationServerIfNeeded()`
- `applyPreferredTheme()`
- `fireFailedCompilationsPixelIfNeeded()`

### Items that stay on AppDelegate:
- `UNUserNotificationCenter.current().delegate = self` — must be AppDelegate
- `didFinishLaunching` flag — AppDelegate-level flag used by other AppDelegate methods
- Lazy properties that are AppDelegate-level UI coordinators (newTabPageCoordinator, autoconsentStatsPopoverCoordinator, etc.) — out of scope

## Launching → Foreground Transition

`Launching` needs to pass some state to `Foreground` beyond just `AppDependencies`:
- `vpnSubscriptionEventHandler` (created in `handleWillFinishLaunching()`, used in `onTransition()` to call `startMonitoring()`)

This can be handled by adding `vpnSubscriptionEventHandler` as an optional property on `AppDependencies.Services` or by passing it through `makeForegroundState()`. The simpler approach: store it on Launching and pass via `makeForegroundState()` → `Foreground.init(dependencies:, vpnSubscriptionEventHandler:)`.

Alternatively, `vpnSubscriptionEventHandler` could be created in `Foreground.onTransition()` directly since it's only used there. The VPN objects it depends on (pinningManager, vpnXPCClient, subscriptionManager) are all in AppDependencies.

**Recommendation:** Create `vpnSubscriptionEventHandler` in `Foreground.onTransition()` to avoid cross-state passing.

## AppDelegate After This Work

```swift
init(dockCustomization: DockCustomization?) {
    // ... existing setup ...
    super.init()
    // Only dispatch .didFinishLaunching (not .willFinishLaunching — that's now for Launching)
    appStateMachine = AppStateMachine(initialState: .initializing(Initializing()))
    appStateMachine.handle(.didFinishLaunching)
    // Extract dependencies as before
    if case .launching(let launching) = appStateMachine.currentState,
       let concreteState = launching as? Launching {
        appDependencies = concreteState.dependencies
    } else {
        fatalError("Expected .launching state after didFinishLaunching")
    }
    (privacyFeatures.contentBlocking as? AppContentBlocking)?.userContentUpdating.userScriptDependenciesProvider = self
}

func applicationWillFinishLaunching(_ notification: Notification) {
    appStateMachine.handle(.willFinishLaunching)
}

func applicationDidFinishLaunching(_ notification: Notification) {
    appStateMachine.handle(.appDidFinishLaunching)
    didFinishLaunching = true
    // Wire AppDelegate as UNUserNotificationCenter delegate
    UNUserNotificationCenter.current().delegate = self
}

func applicationDidBecomeActive(_ notification: Notification) {
    // Existing body stays — only add state machine dispatch
    guard didFinishLaunching else { return }
    appStateMachine.handle(.didBecomeActive)
    // ... existing applicationDidBecomeActive logic remains here ...
}
```

## Initializing Changes

`Initializing.init()` absorbs the crash handler and PixelKit setup currently in `handleWillFinishLaunching()`:

```swift
@MainActor
struct Initializing: InitializingHandling {
    init() {
        let didCrashDuringCrashHandlersSetUp = UserDefaultsWrapper(key: .didCrashDuringCrashHandlersSetUp, defaultValue: false)
        if case .normal = AppVersion.runType,
           !didCrashDuringCrashHandlersSetUp.wrappedValue {
            didCrashDuringCrashHandlersSetUp.wrappedValue = true
            CrashLogMessageExtractor.setUp(swapCxaThrow: false)
            didCrashDuringCrashHandlersSetUp.wrappedValue = false
        }
        if AppVersion.runType.requiresEnvironment {
            AppDelegate.configurePixelKit()
        }
    }

    func makeLaunchingState() throws -> any LaunchingHandling {
        try Launching()
    }
}
```

`handleWillFinishLaunching()` is removed from `InitializingHandling` protocol.

## Testing

- **State machine tests:** Update mock types — `MockInitializing` removes `handleWillFinishLaunching()`, `MockLaunching` adds `handleWillFinishLaunching()`. Transition tests updated: `.appDidFinishLaunching` now transitions Launching → Foreground instead of `.didBecomeActive`.
- **Existing test count:** Tests for state machine transitions, termination deciders remain. New tests added for the new event and transition.
- **Integration risk:** The `Foreground.onTransition()` code creates real services (sync, web extensions, etc.). These are not unit-testable without protocol injection. This matches the current state — the code was already untestable in `applicationDidFinishLaunching`. No regression.

## Out of Scope

- Removing forwarding properties from AppDelegate / migrating call sites
- Moving lazy UI coordinators off AppDelegate
- Making `Foreground.onTransition()` code unit-testable via protocol injection
- Migrating `applicationDidBecomeActive` logic beyond `didReturn()` dispatch (currently minimal)
