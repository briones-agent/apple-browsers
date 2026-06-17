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

struct AIChatRecentChatsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: AIChatRecentChatsEntry

    private var maxRows: Int { family == .systemLarge ? 6 : 3 }
    private var rowSpacing: CGFloat { family == .systemLarge ? 14 : 11 }

    var body: some View {
        DesignSystemWidgetContainerView {
            if !entry.isEnabled || entry.chats.isEmpty {
                AIChatRecentChatsEmptyView()
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    AIChatRecentChatsHeaderView(count: entry.totalChatCount)
                        .padding(.bottom, family == .systemLarge ? 14 : 10)

                    VStack(alignment: .leading, spacing: rowSpacing) {
                        ForEach(entry.chats.prefix(maxRows), id: \.chatId) { chat in
                            Link(destination: AIChatRecentChatsEntry.deepLink(forChatId: chat.chatId)) {
                                AIChatChatRowView(chat: chat, thumbnail: entry.thumbnails[chat.chatId])
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
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            DuckAiLogo()
                .frame(width: 24, height: 24)

            Text(UserText.recentChatsWidgetBrandTitle)
                .daxBodyBold()
                .foregroundStyle(Color(designSystemColor: .textPrimary))

            Spacer(minLength: 8)

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("\(count)")
                    .daxBodyBold()
                    .foregroundStyle(Color(designSystemColor: .accent))
                Text(UserText.recentChatsWidgetCountLabel)
                    .daxFootnoteRegular()
                    .foregroundStyle(Color(designSystemColor: .textSecondary))
            }
            .accessibilityElement(children: .combine)
        }
    }
}

// MARK: - Row

struct AIChatChatRowView: View {
    let chat: WidgetChatEntry
    let thumbnail: UIImage?

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
        if let thumbnail {
            Image(uiImage: thumbnail)
                .resizable()
                .useFullColorRendering()
                .aspectRatio(contentMode: .fill)
                .frame(width: iconSize, height: iconSize)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            Image(systemName: "bubble.left.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(designSystemColor: .accent))
                .frame(width: iconSize, height: iconSize)
                .background(Color(designSystemColor: .accent).opacity(0.12), in: Circle())
        }
    }
}

// MARK: - Empty state

private struct AIChatRecentChatsEmptyView: View {
    var body: some View {
        VStack(spacing: 10) {
            DuckAiLogo()
                .frame(width: 40, height: 40)
            Text(UserText.recentChatsWidgetEmptyMessage)
                .daxFootnoteRegular()
                .multilineTextAlignment(.center)
                .foregroundStyle(Color(designSystemColor: .textSecondary))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

// MARK: - Logo

/// The Duck.ai brand mark, rendered full-color on standard widgets and tintable on accented/
/// Lock Screen render modes.
private struct DuckAiLogo: View {
    var body: some View {
        ResizableTintableImage(fullColor: UIImage(resource: .widgetDaxLogo),
                               tintable: UIImage(resource: .widgetDaxLogoTinted))
    }
}
