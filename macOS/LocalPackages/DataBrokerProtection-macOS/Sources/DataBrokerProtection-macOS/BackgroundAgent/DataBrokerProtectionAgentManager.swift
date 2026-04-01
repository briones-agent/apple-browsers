//
//  DataBrokerProtectionAgentManager.swift
//
//  Copyright © 2023 DuckDuckGo. All rights reserved.
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

import Foundation
import Combine
import Common
import BrowserServicesKit
import Configuration
import PixelKit
import AppKitExtensions
import os.log
import Freemium
import Subscription
import UserNotifications
import DataBrokerProtectionCore
import PrivacyConfig
import FeatureFlags

// This is to avoid exposing all the dependancies outside of the DBP package
public class DataBrokerProtectionAgentManagerProvider {

    static let featureFlagOverridesPublishingHandler = FeatureFlagOverridesPublishingHandler<FeatureFlag>()

    private let databaseURL = DefaultDataBrokerProtectionDatabaseProvider.databaseFilePath(directoryName: DatabaseConstants.directoryName, fileName: DatabaseConstants.fileName, appGroupIdentifier: Bundle.main.appGroupName)

    public static func agentManager(authenticationManager: DataBrokerProtectionAuthenticationManaging,
                                    configurationManager: DefaultConfigurationManager,
                                    privacyConfigurationManager: PrivacyConfigurationManaging,
                                    featureFlagger: DBPFeatureFlagging,
                                    wideEvent: WideEventManaging,
                                    vpnBypassService: VPNBypassFeatureProvider,
                                    applicationNameForUserAgent: String?) -> DataBrokerProtectionAgentManager? {
        guard let pixelKit = PixelKit.shared else {
            assertionFailure("PixelKit not set up")
            return nil
        }
        let pixelHandler = DataBrokerProtectionMacOSPixelsHandler()
        let sharedPixelsHandler = DataBrokerProtectionSharedPixelsHandler(pixelKit: pixelKit, platform: .macOS)
        let engagementPixelRepository = DataBrokerProtectionEngagementPixelsUserDefaults()
        let eventPixelRepository = DataBrokerProtectionEventPixelsUserDefaults()
        let statsPixelRepository = DataBrokerProtectionStatsPixelsUserDefaults()

        let dbpSettings = DataBrokerProtectionSettings(defaults: .dbp)
        let schedulingConfig = DataBrokerMacOSSchedulingConfig(mode: dbpSettings.runType == .integrationTests ? .fastForIntegrationTests : .normal)
        let activityScheduler = DefaultDataBrokerProtectionBackgroundActivityScheduler(config: schedulingConfig)

        let notificationService = DefaultDataBrokerProtectionUserNotificationService(pixelHandler: pixelHandler, userNotificationCenter: UNUserNotificationCenter.current(), authenticationManager: authenticationManager)
        let eventsHandler = BrokerProfileJobEventsHandler(userNotificationService: notificationService)

        let ipcServer = DefaultDataBrokerProtectionIPCServer(machServiceName: Bundle.main.bundleIdentifier!)

        let features = ContentScopeFeatureToggles(emailProtection: false,
                                                  emailProtectionIncontextSignup: false,
                                                  credentialsAutofill: false,
                                                  identitiesAutofill: false,
                                                  creditCardsAutofill: false,
                                                  credentialsSaving: false,
                                                  passwordGeneration: false,
                                                  inlineIconCredentials: false,
                                                  thirdPartyCredentialsProvider: false,
                                                  unknownUsernameCategorization: false,
                                                  partialFormSaves: false,
                                                  passwordVariantCategorization: false,
                                                  inputFocusApi: false,
                                                  autocompleteAttributeSupport: false)
        let contentScopeProperties = ContentScopeProperties(gpcEnabled: false,
                                                            sessionKey: UUID().uuidString,
                                                            messageSecret: UUID().uuidString,
                                                            featureToggles: features)

        let fakeBroker = DataBrokerDebugFlagFakeBroker()
        let databaseURL = DefaultDataBrokerProtectionDatabaseProvider.databaseFilePath(directoryName: DatabaseConstants.directoryName, fileName: DatabaseConstants.fileName, appGroupIdentifier: Bundle.main.appGroupName)
        let vaultFactory = createDataBrokerProtectionSecureVaultFactory(appGroupName: Bundle.main.appGroupName, databaseFileURL: databaseURL)

        let reporter = DataBrokerProtectionSecureVaultErrorReporter(pixelHandler: sharedPixelsHandler, privacyConfigManager: privacyConfigurationManager)

        let vault: DefaultDataBrokerProtectionSecureVault<DefaultDataBrokerProtectionDatabaseProvider>
        do {
            vault = try vaultFactory.makeVault(reporter: reporter)
        } catch let error {
            pixelHandler.fire(.backgroundAgentSetUpFailedSecureVaultInitFailed(error: error))
            return nil
        }

        let localBrokerService = LocalBrokerJSONService(resources: FileResources(runTypeProvider: dbpSettings),
                                                        vault: vault,
                                                        pixelHandler: sharedPixelsHandler,
                                                        runTypeProvider: dbpSettings,
                                                        isAuthenticatedUser: { await authenticationManager.isUserAuthenticated })
        let brokerUpdater = RemoteBrokerJSONService(featureFlagger: featureFlagger,
                                                    settings: dbpSettings,
                                                    vault: vault,
                                                    authenticationManager: authenticationManager,
                                                    pixelHandler: sharedPixelsHandler,
                                                    localBrokerProvider: localBrokerService)

        let database = DataBrokerProtectionDatabase(fakeBrokerFlag: fakeBroker, pixelHandler: sharedPixelsHandler, vault: vault, localBrokerService: brokerUpdater)
        let dataManager = DataBrokerProtectionDataManager(database: database)

        let jobQueue = OperationQueue()
        let jobProvider = BrokerProfileJobProvider()
        let mismatchCalculator = DefaultMismatchCalculator(database: dataManager.database,
                                                           pixelHandler: sharedPixelsHandler)

        let emailConfirmationJobProvider = EmailConfirmationJobProvider()
        let queueManager = JobQueueManager(jobQueue: jobQueue,
                                           jobProvider: jobProvider,
                                           emailConfirmationJobProvider: emailConfirmationJobProvider,
                                           mismatchCalculator: mismatchCalculator,
                                           pixelHandler: sharedPixelsHandler)

        let backendServicePixels = DefaultDataBrokerProtectionBackendServicePixels(pixelHandler: sharedPixelsHandler,
                                                                                   settings: dbpSettings)
        let emailService = EmailService(authenticationManager: authenticationManager,
                                        settings: dbpSettings,
                                        servicePixel: backendServicePixels)
        let emailServiceV1 = EmailServiceV1(authenticationManager: authenticationManager,
                                            settings: dbpSettings,
                                            servicePixel: backendServicePixels)
        let emailConfirmationDataService = EmailConfirmationDataService(emailConfirmationStore: dataManager.database,
                                                                        database: dataManager.database,
                                                                        emailServiceV0: emailService,
                                                                        emailServiceV1: emailServiceV1,
                                                                        featureFlagger: featureFlagger,
                                                                        pixelHandler: sharedPixelsHandler)
        let captchaService = CaptchaService(authenticationManager: authenticationManager, settings: dbpSettings, servicePixel: backendServicePixels)
        let freemiumDBPUserStateManager = DefaultFreemiumDBPUserStateManager(userDefaults: .dbp)
        let agentstopper = DefaultDataBrokerProtectionAgentStopper(dataManager: dataManager,
                                                                   entitlementMonitor: DataBrokerProtectionEntitlementMonitor(),
                                                                   authenticationManager: authenticationManager,
                                                                   pixelHandler: pixelHandler,
                                                                   freemiumDBPUserStateManager: freemiumDBPUserStateManager)

        let executionConfig = BrokerJobExecutionConfig()
        let jobDependencies = BrokerProfileJobDependencies(
            database: dataManager.database,
            contentScopeProperties: contentScopeProperties,
            privacyConfig: privacyConfigurationManager,
            executionConfig: executionConfig,
            notificationCenter: NotificationCenter.default,
            pixelHandler: sharedPixelsHandler,
            eventsHandler: eventsHandler,
            dataBrokerProtectionSettings: dbpSettings,
            emailConfirmationDataService: emailConfirmationDataService,
            captchaService: captchaService,
            featureFlagger: featureFlagger,
            applicationNameForUserAgent: applicationNameForUserAgent,
            vpnBypassService: vpnBypassService,
            wideEvent: wideEvent,
            isAuthenticatedUserProvider: { await authenticationManager.isUserAuthenticated })

        return DataBrokerProtectionAgentManager(
            eventsHandler: eventsHandler,
            activityScheduler: activityScheduler,
            ipcServer: ipcServer,
            queueManager: queueManager,
            dataManager: dataManager,
            emailConfirmationDataService: emailConfirmationDataService,
            jobDependencies: jobDependencies,
            sharedPixelsHandler: sharedPixelsHandler,
            pixelHandler: pixelHandler,
            engagementPixelRepository: engagementPixelRepository,
            eventPixelRepository: eventPixelRepository,
            statsPixelRepository: statsPixelRepository,
            agentStopper: agentstopper,
            configurationManager: configurationManager,
            brokerUpdater: brokerUpdater,
            privacyConfigurationManager: privacyConfigurationManager,
            authenticationManager: authenticationManager,
            freemiumDBPUserStateManager: freemiumDBPUserStateManager,
            wideEvent: wideEvent)
    }
}

public protocol EmailConfirmationDataDelegate: AnyObject {
    func checkForEmailConfirmationData() async
}

public protocol DBPWideEventsDelegate: AnyObject {
    func sweepWideEvents()
}

public final class DataBrokerProtectionAgentManager {

    private let eventsHandler: EventMapping<JobEvent>
    private var activityScheduler: DataBrokerProtectionBackgroundActivityScheduler
    private var ipcServer: DataBrokerProtectionIPCServer
    private var queueManager: JobQueueManaging
    private let dataManager: DataBrokerProtectionDataManaging
    public var emailConfirmationDataService: EmailConfirmationDataServiceProvider?
    private let jobDependencies: BrokerProfileJobDependencyProviding
    private let sharedPixelsHandler: EventMapping<DataBrokerProtectionSharedPixels>
    private let pixelHandler: EventMapping<DataBrokerProtectionMacOSPixels>
    private let engagementPixelRepository: DataBrokerProtectionEngagementPixelsRepository
    private let eventPixelRepository: DataBrokerProtectionEventPixelsRepository
    private let statsPixelRepository: DataBrokerProtectionStatsPixelsRepository
    private let agentStopper: DataBrokerProtectionAgentStopper
    private let configurationManger: DefaultConfigurationManager
    private let brokerUpdater: BrokerJSONServiceProvider
    private let privacyConfigurationManager: PrivacyConfigurationManaging
    private let authenticationManager: DataBrokerProtectionAuthenticationManaging
    private let freemiumDBPUserStateManager: FreemiumDBPUserStateManager
    private let wideEventSweeper: DBPWideEventSweeper?

    // Used for debug functions only, so not injected
    private lazy var browserWindowManager = BrowserWindowManager()
    private let debugScanSession = DebugScanSession()

    /// Lazily-constructed debug email confirmation service (mirrors DataBrokerRunCustomJSONViewModel).
    private lazy var debugEmailConfirmationService: EmailConfirmationDataServiceProvider = {
        let dbpSettings = DataBrokerProtectionSettings(defaults: .dbp)
        let fakePixelHandler: EventMapping<DataBrokerProtectionSharedPixels> = EventMapping { event, _, _, _ in
            Logger.dataBrokerProtection.debug("Debug event: \(String(describing: event), privacy: .public)")
        }
        let backendServicePixels = DefaultDataBrokerProtectionBackendServicePixels(pixelHandler: fakePixelHandler, settings: dbpSettings)
        let emailService = EmailService(authenticationManager: authenticationManager, settings: dbpSettings, servicePixel: backendServicePixels)
        let emailServiceV1 = EmailServiceV1(authenticationManager: authenticationManager, settings: dbpSettings, servicePixel: backendServicePixels)
        return EmailConfirmationDataService(
            emailConfirmationStore: debugScanSession.debugEmailConfirmationStore,
            database: nil,
            emailServiceV0: emailService,
            emailServiceV1: emailServiceV1,
            featureFlagger: jobDependencies.featureFlagger,
            pixelHandler: fakePixelHandler
        )
    }()

    /// No-op pixel handler for debug scan/optout runners.
    private lazy var debugPixelHandler: EventMapping<DataBrokerProtectionSharedPixels> = EventMapping { event, _, _, _ in
        Logger.dataBrokerProtection.debug("Debug event: \(String(describing: event), privacy: .public)")
    }

    /// Lazily-constructed debug captcha service.
    private lazy var debugCaptchaService: CaptchaService = {
        let dbpSettings = DataBrokerProtectionSettings(defaults: .dbp)
        let backendServicePixels = DefaultDataBrokerProtectionBackendServicePixels(pixelHandler: debugPixelHandler, settings: dbpSettings)
        return CaptchaService(authenticationManager: authenticationManager, settings: dbpSettings, servicePixel: backendServicePixels)
    }()

    private var didStartActivityScheduler = false
    private var currentRunIsFreeScan: Bool?

    /// Snapshots the current authentication state and caches whether this is a free scan run.
    /// Returns the current `isAuthenticated` value for callers that need it.
    @discardableResult
    private func refreshIsAuthenticatedState() async -> Bool {
        let isAuthenticated = await authenticationManager.isUserAuthenticated
        currentRunIsFreeScan = !isAuthenticated
        return isAuthenticated
    }

    init(eventsHandler: EventMapping<JobEvent>,
         activityScheduler: DataBrokerProtectionBackgroundActivityScheduler,
         ipcServer: DataBrokerProtectionIPCServer,
         queueManager: JobQueueManaging,
         dataManager: DataBrokerProtectionDataManaging,
         emailConfirmationDataService: EmailConfirmationDataServiceProvider,
         jobDependencies: BrokerProfileJobDependencyProviding,
         sharedPixelsHandler: EventMapping<DataBrokerProtectionSharedPixels>,
         pixelHandler: EventMapping<DataBrokerProtectionMacOSPixels>,
         engagementPixelRepository: DataBrokerProtectionEngagementPixelsRepository,
         eventPixelRepository: DataBrokerProtectionEventPixelsRepository,
         statsPixelRepository: DataBrokerProtectionStatsPixelsRepository,
         agentStopper: DataBrokerProtectionAgentStopper,
         configurationManager: DefaultConfigurationManager,
         brokerUpdater: BrokerJSONServiceProvider,
         privacyConfigurationManager: PrivacyConfigurationManaging,
         authenticationManager: DataBrokerProtectionAuthenticationManaging,
         freemiumDBPUserStateManager: FreemiumDBPUserStateManager,
         wideEvent: WideEventManaging? = nil
    ) {
        self.eventsHandler = eventsHandler
        self.activityScheduler = activityScheduler
        self.ipcServer = ipcServer
        self.queueManager = queueManager
        self.dataManager = dataManager
        self.emailConfirmationDataService = emailConfirmationDataService
        self.jobDependencies = jobDependencies
        self.sharedPixelsHandler = sharedPixelsHandler
        self.pixelHandler = pixelHandler
        self.engagementPixelRepository = engagementPixelRepository
        self.eventPixelRepository = eventPixelRepository
        self.statsPixelRepository = statsPixelRepository
        self.agentStopper = agentStopper
        self.configurationManger = configurationManager
        self.brokerUpdater = brokerUpdater
        self.privacyConfigurationManager = privacyConfigurationManager
        self.authenticationManager = authenticationManager
        self.freemiumDBPUserStateManager = freemiumDBPUserStateManager
        self.wideEventSweeper = wideEvent.map { DBPWideEventSweeper(wideEvent: $0) }

        self.activityScheduler.delegate = self
        self.activityScheduler.dataSource = self
        self.queueManager.delegate = self
        self.ipcServer.serverDelegate = self
        self.ipcServer.activate()
        Logger.dataBrokerProtection.debug("PIR wide event sweep requested (macOS setup)")
        self.sweepWideEvents()
    }

    public func agentFinishedLaunching() {

        Task { @MainActor in
            // The browser shouldn't start the agent if these prerequisites aren't met.
            // However, since the agent can auto-start after a reboot without the browser, we need to validate it again.
            // If the agent needs to be stopped, this function will stop it, so the subsequent calls after it will not be made.
            await agentStopper.validateRunPrerequisitesAndStopAgentIfNecessary()

            await activityScheduler.startScheduler()
            didStartActivityScheduler = true

            await fireMonitoringPixels()
            Logger.dataBrokerProtection.debug("PIR wide event sweep requested (agent launch)")
            sweepWideEvents()
            let operationPreferredDateUpdater = OperationPreferredDateUpdater(database: jobDependencies.database)
            operationPreferredDateUpdater.runPreferredRunDateNilMigrationIfNeeded(settings: jobDependencies.dataBrokerProtectionSettings)
            await checkForEmailConfirmationData()

            startFreemiumOrSubscriptionScheduledOperations(showWebView: false, jobDependencies: jobDependencies, errorHandler: nil, completion: nil)

            /// Monitors entitlement changes every 60 minutes to optimize system performance and resource utilization by avoiding unnecessary operations when entitlement is invalid.
            /// While keeping the agent active with invalid entitlement has no significant risk, setting the monitoring interval at 60 minutes is a good balance to minimize backend checks.
            agentStopper.monitorEntitlementAndStopAgentIfEntitlementIsInvalidAndUserIsNotFreemium(interval: .minutes(60))
        }
    }
}

// MARK: - Regular monitoring pixels

extension DataBrokerProtectionAgentManager {
    func fireMonitoringPixels() async {
        let isAuthenticated = await authenticationManager.isUserAuthenticated

        let database = jobDependencies.database
        let engagementPixels = DataBrokerProtectionEngagementPixels(database: database, handler: sharedPixelsHandler, repository: engagementPixelRepository)
        let eventPixels = DataBrokerProtectionEventPixels(database: database, repository: eventPixelRepository, handler: sharedPixelsHandler)
        let statsPixels = DataBrokerProtectionStatsPixels(database: database, handler: sharedPixelsHandler, featureFlagger: jobDependencies.featureFlagger, repository: statsPixelRepository)

        // This will fire the DAU/WAU/MAU pixels,
        engagementPixels.fireEngagementPixel(isAuthenticated: isAuthenticated)
        // This will try to fire the event weekly report pixels
        eventPixels.tryToFireWeeklyPixels(isAuthenticated: isAuthenticated)

        // Stats pixels only fire for authenticated users (they relate to opt-outs)
        guard isAuthenticated else { return }

        // This will try to fire the stats pixels
        statsPixels.tryToFireStatsPixels()

        // If a user upgraded from Freemium, don't send 24-hour opt-out submit pixels
        guard !freemiumDBPUserStateManager.didActivate else { return }

        // Fire custom stats pixels if needed
        statsPixels.fireCustomStatsPixelsIfNeeded()
    }
}

private extension DataBrokerProtectionAgentManager {

    /// Starts either Subscription (scan and opt-out) or Freemium (scan-only) scheduled operations
    /// - Parameters:
    ///   - showWebView: Whether to show the web view or not
    ///   - jobDependencies: Operation dependencies
    ///   - errorHandler: Error handler
    ///   - completion: Completion handler
    func startFreemiumOrSubscriptionScheduledOperations(showWebView: Bool,
                                                        jobDependencies: BrokerProfileJobDependencyProviding,
                                                        errorHandler: ((DataBrokerProtectionJobsErrorCollection?) -> Void)?,
                                                        completion: (() -> Void)?) {
        Task {
            let isAuthenticated = await refreshIsAuthenticatedState()
            if isAuthenticated {
                queueManager.startScheduledAllOperationsIfPermitted(showWebView: showWebView, jobDependencies: jobDependencies, errorHandler: errorHandler, completion: completion)
            } else {
                queueManager.startScheduledScanOperationsIfPermitted(showWebView: showWebView, jobDependencies: jobDependencies, errorHandler: errorHandler, completion: completion)
            }
        }
    }
}

extension DataBrokerProtectionAgentManager: DataBrokerProtectionBackgroundActivitySchedulerDelegate {

    public func dataBrokerProtectionBackgroundActivitySchedulerDidTrigger(_ activityScheduler: any DataBrokerProtectionBackgroundActivityScheduler) async {
        do {
            let emailConfirmationDataService = activityScheduler.dataSource?.emailConfirmationDataServiceForDataBrokerProtectionBackgroundActivityScheduler(activityScheduler)
            try await emailConfirmationDataService?.checkForEmailConfirmationData()
        } catch {
            Logger.dataBrokerProtection.error("Email confirmation data check failed: \(error, privacy: .public)")
        }
        await startScheduledOperations()
    }

    func startScheduledOperations() async {
        await fireMonitoringPixels()
        await withCheckedContinuation { continuation in
            startScheduledOperations {
                continuation.resume()
            }
        }
    }

    private func startScheduledOperations(completion: (() -> Void)?) {
        startFreemiumOrSubscriptionScheduledOperations(showWebView: false, jobDependencies: jobDependencies, errorHandler: nil) {
            completion?()
        }
    }
}

extension DataBrokerProtectionAgentManager: DataBrokerProtectionBackgroundActivitySchedulerDataSource {
    public func emailConfirmationDataServiceForDataBrokerProtectionBackgroundActivityScheduler(_ activityScheduler: any DataBrokerProtectionBackgroundActivityScheduler) -> EmailConfirmationDataServiceProvider? {
        emailConfirmationDataService
    }
}

extension DataBrokerProtectionAgentManager: JobQueueManagerDelegate {

    public func queueManagerWillEnqueueOperations(_ queueManager: JobQueueManaging) {
        Task {
            do {
                try await brokerUpdater.checkForUpdates()
            }
        }
    }

    public func queueManagerDidCompleteIndividualJob(_ queueManager: any DataBrokerProtectionCore.JobQueueManaging, identifier: CompletedJobIdentifier?) {
        // Figure out if we've just finished initial scans, and send the appropriate pixel if necessary

        let database = jobDependencies.database
        let eventPixels = DataBrokerProtectionEventPixels(database: database, repository: eventPixelRepository, handler: sharedPixelsHandler)
        if eventPixels.hasInitialScansTotalDurationPixelBeenSent() {
            return
        }

        do {
            let hasCompletedInitialScans = try database.haveAllScansRunAtLeastOnce()
            if hasCompletedInitialScans {
                let profile = try database.fetchProfile()
                eventPixels.fireInitialScansTotalDurationPixel(numberOfProfileQueries: profile?.profileQueries.count ?? 0, isFreeScan: currentRunIsFreeScan)
            }
        } catch {
            Logger.dataBrokerProtection.error("Error when calculating if we should send the initial scans duration pixel, error: \(error.localizedDescription, privacy: .public)")
            return
        }
    }

}

extension DataBrokerProtectionAgentManager: DataBrokerProtectionAgentAppEvents {
    public func profileSaved() async {
        let database = jobDependencies.database
        let eventPixels = DataBrokerProtectionEventPixels(database: database, repository: eventPixelRepository, handler: sharedPixelsHandler)
        eventPixels.markInitialScansStarted()

        await refreshIsAuthenticatedState()

        eventsHandler.fire(.profileSaved)
        await fireMonitoringPixels()
        await checkForEmailConfirmationData()

        queueManager.startImmediateScanOperationsIfPermitted(showWebView: false, jobDependencies: jobDependencies) { [weak self] errors in
            guard let self = self else { return }

            if let errors = errors {
                if let oneTimeError = errors.oneTimeError {
                    switch oneTimeError {
                    case BrokerProfileJobQueueError.interrupted:
                        self.pixelHandler.fire(.ipcServerImmediateScansInterrupted)
                        Logger.dataBrokerProtection.error("Interrupted during DataBrokerProtectionAgentManager.profileSaved in queueManager.startImmediateOperationsIfPermitted(), error: \(oneTimeError.localizedDescription, privacy: .public)")
                    default:
                        self.pixelHandler.fire(.ipcServerImmediateScansFinishedWithError(error: oneTimeError))
                        Logger.dataBrokerProtection.error("Error during DataBrokerProtectionAgentManager.profileSaved in queueManager.startImmediateOperationsIfPermitted, error: \(oneTimeError.localizedDescription, privacy: .public)")
                    }
                }
                if let operationErrors = errors.operationErrors,
                          operationErrors.count != 0 {
                    Logger.dataBrokerProtection.log("Operation error(s) during DataBrokerProtectionAgentManager.profileSaved in queueManager.startImmediateOperationsIfPermitted, count: \(operationErrors.count, privacy: .public)")
                }
            }

            if errors?.oneTimeError == nil {
                self.pixelHandler.fire(.ipcServerImmediateScansFinishedWithoutError)
                self.eventsHandler.fire(.firstScanCompleted)
            }
        } completion: { [weak self] in
            guard let self else { return }

            if let hasMatches = try? self.dataManager.hasMatches(),
               hasMatches {
                self.eventsHandler.fire(.firstScanCompletedAndMatchesFound)
            }

            self.startScheduledOperations(completion: nil)
        }
    }

    public func appLaunched() async {
        await fireMonitoringPixels()
        await checkForEmailConfirmationData()

        startFreemiumOrSubscriptionScheduledOperations(showWebView: false, jobDependencies: jobDependencies, errorHandler: { [weak self] errors in
            guard let self = self else { return }

            if let errors = errors {
                if let oneTimeError = errors.oneTimeError {
                    switch oneTimeError {
                    case BrokerProfileJobQueueError.interrupted:
                        self.pixelHandler.fire(.ipcServerAppLaunchedScheduledScansInterrupted)
                        Logger.dataBrokerProtection.log("Interrupted during DataBrokerProtectionAgentManager.appLaunched in queueManager.startScheduledOperationsIfPermitted(), error: \(oneTimeError.localizedDescription, privacy: .public)")
                    case BrokerProfileJobQueueError.cannotInterrupt:
                        self.pixelHandler.fire(.ipcServerAppLaunchedScheduledScansBlocked)
                        Logger.dataBrokerProtection.log("Cannot interrupt during DataBrokerProtectionAgentManager.appLaunched in queueManager.startScheduledOperationsIfPermitted()")
                    default:
                        self.pixelHandler.fire(.ipcServerAppLaunchedScheduledScansFinishedWithError(error: oneTimeError))
                        Logger.dataBrokerProtection.log("Error during DataBrokerProtectionAgentManager.appLaunched in queueManager.startScheduledOperationsIfPermitted, error: \(oneTimeError.localizedDescription, privacy: .public)")
                    }
                }
                if let operationErrors = errors.operationErrors,
                          operationErrors.count != 0 {
                    Logger.dataBrokerProtection.log("Operation error(s) during DataBrokerProtectionAgentManager.profileSaved in queueManager.startImmediateOperationsIfPermitted, count: \(operationErrors.count, privacy: .public)")
                }
            }

            if errors?.oneTimeError == nil {
                self.pixelHandler.fire(.ipcServerAppLaunchedScheduledScansFinishedWithoutError)
            }
        }, completion: nil)
    }
}

extension DataBrokerProtectionAgentManager: DataBrokerProtectionAgentDebugCommands {
    public func openBrowser(domain: String) {
        Task { @MainActor in
            browserWindowManager.show(domain: domain)
        }
    }

    public func startImmediateOperations(showWebView: Bool) {
        queueManager.startImmediateScanOperationsIfPermitted(showWebView: showWebView,
                                                             jobDependencies: jobDependencies,
                                                             errorHandler: nil,
                                                             completion: nil)
    }

    public func startScheduledOperations(showWebView: Bool) {
        startFreemiumOrSubscriptionScheduledOperations(showWebView: showWebView,
                                                       jobDependencies: jobDependencies,
                                                       errorHandler: nil,
                                                       completion: nil)
    }

    public func runAllOptOuts(showWebView: Bool) {
        queueManager.startImmediateOptOutOperationsIfPermitted(showWebView: showWebView,
                                                               jobDependencies: jobDependencies,
                                                               errorHandler: nil,
                                                               completion: nil)
    }

    public func runEmailConfirmationOperations(showWebView: Bool) async {
        await checkForEmailConfirmationData()
        queueManager.addEmailConfirmationJobs(showWebView: showWebView, jobDependencies: jobDependencies)
    }

    public func getDebugMetadata() async -> DBPBackgroundAgentMetadata? {

        if let backgroundAgentVersion = Bundle.main.releaseVersionNumber,
            let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String {

            return DBPBackgroundAgentMetadata(backgroundAgentVersion: backgroundAgentVersion + " (build: \(buildNumber))",
                                              isAgentRunning: true,
                                              agentSchedulerState: queueManager.debugRunningStatusString,
                                              lastSchedulerSessionStartTimestamp: activityScheduler.lastTriggerTimestamp?.timeIntervalSince1970)
        } else {
            return DBPBackgroundAgentMetadata(backgroundAgentVersion: "ERROR: Error fetching background agent version",
                                              isAgentRunning: true,
                                              agentSchedulerState: queueManager.debugRunningStatusString,
                                              lastSchedulerSessionStartTimestamp: activityScheduler.lastTriggerTimestamp?.timeIntervalSince1970)
        }
    }

    // MARK: - MCP Debug Server Support (Profile Management)

    public func removeAllData() async -> Data? {
        do {
            try dataManager.communicator.deleteProfileData()
            let result: [String: Any] = ["success": true, "message": "All PIR data removed"]
            return try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        } catch {
            let result: [String: Any] = ["success": false, "error": error.localizedDescription]
            return try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        }
    }

    public func saveProfile(profileJSON: Data) async -> Data? {
        do {
            let profile = try JSONDecoder().decode(DataBrokerProtectionProfile.self, from: profileJSON)
            try await dataManager.saveProfile(profile)
            let queries = profile.profileQueries
            // Trigger the same flow as the UI: pixel events, auth refresh, immediate scan
            await profileSaved()
            let result: [String: Any] = [
                "success": true,
                "message": "Profile saved with \(profile.names.count) name(s), \(profile.addresses.count) address(es), \(queries.count) profile query/queries. Immediate scan triggered."
            ]
            return try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        } catch {
            let result: [String: Any] = ["success": false, "error": error.localizedDescription]
            return try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        }
    }

    // MARK: - MCP Debug Server Support (Read-Only)

    public func getBrokerProfileData() async -> Data? {
        do {
            let allData = try dataManager.fetchBrokerProfileQueryData(ignoresCache: true)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            var brokerMap = [String: [BrokerProfileQueryData]]()
            for item in allData {
                brokerMap[item.dataBroker.name, default: []].append(item)
            }

            var brokerSummaries = [[String: Any]]()
            for (brokerName, items) in brokerMap.sorted(by: { $0.key < $1.key }) {
                guard let first = items.first else { continue }
                let broker = first.dataBroker

                let allEvents = items.flatMap { $0.events }
                let errorEvents = allEvents.filter { $0.isError }
                let totalMatches = items.reduce(0) { $0 + $1.extractedProfiles.count }
                let lastScanDate = items.compactMap { $0.scanJobData.lastRunDate }.max()
                let recentErrors = errorEvents.sorted { $0.date > $1.date }.prefix(5)

                var summary: [String: Any] = [
                    "name": brokerName,
                    "url": broker.url,
                    "version": broker.version,
                    "profileQueryCount": items.count,
                    "totalMatches": totalMatches,
                    "errorCount": errorEvents.count,
                ]

                if let parent = broker.parent {
                    summary["parent"] = parent
                }
                if let lastScan = lastScanDate {
                    summary["lastScanDate"] = formatter.string(from: lastScan)
                }
                if !recentErrors.isEmpty {
                    summary["recentErrors"] = recentErrors.map { event -> [String: Any] in
                        var dict: [String: Any] = ["date": formatter.string(from: event.date)]
                        if let error = event.error {
                            dict["error"] = error
                        }
                        return dict
                    }
                }

                // Include profile query info for get_profile_queries extraction
                let uniqueQueries = Set(items.map { "\($0.profileQuery.firstName) \($0.profileQuery.lastName)" })
                if let firstQuery = items.first?.profileQuery {
                    summary["profileQuery"] = [
                        "firstName": firstQuery.firstName,
                        "lastName": firstQuery.lastName,
                        "city": firstQuery.city,
                        "state": firstQuery.state,
                        "birthYear": firstQuery.birthYear,
                        "fullName": firstQuery.fullName,
                    ] as [String: Any]
                }

                brokerSummaries.append(summary)
            }

            return try JSONSerialization.data(withJSONObject: brokerSummaries, options: [.prettyPrinted, .sortedKeys])
        } catch {
            Logger.dataBrokerProtection.error("Failed to fetch broker profile data: \(error.localizedDescription)")
            return nil
        }
    }

    public func getBrokerJSON(brokerURL: String) async -> Data? {
        do {
            let allData = try dataManager.fetchBrokerProfileQueryData(ignoresCache: true)
            let normalizedURL = brokerURL.replacingOccurrences(of: ".json", with: "")

            let broker = allData.first(where: {
                $0.dataBroker.url == normalizedURL ||
                $0.dataBroker.name.lowercased() == normalizedURL.lowercased()
            })?.dataBroker

            guard let broker else { return nil }

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try encoder.encode(broker)
        } catch {
            Logger.dataBrokerProtection.error("Failed to fetch broker JSON: \(error.localizedDescription)")
            return nil
        }
    }

    public func getBrokerDetails(brokerName: String) async -> Data? {
        do {
            let allData = try dataManager.fetchBrokerProfileQueryData(ignoresCache: true)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            let brokerItems = allData.filter {
                $0.dataBroker.name.lowercased() == brokerName.lowercased() ||
                $0.dataBroker.url.lowercased() == brokerName.lowercased()
            }

            guard !brokerItems.isEmpty, let broker = brokerItems.first?.dataBroker else { return nil }

            var profileQueries = [[String: Any]]()
            for item in brokerItems {
                let query = item.profileQuery
                let scan = item.scanJobData

                var scanInfo: [String: Any] = [:]
                if let lastRun = scan.lastRunDate {
                    scanInfo["lastRunDate"] = formatter.string(from: lastRun)
                }
                if let preferredRun = scan.preferredRunDate {
                    scanInfo["preferredRunDate"] = formatter.string(from: preferredRun)
                }

                let scanEvents = scan.historyEvents.sorted { $0.date > $1.date }
                if let latest = scanEvents.first {
                    switch latest.type {
                    case .noMatchFound:
                        scanInfo["lastResult"] = "noMatchFound"
                    case .matchesFound(let count):
                        scanInfo["lastResult"] = "matchesFound"
                        scanInfo["matchCount"] = count
                    case .error:
                        scanInfo["lastResult"] = "error"
                        if let error = latest.error {
                            scanInfo["lastError"] = error
                        }
                    case .scanStarted:
                        scanInfo["lastResult"] = "scanStarted"
                    default:
                        scanInfo["lastResult"] = String(describing: latest.type)
                    }
                    scanInfo["lastEventDate"] = formatter.string(from: latest.date)
                }
                scanInfo["totalErrors"] = scan.historyEvents.filter { $0.isError }.count

                var optOuts = [[String: Any]]()
                for optOut in item.optOutJobData {
                    var optOutInfo: [String: Any] = [
                        "extractedProfileId": optOut.extractedProfile.id ?? -1,
                        "extractedProfileName": optOut.extractedProfile.fullName ?? optOut.extractedProfile.name ?? "unknown",
                        "attemptCount": optOut.attemptCount,
                    ]

                    if let addr = optOut.extractedProfile.addresses?.first {
                        optOutInfo["extractedProfileAddress"] = "\(addr.city), \(addr.state)"
                    }
                    if let lastRun = optOut.lastRunDate {
                        optOutInfo["lastRunDate"] = formatter.string(from: lastRun)
                    }
                    if let preferredRun = optOut.preferredRunDate {
                        optOutInfo["preferredRunDate"] = formatter.string(from: preferredRun)
                    }
                    if let submitted = optOut.submittedSuccessfullyDate {
                        optOutInfo["submittedDate"] = formatter.string(from: submitted)
                    }
                    if let removed = optOut.extractedProfile.removedDate {
                        optOutInfo["removedDate"] = formatter.string(from: removed)
                    }

                    let optOutEvents = optOut.historyEvents.sorted { $0.date > $1.date }
                    if let latest = optOutEvents.first {
                        switch latest.type {
                        case .optOutStarted: optOutInfo["status"] = "started"
                        case .optOutRequested: optOutInfo["status"] = "requested"
                        case .optOutConfirmed: optOutInfo["status"] = "confirmed"
                        case .optOutSubmittedAndAwaitingEmailConfirmation: optOutInfo["status"] = "awaitingEmailConfirmation"
                        case .error:
                            optOutInfo["status"] = "error"
                            if let error = latest.error { optOutInfo["lastError"] = error }
                        case .reAppearence: optOutInfo["status"] = "reAppeared"
                        case .matchRemovedByUser: optOutInfo["status"] = "removedByUser"
                        default: optOutInfo["status"] = String(describing: latest.type)
                        }
                    }
                    optOutInfo["totalErrors"] = optOut.historyEvents.filter { $0.isError }.count
                    optOuts.append(optOutInfo)
                }

                var queryDict: [String: Any] = [
                    "profileQueryId": query.id ?? -1,
                    "firstName": query.firstName,
                    "lastName": query.lastName,
                    "city": query.city,
                    "state": query.state,
                    "scan": scanInfo,
                ]
                if !optOuts.isEmpty {
                    queryDict["optOuts"] = optOuts
                }
                profileQueries.append(queryDict)
            }

            let result: [String: Any] = [
                "brokerId": broker.id ?? -1,
                "brokerName": broker.name,
                "brokerURL": broker.url,
                "version": broker.version,
                "parent": broker.parent ?? NSNull(),
                "profileQueryCount": brokerItems.count,
                "profileQueries": profileQueries,
            ]

            return try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        } catch {
            Logger.dataBrokerProtection.error("Failed to fetch broker details: \(error.localizedDescription)")
            return nil
        }
    }
    public func getScanHistory(brokerId: Int64, profileQueryId: Int64) async -> Data? {
        do {
            let allData = try dataManager.fetchBrokerProfileQueryData(ignoresCache: true)
            let item = allData.first(where: {
                $0.dataBroker.id == brokerId && $0.profileQuery.id == profileQueryId
            })

            guard let item else { return nil }

            let events = item.scanJobData.historyEvents.sorted { $0.date < $1.date }
            return try serializeHistoryEvents(events)
        } catch {
            Logger.dataBrokerProtection.error("Failed to fetch scan history: \(error.localizedDescription)")
            return nil
        }
    }

    public func getOptOutHistory(brokerId: Int64, profileQueryId: Int64, extractedProfileId: Int64) async -> Data? {
        do {
            let allData = try dataManager.fetchBrokerProfileQueryData(ignoresCache: true)
            let item = allData.first(where: {
                $0.dataBroker.id == brokerId && $0.profileQuery.id == profileQueryId
            })

            guard let item else { return nil }

            let optOut = item.optOutJobData.first(where: {
                $0.extractedProfile.id == extractedProfileId
            })

            guard let optOut else { return nil }

            let events = optOut.historyEvents.sorted { $0.date < $1.date }
            return try serializeHistoryEvents(events)
        } catch {
            Logger.dataBrokerProtection.error("Failed to fetch opt-out history: \(error.localizedDescription)")
            return nil
        }
    }

    public func getSchedulerState(brokerName: String, profileQueryId: Int64, extractedProfileId: Int64, includeHistory: Bool) async -> Data? {
        do {
            let allData = try dataManager.fetchBrokerProfileQueryData(ignoresCache: true)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            let brokerItems = allData.filter {
                $0.dataBroker.name.lowercased() == brokerName.lowercased() ||
                $0.dataBroker.url.lowercased() == brokerName.lowercased()
            }

            // Filter by profileQueryId if specified (non-zero)
            let filteredItems = profileQueryId > 0
                ? brokerItems.filter { $0.profileQuery.id == profileQueryId }
                : brokerItems

            guard !filteredItems.isEmpty else { return nil }

            let broker = filteredItems.first!.dataBroker
            var queryResults = [[String: Any]]()

            for item in filteredItems {
                let scan = item.scanJobData

                var scanRow: [String: Any] = [
                    "brokerId": broker.id ?? -1,
                    "profileQueryId": item.profileQuery.id ?? -1,
                ]
                if let date = scan.preferredRunDate { scanRow["preferredRunDate"] = formatter.string(from: date) }
                if let date = scan.lastRunDate { scanRow["lastRunDate"] = formatter.string(from: date) }

                var scanHistory: [[String: Any]]?
                if includeHistory {
                    scanHistory = scan.historyEvents.sorted { $0.date < $1.date }.map { serializeHistoryEvent($0, formatter: formatter) }
                }

                // Filter opt-outs by extractedProfileId if specified (non-zero)
                let optOuts = extractedProfileId > 0
                    ? item.optOutJobData.filter { $0.extractedProfile.id == extractedProfileId }
                    : item.optOutJobData

                var optOutRows = [[String: Any]]()
                var optOutHistories = [String: [[String: Any]]]()

                for optOut in optOuts {
                    let epId = optOut.extractedProfile.id ?? -1
                    var row: [String: Any] = [
                        "extractedProfileId": epId,
                        "extractedProfileName": optOut.extractedProfile.fullName ?? optOut.extractedProfile.name ?? "unknown",
                        "attemptCount": optOut.attemptCount,
                    ]
                    if let date = optOut.preferredRunDate { row["preferredRunDate"] = formatter.string(from: date) }
                    if let date = optOut.lastRunDate { row["lastRunDate"] = formatter.string(from: date) }
                    if let date = optOut.submittedSuccessfullyDate { row["submittedSuccessfullyDate"] = formatter.string(from: date) }
                    optOutRows.append(row)

                    if includeHistory {
                        let events = optOut.historyEvents.sorted { $0.date < $1.date }.map { serializeHistoryEvent($0, formatter: formatter) }
                        optOutHistories["\(epId)"] = events
                    }
                }

                var queryResult: [String: Any] = [
                    "scanRow": scanRow,
                    "optOutRows": optOutRows,
                ]
                if let scanHistory { queryResult["scanHistory"] = scanHistory }
                if includeHistory { queryResult["optOutHistory"] = optOutHistories }

                // Include scheduling config for reproducing calculations
                if let configData = try? JSONEncoder().encode(broker.schedulingConfig),
                   let configDict = try? JSONSerialization.jsonObject(with: configData) as? [String: Any] {
                    queryResult["schedulingConfig"] = configDict
                }

                queryResults.append(queryResult)
            }

            let result: [String: Any] = [
                "brokerName": broker.name,
                "brokerURL": broker.url,
                "profileQueries": queryResults,
            ]

            return try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        } catch {
            Logger.dataBrokerProtection.error("Failed to fetch scheduler state: \(error.localizedDescription)")
            return nil
        }
    }

    private func serializeHistoryEvent(_ event: HistoryEvent, formatter: ISO8601DateFormatter) -> [String: Any] {
        var dict: [String: Any] = [
            "date": formatter.string(from: event.date),
        ]
        if let extractedProfileId = event.extractedProfileId {
            dict["extractedProfileId"] = extractedProfileId
        }
        switch event.type {
        case .scanStarted: dict["type"] = "scanStarted"
        case .noMatchFound: dict["type"] = "noMatchFound"
        case .matchesFound(let count):
            dict["type"] = "matchesFound"
            dict["matchCount"] = count
        case .optOutStarted: dict["type"] = "optOutStarted"
        case .optOutRequested: dict["type"] = "optOutRequested"
        case .optOutConfirmed: dict["type"] = "optOutConfirmed"
        case .optOutSubmittedAndAwaitingEmailConfirmation: dict["type"] = "awaitingEmailConfirmation"
        case .error:
            dict["type"] = "error"
            if let error = event.error { dict["error"] = error }
        case .reAppearence: dict["type"] = "reAppearance"
        case .matchRemovedByUser: dict["type"] = "matchRemovedByUser"
        }
        return dict
    }

    private func serializeHistoryEvents(_ events: [HistoryEvent]) throws -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let eventDicts: [[String: Any]] = events.map { event in
            var dict: [String: Any] = [
                "date": formatter.string(from: event.date),
                "brokerId": event.brokerId,
                "profileQueryId": event.profileQueryId,
            ]
            if let extractedProfileId = event.extractedProfileId {
                dict["extractedProfileId"] = extractedProfileId
            }
            switch event.type {
            case .scanStarted: dict["type"] = "scanStarted"
            case .noMatchFound: dict["type"] = "noMatchFound"
            case .matchesFound(let count):
                dict["type"] = "matchesFound"
                dict["matchCount"] = count
            case .optOutStarted: dict["type"] = "optOutStarted"
            case .optOutRequested: dict["type"] = "optOutRequested"
            case .optOutConfirmed: dict["type"] = "optOutConfirmed"
            case .optOutSubmittedAndAwaitingEmailConfirmation: dict["type"] = "awaitingEmailConfirmation"
            case .error:
                dict["type"] = "error"
                if let error = event.error { dict["error"] = error }
            case .reAppearence: dict["type"] = "reAppearance"
            case .matchRemovedByUser: dict["type"] = "matchRemovedByUser"
            }
            return dict
        }

        return try JSONSerialization.data(withJSONObject: eventDicts, options: [.prettyPrinted, .sortedKeys])
    }

    public func getAuthStatus() async -> Data? {
        let settings = DataBrokerProtectionSettings(defaults: .dbp)
        let isAuthenticated = await authenticationManager.isUserAuthenticated
        let hasToken = await authenticationManager.accessToken() != nil
        var hasEntitlement = false
        do {
            hasEntitlement = try await authenticationManager.hasValidEntitlement()
        } catch {}

        let result: [String: Any] = [
            "isAuthenticated": isAuthenticated,
            "hasAccessToken": hasToken,
            "hasValidEntitlement": hasEntitlement,
            "environment": settings.selectedEnvironment.rawValue,
            "endpointURL": settings.endpointURL.absoluteString,
        ]

        return try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    }

    // MARK: - MCP Debug Server Support (Actions)

    public func forceBrokerUpdate() async -> Data? {
        let settings = DataBrokerProtectionSettings(defaults: .dbp)
        settings.resetBrokerDeliveryData()

        do {
            try await brokerUpdater.checkForUpdates(skipsLimiter: true)
            let result: [String: Any] = [
                "success": true,
                "message": "Broker JSON update completed. Rate limiter bypassed, delivery data reset.",
            ]
            return try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        } catch {
            let result: [String: Any] = [
                "success": false,
                "error": error.localizedDescription,
            ]
            return try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        }
    }

    public func setAPIEndpoint(environment: String, serviceRoot: String) async -> Data? {
        let settings = DataBrokerProtectionSettings(defaults: .dbp)

        if let env = DataBrokerProtectionSettings.SelectedEnvironment(rawValue: environment) {
            settings.selectedEnvironment = env
        } else {
            let result: [String: Any] = [
                "success": false,
                "error": "Invalid environment '\(environment)'. Must be 'production' or 'staging'.",
            ]
            return try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        }

        settings.serviceRoot = serviceRoot

        let result: [String: Any] = [
            "success": true,
            "environment": settings.selectedEnvironment.rawValue,
            "serviceRoot": settings.serviceRoot,
            "endpointURL": settings.endpointURL.absoluteString,
        ]
        return try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    }

    // MARK: - Debug Scan/OptOut/WebView State

    public func runCustomScan(brokerJSON: Data, firstName: String, lastName: String, middleName: String?, city: String, state: String, birthYear: Int, showWebView: Bool, pauseOnError: Bool) async -> Data? {
        await debugScanSession.cleanUpPreviousWebView()
        debugScanSession.updateState { s in
            s.isRunning = true
            s.currentStep = "scan"
            s.currentAction = nil
            s.lastError = nil
            s.debugEvents.removeAll()
            s.lastExtractedProfiles.removeAll()
        }
        debugScanSession.debugEmailConfirmationStore.reset()

        do {
            let broker = try JSONDecoder().decode(DataBroker.self, from: brokerJSON)
            let resolvedBroker = broker.with(id: DebugHelper.stableId(for: broker))

            let profile = DataBrokerProtectionProfile(
                names: [.init(firstName: firstName, lastName: lastName, middleName: middleName)],
                addresses: [.init(city: city, state: state)],
                phones: [],
                birthYear: birthYear
            )

            var allExtracted = [ExtractedProfile]()

            for profileQuery in profile.profileQueries {
                let queryWithId = profileQuery.with(id: DebugHelper.stableId(for: profileQuery))
                let brokerId = DebugHelper.stableId(for: resolvedBroker)
                let profileQueryId = DebugHelper.stableId(for: queryWithId)
                let fakeScanJob = ScanJobData(
                    brokerId: brokerId,
                    profileQueryId: profileQueryId,
                    historyEvents: []
                )
                let queryData = BrokerProfileQueryData(
                    dataBroker: resolvedBroker,
                    profileQuery: queryWithId,
                    scanJobData: fakeScanJob
                )

                let stageCalculator = debugScanSession.makeStageCalculator()
                let runner = BrokerProfileScanSubJobWebRunner(
                    privacyConfig: jobDependencies.privacyConfig,
                    prefs: jobDependencies.contentScopeProperties,
                    context: queryData,
                    emailConfirmationDataService: debugEmailConfirmationService,
                    captchaService: debugCaptchaService,
                    featureFlagger: jobDependencies.featureFlagger,
                    applicationNameForUserAgent: jobDependencies.applicationNameForUserAgent,
                    stageDurationCalculator: stageCalculator,
                    pixelHandler: debugPixelHandler,
                    executionConfig: .init(),
                    shouldRunNextStep: { true }
                )
                runner.keepWebViewAlive = pauseOnError

                do {
                    let profiles = try await runner.scan(queryData, showWebView: showWebView) { true }

                    // Store in debug email confirmation store (mirrors debug VM flow)
                    let assignedProfiles: [ExtractedProfile] = profiles.map { profile in
                        debugScanSession.debugEmailConfirmationStore.storeExtractedProfile(
                            profile,
                            brokerId: brokerId,
                            profileQueryId: profileQueryId,
                            stableId: DebugHelper.stableId(for: profile)
                        )
                    }
                    allExtracted.append(contentsOf: assignedProfiles)

                    // Success — clean up WebView
                    await runner.webViewHandler?.finish()
                } catch {
                    // Error — keep WebView alive for inspection
                    debugScanSession.activeWebViewHandler = runner.webViewHandler
                    throw error
                }
            }

            debugScanSession.updateState { s in
                s.isRunning = false
                s.currentStep = "idle"
                s.lastBroker = resolvedBroker
                s.lastProfileQuery = profile.profileQueries.first
                s.lastExtractedProfiles = allExtracted
            }

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let result: [String: Any] = [
                "success": true,
                "matchCount": allExtracted.count,
                "extractedProfiles": (try? JSONSerialization.jsonObject(with: encoder.encode(allExtracted))) ?? [],
            ]
            return try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])

        } catch {
            Logger.dataBrokerProtection.error("Debug scan failed: \(error.localizedDescription, privacy: .public)")
            debugScanSession.updateState { s in
                s.isRunning = false
                s.currentStep = "paused"
                s.lastError = error.localizedDescription
            }
            let result: [String: Any] = [
                "success": false,
                "error": error.localizedDescription,
                "webViewAlive": debugScanSession.activeWebViewHandler != nil,
            ]
            return try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        }
    }

    public func runCustomOptOut(brokerJSON: Data, extractedProfileJSON: Data, firstName: String, lastName: String, middleName: String?, city: String, state: String, birthYear: Int, showWebView: Bool, pauseOnError: Bool) async -> Data? {
        await debugScanSession.cleanUpPreviousWebView()
        debugScanSession.updateState { s in
            s.isRunning = true
            s.currentStep = "optOut"
            s.currentAction = nil
            s.lastError = nil
            s.debugEvents.removeAll()
        }

        do {
            let broker = try JSONDecoder().decode(DataBroker.self, from: brokerJSON)
            let resolvedBroker = broker.with(id: DebugHelper.stableId(for: broker))
            let extractedProfile = try JSONDecoder().decode(ExtractedProfile.self, from: extractedProfileJSON)

            let profile = DataBrokerProtectionProfile(
                names: [.init(firstName: firstName, lastName: lastName, middleName: middleName)],
                addresses: [.init(city: city, state: state)],
                phones: [],
                birthYear: birthYear
            )

            guard let profileQuery = profile.profileQueries.first else {
                throw NSError(domain: "DebugScan", code: -1, userInfo: [NSLocalizedDescriptionKey: "No profile queries generated"])
            }

            let queryWithId = profileQuery.with(id: DebugHelper.stableId(for: profileQuery))
            let fakeScanJob = ScanJobData(
                brokerId: DebugHelper.stableId(for: resolvedBroker),
                profileQueryId: DebugHelper.stableId(for: queryWithId),
                historyEvents: []
            )
            let queryData = BrokerProfileQueryData(
                dataBroker: resolvedBroker,
                profileQuery: queryWithId,
                scanJobData: fakeScanJob
            )

            let stageCalculator = debugScanSession.makeStageCalculator()
            let runner = BrokerProfileOptOutSubJobWebRunner(
                privacyConfig: jobDependencies.privacyConfig,
                prefs: jobDependencies.contentScopeProperties,
                context: queryData,
                emailConfirmationDataService: debugEmailConfirmationService,
                captchaService: debugCaptchaService,
                featureFlagger: jobDependencies.featureFlagger,
                applicationNameForUserAgent: jobDependencies.applicationNameForUserAgent,
                stageCalculator: stageCalculator,
                pixelHandler: debugPixelHandler,
                executionConfig: .init(),
                actionsHandlerMode: .optOut,
                shouldRunNextStep: { true }
            )
            runner.keepWebViewAlive = pauseOnError

            // Store optout context for email confirmation flow
            debugScanSession.updateState { s in
                s.lastOptOutExtractedProfile = extractedProfile
            }

            do {
                try await runner.optOut(
                    profileQuery: queryData,
                    extractedProfile: extractedProfile,
                    showWebView: showWebView
                ) { true }

                // Success — clean up WebView
                await runner.webViewHandler?.finish()
            } catch {
                // Error — keep WebView alive for inspection if pauseOnError
                if pauseOnError {
                    debugScanSession.activeWebViewHandler = runner.webViewHandler
                }
                throw error
            }

            debugScanSession.updateState { s in
                s.isRunning = false
                s.currentStep = "idle"
            }

            let result: [String: Any] = [
                "success": true,
                "message": "Opt-out completed successfully.",
            ]
            return try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])

        } catch {
            // Keep WebView alive for inspection
            Logger.dataBrokerProtection.error("Debug opt-out failed: \(error.localizedDescription, privacy: .public)")
            debugScanSession.updateState { s in
                s.isRunning = false
                s.currentStep = "paused"
                s.lastError = error.localizedDescription
            }
            let result: [String: Any] = [
                "success": false,
                "error": error.localizedDescription,
                "webViewAlive": debugScanSession.activeWebViewHandler != nil,
            ]
            return try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        }
    }

    public func getWebViewState() async -> Data? {
        return await debugScanSession.serializeState()
    }

    public func executeJavaScript(code: String) async -> Data? {
        guard let handler = debugScanSession.activeWebViewHandler else {
            let result: [String: Any] = [
                "success": false,
                "error": "No active WebView. Run a scan or optout first (WebView is kept alive on error).",
            ]
            return try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        }

        do {
            let jsResult = try await handler.evaluateJavaScriptReturningResult(code)
            var result: [String: Any] = ["success": true]
            if let stringResult = jsResult as? String {
                result["result"] = stringResult
            } else if let numResult = jsResult as? NSNumber {
                result["result"] = numResult
            } else if let boolResult = jsResult as? Bool {
                result["result"] = boolResult
            } else if jsResult == nil || jsResult is NSNull {
                result["result"] = NSNull()
            } else {
                result["result"] = String(describing: jsResult)
            }
            return try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        } catch {
            let result: [String: Any] = [
                "success": false,
                "error": error.localizedDescription,
            ]
            return try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        }
    }

    public func checkEmailConfirmation() async -> Data? {
        do {
            try await debugEmailConfirmationService.checkForEmailConfirmationData()

            // Check if confirmation link is now available
            let store = debugScanSession.debugEmailConfirmationStore
            let withLinks = try store.fetchOptOutEmailConfirmationsWithLink()
            let awaiting = try store.fetchOptOutEmailConfirmationsAwaitingLink()

            let result: [String: Any] = [
                "success": true,
                "confirmationsWithLink": withLinks.count,
                "confirmationsAwaiting": awaiting.count,
                "message": withLinks.isEmpty
                    ? "No confirmation links found yet. Try again later."
                    : "Found \(withLinks.count) confirmation link(s). Use continue_optout to complete the opt-out.",
            ]
            return try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        } catch {
            let result: [String: Any] = [
                "success": false,
                "error": error.localizedDescription,
            ]
            return try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        }
    }

    public func continueOptOut(brokerJSON: Data, extractedProfileJSON: Data, firstName: String, lastName: String, middleName: String?, city: String, state: String, birthYear: Int, showWebView: Bool, pauseOnError: Bool) async -> Data? {
        // Find the confirmation URL from the debug email store
        let s = debugScanSession.state
        guard let broker = try? JSONDecoder().decode(DataBroker.self, from: brokerJSON) else {
            let result: [String: Any] = ["success": false, "error": "Invalid broker JSON"]
            return try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        }

        guard let extractedProfile = try? JSONDecoder().decode(ExtractedProfile.self, from: extractedProfileJSON),
              let extractedProfileId = extractedProfile.id else {
            let result: [String: Any] = ["success": false, "error": "Invalid extracted profile or missing ID"]
            return try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        }

        let resolvedBroker = broker.with(id: DebugHelper.stableId(for: broker))
        let profile = DataBrokerProtectionProfile(
            names: [.init(firstName: firstName, lastName: lastName, middleName: middleName)],
            addresses: [.init(city: city, state: state)],
            phones: [],
            birthYear: birthYear
        )
        guard let profileQuery = profile.profileQueries.first else {
            let result: [String: Any] = ["success": false, "error": "No profile queries generated"]
            return try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        }

        let brokerId = DebugHelper.stableId(for: resolvedBroker)
        let profileQueryId = DebugHelper.stableId(for: profileQuery)

        // Look up confirmation URL from email store
        guard let confirmations = try? debugScanSession.debugEmailConfirmationStore.fetchOptOutEmailConfirmationsWithLink(),
              let match = confirmations.first(where: { $0.brokerId == brokerId && $0.profileQueryId == profileQueryId && $0.extractedProfileId == extractedProfileId }),
              let link = match.emailConfirmationLink,
              let confirmationURL = URL(string: link) else {
            let result: [String: Any] = ["success": false, "error": "No confirmation link found. Run check_email_confirmation first."]
            return try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        }

        await debugScanSession.cleanUpPreviousWebView()
        debugScanSession.updateState { s in
            s.isRunning = true
            s.currentStep = "emailConfirmation"
            s.currentAction = nil
            s.lastError = nil
            s.debugEvents.removeAll()
        }

        do {
            let queryWithId = profileQuery.with(id: profileQueryId)
            let fakeScanJob = ScanJobData(brokerId: brokerId, profileQueryId: profileQueryId, historyEvents: [])
            let queryData = BrokerProfileQueryData(dataBroker: resolvedBroker, profileQuery: queryWithId, scanJobData: fakeScanJob)

            let stageCalculator = debugScanSession.makeStageCalculator()
            let runner = BrokerProfileOptOutSubJobWebRunner(
                privacyConfig: jobDependencies.privacyConfig,
                prefs: jobDependencies.contentScopeProperties,
                context: queryData,
                emailConfirmationDataService: debugEmailConfirmationService,
                captchaService: debugCaptchaService,
                featureFlagger: jobDependencies.featureFlagger,
                applicationNameForUserAgent: jobDependencies.applicationNameForUserAgent,
                stageCalculator: stageCalculator,
                pixelHandler: debugPixelHandler,
                executionConfig: .init(),
                actionsHandlerMode: .emailConfirmation(confirmationURL),
                shouldRunNextStep: { true }
            )
            runner.keepWebViewAlive = pauseOnError

            do {
                try await runner.optOut(profileQuery: queryData, extractedProfile: extractedProfile, showWebView: showWebView) { true }
                await runner.webViewHandler?.finish()
            } catch {
                if pauseOnError {
                    debugScanSession.activeWebViewHandler = runner.webViewHandler
                }
                throw error
            }

            debugScanSession.updateState { s in
                s.isRunning = false
                s.currentStep = "idle"
            }

            let result: [String: Any] = ["success": true, "message": "Opt-out email confirmation completed successfully."]
            return try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        } catch {
            Logger.dataBrokerProtection.error("Debug email confirmation opt-out failed: \(error.localizedDescription, privacy: .public)")
            debugScanSession.updateState { s in
                s.isRunning = false
                s.currentStep = pauseOnError ? "paused" : "idle"
                s.lastError = error.localizedDescription
            }
            let result: [String: Any] = [
                "success": false,
                "error": error.localizedDescription,
                "webViewAlive": debugScanSession.activeWebViewHandler != nil,
            ]
            return try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        }
    }

    public func reauthenticate() async -> Data? {
        // Sign out to clear stale auth
        await authenticationManager.signOut()

        // Open the activation flow URL in the DuckDuckGo browser for the user to re-auth.
        // Derive the browser bundle ID from the agent's own bundle ID.
        let activationURLString = "https://duckduckgo.com/subscriptions/activation-flow"
        let browserBundleID = Bundle.main.bundleIdentifier?
            .replacingOccurrences(of: ".DBP.backgroundAgent", with: "") ?? "com.duckduckgo.macos.browser.debug"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-b", browserBundleID, activationURLString]
        try? process.run()

        let result: [String: Any] = [
            "success": true,
            "message": "Signed out. Activation flow opened in browser — please sign in to get a fresh auth token. Use get_auth_status to verify when done.",
        ]
        return try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    }
}

extension DataBrokerProtectionAgentManager: DataBrokerProtectionAppToAgentInterface {

}

extension DataBrokerProtectionAgentManager: EmailConfirmationDataDelegate {
    public func checkForEmailConfirmationData() async {
        do {
            try await emailConfirmationDataService?.checkForEmailConfirmationData()
        } catch {
            Logger.dataBrokerProtection.error("Email confirmation data check failed: \(error, privacy: .public)")
        }
    }
}

extension DataBrokerProtectionAgentManager: DBPWideEventsDelegate {
    public func sweepWideEvents() {
        wideEventSweeper?.sweep()
    }
}
