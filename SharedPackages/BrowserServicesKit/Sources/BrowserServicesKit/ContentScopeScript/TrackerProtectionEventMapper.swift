//
//  TrackerProtectionEventMapper.swift
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

import Common
import ContentBlocking
import Foundation
import PrivacyConfig
import TrackerRadarKit

/// Classifies raw C-S-S resource observations into DetectedRequest using native TrackerResolver.
///
/// C-S-S sends pre-block `{url, resourceType, potentiallyBlocked, pageUrl}` signals.
/// `potentiallyBlocked` reflects JS-side heuristics, not the definitive WKContentRuleList verdict.
/// This mapper computes a native blocked candidate from privacy config state and passes it to
/// TrackerResolver instead, mirroring the legacy contentblockerrules.js semantics.
///
/// Classification mirrors the legacy ContentBlockerRulesUserScript multi-TDS loop:
/// 1. Try each supplementary TDS (CTL, ad-attribution) with the ad-click vendor —
///    if any returns blocked, use it immediately.
/// 2. Fall back to the main TDS without vendor.
/// 3. If no tracker found, synthesize a third-party request when cross-site.
public struct TrackerProtectionEventMapper {

    private let tld: TLD
    private let mainTrackerData: TrackerData
    private let supplementaryTrackerData: [TrackerData]
    private let unprotectedSites: [String]
    private let tempList: [String]
    private let contentBlockingEnabled: Bool

    public init(tld: TLD,
                mainTrackerData: TrackerData,
                supplementaryTrackerData: [TrackerData] = [],
                unprotectedSites: [String],
                tempList: [String],
                contentBlockingEnabled: Bool) {
        self.tld = tld
        self.mainTrackerData = mainTrackerData
        self.supplementaryTrackerData = supplementaryTrackerData
        self.unprotectedSites = unprotectedSites
        self.tempList = tempList
        self.contentBlockingEnabled = contentBlockingEnabled
    }

    /// Convenience init matching the old single-resolver API.
    public init(tld: TLD, trackerResolver: TrackerResolver, privacyConfig: PrivacyConfiguration) {
        self.tld = tld
        self.mainTrackerData = trackerResolver.tds
        self.supplementaryTrackerData = []
        self.unprotectedSites = trackerResolver.unprotectedSites
        self.tempList = trackerResolver.tempList
        self.contentBlockingEnabled = privacyConfig.isEnabled(featureKey: .contentBlocking)
    }

    // MARK: - ResourceObservation classification

    /// Classify a raw resource observation using the multi-TDS loop that mirrors the legacy pipeline.
    public func classifyResource(_ observation: TrackerProtectionSubfeature.ResourceObservation,
                                 adClickAttributionVendor: String? = nil) -> DetectedRequest? {
        return classifyUrl(observation.url,
                           pageUrlString: observation.pageUrl,
                           resourceType: observation.resourceType,
                           adClickAttributionVendor: adClickAttributionVendor)
    }

    // MARK: - SurrogateInjection mapping

    /// Map a surrogate injection signal to a DetectedRequest.
    public func classifySurrogate(_ surrogate: TrackerProtectionSubfeature.SurrogateInjection,
                                  adClickAttributionVendor: String? = nil) -> DetectedRequest? {
        return classifyUrl(surrogate.url,
                           pageUrlString: surrogate.pageUrl,
                           resourceType: "script",
                           adClickAttributionVendor: adClickAttributionVendor)
    }

    /// Extract the surrogate host from the injection URL.
    public func surrogateHost(from surrogate: TrackerProtectionSubfeature.SurrogateInjection) -> String? {
        return URL(string: surrogate.url)?.host
    }

    // MARK: - Classification helpers

    /// Returns true when request and page share the same eTLD+1.
    public func isSameSiteObservation(_ observation: TrackerProtectionSubfeature.ResourceObservation) -> Bool {
        let requestETLDplus1 = tld.eTLDplus1(forStringURL: observation.url)
        let pageETLDplus1 = tld.eTLDplus1(forStringURL: observation.pageUrl)
        guard let requestETLDplus1, let pageETLDplus1 else { return false }
        return requestETLDplus1 == pageETLDplus1
    }

    /// Build a DetectedRequest for a non-TDS cross-site resource (third-party request).
    public func makeThirdPartyRequest(from observation: TrackerProtectionSubfeature.ResourceObservation) -> DetectedRequest? {
        guard !isSameSiteObservation(observation) else { return nil }
        let requestETLDp1 = tld.eTLDplus1(forStringURL: observation.url) ?? observation.url
        let entity = mainTrackerData.findEntity(forHost: requestETLDp1)
            ?? Entity(displayName: requestETLDp1, domains: nil, prevalence: nil)
        let mainResolver = TrackerResolver(tds: mainTrackerData,
                                           unprotectedSites: unprotectedSites,
                                           tempList: tempList,
                                           tld: tld)
        let isAffiliated = mainResolver.isPageAffiliatedWithTrackerEntity(
            pageUrlString: observation.pageUrl, trackerEntity: entity)
        guard !isAffiliated else { return nil }
        return DetectedRequest(url: observation.url,
                               eTLDplus1: requestETLDp1,
                               knownTracker: nil,
                               entity: entity,
                               state: .allowed(reason: .otherThirdPartyRequest),
                               pageUrl: observation.pageUrl)
    }

    // MARK: - Private

    /// Multi-TDS classification mirroring the legacy ContentBlockerRulesUserScript loop.
    ///
    /// 1. Try each supplementary TDS (CTL, ad-attribution) with ad-click vendor.
    ///    If any returns blocked, use it immediately.
    /// 2. Fall back to the main TDS without vendor.
    /// 3. Main result overwrites non-blocked supplementary candidates (matching legacy behavior).
    ///    This is correct because the splitter removes attribution trackers from main TDS,
    ///    so main returns nil for those URLs and the supplementary candidate survives.
    private func classifyUrl(_ urlString: String,
                             pageUrlString: String,
                             resourceType: String,
                             adClickAttributionVendor: String?) -> DetectedRequest? {
        var candidate: DetectedRequest?

        for trackerData in supplementaryTrackerData {
            let resolver = TrackerResolver(tds: trackerData,
                                           unprotectedSites: unprotectedSites,
                                           tempList: tempList,
                                           tld: tld,
                                           adClickAttributionVendor: adClickAttributionVendor)
            if let tracker = resolver.trackerFromUrl(urlString,
                                                     pageUrlString: pageUrlString,
                                                     resourceType: resourceType,
                                                     potentiallyBlocked: contentBlockingEnabled) {
                if tracker.isBlocked {
                    return tracker
                }
                candidate = tracker
            }
        }

        let mainResolver = TrackerResolver(tds: mainTrackerData,
                                           unprotectedSites: unprotectedSites,
                                           tempList: tempList,
                                           tld: tld)
        if let tracker = mainResolver.trackerFromUrl(urlString,
                                                     pageUrlString: pageUrlString,
                                                     resourceType: resourceType,
                                                     potentiallyBlocked: contentBlockingEnabled) {
            candidate = tracker
        }

        return candidate
    }
}
