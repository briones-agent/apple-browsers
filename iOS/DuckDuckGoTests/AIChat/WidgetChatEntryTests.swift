//
//  WidgetChatEntryTests.swift
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
@testable import Core

final class WidgetChatEntryTests: XCTestCase {

    func testWhenEntryEncodedAndDecodedThenRoundTripsEqual() throws {
        let entry = WidgetChatEntry(chatId: "abc",
                                    title: "Hello",
                                    lastEdit: "2026-04-01T21:31:54.260Z",
                                    hasImageThumbnail: true)
        let data = try JSONEncoder().encode([entry])
        let decoded = try JSONDecoder().decode([WidgetChatEntry].self, from: data)
        XCTAssertEqual(decoded, [entry])
    }

    func testWhenDataLocationBuiltFromContainerThenPathsAreNestedUnderRoot() {
        let container = URL(fileURLWithPath: "/tmp/test-container", isDirectory: true)
        let location = AIChatWidgetDataLocation(containerURL: container)

        XCTAssertEqual(location.rootURL, container.appendingPathComponent("duck-ai-widget", isDirectory: true))
        XCTAssertEqual(location.chatsFileURL, location.rootURL.appendingPathComponent("chats.json"))
        XCTAssertEqual(location.thumbnailsDirectoryURL, location.rootURL.appendingPathComponent("thumbnails", isDirectory: true))
        XCTAssertEqual(location.thumbnailURL(forChatId: "xy"), location.thumbnailsDirectoryURL.appendingPathComponent("xy.jpg"))
    }
}
