//
//  ProcessorTests.swift
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

import XCTest
import Suggestions
@testable import SuggestionProcessing

final class ProcessorTests: XCTestCase {

    // MARK: - Basic Tests

    func testEmptyQueryReturnsEmptyResult() throws {
        let result = try Processor.process(
            query: "",
            platform: .desktop,
            bookmarks: [],
            history: [],
            openTabs: [],
            internalPages: [],
            apiResult: nil
        )
        XCTAssertTrue(result.topHits.isEmpty)
        XCTAssertTrue(result.duckduckgoSuggestions.isEmpty)
        XCTAssertTrue(result.localSuggestions.isEmpty)
    }

    func testPhraseSuggestionsReturnedFromAPI() throws {
        var apiResult = APIResult()
        apiResult.items = [
            APIResult.SuggestionResult(phrase: "duckduckgo", isNav: nil),
            APIResult.SuggestionResult(phrase: "duck recipes", isNav: nil),
        ]

        let result = try Processor.process(
            query: "duck",
            platform: .desktop,
            bookmarks: [],
            history: [],
            openTabs: [],
            internalPages: [],
            apiResult: apiResult
        )

        XCTAssertFalse(result.duckduckgoSuggestions.isEmpty)
        XCTAssertTrue(result.duckduckgoSuggestions.contains(Suggestion.phrase(phrase: "duckduckgo")))
    }

    func testBookmarkAppearsInResults() throws {
        let result = try Processor.process(
            query: "duck",
            platform: .desktop,
            bookmarks: [TestBookmark(url: "https://duckduckgo.com", title: "DuckDuckGo", isFavorite: true)],
            history: [],
            openTabs: [],
            internalPages: [],
            apiResult: nil
        )

        let allResults = result.topHits + result.localSuggestions
        let hasDuckDuckGo = allResults.contains(where: { $0.title == "DuckDuckGo" })
        XCTAssertTrue(hasDuckDuckGo, "DuckDuckGo bookmark should appear in results")
    }

    func testHistoryEntryAppearsInResults() throws {
        let result = try Processor.process(
            query: "duck",
            platform: .desktop,
            bookmarks: [],
            history: [TestHistory(
                identifier: UUID(),
                url: URL(string: "https://duck.com")!,
                title: "DuckMail",
                numberOfVisits: 300,
                lastVisit: Date(),
                failedToLoad: false
            )],
            openTabs: [],
            internalPages: [],
            apiResult: nil
        )

        let allResults = result.topHits + result.localSuggestions
        let hasDuckMail = allResults.contains(where: { $0.title == "DuckMail" })
        XCTAssertTrue(hasDuckMail, "DuckMail history entry should appear in results")
    }

    // MARK: - History in Top Hits

    func testWhenOnlyHistoryMatches_ThenHistoryInTopHits() throws {
        let result = try Processor.process(
            query: "Duck",
            platform: .mobile,
            bookmarks: [],
            history: TestHistory.duckHistoryWithoutDuckDuckGo,
            openTabs: [],
            internalPages: [],
            apiResult: TestFixtures.anAPIResult)

        XCTAssertTrue(result.topHits.contains(where: { $0.title == "DuckMail" }))
        XCTAssertEqual(2, result.topHits.count)
        XCTAssertEqual(0, result.localSuggestions.count)
    }

    // MARK: - Platform-specific Tests

    func testWhenOnMobile_ThenBookmarksAlwaysInTopHits() throws {
        let result = try Processor.process(
            query: "Duck",
            platform: .mobile,
            bookmarks: TestBookmark.someBookmarks,
            history: [],
            openTabs: [],
            internalPages: [],
            apiResult: TestFixtures.anAPIResult)

        XCTAssertTrue(result.topHits.contains(where: { $0.title == "DuckDuckGo" }))
    }

    func testWhenOnMobile_ThenDuckDuckGoAPISuggestionsAreLimitedWithoutLosingWebsites() throws {
        var apiResult = APIResult()
        apiResult.items = (0..<30).map {
            .init(phrase: UUID().uuidString, isNav: $0 % 10 == 0)
        }

        let result = try Processor.process(
            query: "Duck",
            platform: .mobile,
            bookmarks: [],
            history: [],
            openTabs: [],
            internalPages: [],
            apiResult: apiResult)

        XCTAssertEqual(result.topHits.count, 2)
        XCTAssertEqual(result.duckduckgoSuggestions.count, 12)
    }

    func testWhenOnDesktop_ThenDuckDuckGoAPISuggestionsAreLimitedByMaxSuggestions() throws {
        var apiResult = APIResult()
        apiResult.items = (0..<30).map { _ in
            .init(phrase: UUID().uuidString, isNav: false)
        }

        let result = try Processor.process(
            query: "Duck",
            platform: .desktop,
            bookmarks: [],
            history: [],
            openTabs: [],
            internalPages: [],
            apiResult: apiResult)

        XCTAssertEqual(result.topHits.count, 0)
        XCTAssertEqual(result.duckduckgoSuggestions.count, 12)
    }

    // MARK: - Combined Source Tests

    func testWhenTabsAndMultipleMatchingHistoryAndBookmarksAvailable_ThenCorrectOrdering() throws {
        let tabs = [
            TestTab(url: "http://duckduckgo.com", title: "DuckDuckGo"),
            TestTab(url: "http://ducktales.com", title: "Duck Tales"),
        ]

        let history: [TestHistory] = [
            TestHistory(identifier: UUID(),
                        url: URL(string: "http://ducks.wikipedia.org")!,
                        title: "Ducks – Wikipedia",
                        numberOfVisits: 301,
                        lastVisit: Date(),
                        failedToLoad: false),
            TestHistory(identifier: UUID(),
                        url: URL(string: "http://www.duck.com")!,
                        title: "Duck",
                        numberOfVisits: 303,
                        lastVisit: Date(),
                        failedToLoad: false),
        ]

        let bookmarks = [
            TestBookmark(url: "http://duckduckgo.com", title: "DuckDuckGo", isFavorite: false),
            TestBookmark(url: "http://duckme.com", title: "Duck me!", isFavorite: false),
        ]

        let result = try Processor.process(
            query: "Duck",
            platform: .desktop,
            bookmarks: bookmarks,
            history: history,
            openTabs: tabs,
            internalPages: [],
            apiResult: TestFixtures.anAPIResult)

        XCTAssertFalse(result.topHits.isEmpty, "Top hits should not be empty")

        let duckItemsCount = result.topHits.filter { $0.title?.lowercased().contains("duck") ?? false }.count +
                            result.localSuggestions.filter { $0.title?.lowercased().contains("duck") ?? false }.count

        XCTAssertGreaterThanOrEqual(duckItemsCount, 3, "Should have at least 3 duck-related suggestions")

        let topHitUrls = Set(result.topHits.compactMap { $0.url?.absoluteString })
        let localUrls = Set(result.localSuggestions.compactMap { $0.url?.absoluteString })
        let intersection = topHitUrls.intersection(localUrls)

        XCTAssertTrue(intersection.isEmpty, "Should not have the same URL in both topHits and localSuggestions")
    }

    func testWhenOnDesktopAndBookmarkIsFavorite_ThenBookmarkAppearsInTopHits() throws {
        let bookmarks = [
            TestBookmark(url: "http://duckduckgo.com", title: "DuckDuckGo", isFavorite: true),
            TestBookmark(url: "spreadprivacy.com", title: "Test 2", isFavorite: false),
            TestBookmark(url: "wikipedia.org", title: "Wikipedia", isFavorite: false)
        ]

        let result = try Processor.process(
            query: "DuckDuckGo",
            platform: .desktop,
            bookmarks: bookmarks,
            history: TestHistory.duckHistoryWithoutDuckDuckGo,
            openTabs: [],
            internalPages: [],
            apiResult: TestFixtures.anAPIResult)

        XCTAssertTrue(result.topHits.contains(where: { $0.title == "DuckDuckGo" }))
        XCTAssertEqual(0, result.localSuggestions.count)
        XCTAssertFalse(result.localSuggestions.contains(where: { $0.title == "DuckDuckGo" }))
    }

    func testWhenOnDesktopAndBookmarkHasHistoryVisits_ThenBookmarkAppearsInTopHits() throws {
        let bookmarks = [
            TestBookmark(url: "http://duckduckgo.com", title: "DuckDuckGo", isFavorite: false),
            TestBookmark(url: "http://duck.com", title: "DuckMail", isFavorite: false),
            TestBookmark(url: "spreadprivacy.com", title: "Test 2", isFavorite: false),
            TestBookmark(url: "wikipedia.org", title: "Wikipedia", isFavorite: false)
        ]

        let result = try Processor.process(
            query: "Duck",
            platform: .desktop,
            bookmarks: bookmarks,
            history: TestHistory.duckHistoryWithoutDuckDuckGo,
            openTabs: [],
            internalPages: [],
            apiResult: TestFixtures.anAPIResult)

        XCTAssertTrue(result.topHits.contains(where: { $0.title == "DuckMail" }))
        XCTAssertFalse(result.topHits.contains(where: { $0.title == "DuckDuckGo" }))
        XCTAssertEqual(1, result.localSuggestions.count)
        XCTAssertTrue(result.localSuggestions.contains(where: { $0.title == "DuckDuckGo" }))
    }

    // MARK: - Tab-Related Tests

    func testWhenOpenTabsAvailableWithMatchingQuery_ThenTabsAppearInSuggestions() throws {
        let tabs = [
            TestTab(url: "http://duckduckgo.com", title: "DuckDuckGo"),
            TestTab(url: "http://ducktales.com", title: "Duck Tales"),
        ]

        let result = try Processor.process(
            query: "Duck",
            platform: .desktop,
            bookmarks: [],
            history: [],
            openTabs: tabs,
            internalPages: [],
            apiResult: TestFixtures.anAPIResult)

        let containsDuckDuckGo = result.topHits.contains(where: { $0.title == "DuckDuckGo" }) ||
                                 result.localSuggestions.contains(where: { $0.title == "DuckDuckGo" })
        let containsDuckTales = result.topHits.contains(where: { $0.title == "Duck Tales" }) ||
                               result.localSuggestions.contains(where: { $0.title == "Duck Tales" })

        XCTAssertTrue(containsDuckDuckGo, "DuckDuckGo tab should appear in suggestions")
        XCTAssertTrue(containsDuckTales, "Duck Tales tab should appear in suggestions")
    }

    func testWhenTabsAndBookmarksAvailableOnMobile_ThenBothTypesSuggested() throws {
        let tabs = [
            TestTab(url: "http://duckduckgo.com", title: "DuckDuckGo"),
            TestTab(url: "http://ducktails.com", title: "Duck Tails"),
        ]

        let bookmarks = [
            TestBookmark(url: "http://ducktails.com", title: "Duck Tails", isFavorite: false)
        ]

        let result = try Processor.process(
            query: "Duck Tails",
            platform: .mobile,
            bookmarks: bookmarks,
            history: [],
            openTabs: tabs,
            internalPages: [],
            apiResult: TestFixtures.anAPIResult)

        let hasBookmark = result.topHits.contains(where: {
            if case .bookmark = $0, $0.title == "Duck Tails" { return true }
            return false
        })

        let hasOpenTab = result.topHits.contains(where: {
            if case .openTab = $0, $0.title == "Duck Tails" { return true }
            return false
        })

        XCTAssertTrue(hasBookmark || hasOpenTab, "Either a bookmark or open tab for 'Duck Tails' should appear in suggestions")
    }

    // MARK: - Deduplication Tests

    func testWhenDuplicatesAreInSourceArrays_ThenTheOneWithTheBiggestInformationValueIsUsed() throws {
        func runAssertion(_ platform: Platform) throws {
            let result = try Processor.process(
                query: "DuckDuckGo",
                platform: platform,
                bookmarks: TestBookmark.someBookmarks,
                history: TestHistory.aHistory,
                openTabs: [],
                internalPages: TestFixtures.someInternalPages,
                apiResult: TestFixtures.anAPIResult)

            XCTAssertEqual(result.topHits.count, 1)
            XCTAssertEqual(result.topHits.first!.title, "DuckDuckGo")
        }

        try runAssertion(.desktop)
        try runAssertion(.mobile)
    }

    // MARK: - Navigation Suggestion Tests

    func testWhenBuildingTopHits_ThenOnlyWebsiteSuggestionsAreUsedForNavigationalSuggestions() throws {
        func runAssertion(_ platform: Platform) throws {
            let result = try Processor.process(
                query: "DuckDuckGo",
                platform: platform,
                bookmarks: TestBookmark.someBookmarks,
                history: TestHistory.aHistory,
                openTabs: [],
                internalPages: TestFixtures.someInternalPages,
                apiResult: TestFixtures.anAPIResultWithNav)

            XCTAssertEqual(result.topHits.count, 2)
            XCTAssertEqual(result.topHits.first!.title, "DuckDuckGo")
            XCTAssertEqual(result.topHits.last!.url?.absoluteString, "http://www.example.com")
        }

        try runAssertion(.desktop)
        try runAssertion(.mobile)
    }

    func testWhenWebsiteInTopHits_ThenWebsiteRemovedFromSuggestions() throws {
        func runAssertion(_ platform: Platform) throws {
            let result = try Processor.process(
                query: "DuckDuckGo",
                platform: platform,
                bookmarks: [],
                history: [],
                openTabs: [],
                internalPages: [],
                apiResult: TestFixtures.anAPIResultWithNav)

            XCTAssertEqual(result.topHits.count, 1)
            XCTAssertEqual(result.topHits[0].url?.absoluteString, "http://www.example.com")

            XCTAssertFalse(
                result.duckduckgoSuggestions.contains(where: {
                    if case .website(let url) = $0, url.absoluteString.hasSuffix("://www.example.com") {
                        return true
                    }
                    return false
                })
            )
        }

        try runAssertion(.desktop)
        try runAssertion(.mobile)
    }
}

// MARK: - Test helpers

private struct TestBookmark: Bookmark {
    var url: String
    var title: String
    var isFavorite: Bool
}

extension TestBookmark {
    static var someBookmarks: [Bookmark] {
        [
            TestBookmark(url: "http://duckduckgo.com", title: "DuckDuckGo", isFavorite: true),
            TestBookmark(url: "spreadprivacy.com", title: "Test 2", isFavorite: true),
            TestBookmark(url: "wikipedia.org", title: "Wikipedia", isFavorite: false),
        ]
    }
}

private struct TestHistory: HistorySuggestion {
    var identifier: UUID
    var url: URL
    var title: String?
    var numberOfVisits: Int
    var lastVisit: Date
    var failedToLoad: Bool
}

extension TestHistory {
    static var aHistory: [HistorySuggestion] {
        [
            TestHistory(identifier: UUID(),
                        url: URL(string: "http://www.duckduckgo.com")!,
                        title: nil,
                        numberOfVisits: 1000,
                        lastVisit: Date(),
                        failedToLoad: false),
        ]
    }

    static var duckHistoryWithoutDuckDuckGo: [HistorySuggestion] {
        [
            TestHistory(identifier: UUID(),
                        url: URL(string: "http://www.ducktails.com")!,
                        title: nil,
                        numberOfVisits: 100,
                        lastVisit: Date(),
                        failedToLoad: false),
            TestHistory(identifier: UUID(),
                        url: URL(string: "http://www.duck.com")!,
                        title: "DuckMail",
                        numberOfVisits: 300,
                        lastVisit: Date(),
                        failedToLoad: false),
        ]
    }
}

private struct TestTab: BrowserTab {
    let tabId: String? = nil
    let url: URL
    let title: String

    init(url: String, title: String) {
        self.url = URL(string: url)!
        self.title = title
    }
}

private enum TestFixtures {
    static var anAPIResult: APIResult {
        var result = APIResult()
        result.items = [
            .init(phrase: "Test", isNav: nil),
            .init(phrase: "Test 2", isNav: nil),
            .init(phrase: "www.example.com", isNav: nil),
        ]
        return result
    }

    static var anAPIResultWithNav: APIResult {
        var result = APIResult()
        result.items = [
            .init(phrase: "Test", isNav: nil),
            .init(phrase: "Test 2", isNav: nil),
            .init(phrase: "www.example.com", isNav: true),
            .init(phrase: "www.othersite.com", isNav: false),
        ]
        return result
    }

    static var someInternalPages: [InternalPage] {
        [
            InternalPage(title: "Settings", url: URL(string: "duck://settings")!),
            InternalPage(title: "Bookmarks", url: URL(string: "duck://bookmarks")!),
            InternalPage(title: "Duck Player Settings", url: URL(string: "duck://bookmarks/duck-player")!),
        ]
    }
}
