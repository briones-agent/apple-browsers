# Design: 1-Click Voice Chat Access in Duck.ai (macOS)

**Date:** 2026-04-10
**Status:** Approved

## Overview

Add multiple 1-click entry points for Duck.ai voice chat in the macOS browser. The goal is to serve both new users (discoverability) and power users (efficiency) simultaneously, across multiple UI surfaces.

Voice chat is frontend-based: all entry points simply navigate to `AIChatURLParameters.voiceModeURL()` via the existing `AIChatMenu.openNewVoiceChat()` action. No native audio capture is involved.

## Goals

- Users can reach Duck.ai voice chat in a single click from multiple surfaces
- Each surface is independently controllable (user preference or feature flag)
- Pixel tracking per surface for analytics

## Non-Goals

- Native microphone capture or speech-to-text (voice processing stays in the Duck.ai frontend)
- Changes to the voice chat UX itself
- Right-click or long-press context menus on any new buttons

---

## Surface 1: Tab bar voice button

**Placement:** Right of the existing "Duck.ai" button, left of the sidebar toggle — forming the group `[Duck.ai] [🎙] [▤]`.

**Interaction:** Single click only → calls `openNewVoiceChat()`.

**Visibility:** User-controlled via `DuckAIChromeButtonsVisibilityManager`.
- New `.voiceChat` visibility key alongside existing `.duckAI` and `.sidebar`
- New `UserDefaults` key in `DuckAIChromeButtonsPreferences` (e.g. `duck-ai-chrome.voice-button.hidden`)
- The existing right-click context menu on the Duck.ai chrome area gains a new item: **"Hide Voice Chat Button"** / **"Show Voice Chat Button"**, positioned between "Hide Duck.ai Shortcut" and "Show Sidebar Button"

**Pixel:** `aiChatNewVoiceChatTabBarButton`

**Files to modify:**
- `macOS/DuckDuckGo/TabBar/View/DuckAIChromeButtonsVisibilityManager.swift` — add `.voiceChat` case
- `macOS/DuckDuckGo/TabBar/View/DuckAIChromeButtonsPreferences.swift` — add UserDefaults key
- Tab bar chrome view — add new button, wire visibility
- Duck.ai chrome right-click context menu — add show/hide menu item

---

## Surface 2: Duck.ai omnibar mic buttons (A/B positions)

The "Ask privately" input in `AIChatOmnibarContainerViewController` has a two-row layout:

```
Top row:    [text input "Ask anything privately"]  [🔍]  [🔵]
Bottom row: [🖼 image]                             [GPT-4o ∨]  [→ submit]
```

Two new `AIChatOmnibarToolButton` instances are added to the **bottom row**, each behind an independent feature flag, to test which position drives more engagement.

### Position A — right of the image attachment button

```
Bottom row: [🖼 image] [🎙 A]      [GPT-4o ∨]  [→ submit]
```

- Groups with other input modality buttons (image attachment)
- Feature flag: `aiChatOmnibarVoiceChatLeft` in `macOS/LocalPackages/FeatureFlags/Sources/FeatureFlags/FeatureFlag.swift`
- Pixel: `aiChatNewVoiceChatOmnibarLeft`

### Position B — left of the submit arrow

```
Bottom row: [🖼 image]      [GPT-4o ∨]  [🎙 B]  [→ submit]
```

- Sits in the action zone where the user's eye is before submitting; mirrors voice search button patterns in other browsers
- Feature flag: `aiChatOmnibarVoiceChatRight` in `macOS/LocalPackages/FeatureFlags/Sources/FeatureFlags/FeatureFlag.swift`
- Pixel: `aiChatNewVoiceChatOmnibarRight`

**Both positions:**
- Single click → `openNewVoiceChat()`
- Use the existing `AIChatOmnibarToolButton` component
- Can be enabled/disabled independently so each can be A/B tested or rolled back

**Files to modify:**
- `macOS/LocalPackages/FeatureFlags/Sources/FeatureFlags/FeatureFlag.swift` — add `aiChatOmnibarVoiceChatLeft` and `aiChatOmnibarVoiceChatRight`
- `macOS/DuckDuckGo/AIChat/AIChatOmnibarContainerViewController.swift` — add two `AIChatOmnibarToolButton` instances, gated by the respective flags

---

## Pixels

| Surface | Pixel name |
|---|---|
| Tab bar voice button | `aiChatNewVoiceChatTabBarButton` |
| Omnibar Position A (left) | `aiChatNewVoiceChatOmnibarLeft` |
| Omnibar Position B (right) | `aiChatNewVoiceChatOmnibarRight` |

Add all three to `macOS/DuckDuckGo/AIChat/AIChatPixel.swift`.

---

## Implementation summary

| What | Where |
|---|---|
| New feature flags | `FeatureFlag.swift` |
| Tab bar button + visibility | `DuckAIChromeButtonsVisibilityManager`, `DuckAIChromeButtonsPreferences`, tab bar chrome view |
| Tab bar context menu item | Duck.ai chrome right-click menu |
| Omnibar buttons | `AIChatOmnibarContainerViewController` |
| Pixels | `AIChatPixel.swift` |
| New files | None — all additions to existing classes |

All surfaces call the existing `AIChatMenu.openNewVoiceChat()` → `AIChatTabOpening.openAIChatTab(with:behavior:)` with `AIChatURLParameters.voiceModeURL()`. No new URL handling or audio code.
