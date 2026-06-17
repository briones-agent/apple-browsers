//
//  AIChatRecentChatsWidget.swift
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

import WidgetKit
import SwiftUI
import UIKit
import Core

struct AIChatRecentChatsEntry: TimelineEntry {
    let date: Date
    let chats: [WidgetChatEntry]
    let thumbnails: [String: UIImage]
    let isEnabled: Bool
    let isPreview: Bool

    /// Deep link that opens a specific chat from a widget row.
    static func deepLink(forChatId chatId: String) -> URL {
        AIChatWidgetDeepLink.url(forChatId: chatId, source: WidgetSourceType.recentChatsWidget.rawValue)
    }
}

struct AIChatRecentChatsProvider: TimelineProvider {

    func placeholder(in context: Context) -> AIChatRecentChatsEntry {
        AIChatRecentChatsEntry(date: Date(), chats: [], thumbnails: [:], isEnabled: true, isPreview: context.isPreview)
    }

    func getSnapshot(in context: Context, completion: @escaping (AIChatRecentChatsEntry) -> Void) {
        completion(makeEntry(isPreview: context.isPreview))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AIChatRecentChatsEntry>) -> Void) {
        // `.never`: the main app drives reloads via WidgetCenter when the mirror changes.
        completion(Timeline(entries: [makeEntry(isPreview: context.isPreview)], policy: .never))
    }

    private func makeEntry(isPreview: Bool) -> AIChatRecentChatsEntry {
        guard isWidgetEnabled, let location = AIChatWidgetDataLocation.appGroup() else {
            return AIChatRecentChatsEntry(date: Date(), chats: [], thumbnails: [:], isEnabled: isWidgetEnabled, isPreview: isPreview)
        }

        let chats = (try? JSONDecoder().decode([WidgetChatEntry].self, from: Data(contentsOf: location.chatsFileURL))) ?? []

        var thumbnails: [String: UIImage] = [:]
        for chat in chats where chat.hasImageThumbnail {
            if let data = try? Data(contentsOf: location.thumbnailURL(forChatId: chat.chatId)),
               let image = UIImage(data: data) {
                thumbnails[chat.chatId] = image.toSRGB()
            }
        }

        return AIChatRecentChatsEntry(date: Date(),
                                      chats: chats,
                                      thumbnails: thumbnails,
                                      isEnabled: true,
                                      isPreview: isPreview && chats.isEmpty)
    }

    /// Both the global AI Chat toggle and the widget toggle must be on. This is defense in depth:
    /// the sync engine already wipes the mirror when either is off, but the widget also refuses to
    /// render stale data if it somehow lingers.
    private var isWidgetEnabled: Bool {
        let defaults = UserDefaults(suiteName: Global.appConfigurationGroupName) ?? UserDefaults()
        let aiChatOn = (defaults.object(forKey: AppConfigurationKeyNames.isAIChatEnabled) as? Bool) ?? true
        let widgetOn = (defaults.object(forKey: AppConfigurationKeyNames.aiChatRecentChatsWidgetEnabled) as? Bool) ?? true
        return aiChatOn && widgetOn
    }
}

struct AIChatRecentChatsWidget: Widget {
    let kind: String = "AIChatRecentChatsWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: AIChatRecentChatsProvider()) { entry in
            AIChatRecentChatsWidgetView(entry: entry)
        }
        .configurationDisplayName(UserText.recentChatsWidgetGalleryDisplayName)
        .description(UserText.recentChatsWidgetGalleryDescription)
        .supportedFamilies([.systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}
