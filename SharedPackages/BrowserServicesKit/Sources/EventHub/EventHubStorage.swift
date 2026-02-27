//
//  EventHubStorage.swift
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

public struct PersistedPixelState: Codable, Equatable {
    public let pixelName: String
    public let periodStartMillis: Int64
    public let periodEndMillis: Int64
    public var paramsState: [String: PersistedParameterState]
    public let configSnapshot: TelemetryPixelConfiguration

    public init(pixelName: String,
                periodStartMillis: Int64,
                periodEndMillis: Int64,
                paramsState: [String: PersistedParameterState],
                configSnapshot: TelemetryPixelConfiguration) {
        self.pixelName = pixelName
        self.periodStartMillis = periodStartMillis
        self.periodEndMillis = periodEndMillis
        self.paramsState = paramsState
        self.configSnapshot = configSnapshot
    }
}

public struct PersistedParameterState: Codable, Equatable {
    public var value: Int
    public var stopCounting: Bool

    public init(value: Int = 0, stopCounting: Bool = false) {
        self.value = value
        self.stopCounting = stopCounting
    }
}

public protocol EventHubStoring {
    func loadPixelState(for pixelName: String) -> PersistedPixelState?
    func savePixelState(_ state: PersistedPixelState)
    func deletePixelState(for pixelName: String)
    func allPixelStates() -> [PersistedPixelState]
    func deleteAllPixelStates()
}

public final class EventHubUserDefaultsStorage: EventHubStoring {

    private static let stateIndexKey = "com.duckduckgo.eventHub.pixelStateIndex"
    private static let stateKeyPrefix = "com.duckduckgo.eventHub.pixelState."

    private let userDefaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    public func loadPixelState(for pixelName: String) -> PersistedPixelState? {
        guard let data = userDefaults.data(forKey: stateKey(for: pixelName)) else { return nil }
        do {
            return try decoder.decode(PersistedPixelState.self, from: data)
        } catch {
            Logger.general.error("EventHub: failed to decode pixel state for \(pixelName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    public func savePixelState(_ state: PersistedPixelState) {
        do {
            let data = try encoder.encode(state)
            userDefaults.set(data, forKey: stateKey(for: state.pixelName))
            addToIndex(state.pixelName)
        } catch {
            Logger.general.error("EventHub: failed to encode pixel state for \(state.pixelName, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    public func deletePixelState(for pixelName: String) {
        userDefaults.removeObject(forKey: stateKey(for: pixelName))
        removeFromIndex(pixelName)
    }

    public func allPixelStates() -> [PersistedPixelState] {
        let index = pixelNameIndex()
        return index.compactMap { loadPixelState(for: $0) }
    }

    public func deleteAllPixelStates() {
        let index = pixelNameIndex()
        for name in index {
            userDefaults.removeObject(forKey: stateKey(for: name))
        }
        userDefaults.removeObject(forKey: Self.stateIndexKey)
    }

    private func stateKey(for pixelName: String) -> String {
        Self.stateKeyPrefix + pixelName
    }

    private func pixelNameIndex() -> Set<String> {
        Set(userDefaults.stringArray(forKey: Self.stateIndexKey) ?? [])
    }

    private func addToIndex(_ pixelName: String) {
        var index = pixelNameIndex()
        index.insert(pixelName)
        userDefaults.set(Array(index), forKey: Self.stateIndexKey)
    }

    private func removeFromIndex(_ pixelName: String) {
        var index = pixelNameIndex()
        index.remove(pixelName)
        userDefaults.set(Array(index), forKey: Self.stateIndexKey)
    }
}
