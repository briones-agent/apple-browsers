# macOS Autoplay Exceptions — Design

**Date:** 2026-03-06
**Branch:** TBD

---

## Overview

Extend the existing autoplay blocking settings to support per-site overrides. Users can add domain exceptions with their own `AutoplayBlockingMode`, overriding the global setting for that site.

---

## Decisions

| Question | Decision |
|----------|----------|
| Exception granularity | Per-domain (bare hostname, `www.`-stripped) |
| Override modes | Full 3-mode picker (`allowAll`, `blockAudio`, `blockAll`) — same as global |
| How users add sites | Manual domain entry (text field) |
| UI placement | Inline in General Settings Permissions section — "Manage…" button below autoplay picker |
| Runtime enforcement | `AutoplayTabExtension` detects mode mismatch on `navigationDidStart`, reloads if needed |

---

## Architecture

**Pattern:** Extend `AutoplayPreferences` with an exceptions dictionary + new `AutoplayTabExtension` NavigationResponder.

### Data Model

`AutoplayPreferences` gains:

```swift
@Published var exceptions: [String: AutoplayBlockingMode]
```

- Persisted as `[String: String]` in UserDefaults under key `preferences.autoplay.exceptions`
- Domain keys are bare hostnames (`youtube.com`) — `www.` stripped, `host` component only
- Effective mode resolution: exception for domain → fallback to global `autoplayBlockingMode`

`AutoplayPreferencesPersistor` gains:

```swift
var autoplayExceptionsRawValue: [String: String] { get set }
```

A helper on `AutoplayPreferences`:

```swift
func effectiveMode(for url: URL) -> AutoplayBlockingMode
```

Strips `www.`, extracts `host`, looks up in `exceptions`, falls back to `autoplayBlockingMode`.

### Settings UI

In **General Settings → Permissions**, below the autoplay picker:

```
Allow websites to autoplay    [Video with audio muted ▾]
Exceptions                    [Manage…]
```

**Manage…** opens a SwiftUI `.sheet()` (`AutoplayExceptionsSheet`):

- Title: "Autoplay Exceptions"
- List of domain rows: `domain label | [mode picker ▾] | × remove`
- Empty state: *"No exceptions. Sites will use the default autoplay setting."*
- **"Add Website"** button → inline text field + mode picker → **Add** / **Cancel**
- **Done** button closes the sheet

### Runtime Enforcement (`AutoplayTabExtension`)

New `AutoplayTabExtension` conforms to `NavigationResponder` and `TabExtension`:

- Holds a `configuredMode: AutoplayBlockingMode` — the mode the WebView was created with (set at tab creation in `Tab.swift`)
- Subscribes to `webViewPublisher` (weak `WKWebView` reference)
- Subscribes to `AutoplayPreferences` (reacts to both `$autoplayBlockingMode` and `$exceptions` changes)
- On `navigationDidStart(_ navigation: Navigation)`:
  - Resolves `effectiveMode(for: navigation.url)`
  - If `effectiveMode != configuredMode` → `webView?.reload()`
  - The reload triggers tab creation with the correct `mediaTypesRequiringUserActionForPlayback`
- On settings change while on an affected domain: same reload check fires immediately

---

## State Flow

```
AutoplayPreferences
  @Published autoplayBlockingMode: AutoplayBlockingMode
  @Published exceptions: [String: AutoplayBlockingMode]
  func effectiveMode(for url: URL) -> AutoplayBlockingMode

      ↓

AutoplayTabExtension (NavigationResponder)
  configuredMode: AutoplayBlockingMode   ← set at Tab creation
  navigationDidStart → effectiveMode check → reload if mismatch

      ↓

Tab.swift
  configuration.mediaTypesRequiringUserActionForPlayback = effectiveMode.mediaTypesRequiringUserAction
```

---

## Files

### New

| File | Purpose |
|------|---------|
| `macOS/DuckDuckGo/Preferences/View/AutoplayExceptionsSheet.swift` | SwiftUI sheet — list, add/remove, per-row mode picker |
| `macOS/DuckDuckGo/Tab/TabExtensions/AutoplayTabExtension.swift` | NavigationResponder — effective mode resolution, reload on mismatch |
| `macOS/UnitTests/Autoplay/AutoplayTabExtensionTests.swift` | Unit tests for effective-mode resolution and reload logic |

### Modified

| File | Change |
|------|--------|
| `macOS/DuckDuckGo/Preferences/Model/AutoplayPreferences.swift` | Add `exceptions`, persistor property, `effectiveMode(for:)` |
| `macOS/DuckDuckGo/Common/Utilities/UserDefaultsWrapper.swift` | Add `autoplayExceptions` key |
| `macOS/DuckDuckGo/Preferences/View/PreferencesGeneralView.swift` | Add Exceptions row + sheet wiring |
| `macOS/DuckDuckGo/Tab/TabExtensions/TabExtensions.swift` | Register `AutoplayTabExtension` |
| `macOS/DuckDuckGo/Tab/Model/Tab.swift` | Pass `configuredMode` to `AutoplayTabExtension` at creation |
| `macOS/DuckDuckGo/DuckDuckGo-macOS.xcodeproj/project.pbxproj` | Register new files |

---

## Testing

### Unit tests (`AutoplayTabExtensionTests.swift`)

- `effectiveMode` returns exception mode when domain matches
- `effectiveMode` falls back to global mode when no exception
- `www.` prefix is stripped during lookup
- `navigationDidStart` triggers reload when effective mode differs from configured mode
- `navigationDidStart` does NOT reload when modes match
- Settings change on current domain triggers immediate reload check

### Manual smoke test

1. Set global mode to "Block audio"
2. Open Settings → General → Permissions → Manage Exceptions
3. Add `youtube.com` with mode "Video and audio"
4. Navigate to `youtube.com` — verify autoplay works
5. Navigate away and back — verify no unnecessary reload loop
6. Remove the exception — verify global policy applies on next navigation
