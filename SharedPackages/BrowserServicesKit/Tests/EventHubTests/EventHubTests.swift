//
//  EventHubTests.swift
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
@testable import EventHub

final class EventHubTests: XCTestCase {

    private var storage: MockEventHubStorage!
    private var pixelFiring: MockPixelFiring!
    private var appState: MockAppStateProvider!
    private var timerFactory: MockTimerFactory!
    private var currentDate: Date!
    private var eventHub: EventHub!

    override func setUp() {
        super.setUp()
        storage = MockEventHubStorage()
        pixelFiring = MockPixelFiring()
        appState = MockAppStateProvider()
        timerFactory = MockTimerFactory()
        currentDate = Date(timeIntervalSince1970: 1_740_000_000) // 2025-02-20
        eventHub = EventHub(
            storage: storage,
            pixelFiring: pixelFiring,
            appStateProvider: appState,
            dateProvider: { [unowned self] in self.currentDate },
            timerFactory: timerFactory
        )
    }

    // MARK: - Configuration

    func testWhenConfigIsNilThenEventHubIsDisabled() {
        eventHub.onConfigChanged(nil)
        XCTAssertFalse(eventHub.isEnabled)
    }

    func testWhenConfigStateIsDisabledThenEventHubIsDisabled() {
        let config = EventHubConfiguration(state: "disabled", telemetry: [:])
        eventHub.onConfigChanged(config)
        XCTAssertFalse(eventHub.isEnabled)
    }

    func testWhenConfigStateIsEnabledThenEventHubIsEnabled() {
        eventHub.onConfigChanged(makeEnabledConfig())
        XCTAssertTrue(eventHub.isEnabled)
    }

    func testWhenConfigChangesToDisabledThenAllStateIsCleared() {
        eventHub.onConfigChanged(makeEnabledConfig())
        XCTAssertEqual(timerFactory.timersCreated.count, 1)

        eventHub.onConfigChanged(EventHubConfiguration(state: "disabled", telemetry: [:]))
        XCTAssertTrue(storage.allPixelStates().isEmpty)
        XCTAssertTrue(timerFactory.timersCreated.allSatisfy { $0.isCancelled })
    }

    func testWhenConfigChangesToNilThenAllStateIsCleared() {
        eventHub.onConfigChanged(makeEnabledConfig())
        eventHub.onConfigChanged(nil)
        XCTAssertTrue(storage.allPixelStates().isEmpty)
    }

    // MARK: - Telemetry Registration

    func testWhenEnabledTelemetryRegisteredThenTimerIsScheduled() {
        eventHub.onConfigChanged(makeEnabledConfig())
        XCTAssertEqual(timerFactory.timersCreated.count, 1)
    }

    func testWhenTelemetryIsDisabledThenItIsNotRegistered() {
        let config = EventHubConfiguration(
            state: "enabled",
            telemetry: [
                "test_pixel": TelemetryPixelConfiguration(
                    state: "disabled",
                    trigger: TriggerConfiguration(period: PeriodConfiguration(days: 1)),
                    parameters: [:]
                )
            ]
        )
        eventHub.onConfigChanged(config)
        XCTAssertTrue(timerFactory.timersCreated.isEmpty)
    }

    func testWhenAppIsBackgroundedThenNewPeriodDoesNotStart() {
        appState.isAppInForeground = false
        eventHub.onConfigChanged(makeEnabledConfig())
        XCTAssertTrue(storage.allPixelStates().isEmpty)
        XCTAssertTrue(timerFactory.timersCreated.isEmpty)
    }

    // MARK: - Event Handling

    func testWhenEventMatchesSourceThenCounterIncrements() {
        eventHub.onConfigChanged(makeEnabledConfig())
        eventHub.handleWebEvent(type: "adwall", tabId: "tab1")

        let state = storage.loadPixelState(for: "test_pixel")
        XCTAssertEqual(state?.paramsState["count"]?.value, 1)
    }

    func testWhenEventDoesNotMatchSourceThenCounterDoesNotIncrement() {
        eventHub.onConfigChanged(makeEnabledConfig())
        eventHub.handleWebEvent(type: "other_event", tabId: "tab1")

        let state = storage.loadPixelState(for: "test_pixel")
        XCTAssertEqual(state?.paramsState["count"]?.value, 0)
    }

    func testWhenFeatureIsDisabledThenEventsAreIgnored() {
        eventHub.onConfigChanged(makeEnabledConfig())
        eventHub.onConfigChanged(EventHubConfiguration(state: "disabled", telemetry: [:]))
        eventHub.handleWebEvent(type: "adwall", tabId: "tab1")
        XCTAssertNil(storage.loadPixelState(for: "test_pixel"))
    }

    func testWhenEmptyEventTypeThenEventIsIgnored() {
        eventHub.onConfigChanged(makeEnabledConfig())
        eventHub.handleWebEvent(type: "", tabId: "tab1")

        let state = storage.loadPixelState(for: "test_pixel")
        XCTAssertEqual(state?.paramsState["count"]?.value, 0)
    }

    // MARK: - Deduplication

    func testWhenSameEventFromSameTabThenDeduplicated() {
        eventHub.onConfigChanged(makeEnabledConfig())
        eventHub.handleWebEvent(type: "adwall", tabId: "tab1")
        eventHub.handleWebEvent(type: "adwall", tabId: "tab1")
        eventHub.handleWebEvent(type: "adwall", tabId: "tab1")

        let state = storage.loadPixelState(for: "test_pixel")
        XCTAssertEqual(state?.paramsState["count"]?.value, 1)
    }

    func testWhenSameEventFromDifferentTabsThenNotDeduplicated() {
        eventHub.onConfigChanged(makeEnabledConfig())
        eventHub.handleWebEvent(type: "adwall", tabId: "tab1")
        eventHub.handleWebEvent(type: "adwall", tabId: "tab2")

        let state = storage.loadPixelState(for: "test_pixel")
        XCTAssertEqual(state?.paramsState["count"]?.value, 2)
    }

    func testWhenNavigationChangesURLThenDedupIsCleared() {
        eventHub.onConfigChanged(makeEnabledConfig())
        eventHub.handleWebEvent(type: "adwall", tabId: "tab1")
        XCTAssertEqual(storage.loadPixelState(for: "test_pixel")?.paramsState["count"]?.value, 1)

        eventHub.onNavigationStarted(tabId: "tab1", url: "https://pageA.com")
        eventHub.onNavigationStarted(tabId: "tab1", url: "https://pageB.com")

        eventHub.handleWebEvent(type: "adwall", tabId: "tab1")
        XCTAssertEqual(storage.loadPixelState(for: "test_pixel")?.paramsState["count"]?.value, 2)
    }

    func testWhenNavigationToSameURLThenDedupIsNotCleared() {
        eventHub.onConfigChanged(makeEnabledConfig())
        eventHub.onNavigationStarted(tabId: "tab1", url: "https://pageA.com")
        eventHub.handleWebEvent(type: "adwall", tabId: "tab1")

        eventHub.onNavigationStarted(tabId: "tab1", url: "https://pageA.com")
        eventHub.handleWebEvent(type: "adwall", tabId: "tab1")

        XCTAssertEqual(storage.loadPixelState(for: "test_pixel")?.paramsState["count"]?.value, 1)
    }

    func testWhenTabIdIsNilThenDedupIsBypassed() {
        eventHub.onConfigChanged(makeEnabledConfig())
        eventHub.handleWebEvent(type: "adwall", tabId: nil)
        eventHub.handleWebEvent(type: "adwall", tabId: nil)

        let state = storage.loadPixelState(for: "test_pixel")
        XCTAssertEqual(state?.paramsState["count"]?.value, 2)
    }

    // MARK: - Stop Counting

    func testWhenMaxBucketReachedThenStopCountingIsSet() {
        let config = makeEnabledConfig(buckets: [
            "0": BucketConfiguration(gte: 0, lt: 1),
            "1+": BucketConfiguration(gte: 1),
        ])
        eventHub.onConfigChanged(config)

        eventHub.handleWebEvent(type: "adwall", tabId: "tab1")
        eventHub.onNavigationStarted(tabId: "tab1", url: "https://a.com")
        eventHub.onNavigationStarted(tabId: "tab1", url: "https://b.com")
        eventHub.handleWebEvent(type: "adwall", tabId: "tab1")

        let state = storage.loadPixelState(for: "test_pixel")
        XCTAssertEqual(state?.paramsState["count"]?.stopCounting, true)
        XCTAssertEqual(state?.paramsState["count"]?.value, 1)
    }

    // MARK: - Pixel Firing

    func testWhenTimerFiresThenPixelIsFired() {
        eventHub.onConfigChanged(makeEnabledConfig())

        eventHub.handleWebEvent(type: "adwall", tabId: "tab1")
        eventHub.onNavigationStarted(tabId: "tab1", url: "https://a.com")
        eventHub.onNavigationStarted(tabId: "tab1", url: "https://b.com")
        eventHub.handleWebEvent(type: "adwall", tabId: "tab1")
        eventHub.onNavigationStarted(tabId: "tab1", url: "https://c.com")
        eventHub.handleWebEvent(type: "adwall", tabId: "tab1")

        timerFactory.timersCreated.first?.fire()

        XCTAssertEqual(pixelFiring.firedPixels.count, 1)
        XCTAssertEqual(pixelFiring.firedPixels.first?.name, "test_pixel")
        XCTAssertEqual(pixelFiring.firedPixels.first?.parameters["count"], "3-5")
        XCTAssertNotNil(pixelFiring.firedPixels.first?.parameters["attributionPeriod"])
    }

    func testWhenNoBucketMatchesThenPixelIsNotFired() {
        let config = makeEnabledConfig(buckets: [
            "1+": BucketConfiguration(gte: 1),
        ])
        eventHub.onConfigChanged(config)

        timerFactory.timersCreated.first?.fire()

        XCTAssertTrue(pixelFiring.firedPixels.isEmpty)
    }

    func testWhenPixelFiredThenPersistedStateIsDeleted() {
        eventHub.onConfigChanged(makeEnabledConfig())
        eventHub.handleWebEvent(type: "adwall", tabId: "tab1")

        let firstTimer = timerFactory.timersCreated.first!
        firstTimer.fire()

        XCTAssertEqual(pixelFiring.firedPixels.count, 1)
        // A new period is started, so new state is stored — but the OLD state is gone
        XCTAssertEqual(timerFactory.timersCreated.count, 2)
    }

    // MARK: - Foreground Check

    func testWhenCheckPixelsCalledThenExpiredStatesAreFired() {
        eventHub.onConfigChanged(makeEnabledConfig())
        eventHub.handleWebEvent(type: "adwall", tabId: "tab1")

        currentDate = currentDate.addingTimeInterval(86401)
        eventHub.checkPixels()

        XCTAssertEqual(pixelFiring.firedPixels.count, 1)
    }

    func testWhenCheckPixelsCalledThenNonExpiredStatesAreRearmed() {
        eventHub.onConfigChanged(makeEnabledConfig())
        let initialTimerCount = timerFactory.timersCreated.count

        currentDate = currentDate.addingTimeInterval(100)

        // Cancel all timers (simulating background)
        for timer in timerFactory.timersCreated {
            timer.cancel()
        }
        timerFactory.timersCreated.removeAll()

        eventHub.checkPixels()
        XCTAssertTrue(timerFactory.timersCreated.count > 0)
    }

    // MARK: - Persistence and Restoration

    func testWhenHubRecreatedThenPersistedStateIsRestored() {
        eventHub.onConfigChanged(makeEnabledConfig())
        eventHub.handleWebEvent(type: "adwall", tabId: "tab1")

        let secondHub = EventHub(
            storage: storage,
            pixelFiring: pixelFiring,
            appStateProvider: appState,
            dateProvider: { [unowned self] in self.currentDate },
            timerFactory: timerFactory
        )
        secondHub.onConfigChanged(makeEnabledConfig())

        let state = storage.loadPixelState(for: "test_pixel")
        XCTAssertEqual(state?.paramsState["count"]?.value, 1)
    }

    // MARK: - Helpers

    private func makeEnabledConfig(buckets: [String: BucketConfiguration]? = nil) -> EventHubConfiguration {
        let defaultBuckets: [String: BucketConfiguration] = [
            "0": BucketConfiguration(gte: 0, lt: 1),
            "1-2": BucketConfiguration(gte: 1, lt: 3),
            "3-5": BucketConfiguration(gte: 3, lt: 6),
            "6-10": BucketConfiguration(gte: 6, lt: 11),
            "11-20": BucketConfiguration(gte: 11, lt: 21),
            "21-39": BucketConfiguration(gte: 21, lt: 40),
            "40+": BucketConfiguration(gte: 40),
        ]
        return EventHubConfiguration(
            state: "enabled",
            telemetry: [
                "test_pixel": TelemetryPixelConfiguration(
                    state: "enabled",
                    trigger: TriggerConfiguration(period: PeriodConfiguration(days: 1)),
                    parameters: [
                        "count": ParameterConfiguration(
                            template: "counter",
                            source: "adwall",
                            buckets: buckets ?? defaultBuckets
                        )
                    ]
                )
            ]
        )
    }
}

// MARK: - Bucketing Tests

final class BucketTests: XCTestCase {

    private let buckets: [String: BucketConfiguration] = [
        "0": BucketConfiguration(gte: 0, lt: 1),
        "1-2": BucketConfiguration(gte: 1, lt: 3),
        "3-5": BucketConfiguration(gte: 3, lt: 6),
        "6-10": BucketConfiguration(gte: 6, lt: 11),
        "40+": BucketConfiguration(gte: 40),
    ]

    func testBucketCountMatching() {
        XCTAssertEqual(bucketCount(value: 0, buckets: buckets), "0")
        XCTAssertEqual(bucketCount(value: 1, buckets: buckets), "1-2")
        XCTAssertEqual(bucketCount(value: 2, buckets: buckets), "1-2")
        XCTAssertEqual(bucketCount(value: 3, buckets: buckets), "3-5")
        XCTAssertEqual(bucketCount(value: 5, buckets: buckets), "3-5")
        XCTAssertEqual(bucketCount(value: 6, buckets: buckets), "6-10")
        XCTAssertEqual(bucketCount(value: 10, buckets: buckets), "6-10")
        XCTAssertEqual(bucketCount(value: 40, buckets: buckets), "40+")
        XCTAssertEqual(bucketCount(value: 100, buckets: buckets), "40+")
    }

    func testBucketCountNoMatch() {
        XCTAssertNil(bucketCount(value: 15, buckets: buckets))
    }

    func testShouldStopCounting() {
        XCTAssertFalse(shouldStopCounting(value: 0, buckets: buckets))
        XCTAssertFalse(shouldStopCounting(value: 5, buckets: buckets))
        XCTAssertFalse(shouldStopCounting(value: 39, buckets: buckets))
        XCTAssertTrue(shouldStopCounting(value: 40, buckets: buckets))
        XCTAssertTrue(shouldStopCounting(value: 100, buckets: buckets))
    }
}

// MARK: - DedupSet Tests

final class DedupSetTests: XCTestCase {

    func testWhenFirstEventThenNotDuplicate() {
        let dedup = DedupSet()
        XCTAssertFalse(dedup.isDuplicate(pixelName: "p", paramName: "c", source: "s", tabId: "t1"))
    }

    func testWhenSecondEventThenDuplicate() {
        let dedup = DedupSet()
        _ = dedup.isDuplicate(pixelName: "p", paramName: "c", source: "s", tabId: "t1")
        XCTAssertTrue(dedup.isDuplicate(pixelName: "p", paramName: "c", source: "s", tabId: "t1"))
    }

    func testWhenDifferentTabThenNotDuplicate() {
        let dedup = DedupSet()
        _ = dedup.isDuplicate(pixelName: "p", paramName: "c", source: "s", tabId: "t1")
        XCTAssertFalse(dedup.isDuplicate(pixelName: "p", paramName: "c", source: "s", tabId: "t2"))
    }

    func testWhenTabClearedThenNotDuplicate() {
        let dedup = DedupSet()
        _ = dedup.isDuplicate(pixelName: "p", paramName: "c", source: "s", tabId: "t1")
        dedup.removeAll(forTabId: "t1")
        XCTAssertFalse(dedup.isDuplicate(pixelName: "p", paramName: "c", source: "s", tabId: "t1"))
    }

    func testWhenTabIdIsNilThenAlwaysNotDuplicate() {
        let dedup = DedupSet()
        XCTAssertFalse(dedup.isDuplicate(pixelName: "p", paramName: "c", source: "s", tabId: nil))
        XCTAssertFalse(dedup.isDuplicate(pixelName: "p", paramName: "c", source: "s", tabId: nil))
    }
}

// MARK: - Configuration Parsing Tests

final class EventHubConfigurationTests: XCTestCase {

    func testWhenValidJSONThenConfigIsParsed() {
        let settings: [String: Any] = [
            "state": "enabled",
            "telemetry": [
                "webTelemetry_adwallDetection_day": [
                    "state": "enabled",
                    "trigger": [
                        "period": ["days": 1]
                    ],
                    "parameters": [
                        "count": [
                            "template": "counter",
                            "source": "adwall",
                            "buckets": [
                                "0": ["gte": 0, "lt": 1],
                                "1-2": ["gte": 1, "lt": 3],
                            ]
                        ]
                    ]
                ] as [String: Any]
            ] as [String: Any]
        ]

        let config = EventHubConfiguration(settings: settings)
        XCTAssertNotNil(config)
        XCTAssertTrue(config!.isEnabled)
        XCTAssertEqual(config!.telemetry.count, 1)

        let pixel = config!.telemetry["webTelemetry_adwallDetection_day"]
        XCTAssertNotNil(pixel)
        XCTAssertTrue(pixel!.isEnabled)
        XCTAssertEqual(pixel!.trigger.period.days, 1)
        XCTAssertEqual(pixel!.parameters["count"]?.template, "counter")
        XCTAssertEqual(pixel!.parameters["count"]?.source, "adwall")
        XCTAssertEqual(pixel!.parameters["count"]?.buckets.count, 2)
    }

    func testWhenMissingStateThenConfigIsNil() {
        let settings: [String: Any] = ["telemetry": [:]]
        XCTAssertNil(EventHubConfiguration(settings: settings))
    }

    func testWhenPeriodIsZeroThenConfigIsNil() {
        let period = PeriodConfiguration(json: ["seconds": 0])
        XCTAssertNil(period)
    }
}

// MARK: - Attribution Period Tests

final class AttributionPeriodTests: XCTestCase {

    func testDailyPeriodAlignment() {
        let startMillis: Int64 = 1_740_052_860_000 // slightly past midnight
        let period = PeriodConfiguration(days: 1)
        let result = attributionPeriod(periodStartMillis: startMillis, period: period)
        XCTAssertEqual(result, "1740009600") // 2025-02-20T00:00:00Z
    }

    func testHourlyPeriodAlignment() {
        let startMillis: Int64 = 1_740_058_500_000 // 17:15 UTC
        let period = PeriodConfiguration(hours: 1)
        let result = attributionPeriod(periodStartMillis: startMillis, period: period)
        XCTAssertEqual(result, "1740056400") // 17:00 UTC
    }
}

// MARK: - Mock Types

final class MockEventHubStorage: EventHubStoring {
    private var states: [String: PersistedPixelState] = [:]

    func loadPixelState(for pixelName: String) -> PersistedPixelState? {
        states[pixelName]
    }

    func savePixelState(_ state: PersistedPixelState) {
        states[state.pixelName] = state
    }

    func deletePixelState(for pixelName: String) {
        states.removeValue(forKey: pixelName)
    }

    func allPixelStates() -> [PersistedPixelState] {
        Array(states.values)
    }

    func deleteAllPixelStates() {
        states.removeAll()
    }
}

final class MockPixelFiring: EventHubPixelFiring {
    struct FiredPixel {
        let name: String
        let parameters: [String: String]
    }

    var firedPixels: [FiredPixel] = []

    func firePixel(named pixelName: String, parameters: [String: String]) {
        firedPixels.append(FiredPixel(name: pixelName, parameters: parameters))
    }
}

final class MockAppStateProvider: EventHubAppStateProviding {
    var isAppInForeground: Bool = true
}

final class MockTimerFactory: EventHubTimerFactory {
    var timersCreated: [MockTimer] = []

    func makeTimer(delay: TimeInterval, handler: @escaping () -> Void) -> EventHubTimer {
        let timer = MockTimer(delay: delay, handler: handler)
        timersCreated.append(timer)
        return timer
    }
}

final class MockTimer: EventHubTimer {
    let delay: TimeInterval
    private let handler: () -> Void
    private(set) var isCancelled = false

    init(delay: TimeInterval, handler: @escaping () -> Void) {
        self.delay = delay
        self.handler = handler
    }

    func cancel() {
        isCancelled = true
    }

    func fire() {
        guard !isCancelled else { return }
        handler()
    }
}
