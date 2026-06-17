//
//  AIChatWidgetDeepLink.swift
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

/// Shared contract for the recent-chats widget deep link, used by both the widget extension
/// (which builds the URL) and the app (which parses the chat id out of it). Centralized in Core
/// so the two sides cannot drift on the parameter name.
public enum AIChatWidgetDeepLink {

    public static let chatIDParameterName = "chatID"

    /// Must match `WidgetSourceType.sourceKey` (defined in the app/widget targets, not Core).
    public static let sourceParameterName = "source"

    /// Builds `ddgOpenAIChat://?chatID=<id>&source=<source>`.
    public static func url(forChatId chatId: String, source: String) -> URL {
        let base = AppDeepLinkSchemes.openAIChat.url
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return base }
        components.queryItems = [
            URLQueryItem(name: chatIDParameterName, value: chatId),
            URLQueryItem(name: sourceParameterName, value: source)
        ]
        return components.url ?? base
    }

    /// Extracts the `chatID` query parameter, or nil when absent/empty.
    public static func chatId(from url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let value = components.queryItems?.first(where: { $0.name == chatIDParameterName })?.value
        return (value?.isEmpty == false) ? value : nil
    }
}
