//
//  TabSwitcherPill.swift
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
import DesignResourcesKit
import DesignResourcesKitIcons

struct TabSwitcherPill: View {
    /// Natural width/height when the pill renders as a circle. Parents typically constrain to this size,
    /// or relax `maxWidth` for the expanded capsule shape.
    static let compactSize: CGFloat = 56

    let count: Int
    let onTap: () -> Void

    @StateObject private var tabCountModel: TabCountModel

    init(count: Int, onTap: @escaping () -> Void) {
        self.count = count
        self.onTap = onTap
        // Seed the model with the correct count up front so the badge
        // renders with the number on the first frame instead of flashing empty.
        _tabCountModel = StateObject(wrappedValue: TabCountModel(count: count))
    }

    var body: some View {
        Button(action: onTap) {
            GeometryReader { proxy in
                // Anything beyond the circular footprint is treated as the expanded capsule.
                let isExpanded = proxy.size.width > Self.compactSize + Metrics.compactWidthEpsilon

                content(isExpanded: isExpanded)
                    .padding(.horizontal, isExpanded ? Metrics.expandedHorizontalPadding : 0)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(Capsule())
            }
            .background(
                // Capsule degenerates to a circle when width == height,
                // so it covers both the compact and expanded shapes.
                Capsule()
                    .fill(Color(designSystemColor: .controlsFillSecondary))
            )
        }
        .buttonStyle(.plain)
        .onChange(of: count) { newValue in tabCountModel.count = newValue }
        .accessibilityLabel(Text(UserText.tabSwitcherAccessibilityLabel))
        .accessibilityValue(Text(UserText.numberOfTabs(count)))
        .accessibilityIdentifier("NTP.escapeHatch.tabSwitcher")
    }

    private func content(isExpanded: Bool) -> some View {
        HStack(spacing: isExpanded ? Metrics.contentSpacing : Metrics.contentSpacingCompact) {
            TabCountBadge(model: tabCountModel)
                .foregroundColor(Color(designSystemColor: .icons))

            if isExpanded {
                expandedContent
            }
        }
        .animation(.easeInOut(duration: 0.25), value: isExpanded)
    }

    @ViewBuilder
    private var expandedContent: some View {
        Text(UserText.escapeHatchTabSwitcherPrivateTabsLabel)
            .daxSubheadSemibold()
            .foregroundColor(Color(designSystemColor: .textPrimary))
            .lineLimit(1)
            .transition(.move(edge: .trailing).combined(with: .opacity))

        Spacer(minLength: 0)

        Image(uiImage: DesignSystemImages.Glyphs.Size24.arrowRight)
            .foregroundColor(Color(designSystemColor: .icons))
            .transition(.move(edge: .trailing).combined(with: .opacity))
    }

    private enum Metrics {
        static let compactWidthEpsilon: CGFloat = 1
        static let contentSpacing: CGFloat = 12
        static let contentSpacingCompact: CGFloat = 0
        static let expandedHorizontalPadding: CGFloat = 16
    }
}

// MARK: - Previews

#if DEBUG

#Preview("Tab switcher pill — compact") {
    HStack(spacing: 8) {
        TabSwitcherPill(count: 1, onTap: {})
            .frame(width: TabSwitcherPill.compactSize, height: TabSwitcherPill.compactSize)
        TabSwitcherPill(count: 9, onTap: {})
            .frame(width: TabSwitcherPill.compactSize, height: TabSwitcherPill.compactSize)
        TabSwitcherPill(count: 99, onTap: {})
            .frame(width: TabSwitcherPill.compactSize, height: TabSwitcherPill.compactSize)
        TabSwitcherPill(count: 100, onTap: {})
            .frame(width: TabSwitcherPill.compactSize, height: TabSwitcherPill.compactSize)
    }
    .padding()
}

#Preview("Tab switcher pill — expanded") {
    VStack(spacing: 12) {
        TabSwitcherPill(count: 1, onTap: {})
            .frame(maxWidth: .infinity)
            .frame(height: TabSwitcherPill.compactSize)
        TabSwitcherPill(count: 42, onTap: {})
            .frame(maxWidth: .infinity)
            .frame(height: TabSwitcherPill.compactSize)
        TabSwitcherPill(count: 100, onTap: {})
            .frame(maxWidth: .infinity)
            .frame(height: TabSwitcherPill.compactSize)
    }
    .padding()
}

#endif
