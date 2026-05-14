//
//  EscapeHatchModel+Previews.swift
//  DuckDuckGo
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
import Combine

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

/// Preview Helper
extension EscapeHatchActions {
    static var noop: EscapeHatchActions {
        EscapeHatchActions(onCardTap: {}, onTabSwitcherTap: {}, onCloseTab: {}, onBurnTab: {})
    }
}

#endif
