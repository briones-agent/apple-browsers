//
//  OnboardingFlowEvaluator.swift
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
import Onboarding
import enum Core.AppDeepLinkSchemes

final class OnboardingFlowEvaluator: OnboardingFlowEvaluating {

    func evaluateOnboardingFlow(from url: URL?) -> OnboardingFlowType {
        guard let url = url, isOnboardingURL(url) else { return .standard }

        // Extract the variant identifier from the URL
        // e.g., ddgOnboarding://privacy-focused -> "privacy-focused"
        guard let identifier = url.host, let tailoredType = OnboardingFlowType.TailoredType(rawValue: identifier) else { return .standard }

        return .tailored(tailoredType)
    }
    
    func isOnboardingURL(_ url: URL) -> Bool {
        url.scheme == AppDeepLinkSchemes.customOnboarding.rawValue
    }

}
