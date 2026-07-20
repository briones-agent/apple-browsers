//
//  NewTabPageOmnibarSubscriptionDialogPresenter.swift
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

import NewTabPage
import PixelKit
import Subscription

/// Presents the shared `AIChatSubscriptionUpsellDialog` for the NTP omnibar's upsell/upgrade messages.
/// Unlike the address bar's `AIChatOmnibarSubscriptionUpsellPresenter`, the web already knows which
/// flow to use (from a gated item's own `upsell` field) and calls the matching message directly —
/// no `requiredTier`/`userTier` to route from, so this skips `routeGatedSelection` entirely.
@MainActor
final class NewTabPageOmnibarSubscriptionDialogPresenter: NewTabPageOmnibarSubscriptionDialogPresenting {

    private static let featurePage = "duckai"

    private let coordinator: SubscriptionNavigationCoordinator
    private let subscriptionManager: any SubscriptionManager

    init(coordinator: SubscriptionNavigationCoordinator, subscriptionManager: any SubscriptionManager) {
        self.coordinator = coordinator
        self.subscriptionManager = subscriptionManager
    }

    func showSubscriptionUpsellDialog() {
        makeUpsellDialog().show()
    }

    func showSubscriptionUpgradeDialog() {
        makeUpgradeDialog().show()
    }

    /// Split from `showSubscriptionUpsellDialog()` so tests can exercise `onSubscribe`/
    /// `onHaveSubscription` without `ModalView.show()`. Fires only for free users, so title/message
    /// stay generic; the primary button follows free-trial eligibility.
    func makeUpsellDialog() -> AIChatSubscriptionUpsellDialog {
        var dialog = AIChatSubscriptionUpsellDialog()
        dialog.primaryButtonText = subscriptionManager.isUserEligibleForFreeTrial()
            ? UserText.aiChatSubscriptionUpsellDialogTryForFreeButton
            : UserText.aiChatSubscriptionUpsellDialogUpgradeButton
        dialog.onSubscribe = { [coordinator] in
            coordinator.navigateToSubscriptionPurchase(origin: SubscriptionFunnelOrigin.newTabPageOmnibar.rawValue, featurePage: Self.featurePage)
            Self.firePixel(flowType: "purchase")
        }
        dialog.onHaveSubscription = { [coordinator] in
            coordinator.navigateToSubscriptionActivation()
        }
        return dialog
    }

    /// Fires only for an existing Plus subscriber gated to Pro — distinct title/message from the
    /// free-tier dialog, and no "I Have a Subscription" button since that doesn't apply here.
    func makeUpgradeDialog() -> AIChatSubscriptionUpsellDialog {
        var dialog = AIChatSubscriptionUpsellDialog()
        dialog.title = UserText.aiChatSubscriptionUpsellDialogProTitle
        dialog.message = UserText.aiChatSubscriptionUpsellDialogProMessage
        dialog.primaryButtonText = UserText.aiChatSubscriptionUpsellDialogUpgradeButton
        dialog.showsHaveSubscriptionButton = false
        dialog.onSubscribe = { [coordinator] in
            coordinator.navigateToSubscriptionPlans(origin: SubscriptionFunnelOrigin.newTabPageOmnibar.rawValue, featurePage: Self.featurePage)
            Self.firePixel(flowType: "upgrade")
        }
        // Dead in practice since showsHaveSubscriptionButton hides the button, but wired anyway to
        // match the address bar's own dialog builder, which sets it unconditionally.
        dialog.onHaveSubscription = { [coordinator] in
            coordinator.navigateToSubscriptionActivation()
        }
        return dialog
    }

    private static func firePixel(flowType: String) {
        PixelKit.fire(
            AIChatPixel.aiChatNtpSubscriptionUpsellTriggered(flowType: flowType),
            frequency: .dailyAndCount,
            includeAppVersionParameter: true
        )
    }
}
