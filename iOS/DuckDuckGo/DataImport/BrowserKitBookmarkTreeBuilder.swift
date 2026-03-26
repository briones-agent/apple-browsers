//
//  BrowserKitBookmarkTreeBuilder.swift
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

import Foundation
import BrowserServicesKit
import Bookmarks

struct BrowserKitBookmarkNode {
    let identifier: String
    let title: String
    let url: URL?
    let parentIdentifier: String?
    let isFolder: Bool
}

struct BrowserKitReadingListNode {
    let title: String
    let url: URL
}

struct BrowserKitBookmarkTreeBuilder {

    private struct BookmarkRecord {
        let streamIndex: Int
        let identifier: String
        let parentIdentifier: String?
        let treeNode: BookmarkOrFolder
        let isFolder: Bool
    }

    private struct TreeBuildSignals {
        var rootFolderChildrenWithoutActiveRoot = 0
        var rootFolderChildrenPrecedingActiveRoot = 0
        var unresolvedParentReferences = 0

        var suggestsReordering: Bool {
            rootFolderChildrenWithoutActiveRoot > 0
                || rootFolderChildrenPrecedingActiveRoot > 0
                || unresolvedParentReferences > 0
        }
    }

    private struct BuildResult {
        let roots: [BookmarkOrFolder]
        let signals: TreeBuildSignals
    }

    private struct RootFolder {
        let identifier: String
        let treeNode: BookmarkOrFolder
    }

    private struct UnplacedRecord {
        let identifier: String
        let parentIdentifier: String
        let treeNode: BookmarkOrFolder
        let isFolder: Bool
    }

    private static let readingListFolderTitle = UserText.bookmarkReadingListFolderTitle
    private static let rootFolderParentIdentifier = "0"

    func build(bookmarks: [BrowserKitBookmarkNode],
               readingListItems: [BrowserKitReadingListNode]) -> [BookmarkOrFolder] {
        // First pass: build the tree using the original stream order from BrowserKit.
        // This works when items arrive in a parent-before-child sequence.
        let streamRecords = makeBookmarkRecords(from: bookmarks)
        let streamResult = buildTree(records: streamRecords,
                                     readingListItems: readingListItems)

        guard streamResult.signals.suggestsReordering else {
            return streamResult.roots
        }

        // Stream order produced placement issues (e.g. root-folder children arriving out of sequence). If all identifiers are numeric, 
        // retry with records sorted by identifier (in observed BrowserKit payloads, numeric sorting restores correct parent-before-child ordering.)
        let canUseNumericFallback = streamRecords.allSatisfy { record in
            numericIdentifierValue(for: record.identifier) != nil
        }

        guard canUseNumericFallback else {
            return streamResult.roots
        }

        // Second pass: rebuild the tree with records sorted by numeric identifier.
        let fallbackRecords = makeBookmarkRecords(from: bookmarks)
        let numericOrderedRecords = makeNumericOrderedRecords(from: fallbackRecords)
        let fallbackResult = buildTree(records: numericOrderedRecords,
                                       readingListItems: readingListItems)

        return fallbackResult.roots
    }

    private func insert(_ treeNode: BookmarkOrFolder,
                        into parentFolder: BookmarkOrFolder?,
                        topLevelNodes: inout [BookmarkOrFolder]) {
        guard let parentFolder else {
            topLevelNodes.append(treeNode)
            return
        }

        if parentFolder.children == nil {
            parentFolder.children = []
        }
        parentFolder.children?.append(treeNode)
    }

    // swiftlint:disable:next cyclomatic_complexity
    private func buildTree(records: [BookmarkRecord],
                           readingListItems: [BrowserKitReadingListNode]) -> BuildResult {
        var topLevelNodes: [BookmarkOrFolder] = []
        var foldersByIdentifier: [String: BookmarkOrFolder] = [:]
        var currentRootFolder: RootFolder?
        var activeNestedFolder: BookmarkOrFolder?
        var unplacedRecords: [UnplacedRecord] = []
        var signals = TreeBuildSignals()

        for record in records {
            guard let parentIdentifier = record.parentIdentifier else {
                insert(record.treeNode, into: nil, topLevelNodes: &topLevelNodes)
                if record.isFolder {
                    currentRootFolder = RootFolder(identifier: record.identifier, treeNode: record.treeNode)
                    foldersByIdentifier[record.identifier] = record.treeNode
                }
                activeNestedFolder = nil
                continue
            }

            if parentIdentifier == Self.rootFolderParentIdentifier {
                if let currentRootFolder {
                    insert(record.treeNode, into: currentRootFolder.treeNode, topLevelNodes: &topLevelNodes)

                    if let rootIdentifier = numericIdentifierValue(for: currentRootFolder.identifier),
                       let currentIdentifier = numericIdentifierValue(for: record.identifier),
                       currentIdentifier < rootIdentifier {
                        signals.rootFolderChildrenPrecedingActiveRoot += 1
                    }
                } else {
                    insert(record.treeNode, into: nil, topLevelNodes: &topLevelNodes)
                    signals.rootFolderChildrenWithoutActiveRoot += 1
                }

                if record.isFolder {
                    if currentRootFolder != nil {
                        activeNestedFolder = record.treeNode
                    }
                    foldersByIdentifier[record.identifier] = record.treeNode
                }
                continue
            }

            // When a nested folder was declared under the current root folder, subsequent
            // items referencing the root folder's identifier belong inside that nested folder.
            if let currentRootFolder,
               parentIdentifier == currentRootFolder.identifier,
               let activeNestedFolder {
                insert(record.treeNode, into: activeNestedFolder, topLevelNodes: &topLevelNodes)
                if record.isFolder {
                    foldersByIdentifier[record.identifier] = record.treeNode
                }
                continue
            }

            activeNestedFolder = nil

            if let parentFolder = foldersByIdentifier[parentIdentifier] {
                insert(record.treeNode, into: parentFolder, topLevelNodes: &topLevelNodes)
                if record.isFolder {
                    foldersByIdentifier[record.identifier] = record.treeNode
                }
            } else {
                unplacedRecords.append(
                    UnplacedRecord(identifier: record.identifier,
                                   parentIdentifier: parentIdentifier,
                                   treeNode: record.treeNode,
                                   isFolder: record.isFolder)
                )
            }
        }

        if !unplacedRecords.isEmpty {
            var remaining = unplacedRecords
            var madeProgress = true

            while !remaining.isEmpty, madeProgress {
                madeProgress = false
                var nextRemaining: [UnplacedRecord] = []

                for unplacedRecord in remaining {
                    let parentIdentifier = unplacedRecord.parentIdentifier

                    if let parentFolder = foldersByIdentifier[parentIdentifier] {
                        insert(unplacedRecord.treeNode, into: parentFolder, topLevelNodes: &topLevelNodes)
                        if unplacedRecord.isFolder {
                            foldersByIdentifier[unplacedRecord.identifier] = unplacedRecord.treeNode
                        }
                        madeProgress = true
                    } else {
                        nextRemaining.append(unplacedRecord)
                    }
                }

                remaining = nextRemaining
            }

            remaining.forEach { remainingRecord in
                insert(remainingRecord.treeNode, into: nil, topLevelNodes: &topLevelNodes)
                signals.unresolvedParentReferences += 1
            }
        }

        let readingListBookmarks = makeReadingListBookmarks(from: readingListItems)
        if !readingListBookmarks.isEmpty {
            topLevelNodes.append(
                BookmarkOrFolder(name: Self.readingListFolderTitle,
                                 type: .folder,
                                 urlString: nil,
                                 children: readingListBookmarks)
            )
        }
        return BuildResult(roots: topLevelNodes, signals: signals)
    }

    private func makeBookmarkRecords(from bookmarks: [BrowserKitBookmarkNode]) -> [BookmarkRecord] {
        bookmarks.enumerated().map { bookmarkIndex, bookmark in
            // Node and parent identifiers intentionally use different normalization semantics.
            // For parent identifiers, blank means "no parent".
            BookmarkRecord(streamIndex: bookmarkIndex,
                           identifier: normalizeNodeIdentifier(bookmark.identifier),
                           parentIdentifier: normalizeParentIdentifier(bookmark.parentIdentifier),
                           treeNode: makeBookmark(from: bookmark),
                           isFolder: bookmark.isFolder)
        }
    }

    private func makeNumericOrderedRecords(from records: [BookmarkRecord]) -> [BookmarkRecord] {
        records.sorted { lhs, rhs in
            guard
                let leftIdentifierValue = numericIdentifierValue(for: lhs.identifier),
                let rightIdentifierValue = numericIdentifierValue(for: rhs.identifier)
            else {
                return lhs.streamIndex < rhs.streamIndex
            }

            if leftIdentifierValue == rightIdentifierValue {
                return lhs.streamIndex < rhs.streamIndex
            }

            return leftIdentifierValue < rightIdentifierValue
        }
    }

    private func makeBookmark(from bookmark: BrowserKitBookmarkNode) -> BookmarkOrFolder {
        let bookmarkType: BookmarkOrFolder.BookmarkType = bookmark.isFolder ? .folder : .bookmark
        return BookmarkOrFolder(name: bookmark.title,
                                type: bookmarkType,
                                urlString: bookmark.url?.absoluteString,
                                children: nil)
    }

    private func makeReadingListBookmarks(from readingListItems: [BrowserKitReadingListNode]) -> [BookmarkOrFolder] {
        readingListItems.map { readingListItem in
            BookmarkOrFolder(name: readingListItem.title,
                             type: .bookmark,
                             urlString: readingListItem.url.absoluteString,
                             children: nil)
        }
    }

    /// Parent identifiers treat blank values as missing to avoid attaching children to a synthetic empty parent key.
    private func normalizeParentIdentifier(_ identifier: String?) -> String? {
        guard let identifier else { return nil }
        let normalized = normalizeNodeIdentifier(identifier)
        return normalized.isEmpty ? nil : normalized
    }

    /// Node identifiers are normalized by trimming whitespace only.
    /// Empty string is preserved as a stable key for node identity.
    private func normalizeNodeIdentifier(_ identifier: String) -> String {
        identifier.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func numericIdentifierValue(for identifier: String) -> Int? {
        Int(identifier.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
