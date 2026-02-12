//
//  DataClearingPixelsReporter.swift
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

import Foundation
import PixelKit
import QuartzCore

final class DataClearingPixelsReporter {

    var timeProvider: () -> CFTimeInterval
    private let pixelFiring: PixelFiring?

    @MainActor
    private var lastFireTime: CFTimeInterval?
    private let retriggerWindow: TimeInterval = 20.0

    // MARK: - Initialization

    init(pixelFiring: PixelFiring? = PixelKit.shared,
         timeProvider: @escaping () -> CFTimeInterval = { CACurrentMediaTime() }) {
        self.pixelFiring = pixelFiring
        self.timeProvider = timeProvider
    }

    // MARK: - Overall Flow Metrics

    func fireClearingCompletionPixel(from startTime: CFTimeInterval,
                                     request: FireRequest) {
        pixelFiring?.fire(
            DataClearingPixels.clearingCompletion(
                duration: elapsedMilliseconds(since: startTime, to: timeProvider()),
                option: request.options.description,
                trigger: request.trigger.description,
                scope: request.scope.description,
                source: request.source.rawValue
            ),
            frequency: .standard
        )
    }

    @MainActor
    func fireRetriggerPixelIfNeeded(request: FireRequest) {
        guard request.trigger == .manualFire else { return }
        let now = timeProvider()
        if let lastFireTime, (now - lastFireTime) <= retriggerWindow {
            pixelFiring?.fire(DataClearingPixels.retriggerIn20s, frequency: .dailyAndStandard)
        }
        lastFireTime = now
    }

    func fireUserActionBeforeCompletionPixel() {
        pixelFiring?.fire(DataClearingPixels.userActionBeforeCompletion, frequency: .standard)
    }

    // MARK: - Per-Action Quality Metrics

    func fireDurationPixel(_ durationPixel: @escaping (Int) -> DataClearingPixels,
                           startTime: CFTimeInterval) {
        pixelFiring?.fire(
            durationPixel(elapsedMilliseconds(since: startTime, to: timeProvider())),
            frequency: .standard
        )
    }
    
    func fireDurationPixel(_ durationPixel: @escaping (Int, String) -> DataClearingPixels,
                           startTime: CFTimeInterval,
                           scope: String) {
        pixelFiring?.fire(
            durationPixel(elapsedMilliseconds(since: startTime, to: timeProvider()), scope),
            frequency: .standard
        )
    }

    func fireErrorPixel(_ errorPixel: DataClearingPixels) {
        pixelFiring?.fire(errorPixel, frequency: .dailyAndStandard)
    }
}

// MARK: - Private Helpers

private extension DataClearingPixelsReporter {

    private func elapsedMilliseconds(since startTime: CFTimeInterval, to endTime: CFTimeInterval) -> Int {
        Int((endTime - startTime) * 1000)
    }
}
