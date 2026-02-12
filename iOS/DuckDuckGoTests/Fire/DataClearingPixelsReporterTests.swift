//
//  DataClearingPixelsReporterTests.swift
//  DuckDuckGo
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

import PixelKit
import PixelKitTestingUtilities
import XCTest

@testable import DuckDuckGo

final class DataClearingPixelsReporterTests: XCTestCase {
    
    private var mockPixelFiring: PixelKitMock!
    private var sut: DataClearingPixelsReporter!
    private var currentTime: CFTimeInterval!
    
    override func setUp() {
        super.setUp()
        mockPixelFiring = PixelKitMock()
        currentTime = CACurrentMediaTime()
        sut = DataClearingPixelsReporter(
            pixelFiring: mockPixelFiring,
            timeProvider: { [weak self] in self?.currentTime ?? CACurrentMediaTime() }
        )
    }
    
    override func tearDown() {
        mockPixelFiring = nil
        sut = nil
        currentTime = nil
        super.tearDown()
    }
    
    // MARK: - fireClearingCompletionPixel Tests
    
    func testWhenFireClearingCompletionPixelCalledThenPixelIsFiredWithCorrectParameters() {
        // Given
        let startTime = currentTime!
        currentTime += 2.5 // 2.5 seconds = 2500ms
        
        // When
        sut.fireClearingCompletionPixel(
            from: startTime, request: FireRequest(options: .all, trigger: .manualFire, scope: .all, source: .settings)
        )
        
        // Then
        XCTAssertEqual(mockPixelFiring.actualFireCalls.count, 1)
        XCTAssertEqual(mockPixelFiring.actualFireCalls.first?.frequency, .standard)
        
        if case .clearingCompletion(let duration, let option, let trigger, let scope, let source) =
            mockPixelFiring.actualFireCalls.first?.pixel as? DataClearingPixels {
            XCTAssertEqual(duration, 2500)
            XCTAssertEqual(option, "tabs,data,ai_chats")
            XCTAssertEqual(trigger, "manual_fire")
            XCTAssertEqual(scope, "all")
            XCTAssertEqual(source, "settings")
        } else {
            XCTFail("Expected clearingCompletion pixel")
        }
    }
    
    func testWhenFireClearingCompletionPixelWithAutoClearOnLaunchThenCorrectTriggerIsSent() {
        // Given
        let startTime = currentTime!
        currentTime += 1.0
        
        // When
        sut.fireClearingCompletionPixel(
            from: startTime,
            request: FireRequest(options: .data, trigger: .autoClearOnLaunch, scope: .all, source: .autoClear)
        )
        
        // Then
        if case .clearingCompletion(_, let option, let trigger, let scope, let source) =
            mockPixelFiring.actualFireCalls.first?.pixel as? DataClearingPixels {
            XCTAssertEqual(option, "data")
            XCTAssertEqual(trigger, "auto_clear_on_launch")
            XCTAssertEqual(scope, "all")
            XCTAssertEqual(source, "autoClear")
        } else {
            XCTFail("Expected clearingCompletion pixel")
        }
    }
    
    // MARK: - fireRetriggerPixelIfNeeded Tests
    
    @MainActor
    func testWhenFirstFireThenNoRetriggerPixelIsFired() {
        // When
        sut.fireRetriggerPixelIfNeeded(request: FireRequest(options: .all, trigger: .manualFire, scope: .all, source: .settings))
        
        // Then
        XCTAssertTrue(mockPixelFiring.actualFireCalls.isEmpty, "No pixel should fire on first call")
    }
    
    @MainActor
    func testWhenCalledTwiceWithin20SecondsThenRetriggerPixelIsFired() {
        let request = FireRequest(options: .all, trigger: .manualFire, scope: .all, source: .settings)
        // Given - first call sets lastFireTime
        sut.fireRetriggerPixelIfNeeded(request: request)
        
        // When - second call within 20 seconds
        currentTime += 10
        sut.fireRetriggerPixelIfNeeded(request: request)
        
        // Then
        mockPixelFiring.expectedFireCalls = [
            .init(pixel: DataClearingPixels.retriggerIn20s, frequency: .dailyAndStandard)
        ]
        mockPixelFiring.verifyExpectations(file: #file, line: #line)
    }
    
    @MainActor
    func testWhenCalledExactlyAt20SecondsThenRetriggerPixelIsFired() {
        let request = FireRequest(options: .all, trigger: .manualFire, scope: .all, source: .settings)
        // Given
        sut.fireRetriggerPixelIfNeeded(request: request)
        
        // When - exactly at 20 seconds (edge case, <= condition)
        currentTime += 20
        sut.fireRetriggerPixelIfNeeded(request: request)
        
        // Then
        mockPixelFiring.expectedFireCalls = [
            .init(pixel: DataClearingPixels.retriggerIn20s, frequency: .dailyAndStandard)
        ]
        mockPixelFiring.verifyExpectations(file: #file, line: #line)
    }
    
    @MainActor
    func testWhenCalledAfter20SecondsThenNoRetriggerPixelIsFired() {
        let request = FireRequest(options: .all, trigger: .manualFire, scope: .all, source: .settings)
        // Given
        sut.fireRetriggerPixelIfNeeded(request: request)
        
        // When - after 20 seconds
        currentTime += 21
        sut.fireRetriggerPixelIfNeeded(request: request)
        
        // Then
        XCTAssertTrue(mockPixelFiring.actualFireCalls.isEmpty, "No pixel should fire after window expires")
    }
    
    @MainActor
    func testWhenCalledMultipleTimesWithinWindowThenRetriggerPixelFiredEachTime() {
        let request = FireRequest(options: .all, trigger: .manualFire, scope: .all, source: .settings)
        // Given
        sut.fireRetriggerPixelIfNeeded(request: request)
        
        // When - multiple rapid calls within window
        currentTime += 5
        sut.fireRetriggerPixelIfNeeded(request: request)
        
        currentTime += 5
        sut.fireRetriggerPixelIfNeeded(request: request)
        
        currentTime += 5
        sut.fireRetriggerPixelIfNeeded(request: request)
        
        // Then
        mockPixelFiring.expectedFireCalls = [
            .init(pixel: DataClearingPixels.retriggerIn20s, frequency: .dailyAndStandard),
            .init(pixel: DataClearingPixels.retriggerIn20s, frequency: .dailyAndStandard),
            .init(pixel: DataClearingPixels.retriggerIn20s, frequency: .dailyAndStandard)
        ]
        mockPixelFiring.verifyExpectations(file: #file, line: #line)
    }
    
    // MARK: - fireErrorPixel Tests
    
    func testWhenFireErrorPixelCalledThenPixelIsFiredWithDailyAndCountFrequency() {
        // Given
        let testError = NSError(domain: "test", code: 123)
        
        // When
        sut.fireErrorPixel(DataClearingPixels.clearTabsError(testError))
        
        // Then
        mockPixelFiring.expectedFireCalls = [
            .init(pixel: DataClearingPixels.clearTabsError(testError), frequency: .dailyAndStandard)
        ]
        mockPixelFiring.verifyExpectations(file: #file, line: #line)
    }
    
    func testWhenFireWebsiteDataErrorPixelCalledThenPixelIsFired() {
        // Given
        let testError = NSError(domain: "WebKit", code: 500)
        
        // When
        sut.fireErrorPixel(DataClearingPixels.clearHistoryError(testError))
        
        // Then
        XCTAssertEqual(mockPixelFiring.actualFireCalls.count, 1)
        XCTAssertEqual(mockPixelFiring.actualFireCalls.first?.frequency, .dailyAndStandard)
        
        if case .clearHistoryError(let error) =
            mockPixelFiring.actualFireCalls.first?.pixel as? DataClearingPixels {
            XCTAssertEqual((error as NSError).domain, testError.domain)
            XCTAssertEqual((error as NSError).code, testError.code)
        } else {
            XCTFail("Expected burnHistoryError pixel")
        }
    }
    
    // MARK: - fireDurationPixel Tests
    
    func testWhenFireDurationPixelCalledThenPixelIsFiredWithCorrectDuration() {
        // Given
        let startTime = currentTime!
        currentTime += 1.5 // 1.5 seconds = 1500ms
        
        // When
        sut.fireDurationPixel(DataClearingPixels.clearTabsDuration, startTime: startTime, scope: "all")
        
        // Then
        XCTAssertEqual(mockPixelFiring.actualFireCalls.count, 1)
        XCTAssertEqual(mockPixelFiring.actualFireCalls.first?.frequency, .standard)
        
        if case .clearTabsDuration(let duration, _) =
            mockPixelFiring.actualFireCalls.first?.pixel as? DataClearingPixels {
            XCTAssertEqual(duration, 1500)
        } else {
            XCTFail("Expected burnTabsDuration pixel")
        }
    }
    
    func testWhenFireURLCacheDurationPixelCalledThenPixelIsFired() {
        // Given
        let startTime = currentTime!
        currentTime += 0.25 // 250ms
        
        // When
        sut.fireDurationPixel(DataClearingPixels.clearURLCacheDuration, startTime: startTime)
        
        // Then
        if case .clearURLCacheDuration(let duration) =
            mockPixelFiring.actualFireCalls.first?.pixel as? DataClearingPixels {
            XCTAssertEqual(duration, 250)
        } else {
            XCTFail("Expected burnURLCacheDuration pixel")
        }
    }
    
    // MARK: - Duration Calculation Tests
    
    func testWhenDurationIsSubMillisecondThenZeroIsReported() {
        // Given
        let startTime = currentTime!
        currentTime += 0.0001 // 0.1ms rounds to 0
        
        // When
        sut.fireDurationPixel(DataClearingPixels.clearTabsDuration, startTime: startTime, scope: "tab")
        
        // Then
        if case .clearTabsDuration(let duration, _) =
            mockPixelFiring.actualFireCalls.first?.pixel as? DataClearingPixels {
            XCTAssertEqual(duration, 0)
        } else {
            XCTFail("Expected burnTabsDuration pixel")
        }
    }
    
    func testWhenDurationIsLargeThenCorrectMillisecondsAreReported() {
        // Given
        let startTime = currentTime!
        currentTime += 30.0 // 30 seconds = 30000ms
        
        // When
        sut.fireDurationPixel(DataClearingPixels.clearHistoryDuration, startTime: startTime, scope: "all")
        
        // Then
        if case .clearHistoryDuration(let duration, _) =
            mockPixelFiring.actualFireCalls.first?.pixel as? DataClearingPixels {
            XCTAssertEqual(duration, 30000)
        } else {
            XCTFail("Expected burnHistoryDuration pixel")
        }
    }
    
    // MARK: - Nil PixelFiring Tests
    
    @MainActor
    func testWhenPixelFiringIsNilThenNoPixelIsFiredAndNoCrash() {
        // Given
        sut = DataClearingPixelsReporter(pixelFiring: nil)
        
        // When - should not crash
        sut.fireRetriggerPixelIfNeeded(request: FireRequest(options: .all, trigger: .manualFire, scope: .all, source: .settings))
        
        // Then - no crash occurred
    }
}
