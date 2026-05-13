//
//  EscapeHatchModel.swift
//  DuckDuckGo
//
//  Copyright © 2025 DuckDuckGo. All rights reserved.
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
import Combine

/// Source for the live tabs array of a given browsing mode.
/// Exists so `EscapeHatchModel` can stay testable / previewable without depending on the whole `TabManaging` surface.
protocol EscapeHatchTabsSource {
    func tabsPublisher(for mode: BrowsingMode) -> AnyPublisher<[Tab], Never>
}

/// Bundles the four user-driven actions exposed by the escape-hatch UI so they thread through
/// the editing-state / NTP / AI-chat stacks as a single value instead of four parallel closures.
struct EscapeHatchActions {
    let onCardTap: () -> Void
    let onTabSwitcherTap: () -> Void
    let onCloseTab: () -> Void
    let onBurnTab: () -> Void
}

/// Model for the NTP "Return to..." escape hatch card that navigates to the most recently used tab.
/// Owns the live open-tab count and target-tab presence for `targetTab.mode` — when initialised with an
/// `EscapeHatchTabsSource`, it subscribes once and derives both fields in a single processing pass per emission.
final class EscapeHatchModel: ObservableObject {

    enum TabType {
        case regular
        case aiChat
        case fire
    }

    @Published private(set) var openTabCount: Int = 0
    @Published private(set) var isTargetTabPresent: Bool = true
    let title: String
    let subtitle: String
    let tabType: TabType
    let domain: String?
    let targetTab: Tab

    private var tabsCancellable: AnyCancellable?

    init(title: String, subtitle: String, tabType: TabType, domain: String?, targetTab: Tab, tabsSource: EscapeHatchTabsSource? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.tabType = tabType
        self.domain = domain
        self.targetTab = targetTab

        if let tabsSource {
            subscribeToTabsSource(tabsSource)
        }
    }

    private func subscribeToTabsSource(_ tabsSource: EscapeHatchTabsSource) {
        tabsCancellable = tabsSource.tabsPublisher(for: targetTab.mode)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tabs in
                guard let self else { return }
                self.openTabCount = tabs.count
                self.isTargetTabPresent = tabs.contains { $0 === self.targetTab }
            }
    }
}

extension TabManager: EscapeHatchTabsSource {
    func tabsPublisher(for mode: BrowsingMode) -> AnyPublisher<[Tab], Never> {
        tabsModel(for: mode).tabsPublisher
    }
}

#if DEBUG
/// Preview-only source — emits a fixed tabs array once. Include the target tab if presence should read `true`.
struct StaticEscapeHatchTabsSource: EscapeHatchTabsSource {
    let tabs: [Tab]
    func tabsPublisher(for mode: BrowsingMode) -> AnyPublisher<[Tab], Never> {
        Just(tabs).eraseToAnyPublisher()
    }
}

extension EscapeHatchTabsSource where Self == StaticEscapeHatchTabsSource {
    /// Synthesises an array of `count` tabs that includes `targetTab`, so the model reads `isTargetTabPresent == true`.
    static func staticTabsSource(count: Int, includes targetTab: Tab) -> Self {
        let padding = max(count - 1, 0)
        let tabs = (0..<padding).map { _ in Tab(fireTab: false) } + [targetTab]
        return StaticEscapeHatchTabsSource(tabs: tabs)
    }
}

#endif
