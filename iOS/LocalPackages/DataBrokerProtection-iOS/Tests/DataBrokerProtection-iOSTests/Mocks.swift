//
//  Mocks.swift
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

import Common
import SwiftUI
@testable import DataBrokerProtection_iOS
import DataBrokerProtectionCore

final class MockDataBrokerProtectionUserNotificationService: DataBrokerProtectionUserNotificationService {
    func requestNotificationPermission() {}
    func sendFirstScanCompletedNotification() {}
    func sendFirstRemovedNotificationIfPossible() {}
    func sendAllInfoRemovedNotificationIfPossible() {}
    func scheduleCheckInNotificationIfPossible() {}
    func sendGoToMarketFirstScanNotificationIfPossible() async {}
    func resetFirstScanCompletedNotificationState() {}
    func resetAllNotificationStatesForDebug() {}
}

final class MockDataBrokerProtectionSubscriptionManaging: DataBrokerProtectionSubscriptionManaging {
    func accessToken() async -> String? { nil }
    func hasValidEntitlement() async throws -> Bool { false }
    func isUserEligibleForFreeTrial() -> Bool { false }
}

final class MockContinuedProcessingEventDelegate: DBPContinuedProcessingEventDelegate {
    var onEvent: ((DBPContinuedProcessingEvent) -> Void)?

    func iosManager(_ manager: DataBrokerProtectionIOSManager, didEmit event: DBPContinuedProcessingEvent) {
        onEvent?(event)
    }
}

final class MockContinuedProcessingCoordinator: DBPContinuedProcessingCoordinating {
    var didCallStartInitialRun = false
    var hasAttachedTask = false
    var startInitialRunError: Error?
    private(set) var receivedProfile: DataBrokerProtectionProfile?

    @MainActor
    func startInitialRun(profile: DataBrokerProtectionProfile) async throws {
        didCallStartInitialRun = true
        receivedProfile = profile

        if let startInitialRunError {
            throw startInitialRunError
        }
    }

    func reset() {
        didCallStartInitialRun = false
        hasAttachedTask = false
        startInitialRunError = nil
        receivedProfile = nil
    }
}
