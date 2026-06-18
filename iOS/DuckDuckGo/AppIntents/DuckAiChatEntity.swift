//
//  DuckAiChatEntity.swift
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

import AppIntents
import CoreSpotlight
import Foundation
import AIChat
import DuckAiDataStore

/// System-facing representation of a single Duck.ai conversation, used to make chats discoverable
/// through Siri / Spotlight semantic search via `IndexedEntity`.
///
/// Conversations are indexed by their concatenated message text (`contents`, mapped to the
/// Spotlight `textContent` attribute) so a query like "the chat about potatoes" resolves by meaning.
/// The `@Property(indexingKey:)` initializer this entity uses requires iOS 18.4+; semantic-match
/// quality is best on iOS 27 / Apple Intelligence devices.
@available(iOS 18.4, *)
struct DuckAiChatEntity: IndexedEntity {

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Duck.ai Conversation"

    /// The Duck.ai `chatId`; used to open the conversation via the existing deep link.
    let id: String

    let title: String

    /// Last-edit timestamp, parsed from the stored ISO-8601 string when available.
    let lastEdit: Date?

    /// Concatenated visible message text, mapped to Spotlight's `textContent` so it participates in
    /// the semantic index. Capped by `make(from:)`. `AttributedString` is required by the
    /// `@Property(indexingKey:)` initializer (the `String`-typed variant does not exist).
    @Property(indexingKey: \.textContent)
    var contents: AttributedString?

    init(id: String, title: String, lastEdit: Date?, contents: AttributedString?) {
        self.id = id
        self.title = title
        self.lastEdit = lastEdit
        self.contents = contents
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: Self.subtitle(forLastEdit: lastEdit))
    }

    static var defaultQuery = DuckAiChatEntityQuery()
}

@available(iOS 18.4, *)
extension DuckAiChatEntity {

    /// Upper bound on indexed text per conversation, keeping the Spotlight index bounded.
    static let maxIndexedTextLength = 8_000

    /// Builds an entity from a stored chat record. Returns nil when the record can't be decoded — a
    /// single bad blob must never abort a full re-index.
    static func make(from record: DuckAiChatRecord) -> DuckAiChatEntity? {
        guard let decoded = try? DuckAiChat.decodeSearchableText(from: record.data) else {
            return nil
        }
        let capped = String(decoded.searchableText.prefix(maxIndexedTextLength))
        return DuckAiChatEntity(id: decoded.chat.chatId,
                                title: decoded.chat.title,
                                lastEdit: date(fromISO8601: decoded.chat.lastEdit),
                                contents: capped.isEmpty ? nil : AttributedString(capped))
    }

    /// Parses the FE's ISO-8601 `lastEdit` string, tolerating presence or absence of fractional seconds.
    static func date(fromISO8601 string: String) -> Date? {
        isoWithFractionalSeconds.date(from: string) ?? isoPlain.date(from: string)
    }

    private static let isoWithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoPlain = ISO8601DateFormatter()

    private static func subtitle(forLastEdit date: Date?) -> LocalizedStringResource {
        guard let date else { return "Duck.ai" }
        return "Edited \(date.formatted(.relative(presentation: .named)))"
    }
}
