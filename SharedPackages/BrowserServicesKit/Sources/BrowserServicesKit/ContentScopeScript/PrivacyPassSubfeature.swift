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

import Foundation
import os.log
import WebKit

// MARK: - Challenge Model

/// Parsed parameters from a `WWW-Authenticate: PrivateToken` header.
public struct PrivacyPassChallenge {
    public let issuerURL: String
    public let tokenType: String?
    public let challenge: String?
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

    /// Extracts issuer URL, token-type, and challenge value from the
    /// `WWW-Authenticate` header.
    ///
    /// Expected format:
    /// ```
    /// PrivateToken challenge=<base64>, issuer="<url>", token-type=<int>
    /// ```
    public func parseChallenge(from response: HTTPURLResponse) throws -> PrivacyPassChallenge {
        guard let wwwAuth = response.value(forHTTPHeaderField: "WWW-Authenticate") else {
            throw PrivacyPassError.challengeParsingFailed("Missing WWW-Authenticate header")
        }

        var issuerURL: String?
        var tokenType: String?
        var challengeValue: String?

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
            case "issuer":
                issuerURL = value
            case "token-type":
                tokenType = value
            case "challenge":
                challengeValue = value
            default:
                break
            }
        }

        guard let issuer = issuerURL else {
            throw PrivacyPassError.challengeParsingFailed("Missing issuer in WWW-Authenticate: \(wwwAuth)")
        }

        return PrivacyPassChallenge(issuerURL: issuer, tokenType: tokenType, challenge: challengeValue)
    }

    // MARK: - Full Challenge Flow

    /// Handles a Privacy Pass challenge end-to-end.
    ///
    /// - Issues a credential with the issuer if none is stored.
    /// - Spends 1 credit.
    /// - Returns the full `Authorization` header value (`PrivateToken token=<base64>`).
    public func handleChallenge(from response: HTTPURLResponse) async throws -> String {
        let challenge = try parseChallenge(from: response)
        Logger.privacyPass.debug("Privacy Pass challenge from issuer: \(challenge.issuerURL, privacy: .public)")

        if !tokenManager.hasCredential(for: challenge.issuerURL) {
            Logger.privacyPass.debug("No credential — starting issuance with \(challenge.issuerURL, privacy: .public)")
            try await tokenManager.issueCredential(for: challenge.issuerURL)
        }

        let spendProof = try await tokenManager.spend(for: challenge.issuerURL)
        let authorization = "PrivateToken token=\(spendProof)"
        Logger.privacyPass.debug("Generated authorization for \(challenge.issuerURL, privacy: .public)")
        return authorization
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
