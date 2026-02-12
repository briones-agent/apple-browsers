//
//  WebExtensionHandlerProvider+macOS.swift
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

import AppKit
import WebExtensions
import WebKit

@available(macOS 15.4, *)
final class WebExtensionHandlerProvider: WebExtensionHandlerProviding {

    init() {}

    func makeHandlers(for extensionIdentifier: String, context: WKWebExtensionContext) -> [WebExtensionMessageHandler] {
        let extensionName = context.webExtension.displayName

        // TODO: Replace with actual extension names and handlers
        switch extensionName {
        case "Example Extension":
            return makeExampleHandlers()
        default:
            return []
        }
    }

    private func makeExampleHandlers() -> [WebExtensionMessageHandler] {
        // TODO: Create real handlers here based on your feature requirements
        // Example:
        // return [
        //     ContentBlockingMessageHandler(service: dependencies.contentBlockingService),
        //     PrivacyStatsMessageHandler(service: dependencies.privacyStatsService)
        // ]
        return []
    }
}
