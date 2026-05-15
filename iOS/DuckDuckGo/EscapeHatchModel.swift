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
import PrivacyConfig
import Core

/// Source for the live tabs array of a given browsing mode.
/// Exists so `EscapeHatchModel` can stay testable / previewable without depending on the whole `TabManaging` surface.
protocol EscapeHatchTabsSource {
    func tabsPublisher(for mode: BrowsingMode) -> AnyPublisher<[Tab], Never>
}

extension TabManager: EscapeHatchTabsSource {
    func tabsPublisher(for mode: BrowsingMode) -> AnyPublisher<[Tab], Never> {
        tabsModel(for: mode).tabsPublisher
    }
}

/// Single sink for the four escape-hatch verbs. Implemented by the object that actually fulfils the
/// actions (today: `MainViewController`). Constructors that want to build an `EscapeHatchModel` without
/// hand-bundling closures hold a weak reference to this and use `EscapeHatchModel(...,router:featureFlagger:)`.
protocol EscapeHatchActionRouter: AnyObject {
    func escapeHatchDidRequestSwitch(to tab: Tab)
    func escapeHatchDidRequestClose(_ tab: Tab)
    func escapeHatchDidRequestBurn(_ tab: Tab)
    func escapeHatchDidRequestTabSwitcher()
}

/// Model for the NTP "Return to..." escape hatch card that navigates to the most recently used tab.
/// Owns the live open-tab count and target-tab presence for `targetTab.mode` — when initialised with an
/// `EscapeHatchTabsSource`, it subscribes once and derives both fields in a single processing pass per emission.
/// Also bundles the four user-driven actions exposed by the escape-hatch UI so consumers thread a single
/// value through the editing-state / NTP / AI-chat stacks instead of a (model, actions) pair.
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
    let isActionsEnabled: Bool
    let onCardTap: () -> Void
    let onTabSwitcherTap: () -> Void
    let onCloseTab: () -> Void
    let onBurnTab: () -> Void

    private var tabsCancellable: AnyCancellable?

    init(title: String,
         subtitle: String,
         tabType: TabType,
         domain: String?,
         targetTab: Tab,
         tabsSource: some EscapeHatchTabsSource,
         isActionsEnabled: Bool,
         onCardTap: @escaping () -> Void,
         onTabSwitcherTap: @escaping () -> Void,
         onCloseTab: @escaping () -> Void,
         onBurnTab: @escaping () -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.tabType = tabType
        self.domain = domain
        self.targetTab = targetTab
        self.isActionsEnabled = isActionsEnabled
        self.onCardTap = onCardTap
        self.onTabSwitcherTap = onTabSwitcherTap
        self.onCloseTab = onCloseTab
        self.onBurnTab = onBurnTab

        subscribeToTabsSource(tabsSource)
    }

    /// Builds the model with action closures wired to a router. The router is captured weakly so holders
    /// of `EscapeHatchModel` don't pin its owner's lifecycle.
    convenience init(title: String,
                     subtitle: String,
                     tabType: TabType,
                     domain: String?,
                     targetTab: Tab,
                     tabsSource: some EscapeHatchTabsSource,
                     router: EscapeHatchActionRouter,
                     featureFlagger: FeatureFlagger) {
        self.init(
            title: title,
            subtitle: subtitle,
            tabType: tabType,
            domain: domain,
            targetTab: targetTab,
            tabsSource: tabsSource,
            isActionsEnabled: featureFlagger.isFeatureOn(.escapeHatchActions),
            onCardTap: { [weak router] in router?.escapeHatchDidRequestSwitch(to: targetTab) },
            onTabSwitcherTap: { [weak router] in router?.escapeHatchDidRequestTabSwitcher() },
            onCloseTab: { [weak router] in router?.escapeHatchDidRequestClose(targetTab) },
            onBurnTab: { [weak router] in router?.escapeHatchDidRequestBurn(targetTab) }
        )
    }

    private func subscribeToTabsSource(_ tabsSource: some EscapeHatchTabsSource) {
        tabsCancellable = tabsSource.tabsPublisher(for: targetTab.mode)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tabs in
                guard let self else { return }
                self.openTabCount = tabs.count
                self.isTargetTabPresent = tabs.contains { $0 === self.targetTab }
            }
    }
}

extension EscapeHatchModel: Equatable {
    static func == (lhs: EscapeHatchModel, rhs: EscapeHatchModel) -> Bool {
        lhs.targetTab === rhs.targetTab &&
        lhs.title == rhs.title &&
        lhs.subtitle == rhs.subtitle &&
        lhs.tabType == rhs.tabType &&
        lhs.domain == rhs.domain
    }
}
