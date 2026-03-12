//
//  DataBrokerProtectionIOSManagerContinuedProcessingTests.swift
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

import XCTest
@testable import DataBrokerProtection_iOS
import DataBrokerProtectionCore

@MainActor
final class DataBrokerProtectionIOSManagerContinuedProcessingTests: XCTestCase {

    func testWhenPrepareContinuedProcessingInitialRunAndPendingScansExist_thenReturnsInitialScanPlan() async throws {
        let (sut, dependencies) = DBPContinuedProcessingTestUtils.makeTestIOSManager()
        dependencies.database.brokerProfileQueryDataToReturn = [
            DBPContinuedProcessingTestUtils.makeBrokerProfileQueryData(
                brokerId: 1,
                profileQueryId: 1,
                scanPreferredRunDate: .now
            )
        ]

        let initialScanPlan = try await sut.prepareContinuedProcessingInitialRun(profile: DBPContinuedProcessingTestUtils.makeProfile())

        XCTAssertEqual(initialScanPlan?.scanCount, 1)
        XCTAssertTrue(dependencies.database.wasSaveProfileCalled)
        XCTAssertTrue(dependencies.eventsHandler.profileSavedFired)
    }

    func testWhenStartImmediateScanOperationsForContinuedProcessing_thenStartsQueueAndEmitsScanPhaseCompleted() async {
        let (sut, dependencies) = DBPContinuedProcessingTestUtils.makeTestIOSManager()
        let delegate = MockContinuedProcessingEventDelegate()
        let expectation = expectation(description: "scan phase completed")
        delegate.onEvent = { event in
            if case .scanPhaseCompleted = event {
                expectation.fulfill()
            }
        }
        sut.continuedProcessingDelegate = delegate

        await sut.startImmediateScanOperationsForContinuedProcessing()
        await fulfillment(of: [expectation], timeout: 1)

        XCTAssertTrue(dependencies.queueManager.didCallStartImmediateScanOperationsIfPermitted)
    }

    func testWhenStartImmediateOptOutOperationsForContinuedProcessing_thenStartsQueueAndEmitsOptOutPhaseCompleted() async {
        let (sut, dependencies) = DBPContinuedProcessingTestUtils.makeTestIOSManager()
        let delegate = MockContinuedProcessingEventDelegate()
        let expectation = expectation(description: "opt-out phase completed")
        delegate.onEvent = { event in
            if case .optOutPhaseCompleted = event {
                expectation.fulfill()
            }
        }
        sut.continuedProcessingDelegate = delegate

        sut.startImmediateOptOutOperationsForContinuedProcessing()
        await fulfillment(of: [expectation], timeout: 1)

        XCTAssertTrue(dependencies.queueManager.didCallStartImmediateOptOutOperationsIfPermitted)
    }

    func testWhenStopContinuedProcessingOperations_thenStopsQueue() {
        let (sut, dependencies) = DBPContinuedProcessingTestUtils.makeTestIOSManager()

        sut.stopContinuedProcessingOperations()

        XCTAssertTrue(dependencies.queueManager.didCallStop)
    }
}
