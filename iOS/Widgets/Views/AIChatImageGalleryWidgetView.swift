//
//  AIChatImageGalleryWidgetView.swift
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
import WidgetKit
import Core
import DesignResourcesKit
import DesignResourcesKitIcons
import os.log

struct AIChatImageGalleryWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: AIChatImageGalleryEntry

    private var columnsPerRow: Int { family == .systemLarge ? 3 : 4 }

    /// Image slots only — the final cell is always reserved for the new-chat button.
    private var maxImages: Int {
        switch family {
        case .systemLarge: return 8    // 3×3 grid, last cell = button
        case .systemMedium: return 7   // 2×4 grid, last cell = button
        default: return 1
        }
    }

    var body: some View {
        let _ = Logger.duckAiWidget.notice("DUCKAI-WIDGET [ext/gallery VIEW] body: family=\(String(describing: family), privacy: .public) images=\(entry.images.count, privacy: .public) thumbnails=\(entry.thumbnails.count, privacy: .public)")
        return content
            .widgetContainerBackground()
    }

    @ViewBuilder
    private var content: some View {
        if entry.images.isEmpty {
            // No images yet — make the entire widget a "start a new Duck.ai chat" CTA.
            Link(destination: AIChatImageGalleryEntry.newChatDeepLink) {
                AIChatImageGalleryEmptyView()
            }
            .accessibilityLabel(UserText.recentChatsWidgetNewChatAccessibilityLabel)
        } else if family == .systemSmall {
            hero
        } else {
            grid
        }
    }

    // Small: the single most-recent image, full-bleed. New-chat button sits in the bottom-right corner.
    @ViewBuilder
    private var hero: some View {
        if let image = entry.images.first, let thumbnail = entry.thumbnails[image.imageId] {
            ZStack(alignment: .bottomTrailing) {
                Link(destination: AIChatImageGalleryEntry.deepLink(forChatId: image.chatId)) {
                    GeometryReader { geo in
                        Image(uiImage: thumbnail)
                            .resizable()
                            .useFullColorRendering()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()
                    }
                }

                Link(destination: AIChatImageGalleryEntry.newChatDeepLink) {
                    newChatChip
                }
                .accessibilityLabel(UserText.recentChatsWidgetNewChatAccessibilityLabel)
                .padding(10)
            }
        }
    }

    // Medium / Large: a full-bleed, gap-less grid. Cells tile edge to edge; the widget host clips the
    // whole thing to its container shape, so the corner cells take the widget's curvature for free.
    // The final cell is always the new-chat button.
    private var grid: some View {
        GeometryReader { geo in
            let cellWidth = geo.size.width / CGFloat(columnsPerRow)
            let totalCells = maxImages + 1
            let totalRows = Int(ceil(Double(totalCells) / Double(columnsPerRow)))
            let cellHeight = geo.size.height / CGFloat(totalRows)

            let images = Array(entry.images.prefix(maxImages))
            let cells: [GridSlot] = images.map { GridSlot.image($0) } + [GridSlot.newChat]

            VStack(spacing: 0) {
                ForEach(0..<totalRows, id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach(0..<columnsPerRow, id: \.self) { col in
                            let index = row * columnsPerRow + col
                            slotView(at: index, in: cells, width: cellWidth, height: cellHeight)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func slotView(at index: Int, in cells: [GridSlot], width: CGFloat, height: CGFloat) -> some View {
        if index < cells.count {
            switch cells[index] {
            case .image(let image):
                Link(destination: AIChatImageGalleryEntry.deepLink(forChatId: image.chatId)) {
                    imageCell(for: image, width: width, height: height)
                }
            case .newChat:
                Link(destination: AIChatImageGalleryEntry.newChatDeepLink) {
                    newChatCell(width: width, height: height)
                }
                .accessibilityLabel(UserText.recentChatsWidgetNewChatAccessibilityLabel)
            }
        } else {
            // Past the end of `cells` (only ever the trailing slots of a partial final row): fill with
            // surface so the grid keeps a clean rectangular fill.
            Color(designSystemColor: .surface)
                .frame(width: width, height: height)
        }
    }

    private func imageCell(for image: WidgetImageEntry, width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            Color(designSystemColor: .surface)
            if let thumbnail = entry.thumbnails[image.imageId] {
                Image(uiImage: thumbnail)
                    .resizable()
                    .useFullColorRendering()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: width, height: height)
            }
        }
        .frame(width: width, height: height)
        .clipped()
    }

    private func newChatCell(width: CGFloat, height: CGFloat) -> some View {
        let iconSize = min(width, height) * 0.4
        return ZStack {
            Color(designSystemColor: .accent).opacity(0.12)
            Image(uiImage: DesignSystemImages.Glyphs.Size24.aiChatAdd)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(Color(designSystemColor: .accent))
                .frame(width: iconSize, height: iconSize)
        }
        .frame(width: width, height: height)
        .clipped()
    }

    // Small-widget overlay version of the new-chat affordance — a Duck.ai-tinted icon chip.
    private var newChatChip: some View {
        Image(uiImage: DesignSystemImages.Glyphs.Size24.aiChatAdd)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .foregroundStyle(Color(designSystemColor: .accent))
            .frame(width: 18, height: 18)
            .padding(8)
            .background(.ultraThinMaterial, in: Circle())
    }
}

private enum GridSlot {
    case image(WidgetImageEntry)
    case newChat
}

// MARK: - Empty state

private struct AIChatImageGalleryEmptyView: View {
    var body: some View {
        VStack(spacing: 10) {
            DuckAiLogo(size: 52)
            Text(UserText.imageGalleryWidgetEmptyMessage)
                .daxFootnoteRegular()
                .multilineTextAlignment(.center)
                .foregroundStyle(Color(designSystemColor: .textSecondary))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(16)
    }
}
