//
//  ExampleMessageHandler.swift
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

import Foundation
import os.log

/// Example message handler demonstrating the pattern for handling web extension messages.
/// This handler can be used as a template for creating feature-specific handlers.
@available(macOS 15.4, iOS 18.4, *)
public final class ExampleMessageHandler: WebExtensionMessageHandler {

    public var handledFeatureName: String { "example" }

    public init() {}

    public func handleMessage(_ message: WebExtensionMessage) async -> WebExtensionMessageResult {
        Logger.webExtensions.debug("📝 ExampleMessageHandler received method: \(message.method)")

        switch message.method {
        case "ping":
            return handlePing(message)
        case "echo":
            return handleEcho(message)
        default:
            return .failure(WebExtensionMessageHandlerError.unknownMethod(message.method))
        }
    }

    private func handlePing(_ message: WebExtensionMessage) -> WebExtensionMessageResult {
        return .success(["response": "pong"])
    }

    private func handleEcho(_ message: WebExtensionMessage) -> WebExtensionMessageResult {
        guard let text = message.params?["text"] as? String else {
            return .failure(WebExtensionMessageHandlerError.missingParameter("text"))
        }

        return .success(["echo": text])
    }
}
