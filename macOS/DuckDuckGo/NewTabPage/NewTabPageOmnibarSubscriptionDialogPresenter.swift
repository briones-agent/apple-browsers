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

import AIChat
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

    func showSubscriptionUpsellDialog() async {
        makeUpsellDialog(userTier: await resolveUserTier()).show()
    }

    func showSubscriptionUpgradeDialog() {
        makeUpgradeDialog().show()
    }

    /// Split from `showSubscriptionUpsellDialog()` so tests can exercise `onSubscribe`/
    /// `onHaveSubscription` without `ModalView.show()`. Fires only for free users, so title/message
    /// stay generic; the primary button follows free-trial eligibility, but only when `userTier` is
    /// actually `.free` — StoreKit trial eligibility is independent of subscription tier, so an
    /// existing subscriber could otherwise still read as trial-eligible.
    func makeUpsellDialog(userTier: AIChatUserTier) -> AIChatSubscriptionUpsellDialog {
        let primaryButtonText = (userTier == .free && subscriptionManager.isUserEligibleForFreeTrial())
            ? UserText.aiChatSubscriptionUpsellDialogTryForFreeButton
            : UserText.aiChatSubscriptionUpsellDialogUpgradeButton
        return makeDialog(primaryButtonText: primaryButtonText) { [coordinator] in
            coordinator.navigateToSubscriptionPurchase(origin: SubscriptionFunnelOrigin.newTabPageOmnibar.rawValue, featurePage: Self.featurePage)
            Self.firePixel(flowType: "purchase")
        }
    }

    /// Fires only for an existing Plus subscriber gated to Pro — distinct title/message from the
    /// free-tier dialog, and no "I Have a Subscription" button since that doesn't apply here.
    func makeUpgradeDialog() -> AIChatSubscriptionUpsellDialog {
        makeDialog(
            title: UserText.aiChatSubscriptionUpsellDialogProTitle,
            message: UserText.aiChatSubscriptionUpsellDialogProMessage,
            primaryButtonText: UserText.aiChatSubscriptionUpsellDialogUpgradeButton,
            showsHaveSubscriptionButton: false
        ) { [coordinator] in
            coordinator.navigateToSubscriptionPlans(origin: SubscriptionFunnelOrigin.newTabPageOmnibar.rawValue, featurePage: Self.featurePage)
            Self.firePixel(flowType: "upgrade")
        }
    }

    private func makeDialog(
        title: String? = nil,
        message: String? = nil,
        primaryButtonText: String,
        showsHaveSubscriptionButton: Bool = true,
        onSubscribe: @escaping () -> Void
    ) -> AIChatSubscriptionUpsellDialog {
        var dialog = AIChatSubscriptionUpsellDialog()
        if let title { dialog.title = title }
        if let message { dialog.message = message }
        dialog.primaryButtonText = primaryButtonText
        dialog.showsHaveSubscriptionButton = showsHaveSubscriptionButton
        dialog.onSubscribe = onSubscribe
        dialog.onHaveSubscription = { [coordinator] in
            coordinator.navigateToSubscriptionActivation()
        }
        return dialog
    }

    /// Mirrors `NewTabPageOmnibarModelsProvider.resolveUserTier()` — re-resolved here rather than
    /// shared, since the two run at unrelated times (model fetch vs. dialog presentation) and a
    /// cached value from one could be stale for the other.
    private func resolveUserTier() async -> AIChatUserTier {
        do {
            guard let subscription = try await subscriptionManager.getSubscription(),
                  subscription.isActive else { return .free }
            switch subscription.tier {
            case .plus: return .plus
            case .pro: return .pro
            case .none: return .free
            }
        } catch {
            return .free
        }
    }

    private static func firePixel(flowType: String) {
        PixelKit.fire(
            AIChatPixel.aiChatNtpSubscriptionUpsellTriggered(flowType: flowType),
            frequency: .dailyAndCount,
            includeAppVersionParameter: true
        )
    }
}
