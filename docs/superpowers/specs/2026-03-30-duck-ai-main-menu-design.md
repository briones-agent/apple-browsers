# Duck.ai Main Menu Integration — Design Spec

## Goal

Add Duck.ai entries to the macOS application menu bar: New Chat, New Voice Chat, New Image Chat, recent chat history (max 10, most-recently-used order), View All Chats, and Delete All Chats. Gated behind the `duckAiMenuApplication` feature flag.

## Architecture

**Approach:** `AIChatMenu: NSMenu` subclass. Overrides `update()` to fetch fresh chats on every menu open (fetch-on-open, always fresh). Static items are set up once at init; dynamic chat items are cleared and repopulated on each `update()`.

---

## Components

### New file: `macOS/DuckDuckGo/Menus/AIChatMenu.swift`

`AIChatMenu: NSMenu` owns the fetch lifecycle. Initialised with a reader and an actions struct:

```swift
init(suggestionsReader: AIChatSuggestionsReading, actions: AIChatMenuActions)
```

```swift
struct AIChatMenuActions {
    var openNewChat: () -> Void
    var openNewVoiceChat: () -> Void
    var openNewImageChat: () -> Void
    var openChat: (AIChatSuggestion) -> Void
    var viewAllChats: () -> Void
    var deleteAllChats: () async -> Void  // performs deletion only; no UI work
}
```

`AIChatMenu` itself presents the `NSAlert` confirmation for Delete All Chats and only calls the `deleteAllChats` closure if the user confirms. The closure is responsible for the deletion operation only.

### Modified: `AIChatSuggestionsReading` + `AIChatSuggestionsReader`

Add `maxChats: Int` parameter to `fetchSuggestions`:

```swift
func fetchSuggestions(query: String?, maxChats: Int) async -> (pinned: [AIChatSuggestion], recent: [AIChatSuggestion])
```

Existing callers (omnibar, NTP) pass their `historySettings.maxHistoryCount` as before. `AIChatMenu` passes `10`.

### Modified: `AppDelegate`

Add a `@MainActor lazy var aiChatSuggestionsReader: AIChatSuggestionsReading` singleton used exclusively by the menu, created with the same `SuggestionsReader` + `AIChatHistorySettings` configuration as per-window instances. Omnibar and NTP keep their own per-window instances.

### Modified: `MainMenu.swift`

Replace the bare menu item with an `AIChatMenu` instance. Wire it with the AppDelegate's reader and an `AIChatMenuActions` built from window/tab navigation helpers. Show/hide based on `AIChatMenuConfiguration.shouldDisplayApplicationMenuShortcut`, subscribing to `valuesChangedPublisher` for live updates.

---

## Menu Structure

Always visible (static):

```
New Chat
New Voice Chat
New Image Chat
─────────────────────────
Recent Chats              ← disabled label, always present
[chat items appear here]  ← dynamic, 0–10 items
─────────────────────────
View All Chats...
─────────────────────────
Delete All Chats...
```

---

## Data Flow

1. User opens the Duck.ai menu → `NSMenu.update()` fires
2. Clear existing dynamic chat items (the "Recent Chats" label and surrounding separators remain)
3. `Task { @MainActor }` calls `suggestionsReader.fetchSuggestions(query: nil, maxChats: 10)`
4. While the task is in flight the menu is open with no items below the "Recent Chats" label — items pop in when the fetch completes. This is the accepted UX trade-off for always-fresh data.
5. Merge pinned and recent results into a single flat list, sorted by `timestamp` descending (most recently used first). Pinned chats have no special priority in this context — all chats compete purely on recency.
6. Take the first 10 items and insert `NSMenuItem`s after the "Recent Chats" label.

---

## Actions

| Item | Behaviour | Tab |
|------|-----------|-----|
| New Chat | Navigate to Duck.ai new chat URL | New tab |
| New Voice Chat | Navigate to Duck.ai voice chat URL | New tab |
| New Image Chat | Navigate to Duck.ai image chat URL | New tab |
| Recent chat item | Navigate to selected chat URL | Current tab |
| View All Chats... | Navigate to Duck.ai | New tab |
| Delete All Chats... | `AIChatMenu` shows `NSAlert`; on confirm calls `deleteAllChats()` closure | — |

---

## Feature Gating

- `AIChatMenuConfiguration.shouldDisplayApplicationMenuShortcut` gates the entire menu (combines `duckAiMenuApplication` feature flag + Duck.ai globally enabled)
- `MainMenu.swift` shows/hides the menu item and subscribes to `valuesChangedPublisher` for live changes
- `AIChatMenu` itself has no knowledge of feature flags

---

## Pixels

All at `dailyAndStandard` frequency.

| Swift name | Pixel name | Trigger |
|---|---|---|
| `aiChatNewChatMainMenu` | `aichat_new_chat_main_menu` | New Chat tapped |
| `aiChatNewVoiceChatMainMenu` | `aichat_new_voice_chat_main_menu` | New Voice Chat tapped |
| `aiChatNewImageChatMainMenu` | `aichat_new_image_chat_main_menu` | New Image Chat tapped |
| `aiChatRecentChatSelectedMainMenu` | `aichat_recent_chat_selected_main_menu` | Recent chat item tapped |
| `aiChatViewAllChatsMainMenu` | `aichat_view_all_chats_main_menu` | View All Chats tapped |
| `aiChatDeleteAllChatsMainMenu` | `aichat_delete_all_chats_main_menu` | Delete All Chats confirmed (not on tap) |

---

## Testing

Unit tests for `AIChatMenu` using `MockAIChatSuggestionsReader`:

- Static items (New Chat, New Voice Chat, New Image Chat, Recent Chats label, View All Chats, Delete All Chats) always present regardless of chat history
- "Recent Chats" label always present even when no chats returned
- No chats → no dynamic items inserted between label and separator
- With chats → items inserted ordered by `timestamp` descending
- 11+ chats in reader → only 10 items inserted
- New Chat tapped → `openNewChat` closure called + `aiChatNewChatMainMenu` pixel fired
- New Voice Chat tapped → `openNewVoiceChat` closure called + `aiChatNewVoiceChatMainMenu` pixel fired
- New Image Chat tapped → `openNewImageChat` closure called + `aiChatNewImageChatMainMenu` pixel fired
- Recent chat tapped → `openChat` closure called with correct suggestion + `aiChatRecentChatSelectedMainMenu` pixel fired
- View All Chats tapped → `viewAllChats` closure called + `aiChatViewAllChatsMainMenu` pixel fired
- Delete All Chats: cancel → `deleteAllChats` closure NOT called, no pixel fired
- Delete All Chats: confirm → `deleteAllChats` closure called + `aiChatDeleteAllChatsMainMenu` pixel fired
