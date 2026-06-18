//
//  DuckAiChatEntityMappingTests.swift
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
import AIChat
import DuckAiDataStore
@testable import DuckDuckGo

@available(iOS 18.4, *)
final class DuckAiChatEntityMappingTests: XCTestCase {

    private func record(_ id: String, _ json: String) -> DuckAiChatRecord {
        DuckAiChatRecord(chatId: id, data: Data(json.utf8))
    }

    func testWhenRecordDecodesThenEntityHasIdTitleAndContents() {
        let json = """
            {"chatId": "abc", "title": "Potatoes", "model": "gpt", "lastEdit": "2026-04-01T21:31:54.260Z",
             "messages": [{"role": "user", "content": "how to grow potatoes"}]}
            """
        let entity = DuckAiChatEntity.make(from: record("abc", json))
        XCTAssertEqual(entity?.id, "abc")
        XCTAssertEqual(entity?.title, "Potatoes")
        XCTAssertEqual(entity?.contents.map { String($0.characters) }, "how to grow potatoes")
    }

    func testWhenLastEditHasFractionalSecondsThenParsedToDate() {
        let json = """
            {"chatId": "abc", "title": "T", "model": "gpt", "lastEdit": "2026-04-01T21:31:54.260Z", "messages": []}
            """
        let entity = DuckAiChatEntity.make(from: record("abc", json))
        XCTAssertNotNil(entity?.lastEdit)
    }

    func testWhenContentsExceedCapThenTruncatedToMaxLength() {
        let long = String(repeating: "a", count: DuckAiChatEntity.maxIndexedTextLength + 500)
        let json = """
            {"chatId": "abc", "title": "T", "model": "gpt", "messages": [{"role": "user", "content": "\(long)"}]}
            """
        let entity = DuckAiChatEntity.make(from: record("abc", json))
        XCTAssertEqual(entity?.contents.map { String($0.characters).count }, DuckAiChatEntity.maxIndexedTextLength)
    }

    func testWhenNoMessageTextThenContentsIsNil() {
        let json = #"{"chatId": "abc", "title": "T", "model": "gpt", "messages": []}"#
        let entity = DuckAiChatEntity.make(from: record("abc", json))
        XCTAssertNil(entity?.contents)
    }

    func testWhenInvalidDataThenReturnsNil() {
        XCTAssertNil(DuckAiChatEntity.make(from: record("abc", "not json")))
    }

    func testDateParsingHandlesBothFractionalAndPlainISO8601() {
        XCTAssertNotNil(DuckAiChatEntity.date(fromISO8601: "2026-04-01T21:31:54Z"))
        XCTAssertNotNil(DuckAiChatEntity.date(fromISO8601: "2026-04-01T21:31:54.260Z"))
        XCTAssertNil(DuckAiChatEntity.date(fromISO8601: "garbage"))
    }
}
