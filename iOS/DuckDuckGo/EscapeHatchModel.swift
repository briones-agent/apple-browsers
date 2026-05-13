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

/// Source for the live open-tab count of a given browsing mode.
/// Exists so `EscapeHatchModel` can stay testable / previewable without depending on the whole `TabManaging` surface.
protocol EscapeHatchTabCountSource {
    func openTabCountPublisher(for mode: BrowsingMode) -> AnyPublisher<Int, Never>
}

/// Model for the NTP "Return to..." escape hatch card that navigates to the most recently used tab.
/// Owns the live open-tab count for `targetTab.mode` — when initialised with an `EscapeHatchTabCountSource`,
/// it subscribes to that source and keeps `openTabCount` in sync.
final class EscapeHatchModel: ObservableObject {

    enum TabType {
        case regular
        case aiChat
        case fire
    }

    @Published private(set) var openTabCount: Int = 0
    let title: String
    let subtitle: String
    let tabType: TabType
    let domain: String?
    let targetTab: Tab

    private var openTabCountCancellable: AnyCancellable?

    init(title: String, subtitle: String, tabType: TabType, domain: String?, targetTab: Tab, tabCountSource: EscapeHatchTabCountSource? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.tabType = tabType
        self.domain = domain
        self.targetTab = targetTab
    }

    private func subscribeToTasIfPossible(tabCountSource: EscapeHatchTabCountSource? = nil) {
        guard let tabCountSource else {
            return
        }

        openTabCountCancellable = tabCountSource.openTabCountPublisher(for: targetTab.mode)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.openTabCount = $0
            }
    }
}

extension TabManager: EscapeHatchTabCountSource {
    func openTabCountPublisher(for mode: BrowsingMode) -> AnyPublisher<Int, Never> {
        tabsModel(for: mode).tabsPublisher
            .map(\.count)
            .eraseToAnyPublisher()
    }
}

#if DEBUG
/// Preview-only count source — emits a fixed value once and completes.
struct StaticEscapeHatchTabCountSource: EscapeHatchTabCountSource {
    let count: Int
    func openTabCountPublisher(for mode: BrowsingMode) -> AnyPublisher<Int, Never> {
        Just(count).eraseToAnyPublisher()
    }
}

extension EscapeHatchTabCountSource where Self == StaticEscapeHatchTabCountSource {
    static func staticTabCountSource(_ count: Int) -> Self {
        StaticEscapeHatchTabCountSource(count: count)
    }
}

#endif
