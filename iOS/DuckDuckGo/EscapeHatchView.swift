//
//  EscapeHatchView.swift
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

import SwiftUI

/// Bundles the "Return to tab" card and the tab switcher pill so callers render them as a single unit.
struct EscapeHatchView: View {
    @ObservedObject var model: EscapeHatchModel
    let onCardTap: () -> Void
    let onTabSwitcherTap: () -> Void
    let onCloseTab: () -> Void
    let onBurnTab: () -> Void

    var body: some View {
        HStack(spacing: Metrics.spacing) {
            ReturnToTabCard(model: model, onTap: onCardTap, onCloseTab: onCloseTab, onBurnTab: onBurnTab)
            TabSwitcherPill(count: model.openTabCount, onTap: onTabSwitcherTap)
        }
    }

    private enum Metrics {
        static let spacing: CGFloat = 8
    }
}

#Preview("Escape hatch — regular tab") {
    EscapeHatchView(
        model: EscapeHatchModel(
            title: "Tokamak - Wikipedia",
            subtitle: "en.wikipedia.org/wiki/Tokamak",
            tabType: .regular,
            domain: "en.wikipedia.org",
            targetTab: Tab(fireTab: false),
            tabCountSource: .staticTabCountSource(9)
        ),
        onCardTap: {},
        onTabSwitcherTap: {},
        onCloseTab: {},
        onBurnTab: {}
    )
    .padding()
}

#Preview("Escape hatch — duck.ai") {
    EscapeHatchView(
        model: EscapeHatchModel(
            title: "Good Dog Name Ideas",
            subtitle: "Duck.ai",
            tabType: .aiChat,
            domain: nil,
            targetTab: Tab(fireTab: false),
            tabCountSource: .staticTabCountSource(99)
        ),
        onCardTap: {},
        onTabSwitcherTap: {},
        onCloseTab: {},
        onBurnTab: {}
    )
    .padding()
}
