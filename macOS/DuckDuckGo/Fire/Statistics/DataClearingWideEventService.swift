//
//  DataClearingWideEventService.swift
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
import BrowserServicesKit
import PixelKit

/// Service responsible for managing data clearing wide event lifecycle.
///
/// This service handles the complete lifecycle of data clearing wide events:
/// - Starting new events with macOS-specific parameters
/// - Tracking per-action results (success or failure)
/// - Completing events with overall duration calculation
///
/// The service maintains a single active event at a time and automatically
/// cleans up pending events when starting a new one.
final class DataClearingWideEventService {

    /// Execution path during data clearing.
    enum BurnPath: String {
        case burnEntity = "burn_entity"
        case burnAll = "burn_all"
        case burnVisits = "burn_visits"
    }

    // MARK: - Properties

    private let wideEvent: WideEventManaging
    private var eventData: DataClearingWideEventData?

    // MARK: - Initialization

    /// Creates a new data clearing wide event service.
    /// - Parameter wideEvent: The wide event manager for handling event flows.
    init(wideEvent: WideEventManaging) {
        self.wideEvent = wideEvent
    }

    // MARK: - Starting Wide Event

    /// Starts a new data clearing wide event.
    ///
    /// This method creates and initializes a new wide event with the specified parameters
    /// from the Fire dialog. Any pending events are automatically completed before starting the new one.
    ///
    /// - Parameters:
    ///   - options: The Fire dialog result containing user selections.
    ///   - path: The execution path during clearing.
    ///   - isAutoClear: Whether this was triggered by auto-clear.
    func start(
        options: FireDialogResult,
        path: BurnPath,
        isAutoClear: Bool
    ) {
        completeAllPending()

        let data = DataClearingWideEventData(
            options: options.toWideEventOptions(),
            trigger: isAutoClear.toWideEventTrigger(),
            overallDuration: .startingNow(),
            path: path.toWideEventPath(),
            includedDomains: options.toIncludedDomains(),
            contextData: WideEventContextData(name: "data-clearing")
        )

        self.eventData = data
        wideEvent.startFlow(data)
    }

    // MARK: - Updating Action Results

    /// Updates the wide event with a successful action result.
    ///
    /// - Parameters:
    ///   - action: The action that completed successfully.
    ///   - duration: The measured duration of the action.
    func update(action: DataClearingWideEventData.Action, duration: WideEvent.MeasuredInterval) {
        eventData?[keyPath: action.durationPath] = duration
        eventData?[keyPath: action.statusPath] = .success
    }

    /// Updates the wide event with a failed action result.
    ///
    /// - Parameters:
    ///   - action: The action that failed.
    ///   - error: The error that occurred.
    ///   - duration: The measured duration of the action.
    func update(action: DataClearingWideEventData.Action, error: Error, duration: WideEvent.MeasuredInterval) {
        eventData?[keyPath: action.durationPath] = duration
        eventData?[keyPath: action.statusPath] = .failure
        eventData?[keyPath: action.errorPath] = WideEventErrorData(error: error)
    }

    // MARK: - Completing Wide Event

    /// Completes the current wide event with success status.
    ///
    /// This method finalizes the overall duration, marks the event as successful,
    /// and fires the wide pixel. The event data is then cleared.
    func complete() {
        guard let data = eventData else { return }
        data.overallDuration?.complete()
        wideEvent.completeFlow(data, status: .success, onComplete: { _, _ in })
        eventData = nil
    }
}

// MARK: - Private Helpers

private extension DataClearingWideEventService {

    /// Completes all pending data clearing wide events.
    ///
    /// This is called before starting a new event to ensure only one
    /// active event exists at a time. Pending events are marked as unknown.
    func completeAllPending() {
        let pending = wideEvent.getAllFlowData(DataClearingWideEventData.self)
        for data in pending {
            wideEvent.completeFlow(
                data,
                status: .unknown(reason: DataClearingWideEventData.StatusReason.partialData.rawValue),
                onComplete: { _, _ in }
            )
        }
    }
}

// MARK: - Transformation Helpers

private extension FireDialogResult {

    /// Transforms Fire dialog clearing option to wide event options.
    func toWideEventOptions() -> DataClearingWideEventData.Options {
        switch clearingOption {
        case .currentTab:
            return .currentTab
        case .currentWindow:
            return .currentWindow
        case .allData:
            return .allData
        }
    }

    /// Prepares included domains string from Fire dialog result.
    func toIncludedDomains() -> String {
        var domains: [String] = []
        if includeHistory {
            domains.append("History")
        }
        if includeTabsAndWindows {
            domains.append("TabsAndWindows")
        }
        if includeCookiesAndSiteData {
            domains.append("CookiesAndSiteData")
        }
        if includeChatHistory {
            domains.append("ChatHistory")
        }
        return domains.joined(separator: ",")
    }
}

private extension Bool {

    /// Transforms auto-clear boolean to wide event trigger.
    func toWideEventTrigger() -> DataClearingWideEventData.Trigger {
        return self ? .autoClear : .manual
    }
}

private extension DataClearingWideEventService.BurnPath {

    /// Transforms burn path to wide event path.
    func toWideEventPath() -> DataClearingWideEventData.Path {
        switch self {
        case .burnEntity:
            return .burnEntity
        case .burnAll:
            return .burnAll
        case .burnVisits:
            return .burnVisits
        }
    }
}
