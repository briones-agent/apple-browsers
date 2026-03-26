//
//  PrivacyPassChallengeHandler.swift
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

import CommonCrypto
import Foundation
import os.log
import Security
import WebKit

// MARK: - Challenge Model

/// Parsed parameters from a `WWW-Authenticate: PrivateToken` header (RFC 9577).
public struct PrivacyPassChallenge {
    public let issuerURL: String
    public let tokenType: UInt16
    public let tokenKey: String
    public let redemptionContext: Data
    public let rawTokenChallenge: Data
}

// MARK: - Challenge Handler

/// HTTP-level Privacy Pass ACT handler.
///
/// Replaces the previous JS message–based `PrivacyPassSubfeature`.
/// Instead of handling content-scope-scripts messages, this class operates
/// at the HTTP layer:
///
/// 1. Detects `401` responses carrying `WWW-Authenticate: PrivateToken`
/// 2. Parses the challenge to extract the issuer URL
/// 3. Runs the ACT issuance protocol if no credential is stored for that issuer
/// 4. Spends 1 credit to obtain a spend proof
/// 5. Returns an `Authorization` header value so the caller can retry the request
///
/// Both iOS (`TabViewController`) and macOS (navigation responder chain) call
/// into this handler when they observe an eligible 401 response.
public final class PrivacyPassChallengeHandler {

    private let tokenManager: PrivacyPassTokenManaging

    public init(tokenManager: PrivacyPassTokenManaging) {
        self.tokenManager = tokenManager
    }

    // MARK: - Detection

    /// Returns `true` when the response is a Privacy Pass challenge (401 + PrivateToken).
    public func isPrivacyPassChallenge(_ response: HTTPURLResponse) -> Bool {
        guard response.statusCode == 401 else { return false }
        let wwwAuth = response.value(forHTTPHeaderField: "WWW-Authenticate") ?? ""
        return wwwAuth.contains("PrivateToken")
    }

    // MARK: - Parsing

    /// Extracts challenge and token-key from the `WWW-Authenticate` header per RFC 9577.
    ///
    /// Expected format:
    /// ```
    /// PrivateToken challenge=<base64url TokenChallenge>, token-key=<base64url public key CBOR>
    /// ```
    ///
    /// The `TokenChallenge` binary struct contains:
    /// `token_type (2 BE) | issuer_name_len (2 BE) | issuer_name | redemption_context (32)`
    public func parseChallenge(from response: HTTPURLResponse) throws -> PrivacyPassChallenge {
        guard let wwwAuth = response.value(forHTTPHeaderField: "WWW-Authenticate") else {
            throw PrivacyPassError.challengeParsingFailed("Missing WWW-Authenticate header")
        }

        var challengeB64URL: String?
        var tokenKeyB64URL: String?

        let paramString = wwwAuth
            .replacingOccurrences(of: "PrivateToken", with: "")
            .trimmingCharacters(in: .whitespaces)
        let parts = paramString.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }

        for part in parts {
            let keyValue = part.split(separator: "=", maxSplits: 1)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
            guard keyValue.count == 2 else { continue }

            let key = keyValue[0].lowercased()
            let value = keyValue[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))

            switch key {
            case "challenge":
                challengeB64URL = value
            case "token-key":
                tokenKeyB64URL = value
            default:
                break
            }
        }

        guard let challengeB64 = challengeB64URL,
              let challengeData = Self.base64urlDecode(challengeB64) else {
            throw PrivacyPassError.challengeParsingFailed("Missing or invalid challenge in WWW-Authenticate: \(wwwAuth)")
        }

        guard let tokenKeyB64 = tokenKeyB64URL else {
            throw PrivacyPassError.challengeParsingFailed("Missing token-key in WWW-Authenticate: \(wwwAuth)")
        }

        guard challengeData.count >= 4 else {
            throw PrivacyPassError.challengeParsingFailed("TokenChallenge too short")
        }

        let tokenType = UInt16(challengeData[0]) << 8 | UInt16(challengeData[1])
        let issuerNameLen = Int(UInt16(challengeData[2]) << 8 | UInt16(challengeData[3]))

        guard challengeData.count >= 4 + issuerNameLen + 32 else {
            throw PrivacyPassError.challengeParsingFailed("TokenChallenge truncated")
        }

        let issuerName = String(data: challengeData[4..<(4 + issuerNameLen)], encoding: .utf8)
            ?? String(data: challengeData[4..<(4 + issuerNameLen)], encoding: .ascii) ?? ""

        let redemptionStart = 4 + issuerNameLen
        let redemptionContext = challengeData[redemptionStart..<(redemptionStart + 32)]

        return PrivacyPassChallenge(
            issuerURL: issuerName,
            tokenType: tokenType,
            tokenKey: tokenKeyB64,
            redemptionContext: Data(redemptionContext),
            rawTokenChallenge: challengeData)
    }

    // MARK: - Base64url

    private static func base64urlDecode(_ input: String) -> Data? {
        var base64 = input
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64.append(contentsOf: String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: base64)
    }

    static func base64urlEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    // MARK: - Full Challenge Flow

    /// Handles a Privacy Pass challenge end-to-end.
    ///
    /// - Extracts the issuer public key from `token-key` in the challenge header.
    /// - Issues a credential with the issuer if none is stored.
    /// - Spends 1 credit to get a SpendProof.
    /// - Wraps the SpendProof in a Token struct (RFC 9577).
    /// - Returns the full `Authorization` header value (`PrivateToken token=<base64url Token>`).
    public func handleChallenge(from response: HTTPURLResponse) async throws -> String {
        let challenge = try parseChallenge(from: response)
        Logger.privacyPass.debug("Privacy Pass challenge from issuer: \(challenge.issuerURL, privacy: .public)")

        if !tokenManager.hasCredential(for: challenge.issuerURL) {
            Logger.privacyPass.debug("No credential - starting issuance with \(challenge.issuerURL, privacy: .public)")
            try await tokenManager.issueCredential(for: challenge.issuerURL, tokenKeyBase64url: challenge.tokenKey)
        }

        let spendProofData = try await tokenManager.spendRaw(for: challenge.issuerURL)

        var tokenStruct = Data()
        var tokenTypeBE = challenge.tokenType.bigEndian
        tokenStruct.append(Data(bytes: &tokenTypeBE, count: 2))

        var nonce = Data(count: 32)
        nonce.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        tokenStruct.append(nonce)

        var challengeDigest = Data(count: 32)
        let rawChallenge = challenge.rawTokenChallenge
        challengeDigest = sha256(rawChallenge)
        tokenStruct.append(challengeDigest)

        tokenStruct.append(spendProofData)

        let tokenB64URL = Self.base64urlEncode(tokenStruct)
        let authorization = "PrivateToken token=\(tokenB64URL)"
        Logger.privacyPass.debug("Generated authorization for \(challenge.issuerURL, privacy: .public)")
        return authorization
    }

    private func sha256(_ data: Data) -> Data {
        var hash = [UInt8](repeating: 0, count: 32)
        data.withUnsafeBytes {
            _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash)
        }
        return Data(hash)
    }

    /// Builds a `URLRequest` that retries the original URL with the authorization token.
    public func authorizedRequest(for originalURL: URL, authorization: String) -> URLRequest {
        var request = URLRequest(url: originalURL)
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        return request
    }

    // MARK: - WKWebView Integration

    /// Convenience for retrying a navigation in a `WKWebView` after obtaining authorization.
    ///
    /// Call this from `decidePolicy(for navigationResponse:)` when `isPrivacyPassChallenge` returns true.
    /// The handler will cancel the current navigation, perform the issuance/spend flow,
    /// and load a new request with the `Authorization` header.
    @MainActor
    public func handleChallengeAndRetry(response: HTTPURLResponse,
                                        originalURL: URL,
                                        webView: WKWebView) async throws {
        let authorization = try await handleChallenge(from: response)
        let request = authorizedRequest(for: originalURL, authorization: authorization)
        webView.load(request)
        Logger.privacyPass.debug("Retrying navigation to \(originalURL.absoluteString, privacy: .public) with authorization")
    }
}
