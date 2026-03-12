# Phase 3: Integrate TerminationDeciderHandler into AppStateMachine

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move termination decision logic from AppDelegate into the Foreground state handler, wiring `applicationShouldTerminate` through the state machine.

**Architecture:** Foreground owns the `TerminationDeciderHandler` and `createTerminationDeciders()`. The state machine gains a `confirmTermination()` method for async termination completion. AppDelegate's `applicationShouldTerminate` delegates entirely to the state machine.

**Tech Stack:** Swift, AppKit, Swift Testing

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `macOS/DuckDuckGo/Application/AppLifecycle/AppStateMachine.swift` | Modify | Add `confirmTermination()`, update `ForegroundHandling` protocol |
| `macOS/DuckDuckGo/Application/AppLifecycle/AppStates/Foreground.swift` | Modify | Own termination handler, decider creation, execute chain |
| `macOS/DuckDuckGo/Application/AppDelegate.swift` | Modify | Wire `applicationShouldTerminate` to state machine, remove termination logic, widen `autoClearHandler` access |
| `macOS/UnitTests/AppLifecycle/AppStateMachineTests.swift` | Modify | Update MockForeground, add async termination tests |

## Chunk 1: State Machine and Protocol Changes

### Task 1: Update ForegroundHandling protocol

The `handleTerminationRequest()` method needs an `onAsyncTerminationApproved` closure so the state machine can transition to `.terminating` when an async decider chain completes with approval.

**Files:**
- Modify: `macOS/DuckDuckGo/Application/AppLifecycle/AppStateMachine.swift:78-84`

- [ ] **Step 1: Update ForegroundHandling protocol**

Change `handleTerminationRequest()` to accept an async completion closure:

```swift
@MainActor
protocol ForegroundHandling {

    func onTransition()
    func didReturn()
    func handleTerminationRequest(onAsyncTerminationApproved: @escaping @MainActor () -> Void) -> NSApplication.TerminateReply

}
```

- [ ] **Step 2: Update `AppStateMachine.handleTerminationRequest()` to pass closure**

Update the method at line 147-159 to pass a closure that transitions to terminating:

```swift
func handleTerminationRequest() -> NSApplication.TerminateReply {
    guard case .foreground(let foreground) = currentState else {
        Logger.general.error("Termination request received in unexpected state: \(self.currentState.name)")
        return .terminateCancel
    }
    let reply = foreground.handleTerminationRequest(onAsyncTerminationApproved: { [weak self] in
        self?.confirmTermination()
    })
    if reply == .terminateNow {
        let terminating = terminatingStateFactory.makeTerminatingState()
        terminating.terminate()
        currentState = .terminating(terminating)
    }
    return reply
}
```

- [ ] **Step 3: Add `confirmTermination()` method**

Add after `handleTerminationRequest()`:

```swift
private func confirmTermination() {
    guard case .foreground = currentState else {
        Logger.general.error("Async termination confirmation received in unexpected state: \(self.currentState.name)")
        return
    }
    let terminating = terminatingStateFactory.makeTerminatingState()
    terminating.terminate()
    currentState = .terminating(terminating)
}
```

- [ ] **Step 4: Verify it compiles (will fail until Foreground is updated)**

Expected: Compiler error in `Foreground.swift` because `handleTerminationRequest` signature changed. This is expected and fixed in Task 2.

### Task 2: Move termination logic into Foreground

**Files:**
- Modify: `macOS/DuckDuckGo/Application/AppLifecycle/AppStates/Foreground.swift`

- [ ] **Step 1: Update Foreground to implement the new protocol signature**

Replace the current `handleTerminationRequest` with the full termination chain logic. Foreground needs to:
- Own a `terminationHandler` property
- Create the decider chain from AppDelegate's properties
- Execute the chain and handle sync/async results

```swift
import AppKit
import PixelKit

@MainActor
struct Foreground: ForegroundHandling {

    private weak var appDelegate: AppDelegate?
    private var terminationHandler: TerminationDeciderHandler?

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
    }

    func onTransition() {
        // Phase 1: AppDelegate.applicationDidBecomeActive still runs its own logic.
        // In Phase 2, that logic moves here.
    }

    func didReturn() {
        // Called on subsequent didBecomeActive while already in foreground.
        // Phase 1: no-op (AppDelegate handles this via its didFinishLaunching guard).
    }

    mutating func handleTerminationRequest(onAsyncTerminationApproved: @escaping @MainActor () -> Void) -> NSApplication.TerminateReply {
        // Already processing an async termination — defer to in-flight handler
        if terminationHandler != nil {
            return .terminateLater
        }

        let handler = TerminationDeciderHandler(
            deciders: createTerminationDeciders(),
            replyToApplicationShouldTerminate: { [self] shouldTerminate in
                var mutableSelf = self
                mutableSelf.terminationHandler = nil
                if shouldTerminate {
                    onAsyncTerminationApproved()
                }
                NSApp.reply(toApplicationShouldTerminate: shouldTerminate)
            }
        )
        terminationHandler = handler
        let reply = handler.executeTerminationDeciders()

        if reply == .terminateCancel {
            terminationHandler = nil
        }
        return reply
    }

}
```

**IMPORTANT:** `Foreground` is a struct with a `mutating` method but `ForegroundHandling` currently uses non-mutating methods. Since this method needs to mutate `terminationHandler`, we have two options:
- (A) Change `Foreground` to a `class`
- (B) Change `ForegroundHandling.handleTerminationRequest` to `mutating`

Option A is simpler and avoids value-type copy issues with the `terminationHandler` reference. **Use option A: change Foreground to a class.**

```swift
@MainActor
final class Foreground: ForegroundHandling {

    private weak var appDelegate: AppDelegate?
    private var terminationHandler: TerminationDeciderHandler?

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
    }

    // ... (methods as above, without `mutating`)
}
```

- [ ] **Step 2: Add `createTerminationDeciders()` to Foreground**

Add the method that builds the decider chain, accessing AppDelegate properties:

```swift
private func createTerminationDeciders() -> [ApplicationTerminationDecider] {
    guard let appDelegate else { return [] }

    let persistor = QuitSurveyUserDefaultsPersistor(keyValueStore: appDelegate.keyValueStore)

    let deciders: [ApplicationTerminationDecider?] = [
        QuitSurveyAppTerminationDecider(
            featureFlagger: appDelegate.featureFlagger,
            dataClearingPreferences: appDelegate.dataClearingPreferences,
            downloadManager: appDelegate.downloadManager,
            installDate: AppDelegate.firstLaunchDate,
            persistor: persistor,
            reinstallUserDetection: DefaultReinstallUserDetection(keyValueStore: appDelegate.keyValueStore),
            showQuitSurvey: { [weak appDelegate] in
                guard let appDelegate else { return }
                let presenter = QuitSurveyPresenter(
                    windowControllersManager: appDelegate.windowControllersManager,
                    persistor: persistor
                )
                await presenter.showSurvey()
            }
        ),

        ActiveDownloadsAppTerminationDecider(
            downloadManager: appDelegate.downloadManager,
            downloadListCoordinator: appDelegate.downloadListCoordinator
        ),

        makeWarnBeforeQuitDecider(),

        .perform { [weak appDelegate] in
            appDelegate?.updateController?.handleAppTermination()
        },

        .perform { [weak appDelegate] in
            appDelegate?.stateRestorationManager?.applicationWillTerminate()
        },

        appDelegate.autoClearHandler,

        .terminationDecider { [weak appDelegate] _ in
            guard let appDelegate else { return .sync(.next) }
            return .async(Task {
                await appDelegate.privacyStats.handleAppTermination()
                return .next
            })
        },

        .perform {
            NSApp.visibleWindows.forEach { $0.close() }
        }
    ]

    return deciders.compactMap { $0 }
}
```

- [ ] **Step 3: Add `makeWarnBeforeQuitDecider()` to Foreground**

Move this helper from AppDelegate:

```swift
private func makeWarnBeforeQuitDecider() -> ApplicationTerminationDecider? {
    guard let appDelegate else { return nil }

    let willShowAutoClearWarning = appDelegate.dataClearingPreferences.isAutoClearEnabled
        && appDelegate.dataClearingPreferences.isWarnBeforeClearingEnabled

    let hasWindow = appDelegate.windowControllersManager.lastKeyMainWindowController?.window != nil

    guard appDelegate.featureFlagger.isFeatureOn(.warnBeforeQuit),
          !willShowAutoClearWarning,
          hasWindow,
          let currentEvent = NSApp.currentEvent else { return nil }

    guard let manager = WarnBeforeQuitManager(
        currentEvent: currentEvent,
        action: .quit,
        isWarningEnabled: { [weak appDelegate] in
            appDelegate?.tabsPreferences.warnBeforeQuitting ?? false
        },
        isPhysicalKeyPress: WarnBeforeQuitManager.makePhysicalKeyPressCheck(for: currentEvent)
    ) else { return nil }

    let presenter = WarnBeforeQuitOverlayPresenter(
        startupPreferences: appDelegate.startupPreferences,
        buttonHandlers: [.dontShowAgain: { [weak appDelegate] in
            PixelKit.fire(GeneralPixel.warnBeforeQuitDontShowAgain, frequency: .standard)
            appDelegate?.tabsPreferences.warnBeforeQuitting = false
        }],
        onHoverChange: { [weak manager] isHovering in
            manager?.setMouseHovering(isHovering)
        }
    )

    presenter.subscribe(to: manager.stateStream)
    return manager
}
```

- [ ] **Step 4: Build and verify compilation**

Run: Build via Xcode MCP or `xcodebuild`
Expected: Compilation succeeds (may need access control fixes — see Task 3)

### Task 3: Widen access control on AppDelegate properties

**Files:**
- Modify: `macOS/DuckDuckGo/Application/AppDelegate.swift`

- [ ] **Step 1: Change `autoClearHandler` from `private` to `private(set)`**

At line 110:
```swift
// Before:
private var autoClearHandler: AutoClearHandler!
// After:
private(set) var autoClearHandler: AutoClearHandler!
```

This allows Foreground to read it (same module) while preventing external mutation.

- [ ] **Step 2: Check if `makeWarnBeforeQuitDecider` references anything else private**

Verify all properties used by `createTerminationDeciders()` and `makeWarnBeforeQuitDecider()` are at least `internal`. From investigation:
- `keyValueStore` — internal (OK)
- `featureFlagger` — internal (OK)
- `dataClearingPreferences` — internal (OK)
- `downloadManager` — internal (OK)
- `downloadListCoordinator` — internal (OK)
- `windowControllersManager` — internal (OK)
- `updateController` — internal (OK)
- `stateRestorationManager` — `private(set)` getter is internal (OK)
- `privacyStats` — internal (OK)
- `tabsPreferences` — internal (OK)
- `startupPreferences` — internal (OK)
- `autoClearHandler` — **private** (needs change above)

- [ ] **Step 3: Build and verify**

Run: Build via Xcode MCP
Expected: BUILD SUCCEEDED

## Chunk 2: Wire AppDelegate and Update Tests

### Task 4: Wire `applicationShouldTerminate` to state machine

**Files:**
- Modify: `macOS/DuckDuckGo/Application/AppDelegate.swift`

- [ ] **Step 1: Replace `applicationShouldTerminate` body**

Replace lines 1509-1530 with delegation to the state machine:

```swift
func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    return appStateMachine.handleTerminationRequest()
}
```

- [ ] **Step 2: Remove `terminationHandler` property from AppDelegate**

Delete line 1507:
```swift
private var terminationHandler: TerminationDeciderHandler?
```

- [ ] **Step 3: Remove `createTerminationDeciders()` from AppDelegate**

Delete the entire method (lines 1533-1589).

- [ ] **Step 4: Remove `makeWarnBeforeQuitDecider()` from AppDelegate**

Delete the entire method (lines 1591-1627).

- [ ] **Step 5: Build and verify**

Run: Build via Xcode MCP
Expected: BUILD SUCCEEDED

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "Phase 3: Move termination logic from AppDelegate to Foreground state handler"
```

### Task 5: Update tests

**Files:**
- Modify: `macOS/UnitTests/AppLifecycle/AppStateMachineTests.swift`

- [ ] **Step 1: Update MockForeground to match new protocol**

```swift
@MainActor
final class MockForeground: ForegroundHandling {

    private(set) var eventLog: [String] = []
    var terminationReply: NSApplication.TerminateReply = .terminateNow
    private(set) var lastAsyncTerminationClosure: (@MainActor () -> Void)?

    var onTransitionCalled: Bool { eventLog.contains("onTransition") }
    var didReturnCalled: Bool { eventLog.contains("didReturn") }

    func onTransition() { eventLog.append("onTransition") }
    func didReturn() { eventLog.append("didReturn") }

    func handleTerminationRequest(onAsyncTerminationApproved: @escaping @MainActor () -> Void) -> NSApplication.TerminateReply {
        eventLog.append("handleTerminationRequest")
        lastAsyncTerminationClosure = onAsyncTerminationApproved
        return terminationReply
    }

}
```

- [ ] **Step 2: Add test for async termination confirmation**

Add to `ForegroundTests`:

```swift
@Test("terminateLater followed by async confirmation should transition to terminating")
func asyncTerminationConfirmed() {
    if case .foreground(let foreground) = stateMachine.currentState,
       let mock = foreground as? MockForeground {
        mock.terminationReply = .terminateLater
    }
    let reply = stateMachine.handleTerminationRequest()
    #expect(reply == .terminateLater)
    #expect(stateMachine.currentState.name == "foreground")

    // Simulate async decider chain completing with approval
    if case .foreground(let foreground) = stateMachine.currentState,
       let mock = foreground as? MockForeground {
        mock.lastAsyncTerminationClosure?()
    }
    #expect(stateMachine.currentState.name == "terminating")
}
```

- [ ] **Step 3: Add test for async confirmation in wrong state**

Add to `TerminatingTests` or a new suite:

```swift
@Test("confirmTermination while already terminating is ignored")
func asyncConfirmationInTerminatingIgnored() {
    // State machine starts in terminating
    #expect(stateMachine.currentState.name == "terminating")
    // confirmTermination is private, so we test indirectly:
    // a second handleTerminationRequest should return terminateCancel
    let reply = stateMachine.handleTerminationRequest()
    #expect(reply == .terminateCancel)
    #expect(stateMachine.currentState.name == "terminating")
}
```

- [ ] **Step 4: Run all AppStateMachine tests**

Run: via Xcode MCP RunSomeTests
Expected: All tests pass (existing 18 + new tests)

- [ ] **Step 5: Commit**

```bash
git add macOS/UnitTests/AppLifecycle/AppStateMachineTests.swift
git commit -m "Update tests for Phase 3 termination handling"
```

### Task 6: Build and run app for smoke test

- [ ] **Step 1: Build and run the app**

Verify the app launches normally and Cmd+Q triggers proper termination flow.

- [ ] **Step 2: Verify no regressions in existing termination tests**

Run: `TerminationDeciderHandlerTests` via Xcode MCP
Expected: All existing tests pass — these test the handler in isolation and should be unaffected.
