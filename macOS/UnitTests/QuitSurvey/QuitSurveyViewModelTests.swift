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

// MARK: - Mock

final class MockHistoryCoordinating: HistoryCoordinating {

    var history: BrowsingHistory?
    var allHistoryVisits: [Visit]?
    @Published var historyDictionary: [URL: HistoryEntry]?
    var historyDictionaryPublisher: Published<[URL: HistoryEntry]?>.Publisher { $historyDictionary }
    var dataClearingPixelsHandling: DataClearingPixelsHandling?

    func loadHistory(onCleanFinished: @escaping () -> Void) {}

    @discardableResult
    func addVisit(of url: URL, at date: Date, tabID: String?) -> Visit? { nil }

    func addBlockedTracker(entityName: String, on url: URL) {}
    func trackerFound(on url: URL) {}
    func cookiePopupBlocked(on url: URL) {}
    func updateTitleIfNeeded(title: String, url: URL) {}
    func markFailedToLoadUrl(_ url: URL) {}
    func commitChanges(url: URL) {}
    func title(for url: URL) -> String? { nil }
    func burnAll(completion: @escaping @MainActor () -> Void) { completion() }
    func burnDomains(_ baseDomains: Set<String>, tld: TLD, completion: @escaping @MainActor (Set<URL>) -> Void) { completion([]) }
    func burnVisits(_ visits: [Visit], completion: @escaping @MainActor () -> Void) { completion() }
    func burnVisits(for tabID: String) async throws {}
    func resetCookiePopupBlocked(for domains: Set<String>, tld: TLD, completion: @escaping @MainActor () -> Void) { completion() }
    func removeUrlEntry(_ url: URL, completion: (@MainActor (Error?) -> Void)?) { completion?(nil) }
}

// MARK: - Tests

@MainActor
final class QuitSurveyViewModelTests: XCTestCase {

    func testRecentDomainsReturnsLast5UniqueHostsSortedByMostRecent() {
        let now = Date()
        let historyCoordinating = MockHistoryCoordinating()
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
            historyCoordinating: historyCoordinating,
            onQuit: {}
        )

        XCTAssertEqual(viewModel.recentDomains, ["a.com", "b.com", "c.com", "d.com", "e.com"])
    }

    func testRecentDomainsIsEmptyWhenNoHistory() {
        let viewModel = QuitSurveyViewModel(
            persistor: nil,
            historyCoordinating: nil,
            onQuit: {}
        )

        XCTAssertTrue(viewModel.recentDomains.isEmpty)
    }

    func testToggleDomainAddsAndRemovesDomain() {
        let viewModel = QuitSurveyViewModel(
            persistor: nil,
            historyCoordinating: nil,
            onQuit: {}
        )

        viewModel.toggleDomain("example.com")
        XCTAssertTrue(viewModel.selectedDomains.contains("example.com"))

        viewModel.toggleDomain("example.com")
        XCTAssertFalse(viewModel.selectedDomains.contains("example.com"))
    }

    func testShouldShowDomainSelectorWhenWebsitesPillSelectedAndHistoryNonEmpty() {
        let historyCoordinating = MockHistoryCoordinating()
        historyCoordinating.history = [
            makeEntry(host: "example.com", lastVisit: Date()),
        ]

        let viewModel = QuitSurveyViewModel(
            persistor: nil,
            historyCoordinating: historyCoordinating,
            onQuit: {}
        )

        XCTAssertFalse(viewModel.shouldShowDomainSelector)

        viewModel.toggleOption("websites-didnt-work")
        XCTAssertTrue(viewModel.shouldShowDomainSelector)
    }

    func testGoBackFromDomainSelectionReturnsToNegativeFeedbackAndClearsDomains() {
        let historyCoordinating = MockHistoryCoordinating()
        historyCoordinating.history = [
            makeEntry(host: "example.com", lastVisit: Date()),
        ]

        let viewModel = QuitSurveyViewModel(
            persistor: nil,
            historyCoordinating: historyCoordinating,
            onQuit: {}
        )

        viewModel.selectNegativeResponse()
        viewModel.proceedToDomainSelection()
        viewModel.toggleDomain("example.com")

        XCTAssertEqual(viewModel.state, .domainSelection)
        XCTAssertFalse(viewModel.selectedDomains.isEmpty)

        viewModel.goBackFromDomainSelection()

        XCTAssertEqual(viewModel.state, .negativeFeedback)
        XCTAssertTrue(viewModel.selectedDomains.isEmpty)
    }
}
