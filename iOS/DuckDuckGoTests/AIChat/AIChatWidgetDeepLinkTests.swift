//
//  AIChatWidgetDeepLinkTests.swift
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

final class AIChatWidgetDeepLinkTests: XCTestCase {

    private func queryValue(_ url: URL, _ name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == name })?.value
    }

    func testWhenURLBuiltThenCarriesChatIDAndSource() {
        let url = AIChatWidgetDeepLink.url(forChatId: "chat-9", source: "widget.recentchats")
        XCTAssertEqual(queryValue(url, AIChatWidgetDeepLink.chatIDParameterName), "chat-9")
        XCTAssertEqual(queryValue(url, AIChatWidgetDeepLink.sourceParameterName), "widget.recentchats")
        XCTAssertEqual(url.scheme, AppDeepLinkSchemes.openAIChat.rawValue)
    }

    func testWhenBuiltURLParsedThenChatIDRoundTrips() {
        let url = AIChatWidgetDeepLink.url(forChatId: "chat-9", source: "widget.recentchats")
        XCTAssertEqual(AIChatWidgetDeepLink.chatId(from: url), "chat-9")
    }

    func testWhenNoChatIDThenNil() {
        XCTAssertNil(AIChatWidgetDeepLink.chatId(from: AppDeepLinkSchemes.openAIChat.url))
    }
}
