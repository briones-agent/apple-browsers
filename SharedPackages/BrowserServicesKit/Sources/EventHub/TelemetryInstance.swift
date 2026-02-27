//
//  TelemetryInstance.swift
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

final class TelemetryInstance {

    let name: String
    private let storage: EventHubStoring
    private let dateProvider: () -> Date

    private(set) var periodStartMillis: Int64?
    private(set) var periodEndMillis: Int64?
    private(set) var paramsState: [String: PersistedParameterState] = [:]
    private var configSnapshot: TelemetryPixelConfiguration?

    init(name: String,
         storage: EventHubStoring,
         dateProvider: @escaping () -> Date) {
        self.name = name
        self.storage = storage
        self.dateProvider = dateProvider
    }

    func restore(from state: PersistedPixelState) {
        periodStartMillis = state.periodStartMillis
        periodEndMillis = state.periodEndMillis
        paramsState = state.paramsState
        configSnapshot = state.configSnapshot
    }

    func handleEvent(type: String, tabId: String?, dedupSeen: DedupSet) {
        guard let periodStartMillis, let periodEndMillis, let configSnapshot else { return }

        let nowMillis = Int64(dateProvider().timeIntervalSince1970 * 1000)
        guard nowMillis <= periodEndMillis else { return }

        for (paramName, paramConfig) in configSnapshot.parameters {
            guard paramConfig.template == "counter", paramConfig.source == type else { continue }

            guard var paramState = paramsState[paramName] else { continue }
            guard !paramState.stopCounting else { continue }

            if dedupSeen.isDuplicate(pixelName: name, paramName: paramName, source: type, tabId: tabId) {
                continue
            }

            if shouldStopCounting(value: paramState.value, buckets: paramConfig.buckets) {
                paramState.stopCounting = true
                paramsState[paramName] = paramState
                persist()
                continue
            }

            paramState.value += 1
            paramsState[paramName] = paramState
            persist()
        }
    }

    private func persist() {
        guard let periodStartMillis, let periodEndMillis, let configSnapshot else { return }

        let state = PersistedPixelState(
            pixelName: name,
            periodStartMillis: periodStartMillis,
            periodEndMillis: periodEndMillis,
            paramsState: paramsState,
            configSnapshot: configSnapshot
        )
        storage.savePixelState(state)
    }
}
