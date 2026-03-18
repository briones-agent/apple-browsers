//
//  SubscriptionPromoCoordinator.swift
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

import BrowserServicesKit
import Core
import Foundation
import PrivacyConfig
import Subscription

/// Coordinates the subscription promotion launch sheet for users who skipped onboarding.
///
/// Encapsulates eligibility checking, CTA/dismiss handling, and pixel firing.
/// Uses only stable, synchronous signals for eligibility — no dependency on async product availability.
protocol SubscriptionPromoCoordinating: AnyObject {
    func shouldPresentLaunchPrompt() -> Bool
    func markLaunchPromptPresented()
    func promoTitle() -> String
    func proceedButtonText() -> String
    func promoMessage() -> String
    func handleCTAAction()
    func handleDismissAction()
}

final class SubscriptionPromoCoordinator: SubscriptionPromoCoordinating {
    private let onboardingPromotionHelper: OnboardingSubscriptionPromotionHelping
    private let daxDialogsSettings: DaxDialogsSettings
    private let featureFlagger: FeatureFlagger
    private let tutorialSettings: TutorialSettings
    private let statisticsStore: StatisticsStore
    private let pixelHandler: (Pixel.Event, [String: String]) -> Void

    init(
        onboardingPromotionHelper: OnboardingSubscriptionPromotionHelping,
        daxDialogsSettings: DaxDialogsSettings = DefaultDaxDialogsSettings(),
        featureFlagger: FeatureFlagger = AppDependencyProvider.shared.featureFlagger,
        tutorialSettings: TutorialSettings = DefaultTutorialSettings(),
        statisticsStore: StatisticsStore = StatisticsUserDefaults(),
        pixelHandler: @escaping (Pixel.Event, [String: String]) -> Void = { Pixel.fire(pixel: $0, withAdditionalParameters: $1) }
    ) {
        self.onboardingPromotionHelper = onboardingPromotionHelper
        self.daxDialogsSettings = daxDialogsSettings
        self.featureFlagger = featureFlagger
        self.tutorialSettings = tutorialSettings
        self.statisticsStore = statisticsStore
        self.pixelHandler = pixelHandler
    }

    func shouldPresentLaunchPrompt() -> Bool {
        guard !daxDialogsSettings.subscriptionPromotionDialogShown else {
            Logger.subscription.debug("[Subscription Promo] Promo already shown, skipping.")
            return false
        }
        // Use stable signals only — no dependency on async product availability.
        // The full shouldDisplayForSkippedOnboarding check includes hasAppStoreProductsAvailable,
        // which may not be loaded yet at launch time when the modal prompt system runs.
        let shouldShow = featureFlagger.isFeatureOn(for: FeatureFlag.subscriptionPromoForReinstallers, allowOverride: true)
            && featureFlagger.isFeatureOn(for: FeatureFlag.privacyProOnboardingPromotion, allowOverride: true)
            && tutorialSettings.hasSkippedOnboarding
            && hasCooldownPassed()
        Logger.subscription.debug("[Subscription Promo] shouldPresentLaunchPrompt: \(shouldShow)")
        return shouldShow
    }

    private func hasCooldownPassed() -> Bool {
        guard let installDate = statisticsStore.installDate else { return false }
        let daysSinceInstall = Calendar.current.dateComponents([.day], from: installDate, to: Date()).day ?? 0
        return daysSinceInstall >= OnboardingSubscriptionPromotionHelper.skipOnboardingCooldownDays
    }

    func markLaunchPromptPresented() {
        daxDialogsSettings.subscriptionPromotionDialogShown = true
        Logger.subscription.debug("[Subscription Promo] Launch prompt marked as presented.")
        onboardingPromotionHelper.fireImpressionPixel()
    }

    func promoTitle() -> String {
        UserText.SubscriptionPromotionOnboarding.Promo.delayedTitle
    }

    func proceedButtonText() -> String {
        onboardingPromotionHelper.proceedButtonText
    }

    func promoMessage() -> String {
        let text = UserText.SubscriptionPromotionOnboarding.Promo.self
        return String(format: text.messageFormat, text.optionalSubscriptionBold, text.vpnBold, text.privateAIBold)
    }

    func handleCTAAction() {
        Logger.subscription.debug("[Subscription Promo] CTA action triggered.")
        onboardingPromotionHelper.fireTapPixel()

        let comps = onboardingPromotionHelper.redirectURLComponents()
        let deepLink = SettingsViewModel.SettingsDeepLinkSection.subscriptionFlow(redirectURLComponents: comps)
        NotificationCenter.default.post(name: .settingsDeepLinkNotification, object: deepLink)
    }

    func handleDismissAction() {
        Logger.subscription.debug("[Subscription Promo] Dismiss action triggered.")
        onboardingPromotionHelper.fireDismissPixel()
    }
}
