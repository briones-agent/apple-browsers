//
//  DuckAiChatSpotlightIndexerTests.swift
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

import XCTest
import Combine
import Core
import AIChat
import DuckAiDataStore
@testable import DuckDuckGo

@available(iOS 18.4, *)
final class DuckAiChatSpotlightIndexerTests: XCTestCase {

    // MARK: - Test doubles

    final class FakeChatSearchIndex: ChatSearchIndexing {
        private(set) var indexed: [DuckAiChatEntity] = []
        private(set) var replaceAllCallCount = 0
        private(set) var deleteAllCallCount = 0

        func replaceAll(with entities: [DuckAiChatEntity]) async throws {
            replaceAllCallCount += 1
            indexed = entities
        }

        func deleteAll() async throws {
            deleteAllCallCount += 1
            indexed = []
        }
    }

    final class MockObservableStorage: DuckAiNativeStorageHandling, DuckAiNativeChatsObserving {
        var chats: [DuckAiChatRecord] = []
        private let subject = CurrentValueSubject<[DuckAiChatRecord], Error>([])

        func emit() { subject.send(chats) }
        func chatsPublisher() -> AnyPublisher<[DuckAiChatRecord], Error> { subject.eraseToAnyPublisher() }

        func putChat(chatId: String, data: Data) throws {}
        func putChats(_ chats: [DuckAiChatRecord]) throws {}
        func getChat(chatId: String) throws -> DuckAiChatRecord? { chats.first { $0.chatId == chatId } }
        func getAllChats() throws -> [DuckAiChatRecord] { chats }
        func deleteChat(chatId: String) throws {}
        func deleteAllChats() throws {}

        func putFile(uuid: String, chatId: String, data: Data) throws {}
        func getFile(uuid: String) throws -> DuckAiFileContent? { nil }
        func listFiles() throws -> [DuckAiFileMetadata] { [] }
        func deleteFile(uuid: String) throws {}
        func deleteFiles(chatId: String) throws {}
        func deleteAllFiles() throws {}

        func putEntry(key: String, value: Any) throws {}
        func getEntry(key: String) throws -> Any? { nil }
        func getAllEntries() throws -> [String: Any] { [:] }
        func deleteEntry(key: String) throws {}
        func deleteAllEntries() throws {}
        func replaceAllEntries(_ entries: [String: Any]) throws {}

        func isMigrationDone() throws -> Bool { true }
        func isMigrationDone(key: String) throws -> Bool { true }
        func markMigrationDone(key: String) throws {}
    }

    // MARK: - Helpers

    private func chatRecord(id: String, title: String, text: String,
                            lastEdit: String = "2026-01-01T00:00:00.000Z") -> DuckAiChatRecord {
        let json = """
            {"chatId": "\(id)", "title": "\(title)", "model": "gpt", "lastEdit": "\(lastEdit)", "pinned": false,
             "messages": [{"role": "user", "content": "\(text)"}]}
            """
        return DuckAiChatRecord(chatId: id, data: Data(json.utf8))
    }

    private func makeIndexer(storage: MockObservableStorage?,
                             flagEnabled: Bool = true,
                             settingEnabled: Bool = true,
                             index: FakeChatSearchIndex) -> DuckAiChatSpotlightIndexer {
        let settings = MockAIChatSettingsProvider(isAIChatEnabled: true, isSiriChatSearchEnabled: settingEnabled)
        let flagger = MockFeatureFlagger(enabledFeatureFlags: flagEnabled ? [.aiChatSiriSearch] : [])
        return DuckAiChatSpotlightIndexer(storage: storage,
                                          settings: settings,
                                          featureFlagger: flagger,
                                          index: index,
                                          notificationCenter: NotificationCenter())
    }

    // MARK: - Tests

    func testWhenEnabledThenReindexIndexesAllChats() async {
        let storage = MockObservableStorage()
        storage.chats = [chatRecord(id: "a", title: "Potatoes", text: "how to grow potatoes"),
                         chatRecord(id: "b", title: "Soup", text: "tomato soup recipe")]
        let index = FakeChatSearchIndex()
        let indexer = makeIndexer(storage: storage, index: index)

        await indexer.reindex()

        XCTAssertEqual(Set(index.indexed.map(\.id)), ["a", "b"])
        XCTAssertEqual(index.deleteAllCallCount, 0)
    }

    func testWhenIndexedThenConversationContentIsSearchable() async {
        let storage = MockObservableStorage()
        storage.chats = [chatRecord(id: "a", title: "Garden", text: "I planted potatoes today")]
        let index = FakeChatSearchIndex()
        let indexer = makeIndexer(storage: storage, index: index)

        await indexer.reindex()

        XCTAssertEqual(index.indexed.first?.contents.map { String($0.characters) }, "I planted potatoes today")
    }

    func testWhenFeatureFlagDisabledThenReindexWipesIndex() async {
        let storage = MockObservableStorage()
        storage.chats = [chatRecord(id: "a", title: "X", text: "y")]
        let index = FakeChatSearchIndex()
        let indexer = makeIndexer(storage: storage, flagEnabled: false, index: index)

        await indexer.reindex()

        XCTAssertTrue(index.indexed.isEmpty)
        XCTAssertEqual(index.deleteAllCallCount, 1)
    }

    func testWhenUserSettingDisabledThenReindexWipesIndex() async {
        let storage = MockObservableStorage()
        storage.chats = [chatRecord(id: "a", title: "X", text: "y")]
        let index = FakeChatSearchIndex()
        let indexer = makeIndexer(storage: storage, settingEnabled: false, index: index)

        await indexer.reindex()

        XCTAssertTrue(index.indexed.isEmpty)
        XCTAssertEqual(index.deleteAllCallCount, 1)
    }

    func testWhenStorageIsNilThenReindexDoesNothing() async {
        let index = FakeChatSearchIndex()
        let indexer = makeIndexer(storage: nil, index: index)

        await indexer.reindex()

        XCTAssertEqual(index.replaceAllCallCount, 0)
        XCTAssertEqual(index.deleteAllCallCount, 0)
    }

    func testWhenChatCannotBeDecodedThenItIsSkippedNotFatal() async {
        let storage = MockObservableStorage()
        storage.chats = [DuckAiChatRecord(chatId: "bad", data: Data("not json".utf8)),
                         chatRecord(id: "good", title: "OK", text: "valid")]
        let index = FakeChatSearchIndex()
        let indexer = makeIndexer(storage: storage, index: index)

        await indexer.reindex()

        XCTAssertEqual(index.indexed.map(\.id), ["good"])
    }
}
