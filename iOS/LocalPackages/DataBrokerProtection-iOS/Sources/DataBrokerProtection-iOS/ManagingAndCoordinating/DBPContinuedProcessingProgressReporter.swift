//
//  DBPContinuedProcessingProgressReporter.swift
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

import DataBrokerProtectionCore
import Foundation

/// Tracks the user-visible progress for a continued-processing initial run.
///
/// The model reserves a fixed 50/50 split between scans and opt-outs:
/// - the scan half is allocated up front from the initial scan summary
/// - the opt-out half is reserved at the same size and only divided once runnable opt-outs are known
///
/// Within each phase, heartbeat consumes the current phase budget one unit at a time.
/// Whole-job completion then snaps progress forward to the sum of all fully completed jobs'
/// allotted units so the reported progress stays monotonic and tied to real work.
@MainActor
final class DBPContinuedProcessingProgressReporter {

    struct ScanJobID: Hashable, Sendable {
        let brokerId: Int64
        let profileQueryId: Int64
    }

    struct OptOutJobID: Hashable, Sendable {
        let brokerId: Int64
        let profileQueryId: Int64
        let extractedProfileId: Int64
    }

    struct ScanJobSummary: Sendable {
        let id: ScanJobID
    }

    struct OptOutJobSummary: Sendable {
        let id: OptOutJobID
    }

    struct InitialScanSummary {
        let scanJobs: [ScanJobSummary]

        var scanCount: Int {
            scanJobs.count
        }
    }

    struct OptOutSummary {
        let optOutJobs: [OptOutJobSummary]

        var optOutCount: Int {
            optOutJobs.count
        }
    }

    struct Snapshot {
        let completed: Int64
        let total: Int64
    }

    private enum Phase {
        case scan
        case optOut
    }

    private enum Constants {
        static let preparingScanSubtitle = "Preparing scan"
        static let preparingOptOutSubtitle = "Continuing opt-outs for found matches"
    }

    private struct SummaryKey: Hashable {
        let brokerId: Int64
        let profileQueryId: Int64
    }

    private struct PlannedItemProgress<ID: Hashable> {
        let id: ID
        let allottedUnits: Int64
        var isCompleted: Bool
    }

    // MARK: - Phase State

    private var phase: Phase?

    // MARK: - Scan Phase Budget

    private var scanCompletedUnits: Int64 = 0
    private var scanTotalUnits: Int64 = 0

    // MARK: - Opt-Out Phase Budget

    private var optOutCompletedUnits: Int64 = 0
    private var optOutTotalUnits: Int64 = 0
    /// Reserves the second half of the progress bar before runnable opt-outs are known.
    private var reservedOptOutUnits: Int64 = 0

    // MARK: - Planned Job Allocations

    private var plannedScans: [ScanJobID: PlannedItemProgress<ScanJobID>] = [:]
    private var plannedOptOuts: [OptOutJobID: PlannedItemProgress<OptOutJobID>] = [:]

    // MARK: - Run Setup

    /// Seeds the scan half of the progress model and reserves the second half for future opt-outs.
    func startInitialRun(summary: InitialScanSummary, scanBudgetUnitsPerJob: Int64) {
        let scanBudgetUnitsPerJob = max(scanBudgetUnitsPerJob, 1)
        phase = .scan
        scanCompletedUnits = 0
        optOutCompletedUnits = 0
        plannedScans = Dictionary(uniqueKeysWithValues: summary.scanJobs.map {
            (
                $0.id,
                PlannedItemProgress(
                    id: $0.id,
                    allottedUnits: scanBudgetUnitsPerJob,
                    isCompleted: false
                )
            )
        })
        plannedOptOuts = [:]
        scanTotalUnits = max(plannedScans.values.reduce(0) { $0 + $1.allottedUnits }, scanBudgetUnitsPerJob)
        // Reserve a fixed second half up front so the total progress budget stays a 50/50 scan/opt-out split.
        reservedOptOutUnits = scanTotalUnits
        optOutTotalUnits = reservedOptOutUnits
    }

    /// Marks scans as the active phase for subsequent heartbeat and subtitle updates.
    func enterScanPhase() {
        phase = .scan
    }

    /// Allocates the reserved opt-out half across the discovered opt-out jobs.
    func enterOptOutPhase(summary: OptOutSummary) {
        phase = .optOut
        optOutTotalUnits = reservedOptOutUnits
        let allottedUnitsPerJob = distribute(totalUnits: reservedOptOutUnits, acrossItemCount: summary.optOutJobs.count)
        plannedOptOuts = Dictionary(uniqueKeysWithValues: zip(summary.optOutJobs, allottedUnitsPerJob).map { job, allottedUnits in
            (
                job.id,
                PlannedItemProgress(
                    id: job.id,
                    allottedUnits: allottedUnits,
                    isCompleted: false
                )
            )
        })
    }

    // MARK: - Progress Updates

    /// Advances the active phase by one heartbeat tick, growing total units only after a phase budget is exhausted.
    func advanceHeartbeat() {
        switch phase {
        case .scan:
            advance(completedUnits: &scanCompletedUnits, totalUnits: &scanTotalUnits)
        case .optOut:
            advance(completedUnits: &optOutCompletedUnits, totalUnits: &optOutTotalUnits)
        case .none:
            return
        }
    }

    /// Snaps the scan phase to its full allotted budget.
    func completeScanPhase() {
        plannedScans = plannedScans.mapValues { progress in
            var progress = progress
            progress.isCompleted = true
            return progress
        }
        scanCompletedUnits = max(scanCompletedUnits, scanTotalUnits)
    }

    /// Snaps the opt-out phase to its full allotted budget.
    func completeOptOutPhase() {
        plannedOptOuts = plannedOptOuts.mapValues { progress in
            var progress = progress
            progress.isCompleted = true
            return progress
        }
        optOutCompletedUnits = max(optOutCompletedUnits, optOutTotalUnits)
    }

    /// Marks both phases as complete so the overall progress reaches 100%.
    func completeAll() {
        completeScanPhase()
        completeOptOutPhase()
    }

    /// Marks a scan job complete and tops scan progress up to that job's allotted share.
    func recordCompletedScan(_ id: ScanJobID) {
        guard var progress = plannedScans[id], !progress.isCompleted else { return }
        progress.isCompleted = true
        plannedScans[id] = progress
        scanCompletedUnits = max(scanCompletedUnits, plannedScans.values.filter(\.isCompleted).reduce(0) { $0 + $1.allottedUnits })
    }

    /// Marks an opt-out job complete and tops opt-out progress up to that job's allotted share.
    func recordCompletedOptOut(_ id: OptOutJobID) {
        guard var progress = plannedOptOuts[id], !progress.isCompleted else { return }
        progress.isCompleted = true
        plannedOptOuts[id] = progress
        optOutCompletedUnits = max(optOutCompletedUnits, plannedOptOuts.values.filter(\.isCompleted).reduce(0) { $0 + $1.allottedUnits })
    }

    // MARK: - Reporting

    /// Returns the current combined progress snapshot for scans and opt-outs.
    func snapshot() -> Snapshot {
        Snapshot(completed: scanCompletedUnits + optOutCompletedUnits,
                 total: max(scanTotalUnits + optOutTotalUnits, 1))
    }

    /// Builds the scan-phase subtitle shown by the system task UI.
    var scanSubtitle: String {
        let brokerCount = uniqueScanBrokerCount
        guard brokerCount > 0 else {
            return Constants.preparingScanSubtitle
        }

        return "Scanning \(completedScanBrokerCount) of \(brokerCount) brokers"
    }

    /// Builds the opt-out-phase subtitle shown by the system task UI.
    var optOutSubtitle: String {
        let optOutCount = plannedOptOuts.count
        guard optOutCount > 0 else {
            return Constants.preparingOptOutSubtitle
        }

        return "Submitting \(optOutCount) opt-out requests"
    }

    // MARK: - Helpers

    /// Advances a phase budget by one unit, extending the budget only after it has been fully consumed.
    private func advance(completedUnits: inout Int64, totalUnits: inout Int64) {
        // Heartbeat consumes the allotted phase budget first, then grows both completed and total
        // so progress can keep moving without reaching 100% prematurely.
        if completedUnits < totalUnits {
            completedUnits += 1
        } else {
            completedUnits += 1
            totalUnits += 1
        }
    }

    /// Evenly distributes a phase budget across a fixed number of planned jobs.
    private func distribute(totalUnits: Int64, acrossItemCount itemCount: Int) -> [Int64] {
        guard itemCount > 0 else { return [] }

        let baseUnits = totalUnits / Int64(itemCount)
        let remainder = totalUnits % Int64(itemCount)

        // Spread any remainder across the first few jobs so the full phase budget is assigned.
        return (0..<itemCount).map { index in
            baseUnits + (Int64(index) < remainder ? 1 : 0)
        }
    }

    /// Counts distinct brokers represented in the planned scan set.
    private var uniqueScanBrokerCount: Int {
        Set(plannedScans.keys.map(\.brokerId)).count
    }

    /// Counts brokers whose full set of scan jobs has finished.
    private var completedScanBrokerCount: Int {
        Dictionary(grouping: plannedScans.values, by: \.id.brokerId)
            .values
            .filter { brokerJobs in brokerJobs.allSatisfy(\.isCompleted) }
            .count
    }

}

// MARK: - Summary Builders

extension DBPContinuedProcessingProgressReporter {
    /// Builds the initial scan summary used to seed the scan half of the progress model.
    static func makeInitialScanSummary(
        from brokerProfileQueryData: [BrokerProfileQueryData],
        priorityDate: Date = Date()
    ) -> InitialScanSummary {
        let eligibleJobs = BrokerProfileJob.sortedEligibleJobs(
            brokerProfileQueriesData: brokerProfileQueryData,
            jobType: .manualScan,
            priorityDate: priorityDate
        )

        let scanJobs = eligibleJobs.compactMap { $0 as? ScanJobData }
        let scanJobsSummary = scanJobs.map { job in
            return ScanJobSummary(
                id: .init(brokerId: job.brokerId, profileQueryId: job.profileQueryId)
            )
        }

        return InitialScanSummary(scanJobs: scanJobsSummary)
    }

    /// Builds the initial opt-out summary from runnable opt-outs discovered after scans complete.
    static func makeOptOutSummary(
        from brokerProfileQueryData: [BrokerProfileQueryData],
        priorityDate: Date = Date()
    ) -> OptOutSummary {
        let eligibleJobs = BrokerProfileJob.sortedEligibleJobs(
            brokerProfileQueriesData: brokerProfileQueryData,
            jobType: .optOut,
            priorityDate: priorityDate
        )

        let optOutJobs = eligibleJobs.compactMap { $0 as? OptOutJobData }
        let dataByKey: [SummaryKey: BrokerProfileQueryData] = Dictionary(uniqueKeysWithValues: brokerProfileQueryData.compactMap { queryData -> (SummaryKey, BrokerProfileQueryData)? in
            guard let brokerId = queryData.dataBroker.id,
                  let profileQueryId = queryData.profileQuery.id else { return nil }
            return (
                SummaryKey(brokerId: brokerId, profileQueryId: profileQueryId),
                queryData
            )
        })

        let optOutJobsSummary = optOutJobs.compactMap { job -> OptOutJobSummary? in
            guard let extractedProfileId = job.extractedProfile.id else { return nil }
            let key = SummaryKey(brokerId: job.brokerId, profileQueryId: job.profileQueryId)
            guard let queryData = dataByKey[key],
                  shouldIncludeInInitialOptOutProgress(job: job, queryData: queryData) else {
                return nil
            }

            return OptOutJobSummary(
                id: .init(
                    brokerId: job.brokerId,
                    profileQueryId: job.profileQueryId,
                    extractedProfileId: extractedProfileId
                )
            )
        }

        return OptOutSummary(optOutJobs: optOutJobsSummary)
    }

    /// Filters out opt-out jobs that will be skipped and should not count toward initial-run progress.
    private static func shouldIncludeInInitialOptOutProgress(
        job: OptOutJobData,
        queryData: BrokerProfileQueryData
    ) -> Bool {
        guard job.extractedProfile.removedDate == nil else {
            return false
        }

        guard !queryData.dataBroker.performsOptOutWithinParent() else {
            return false
        }

        return !job.historyEvents.doesBelongToUserRemovedRecord
    }
}
