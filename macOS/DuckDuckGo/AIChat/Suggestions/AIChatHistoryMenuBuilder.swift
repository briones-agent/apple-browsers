//
//  AIChatHistoryMenuBuilder.swift
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

import AppKit
import AIChat
import DesignResourcesKitIcons

/// Builds an NSMenu populated with duck.ai chat history suggestions.
@MainActor
enum AIChatHistoryMenuBuilder {

    /// Builds a menu from pinned and recent suggestions.
    /// - Parameters:
    ///   - pinned: Pinned chat suggestions, shown after the top actions.
    ///   - recent: Recent chat suggestions, shown after pinned.
    ///   - target: The target for the selection actions.
    ///   - chatAction: Selector called when a chat item is selected. The sender is the `NSMenuItem`
    ///                 whose `representedObject` is the `chatId` string.
    ///   - newChatAction: Selector called when "New Chat" is selected.
    ///   - newImageChatAction: Selector called when "New Image Chat" is selected.
    ///   - newVoiceChatAction: Selector called when "New Voice Chat" is selected.
    ///   - settingsAction: Selector called when "Settings…" is selected.
    /// - Returns: A populated `NSMenu`.
    static func buildMenu(pinned: [AIChatSuggestion],
                          recent: [AIChatSuggestion],
                          target: AnyObject,
                          chatAction: Selector,
                          newChatAction: Selector,
                          newImageChatAction: Selector,
                          newVoiceChatAction: Selector,
                          settingsAction: Selector) -> NSMenu {
        let menu = NSMenu()

        // Top actions
        let newChatItem = NSMenuItem(title: UserText.aiChatHistoryNewChat, action: newChatAction, keyEquivalent: "")
        newChatItem.target = target
        newChatItem.image = DesignSystemImages.Glyphs.Size16.aiChatAdd
        menu.addItem(newChatItem)

        let newImageChatItem = NSMenuItem(title: UserText.aiChatHistoryNewImageChat, action: newImageChatAction, keyEquivalent: "")
        newImageChatItem.target = target
        newImageChatItem.image = DesignSystemImages.Glyphs.Size16.image
        menu.addItem(newImageChatItem)

        let newVoiceChatItem = NSMenuItem(title: UserText.aiChatHistoryNewVoiceChat, action: newVoiceChatAction, keyEquivalent: "")
        newVoiceChatItem.target = target
        newVoiceChatItem.image = DesignSystemImages.Glyphs.Size16.permissionMicrophone
        menu.addItem(newVoiceChatItem)

        menu.addItem(.separator())

        // Recent chats section
        let headerItem = NSMenuItem(title: UserText.aiChatHistoryRecentChats, action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)

        let all = pinned + recent
        if all.isEmpty {
            let noChatsItem = NSMenuItem(title: UserText.aiChatHistoryNoRecentChats, action: nil, keyEquivalent: "")
            noChatsItem.isEnabled = false
            menu.addItem(noChatsItem)
        } else {
            for suggestion in all {
                let item = NSMenuItem(title: suggestion.title, action: chatAction, keyEquivalent: "")
                item.target = target
                item.representedObject = suggestion.chatId
                item.image = suggestion.isPinned
                    ? DesignSystemImages.Glyphs.Size16.pin
                    : DesignSystemImages.Glyphs.Size16.chat
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: UserText.aiChatHistorySettings, action: settingsAction, keyEquivalent: "")
        settingsItem.target = target
        settingsItem.image = DesignSystemImages.Glyphs.Size16.aiChatSettings
        menu.addItem(settingsItem)

        return menu
    }
}
