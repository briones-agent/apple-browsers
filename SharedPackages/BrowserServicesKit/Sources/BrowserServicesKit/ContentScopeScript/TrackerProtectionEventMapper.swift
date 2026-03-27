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
import TrackerRadarKit

/// Classifies raw C-S-S resource observations into DetectedRequest using native TrackerResolver.
///
/// C-S-S is a raw resource observer — it sends `{url, resourceType, potentiallyBlocked, pageUrl}`.
/// This mapper runs TrackerResolver with full in-memory TDS to produce authoritative classification.
public struct TrackerProtectionEventMapper {

    private let tld: TLD
    private let trackerResolver: TrackerResolver

    public init(tld: TLD, trackerResolver: TrackerResolver) {
        self.tld = tld
        self.trackerResolver = trackerResolver
    }

    // MARK: - ResourceObservation classification

    /// Classify a raw resource observation from C-S-S using native TrackerResolver.
    /// Returns nil if the URL is not a known tracker.
    public func classifyResource(_ observation: TrackerProtectionSubfeature.ResourceObservation) -> DetectedRequest? {
        return trackerResolver.trackerFromUrl(
            observation.url,
            pageUrlString: observation.pageUrl,
            resourceType: observation.resourceType,
            potentiallyBlocked: observation.potentiallyBlocked)
    }

    // MARK: - SurrogateInjection mapping

    /// Map a surrogate injection signal to a DetectedRequest.
    /// Uses TrackerResolver to classify the blocked URL.
    public func classifySurrogate(_ surrogate: TrackerProtectionSubfeature.SurrogateInjection) -> DetectedRequest? {
        return trackerResolver.trackerFromUrl(
            surrogate.url,
            pageUrlString: surrogate.pageUrl,
            resourceType: "script",
            potentiallyBlocked: true)
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
}
