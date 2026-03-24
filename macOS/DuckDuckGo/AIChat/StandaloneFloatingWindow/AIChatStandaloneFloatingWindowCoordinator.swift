//
//  AIChatStandaloneFloatingWindowCoordinator.swift
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
import Foundation

/// Owned by MainViewController. Lazily creates the standalone floating window
/// and builds duck.ai URLs for launcher selections.
@MainActor
final class AIChatStandaloneFloatingWindowCoordinator {

    private lazy var windowController = AIChatStandaloneFloatingWindowController(keyValueStore: UserDefaults.standard)

    // MARK: - Public API

    func open(url: URL) {
        windowController.open(url: url)
    }

    func openNewChat() {
        open(url: baseURL())
    }

    func openVoiceChat() {
        open(url: buildModeURL(mode: AIChatURLParameters.voiceModeValue))
    }

    func openImageChat() {
        open(url: buildModeURL(mode: AIChatURLParameters.imageModeValue))
    }

    func openExistingChat(chatId: String) {
        open(url: buildChatURL(chatId: chatId))
    }

    // MARK: - URL Building

    private func baseURL() -> URL {
        AIChatRemoteSettings().aiChatURL
    }

    private func buildModeURL(mode: String) -> URL {
        let settings = AIChatRemoteSettings()
        guard var components = URLComponents(url: settings.aiChatURL, resolvingAgainstBaseURL: false) else {
            return settings.aiChatURL
        }
        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name == AIChatURLParameters.modeName || $0.name == "chatID" }
        queryItems.append(URLQueryItem(name: AIChatURLParameters.modeName, value: mode))
        components.queryItems = queryItems
        return components.url ?? settings.aiChatURL
    }

    private func buildChatURL(chatId: String) -> URL {
        let settings = AIChatRemoteSettings()
        guard var components = URLComponents(url: settings.aiChatURL, resolvingAgainstBaseURL: false) else {
            return settings.aiChatURL
        }
        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name == AIChatURLParameters.modeName || $0.name == "chatID" }
        queryItems.append(URLQueryItem(name: "chatID", value: chatId))
        components.queryItems = queryItems
        return components.url ?? settings.aiChatURL
    }
}
