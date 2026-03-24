# Duck.ai Chat History Sidebar — Design Spec

**Date:** 2026-03-24
**Branch:** `juan/feature/duck-ai-history-chats`
**Status:** Approved

---

## Overview

Add a native left-side browser sidebar that shows the user's Duck.ai chat history. The sidebar is toggled by a new toolbar button placed to the left of the back/forward buttons. It mirrors Safari's sidebar pattern — a persistent panel that animates in/out from the left edge of the browser window.

---

## Goals

- Give users quick access to past Duck.ai chats without leaving the browser.
- Match the visual design of the Duck.ai web sidebar (screenshot reference).
- Reuse existing data infrastructure (`SuggestionsReader`, `AIChatSuggestionsReader`, `AIChatTabOpening`).

## Non-Goals

- Per-item context menu (rename, delete, pin) — deferred.
- Sidebar resize handle — fixed width for now.
- History sidebar persistence across sessions — no state saved.
- Search/filter, pagination, iOS support.

---

## Layout

```
[ Left History Sidebar ] [ Main Web Content ] [ Right AI Chat Sidebar ]
```

The left container is a new `NSView` added to `MainViewController`, default width 260pt. It is hidden off-screen by default via a leading offset constraint (same technique as the right AI Chat sidebar). It animates in using `NSAnimationContext` (0.25s ease-in-out).

**Mutual exclusion:**
- Opening the history sidebar: if the AI Chat sidebar is open on the active tab, call `aiChatCoordinator.collapseSidebar(withAnimation: false)` before animating in.
- Opening the AI Chat sidebar: `AIChatCoordinator.showSidebar` fires `sidebarPresenceDidChangePublisher` with `isShown = true` **before** the animation starts. `MainViewController` subscribes to this publisher and calls `historySidebarCoordinator.closeSidebar(animated: false)` — this runs synchronously on `Main`, so the history sidebar is hidden before the AI Chat animation begins. No frame where both sidebars are simultaneously visible.
- Selecting a chat item calls `openAIChatTab(with: .existingChat(chatId:), behavior: .currentTab)`. Internally this calls `aiChatTabManaging.openAIChat(url, with: .currentTab)`, which only navigates the tab's main web view. It does **not** call `AIChatCoordinator.showSidebar()`, so `sidebarPresenceDidChangePublisher` does **not** fire. The history sidebar remains open and the AI Chat sidebar is not affected.

---

## Toolbar Button

- A new `MouseOverButton` inserted into the navigation stack view in `NavigationBarViewController`, to the **left of `goBackButton`**.
- Icon: an appropriate glyph from `DesignSystemImages`.
- Shows active visual state (highlighted background) when `isSidebarOpen == true`; uses the existing `mouseDownColor`/`mouseOverColor` pattern.
- Hidden in popup windows: check `isInPopUpWindow` (existing property on `NavigationBarViewController` that reads `tabCollectionViewModel.isPopup`).
- On click: calls `AIChatHistorySidebarCoordinator.toggleSidebar()`.
- Wired up in `MainViewController+AIChatHistorySidebar`.

---

## `AIChatSuggestion` Fields Referenced

`AIChatSuggestion` (from `SharedPackages/AIChat`) has:
- `chatId: String` — used in `onChatSelected` and `openAIChatTab(.existingChat(chatId:))`
- `title: String` — displayed as the row label
- `isPinned: Bool` — controls trailing pin icon visibility
- `timestamp: Date?` — used for recency sort; treat `nil` as `.distantPast`

---

## Coordinator (`AIChatHistorySidebarCoordinator`)

Owned by `MainViewController`, one instance per window.

**Init dependencies (injected):**
```swift
init(
    sidebarHost: AIChatHistorySidebarHosting,
    suggestionsReader: AIChatSuggestionsReading,
    aiChatTabOpener: AIChatTabOpening,
    privacyConfig: PrivacyConfigurationManaging
)
```
`AIChatHistorySettings` is instantiated inside `init` from injected `privacyConfig`:
```swift
private let historySettings: AIChatHistorySettings
// = AIChatHistorySettings(privacyConfig: privacyConfig)
```

**Public API:**
```swift
@Published private(set) var isSidebarOpen: Bool = false
func toggleSidebar()
func closeSidebar(animated: Bool)
```

`isSidebarOpen` is `@Published` so `MainViewController` can bind the toolbar button's active state via Combine.

**`toggleSidebar()` flow:**
1. If `isSidebarOpen` → `closeSidebar(animated: true)`.
2. If closed:
   a. Cancel any in-flight fetch task: `fetchTask?.cancel(); fetchTask = nil`.
   b. `viewModel.chats = []`, `viewModel.isLoading = true`.
   c. `isSidebarOpen = true`.
   d. Animate left container in (0.25s) via `sidebarHost`.
   e. `fetchTask = Task { await fetchAndPublish() }`.

**`closeSidebar(animated:)` flow:**
1. `isSidebarOpen = false`.
2. Cancel in-flight fetch: `fetchTask?.cancel(); fetchTask = nil`.
3. Animate (or immediately hide) left container.
4. After animation: `viewModel.chats = []`, `viewModel.isLoading = false`.

The `fetchTask` is stored as `private var fetchTask: Task<Void, Never>?` on the coordinator.

**`fetchAndPublish()`:**
1. Call `await suggestionsReader.fetchSuggestions(query: nil)`.
   - `suggestionsReader` is typed as `AIChatSuggestionsReading` (the macOS-level protocol in `macOS/DuckDuckGo/AIChat/Suggestions/AIChatSuggestionsReader.swift`), **not** the lower-level `SuggestionsReading` from SharedPackages.
   - `AIChatSuggestionsReading.fetchSuggestions(query: String?)` returns `(pinned: [AIChatSuggestion], recent: [AIChatSuggestion])` directly — no `maxChats` parameter, no `Result` wrapper. Internally the reader already passes `maxHistoryCount` to the underlying `SuggestionsReader` and handles errors by returning empty arrays.
   - `query: nil` means "no text filter — return chats from the last week" (applied server-side).
   - **Do not apply `prefix` in the coordinator** — the returned arrays are already capped.
2. Check for cancellation: `guard !Task.isCancelled else { return }`.
3. Merge: `let all = pinned + recent`.
4. Sort by `timestamp` descending (`nil` treated as `.distantPast`). **Pinned items are NOT hoisted** — they appear in chronological order alongside recent items. `isPinned` on a suggestion only controls whether the pin icon is shown in the row view; it has no effect on ordering or grouping.
5. On success: `viewModel.chats = all (sorted)`, `viewModel.isLoading = false`.
6. On failure: `viewModel.chats = []`, `viewModel.isLoading = false`. Empty state shown. No retry.

**Action handler implementations** (closures set on `viewModel`):

| Closure | Call |
|---------|------|
| `onNewChat` | `aiChatTabOpener.openAIChatTab(with: .newChat, behavior: .currentTab)` |
| `onNewVoiceChat` | Build URL from `AIChatRemoteSettings().aiChatURL` appending query item `mode=voice` (`AIChatURLParameters.modeName`/`.voiceModeValue`); `openAIChatTab(with: .url(url), behavior: .currentTab)` |
| `onNewImageChat` | Same URL builder with `mode=image` (`AIChatURLParameters.imageModeValue`); `openAIChatTab(with: .url(url), behavior: .currentTab)` |
| `onSettings` | `Application.appDelegate.windowControllersManager.showPreferencesTab(withSelectedPane: .aiChat)` |
| `onClose` | `closeSidebar(animated: true)` |
| `onChatSelected(chatId:)` | `aiChatTabOpener.openAIChatTab(with: .existingChat(chatId: chatId), behavior: .currentTab)`; sidebar stays open |

URL-building for voice/image reuses the same logic as `buildDuckAIModeURL(mode:)` already in `NavigationBarViewController` — extract to a shared private helper or duplicate in the coordinator.

---

## `AIChatHistorySidebarHosting` Protocol

A thin protocol over `MainViewController` so the coordinator can drive layout without importing the full view controller:

```swift
@MainActor
protocol AIChatHistorySidebarHosting: AnyObject {
    var leftSidebarContainerLeadingConstraint: NSLayoutConstraint? { get }
    var leftSidebarContainerWidthConstraint: NSLayoutConstraint? { get }
    func embedHistorySidebarViewController(_ viewController: NSViewController)
}
```

---

## View Model (`AIChatHistorySidebarViewModel`)

```swift
@MainActor
final class AIChatHistorySidebarViewModel: ObservableObject {
    @Published private(set) var chats: [AIChatSuggestion] = []
    @Published private(set) var isLoading: Bool = false

    // Set by coordinator
    var onChatSelected: ((String) -> Void)?     // receives chatId
    var onNewChat: (() -> Void)?
    var onNewVoiceChat: (() -> Void)?
    var onNewImageChat: (() -> Void)?
    var onSettings: (() -> Void)?
    var onClose: (() -> Void)?

    // Called by coordinator
    func update(chats: [AIChatSuggestion], isLoading: Bool) {
        self.chats = chats
        self.isLoading = isLoading
    }
}
```

---

## View Controller (`AIChatHistorySidebarViewController`)

An `NSViewController` subclass that:
- Creates and owns `AIChatHistorySidebarViewModel`.
- Creates `NSHostingController<AIChatHistorySidebarView>` as a child view controller, passing the view model.
- Exposes `viewModel` so the coordinator can wire closures and push data.

```swift
final class AIChatHistorySidebarViewController: NSViewController {
    let viewModel = AIChatHistorySidebarViewModel()
    private var hostingController: NSHostingController<AIChatHistorySidebarView>!

    override func loadView() {
        hostingController = NSHostingController(rootView: AIChatHistorySidebarView(viewModel: viewModel))
        addChild(hostingController)
        view = hostingController.view
    }
}
```

---

## View (`AIChatHistorySidebarView` — SwiftUI)

```swift
struct AIChatHistorySidebarView: View {
    @ObservedObject var viewModel: AIChatHistorySidebarViewModel
}
```

**Layout (top to bottom):**

1. **Header** — Duck.ai icon + "Duck.ai" title (leading); close (X) button (trailing). Tap close → `viewModel.onClose?()`.
2. **Action rows** (each full-width, tappable, with leading 16pt icon):
   - "New Chat" — `DesignSystemImages.Glyphs.Size16.aiChatAdd` — `viewModel.onNewChat?()`
   - "New Voice Chat" — `DesignSystemImages.Glyphs.Size16.permissionMicrophone` — `viewModel.onNewVoiceChat?()`
   - "New Image" — `DesignSystemImages.Glyphs.Size16.image` — `viewModel.onNewImageChat?()`
3. **"Chats" section header** — plain, non-interactive label.
4. **Scrollable list** (`List` or `ScrollView + LazyVStack`):
   - `isLoading && chats.isEmpty` → `ProgressView()` centered.
   - `!isLoading && chats.isEmpty` → "No recent chats" label centered.
   - Otherwise → rows. Each row:
     - Title: single line, `.lineLimit(1)`, `.truncationMode(.tail)`.
     - Trailing pin icon (`DesignSystemImages.Glyphs.Size16.pin`) if `suggestion.isPinned`. Hidden otherwise.
     - Tap → `viewModel.onChatSelected?(suggestion.chatId)`.
5. **Footer** — `Spacer()` then "Settings & More" row pinned to bottom. Tap → `viewModel.onSettings?()`.

**Theming:** `NSColor(designSystemColor:)` for background and text colors. Responds to `colorScheme` environment value for dark/light mode.

---

## `MainViewController+AIChatHistorySidebar` Extension

This extension on `MainViewController`:
1. Creates the left container `NSView` and sets up Auto Layout constraints (leading anchor, width = 260pt, top/bottom anchors). Stores `leftSidebarContainerLeadingConstraint` and `leftSidebarContainerWidthConstraint`.
2. Creates `AIChatHistorySidebarViewController` and calls `embedHistorySidebarViewController(_:)` once at setup — the VC is embedded permanently and reused across open/close cycles (open/close only animates the container, never removes/re-adds the VC).
3. Creates `AIChatHistorySidebarCoordinator` with the VC's `viewModel` reference for closure wiring.
4. Subscribes to `aiChatCoordinator.sidebarPresenceDidChangePublisher`:
   ```swift
   aiChatCoordinator.sidebarPresenceDidChangePublisher
       .filter { $0.isShown }
       .receive(on: DispatchQueue.main)
       .sink { [weak self] _ in self?.historySidebarCoordinator.closeSidebar(animated: false) }
       .store(in: &cancellables)
   ```
5. Subscribes to `historySidebarCoordinator.$isSidebarOpen` to update the toolbar button's active/normal visual state.

---

## File Plan

| File | Location | Action |
|------|----------|--------|
| `AIChatHistorySidebarCoordinator.swift` | `macOS/DuckDuckGo/AIChat/Sidebar/` | New |
| `AIChatHistorySidebarViewModel.swift` | `macOS/DuckDuckGo/AIChat/Sidebar/` | New |
| `AIChatHistorySidebarViewController.swift` | `macOS/DuckDuckGo/AIChat/Sidebar/` | New |
| `AIChatHistorySidebarView.swift` | `macOS/DuckDuckGo/AIChat/Sidebar/` | New |
| `MainViewController+AIChatHistorySidebar.swift` | `macOS/DuckDuckGo/` | New |
| `NavigationBarViewController.swift` | existing | Add toolbar button; extract `buildDuckAIModeURL` if needed |
| `UserText.swift` | existing | New strings: header title, action row labels, section header, empty state, footer |

---

## Localization Strings Needed

```swift
static let aiChatHistorySidebarTitle = "Duck.ai"
static let aiChatHistorySidebarNewChat = "New Chat"
static let aiChatHistorySidebarNewVoiceChat = "New Voice Chat"
static let aiChatHistorySidebarNewImage = "New Image"
static let aiChatHistorySidebarChatsHeader = "Chats"
static let aiChatHistorySidebarNoChats = "No recent chats"
static let aiChatHistorySidebarSettingsAndMore = "Settings & More"
```

---

## Interaction Flows

### Open sidebar
1. User clicks history toolbar button.
2. Coordinator checks `aiChatCoordinator` — if AI Chat sidebar is open, calls `collapseSidebar(withAnimation: false)`.
3. `viewModel.chats = []`, `viewModel.isLoading = true`.
4. Left container animates in (0.25s).
5. `Task { await fetchAndPublish() }` runs concurrently. On completion, view model is updated.

### Close sidebar (toolbar button or close button in header)
1. Left container animates out (0.25s).
2. After animation: `viewModel.chats = []`, `viewModel.isLoading = false`.

### Select chat item
1. User taps a chat row.
2. `viewModel.onChatSelected?(chatId)` → coordinator → `openAIChatTab(with: .existingChat(chatId:), behavior: .currentTab)`.
3. Sidebar remains open.

### AI Chat sidebar opens while history sidebar is open
1. `sidebarPresenceDidChangePublisher` emits `isShown = true`.
2. `MainViewController` calls `historySidebarCoordinator.closeSidebar(animated: false)`.
3. History sidebar disappears immediately; AI Chat sidebar animates in.

### Fetch fails
1. `viewModel.chats = []`, `viewModel.isLoading = false`.
2. View shows empty state: "No recent chats".
3. No retry. User closes and reopens to try again.
