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

    var body: some View {
        DesignSystemWidgetContainerView {
            if !entry.isEnabled || entry.chats.isEmpty {
                emptyState
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(entry.chats.prefix(maxRows)), id: \.chatId) { chat in
                        Link(destination: AIChatRecentChatsEntry.deepLink(forChatId: chat.chatId)) {
                            AIChatChatRowView(chat: chat, thumbnail: entry.thumbnails[chat.chatId])
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(UserText.recentChatsWidgetGalleryDisplayName)
                .daxSubheadSemibold()
                .foregroundStyle(Color(designSystemColor: .textPrimary))
            Text(UserText.recentChatsWidgetEmptyMessage)
                .daxCaption()
                .foregroundStyle(Color(designSystemColor: .textSecondary))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct AIChatChatRowView: View {
    let chat: WidgetChatEntry
    let thumbnail: UIImage?

    var body: some View {
        HStack(spacing: 8) {
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .useFullColorRendering()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            Text(chat.title)
                .daxBodyRegular()
                .foregroundStyle(Color(designSystemColor: .textPrimary))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }
}
