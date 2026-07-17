//
//  WakeConnectivityMonitor.swift
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
import Network
import os.log

/// The outcome of a post-wake connectivity confirmation: did VPN connectivity come back after the device woke?
public enum WakeConnectivityResult: Equatable {
    case restored
    case notRestored(reason: Reason)

    /// Why connectivity couldn't be confirmed. `handshakeStale` is the weakest signal: WireGuard handshakes on
    /// demand, so a healthy tunnel after a short sleep can still carry an old handshake.
    public enum Reason: String, Equatable {
        /// The connection tester failed to start after wake, so it never produced a verdict.
        case testerNotRunning = "tester_not_running"
        /// The connection tester started and reported the VPN down, and didn't recover within the window.
        case testerFailed = "tester_failed"
        /// No positive confirmation available and the most recent handshake predates the wake.
        case handshakeStale = "handshake_stale"
        /// The device had no usable non-VPN network at evaluation — connectivity can't be blamed on the VPN.
        case networkDown = "network_down"
    }
}

@MainActor
protocol WakeConnectivityMonitoring: AnyObject {
    /// Opens a confirmation window for a wake that's being handled. Replaces any window already in flight.
    func noteWake()
    /// Feeds the monitor a connection test result; ignored unless a wake window is open.
    func recordConnectionTestResult(_ result: ConnectionTestingResult)
    /// Signals that the post-wake monitor start threw, so the tester won't produce a verdict this window.
    func noteMonitorStartFailed()
    /// Cancels any open window (e.g. the device is going back to sleep).
    func cancel()
}

/// Confirms whether VPN connectivity returned after a wake and emits a single `WakeConnectivityResult`.
///
/// Owned by `PacketTunnelProvider` (not `TunnelMonitors`): the monitor lifecycle inside `TunnelMonitors.start/stop`
/// runs *after* `noteWake()` and would otherwise cancel the window we just opened.
@MainActor
final class WakeConnectivityMonitor: WakeConnectivityMonitoring {

    private let handshakeReporter: HandshakeReporting
    private let now: () -> Date
    private let confirmationWindow: TimeInterval
    private let onResult: (WakeConnectivityResult) -> Void

    /// Optional network-availability override for testing; when nil the internal `NWPathMonitor` is used.
    private let networkAvailabilityOverride: (() -> Bool)?
    private let pathMonitor: NWPathMonitor?

    /// Wake time (epoch seconds) for the open window, or nil when no window is open.
    private var wakeTime: TimeInterval?
    private var confirmationTask: Task<Void, Never>?
    private var resolved = false
    private var testerStartFailed = false
    private var sawDisconnected = false

    /// Incremented on every `noteWake()`. The confirmation task captures its value so a stale, in-flight
    /// `evaluate()` (past its sleep, awaiting the handshake) can't resolve a newer window.
    private var generation = 0

    init(handshakeReporter: HandshakeReporting,
         now: @escaping () -> Date = { Date() },
         confirmationWindow: TimeInterval = 30,
         networkAvailability: (() -> Bool)? = nil,
         onResult: @escaping (WakeConnectivityResult) -> Void) {
        self.handshakeReporter = handshakeReporter
        self.now = now
        self.confirmationWindow = confirmationWindow
        self.onResult = onResult
        self.networkAvailabilityOverride = networkAvailability

        if networkAvailability == nil {
            let monitor = NWPathMonitor()
            monitor.start(queue: .global())
            self.pathMonitor = monitor
        } else {
            self.pathMonitor = nil
        }

        Logger.networkProtectionMemory.debug("[+] \(String(describing: self), privacy: .public)")
    }

    deinit {
        confirmationTask?.cancel()
        pathMonitor?.cancel()
        Logger.networkProtectionMemory.debug("[-] \(String(describing: self), privacy: .public)")
    }

    // MARK: - WakeConnectivityMonitoring

    func noteWake() {
        confirmationTask?.cancel()

        generation &+= 1
        let windowGeneration = generation
        wakeTime = now().timeIntervalSince1970
        resolved = false
        testerStartFailed = false
        sawDisconnected = false

        Logger.networkProtectionSleep.log("⚪️ Opening wake connectivity confirmation window")

        let nanoseconds = UInt64(confirmationWindow * 1_000_000_000)
        confirmationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            await self?.evaluate(windowGeneration: windowGeneration)
        }
    }

    func recordConnectionTestResult(_ result: ConnectionTestingResult) {
        guard wakeTime != nil, !resolved else { return }

        switch result {
        case .connected, .reconnected:
            // The tester confirmed traffic is flowing through the tunnel — connectivity is back.
            resolve(.restored)
        case .disconnected:
            // Keep waiting; the tunnel may recover before the window closes.
            sawDisconnected = true
        }
    }

    func noteMonitorStartFailed() {
        guard wakeTime != nil, !resolved else { return }
        testerStartFailed = true
    }

    func cancel() {
        confirmationTask?.cancel()
        confirmationTask = nil
        // Block any late resolution from an in-flight evaluate() and close the window.
        resolved = true
        wakeTime = nil
    }

    // MARK: - Evaluation

    private func evaluate(windowGeneration: Int) async {
        guard windowGeneration == generation, let wakeTime, !resolved else { return }

        // Fallback confirmation: a handshake newer than the wake means the tunnel is passing traffic even if the
        // tester never gave us a verdict.
        let mostRecentHandshake = (try? await handshakeReporter.getMostRecentHandshake()) ?? 0

        // A tester result may have resolved us — or a newer wake may have opened — while we awaited the handshake.
        guard windowGeneration == generation, !resolved else { return }

        if mostRecentHandshake > wakeTime {
            resolve(.restored)
            return
        }

        let reason: WakeConnectivityResult.Reason
        if !isNetworkAvailable {
            reason = .networkDown
        } else if testerStartFailed {
            reason = .testerNotRunning
        } else if sawDisconnected {
            reason = .testerFailed
        } else {
            reason = .handshakeStale
        }

        resolve(.notRestored(reason: reason))
    }

    private func resolve(_ result: WakeConnectivityResult) {
        guard !resolved else { return }
        resolved = true
        confirmationTask?.cancel()
        confirmationTask = nil

        Logger.networkProtectionSleep.log("⚪️ Wake connectivity result: \(String(describing: result), privacy: .public)")
        onResult(result)
    }

    private var isNetworkAvailable: Bool {
        if let networkAvailabilityOverride {
            return networkAvailabilityOverride()
        }

        guard let pathMonitor else { return true }
        let path = pathMonitor.currentPath
        let connectionType = NetworkConnectionType(nwPath: path)
        return [.wifi, .eth, .cellular].contains(connectionType) && path.status == .satisfied
    }
}
