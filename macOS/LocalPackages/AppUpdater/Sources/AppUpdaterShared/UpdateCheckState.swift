//
//  UpdateCheckState.swift
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

/// Actor responsible for managing update check state and rate limiting.
///
/// Handles rate limiting and in-flight tracking to prevent concurrent update checks.
/// Each UpdateController instance has its own UpdateCheckState for isolated state management.
///
public actor UpdateCheckState {

    /// Default minimum interval between update checks
    public static let defaultMinimumCheckInterval: TimeInterval = .minutes(5)

    private var lastUpdateCheckTime: Date?
    private var isCheckInProgress = false

    public init() {}

    /// Determines whether a new update check can be started.
    ///
    /// Returns `false` if a check is already in flight, the updater disallows checks,
    /// or the minimum interval since the last check has not elapsed.
    ///
    public func canStartNewCheck(
        updater: UpdaterAvailabilityChecking?,
        minimumInterval: TimeInterval = UpdateCheckState.defaultMinimumCheckInterval
    ) -> Bool {
        guard !isCheckInProgress else { return false }

        if let updater = updater, !updater.canCheckForUpdates {
            return false
        }

        if let lastCheck = lastUpdateCheckTime,
           Date().timeIntervalSince(lastCheck) < minimumInterval {
            return false
        }

        return true
    }

    /// Marks a check as in progress. Call this immediately after `canStartNewCheck` returns `true`.
    public func beginCheck() {
        isCheckInProgress = true
    }

    /// Marks the check as finished and records the current time for rate limiting.
    /// Call this in both the success and error paths of the check.
    public func endCheck() {
        isCheckInProgress = false
        lastUpdateCheckTime = Date()
    }
}
