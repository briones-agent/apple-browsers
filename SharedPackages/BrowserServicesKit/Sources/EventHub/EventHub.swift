//
//  EventHub.swift
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
import os.log

public protocol EventHubAppStateProviding {
    var isAppInForeground: Bool { get }
}

public final class EventHub {

    private let storage: EventHubStoring
    private let pixelFiring: EventHubPixelFiring
    private let appStateProvider: EventHubAppStateProviding
    private let dateProvider: () -> Date
    private let timerFactory: EventHubTimerFactory

    private var config: EventHubConfiguration?
    private var timers: [String: EventHubTimer] = [:]
    private var telemetry: [String: TelemetryInstance] = [:]

    private let dedupSeen = DedupSet()
    private var tabCurrentURL: [String: String] = [:]

    private let lock = NSLock()

    public init(storage: EventHubStoring,
                pixelFiring: EventHubPixelFiring,
                appStateProvider: EventHubAppStateProviding,
                dateProvider: @escaping () -> Date = { Date() },
                timerFactory: EventHubTimerFactory = DefaultEventHubTimerFactory()) {
        self.storage = storage
        self.pixelFiring = pixelFiring
        self.appStateProvider = appStateProvider
        self.dateProvider = dateProvider
        self.timerFactory = timerFactory
    }

    // MARK: - Configuration

    public func onConfigChanged(_ newConfig: EventHubConfiguration?) {
        lock.lock()
        defer { lock.unlock() }

        config = newConfig

        guard let config, config.isEnabled else {
            onDisable()
            return
        }

        for name in config.telemetry.keys {
            if telemetry[name] == nil {
                registerTelemetry(name)
            }
        }
    }

    public var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return config?.isEnabled == true
    }

    // MARK: - Event Handling

    public func handleWebEvent(type: String, tabId: String?) {
        lock.lock()
        defer { lock.unlock() }

        guard config?.isEnabled == true else { return }
        guard !type.isEmpty else { return }

        for instance in telemetry.values {
            instance.handleEvent(type: type, tabId: tabId, dedupSeen: dedupSeen)
        }
    }

    public func onNavigationStarted(tabId: String, url: String) {
        lock.lock()
        defer { lock.unlock() }

        guard !tabId.isEmpty, !url.isEmpty else { return }

        let previousURL = tabCurrentURL[tabId]
        tabCurrentURL[tabId] = url

        if let previousURL, previousURL != url {
            dedupSeen.removeAll(forTabId: tabId)
        }
    }

    // MARK: - Foreground

    public func checkPixels() {
        lock.lock()
        defer { lock.unlock() }

        guard let config, config.isEnabled else { return }

        let allStates = storage.allPixelStates()
        let now = dateProvider()
        let nowMillis = Int64(now.timeIntervalSince1970 * 1000)

        for state in allStates {
            if nowMillis >= state.periodEndMillis {
                fireTelemetry(name: state.pixelName, persistedState: state)
            } else {
                let remainingSeconds = TimeInterval(state.periodEndMillis - nowMillis) / 1000.0
                scheduleFireTelemetry(name: state.pixelName, delay: remainingSeconds)
            }
        }

        for (name, pixelConfig) in config.telemetry where pixelConfig.isEnabled {
            if storage.loadPixelState(for: name) == nil && telemetry[name] == nil {
                registerTelemetry(name)
            }
        }
    }

    // MARK: - Private: Registration

    private func registerTelemetry(_ name: String) {
        guard let config, config.isEnabled else { return }
        guard let pixelConfig = config.telemetry[name] else { return }
        guard telemetry[name] == nil else { return }
        guard pixelConfig.isEnabled else { return }

        if let existingState = storage.loadPixelState(for: name) {
            let instance = TelemetryInstance(name: name, storage: storage, dateProvider: dateProvider)
            instance.restore(from: existingState)
            telemetry[name] = instance

            let now = dateProvider()
            let nowMillis = Int64(now.timeIntervalSince1970 * 1000)
            if nowMillis >= existingState.periodEndMillis {
                fireTelemetry(name: name, persistedState: existingState)
            } else {
                let remainingSeconds = TimeInterval(existingState.periodEndMillis - nowMillis) / 1000.0
                scheduleFireTelemetry(name: name, delay: remainingSeconds)
            }
        } else {
            let instance = TelemetryInstance(name: name, storage: storage, dateProvider: dateProvider)
            telemetry[name] = instance
            startNewPeriod(name: name, pixelConfig: pixelConfig)
        }
    }

    private func startNewPeriod(name: String, pixelConfig: TelemetryPixelConfiguration) {
        guard appStateProvider.isAppInForeground else { return }
        guard pixelConfig.isEnabled else { return }

        let now = dateProvider()
        let nowMillis = Int64(now.timeIntervalSince1970 * 1000)
        let periodEndMillis = nowMillis + Int64(pixelConfig.trigger.period.totalSeconds * 1000)

        var paramsState: [String: PersistedParameterState] = [:]
        for (paramName, _) in pixelConfig.parameters {
            paramsState[paramName] = PersistedParameterState()
        }

        let persistedState = PersistedPixelState(
            pixelName: name,
            periodStartMillis: nowMillis,
            periodEndMillis: periodEndMillis,
            paramsState: paramsState,
            configSnapshot: pixelConfig
        )
        storage.savePixelState(persistedState)

        let instance = telemetry[name] ?? TelemetryInstance(name: name, storage: storage, dateProvider: dateProvider)
        instance.restore(from: persistedState)
        telemetry[name] = instance

        let delay = pixelConfig.trigger.period.totalSeconds
        scheduleFireTelemetry(name: name, delay: delay)
    }

    // MARK: - Private: Firing

    private func scheduleFireTelemetry(name: String, delay: TimeInterval) {
        guard timers[name] == nil else { return }

        let timer = timerFactory.makeTimer(delay: delay) { [weak self] in
            self?.onTimerFired(name: name)
        }
        timers[name] = timer
    }

    private func onTimerFired(name: String) {
        lock.lock()
        defer { lock.unlock() }

        timers[name] = nil

        guard let persistedState = storage.loadPixelState(for: name) else { return }
        fireTelemetry(name: name, persistedState: persistedState)
    }

    private func fireTelemetry(name: String, persistedState: PersistedPixelState) {
        guard config?.isEnabled == true else { return }

        let pixelParams = buildPixelParams(from: persistedState)

        timers[name]?.cancel()
        timers[name] = nil

        storage.deletePixelState(for: name)
        telemetry[name] = nil

        if !pixelParams.isEmpty {
            var allParams = pixelParams
            allParams["attributionPeriod"] = attributionPeriod(
                periodStartMillis: persistedState.periodStartMillis,
                period: persistedState.configSnapshot.trigger.period
            )
            pixelFiring.firePixel(named: name, parameters: allParams)
        }

        if let latestConfig = config?.telemetry[name], latestConfig.isEnabled {
            startNewPeriod(name: name, pixelConfig: latestConfig)
        }
    }

    private func buildPixelParams(from state: PersistedPixelState) -> [String: String] {
        var params: [String: String] = [:]
        let config = state.configSnapshot

        for (paramName, paramConfig) in config.parameters {
            guard paramConfig.template == "counter" else { continue }
            guard let paramState = state.paramsState[paramName] else { continue }

            if let bucket = bucketCount(value: paramState.value, buckets: paramConfig.buckets) {
                params[paramName] = bucket
            }
        }
        return params
    }

    // MARK: - Private: Disable

    private func onDisable() {
        for (_, timer) in timers {
            timer.cancel()
        }
        timers.removeAll()

        for name in telemetry.keys {
            storage.deletePixelState(for: name)
        }
        telemetry.removeAll()
        storage.deleteAllPixelStates()
    }
}

// MARK: - Bucketing

func bucketCount(value: Int, buckets: [String: BucketConfiguration]) -> String? {
    for (name, bucket) in buckets {
        guard value >= bucket.gte else { continue }
        if let lt = bucket.lt, value >= lt { continue }
        return name
    }
    return nil
}

func shouldStopCounting(value: Int, buckets: [String: BucketConfiguration]) -> Bool {
    !buckets.values.contains { value < $0.gte }
}

func attributionPeriod(periodStartMillis: Int64, period: PeriodConfiguration) -> String {
    let periodSecs = period.totalSeconds
    guard periodSecs > 0 else { return String(periodStartMillis / 1000) }

    let epochSecs = Double(periodStartMillis) / 1000.0
    let aligned = floor(epochSecs / periodSecs) * periodSecs
    return String(Int64(aligned))
}
