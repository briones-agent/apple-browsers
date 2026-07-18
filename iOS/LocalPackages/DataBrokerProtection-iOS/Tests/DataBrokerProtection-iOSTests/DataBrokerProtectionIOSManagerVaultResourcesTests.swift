//
//  DataBrokerProtectionIOSManagerVaultResourcesTests.swift
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

@MainActor
final class DataBrokerProtectionIOSManagerVaultResourcesTests: XCTestCase {

    private enum TestError: Error {
        case initializationFailed
    }

    func testPrepareSecureVaultResourcesAtLaunch_concurrentCallsShareInitialization() async throws {
        let providerStarted = expectation(description: "Provider started")
        let releaseProvider = DispatchSemaphore(value: 0)
        let providerCallCount = LockedValue(0)

        let (sut, _) = DBPIOSManagerTestUtils.makeDeferredTestIOSManager { resources in
            {
                providerCallCount.withValue { $0 += 1 }
                providerStarted.fulfill()
                releaseProvider.wait()
                return resources
            }
        }

        let first = Task {
            try await sut.prepareSecureVaultResourcesAtLaunch()
        }
        await fulfillment(of: [providerStarted], timeout: 1)

        let second = Task {
            try await sut.prepareSecureVaultResourcesAtLaunch()
        }
        await Task.yield()

        releaseProvider.signal()
        releaseProvider.signal()
        try await first.value
        try await second.value

        XCTAssertEqual(providerCallCount.value, 1)
    }

    func testPrepareSecureVaultResourcesAtLaunch_afterFailureRetriesInitialization() async throws {
        let providerCallCount = LockedValue(0)

        let (sut, _) = DBPIOSManagerTestUtils.makeDeferredTestIOSManager { resources in
            {
                let callCount = providerCallCount.withValue { count in
                    count += 1
                    return count
                }

                if callCount == 1 {
                    throw TestError.initializationFailed
                }

                return resources
            }
        }

        do {
            try await sut.prepareSecureVaultResourcesAtLaunch()
            XCTFail("Expected first initialization attempt to fail")
        } catch TestError.initializationFailed {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        try await sut.prepareSecureVaultResourcesAtLaunch()

        XCTAssertEqual(providerCallCount.value, 2)
    }
}

private final class LockedValue<Value> {
    private let lock = NSLock()
    private var storage: Value

    var value: Value {
        lock.withLock {
            storage
        }
    }

    init(_ value: Value) {
        storage = value
    }

    func withValue<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        try lock.withLock {
            try body(&storage)
        }
    }
}
