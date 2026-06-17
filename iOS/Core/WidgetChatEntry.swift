//
//  WidgetChatEntry.swift
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

/// Minimal mirror of a Duck.ai chat, written to the shared app group so the recent-chats
/// widget can render it.
///
/// Native chat storage (GRDB + filesystem) is intentionally not in an app group and is never
/// moved; this struct carries only what the widget displays — no messages, model, file refs,
/// or pinned state.
public struct WidgetChatEntry: Codable, Equatable {

    public let chatId: String
    public let title: String

    /// ISO-8601 string as supplied by native storage, used for ordering.
    public let lastEdit: String

    /// True when a thumbnail JPEG exists for this chat in the widget thumbnails directory.
    public let hasImageThumbnail: Bool

    public init(chatId: String, title: String, lastEdit: String, hasImageThumbnail: Bool) {
        self.chatId = chatId
        self.title = title
        self.lastEdit = lastEdit
        self.hasImageThumbnail = hasImageThumbnail
    }
}

/// Envelope written to the app group: the most-recent chats the widget renders, plus the total
/// number of chats the user has (so the widget can show an accurate count even though only the
/// top few are mirrored).
public struct WidgetChatSnapshot: Codable, Equatable {
    public let totalChatCount: Int
    public let chats: [WidgetChatEntry]

    public init(totalChatCount: Int, chats: [WidgetChatEntry]) {
        self.totalChatCount = totalChatCount
        self.chats = chats
    }
}
