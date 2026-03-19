# User Scripts Debug Menu Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a Debug → User Scripts → Disable Individual Scripts submenu that lets developers disable specific user scripts per-tab or globally (session-only) to isolate which script causes a website issue.

**Architecture:** A `UserScriptDisabledStore` singleton holds globally-disabled script names. Each `UserScripts` instance (one per tab) holds per-tab disabled names. `loadWKUserScripts()` filters both sets before building WKUserScript objects. `UserContentController` gets a new `reinstallUserScripts()` method to apply the updated filter without a full config reload. `UserScriptsDebugMenu` (NSMenu + NSMenuDelegate) rebuilds on open and toggles the appropriate store, then reinstalls + reloads.

**Tech Stack:** Swift, AppKit (NSMenu/NSMenuDelegate), BrowserServicesKit (local package at `SharedPackages/BrowserServicesKit/`), WKWebView user content controller.

---

### Context for the implementer

- User scripts live in `macOS/DuckDuckGo/Tab/UserScripts/UserScripts.swift`. The `userScripts: [UserScript]` array (lazy var, appended in `init`) is what gets injected into pages. `loadWKUserScripts()` converts it to `[WKUserScript]` asynchronously.
- `UserContentController` is in `SharedPackages/BrowserServicesKit/Sources/BrowserServicesKit/ContentScopeScript/UserContentController.swift`. Its `contentBlockingAssets` willSet calls private `installUserScripts(_:handlers:)` which removes all scripts and reinstalls them.
- The debug menu pattern used in this repo: `final class XyzDebugMenu: NSMenu, NSMenuDelegate` with `menuNeedsUpdate(_:)` rebuilding items dynamically. See `ContentScopeExperimentsMenu.swift` and `UpdatesDebugMenu.swift` for reference.
- Active tab access: `Application.appDelegate.windowControllersManager.selectedTab`
- All tabs: `Application.appDelegate.windowControllersManager.mainWindowControllers.flatMap { $0.mainViewController.tabCollectionViewModel.tabCollection.tabs }`
- Existing "User Scripts" entry in the debug menu is at `setupDebugMenu` in `MainMenu.swift` — currently contains one item: "Remove user scripts from selected tab".

---

### Task 1: `UserScriptDisabledStore` singleton

**Files:**
- Create: `macOS/DuckDuckGo/Debug/UserScriptDisabledStore.swift`

**Step 1: Create the file**

```swift
//
//  UserScriptDisabledStore.swift
//
//  Copyright © 2025 DuckDuckGo. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

import Foundation

/// Session-only store for globally disabled user script names.
/// Reset to empty on every app launch (no persistence).
@MainActor
final class UserScriptDisabledStore {
    static let shared = UserScriptDisabledStore()
    private init() {}

    var globallyDisabled: Set<String> = []
}
```

**Step 2: Add to Xcode project**

Open `macOS/DuckDuckGo-macOS.xcodeproj`, add `UserScriptDisabledStore.swift` to the `Debug` group (create the group if it doesn't exist) in the main app target. Alternatively, edit `project.pbxproj` directly following the same pattern as other files in `macOS/DuckDuckGo/Debug/` or `macOS/DuckDuckGo/Menus/`.

**Step 3: Commit**

```bash
git add macOS/DuckDuckGo/Debug/UserScriptDisabledStore.swift macOS/DuckDuckGo-macOS.xcodeproj/project.pbxproj
git commit -m "feat: add UserScriptDisabledStore session-only singleton"
```

---

### Task 2: Filter disabled scripts in `UserScripts`

**Files:**
- Modify: `macOS/DuckDuckGo/Tab/UserScripts/UserScripts.swift`

**Step 1: Add `perTabDisabled` property**

After the `private let contentScopePreferences: ContentScopePreferences` line (line 63), add:

```swift
/// Script class names disabled for this tab only. Session-only; cleared when the tab closes.
var perTabDisabled: Set<String> = []
```

**Step 2: Filter in `loadWKUserScripts()`**

Replace the current `loadWKUserScripts()` implementation (lines 273–287) with:

```swift
@MainActor
func loadWKUserScripts() async -> [WKUserScript] {
    let disabled = perTabDisabled.union(UserScriptDisabledStore.shared.globallyDisabled)
    return await withTaskGroup(of: WKUserScriptBox.self) { @MainActor group in
        var wkUserScripts = [WKUserScript]()
        userScripts
            .filter { !disabled.contains(String(describing: type(of: $0))) }
            .forEach { userScript in
                group.addTask { @MainActor in
                    await userScript.makeWKUserScript()
                }
            }
        for await result in group {
            wkUserScripts.append(result.wkUserScript)
        }
        return wkUserScripts
    }
}
```

The only change is the `.filter` before `.forEach`. Scripts are identified by their class name, e.g. `"ClickToLoadUserScript"`, `"ContentScopeUserScript"`.

**Step 3: Build to verify**

In Xcode, build the macOS target (`Cmd+B`). Expected: builds cleanly with no errors.

**Step 4: Commit**

```bash
git add macOS/DuckDuckGo/Tab/UserScripts/UserScripts.swift
git commit -m "feat: filter disabled scripts in UserScripts.loadWKUserScripts()"
```

---

### Task 3: Add `reinstallUserScripts()` to `UserContentController`

**Files:**
- Modify: `SharedPackages/BrowserServicesKit/Sources/BrowserServicesKit/ContentScopeScript/UserContentController.swift`

**Context:** `installUserScripts(_:handlers:)` is currently `private` at line 251. We need a public async method that re-runs it using the current `contentBlockingAssets`. Because the new method is on the same class, it can call the private method directly — no access change needed.

**Step 1: Add the public method**

After the closing brace of `installContentBlockingAssets(_:)` (around line 119), add:

```swift
/// Reinstalls user scripts from the current content blocking assets,
/// applying any active per-tab or global disable filters.
/// Call this after modifying `UserScripts.perTabDisabled` or `UserScriptDisabledStore`.
@MainActor
public func reinstallUserScripts() async {
    guard let assets = contentBlockingAssets else { return }
    let wkUserScripts = await assets.userScripts.loadWKUserScripts()
    installUserScripts(wkUserScripts, handlers: assets.userScripts.userScripts)
}
```

**Step 2: Build to verify**

Build the macOS target (`Cmd+B`). Expected: builds cleanly.

**Step 3: Commit**

```bash
git add SharedPackages/BrowserServicesKit/Sources/BrowserServicesKit/ContentScopeScript/UserContentController.swift
git commit -m "feat: add reinstallUserScripts() to UserContentController"
```

---

### Task 4: Build `UserScriptsDebugMenu`

**Files:**
- Create: `macOS/DuckDuckGo/Debug/UserScriptsDebugMenu.swift`

**Step 1: Create the file**

```swift
//
//  UserScriptsDebugMenu.swift
//
//  Copyright © 2025 DuckDuckGo. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

import AppKit

/// Debug submenu for disabling individual user scripts per-tab or globally.
/// Changes are session-only — disabled state resets when the app quits.
@MainActor
final class UserScriptsDebugMenu: NSMenu, NSMenuDelegate {

    init() {
        super.init(title: "Disable Individual Scripts")
        self.delegate = self
        self.autoenablesItems = false
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    // MARK: - Menu Building

    private func rebuildMenu() {
        removeAllItems()

        let scriptNames = currentTabScriptNames()

        if scriptNames.isEmpty {
            let item = NSMenuItem(title: "No scripts loaded", action: nil, keyEquivalent: "")
            item.isEnabled = false
            addItem(item)
            return
        }

        addSectionHeader("[Current Tab]")
        for name in scriptNames {
            let item = makeScriptItem(name: name,
                                      action: #selector(togglePerTab(_:)),
                                      isDisabled: currentTabUserScripts()?.perTabDisabled.contains(name) ?? false)
            addItem(item)
        }

        addItem(.separator())

        addSectionHeader("[Global — all tabs]")
        for name in scriptNames {
            let item = makeScriptItem(name: name,
                                      action: #selector(toggleGlobal(_:)),
                                      isDisabled: UserScriptDisabledStore.shared.globallyDisabled.contains(name))
            addItem(item)
        }
    }

    private func addSectionHeader(_ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        addItem(item)
    }

    private func makeScriptItem(name: String, action: Selector, isDisabled: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: name, action: action, keyEquivalent: "")
        item.representedObject = name
        item.target = self
        item.state = isDisabled ? .on : .off
        item.isEnabled = true
        return item
    }

    // MARK: - Helpers

    private func currentTabUserScripts() -> UserScripts? {
        let tab = Application.appDelegate.windowControllersManager.selectedTab
        return tab?.userContentController?.contentBlockingAssets?.userScripts as? UserScripts
    }

    private func currentTabScriptNames() -> [String] {
        guard let scripts = currentTabUserScripts() else { return [] }
        return scripts.userScripts
            .map { String(describing: type(of: $0)) }
            .sorted()
    }

    // MARK: - Actions

    @objc private func togglePerTab(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let tab = Application.appDelegate.windowControllersManager.selectedTab,
              let userScripts = tab.userContentController?.contentBlockingAssets?.userScripts as? UserScripts
        else { return }

        if userScripts.perTabDisabled.contains(name) {
            userScripts.perTabDisabled.remove(name)
        } else {
            userScripts.perTabDisabled.insert(name)
        }

        Task { @MainActor in
            await tab.userContentController?.reinstallUserScripts()
            tab.reload()
        }
    }

    @objc private func toggleGlobal(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }

        let store = UserScriptDisabledStore.shared
        if store.globallyDisabled.contains(name) {
            store.globallyDisabled.remove(name)
        } else {
            store.globallyDisabled.insert(name)
        }

        let allTabs = Application.appDelegate.windowControllersManager.mainWindowControllers
            .flatMap { $0.mainViewController.tabCollectionViewModel.tabCollection.tabs }

        Task { @MainActor in
            for tab in allTabs {
                await tab.userContentController?.reinstallUserScripts()
                tab.reload()
            }
        }
    }
}
```

**Step 2: Add to Xcode project**

Add `UserScriptsDebugMenu.swift` to the same `Debug` group in `project.pbxproj` as `UserScriptDisabledStore.swift`.

**Step 3: Build to verify**

Build the macOS target (`Cmd+B`). Expected: builds cleanly.

**Step 4: Commit**

```bash
git add macOS/DuckDuckGo/Debug/UserScriptsDebugMenu.swift macOS/DuckDuckGo-macOS.xcodeproj/project.pbxproj
git commit -m "feat: add UserScriptsDebugMenu with per-tab and global script disabling"
```

---

### Task 5: Wire into `MainMenu.swift`

**Files:**
- Modify: `macOS/DuckDuckGo/Menus/MainMenu.swift`

**Context:** Find the "User Scripts" menu item in `setupDebugMenu`. It currently looks like:

```swift
NSMenuItem(title: "User Scripts") {
    NSMenuItem(title: "Remove user scripts from selected tab", action: #selector(MainViewController.removeUserScripts))
}
```

**Step 1: Add the new submenu entry**

Change it to:

```swift
NSMenuItem(title: "User Scripts") {
    NSMenuItem(title: "Remove user scripts from selected tab", action: #selector(MainViewController.removeUserScripts))
    NSMenuItem(title: "Disable Individual Scripts")
        .submenu(UserScriptsDebugMenu())
}
```

**Step 2: Build to verify**

Build the macOS target (`Cmd+B`). Expected: builds cleanly.

**Step 3: Manual smoke test**

1. Run the app
2. Open Debug → User Scripts → Disable Individual Scripts
3. Confirm two sections appear: [Current Tab] and [Global — all tabs]
4. Each section should list all loaded script names (e.g. `AutoconsentUserScript`, `ContentScopeUserScript`, etc.)
5. Toggle one script — confirm checkmark appears
6. Confirm the tab reloads
7. Re-open the menu — confirm the checkmark persists

**Step 4: Commit**

```bash
git add macOS/DuckDuckGo/Menus/MainMenu.swift
git commit -m "feat: wire UserScriptsDebugMenu into Debug > User Scripts"
```
