//
//  EventHubCoordinator.swift
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

import Combine
import Foundation
import PrivacyConfig
import os.log

public final class EventHubCoordinator {

    public let eventHub: EventHub
    public let subfeature: EventHubSubfeature

    private let configManager: PrivacyConfigurationManaging
    private var cancellables = Set<AnyCancellable>()
    private var lastConfigJSON: Data?

    public init(configManager: PrivacyConfigurationManaging,
                storage: EventHubStoring = EventHubUserDefaultsStorage(),
                pixelFiring: EventHubPixelFiring,
                appStateProvider: EventHubAppStateProviding,
                tabIdProvider: EventHubTabIdProviding,
                dateProvider: @escaping () -> Date = { Date() },
                timerFactory: EventHubTimerFactory = DefaultEventHubTimerFactory()) {
        self.configManager = configManager

        eventHub = EventHub(
            storage: storage,
            pixelFiring: pixelFiring,
            appStateProvider: appStateProvider,
            dateProvider: dateProvider,
            timerFactory: timerFactory
        )

        subfeature = EventHubSubfeature(eventHub: eventHub, tabIdProvider: tabIdProvider)

        subscribeToConfigChanges()
        applyCurrentConfig()
    }

    /// Call when the app returns to the foreground.
    public func applicationDidBecomeActive() {
        eventHub.checkPixels()
    }

    /// Call on navigation start for a tab. Used for dedup tracking.
    public func onNavigationStarted(tabId: String, url: String) {
        eventHub.onNavigationStarted(tabId: tabId, url: url)
    }

    // MARK: - Private

    private func subscribeToConfigChanges() {
        configManager.updatesPublisher
            .sink { [weak self] in
                self?.applyCurrentConfig()
            }
            .store(in: &cancellables)
    }

    private func applyCurrentConfig() {
        let privacyConfig = configManager.privacyConfig
        let settings = privacyConfig.settings(for: .eventHub)

        if settings.isEmpty {
            let eventHubState = privacyConfig.stateFor(featureKey: .eventHub)
            if case .disabled = eventHubState {
                eventHub.onConfigChanged(nil)
                return
            }
        }

        var mergedSettings = settings
        if mergedSettings["state"] == nil {
            let state = privacyConfig.stateFor(featureKey: .eventHub)
            switch state {
            case .enabled:
                mergedSettings["state"] = "enabled"
            default:
                mergedSettings["state"] = "disabled"
            }
        }

        if let config = EventHubConfiguration(settings: mergedSettings) {
            let newJSON = try? JSONEncoder().encode(config)
            guard newJSON != lastConfigJSON else { return }
            lastConfigJSON = newJSON
            eventHub.onConfigChanged(config)
        } else {
            eventHub.onConfigChanged(nil)
        }
    }
}
