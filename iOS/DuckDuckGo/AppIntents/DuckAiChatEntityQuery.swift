//
//  DuckAiChatEntityQuery.swift
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
import Foundation
import AIChat
import DuckAiDataStore

/// Reads Duck.ai chats from native storage to build `DuckAiChatEntity` values. Registered as an
/// App Intents dependency at launch (see `Launching`) so the system-instantiated query can reach
/// storage without a global singleton.
@available(iOS 18.4, *)
final class DuckAiChatSearchReader {

    private let storage: DuckAiNativeStorageHandling

    init(storage: DuckAiNativeStorageHandling) {
        self.storage = storage
    }

    func entity(forChatId id: String) -> DuckAiChatEntity? {
        guard let record = try? storage.getChat(chatId: id) else { return nil }
        return DuckAiChatEntity.make(from: record)
    }

    func recentEntities(limit: Int) -> [DuckAiChatEntity] {
        guard let records = try? storage.getAllChats() else { return [] }
        return records
            .compactMap(DuckAiChatEntity.make(from:))
            .sorted { ($0.lastEdit ?? .distantPast) > ($1.lastEdit ?? .distantPast) }
            .prefix(limit)
            .map { $0 }
    }
}

/// Resolves `DuckAiChatEntity` instances for Siri / Spotlight. Entity *matching* is performed by the
/// Spotlight semantic index (populated by `DuckAiChatSpotlightIndexer`); this query hydrates the
/// entities the system asks about and supplies recents as suggestions.
@available(iOS 18.4, *)
struct DuckAiChatEntityQuery: EntityQuery {

    @Dependency
    private var reader: DuckAiChatSearchReader

    func entities(for identifiers: [DuckAiChatEntity.ID]) async throws -> [DuckAiChatEntity] {
        identifiers.compactMap { reader.entity(forChatId: $0) }
    }

    func suggestedEntities() async throws -> [DuckAiChatEntity] {
        reader.recentEntities(limit: 10)
    }
}

/// Launch-time setup for Siri / Spotlight search. Registers the storage reader as an App Intents
/// dependency so the system-instantiated `DuckAiChatEntityQuery` can resolve entities. Kept here so
/// the composition root doesn't have to import AppIntents directly.
@available(iOS 18.4, *)
enum DuckAiSiriSearchSetup {
    static func registerDependencies(storage: DuckAiNativeStorageHandling) {
        AppDependencyManager.shared.add(dependency: DuckAiChatSearchReader(storage: storage))
    }
}
