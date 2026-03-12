//
//  AppDependencies.swift
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
import AppKitExtensions
import AppUpdaterShared
import AttributedMetric
import AutoconsentStats
import BWManagementShared
import Bookmarks
import BrokenSitePrompt
import BrowserServicesKit
import Cocoa
import Combine
import Common
import Configuration
import ContentScopeScripts
import CoreData
import Crashes
import CrashReportingShared
import DataBrokerProtection_macOS
import DataBrokerProtectionCore
import DDGSync
import FeatureFlags
import Freemium
import History
import HistoryView
import Lottie
import MetricKit
import Network
import Networking
import NetworkProtectionIPC
import NewTabPage
import os.log
import Persistence
import PixelExperimentKit
import PixelKit
import PrivacyConfig
import PrivacyStats
import RemoteMessaging
import ServiceManagement
import Subscription
import SyncDataProviders
import UserNotifications
import Utilities
import VPN
import VPNAppState
import WebExtensions
import WebKit

struct AppDependencies {

    // MARK: - Stores

    struct Stores {
        let keyStore: EncryptionKeyStoring
        let keyValueStore: ThrowingKeyValueStoring
        let fileStore: FileStore
        let database: Database!
        let bookmarkDatabase: BookmarkDatabase
        var configurationStore: ConfigurationStore
    }

    // MARK: - FeatureFlags

    struct FeatureFlags {
        let featureFlagger: FeatureFlagger
        let internalUserDecider: InternalUserDecider
        let contentScopeExperimentsManager: ContentScopeExperimentsManaging
        let featureFlagOverridesPublishingHandler: FeatureFlagOverridesPublishingHandler<FeatureFlag>
    }

    // MARK: - Preferences

    struct Preferences {
        let appearancePreferences: AppearancePreferences
        let dataClearingPreferences: DataClearingPreferences
        let startupPreferences: StartupPreferences
        let defaultBrowserPreferences: DefaultBrowserPreferences
        let downloadsPreferences: DownloadsPreferences
        let searchPreferences: SearchPreferences
        let tabsPreferences: TabsPreferences
        let webTrackingProtectionPreferences: WebTrackingProtectionPreferences
        let cookiePopupProtectionPreferences: CookiePopupProtectionPreferences
        let aboutPreferences: AboutPreferences
        let accessibilityPreferences: AccessibilityPreferences
        let contentScopePreferences: ContentScopePreferences
        let aiChatPreferences: AIChatPreferences
    }

    // MARK: - Services

    /// Class (reference type) so mutations made by state handlers are visible through
    /// any copy of AppDependencies — including AppDelegate's snapshot taken during init().
    final class Services {
        var configurationManager: ConfigurationManager
        var configurationURLProvider: CustomConfigurationURLProviding
        let bookmarkManager: LocalBookmarkManager
        let historyCoordinator: HistoryCoordinator
        let faviconManager: FaviconManager
        let fireproofDomains: FireproofDomains
        let permissionManager: PermissionManager
        let downloadManager: FileDownloadManagerProtocol
        let downloadListCoordinator: DownloadListCoordinator
        let privacyStats: PrivacyStatsCollecting
        let autoconsentStats: AutoconsentStatsCollecting
        let remoteMessagingClient: RemoteMessagingClient!
        let activeRemoteMessageModel: ActiveRemoteMessageModel
        var syncService: DDGSyncing?
        var syncDataProviders: SyncDataProvidersSource?
        var syncErrorHandler: SyncErrorHandler
        let webCacheManager: WebCacheManager
        let crashReporting: any CrashReporting
        let watchdog: Watchdog
        let watchdogSleepMonitor: WatchdogSleepMonitor
        var autoClearHandler: AutoClearHandler!
        let privacyFeatures: AnyPrivacyFeatures
        let tld: TLD
        let autoconsentManagement: AutoconsentManagement
        let brokenSitePromptLimiter: BrokenSitePromptLimiter
        let notificationService: UserNotificationAuthorizationServicing
        let onboardingContextualDialogsManager: ContextualOnboardingDialogTypeProviding & ContextualOnboardingStateUpdater
        let defaultBrowserAndDockPromptService: DefaultBrowserAndDockPromptService
        let userChurnScheduler: UserChurnBackgroundActivityScheduler
        let bitwardenManager: BWManagement?
        let passwordManagerCoordinator: PasswordManagerCoordinator
        let attributedMetricManager: AttributedMetricManager
        let memoryUsageMonitor: MemoryUsageMonitor
        var memoryPressureReporter: MemoryPressureReporter?
        let memoryUsageThresholdReporter: MemoryUsageThresholdReporter
        var memoryUsageIntervalReporter: MemoryUsageIntervalReporter?
        let startupProfiler: StartupProfiler
        let duckPlayer: DuckPlayer
        let newTabPageCustomizationModel: NewTabPageCustomizationModel
        let vpnSettings: VPNSettings
        let freemiumDBPFeature: FreemiumDBPFeature
        let freemiumDBPPromotionViewCoordinator: FreemiumDBPPromotionViewCoordinator
        let blackFridayCampaignProvider: BlackFridayCampaignProviding
        let wideEvent: WideEventManaging
        let urlEventHandler: URLEventHandler
        let tabCrashAggregator: TabCrashAggregator
        let grammarFeaturesManager: GrammarFeaturesManager
        let webExtensionAvailability: WebExtensionAvailabilityProviding
        let aiChatSessionStore: AIChatSessionStoring
        let aiChatMenuConfiguration: AIChatMenuVisibilityConfigurable
        let visualizeFireSettingsDecider: VisualizeFireSettingsDecider
        var autoconsentEventCoordinator: AutoconsentEventCoordinator?
        var stateRestorationManager: AppStateRestorationManager!
        var appIconChanger: AppIconChanger!
        let launchOptionsHandler: LaunchOptionsHandler
        var updateController: UpdateController?

        // swiftlint:disable function_parameter_count
        init(
            configurationManager: ConfigurationManager,
            configurationURLProvider: CustomConfigurationURLProviding,
            bookmarkManager: LocalBookmarkManager,
            historyCoordinator: HistoryCoordinator,
            faviconManager: FaviconManager,
            fireproofDomains: FireproofDomains,
            permissionManager: PermissionManager,
            downloadManager: FileDownloadManagerProtocol,
            downloadListCoordinator: DownloadListCoordinator,
            privacyStats: PrivacyStatsCollecting,
            autoconsentStats: AutoconsentStatsCollecting,
            remoteMessagingClient: RemoteMessagingClient!,
            activeRemoteMessageModel: ActiveRemoteMessageModel,
            syncService: DDGSyncing?,
            syncDataProviders: SyncDataProvidersSource?,
            syncErrorHandler: SyncErrorHandler,
            webCacheManager: WebCacheManager,
            crashReporting: any CrashReporting,
            watchdog: Watchdog,
            watchdogSleepMonitor: WatchdogSleepMonitor,
            autoClearHandler: AutoClearHandler!,
            privacyFeatures: AnyPrivacyFeatures,
            tld: TLD,
            autoconsentManagement: AutoconsentManagement,
            brokenSitePromptLimiter: BrokenSitePromptLimiter,
            notificationService: UserNotificationAuthorizationServicing,
            onboardingContextualDialogsManager: ContextualOnboardingDialogTypeProviding & ContextualOnboardingStateUpdater,
            defaultBrowserAndDockPromptService: DefaultBrowserAndDockPromptService,
            userChurnScheduler: UserChurnBackgroundActivityScheduler,
            bitwardenManager: BWManagement?,
            passwordManagerCoordinator: PasswordManagerCoordinator,
            attributedMetricManager: AttributedMetricManager,
            memoryUsageMonitor: MemoryUsageMonitor,
            memoryPressureReporter: MemoryPressureReporter?,
            memoryUsageThresholdReporter: MemoryUsageThresholdReporter,
            memoryUsageIntervalReporter: MemoryUsageIntervalReporter?,
            startupProfiler: StartupProfiler,
            duckPlayer: DuckPlayer,
            newTabPageCustomizationModel: NewTabPageCustomizationModel,
            vpnSettings: VPNSettings,
            freemiumDBPFeature: FreemiumDBPFeature,
            freemiumDBPPromotionViewCoordinator: FreemiumDBPPromotionViewCoordinator,
            blackFridayCampaignProvider: BlackFridayCampaignProviding,
            wideEvent: WideEventManaging,
            urlEventHandler: URLEventHandler,
            tabCrashAggregator: TabCrashAggregator,
            grammarFeaturesManager: GrammarFeaturesManager,
            webExtensionAvailability: WebExtensionAvailabilityProviding,
            aiChatSessionStore: AIChatSessionStoring,
            aiChatMenuConfiguration: AIChatMenuVisibilityConfigurable,
            visualizeFireSettingsDecider: VisualizeFireSettingsDecider,
            autoconsentEventCoordinator: AutoconsentEventCoordinator?,
            stateRestorationManager: AppStateRestorationManager!,
            appIconChanger: AppIconChanger!,
            launchOptionsHandler: LaunchOptionsHandler,
            updateController: UpdateController?
        ) {
            self.configurationManager = configurationManager
            self.configurationURLProvider = configurationURLProvider
            self.bookmarkManager = bookmarkManager
            self.historyCoordinator = historyCoordinator
            self.faviconManager = faviconManager
            self.fireproofDomains = fireproofDomains
            self.permissionManager = permissionManager
            self.downloadManager = downloadManager
            self.downloadListCoordinator = downloadListCoordinator
            self.privacyStats = privacyStats
            self.autoconsentStats = autoconsentStats
            self.remoteMessagingClient = remoteMessagingClient
            self.activeRemoteMessageModel = activeRemoteMessageModel
            self.syncService = syncService
            self.syncDataProviders = syncDataProviders
            self.syncErrorHandler = syncErrorHandler
            self.webCacheManager = webCacheManager
            self.crashReporting = crashReporting
            self.watchdog = watchdog
            self.watchdogSleepMonitor = watchdogSleepMonitor
            self.autoClearHandler = autoClearHandler
            self.privacyFeatures = privacyFeatures
            self.tld = tld
            self.autoconsentManagement = autoconsentManagement
            self.brokenSitePromptLimiter = brokenSitePromptLimiter
            self.notificationService = notificationService
            self.onboardingContextualDialogsManager = onboardingContextualDialogsManager
            self.defaultBrowserAndDockPromptService = defaultBrowserAndDockPromptService
            self.userChurnScheduler = userChurnScheduler
            self.bitwardenManager = bitwardenManager
            self.passwordManagerCoordinator = passwordManagerCoordinator
            self.attributedMetricManager = attributedMetricManager
            self.memoryUsageMonitor = memoryUsageMonitor
            self.memoryPressureReporter = memoryPressureReporter
            self.memoryUsageThresholdReporter = memoryUsageThresholdReporter
            self.memoryUsageIntervalReporter = memoryUsageIntervalReporter
            self.startupProfiler = startupProfiler
            self.duckPlayer = duckPlayer
            self.newTabPageCustomizationModel = newTabPageCustomizationModel
            self.vpnSettings = vpnSettings
            self.freemiumDBPFeature = freemiumDBPFeature
            self.freemiumDBPPromotionViewCoordinator = freemiumDBPPromotionViewCoordinator
            self.blackFridayCampaignProvider = blackFridayCampaignProvider
            self.wideEvent = wideEvent
            self.urlEventHandler = urlEventHandler
            self.tabCrashAggregator = tabCrashAggregator
            self.grammarFeaturesManager = grammarFeaturesManager
            self.webExtensionAvailability = webExtensionAvailability
            self.aiChatSessionStore = aiChatSessionStore
            self.aiChatMenuConfiguration = aiChatMenuConfiguration
            self.visualizeFireSettingsDecider = visualizeFireSettingsDecider
            self.autoconsentEventCoordinator = autoconsentEventCoordinator
            self.stateRestorationManager = stateRestorationManager
            self.appIconChanger = appIconChanger
            self.launchOptionsHandler = launchOptionsHandler
            self.updateController = updateController
        }
        // swiftlint:enable function_parameter_count
    }

    // MARK: - UI

    struct UI {
        let windowControllersManager: WindowControllersManager
        let pinnedTabsManager: PinnedTabsManager
        let pinnedTabsManagerProvider: PinnedTabsManagerProvider
        let themeManager: ThemeManager
        let fireCoordinator: FireCoordinator
        let recentlyClosedCoordinator: RecentlyClosedCoordinating
        let tabDragAndDropManager: TabDragAndDropManager
        let bookmarkDragDropManager: BookmarkDragDropManager
        let pinningManager: LocalPinningManager
    }

    // MARK: - SubscriptionDependencies

    struct SubscriptionDependencies {
        let subscriptionManager: any SubscriptionManager
        let subscriptionUIHandler: SubscriptionUIHandling
        let subscriptionNavigationCoordinator: SubscriptionNavigationCoordinator
        let freeTrialConversionService: FreeTrialConversionInstrumentationService
    }

    // MARK: - Sub-containers

    var stores: Stores
    var featureFlags: FeatureFlags
    var preferences: Preferences
    var services: Services
    var ui: UI
    var subscription: SubscriptionDependencies
}
