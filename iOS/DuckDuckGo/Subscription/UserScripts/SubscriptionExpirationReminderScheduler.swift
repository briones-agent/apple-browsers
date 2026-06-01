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
    /// Schedules a single local reminder firing `daysBeforeCancel` days before the active subscription's expiry/renewal date.
    /// Silently skips when the feature flag is off, permission is unavailable, `daysBeforeCancel <= 0`, the subscription has no expiry, or the computed fire date is in the past.
    /// Cancels any previously scheduled reminder with the same identifier before scheduling the new one.
    func scheduleReminder(daysBeforeCancel: Int) async
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

        // In-app subscription operations post .subscriptionDidChange after updating the cache;
        // we can trust the cache and skip the network call.
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

    func scheduleReminder(daysBeforeCancel: Int) async {
        guard isFeatureEnabled() else {
            Logger.subscription.log("Expiration reminder skipped: feature flag off")
            return
        }

        guard daysBeforeCancel > 0 else {
            Logger.subscription.log("Expiration reminder skipped: non-positive daysBeforeCancel \(daysBeforeCancel, privacy: .public)")
            return
        }

        // Only schedule when the user has explicitly tapped Allow. .provisional silently routes to
        // Notification Center with no banner, and .ephemeral is an App Clip state — neither would
        // produce the visible reminder the user opted in for.
        guard await notificationCenter.authorizationStatus() == .authorized else {
            Logger.subscription.log("Expiration reminder skipped: notifications not explicitly authorized")
            return
        }

        guard let subscription = try? await subscriptionManager.getSubscription(forceRefresh: false), subscription.isActive else {
            Logger.subscription.log("Expiration reminder skipped: no active subscription available")
            return
        }

        guard let fireDate = Calendar.current.date(byAdding: .day, value: -daysBeforeCancel, to: subscription.expiresOrRenewsAt),
              fireDate > dateProvider() else {
            Logger.subscription.log("Expiration reminder skipped: invalid or past fire date")
            return
        }

        notificationCenter.removePendingNotificationRequests(withIdentifiers: [Self.notificationIdentifier])

        // Copy taken from the tech spec; subject to product/copy review before launch and likely to be localized.
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

    /// Cancels the pending reminder when the subscription is no longer in a state that warrants a reminder.
    /// Skips work entirely when no reminder is queued — most users will never opt in.
    /// Per spec, `.autoRenewable`, `.notAutoRenewable`, and `.gracePeriod` are the only statuses considered active for this purpose.
    private func cancelReminderIfInactive(forceRefresh: Bool) async {
        let pending = await notificationCenter.pendingNotificationRequests()
        guard pending.contains(where: { $0.identifier == Self.notificationIdentifier }) else { return }

        let subscription = try? await subscriptionManager.getSubscription(forceRefresh: forceRefresh)
        if let status = subscription?.status {
            switch status {
            case .autoRenewable, .notAutoRenewable, .gracePeriod:
                return
            case .inactive, .expired, .unknown:
                break
            }
        }
        notificationCenter.removePendingNotificationRequests(withIdentifiers: [Self.notificationIdentifier])
    }
}
