//
//  PrivacyPassSubfeature.swift
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
import os.log
import UserScript
import WebKit

/// Subfeature that handles Privacy Pass ACT messages from content-scope-scripts.
///
/// When the JavaScript `privacyPass` feature calls methods like `issue`, `spend`,
/// `balance`, or `redeem`, this subfeature routes them to the `PrivacyPassTokenManaging`
/// implementation.
///
/// ## Usage
///
/// ```swift
/// let tokenManager = MockPrivacyPassTokenManager()
/// let privacyPassSubfeature = PrivacyPassSubfeature(tokenManager: tokenManager)
/// contentScopeUserScriptIsolated.registerSubfeature(delegate: privacyPassSubfeature)
/// ```
public final class PrivacyPassSubfeature: Subfeature {

    public static let featureNameValue = "privacyPass"

    public let messageOriginPolicy: MessageOriginPolicy = .all
    public let featureName: String = PrivacyPassSubfeature.featureNameValue
    public weak var broker: UserScriptMessageBroker?

    private let tokenManager: PrivacyPassTokenManaging

    public init(tokenManager: PrivacyPassTokenManaging) {
        self.tokenManager = tokenManager
    }

    public func with(broker: UserScriptMessageBroker) {
        self.broker = broker
    }

    enum MessageNames: String, CaseIterable {
        case issue
        case spend
        case balance
        case redeem
    }

    public func handler(forMethodNamed methodName: String) -> Subfeature.Handler? {
        switch MessageNames(rawValue: methodName) {
        case .issue:
            return { [weak self] params, original in
                try await self?.handleIssue(params: params, original: original)
            }
        case .spend:
            return { [weak self] params, original in
                try await self?.handleSpend(params: params, original: original)
            }
        case .balance:
            return { [weak self] params, original in
                try await self?.handleBalance(params: params, original: original)
            }
        case .redeem:
            return { [weak self] params, original in
                try await self?.handleRedeem(params: params, original: original)
            }
        default:
            return nil
        }
    }

    // MARK: - Handlers

    @MainActor
    private func handleIssue(params: Any, original: WKScriptMessage) async throws -> Encodable? {
        let dict = params as? [String: Any] ?? [:]
        let issuer = dict["issuer"] as? String ?? "unknown"
        let credits = dict["credits"] as? Int ?? 0
        Logger.privacyPass.debug("Handling issue request: issuer=\(issuer, privacy: .public), credits=\(credits, privacy: .public)")
        let credential = tokenManager.issueCredential(issuer: issuer, credits: credits)
        return credential
    }

    @MainActor
    private func handleSpend(params: Any, original: WKScriptMessage) async throws -> Encodable? {
        let dict = params as? [String: Any] ?? [:]
        guard let credentialId = dict["credentialId"] as? String else {
            throw PrivacyPassError.credentialNotFound
        }
        let amount = dict["amount"] as? Int ?? 1
        Logger.privacyPass.debug("Handling spend request: credentialId=\(credentialId, privacy: .public), amount=\(amount, privacy: .public)")
        let result = try tokenManager.spendCredits(credentialId: credentialId, amount: amount)
        return result
    }

    @MainActor
    private func handleBalance(params: Any, original: WKScriptMessage) async throws -> Encodable? {
        let dict = params as? [String: Any] ?? [:]
        guard let credentialId = dict["credentialId"] as? String else {
            throw PrivacyPassError.credentialNotFound
        }
        Logger.privacyPass.debug("Handling balance request: credentialId=\(credentialId, privacy: .public)")
        let credits = tokenManager.balance(credentialId: credentialId)
        return ["credits": credits]
    }

    @MainActor
    private func handleRedeem(params: Any, original: WKScriptMessage) async throws -> Encodable? {
        let dict = params as? [String: Any] ?? [:]
        guard let token = dict["token"] as? String else {
            return ["success": false]
        }
        Logger.privacyPass.debug("Handling redeem request")
        let success = tokenManager.redeemToken(token)
        return ["success": success]
    }
}
