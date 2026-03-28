//
//  ResourceLoadTracker.swift
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

import Combine
import Foundation

/// Tracks resource load state to detect stalled resources — those that sent a request
/// but never received a response within a timeout period.
///
/// A resource is considered "stalled" when it has been waiting for a response longer than
/// `stalledTimeout`. This distinguishes truly stalled connections (e.g. DNS sinkholes)
/// from slow-but-progressing downloads that have received headers and are transferring data.
final class ResourceLoadTracker {

    static let stalledTimeout: TimeInterval = 10

    // MARK: - Resource State

    private enum ResourceState {
        case requestSent(Date)
        case responseReceived
    }

    private var resources = [URL: [ResourceState]]()
    private var stalledCheckTimer: Timer?
    private let allResourcesStalledSubject = PassthroughSubject<Void, Never>()
    private let stalledStateSubject = CurrentValueSubject<Bool, Never>(false)

    var allResourcesStalledPublisher: AnyPublisher<Void, Never> {
        allResourcesStalledSubject.eraseToAnyPublisher()
    }

    var stalledStatePublisher: AnyPublisher<Bool, Never> {
        stalledStateSubject.removeDuplicates().eraseToAnyPublisher()
    }

    /// True when there are pending resources and all of them are stalled (no response received).
    var hasOnlyStalledResources: Bool {
        let pendingResources = resources.values
            .flatMap { $0 }
            .compactMap { state -> Date? in
                if case .requestSent(let sentDate) = state { return sentDate }
                return nil
            }
        guard !pendingResources.isEmpty else { return false }

        let now = Date()
        return pendingResources.allSatisfy { sentDate in
            now.timeIntervalSince(sentDate) >= Self.stalledTimeout
        }
    }

    // MARK: - Tracking

    func didSendRequest(for url: URL) {
        resources[url, default: []].append(.requestSent(Date()))
        updateStalledState()
        scheduleStalledCheckIfNeeded()
    }

    func didReceiveResponse(for url: URL) {
        guard var resourceStates = resources[url],
              let pendingIndex = resourceStates.firstIndex(where: { state in
                  if case .requestSent = state { return true }
                  return false
              }) else {
            return
        }

        resourceStates[pendingIndex] = .responseReceived
        resources[url] = resourceStates
        updateStalledState()
    }

    func didComplete(for url: URL, hadResponse: Bool) {
        guard var resourceStates = resources[url], !resourceStates.isEmpty else {
            resources.removeValue(forKey: url)
            updateStalledState()
            return
        }

        if hadResponse,
           let responseIndex = resourceStates.firstIndex(where: { state in
               if case .responseReceived = state { return true }
               return false
           }) {
            resourceStates.remove(at: responseIndex)
        } else if let pendingIndex = resourceStates.firstIndex(where: { state in
            if case .requestSent = state { return true }
            return false
        }) {
            resourceStates.remove(at: pendingIndex)
        } else {
            resourceStates.removeFirst()
        }

        if resourceStates.isEmpty {
            resources.removeValue(forKey: url)
        } else {
            resources[url] = resourceStates
        }
        updateStalledState()
    }

    func reset() {
        resources.removeAll()
        stalledCheckTimer?.invalidate()
        stalledCheckTimer = nil
        stalledStateSubject.send(false)
    }

    // MARK: - Stalled Detection

    private func scheduleStalledCheckIfNeeded() {
        guard stalledCheckTimer == nil else { return }

        stalledCheckTimer = Timer.scheduledTimer(
            withTimeInterval: Self.stalledTimeout,
            repeats: false
        ) { [weak self] _ in
            self?.checkForStalledResources()
        }
    }

    private func checkForStalledResources() {
        stalledCheckTimer = nil

        if hasOnlyStalledResources {
            stalledStateSubject.send(true)
            allResourcesStalledSubject.send()
        } else {
            stalledStateSubject.send(false)
            // Some resources are still progressing or new ones arrived — check again later
            let hasPendingRequests = resources.values
                .flatMap { $0 }
                .contains { state in
                if case .requestSent = state { return true }
                return false
            }
            if hasPendingRequests {
                scheduleStalledCheckIfNeeded()
            }
        }
    }

    private func updateStalledState() {
        stalledStateSubject.send(hasOnlyStalledResources)
    }
}
