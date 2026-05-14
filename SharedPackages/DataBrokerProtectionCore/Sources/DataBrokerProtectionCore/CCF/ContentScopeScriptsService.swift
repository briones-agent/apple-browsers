//
//  ContentScopeScriptsService.swift
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
import Common
import BrowserServicesKit
import UserScript

public protocol ContentScopeScriptsServiceProtocol {
    /// Reads the remote manifest; if the remote patch number is higher than the locally-saved
    /// version's patch number, downloads and saves the new script and updates the persisted version.
    /// Returns the saved version when a download was applied, otherwise `nil`.
    @discardableResult
    func checkForUpdates() async throws -> String?

    /// Currently-saved script content, if any has been downloaded.
    var cachedScript: String? { get }

    /// Currently-saved version, if any has been downloaded.
    var savedVersion: String? { get }
}

public final class ContentScopeScriptsService: ContentScopeScriptsServiceProtocol {

    public enum Error: Swift.Error, CustomNSError {
        case serverError(httpCode: Int?)
        case clientError
        case noAccessToken
        case invalidEncoding
        case invalidManifest
        case invalidVersion(String)

        public static var errorDomain: String { "ContentScopeScriptsService" }

        public var errorCode: Int {
            switch self {
            case .serverError: return 201
            case .clientError: return 202
            case .noAccessToken: return 203
            case .invalidEncoding: return 204
            case .invalidManifest: return 205
            case .invalidVersion: return 206
            }
        }

        public var errorUserInfo: [String: Any] {
            switch self {
            case .serverError(httpCode: let code):
                guard let code else { return [:] }
                return [NSUnderlyingErrorKey: NSError(domain: "HTTPError", code: code)]
            case .invalidVersion(let version):
                return [NSLocalizedDescriptionKey: "Invalid version string: \(version)"]
            case .clientError, .noAccessToken, .invalidEncoding, .invalidManifest:
                return [:]
            }
        }
    }

    enum Endpoint {
        static let path = "/dbp/remote/v0"
        static let scriptFileName = "contentScopeScripts.js"
        static let manifestFileName = "contentScopeScripts.json"
        static let type = "css"

        static func manifestRequest(endpointURL: URL, accessToken: String) throws -> URLRequest {
            var components = URLComponents(url: endpointURL, resolvingAgainstBaseURL: true)
            components?.path += path
            components?.queryItems = [
                .init(name: "name", value: manifestFileName),
                .init(name: "type", value: type)
            ]
            return try makeRequest(components: components, accessToken: accessToken)
        }

        static func scriptRequest(version: String, endpointURL: URL, accessToken: String) throws -> URLRequest {
            var components = URLComponents(url: endpointURL, resolvingAgainstBaseURL: true)
            components?.path += path
            components?.queryItems = [
                .init(name: "name", value: scriptFileName),
                .init(name: "type", value: type),
                .init(name: "version", value: version)
            ]
            return try makeRequest(components: components, accessToken: accessToken)
        }

        private static func makeRequest(components: URLComponents?, accessToken: String) throws -> URLRequest {
            guard let url = components?.url else { throw Error.clientError }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            return request
        }
    }

    struct Manifest: Decodable {
        let version: String
    }

    private static var cacheDirectoryName = "PIR"
    private static let cachedScriptFileName = ContentScopeScriptContext.pirRemote.fileName

    private let settings: DataBrokerProtectionSettings
    private let fileManager: FileManager
    private let urlSession: URLSession
    private let authenticationManager: DataBrokerProtectionAuthenticationManaging

    public init(settings: DataBrokerProtectionSettings,
                authenticationManager: DataBrokerProtectionAuthenticationManaging,
                fileManager: FileManager = .default,
                urlSession: URLSession = .shared) {
        self.settings = settings
        self.authenticationManager = authenticationManager
        self.fileManager = fileManager
        self.urlSession = urlSession
    }

    // MARK: - Public API

    public var shouldUseRemoteContentScopeScript: Bool {
        //todo feature flagging and compile flagging
        //TODO handle if not saved
        return true
    }

    public var savedVersion: String? {
        settings.contentScopeScriptsFetchedVersion
    }

    public var cachedScript: String? {
        guard let url = try? savedScriptURL(),
              fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    @discardableResult
    public func checkForUpdates() async throws -> String? {
        guard let accessToken = await authenticationManager.accessToken() else {
            Logger.dataBrokerProtection.error("🧩 No access token available to check content scope script updates")
            throw Error.noAccessToken
        }

        let remoteVersion = try await fetchRemoteVersion(accessToken: accessToken)

        guard try Self.shouldUpdate(currentVersion: savedVersion, remoteVersion: remoteVersion) else {
            Logger.dataBrokerProtection.log("🧩 Content scope script up to date (saved: \(self.savedVersion ?? "none", privacy: .public), remote: \(remoteVersion, privacy: .public))")
            return nil
        }

        try await downloadAndSaveScript(version: remoteVersion, accessToken: accessToken)
        settings.contentScopeScriptsFetchedVersion = remoteVersion
        Logger.dataBrokerProtection.log("🧩 Updated content scope script to version \(remoteVersion, privacy: .public)")
        return remoteVersion
    }

    // MARK: - Network

    private func fetchRemoteVersion(accessToken: String) async throws -> String {
        let request = try Endpoint.manifestRequest(endpointURL: settings.endpointURL, accessToken: accessToken)
        let (data, response) = try await urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode
            Logger.dataBrokerProtection.error("🧩 Failed to fetch content scope script manifest, status: \(String(describing: code), privacy: .public)")
            throw Error.serverError(httpCode: code)
        }

        do {
            return try JSONDecoder().decode(Manifest.self, from: data).version
        } catch {
            throw Error.invalidManifest
        }
    }

    private func downloadAndSaveScript(version: String, accessToken: String) async throws {
        let request = try Endpoint.scriptRequest(version: version, endpointURL: settings.endpointURL, accessToken: accessToken)
        let (data, response) = try await urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode
            Logger.dataBrokerProtection.error("🧩 Failed to fetch content scope script for version \(version, privacy: .public), status: \(String(describing: code), privacy: .public)")
            throw Error.serverError(httpCode: code)
        }

        guard String(data: data, encoding: .utf8) != nil else {
            throw Error.invalidEncoding
        }

        let destinationURL = try savedScriptURL()
        try data.write(to: destinationURL, options: .atomic)
        JSFileCache.clearCache(forFile: Self.cachedScriptFileName, in: destinationURL.deletingLastPathComponent())
    }

    // MARK: - File handling

    func savedScriptURL() throws -> URL {
        let directory = fileManager.applicationSupportDirectoryForComponent(named: Self.cacheDirectoryName)

        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        return directory.appendingPathComponent(Self.cachedScriptFileName)
    }
}

// MARK: - should update logic
private extension ContentScopeScriptsService {

    /// Returns true when `remoteVersion` and `currentVersion` share the same major and minor
    /// components and `remoteVersion`'s patch component is strictly higher, or when there is
    /// no `currentVersion` yet. A remote with a different major or minor is never auto-applied.
    /// Throws `Error.invalidVersion` if either string is not in `MAJOR.MINOR.PATCH` form.
    static func shouldUpdate(currentVersion: String?, remoteVersion: String) throws -> Bool {
        let remote = try versionComponents(remoteVersion)
        guard let currentVersion else { return true }
        let current = try versionComponents(currentVersion)
        guard current.major == remote.major, current.minor == remote.minor else { return false }
        return remote.patch > current.patch
    }

    /// Parses a strict `MAJOR.MINOR.PATCH` version string with non-negative integer components.
    /// Any deviation (wrong component count, non-numeric, negative) throws `Error.invalidVersion`.
    static func versionComponents(_ version: String) throws -> (major: Int, minor: Int, patch: Int) {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let major = Int(parts[0]), major >= 0,
              let minor = Int(parts[1]), minor >= 0,
              let patch = Int(parts[2]), patch >= 0 else {
            throw Error.invalidVersion(version)
        }
        return (major, minor, patch)
    }
}
