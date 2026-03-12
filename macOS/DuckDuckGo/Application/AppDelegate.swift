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

    /// Set once during init() from the Launching state. All forwarding properties read from here.
    /// Services is a reference type (class), so mutations by state handlers are visible immediately.
    private var appDependencies: AppDependencies!

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

    // MARK: - Properties that stay on AppDelegate (used outside applicationDidFinishLaunching)

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

    private(set) lazy var vpnAppEventsHandler = VPNAppEventsHandler(
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

    // MARK: - Init

    @MainActor
    init(dockCustomization: DockCustomization?) {
        let didCrashDuringCrashHandlersSetUp = UserDefaultsWrapper(key: .didCrashDuringCrashHandlersSetUp, defaultValue: false)
        _didCrashDuringCrashHandlersSetUp = didCrashDuringCrashHandlersSetUp
        self.dockCustomization = dockCustomization
        super.init()

        // Create state machine and transition through Initializing → Launching.
        // This must happen in init() so that forwarding properties (which read from
        // appDependencies) are available immediately — matching the original behavior
        // where all ~89 properties were created in init().
        appStateMachine = AppStateMachine(initialState: .initializing(Initializing()))
        appStateMachine.handle(.didFinishLaunching)
        if case .launching(let launching) = appStateMachine.currentState,
           let concreteState = launching as? Launching {
            appDependencies = concreteState.dependencies
        } else {
            fatalError("Expected .launching state after didFinishLaunching")
        }

        // Wire AppDelegate as the UserScriptDependenciesProvider.
        // This was originally at the end of the old init() — Launching can't do it
        // because the provider must be AppDelegate (which conforms to the protocol).
        (privacyFeatures.contentBlocking as? AppContentBlocking)?.userContentUpdating.userScriptDependenciesProvider = self
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
    var appSyncService: AppSyncService { appDependencies.services.appSyncService }
    var syncService: DDGSyncing? { appDependencies.services.appSyncService.sync }
    var syncDataProviders: SyncDataProvidersSource? { appDependencies.services.appSyncService.syncDataProviders }
    var syncErrorHandler: SyncErrorHandler { appDependencies.services.appSyncService.syncErrorHandler }
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

    // -- Properties forwarded from Foreground state --
    // These are accessed from non-isolated contexts (matching previous stored property behavior).
    // AppDelegate methods always run on the main thread, so this is safe.
    var webExtensionManager: WebExtensionManaging? {
        MainActor.assumeMainThread { foregroundState?.webExtensionManager }
    }
    var darkReaderFeatureSettings: DarkReaderFeatureSettings? {
        MainActor.assumeMainThread { foregroundState?.darkReaderFeatureSettings }
    }
    var aiChatSyncCleaner: AIChatSyncCleaning? { appDependencies.services.appSyncService.aiChatSyncCleaner }
    var autofillPixelReporter: AutofillPixelReporter? {
        MainActor.assumeMainThread { foregroundState?.autofillPixelReporter }
    }

    @MainActor
    private var foregroundState: Foreground? {
        if case .foreground(let fg) = appStateMachine.currentState {
            return fg as? Foreground
        }
        return nil
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        appStateMachine.handle(.willFinishLaunching)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        appStateMachine.handle(.appDidFinishLaunching)
        guard AppVersion.runType.requiresEnvironment else { return }
        didFinishLaunching = true
        UNUserNotificationCenter.current().delegate = self
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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        return appStateMachine.handleTerminationRequest()
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
