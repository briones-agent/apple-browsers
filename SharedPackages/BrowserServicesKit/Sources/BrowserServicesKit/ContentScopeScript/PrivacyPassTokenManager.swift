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

import ActCore
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
    case ffiError(String)

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
        case .ffiError(let detail):
            return "ACT FFI error: \(detail)"
        }
    }
}

// MARK: - Protocol

/// Manages ACT (Anonymous Credit Token) credentials for Privacy Pass.
///
/// The full protocol flow:
/// 1. **Issuance**: `act_pre_issuance_new` → `act_issuance_request` → HTTP POST `/token-request` → `act_complete_issuance`
/// 2. **Spending**: `act_spend` → HTTP POST `/token-spend` → `act_complete_refund`
public protocol PrivacyPassTokenManaging: AnyObject {
    func hasCredential(for issuerOrigin: String) -> Bool
    func issueCredential(for issuerOrigin: String) async throws
    func issueCredential(for issuerOrigin: String, tokenKeyBase64url: String) async throws
    func spend(for issuerOrigin: String) async throws -> String
    func spendRaw(for issuerOrigin: String) async throws -> Data
}

// MARK: - Implementation

public final class PrivacyPassTokenManager: PrivacyPassTokenManaging {

    private var credentialCBOR: [String: Data] = [:]
    private var publicKeyCBOR: [String: Data] = [:]
    private let lock = NSLock()
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func hasCredential(for issuerOrigin: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return credentialCBOR[issuerOrigin] != nil
    }

    public func issueCredential(for issuerOrigin: String) async throws {
        guard let issuerBaseURL = URL(string: issuerOrigin) else {
            throw PrivacyPassError.issuerURLInvalid(issuerOrigin)
        }

        let pkData = try await fetchPublicKey(from: issuerBaseURL)
        try await performIssuance(for: issuerOrigin, issuerBaseURL: issuerBaseURL, pkData: pkData)
    }

    public func issueCredential(for issuerOrigin: String, tokenKeyBase64url: String) async throws {
        guard let issuerBaseURL = URL(string: issuerOrigin) else {
            throw PrivacyPassError.issuerURLInvalid(issuerOrigin)
        }

        guard let pkData = base64urlDecode(tokenKeyBase64url) else {
            throw PrivacyPassError.publicKeyFetchFailed("Invalid base64url token-key")
        }

        try await performIssuance(for: issuerOrigin, issuerBaseURL: issuerBaseURL, pkData: pkData)
    }

    private func performIssuance(for issuerOrigin: String, issuerBaseURL: URL, pkData: Data) async throws {
        Logger.privacyPass.debug("Using public key for \(issuerOrigin, privacy: .public)")

        let pk = try pkData.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> OpaquePointer in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                throw PrivacyPassError.ffiError("public key buffer empty")
            }
            guard let ptr = act_public_key_from_cbor(base, raw.count) else {
                throw PrivacyPassError.ffiError("act_public_key_from_cbor returned nil")
            }
            return ptr
        }
        defer { act_public_key_free(pk) }

        guard let pre = act_pre_issuance_new() else {
            throw PrivacyPassError.ffiError("act_pre_issuance_new returned nil")
        }
        defer { act_pre_issuance_free(pre) }

        guard let params = act_params_new("duckduckgo", "privacy-pass", "prototype", "2026-03") else {
            throw PrivacyPassError.ffiError("act_params_new returned nil")
        }
        defer { act_params_free(params) }

        var requestBuf = act_issuance_request(pre, params)
        guard let requestData = bufferToData(requestBuf) else {
            act_buffer_free(requestBuf)
            throw PrivacyPassError.ffiError("act_issuance_request returned empty buffer")
        }
        act_buffer_free(requestBuf)

        let requestBase64 = requestData.base64EncodedString()
        let issuancePayload = try JSONSerialization.data(withJSONObject: ["cbor": requestBase64])

        let tokenRequestURL = issuerBaseURL.appendingPathComponent("token-request")
        var httpRequest = URLRequest(url: tokenRequestURL)
        httpRequest.httpMethod = "POST"
        httpRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        httpRequest.httpBody = issuancePayload

        let (responseData, response) = try await session.data(for: httpRequest)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw PrivacyPassError.issuanceRequestFailed("HTTP \(statusCode)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let responseCborBase64 = json["cbor"] as? String,
              let responseCborData = Data(base64Encoded: responseCborBase64) else {
            throw PrivacyPassError.invalidServerResponse
        }

        let token: OpaquePointer = try requestData.withUnsafeBytes { (reqRaw: UnsafeRawBufferPointer) in
            try responseCborData.withUnsafeBytes { (respRaw: UnsafeRawBufferPointer) in
                guard let reqBase = reqRaw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let respBase = respRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    throw PrivacyPassError.ffiError("buffer base address nil")
                }
                guard let t = act_complete_issuance(pre, params, pk,
                                                    reqBase, reqRaw.count,
                                                    respBase, respRaw.count) else {
                    throw PrivacyPassError.ffiError("act_complete_issuance returned nil")
                }
                return t
            }
        }
        defer { act_credit_token_free(token) }

        var tokenBuf = act_credit_token_to_cbor(token)
        guard let tokenData = bufferToData(tokenBuf) else {
            act_buffer_free(tokenBuf)
            throw PrivacyPassError.ffiError("act_credit_token_to_cbor returned empty buffer")
        }
        act_buffer_free(tokenBuf)

        lock.lock()
        credentialCBOR[issuerOrigin] = tokenData
        publicKeyCBOR[issuerOrigin] = pkData
        lock.unlock()

        Logger.privacyPass.debug("Stored credential for \(issuerOrigin, privacy: .public)")
    }

    public func spend(for issuerOrigin: String) async throws -> String {
        guard let issuerBaseURL = URL(string: issuerOrigin) else {
            throw PrivacyPassError.issuerURLInvalid(issuerOrigin)
        }

        lock.lock()
        guard let storedTokenCBOR = credentialCBOR[issuerOrigin],
              let storedPKCBOR = publicKeyCBOR[issuerOrigin] else {
            lock.unlock()
            throw PrivacyPassError.noCredentialForIssuer(issuerOrigin)
        }
        lock.unlock()

        let token: OpaquePointer = try storedTokenCBOR.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                throw PrivacyPassError.ffiError("token buffer empty")
            }
            guard let t = act_credit_token_from_cbor(base, raw.count) else {
                throw PrivacyPassError.ffiError("act_credit_token_from_cbor returned nil")
            }
            return t
        }
        defer { act_credit_token_free(token) }

        guard let params = act_params_new("duckduckgo", "privacy-pass", "prototype", "2026-03") else {
            throw PrivacyPassError.ffiError("act_params_new returned nil")
        }
        defer { act_params_free(params) }

        let pk: OpaquePointer = try storedPKCBOR.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                throw PrivacyPassError.ffiError("pk buffer empty")
            }
            guard let ptr = act_public_key_from_cbor(base, raw.count) else {
                throw PrivacyPassError.ffiError("act_public_key_from_cbor returned nil")
            }
            return ptr
        }
        defer { act_public_key_free(pk) }

        var spendResult = act_spend(token, params, 1)
        guard let spendProofData = bufferToData(spendResult.spend_proof_cbor) else {
            act_buffer_free(spendResult.spend_proof_cbor)
            if let preRefund = spendResult.pre_refund { act_pre_refund_free(preRefund) }
            throw PrivacyPassError.ffiError("act_spend returned empty spend proof")
        }
        act_buffer_free(spendResult.spend_proof_cbor)

        guard let preRefund = spendResult.pre_refund else {
            throw PrivacyPassError.ffiError("act_spend returned nil pre_refund")
        }
        defer { act_pre_refund_free(preRefund) }

        let spendPayload = try JSONSerialization.data(
            withJSONObject: ["cbor": spendProofData.base64EncodedString()])

        let tokenSpendURL = issuerBaseURL.appendingPathComponent("token-spend")
        var httpRequest = URLRequest(url: tokenSpendURL)
        httpRequest.httpMethod = "POST"
        httpRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        httpRequest.httpBody = spendPayload

        let (responseData, response) = try await session.data(for: httpRequest)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw PrivacyPassError.spendRequestFailed("HTTP \(statusCode)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let refundCborBase64 = json["cbor"] as? String,
              let refundCborData = Data(base64Encoded: refundCborBase64) else {
            throw PrivacyPassError.invalidServerResponse
        }

        let newToken: OpaquePointer = try spendProofData.withUnsafeBytes { (spRaw: UnsafeRawBufferPointer) in
            try refundCborData.withUnsafeBytes { (rfRaw: UnsafeRawBufferPointer) in
                guard let spBase = spRaw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let rfBase = rfRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    throw PrivacyPassError.ffiError("refund buffer base address nil")
                }
                guard let t = act_complete_refund(preRefund, params,
                                                  spBase, spRaw.count,
                                                  rfBase, rfRaw.count,
                                                  pk) else {
                    throw PrivacyPassError.ffiError("act_complete_refund returned nil")
                }
                return t
            }
        }
        defer { act_credit_token_free(newToken) }

        var newTokenBuf = act_credit_token_to_cbor(newToken)
        guard let newTokenData = bufferToData(newTokenBuf) else {
            act_buffer_free(newTokenBuf)
            throw PrivacyPassError.ffiError("act_credit_token_to_cbor returned empty buffer")
        }
        act_buffer_free(newTokenBuf)

        lock.lock()
        credentialCBOR[issuerOrigin] = newTokenData
        lock.unlock()

        Logger.privacyPass.debug("Updated credential after refund for \(issuerOrigin, privacy: .public)")

        return spendProofData.base64EncodedString()
    }

    public func spendRaw(for issuerOrigin: String) async throws -> Data {
        let base64String = try await spend(for: issuerOrigin)
        guard let data = Data(base64Encoded: base64String) else {
            throw PrivacyPassError.ffiError("Failed to decode spend proof from base64")
        }
        return data
    }

    // MARK: - Private

    private func fetchPublicKey(from issuerBaseURL: URL) async throws -> Data {
        let publicKeyURL = issuerBaseURL.appendingPathComponent("public-key")
        let (data, response) = try await session.data(from: publicKeyURL)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw PrivacyPassError.publicKeyFetchFailed("HTTP \(statusCode)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cborBase64 = json["cbor"] as? String,
              let cborData = Data(base64Encoded: cborBase64) else {
            throw PrivacyPassError.publicKeyFetchFailed("Invalid response format")
        }

        return cborData
    }

    private func bufferToData(_ buf: ActBuffer) -> Data? {
        guard let ptr = buf.data else { return nil }
        return Data(bytes: ptr, count: buf.len)
    }

    private func base64urlDecode(_ input: String) -> Data? {
        var base64 = input
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64.append(contentsOf: String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: base64)
    }
}

// MARK: - Logger

public extension Logger {
    static let privacyPass = Logger(subsystem: "BrowserServicesKit", category: "PrivacyPass")
}
