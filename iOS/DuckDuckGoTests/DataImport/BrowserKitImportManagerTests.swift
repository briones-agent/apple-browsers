//
//  BrowserKitImportManagerTests.swift
//  DuckDuckGoTests
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
import Bookmarks
import BrowserServicesKit
import Persistence
@testable import DuckDuckGo

@MainActor
final class BrowserKitImportManagerTests: XCTestCase {

    private var database: CoreDataDatabase!

    override func setUpWithError() throws {
        try super.setUpWithError()
        database = MockBookmarksDatabase.make()
    }

    override func tearDownWithError() throws {
        try database.tearDown(deleteStores: true)
        database = nil
        try super.tearDownWithError()
    }

    func testWhenStreamContainsMultipleNestedLevelsThenImportPersistsExpectedHierarchy() async throws {
        let token = UUID()
        let mockImportManager = MockBEBrowserDataImportManager(items: makeMultiLevelFixture())
        let callbackExpectation = expectation(description: "Import callback")
        var callbackResult: Result<DataImportSummary, Error>?

        let browserKitImportManager = BrowserKitImportManager(bookmarksDatabase: database,
                                                              favoritesDisplayMode: .displayNative(.mobile),
                                                              browserDataImportManager: mockImportManager) { result in
            callbackResult = result
            callbackExpectation.fulfill()
        }

        browserKitImportManager.handleImportRequest(with: token)
        await fulfillment(of: [callbackExpectation], timeout: 2.0)

        let summary = try XCTUnwrap(callbackResult).get()
        _ = try XCTUnwrap(summary[.bookmarks]?.get())
        XCTAssertEqual(mockImportManager.receivedTokens, [token])

        let context = database.makeContext(concurrencyType: .mainQueueConcurrencyType)
        let root = try XCTUnwrap(BookmarkUtils.fetchRootFolder(context), "Root folder missing")

        let rootAlpha = try XCTUnwrap(folder(named: "Root Alpha", in: root.childrenArray))
        let folderAlphaOne = try XCTUnwrap(folder(named: "Folder Alpha One", in: rootAlpha.childrenArray))
        let folderAlphaTwo = try XCTUnwrap(folder(named: "Folder Alpha Two", in: folderAlphaOne.childrenArray))
        XCTAssertNotNil(bookmark(url: "https://example.com/alpha/deep-item", in: folderAlphaTwo.childrenArray))
        XCTAssertNotNil(bookmark(url: "https://example.com/alpha/root-item", in: rootAlpha.childrenArray))
        XCTAssertNil(bookmark(url: "https://example.com/alpha/root-item", in: folderAlphaTwo.childrenArray))

        let rootBeta = try XCTUnwrap(folder(named: "Root Beta", in: root.childrenArray))
        let folderBetaOne = try XCTUnwrap(folder(named: "Folder Beta One", in: rootBeta.childrenArray))
        let folderBetaTwo = try XCTUnwrap(folder(named: "Folder Beta Two", in: folderBetaOne.childrenArray))
        XCTAssertNotNil(bookmark(url: "https://example.com/beta/deep-item-1", in: folderBetaTwo.childrenArray))
        XCTAssertNotNil(bookmark(url: "https://example.com/beta/deep-item-2", in: folderBetaTwo.childrenArray))
        XCTAssertNotNil(bookmark(url: "https://example.com/beta/root-item", in: rootBeta.childrenArray))
        XCTAssertNil(bookmark(url: "https://example.com/beta/root-item", in: folderBetaTwo.childrenArray))

        let rootGamma = try XCTUnwrap(folder(named: "Root Gamma", in: root.childrenArray))
        let folderGammaOne = try XCTUnwrap(folder(named: "Folder Gamma One", in: rootGamma.childrenArray))
        let folderGammaTwo = try XCTUnwrap(folder(named: "Folder Gamma Two", in: folderGammaOne.childrenArray))
        let deepGammaFolder = try XCTUnwrap(folder(named: "Folder Gamma Three", in: folderGammaTwo.childrenArray))
        XCTAssertNotNil(bookmark(url: "https://example.com/save-to-pocket", in: deepGammaFolder.childrenArray))
        XCTAssertNotNil(bookmark(url: "https://example.com/gamma/root-item", in: rootGamma.childrenArray))
        XCTAssertNil(bookmark(url: "https://example.com/gamma/root-item", in: deepGammaFolder.childrenArray))

        let readingList = try XCTUnwrap(folder(named: "Reading List", in: root.childrenArray))
        XCTAssertNotNil(bookmark(url: "https://example.com/reading-list-item", in: readingList.childrenArray))
    }

    func testWhenStreamThrowsThenImportResultIsFailure() async throws {
        let token = UUID()
        let mockImportManager = MockBEBrowserDataImportManager(items: [], completionError: MockBrowserKitImportError.streamFailed)
        let callbackExpectation = expectation(description: "Import callback")
        var callbackResult: Result<DataImportSummary, Error>?

        let browserKitImportManager = BrowserKitImportManager(bookmarksDatabase: database,
                                                              favoritesDisplayMode: .displayNative(.mobile),
                                                              browserDataImportManager: mockImportManager) { result in
            callbackResult = result
            callbackExpectation.fulfill()
        }

        browserKitImportManager.handleImportRequest(with: token)
        await fulfillment(of: [callbackExpectation], timeout: 2.0)

        let result = try XCTUnwrap(callbackResult)
        guard case .failure(let error) = result else {
            XCTFail("Expected failure result")
            return
        }

        XCTAssertTrue(error is MockBrowserKitImportError)
        XCTAssertEqual(mockImportManager.receivedTokens, [token])
    }

    func testWhenStreamContainsOnlyUnsupportedItemsThenImportReturnsZeroBookmarkSummary() async throws {
        let token = UUID()
        let mockImportManager = MockBEBrowserDataImportManager(items: [
            .unsupported(typeName: "UnknownDataType"),
            .unsupported(typeName: "AnotherType")
        ])
        let callbackExpectation = expectation(description: "Import callback")
        var callbackResult: Result<DataImportSummary, Error>?

        let browserKitImportManager = BrowserKitImportManager(bookmarksDatabase: database,
                                                              favoritesDisplayMode: .displayNative(.mobile),
                                                              browserDataImportManager: mockImportManager) { result in
            callbackResult = result
            callbackExpectation.fulfill()
        }

        browserKitImportManager.handleImportRequest(with: token)
        await fulfillment(of: [callbackExpectation], timeout: 2.0)

        let summary = try XCTUnwrap(callbackResult).get()
        let bookmarkSummary = try XCTUnwrap(summary[.bookmarks]?.get())
        XCTAssertEqual(bookmarkSummary.successful, 0)
        XCTAssertEqual(bookmarkSummary.duplicate, 0)
        XCTAssertEqual(bookmarkSummary.failed, 0)
        XCTAssertEqual(mockImportManager.receivedTokens, [token])
    }

    private func makeMultiLevelFixture() -> [BrowserKitImportPayloadItem] {
        [
            .bookmark(makeFolder(identifier: "100", title: "Root Alpha")),
            .bookmark(makeFolder(identifier: "110", parentIdentifier: "0", title: "Folder Alpha One")),
            .bookmark(makeFolder(identifier: "120", parentIdentifier: "100", title: "Folder Alpha Two")),
            .bookmark(makeBookmark(identifier: "130",
                                   parentIdentifier: "120",
                                   title: "Alpha Deep Item",
                                   urlString: "https://example.com/alpha/deep-item")),
            .bookmark(makeBookmark(identifier: "140",
                                   parentIdentifier: "0",
                                   title: "Alpha Root Item",
                                   urlString: "https://example.com/alpha/root-item")),

            .bookmark(makeFolder(identifier: "200", title: "Root Beta")),
            .bookmark(makeFolder(identifier: "210", parentIdentifier: "0", title: "Folder Beta One")),
            .bookmark(makeFolder(identifier: "220", parentIdentifier: "200", title: "Folder Beta Two")),
            .bookmark(makeBookmark(identifier: "230",
                                   parentIdentifier: "220",
                                   title: "Beta Deep Item One",
                                   urlString: "https://example.com/beta/deep-item-1")),
            .bookmark(makeBookmark(identifier: "240",
                                   parentIdentifier: "220",
                                   title: "Beta Deep Item Two",
                                   urlString: "https://example.com/beta/deep-item-2")),
            .bookmark(makeBookmark(identifier: "250",
                                   parentIdentifier: "0",
                                   title: "Beta Root Item",
                                   urlString: "https://example.com/beta/root-item")),

            .bookmark(makeFolder(identifier: "300", title: "Root Gamma")),
            .bookmark(makeFolder(identifier: "310", parentIdentifier: "0", title: "Folder Gamma One")),
            .bookmark(makeFolder(identifier: "320", parentIdentifier: "300", title: "Folder Gamma Two")),
            .bookmark(makeFolder(identifier: "330", parentIdentifier: "320", title: "Folder Gamma Three")),
            .bookmark(makeBookmark(identifier: "340",
                                   parentIdentifier: "330",
                                   title: "Gamma Deep Item",
                                   urlString: "https://example.com/save-to-pocket")),
            .bookmark(makeBookmark(identifier: "350",
                                   parentIdentifier: "0",
                                   title: "Gamma Root Item",
                                   urlString: "https://example.com/gamma/root-item")),

            .readingListItem(
                BrowserKitReadingListNode(title: "Reading Item",
                                          url: URL(string: "https://example.com/reading-list-item")!)
            ),
            .unsupported(typeName: "MockUnsupportedBrowserData")
        ]
    }

    private func makeFolder(identifier: String,
                            parentIdentifier: String? = nil,
                            title: String) -> BrowserKitBookmarkNode {
        BrowserKitBookmarkNode(identifier: identifier,
                               title: title,
                               url: nil,
                               parentIdentifier: parentIdentifier,
                               isFolder: true)
    }

    private func makeBookmark(identifier: String,
                              parentIdentifier: String?,
                              title: String,
                              urlString: String) -> BrowserKitBookmarkNode {
        BrowserKitBookmarkNode(identifier: identifier,
                               title: title,
                               url: URL(string: urlString),
                               parentIdentifier: parentIdentifier,
                               isFolder: false)
    }

    private func folder(named name: String, in entities: [BookmarkEntity]) -> BookmarkEntity? {
        entities.first { entity in
            entity.isFolder && entity.title == name
        }
    }

    private func bookmark(url urlString: String, in entities: [BookmarkEntity]) -> BookmarkEntity? {
        entities.first { entity in
            !entity.isFolder && entity.url == urlString
        }
    }
}

private enum MockBrowserKitImportError: Error {
    case streamFailed
}

private final class MockBEBrowserDataImportManager: BrowserKitBrowserDataImportManaging {

    private let items: [BrowserKitImportPayloadItem]
    private let completionError: Error?
    private(set) var receivedTokens: [UUID] = []

    init(items: [BrowserKitImportPayloadItem], completionError: Error? = nil) {
        self.items = items
        self.completionError = completionError
    }

    func importBrowserData(token: UUID) -> AsyncThrowingStream<BrowserKitImportPayloadItem, Error> {
        receivedTokens.append(token)

        return AsyncThrowingStream { continuation in
            items.forEach { continuation.yield($0) }
            if let completionError {
                continuation.finish(throwing: completionError)
            } else {
                continuation.finish()
            }
        }
    }
}
