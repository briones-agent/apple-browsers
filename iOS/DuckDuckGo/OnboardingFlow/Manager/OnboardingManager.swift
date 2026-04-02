//
//  OnboardingManager.swift
//  DuckDuckGo
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

import AVKit
import BrowserServicesKit
import Core
import PrivacyConfig
import Onboarding

enum OnboardingUserType: String, Equatable, CaseIterable, CustomStringConvertible {
    case notSet
    case newUser
    case returningUser

    var description: String {
        switch self {
        case .notSet:
            "Not Set - Using Real Value"
        case .newUser:
            "New User"
        case .returningUser:
            "Returning User"
        }
    }
}

protocol OnboardingAddToDockVisibilityManager {
    var userHasSeenAddToDockPromoDuringOnboarding: Bool { get }
}

protocol OnboardingExperienceManager {
    func configureOnboardingFlow(from action: AppAction?)
}

typealias OnboardingManaging = OnboardingFlowEvaluating & OnboardingStepsProvider & OnboardingAddToDockVisibilityManager & OnboardingExperienceManager

final class OnboardingManager {
    private let onboardingFlowEvaluator: OnboardingFlowEvaluating
    private var appDefaults: OnboardingDebugAppSettings
    private let featureFlagger: FeatureFlagger
    private let variantManager: VariantManager
    private let isIphone: Bool
    private let tutorialSettings: TutorialSettings

    private let iPhoneFlowWithoutSearchExperience: [OnboardingIntroStep] = [
        .browserComparison,
        .addToDockPromo,
        .appIconSelection,
        .addressBarPositionSelection
    ]
    private let iPhoneFlowWithSearchExperience: [OnboardingIntroStep] = [
        .browserComparison,
        .addToDockPromo,
        .appIconSelection,
        .addressBarPositionSelection,
        .searchExperienceSelection
    ]
    private let iPadFlowWithoutSearchExperience: [OnboardingIntroStep] = [.browserComparison, .appIconSelection]
    private let iPadFlowWithSearchExperience: [OnboardingIntroStep] = [.browserComparison, .appIconSelection, .searchExperienceSelection]

    private let duckAIFlowSteps: [OnboardingIntroStep] = [.searchExperienceSelection, .browserComparison]

    var isNewUser: Bool {
#if DEBUG || ALPHA
        // If debug or alpha build enable testing the experiment with cohort override.
        // If running unit tests do not override behaviour.
        switch appDefaults.onboardingUserType {
        case .notSet:
            variantManager.currentVariant?.name != VariantIOS.returningUser.name
        case .newUser:
            true
        case .returningUser:
            false
        }
#else
        variantManager.currentVariant?.name != VariantIOS.returningUser.name
#endif
    }

    init(
        onboardingFlowEvaluator: OnboardingFlowEvaluating = OnboardingFlowEvaluator(),
        appDefaults: OnboardingDebugAppSettings = AppDependencyProvider.shared.appSettings,
        featureFlagger: FeatureFlagger = AppDependencyProvider.shared.featureFlagger,
        variantManager: VariantManager = DefaultVariantManager(),
        isIphone: Bool = UIDevice.current.userInterfaceIdiom == .phone,
        tutorialSettings: TutorialSettings = DefaultTutorialSettings()
    ) {
        self.onboardingFlowEvaluator = onboardingFlowEvaluator
        self.appDefaults = appDefaults
        self.featureFlagger = featureFlagger
        self.variantManager = variantManager
        self.isIphone = isIphone
        self.tutorialSettings = tutorialSettings
    }

    func newUserSteps(isIphone: Bool) -> [OnboardingIntroStep] {
        let introStep = OnboardingIntroStep.introDialog(isReturningUser: false)
        return [introStep] + steps(isIphone: isIphone)
    }

    func returningUserSteps(isIphone: Bool) -> [OnboardingIntroStep] {
        let introStep = OnboardingIntroStep.introDialog(isReturningUser: true)
        return [introStep] + steps(isIphone: isIphone)
    }

    private func steps(isIphone: Bool) -> [OnboardingIntroStep] {
        isIphone ? iPhoneFlow() : iPadFlow()
    }

    private func iPhoneFlow() -> [OnboardingIntroStep] {
        if featureFlagger.isFeatureOn(.onboardingSearchExperience) {
            return iPhoneFlowWithSearchExperience
        } else {
            return iPhoneFlowWithoutSearchExperience
        }
    }

    private func iPadFlow() -> [OnboardingIntroStep] {
        return iPadFlowWithoutSearchExperience
    }
}

// MARK: - New User Debugging

protocol OnboardingNewUserProviderDebugging: AnyObject {
    var onboardingUserTypeDebugValue: OnboardingUserType { get set }
}

extension OnboardingManager: OnboardingNewUserProviderDebugging {

    var onboardingUserTypeDebugValue: OnboardingUserType {
        get {
            appDefaults.onboardingUserType
        }
        set {
            appDefaults.onboardingUserType = newValue
        }
    }
}

// MARK: - Onboarding Steps Provider

enum OnboardingIntroStep: Equatable {
    case introDialog(isReturningUser: Bool)
    case browserComparison
    case appIconSelection
    case addToDockPromo
    case addressBarPositionSelection
    case searchExperienceSelection
    case duckAIQueryExperimentSelection
}

protocol OnboardingStepsProvider: AnyObject {
    var onboardingSteps: [OnboardingIntroStep] { get }
}

extension OnboardingManager: OnboardingStepsProvider {

    var onboardingSteps: [OnboardingIntroStep] {
        onboardingStepsForCurrentFlow()
    }

}

extension OnboardingManager: OnboardingAddToDockVisibilityManager {

    var userHasSeenAddToDockPromoDuringOnboarding: Bool {
        onboardingSteps.contains(.addToDockPromo)
    }
    
}

extension OnboardingManager: OnboardingFlowEvaluating {

    func evaluateOnboardingFlow(from url: URL?) -> OnboardingFlowType {
        onboardingFlowEvaluator.evaluateOnboardingFlow(from: url)
    }

    func isOnboardingURL(_ url: URL) -> Bool {
        onboardingFlowEvaluator.isOnboardingURL(url)
    }

}

extension OnboardingManager: OnboardingExperienceManager {

    /// Configure the onboarding flow based on the app action (e.g., deep link)
    /// This should be called early in the app lifecycle, before onboarding is presented
    func configureOnboardingFlow(from action: AppAction?) {
        // If onboarding has already been completed or skipped return
        guard !tutorialSettings.hasSeenOnboarding || !tutorialSettings.hasSkippedOnboarding else { return }
        // If onboarding type has been previously set, skip it. This will avoid starting a different onboarding experience if the user quits the onboarding mid journey and launches the app again.
        guard tutorialSettings.onboardingFlowType == nil else { return }

        switch action {
        case .some(.openURL(let url)):
            tutorialSettings.onboardingFlowType = onboardingFlowEvaluator.evaluateOnboardingFlow(from: url)
        default:
            tutorialSettings.onboardingFlowType = .standard
        }
    }

    /// Get the appropriate steps for the current flow type
    func onboardingStepsForCurrentFlow() -> [OnboardingIntroStep] {
        switch tutorialSettings.onboardingFlowType {
        case .none, .standard:
            // Existing logic
            if isNewUser {
                return newUserSteps(isIphone: isIphone)
            } else {
                return returningUserSteps(isIphone: isIphone)
            }
        case let .tailored(type):
            return tailoredOnboardingSteps(for: type)
        }
    }

    private func tailoredOnboardingSteps(for type: OnboardingFlowType.TailoredType) -> [OnboardingIntroStep] {
        switch type {
        case .duckAI: return duckAIFlowSteps
        }
    }

}
