# User Scripts Debug Menu — Design

## Goal

Add a Debug menu feature that lets developers disable individual user scripts per-tab or globally, to isolate which script is causing issues on a specific website.

## Background

The macOS DuckDuckGo browser injects ~25 user scripts into pages (tracker protection, click-to-load, autoconsent, autofill, etc.). When a website breaks, it's hard to tell which script is responsible. Currently the only option is "turn off protections" which disables many things at once. This feature gives finer-grained control for diagnosis.

## Design

### Behaviour

- **Per-tab disable:** disables a script only in the active tab; other tabs unaffected
- **Global disable:** disables a script in all open tabs and any new tabs opened during the session
- **Session-only:** disabled state resets when the app quits — no persistence
- **All scripts exposed:** all ~25 scripts registered in `UserScripts.swift` are listed
- **Auto-reload:** toggling a script triggers a page reload on the affected tab(s) so the change takes effect immediately

### Architecture

Three pieces:

**1. `UserScriptDisabledStore`** (new singleton)
- Holds `globallyDisabled: Set<String>` — script class names disabled for all tabs
- Session-only; no UserDefaults or CoreData

**2. `UserScripts` extension**
- Add `perTabDisabled: Set<String>` property to the existing `UserScripts` class
- In `loadWKUserScripts()`, filter out any script whose `String(describing: type(of: script))` is in either `perTabDisabled` or `UserScriptDisabledStore.shared.globallyDisabled`
- Reinstall is triggered via the existing `contentBlockingAssets` pipeline — the same path used on every navigation

**3. `UserScriptsDebugMenu`** (new `NSMenu` subclass)
- Two sections: *Current Tab* and *Global*
- Each section lists all scripts alphabetically with a checkmark when disabled
- On toggle: update the appropriate store, trigger reinstall on affected tab(s), reload page(s)
- `menuNeedsUpdate(_:)` rebuilds checkmarks from current store state on each open
- Gets active tab reference via `WindowControllersManager`

### Data Flow

```
User toggles script in Debug menu
    │
    ├─ Per-tab: tab.userScripts.perTabDisabled.insert/remove(name)
    │           → trigger UserContentController reinstall for that tab
    │           → tab.reload()
    │
    └─ Global:  UserScriptDisabledStore.shared.globallyDisabled.insert/remove(name)
                → trigger UserContentController reinstall for all tabs
                → reload all tabs
```

### Script Identification

Scripts are identified by class name using `String(describing: type(of: script))` (e.g. `"ClickToLoadUserScript"`). No new protocol or property needed on individual script classes.

### Menu Structure

```
Debug
└── User Scripts
    ├── [Current Tab]
    │   ├── ✓ AutoconsentUserScript
    │   ├──   ClickToLoadUserScript
    │   └── ... (all scripts)
    ├── ────────────────
    └── [Global]
        ├──   AutoconsentUserScript
        └── ... (all scripts)
```

## Files

| Action | File |
|--------|------|
| New | `macOS/DuckDuckGo/Debug/UserScriptsDebugMenu.swift` |
| New | `macOS/DuckDuckGo/Debug/UserScriptDisabledStore.swift` |
| Modify | `macOS/DuckDuckGo/Tab/UserScripts/UserScripts.swift` |
| Modify | `macOS/DuckDuckGo/Menus/MainMenu.swift` |
| Modify | `macOS/DuckDuckGo-macOS.xcodeproj/project.pbxproj` |

## Out of Scope

- Persistence across launches
- Per-URL disabled state
- Disabling content blocking rules (separate from user scripts)
