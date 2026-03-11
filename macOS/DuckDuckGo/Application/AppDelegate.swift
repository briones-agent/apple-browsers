//
//  AppDelegate.swift
//
//  Copyright © 2020 DuckDuckGo. All rights reserved.
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

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var appStateMachine: AppStateMachine!

#if DEBUG
    let disableCVDisplayLinkLogs: Void = {
        // Disable CVDisplayLink logs
        CFPreferencesSetValue("cv_note" as CFString,
                              0 as CFPropertyList,
                              "com.apple.corevideo" as CFString,
                              kCFPreferencesCurrentUser,
                              kCFPreferencesAnyHost)
        CFPreferencesSynchronize("com.apple.corevideo" as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }()
#endif

    // MARK: - Stored Properties

    /// Set after transitioning to the Launching state. All forwarding properties read from here.
    private(set) var appDependencies: AppDependencies!

    private var didFinishLaunching = false
    var dockCustomization: DockCustomization?
    var privacyDashboardWindow: NSWindow?

    @UserDefaultsWrapper(key: .firstLaunchDate, defaultValue: Date.monthAgo)
    static var firstLaunchDate: Date

    @UserDefaultsWrapper
    private var didCrashDuringCrashHandlersSetUp: Bool

    static var isNewUser: Bool {
        return firstLaunchDate >= Date.weekAgo
    }

    static var twoDaysPassedSinceFirstLaunch: Bool {
        return firstLaunchDate.daysSinceNow() >= 2
    }

    static let deadTokenRecoverer = DeadTokenRecoverer()

    // MARK: - Properties set post-init (in applicationWillFinishLaunching / applicationDidFinishLaunching)

    private var automationServer: AutomationServer?
    private var vpnSubscriptionEventHandler: VPNSubscriptionEventsHandler?
    private var freemiumDBPScanResultPolling: FreemiumDBPScanResultPolling?
    private(set) var aiChatSyncCleaner: AIChatSyncCleaning?
    private(set) var autofillPixelReporter: AutofillPixelReporter?
    private var passwordsStatusBarMenu: PasswordsStatusBarMenu?
    private var passwordsMenuBarCancellable: AnyCancellable?
    private var isInternalUserSharingCancellable: AnyCancellable?
    private var isSyncInProgressCancellable: AnyCancellable?
    private var syncFeatureFlagsCancellable: AnyCancellable?
    private var screenLockedCancellable: AnyCancellable?
    private var emailCancellables = Set<AnyCancellable>()
    private var updateProgressCancellable: AnyCancellable?

    // MARK: - Web Extensions (stored on AppDelegate, set up in applicationDidFinishLaunching)

    private(set) var webExtensionManager: WebExtensionManaging?
    private var webExtensionFeatureFlagHandler: AnyObject?
    private var isSyncingEmbeddedExtensions = false
    private(set) var darkReaderFeatureSettings: DarkReaderFeatureSettings?
    private var darkReaderCancellables = Set<AnyCancellable>()

    // MARK: - Lazy Properties

    @MainActor
    private(set) lazy var autoconsentStatsPopoverCoordinator: AutoconsentStatsPopoverCoordinator = AutoconsentStatsPopoverCoordinator(
        autoconsentStats: autoconsentStats,
        keyValueStore: keyValueStore,
        windowControllersManager: windowControllersManager,
        cookiePopupProtectionPreferences: cookiePopupProtectionPreferences,
        appearancePreferences: appearancePreferences,
        onboardingStateUpdater: onboardingContextualDialogsManager
    )

    @MainActor
    private(set) lazy var newTabPageCoordinator: NewTabPageCoordinator = NewTabPageCoordinator(
        appearancePreferences: appearancePreferences,
        customizationModel: newTabPageCustomizationModel,
        bookmarkManager: bookmarkManager,
        faviconManager: faviconManager,
        duckPlayerHistoryEntryTitleProvider: duckPlayer,
        activeRemoteMessageModel: activeRemoteMessageModel,
        historyCoordinator: historyCoordinator,
        contentBlocking: privacyFeatures.contentBlocking,
        fireproofDomains: fireproofDomains,
        privacyStats: privacyStats,
        autoconsentStats: autoconsentStats,
        cookiePopupProtectionPreferences: cookiePopupProtectionPreferences,
        freemiumDBPPromotionViewCoordinator: freemiumDBPPromotionViewCoordinator,
        tld: tld,
        fireCoordinator: fireCoordinator,
        keyValueStore: keyValueStore,
        visualizeFireAnimationDecider: visualizeFireSettingsDecider,
        featureFlagger: featureFlagger,
        windowControllersManager: windowControllersManager,
        tabsPreferences: tabsPreferences,
        newTabPageAIChatShortcutSettingProvider: NewTabPageAIChatShortcutSettingProvider(aiChatMenuConfiguration: aiChatMenuConfiguration),
        winBackOfferPromotionViewCoordinator: winBackOfferPromotionViewCoordinator,
        subscriptionCardVisibilityManager: homePageSetUpDependencies.subscriptionCardVisibilityManager,
        protectionsReportModel: newTabPageProtectionsReportModel,
        homePageContinueSetUpModelPersistor: homePageSetUpDependencies.continueSetUpModelPersistor,
        nextStepsCardsPersistor: homePageSetUpDependencies.nextStepsCardsPersistor,
        subscriptionCardPersistor: homePageSetUpDependencies.subscriptionCardPersistor,
        duckPlayerPreferences: DuckPlayerPreferencesUserDefaultsPersistor(),
        syncService: syncService,
        pinningManager: pinningManager
    )

    private(set) lazy var aiChatTabOpener: AIChatTabOpening = AIChatTabOpener(
        promptHandler: AIChatPromptHandler.shared,
        aiChatTabManaging: windowControllersManager
    )

    private(set) lazy var newTabPageProtectionsReportModel: NewTabPageProtectionsReportModel = NewTabPageProtectionsReportModel(
        privacyStats: privacyStats,
        autoconsentStats: autoconsentStats,
        keyValueStore: keyValueStore,
        burnAnimationSettingChanges: visualizeFireSettingsDecider.shouldShowFireAnimationPublisher,
        showBurnAnimation: visualizeFireSettingsDecider.shouldShowFireAnimation,
        isAutoconsentEnabled: { self.cookiePopupProtectionPreferences.isAutoconsentEnabled },
        getLegacyIsViewExpandedSetting: settingsMigrator.isViewExpanded,
        getLegacyActiveFeedSetting: settingsMigrator.activeFeed
    )
    private let settingsMigrator = NewTabPageProtectionsReportSettingsMigrator(legacyKeyValueStore: UserDefaultsWrapper<Any>.sharedDefaults)

    private lazy var webNotificationClickHandler = WebNotificationClickHandler(tabFinder: windowControllersManager)

    lazy var vpnUpsellPopoverPresenter = DefaultVPNUpsellPopoverPresenter(
        subscriptionManager: subscriptionManager,
        featureFlagger: featureFlagger,
        vpnUpsellVisibilityManager: vpnUpsellVisibilityManager
    )

    private(set) lazy var sessionRestorePromptCoordinator = SessionRestorePromptCoordinator(pixelFiring: PixelKit.shared)

    private lazy var vpnAppEventsHandler = VPNAppEventsHandler(
        featureGatekeeper: DefaultVPNFeatureGatekeeper(vpnUninstaller: VPNUninstaller(pinningManager: pinningManager), subscriptionManager: subscriptionManager),
        featureFlagOverridesPublisher: featureFlagOverridesPublishingHandler.flagDidChangePublisher,
        loginItemsManager: LoginItemsManager(),
        defaults: .netP)

    private var vpnXPCClient: VPNControllerXPCClient {
        VPNControllerXPCClient.shared
    }

    lazy var vpnUpsellVisibilityManager: VPNUpsellVisibilityManager = {
        return VPNUpsellVisibilityManager(
            isNewUser: AppDelegate.isNewUser,
            subscriptionManager: subscriptionManager,
            defaultBrowserProvider: SystemDefaultBrowserProvider(),
            contextualOnboardingPublisher: onboardingContextualDialogsManager.isContextualOnboardingCompletedPublisher.eraseToAnyPublisher(),
            persistor: vpnUpsellUserDefaultsPersistor,
            timerDuration: vpnUpsellUserDefaultsPersistor.expectedUpsellTimeInterval
        )
    }()

    lazy var vpnUpsellUserDefaultsPersistor: VPNUpsellUserDefaultsPersistor = {
        return VPNUpsellUserDefaultsPersistor(keyValueStore: keyValueStore)
    }()

    // Note: Using UserDefaultsWrapper as legacy store here because the pre-existed code used it.
    lazy var homePageSetUpDependencies: HomePageSetUpDependencies = {
        return HomePageSetUpDependencies(subscriptionManager: subscriptionManager,
                                         keyValueStore: keyValueStore,
                                         legacyKeyValueStore: UserDefaultsWrapper<Any>.sharedDefaults)
    }()

    private lazy var dataBrokerProtectionSubscriptionEventHandler: DataBrokerProtectionSubscriptionEventHandler = {
        let authManager = DataBrokerAuthenticationManagerBuilder.buildAuthenticationManager(subscriptionManager: subscriptionManager)
        return DataBrokerProtectionSubscriptionEventHandler(featureDisabler: DataBrokerProtectionFeatureDisabler(),
                                                            authenticationManager: authManager,
                                                            pixelHandler: DataBrokerProtectionMacOSPixelsHandler())
    }()

    lazy var winBackOfferVisibilityManager: WinBackOfferVisibilityManaging = {
        let winBackOfferVisibilityManager: WinBackOfferVisibilityManaging
        let buildType = StandardApplicationBuildType()
        if buildType.isDebugBuild || buildType.isReviewBuild {
            let winBackOfferDebugStore = WinBackOfferDebugStore(keyValueStore: keyValueStore)
            let dateProvider: () -> Date = { winBackOfferDebugStore.simulatedTodayDate }
            winBackOfferVisibilityManager = WinBackOfferVisibilityManager(subscriptionManager: subscriptionManager,
                                                                        winbackOfferStore: winbackOfferStore,
                                                                        winbackOfferFeatureFlagProvider: winbackOfferFeatureFlagProvider,
                                                                        dateProvider: dateProvider,
                                                                        timeBeforeOfferAvailability: .seconds(5))
        } else {
            winBackOfferVisibilityManager = WinBackOfferVisibilityManager(subscriptionManager: subscriptionManager,
                                                                          winbackOfferStore: winbackOfferStore,
                                                                          winbackOfferFeatureFlagProvider: winbackOfferFeatureFlagProvider)
        }
        return winBackOfferVisibilityManager
    }()

    lazy var winbackOfferStore: WinbackOfferStoring = {
        return WinbackOfferStore(keyValueStore: keyValueStore)
    }()

    private lazy var winbackOfferFeatureFlagProvider: WinBackOfferFeatureFlagProvider = {
        return WinBackOfferFeatureFlagger(featureFlagger: featureFlagger)
    }()

    lazy var winBackOfferPromptPresenter: WinBackOfferPromptPresenting = {
        return WinBackOfferPromptPresenter(visibilityManager: winBackOfferVisibilityManager,
                                          subscriptionManager: subscriptionManager)
    }()

    lazy var winBackOfferPromotionViewCoordinator: WinBackOfferPromotionViewCoordinator = {
        return WinBackOfferPromotionViewCoordinator(winBackOfferVisibilityManager: winBackOfferVisibilityManager)
    }()

    private lazy var wideEventService: WideEventService = {
        return WideEventService(
            wideEvent: wideEvent,
            subscriptionManager: subscriptionManager
        )
    }()

    // MARK: - Init

    @MainActor
    init(dockCustomization: DockCustomization?) {
        let didCrashDuringCrashHandlersSetUp = UserDefaultsWrapper(key: .didCrashDuringCrashHandlersSetUp, defaultValue: false)
        _didCrashDuringCrashHandlersSetUp = didCrashDuringCrashHandlersSetUp
        self.dockCustomization = dockCustomization
        super.init()
    }

    // MARK: - Forwarding Properties (backward compatibility)
    // These forward to AppDependencies sub-containers so that existing call sites
    // (e.g. `Application.appDelegate.featureFlagger`) continue to compile.

    // -- Stores --
    var keyValueStore: ThrowingKeyValueStoring { appDependencies.stores.keyValueStore }
    var fileStore: FileStore { appDependencies.stores.fileStore }
    var database: Database! { appDependencies.stores.database }
    var bookmarkDatabase: BookmarkDatabase { appDependencies.stores.bookmarkDatabase }
    var configurationStore: ConfigurationStore {
        get { appDependencies.stores.configurationStore }
        set { appDependencies.stores.configurationStore = newValue }
    }

    // -- Feature Flags --
    var featureFlagger: FeatureFlagger { appDependencies.featureFlags.featureFlagger }
    var internalUserDecider: InternalUserDecider { appDependencies.featureFlags.internalUserDecider }
    var contentScopeExperimentsManager: ContentScopeExperimentsManaging { appDependencies.featureFlags.contentScopeExperimentsManager }
    var featureFlagOverridesPublishingHandler: FeatureFlagOverridesPublishingHandler<FeatureFlag> { appDependencies.featureFlags.featureFlagOverridesPublishingHandler }

    // -- Preferences --
    var appearancePreferences: AppearancePreferences { appDependencies.preferences.appearancePreferences }
    var dataClearingPreferences: DataClearingPreferences { appDependencies.preferences.dataClearingPreferences }
    var startupPreferences: StartupPreferences { appDependencies.preferences.startupPreferences }
    var defaultBrowserPreferences: DefaultBrowserPreferences { appDependencies.preferences.defaultBrowserPreferences }
    var downloadsPreferences: DownloadsPreferences { appDependencies.preferences.downloadsPreferences }
    var searchPreferences: SearchPreferences { appDependencies.preferences.searchPreferences }
    var tabsPreferences: TabsPreferences { appDependencies.preferences.tabsPreferences }
    var webTrackingProtectionPreferences: WebTrackingProtectionPreferences { appDependencies.preferences.webTrackingProtectionPreferences }
    var cookiePopupProtectionPreferences: CookiePopupProtectionPreferences { appDependencies.preferences.cookiePopupProtectionPreferences }
    var aboutPreferences: AboutPreferences { appDependencies.preferences.aboutPreferences }
    var accessibilityPreferences: AccessibilityPreferences { appDependencies.preferences.accessibilityPreferences }
    var contentScopePreferences: ContentScopePreferences { appDependencies.preferences.contentScopePreferences }
    var aiChatPreferences: AIChatPreferences { appDependencies.preferences.aiChatPreferences }

    // -- Services --
    var configurationManager: ConfigurationManager {
        get { appDependencies.services.configurationManager }
        set { appDependencies.services.configurationManager = newValue }
    }
    var configurationURLProvider: CustomConfigurationURLProviding {
        get { appDependencies.services.configurationURLProvider }
        set { appDependencies.services.configurationURLProvider = newValue }
    }
    var bookmarkManager: LocalBookmarkManager { appDependencies.services.bookmarkManager }
    var historyCoordinator: HistoryCoordinator { appDependencies.services.historyCoordinator }
    var faviconManager: FaviconManager { appDependencies.services.faviconManager }
    var fireproofDomains: FireproofDomains { appDependencies.services.fireproofDomains }
    var permissionManager: PermissionManager { appDependencies.services.permissionManager }
    var downloadManager: FileDownloadManagerProtocol { appDependencies.services.downloadManager }
    var downloadListCoordinator: DownloadListCoordinator { appDependencies.services.downloadListCoordinator }
    var privacyStats: PrivacyStatsCollecting { appDependencies.services.privacyStats }
    var autoconsentStats: AutoconsentStatsCollecting { appDependencies.services.autoconsentStats }
    var remoteMessagingClient: RemoteMessagingClient! { appDependencies.services.remoteMessagingClient }
    var activeRemoteMessageModel: ActiveRemoteMessageModel { appDependencies.services.activeRemoteMessageModel }
    var syncService: DDGSyncing? {
        get { appDependencies.services.syncService }
        set { appDependencies.services.syncService = newValue }
    }
    var syncDataProviders: SyncDataProvidersSource? {
        get { appDependencies.services.syncDataProviders }
        set { appDependencies.services.syncDataProviders = newValue }
    }
    var syncErrorHandler: SyncErrorHandler {
        get { appDependencies.services.syncErrorHandler }
        set { appDependencies.services.syncErrorHandler = newValue }
    }
    var webCacheManager: WebCacheManager { appDependencies.services.webCacheManager }
    var watchdog: Watchdog { appDependencies.services.watchdog }
    var autoClearHandler: AutoClearHandler! {
        get { appDependencies.services.autoClearHandler }
        set { appDependencies.services.autoClearHandler = newValue }
    }
    var privacyFeatures: AnyPrivacyFeatures { appDependencies.services.privacyFeatures }
    var tld: TLD { appDependencies.services.tld }
    var autoconsentManagement: AutoconsentManagement { appDependencies.services.autoconsentManagement }
    var brokenSitePromptLimiter: BrokenSitePromptLimiter { appDependencies.services.brokenSitePromptLimiter }
    var notificationService: UserNotificationAuthorizationServicing { appDependencies.services.notificationService }
    var onboardingContextualDialogsManager: ContextualOnboardingDialogTypeProviding & ContextualOnboardingStateUpdater { appDependencies.services.onboardingContextualDialogsManager }
    var defaultBrowserAndDockPromptService: DefaultBrowserAndDockPromptService { appDependencies.services.defaultBrowserAndDockPromptService }
    var userChurnScheduler: UserChurnBackgroundActivityScheduler { appDependencies.services.userChurnScheduler }
    var bitwardenManager: BWManagement? { appDependencies.services.bitwardenManager }
    var passwordManagerCoordinator: PasswordManagerCoordinator { appDependencies.services.passwordManagerCoordinator }
    var attributedMetricManager: AttributedMetricManager { appDependencies.services.attributedMetricManager }
    var memoryUsageMonitor: MemoryUsageMonitor { appDependencies.services.memoryUsageMonitor }
    var memoryPressureReporter: MemoryPressureReporter? {
        get { appDependencies.services.memoryPressureReporter }
        set { appDependencies.services.memoryPressureReporter = newValue }
    }
    var memoryUsageThresholdReporter: MemoryUsageThresholdReporter { appDependencies.services.memoryUsageThresholdReporter }
    var memoryUsageIntervalReporter: MemoryUsageIntervalReporter? {
        get { appDependencies.services.memoryUsageIntervalReporter }
        set { appDependencies.services.memoryUsageIntervalReporter = newValue }
    }
    var startupProfiler: StartupProfiler { appDependencies.services.startupProfiler }
    var duckPlayer: DuckPlayer { appDependencies.services.duckPlayer }
    var newTabPageCustomizationModel: NewTabPageCustomizationModel { appDependencies.services.newTabPageCustomizationModel }
    var vpnSettings: VPNSettings { appDependencies.services.vpnSettings }
    var freemiumDBPFeature: FreemiumDBPFeature { appDependencies.services.freemiumDBPFeature }
    var freemiumDBPPromotionViewCoordinator: FreemiumDBPPromotionViewCoordinator { appDependencies.services.freemiumDBPPromotionViewCoordinator }
    var blackFridayCampaignProvider: BlackFridayCampaignProviding { appDependencies.services.blackFridayCampaignProvider }
    var wideEvent: WideEventManaging { appDependencies.services.wideEvent }
    var urlEventHandler: URLEventHandler { appDependencies.services.urlEventHandler }
    var tabCrashAggregator: TabCrashAggregator { appDependencies.services.tabCrashAggregator }
    var grammarFeaturesManager: GrammarFeaturesManager { appDependencies.services.grammarFeaturesManager }
    var webExtensionAvailability: WebExtensionAvailabilityProviding { appDependencies.services.webExtensionAvailability }
    var aiChatSessionStore: AIChatSessionStoring { appDependencies.services.aiChatSessionStore }
    var aiChatMenuConfiguration: AIChatMenuVisibilityConfigurable { appDependencies.services.aiChatMenuConfiguration }
    var visualizeFireSettingsDecider: VisualizeFireSettingsDecider { appDependencies.services.visualizeFireSettingsDecider }
    var stateRestorationManager: AppStateRestorationManager! {
        get { appDependencies.services.stateRestorationManager }
        set { appDependencies.services.stateRestorationManager = newValue }
    }
    private(set) var appIconChanger: AppIconChanger! {
        get { appDependencies.services.appIconChanger }
        set { appDependencies.services.appIconChanger = newValue }
    }
    var launchOptionsHandler: LaunchOptionsHandler { appDependencies.services.launchOptionsHandler }
    var updateController: UpdateController? {
        get { appDependencies.services.updateController }
        set { appDependencies.services.updateController = newValue }
    }
    var crashReporting: any CrashReporting { appDependencies.services.crashReporting }

    // -- UI --
    var windowControllersManager: WindowControllersManager { appDependencies.ui.windowControllersManager }
    var pinnedTabsManager: PinnedTabsManager { appDependencies.ui.pinnedTabsManager }
    var pinnedTabsManagerProvider: PinnedTabsManagerProvider { appDependencies.ui.pinnedTabsManagerProvider }
    var themeManager: ThemeManager { appDependencies.ui.themeManager }
    var fireCoordinator: FireCoordinator { appDependencies.ui.fireCoordinator }
    var recentlyClosedCoordinator: RecentlyClosedCoordinating { appDependencies.ui.recentlyClosedCoordinator }
    var tabDragAndDropManager: TabDragAndDropManager { appDependencies.ui.tabDragAndDropManager }
    var bookmarkDragDropManager: BookmarkDragDropManager { appDependencies.ui.bookmarkDragDropManager }
    var pinningManager: LocalPinningManager { appDependencies.ui.pinningManager }

    // -- Subscription --
    var subscriptionManager: any SubscriptionManager { appDependencies.subscription.subscriptionManager }
    var subscriptionUIHandler: SubscriptionUIHandling { appDependencies.subscription.subscriptionUIHandler }
    var subscriptionNavigationCoordinator: SubscriptionNavigationCoordinator { appDependencies.subscription.subscriptionNavigationCoordinator }
    var freeTrialConversionService: FreeTrialConversionInstrumentationService { appDependencies.subscription.freeTrialConversionService }

    func applicationWillFinishLaunching(_ notification: Notification) {
        appStateMachine = AppStateMachine(initialState: .initializing(Initializing()))
        appStateMachine.handle(.willFinishLaunching)
        appStateMachine.handle(.didFinishLaunching)
        // State is now .launching — extract dependencies for forwarding properties
        if case .launching(let launching) = appStateMachine.currentState,
           let concreteState = launching as? Launching {
            appDependencies = concreteState.dependencies
        } else {
            fatalError("Expected .launching state after didFinishLaunching")
        }

        let profilerToken = startupProfiler.startMeasuring(.appWillFinishLaunching)
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
            try DefaultReinstallUserDetection(keyValueStore: keyValueStore).checkForReinstallingUser()
        } catch {
            Logger.general.error("Problem when checking for reinstalling user: \(error.localizedDescription)")
        }

        APIRequest.Headers.setUserAgent(UserAgent.duckDuckGoUserAgent())

        stateRestorationManager = AppStateRestorationManager(fileStore: fileStore,
                                                             startupPreferences: startupPreferences,
                                                             tabsPreferences: tabsPreferences,
                                                             keyValueStore: keyValueStore,
                                                             sessionRestorePromptCoordinator: sessionRestorePromptCoordinator,
                                                             pixelFiring: PixelKit.shared)

        initializeUpdateController()

        appIconChanger = AppIconChanger(internalUserDecider: internalUserDecider, appearancePreferences: appearancePreferences)

        if AppVersion.runType.requiresEnvironment {
            // Configure Event handlers
            let vpnUninstaller = VPNUninstaller(pinningManager: pinningManager, ipcClient: vpnXPCClient)
            let featureGatekeeper = DefaultVPNFeatureGatekeeper(vpnUninstaller: vpnUninstaller, subscriptionManager: subscriptionManager)
            let tunnelController = NetworkProtectionIPCTunnelController(featureGatekeeper: featureGatekeeper, ipcClient: vpnXPCClient)

            vpnSubscriptionEventHandler = VPNSubscriptionEventsHandler(subscriptionManager: subscriptionManager,
                                                                       tunnelController: tunnelController,
                                                                       vpnUninstaller: vpnUninstaller)

            // Freemium DBP
            freemiumDBPFeature.subscribeToDependencyUpdates()
        }

        // ignore popovers shown from a view not in view hierarchy
        // https://app.asana.com/0/1201037661562251/1206407295280737/f
        _ = NSPopover.swizzleShowRelativeToRectOnce
        // disable macOS system-wide window tabbing
        NSWindow.allowsAutomaticWindowTabbing = false
        // Fix SwifUI context menus and its owner View leaking
        SwiftUIContextMenuRetainCycleFix.setUp()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard AppVersion.runType.requiresEnvironment else { return }

        defer {
            didFinishLaunching = true
        }

        let profilerToken = startupProfiler.measureSequence(initialStep: .appDidFinishLaunchingBeforeRestoration)

        Task {
            await subscriptionManager.loadInitialData()

            vpnAppEventsHandler.applicationDidFinishLaunching()
        }

        historyCoordinator.loadHistory {
            self.historyCoordinator.migrateModelV5toV6IfNeeded()
        }

        privacyFeatures.httpsUpgrade.loadDataAsync()
        bookmarkManager.loadBookmarks()

        // Force use of .mainThread to prevent high WindowServer Usage
        // Pending Fix with newer Lottie versions
        // https://app.asana.com/0/1177771139624306/1207024603216659/f
        LottieConfiguration.shared.renderingEngine = .mainThread

        configurationManager.start()

        let isFirstLaunch = LocalStatisticsStore().atb == nil

        if isFirstLaunch {
            AppDelegate.firstLaunchDate = Date()
        }

        setupWebExtensions()

        vpnUpsellVisibilityManager.setup(isFirstLaunch: isFirstLaunch, isOnboardingFinished: OnboardingActionsManager.isOnboardingFinished)

        AtbAndVariantCleanup.cleanup()
        DefaultVariantManager().assignVariantIfNeeded { _ in
            // MARK: perform first time launch logic here
        }

        let statisticsLoader = AppVersion.runType.requiresEnvironment ? StatisticsLoader.shared : nil
        statisticsLoader?.load()

        startupSync()

        profilerToken.advance(to: .appStateRestoration)

        if AppVersion.runType.stateRestorationAllowed {
            stateRestorationManager.applicationDidFinishLaunching()
        }

        profilerToken.advance(to: .appDidFinishLaunchingAfterRestoration)

        let urlEventHandlerResult = urlEventHandler.applicationDidFinishLaunching()

        setUpAutoClearHandler()
        bitwardenManager?.initCommunication()

        if AppVersion.runType.opensWindowOnStartupIfNeeded,
           !urlEventHandlerResult.willOpenWindows && WindowsManager.windows.first(where: { $0 is MainWindow }) == nil {
            // Use startup window preferences if not restoring previous session
            if !startupPreferences.restorePreviousSession {
                let burnerMode = startupPreferences.startupBurnerMode()
                WindowsManager.openNewWindow(burnerMode: burnerMode, lazyLoadTabs: true)
            } else {
                WindowsManager.openNewWindow(lazyLoadTabs: true)
            }
        }

        grammarFeaturesManager.manage()

        applyPreferredTheme()

        if case .normal = AppVersion.runType {
            Task {
                await crashReporting.start()
            }
        }

        subscribeToEmailProtectionStatusNotifications()
        subscribeToDataImportCompleteNotification()
        subscribeToInternalUserChanges()
        subscribeToUpdateControllerChanges()

        fireFailedCompilationsPixelIfNeeded()

        UserDefaultsWrapper<Any>.clearRemovedKeys()

        vpnSubscriptionEventHandler?.startMonitoring()

        UNUserNotificationCenter.current().delegate = self

        dataBrokerProtectionSubscriptionEventHandler.registerForSubscriptionAccountManagerEvents()

        let freemiumDBPUserStateManager = DefaultFreemiumDBPUserStateManager(userDefaults: .dbp)
        let pirGatekeeper = DefaultDataBrokerProtectionFeatureGatekeeper(
            privacyConfigurationManager: privacyFeatures.contentBlocking.privacyConfigurationManager,
            subscriptionManager: subscriptionManager,
            freemiumDBPUserStateManager: freemiumDBPUserStateManager
        )

        DataBrokerProtectionAppEvents(featureGatekeeper: pirGatekeeper).applicationDidFinishLaunching()

        TipKitAppEventHandler(featureFlagger: featureFlagger).appDidFinishLaunching()

        setUpAutofillPixelReporter()
        setUpPasswordsMenuBarVisibility()

        remoteMessagingClient?.startRefreshingRemoteMessages()

        // This messaging system has been replaced by RMF, but we need to clean up the message manifest for any users who had it stored.
        let deprecatedRemoteMessagingStorage = DefaultSurveyRemoteMessagingStorage.surveys()
        deprecatedRemoteMessagingStorage.removeStoredMessagesIfNecessary()

        if didCrashDuringCrashHandlersSetUp {
            PixelKit.fire(GeneralPixel.crashOnCrashHandlersSetUp)
            didCrashDuringCrashHandlersSetUp = false
        }

        freemiumDBPScanResultPolling = DefaultFreemiumDBPScanResultPolling(dataManager: DataBrokerProtectionManager.shared.dataManager, freemiumDBPUserStateManager: freemiumDBPUserStateManager)
        freemiumDBPScanResultPolling?.startPollingOrObserving()

        Task(priority: .utility) {
            await wideEventService.sendPendingEvents()
        }

        userChurnScheduler.start()

        memoryUsageMonitor.enableIfNeeded(featureFlagger: featureFlagger)

        startAutomationServerIfNeeded()

        PixelKit.fire(GeneralPixel.launch, doNotEnforcePrefix: true)
        profilerToken.stop()
    }

    private func fireFailedCompilationsPixelIfNeeded() {
        let store = FailedCompilationsStore()
        if store.hasAnyFailures {
            PixelKit.fire(DebugEvent(GeneralPixel.compilationFailed),
                          frequency: .legacyDaily,
                          withAdditionalParameters: store.summary,
                          includeAppVersionParameter: true) { didFire, _ in
                if !didFire {
                    store.cleanup()
                }
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard didFinishLaunching else { return }
        appStateMachine.handle(.didBecomeActive)

        // Fire quit survey return user pixel if the user completed the survey and returned within 8-14 day window
        let quitSurveyPersistor = QuitSurveyUserDefaultsPersistor(keyValueStore: keyValueStore)
        QuitSurveyReturnUserHandler(
            persistor: quitSurveyPersistor,
            installDate: AppDelegate.firstLaunchDate
        ).fireReturnUserPixelIfNeeded()

        fireDailyActiveUserPixels()
        fireDailyFireWindowConfigurationPixels()

        fireAutoconsentDailyPixel()
        fireThemeDailyPixel()

        initializeSync()

        let freemiumDBPUserStateManager = DefaultFreemiumDBPUserStateManager(userDefaults: .dbp)
        let pirGatekeeper = DefaultDataBrokerProtectionFeatureGatekeeper(
            privacyConfigurationManager: privacyFeatures.contentBlocking.privacyConfigurationManager,
            subscriptionManager: subscriptionManager,
            freemiumDBPUserStateManager: freemiumDBPUserStateManager
        )

        DataBrokerProtectionAppEvents(featureGatekeeper: pirGatekeeper).applicationDidBecomeActive()

        Task { @MainActor in
            vpnAppEventsHandler.applicationDidBecomeActive()
        }

        defaultBrowserAndDockPromptService.applicationDidBecomeActive()

        Task { @MainActor in
            await autoconsentStatsPopoverCoordinator.checkAndShowDialogIfNeeded()
        }
    }

    private func fireDailyActiveUserPixels() {
        PixelKit.fire(GeneralPixel.dailyActiveUser, frequency: .legacyDaily, doNotEnforcePrefix: true)
        PixelKit.fire(GeneralPixel.dailyDefaultBrowser(isDefault: defaultBrowserPreferences.isDefault), frequency: .daily, doNotEnforcePrefix: true)
        if let dockCustomization {
            PixelKit.fire(GeneralPixel.dailyAddedToDock(isAddedToDock: dockCustomization.isAddedToDock), frequency: .daily, doNotEnforcePrefix: true)
        }
    }

    private func fireDailyFireWindowConfigurationPixels() {
        PixelKit.fire(GeneralPixel.dailyFireWindowConfigurationStartupFireWindowEnabled(
            startupFireWindow: startupPreferences.startupWindowType == .fireWindow
        ), frequency: .daily, doNotEnforcePrefix: true)

        PixelKit.fire(GeneralPixel.dailyFireWindowConfigurationOpenFireWindowByDefaultEnabled(
            openFireWindowByDefault: dataClearingPreferences.shouldOpenFireWindowByDefault
        ), frequency: .daily, doNotEnforcePrefix: true)

        PixelKit.fire(GeneralPixel.dailyFireWindowConfigurationFireAnimationEnabled(
            fireAnimationEnabled: dataClearingPreferences.isFireAnimationEnabled
        ), frequency: .daily, doNotEnforcePrefix: true)
    }

    private func fireAutoconsentDailyPixel() {
        Task {
            let dailyStats = await autoconsentStats.fetchAutoconsentDailyUsagePack().asPixelParameters()
            PixelKit.fire(AutoconsentPixel.usageStats(stats: dailyStats), frequency: .daily)
        }
    }

    private func fireThemeDailyPixel() {
        PixelKit.fire(ThemePixels.themeNameDaily(themeName: themeManager.theme.name), frequency: .daily)
    }

    private func initializeSync() {
        guard let syncService else { return }
        syncService.initializeIfNeeded()
        syncService.scheduler.notifyAppLifecycleEvent()
        SyncDiagnosisHelper(syncService: syncService).diagnoseAccountStatus()
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

            self.updateController = appStoreFactory.instantiate(
                internalUserDecider: internalUserDecider,
                featureFlagger: featureFlagger,
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
                internalUserDecider: internalUserDecider,
                featureFlagger: featureFlagger,
                pixelFiring: PixelKit.shared,
                notificationPresenter: notificationPresenter,
                keyValueStore: UserDefaults.standard,
                allowCustomUpdateFeed: allowCustomUpdateFeed,
                wideEvent: wideEvent,
                isOnboardingFinished: { OnboardingActionsManager.isOnboardingFinished },
                openUpdatesPage: { [windowControllersManager] in
                    windowControllersManager.showTab(with: .releaseNotes)
                }
            )
            stateRestorationManager.subscribeToAutomaticAppRelaunching(using: sparkleUpdateController.willRelaunchAppPublisher)
            self.updateController = sparkleUpdateController
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        return appStateMachine.handleTerminationRequest()
    }

    // MARK: - Automation Server

    private func startAutomationServerIfNeeded() {
        let buildType = StandardApplicationBuildType()
        guard buildType.isDebugBuild || buildType.isReviewBuild,
              let port = launchOptionsHandler.automationPort else {
            return
        }
        Task { @MainActor in
            automationServer = AutomationServer(
                windowControllersManager: windowControllersManager,
                contentBlockingManager: privacyFeatures.contentBlocking.contentBlockingManager,
                port: port
            )
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if Application.appDelegate.windowControllersManager.mainWindowControllers.isEmpty,
           case .normal = AppVersion.runType {
            // Use startup window preferences when reopening from dock
            let burnerMode = startupPreferences.startupBurnerMode()
            WindowsManager.openNewWindow(burnerMode: burnerMode)
            return true
        }
        return true
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        return ApplicationDockMenu(internalUserDecider: internalUserDecider, isFireWindowDefault: visualizeFireSettingsDecider.isOpenFireWindowByDefaultEnabled)
    }

    func application(_ sender: NSApplication, openFiles files: [String]) {
        urlEventHandler.handleFiles(files)
    }

    // MARK: - Web Extensions

    @MainActor
    private func setupWebExtensions() {
        guard #available(macOS 15.4, *) else { return }

        let darkReaderSettings = AppDarkReaderFeatureSettings(
            featureFlagger: featureFlagger,
            privacyConfigurationManager: privacyFeatures.contentBlocking.privacyConfigurationManager,
            storage: keyValueStore.throwingKeyedStoring(),
            currentThemeProvider: appearancePreferences,
            pixelFiring: PixelKit.shared
        )
        self.darkReaderFeatureSettings = darkReaderSettings
        appearancePreferences.darkReaderFeatureSettings = darkReaderSettings

        darkReaderSettings.forceDarkModeChangedPublisher
            .sink { [weak self] _ in
                Task { @MainActor in
                    await self?.syncEmbeddedExtensions()
                }
            }
            .store(in: &darkReaderCancellables)

        appearancePreferences.$themeAppearance
            .dropFirst()
            .sink { [weak self] _ in
                self?.darkReaderFeatureSettings?.themeDidChange()
            }
            .store(in: &darkReaderCancellables)

        let webExtensionsPublisher = featureFlagger.updatesPublisher
            .compactMap { [weak featureFlagger] in
                featureFlagger?.isFeatureOn(.webExtensions)
            }
            .removeDuplicates()
            .eraseToAnyPublisher()

        let embeddedExtensionPublisher = featureFlagger.updatesPublisher
            .compactMap { [weak featureFlagger] in
                featureFlagger?.isFeatureOn(.embeddedExtension)
            }
            .removeDuplicates()
            .eraseToAnyPublisher()

        webExtensionFeatureFlagHandler = WebExtensionFeatureFlagHandler(
            webExtensionManagerProvider: { [weak self] in self?.webExtensionManager },
            featureFlagPublisher: webExtensionsPublisher,
            embeddedExtensionFlagPublisher: embeddedExtensionPublisher,
            onFeatureFlagEnabled: { [weak self] in
                await self?.initializeWebExtensions()
            },
            onFeatureFlagDisabled: { [weak self] in
                self?.webExtensionManager = nil
            },
            onEmbeddedExtensionFlagEnabled: { [weak self] in
                await self?.syncEmbeddedExtensions()
            }
        )

        if featureFlagger.isFeatureOn(.webExtensions) {
            // Create manager synchronously so it's available during state restoration.
            // Tabs restored before the manager exists won't have webExtensionController attached.
            let webExtensionManager = WebExtensionManagerFactory.makeManager(
                privacyConfigurationManager: privacyFeatures.contentBlocking.privacyConfigurationManager,
                autoconsentPreferences: cookiePopupProtectionPreferences,
                darkReaderExcludedDomainsProvider: darkReaderSettings
            )
            self.webExtensionManager = webExtensionManager

            // Load extensions asynchronously - the controller is already attached to tabs
            Task {
                await webExtensionManager.loadInstalledExtensions()
                await syncEmbeddedExtensions()
            }
        } else {
            webExtensionManager = nil
        }
    }

    @available(macOS 15.4, *)
    @MainActor
    private func initializeWebExtensions() async {
        guard webExtensionManager == nil else {
            // Already initialized, just load extensions
            await (webExtensionManager as? WebExtensionManager)?.loadInstalledExtensions()
            await syncEmbeddedExtensions()
            return
        }

        let webExtensionManager = WebExtensionManagerFactory.makeManager(
            privacyConfigurationManager: privacyFeatures.contentBlocking.privacyConfigurationManager,
            autoconsentPreferences: cookiePopupProtectionPreferences,
            darkReaderExcludedDomainsProvider: darkReaderFeatureSettings
        )
        self.webExtensionManager = webExtensionManager

        await webExtensionManager.loadInstalledExtensions()
        await syncEmbeddedExtensions()
    }

    @available(macOS 15.4, *)
    @MainActor
    private func syncEmbeddedExtensions() async {
        guard !isSyncingEmbeddedExtensions else { return }
        guard let webExtensionManager = webExtensionManager as? WebExtensionManager else { return }

        isSyncingEmbeddedExtensions = true
        defer { isSyncingEmbeddedExtensions = false }

        var enabledTypes: Set<DuckDuckGoWebExtensionType> = []
        if featureFlagger.isFeatureOn(.embeddedExtension) {
            enabledTypes.insert(.embedded)
        }
        if darkReaderFeatureSettings?.isForceDarkModeEnabled == true {
            enabledTypes.insert(.darkReader)
        }
        await webExtensionManager.syncEmbeddedExtensions(enabledTypes: enabledTypes)
    }

    // MARK: - PixelKit

    static func configurePixelKit() {
        Self.setUpPixelKit(dryRun: PixelKitConfig.isDryRun(isProductionBuild: BuildFlags.isProductionBuild))
    }

    private static func setUpPixelKit(dryRun: Bool) {
        let source = NSApp.isSandboxed ? "browser-appstore" : "browser-dmg"
        let userAgent = UserAgent.duckDuckGoUserAgent()

        PixelKit.setUp(dryRun: dryRun,
                       appVersion: AppVersion.shared.versionNumber,
                       source: source,
                       defaultHeaders: [:],
                       defaults: .netP) { (pixelName: String, headers: [String: String], parameters: [String: String], _, _, onComplete: @escaping PixelKit.CompletionBlock) in

            let url = URL.pixelUrl(forPixelNamed: pixelName)
            let apiHeaders = APIRequest.Headers(userAgent: userAgent, additionalHeaders: headers)
            let configuration = APIRequest.Configuration(url: url, method: .get, queryParameters: parameters, headers: apiHeaders)
            let request = APIRequest(configuration: configuration)

            request.fetch { _, error in
                onComplete(error == nil, error)
            }
        }
    }

    // MARK: - Theme

    private func applyPreferredTheme() {
        appearancePreferences.updateUserInterfaceStyle()
    }

    // MARK: - Sync

    @MainActor private func startupSync() {
#if DEBUG
        let defaultEnvironment = ServerEnvironment.development
#else
        let defaultEnvironment = ServerEnvironment.production
#endif

        let environment: ServerEnvironment
        let buildType = StandardApplicationBuildType()
        if buildType.isDebugBuild || buildType.isReviewBuild {
            environment = ServerEnvironment(
                UserDefaultsWrapper(key: .syncEnvironment, defaultValue: defaultEnvironment.description).wrappedValue
            ) ?? defaultEnvironment
        } else {
            environment = defaultEnvironment
        }
        let syncDataProviders = SyncDataProvidersSource(
            bookmarksDatabase: bookmarkDatabase.db,
            bookmarkManager: bookmarkManager,
            appearancePreferences: appearancePreferences,
            syncErrorHandler: syncErrorHandler
        )
        let syncService = DDGSync(
            dataProvidersSource: syncDataProviders,
            errorEvents: SyncErrorHandler(),
            privacyConfigurationManager: privacyFeatures.contentBlocking.privacyConfigurationManager,
            keyValueStore: keyValueStore,
            environment: environment
        )
        let aiChatSyncCleaner = AIChatSyncCleaner(
            sync: syncService,
            keyValueStore: keyValueStore,
            featureFlagProvider: AIChatFeatureFlagProvider(featureFlagger: featureFlagger),
            httpRequestErrorHandler: syncErrorHandler.handleAiChatsError
        )
        syncService.setCustomOperations([AIChatDeleteOperation(cleaner: aiChatSyncCleaner)])

        syncService.initializeIfNeeded()
        syncDataProviders.setUpDatabaseCleaners(syncService: syncService)

        // This is also called in applicationDidBecomeActive, but we're also calling it here, since
        // syncService can be nil when applicationDidBecomeActive is called during startup, if a modal
        // alert is shown before it's instantiated.  In any case it should be safe to call this here,
        // since the scheduler debounces calls to notifyAppLifecycleEvent().
        //
        syncService.scheduler.notifyAppLifecycleEvent()

        self.syncDataProviders = syncDataProviders
        self.syncService = syncService
        self.aiChatSyncCleaner = aiChatSyncCleaner

        isSyncInProgressCancellable = syncService.isSyncInProgressPublisher
            .filter { $0 }
            .asVoid()
            .sink { [weak syncService] in
                PixelKit.fire(GeneralPixel.syncDaily, frequency: .legacyDailyNoSuffix)
                syncService?.syncDailyStats.sendStatsIfNeeded(handler: { params in
                    PixelKit.fire(GeneralPixel.syncSuccessRateDaily, withAdditionalParameters: params)
                })
            }

        subscribeSyncQueueToScreenLockedNotifications()
        subscribeToSyncFeatureFlags(syncService)
    }

    @UserDefaultsWrapper(key: .syncDidShowSyncPausedByFeatureFlagAlert, defaultValue: false)
    private var syncDidShowSyncPausedByFeatureFlagAlert: Bool

    private func subscribeToSyncFeatureFlags(_ syncService: DDGSync) {
        syncFeatureFlagsCancellable = syncService.featureFlagsPublisher
            .dropFirst()
            .map { $0.contains(.dataSyncing) }
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak syncService] isDataSyncingAvailable in
                if isDataSyncingAvailable {
                    self?.syncDidShowSyncPausedByFeatureFlagAlert = false
                } else if syncService?.authState == .active, self?.syncDidShowSyncPausedByFeatureFlagAlert == false {
                    let isSyncUIVisible = syncService?.featureFlags.contains(.userInterface) == true
                    let alert = NSAlert.dataSyncingDisabledByFeatureFlag(showLearnMore: isSyncUIVisible)
                    let response = alert.runModal()
                    self?.syncDidShowSyncPausedByFeatureFlagAlert = true

                    switch response {
                    case .alertSecondButtonReturn:
                        alert.window.sheetParent?.endSheet(alert.window)
                        DispatchQueue.main.async {
                            Application.appDelegate.windowControllersManager.showPreferencesTab(withSelectedPane: .sync)
                        }
                    default:
                        break
                    }
                }
            }
    }

    private func subscribeSyncQueueToScreenLockedNotifications() {
        let screenIsLockedPublisher = DistributedNotificationCenter.default
            .publisher(for: .init(rawValue: "com.apple.screenIsLocked"))
            .map { _ in true }
        let screenIsUnlockedPublisher = DistributedNotificationCenter.default
            .publisher(for: .init(rawValue: "com.apple.screenIsUnlocked"))
            .map { _ in false }

        screenLockedCancellable = Publishers.Merge(screenIsLockedPublisher, screenIsUnlockedPublisher)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isLocked in
                guard let syncService = self?.syncService, syncService.authState != .inactive else {
                    return
                }
                if isLocked {
                    Logger.sync.debug("Screen is locked")
                    syncService.scheduler.cancelSyncAndSuspendSyncQueue()
                } else {
                    Logger.sync.debug("Screen is unlocked")
                    syncService.scheduler.resumeSyncQueue()
                }
            }
    }

    private func subscribeToEmailProtectionStatusNotifications() {
        NotificationCenter.default.publisher(for: .emailDidSignIn)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.emailDidSignInNotification(notification)
            }
            .store(in: &emailCancellables)

        NotificationCenter.default.publisher(for: .emailDidSignOut)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.emailDidSignOutNotification(notification)
            }
            .store(in: &emailCancellables)
    }

    private func subscribeToDataImportCompleteNotification() {
        NotificationCenter.default.addObserver(self, selector: #selector(dataImportCompleteNotification(_:)), name: .dataImportComplete, object: nil)
    }

    private func subscribeToInternalUserChanges() {
        UserDefaults.appConfiguration.isInternalUser = internalUserDecider.isInternalUser

        isInternalUserSharingCancellable = internalUserDecider.isInternalUserPublisher
            .assign(to: \.isInternalUser, onWeaklyHeld: UserDefaults.appConfiguration)
    }

    private func subscribeToUpdateControllerChanges() {
        guard AppVersion.runType.allowsUpdates,
              let sparkleUpdateController = updateController as? any SparkleUpdateControlling else { return }

        updateProgressCancellable = sparkleUpdateController.updateProgressPublisher
            .sink { [weak sparkleUpdateController] progress in
                sparkleUpdateController?.checkNewApplicationVersionIfNeeded(updateProgress: progress)
            }
    }

    private func emailDidSignInNotification(_ notification: Notification) {
        PixelKit.fire(NonStandardPixel.emailEnabled, doNotEnforcePrefix: true)
        if AppDelegate.isNewUser {
            PixelKit.fire(GeneralPixel.emailEnabledInitial, frequency: .legacyInitial)
        }

        if let object = notification.object as? EmailManager, let emailManager = syncDataProviders?.settingsAdapter.emailManager, object !== emailManager {
            syncService?.scheduler.notifyDataChanged()
        }
    }

    private func emailDidSignOutNotification(_ notification: Notification) {
        PixelKit.fire(NonStandardPixel.emailDisabled, doNotEnforcePrefix: true)
        if let object = notification.object as? EmailManager, let emailManager = syncDataProviders?.settingsAdapter.emailManager, object !== emailManager {
            syncService?.scheduler.notifyDataChanged()
        }
    }

    @objc private func dataImportCompleteNotification(_ notification: Notification) {
        if AppDelegate.isNewUser {
            PixelKit.fire(GeneralPixel.importDataInitial, frequency: .legacyInitial)
        }
    }

    @MainActor
    private func setUpAutoClearHandler() {
        let autoClearHandler = AutoClearHandler(dataClearingPreferences: dataClearingPreferences,
                                                startupPreferences: startupPreferences,
                                                fireViewModel: fireCoordinator.fireViewModel,
                                                stateRestorationManager: self.stateRestorationManager,
                                                aiChatSyncCleaner: aiChatSyncCleaner)
        self.autoClearHandler = autoClearHandler
        DispatchQueue.main.async {
            autoClearHandler.handleAppLaunch()
        }
    }

    private func setUpAutofillPixelReporter() {
        autofillPixelReporter = AutofillPixelReporter(
            usageStore: AutofillUsageStore(standardUserDefaults: .standard, appGroupUserDefaults: nil),
            autofillEnabled: AutofillPreferences().askToSaveUsernamesAndPasswords,
            eventMapping: EventMapping<AutofillPixelEvent> {event, _, params, _ in
                switch event {
                case .autofillActiveUser:
                    PixelKit.fire(GeneralPixel.autofillActiveUser, withAdditionalParameters: params)
                case .autofillEnabledUser:
                    PixelKit.fire(GeneralPixel.autofillEnabledUser)
                case .autofillOnboardedUser:
                    PixelKit.fire(GeneralPixel.autofillOnboardedUser)
                case .autofillToggledOn:
                    PixelKit.fire(GeneralPixel.autofillToggledOn, withAdditionalParameters: params)
                case .autofillToggledOff:
                    PixelKit.fire(GeneralPixel.autofillToggledOff, withAdditionalParameters: params)
                case .autofillLoginsStacked:
                    PixelKit.fire(GeneralPixel.autofillLoginsStacked, withAdditionalParameters: params)
                case .autofillCreditCardsStacked:
                    PixelKit.fire(GeneralPixel.autofillCreditCardsStacked, withAdditionalParameters: params)
                case .autofillIdentitiesStacked:
                    PixelKit.fire(GeneralPixel.autofillIdentitiesStacked, withAdditionalParameters: params)
                }
            },
            passwordManager: passwordManagerCoordinator,
            installDate: AppDelegate.firstLaunchDate)

        _ = NotificationCenter.default.addObserver(forName: .autofillUserSettingsDidChange,
                                                   object: nil,
                                                   queue: nil) { [weak self] _ in
            self?.autofillPixelReporter?.updateAutofillEnabledStatus(AutofillPreferences().askToSaveUsernamesAndPasswords)
        }
    }

    @MainActor
    private func setUpPasswordsMenuBarVisibility() {
        guard featureFlagger.isFeatureOn(.autofillPasswordsStatusBar) else {
            passwordsStatusBarMenu?.hide()
            passwordsStatusBarMenu = nil
            passwordsMenuBarCancellable = nil
            return
        }

        let preferences = AutofillPreferences()
        if passwordsStatusBarMenu == nil {
            passwordsStatusBarMenu = PasswordsStatusBarMenu(preferences: preferences, pinningManager: pinningManager)
        }

        if preferences.showInMenuBar {
            passwordsStatusBarMenu?.show()
        } else {
            passwordsStatusBarMenu?.hide()
        }

        passwordsMenuBarCancellable = NotificationCenter.default.publisher(for: .autofillShowInMenuBarDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    let showInMenuBar = AutofillPreferences().showInMenuBar
                    if showInMenuBar {
                        self?.passwordsStatusBarMenu?.show()
                    } else {
                        self?.passwordsStatusBarMenu?.hide()
                    }
                }
            }
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension AppDelegate: UNUserNotificationCenterDelegate {

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        return .banner
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        if let notificationIdentifier = DefaultBrowserAndDockPromptNotificationIdentifier(rawValue: response.notification.request.identifier) {
            await defaultBrowserAndDockPromptService.handleNotificationResponse(notificationIdentifier)
            return
        }

        // Handle web notification clicks
        let userInfo = response.notification.request.content.userInfo
        if let tabUUID = userInfo[WebNotificationsHandler.UserInfoKey.tabUUID] as? String,
           let notificationId = userInfo[WebNotificationsHandler.UserInfoKey.notificationId] as? String {
            await webNotificationClickHandler.handleClick(tabUUID: tabUUID, notificationId: notificationId)
        }
    }

}

extension AppDelegate: UserScriptDependenciesProviding {
    @MainActor
    func makeNewTabPageActionsManager() -> NewTabPageActionsManager? {
        guard let contentBlocking = privacyFeatures.contentBlocking as? AppContentBlocking else {
            return nil
        }

        return NewTabPageActionsManager(
            appearancePreferences: appearancePreferences,
            visualizeFireAnimationDecider: visualizeFireSettingsDecider,
            customizationModel: newTabPageCustomizationModel,
            bookmarkManager: bookmarkManager,
            faviconManager: faviconManager,
            duckPlayerHistoryEntryTitleProvider: duckPlayer,
            contentBlocking: contentBlocking,
            trackerDataManager: contentBlocking.trackerDataManager,
            activeRemoteMessageModel: activeRemoteMessageModel,
            historyCoordinator: historyCoordinator,
            fireproofDomains: fireproofDomains,
            privacyStats: privacyStats,
            autoconsentStats: autoconsentStats,
            cookiePopupProtectionPreferences: cookiePopupProtectionPreferences,
            freemiumDBPPromotionViewCoordinator: freemiumDBPPromotionViewCoordinator,
            tld: tld,
            fire: { @MainActor in self.fireCoordinator.fireViewModel.fire },
            keyValueStore: keyValueStore,
            featureFlagger: featureFlagger,
            windowControllersManager: windowControllersManager,
            tabsPreferences: tabsPreferences,
            newTabPageAIChatShortcutSettingProvider: NewTabPageAIChatShortcutSettingProvider(aiChatMenuConfiguration: aiChatMenuConfiguration),
            winBackOfferPromotionViewCoordinator: winBackOfferPromotionViewCoordinator,
            subscriptionCardVisibilityManager: homePageSetUpDependencies.subscriptionCardVisibilityManager,
            protectionsReportModel: newTabPageProtectionsReportModel,
            homePageContinueSetUpModelPersistor: homePageSetUpDependencies.continueSetUpModelPersistor,
            nextStepsCardsPersistor: homePageSetUpDependencies.nextStepsCardsPersistor,
            subscriptionCardPersistor: homePageSetUpDependencies.subscriptionCardPersistor,
            duckPlayerPreferences: DuckPlayerPreferencesUserDefaultsPersistor(),
            syncService: syncService,
            pinningManager: pinningManager
        )
    }

    private static func makeAutoconsentEventCoordinator(
        autoconsentStats: AutoconsentStatsCollecting,
        historyCoordinating: HistoryCoordinating,
        webExtensionAvailability: WebExtensionAvailabilityProviding
    ) -> AutoconsentEventCoordinator {
        return AutoconsentEventCoordinator(
            autoconsentStats: autoconsentStats,
            historyCoordinating: historyCoordinating,
            webExtensionAvailability: webExtensionAvailability
        )
    }
}

extension FeatureFlagLocalOverrides {

    func applyUITestsFeatureFlagsIfNeeded() {
        guard AppVersion.runType == .uiTests else { return }

        for item in ProcessInfo().environment["FEATURE_FLAGS", default: ""].split(separator: " ") {
            let keyValue = item.split(separator: "=")
            let key = String(keyValue[0])
            guard let value = Bool(keyValue[safe: 1]?.lowercased() ?? "true") else {
                fatalError("Only true/false values are supported for feature flag values (or none)")
            }
            guard let featureFlag = FeatureFlag(rawValue: key) else {
                fatalError("Unrecognized feature flag: \(key)")
            }
            guard featureFlag.supportsLocalOverriding else {
                fatalError("Feature flag \(key) does not support local overriding")
            }
            if currentValue(for: featureFlag)! != value {
                toggleOverride(for: featureFlag)
            }
        }
    }

}
