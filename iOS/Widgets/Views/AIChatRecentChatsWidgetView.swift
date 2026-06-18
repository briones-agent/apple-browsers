//
//  AIChatRecentChatsWidgetView.swift
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

struct AIChatRecentChatsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: AIChatRecentChatsEntry

    private var maxRows: Int { family == .systemLarge ? 6 : 3 }
    private var rowSpacing: CGFloat { family == .systemLarge ? 14 : 11 }

    var body: some View {
        let _ = Logger.duckAiWidget.notice("DUCKAI-WIDGET [ext/chats VIEW] body: family=\(String(describing: family), privacy: .public) chats=\(entry.chats.count, privacy: .public)")
        return DesignSystemWidgetContainerView {
            if entry.chats.isEmpty {
                AIChatRecentChatsEmptyView()
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    AIChatRecentChatsHeaderView()
                        .padding(.bottom, family == .systemLarge ? 14 : 10)

                    VStack(alignment: .leading, spacing: rowSpacing) {
                        ForEach(entry.chats.prefix(maxRows), id: \.chatId) { chat in
                            Link(destination: AIChatRecentChatsEntry.deepLink(forChatId: chat.chatId)) {
                                AIChatChatRowView(chat: chat)
                            }
                        }
                    }

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }
}

// MARK: - Header

private struct AIChatRecentChatsHeaderView: View {
    var body: some View {
        HStack(spacing: 8) {
            DuckAiLogo(size: 25)

            Text(UserText.recentChatsWidgetBrandTitle)
                .daxBodyBold()
                .foregroundStyle(Color(designSystemColor: .textPrimary))

            Spacer(minLength: 8)

            // Opens a brand-new Duck.ai chat. Uses the "new chat" glyph (chat bubble + plus).
            Link(destination: AIChatRecentChatsEntry.newChatDeepLink) {
                Image(uiImage: DesignSystemImages.Glyphs.Size24.aiChatAdd)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(Color(designSystemColor: .accent))
                    .frame(width: 25, height: 25)
                    .frame(width: 30, height: 30)
                    .background(Color(designSystemColor: .accent).opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .accessibilityLabel(UserText.recentChatsWidgetNewChatAccessibilityLabel)
        }
    }
}

// MARK: - Row

struct AIChatChatRowView: View {
    let chat: WidgetChatEntry

    private let iconSize: CGFloat = 26

    var body: some View {
        HStack(spacing: 10) {
            icon
            Text(chat.title)
                .daxSubheadRegular()
                .foregroundStyle(Color(designSystemColor: .textPrimary))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var icon: some View {
        if chat.pinned {
            glyphIcon(DesignSystemImages.Glyphs.Size16.pin)
        } else if chat.isImageGeneration {
            symbolIcon("photo")
        } else {
            glyphIcon(DesignSystemImages.Glyphs.Size24.chat)
        }
    }

    private func glyphIcon(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .foregroundStyle(Color(designSystemColor: .accent))
            .frame(width: 20, height: 20)
            .frame(width: iconSize, height: iconSize)
    }

    private func symbolIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 17, weight: .regular))
            .foregroundStyle(Color(designSystemColor: .accent))
            .frame(width: iconSize, height: iconSize)
    }
}

// MARK: - Empty state

private struct AIChatRecentChatsEmptyView: View {
    var body: some View {
        VStack(spacing: 10) {
            DuckAiLogo(size: 52)
            Text(UserText.recentChatsWidgetEmptyMessage)
                .daxFootnoteRegular()
                .multilineTextAlignment(.center)
                .foregroundStyle(Color(designSystemColor: .textSecondary))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

// MARK: - Logo

/// The Duck.ai icon, rendered the same way as the Quick Actions widget: the monochrome glyph
/// tinted with the design-system icon color, no background.
struct DuckAiLogo: View {
    var size: CGFloat = 30

    var body: some View {
        Image(uiImage: DesignSystemImages.Glyphs.Size24.aiChat)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .foregroundStyle(Color(designSystemColor: .icons))
            .frame(width: size, height: size)
    }
}
