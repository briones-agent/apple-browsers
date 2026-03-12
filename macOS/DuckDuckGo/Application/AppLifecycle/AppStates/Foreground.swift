//
//  Foreground.swift
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
import AppKit
import AppUpdaterShared
import BrowserServicesKit
import Combine
import Common
import Configuration
import DataBrokerProtection_macOS
import DataBrokerProtectionCore
import DDGSync
import FeatureFlags
import Freemium
import Lottie
import os.log
import PixelKit
import Subscription
import SyncDataProviders
import VPN
import WebExtensions

// swiftlint:disable type_body_length
// swiftlint:disable function_body_length
// swiftlint:disable file_length

@MainActor
final class Foreground: ForegroundHandling {

    var dependencies: AppDependencies
    private var terminationHandler: TerminationDeciderHandler?

    // MARK: - Stored Properties (moved from AppDelegate)

    private var vpnSubscriptionEventHandler: VPNSubscriptionEventsHandler?
    private var freemiumDBPScanResultPolling: FreemiumDBPScanResultPolling?
    private(set) var autofillPixelReporter: AutofillPixelReporter?
    private var passwordsStatusBarMenu: PasswordsStatusBarMenu?
    private var passwordsMenuBarCancellable: AnyCancellable?
    private var isInternalUserSharingCancellable: AnyCancellable?
    private var syncFeatureFlagsCancellable: AnyCancellable?
    private var screenLockedCancellable: AnyCancellable?
    private var emailCancellables = Set<AnyCancellable>()
    private var updateProgressCancellable: AnyCancellable?
    private(set) var webExtensionManager: WebExtensionManaging?
    private var webExtensionFeatureFlagHandler: AnyObject?
    private var isSyncingEmbeddedExtensions = false
    private(set) var darkReaderFeatureSettings: DarkReaderFeatureSettings?
    private var darkReaderCancellables = Set<AnyCancellable>()
    private var automationServer: AutomationServer?

    @UserDefaultsWrapper(key: .syncDidShowSyncPausedByFeatureFlagAlert, defaultValue: false)
    private var syncDidShowSyncPausedByFeatureFlagAlert: Bool

    init(dependencies: AppDependencies, vpnSubscriptionEventHandler: VPNSubscriptionEventsHandler? = nil) {
        self.dependencies = dependencies
        self.vpnSubscriptionEventHandler = vpnSubscriptionEventHandler
    }

    // MARK: - onTransition (moved from AppDelegate.applicationDidFinishLaunching)

    func onTransition() {
        guard AppVersion.runType.requiresEnvironment else { return }

        let startupProfiler = dependencies.services.startupProfiler
        let profilerToken = startupProfiler.measureSequence(initialStep: .appDidFinishLaunchingBeforeRestoration)

        Task {
            await dependencies.subscription.subscriptionManager.loadInitialData()

            Application.appDelegate.vpnAppEventsHandler.applicationDidFinishLaunching()
        }

        dependencies.services.historyCoordinator.loadHistory {
            self.dependencies.services.historyCoordinator.migrateModelV5toV6IfNeeded()
        }

        dependencies.services.privacyFeatures.httpsUpgrade.loadDataAsync()
        dependencies.services.bookmarkManager.loadBookmarks()

        // Force use of .mainThread to prevent high WindowServer Usage
        // Pending Fix with newer Lottie versions
        // https://app.asana.com/0/1177771139624306/1207024603216659/f
        LottieConfiguration.shared.renderingEngine = .mainThread

        dependencies.services.configurationManager.start()

        let isFirstLaunch = LocalStatisticsStore().atb == nil

        if isFirstLaunch {
            AppDelegate.firstLaunchDate = Date()
        }

        setupWebExtensions()

        Application.appDelegate.vpnUpsellVisibilityManager.setup(isFirstLaunch: isFirstLaunch, isOnboardingFinished: OnboardingActionsManager.isOnboardingFinished)

        AtbAndVariantCleanup.cleanup()
        DefaultVariantManager().assignVariantIfNeeded { _ in
            // MARK: perform first time launch logic here
        }

        let statisticsLoader = AppVersion.runType.requiresEnvironment ? StatisticsLoader.shared : nil
        statisticsLoader?.load()

        subscribeSyncQueueToScreenLockedNotifications()
        subscribeToSyncFeatureFlags(dependencies.services.appSyncService.sync)

        profilerToken.advance(to: .appStateRestoration)

        if AppVersion.runType.stateRestorationAllowed {
            dependencies.services.stateRestorationManager?.applicationDidFinishLaunching()
        }

        profilerToken.advance(to: .appDidFinishLaunchingAfterRestoration)

        let urlEventHandlerResult = dependencies.services.urlEventHandler.applicationDidFinishLaunching()

        setUpAutoClearHandler()
        dependencies.services.bitwardenManager?.initCommunication()

        if AppVersion.runType.opensWindowOnStartupIfNeeded,
           !urlEventHandlerResult.willOpenWindows && WindowsManager.windows.first(where: { $0 is MainWindow }) == nil {
            // Use startup window preferences if not restoring previous session
            if !dependencies.preferences.startupPreferences.restorePreviousSession {
                let burnerMode = dependencies.preferences.startupPreferences.startupBurnerMode()
                WindowsManager.openNewWindow(burnerMode: burnerMode, lazyLoadTabs: true)
            } else {
                WindowsManager.openNewWindow(lazyLoadTabs: true)
            }
        }

        dependencies.services.grammarFeaturesManager.manage()

        applyPreferredTheme()

        if case .normal = AppVersion.runType {
            Task {
                await dependencies.services.crashReporting.start()
            }
        }

        subscribeToEmailProtectionStatusNotifications()
        subscribeToDataImportCompleteNotification()
        subscribeToInternalUserChanges()
        subscribeToUpdateControllerChanges()

        fireFailedCompilationsPixelIfNeeded()

        UserDefaultsWrapper<Any>.clearRemovedKeys()

        vpnSubscriptionEventHandler?.startMonitoring()

        let dataBrokerProtectionSubscriptionEventHandler: DataBrokerProtectionSubscriptionEventHandler = {
            let authManager = DataBrokerAuthenticationManagerBuilder.buildAuthenticationManager(subscriptionManager: dependencies.subscription.subscriptionManager)
            return DataBrokerProtectionSubscriptionEventHandler(featureDisabler: DataBrokerProtectionFeatureDisabler(),
                                                                authenticationManager: authManager,
                                                                pixelHandler: DataBrokerProtectionMacOSPixelsHandler())
        }()
        dataBrokerProtectionSubscriptionEventHandler.registerForSubscriptionAccountManagerEvents()

        let freemiumDBPUserStateManager = DefaultFreemiumDBPUserStateManager(userDefaults: .dbp)
        let pirGatekeeper = DefaultDataBrokerProtectionFeatureGatekeeper(
            privacyConfigurationManager: dependencies.services.privacyFeatures.contentBlocking.privacyConfigurationManager,
            subscriptionManager: dependencies.subscription.subscriptionManager,
            freemiumDBPUserStateManager: freemiumDBPUserStateManager
        )

        DataBrokerProtectionAppEvents(featureGatekeeper: pirGatekeeper).applicationDidFinishLaunching()

        TipKitAppEventHandler(featureFlagger: dependencies.featureFlags.featureFlagger).appDidFinishLaunching()

        setUpAutofillPixelReporter()
        setUpPasswordsMenuBarVisibility()

        dependencies.services.remoteMessagingClient?.startRefreshingRemoteMessages()

        // This messaging system has been replaced by RMF, but we need to clean up the message manifest for any users who had it stored.
        let deprecatedRemoteMessagingStorage = DefaultSurveyRemoteMessagingStorage.surveys()
        deprecatedRemoteMessagingStorage.removeStoredMessagesIfNecessary()

        let didCrashDuringCrashHandlersSetUp = UserDefaultsWrapper(key: .didCrashDuringCrashHandlersSetUp, defaultValue: false)
        if didCrashDuringCrashHandlersSetUp.wrappedValue {
            PixelKit.fire(GeneralPixel.crashOnCrashHandlersSetUp)
            didCrashDuringCrashHandlersSetUp.wrappedValue = false
        }

        freemiumDBPScanResultPolling = DefaultFreemiumDBPScanResultPolling(dataManager: DataBrokerProtectionManager.shared.dataManager, freemiumDBPUserStateManager: freemiumDBPUserStateManager)
        freemiumDBPScanResultPolling?.startPollingOrObserving()

        let wideEventService = WideEventService(
            wideEvent: dependencies.services.wideEvent,
            subscriptionManager: dependencies.subscription.subscriptionManager
        )
        Task(priority: .utility) {
            await wideEventService.sendPendingEvents()
        }

        dependencies.services.userChurnScheduler.start()

        dependencies.services.memoryUsageMonitor.enableIfNeeded(featureFlagger: dependencies.featureFlags.featureFlagger)

        startAutomationServerIfNeeded()

        PixelKit.fire(GeneralPixel.launch, doNotEnforcePrefix: true)
        profilerToken.stop()
    }

    func didReturn() {
        // Called on subsequent didBecomeActive while already in foreground.
        // Phase 1: no-op (AppDelegate handles this via its didFinishLaunching guard).
    }

    func handleTerminationRequest(onAsyncTerminationApproved: @escaping @MainActor () -> Void) -> NSApplication.TerminateReply {
        // Already processing an async termination — defer to in-flight handler
        if terminationHandler != nil {
            return .terminateLater
        }

        let handler = TerminationDeciderHandler(
            deciders: createTerminationDeciders(),
            replyToApplicationShouldTerminate: { [weak self] shouldTerminate in
                self?.terminationHandler = nil
                if shouldTerminate {
                    onAsyncTerminationApproved()
                }
                NSApp.reply(toApplicationShouldTerminate: shouldTerminate)
            }
        )
        terminationHandler = handler
        let reply = handler.executeTerminationDeciders()

        if reply == .terminateCancel {
            terminationHandler = nil
        }
        return reply
    }

    // MARK: - Private

    private func createTerminationDeciders() -> [ApplicationTerminationDecider] {
        let persistor = QuitSurveyUserDefaultsPersistor(keyValueStore: dependencies.stores.keyValueStore)

        let deciders: [ApplicationTerminationDecider?] = [
            QuitSurveyAppTerminationDecider(
                featureFlagger: dependencies.featureFlags.featureFlagger,
                dataClearingPreferences: dependencies.preferences.dataClearingPreferences,
                downloadManager: dependencies.services.downloadManager,
                installDate: AppDelegate.firstLaunchDate,
                persistor: persistor,
                reinstallUserDetection: DefaultReinstallUserDetection(keyValueStore: dependencies.stores.keyValueStore),
                showQuitSurvey: { [weak self] in
                    guard let self else { return }
                    let presenter = QuitSurveyPresenter(
                        windowControllersManager: self.dependencies.ui.windowControllersManager,
                        persistor: persistor
                    )
                    await presenter.showSurvey()
                }
            ),

            ActiveDownloadsAppTerminationDecider(
                downloadManager: dependencies.services.downloadManager,
                downloadListCoordinator: dependencies.services.downloadListCoordinator
            ),

            makeWarnBeforeQuitDecider(),

            .perform { [weak self] in
                self?.dependencies.services.updateController?.handleAppTermination()
            },

            .perform { [weak self] in
                self?.dependencies.services.stateRestorationManager?.applicationWillTerminate()
            },

            dependencies.services.autoClearHandler,

            .terminationDecider { [weak self] _ in
                guard let self else { return .sync(.next) }
                return .async(Task {
                    await self.dependencies.services.privacyStats.handleAppTermination()
                    return .next
                })
            },

            .perform {
                NSApp.visibleWindows.forEach { $0.close() }
            }
        ]

        return deciders.compactMap { $0 }
    }

    private func makeWarnBeforeQuitDecider() -> ApplicationTerminationDecider? {
        let willShowAutoClearWarning = dependencies.preferences.dataClearingPreferences.isAutoClearEnabled
            && dependencies.preferences.dataClearingPreferences.isWarnBeforeClearingEnabled

        let hasWindow = dependencies.ui.windowControllersManager.lastKeyMainWindowController?.window != nil

        guard dependencies.featureFlags.featureFlagger.isFeatureOn(.warnBeforeQuit),
              !willShowAutoClearWarning,
              hasWindow,
              let currentEvent = NSApp.currentEvent else { return nil }

        guard let manager = WarnBeforeQuitManager(
            currentEvent: currentEvent,
            action: .quit,
            isWarningEnabled: { [weak self] in
                self?.dependencies.preferences.tabsPreferences.warnBeforeQuitting ?? false
            },
            isPhysicalKeyPress: WarnBeforeQuitManager.makePhysicalKeyPressCheck(for: currentEvent)
        ) else { return nil }

        let presenter = WarnBeforeQuitOverlayPresenter(
            startupPreferences: dependencies.preferences.startupPreferences,
            buttonHandlers: [.dontShowAgain: { [weak self] in
                PixelKit.fire(GeneralPixel.warnBeforeQuitDontShowAgain, frequency: .standard)
                self?.dependencies.preferences.tabsPreferences.warnBeforeQuitting = false
            }],
            onHoverChange: { [weak manager] isHovering in
                manager?.setMouseHovering(isHovering)
            }
        )

        presenter.subscribe(to: manager.stateStream)
        return manager
    }

    // MARK: - Web Extensions

    @MainActor
    private func setupWebExtensions() {
        guard #available(macOS 15.4, *) else { return }

        let featureFlagger = dependencies.featureFlags.featureFlagger
        let privacyFeatures = dependencies.services.privacyFeatures
        let keyValueStore = dependencies.stores.keyValueStore
        let appearancePreferences = dependencies.preferences.appearancePreferences
        let cookiePopupProtectionPreferences = dependencies.preferences.cookiePopupProtectionPreferences

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
            privacyConfigurationManager: dependencies.services.privacyFeatures.contentBlocking.privacyConfigurationManager,
            autoconsentPreferences: dependencies.preferences.cookiePopupProtectionPreferences,
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
        if dependencies.featureFlags.featureFlagger.isFeatureOn(.embeddedExtension) {
            enabledTypes.insert(.embedded)
        }
        if darkReaderFeatureSettings?.isForceDarkModeEnabled == true {
            enabledTypes.insert(.darkReader)
        }
        await webExtensionManager.syncEmbeddedExtensions(enabledTypes: enabledTypes)
    }

    // MARK: - Sync

    @MainActor
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
                        DispatchQueue.main.async { [weak self] in
                            self?.dependencies.ui.windowControllersManager.showPreferencesTab(withSelectedPane: .sync)
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
                guard let sync = self?.dependencies.services.appSyncService.sync, sync.authState != .inactive else {
                    return
                }
                if isLocked {
                    Logger.sync.debug("Screen is locked")
                    sync.scheduler.cancelSyncAndSuspendSyncQueue()
                } else {
                    Logger.sync.debug("Screen is unlocked")
                    sync.scheduler.resumeSyncQueue()
                }
            }
    }

    // MARK: - Email Protection

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

    private func emailDidSignInNotification(_ notification: Notification) {
        PixelKit.fire(NonStandardPixel.emailEnabled, doNotEnforcePrefix: true)
        if AppDelegate.isNewUser {
            PixelKit.fire(GeneralPixel.emailEnabledInitial, frequency: .legacyInitial)
        }

        if let object = notification.object as? EmailManager, let emailManager = dependencies.services.appSyncService.syncDataProviders.settingsAdapter.emailManager, object !== emailManager {
            dependencies.services.appSyncService.sync.scheduler.notifyDataChanged()
        }
    }

    private func emailDidSignOutNotification(_ notification: Notification) {
        PixelKit.fire(NonStandardPixel.emailDisabled, doNotEnforcePrefix: true)
        if let object = notification.object as? EmailManager, let emailManager = dependencies.services.appSyncService.syncDataProviders.settingsAdapter.emailManager, object !== emailManager {
            dependencies.services.appSyncService.sync.scheduler.notifyDataChanged()
        }
    }

    // MARK: - Data Import

    private func subscribeToDataImportCompleteNotification() {
        NotificationCenter.default.addObserver(self, selector: #selector(dataImportCompleteNotification(_:)), name: .dataImportComplete, object: nil)
    }

    @objc private func dataImportCompleteNotification(_ notification: Notification) {
        if AppDelegate.isNewUser {
            PixelKit.fire(GeneralPixel.importDataInitial, frequency: .legacyInitial)
        }
    }

    // MARK: - Internal User

    private func subscribeToInternalUserChanges() {
        UserDefaults.appConfiguration.isInternalUser = dependencies.featureFlags.internalUserDecider.isInternalUser

        isInternalUserSharingCancellable = dependencies.featureFlags.internalUserDecider.isInternalUserPublisher
            .assign(to: \.isInternalUser, onWeaklyHeld: UserDefaults.appConfiguration)
    }

    // MARK: - Update Controller

    private func subscribeToUpdateControllerChanges() {
        guard AppVersion.runType.allowsUpdates,
              let sparkleUpdateController = dependencies.services.updateController as? any SparkleUpdateControlling else { return }

        updateProgressCancellable = sparkleUpdateController.updateProgressPublisher
            .sink { [weak sparkleUpdateController] progress in
                sparkleUpdateController?.checkNewApplicationVersionIfNeeded(updateProgress: progress)
            }
    }

    // MARK: - AutoClear

    @MainActor
    private func setUpAutoClearHandler() {
        let autoClearHandler = AutoClearHandler(dataClearingPreferences: dependencies.preferences.dataClearingPreferences,
                                                startupPreferences: dependencies.preferences.startupPreferences,
                                                fireViewModel: dependencies.ui.fireCoordinator.fireViewModel,
                                                stateRestorationManager: dependencies.services.stateRestorationManager,
                                                aiChatSyncCleaner: dependencies.services.appSyncService.aiChatSyncCleaner)
        dependencies.services.autoClearHandler = autoClearHandler
        DispatchQueue.main.async {
            autoClearHandler.handleAppLaunch()
        }
    }

    // MARK: - Autofill

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
            passwordManager: dependencies.services.passwordManagerCoordinator,
            installDate: AppDelegate.firstLaunchDate)

        _ = NotificationCenter.default.addObserver(forName: .autofillUserSettingsDidChange,
                                                   object: nil,
                                                   queue: nil) { [weak self] _ in
            self?.autofillPixelReporter?.updateAutofillEnabledStatus(AutofillPreferences().askToSaveUsernamesAndPasswords)
        }
    }

    // MARK: - Passwords Menu Bar

    @MainActor
    private func setUpPasswordsMenuBarVisibility() {
        guard dependencies.featureFlags.featureFlagger.isFeatureOn(.autofillPasswordsStatusBar) else {
            passwordsStatusBarMenu?.hide()
            passwordsStatusBarMenu = nil
            passwordsMenuBarCancellable = nil
            return
        }

        let preferences = AutofillPreferences()
        if passwordsStatusBarMenu == nil {
            passwordsStatusBarMenu = PasswordsStatusBarMenu(preferences: preferences, pinningManager: dependencies.ui.pinningManager)
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

    // MARK: - Theme

    private func applyPreferredTheme() {
        dependencies.preferences.appearancePreferences.updateUserInterfaceStyle()
    }

    // MARK: - Compilations Pixel

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

    // MARK: - Automation Server

    private func startAutomationServerIfNeeded() {
        let buildType = StandardApplicationBuildType()
        guard buildType.isDebugBuild || buildType.isReviewBuild,
              let port = dependencies.services.launchOptionsHandler.automationPort else {
            return
        }
        Task { @MainActor in
            automationServer = AutomationServer(
                windowControllersManager: dependencies.ui.windowControllersManager,
                contentBlockingManager: dependencies.services.privacyFeatures.contentBlocking.contentBlockingManager,
                port: port
            )
        }
    }

}

// swiftlint:enable type_body_length
// swiftlint:enable function_body_length
// swiftlint:enable file_length
