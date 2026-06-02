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
import Foundation
import UIKit
import UserNotifications
import os.log
import Subscription

protocol SubscriptionExpirationReminderScheduling: AnyObject {
    /// Schedules a single local reminder firing `timeBeforeCancel` seconds before the active subscription's expiry/renewal date.
    /// Silently skips when the feature flag is off, permission is unavailable, `timeBeforeCancel <= 0`, the subscription has no expiry, or the computed fire date is in the past.
    /// Cancels any previously scheduled reminder with the same identifier before scheduling the new one.
    func scheduleReminder(timeBeforeCancel: TimeInterval) async
}

final class DefaultSubscriptionExpirationReminderScheduler: SubscriptionExpirationReminderScheduling {

    static let notificationIdentifier = "com.duckduckgo.subscriptions.expiration.reminder"

    private let subscriptionManager: SubscriptionManager
    private let isFeatureEnabled: () -> Bool
    private let notificationCenter: UNUserNotificationCenterRepresentable
    private let dateProvider: () -> Date
    private var cancellables: Set<AnyCancellable> = []

    init(subscriptionManager: SubscriptionManager,
         isFeatureEnabled: @escaping () -> Bool,
         notificationCenter: UNUserNotificationCenterRepresentable = UNUserNotificationCenter.current(),
         dateProvider: @escaping () -> Date = Date.init,
         notificationCenterObserver: NotificationCenter = .default) {
        self.subscriptionManager = subscriptionManager
        self.isFeatureEnabled = isFeatureEnabled
        self.notificationCenter = notificationCenter
        self.dateProvider = dateProvider

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
            return
        }

        guard let subscription = try? await subscriptionManager.getSubscription(forceRefresh: false),
              Self.statusWarrantsReminder(subscription.status) else {
            Logger.subscription.log("Expiration reminder skipped: subscription not in an active state for reminders")
            return
        }

        let fireDate = subscription.expiresOrRenewsAt.addingTimeInterval(-timeBeforeCancel)
        guard fireDate > dateProvider() else {
            Logger.subscription.log("Expiration reminder skipped: past fire date")
            return
        }

        notificationCenter.removePendingNotificationRequests(withIdentifiers: [Self.notificationIdentifier])

        // TODO: Revisit after copy finalized
        let content = UNMutableNotificationContent()
        content.title = "Your Privacy Pro subscription is ending soon"
        content.body = "Tap to review your subscription and stay protected."
        content.categoryIdentifier = Self.notificationIdentifier

        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: fireDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(identifier: Self.notificationIdentifier, content: content, trigger: trigger)

        do {
            try await notificationCenter.add(request)
            Logger.subscription.log("Expiration reminder scheduled for \(fireDate, privacy: .public)")
        } catch {
            Logger.subscription.error("Failed to schedule expiration reminder: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Cancels the pending reminder unless the subscription is in an active state.
    /// A thrown error (e.g. transient network failure) leaves the reminder alone; a confirmed inactive/missing subscription cancels it.
    @MainActor
    private func cancelReminderIfInactive(forceRefresh: Bool) async {
        let pending = await notificationCenter.pendingNotificationRequests()
        guard pending.contains(where: { $0.identifier == Self.notificationIdentifier }) else { return }

        let subscription: DuckDuckGoSubscription?
        do {
            subscription = try await subscriptionManager.getSubscription(forceRefresh: forceRefresh)
        } catch {
            Logger.subscription.log("Skipping expiration-reminder check: \(error.localizedDescription, privacy: .public)")
            return
        }

        if let status = subscription?.status, Self.statusWarrantsReminder(status) {
            return
        }
        notificationCenter.removePendingNotificationRequests(withIdentifiers: [Self.notificationIdentifier])
    }

    private static func statusWarrantsReminder(_ status: DuckDuckGoSubscription.Status) -> Bool {
        switch status {
        case .autoRenewable, .notAutoRenewable, .gracePeriod: return true
        case .inactive, .expired, .unknown: return false
        }
    }
}
