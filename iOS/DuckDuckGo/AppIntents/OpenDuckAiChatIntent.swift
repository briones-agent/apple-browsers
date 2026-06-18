//
//  OpenDuckAiChatIntent.swift
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
import Core
import UIKit

/// Opens a specific Duck.ai conversation when the user taps a Siri / Spotlight search result.
/// Reuses the existing recent-chats deep link (`ddgOpenAIChat://?chatID=…`), so it routes through
/// `AIChatDeepLinkHandler` → `MainViewController.openAIChat(chatId:)` like the widget does.
@available(iOS 18.4, *)
struct OpenDuckAiChatIntent: OpenIntent {

    static var title: LocalizedStringResource = "Open Duck.ai Conversation"

    /// Not a standalone, user-facing shortcut — it exists to open a resolved conversation entity.
    static let isDiscoverable: Bool = false

    @Parameter(title: "Conversation")
    var target: DuckAiChatEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        Pixel.fire(pixel: .appIntentPerformed, withAdditionalParameters: ["type": "duckai_search_open"])
        await UIApplication.shared.open(AIChatWidgetDeepLink.url(forChatId: target.id, source: "siri"))
        return .result()
    }
}
