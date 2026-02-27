//
//  EventHubSubfeature.swift
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
import UserScript
import WebKit

public final class EventHubSubfeature: Subfeature {

    private let eventHub: EventHub
    private let tabIdProvider: EventHubTabIdProviding

    public var broker: UserScriptMessageBroker?

    public var featureName: String { "webEvents" }

    public var messageOriginPolicy: MessageOriginPolicy { .all }

    public init(eventHub: EventHub, tabIdProvider: EventHubTabIdProviding) {
        self.eventHub = eventHub
        self.tabIdProvider = tabIdProvider
    }

    public func handler(forMethodNamed methodName: String) -> Handler? {
        guard methodName == "webEvent" else { return nil }
        return { [weak self] params, message in
            self?.handleWebEvent(params: params, message: message)
            return nil
        }
    }

    private func handleWebEvent(params: Any, message: WKScriptMessage) {
        guard let dict = params as? [String: Any],
              let type = dict["type"] as? String else {
            return
        }

        let tabId = tabIdProvider.tabId(for: message.webView)
        eventHub.handleWebEvent(type: type, tabId: tabId)
    }
}

public protocol EventHubTabIdProviding {
    func tabId(for webView: WKWebView?) -> String?
}
