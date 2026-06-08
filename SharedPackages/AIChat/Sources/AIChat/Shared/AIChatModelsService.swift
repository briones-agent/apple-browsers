//
//  AIChatModelsService.swift
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
import WebKit

// MARK: - Cookie Providing

public protocol AIChatCookieProviding {
    func cookies(for url: URL) async -> [HTTPCookie]
}

public struct WKHTTPCookieStoreProvider: AIChatCookieProviding {
    private let cookieStore: WKHTTPCookieStore

    public init(cookieStore: WKHTTPCookieStore = WKWebsiteDataStore.default().httpCookieStore) {
        self.cookieStore = cookieStore
    }

    public func cookies(for url: URL) async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            cookieStore.getAllCookies { cookies in
                let domain = url.host ?? ""
                let relevant = cookies.filter { cookie in
                    let cookieDomain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
                    return domain.hasSuffix(cookieDomain)
                }
                continuation.resume(returning: relevant)
            }
        }
    }
}

// MARK: - Remote Models

public struct AIChatModelsResponse: Decodable {
    public let models: [AIChatRemoteModel]
    public let attachmentLimits: AIChatAttachmentLimits?

    public init(models: [AIChatRemoteModel], attachmentLimits: AIChatAttachmentLimits? = nil) {
        self.models = models
        self.attachmentLimits = attachmentLimits
    }

    private enum CodingKeys: String, CodingKey {
        case models
        case attachmentLimits
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        models = try container.decode([AIChatRemoteModel].self, forKey: .models)

        do {
            attachmentLimits = try container.decodeIfPresent(AIChatAttachmentLimits.self, forKey: .attachmentLimits)
        } catch {
            Logger.aiChat.error("Failed to decode AI Chat attachment limits: \(error.localizedDescription)")
            attachmentLimits = nil
        }
    }
}

public struct AIChatRemoteModel: Decodable, Equatable {
    public let id: String
    public let name: String
    public let modelShortName: String?
    public let provider: String
    public let entityHasAccess: Bool
    public let supportsImageUpload: Bool
    public let supportedFileTypes: [String]?
    public let supportedTools: [String]
    public let accessTier: [String]
    public let supportedReasoningEffort: [AIChatReasoningEffort]

    public init(
        id: String,
        name: String,
        modelShortName: String? = nil,
        provider: String,
        entityHasAccess: Bool,
        supportsImageUpload: Bool,
        supportedFileTypes: [String]? = nil,
        supportedTools: [String],
        accessTier: [String],
        supportedReasoningEffort: [AIChatReasoningEffort] = []
    ) {
        self.id = id
        self.name = name
        self.modelShortName = modelShortName
        self.provider = provider
        self.entityHasAccess = entityHasAccess
        self.supportsImageUpload = supportsImageUpload
        self.supportedFileTypes = supportedFileTypes
        self.supportedTools = supportedTools
        self.accessTier = accessTier
        self.supportedReasoningEffort = supportedReasoningEffort
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, modelShortName, provider, entityHasAccess, supportsImageUpload, supportedFileTypes, supportedTools, supportedReasoningEffort, accessTier
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.modelShortName = try container.decodeIfPresent(String.self, forKey: .modelShortName)
        self.provider = try container.decode(String.self, forKey: .provider)
        self.entityHasAccess = try container.decode(Bool.self, forKey: .entityHasAccess)
        self.supportsImageUpload = try container.decode(Bool.self, forKey: .supportsImageUpload)
        self.supportedFileTypes = try container.decodeIfPresent([String].self, forKey: .supportedFileTypes)
        self.supportedTools = try container.decode([String].self, forKey: .supportedTools)
        self.supportedReasoningEffort = try container.decodeIfPresent([String].self, forKey: .supportedReasoningEffort)?
            .compactMap(AIChatReasoningEffort.init(rawValue:)) ?? []
        self.accessTier = try container.decode([String].self, forKey: .accessTier)
    }
}

// MARK: - Service Protocol

public protocol AIChatModelsProviding {
    func fetchModels() async throws -> AIChatModelsResponse
}

// MARK: - Service Implementation

public final class AIChatModelsService: AIChatModelsProviding {

    public enum ServiceError: Error, LocalizedError {
        case invalidResponse
        case httpError(statusCode: Int)

        public var errorDescription: String? {
            switch self {
            case .invalidResponse: return "Invalid response from models endpoint"
            case .httpError(let statusCode): return "HTTP error \(statusCode) from models endpoint"
            }
        }
    }

    /// Returns a subscription access token (JWT) to send as a `Bearer` Authorization header,
    /// or `nil` when the user is signed out / free. The backend needs this token to resolve the
    /// caller's tier and return correct `entityHasAccess` values. Optional so callers that don't
    /// wire a subscription (e.g. tests, or platforms still on local access computation) are unaffected.
    public typealias AccessTokenProviding = () async -> String?

    private let baseURL: URL
    private let session: URLSession
    private let cookieProvider: AIChatCookieProviding
    private let accessTokenProvider: AccessTokenProviding?

    public init(
        baseURL: URL = URL(string: "https://duck.ai")!,
        session: URLSession = .shared,
        cookieProvider: AIChatCookieProviding = WKHTTPCookieStoreProvider(),
        accessTokenProvider: AccessTokenProviding? = nil
    ) {
        self.baseURL = baseURL
        self.session = session
        self.cookieProvider = cookieProvider
        self.accessTokenProvider = accessTokenProvider
    }

    public func fetchModels() async throws -> AIChatModelsResponse {
        let url = baseURL.appendingPathComponent("duckchat/v1/models")

        let cookies = await cookieProvider.cookies(for: baseURL)
        var request = URLRequest(url: url)
        HTTPCookie.requestHeaderFields(with: cookies).forEach {
            request.addValue($1, forHTTPHeaderField: $0)
        }

        let accessToken = await accessTokenProvider?()
        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }

        // Diagnostics for backend: log what we actually send (auth presence + cookie names only,
        // never values/tokens) so backend folks can correlate a request with the tier they resolve.
        Logger.aiChat.log("duck.ai models request — Authorization: \(accessToken != nil ? "Bearer present" : "none", privacy: .public), cookies: [\(cookies.map(\.name).sorted().joined(separator: ", "), privacy: .public)]")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ServiceError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw ServiceError.httpError(statusCode: httpResponse.statusCode)
        }

        // Diagnostics for backend: dump the full raw body (debug level → not persisted in production,
        // visible only when streaming logs). Logged before decoding so it survives a decode failure.
        if let bodyString = String(data: data, encoding: .utf8) {
            Logger.aiChat.debug("duck.ai models raw response body: \(bodyString, privacy: .public)")
        }

        let decoded = try JSONDecoder().decode(AIChatModelsResponse.self, from: data)

        // Diagnostics for backend: log the entityHasAccess / accessTier the backend returned per model,
        // so a discrepancy with the user's real tier is visible in logs.
        let summary = decoded.models.map { "\($0.id)=\($0.entityHasAccess)[\($0.accessTier.joined(separator: "|"))]" }.joined(separator: ", ")
        Logger.aiChat.log("duck.ai models response — \(summary, privacy: .public)")

        return decoded
    }

}

// MARK: - AIChatModel Mapping

public enum AIChatUserTier: String {
    case free
    case plus
    case pro
    case `internal`
}

extension AIChatModel {
    private static let nativeSupportedImageFormats = ["png", "jpeg", "webp"]

    public init(remoteModel: AIChatRemoteModel, userTier: AIChatUserTier) {
        let hasAccess = remoteModel.accessTier.contains(userTier.rawValue)
        self.init(
            id: remoteModel.id,
            name: remoteModel.name,
            shortName: remoteModel.modelShortName,
            provider: .from(id: remoteModel.id, providerString: remoteModel.provider),
            supportsImageUpload: remoteModel.supportsImageUpload,
            supportedFileTypes: remoteModel.supportedFileTypes ?? [],
            supportedImageFormats: remoteModel.supportsImageUpload ? Self.nativeSupportedImageFormats : [],
            supportedTools: remoteModel.supportedTools.compactMap(AIChatRAGTool.init(rawValue:)),
            entityHasAccess: hasAccess,
            accessTier: remoteModel.accessTier,
            supportedReasoningEffort: remoteModel.supportedReasoningEffort
        )
    }
}

extension AIChatModel.ModelProvider {
    public static func from(id: String, providerString: String) -> AIChatModel.ModelProvider {
        let normalizedProviderString = providerString.lowercased()
        let isMetaProvider = id.hasPrefix("meta-llama/") || id.hasPrefix("meta-llama_") || normalizedProviderString == "azure"
        let isMistralProvider = id.hasPrefix("mistralai/")
            || id.hasPrefix("mistralai_")
            || normalizedProviderString == "mistral"
            || normalizedProviderString == "mistralai"

        if isMetaProvider {
            return .meta
        } else if isMistralProvider {
            return .mistral
        } else if id.contains("gpt-oss") {
            return .oss
        } else if normalizedProviderString == "anthropic" {
            return .anthropic
        } else if normalizedProviderString == "openai" {
            return .openAI
        } else {
            return .unknown
        }
    }
}
