//
//  MacOSEventHubIntegration.swift
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
import EventHub
import Foundation
import PixelKit
import PrivacyConfig
import WebKit

final class MacOSEventHubIntegration {

    let coordinator: EventHubCoordinator

    init(configManager: PrivacyConfigurationManaging) {
        coordinator = EventHubCoordinator(
            configManager: configManager,
            pixelFiring: MacOSEventHubPixelFiring(),
            appStateProvider: MacOSAppStateProvider(),
            tabIdProvider: MacOSTabIdProvider()
        )
    }

    func applicationDidBecomeActive() {
        coordinator.applicationDidBecomeActive()
    }
}

private struct MacOSEventHubPixelFiring: EventHubPixelFiring {
    func firePixel(named pixelName: String, parameters: [String: String]) {
        let event = EventHubPixelEvent(pixelName: pixelName, pixelParameters: parameters)
        PixelKit.fire(event, frequency: .standard)
    }
}

private struct EventHubPixelEvent: PixelKitEvent {
    let pixelName: String
    let pixelParameters: [String: String]

    var name: String { pixelName }
    var parameters: [String: String]? { pixelParameters }
    var error: (any Error)? { nil }
    var standardParameters: [PixelKitStandardParameter]? { nil }
}

private struct MacOSAppStateProvider: EventHubAppStateProviding {
    var isAppInForeground: Bool {
        DispatchQueue.main.sync {
            NSApplication.shared.isActive
        }
    }
}

final class MacOSTabIdProvider: EventHubTabIdProviding {

    private var webViewToTabId = NSMapTable<WKWebView, NSString>.weakToStrongObjects()

    func register(webView: WKWebView, tabId: String) {
        webViewToTabId.setObject(tabId as NSString, forKey: webView)
    }

    func tabId(for webView: WKWebView?) -> String? {
        guard let webView else { return nil }
        return webViewToTabId.object(forKey: webView) as String?
    }
}
