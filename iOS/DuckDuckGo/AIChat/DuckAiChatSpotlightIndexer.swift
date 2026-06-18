//
//  DuckAiChatSpotlightIndexer.swift
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
import CoreSpotlight
import Core
import AIChat
import DuckAiDataStore
import PrivacyConfig
import os.log

/// Non-availability-gated handle so callers (e.g. `AIChatService`) can hold and drive the indexer
/// without an `if #available` at every call site. The concrete implementation is iOS 18+.
protocol DuckAiChatIndexing: AnyObject {
    /// Begins observing storage + settings and performs an initial index pass. Call once at launch.
    func start()
    /// Re-runs indexing (e.g. on app foreground / background).
    func refresh()
}

/// Abstraction over the Spotlight index so the indexer can be unit-tested without a live index.
@available(iOS 18.4, *)
protocol ChatSearchIndexing {
    func replaceAll(with entities: [DuckAiChatEntity]) async throws
    func deleteAll() async throws
}

/// Default `ChatSearchIndexing` backed by a dedicated Core Spotlight index.
@available(iOS 18.4, *)
struct DefaultChatSearchIndex: ChatSearchIndexing {

    static let indexName = "com.duckduckgo.duckai.chats"

    private let index: CSSearchableIndex

    init(index: CSSearchableIndex = CSSearchableIndex(name: DefaultChatSearchIndex.indexName)) {
        self.index = index
    }

    func replaceAll(with entities: [DuckAiChatEntity]) async throws {
        // Full replace keeps the index consistent with storage (adds, edits and removals) without
        // per-identifier deletion bookkeeping. Chat counts are small enough that a debounced full
        // re-index is acceptable for v1; optimise to incremental later if needed.
        try await index.deleteAllSearchableItems()
        guard !entities.isEmpty else { return }
        try await index.indexAppEntities(entities)
    }

    func deleteAll() async throws {
        try await index.deleteAllSearchableItems()
    }
}

/// Mirrors Duck.ai conversations into the Core Spotlight semantic index so Siri / Spotlight can find
/// them by content. One-way and gated: indexing only happens while the feature flag is on and the
/// user setting (itself AND-gated on the global AI Chat toggle) is enabled; when the gate is off the
/// index is wiped. Implicitly disabled when native storage is absent (`storage` is nil).
@available(iOS 18.4, *)
final class DuckAiChatSpotlightIndexer: DuckAiChatIndexing {

    private let storage: DuckAiNativeObservableStorage?
    private let settings: AIChatSettingsProvider
    private let featureFlagger: FeatureFlagger
    private let index: ChatSearchIndexing
    private let notificationCenter: NotificationCenter
    private let debounce: DispatchQueue.SchedulerTimeType.Stride
    private let logger = Logger(subsystem: "com.duckduckgo.mobile.ios", category: "DuckAiSiriSearch")

    private var cancellable: AnyCancellable?
    private var settingsObserver: NSObjectProtocol?

    init(storage: DuckAiNativeObservableStorage?,
         settings: AIChatSettingsProvider,
         featureFlagger: FeatureFlagger,
         index: ChatSearchIndexing = DefaultChatSearchIndex(),
         notificationCenter: NotificationCenter = .default,
         debounce: DispatchQueue.SchedulerTimeType.Stride = .seconds(2)) {
        self.storage = storage
        self.settings = settings
        self.featureFlagger = featureFlagger
        self.index = index
        self.notificationCenter = notificationCenter
        self.debounce = debounce
    }

    deinit {
        if let settingsObserver {
            notificationCenter.removeObserver(settingsObserver)
        }
    }

    func start() {
        // Debounce: the FE can write many times in quick succession; coalesce into one re-index.
        cancellable = storage?.chatsPublisher()
            .debounce(for: debounce, scheduler: DispatchQueue.global(qos: .utility))
            .sink(receiveCompletion: { _ in }, receiveValue: { [weak self] _ in
                self?.refresh()
            })

        // The same notification is posted when the global AI Chat toggle or the Siri-search toggle
        // changes, so one observer drives both the "re-index" and "wipe" paths.
        settingsObserver = notificationCenter.addObserver(forName: .aiChatSettingsChanged,
                                                          object: nil,
                                                          queue: nil) { [weak self] _ in
            self?.refresh()
        }

        refresh()
    }

    func refresh() {
        Task { [weak self] in
            await self?.reindex()
        }
    }

    /// Single source of truth for whether indexing should be active right now.
    /// `isSiriChatSearchEnabled` already ANDs the global AI Chat toggle, so turning AI Chat off here
    /// also tears the index down.
    var isEnabled: Bool {
        featureFlagger.isFeatureOn(.aiChatSiriSearch) && settings.isSiriChatSearchEnabled
    }

    /// Rebuilds the index from current storage, or wipes it when the gate is off. Exposed for tests.
    func reindex() async {
        guard let storage else { return }

        guard isEnabled else {
            try? await index.deleteAll()
            return
        }

        do {
            let records = try storage.getAllChats()
            let entities = records.compactMap(DuckAiChatEntity.make(from:))
            try await index.replaceAll(with: entities)
        } catch {
            logger.error("DuckAiChatSpotlightIndexer reindex failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
