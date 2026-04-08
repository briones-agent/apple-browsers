//
//  WebTelemetrySubfeature.swift
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

import Foundation
import UserScript
import WebKit

/// Protocol for handling web telemetry events from content-scope-scripts.
///
/// The `video-playback` notification includes `userInteraction` (Bool) which
/// indicates `navigator.userActivation.isActive` at the time the video's
/// `play` event fired. This can be used to distinguish user-initiated playback
/// from autoplay.
public protocol WebTelemetrySubfeatureDelegate: AnyObject {
    /// Called when a video play event is detected on the page.
    ///
    /// - Parameter userInteraction: Whether the user activation state was active
    ///   when the video started playing (`navigator.userActivation.isActive`).
    @MainActor
    func webTelemetryDidDetectVideoPlayback(userInteraction: Bool)
}

/// Subfeature that handles web telemetry notifications from content-scope-scripts.
///
/// Receives `video-playback` notifications containing user activation state,
/// useful for determining whether video playback was user-initiated or autoplay.
///
/// ## Usage
///
/// 1. Create an instance of `WebTelemetrySubfeature`
/// 2. Set its `delegate` to receive telemetry events
/// 3. Register it with the `ContentScopeUserScript`:
///
/// ```swift
/// let webTelemetrySubfeature = WebTelemetrySubfeature()
/// webTelemetrySubfeature.delegate = self
/// contentScopeUserScript.registerSubfeature(delegate: webTelemetrySubfeature)
/// ```
///
/// 4. Add `WebTelemetrySubfeature.featureNameValue` to `allowedNonisolatedFeatures`
///    when creating the `ContentScopeUserScript`.
public final class WebTelemetrySubfeature: NSObject, Subfeature {

    public static let featureNameValue = "webTelemetry"

    public let messageOriginPolicy: MessageOriginPolicy = .all

    public let featureName: String = WebTelemetrySubfeature.featureNameValue

    public weak var broker: UserScriptMessageBroker?

    public weak var delegate: WebTelemetrySubfeatureDelegate?

    public override init() {
        super.init()
    }

    public func with(broker: UserScriptMessageBroker) {
        self.broker = broker
    }

    enum MessageNames: String, CaseIterable {
        case videoPlayback = "video-playback"
    }

    public func handler(forMethodNamed methodName: String) -> Subfeature.Handler? {
        switch MessageNames(rawValue: methodName) {
        case .videoPlayback:
            return { [weak self] in try await self?.handleVideoPlayback(params: $0, original: $1) }
        default:
            return nil
        }
    }

    @MainActor
    private func handleVideoPlayback(params: Any, original: WKScriptMessage) async throws -> Encodable? {
        guard let dict = params as? [String: Any] else { return nil }
        let userInteraction = dict["userInteraction"] as? Bool ?? false
        delegate?.webTelemetryDidDetectVideoPlayback(userInteraction: userInteraction)
        return nil
    }
}
