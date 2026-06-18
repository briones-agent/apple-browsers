//
//  DuckAiChatSearchableTextTests.swift
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
@testable import AIChat

final class DuckAiChatSearchableTextTests: XCTestCase {

    func testWhenMultipleMessagesThenSearchableTextJoinsAllVisibleText() throws {
        let json = """
            {
              "chatId": "c1", "title": "Gardening", "model": "gpt",
              "messages": [
                {"role": "user", "content": "How do I grow potatoes?"},
                {"role": "assistant", "content": "Plant seed potatoes in trenches."}
              ]
            }
            """
        let result = try DuckAiChat.decodeSearchableText(from: Data(json.utf8))
        XCTAssertEqual(result.chat.title, "Gardening")
        XCTAssertTrue(result.searchableText.contains("grow potatoes"))
        XCTAssertTrue(result.searchableText.contains("seed potatoes"))
    }

    func testWhenAssistantUsesRichContentThenTextIsIncluded() throws {
        let json = """
            {
              "chatId": "c1", "model": "gpt",
              "messages": [
                {"role": "user", "content": "what is this?"},
                {"role": "assistant", "content": {"text": "a duck", "images": []}}
              ]
            }
            """
        let result = try DuckAiChat.decodeSearchableText(from: Data(json.utf8))
        XCTAssertTrue(result.searchableText.contains("a duck"))
    }

    func testWhenReasoningModelMessageThenPartsTextIncludedButReasoningExcluded() throws {
        let json = """
            {
              "chatId": "c1", "model": "gpt-5-mini",
              "messages": [
                {"role": "user", "content": "hello"},
                {"role": "assistant", "content": "", "parts": [
                  {"type": "reasoning", "encryptedText": "opaque"},
                  {"type": "text", "text": "the actual reply"}
                ]}
              ]
            }
            """
        let result = try DuckAiChat.decodeSearchableText(from: Data(json.utf8))
        XCTAssertTrue(result.searchableText.contains("the actual reply"))
        XCTAssertFalse(result.searchableText.contains("opaque"))
    }

    func testWhenMessageHasNoVisibleTextThenItIsSkipped() throws {
        let json = """
            {
              "chatId": "c1", "model": "gpt",
              "messages": [
                {"role": "user", "content": "draw a duck"},
                {"role": "assistant", "parts": [{"type": "ui-component", "name": "generate-image"}]}
              ]
            }
            """
        let result = try DuckAiChat.decodeSearchableText(from: Data(json.utf8))
        XCTAssertEqual(result.searchableText, "draw a duck")
    }

    func testWhenNoMessagesThenSearchableTextIsEmpty() throws {
        let json = #"{"chatId": "c1", "title": "Empty", "model": "gpt"}"#
        let result = try DuckAiChat.decodeSearchableText(from: Data(json.utf8))
        XCTAssertEqual(result.searchableText, "")
        XCTAssertEqual(result.chat.title, "Empty")
    }

    func testWhenTitleMissingThenFallsBackToUntitled() throws {
        let json = #"{"chatId": "c1", "model": "gpt", "messages": [{"role": "user", "content": "hi"}]}"#
        let result = try DuckAiChat.decodeSearchableText(from: Data(json.utf8))
        XCTAssertEqual(result.chat.title, "Untitled Chat")
    }

    func testWhenInvalidJSONThenThrows() {
        XCTAssertThrowsError(try DuckAiChat.decodeSearchableText(from: Data("not json".utf8)))
    }
}
