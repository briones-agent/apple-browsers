//
//  AIChatService.swift
//  DuckDuckGo
//
//  Copyright © 2025 DuckDuckGo. All rights reserved.
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

import UIKit
import Core
import AIChat

final class AIChatService: NSObject {

    private let aiChatSettings: AIChatSettingsProvider
    private let widgetSyncEngine: AIChatWidgetSyncEngine?
    private let spotlightIndexer: DuckAiChatIndexing?

    init(aiChatSettings: AIChatSettingsProvider,
         widgetSyncEngine: AIChatWidgetSyncEngine? = nil,
         spotlightIndexer: DuckAiChatIndexing? = nil) {
        self.aiChatSettings = aiChatSettings
        self.widgetSyncEngine = widgetSyncEngine
        self.spotlightIndexer = spotlightIndexer
        super.init()
        widgetSyncEngine?.start()
        spotlightIndexer?.start()
    }

    // MARK: - Resume

    @MainActor
    func resume() {
        // Refresh the widget mirror in case chats changed while we were backgrounded.
        widgetSyncEngine?.syncNow()
        spotlightIndexer?.refresh()
    }

    // MARK: - Suspend

    func suspend() {
        // Sync + reload as the app leaves the foreground so the home-screen widgets show the
        // latest chats/images when the user looks at them.
        widgetSyncEngine?.syncNow()
        spotlightIndexer?.refresh()
    }

    func shortcutItem() -> UIApplicationShortcutItem? {
        aiChatSettings.isAIChatEnabled ?
            UIApplicationShortcutItem(type: ShortcutKey.aiChat,
                                      localizedTitle: UserText.duckAiFeatureName,
                                      localizedSubtitle: nil,
                                      icon: UIApplicationShortcutIcon(templateImageName: "ApplicationShortcutItemAIChat"),
                                      userInfo: nil) : nil
    }

}
