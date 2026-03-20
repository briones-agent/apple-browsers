//
//  BrowserKitBookmarkTreeBuilderTests.swift
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

final class BrowserKitBookmarkTreeBuilderTests: XCTestCase {

    private var treeBuilder: BrowserKitBookmarkTreeBuilder!

    override func setUp() {
        super.setUp()
        treeBuilder = BrowserKitBookmarkTreeBuilder()
    }

    override func tearDown() {
        treeBuilder = nil
        super.tearDown()
    }

    func testWhenFolderHasMultipleChildrenThenAllChildrenAreAttached() throws {
        let bookmarks = [
            makeFolder(identifier: "folder"),
            makeBookmark(identifier: "bookmark-1", parentIdentifier: "folder", urlString: "https://duckduckgo.com/one"),
            makeBookmark(identifier: "bookmark-2", parentIdentifier: "folder", urlString: "https://duckduckgo.com/two")
        ]

        let result = treeBuilder.build(bookmarks: bookmarks, readingListItems: [])

        XCTAssertEqual(result.count, 1)
        let folder = try XCTUnwrap(result.first)
        XCTAssertEqual(folder.type, .folder)
        XCTAssertEqual(folder.children?.count, 2)
        XCTAssertEqual(folder.children?.compactMap(\.urlString), ["https://duckduckgo.com/one", "https://duckduckgo.com/two"])
    }

    func testWhenIdentifierCollidesThenChildrenAreStillPreserved() throws {
        let bookmarks = [
            makeFolder(identifier: "shared"),
            makeBookmark(identifier: "shared", parentIdentifier: "shared", urlString: "https://duckduckgo.com/a"),
            makeBookmark(identifier: "shared", parentIdentifier: "shared", urlString: "https://duckduckgo.com/b")
        ]

        let result = treeBuilder.build(bookmarks: bookmarks, readingListItems: [])

        XCTAssertEqual(result.count, 1)
        let folder = try XCTUnwrap(result.first)
        XCTAssertEqual(folder.type, .folder)
        XCTAssertEqual(folder.children?.count, 2)
        XCTAssertEqual(folder.children?.compactMap(\.urlString), ["https://duckduckgo.com/a", "https://duckduckgo.com/b"])
    }

    func testWhenBookmarksAreNestedThenFolderHierarchyIsBuilt() throws {
        let bookmarks = [
            makeFolder(identifier: "root-folder"),
            makeFolder(identifier: "child-folder", parentIdentifier: "root-folder"),
            makeBookmark(identifier: "nested-bookmark", parentIdentifier: "child-folder", urlString: "https://duckduckgo.com/nested")
        ]

        let result = treeBuilder.build(bookmarks: bookmarks, readingListItems: [])

        XCTAssertEqual(result.count, 1)
        let rootFolder = try XCTUnwrap(result.first)
        XCTAssertEqual(rootFolder.type, .folder)
        XCTAssertEqual(rootFolder.children?.count, 1)

        let childFolder = try XCTUnwrap(rootFolder.children?.first)
        XCTAssertEqual(childFolder.type, .folder)
        XCTAssertEqual(childFolder.children?.count, 1)
        XCTAssertEqual(childFolder.children?.first?.urlString, "https://duckduckgo.com/nested")
    }

    func testWhenFolderIdentifiersRepeatAcrossBranchesThenNestedChildrenAttachToNearestParent() throws {
        let bookmarks = [
            makeFolder(identifier: "root", title: "Root One"),
            makeFolder(identifier: "folder", parentIdentifier: "root", title: "Folder One"),
            makeBookmark(identifier: "bookmark-one", parentIdentifier: "folder", urlString: "https://duckduckgo.com/one"),
            makeFolder(identifier: "root", title: "Root Two"),
            makeFolder(identifier: "folder", parentIdentifier: "root", title: "Folder Two"),
            makeBookmark(identifier: "bookmark-two", parentIdentifier: "folder", urlString: "https://duckduckgo.com/two")
        ]

        let result = treeBuilder.build(bookmarks: bookmarks, readingListItems: [])

        XCTAssertEqual(result.count, 2)
        let rootOne = try XCTUnwrap(result.first(where: { $0.name == "Root One" }))
        let rootTwo = try XCTUnwrap(result.first(where: { $0.name == "Root Two" }))

        XCTAssertEqual(rootOne.children?.count, 1)
        XCTAssertEqual(rootTwo.children?.count, 1)

        let folderOne = try XCTUnwrap(rootOne.children?.first)
        let folderTwo = try XCTUnwrap(rootTwo.children?.first)

        XCTAssertEqual(folderOne.name, "Folder One")
        XCTAssertEqual(folderTwo.name, "Folder Two")
        XCTAssertEqual(folderOne.children?.first?.urlString, "https://duckduckgo.com/one")
        XCTAssertEqual(folderTwo.children?.first?.urlString, "https://duckduckgo.com/two")
    }

    func testWhenParentIdentifierIsRootFolderMarkerThenItemsAttachToCurrentRootFolder() throws {
        let bookmarks = [
            makeFolder(identifier: "root-1", title: "Root One"),
            makeBookmark(identifier: "child-1", parentIdentifier: "0", urlString: "https://duckduckgo.com/one"),
            makeFolder(identifier: "nested", parentIdentifier: "0", title: "Nested Folder"),
            makeBookmark(identifier: "child-2", parentIdentifier: "0", urlString: "https://duckduckgo.com/two")
        ]

        let result = treeBuilder.build(bookmarks: bookmarks, readingListItems: [])

        XCTAssertEqual(result.count, 1)
        let rootFolder = try XCTUnwrap(result.first)
        XCTAssertEqual(rootFolder.name, "Root One")
        XCTAssertEqual(rootFolder.children?.count, 3)
        XCTAssertEqual(rootFolder.children?[0].urlString, "https://duckduckgo.com/one")
        XCTAssertEqual(rootFolder.children?[1].name, "Nested Folder")
        XCTAssertEqual(rootFolder.children?[2].urlString, "https://duckduckgo.com/two")
    }

    func testWhenNestedFolderIsCreatedFromRootFolderMarkerThenParentScopedChildrenAttachInsideNestedFolder() throws {
        let bookmarks = [
            makeFolder(identifier: "workspace-root", title: "Workspace Root"),
            makeBookmark(identifier: "top-level", parentIdentifier: "0", urlString: "https://duckduckgo.com/top"),
            makeFolder(identifier: "reports-folder", parentIdentifier: "0", title: "Reports Folder"),
            makeBookmark(identifier: "intermediate-root", parentIdentifier: "0", urlString: "https://duckduckgo.com/intermediate"),
            makeBookmark(identifier: "report-1", parentIdentifier: "workspace-root", urlString: "https://duckduckgo.com/report1"),
            makeBookmark(identifier: "report-2", parentIdentifier: "workspace-root", urlString: "https://duckduckgo.com/report2"),
            makeBookmark(identifier: "back-to-root", parentIdentifier: "0", urlString: "https://duckduckgo.com/back")
        ]

        let result = treeBuilder.build(bookmarks: bookmarks, readingListItems: [])

        XCTAssertEqual(result.count, 1)
        let workspaceRoot = try XCTUnwrap(result.first)
        XCTAssertEqual(workspaceRoot.name, "Workspace Root")
        XCTAssertEqual(workspaceRoot.children?.count, 4)

        let reportsFolder = try XCTUnwrap(workspaceRoot.children?.first(where: { $0.name == "Reports Folder" }))
        XCTAssertEqual(reportsFolder.type, .folder)
        XCTAssertEqual(reportsFolder.children?.count, 2)
        XCTAssertEqual(reportsFolder.children?.compactMap(\.urlString), ["https://duckduckgo.com/report1", "https://duckduckgo.com/report2"])

        XCTAssertNotNil(workspaceRoot.children?.first(where: { $0.urlString == "https://duckduckgo.com/intermediate" }))
        XCTAssertNotNil(workspaceRoot.children?.first(where: { $0.urlString == "https://duckduckgo.com/back" }))
        XCTAssertNil(reportsFolder.children?.first(where: { $0.urlString == "https://duckduckgo.com/intermediate" }))
        XCTAssertNil(reportsFolder.children?.first(where: { $0.urlString == "https://duckduckgo.com/back" }))
    }

    func testWhenRootFolderMarkerAppearsWithoutCurrentRootFolderThenItemStaysAtTopLevel() {
        let bookmarks = [
            makeBookmark(identifier: "lonely", parentIdentifier: "0", urlString: "https://duckduckgo.com")
        ]

        let result = treeBuilder.build(bookmarks: bookmarks, readingListItems: [])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.urlString, "https://duckduckgo.com")
    }

    func testWhenNumericIdentifiersArriveOutOfOrderThenRootFolderChildrenAttachToCorrectRoot() throws {
        let bookmarks = [
            makeFolder(identifier: "1", title: "Root One"),
            makeFolder(identifier: "17", parentIdentifier: "0", title: "Nested One"),
            makeBookmark(identifier: "21",
                         parentIdentifier: "1",
                         urlString: "https://example.com/nested-one-item",
                         title: "Nested One Item"),
            makeFolder(identifier: "124", title: "Root Two"),
            makeFolder(identifier: "144", parentIdentifier: "0", title: "Nested Two"),
            makeBookmark(identifier: "145",
                         parentIdentifier: "124",
                         urlString: "https://example.com/nested-two-item",
                         title: "Nested Two Item"),
            // Intentionally out-of-order: this belongs to Root One despite arriving late.
            makeBookmark(identifier: "11",
                         parentIdentifier: "0",
                         urlString: "https://example.com/root-one-tail",
                         title: "Root One Tail"),
            // Intentionally out-of-order: this belongs to Root Two despite arriving after id 11.
            makeBookmark(identifier: "160",
                         parentIdentifier: "0",
                         urlString: "https://example.com/root-two-tail",
                         title: "Root Two Tail")
        ]

        let result = treeBuilder.build(bookmarks: bookmarks, readingListItems: [])

        let rootOne = try XCTUnwrap(result.first(where: { $0.name == "Root One" }))
        let nestedOne = try XCTUnwrap(rootOne.children?.first(where: { $0.name == "Nested One" }))
        XCTAssertEqual(rootOne.children?.count, 2)
        XCTAssertEqual(nestedOne.children?.count, 1)
        XCTAssertNotNil(nestedOne.children?.first(where: { $0.urlString == "https://example.com/nested-one-item" }))
        XCTAssertNotNil(rootOne.children?.first(where: { $0.urlString == "https://example.com/root-one-tail" }))

        let rootTwo = try XCTUnwrap(result.first(where: { $0.name == "Root Two" }))
        let nestedTwo = try XCTUnwrap(rootTwo.children?.first(where: { $0.name == "Nested Two" }))
        XCTAssertEqual(rootTwo.children?.count, 2)
        XCTAssertEqual(nestedTwo.children?.count, 1)
        XCTAssertNotNil(nestedTwo.children?.first(where: { $0.urlString == "https://example.com/nested-two-item" }))
        XCTAssertNotNil(rootTwo.children?.first(where: { $0.urlString == "https://example.com/root-two-tail" }))
    }

    func testWhenBrowserKitPayloadMatchesSafariExportPatternThenNestedHierarchyIsPreserved() throws {
        let bookmarks = [
            makeFolder(identifier: "root-a", title: "Root Alpha"),
            makeFolder(identifier: "folder-a1", parentIdentifier: "0", title: "Folder Alpha One"),
            makeBookmark(identifier: "deep-a1-item", parentIdentifier: "root-a", urlString: "https://example.com/alpha/deep-item"),
            makeBookmark(identifier: "root-a-item", parentIdentifier: "0", urlString: "https://example.com/alpha/root-item"),

            makeFolder(identifier: "root-b", title: "Root Beta"),
            makeFolder(identifier: "folder-b1", parentIdentifier: "0", title: "Folder Beta One"),
            makeBookmark(identifier: "deep-b1-item", parentIdentifier: "root-b", urlString: "https://example.com/beta/deep-item-1"),
            makeBookmark(identifier: "deep-b1-item-2", parentIdentifier: "root-b", urlString: "https://example.com/beta/deep-item-2"),
            makeBookmark(identifier: "root-b-item", parentIdentifier: "0", urlString: "https://example.com/beta/root-item"),

            makeFolder(identifier: "root-c", title: "Root Gamma"),
            makeFolder(identifier: "folder-c1", parentIdentifier: "0", title: "Folder Gamma One"),
            makeBookmark(identifier: "deep-c1-item", parentIdentifier: "root-c", urlString: "https://example.com/gamma/deep-item"),
            makeBookmark(identifier: "root-c-item", parentIdentifier: "0", urlString: "https://example.com/gamma/root-item")
        ]

        let result = treeBuilder.build(bookmarks: bookmarks, readingListItems: [])

        let rootAlpha = try XCTUnwrap(result.first(where: { $0.name == "Root Alpha" }))
        let folderAlphaOne = try XCTUnwrap(rootAlpha.children?.first(where: { $0.name == "Folder Alpha One" }))
        XCTAssertEqual(folderAlphaOne.children?.compactMap(\.urlString), ["https://example.com/alpha/deep-item"])
        XCTAssertNotNil(rootAlpha.children?.first(where: { $0.urlString == "https://example.com/alpha/root-item" }))
        XCTAssertNil(folderAlphaOne.children?.first(where: { $0.urlString == "https://example.com/alpha/root-item" }))

        let rootBeta = try XCTUnwrap(result.first(where: { $0.name == "Root Beta" }))
        let folderBetaOne = try XCTUnwrap(rootBeta.children?.first(where: { $0.name == "Folder Beta One" }))
        XCTAssertEqual(folderBetaOne.children?.compactMap(\.urlString), ["https://example.com/beta/deep-item-1", "https://example.com/beta/deep-item-2"])
        XCTAssertNotNil(rootBeta.children?.first(where: { $0.urlString == "https://example.com/beta/root-item" }))
        XCTAssertNil(folderBetaOne.children?.first(where: { $0.urlString == "https://example.com/beta/root-item" }))

        let rootGamma = try XCTUnwrap(result.first(where: { $0.name == "Root Gamma" }))
        let folderGammaOne = try XCTUnwrap(rootGamma.children?.first(where: { $0.name == "Folder Gamma One" }))
        XCTAssertEqual(folderGammaOne.children?.compactMap(\.urlString), ["https://example.com/gamma/deep-item"])
        XCTAssertNotNil(rootGamma.children?.first(where: { $0.urlString == "https://example.com/gamma/root-item" }))
        XCTAssertNil(folderGammaOne.children?.first(where: { $0.urlString == "https://example.com/gamma/root-item" }))
    }

    func testWhenReadingListItemsExistThenReadingListFolderIsAppended() throws {
        let readingListItems = [
            BrowserKitReadingListNode(title: "DuckDuckGo", url: try XCTUnwrap(URL(string: "https://duckduckgo.com"))),
            BrowserKitReadingListNode(title: "Privacy", url: try XCTUnwrap(URL(string: "https://duckduckgo.com/privacy")))
        ]

        let result = treeBuilder.build(bookmarks: [], readingListItems: readingListItems)

        XCTAssertEqual(result.count, 1)
        let readingListFolder = try XCTUnwrap(result.first)
        XCTAssertEqual(readingListFolder.type, .folder)
        XCTAssertEqual(readingListFolder.name, "Reading List")
        XCTAssertEqual(readingListFolder.children?.count, 2)
    }

    private func makeFolder(identifier: String, parentIdentifier: String? = nil, title: String = "Folder") -> BrowserKitBookmarkNode {
        BrowserKitBookmarkNode(identifier: identifier,
                               title: title,
                               url: nil,
                               parentIdentifier: parentIdentifier,
                               isFolder: true)
    }

    private func makeBookmark(identifier: String, parentIdentifier: String?, urlString: String, title: String = "Bookmark") -> BrowserKitBookmarkNode {
        BrowserKitBookmarkNode(identifier: identifier,
                               title: title,
                               url: URL(string: urlString),
                               parentIdentifier: parentIdentifier,
                               isFolder: false)
    }
}

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

private final class MockBEBrowserDataImportManager: BrowserKitBrowserDataImportManaging {

    private let items: [BrowserKitImportPayloadItem]
    private(set) var receivedTokens: [UUID] = []

    init(items: [BrowserKitImportPayloadItem]) {
        self.items = items
    }

    func importBrowserData(token: UUID) -> AsyncThrowingStream<BrowserKitImportPayloadItem, Error> {
        receivedTokens.append(token)

        return AsyncThrowingStream { continuation in
            items.forEach { continuation.yield($0) }
            continuation.finish()
        }
    }
}
