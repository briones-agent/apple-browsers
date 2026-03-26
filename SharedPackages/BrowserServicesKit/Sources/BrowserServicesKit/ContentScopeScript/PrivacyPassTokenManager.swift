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

// MARK: - Errors

public enum PrivacyPassError: LocalizedError {
    case noCredentialForIssuer(String)
    case issuerURLInvalid(String)
    case issuanceRequestFailed(String)
    case spendRequestFailed(String)
    case publicKeyFetchFailed(String)
    case invalidServerResponse
    case insufficientCredits
    case challengeParsingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noCredentialForIssuer(let issuer):
            return "No credential for issuer: \(issuer)"
        case .issuerURLInvalid(let url):
            return "Invalid issuer URL: \(url)"
        case .issuanceRequestFailed(let detail):
            return "Issuance request failed: \(detail)"
        case .spendRequestFailed(let detail):
            return "Spend request failed: \(detail)"
        case .publicKeyFetchFailed(let detail):
            return "Public key fetch failed: \(detail)"
        case .invalidServerResponse:
            return "Invalid server response"
        case .insufficientCredits:
            return "Insufficient credits"
        case .challengeParsingFailed(let detail):
            return "Challenge parsing failed: \(detail)"
        }
    }
}

// MARK: - Protocol

/// Manages ACT (Anonymous Credit Token) credentials for Privacy Pass.
///
/// The full protocol flow:
/// 1. **Issuance**: `act_pre_issuance_new` → `act_issuance_request` → HTTP POST `/token-request` → `act_complete_issuance`
/// 2. **Spending**: `act_spend` → HTTP POST `/token-spend` → `act_complete_refund`
///
/// This prototype uses pure HTTP orchestration; the Rust FFI (`act-core`) handles
/// crypto validation in the test server.
public protocol PrivacyPassTokenManaging: AnyObject {
    func hasCredential(for issuerOrigin: String) -> Bool
    func issueCredential(for issuerOrigin: String) async throws
    func spend(for issuerOrigin: String) async throws -> String
}

// MARK: - Implementation

public final class PrivacyPassTokenManager: PrivacyPassTokenManaging {

    /// Stored credential data per issuer origin (in-memory for prototype).
    private var credentials: [String: Data] = [:]
    private let lock = NSLock()
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func hasCredential(for issuerOrigin: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return credentials[issuerOrigin] != nil
    }

    /// Runs the full ACT issuance flow against the issuer.
    ///
    /// 1. Fetches the issuer's public key from `/public-key`
    /// 2. POSTs an issuance request to `/token-request`
    /// 3. Stores the resulting CreditToken (CBOR blob) keyed by issuer origin
    ///
    /// In production these steps would interleave with Rust FFI calls:
    /// `act_pre_issuance_new`, `act_issuance_request`, `act_complete_issuance`.
    public func issueCredential(for issuerOrigin: String) async throws {
        guard let issuerBaseURL = URL(string: issuerOrigin) else {
            throw PrivacyPassError.issuerURLInvalid(issuerOrigin)
        }

        let publicKeyCBOR = try await fetchPublicKey(from: issuerBaseURL)
        Logger.privacyPass.debug("Fetched public key from \(issuerOrigin, privacy: .public)")

        // In production: act_pre_issuance_new() → act_issuance_request(pre, params)
        let issuancePayload = try JSONSerialization.data(withJSONObject: ["cbor": publicKeyCBOR])

        let tokenRequestURL = issuerBaseURL.appendingPathComponent("token-request")
        var request = URLRequest(url: tokenRequestURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = issuancePayload

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw PrivacyPassError.issuanceRequestFailed("HTTP \(statusCode)")
        }

        // In production: act_complete_issuance(pre, params, pk, requestCBOR, responseCBOR)
        lock.lock()
        credentials[issuerOrigin] = data
        lock.unlock()

        Logger.privacyPass.debug("Stored credential for \(issuerOrigin, privacy: .public)")
    }

    /// Spends 1 credit from the stored credential for the given issuer.
    ///
    /// 1. POSTs the spend proof to `/token-spend`
    /// 2. Receives a refund response and updates the stored credential
    /// 3. Returns the base64-encoded spend proof for the `Authorization` header
    ///
    /// In production these steps would use:
    /// `act_spend`, then `act_complete_refund` with the server's refund response.
    public func spend(for issuerOrigin: String) async throws -> String {
        guard let issuerBaseURL = URL(string: issuerOrigin) else {
            throw PrivacyPassError.issuerURLInvalid(issuerOrigin)
        }

        lock.lock()
        guard let credentialData = credentials[issuerOrigin] else {
            lock.unlock()
            throw PrivacyPassError.noCredentialForIssuer(issuerOrigin)
        }
        lock.unlock()

        // In production: act_spend(token, params, charge=1) → SpendProof + PreRefund
        let spendPayload = try JSONSerialization.data(
            withJSONObject: ["cbor": credentialData.base64EncodedString()])

        let tokenSpendURL = issuerBaseURL.appendingPathComponent("token-spend")
        var request = URLRequest(url: tokenSpendURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = spendPayload

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw PrivacyPassError.spendRequestFailed("HTTP \(statusCode)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let spendProofBase64 = json["spend_proof"] as? String else {
            throw PrivacyPassError.invalidServerResponse
        }

        // In production: act_complete_refund(preRefund, params, spendProofCBOR, refundCBOR, pk)
        if let refundCBOR = json["refund_cbor"] as? String,
           let refundData = Data(base64Encoded: refundCBOR) {
            lock.lock()
            credentials[issuerOrigin] = refundData
            lock.unlock()
            Logger.privacyPass.debug("Updated credential after refund for \(issuerOrigin, privacy: .public)")
        }

        return spendProofBase64
    }

    // MARK: - Private

    private func fetchPublicKey(from issuerBaseURL: URL) async throws -> String {
        let publicKeyURL = issuerBaseURL.appendingPathComponent("public-key")
        let (data, response) = try await session.data(from: publicKeyURL)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw PrivacyPassError.publicKeyFetchFailed("HTTP \(statusCode)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cborBase64 = json["cbor"] as? String else {
            throw PrivacyPassError.publicKeyFetchFailed("Invalid response format")
        }

        return cborBase64
    }
}

// MARK: - Logger

public extension Logger {
    static let privacyPass = Logger(subsystem: "BrowserServicesKit", category: "PrivacyPass")
}
