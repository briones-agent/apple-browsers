//
//  UpdateCheckStateTests.swift
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

import AppUpdaterShared
import AppUpdaterTestHelpers
import XCTest

/// Tests for UpdateCheckState actor that manages update check rate limiting.
///
/// This test suite validates rate limiting behavior that prevents excessive update checks
/// which could impact performance or server load.
///
/// These behaviors are essential for:
/// - Maintaining app responsiveness during update checks
/// - Preventing server abuse from rapid-fire update requests
/// - Ensuring user-initiated checks can bypass rate limiting when needed
@available(macOS 10.15.0, *)
final class UpdateCheckStateTests: XCTestCase {

    var updateCheckState: UpdateCheckState!
    var mockUpdater: MockUpdater!

    override func setUp() async throws {
        try await super.setUp()
        updateCheckState = UpdateCheckState()
        mockUpdater = MockUpdater()
    }

    override func tearDown() async throws {
        updateCheckState = nil
        mockUpdater = nil
        try await super.tearDown()
    }

    // MARK: - beginCheckIfAllowed Tests

    /// Tests that update checks are allowed when the system is in its initial state.
    func testAllowsUpdateChecksInInitialState() async {
        let started = await updateCheckState.beginCheckIfAllowed(updater: mockUpdater)
        XCTAssertTrue(started, "Should be able to start check in initial state")
    }

    /// Tests that update checks are rate limited to prevent excessive requests.
    func testRateLimitingPreventsExcessiveRequests() async {
        await updateCheckState.endCheck()

        let started = await updateCheckState.beginCheckIfAllowed(updater: mockUpdater)
        XCTAssertFalse(started, "Should be rate limited when checking too soon")
    }

    /// Tests that rate limiting can be bypassed when needed (e.g., user-initiated checks).
    func testRateLimitingCanBeBypassed() async {
        await updateCheckState.endCheck()

        let started = await updateCheckState.beginCheckIfAllowed(updater: mockUpdater, minimumInterval: 0)
        XCTAssertTrue(started, "Should be able to start check when rate limit is disabled")
    }

    /// Tests that rate limiting intervals are configurable for different scenarios.
    func testRateLimitingIntervalsAreConfigurable() async {
        await updateCheckState.endCheck()

        let started = await updateCheckState.beginCheckIfAllowed(updater: mockUpdater, minimumInterval: 0.1)
        XCTAssertFalse(started, "Should respect custom minimum interval")
    }

    /// Tests that checks are blocked when Sparkle doesn't allow updates.
    func testChecksAreBlockedWhenSparkleDoesntAllow() async {
        mockUpdater.mockCanCheckForUpdates = false

        let started = await updateCheckState.beginCheckIfAllowed(updater: mockUpdater)
        XCTAssertFalse(started, "Should not be able to start check when Sparkle doesn't allow it")
    }

    /// Tests that checks are allowed when Sparkle allows updates.
    func testChecksAreAllowedWhenSparkleAllows() async {
        mockUpdater.mockCanCheckForUpdates = true

        let started = await updateCheckState.beginCheckIfAllowed(updater: mockUpdater)
        XCTAssertTrue(started, "Should be able to start check when Sparkle allows it")
    }

    /// Tests that nil updater allows update checks (doesn't block them).
    func testNilUpdaterAllowsChecks() async {
        let started = await updateCheckState.beginCheckIfAllowed(updater: nil)
        XCTAssertTrue(started, "Should be able to start check with nil updater")
    }

    /// Tests that nil updater still respects rate limiting.
    func testNilUpdaterRespectsRateLimiting() async {
        await updateCheckState.endCheck()

        let started = await updateCheckState.beginCheckIfAllowed(updater: nil)
        XCTAssertFalse(started, "Should still be rate limited with nil updater")
    }

    // MARK: - endCheck Tests

    /// Tests that endCheck enables rate limiting for subsequent checks.
    func testEndCheckEnablesRateLimiting() async {
        let initialStart = await updateCheckState.beginCheckIfAllowed(updater: mockUpdater)
        XCTAssertTrue(initialStart, "Should initially be able to start check")

        await updateCheckState.endCheck()

        let startAfterEnd = await updateCheckState.beginCheckIfAllowed(updater: mockUpdater)
        XCTAssertFalse(startAfterEnd, "Should be rate limited after endCheck")
    }

    /// Tests that rate limiting expires after sufficient time passes.
    func testRateLimitingExpiresAfterTime() async {
        await updateCheckState.endCheck()

        // Check immediately after — should be rate limited
        let canStartImmediately = await updateCheckState.beginCheckIfAllowed(updater: mockUpdater, minimumInterval: 0.01)
        XCTAssertFalse(canStartImmediately, "Should be rate limited immediately after endCheck")

        // Wait for rate limit to expire
        try? await Task.sleep(nanoseconds: 20_000_000) // 20ms

        let canStartAfterWait = await updateCheckState.beginCheckIfAllowed(updater: mockUpdater, minimumInterval: 0.01)
        XCTAssertTrue(canStartAfterWait, "Should be able to start check after rate limit expires")
    }

    // MARK: - Integration Tests

    /// Tests the basic rate limiting workflow.
    func testBasicRateLimitingWorkflow() async {
        // Initial state - should allow checks
        let initialStart = await updateCheckState.beginCheckIfAllowed(updater: mockUpdater)
        XCTAssertTrue(initialStart, "Should initially be able to start check")

        // End check - should now be rate limited
        await updateCheckState.endCheck()
        let startAfterEnd = await updateCheckState.beginCheckIfAllowed(updater: mockUpdater)
        XCTAssertFalse(startAfterEnd, "Should be rate limited after endCheck")

        // User-initiated check can bypass rate limit
        let userInitiatedStart = await updateCheckState.beginCheckIfAllowed(updater: mockUpdater, minimumInterval: 0)
        XCTAssertTrue(userInitiatedStart, "User-initiated check should bypass rate limit")
    }

    /// Tests behavior with different Sparkle states and rate limiting.
    func testSparkleStateAndRateLimitingInteraction() async {
        // Record a check time to enable rate limiting
        await updateCheckState.endCheck()

        // Even if rate limited, Sparkle state should still be respected
        mockUpdater.mockCanCheckForUpdates = false
        let canStartWithBlockedSparkle = await updateCheckState.beginCheckIfAllowed(updater: mockUpdater, minimumInterval: 0)
        XCTAssertFalse(canStartWithBlockedSparkle, "Should not be able to start even when bypassing rate limit if Sparkle blocks")

        // When Sparkle allows but we're rate limited
        mockUpdater.mockCanCheckForUpdates = true
        let canStartWithAllowedSparkle = await updateCheckState.beginCheckIfAllowed(updater: mockUpdater)
        XCTAssertFalse(canStartWithAllowedSparkle, "Should still be rate limited even when Sparkle allows")

        // When both Sparkle allows and rate limit is bypassed
        let canStartBothAllowed = await updateCheckState.beginCheckIfAllowed(updater: mockUpdater, minimumInterval: 0)
        XCTAssertTrue(canStartBothAllowed, "Should be able to start when both conditions are met")
    }

    // MARK: - Constants Tests

    /// Tests that the default rate limiting interval is configured to 5 minutes.
    func testDefaultRateLimitingInterval() {
        XCTAssertEqual(UpdateCheckState.defaultMinimumCheckInterval, .minutes(5), "Default minimum check interval should be 5 minutes")
    }

    // MARK: - Atomicity / in-flight guard tests

    /// Fires N concurrent callers and asserts exactly one wins.
    /// Validates that beginCheckIfAllowed is atomic under real concurrency,
    /// not just sequential state transitions.
    func testExactlyOneCallerWinsUnderConcurrency() async {
        let results = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    await self.updateCheckState.beginCheckIfAllowed(updater: self.mockUpdater)
                }
            }
            var outcomes: [Bool] = []
            for await result in group {
                outcomes.append(result)
            }
            return outcomes
        }

        let startedCount = results.filter { $0 }.count
        XCTAssertEqual(startedCount, 1, "Exactly one concurrent caller should be allowed to start a check")
    }

    /// beginCheckIfAllowed must atomically check AND set the flag.
    /// A second call while the first is in flight must return false immediately.
    func testBlocksNewCheckWhileOneIsInFlight() async {
        let firstStart = await updateCheckState.beginCheckIfAllowed(updater: mockUpdater)
        XCTAssertTrue(firstStart, "First check should start")

        let secondStart = await updateCheckState.beginCheckIfAllowed(updater: mockUpdater)
        XCTAssertFalse(secondStart, "Should block a second check while one is already in flight")
    }

    /// After endCheck(), the gate should open again (respecting the time interval).
    func testAllowsCheckAfterEndCheck() async {
        _ = await updateCheckState.beginCheckIfAllowed(updater: mockUpdater)
        await updateCheckState.endCheck()

        // minimumInterval: 0 to bypass the time check — we only want to test the flag
        let started = await updateCheckState.beginCheckIfAllowed(updater: mockUpdater, minimumInterval: 0)
        XCTAssertTrue(started, "Should allow a new check after endCheck() clears the flag")
    }

    /// Rate limiting must apply even when no update has ever been found.
    func testRateLimitingAppliesEvenWhenNoUpdateFound() async {
        // Simulate: a check ran, found no update, endCheck() called
        _ = await updateCheckState.beginCheckIfAllowed(updater: mockUpdater)
        await updateCheckState.endCheck()

        // Immediately after — should be rate limited
        let started = await updateCheckState.beginCheckIfAllowed(updater: mockUpdater)
        XCTAssertFalse(started, "Rate limiting must apply even when no update has ever been found")
    }

    /// endCheck() records check time, so the rate limit window starts from that call.
    func testEndCheckRecordsCheckTime() async {
        _ = await updateCheckState.beginCheckIfAllowed(updater: mockUpdater)
        await updateCheckState.endCheck()

        // With a large interval, should be blocked immediately after endCheck
        let started = await updateCheckState.beginCheckIfAllowed(updater: mockUpdater, minimumInterval: 60)
        XCTAssertFalse(started, "endCheck() must record check time for rate limiting")
    }
}
