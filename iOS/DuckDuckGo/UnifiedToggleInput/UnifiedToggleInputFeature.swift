//
//  UnifiedToggleInputFeature.swift
//  DuckDuckGo
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
import Common
import FoundationExtensions
import Core
import PrivacyConfig

protocol UnifiedToggleInputFeatureProviding {
    var isAvailable: Bool { get }
    /// When true, the UTI hides the Search↔Duck.ai toggle on Duck.ai tabs regardless of the
    /// user's toggle-enabled setting. Backed by `FeatureFlag.aiChatTabHideToggle`.
    ///
    /// No protocol-extension default: every conformer (including test mocks) must declare an
    /// explicit value so test coverage isn't silently masked by a convenient fallback.
    var isToggleHiddenOnDuckAITab: Bool { get }
}

struct UnifiedToggleInputFeature: UnifiedToggleInputFeatureProviding {

    private static let isFeatureFlagEnabledKey = "com.duckduckgo.unifiedToggleInput.session.enabled"
    private static let isToggleHiddenOnDuckAITabKey = "com.duckduckgo.unifiedToggleInput.aiChatTabHideToggle.session.enabled"

    private static let controlCohortID = FeatureFlag.DuckAIQueryExperimentCohort.control.rawValue

    private static let nonControlCohortExcludedExperimentIDs: Set<SubfeatureID> = [
        AIChatSubfeature.onboardingDuckAIQueryExperiment.rawValue,
        AIChatSubfeature.onboardingDuckAIQueryTrackersDemoExperiment.rawValue,
    ]

    /// Snapshot the UTI availability decision once per session, and record the sticky grant when the
    /// device first becomes available. Call early at launch, before any consumer reads `isAvailable` /
    /// `isToggleHiddenOnDuckAITab`.
    ///
    /// Gate precedence:
    /// a. `unifiedToggleInput` off → off for everyone (primary kill switch wins, even over a grant).
    /// b. already granted → on (grandfathered; the grant is never revoked).
    /// c. `!includeNewUsers` && the user is a new install → off.
    /// d. otherwise → on, and the grant is recorded (gated on the device actually being able to show UTI).
    ///
    /// `unifiedToggleInputIncludeNewUsers` is on by default in code, so an absent/unfetched config keeps
    /// new users included; shipping `{state: "disabled"}` stops only future new installs.
    static func resolve(using featureFlagger: FeatureFlagger,
                        userTypeProvider: UnifiedToggleInputUserTypeProviding,
                        grantStore: UnifiedToggleInputGrantStoring,
                        devicePlatform: DevicePlatformProviding.Type = DevicePlatform.self) {
        let gateDecision: Bool
        if !featureFlagger.isFeatureOn(.unifiedToggleInput) {
            gateDecision = false // (a) primary kill switch wins; the sticky grant is deliberately left untouched.
        } else if grantStore.hasGrantedUnifiedToggleInput {
            gateDecision = true // (b) grandfathered.
        } else if !featureFlagger.isFeatureOn(.unifiedToggleInputIncludeNewUsers) && userTypeProvider.isNewUser {
            gateDecision = false // (c) lever pulled and this is a new install.
        } else {
            gateDecision = true // (d) returning/existing/undetermined, or new users still included.
        }

        // Record the grant only when this device would actually present UTI, so the read-time device
        // gate and the grant decision can never diverge.
        if gateDecision && isDeviceEligible(featureFlagger: featureFlagger, devicePlatform: devicePlatform) {
            grantStore.recordGrant()
        }

        UserDefaults.app.set(gateDecision, forKey: isFeatureFlagEnabledKey)
        UserDefaults.app.set(featureFlagger.isFeatureOn(.aiChatTabHideToggle), forKey: isToggleHiddenOnDuckAITabKey)
    }

    /// Device/cohort eligibility applied live at read time, and again when deciding whether to record a
    /// grant. UTI is iPhone-only and excludes non-control cohorts of the Duck.ai onboarding experiments.
    private static func isDeviceEligible(featureFlagger: FeatureFlagger, devicePlatform: DevicePlatformProviding.Type) -> Bool {
        devicePlatform.isIphone && !isInExcludedExperimentCohort(featureFlagger)
    }

    private static func isInExcludedExperimentCohort(_ featureFlagger: FeatureFlagger) -> Bool {
        nonControlCohortExcludedExperimentIDs.contains { experimentID in
            guard let cohortID = featureFlagger.allActiveExperiments[experimentID]?.cohortID else {
                return false
            }
            return cohortID != controlCohortID
        }
    }

    private let featureFlagger: FeatureFlagger
    private let devicePlatform: DevicePlatformProviding.Type

    init(featureFlagger: FeatureFlagger = AppDependencyProvider.shared.featureFlagger,
         devicePlatform: DevicePlatformProviding.Type = DevicePlatform.self) {
        self.featureFlagger = featureFlagger
        self.devicePlatform = devicePlatform
    }

    private var isGateDecisionEnabled: Bool {
        UserDefaults.app.bool(forKey: Self.isFeatureFlagEnabledKey)
    }

    var isAvailable: Bool {
        isGateDecisionEnabled && Self.isDeviceEligible(featureFlagger: featureFlagger, devicePlatform: devicePlatform)
    }

    var isToggleHiddenOnDuckAITab: Bool {
        UserDefaults.app.bool(forKey: Self.isToggleHiddenOnDuckAITabKey)
    }
}
