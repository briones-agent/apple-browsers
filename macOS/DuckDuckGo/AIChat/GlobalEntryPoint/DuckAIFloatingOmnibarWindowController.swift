//
//  DuckAIFloatingOmnibarWindowController.swift
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

/// Owns the global Duck.ai floating omnibar window. Hosts the existing
/// `AIChatOmnibarContainerViewController` (background, tools, attachments, suggestions, model
/// picker) overlaid by `AIChatOmnibarTextContainerViewController` (text input) — same two-VC
/// pattern as the address-bar Duck.ai mode, but with no tab collection backing it.
@MainActor
final class DuckAIFloatingOmnibarWindowController: NSObject, NSWindowDelegate {

    private enum Constants {
        static let width: CGFloat = 580
        /// Match the address-bar omnibar's collapsed height (`MainView.Constants.aiChatOmnibarContainerMinHeight`).
        static let omnibarContainerMinHeight: CGFloat = 60
        /// In the address bar, the text container view extends UP into the navigation bar above the
        /// omnibar container, gaining ~52 pt of vertical space for the text input. The floating panel
        /// has no navigation bar to extend into, so we explicitly add the same extra height — without
        /// it, the text scrollView gets squished to ~20 pt and sits on top of the tools row.
        static let inputAreaExtraHeight: CGFloat = 52
        /// Initial panel height. Pre-sizing the window at its final collapsed height (omnibar + input
        /// area extra) avoids a post-show resize from 60 → 112 pt, which on the very first show was
        /// causing `HoverTrackingArea`s under the text container to evaluate against stale bounds and
        /// miss the cursor's already-inside position.
        static let baseContainerHeight: CGFloat = omnibarContainerMinHeight + inputAreaExtraHeight
        /// Inset values mirror the address-bar `aiChatOmnibarTextContainerView` constraints in `MainView`.
        /// `textTopInset` is a touch larger than the address-bar's 5 pt because we own the chrome here —
        /// a bit of headroom keeps the input's first line from kissing the panel's top edge.
        static let textTopInset: CGFloat = 8
        static let textLeadingInset: CGFloat = 10
        static let textTrailingInset: CGFloat = 78
        static let cornerRadius: CGFloat = 16
        /// Fraction of the visible screen height where the panel's top edge anchors.
        /// 1/3 = "centered ~third from the top", matching ChatGPT/Claude desktop apps.
        static let topInsetFraction: CGFloat = 1.0 / 3.0
        /// System material driving the floating panel's backdrop. Spotlight uses something close to
        /// `.hudWindow`; lighter alternatives to try: `.popover`, `.menu`, `.sidebar`, `.fullScreenUI`,
        /// `.underWindowBackground`.
        static let backdropMaterial: NSVisualEffectView.Material = .hudWindow
    }

    private var window: DuckAIFloatingOmnibarWindow?
    private var omnibarController: AIChatOmnibarController?
    private var containerVC: AIChatOmnibarContainerViewController?
    private var textVC: AIChatOmnibarTextContainerViewController?
    /// Wraps the text VC's view to enable click-through in the bottom strip where the omnibar
    /// container's tool buttons live. Without this wrapper the text VC's `MouseOverView` swallows
    /// every click in its full-frame area, blocking the tool buttons / model picker / submit.
    private var textPassthroughView: PassthroughView?
    /// The app that was foreground when `show()` was called. Captured so we can re-activate it on
    /// close instead of letting AppKit promote a DDG browser window to key — important because the
    /// browser window can live on a different desktop space, and AppKit's auto-promotion would
    /// force-switch spaces. M6+ will skip this re-activation for the submit path.
    private var previouslyActiveApp: NSRunningApplication?
    /// When the panel is closed because it lost key status (e.g. status-bar click), AppKit
    /// dispatches `windowDidResignKey` *before* the click action that triggered it lands on
    /// `toggle()`. Without this debounce, the toggle would see `isVisible == false` and re-open
    /// the panel — flipping a "close" gesture into a "leave open" no-op.
    private var lastResignKeyCloseAt: Date?
    private static let resignKeyToggleSuppression: TimeInterval = 0.25
    /// Global event monitor active while the panel is visible. Catches mouse-downs that land in
    /// any other app's window so we close even when AppKit's `windowDidResignKey` doesn't fire
    /// (it can be flaky if the click lands on the Finder desktop or certain non-windowed surfaces).
    /// Mouse-event global monitors do NOT require Accessibility permission — only keyboard ones do.
    private var outsideClickMonitor: Any?

    var isVisible: Bool { window?.isVisible == true }

    func toggle() {
        if isVisible {
            close()
            return
        }
        if let lastClose = lastResignKeyCloseAt,
           Date().timeIntervalSince(lastClose) < Self.resignKeyToggleSuppression {
            lastResignKeyCloseAt = nil
            return
        }
        show()
    }

    func show() {
        let window = ensureWindow()
        positionWindow(window)
        // Remember the foreground app so we can hand focus back on close. Skip if DDG was already
        // foreground — re-activating ourselves on close would be a no-op.
        let frontmost = NSWorkspace.shared.frontmostApplication
        let myBundleID = Bundle.main.bundleIdentifier
        previouslyActiveApp = (frontmost?.bundleIdentifier != myBundleID) ? frontmost : nil

        // We deliberately do NOT activate DDG here. The panel is a `.nonactivatingPanel` at level
        // `.popUpMenu`, so it can become the system's key window and accept input without DDG ever
        // becoming the foreground app — the pattern Claude/ChatGPT desktop apps and `NSStatusItem`
        // menus use. Net effect: the menu-bar app indicator stays on whatever app the user was in,
        // open DDG browser windows aren't pulled forward, and no desktop space is force-switched.
        window.orderFrontRegardless()
        window.makeKey()
        installOutsideClickMonitor()

        // App activation is async — on the very first show (DDG not already foreground), the panel
        // comes up before the activation event lands and AppKit refuses to promote it to key.
        // Defer the makeKey + first-responder + tracking-refresh follow-up to the next runloop
        // tick: by then the activation has been processed and the text view can legitimately
        // become first responder. Already-active shows turn this into a harmless no-op.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, window.isVisible else { return }
            if !window.isKeyWindow {
                window.makeKey()
            }
            self.textVC?.focusTextViewWithCursorAtEnd()
            // `HoverTrackingArea` is `.activeInKeyWindow`-bound. On the very first show the window
            // isn't key yet when those areas register, and AppKit doesn't auto-fire `mouseEntered`
            // for the cursor's already-inside position once the window later becomes key — the
            // user has to nudge the mouse for hover to light up under the text container's overlay.
            // We refresh tracking areas as a best-effort here; a fully-reliable fix would need a
            // `CGEvent` injection, which requires Accessibility permission and is out of scope.
            if let host = window.contentView {
                Self.updateTrackingAreasRecursively(in: host)
            }
        }

        omnibarController?.onOmnibarActivated()
        textVC?.startEventMonitoring()
        recalculatePanelHeight(animated: false)
    }

    func close() {
        guard let window, window.isVisible else { return }
        removeOutsideClickMonitor()
        // Hand focus back BEFORE we tear the panel down. If we let AppKit cycle key away from the
        // panel after orderOut, it picks the next available DDG window — which can live on a
        // different desktop space and force-switch the user there. Activating the previous app
        // first means the system's key window moves to that app's window (on the user's current
        // space), so the panel's orderOut has nothing left to cycle to.
        if let previouslyActiveApp, previouslyActiveApp.isTerminated == false {
            previouslyActiveApp.activate()
        }
        previouslyActiveApp = nil
        textVC?.stopEventMonitoring()
        // Reset draft / attachments / suggestions so the next show() starts fresh.
        containerVC?.cleanup()
        lastResignKeyCloseAt = Date()
        window.orderOut(nil)
    }

    private func installOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            // Global monitors only fire for events targeted at *other* apps. Any click here means
            // the user clicked outside the panel — close it.
            self?.close()
        }
    }

    private func removeOutsideClickMonitor() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
        }
        outsideClickMonitor = nil
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        // Dismiss as soon as focus moves elsewhere — matches the dismiss-on-outside-click
        // expectation of a Spotlight-style entry point.
        guard let window, notification.object as AnyObject === window, window.isVisible else { return }
        close()
    }

    // MARK: - Private

    private func ensureWindow() -> DuckAIFloatingOmnibarWindow {
        if let window { return window }

        let initialFrame = NSRect(x: 0, y: 0, width: Constants.width, height: Constants.baseContainerHeight)
        let panel = DuckAIFloatingOmnibarWindow(contentRect: initialFrame)
        panel.delegate = self
        panel.onCancelRequested = { [weak self] in
            self?.close()
        }

        let omnibar = AIChatOmnibarController(
            aiChatTabOpener: NSApp.delegateTyped.aiChatTabOpener,
            tabCollectionViewModel: nil,
            suggestionsReader: NSApp.delegateTyped.aiChatSuggestionsReader,
            preferences: NSApp.delegateTyped.aiChatPreferencesPersistor
        )
        // Spotlight-style entry point: keep the panel a pure input surface, no recent-chats list.
        omnibar.suggestionsDisabledOverride = true
        omnibar.delegate = self

        let themeManager = NSApp.delegateTyped.themeManager
        let container = AIChatOmnibarContainerViewController(themeManager: themeManager, omnibarController: omnibar)
        // We own the host shadow + rounded corners; ask the container to skip its address-bar-specific
        // top clip mask and external shadow view so the top edge can render fully and the panel's
        // own shadow extends evenly on all four sides.
        container.disablesAddressBarChrome = true
        // Image attachments are hidden in the floating panel — the file-picker sheet conflicts with
        // a non-activating panel (icon bounce, sheet swallows the panel on dismiss). Attachments
        // will return through a future menu-style entry point.
        container.hidesImageAttachments = true
        let text = AIChatOmnibarTextContainerViewController(omnibarController: omnibar, themeManager: themeManager)
        text.containerViewController = container

        // Force the child VCs' views to load and run viewDidLoad.
        _ = container.view
        _ = text.view

        let contentView = makeContentView(container: container.view, text: text.view)
        panel.contentView = contentView
        // The omnibar's tool / model-picker / submit buttons render a default focus ring whenever
        // they accept first-responder status, which is part of the address-bar tab-cycle UX. The
        // floating panel doesn't tab-cycle through those buttons, so the ring just shows up as a
        // blue outline whenever the user clicks one — disable it for the whole subtree.
        Self.disableFocusRingsRecursively(in: contentView)

        wireHeightCallbacks(container: container, text: text)

        self.window = panel
        self.omnibarController = omnibar
        self.containerVC = container
        self.textVC = text
        return panel
    }

    private func makeContentView(container: NSView, text: NSView) -> NSView {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: Constants.width, height: Constants.baseContainerHeight))
        host.wantsLayer = true
        // Rounded clipping container. The actual fill is provided by the `NSVisualEffectView` added
        // below — SwiftUI `Material` equivalent. `masksToBounds` clips both the vibrancy and the
        // child VCs to the rounded shape; the panel's own `hasShadow = true` wraps the result.
        host.layer?.cornerRadius = Constants.cornerRadius
        host.layer?.masksToBounds = true

        let backdrop = NSVisualEffectView()
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        backdrop.material = Constants.backdropMaterial
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.isEmphasized = true
        host.addSubview(backdrop)
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: host.topAnchor),
            backdrop.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            backdrop.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])

        // Wrap the text VC's view in a PassthroughView so clicks in the bottom strip (where the
        // omnibar container's tool buttons sit *behind* the text container) fall through to the
        // tool buttons. Mirrors the address-bar setup in `MainView` where the text container view
        // is itself a PassthroughView, except here we only need the wrapper because the text VC's
        // own view is a `MouseOverView` that doesn't pass clicks.
        let textPassthrough = PassthroughView()
        textPassthrough.translatesAutoresizingMaskIntoConstraints = false
        text.translatesAutoresizingMaskIntoConstraints = false
        textPassthrough.addSubview(text)
        NSLayoutConstraint.activate([
            text.topAnchor.constraint(equalTo: textPassthrough.topAnchor),
            text.leadingAnchor.constraint(equalTo: textPassthrough.leadingAnchor),
            text.trailingAnchor.constraint(equalTo: textPassthrough.trailingAnchor),
            text.bottomAnchor.constraint(equalTo: textPassthrough.bottomAnchor)
        ])
        textPassthroughView = textPassthrough

        container.translatesAutoresizingMaskIntoConstraints = false

        host.addSubview(container)
        host.addSubview(textPassthrough)

        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: host.topAnchor),
            container.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: host.bottomAnchor),

            textPassthrough.topAnchor.constraint(equalTo: host.topAnchor, constant: Constants.textTopInset),
            textPassthrough.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: Constants.textLeadingInset),
            textPassthrough.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -Constants.textTrailingInset),
            textPassthrough.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])

        return host
    }

    private func wireHeightCallbacks(container: AIChatOmnibarContainerViewController,
                                     text: AIChatOmnibarTextContainerViewController) {
        text.heightDidChange = { [weak self] _ in
            self?.recalculatePanelHeight(animated: true)
        }
        container.onSuggestionsHeightChanged = { [weak self] _ in
            self?.recalculatePanelHeight(animated: false)
        }
        container.onPassthroughHeightNeedsUpdate = { [weak self] in
            self?.recalculatePanelHeight(animated: false)
        }
    }

    private func recalculatePanelHeight(animated: Bool) {
        guard let window, let containerVC, let textVC else { return }

        let textHeight = textVC.calculateDesiredPanelHeight()
        let suggestionsHeight = containerVC.suggestionsHeight
        let additionalHeight = containerVC.additionalContentHeight
        let totalHeight = textHeight + suggestionsHeight + additionalHeight + Constants.inputAreaExtraHeight

        let currentFrame = window.frame
        // Anchor the top edge so growing/shrinking the panel doesn't make it jump up the screen.
        let newOriginY = currentFrame.maxY - totalHeight
        let newFrame = NSRect(x: currentFrame.origin.x, y: newOriginY, width: currentFrame.width, height: totalHeight)
        window.setFrame(newFrame, display: true, animate: animated)

        // Tell the text container's wrapping PassthroughView to ignore clicks in its bottom strip
        // (where the omnibar container's tool buttons / suggestions / attachments sit), and tell the
        // text VC itself so its scroll view doesn't render content into that region. Same pattern as
        // `MainViewController.wireAIChatOmnibarHeightUpdates`.
        let passthroughHeight = containerVC.totalPassthroughHeight
        textPassthroughView?.passthroughBottomHeight = passthroughHeight
        textVC.setPassthroughBottomHeight(passthroughHeight)
    }

    private static func updateTrackingAreasRecursively(in view: NSView) {
        view.updateTrackingAreas()
        for subview in view.subviews {
            updateTrackingAreasRecursively(in: subview)
        }
    }

    private static func disableFocusRingsRecursively(in view: NSView) {
        if let control = view as? NSControl {
            control.focusRingType = .none
        }
        // The omnibar's tool / model-picker buttons are NSView subclasses (not NSControl) that draw
        // their own keyboard-focus accent ring in `draw(_:)`. They're decorative for the address-bar
        // tab cycle, irrelevant in the floating panel — set the opt-out flag.
        if let toolButton = view as? AIChatOmnibarToolButton {
            toolButton.suppressesFocusRing = true
        }
        if let modelPicker = view as? AIChatModelPickerButton {
            modelPicker.suppressesFocusRing = true
        }
        for subview in view.subviews {
            disableFocusRingsRecursively(in: subview)
        }
    }

    private func positionWindow(_ window: NSWindow) {
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        guard visible.width > 0 else { return }

        let size = window.frame.size
        let originX = visible.midX - size.width / 2
        let originY = visible.maxY - visible.height * Constants.topInsetFraction - size.height
        window.setFrameOrigin(NSPoint(x: originX, y: originY))
    }
}

// MARK: - AIChatOmnibarControllerDelegate

extension DuckAIFloatingOmnibarWindowController: AIChatOmnibarControllerDelegate {

    func aiChatOmnibarControllerDidSubmit(_ controller: AIChatOmnibarController) {
        // M5: simply dismiss the floating panel. M6 wires the actual submit hand-off.
        close()
    }

    func aiChatOmnibarController(_ controller: AIChatOmnibarController, didRequestNavigationToURL url: URL) {
        // M5 stub — URL navigation routing lands with the rest of the global submit flow.
        close()
    }

    func aiChatOmnibarController(_ controller: AIChatOmnibarController, didSelectSuggestion suggestion: AIChatSuggestion) {
        // M5 stub — suggestion selection routing lands with the rest of the global submit flow.
        close()
    }

    func aiChatOmnibarController(_ controller: AIChatOmnibarController, requestsGlobalSubmissionOf prompt: AIChatNativePrompt) {
        // Pull the user's text out of the prompt payload — the simple `.query(...)` trigger needs
        // a plain string; we re-set the full prompt afterwards so images/model/mode/reasoning
        // carry over (M7 verifies the full payload survives).
        let trimmedText: String
        if case .query(let query) = prompt.tool {
            trimmedText = query.prompt
        } else {
            trimmedText = ""
        }
        guard !trimmedText.isEmpty else { return }

        let appDelegate = NSApp.delegateTyped
        let manager = appDelegate.windowControllersManager

        // Only target a browser window that's on the user's *current* desktop space. Otherwise
        // `makeKeyAndOrderFront` would force-switch Mission Control spaces, which is jarring when
        // the user just clicked the menu-bar entry point. If none qualifies, open a fresh window
        // — that always appears on the current space.
        let activeSpaceWindow = manager.lastKeyMainWindowController(where: {
            $0.window?.isOnActiveSpace == true
        })?.window

        let target: NSWindow?
        let behavior: LinkOpenBehavior
        if let activeSpaceWindow {
            target = activeSpaceWindow
            // Existing window already has the user's tabs — open Duck.ai as a new selected tab
            // alongside them.
            behavior = .newTab(selected: true)
        } else {
            target = manager.openNewWindow()
            // Newly-created window opens with a single home-page tab. Loading Duck.ai into the
            // current tab replaces that placeholder rather than leaving it as a leftover second
            // tab in the new window.
            behavior = .currentTab
        }

        // Bring the target window forward and activate DDG. This is the *intentional* foreground
        // hand-off — we want the browser tab the user just queried to be in front. Skip the
        // re-activate-previous-app logic in `close()` by clearing the captured app first.
        previouslyActiveApp = nil
        target?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        appDelegate.aiChatTabOpener.openAIChatTab(
            with: .query(trimmedText, shouldAutoSubmit: true),
            behavior: behavior
        )
        // The simple `.query(...)` trigger above sets a text-only prompt; re-setting here with the
        // full payload preserves attachments/model/mode/reasoning. Mirrors the address-bar submit
        // path in `AIChatOmnibarController.submit()`.
        AIChatPromptHandler.shared.setData(prompt)

        close()
    }
}
