//
//  UseSubscriptionUserScript.swift
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

import Common
import UserScript
import WebKit

///
/// Isolated-world mirror of the page-world `useSubscription` feature.
///
/// The page-world handlers live under contextName `subscriptionPages` / featureName
/// `useSubscription` and are unreachable from the C-S-S message bridge (which operates
/// in the isolated world). This subfeature is registered in `contentScopeScriptsIsolated`
/// so bridged pages can call the same `useSubscription` methods.
///
/// Methods that require page-world UI (purchase flows, navigation, pixels) return nil;
/// only data-query handlers carry real implementations here.
///
public final class UseSubscriptionUserScript: NSObject, Subfeature {

    private let defaultOriginDomain = "duckduckgo.com"
    private let defaultAiOriginDomain = "duck.ai"

    public let featureName: String = "useSubscription"
    public var messageOriginPolicy: MessageOriginPolicy {
        var rules: [HostnameMatchingRule] = [.exact(hostname: defaultOriginDomain), .exact(hostname: defaultAiOriginDomain)]
        if let debugHost {
            rules.append(.exact(hostname: debugHost))
        }
        return .only(rules: rules)
    }
    weak public var broker: UserScriptMessageBroker?

    public func with(broker: UserScriptMessageBroker) {
        self.broker = broker
    }

    // swiftlint:disable:next cyclomatic_complexity
    public func handler(forMethodNamed methodName: String) -> Subfeature.Handler? {
        switch methodName {
        case "getSubscription": return getSubscription
        case "setSubscription": return noop
        case "getSubscriptionOptions": return getSubscriptionOptions
        case "setAuthTokens": return noop
        case "getAuthAccessToken": return getAuthAccessToken
        case "getFeatureConfig": return noop
        case "getSubscriptionTierOptions": return noop
        case "subscriptionSelected": return noop
        case "subscriptionChangeSelected": return noop
        case "activateSubscription": return noop
        case "featureSelected": return noop
        case "backToSettings": return noop
        case "getAccessToken": return getAccessToken
        case "backToSettingsActivateSuccess": return noop
        case "subscriptionsMonthlyPriceClicked": return noop
        case "subscriptionsYearlyPriceClicked": return noop
        case "subscriptionsUnknownPriceClicked": return noop
        case "subscriptionsAddEmailSuccess": return noop
        case "subscriptionsWelcomeAddEmailClicked": return noop
        case "subscriptionsWelcomeFaqClicked": return noop
        default:
            return nil
        }
    }

    private let subscriptionManager: any SubscriptionManager
    private let debugHost: String?

    public init(subscriptionManager: any SubscriptionManager,
                debugHost: String?) {
        self.subscriptionManager = subscriptionManager
        self.debugHost = debugHost
        super.init()
    }

    // MARK: - Data-query handlers

    func getSubscription(params: Any, original: WKScriptMessage) async throws -> Encodable? {
        let tokenContainer = try? await subscriptionManager.getTokenContainer(policy: .localValid)
        return ["token": tokenContainer?.accessToken ?? ""]
    }

    func getAuthAccessToken(params: Any, original: WKScriptMessage) async throws -> Encodable? {
        let tokenContainer = try? await subscriptionManager.getTokenContainer(policy: .localValid)
        return AccessTokenValue(accessToken: tokenContainer?.accessToken ?? "")
    }

    func getAccessToken(params: Any, original: WKScriptMessage) async throws -> Encodable? {
        let tokenContainer = try? await subscriptionManager.getTokenContainer(policy: .localValid)
        return ["token": tokenContainer?.accessToken ?? ""]
    }

    func getSubscriptionOptions(params: Any, original: WKScriptMessage) async throws -> Encodable? {
        nil
    }

    func noop(params: Any, original: WKScriptMessage) async throws -> Encodable? {
        nil
    }
}

private struct AccessTokenValue: Encodable {
    let accessToken: String
}
