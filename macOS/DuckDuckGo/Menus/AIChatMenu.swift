//
//  AIChatMenu.swift
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
import AppKit
import PixelKit

@MainActor
final class AIChatMenu: NSMenu {

    // MARK: - Actions

    struct Actions {
        var openNewChat: () -> Void
        var openNewVoiceChat: () -> Void
        var openNewImageChat: () -> Void
        var openChat: (AIChatSuggestion) -> Void
        var viewAllChats: () -> Void
        var deleteAllChats: () async -> Void
    }

    // MARK: - Static items

    private lazy var newChatItem: NSMenuItem = {
        let item = NSMenuItem(title: UserText.aiChatMenuNewChat, action: #selector(newChatTapped), keyEquivalent: "")
        item.target = self
        return item
    }()

    private lazy var newVoiceChatItem: NSMenuItem = {
        let item = NSMenuItem(title: UserText.aiChatMenuNewVoiceChat, action: #selector(newVoiceChatTapped), keyEquivalent: "")
        item.target = self
        return item
    }()

    private lazy var newImageChatItem: NSMenuItem = {
        let item = NSMenuItem(title: UserText.aiChatMenuNewImageChat, action: #selector(newImageChatTapped), keyEquivalent: "")
        item.target = self
        return item
    }()

    private lazy var recentChatsLabel: NSMenuItem = {
        let item = NSMenuItem(title: UserText.aiChatMenuRecentChats)
        item.isEnabled = false
        return item
    }()

    private lazy var viewAllChatsItem: NSMenuItem = {
        let item = NSMenuItem(title: UserText.aiChatMenuViewAllChats, action: #selector(viewAllChatsTapped), keyEquivalent: "")
        item.target = self
        return item
    }()

    private lazy var deleteAllChatsItem: NSMenuItem = {
        let item = NSMenuItem(title: UserText.aiChatMenuDeleteAllChats, action: #selector(deleteAllChatsTapped), keyEquivalent: "")
        item.target = self
        return item
    }()

    // MARK: - Dynamic chat items

    private var chatItems: [NSMenuItem] = []
    private var fetchTask: Task<Void, Never>?

    // MARK: - Dependencies

    private let suggestionsReader: AIChatSuggestionsReading
    private let actions: Actions

    // MARK: - Init

    init(suggestionsReader: AIChatSuggestionsReading, actions: Actions) {
        self.suggestionsReader = suggestionsReader
        self.actions = actions
        super.init(title: "Duck.ai")
        buildMenu()
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Menu construction

    private func buildMenu() {
        addItem(newChatItem)
        addItem(newVoiceChatItem)
        addItem(newImageChatItem)
        addItem(.separator())
        addItem(recentChatsLabel)
        // Dynamic chat items are inserted after recentChatsLabel by insertChatItems(_:)
        addItem(.separator())
        addItem(viewAllChatsItem)
        addItem(.separator())
        addItem(deleteAllChatsItem)
    }

    // MARK: - NSMenu update

    override func update() {
        super.update()
        clearChatItems()
        fetchTask?.cancel()
        fetchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let (pinned, recent) = await suggestionsReader.fetchSuggestions(query: nil, maxChats: 10)
            guard !Task.isCancelled else { return }
            let sorted = (pinned + recent)
                .sorted { ($0.timestamp ?? .distantPast) > ($1.timestamp ?? .distantPast) }
            insertChatItems(Array(sorted.prefix(10)))
        }
    }

    // MARK: - Dynamic item management

    private func clearChatItems() {
        chatItems.forEach { removeItem($0) }
        chatItems.removeAll()
    }

    private func insertChatItems(_ chats: [AIChatSuggestion]) {
        let labelIndex = index(of: recentChatsLabel)
        guard labelIndex != -1 else { return }
        for (offset, chat) in chats.enumerated() {
            let item = NSMenuItem(title: chat.title, action: #selector(chatItemTapped(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = chat
            insertItem(item, at: labelIndex + 1 + offset)
            chatItems.append(item)
        }
    }

    // MARK: - Action handlers

    @objc private func newChatTapped() {
        actions.openNewChat()
        PixelKit.fire(AIChatPixel.aiChatNewChatMainMenu, frequency: .dailyAndStandard)
    }

    @objc private func newVoiceChatTapped() {
        actions.openNewVoiceChat()
        PixelKit.fire(AIChatPixel.aiChatNewVoiceChatMainMenu, frequency: .dailyAndStandard)
    }

    @objc private func newImageChatTapped() {
        actions.openNewImageChat()
        PixelKit.fire(AIChatPixel.aiChatNewImageChatMainMenu, frequency: .dailyAndStandard)
    }

    @objc private func chatItemTapped(_ sender: NSMenuItem) {
        guard let chat = sender.representedObject as? AIChatSuggestion else { return }
        actions.openChat(chat)
        PixelKit.fire(AIChatPixel.aiChatRecentChatSelectedMainMenu, frequency: .dailyAndStandard)
    }

    @objc private func viewAllChatsTapped() {
        actions.viewAllChats()
        PixelKit.fire(AIChatPixel.aiChatViewAllChatsMainMenu, frequency: .dailyAndStandard)
    }

    @objc private func deleteAllChatsTapped() {
        let alert = NSAlert()
        alert.messageText = UserText.aiChatMenuDeleteAllChatsAlertTitle
        alert.informativeText = UserText.aiChatMenuDeleteAllChatsAlertMessage
        alert.addButton(withTitle: UserText.aiChatMenuDeleteAllChatsConfirmButton)
        alert.addButton(withTitle: UserText.cancel)
        alert.alertStyle = .warning

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        PixelKit.fire(AIChatPixel.aiChatDeleteAllChatsMainMenu, frequency: .dailyAndStandard)
        Task { @MainActor in
            await actions.deleteAllChats()
        }
    }
}
