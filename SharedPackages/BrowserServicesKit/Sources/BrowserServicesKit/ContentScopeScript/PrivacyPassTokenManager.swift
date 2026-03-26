//
//  PrivacyPassTokenManager.swift
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

// MARK: - Models

public struct PrivacyPassCredential: Encodable {
    public let id: String
    public let credits: Int

    public init(id: String, credits: Int) {
        self.id = id
        self.credits = credits
    }
}

public struct PrivacyPassSpendResult: Encodable {
    public let credentialId: String
    public let remainingCredits: Int
    public let token: String

    public init(credentialId: String, remainingCredits: Int, token: String) {
        self.credentialId = credentialId
        self.remainingCredits = remainingCredits
        self.token = token
    }
}

// MARK: - Protocol

public protocol PrivacyPassTokenManaging {
    func issueCredential(issuer: String, credits: Int) -> PrivacyPassCredential
    func spendCredits(credentialId: String, amount: Int) throws -> PrivacyPassSpendResult
    func balance(credentialId: String) -> Int?
    func redeemToken(_ token: String) -> Bool
}

// MARK: - Errors

public enum PrivacyPassError: LocalizedError {
    case credentialNotFound
    case insufficientCredits

    public var errorDescription: String? {
        switch self {
        case .credentialNotFound:
            return "Credential not found"
        case .insufficientCredits:
            return "Insufficient credits"
        }
    }
}

// MARK: - Mock Implementation

public final class MockPrivacyPassTokenManager: PrivacyPassTokenManaging {

    private var credentialStore: [String: Int] = [:]
    private var issuedTokens: Set<String> = []
    private let lock = NSLock()

    public init() {}

    public func issueCredential(issuer: String, credits: Int) -> PrivacyPassCredential {
        let credentialId = UUID().uuidString
        lock.lock()
        credentialStore[credentialId] = credits
        lock.unlock()
        Logger.privacyPass.debug("Issued credential \(credentialId, privacy: .public) with \(credits, privacy: .public) credits for issuer \(issuer)")
        return PrivacyPassCredential(id: credentialId, credits: credits)
    }

    public func spendCredits(credentialId: String, amount: Int) throws -> PrivacyPassSpendResult {
        lock.lock()
        defer { lock.unlock() }

        guard let currentCredits = credentialStore[credentialId] else {
            throw PrivacyPassError.credentialNotFound
        }
        guard currentCredits >= amount else {
            throw PrivacyPassError.insufficientCredits
        }

        let remaining = currentCredits - amount
        credentialStore[credentialId] = remaining

        let token = UUID().uuidString
        issuedTokens.insert(token)
        Logger.privacyPass.debug("Spent \(amount, privacy: .public) credits from \(credentialId, privacy: .public), remaining: \(remaining, privacy: .public)")
        return PrivacyPassSpendResult(credentialId: credentialId, remainingCredits: remaining, token: token)
    }

    public func balance(credentialId: String) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return credentialStore[credentialId]
    }

    public func redeemToken(_ token: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let removed = issuedTokens.remove(token)
        Logger.privacyPass.debug("Redeem token result: \(removed != nil, privacy: .public)")
        return removed != nil
    }
}

// MARK: - Logger

public extension Logger {
    static let privacyPass = Logger(subsystem: "BrowserServicesKit", category: "PrivacyPass")
}
