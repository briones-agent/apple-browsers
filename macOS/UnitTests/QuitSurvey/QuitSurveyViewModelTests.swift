//
//  QuitSurveyViewModelTests.swift
//
//  Copyright © 2025 DuckDuckGo. All rights reserved.
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

import History
import XCTest
import PrivacyConfig

@testable import DuckDuckGo_Privacy_Browser

// MARK: - Helpers

private func makeEntry(host: String, lastVisit: Date) -> HistoryEntry {
    HistoryEntry(
        identifier: UUID(),
        url: URL(string: "https://\(host)/")!,
        title: nil,
        failedToLoad: false,
        numberOfTotalVisits: 1,
        lastVisit: lastVisit,
        visits: [],
        numberOfTrackersBlocked: 0,
        blockedTrackingEntities: [],
        trackersFound: false,
        cookiePopupBlocked: false
    )
}

// MARK: - Tests

@MainActor
final class QuitSurveyViewModelTests: XCTestCase {

    func testRecentDomainsReturnsLast5UniqueHostsSortedByMostRecent() {
        let now = Date()
        let historyCoordinating = HistoryCoordinatingMock()
        historyCoordinating.history = [
            makeEntry(host: "a.com", lastVisit: now.addingTimeInterval(-1)),
            makeEntry(host: "b.com", lastVisit: now.addingTimeInterval(-2)),
            makeEntry(host: "c.com", lastVisit: now.addingTimeInterval(-3)),
            makeEntry(host: "d.com", lastVisit: now.addingTimeInterval(-4)),
            makeEntry(host: "e.com", lastVisit: now.addingTimeInterval(-5)),
            makeEntry(host: "f.com", lastVisit: now.addingTimeInterval(-6)),
            makeEntry(host: "a.com", lastVisit: now.addingTimeInterval(-7)), // duplicate
        ]

        let viewModel = QuitSurveyViewModel(
            persistor: nil,
            featureFlagger: MockFeatureFlagger(),
            historyCoordinating: historyCoordinating,
            onQuit: {}
        )

        XCTAssertEqual(viewModel.recentDomains.map(\.domain), ["a.com", "b.com", "c.com", "d.com", "e.com"])
    }

    func testRecentDomainsIsEmptyWhenNoHistory() {
        let viewModel = QuitSurveyViewModel(
            persistor: nil,
            featureFlagger: MockFeatureFlagger(),
            historyCoordinating: nil,
            onQuit: {}
        )

        XCTAssertTrue(viewModel.recentDomains.isEmpty)
    }

    func testToggleDomainAddsAndRemovesDomain() {
        let viewModel = QuitSurveyViewModel(
            persistor: nil,
            featureFlagger: MockFeatureFlagger(),
            historyCoordinating: nil,
            onQuit: {}
        )

        viewModel.toggleDomain("example.com")
        XCTAssertTrue(viewModel.selectedDomains.contains("example.com"))

        viewModel.toggleDomain("example.com")
        XCTAssertFalse(viewModel.selectedDomains.contains("example.com"))
    }

    func testShouldShowDomainSelectorWhenWebsitesPillSelectedAndHistoryNonEmpty() {
        let historyCoordinating = HistoryCoordinatingMock()
        historyCoordinating.history = [
            makeEntry(host: "example.com", lastVisit: Date()),
        ]
        let featureFlagger = MockFeatureFlagger()
        featureFlagger.enabledFeatureFlags = [.websitesHistoryFirstTimeQuitSurvey]

        let viewModel = QuitSurveyViewModel(
            persistor: nil,
            featureFlagger: featureFlagger,
            historyCoordinating: historyCoordinating,
            onQuit: {}
        )

        XCTAssertFalse(viewModel.shouldShowDomainSelector)

        viewModel.toggleOption("websites-didnt-work")
        XCTAssertTrue(viewModel.shouldShowDomainSelector)
    }

    func testShouldNotShowDomainSelectorWhenFeatureFlagIsOff() {
        let historyCoordinating = HistoryCoordinatingMock()
        historyCoordinating.history = [
            makeEntry(host: "example.com", lastVisit: Date()),
        ]

        let viewModel = QuitSurveyViewModel(
            persistor: nil,
            featureFlagger: MockFeatureFlagger(),
            historyCoordinating: historyCoordinating,
            onQuit: {}
        )

        viewModel.toggleOption("websites-didnt-work")
        XCTAssertFalse(viewModel.shouldShowDomainSelector)
    }

    func testSubmitFeedbackIncludesDomainsInFeedbackText() {
        let historyCoordinating = HistoryCoordinatingMock()
        historyCoordinating.history = [
            makeEntry(host: "a.com", lastVisit: Date()),
        ]
        let sender = MockFeedbackSender()
        let vm = QuitSurveyViewModel(feedbackSender: sender, featureFlagger: MockFeatureFlagger(), historyCoordinating: historyCoordinating, onQuit: {})
        vm.selectNegativeResponse()
        vm.toggleOption("websites-didnt-work")
        vm.toggleDomain("a.com")
        vm.submitFeedback()
        XCTAssertTrue(sender.lastFeedback?.comment.contains("a.com") == true)
    }
}
