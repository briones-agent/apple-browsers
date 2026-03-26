//
//  TrackerProtectionDataSource.swift
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

import Common
import Foundation
import os.log
import TrackerRadarKit

/// Source of tracker data for the C-S-S trackerProtection feature.
///
/// `trackerData` provides the full merged TDS for native classification.
/// `encodedTrackerData` provides the surrogate-filtered subset for JS injection.
/// These are separate datasets per the dataset contract (see ContentBlockerRulesManager.Rules).
public protocol TrackerProtectionDataSource {
    var trackerData: TrackerData? { get }
    var encodedTrackerData: String? { get }
}

/// Default implementation using `CompiledRuleListsSource` (typically `ContentBlockerRulesManager`).
///
/// On macOS, ClickToLoad rules are compiled into a separate rule list.
/// Pass the list name via `additionalRuleLists` so the merged tracker data
/// includes CTL rules (e.g. `block-ctl-fb`), making them visible to the
/// C-S-S TrackerResolver for blocking decisions and dashboard reporting.
public struct DefaultTrackerProtectionDataSource: TrackerProtectionDataSource {

    private let contentBlockingManager: CompiledRuleListsSource
    private let additionalRuleLists: [String]

    public init(contentBlockingManager: CompiledRuleListsSource,
                additionalRuleLists: [String] = []) {
        self.contentBlockingManager = contentBlockingManager
        self.additionalRuleLists = additionalRuleLists
    }

    public var trackerData: TrackerData? {
        mergedTrackerData()
    }

    /// Returns JSON-encoded surrogate-filtered tracker data for C-S-S surrogate injection.
    ///
    /// Uses `extractSurrogates` to include only trackers with surrogate rules,
    /// matching the dataset contract: full TDS for native classification,
    /// surrogate-filtered TDS for JavaScript.
    public var encodedTrackerData: String? {
        guard let data = mergedTrackerData() else {
            Logger.contentBlocking.warning("TrackerProtectionDataSource: no tracker data available")
            return nil
        }

        let surrogateTDS = ContentBlockerRulesManager.extractSurrogates(from: data)

        guard let encodedData = try? JSONEncoder().encode(surrogateTDS),
              let encodedString = String(data: encodedData, encoding: .utf8) else {
            Logger.contentBlocking.warning("TrackerProtectionDataSource: Failed to encode trackerData")
            return nil
        }

        return encodedString
    }

    /// Merge main TDS tracker data with any additional compiled rule lists
    /// (e.g. ClickToLoad).  Takes a single snapshot of `currentRules` to
    /// avoid torn reads while rules are recompiling.
    private func mergedTrackerData() -> TrackerData? {
        let rulesSnapshot = contentBlockingManager.currentRules
        guard let main = rulesSnapshot.first(where: {
            $0.name == DefaultContentBlockerRulesListsSource.Constants.trackerDataSetRulesListName
        }) else {
            Logger.contentBlocking.warning("TrackerProtectionDataSource: currentMainRules is nil")
            return nil
        }

        guard !additionalRuleLists.isEmpty else { return main.trackerData }

        var trackers = main.trackerData.trackers
        var entities = main.trackerData.entities
        var domains = main.trackerData.domains

        for name in additionalRuleLists {
            guard let rules = rulesSnapshot.first(where: { $0.name == name }) else { continue }
            trackers.merge(rules.trackerData.trackers) { _, new in new }
            entities.merge(rules.trackerData.entities) { _, new in new }
            domains.merge(rules.trackerData.domains) { _, new in new }
        }

        return TrackerData(trackers: trackers, entities: entities, domains: domains,
                           cnames: main.trackerData.cnames)
    }
}
