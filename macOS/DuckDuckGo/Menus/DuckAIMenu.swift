//
//  DuckAIMenu.swift
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
import Cocoa
import Combine
import FeatureFlags
import os.log
import PrivacyConfig

@MainActor
final class DuckAIMenu: NSMenu {

    private let featureFlagger: FeatureFlagger
    private let aiChatMenuConfig: AIChatMenuVisibilityConfigurable

    // MARK: - Static Items

    let newChatMenuItem = NSMenuItem(title: UserText.newAIChatMenuItem,
                                     action: #selector(AppDelegate.newAIChat),
                                     keyEquivalent: [.option, .command, "n"])
        .withAccessibilityIdentifier("DuckAIMenu.newChat")

    let newVoiceChatMenuItem = NSMenuItem(title: UserText.duckAIMenuNewVoiceChat,
                                          action: #selector(MainViewController.newVoiceChat))
        .withAccessibilityIdentifier("DuckAIMenu.newVoiceChat")

    let generateImageMenuItem = NSMenuItem(title: UserText.duckAIMenuGenerateImage,
                                           action: #selector(MainViewController.generateImage))
        .withAccessibilityIdentifier("DuckAIMenu.generateImage")

    let openDuckAIMenuItem = NSMenuItem(title: UserText.duckAIMenuOpenDuckAI,
                                        action: #selector(AppDelegate.newAIChat))
        .withAccessibilityIdentifier("DuckAIMenu.openDuckAI")

    let recentChatsMenuItem = NSMenuItem(title: UserText.duckAIMenuRecentChats)
        .withAccessibilityIdentifier("DuckAIMenu.recentChats")

    let summarizeMenuItem = NSMenuItem(title: UserText.aiChatSummarize,
                                       action: #selector(MainViewController.summarize),
                                       keyEquivalent: [.command, .shift, "\r"])
        .withAccessibilityIdentifier("DuckAIMenu.summarize")

    let toggleSidebarMenuItem = NSMenuItem(title: UserText.duckAIMenuToggleSidebar,
                                           action: #selector(MainViewController.toggleAIChatSidebar),
                                           keyEquivalent: [.option, .command, "l"])
        .withAccessibilityIdentifier("DuckAIMenu.toggleSidebar")

    let detachAttachSidebarMenuItem = NSMenuItem(title: UserText.duckAIMenuDetachSidebar,
                                                 action: #selector(MainViewController.detachAIChatSidebar))
        .withAccessibilityIdentifier("DuckAIMenu.detachAttachSidebar")

    let aiSettingsMenuItem = NSMenuItem(title: UserText.duckAIMenuSettings,
                                        action: #selector(MainViewController.openAIFeaturesSettings))
        .withAccessibilityIdentifier("DuckAIMenu.settings")

    // MARK: - Recent Chats

    private var recentChatsMenu = NSMenu(title: UserText.duckAIMenuRecentChats)
    private var suggestionsReader: AIChatSuggestionsReading?
    private var isFetchingRecentChats = false

    // MARK: - Initialization

    init(featureFlagger: FeatureFlagger,
         aiChatMenuConfig: AIChatMenuVisibilityConfigurable) {
        self.featureFlagger = featureFlagger
        self.aiChatMenuConfig = aiChatMenuConfig

        super.init(title: UserText.duckAIMenuTitle)

        buildItems {
            newChatMenuItem
            newVoiceChatMenuItem
            generateImageMenuItem

            NSMenuItem.separator()

            openDuckAIMenuItem
            recentChatsMenuItem

            NSMenuItem.separator()

            summarizeMenuItem

            NSMenuItem.separator()

            toggleSidebarMenuItem
            detachAttachSidebarMenuItem

            NSMenuItem.separator()

            aiSettingsMenuItem
        }

        recentChatsMenuItem.submenu = recentChatsMenu
        setupRecentChatsPlaceholder()
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Dynamic Updates

    override func update() {
        super.update()
        updateDetachAttachItem()
        updateRecentChats()
    }

    // MARK: - Detach/Attach Toggle

    private func updateDetachAttachItem() {
        guard let mainVC = Application.appDelegate.windowControllersManager.lastKeyMainWindowController?.mainViewController,
              let tabID = mainVC.tabCollectionViewModel.selectedTabViewModel?.tab.uuid else {
            return
        }

        let isFloating = mainVC.aiChatCoordinator.isChatFloating(for: tabID)
        if isFloating {
            detachAttachSidebarMenuItem.title = UserText.duckAIMenuAttachSidebar
            detachAttachSidebarMenuItem.action = #selector(MainViewController.attachAIChatSidebar)
        } else {
            detachAttachSidebarMenuItem.title = UserText.duckAIMenuDetachSidebar
            detachAttachSidebarMenuItem.action = #selector(MainViewController.detachAIChatSidebar)
        }
    }

    // MARK: - Recent Chats

    func setSuggestionsReader(_ reader: AIChatSuggestionsReading) {
        self.suggestionsReader = reader
    }

    private func setupRecentChatsPlaceholder() {
        let placeholder = NSMenuItem(title: UserText.duckAIMenuNoRecentChats)
        placeholder.isEnabled = false
        recentChatsMenu.items = [placeholder]
    }

    private func updateRecentChats() {
        guard featureFlagger.isFeatureOn(.aiChatSuggestions),
              let suggestionsReader,
              !isFetchingRecentChats else {
            return
        }

        isFetchingRecentChats = true

        Task { @MainActor in
            defer { isFetchingRecentChats = false }

            let (pinned, recent) = await suggestionsReader.fetchSuggestions(query: nil)

            recentChatsMenu.removeAllItems()

            if pinned.isEmpty && recent.isEmpty {
                setupRecentChatsPlaceholder()
                return
            }

            for suggestion in pinned {
                recentChatsMenu.addItem(makeRecentChatItem(suggestion, isPinned: true))
            }

            if !pinned.isEmpty && !recent.isEmpty {
                recentChatsMenu.addItem(.separator())
            }

            for suggestion in recent {
                recentChatsMenu.addItem(makeRecentChatItem(suggestion, isPinned: false))
            }
        }
    }

    private func makeRecentChatItem(_ suggestion: AIChatSuggestion, isPinned: Bool) -> NSMenuItem {
        let title = suggestion.title.truncated(length: MainMenu.Constants.maxTitleLength)
        let item = NSMenuItem(title: title,
                              action: #selector(MainViewController.openRecentAIChat(_:)),
                              keyEquivalent: "")
        item.representedObject = suggestion.chatId

        if isPinned {
            item.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        }

        if let preview = suggestion.firstUserMessageContent {
            item.toolTip = preview
        }

        return item
    }
}

// MARK: - String Truncation

private extension String {
    func truncated(length: Int) -> String {
        if count > length {
            return prefix(length) + "…"
        }
        return self
    }
}
