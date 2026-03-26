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
import os.log
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

    private enum BuildStrategy: String {
        case streamOrder = "stream-order"
        case numericFallback = "numeric-fallback"
    }

    private static let readingListFolderTitle = "Reading List"
    private static let rootFolderParentIdentifier = "0"

    func build(bookmarks: [BrowserKitBookmarkNode],
               readingListItems: [BrowserKitReadingListNode]) -> [BookmarkOrFolder] {
        Logger.bookmarks.debug(
            "BrowserKit tree build started: bookmarks=\(bookmarks.count, privacy: .public), reading-list=\(readingListItems.count, privacy: .public)"
        )

        // First pass: build the tree using the original stream order from BrowserKit.
        // This works when items arrive in a parent-before-child sequence.
        let streamRecords = makeBookmarkRecords(from: bookmarks)
        let streamResult = buildTree(records: streamRecords,
                                     readingListItems: readingListItems,
                                     strategy: .streamOrder)

        guard streamResult.signals.suggestsReordering else {
            Logger.bookmarks.debug(
                "BrowserKit tree build finished: strategy=stream-order, roots=\(streamResult.roots.count, privacy: .public), fallback-used=false"
            )
            return streamResult.roots
        }

        // Stream order produced placement issues (e.g. root-folder children arriving out of sequence). If all identifiers are numeric, 
        // retry with records sorted by identifier (in observed BrowserKit payloads, numeric sorting restores correct parent-before-child ordering.)
        let canUseNumericFallback = streamRecords.allSatisfy { record in
            numericIdentifierValue(for: record.identifier) != nil
        }

        guard canUseNumericFallback else {
            Logger.bookmarks.debug(
                """
                BrowserKit tree fallback skipped: \
                root-children-without-root=\(streamResult.signals.rootFolderChildrenWithoutActiveRoot, privacy: .public), \
                root-children-preceding-root=\(streamResult.signals.rootFolderChildrenPrecedingActiveRoot, privacy: .public), \
                unresolved-parent-references=\(streamResult.signals.unresolvedParentReferences, privacy: .public), \
                reason=non-numeric-identifiers
                """
            )
            return streamResult.roots
        }

        // Second pass: rebuild the tree with records sorted by numeric identifier.
        let fallbackRecords = makeBookmarkRecords(from: bookmarks)
        let numericOrderedRecords = makeNumericOrderedRecords(from: fallbackRecords)
        let fallbackResult = buildTree(records: numericOrderedRecords,
                                       readingListItems: readingListItems,
                                       strategy: .numericFallback)

        Logger.bookmarks.debug(
            """
            BrowserKit tree fallback applied: stream-signals \
            root-children-without-root=\(streamResult.signals.rootFolderChildrenWithoutActiveRoot, privacy: .public), \
            root-children-preceding-root=\(streamResult.signals.rootFolderChildrenPrecedingActiveRoot, privacy: .public), \
            unresolved-parent-references=\(streamResult.signals.unresolvedParentReferences, privacy: .public), \
            fallback-roots=\(fallbackResult.roots.count, privacy: .public)
            """
        )

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
                           readingListItems: [BrowserKitReadingListNode],
                           strategy: BuildStrategy) -> BuildResult {
        var topLevelNodes: [BookmarkOrFolder] = []
        var foldersByIdentifier: [String: BookmarkOrFolder] = [:]
        var currentRootFolder: RootFolder?
        var activeNestedFolder: BookmarkOrFolder?
        var unplacedRecords: [UnplacedRecord] = []
        var signals = TreeBuildSignals()

        Logger.bookmarks.debug("BrowserKit tree processing order: strategy=\(strategy.rawValue, privacy: .public)")

        for record in records {
            Logger.bookmarks.debug(
                """
                BrowserKit tree item: strategy=\(strategy.rawValue, privacy: .public), \
                idx=\(record.streamIndex, privacy: .public), \
                id=\(record.identifier, privacy: .private), \
                parent=\(record.parentIdentifier ?? "nil", privacy: .private), \
                is-folder=\(record.isFolder, privacy: .public), \
                current-root=\(currentRootFolder?.identifier ?? "nil", privacy: .private), \
                has-active-nested=\(activeNestedFolder != nil, privacy: .public)
                """
            )

            guard let parentIdentifier = record.parentIdentifier else {
                insert(record.treeNode, into: nil, topLevelNodes: &topLevelNodes)
                if record.isFolder {
                    currentRootFolder = RootFolder(identifier: record.identifier, treeNode: record.treeNode)
                    foldersByIdentifier[record.identifier] = record.treeNode
                    Logger.bookmarks.debug(
                        "BrowserKit tree root attach: strategy=\(strategy.rawValue, privacy: .public), idx=\(record.streamIndex, privacy: .public), id=\(record.identifier, privacy: .private), reason=no-parent-folder"
                    )
                } else {
                    Logger.bookmarks.debug(
                        "BrowserKit tree root attach: strategy=\(strategy.rawValue, privacy: .public), idx=\(record.streamIndex, privacy: .public), id=\(record.identifier, privacy: .private), reason=no-parent-bookmark-preserves-root-context"
                    )
                }

                if activeNestedFolder != nil {
                    Logger.bookmarks.debug(
                        "BrowserKit tree nested context cleared: strategy=\(strategy.rawValue, privacy: .public), idx=\(record.streamIndex, privacy: .public), reason=no-parent"
                    )
                }
                activeNestedFolder = nil
                continue
            }

            if parentIdentifier == Self.rootFolderParentIdentifier {
                if let currentRootFolder {
                    insert(record.treeNode, into: currentRootFolder.treeNode, topLevelNodes: &topLevelNodes)
                    Logger.bookmarks.debug(
                        "BrowserKit tree nested attach: strategy=\(strategy.rawValue, privacy: .public), idx=\(record.streamIndex, privacy: .public), id=\(record.identifier, privacy: .private), parent=root-sentinel, target-root=\(currentRootFolder.identifier, privacy: .private)"
                    )

                    if let rootIdentifier = numericIdentifierValue(for: currentRootFolder.identifier),
                       let currentIdentifier = numericIdentifierValue(for: record.identifier),
                       currentIdentifier < rootIdentifier {
                        signals.rootFolderChildrenPrecedingActiveRoot += 1
                    }
                } else {
                    insert(record.treeNode, into: nil, topLevelNodes: &topLevelNodes)
                    signals.rootFolderChildrenWithoutActiveRoot += 1
                    Logger.bookmarks.debug(
                        "BrowserKit tree root attach: strategy=\(strategy.rawValue, privacy: .public), idx=\(record.streamIndex, privacy: .public), id=\(record.identifier, privacy: .private), parent=root-sentinel, reason=no-active-root"
                    )
                }

                if record.isFolder {
                    if currentRootFolder != nil {
                        activeNestedFolder = record.treeNode
                        Logger.bookmarks.debug(
                            "BrowserKit tree nested context set: strategy=\(strategy.rawValue, privacy: .public), idx=\(record.streamIndex, privacy: .public), folder-id=\(record.identifier, privacy: .private)"
                        )
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
                Logger.bookmarks.debug(
                    "BrowserKit tree nested attach: strategy=\(strategy.rawValue, privacy: .public), idx=\(record.streamIndex, privacy: .public), id=\(record.identifier, privacy: .private), parent=\(parentIdentifier, privacy: .private), target=active-nested-folder"
                )
                if record.isFolder {
                    foldersByIdentifier[record.identifier] = record.treeNode
                }
                continue
            }

            if activeNestedFolder != nil {
                Logger.bookmarks.debug(
                    "BrowserKit tree nested context cleared: strategy=\(strategy.rawValue, privacy: .public), idx=\(record.streamIndex, privacy: .public), reason=parent-not-current-root"
                )
            }
            activeNestedFolder = nil

            if let parentFolder = foldersByIdentifier[parentIdentifier] {
                insert(record.treeNode, into: parentFolder, topLevelNodes: &topLevelNodes)
                Logger.bookmarks.debug(
                    "BrowserKit tree nested attach: strategy=\(strategy.rawValue, privacy: .public), idx=\(record.streamIndex, privacy: .public), id=\(record.identifier, privacy: .private), parent=\(parentIdentifier, privacy: .private), target=parent-lookup"
                )
                if record.isFolder {
                    foldersByIdentifier[record.identifier] = record.treeNode
                }
            } else {
                Logger.bookmarks.debug(
                    "BrowserKit tree unresolved parent queued: strategy=\(strategy.rawValue, privacy: .public), idx=\(record.streamIndex, privacy: .public), id=\(record.identifier, privacy: .private), parent=\(parentIdentifier, privacy: .private)"
                )
                unplacedRecords.append(
                    UnplacedRecord(identifier: record.identifier,
                                   parentIdentifier: parentIdentifier,
                                   treeNode: record.treeNode,
                                   isFolder: record.isFolder)
                )
            }
        }

        if !unplacedRecords.isEmpty {
            Logger.bookmarks.debug(
                "BrowserKit tree unresolved pass started: strategy=\(strategy.rawValue, privacy: .public), queued=\(unplacedRecords.count, privacy: .public)"
            )
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
                        Logger.bookmarks.debug(
                            "BrowserKit tree unresolved attach: strategy=\(strategy.rawValue, privacy: .public), id=\(unplacedRecord.identifier, privacy: .private), parent=\(parentIdentifier, privacy: .private), target=parent-lookup"
                        )
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
                Logger.bookmarks.debug(
                    "BrowserKit tree unresolved parent dropped-to-root: strategy=\(strategy.rawValue, privacy: .public), id=\(remainingRecord.identifier, privacy: .private), parent=\(remainingRecord.parentIdentifier, privacy: .private)"
                )
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
            Logger.bookmarks.debug(
                "BrowserKit tree reading-list appended: strategy=\(strategy.rawValue, privacy: .public), count=\(readingListBookmarks.count, privacy: .public)"
            )
        }

        Logger.bookmarks.debug(
            """
            BrowserKit tree build finished: strategy=\(strategy.rawValue, privacy: .public), \
            roots=\(topLevelNodes.count, privacy: .public), \
            unresolved-parent-references=\(signals.unresolvedParentReferences, privacy: .public), \
            suggests-reordering=\(signals.suggestsReordering, privacy: .public)
            """
        )
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
