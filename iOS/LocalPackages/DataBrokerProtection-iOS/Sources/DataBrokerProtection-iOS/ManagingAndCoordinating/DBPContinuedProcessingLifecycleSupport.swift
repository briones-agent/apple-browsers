//
//  DBPContinuedProcessingLifecycleSupport.swift
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

struct DBPContinuedProcessingScanJobID: Hashable, Sendable {
    let brokerId: Int64
    let profileQueryId: Int64
}

struct DBPContinuedProcessingOptOutJobID: Hashable, Sendable {
    let brokerId: Int64
    let profileQueryId: Int64
    let extractedProfileId: Int64
}

struct DBPContinuedProcessingScanJobSummary: Sendable {
    let id: DBPContinuedProcessingScanJobID
}

struct DBPContinuedProcessingOptOutJobSummary: Sendable {
    let id: DBPContinuedProcessingOptOutJobID
}

struct DBPContinuedProcessingInitialScanSummary {
    let scanJobs: [DBPContinuedProcessingScanJobSummary]

    var scanCount: Int {
        scanJobs.count
    }
}

struct DBPContinuedProcessingOptOutSummary {
    let optOutJobs: [DBPContinuedProcessingOptOutJobSummary]

    var optOutCount: Int {
        optOutJobs.count
    }
}

struct DBPContinuedProcessingProgressSnapshot {
    let completed: Int64
    let total: Int64
}

enum DBPContinuedProcessingSummaryBuilder {
    static func makeInitialScanSummary(
        from brokerProfileQueryData: [BrokerProfileQueryData],
        priorityDate: Date = Date()
    ) -> DBPContinuedProcessingInitialScanSummary {
        let eligibleJobs = BrokerProfileJob.sortedEligibleJobs(
            brokerProfileQueriesData: brokerProfileQueryData,
            jobType: .manualScan,
            priorityDate: priorityDate
        )

        let scanJobs = eligibleJobs.compactMap { $0 as? ScanJobData }
        return DBPContinuedProcessingInitialScanSummary(
            scanJobs: scanJobs.map { job in
                DBPContinuedProcessingScanJobSummary(
                    id: .init(brokerId: job.brokerId, profileQueryId: job.profileQueryId)
                )
            }
        )
    }

    static func makeOptOutSummary(
        from brokerProfileQueryData: [BrokerProfileQueryData],
        priorityDate: Date = Date()
    ) -> DBPContinuedProcessingOptOutSummary {
        let eligibleJobs = BrokerProfileJob.sortedEligibleJobs(
            brokerProfileQueriesData: brokerProfileQueryData,
            jobType: .optOut,
            priorityDate: priorityDate
        )

        let optOutJobs = eligibleJobs.compactMap { $0 as? OptOutJobData }
        return DBPContinuedProcessingOptOutSummary(
            optOutJobs: optOutJobs.compactMap { job in
                guard let extractedProfileId = job.extractedProfile.id else { return nil }
                return DBPContinuedProcessingOptOutJobSummary(
                    id: .init(
                        brokerId: job.brokerId,
                        profileQueryId: job.profileQueryId,
                        extractedProfileId: extractedProfileId
                    )
                )
            }
        )
    }
}

@MainActor
final class DBPContinuedProcessingLifecycleProgressState {

    private enum Phase {
        case scan
        case optOut
    }

    private enum Constants {
        static let preparingScanSubtitle = "Preparing scan"
        static let preparingOptOutSubtitle = "Preparing opt-outs"
        static let scanSubtitle = "Scanning brokers"
        static let optOutSubtitle = "Submitting opt-out requests"
    }

    private struct PlannedItemProgress<ID: Hashable> {
        let id: ID
        let allottedUnits: Int64
        var isCompleted: Bool
    }

    private var phase: Phase?
    private var scanCompletedUnits: Int64 = 0
    private var scanTotalUnits: Int64 = 0
    private var optOutCompletedUnits: Int64 = 0
    private var optOutTotalUnits: Int64 = 0
    private var reservedOptOutUnits: Int64 = 0
    private var plannedScans: [DBPContinuedProcessingScanJobID: PlannedItemProgress<DBPContinuedProcessingScanJobID>] = [:]
    private var plannedOptOuts: [DBPContinuedProcessingOptOutJobID: PlannedItemProgress<DBPContinuedProcessingOptOutJobID>] = [:]

    func startInitialRun(summary: DBPContinuedProcessingInitialScanSummary, scanBudgetUnitsPerJob: Int64) {
        let scanBudgetUnitsPerJob = max(scanBudgetUnitsPerJob, 1)
        phase = .scan
        scanCompletedUnits = 0
        optOutCompletedUnits = 0
        plannedScans = Dictionary(uniqueKeysWithValues: summary.scanJobs.map {
            (
                $0.id,
                PlannedItemProgress(id: $0.id, allottedUnits: scanBudgetUnitsPerJob, isCompleted: false)
            )
        })
        plannedOptOuts = [:]
        scanTotalUnits = max(plannedScans.values.reduce(0) { $0 + $1.allottedUnits }, scanBudgetUnitsPerJob)
        reservedOptOutUnits = scanTotalUnits
        optOutTotalUnits = reservedOptOutUnits
    }

    func enterScanPhase() {
        phase = .scan
    }

    func enterOptOutPhase(summary: DBPContinuedProcessingOptOutSummary) {
        phase = .optOut
        optOutTotalUnits = reservedOptOutUnits
        let allottedUnitsPerJob = distribute(totalUnits: reservedOptOutUnits, acrossItemCount: summary.optOutJobs.count)
        plannedOptOuts = Dictionary(uniqueKeysWithValues: zip(summary.optOutJobs, allottedUnitsPerJob).map { job, allottedUnits in
            (
                job.id,
                PlannedItemProgress(id: job.id, allottedUnits: allottedUnits, isCompleted: false)
            )
        })
    }

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

    func completeScanPhase() {
        plannedScans = plannedScans.mapValues { progress in
            var progress = progress
            progress.isCompleted = true
            return progress
        }
        scanCompletedUnits = max(scanCompletedUnits, scanTotalUnits)
    }

    func completeOptOutPhase() {
        plannedOptOuts = plannedOptOuts.mapValues { progress in
            var progress = progress
            progress.isCompleted = true
            return progress
        }
        optOutCompletedUnits = max(optOutCompletedUnits, optOutTotalUnits)
    }

    func completeAll() {
        completeScanPhase()
        completeOptOutPhase()
    }

    func recordCompletedScan(_ id: DBPContinuedProcessingScanJobID) {
        guard var progress = plannedScans[id], !progress.isCompleted else { return }
        progress.isCompleted = true
        plannedScans[id] = progress
        scanCompletedUnits = max(scanCompletedUnits, plannedScans.values.filter(\.isCompleted).reduce(0) { $0 + $1.allottedUnits })
    }

    func recordCompletedOptOut(_ id: DBPContinuedProcessingOptOutJobID) {
        guard var progress = plannedOptOuts[id], !progress.isCompleted else { return }
        progress.isCompleted = true
        plannedOptOuts[id] = progress
        optOutCompletedUnits = max(optOutCompletedUnits, plannedOptOuts.values.filter(\.isCompleted).reduce(0) { $0 + $1.allottedUnits })
    }

    func snapshot() -> DBPContinuedProcessingProgressSnapshot {
        DBPContinuedProcessingProgressSnapshot(
            completed: scanCompletedUnits + optOutCompletedUnits,
            total: max(scanTotalUnits + optOutTotalUnits, 1)
        )
    }

    var scanSubtitle: String {
        plannedScans.isEmpty ? Constants.preparingScanSubtitle : Constants.scanSubtitle
    }

    var optOutSubtitle: String {
        plannedOptOuts.isEmpty ? Constants.preparingOptOutSubtitle : Constants.optOutSubtitle
    }

    private func advance(completedUnits: inout Int64, totalUnits: inout Int64) {
        if completedUnits < totalUnits {
            completedUnits += 1
        } else {
            completedUnits += 1
            totalUnits += 1
        }
    }

    private func distribute(totalUnits: Int64, acrossItemCount itemCount: Int) -> [Int64] {
        guard itemCount > 0 else { return [] }

        let baseUnits = totalUnits / Int64(itemCount)
        let remainder = totalUnits % Int64(itemCount)

        return (0..<itemCount).map { index in
            baseUnits + (Int64(index) < remainder ? 1 : 0)
        }
    }
}
