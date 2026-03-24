//
//  AIChatLauncherViewModel.swift
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
import Combine

/// Data model for the launcher panel. Logic lives in AIChatLauncherCoordinator.
@MainActor
final class AIChatLauncherViewModel: ObservableObject {

    // MARK: - Published State

    @Published var searchText: String = "" {
        didSet {
            // Reset selection when the filter changes
            selectedIndex = nil
        }
    }

    @Published private(set) var allChats: [AIChatSuggestion] = []
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var selectedIndex: Int? = nil

    // MARK: - Derived

    var filteredChats: [AIChatSuggestion] {
        guard !searchText.isEmpty else { return allChats }
        return allChats.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    // MARK: - Action Closures (wired by coordinator)

    var onNewChat: (() -> Void)?
    var onNewVoiceChat: (() -> Void)?
    var onNewImageChat: (() -> Void)?
    var onSettings: (() -> Void)?
    var onChatSelected: ((String) -> Void)?
    var onDismiss: (() -> Void)?

    // MARK: - Updates

    func update(chats: [AIChatSuggestion], isLoading: Bool) {
        self.allChats = chats
        self.isLoading = isLoading
        self.selectedIndex = nil
    }

    func reset() {
        searchText = ""
        selectedIndex = nil
    }

    // MARK: - Keyboard Navigation

    func moveSelectionDown() {
        let items = filteredChats
        guard !items.isEmpty else { return }
        if let current = selectedIndex {
            selectedIndex = min(current + 1, items.count - 1)
        } else {
            selectedIndex = 0
        }
    }

    func moveSelectionUp() {
        guard let current = selectedIndex else { return }
        if current == 0 {
            selectedIndex = nil  // return focus to search field
        } else {
            selectedIndex = current - 1
        }
    }

    func activateSelection() {
        guard let index = selectedIndex, index < filteredChats.count else { return }
        let chat = filteredChats[index]
        onChatSelected?(chat.chatId)
    }
}
