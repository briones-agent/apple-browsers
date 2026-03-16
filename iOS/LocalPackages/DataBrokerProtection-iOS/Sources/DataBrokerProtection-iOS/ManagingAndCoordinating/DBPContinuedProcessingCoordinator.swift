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
    case scanPhaseCompleted
    case optOutPhaseCompleted
}

@MainActor
protocol DBPContinuedProcessingCoordinating {
    var hasAttachedTask: Bool { get }
    func startInitialRun(profile: DataBrokerProtectionProfile) async throws
}

@available(iOS 26.0, *)
@MainActor
final class DBPContinuedProcessingCoordinator {

    enum Phase {
        case initialScan
        case initialOptOut
    }

    private enum Constants {
        static let taskIdentifierPrefix = "dbp.continuedProcessing"
        static let taskTitle = "Personal Information Removal"
        static let taskSubtitle = "In Progress"
    }

    private weak var manager: DataBrokerProtectionIOSManager?

    private var taskIdentifier: String?
    private var runStartedAt: Date?
    private var phase: Phase?
    private var task: BGContinuedProcessingTask?

    var hasAttachedTask: Bool {
        task != nil
    }

    init(manager: DataBrokerProtectionIOSManager) {
        self.manager = manager
    }

    // MARK: - Run Lifecycle

    func startInitialRun(profile: DataBrokerProtectionProfile) async throws {
        guard let manager else { return }

        let hasPendingScans = try await manager.prepareContinuedProcessingInitialRun(profile: profile)
        guard hasPendingScans else {
            Logger.dataBrokerProtection.log("Continued processing: no pending scans found during initial run preparation")
            return
        }

        Logger.dataBrokerProtection.log("Continued processing: prepared initial run")
        runStartedAt = Date()

        phase = .initialScan
        manager.continuedProcessingDelegate = self

        let taskIdentifier = makeUniqueTaskIdentifier()
        self.taskIdentifier = taskIdentifier
        Logger.dataBrokerProtection.log("Continued processing: starting run \(self.logRunIdentifier(), privacy: .public) with task identifier \(taskIdentifier, privacy: .public)")
        do {
            try registerTaskHandler(identifier: taskIdentifier)
            try submitTaskRequest(identifier: taskIdentifier)
        } catch {
            finish(success: false)
            throw error
        }

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
            "Continued processing: finishing run \(self.logRunIdentifier(), privacy: .public) elapsed=\(self.elapsedDescription(), privacy: .public) success=\(success, privacy: .public) phase=\(String(describing: self.phase), privacy: .public)"
        )
        manager?.continuedProcessingDelegate = nil

        task?.setTaskCompleted(success: success)
        task = nil
        phase = nil
        taskIdentifier = nil
        runStartedAt = nil
    }

    // MARK: - Phases

    func startScanPhase() async {
        guard let manager else { return }
        transition(to: .initialScan)
        Logger.dataBrokerProtection.log("Continued processing: starting scan phase for run \(self.logRunIdentifier(), privacy: .public)")
        await manager.startImmediateScanOperationsForContinuedProcessing()
    }

    func handleScanPhaseCompleted() async {
        Logger.dataBrokerProtection.log("Continued processing: scan phase completed for run \(self.logRunIdentifier(), privacy: .public)")

        guard let manager,
              let hasPendingInitialOptOuts = try? manager.hasPendingContinuedProcessingOptOuts() else {
            Logger.dataBrokerProtection.log("Continued processing: failed to determine pending opt-outs after scan phase for run \(self.logRunIdentifier(), privacy: .public)")
            finish(success: false)
            return
        }

        guard hasPendingInitialOptOuts else {
            Logger.dataBrokerProtection.log("Continued processing: no initial opt-outs found after scan phase for run \(self.logRunIdentifier(), privacy: .public)")
            finish(success: true)
            return
        }

        Logger.dataBrokerProtection.log("Continued processing: initial opt-outs found for run \(self.logRunIdentifier(), privacy: .public)")
        await startOptOutPhase()
    }

    func startOptOutPhase() async {
        guard let manager else { return }
        transition(to: .initialOptOut)
        Logger.dataBrokerProtection.log("Continued processing: starting opt-out phase for run \(self.logRunIdentifier(), privacy: .public)")
        manager.startImmediateOptOutOperationsForContinuedProcessing()
    }

    func handleOptOutPhaseCompleted() {
        Logger.dataBrokerProtection.log("Continued processing: opt-out phase completed for run \(self.logRunIdentifier(), privacy: .public)")
        finish(success: true)
    }

    // MARK: - Helpers

    private func transition(to phase: Phase) {
        Logger.dataBrokerProtection.log(
            "Continued processing: transitioning run \(self.logRunIdentifier(), privacy: .public) from \(String(describing: self.phase), privacy: .public) to \(String(describing: phase), privacy: .public)"
        )
        self.phase = phase
    }

    private func elapsedDescription() -> String {
        guard let runStartedAt else { return "n/a" }

        return String(format: "%.1fs", Date().timeIntervalSince(runStartedAt))
    }

    private func makeUniqueTaskIdentifier() -> String {
        "\(requiredBundleIdentifier()).\(Constants.taskIdentifierPrefix).\(UUID().uuidString)"
    }

    private func requiredBundleIdentifier() -> String {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            fatalError("Missing bundle identifier for continued processing task registration")
        }

        return bundleIdentifier
    }

    private func logRunIdentifier() -> String {
        guard let taskIdentifier else { return "unknown" }
        return taskIdentifier.split(separator: ".").last.map(String.init) ?? taskIdentifier
    }

    @available(iOS 26.0, *)
    private func registerTaskHandler(identifier taskIdentifier: String) throws {
        Logger.dataBrokerProtection.log(
            "Continued processing: registering task handler for identifier \(taskIdentifier, privacy: .public)"
        )

        let didRegister = BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { [weak self] task in
            Logger.dataBrokerProtection.log("Continued processing: task handler invoked for identifier \(task.identifier, privacy: .public)")
            guard let continuedTask = task as? BGContinuedProcessingTask else {
                Logger.dataBrokerProtection.error("Continued processing: received non-continued task for identifier \(task.identifier, privacy: .public)")
                task.setTaskCompleted(success: true)
                return
            }

            Task { @MainActor in
                self?.attach(task: continuedTask)
            }
        }

        guard didRegister else {
            Logger.dataBrokerProtection.error(
                "Continued processing: failed to register task handler for identifier \(taskIdentifier, privacy: .public)"
            )
            throw DBPContinuedProcessingError.taskHandlerRegistrationFailed
        }

        Logger.dataBrokerProtection.log(
            "Continued processing: successfully registered task handler for identifier \(taskIdentifier, privacy: .public)"
        )
    }

    @available(iOS 26.0, *)
    private func submitTaskRequest(identifier: String) throws {
        #if targetEnvironment(simulator)
        Logger.dataBrokerProtection.log("Continued processing: skipping task request submission on simulator for identifier \(identifier, privacy: .public)")
        return
        #else
        let request = BGContinuedProcessingTaskRequest(identifier: identifier,
                                                       title: Constants.taskTitle,
                                                       subtitle: Constants.taskSubtitle)
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

}

@available(iOS 26.0, *)
extension DBPContinuedProcessingCoordinator: DBPContinuedProcessingCoordinating {}

// MARK: - DBPContinuedProcessingEventDelegate

@available(iOS 26.0, *)
extension DBPContinuedProcessingCoordinator: DBPContinuedProcessingEventDelegate {
    func iosManager(_ manager: DataBrokerProtectionIOSManager, didEmit event: DBPContinuedProcessingEvent) {
        Logger.dataBrokerProtection.log(
            "Continued processing: received manager event \(String(describing: event), privacy: .public) for run \(self.logRunIdentifier(), privacy: .public)"
        )
        switch event {
        case .scanPhaseCompleted:
            Task { @MainActor in
                await handleScanPhaseCompleted()
            }
        case .optOutPhaseCompleted:
            handleOptOutPhaseCompleted()
        }
    }
}
