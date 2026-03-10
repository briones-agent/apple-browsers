//
//  AIChatDisappearanceValidator.swift
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

import AIChat
import Core
import Persistence

/// Validates that Duck.ai chats are not unexpectedly disappearing over time.
///
/// On app background, saves the current chat count.
/// On app foreground, if 7+ days have passed, compares the saved count
/// with the current count and fires a pixel if chats have disappeared.
///
/// Callers use the synchronous `resume()` / `suspend()` entry points;
/// the validator manages its own async execution internally.
protocol AIChatDisappearanceValidating {
    func resume()
    func suspend()
}

struct AIChatDisappearanceValidator: AIChatDisappearanceValidating {

    private let storage: ThrowingKeyValueStoring
    private let suggestionsReaderProvider: @MainActor @Sendable () -> SuggestionsReading
    private let pixelFiring: PixelFiring.Type

    enum Keys {
        static let savedChatCount = "aichat_disappearance_validator_saved_chat_count"
        static let savedTimestamp = "aichat_disappearance_validator_saved_timestamp"
    }

    static let sevenDaysInSeconds: TimeInterval = 7 * 24 * 60 * 60

    init(storage: ThrowingKeyValueStoring,
         suggestionsReaderProvider: @escaping @MainActor @Sendable () -> SuggestionsReading,
         pixelFiring: PixelFiring.Type = Pixel.self) {
        self.storage = storage
        self.suggestionsReaderProvider = suggestionsReaderProvider
        self.pixelFiring = pixelFiring
    }

    // MARK: - Synchronous entry points

    /// Call when the app enters foreground. Internally schedules async check.
    func resume() {
        let storage = storage
        let readerProvider = suggestionsReaderProvider
        let pixelFiring = pixelFiring
        Task { @MainActor in
            let validator = AIChatDisappearanceValidator(storage: storage,
                                                         suggestionsReaderProvider: readerProvider,
                                                         pixelFiring: pixelFiring)
            await validator.checkForUnexpectedDeletion()
        }
    }

    /// Call when the app enters background. Internally schedules async snapshot.
    func suspend() {
        let storage = storage
        let readerProvider = suggestionsReaderProvider
        Task { @MainActor in
            let validator = AIChatDisappearanceValidator(storage: storage,
                                                         suggestionsReaderProvider: readerProvider)
            await validator.saveChatSnapshot()
        }
    }

    // MARK: - Async implementation

    /// Saves the current chat count.
    @MainActor
    func saveChatSnapshot() async {
        let reader = suggestionsReaderProvider()
        let result = await reader.fetchSuggestions(query: nil, maxChats: 100)
        reader.tearDown()

        if case .success(let suggestions) = result {
            let count = suggestions.pinned.count + suggestions.recent.count
            try? storage.set(count, forKey: Keys.savedChatCount)
            try? storage.set(Date().timeIntervalSince1970, forKey: Keys.savedTimestamp)
        }
    }

    /// Checks if chats have unexpectedly disappeared since the last snapshot.
    /// Only runs if 7+ days have passed since the last save.
    @MainActor
    func checkForUnexpectedDeletion() async {
        guard let savedCount = try? storage.object(forKey: Keys.savedChatCount) as? Int,
              let savedTimestamp = try? storage.object(forKey: Keys.savedTimestamp) as? Double else {
            return
        }

        let elapsed = Date().timeIntervalSince1970 - savedTimestamp
        guard elapsed >= Self.sevenDaysInSeconds else { return }
        guard savedCount > 0 else {
            clearSavedSnapshot()
            return
        }

        let reader = suggestionsReaderProvider()
        let result = await reader.fetchSuggestions(query: nil, maxChats: 100)
        reader.tearDown()

        if case .success(let suggestions) = result {
            let currentCount = suggestions.pinned.count + suggestions.recent.count
            if currentCount < savedCount {
                pixelFiring.fire(.aiChatChatsDisappearedAfterWeek, withAdditionalParameters: [:])
            }
        }

        clearSavedSnapshot()
    }

    private func clearSavedSnapshot() {
        try? storage.removeObject(forKey: Keys.savedChatCount)
        try? storage.removeObject(forKey: Keys.savedTimestamp)
    }
}
