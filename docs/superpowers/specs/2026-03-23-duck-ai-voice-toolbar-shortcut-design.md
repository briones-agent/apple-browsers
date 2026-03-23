# Duck.ai Voice Toolbar Shortcut — Design Spec

**Date:** 2026-03-23
**Platform:** macOS
**Scope:** PoC — minimal implementation to validate the entry point

---

## Goal

Add a pinnable button to the macOS navigation bar (right of the address bar, alongside VPN/passwords/downloads) that opens duck.ai in voice mode in a new tab with one click.

URL: `https://duck.ai/?mode=voice-mode`

---

## Design Decisions

- **PoC-first:** no URL constant in `AppURLs`, no icons provider protocol extension — these are deferred to productionisation.
- **Unpinned by default:** users with the flag on won't see the button until they pin it via the options button (hamburger) menu.
- **Feature-flagged:** hidden entirely when the flag is off.
- **No popover, no model:** the button just navigates. No `NavBarButtonModel` class is needed.

---

## Components & Changes

### 1. Feature Flag — `FeatureFlag.swift`

Add a new case to the `FeatureFlag` enum:

```swift
case duckAIVoiceShortcut
```

Disabled by default (internal rollout only for PoC).

---

### 2. PinningManager — `PinningManager.swift`

Add `.duckAIVoice` to `PinnableView`:

```swift
case duckAIVoice
```

Add a `shortcutTitle` case:

```swift
case .duckAIVoice:
    return isPinned(.duckAIVoice) ? UserText.hideDuckAIVoiceShortcut : UserText.showDuckAIVoiceShortcut
```

No `pin()` call on first launch — unpinned by default.

`MockPinningManager` (DEBUG-only) requires no changes — it uses the protocol and handles all cases generically.

---

### 3. Localisation — `UserText.swift` (macOS)

Add two strings:

```swift
static let showDuckAIVoiceShortcut = NSLocalizedString("show.duck.ai.voice.shortcut", value: "Show Duck.ai Voice", comment: "Menu item to pin the Duck.ai voice button to the toolbar")
static let hideDuckAIVoiceShortcut = NSLocalizedString("hide.duck.ai.voice.shortcut", value: "Hide Duck.ai Voice", comment: "Menu item to unpin the Duck.ai voice button from the toolbar")
```

---

### 4. NavigationBarViewController — Storyboard + Swift

#### Storyboard (`NavigationBar.storyboard`)

- Add a `MouseOverButton` to the `menuButtons` NSStackView, positioned to the left of `networkProtectionButton` (consistent with the visual order: share → downloads → passwords → duckAIVoice → VPN → overflow → options).
- Wire outlet: `duckAIVoiceButton`
- Wire width/height constraints: `duckAIVoiceButtonWidthConstraint`, `duckAIVoiceButtonHeightConstraint` — same sizing as `vpnButtonWidthConstraint`/`vpnButtonHeightConstraint`
- Wire action: `duckAIVoiceButtonAction`

#### `NavigationBarViewController.swift` — Outlets

```swift
@IBOutlet private var duckAIVoiceButton: MouseOverButton!
@IBOutlet private var duckAIVoiceButtonWidthConstraint: NSLayoutConstraint!
@IBOutlet private var duckAIVoiceButtonHeightConstraint: NSLayoutConstraint!
```

#### Setup method — call from `viewDidLoad` alongside `setupNetworkProtectionButton()`

```swift
private func setupDuckAIVoiceButton() {
    guard featureFlagger.isFeatureOn(.duckAIVoiceShortcut),
          !isInPopUpWindow else {
        duckAIVoiceButton.isHidden = true
        return
    }

    assert(duckAIVoiceButton.menu == nil)

    let menuItem = NSMenuItem(title: pinningManager.shortcutTitle(for: .duckAIVoice),
                              action: #selector(toggleDuckAIVoicePinning),
                              keyEquivalent: "")
        .targetting(self)
    duckAIVoiceButton.menu = NSMenu(items: [menuItem])
    duckAIVoiceButton.image = DesignSystemImages.Glyphs.Size16.microphone
    duckAIVoiceButton.isHidden = !pinningManager.isPinned(.duckAIVoice)
    duckAIVoiceButton.sendAction(on: .leftMouseDown)
    duckAIVoiceButton.setAccessibilityIdentifier("NavigationBarViewController.duckAIVoiceButton")
}
```

#### `listenToPinningManagerNotifications` — add `.duckAIVoice` case to the existing switch

```swift
case .duckAIVoice:
    self.updateDuckAIVoiceButton()
```

Add the corresponding update method:

```swift
private func updateDuckAIVoiceButton() {
    guard featureFlagger.isFeatureOn(.duckAIVoiceShortcut) else { return }
    duckAIVoiceButton.isHidden = !pinningManager.isPinned(.duckAIVoice)
    if let menuItem = duckAIVoiceButton.menu?.items.first {
        menuItem.title = pinningManager.shortcutTitle(for: .duckAIVoice)
    }
}
```

#### `pinnedViews` array — add `.duckAIVoice`

```swift
let allButtons: [PinnableView] = [.share, .downloads, .autofill, .bookmarks, .networkProtection, .homeButton, .duckAIVoice]
```

#### `navBarButtonViews(for:)` — add case

```swift
case .duckAIVoice:
    return [duckAIVoiceButton]
```

#### `overflowMenuItem(for:)` — add case

```swift
case .duckAIVoice:
    return NSMenuItem(title: UserText.showDuckAIVoiceShortcut, action: #selector(overflowMenuRequestedDuckAIVoice), keyEquivalent: "")
        .targetting(self)
        .withImage(DesignSystemImages.Glyphs.Size16.microphone)
```

Add the overflow handler:

```swift
@objc func overflowMenuRequestedDuckAIVoice(_ menu: NSMenu) {
    makeSpaceInNavBarIfNeeded(for: .duckAIVoice)
    updateNavBarViews(with: .duckAIVoice, isHidden: false)
    guard let url = URL(string: "https://duck.ai/?mode=voice-mode") else { return }
    showTab(.aiChat(url))
}
```

#### Options button menu — add entry (feature-flag gated)

In the method that populates the options button menu (where VPN, downloads, etc. are listed), add alongside the other pinnable items:

```swift
if featureFlagger.isFeatureOn(.duckAIVoiceShortcut) {
    let duckAIVoiceTitle = pinningManager.shortcutTitle(for: .duckAIVoice)
    menu.addItem(withTitle: duckAIVoiceTitle, action: #selector(toggleDuckAIVoicePinning), keyEquivalent: "")
}
```

#### Pin toggle selector

```swift
@objc private func toggleDuckAIVoicePinning(_ sender: NSMenuItem) {
    pinningManager.togglePinning(for: .duckAIVoice)
}
```

#### `@IBAction`

```swift
@IBAction func duckAIVoiceButtonAction(_ sender: NSButton) {
    guard let url = URL(string: "https://duck.ai/?mode=voice-mode") else { return }
    showTab(.aiChat(url))
}
```

#### `setupNavigationButtonsSize()` — add sizing

```swift
duckAIVoiceButtonWidthConstraint.constant = addressBarStyleProvider.addressBarButtonSize
duckAIVoiceButtonHeightConstraint.constant = addressBarStyleProvider.addressBarButtonSize
```

#### `setupNavigationButtonsCornerRadius()` — add corner radius

```swift
duckAIVoiceButton.setCornerRadius(theme.toolbarButtonsCornerRadius)
```

#### `deinit` guard (inside existing `#if DEBUG` / `if isViewLoaded` block)

```swift
duckAIVoiceButton.ensureObjectDeallocated(after: 1.0, do: .interrupt)
```

---

## Out of Scope (PoC)

- Pixel firing
- URL constant in `AppURLs`
- Icon added to `NavigationToolbarIconsProviding` protocol
- Unit tests

---

## Files Changed

| File | Change |
|------|--------|
| `macOS/LocalPackages/FeatureFlags/Sources/FeatureFlags/FeatureFlag.swift` | Add `case duckAIVoiceShortcut` |
| `macOS/DuckDuckGo/NavigationBar/PinningManager.swift` | Add `case duckAIVoice` + `shortcutTitle` case |
| `macOS/DuckDuckGo/Common/Localizables/UserText.swift` | Add show/hide strings |
| `macOS/DuckDuckGo/NavigationBar/View/NavigationBarViewController.swift` | Outlets, setup, update, action, pin toggle, overflow handler, sizing, corner radius, deinit guard, `pinnedViews` array, `navBarButtonViews`, `overflowMenuItem`, `listenToPinningManagerNotifications`, options menu |
| `macOS/DuckDuckGo/NavigationBar/View/NavigationBar.storyboard` | New button, constraints, outlet + action wiring |
