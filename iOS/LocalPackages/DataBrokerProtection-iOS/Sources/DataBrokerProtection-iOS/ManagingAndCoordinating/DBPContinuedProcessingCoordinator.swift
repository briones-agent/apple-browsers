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
    private var runStartedAt: Date?
    private var phase: Phase?
    private var task: BGContinuedProcessingTask?
    private var registeredTaskIdentifiers = Set<String>()
    private var heartbeatTimer: Timer?

    var hasAttachedTask: Bool {
        task != nil
    }

    init(manager: DataBrokerProtectionIOSManager) {
        self.manager = manager
        self.progressReporter = DBPContinuedProcessingProgressReporter()
    }

    init(
        manager: DataBrokerProtectionIOSManager,
        progressReporter: DBPContinuedProcessingProgressReporter
    ) {
        self.manager = manager
        self.progressReporter = progressReporter
    }

    // MARK: - Run Lifecycle

    func startInitialRun(profile: DataBrokerProtectionProfile) async throws {
        guard let manager else { return }

        guard let scanSummary = try await manager.prepareContinuedProcessingInitialRun(profile: profile) else {
            Logger.dataBrokerProtection.log("Continued processing: no pending scans found during initial run preparation")
            return
        }

        Logger.dataBrokerProtection.log(
            "Continued processing: preparing initial run with \(scanSummary.scanCount, privacy: .public) scans"
        )
        let scanJobTimeout = manager.continuedProcessingScanJobTimeout()
        let scanBudgetUnitsPerJob = max(Int64(scanJobTimeout / Constants.heartbeatInterval), 1)
        Logger.dataBrokerProtection.log(
            "Continued processing: derived scan budget units per job \(scanBudgetUnitsPerJob, privacy: .public) from timeout \(scanJobTimeout, privacy: .public)s and heartbeat \(Constants.heartbeatInterval, privacy: .public)s"
        )
        progressReporter.startInitialRun(summary: scanSummary, scanBudgetUnitsPerJob: scanBudgetUnitsPerJob)
        runStartedAt = Date()

        phase = .initialScan
        manager.continuedProcessingDelegate = self

        let taskIdentifier = makeTaskIdentifier()
        self.taskIdentifier = taskIdentifier
        Logger.dataBrokerProtection.log("Continued processing: starting run \(self.logRunIdentifier(), privacy: .public) with task identifier \(taskIdentifier, privacy: .public)")
        try registerTaskHandlerIfNeeded(identifier: taskIdentifier)
        try submitTaskRequest(identifier: taskIdentifier)

        startHeartbeat()
        await startScanPhase()
    }

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

    func expire() {
        Logger.dataBrokerProtection.log(
            "Continued processing: task expired for run \(self.logRunIdentifier(), privacy: .public) in phase \(String(describing: self.phase), privacy: .public)"
        )
        manager?.stopContinuedProcessingOperations()
        finish(success: false)
    }

    private func finish(success: Bool) {
        Logger.dataBrokerProtection.log(
            "Continued processing: finishing run \(self.logRunIdentifier(), privacy: .public) success=\(success, privacy: .public) phase=\(String(describing: self.phase), privacy: .public)"
        )
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        manager?.continuedProcessingDelegate = nil

        if success {
            progressReporter.completeAll()
            publishProgress()
        }

        task?.setTaskCompleted(success: success)
        task = nil
        phase = nil
        taskIdentifier = nil
        runStartedAt = nil
    }

    // MARK: - Phases

    func startScanPhase() async {
        guard let manager else { return }
        transition(to: .initialScan) {
            progressReporter.enterScanPhase()
        }
        Logger.dataBrokerProtection.log("Continued processing: starting scan phase for run \(self.logRunIdentifier(), privacy: .public)")
        await manager.startImmediateScanOperationsForContinuedProcessing()
    }

    func handleScanPhaseCompleted() async {
        progressReporter.completeScanPhase()
        refreshContinuedProcessingUI()
        Logger.dataBrokerProtection.log("Continued processing: scan phase completed for run \(self.logRunIdentifier(), privacy: .public)")

        guard let manager,
              let optOutSummary = try? manager.makeContinuedProcessingOptOutSummary() else {
            Logger.dataBrokerProtection.log("Continued processing: failed to load opt-out summary after scan phase for run \(self.logRunIdentifier(), privacy: .public)")
            finish(success: false)
            return
        }

        guard
              optOutSummary.optOutCount > 0 else {
            Logger.dataBrokerProtection.log("Continued processing: no initial opt-outs found after scan phase for run \(self.logRunIdentifier(), privacy: .public)")
            finish(success: true)
            return
        }

        Logger.dataBrokerProtection.log(
            "Continued processing: discovered \(optOutSummary.optOutCount, privacy: .public) initial opt-outs for run \(self.logRunIdentifier(), privacy: .public)"
        )
        await startOptOutPhase(optOutSummary: optOutSummary)
    }

    func startOptOutPhase(optOutSummary: DBPContinuedProcessingProgressReporter.OptOutSummary) async {
        guard let manager else { return }
        transition(to: .initialOptOut) {
            progressReporter.enterOptOutPhase(summary: optOutSummary)
        }
        Logger.dataBrokerProtection.log("Continued processing: starting opt-out phase for run \(self.logRunIdentifier(), privacy: .public)")
        manager.startImmediateOptOutOperationsForContinuedProcessing()
    }

    func handleOptOutPhaseCompleted() {
        progressReporter.completeOptOutPhase()
        refreshContinuedProcessingUI()
        Logger.dataBrokerProtection.log("Continued processing: opt-out phase completed for run \(self.logRunIdentifier(), privacy: .public)")
        finish(success: true)
    }

    // MARK: - Task Presentation

    private func publishProgress() {
        guard let task else { return }
        let snapshot = progressReporter.snapshot()
        task.progress.totalUnitCount = max(snapshot.total, 1)
        task.progress.completedUnitCount = min(snapshot.completed, max(snapshot.total, 1))
    }

    private func refreshContinuedProcessingUI() {
        publishProgress()
        updateTaskPresentation()
    }

    func updateTaskPresentation() {
        guard let task else { return }
        task.updateTitle(title(for: self.phase), subtitle: subtitle(for: self.phase))
    }

    // MARK: - Helpers

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

    private func transition(to phase: Phase, updateProgress: () -> Void) {
        self.phase = phase
        updateProgress()
        refreshContinuedProcessingUI()
    }

    private func makeTaskIdentifier() -> String {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.duckduckgo.app"
        return "\(bundleIdentifier).\(Constants.taskSemanticContext).\(UUID().uuidString)"
    }

    private func logRunIdentifier() -> String {
        guard let taskIdentifier else { return "unknown" }
        return taskIdentifier.split(separator: ".").last.map(String.init) ?? taskIdentifier
    }

    @available(iOS 26.0, *)
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

    private func title(for phase: Phase?) -> String {
        Constants.taskTitle
    }

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
