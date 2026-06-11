//
//  SubscriptionExpirationReminderScheduler.swift
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

import Combine
import Core
import Foundation
import UIKit
import UserNotifications
import os.log
import Subscription

protocol SubscriptionExpirationReminderScheduling: AnyObject {
    /// Schedules a single local reminder firing `timeBeforeCancel` seconds before the active subscription's expiry/renewal date.
    /// Silently skips when the feature flag is off, permission is unavailable, `timeBeforeCancel <= 0`, the subscription is not on a free trial, the subscription has no expiry, or the computed fire date is in the past.
    /// Cancels any previously scheduled reminder with the same identifier before scheduling the new one.
    func scheduleReminder(timeBeforeCancel: TimeInterval) async
}

final class DefaultSubscriptionExpirationReminderScheduler: SubscriptionExpirationReminderScheduling {

    static let notificationIdentifier = "com.duckduckgo.subscriptions.expiration.reminder"

    private let subscriptionManager: SubscriptionManager
    private let isFeatureEnabled: () -> Bool
    private let notificationCenter: UNUserNotificationCenterRepresentable
    private let dateProvider: () -> Date
    private let pixelFiring: any PixelFiring.Type
    private var cancellables: Set<AnyCancellable> = []

    init(subscriptionManager: SubscriptionManager,
         isFeatureEnabled: @escaping () -> Bool,
         notificationCenter: UNUserNotificationCenterRepresentable = UNUserNotificationCenter.current(),
         dateProvider: @escaping () -> Date = Date.init,
         notificationCenterObserver: NotificationCenter = .default,
         pixelFiring: any PixelFiring.Type = Pixel.self) {
        self.subscriptionManager = subscriptionManager
        self.isFeatureEnabled = isFeatureEnabled
        self.notificationCenter = notificationCenter
        self.dateProvider = dateProvider
        self.pixelFiring = pixelFiring

        // In-app subscription operations post .subscriptionDidChange after updating the cache.
        notificationCenterObserver.publisher(for: .subscriptionDidChange)
            .sink { [weak self] _ in
                Task { [weak self] in await self?.cancelReminderIfInactive(forceRefresh: false) }
            }
            .store(in: &cancellables)

        // External changes (App Store cancellation, billing failure) happen without our knowledge,
        // so re-read from the backend on every foreground.
        notificationCenterObserver.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                Task { [weak self] in await self?.cancelReminderIfInactive(forceRefresh: true) }
            }
            .store(in: &cancellables)
    }

    func scheduleReminder(timeBeforeCancel: TimeInterval) async {
        guard isFeatureEnabled() else { return }
        guard timeBeforeCancel > 0 else { return }

        guard await notificationCenter.authorizationStatus() == .authorized else {
            Logger.subscription.log("Expiration reminder skipped: notifications not explicitly authorized")
            pixelFiring.fire(.subscriptionExpirationReminderSkippedNoPermission, withAdditionalParameters: [:])
            return
        }

        guard let subscription = try? await subscriptionManager.getSubscription(forceRefresh: false),
              Self.subscriptionWarrantsReminder(subscription) else {
            Logger.subscription.log("Expiration reminder skipped: subscription does not warrant a reminder (must be active and on a free trial)")
            return
        }

        let fireDate = subscription.expiresOrRenewsAt.addingTimeInterval(-timeBeforeCancel)
        guard fireDate > dateProvider() else {
            Logger.subscription.log("Expiration reminder skipped: past fire date")
            return
        }

        notificationCenter.removePendingNotificationRequests(withIdentifiers: [Self.notificationIdentifier])

        // Register a category with .customDismissAction so the delegate is notified when the user
        // explicitly dismisses the reminder. No actions are added, so the notification's appearance
        // and behaviour are unchanged.
        // setNotificationCategories replaces the whole category set, so merge by identifier to
        // avoid discarding categories registered by other features.
        let category = UNNotificationCategory(identifier: Self.notificationIdentifier,
                                              actions: [],
                                              intentIdentifiers: [],
                                              options: [.customDismissAction])
        var categories = await notificationCenter.getNotificationCategories()
            .filter { $0.identifier != Self.notificationIdentifier }
        categories.insert(category)
        notificationCenter.setNotificationCategories(categories)

        // TODO: Revisit after copy finalized
        let content = UNMutableNotificationContent()
        content.title = "Your Privacy Pro subscription is ending soon"
        content.body = "Tap to review your subscription and stay protected."
        content.categoryIdentifier = Self.notificationIdentifier

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: fireDate.timeIntervalSince(dateProvider()), repeats: false)
        let request = UNNotificationRequest(identifier: Self.notificationIdentifier, content: content, trigger: trigger)

        do {
            try await notificationCenter.add(request)
            Logger.subscription.log("Expiration reminder scheduled for \(fireDate, privacy: .public)")
        } catch {
            Logger.subscription.error("Failed to schedule expiration reminder: \(error.localizedDescription, privacy: .public)")
            pixelFiring.fire(pixel: .subscriptionExpirationReminderSchedulingError,
                             error: error,
                             includedParameters: [.appVersion],
                             withAdditionalParameters: [:],
                             onComplete: { _ in })
        }
    }

    /// Cancels the pending reminder unless the subscription still warrants one (active status + on a free trial),
    /// or unconditionally when the feature flag is off (remote kill switch).
    /// A thrown error (e.g. transient network failure) leaves the reminder alone; a confirmed inactive/missing/no-longer-trial subscription cancels it.
    @MainActor
    private func cancelReminderIfInactive(forceRefresh: Bool) async {
        let pending = await notificationCenter.pendingNotificationRequests()
        guard pending.contains(where: { $0.identifier == Self.notificationIdentifier }) else { return }

        guard isFeatureEnabled() else {
            cancelPendingReminder()
            return
        }

        let subscription: DuckDuckGoSubscription?
        do {
            subscription = try await subscriptionManager.getSubscription(forceRefresh: forceRefresh)
        } catch {
            Logger.subscription.log("Skipping expiration-reminder check: \(error.localizedDescription, privacy: .public)")
            return
        }

        if let subscription, Self.subscriptionWarrantsReminder(subscription) {
            return
        }
        // Reached only when the subscription itself no longer warrants the reminder
        // (no subscription found, inactive/expired/unknown status, or the free-trial offer ended).
        // The feature-flag kill switch cancels and returns earlier, so it does not fire this pixel.
        pixelFiring.fire(.subscriptionExpirationReminderCancelled, withAdditionalParameters: [:])
        cancelPendingReminder()
    }

    @MainActor
    private func cancelPendingReminder() {
        notificationCenter.removePendingNotificationRequests(withIdentifiers: [Self.notificationIdentifier])
    }

    /// A subscription warrants a reminder iff its status is active AND it is on a free trial.
    private static func subscriptionWarrantsReminder(_ subscription: DuckDuckGoSubscription) -> Bool {
        switch subscription.status {
        case .autoRenewable, .notAutoRenewable, .gracePeriod:
            return subscription.hasActiveTrialOffer
        case .inactive, .expired, .unknown:
            return false
        }
    }
}
