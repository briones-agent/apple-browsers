//
//  AIChatWidgetDataLocation.swift
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

/// Resolves the on-disk locations of the Duck.ai widget mirror inside a shared app-group
/// container. Both the main app (writer) and the widget extension (reader) construct this
/// from the same app group so they agree on where the mirror lives.
public struct AIChatWidgetDataLocation {

    /// Root directory of the widget mirror inside the app-group container.
    public let rootURL: URL

    public init(containerURL: URL) {
        self.rootURL = containerURL.appendingPathComponent("duck-ai-widget", isDirectory: true)
    }

    /// Builds a location from the shared app-group container. Returns `nil` when the container
    /// cannot be resolved (e.g. missing entitlement).
    public static func appGroup(groupName: String = Global.appConfigurationGroupName) -> AIChatWidgetDataLocation? {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupName) else {
            return nil
        }
        return AIChatWidgetDataLocation(containerURL: container)
    }

    /// JSON file holding the `[WidgetChatEntry]` mirror.
    public var chatsFileURL: URL {
        rootURL.appendingPathComponent("chats.json")
    }

    /// Directory holding per-chat thumbnail JPEGs.
    public var thumbnailsDirectoryURL: URL {
        rootURL.appendingPathComponent("thumbnails", isDirectory: true)
    }

    /// Thumbnail JPEG location for a given chat id.
    public func thumbnailURL(forChatId chatId: String) -> URL {
        thumbnailsDirectoryURL.appendingPathComponent("\(chatId).jpg")
    }
}
