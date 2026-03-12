//
//  Launching.swift
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

// swiftlint:disable type_body_length
// swiftlint:disable function_body_length
// swiftlint:disable cyclomatic_complexity
// swiftlint:disable file_length

@MainActor
final class Launching: LaunchingHandling {

    private(set) var dependencies: AppDependencies

    // MARK: - Properties that live on Launching (not in AppDependencies)

    /// Properties that need to outlive init but aren't part of AppDependencies
    private var hangReportingFeatureMonitor: HangReportingFeatureMonitor?
    private var autofillPixelReporter: AutofillPixelReporter?
    private var passwordsStatusBarMenu: PasswordsStatusBarMenu?
    private var aiChatSyncCleaner: AIChatSyncCleaning?
    private var startupMetricsReporter: PerformanceMetricsReporter?

    /// The date this app instance was launched, used for computing uptime in memory pixels.
    private let appLaunchDate = Date()

    init() throws {
        let startupProfiler = StartupProfiler()
        let profilerToken = startupProfiler.startMeasuring(.appDelegateInit)
        defer {
            profilerToken.stop()
        }

        // MARK: - Key Store

        let keyStore: EncryptionKeyStoring
        if [.unitTests, .integrationTests].contains(AppVersion.runType) {
            keyStore = (NSClassFromString("MockEncryptionKeyStore") as? EncryptionKeyStoring.Type)!.init()
        } else {
            keyStore = EncryptionKeyStore()
        }

        // MARK: - Skip crash handler setup + PixelKit configuration (handled by Initializing)

        // MARK: - Key Value Store

        let keyValueStore: ThrowingKeyValueStoring
        do {
            keyValueStore = try KeyValueFileStore(location: URL.sandboxApplicationSupportURL, name: "AppKeyValueStore")
            // perform a dummy read to ensure that KVS is accessible
            _ = try keyValueStore.object(forKey: AppearancePreferencesUserDefaultsPersistor.Key.newTabPageIsProtectionsReportVisible.rawValue)
        } catch {
            PixelKit.fire(DebugEvent(GeneralPixel.keyValueFileStoreInitError, error: error))
            Thread.sleep(forTimeInterval: 1)
            throw LaunchingError.keyValueStoreFailure(error)
        }

        // MARK: - File Store

        let fileStore: FileStore
        do {
            let encryptionKey = AppVersion.runType.requiresEnvironment ? try keyStore.readKey() : nil
            fileStore = EncryptedFileStore(encryptionKey: encryptionKey)
        } catch {
            Logger.general.error("App Encryption Key could not be read: \(error.localizedDescription)")
            fileStore = EncryptedFileStore()
        }

        // MARK: - Bookmark Database

        let bookmarkDatabase = BookmarkDatabase()

        // MARK: - Internal User Decider

        let internalUserDeciderStore = InternalUserDeciderStore(fileStore: fileStore)
        let internalUserDecider = DefaultInternalUserDecider(store: internalUserDeciderStore)

        // MARK: - Database

        let database: Database!
        if AppVersion.runType.requiresEnvironment {
            let commonDatabase = Database()
            database = commonDatabase

            database.db.loadStore { _, error in
                guard let error = error else { return }

                switch error {
                case CoreDataDatabase.Error.containerLocationCouldNotBePrepared(let underlyingError):
                    PixelKit.fire(DebugEvent(GeneralPixel.dbContainerInitializationError(error: underlyingError)))
                default:
                    PixelKit.fire(DebugEvent(GeneralPixel.dbInitializationError(error: error)))
                }

                // Give Pixel a chance to be sent, but not too long
                Thread.sleep(forTimeInterval: 1)
                fatalError("Could not load DB: \(error.localizedDescription)")
            }

            do {
                let formFactorFavMigration = BookmarkFormFactorFavoritesMigration()
                let favoritesOrder = try formFactorFavMigration.getFavoritesOrderFromPreV4Model(dbContainerLocation: BookmarkDatabase.defaultDBLocation,
                                                                                                dbFileURL: BookmarkDatabase.defaultDBFileURL)
                bookmarkDatabase.preFormFactorSpecificFavoritesFolderOrder = favoritesOrder
            } catch {
                PixelKit.fire(DebugEvent(GeneralPixel.bookmarksCouldNotLoadDatabase(error: error)))
                Thread.sleep(forTimeInterval: 1)
                throw LaunchingError.bookmarkDatabaseFailure(error)
            }

            bookmarkDatabase.db.loadStore { context, error in
                guard let context = context else {
                    PixelKit.fire(DebugEvent(GeneralPixel.bookmarksCouldNotLoadDatabase(error: error)))
                    Thread.sleep(forTimeInterval: 1)
                    fatalError("Could not create Bookmarks database stack: \(error?.localizedDescription ?? "err")")
                }

                let legacyDB = commonDatabase.db.makeContext(concurrencyType: .privateQueueConcurrencyType)
                legacyDB.performAndWait {
                    LegacyBookmarksStoreMigration.setupAndMigrate(from: legacyDB, to: context)
                }
            }
        } else {
            database = nil
        }

        // MARK: - Privacy Configuration

        let privacyConfigurationManager: PrivacyConfigurationManager
        let buildType = StandardApplicationBuildType()
        var configurationStore = ConfigurationStore()

        // When TEST_PRIVACY_CONFIG_PATH is set, skip cached config to use the test config from embedded data provider
        let useTestConfig = (buildType.isDebugBuild || buildType.isReviewBuild) && ProcessInfo.processInfo.environment[AppPrivacyConfigurationDataProvider.EnvironmentKeys.testPrivacyConfigPath] != nil
        let fetchedEtag: String? = useTestConfig ? nil : configurationStore.loadEtag(for: .privacyConfiguration)
        let fetchedData: Data? = useTestConfig ? nil : configurationStore.loadData(for: .privacyConfiguration)

        if useTestConfig {
            Logger.general.log("[DDG-TEST-CONFIG] Skipping cached privacy config to use TEST_PRIVACY_CONFIG_PATH")
        }

        if AppVersion.runType.requiresEnvironment {
            privacyConfigurationManager = PrivacyConfigurationManager(
                fetchedETag: fetchedEtag,
                fetchedData: fetchedData,
                embeddedDataProvider: AppPrivacyConfigurationDataProvider(),
                localProtection: LocalUnprotectedDomains(database: database.db),
                errorReporting: AppContentBlocking.debugEvents,
                internalUserDecider: internalUserDecider
            )
        } else {
            privacyConfigurationManager = PrivacyConfigurationManager(
                fetchedETag: fetchedEtag,
                fetchedData: fetchedData,
                embeddedDataProvider: AppPrivacyConfigurationDataProvider(),
                localProtection: LocalUnprotectedDomains(database: nil),
                errorReporting: AppContentBlocking.debugEvents,
                internalUserDecider: internalUserDecider
            )
        }

        // MARK: - Feature Flags

        let featureFlagOverridesPublishingHandler = FeatureFlagOverridesPublishingHandler<FeatureFlag>()
        let featureFlagger: FeatureFlagger
        let contentScopeExperimentsManager: ContentScopeExperimentsManaging
        if [.unitTests, .integrationTests, .xcPreviews].contains(AppVersion.runType) {
            featureFlagger = MockFeatureFlagger()
            contentScopeExperimentsManager = MockContentScopeExperimentManager()
        } else {
            let featureFlagOverrides = FeatureFlagLocalOverrides(
                keyValueStore: UserDefaults.appConfiguration,
                actionHandler: featureFlagOverridesPublishingHandler
            )
            let defaultFeatureFlagger = DefaultFeatureFlagger(
                internalUserDecider: internalUserDecider,
                privacyConfigManager: privacyConfigurationManager,
                localOverrides: featureFlagOverrides,
                allowOverrides: { [internalUserDecider, isRunningUITests=(AppVersion.runType == .uiTests)] in
                    internalUserDecider.isInternalUser || isRunningUITests
                },
                experimentManager: ExperimentCohortsManager(
                    store: ExperimentsDataStore(),
                    fireCohortAssigned: PixelKit.fireExperimentEnrollmentPixel(subfeatureID:experiment:)
                ),
                for: FeatureFlag.self
            )
            featureFlagger = defaultFeatureFlagger
            contentScopeExperimentsManager = defaultFeatureFlagger

            featureFlagOverrides.applyUITestsFeatureFlagsIfNeeded()
        }

        // MARK: - Web Extension Availability

        // WebExtensionAvailability needs a provider closure for the manager.
        // In AppDelegate this used a holder class that referenced self. Here we use a simple closure
        // that returns nil — AppDelegate will set up the real web extension manager post-init.
        let webExtensionAvailability: WebExtensionAvailabilityProviding = WebExtensionAvailability(
            featureFlagger: featureFlagger,
            webExtensionManagerProvider: {
                // The web extension manager is set up later by AppDelegate.
                // For now, return nil. This will be wired in a later task.
                Application.appDelegate.webExtensionManager
            }
        )

        // MARK: - Wide Event

        let wideEvent: WideEventManaging = WideEvent(featureFlagProvider: WideEventFeatureFlagAdapter(featureFlagger: featureFlagger))

        // MARK: - AI Chat

        let aiChatSessionStore: AIChatSessionStoring = AIChatSessionStore(featureFlagger: featureFlagger)
        let aiChatMenuConfiguration: AIChatMenuVisibilityConfigurable = AIChatMenuConfiguration(
            storage: DefaultAIChatPreferencesStorage(),
            remoteSettings: AIChatRemoteSettings(
                privacyConfigurationManager: privacyConfigurationManager
            ),
            featureFlagger: featureFlagger
        )

        // MARK: - Appearance Preferences

        let appearancePreferences = AppearancePreferences(
            keyValueStore: keyValueStore,
            privacyConfigurationManager: privacyConfigurationManager,
            pixelFiring: PixelKit.shared,
            featureFlagger: featureFlagger,
            aiChatMenuConfig: aiChatMenuConfiguration
        )

        // MARK: - Bookmark Manager & History Coordinator

        let bookmarkManager: LocalBookmarkManager
        let historyCoordinator: HistoryCoordinator
#if DEBUG
        if AppVersion.runType.requiresEnvironment {
            bookmarkManager = LocalBookmarkManager(
                bookmarkStore: LocalBookmarkStore(
                    bookmarkDatabase: bookmarkDatabase,
                    favoritesDisplayMode: appearancePreferences.favoritesDisplayMode
                ),
                appearancePreferences: appearancePreferences
            )
            historyCoordinator = HistoryCoordinator(
                historyStoring: EncryptedHistoryStore(
                    context: database.db.makeContext(concurrencyType: .privateQueueConcurrencyType, name: "History")
                )
            )
        } else {
            bookmarkManager = LocalBookmarkManager(bookmarkStore: BookmarkStoreMock(), appearancePreferences: appearancePreferences)
            historyCoordinator = HistoryCoordinator(historyStoring: MockHistoryStore())
        }
#else
        bookmarkManager = LocalBookmarkManager(
            bookmarkStore: LocalBookmarkStore(
                bookmarkDatabase: bookmarkDatabase,
                favoritesDisplayMode: appearancePreferences.favoritesDisplayMode
            ),
            appearancePreferences: appearancePreferences
        )
        historyCoordinator = HistoryCoordinator(
            historyStoring: EncryptedHistoryStore(
                context: database.db.makeContext(concurrencyType: .privateQueueConcurrencyType, name: "History")
            )
        )
#endif
        let bookmarkDragDropManager = BookmarkDragDropManager(bookmarkManager: bookmarkManager)

        // MARK: - Subscription configuration

        let subscriptionUIHandler: SubscriptionUIHandling = SubscriptionUIHandler(windowControllersManagerProvider: {
            return Application.appDelegate.windowControllersManager
        })

        let subscriptionAppGroup = Bundle.main.appGroup(bundle: .subs)
        let subscriptionUserDefaults = UserDefaults(suiteName: subscriptionAppGroup)!
        let subscriptionEnvironment = DefaultSubscriptionManager.getSavedOrDefaultEnvironment(userDefaults: subscriptionUserDefaults)

        // Configuring V2 for migration
        let pixelHandler: SubscriptionPixelHandling = SubscriptionPixelHandler(source: .mainApp, pixelKit: PixelKit.shared)
        let keychainType = KeychainType.dataProtection(.named(subscriptionAppGroup))
        let keychainManager = KeychainManager(attributes: SubscriptionTokenKeychainStorage.defaultAttributes(keychainType: keychainType), pixelHandler: pixelHandler)
        let authService = DefaultOAuthService(baseURL: subscriptionEnvironment.authEnvironment.url,
                                              apiService: APIServiceFactory.makeAPIServiceForAuthV2(withUserAgent: UserAgent.duckDuckGoUserAgent()))
        let tokenStorage = SubscriptionTokenKeychainStorage(keychainManager: keychainManager, userDefaults: .subs) { accessType, error in
            PixelKit.fire(SubscriptionErrorPixel.subscriptionKeychainAccessError(accessType: accessType,
                                                                                 accessError: error,
                                                                                 source: KeychainErrorSource.browser,
                                                                                 authVersion: KeychainErrorAuthVersion.v2),
                          frequency: .legacyDailyAndCount)
        }

        let authRefreshWideEventMapper = AuthV2TokenRefreshWideEventData.authV2RefreshEventMapping(wideEvent: wideEvent, isFeatureEnabled: {
#if DEBUG
            return true // Allow the refresh event when using staging in debug mode, for easier testing
#else
            return subscriptionEnvironment.serviceEnvironment == .production
#endif
        })
        let authClient = DefaultOAuthClient(tokensStorage: tokenStorage,
                                            authService: authService,
                                            refreshEventMapping: authRefreshWideEventMapper)
        Logger.general.log("Configuring Subscription")
        var apiServiceForSubscription = APIServiceFactory.makeAPIServiceForSubscription(withUserAgent: UserAgent.duckDuckGoUserAgent())
        let subscriptionEndpointService = DefaultSubscriptionEndpointService(apiService: apiServiceForSubscription,
                                                                               baseURL: subscriptionEnvironment.serviceEnvironment.url)
        apiServiceForSubscription.authorizationRefresherCallback = { _ in

            guard let tokenContainer = try? tokenStorage.getTokenContainer() else {
                throw OAuthClientError.internalError("Missing refresh token")
            }

            if tokenContainer.decodedAccessToken.isExpired() {
                Logger.OAuth.debug("Refreshing tokens")
                let tokens = try await authClient.getTokens(policy: .localForceRefresh)
                return tokens.accessToken
            } else {
                Logger.general.debug("Trying to refresh valid token, using the old one")
                return tokenContainer.accessToken
            }
        }
        let subscriptionFeatureFlagger: FeatureFlaggerMapping<SubscriptionFeatureFlags> = FeatureFlaggerMapping { feature in
            switch feature {
            case .useSubscriptionUSARegionOverride:
                return (featureFlagger.internalUserDecider.isInternalUser &&
                        subscriptionEnvironment.serviceEnvironment == .staging &&
                        subscriptionUserDefaults.storefrontRegionOverride == .usa)
            case .useSubscriptionROWRegionOverride:
                return (featureFlagger.internalUserDecider.isInternalUser &&
                        subscriptionEnvironment.serviceEnvironment == .staging &&
                        subscriptionUserDefaults.storefrontRegionOverride == .restOfWorld)
            }
        }

        let isInternalUserEnabled = { featureFlagger.internalUserDecider.isInternalUser }
        let pendingTransactionHandler = DefaultPendingTransactionHandler(userDefaults: subscriptionUserDefaults,
                                                                         pixelHandler: pixelHandler)
        let defaultSubscriptionManager: DefaultSubscriptionManager
        if #available(macOS 12.0, *) {
            defaultSubscriptionManager = DefaultSubscriptionManager(storePurchaseManager: DefaultStorePurchaseManager(subscriptionFeatureMappingCache: subscriptionEndpointService,
                                                                                                                      subscriptionFeatureFlagger: subscriptionFeatureFlagger,
                                                                                                                      pendingTransactionHandler: pendingTransactionHandler),
                                                                    oAuthClient: authClient,
                                                                    userDefaults: subscriptionUserDefaults,
                                                                    subscriptionEndpointService: subscriptionEndpointService,
                                                                    subscriptionEnvironment: subscriptionEnvironment,
                                                                    pixelHandler: pixelHandler,
                                                                    isInternalUserEnabled: isInternalUserEnabled)
        } else {
            defaultSubscriptionManager = DefaultSubscriptionManager(oAuthClient: authClient,
                                                                    userDefaults: subscriptionUserDefaults,
                                                                    subscriptionEndpointService: subscriptionEndpointService,
                                                                    subscriptionEnvironment: subscriptionEnvironment,
                                                                    pixelHandler: pixelHandler,
                                                                    isInternalUserEnabled: isInternalUserEnabled)
        }

        // Expired refresh token recovery
        if #available(iOS 15.0, macOS 12.0, *) {
            let restoreFlow = DefaultAppStoreRestoreFlow(subscriptionManager: defaultSubscriptionManager,
                                                         storePurchaseManager: defaultSubscriptionManager.storePurchaseManager(),
                                                         pendingTransactionHandler: pendingTransactionHandler)
            defaultSubscriptionManager.tokenRecoveryHandler = {
                try await AppDelegate.deadTokenRecoverer.attemptRecoveryFromPastPurchase(purchasePlatform: defaultSubscriptionManager.currentEnvironment.purchasePlatform, restoreFlow: restoreFlow)
            }
        }

        let subscriptionManager: any SubscriptionManager = defaultSubscriptionManager
        let freeTrialConversionService = DefaultFreeTrialConversionInstrumentationService(
            wideEvent: wideEvent,
            pixelHandler: FreeTrialPixelHandler(),
            subscriptionFetcher: { try? await defaultSubscriptionManager.getSubscription(cachePolicy: .cacheFirst) },
            isFeatureEnabled: { [featureFlagger] in featureFlagger.isFeatureOn(.freeTrialConversionWideEvent) }
        )
        freeTrialConversionService.startObservingSubscriptionChanges()

        // MARK: - Pinned Tabs & Window Controllers

        let pinnedTabsManager = PinnedTabsManager()
        let pinnedTabsManagerProvider = PinnedTabsManagerProvider(sharedPinnedTabsManager: pinnedTabsManager)
        let pinningManager = LocalPinningManager()

        let windowControllersManager = WindowControllersManager(
            pinnedTabsManagerProvider: pinnedTabsManagerProvider,
            subscriptionFeatureAvailability: DefaultSubscriptionFeatureAvailability(
                privacyConfigurationManager: privacyConfigurationManager,
                purchasePlatform: defaultSubscriptionManager.currentEnvironment.purchasePlatform,
                featureFlagProvider: SubscriptionPageFeatureFlagAdapter(featureFlagger: featureFlagger)
            ),
            internalUserDecider: internalUserDecider,
            featureFlagger: featureFlagger,
            pinningManager: pinningManager
        )
        let tabsPreferences = TabsPreferences(
            persistor: TabsPreferencesUserDefaultsPersistor(keyValueStore: UserDefaults.standard),
            windowControllersManager: windowControllersManager
        )
        windowControllersManager.tabsPreferences = tabsPreferences

        pinnedTabsManagerProvider.tabsPreferences = tabsPreferences
        pinnedTabsManagerProvider.windowControllersManager = windowControllersManager

        // MARK: - More Preferences

        let contentScopePreferences = ContentScopePreferences(windowControllersManager: windowControllersManager)
        let webTrackingProtectionPreferences = WebTrackingProtectionPreferences(persistor: WebTrackingProtectionPreferencesUserDefaultsPersistor(), windowControllersManager: windowControllersManager)
        let cookiePopupProtectionPreferences = CookiePopupProtectionPreferences(persistor: CookiePopupProtectionPreferencesUserDefaultsPersistor(), windowControllersManager: windowControllersManager)
        let aiChatPreferences = AIChatPreferences(
            storage: DefaultAIChatPreferencesStorage(),
            aiChatMenuConfiguration: aiChatMenuConfiguration,
            windowControllersManager: windowControllersManager,
            featureFlagger: featureFlagger
        )

        let subscriptionNavigationCoordinator = SubscriptionNavigationCoordinator(
            tabShower: windowControllersManager,
            subscriptionManager: subscriptionManager
        )

        let themeManager = ThemeManager(appearancePreferences: appearancePreferences, featureFlagger: featureFlagger)

        // MARK: - Fireproof Domains, Favicon Manager, Permission Manager

        let tld = TLD()
        let fireproofDomains: FireproofDomains
        let faviconManager: FaviconManager
        let permissionManager: PermissionManager
#if DEBUG
        if AppVersion.runType.requiresEnvironment {
            fireproofDomains = FireproofDomains(store: FireproofDomainsStore(database: database.db, tableName: "FireproofDomains"), tld: tld)
            faviconManager = FaviconManager(cacheType: .standard(database.db), bookmarkManager: bookmarkManager, fireproofDomains: fireproofDomains, privacyConfigurationManager: privacyConfigurationManager)
            permissionManager = PermissionManager(store: LocalPermissionStore(database: database.db), featureFlagger: featureFlagger)
        } else {
            fireproofDomains = FireproofDomains(store: FireproofDomainsStore(context: nil), tld: tld)
            faviconManager = FaviconManager(cacheType: .inMemory, bookmarkManager: bookmarkManager, fireproofDomains: fireproofDomains, privacyConfigurationManager: privacyConfigurationManager)
            permissionManager = PermissionManager(store: LocalPermissionStore(database: nil), featureFlagger: featureFlagger)
        }
#else
        fireproofDomains = FireproofDomains(store: FireproofDomainsStore(database: database.db, tableName: "FireproofDomains"), tld: tld)
        faviconManager = FaviconManager(cacheType: .standard(database.db), bookmarkManager: bookmarkManager, fireproofDomains: fireproofDomains, privacyConfigurationManager: privacyConfigurationManager)
        permissionManager = PermissionManager(store: LocalPermissionStore(database: database.db), featureFlagger: featureFlagger)
#endif
        let notificationService: UserNotificationAuthorizationServicing = UserNotificationAuthorizationService()

        let webCacheManager = WebCacheManager(fireproofDomains: fireproofDomains)

        // MARK: - Data Clearing & More Preferences

        let aiChatHistoryCleaner = AIChatHistoryCleaner(featureFlagger: featureFlagger,
                                                        aiChatMenuConfiguration: aiChatMenuConfiguration,
                                                        featureDiscovery: DefaultFeatureDiscovery(),
                                                        privacyConfig: privacyConfigurationManager)
        let dataClearingPreferences = DataClearingPreferences(
            fireproofDomains: fireproofDomains,
            faviconManager: faviconManager,
            windowControllersManager: windowControllersManager,
            featureFlagger: featureFlagger,
            pixelFiring: PixelKit.shared,
            aiChatHistoryCleaner: aiChatHistoryCleaner
        )
        let visualizeFireSettingsDecider: VisualizeFireSettingsDecider = DefaultVisualizeFireSettingsDecider(featureFlagger: featureFlagger, dataClearingPreferences: dataClearingPreferences)
        let startupPreferences = StartupPreferences(
            pinningManager: pinningManager,
            persistor: StartupPreferencesUserDefaultsPersistor(keyValueStore: keyValueStore),
            appearancePreferences: appearancePreferences
        )
        let defaultBrowserPreferences = DefaultBrowserPreferences()
        let searchPreferences = SearchPreferences(persistor: SearchPreferencesUserDefaultsPersistor(), windowControllersManager: windowControllersManager)
        let aboutPreferences = AboutPreferences(
            internalUserDecider: internalUserDecider,
            featureFlagger: featureFlagger,
            windowControllersManager: windowControllersManager,
            keyValueStore: UserDefaults.standard
        )
        let accessibilityPreferences = AccessibilityPreferences()
        let downloadsPreferences = DownloadsPreferences(persistor: DownloadsPreferencesUserDefaultsPersistor())
        let duckPlayer = DuckPlayer(
            preferencesPersistor: DuckPlayerPreferencesUserDefaultsPersistor(),
            privacyConfigurationManager: privacyConfigurationManager,
            internalUserDecider: internalUserDecider
        )
        let newTabPageCustomizationModel = NewTabPageCustomizationModel(appearancePreferences: appearancePreferences)

        // MARK: - Sync Service

        let appSyncService = AppSyncService(
            bookmarksDatabase: bookmarkDatabase.db,
            bookmarkManager: bookmarkManager,
            appearancePreferences: appearancePreferences,
            privacyConfigurationManager: privacyConfigurationManager,
            keyValueStore: keyValueStore,
            featureFlagger: featureFlagger
        )
        let syncErrorHandler = appSyncService.syncErrorHandler

        // MARK: - Fire Coordinator

        let autoconsentManagement = AutoconsentManagement()

        let fireCoordinator = FireCoordinator(tld: tld,
                                              featureFlagger: featureFlagger,
                                              historyCoordinating: historyCoordinator,
                                              visualizeFireAnimationDecider: visualizeFireSettingsDecider,
                                              onboardingContextualDialogsManager: { Application.appDelegate.onboardingContextualDialogsManager },
                                              fireproofDomains: fireproofDomains,
                                              faviconManagement: faviconManager,
                                              windowControllersManager: windowControllersManager,
                                              pixelFiring: PixelKit.shared,
                                              aiChatSyncCleaner: { Application.appDelegate.aiChatSyncCleaner })

        // MARK: - Content Blocking & Privacy Features

        var appContentBlocking: AppContentBlocking?
        let privacyFeatures: AnyPrivacyFeatures
#if DEBUG
        if AppVersion.runType.requiresEnvironment {
            let contentBlocking = AppContentBlocking(
                privacyConfigurationManager: privacyConfigurationManager,
                internalUserDecider: internalUserDecider,
                featureFlagger: featureFlagger,
                configurationStore: configurationStore,
                contentScopeExperimentsManager: contentScopeExperimentsManager,
                onboardingNavigationDelegate: windowControllersManager,
                appearancePreferences: appearancePreferences,
                themeManager: themeManager,
                startupPreferences: startupPreferences,
                webTrackingProtectionPreferences: webTrackingProtectionPreferences,
                cookiePopupProtectionPreferences: cookiePopupProtectionPreferences,
                duckPlayer: duckPlayer,
                windowControllersManager: windowControllersManager,
                bookmarkManager: bookmarkManager,
                pinningManager: pinningManager,
                historyCoordinator: historyCoordinator,
                fireproofDomains: fireproofDomains,
                fireCoordinator: fireCoordinator,
                tld: tld,
                autoconsentManagement: autoconsentManagement,
                contentScopePreferences: contentScopePreferences,
                syncErrorHandler: syncErrorHandler,
                webExtensionAvailability: webExtensionAvailability
            )
            privacyFeatures = AppPrivacyFeatures(contentBlocking: contentBlocking, database: database.db)
            appContentBlocking = contentBlocking
        } else {
            // runtime mock-replacement for Unit Tests, to be redone when we'll be doing Dependency Injection
            privacyFeatures = AppPrivacyFeatures(contentBlocking: ContentBlockingMock(), httpsUpgradeStore: HTTPSUpgradeStoreMock())
        }
#else
        let contentBlocking = AppContentBlocking(
            privacyConfigurationManager: privacyConfigurationManager,
            internalUserDecider: internalUserDecider,
            featureFlagger: featureFlagger,
            configurationStore: configurationStore,
            contentScopeExperimentsManager: contentScopeExperimentsManager,
            onboardingNavigationDelegate: windowControllersManager,
            appearancePreferences: appearancePreferences,
            themeManager: themeManager,
            startupPreferences: startupPreferences,
            webTrackingProtectionPreferences: webTrackingProtectionPreferences,
            cookiePopupProtectionPreferences: cookiePopupProtectionPreferences,
            duckPlayer: duckPlayer,
            windowControllersManager: windowControllersManager,
            bookmarkManager: bookmarkManager,
            pinningManager: pinningManager,
            historyCoordinator: historyCoordinator,
            fireproofDomains: fireproofDomains,
            fireCoordinator: fireCoordinator,
            tld: tld,
            autoconsentManagement: autoconsentManagement,
            contentScopePreferences: contentScopePreferences,
            syncErrorHandler: syncErrorHandler,
            webExtensionAvailability: webExtensionAvailability
        )
        privacyFeatures = AppPrivacyFeatures(
            contentBlocking: contentBlocking,
            database: database.db
        )
        appContentBlocking = contentBlocking
#endif

        // MARK: - Configuration Manager

        let configurationURLProvider: CustomConfigurationURLProviding = ConfigurationURLProvider(defaultProvider: AppConfigurationURLProvider(privacyConfigurationManager: privacyConfigurationManager, featureFlagger: featureFlagger), internalUserDecider: internalUserDecider, store: CustomConfigurationURLStorage(defaults: UserDefaults.appConfiguration))
        let configurationManager = ConfigurationManager(
            fetcher: ConfigurationFetcher(store: configurationStore, configurationURLProvider: configurationURLProvider, eventMapping: ConfigurationManager.configurationDebugEvents),
            store: configurationStore,
            trackerDataManager: privacyFeatures.contentBlocking.trackerDataManager,
            privacyConfigurationManager: privacyConfigurationManager,
            contentBlockingManager: privacyFeatures.contentBlocking.contentBlockingManager,
            httpsUpgrade: privacyFeatures.httpsUpgrade
        )

        // MARK: - Onboarding & Default Browser Prompt

        let onboardingContextualDialogsManager: ContextualOnboardingDialogTypeProviding & ContextualOnboardingStateUpdater = ContextualDialogsManager(
            trackerMessageProvider: TrackerMessageProvider(
                entityProviding: privacyFeatures.contentBlocking.contentBlockingManager
            )
        )

        let onboardingManager = onboardingContextualDialogsManager
        let notificationPresenter = DefaultBrowserAndDockPromptNotificationPresenter(reportABrowserProblemPresenter: AppDelegate.openReportABrowserProblem)
        let defaultBrowserAndDockPromptService = DefaultBrowserAndDockPromptService(privacyConfigManager: privacyConfigurationManager,
                                                                                    keyValueStore: keyValueStore,
                                                                                    notificationPresenter: notificationPresenter,
                                                                                    isOnboardingCompletedProvider: { onboardingManager.state == .onboardingCompleted })

        // MARK: - Remote Messaging

        let remoteMessagingClient: RemoteMessagingClient!
        let activeRemoteMessageModel: ActiveRemoteMessageModel
        if AppVersion.runType.requiresEnvironment {
            remoteMessagingClient = RemoteMessagingClient(
                remoteMessagingDatabase: RemoteMessagingDatabase().db,
                bookmarksDatabase: bookmarkDatabase.db,
                database: database.db,
                appearancePreferences: appearancePreferences,
                startupPreferences: startupPreferences,
                pinnedTabsManagerProvider: pinnedTabsManagerProvider,
                internalUserDecider: internalUserDecider,
                configurationStore: configurationStore,
                remoteMessagingAvailabilityProvider: PrivacyConfigurationRemoteMessagingAvailabilityProvider(
                    privacyConfigurationManager: privacyConfigurationManager
                ),
                remoteMessagingSurfacesProvider: DefaultRemoteMessagingSurfacesProvider(),
                subscriptionManager: subscriptionManager,
                featureFlagger: featureFlagger,
                configurationURLProvider: configurationURLProvider,
                themeManager: themeManager,
                dbpDataManagerProvider: { DataBrokerProtectionManager.shared.dataManager }
            )
            let subscriptionManagerForPIR = subscriptionManager
            activeRemoteMessageModel = ActiveRemoteMessageModel(remoteMessagingClient: remoteMessagingClient, openURLHandler: { url in
                windowControllersManager.showTab(with: .contentFromURL(url, source: .appOpenUrl))
            }, navigateToFeedbackHandler: {
                windowControllersManager.showFeedbackModal(preselectedFormOption: .feedback(feedbackCategory: .other))
            }, navigateToPIRHandler: {
                let hasEntitlement = (try? await subscriptionManagerForPIR.isFeatureEnabled(.dataBrokerProtection)) ?? false
                await MainActor.run {
                    if hasEntitlement {
                        windowControllersManager.showTab(with: .dataBrokerProtection)
                    } else {
                        let url = subscriptionManagerForPIR.url(for: .purchase)
                        windowControllersManager.showTab(with: .subscription(url))
                    }
                }
            }, navigateToSoftwareUpdateHandler: {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension")!)
            })
        } else {
            // As long as remoteMessagingClient is private to App Delegate and activeRemoteMessageModel
            // is used only by HomePage RootView as environment object,
            // it's safe to not initialize the client for unit tests to avoid side effects.
            remoteMessagingClient = nil
            activeRemoteMessageModel = ActiveRemoteMessageModel(
                remoteMessagingStore: nil,
                remoteMessagingAvailabilityProvider: nil,
                openURLHandler: { _ in },
                navigateToFeedbackHandler: { },
                navigateToPIRHandler: { },
                navigateToSoftwareUpdateHandler: { }
            )
        }

        // MARK: - VPN & DBP Settings

        let vpnSettings = VPNSettings(defaults: .netP)

        // Update VPN environment and match the Subscription environment
        vpnSettings.alignTo(subscriptionEnvironment: subscriptionManager.currentEnvironment)

        // Update DBP environment and match the Subscription environment
        let dbpSettings = DataBrokerProtectionSettings(defaults: .dbp)
        dbpSettings.alignTo(subscriptionEnvironment: subscriptionManager.currentEnvironment)

        // Also update the stored run type so the login item knows if tests are running
        dbpSettings.updateStoredRunType()

        // MARK: - Freemium DBP

        let freemiumDBPUserStateManager = DefaultFreemiumDBPUserStateManager(userDefaults: .dbp)

        let freemiumDBPFeature = DefaultFreemiumDBPFeature(privacyConfigurationManager: privacyConfigurationManager,
                                                           subscriptionManager: subscriptionManager,
                                                           freemiumDBPUserStateManager: freemiumDBPUserStateManager)
        let freemiumDBPPromotionViewCoordinator = FreemiumDBPPromotionViewCoordinator(freemiumDBPUserStateManager: freemiumDBPUserStateManager,
                                                                                      freemiumDBPFeature: freemiumDBPFeature,
                                                                                      contextualOnboardingPublisher: onboardingContextualDialogsManager.isContextualOnboardingCompletedPublisher.eraseToAnyPublisher())

        // MARK: - Broken Site Prompt & Privacy Stats

        let brokenSitePromptLimiter = BrokenSitePromptLimiter(privacyConfigManager: privacyConfigurationManager, store: BrokenSitePromptLimiterStore())
        let privacyStats: PrivacyStatsCollecting
#if DEBUG
        if AppVersion.runType.requiresEnvironment {
            privacyStats = PrivacyStats(databaseProvider: PrivacyStatsDatabase(), errorEvents: PrivacyStatsErrorHandler())
        } else {
            privacyStats = MockPrivacyStats()
        }
#else
        privacyStats = PrivacyStats(databaseProvider: PrivacyStatsDatabase())
#endif
        let autoconsentStats: AutoconsentStatsCollecting = AutoconsentStats(keyValueStore: keyValueStore)
        let autoconsentEventCoordinator: AutoconsentEventCoordinator? = AutoconsentEventCoordinator(
            autoconsentStats: autoconsentStats,
            historyCoordinating: historyCoordinator,
            webExtensionAvailability: webExtensionAvailability
        )
        PixelKit.configureExperimentKit(featureFlagger: featureFlagger, eventTracker: ExperimentEventTracker(store: UserDefaults.appConfiguration))

        // MARK: - Crash Reporting & Watchdog

        let crashReporting: any CrashReporting = CrashReportingFactory.makeCrashReporting(internalUserDecider: internalUserDecider,
                                                                                           featureFlagger: featureFlagger,
                                                                                           keyValueStore: UserDefaults.standard)

        let watchdogDiagnosticProvider = MacWatchdogDiagnosticProvider(windowControllersManager: windowControllersManager)
        let eventMapper = WatchdogEventMapper(diagnosticProvider: watchdogDiagnosticProvider)
        let watchdog = Watchdog(eventMapper: eventMapper)
        let watchdogSleepMonitor = WatchdogSleepMonitor(watchdog: watchdog)

#if !DEBUG
        if AppVersion.runType == .normal {
            hangReportingFeatureMonitor = HangReportingFeatureMonitor(
                privacyConfigurationManager: privacyConfigurationManager,
                featureFlagger: featureFlagger,
                watchdog: watchdog
            )
        }
#endif

        // MARK: - Downloads & Recently Closed

        let recentlyClosedCoordinator: RecentlyClosedCoordinating = RecentlyClosedCoordinator(windowControllersManager: windowControllersManager, pinnedTabsManagerProvider: pinnedTabsManagerProvider)
        let downloadManager: FileDownloadManagerProtocol = FileDownloadManager(preferences: downloadsPreferences)
        let downloadListCoordinator: DownloadListCoordinator
#if DEBUG
        if AppVersion.runType.requiresEnvironment {
            downloadListCoordinator = DownloadListCoordinator(
                store: DownloadListStore(database: database.db),
                downloadManager: downloadManager,
                windowControllersManager: windowControllersManager
            )
        } else {
            downloadListCoordinator = DownloadListCoordinator(
                store: DownloadListStore(database: nil),
                downloadManager: downloadManager,
                windowControllersManager: windowControllersManager
            )
        }
#else
        downloadListCoordinator = DownloadListCoordinator(
            store: DownloadListStore(database: database.db),
            downloadManager: downloadManager,
            windowControllersManager: windowControllersManager
        )
#endif

        let tabDragAndDropManager = TabDragAndDropManager()

        // MARK: - Black Friday, User Churn, Bitwarden

        let blackFridayCampaignProvider: BlackFridayCampaignProviding = DefaultBlackFridayCampaignProvider(
            privacyConfigurationManager: privacyConfigurationManager,
            isFeatureEnabled: { [weak featureFlagger] in
                featureFlagger?.isFeatureOn(.blackFridayCampaign) ?? false
            }
        )

        let userChurnScheduler = UserChurnBackgroundActivityScheduler(
            defaultBrowserProvider: SystemDefaultBrowserProvider(),
            keyValueStore: keyValueStore,
            pixelFiring: PixelKit.shared,
            atbProvider: { LocalStatisticsStore().atb }
        )

        let bitwardenManager: BWManagement? = BWManagerProvider.makeManager()
        let passwordManagerCoordinator = PasswordManagerCoordinator(bitwardenManagement: bitwardenManager)

        // MARK: - Attributed Metric

        let errorHandler = AttributedMetricErrorHandler(pixelKit: PixelKit.shared)
        let attributedMetricDataStorage = AttributedMetricDataStorage(userDefaults: .appConfiguration,
                                                                      errorHandler: errorHandler)
        let settingsProvider = DefaultAttributedMetricSettingsProvider(privacyConfig: privacyConfigurationManager.privacyConfig)
        let subscriptionStateProvider = DefaultSubscriptionStateProvider(subscriptionManager: subscriptionManager)
        let defaultBrowserProvider = SystemDefaultBrowserProvider()
        let returningUserProvider = AttributedMetricReturningUserProvider(
            reinstallUserDetection: DefaultReinstallUserDetection(keyValueStore: keyValueStore)
        )
        let attributedMetricManager = AttributedMetricManager(pixelKit: PixelKit.shared,
                                                               dataStoring: attributedMetricDataStorage,
                                                               featureFlagger: featureFlagger,
                                                               originProvider: AttributedMetricOriginFileProvider(),
                                                               defaultBrowserProviding: defaultBrowserProvider,
                                                               subscriptionStateProvider: subscriptionStateProvider,
                                                               returningUserProvider: returningUserProvider,
                                                               settingsProvider: settingsProvider)
        attributedMetricManager.addNotificationsObserver()

        // MARK: - Memory Usage

        let memoryUsageMonitor = MemoryUsageMonitor(internalUserDecider: internalUserDecider, logger: .memory)
        let memoryUsageThresholdReporter = MemoryUsageThresholdReporter(
            memoryUsageMonitor: memoryUsageMonitor,
            featureFlagger: featureFlagger,
            pixelFiring: PixelKit.shared,
            launchDate: appLaunchDate,
            logger: .memory
        )

        // MARK: - Grammar Features

        let grammarFeaturesManager = GrammarFeaturesManager()

        // MARK: - URL Event Handler & Launch Options

        let urlEventHandler = URLEventHandler()
        let launchOptionsHandler = LaunchOptionsHandler()

        // MARK: - Tab Crash Aggregator

        let tabCrashAggregator = TabCrashAggregator()

        // MARK: - Build AppDependencies

        self.dependencies = AppDependencies(
            stores: .init(
                keyStore: keyStore,
                keyValueStore: keyValueStore,
                fileStore: fileStore,
                database: database,
                bookmarkDatabase: bookmarkDatabase,
                configurationStore: configurationStore
            ),
            featureFlags: .init(
                featureFlagger: featureFlagger,
                internalUserDecider: internalUserDecider,
                contentScopeExperimentsManager: contentScopeExperimentsManager,
                featureFlagOverridesPublishingHandler: featureFlagOverridesPublishingHandler
            ),
            preferences: .init(
                appearancePreferences: appearancePreferences,
                dataClearingPreferences: dataClearingPreferences,
                startupPreferences: startupPreferences,
                defaultBrowserPreferences: defaultBrowserPreferences,
                downloadsPreferences: downloadsPreferences,
                searchPreferences: searchPreferences,
                tabsPreferences: tabsPreferences,
                webTrackingProtectionPreferences: webTrackingProtectionPreferences,
                cookiePopupProtectionPreferences: cookiePopupProtectionPreferences,
                aboutPreferences: aboutPreferences,
                accessibilityPreferences: accessibilityPreferences,
                contentScopePreferences: contentScopePreferences,
                aiChatPreferences: aiChatPreferences
            ),
            services: .init(
                configurationManager: configurationManager,
                configurationURLProvider: configurationURLProvider,
                bookmarkManager: bookmarkManager,
                historyCoordinator: historyCoordinator,
                faviconManager: faviconManager,
                fireproofDomains: fireproofDomains,
                permissionManager: permissionManager,
                downloadManager: downloadManager,
                downloadListCoordinator: downloadListCoordinator,
                privacyStats: privacyStats,
                autoconsentStats: autoconsentStats,
                remoteMessagingClient: remoteMessagingClient,
                activeRemoteMessageModel: activeRemoteMessageModel,
                appSyncService: appSyncService,
                webCacheManager: webCacheManager,
                crashReporting: crashReporting,
                watchdog: watchdog,
                watchdogSleepMonitor: watchdogSleepMonitor,
                autoClearHandler: nil,
                privacyFeatures: privacyFeatures,
                tld: tld,
                autoconsentManagement: autoconsentManagement,
                brokenSitePromptLimiter: brokenSitePromptLimiter,
                notificationService: notificationService,
                onboardingContextualDialogsManager: onboardingContextualDialogsManager,
                defaultBrowserAndDockPromptService: defaultBrowserAndDockPromptService,
                userChurnScheduler: userChurnScheduler,
                bitwardenManager: bitwardenManager,
                passwordManagerCoordinator: passwordManagerCoordinator,
                attributedMetricManager: attributedMetricManager,
                memoryUsageMonitor: memoryUsageMonitor,
                memoryPressureReporter: nil,
                memoryUsageThresholdReporter: memoryUsageThresholdReporter,
                memoryUsageIntervalReporter: nil,
                startupProfiler: startupProfiler,
                duckPlayer: duckPlayer,
                newTabPageCustomizationModel: newTabPageCustomizationModel,
                vpnSettings: vpnSettings,
                freemiumDBPFeature: freemiumDBPFeature,
                freemiumDBPPromotionViewCoordinator: freemiumDBPPromotionViewCoordinator,
                blackFridayCampaignProvider: blackFridayCampaignProvider,
                wideEvent: wideEvent,
                urlEventHandler: urlEventHandler,
                tabCrashAggregator: tabCrashAggregator,
                grammarFeaturesManager: grammarFeaturesManager,
                webExtensionAvailability: webExtensionAvailability,
                aiChatSessionStore: aiChatSessionStore,
                aiChatMenuConfiguration: aiChatMenuConfiguration,
                visualizeFireSettingsDecider: visualizeFireSettingsDecider,
                autoconsentEventCoordinator: autoconsentEventCoordinator,
                stateRestorationManager: nil,
                appIconChanger: nil,
                launchOptionsHandler: launchOptionsHandler,
                updateController: nil
            ),
            ui: .init(
                windowControllersManager: windowControllersManager,
                pinnedTabsManager: pinnedTabsManager,
                pinnedTabsManagerProvider: pinnedTabsManagerProvider,
                themeManager: themeManager,
                fireCoordinator: fireCoordinator,
                recentlyClosedCoordinator: recentlyClosedCoordinator,
                tabDragAndDropManager: tabDragAndDropManager,
                bookmarkDragDropManager: bookmarkDragDropManager,
                pinningManager: pinningManager
            ),
            subscription: .init(
                subscriptionManager: subscriptionManager,
                subscriptionUIHandler: subscriptionUIHandler,
                subscriptionNavigationCoordinator: subscriptionNavigationCoordinator,
                freeTrialConversionService: freeTrialConversionService
            )
        )

        // MARK: - Post-init setup (self-referencing closures)

        // Memory reporters need self-referencing closures for syncService access.
        // In a class, we can set these up after all stored properties are initialized.
        self.dependencies.services.memoryPressureReporter = MemoryPressureReporter(
            pixelFiring: PixelKit.shared,
            memoryUsageMonitor: memoryUsageMonitor,
            windowContext: WindowContext(windowControllersManager: windowControllersManager),
            isSyncEnabled: { [weak appSyncService] in
                return appSyncService?.sync.authState == .active
            },
            launchDate: appLaunchDate,
            logger: .memory
        )

        self.dependencies.services.memoryUsageIntervalReporter = MemoryUsageIntervalReporter(
            memoryUsageMonitor: memoryUsageMonitor,
            featureFlagger: featureFlagger,
            pixelFiring: PixelKit.shared,
            windowContext: WindowContext(windowControllersManager: windowControllersManager),
            isSyncEnabled: { [weak appSyncService] in
                return appSyncService?.sync.authState == .active
            },
            launchDate: appLaunchDate,
            logger: .memory
        )

        // Startup metrics reporter
        let metricsReporter = PerformanceMetricsReporter(
            featureFlagger: featureFlagger,
            pixelFiring: PixelKit.shared,
            previousSessionRestored: startupPreferences.restorePreviousSession,
            windowContext: WindowContext(windowControllersManager: windowControllersManager)
        )
        startupProfiler.delegate = metricsReporter
        startupMetricsReporter = metricsReporter

    }

    private(set) var vpnSubscriptionEventHandler: VPNSubscriptionEventsHandler?

    func handleWillFinishLaunching() {
        let profilerToken = dependencies.services.startupProfiler.startMeasuring(.appWillFinishLaunching)
        defer {
            profilerToken.stop()
        }

        /// Check for reinstalling user by comparing bundle creation dates.
        /// Stores the bundle's creation date in the KeyValueStore and compares
        /// on subsequent launches. If the date changes and it's not a Sparkle update,
        /// the user has reinstalled the app.
        ///
        /// This needs to run before the SparkleUpdateController is run to avoid having the user defaults resetted after an update restart.
        do {
            try DefaultReinstallUserDetection(keyValueStore: dependencies.stores.keyValueStore).checkForReinstallingUser()
        } catch {
            Logger.general.error("Problem when checking for reinstalling user: \(error.localizedDescription)")
        }

        APIRequest.Headers.setUserAgent(UserAgent.duckDuckGoUserAgent())

        dependencies.services.stateRestorationManager = AppStateRestorationManager(
            fileStore: dependencies.stores.fileStore,
            startupPreferences: dependencies.preferences.startupPreferences,
            tabsPreferences: dependencies.preferences.tabsPreferences,
            keyValueStore: dependencies.stores.keyValueStore,
            sessionRestorePromptCoordinator: SessionRestorePromptCoordinator(pixelFiring: PixelKit.shared),
            pixelFiring: PixelKit.shared
        )

        initializeUpdateController()

        dependencies.services.appIconChanger = AppIconChanger(
            internalUserDecider: dependencies.featureFlags.internalUserDecider,
            appearancePreferences: dependencies.preferences.appearancePreferences
        )

        if AppVersion.runType.requiresEnvironment {
            // Configure Event handlers
            let vpnUninstaller = VPNUninstaller(pinningManager: dependencies.ui.pinningManager, ipcClient: VPNControllerXPCClient.shared)
            let featureGatekeeper = DefaultVPNFeatureGatekeeper(vpnUninstaller: vpnUninstaller, subscriptionManager: dependencies.subscription.subscriptionManager)
            let tunnelController = NetworkProtectionIPCTunnelController(featureGatekeeper: featureGatekeeper, ipcClient: VPNControllerXPCClient.shared)

            vpnSubscriptionEventHandler = VPNSubscriptionEventsHandler(
                subscriptionManager: dependencies.subscription.subscriptionManager,
                tunnelController: tunnelController,
                vpnUninstaller: vpnUninstaller
            )

            // Freemium DBP
            dependencies.services.freemiumDBPFeature.subscribeToDependencyUpdates()
        }

        // ignore popovers shown from a view not in view hierarchy
        // https://app.asana.com/0/1201037661562251/1206407295280737/f
        _ = NSPopover.swizzleShowRelativeToRectOnce
        // disable macOS system-wide window tabbing
        NSWindow.allowsAutomaticWindowTabbing = false
        // Fix SwifUI context menus and its owner View leaking
        SwiftUIContextMenuRetainCycleFix.setUp()
    }

    @MainActor
    private func initializeUpdateController() {
        guard AppVersion.runType.allowsUpdates else { return }

        let buildType = StandardApplicationBuildType()
        let notificationPresenter = UpdateNotificationPresenter(pixelFiring: PixelKit.shared)

        if buildType.isAppStoreBuild {
            guard let appStoreFactory = UpdateControllerFactory.self as? any AppStoreUpdateControllerFactory.Type else {
                assertionFailure("Failed to instantiate app store update controller")
                return
            }

            dependencies.services.updateController = appStoreFactory.instantiate(
                internalUserDecider: dependencies.featureFlags.internalUserDecider,
                featureFlagger: dependencies.featureFlags.featureFlagger,
                pixelFiring: PixelKit.shared,
                notificationPresenter: notificationPresenter,
                isOnboardingFinished: { OnboardingActionsManager.isOnboardingFinished }
            )
        } else {
            assert(buildType.isSparkleBuild)

            guard let sparkleFactory = UpdateControllerFactory.self as? any SparkleUpdateControllerFactory.Type else {
                assertionFailure("Failed to instantiate sparkle update controller")
                return
            }

            let allowCustomUpdateFeed = buildType.isDebugBuild || buildType.isReviewBuild
            let sparkleUpdateController = sparkleFactory.instantiate(
                internalUserDecider: dependencies.featureFlags.internalUserDecider,
                featureFlagger: dependencies.featureFlags.featureFlagger,
                pixelFiring: PixelKit.shared,
                notificationPresenter: notificationPresenter,
                keyValueStore: UserDefaults.standard,
                allowCustomUpdateFeed: allowCustomUpdateFeed,
                wideEvent: dependencies.services.wideEvent,
                isOnboardingFinished: { OnboardingActionsManager.isOnboardingFinished },
                openUpdatesPage: { [windowControllersManager = dependencies.ui.windowControllersManager] in
                    windowControllersManager.showTab(with: .releaseNotes)
                }
            )
            dependencies.services.stateRestorationManager.subscribeToAutomaticAppRelaunching(using: sparkleUpdateController.willRelaunchAppPublisher)
            dependencies.services.updateController = sparkleUpdateController
        }
    }

    func makeForegroundState() throws -> any ForegroundHandling {
        Foreground(dependencies: dependencies, vpnSubscriptionEventHandler: vpnSubscriptionEventHandler)
    }
}

// MARK: - Launching Errors

enum LaunchingError: Error {
    case keyValueStoreFailure(Error)
    case bookmarkDatabaseFailure(Error)
}

// swiftlint:enable type_body_length
// swiftlint:enable function_body_length
// swiftlint:enable cyclomatic_complexity
// swiftlint:enable file_length
