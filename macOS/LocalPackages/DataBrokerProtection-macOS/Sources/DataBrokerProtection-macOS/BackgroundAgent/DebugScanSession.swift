//
//  DebugScanSession.swift
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

import Foundation
import DataBrokerProtectionCore
import os.log

// MARK: - Debug Scan Session

/// Holds mutable state for an active debug scan/optout session.
/// Updated by the stage calculator callbacks and read by get_webview_state.
public final class DebugScanSession {

    /// In-memory email confirmation store for debug scans (mirrors DebugEmailConfirmationStore in debug VM).
    let debugEmailConfirmationStore = DebugEmailConfirmationStore()

    // MARK: - Live State

    struct State {
        var isRunning: Bool = false
        var currentStep: String = "idle"
        var currentAction: String?
        var lastError: String?
        var debugEvents: [(date: Date, kind: String, action: String?, details: String)] = []

        // Last scan results for feeding into run_optout
        var lastBroker: DataBroker?
        var lastProfileQuery: ProfileQuery?
        var lastExtractedProfiles: [ExtractedProfile] = []
    }

    private let lock = NSLock()
    private var _state = State()

    var state: State {
        lock.lock()
        defer { lock.unlock() }
        return _state
    }

    func updateState(_ block: (inout State) -> Void) {
        lock.lock()
        block(&_state)
        lock.unlock()
    }

    // MARK: - Serialization

    func serializeState() -> Data? {
        let s = state
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var result: [String: Any] = [
            "isRunning": s.isRunning,
            "currentStep": s.currentStep,
        ]

        if let action = s.currentAction {
            result["currentAction"] = action
        }
        if let error = s.lastError {
            result["lastError"] = error
        }

        let recentEvents = s.debugEvents.suffix(20).map { event -> [String: Any] in
            var dict: [String: Any] = [
                "date": formatter.string(from: event.date),
                "kind": event.kind,
                "details": event.details,
            ]
            if let action = event.action {
                dict["action"] = action
            }
            return dict
        }
        result["recentEvents"] = recentEvents
        result["extractedProfileCount"] = s.lastExtractedProfiles.count

        return try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    }

    // MARK: - Stage Duration Calculator

    func makeStageCalculator() -> DebugSessionStageDurationCalculator {
        DebugSessionStageDurationCalculator(session: self)
    }
}

// MARK: - Stage Duration Calculator (no-op + event recording)

final class DebugSessionStageDurationCalculator: StageDurationCalculator, DebugEventReporting {
    var attemptId = UUID()
    var isImmediateOperation: Bool = false
    var isFreeScan: Bool?
    var tries = 1

    private weak var session: DebugScanSession?

    init(session: DebugScanSession) {
        self.session = session
    }

    func durationSinceLastStage() -> Double { 0.0 }
    func durationSinceStartTime() -> Double { 0.0 }
    func fireOptOutStart() {}
    func setEmailPattern(_ emailPattern: String?) {}
    func fireOptOutEmailGenerate() {}
    func fireOptOutCaptchaParse() {}
    func fireOptOutCaptchaSend() {}
    func fireOptOutCaptchaSolve() {}
    func fireOptOutSubmit() {}
    func fireOptOutFillForm() {}
    func fireOptOutEmailReceive() {}
    func fireOptOutEmailConfirm() {}
    func fireOptOutValidate() {}
    func fireOptOutSubmitSuccess(tries: Int) {}
    func fireOptOutFailure(tries: Int, error: Error) {}
    func fireScanSuccess(matchesFound: Int) {}
    func fireScanNoResults() {}
    func fireScanError(error: Error) {}
    func setStage(_ stage: Stage) {}
    func setLastAction(_ action: Action) {
        session?.updateState { state in
            state.currentAction = action.actionType.rawValue
        }
    }
    func fireOptOutConditionFound() {}
    func fireOptOutConditionNotFound() {}
    func resetTries() { tries = 1 }
    func incrementTries() { tries += 1 }

    func recordDebugEvent(kind: DebugEventKind, actionType: ActionType?, details: String) {
        session?.updateState { state in
            state.currentAction = actionType?.rawValue
            state.debugEvents.append((
                date: Date(),
                kind: kind.rawValue,
                action: actionType?.rawValue,
                details: details
            ))
        }
    }
}
