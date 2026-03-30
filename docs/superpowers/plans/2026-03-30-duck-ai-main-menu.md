# Duck.ai Main Menu Integration — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Duck.ai submenu to the macOS application menu bar with New Chat, New Voice Chat, New Image Chat, recent chat history (max 10), View All Chats, and Delete All Chats.

**Architecture:** `AIChatMenu: NSMenu` subclass fetches fresh chats on every `update()` call via an async `Task`. Static items are set up once at init; dynamic chat items are cleared and repopulated on each open. The menu is injected with an `AIChatSuggestionsReading` instance and an `AIChatMenu.Actions` struct of closures.

**Tech Stack:** Swift, AppKit (NSMenu), Combine, PixelKit, AIChat shared package.

**Important:** The user commits manually with their own messages. Each task ends with `- [ ] Stop and commit`.

---

## File Map

| Action | Path | Purpose |
|---|---|---|
| Modify | `macOS/DuckDuckGo/AIChat/Suggestions/AIChatSuggestionsReader.swift` | Add `maxChats` param to protocol |
| Modify | `macOS/DuckDuckGo/AIChat/AIChatPixel.swift` | Add 6 new pixel cases + update 3 switches |
| Modify | `macOS/DuckDuckGo/Common/Localizables/UserText.swift` | Add menu string keys |
| Modify | `macOS/DuckDuckGo/Common/Localizables/en.lproj/Localizable.strings` | Add localised strings |
| Create | `macOS/DuckDuckGo/Menus/AIChatMenu.swift` | The NSMenu subclass |
| Modify | `macOS/DuckDuckGo/Application/AppDelegate.swift` | Expose `aiChatSuggestionsReader` and `aiChatHistoryCleaner` |
| Modify | `macOS/DuckDuckGo/Application/Application.swift` | Pass dependencies to MainMenu |
| Modify | `macOS/DuckDuckGo/Menus/MainMenu.swift` | Replace bare NSMenuItem with AIChatMenu |
| Modify | `macOS/DuckDuckGo.xcodeproj/project.pbxproj` | Register new Swift file |

---

## Task 1: Update `AIChatSuggestionsReading` to support `maxChats`

**Files:**
- Modify: `macOS/DuckDuckGo/AIChat/Suggestions/AIChatSuggestionsReader.swift`

**Current state of the file:** The protocol already has `maxHistoryCount: Int` and `fetchSuggestions(query: String?)` (no `maxChats` param). The concrete class internally calls `suggestionsReader.fetchSuggestions(query: query, maxChats: maxHistoryCount)`.

**Goal:** Make `fetchSuggestions(query:maxChats:)` the protocol's required method, and add a default `fetchSuggestions(query:)` overload in a protocol extension so existing callers (omnibar, NTP) don't need to change. `AIChatMenu` will call `fetchSuggestions(query: nil, maxChats: 10)` directly.

- [ ] **Replace the entire file contents with:**

```swift
//
//  AIChatSuggestionsReader.swift
//
//  Copyright © 2026 DuckDuckGo. All rights reserved.
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

import AIChat
import BrowserServicesKit
import Foundation
import os.log
import PrivacyConfig

// MARK: - Protocol

@MainActor
protocol AIChatSuggestionsReading {
    /// Maximum number of recent chat history items, from privacy config.
    var maxHistoryCount: Int { get }

    /// Fetches AI chat suggestions, limited to `maxChats` recent results.
    func fetchSuggestions(query: String?, maxChats: Int) async -> (pinned: [AIChatSuggestion], recent: [AIChatSuggestion])

    /// Tears down the hidden WebView and releases resources.
    func tearDown()
}

extension AIChatSuggestionsReading {
    /// Convenience overload that uses `maxHistoryCount` from privacy config.
    /// Existing callers (omnibar, NTP) use this and are unaffected by the protocol change.
    func fetchSuggestions(query: String?) async -> (pinned: [AIChatSuggestion], recent: [AIChatSuggestion]) {
        return await fetchSuggestions(query: query, maxChats: maxHistoryCount)
    }
}

// MARK: - AIChatSuggestionsReader

@MainActor
final class AIChatSuggestionsReader: AIChatSuggestionsReading {
    private let suggestionsReader: SuggestionsReading
    private let historySettings: AIChatHistorySettings

    var maxHistoryCount: Int {
        historySettings.maxHistoryCount
    }

    init(suggestionsReader: SuggestionsReading, historySettings: AIChatHistorySettings) {
        self.suggestionsReader = suggestionsReader
        self.historySettings = historySettings
    }

    func fetchSuggestions(query: String?, maxChats: Int) async -> (pinned: [AIChatSuggestion], recent: [AIChatSuggestion]) {
        let result = await suggestionsReader.fetchSuggestions(query: query, maxChats: maxChats)
        switch result {
        case .success(let suggestions):
            return suggestions
        case .failure(let error):
            Logger.aiChat.error("Failed to fetch AI chat suggestions: \(error.localizedDescription)")
            return (pinned: [], recent: [])
        }
    }

    func tearDown() {
        suggestionsReader.tearDown()
    }
}
```

- [ ] **Update `MockAIChatSuggestionsReader` in unit tests**

Find `MockAIChatSuggestionsReader` in `macOS/UnitTests/NewTabPage/NewTabPageOmnibarAiChatsProviderTests.swift`. Change its `fetchSuggestions` method to match the new required signature:

```swift
func fetchSuggestions(query: String?, maxChats: Int) async -> (pinned: [AIChatSuggestion], recent: [AIChatSuggestion]) {
    receivedQuery = query
    return (pinned: pinnedChats, recent: recentChats)
}
```

Remove the old `fetchSuggestions(query:)` override — the protocol extension now provides it.

- [ ] **Build to confirm no compiler errors**

- [ ] Stop and commit

---

## Task 2: Add new pixel cases to `AIChatPixel.swift`

**Files:**
- Modify: `macOS/DuckDuckGo/AIChat/AIChatPixel.swift`

**Important:** Adding new enum cases to `AIChatPixel` requires updates in **three** switch statements: `name`, `parameters`, and `standardParameters`. Missing any one causes a compiler exhaustiveness error.

- [ ] **Add pixel cases after `aiChatDeleteHistoryFailed` (around line 150)**

```swift
// MARK: - Main menu

/// Event Trigger: User opens a new Duck.ai chat from the main menu
case aiChatNewChatMainMenu

/// Event Trigger: User opens a new Duck.ai voice chat from the main menu
case aiChatNewVoiceChatMainMenu

/// Event Trigger: User opens a new Duck.ai image chat from the main menu
case aiChatNewImageChatMainMenu

/// Event Trigger: User selects a recent chat from the main menu
case aiChatRecentChatSelectedMainMenu

/// Event Trigger: User clicks View All Chats in the main menu
case aiChatViewAllChatsMainMenu

/// Event Trigger: User confirms Delete All Chats from the main menu
case aiChatDeleteAllChatsMainMenu
```

- [ ] **Add to the `name` computed property switch**

Find `var name: String` and add to the switch:

```swift
case .aiChatNewChatMainMenu: return "aichat_new_chat_main_menu"
case .aiChatNewVoiceChatMainMenu: return "aichat_new_voice_chat_main_menu"
case .aiChatNewImageChatMainMenu: return "aichat_new_image_chat_main_menu"
case .aiChatRecentChatSelectedMainMenu: return "aichat_recent_chat_selected_main_menu"
case .aiChatViewAllChatsMainMenu: return "aichat_view_all_chats_main_menu"
case .aiChatDeleteAllChatsMainMenu: return "aichat_delete_all_chats_main_menu"
```

- [ ] **Add to the `parameters` computed property switch**

Find `var parameters: [String: String]?` (~line 421). It has a long list of cases that all `return nil`. Add the 6 new cases to that list:

```swift
.aiChatNewChatMainMenu,
.aiChatNewVoiceChatMainMenu,
.aiChatNewImageChatMainMenu,
.aiChatRecentChatSelectedMainMenu,
.aiChatViewAllChatsMainMenu,
.aiChatDeleteAllChatsMainMenu,
```

- [ ] **Add to the `standardParameters` computed property switch**

Find `var standardParameters: [PixelKitStandardParameter]?` (~line 514). It has a long list of cases that all `return [.pixelSource]`. Add the 6 new cases to that list:

```swift
.aiChatNewChatMainMenu,
.aiChatNewVoiceChatMainMenu,
.aiChatNewImageChatMainMenu,
.aiChatRecentChatSelectedMainMenu,
.aiChatViewAllChatsMainMenu,
.aiChatDeleteAllChatsMainMenu,
```

- [ ] **Build to confirm no compiler errors**

- [ ] Stop and commit

---

## Task 3: Add `UserText` strings

**Files:**
- Modify: `macOS/DuckDuckGo/Common/Localizables/UserText.swift`
- Modify: `macOS/DuckDuckGo/Common/Localizables/en.lproj/Localizable.strings`

- [ ] **Add to `UserText.swift`** (find the AI chat section — search `newAIChatMenuItem`)

```swift
// Duck.ai main menu
static let aiChatMenuNewChat = NSLocalizedString("duckai.menu.new-chat", value: "New Chat", comment: "Duck.ai main menu item to start a new chat")
static let aiChatMenuNewVoiceChat = NSLocalizedString("duckai.menu.new-voice-chat", value: "New Voice Chat", comment: "Duck.ai main menu item to start a new voice chat")
static let aiChatMenuNewImageChat = NSLocalizedString("duckai.menu.new-image-chat", value: "New Image Chat", comment: "Duck.ai main menu item to start a new image chat")
static let aiChatMenuRecentChats = NSLocalizedString("duckai.menu.recent-chats", value: "Recent Chats", comment: "Duck.ai main menu section label for recent chat history")
static let aiChatMenuViewAllChats = NSLocalizedString("duckai.menu.view-all-chats", value: "View All Chats...", comment: "Duck.ai main menu item to view all chats")
static let aiChatMenuDeleteAllChats = NSLocalizedString("duckai.menu.delete-all-chats", value: "Delete All Chats...", comment: "Duck.ai main menu item to delete all chat history")
static let aiChatMenuDeleteAllChatsAlertTitle = NSLocalizedString("duckai.menu.delete-all-chats.alert-title", value: "Delete All Duck.ai Chats?", comment: "Title of the confirmation alert before deleting all Duck.ai chats")
static let aiChatMenuDeleteAllChatsAlertMessage = NSLocalizedString("duckai.menu.delete-all-chats.alert-message", value: "This will permanently delete all your Duck.ai chat history.", comment: "Message body of the confirmation alert before deleting all Duck.ai chats")
static let aiChatMenuDeleteAllChatsConfirmButton = NSLocalizedString("duckai.menu.delete-all-chats.confirm-button", value: "Delete All", comment: "Confirm button in the Delete All Duck.ai Chats alert")
```

- [ ] **Add to `Localizable.strings`**

```
/* Duck.ai main menu */
"duckai.menu.new-chat" = "New Chat";
"duckai.menu.new-voice-chat" = "New Voice Chat";
"duckai.menu.new-image-chat" = "New Image Chat";
"duckai.menu.recent-chats" = "Recent Chats";
"duckai.menu.view-all-chats" = "View All Chats...";
"duckai.menu.delete-all-chats" = "Delete All Chats...";
"duckai.menu.delete-all-chats.alert-title" = "Delete All Duck.ai Chats?";
"duckai.menu.delete-all-chats.alert-message" = "This will permanently delete all your Duck.ai chat history.";
"duckai.menu.delete-all-chats.confirm-button" = "Delete All";
```

- [ ] **Build to confirm no compiler errors**

- [ ] Stop and commit

---

## Task 4: Create `AIChatMenu.swift`

**Files:**
- Create: `macOS/DuckDuckGo/Menus/AIChatMenu.swift`

**Note on voice/image chat URLs:** `AIChatOpenTrigger` has a `.newChat` case and a `.url(URL)` case but no dedicated voice/image case. Before finalising `openNewVoiceChat` and `openNewImageChat`, confirm the correct URLs with the team. The plan uses `.newChat` as a placeholder — replace with the correct trigger once known.

**Note on `UserText.cancel`:** Search `UserText.swift` for `cancel` — a generic cancel string already exists in the codebase (used throughout menus and alerts). Use it for the alert's cancel button.

- [ ] **Create the file**

```swift
//
//  AIChatMenu.swift
//
//  Copyright © 2026 DuckDuckGo. All rights reserved.
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

import AIChat
import AppKit
import PixelKit

@MainActor
final class AIChatMenu: NSMenu {

    // MARK: - Actions

    struct Actions {
        var openNewChat: () -> Void
        var openNewVoiceChat: () -> Void
        var openNewImageChat: () -> Void
        var openChat: (AIChatSuggestion) -> Void
        var viewAllChats: () -> Void
        var deleteAllChats: () async -> Void
    }

    // MARK: - Static items

    private lazy var newChatItem: NSMenuItem = {
        let item = NSMenuItem(title: UserText.aiChatMenuNewChat, action: #selector(newChatTapped), keyEquivalent: "")
        item.target = self
        return item
    }()

    private lazy var newVoiceChatItem: NSMenuItem = {
        let item = NSMenuItem(title: UserText.aiChatMenuNewVoiceChat, action: #selector(newVoiceChatTapped), keyEquivalent: "")
        item.target = self
        return item
    }()

    private lazy var newImageChatItem: NSMenuItem = {
        let item = NSMenuItem(title: UserText.aiChatMenuNewImageChat, action: #selector(newImageChatTapped), keyEquivalent: "")
        item.target = self
        return item
    }()

    private lazy var recentChatsLabel: NSMenuItem = {
        let item = NSMenuItem(title: UserText.aiChatMenuRecentChats)
        item.isEnabled = false
        return item
    }()

    private lazy var viewAllChatsItem: NSMenuItem = {
        let item = NSMenuItem(title: UserText.aiChatMenuViewAllChats, action: #selector(viewAllChatsTapped), keyEquivalent: "")
        item.target = self
        return item
    }()

    private lazy var deleteAllChatsItem: NSMenuItem = {
        let item = NSMenuItem(title: UserText.aiChatMenuDeleteAllChats, action: #selector(deleteAllChatsTapped), keyEquivalent: "")
        item.target = self
        return item
    }()

    // MARK: - Dynamic chat items

    private var chatItems: [NSMenuItem] = []

    // MARK: - Dependencies

    private let suggestionsReader: AIChatSuggestionsReading
    private let actions: Actions

    // MARK: - Init

    init(suggestionsReader: AIChatSuggestionsReading, actions: Actions) {
        self.suggestionsReader = suggestionsReader
        self.actions = actions
        super.init(title: "Duck.ai")
        buildMenu()
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Menu construction

    private func buildMenu() {
        addItem(newChatItem)
        addItem(newVoiceChatItem)
        addItem(newImageChatItem)
        addItem(.separator())
        addItem(recentChatsLabel)
        // Dynamic chat items are inserted after recentChatsLabel by insertChatItems(_:)
        addItem(.separator())
        addItem(viewAllChatsItem)
        addItem(.separator())
        addItem(deleteAllChatsItem)
    }

    // MARK: - NSMenu update

    override func update() {
        super.update()
        clearChatItems()
        Task { @MainActor [weak self] in
            guard let self else { return }
            let (pinned, recent) = await suggestionsReader.fetchSuggestions(query: nil, maxChats: 10)
            let sorted = (pinned + recent)
                .sorted { ($0.timestamp ?? .distantPast) > ($1.timestamp ?? .distantPast) }
            insertChatItems(Array(sorted.prefix(10)))
        }
    }

    // MARK: - Dynamic item management

    private func clearChatItems() {
        chatItems.forEach { removeItem($0) }
        chatItems.removeAll()
    }

    private func insertChatItems(_ chats: [AIChatSuggestion]) {
        let labelIndex = index(of: recentChatsLabel)
        guard labelIndex != -1 else { return }
        for (offset, chat) in chats.enumerated() {
            let item = NSMenuItem(title: chat.title, action: #selector(chatItemTapped(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = chat
            insertItem(item, at: labelIndex + 1 + offset)
            chatItems.append(item)
        }
    }

    // MARK: - Action handlers

    @objc private func newChatTapped() {
        actions.openNewChat()
        PixelKit.fire(AIChatPixel.aiChatNewChatMainMenu, frequency: .dailyAndStandard)
    }

    @objc private func newVoiceChatTapped() {
        actions.openNewVoiceChat()
        PixelKit.fire(AIChatPixel.aiChatNewVoiceChatMainMenu, frequency: .dailyAndStandard)
    }

    @objc private func newImageChatTapped() {
        actions.openNewImageChat()
        PixelKit.fire(AIChatPixel.aiChatNewImageChatMainMenu, frequency: .dailyAndStandard)
    }

    @objc private func chatItemTapped(_ sender: NSMenuItem) {
        guard let chat = sender.representedObject as? AIChatSuggestion else { return }
        actions.openChat(chat)
        PixelKit.fire(AIChatPixel.aiChatRecentChatSelectedMainMenu, frequency: .dailyAndStandard)
    }

    @objc private func viewAllChatsTapped() {
        actions.viewAllChats()
        PixelKit.fire(AIChatPixel.aiChatViewAllChatsMainMenu, frequency: .dailyAndStandard)
    }

    @objc private func deleteAllChatsTapped() {
        let alert = NSAlert()
        alert.messageText = UserText.aiChatMenuDeleteAllChatsAlertTitle
        alert.informativeText = UserText.aiChatMenuDeleteAllChatsAlertMessage
        alert.addButton(withTitle: UserText.aiChatMenuDeleteAllChatsConfirmButton)
        alert.addButton(withTitle: UserText.cancel)
        alert.alertStyle = .warning

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        PixelKit.fire(AIChatPixel.aiChatDeleteAllChatsMainMenu, frequency: .dailyAndStandard)
        Task { @MainActor in
            await actions.deleteAllChats()
        }
    }
}
```

- [ ] **Build to confirm no compiler errors**

- [ ] Stop and commit

---

## Task 5: Expose `aiChatSuggestionsReader` and `aiChatHistoryCleaner` on `AppDelegate`

**Files:**
- Modify: `macOS/DuckDuckGo/Application/AppDelegate.swift`

**`aiChatSuggestionsReader`:** The menu needs a single app-lifetime reader. Add it as a lazy stored property.

**`aiChatHistoryCleaner`:** Currently a local `let` inside `AppDelegate.init` (line ~817), passed only to `DataClearingPreferences`. We need to promote it to a stored property so `MainMenu` can call `cleanAIChatHistory()`. Change the local `let` to an assignment to a stored property, keeping the same construction arguments.

- [ ] **Add the stored property declarations**

Find where other `let` AI chat properties are declared (near `aiChatMenuConfiguration`, ~line 216). Add:

```swift
private(set) var aiChatHistoryCleaner: AIChatHistoryCleaning!

private(set) lazy var aiChatSuggestionsReader: AIChatSuggestionsReading = AIChatSuggestionsReader(
    suggestionsReader: SuggestionsReader(
        featureFlagger: featureFlagger,
        privacyConfig: privacyFeatures.contentBlocking.privacyConfigurationManager
    ),
    historySettings: AIChatHistorySettings(
        privacyConfig: privacyFeatures.contentBlocking.privacyConfigurationManager
    )
)
```

- [ ] **Promote `aiChatHistoryCleaner` from local to stored in `init`**

Find in `AppDelegate.init` (~line 817):

```swift
let aiChatHistoryCleaner = AIChatHistoryCleaner(featureFlagger: featureFlagger,
                                                aiChatMenuConfiguration: aiChatMenuConfiguration,
                                                featureDiscovery: DefaultFeatureDiscovery(),
                                                privacyConfig: privacyConfigurationManager)
```

Change `let aiChatHistoryCleaner =` to `aiChatHistoryCleaner =` (assignment to the stored property).

- [ ] **Build to confirm no compiler errors**

- [ ] Stop and commit

---

## Task 6: Wire `AIChatMenu` into `MainMenu`

**Files:**
- Modify: `macOS/DuckDuckGo/Menus/MainMenu.swift`
- Modify: `macOS/DuckDuckGo/Application/Application.swift`

### `MainMenu.swift` changes

The current `aiChatMenu` is `var aiChatMenu = NSMenuItem(title: ...)` — a plain item. Replace it with an NSMenuItem container whose submenu is an `AIChatMenu` instance.

- [ ] **Add stored properties for the new dependencies**

Find where other stored `let` properties are declared in `MainMenu`. Add:

```swift
private let aiChatSuggestionsReader: AIChatSuggestionsReading
private let aiChatHistoryCleaner: AIChatHistoryCleaning
```

- [ ] **Add parameters to `MainMenu.init`**

In `MainMenu.init(...)` add two parameters (place them near the existing `aiChatMenuConfig` parameter):

```swift
aiChatSuggestionsReader: AIChatSuggestionsReading,
aiChatHistoryCleaner: AIChatHistoryCleaning,
```

In the init body, add the assignments **before** any call to `super.init` or `buildFileMenu`:

```swift
self.aiChatSuggestionsReader = aiChatSuggestionsReader
self.aiChatHistoryCleaner = aiChatHistoryCleaner
```

- [ ] **Replace `aiChatMenu` property**

Change:
```swift
var aiChatMenu = NSMenuItem(title: UserText.newAIChatMenuItem, action: #selector(AppDelegate.newAIChat), keyEquivalent: [.option, .command, "n"])
```

To:
```swift
private(set) lazy var aiChatMenu: NSMenuItem = {
    let container = NSMenuItem(title: "Duck.ai")
    container.submenu = makeAIChatMenu()
    return container
}()
```

- [ ] **Add `makeAIChatMenu()` helper**

```swift
private func makeAIChatMenu() -> AIChatMenu {
    let actions = AIChatMenu.Actions(
        openNewChat: {
            NSApp.delegateTyped.aiChatTabOpener.openAIChatTab(with: .newChat, behavior: .newTab(selected: true))
        },
        openNewVoiceChat: {
            // TODO: Replace .newChat with the correct voice chat trigger once URL is confirmed with the team
            NSApp.delegateTyped.aiChatTabOpener.openAIChatTab(with: .newChat, behavior: .newTab(selected: true))
        },
        openNewImageChat: {
            // TODO: Replace .newChat with the correct image chat trigger once URL is confirmed with the team
            NSApp.delegateTyped.aiChatTabOpener.openAIChatTab(with: .newChat, behavior: .newTab(selected: true))
        },
        openChat: { suggestion in
            NSApp.delegateTyped.aiChatTabOpener.openAIChatTab(
                with: .existingChat(chatId: suggestion.chatId),
                behavior: .currentTab
            )
        },
        viewAllChats: {
            NSApp.delegateTyped.aiChatTabOpener.openAIChatTab(with: .newChat, behavior: .newTab(selected: true))
        },
        deleteAllChats: { [weak self] in
            guard let self else { return }
            _ = await aiChatHistoryCleaner.cleanAIChatHistory()
        }
    )
    return AIChatMenu(suggestionsReader: aiChatSuggestionsReader, actions: actions)
}
```

- [ ] **Verify `setupAIChatMenu()` still works**

The existing `setupAIChatMenu()` at line 1193 reads:
```swift
aiChatMenu.isHidden = !aiChatMenuConfig.shouldDisplayApplicationMenuShortcut
```
Since `aiChatMenu` is still an `NSMenuItem`, this works unchanged — no edits needed.

### `Application.swift` changes

- [ ] **Pass the two new dependencies to `MainMenu`**

In `Application.swift`, find where `MainMenu(...)` is initialised (~line 61). Add:

```swift
aiChatSuggestionsReader: delegate.aiChatSuggestionsReader,
aiChatHistoryCleaner: delegate.aiChatHistoryCleaner,
```

- [ ] **Build to confirm no compiler errors**

- [ ] Stop and commit

---

## Task 7: Register `AIChatMenu.swift` in the Xcode project

**Files:**
- Modify: `macOS/DuckDuckGo.xcodeproj/project.pbxproj`

New Swift files must be registered in the Xcode project to be compiled.

- [ ] **Open Xcode and add the file to the project**

In Xcode's Project Navigator: right-click `macOS/DuckDuckGo/Menus/` → "Add Files to DuckDuckGo..." → select `AIChatMenu.swift` → ensure the **DuckDuckGo** target checkbox is checked → click Add.

- [ ] **Build the full project to confirm everything compiles**

- [ ] Stop and commit
