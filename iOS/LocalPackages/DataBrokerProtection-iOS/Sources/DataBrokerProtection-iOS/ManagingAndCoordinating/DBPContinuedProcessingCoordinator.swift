//
//  DBPContinuedProcessingCoordinator.swift
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

import BackgroundTasks
import DataBrokerProtectionCore
import Foundation
import os.log

@MainActor
protocol DBPContinuedProcessingEventDelegate: AnyObject {
    func iosManager(_ manager: DataBrokerProtectionIOSManager, didEmit event: DBPContinuedProcessingEvent)
}

enum DBPContinuedProcessingEvent {
    case scanJobCompleted(DBPContinuedProcessingProgressReporter.ScanJobID)
    case optOutJobCompleted(DBPContinuedProcessingProgressReporter.OptOutJobID)
    case scanPhaseCompleted
    case optOutPhaseCompleted
}

@available(iOS 26.0, *)
@MainActor
final class DBPContinuedProcessingCoordinator {

    enum Phase {
        case initialScan
        case initialOptOut
    }

    private enum Constants {
        static let taskSemanticContext = "dbp.continuedProcessing"
        static let taskTitle = "Personal Information Removal"
        static let heartbeatInterval: TimeInterval = 1.5
    }

    private weak var manager: DataBrokerProtectionIOSManager?
    private let progressReporter: DBPContinuedProcessingProgressReporter

    private var taskIdentifier: String?
    private var phase: Phase?
    private var task: BGContinuedProcessingTask?
    private var registeredTaskIdentifiers = Set<String>()
    private var heartbeatTimer: Timer?

    var hasAttachedTask: Bool {
        task != nil
    }

    init(manager: DataBrokerProtectionIOSManager,
         progressReporter: DBPContinuedProcessingProgressReporter? = nil) {
        self.manager = manager
        self.progressReporter = progressReporter ?? DBPContinuedProcessingProgressReporter()
    }

    // MARK: - Run Lifecycle

    /// Prepares the initial run, registers the continued task, and starts the initial scan phase.
    func startInitialRun(profile: DataBrokerProtectionProfile) async throws {
        guard let scanSummary = try await prepareInitialRun(profile: profile) else {
            Logger.dataBrokerProtection.log("Continued processing: no pending scans found during initial run preparation")
            return
        }

        phase = .initialScan
        manager?.continuedProcessingDelegate = self

        try registerAndSubmitTask()
        startHeartbeat()
        await startScanPhase()
    }

    /// Attaches the system-provided continued task and starts keeping its presentation in sync.
    func attach(task: BGContinuedProcessingTask) {
        self.task = task
        Logger.dataBrokerProtection.log(
            "Continued processing: attached task for run \(self.logRunIdentifier(), privacy: .public) in phase \(String(describing: self.phase), privacy: .public)"
        )
        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                self?.expire()
            }
        }

        refreshContinuedProcessingUI()
    }

    /// Stops continued-processing work when the system expires the task.
    func expire() {
        Logger.dataBrokerProtection.log(
            "Continued processing: task expired for run \(self.logRunIdentifier(), privacy: .public) in phase \(String(describing: self.phase), privacy: .public)"
        )
        manager?.stopContinuedProcessingOperations()
        finish(success: false)
    }

    /// Tears down the continued task and reports final success to the system.
    private func finish(success: Bool) {
        Logger.dataBrokerProtection.log(
            "Continued processing: finishing run \(self.logRunIdentifier(), privacy: .public) success=\(success, privacy: .public) phase=\(String(describing: self.phase), privacy: .public)"
        )
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        manager?.continuedProcessingDelegate = nil

        if success {
            progressReporter.completeAll()
            refreshContinuedProcessingUI()
        }

        task?.setTaskCompleted(success: success)
        task = nil
        phase = nil
        taskIdentifier = nil
    }

    // MARK: - Phases

    /// Transitions into the initial scan phase and starts immediate scans through the manager.
    func startScanPhase() async {
        transition(to: .initialScan) {
            progressReporter.enterScanPhase()
        }
        Logger.dataBrokerProtection.log("Continued processing: starting scan phase for run \(self.logRunIdentifier(), privacy: .public)")
        await manager?.startImmediateScanOperationsForContinuedProcessing()
    }

    /// Completes scan progress and either moves to initial opt-outs or finishes the run.
    func handleScanPhaseCompleted() async {
        progressReporter.completeScanPhase()
        refreshContinuedProcessingUI()
        Logger.dataBrokerProtection.log("Continued processing: scan phase completed for run \(self.logRunIdentifier(), privacy: .public)")

        guard let optOutSummary = try? manager?.makeContinuedProcessingOptOutSummary() else {
            Logger.dataBrokerProtection.log("Continued processing: failed to load opt-out summary after scan phase for run \(self.logRunIdentifier(), privacy: .public)")
            finish(success: false)
            return
        }

        guard optOutSummary.optOutCount > 0 else {
            Logger.dataBrokerProtection.log("Continued processing: no initial opt-outs found after scan phase for run \(self.logRunIdentifier(), privacy: .public)")
            finish(success: true)
            return
        }

        Logger.dataBrokerProtection.log(
            "Continued processing: discovered \(optOutSummary.optOutCount, privacy: .public) initial opt-outs for run \(self.logRunIdentifier(), privacy: .public)"
        )
        await startOptOutPhase(optOutSummary: optOutSummary)
    }

    /// Transitions into the initial opt-out phase and starts immediate opt-out work.
    func startOptOutPhase(optOutSummary: DBPContinuedProcessingProgressReporter.OptOutSummary) async {
        transition(to: .initialOptOut) {
            progressReporter.enterOptOutPhase(summary: optOutSummary)
        }
        Logger.dataBrokerProtection.log("Continued processing: starting opt-out phase for run \(self.logRunIdentifier(), privacy: .public)")
        manager?.startImmediateOptOutOperationsForContinuedProcessing()
    }

    /// Completes opt-out progress and finishes the continued-processing run.
    func handleOptOutPhaseCompleted() {
        progressReporter.completeOptOutPhase()
        refreshContinuedProcessingUI()
        Logger.dataBrokerProtection.log("Continued processing: opt-out phase completed for run \(self.logRunIdentifier(), privacy: .public)")
        finish(success: true)
    }

    // MARK: - Task Presentation

    @MainActor
    /// Refreshes the system UI.
    private func refreshContinuedProcessingUI() {
        let snapshot = progressReporter.snapshot()
        task?.progress.totalUnitCount = max(snapshot.total, 1)
        task?.progress.completedUnitCount = min(snapshot.completed, max(snapshot.total, 1))
        task?.updateTitle(title(for: self.phase), subtitle: subtitle(for: self.phase))
    }

    // MARK: - Helpers

    /// Builds the initial scan summary and seeds the progress reporter for the run.
    private func prepareInitialRun(profile: DataBrokerProtectionProfile) async throws -> DBPContinuedProcessingProgressReporter.InitialScanSummary? {
        guard let scanSummary = try await manager?.prepareContinuedProcessingInitialRun(profile: profile) else {
            return nil
        }

        Logger.dataBrokerProtection.log(
            "Continued processing: preparing initial run with \(scanSummary.scanCount, privacy: .public) scans"
        )
        let scanJobTimeout = manager?.continuedProcessingScanJobTimeout() ?? .minutes(3)
        let scanBudgetUnitsPerJob = max(Int64(scanJobTimeout / Constants.heartbeatInterval), 1)
        Logger.dataBrokerProtection.log(
            "Continued processing: derived scan budget units per job \(scanBudgetUnitsPerJob, privacy: .public) from timeout \(scanJobTimeout, privacy: .public)s and heartbeat \(Constants.heartbeatInterval, privacy: .public)s"
        )
        progressReporter.startInitialRun(summary: scanSummary, scanBudgetUnitsPerJob: scanBudgetUnitsPerJob)
        return scanSummary
    }

    /// Creates a unique task identifier, registers the handler, and submits the continued task request.
    private func registerAndSubmitTask() throws {
        let taskIdentifier = makeTaskIdentifier()
        self.taskIdentifier = taskIdentifier
        Logger.dataBrokerProtection.log("Continued processing: starting run \(self.logRunIdentifier(), privacy: .public) with task identifier \(taskIdentifier, privacy: .public)")
        try registerTaskHandlerIfNeeded(identifier: taskIdentifier)
        try submitTaskRequest(identifier: taskIdentifier)
    }

    /// Keeps the system task alive by periodically advancing synthetic progress.
    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: Constants.heartbeatInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.progressReporter.advanceHeartbeat()
                self.refreshContinuedProcessingUI()
            }
        }
    }

    @MainActor
    /// Switches the active phase and refreshes the system task UI after phase-specific updates.
    private func transition(to phase: Phase, updateProgress: @MainActor () -> Void) {
        self.phase = phase
        updateProgress()
        refreshContinuedProcessingUI()
    }

    /// Builds the unique identifier used to register and submit a continued task request.
    private func makeTaskIdentifier() -> String {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.duckduckgo.app"
        return "\(bundleIdentifier).\(Constants.taskSemanticContext).\(UUID().uuidString)"
    }

    /// Returns a short log-friendly suffix derived from the full task identifier.
    private func logRunIdentifier() -> String {
        guard let taskIdentifier else { return "unknown" }
        return taskIdentifier.split(separator: ".").last.map(String.init) ?? taskIdentifier
    }

    @available(iOS 26.0, *)
    /// Registers the continued task handler once per generated task identifier.
    private func registerTaskHandlerIfNeeded(identifier: String) throws {
        guard !registeredTaskIdentifiers.contains(identifier) else {
            Logger.dataBrokerProtection.log("Continued processing: task handler already registered for identifier \(identifier, privacy: .public)")
            return
        }

        Logger.dataBrokerProtection.log("Continued processing: registering task handler for identifier \(identifier, privacy: .public)")

        let didRegister = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            Logger.dataBrokerProtection.log("Continued processing: task handler invoked for identifier \(identifier, privacy: .public)")
            guard let continuedTask = task as? BGContinuedProcessingTask else {
                Logger.dataBrokerProtection.error("Continued processing: received non-continued task for identifier \(identifier, privacy: .public)")
                task.setTaskCompleted(success: true)
                return
            }

            Task { @MainActor in
                self.attach(task: continuedTask)
            }
        }

        guard didRegister else {
            Logger.dataBrokerProtection.error("Continued processing: failed to register task handler for identifier \(identifier, privacy: .public)")
            throw DBPContinuedProcessingError.taskHandlerRegistrationFailed
        }

        Logger.dataBrokerProtection.log("Continued processing: successfully registered task handler for identifier \(identifier, privacy: .public)")
        registeredTaskIdentifiers.insert(identifier)
    }

    @available(iOS 26.0, *)
    /// Submits the continued task request that lets the system relaunch or continue the work.
    private func submitTaskRequest(identifier: String) throws {
        #if targetEnvironment(simulator)
        Logger.dataBrokerProtection.log("Continued processing: skipping task request submission on simulator for identifier \(identifier, privacy: .public)")
        return
        #else
        let request = BGContinuedProcessingTaskRequest(identifier: identifier,
                                                       title: Constants.taskTitle,
                                                       subtitle: progressReporter.scanSubtitle)
        request.strategy = .queue

        do {
            Logger.dataBrokerProtection.log("Continued processing: submitting task request for identifier \(identifier, privacy: .public)")
            try BGTaskScheduler.shared.submit(request)
            Logger.dataBrokerProtection.log("Continued processing: submitted task request for identifier \(identifier, privacy: .public)")
        } catch {
            Logger.dataBrokerProtection.error(
                "Continued processing: failed to submit task request for identifier \(identifier, privacy: .public), error: \(error.localizedDescription, privacy: .public)"
            )
            throw DBPContinuedProcessingError.taskRequestSubmissionFailed(underlyingError: error)
        }
        #endif
    }

    /// Returns the static system task title shown throughout the run.
    private func title(for phase: Phase?) -> String {
        Constants.taskTitle
    }

    /// Returns the current phase-specific subtitle for the system task.
    private func subtitle(for phase: Phase?) -> String {
        switch phase {
        case .initialOptOut:
            progressReporter.optOutSubtitle
        default:
            progressReporter.scanSubtitle
        }
    }
}

// MARK: - DBPContinuedProcessingEventDelegate

@available(iOS 26.0, *)
extension DBPContinuedProcessingCoordinator: DBPContinuedProcessingEventDelegate {
    /// Applies manager-emitted scan and opt-out events to the current continued-processing run.
    func iosManager(_ manager: DataBrokerProtectionIOSManager, didEmit event: DBPContinuedProcessingEvent) {
        switch event {
        case .scanJobCompleted(let id):
            guard phase == .initialScan else { return }
            progressReporter.recordCompletedScan(id)
            refreshContinuedProcessingUI()
        case .optOutJobCompleted(let id):
            guard phase == .initialOptOut else { return }
            progressReporter.recordCompletedOptOut(id)
            refreshContinuedProcessingUI()
        case .scanPhaseCompleted:
            Task { @MainActor in
                await handleScanPhaseCompleted()
            }
        case .optOutPhaseCompleted:
            handleOptOutPhaseCompleted()
        }
    }
}
