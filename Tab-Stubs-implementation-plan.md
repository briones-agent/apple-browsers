# Tab Stubs Implementation Plan

## Context

Tab objects in the macOS browser are heavyweight — each creates a `WKWebView`, content blocking infrastructure, navigation delegates, user scripts, and numerous extensions on init. When many tabs are open, this consumes significant memory even for tabs the user hasn't looked at in hours.

**Tab Stubs** are lightweight objects that replace inactive tabs, retaining only the data needed to display them in the tab bar and restore the full `Tab` on demand. The user triggers stubbing via a context menu action; activation (clicking the stub) restores the full Tab transparently.

## Architecture: Wrapper Enum

```swift
enum TabItem: Identifiable, Hashable {
    case tab(Tab)
    case stub(TabStub)
}
```

`TabCollection` changes from `[Tab]` to `[TabItem]`. A computed `tabs: [Tab]` property provides backward compatibility for code that only needs live tabs (lazy loader, web extensions, etc.).

---

## Phase 1: Foundation Types (no existing files changed)

### 1a. `TabStub` class

**New file:** `macOS/DuckDuckGo/Tab/Model/TabStub.swift`

```swift
final class TabStub: NSObject, Identifiable {
    let uuid: String           // preserved from original Tab
    let content: TabContent    // stored via .loadedFromCache()
    let title: String?
    let favicon: NSImage?
    let interactionStateData: Data?
    let lastSelectedAt: Date?
    let parentTabID: String?
    let burnerMode: BurnerMode
    let snapshotIdentifier: UUID?
    let wasMuted: Bool
    let localHistory: [Visit]  // captured for fire button

    // Transient (not coded) — populated at creation, lazy-loaded from disk on decode
    var cachedSnapshot: NSImage?

    init(from tab: Tab) {
        uuid = tab.uuid
        content = tab.content.loadedFromCache()
        title = tab.title
        favicon = tab.favicon
        interactionStateData = tab.getActualInteractionStateData()
        lastSelectedAt = tab.lastSelectedAt
        parentTabID = tab.parentTabID
        burnerMode = tab.burnerMode
        snapshotIdentifier = tab.tabSnapshotIdentifier
        wasMuted = tab.audioState.isMuted
        localHistory = tab.localHistory
        cachedSnapshot = tab.tabSnapshot
    }
}
```

**Reference pattern:** `RecentlyClosedTab` at `macOS/DuckDuckGo/RecentlyClosed/Model/RecentlyClosedTab.swift` stores nearly the same fields.

**Key:** TabStub does NOT clear the snapshot from `TabSnapshotStore` on deinit (unlike `TabSnapshotExtension`). The snapshot persists until the stub is closed.

### 1b. `TabItem` enum

**New file:** `macOS/DuckDuckGo/Tab/Model/TabItem.swift`

```swift
enum TabItem: Identifiable, Hashable {
    case tab(Tab)
    case stub(TabStub)

    var id: String { /* uuid from either side */ }
    var title: String? { ... }
    var favicon: NSImage? { ... }
    var content: TabContent { ... }
    var lastSelectedAt: Date? { ... }
    var burnerMode: BurnerMode { ... }
    var snapshotIdentifier: UUID? { ... }

    var tab: Tab? { ... }
    var stub: TabStub? { ... }
    var isStub: Bool { ... }

    // Hashable via id
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}
```

### 1c. `TabStubViewModel`

**New file:** `macOS/DuckDuckGo/Tab/ViewModel/TabStubViewModel.swift`

Conforms to `TabBarViewModel` (from `TabBarViewItem.swift:33`) and `Previewable` (from `TabPreviewViewController.swift:21`).

All publishers are static — stubs don't change. Key implementations:
- `audioState`: `.muted(isPlayingAudio: false)` if `wasMuted`, else `.unmuted(isPlayingAudio: false)`
- `isLoadingPublisher`: `Just((false, nil))`
- `canKillWebContentProcess`: `false`
- `crashIndicatorModel`: inert `TabCrashIndicatorModel()` (has default init)
- `snapshot`: returns `stub.cachedSnapshot` (captured at stub time, or loaded from `TabSnapshotStore` via `snapshotIdentifier`)
- `shouldShowPreview`: `true`

The protocol requires `@Published` properties for `favicon` and `usedPermissions` (concrete `Published<T>.Publisher` types). `TabStubViewModel` declares these as `@Published` with initial values from the stub.

### 1d. `TabStub+NSSecureCoding`

**New file:** `macOS/DuckDuckGo/StateRestoration/TabStub+NSSecureCoding.swift`

Encodes: uuid, url, title, favicon, interactionStateData, tabType (from `TabContent.ContentType`), lastSelectedAt, snapshotIdentifier, wasMuted. Same keys as `Tab+NSSecureCoding` where applicable.

---

## Phase 2: Core Model Changes

### 2a. `TabCollection` — change storage type

**File:** `macOS/DuckDuckGo/TabBar/Model/TabCollection.swift`

```swift
// Change:
@Published private(set) var tabs: [Tab]
// To:
@Published private(set) var items: [TabItem]

// Add backward-compatible computed property:
var tabs: [Tab] { items.compactMap(\.tab) }
```

Update all mutating methods to work with `TabItem`:
- `append(tab:)` → wraps in `.tab()`, keep signature; add `append(item:)`
- `insert(_:at:)` → accept `TabItem`
- `removeTab(at:)` → rename to `removeItem(at:)`, handle both cases
- `moveTab(at:to:)` → `moveItem(at:to:)`
- `replaceTab(at:with:)` → `replaceItem(at:with:)` accepting `TabItem`
- `reorderTabs(_:)` → `reorderItems(_:)` accepting `[TabItem]`
- `removeAll`, `removeTabs(before/after:)`, `removeTabs(at:)` → update to use `items`
- `didRemoveTabPublisher` → change to `PassthroughSubject<(TabItem, Int), Never>()`

**`keepLocalHistory`:** Handle both cases:
```swift
case .tab(let tab): // existing logic using tab.localHistory
case .stub(let stub): // use stub.localHistory
```

**Web extension events:** Only fire for `.tab` cases:
```swift
if case .tab(let tab) = item {
    webExtensionManager.eventsListener.didOpenTab(tab)
}
```

### 2b. `TabCollection+NSSecureCoding` — backward-compatible encoding

**File:** `macOS/DuckDuckGo/StateRestoration/TabCollection+NSSecureCoding.swift`

Strategy: Encode live tabs under existing key (backward compat), stubs + their indices under new keys.

```swift
// Encode:
coder.encode(tabs, forKey: NSKeyedArchiveRootObjectKey)  // [Tab] only
coder.encode(stubIndices as NSArray, forKey: "stubIndices")
coder.encode(stubs as NSArray, forKey: "stubs")

// Decode: if "stubs" key exists, merge them into items at saved indices.
// Otherwise, fall back to old format (all tabs, no stubs).
```

### 2c. `TabCollectionViewModel` — the central coordinator

**File:** `macOS/DuckDuckGo/TabBar/ViewModel/TabCollectionViewModel.swift`

**View model dictionaries — use two separate dicts:**
```swift
private(set) var tabViewModels = [Tab: TabViewModel]()      // unchanged type
private(set) var stubViewModels = [TabStub: TabStubViewModel]()  // new
```

**`subscribeToTabs()` (line 826):** Subscribe to `$items`, diff tabs and stubs separately:
```swift
tabCollection.$items.sink { [weak self] newItems in
    let newTabs = Set(newItems.compactMap(\.tab))
    let oldTabs = Set(self.tabViewModels.keys)
    self.removeTabViewModels(oldTabs.subtracting(newTabs))
    self.addTabViewModels(newTabs.subtracting(oldTabs))

    let newStubs = Set(newItems.compactMap(\.stub))
    let oldStubs = Set(self.stubViewModels.keys)
    self.removeStubViewModels(oldStubs.subtracting(newStubs))
    self.addStubViewModels(newStubs.subtracting(oldStubs))
}
```

**New method `tabBarViewModel(at:)` → returns `(any TabBarViewModel)?`:**
For the tab bar and previews. Existing `tabViewModel(at:)` stays, returns nil for stubs.

**Selection guard — restore stub on select:**
```swift
private func selectUnpinnedTab(at index: Int, ...) -> Bool {
    if case .stub(let stub) = tabCollection.items[safe: index] {
        restoreStub(stub, at: index)
    }
    selectionIndex = .unpinned(index)
    return true
}
```

**New `stubTab(at:)` — Stubbing Flow (Tab → TabStub):**

The full sequence when the user suspends an inactive tab:

```
1. Guard preconditions (not pinned, not active, not burner)
2. Render snapshot if missing (tab may never have been deselected)
3. Capture interactionStateData from the live WKWebView
4. Capture all display data (title, favicon, muted state, localHistory)
5. Create TabStub from captured data
6. Stop media and loading on the tab
7. Replace the tab with the stub in TabCollection
8. Old Tab deallocates → WKWebView torn down, memory freed
9. Web extension receives didCloseTab for the old tab
```

```swift
func stubTab(at index: TabIndex) {
    guard index.isUnpinnedTab else { return }       // pinned tabs are never stubbable
    guard index != selectionIndex else { return }    // can't stub active tab
    guard let tab = tab(at: index) else { return }
    guard !tab.burnerMode.isBurner else { return }   // can't stub burner tabs

    // Ensure a snapshot exists before we lose the webView.
    // renderTabSnapshot() is async but the snapshot may already
    // be cached from a prior tab deselection. If not, we render
    // synchronously or accept a nil snapshot for this edge case.
    if tab.tabSnapshot == nil {
        tab.renderTabSnapshot()
    }

    // Force-capture interactionStateData now, while webView is alive.
    // getActualInteractionStateData() reads webView.interactionState.
    _ = tab.getActualInteractionStateData()

    // Create the lightweight stub with all captured data
    let stub = TabStub(from: tab)

    // Stop media playback and any in-progress loading before replacement
    tab.stopAllMediaAndLoading()

    // Replace in collection — this triggers:
    //   - TabCollectionViewModel removes TabViewModel for the old tab
    //   - TabCollectionViewModel creates TabStubViewModel for the new stub
    //   - Web extension didCloseTab fires for the old tab (inside replaceItem)
    //   - Old Tab loses all strong references → deinit → WKWebView deallocated
    tabCollection.replaceItem(at: index.item, with: .stub(stub))
}
```

**New `restoreStub(_:at:)` — Restoration Flow (TabStub → Tab):**

The full sequence when a stub is activated (user clicks it, or it's selected programmatically):

```
1. Create a new Tab from stub data (uuid, content, title, favicon, interactionStateData)
2. Restore the snapshot identifier so preview is preserved during load
3. Replace the stub with the new tab in TabCollection
4. TabCollectionViewModel creates TabViewModel, removes TabStubViewModel
5. Web extension receives didOpenTab for the new tab
6. Tab's webView restores session from interactionStateData
7. Tab begins loading (pendingStateRestoration source triggers reload)
```

```swift
func restoreStub(_ stub: TabStub, at index: Int) {
    let tab = Tab(uuid: stub.uuid,
                  content: stub.content,
                  title: stub.title,
                  favicon: stub.favicon,
                  interactionStateData: stub.interactionStateData,
                  shouldLoadInBackground: false,
                  burnerMode: stub.burnerMode,
                  lastSelectedAt: stub.lastSelectedAt)

    // Restore snapshot identifier so the existing persisted snapshot
    // is reused for tab preview until the webView finishes loading
    if let snapshotID = stub.snapshotIdentifier {
        tab.tabSnapshots?.setIdentifier(snapshotID)
    }

    // Replace in collection — this triggers:
    //   - TabCollectionViewModel creates TabViewModel for the new tab
    //   - TabCollectionViewModel removes TabStubViewModel for the old stub
    //   - Web extension didOpenTab fires for the new tab (inside replaceItem)
    //   - TabStub loses all strong references → deinit (snapshot NOT cleared)
    tabCollection.replaceItem(at: index, with: .tab(tab))
}
```

**Other methods to update:**
- `allTabsCount` → count `items` (stubs count as tabs for UI purposes)
- `indexInAllTabs(of:)` → search `items` for `.tab(tab)`
- `duplicateTab(at:)` (line 716) → add branch for stubs (create Tab from stub data)
- `pinTab(at:)` → disallow for stubs initially
- `tab(at:)` → returns nil for stubs; add `item(at:) -> TabItem?`

### 2d. `TabCollectionViewModel+NSSecureCoding`

**File:** `macOS/DuckDuckGo/StateRestoration/TabCollectionViewModel+NSSecureCoding.swift`

Minimal change — delegates to `TabCollection` coding. Clamp selection index if it points to a stub.

---

## Phase 3: Tab Bar UI

### 3a. `TabBarViewController` data source

**File:** `macOS/DuckDuckGo/TabBar/View/TabBarViewController.swift`

- Collection view count → `tabCollectionViewModel.tabCollection.items.count`
- Item configuration → `tabCollectionViewModel.tabBarViewModel(at:)` instead of `tabViewModel(at:)`
- Tab preview → accept `Previewable` instead of `TabViewModel` in `showTabPreview(for:from:)`

### 3b. Context menu — suspend/wake action

**File:** `macOS/DuckDuckGo/TabBar/View/TabBarViewItem.swift`

Add to `menuNeedsUpdate()` (line 1267):
```swift
addSuspendWakeMenuItem(to: menu)
```

Add to `TabBarViewItemDelegate` protocol:
```swift
func tabBarViewItemIsStub(_: TabBarViewItem) -> Bool
func tabBarViewItemCanBeSuspended(_: TabBarViewItem) -> Bool
func tabBarViewItemSuspendWakeAction(_: TabBarViewItem)
```

Implementation in `TabBarViewController`:
- `isStub` → check `items[index].isStub`
- `canBeSuspended` → `index.isUnpinnedTab && index != selectionIndex && !isBurner`
- `suspendWakeAction` → call `stubTab(at:)` or `select(at:)` (selecting restores)

### 3c. `TabBarViewItem.subscribe(to:)` — already protocol-based

At line 903, takes `TabBarViewModel`. Works with `TabStubViewModel` unchanged.

---

## Phase 4: Supporting Systems

### 4a. TabLazyLoader — no changes needed

`TabLazyLoaderDataSource.tabs` (line 59 of `TabLazyLoaderDataSource.swift`) returns `tabCollection.tabs` — the computed `[Tab]` property that filters stubs. Lazy loader automatically ignores stubs.

### 4b. Tab preview

**File:** `macOS/DuckDuckGo/TabPreview/TabPreviewViewController.swift`

Already uses `Previewable` protocol (line 21). `TabStubViewModel` conforms. No changes to the view controller.

`TabBarViewController.showTabPreview(for:from:)` (line 981) needs to accept `Previewable` instead of `TabViewModel`.

### 4c. Snapshot handling

**File:** `macOS/DuckDuckGo/StateRestoration/AppStateRestorationManager.swift`

Snapshot cleanup must include stubs' `snapshotIdentifier` in the "keep" set.

### 4d. State change publisher

**File:** `macOS/DuckDuckGo/StateRestoration/AppStateChangedPublisher.swift`

`Tab.stateChanged` publishes `$content`, `$favicon`, `$title` changes. `TabItem` needs a `stateChanged` publisher: delegates to `Tab.stateChanged` for `.tab`, returns `Empty()` for `.stub`.

### 4e. Fire button / local history

**Files:** `macOS/DuckDuckGo/Fire/Model/Fire.swift`, `TabCollection.swift`

`TabCollection.localHistory` must include stubs' stored `localHistory`.

### 4f. Web extensions

**Files:** `TabCollection.swift`, `TabCollectionViewModel.swift`

Policy:
- Stubbing a tab → fire `didCloseTab` (the live tab is gone)
- Restoring a stub → fire `didOpenTab` (a new live tab appears)
- Stubs are invisible to web extensions

### 4g. Pinned tabs — never stubbable

Pinned tabs must never be stubbed. They are always-live tabs shared across windows via `PinnedTabsManager`. The context menu "Suspend" item is hidden for pinned tabs. Guards in `stubTab(at:)` reject pinned tab indices. `PinnedTabsManager` remains unchanged — its `TabCollection` continues to store `[Tab]` only (no `TabItem` migration needed).

### 4h. Other callers needing updates

| File | Change |
|------|--------|
| `WindowControllersManager.swift` | Use `items.count`, handle `TabItem` |
| `RecentlyClosedCoordinator.swift` | Adapt to `TabItem` in removal publisher |
| `WebExtensionWindowTabProvider+macOS.swift` | Use `tabs` (live tabs only) |
| `RemoteMessagingConfigMatcherProvider.swift` | Use `items.count` |
| `MainMenuActions.swift` | Check for stubs in action enablement |
| `Bookmarks+Tab.swift` | Handle stub URLs for bookmarking |
| `TabIndex.swift` | Use `items.count`/`items.indices` |

---

## Phase 5: Testing

- Unit tests for `TabStub` init from Tab (all properties captured correctly)
- Unit tests for `TabItem` Hashable/Identifiable behavior
- Unit tests for `TabStubViewModel` protocol conformance
- Unit tests for `TabCollection` with mixed `[TabItem]` (insert, remove, reorder)
- Unit tests for `TabCollectionViewModel` stub/restore flow (selection guard, viewmodel dicts)
- Unit tests for NSSecureCoding round-trip (encode tabs+stubs, decode, verify)
- Unit tests for backward-compatible decoding (old format with no stubs key)
- Integration tests for fire button with stubbed tabs

---

## Implementation Order

1. **Phase 1** — New types: `TabStub`, `TabItem`, `TabStubViewModel`, `TabStub+NSSecureCoding`
2. **Phase 2** — Core model: `TabCollection`, `TabCollectionViewModel`, NSSecureCoding updates
3. **Phase 3** — Tab bar UI: data source, context menu, preview
4. **Phase 4** — Supporting systems: lazy loader verification, snapshots, fire button, web extensions, other callers
5. **Phase 5** — Tests

---

## Edge Cases

- **Rapid tab switching through stubs:** Restore is synchronous (`Tab.init` creates WKWebView immediately), so `selectedTabViewModel` is never nil during transition.
- **Pinned tabs:** Never stubbable. `PinnedTabsManager` keeps its own `TabCollection` with `[Tab]` only — no migration to `TabItem` needed. Guards at `stubTab(at:)` and context menu level.
- **Burner tabs:** Cannot be stubbed (guard in `stubTab(at:)`).
- **Parent tab stubbed:** Child tabs' weak `parentTab` reference becomes nil. The string `parentTabID` survives. Close-to-parent logic falls through to other heuristics.
- **State restoration crash recovery:** Old app versions ignore the `stubs` key and restore only live tabs — graceful degradation.
- **Tab.deinit verification:** When a tab is replaced with a stub, `#if DEBUG` checks verify the Tab and its WebView deallocate promptly.
