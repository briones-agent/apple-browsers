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
