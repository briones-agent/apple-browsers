//
//  AIChatWidgetSyncEngineTests.swift
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
import UIKit
import Core
import AIChat
import DuckAiDataStore
@testable import DuckDuckGo

final class AIChatWidgetSyncEngineTests: XCTestCase {

    // MARK: - Test double

    final class MockObservableStorage: DuckAiNativeStorageHandling, DuckAiNativeChatsObserving {
        var chats: [DuckAiChatRecord] = []
        var files: [String: Data] = [:]   // uuid -> bytes
        private let subject = CurrentValueSubject<[DuckAiChatRecord], Error>([])

        func emit() { subject.send(chats) }
        func chatsPublisher() -> AnyPublisher<[DuckAiChatRecord], Error> { subject.eraseToAnyPublisher() }

        // Chats
        func putChat(chatId: String, data: Data) throws {}
        func putChats(_ chats: [DuckAiChatRecord]) throws {}
        func getChat(chatId: String) throws -> DuckAiChatRecord? { chats.first { $0.chatId == chatId } }
        func getAllChats() throws -> [DuckAiChatRecord] { chats }
        func deleteChat(chatId: String) throws {}
        func deleteAllChats() throws {}

        // Files
        func putFile(uuid: String, chatId: String, data: Data) throws {}
        func getFile(uuid: String) throws -> DuckAiFileContent? {
            files[uuid].map { DuckAiFileContent(uuid: uuid, chatId: "", data: $0) }
        }
        func listFiles() throws -> [DuckAiFileMetadata] { [] }
        func deleteFile(uuid: String) throws {}
        func deleteFiles(chatId: String) throws {}
        func deleteAllFiles() throws {}

        // Entries
        func putEntry(key: String, value: Any) throws {}
        func getEntry(key: String) throws -> Any? { nil }
        func getAllEntries() throws -> [String: Any] { [:] }
        func deleteEntry(key: String) throws {}
        func deleteAllEntries() throws {}
        func replaceAllEntries(_ entries: [String: Any]) throws {}

        // Migration
        func isMigrationDone() throws -> Bool { true }
        func isMigrationDone(key: String) throws -> Bool { true }
        func markMigrationDone(key: String) throws {}
    }

    // MARK: - Helpers

    private func chatData(id: String, title: String, lastEdit: String) -> Data {
        let json = """
        { "chatId": "\(id)", "title": "\(title)", "model": "gpt", "lastEdit": "\(lastEdit)", "pinned": false, "messages": [] }
        """
        return Data(json.utf8)
    }

    private func imageGenChatData(id: String, lastEdit: String, fileRef: String) -> Data {
        let json = """
        { "chatId": "\(id)", "title": "Image chat", "model": "gpt", "lastEdit": "\(lastEdit)", "pinned": false,
          "fileRefs": ["\(fileRef)"],
          "messages": [ { "role": "assistant", "parts": [ { "type": "ui-component", "name": "generate-image" } ] } ] }
        """
        return Data(json.utf8)
    }

    private func makeJPEGData() -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 300))
        let image = renderer.image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 300, height: 300))
        }
        return image.jpegData(compressionQuality: 0.8)!
    }

    private func makeLocation() -> AIChatWidgetDataLocation {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        return AIChatWidgetDataLocation(containerURL: dir)
    }

    private func readEntries(_ location: AIChatWidgetDataLocation) throws -> [WidgetChatEntry] {
        let data = try Data(contentsOf: location.chatsFileURL)
        return try JSONDecoder().decode([WidgetChatEntry].self, from: data)
    }

    private func makeEngine(storage: MockObservableStorage,
                            location: AIChatWidgetDataLocation,
                            widgetEnabled: Bool = true,
                            notificationCenter: NotificationCenter = NotificationCenter()) -> AIChatWidgetSyncEngine {
        let settings = MockAIChatSettingsProvider()
        settings.isAIChatRecentChatsWidgetUserSettingsEnabled = widgetEnabled
        return AIChatWidgetSyncEngine(storage: storage,
                                      settings: settings,
                                      dataLocation: location,
                                      notificationCenter: notificationCenter,
                                      reloadWidgets: {})
    }

    // MARK: - Mirror write (Task 4)

    func testWhenSyncNowThenMirrorWrittenSortedByLastEditDescending() throws {
        let storage = MockObservableStorage()
        storage.chats = [
            DuckAiChatRecord(chatId: "a", data: chatData(id: "a", title: "Older", lastEdit: "2026-01-01T00:00:00.000Z")),
            DuckAiChatRecord(chatId: "b", data: chatData(id: "b", title: "Newer", lastEdit: "2026-02-01T00:00:00.000Z"))
        ]
        let location = makeLocation()
        let engine = makeEngine(storage: storage, location: location)

        engine.syncNow()

        let entries = try readEntries(location)
        XCTAssertEqual(entries.map(\.chatId), ["b", "a"])
        XCTAssertEqual(entries.first?.title, "Newer")
    }

    func testWhenMoreThanSixChatsThenOnlyTopSixWritten() throws {
        let storage = MockObservableStorage()
        storage.chats = (0..<10).map { index in
            let day = String(format: "%02d", index + 1)
            return DuckAiChatRecord(chatId: "c\(index)", data: chatData(id: "c\(index)", title: "T\(index)", lastEdit: "2026-03-\(day)T00:00:00.000Z"))
        }
        let location = makeLocation()
        let engine = makeEngine(storage: storage, location: location)

        engine.syncNow()

        let entries = try readEntries(location)
        XCTAssertEqual(entries.count, 6)
        XCTAssertEqual(entries.first?.chatId, "c9")
    }

    // MARK: - Thumbnails (Task 5)

    func testWhenImageGenChatThenThumbnailWrittenAndFlagged() throws {
        let storage = MockObservableStorage()
        storage.chats = [DuckAiChatRecord(chatId: "img", data: imageGenChatData(id: "img", lastEdit: "2026-05-01T00:00:00.000Z", fileRef: "file-1"))]
        storage.files = ["file-1": makeJPEGData()]
        let location = makeLocation()
        let engine = makeEngine(storage: storage, location: location)

        engine.syncNow()

        let entries = try readEntries(location)
        XCTAssertEqual(entries.first?.hasImageThumbnail, true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: location.thumbnailURL(forChatId: "img").path))
    }

    func testWhenChatNoLongerImageGenThenStaleThumbnailRemoved() throws {
        let storage = MockObservableStorage()
        storage.chats = [DuckAiChatRecord(chatId: "img", data: imageGenChatData(id: "img", lastEdit: "2026-05-01T00:00:00.000Z", fileRef: "file-1"))]
        storage.files = ["file-1": makeJPEGData()]
        let location = makeLocation()
        let engine = makeEngine(storage: storage, location: location)

        engine.syncNow()
        XCTAssertTrue(FileManager.default.fileExists(atPath: location.thumbnailURL(forChatId: "img").path))

        storage.chats = [DuckAiChatRecord(chatId: "img", data: chatData(id: "img", title: "Now text", lastEdit: "2026-05-02T00:00:00.000Z"))]
        engine.syncNow()
        XCTAssertFalse(FileManager.default.fileExists(atPath: location.thumbnailURL(forChatId: "img").path))
    }

    // MARK: - Gating + subscription (Task 6)

    func testWhenSettingDisabledThenSyncWipesInsteadOfWriting() throws {
        let storage = MockObservableStorage()
        storage.chats = [DuckAiChatRecord(chatId: "a", data: chatData(id: "a", title: "X", lastEdit: "2026-01-01T00:00:00.000Z"))]
        let location = makeLocation()

        let settings = MockAIChatSettingsProvider()
        settings.isAIChatRecentChatsWidgetUserSettingsEnabled = true
        let engine = AIChatWidgetSyncEngine(storage: storage, settings: settings, dataLocation: location, reloadWidgets: {})

        engine.syncNow()
        XCTAssertTrue(FileManager.default.fileExists(atPath: location.chatsFileURL.path))

        settings.isAIChatRecentChatsWidgetUserSettingsEnabled = false
        engine.syncNow()
        XCTAssertFalse(FileManager.default.fileExists(atPath: location.rootURL.path))
    }

    func testWhenStorageEmitsThenMirrorUpdates() throws {
        let storage = MockObservableStorage()
        let location = makeLocation()
        let engine = makeEngine(storage: storage, location: location)

        engine.start()
        storage.chats = [DuckAiChatRecord(chatId: "z", data: chatData(id: "z", title: "Z", lastEdit: "2026-06-01T00:00:00.000Z"))]
        storage.emit()

        let entries = try readEntries(location)
        XCTAssertEqual(entries.map(\.chatId), ["z"])
    }

    func testWhenWipeWidgetDataThenMirrorRemoved() throws {
        let storage = MockObservableStorage()
        storage.chats = [DuckAiChatRecord(chatId: "a", data: chatData(id: "a", title: "X", lastEdit: "2026-01-01T00:00:00.000Z"))]
        let location = makeLocation()
        let engine = makeEngine(storage: storage, location: location)

        engine.syncNow()
        XCTAssertTrue(FileManager.default.fileExists(atPath: location.chatsFileURL.path))

        engine.wipeWidgetData()
        XCTAssertFalse(FileManager.default.fileExists(atPath: location.rootURL.path))
    }
}
