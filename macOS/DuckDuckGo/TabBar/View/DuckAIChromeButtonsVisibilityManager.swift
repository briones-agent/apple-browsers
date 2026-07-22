//
//  DuckAIChromeButtonsVisibilityManager.swift
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

import Foundation
import PrivacyConfig
import FeatureFlags

enum DuckAIChromeButtonType {
    case duckAI
    case sidebar
}

/// PoC layout for the Duck.ai chrome control, resolved from local feature-flag overrides.
///
/// All variants are sub-modes of the `aiChatChromeSidebar` master flag: they only take effect while that
/// flag is enabled. Intended to be toggled one at a time via Debug → Feature Flag Overrides; if more than
/// one is on, precedence is A > B1 > B2.
enum DuckAIChromeLayout {
    /// Default: the "Duck.ai" title and sidebar toggle joined into one pill in the tab bar.
    case combined
    /// Approach A: title and sidebar toggle rendered as two separate buttons in the tab bar.
    case splitTabBar
    /// Approach B1: sidebar toggle relocated to the far right of the navigation bar (icon-only, with separator).
    case sidebarNavBarRight
    /// Approach B2: sidebar toggle relocated to the far left of the navigation bar's right-side group ("Ask" label).
    case sidebarNavBarLeft
    /// Approach C: a single Duck.ai button that opens a menu (New Chat / Recent Chats / Ask About Page).
    case menuButton
    /// Approach D: a single Duck.ai button that toggles the sidebar on click; "open in new tab" moves to the right-click menu.
    case singleSidebarButton

    static func resolve(_ featureFlagger: FeatureFlagger) -> DuckAIChromeLayout {
        if featureFlagger.isFeatureOn(.aiChatChromeSplitButtons) { return .splitTabBar }
        if featureFlagger.isFeatureOn(.aiChatChromeSidebarNavBarRight) { return .sidebarNavBarRight }
        if featureFlagger.isFeatureOn(.aiChatChromeSidebarNavBarLeft) { return .sidebarNavBarLeft }
        if featureFlagger.isFeatureOn(.aiChatChromeMenuButton) { return .menuButton }
        if featureFlagger.isFeatureOn(.aiChatChromeSingleSidebarButton) { return .singleSidebarButton }
        return .combined
    }

    /// The sidebar toggle lives in the navigation bar (rather than the tab bar) for these layouts.
    var relocatesSidebarToNavBar: Bool {
        self == .sidebarNavBarRight || self == .sidebarNavBarLeft
    }
}

protocol DuckAIChromeButtonsVisibilityManaging {
    func isHidden(_ button: DuckAIChromeButtonType) -> Bool
    func toggleVisibility(for button: DuckAIChromeButtonType)
    func setHidden(_ hidden: Bool, for button: DuckAIChromeButtonType)
}

final class LocalDuckAIChromeButtonsVisibilityManager: DuckAIChromeButtonsVisibilityManaging {

    private var persistor: DuckAIChromeButtonsUserDefaultsPersistor

    init(persistor: DuckAIChromeButtonsUserDefaultsPersistor = DuckAIChromeButtonsUserDefaultsPersistor()) {
        self.persistor = persistor
    }

    func isHidden(_ button: DuckAIChromeButtonType) -> Bool {
        switch button {
        case .duckAI:
            persistor.isDuckAIButtonHidden
        case .sidebar:
            persistor.isSidebarButtonHidden
        }
    }

    func toggleVisibility(for button: DuckAIChromeButtonType) {
        setHidden(!isHidden(button), for: button)
    }

    func setHidden(_ hidden: Bool, for button: DuckAIChromeButtonType) {
        let currentValue = isHidden(button)
        guard currentValue != hidden else { return }

        switch button {
        case .duckAI:
            persistor.isDuckAIButtonHidden = hidden
        case .sidebar:
            persistor.isSidebarButtonHidden = hidden
        }

        NotificationCenter.default.post(name: .duckAIChromeButtonsVisibilityChanged, object: nil)
    }
}

extension NSNotification.Name {
    static let duckAIChromeButtonsVisibilityChanged = NSNotification.Name("duck-ai-chrome.buttons-visibility-changed")
}
