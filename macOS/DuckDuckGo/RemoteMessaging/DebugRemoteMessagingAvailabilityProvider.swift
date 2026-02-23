//
//  DebugRemoteMessagingAvailabilityProvider.swift
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

import Combine
import Foundation
import RemoteMessaging

/// Wraps a RemoteMessagingAvailabilityProviding and allows forcing RMF on for debugging when the
/// privacy config has `remoteMessaging` disabled. Only for use in Debug builds / internal testing.
final class DebugRemoteMessagingAvailabilityProvider: RemoteMessagingAvailabilityProviding {

    static let overrideDidChangeNotification = Notification.Name("com.duckduckgo.macos.debug.remoteMessagingOverrideDidChange")

    private static let forceEnabledKey = "com.duckduckgo.macos.debug.remoteMessagingForceEnabled"

    private let base: RemoteMessagingAvailabilityProviding

    init(base: RemoteMessagingAvailabilityProviding) {
        self.base = base
    }

    var isRemoteMessagingAvailable: Bool {
        effectiveAvailability
    }

    var isRemoteMessagingAvailablePublisher: AnyPublisher<Bool, Never> {
        let overridePublisher = NotificationCenter.default.publisher(for: Self.overrideDidChangeNotification)
            .map { [weak self] _ in self?.effectiveAvailability ?? false }

        return base.isRemoteMessagingAvailablePublisher
            .map { [weak self] _ in self?.effectiveAvailability ?? false }
            .merge(with: overridePublisher)
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    private var effectiveAvailability: Bool {
        if let overrideEnabled = UserDefaults.standard.object(forKey: Self.forceEnabledKey) as? Bool {
            return overrideEnabled
        }
        return base.isRemoteMessagingAvailable
    }

    // MARK: - Debug menu

    static var isForceEnabled: Bool {
        get {
            (UserDefaults.standard.object(forKey: forceEnabledKey) as? Bool) ?? false
        }
        set {
            UserDefaults.standard.set(newValue, forKey: forceEnabledKey)
            NotificationCenter.default.post(name: overrideDidChangeNotification, object: nil)
        }
    }
}
