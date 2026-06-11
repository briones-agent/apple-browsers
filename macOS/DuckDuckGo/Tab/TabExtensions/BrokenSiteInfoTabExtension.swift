//
//  BrokenSiteInfoTabExtension.swift
//
//  Copyright © 2024 DuckDuckGo. All rights reserved.
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

import BrowserServicesKit
import Combine
import Common
import Foundation
import Navigation
import os.log
import PrivacyDashboard
import UserScript
import WebKit

final class BrokenSiteInfoTabExtension {

    private(set) var lastWebError: Error?
    private(set) var lastHttpStatusCode: Int?

    private(set) var inferredOpenerContext: BrokenSiteReport.OpenerContext?
    private(set) var refreshCountSinceLoad: Int = 0

    private(set) var breakageReportingSubfeature: BreakageReportingSubfeature?
    private var siteLoadingPerformanceSubfeature: SiteLoadingPerformanceSubfeature?
    private(set) var lastPageLoadTiming: WKPageLoadTiming?

    private var cancellables = Set<AnyCancellable>()

    init(contentPublisher: some Publisher<Tab.TabContent, Never>,
         webViewPublisher: some Publisher<WKWebView, Never>,
         contentScopeUserScriptPublisher: some Publisher<ContentScopeUserScript, Never>) {

        webViewPublisher.sink { [weak self] webView in
            self?.breakageReportingSubfeature = BreakageReportingSubfeature(targetWebview: webView)
            self?.siteLoadingPerformanceSubfeature = SiteLoadingPerformanceSubfeature()
        }.store(in: &cancellables)

        contentScopeUserScriptPublisher.sink { [weak self] contentScopeUserScript in
            guard let self else { return }

            if let breakageReportingSubfeature {
                contentScopeUserScript.registerSubfeature(delegate: breakageReportingSubfeature)
            }
            if let siteLoadingPerformanceSubfeature {
                contentScopeUserScript.registerSubfeature(delegate: siteLoadingPerformanceSubfeature)
            }
        }.store(in: &cancellables)
    }

    private func resetRefreshCountIfNeeded(action: NavigationAction) {
        switch action.navigationType {
        case .reload, .other:
            break
        default:
            refreshCountSinceLoad = 0
        }
    }

    private func setOpenerContextIfNeeded(action: NavigationAction) {
        switch action.navigationType {
        case .linkActivated, .formSubmitted:
            inferredOpenerContext = .navigation
        default:
            break
        }
    }

    func tabReloadRequested() {
        refreshCountSinceLoad += 1
    }

}

extension BrokenSiteInfoTabExtension: NavigationResponder {

    @MainActor
    func decidePolicy(for navigationAction: NavigationAction, preferences: inout NavigationPreferences) async -> NavigationActionPolicy? {
        resetRefreshCountIfNeeded(action: navigationAction)
        setOpenerContextIfNeeded(action: navigationAction)

        return .next
    }

    @MainActor
    func willStart(_ navigation: Navigation) {
        if lastWebError != nil { lastWebError = nil }
    }

    @MainActor
    func decidePolicy(for navigationResponse: NavigationResponse) async -> NavigationResponsePolicy? {
        lastHttpStatusCode = navigationResponse.httpStatusCode

        return .next
    }

    @MainActor
    func didStart(_ navigation: Navigation) {
        if inferredOpenerContext != .external {
            inferredOpenerContext = nil
        }

        if lastWebError != nil {
            lastWebError = nil
        }
    }

    @MainActor
    func navigationDidFinish(_ navigation: Navigation) {
        Task { @MainActor in
            if await navigation.navigationAction.targetFrame?.webView?.isCurrentSiteReferredFromDuckDuckGo == true {
                inferredOpenerContext = .serp
            }
        }
    }

    @MainActor
    func didFailProvisionalLoad(with request: URLRequest, in frame: WKFrameInfo, with error: Error) {
        lastWebError = error
    }

    func didGeneratePageLoadTiming(_ timing: WKPageLoadTiming) {
        lastPageLoadTiming = timing
    }

}

protocol BrokenSiteInfoTabExtensionProtocol: AnyObject, NavigationResponder {
    var lastWebError: Error? { get }
    var lastHttpStatusCode: Int? { get }

    var inferredOpenerContext: BrokenSiteReport.OpenerContext? { get }
    var refreshCountSinceLoad: Int { get }

    var breakageReportingSubfeature: BreakageReportingSubfeature? { get }
    var lastPageLoadTiming: WKPageLoadTiming? { get }

    func tabReloadRequested()
}

extension BrokenSiteInfoTabExtension: TabExtension, BrokenSiteInfoTabExtensionProtocol {
    typealias PublicProtocol = BrokenSiteInfoTabExtensionProtocol
    func getPublicProtocol() -> PublicProtocol { self }
}

extension TabExtensions {
    var brokenSiteInfo: BrokenSiteInfoTabExtensionProtocol? {
        resolve(BrokenSiteInfoTabExtension.self)
    }
}

// MARK: - Breakage Signals PoC
//
// Per-page, in-memory accumulator of failed / errored subresources, observed via the WKWebView
// `BreakageResourceLoadObserver` SPI. Emits a single digest line to the unified log (filter "🧪📊")
// on demand (wired to the site-protections button), reading the live buffer so post-load /
// interaction-driven failures up to that moment are included.
//
// Deliberately scoped to the ONE signal the broken-site report doesn't already carry: per-subresource
// failure detail. Main-frame status/failure and blocked-tracker domains already live in
// `BrokenSiteReport` (httpStatusCodes / errors / blockedTrackerDomains) and are not duplicated here.
// Each entry: sanitized URL (scheme+host+path, no query/fragment) + code + resource type + failure
// class + first/third-party, deduped with a count.

final class BreakageSignalsTabExtension {

    enum ResourceOutcome: Equatable {
        case failed(code: Int, errorDomain: String)
        case httpError(status: Int)

        /// Short label used both for de-duplication keys and the digest (the "code" per entry).
        var label: String {
            switch self {
            case .failed(let code, _): return "err\(code)"
            case .httpError(let status): return "http\(status)"
            }
        }

        /// Error domain disambiguating the code (e.g. NSURLErrorDomain vs WebKitErrorDomain); "http" for status errors.
        var errorDomain: String {
            switch self {
            case .failed(_, let domain): return domain
            case .httpError: return "http"
            }
        }
    }

    enum FailureClass: String {
        case resolve, unreachable, cert, http4xx, http5xx, other
    }

    struct ResourceSignal {
        let domain: String        // eTLD+1
        let fileName: String      // last path component only (no path, query, fragment, credentials)
        let displayURL: String?   // sanitized scheme+host+path — internal de-dup key only, not reported
        let resourceType: String?
        let outcome: ResourceOutcome
        let failureClass: FailureClass
        let isThirdParty: Bool
        var count: Int
    }

    /// Mutable subresource failures for a single main-frame page load.
    private final class PageSignals {
        var pageHost: String?
        var resources: [String: ResourceSignal] = [:] // keyed by "displayURL/domain|outcomeLabel"
    }

    private let tld: TLD
    private var page = PageSignals()
    private var cancellables = Set<AnyCancellable>()

    private static let logger = Logger(subsystem: "com.duckduckgo.macos.browser.breakage-poc", category: "BreakageSignalsPoC")
    private static let marker = "🧪"
    private static let maxResources = 200
    private static let ignoredResourceTypes: Set<String> = ["Beacon", "Ping", "CSPReport"] // telemetry, not breakage
    private static let ignoredHosts: Set<String> = ["external-content.duckduckgo.com"] // DDG favicon proxy

    init(webViewPublisher: some Publisher<WKWebView, Never>, tld: TLD) {
        self.tld = tld

        webViewPublisher.sink { [weak self] webView in
            guard let observer = (webView as? WebView)?.breakageObserver else { return }
            observer.onObservation = { [weak self] observation in
                DispatchQueue.main.async { self?.record(observation) }
            }
        }.store(in: &cancellables)
    }

    // MARK: Recording

    private func record(_ observation: BreakageResourceObservation) {
        let host = observation.url?.host
        if let host, Self.ignoredHosts.contains(host) { return }
        if Self.ignoredResourceTypes.contains(observation.resourceTypeName) { return }

        let outcome: ResourceOutcome
        let failureClass: FailureClass
        if let error = observation.error {
            if error.code == NSURLErrorCancelled { return } // navigation churn / fire-and-forget, not breakage
            outcome = .failed(code: error.code, errorDomain: error.domain)
            failureClass = Self.classify(errorCode: error.code)
        } else if let status = observation.httpStatusCode, status >= 400 {
            outcome = .httpError(status: status)
            failureClass = status >= 500 ? .http5xx : .http4xx
        } else {
            return
        }

        add(domain: tld.eTLDplus1(host) ?? host ?? "<?>",
            fileName: Self.fileName(from: observation.url),
            displayURL: Self.sanitizedURLString(observation.url),
            resourceType: observation.resourceTypeName,
            outcome: outcome,
            failureClass: failureClass)
    }

    private func add(domain: String, fileName: String, displayURL: String?, resourceType: String?, outcome: ResourceOutcome, failureClass: FailureClass) {
        let isThirdParty = page.pageHost.map { domain != $0 } ?? true
        let key = "\(displayURL ?? domain)|\(outcome.label)"
        if var existing = page.resources[key] {
            existing.count += 1
            page.resources[key] = existing
        } else if page.resources.count < Self.maxResources {
            page.resources[key] = ResourceSignal(domain: domain, fileName: fileName, displayURL: displayURL, resourceType: resourceType,
                                                 outcome: outcome, failureClass: failureClass, isThirdParty: isThirdParty, count: 1)
        }
    }

    /// Last path component only (e.g. "poster.jpg"); empty for pathless / directory-style URLs.
    private static func fileName(from url: URL?) -> String {
        guard let url else { return "" }
        let last = url.lastPathComponent
        return last == "/" ? "" : last
    }

    /// Strips query, fragment, and credentials — keeps scheme + host + path only.
    private static func sanitizedURLString(_ url: URL?) -> String? {
        guard let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        return components.string
    }

    // MARK: Digest

    @MainActor
    private func resetPage(for navigation: Navigation) {
        page = PageSignals()
        page.pageHost = tld.eTLDplus1(navigation.url.host)
    }

    /// On-demand emission (Breakage Signals PoC — wired to the site-protections button). Reads the
    /// live buffer, so post-load / interaction-driven failures up to this moment are included.
    @MainActor
    func emitDigestOnDemand() {
        emitDigest(reason: "protections-button")
    }

    /// Serialises the current page's failed subresources into a compact delimited string for the
    /// broken-site report (Breakage Signals PoC). One record per line; fields separated by "|" in a
    /// fixed order: domain|filename|code|errorDomain|count. Only the eTLD+1 and the file name are sent —
    /// no path, query, or fragment — so intermediate path IDs aren't disclosed; the resource kind is
    /// inferable from the file name, and first/third-party from the domain vs. the site URL. "|" and
    /// newlines never appear in any field, so no escaping is needed. Returns nil when empty.
    @MainActor
    func failedResourcesReportParameter() -> String? {
        guard !page.resources.isEmpty else { return nil }
        let records = page.resources.values
            .sorted { $0.count > $1.count }
            .prefix(50)
            .map { [
                $0.domain,
                $0.fileName,
                $0.outcome.label,
                $0.outcome.errorDomain,
                String($0.count)
            ].joined(separator: "|") }
        return records.joined(separator: "\n")
    }

    private func emitDigest(reason: String) {
        guard !page.resources.isEmpty else { return }

        let resources = Array(page.resources.values)
        let total = resources.reduce(0) { $0 + $1.count }
        let firstParty = resources.filter { !$0.isThirdParty }.reduce(0) { $0 + $1.count }

        var classes: [FailureClass: Int] = [:]
        for signal in resources { classes[signal.failureClass, default: 0] += signal.count }
        let classSummary = classes.map { "\($0.key.rawValue):\($0.value)" }.sorted().joined(separator: ",")

        let pageHost = page.pageHost ?? "<?>"
        let detail = resources
            .sorted { $0.count > $1.count }
            .prefix(20)
            .map { "\($0.isThirdParty ? "3p" : "1p") \($0.displayURL ?? $0.domain)=\($0.outcome.label)\($0.resourceType.map { "[\($0)]" } ?? "")×\($0.count)" }
            .joined(separator: ", ")

        Self.logger.log("\(Self.marker, privacy: .public)📊 [\(reason, privacy: .public)] page=\(pageHost, privacy: .public) failed=\(total)(1p:\(firstParty),3p:\(total - firstParty)) classes{\(classSummary, privacy: .public)} — \(detail, privacy: .public)")
    }

    static func classify(errorCode: Int) -> FailureClass {
        switch errorCode {
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return .resolve
        case NSURLErrorCannotConnectToHost, NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet:
            return .unreachable
        case (-1206)...(-1200): // NSURLError server/client certificate range
            return .cert
        default:
            return .other
        }
    }
}

extension BreakageSignalsTabExtension: NavigationResponder {

    @MainActor
    func didStart(_ navigation: Navigation) {
        resetPage(for: navigation)
    }
}

protocol BreakageSignalsTabExtensionProtocol: AnyObject, NavigationResponder {
    @MainActor func emitDigestOnDemand()
    @MainActor func failedResourcesReportParameter() -> String?
}

extension BreakageSignalsTabExtension: TabExtension, BreakageSignalsTabExtensionProtocol {
    typealias PublicProtocol = BreakageSignalsTabExtensionProtocol
    func getPublicProtocol() -> PublicProtocol { self }
}

extension TabExtensions {
    var breakageSignals: BreakageSignalsTabExtensionProtocol? {
        resolve(BreakageSignalsTabExtension.self)
    }
}
