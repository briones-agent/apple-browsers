//
//  BrowserKitImportManager.swift
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
import BrowserKit
import BrowserServicesKit
import Persistence
import Bookmarks

protocol BrowserKitImportManaging {
    func handleImportRequest(with token: UUID)
}

typealias BrowserKitImportResultHandler = (Result<DataImportSummary, Error>) -> Void

enum BrowserKitImportManagerError: Error {
    case unsupportedPlatform
}

enum BrowserKitImportPayloadItem {
    case bookmark(BrowserKitBookmarkNode)
    case readingListItem(BrowserKitReadingListNode)
    case unsupported(typeName: String)
}

protocol BrowserKitBrowserDataImportManaging {
    func importBrowserData(token: UUID) -> AsyncThrowingStream<BrowserKitImportPayloadItem, Error>
}

final class LiveBEBrowserDataImportManagerAdapter: BrowserKitBrowserDataImportManaging {

#if compiler(>=6.3)
    func importBrowserData(token: UUID) -> AsyncThrowingStream<BrowserKitImportPayloadItem, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    if #available(iOS 26.4, *) {
                        let browserDataImportManager = BEBrowserDataImportManager()
                        for try await browserData in browserDataImportManager.importBrowserData(token: token) {
                            if let bookmark = browserData as? BEBrowserDataBookmark {
                                continuation.yield(
                                    .bookmark(
                                        BrowserKitBookmarkNode(identifier: bookmark.identifier,
                                                               title: bookmark.title,
                                                               url: bookmark.url,
                                                               parentIdentifier: bookmark.parentIdentifier,
                                                               isFolder: bookmark.isFolder)
                                    )
                                )
                            } else if let readingListItem = browserData as? BEBrowserDataReadingListItem {
                                continuation.yield(
                                    .readingListItem(
                                        BrowserKitReadingListNode(title: readingListItem.title,
                                                                  url: readingListItem.url)
                                    )
                                )
                            } else {
                                continuation.yield(.unsupported(typeName: String(describing: type(of: browserData))))
                            }
                        }
                        continuation.finish()
                    } else {
                        throw BrowserKitImportManagerError.unsupportedPlatform
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
#else
    func importBrowserData(token _: UUID) -> AsyncThrowingStream<BrowserKitImportPayloadItem, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: BrowserKitImportManagerError.unsupportedPlatform)
        }
    }
#endif
}

final class BrowserKitImportManager: BrowserKitImportManaging {
    private let bookmarkImporter: BookmarkCoreDataImporter
    private let browserDataImportManager: BrowserKitBrowserDataImportManaging
    private let onImportResult: BrowserKitImportResultHandler

    init(bookmarksDatabase: CoreDataDatabase,
         favoritesDisplayMode: FavoritesDisplayMode,
         browserDataImportManager: BrowserKitBrowserDataImportManaging = LiveBEBrowserDataImportManagerAdapter(),
         onImportResult: @escaping BrowserKitImportResultHandler = { _ in }) {
        self.bookmarkImporter = BookmarkCoreDataImporter(database: bookmarksDatabase,
                                                         favoritesDisplayMode: favoritesDisplayMode)
        self.browserDataImportManager = browserDataImportManager
        self.onImportResult = onImportResult
    }

    func handleImportRequest(with token: UUID) {
        Task { [weak self] in
            guard let self else { return }

            guard #available(iOS 26.4, *) else {
                await MainActor.run {
                    self.onImportResult(.failure(BrowserKitImportManagerError.unsupportedPlatform))
                }
                return
            }

            do {
                Logger.general.debug("Received BrowserKit import request")

                let importedData = try await importSupportedData(token: token)
                let folderCount = importedData.bookmarks.filter(\.isFolder).count
                let bookmarkCount = importedData.bookmarks.count - folderCount
                let nodesWithParentCount = importedData.bookmarks.filter { bookmark in
                    guard let parentIdentifier = bookmark.parentIdentifier else { return false }
                    return !parentIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }.count
                Logger.general.debug(
                    "BrowserKit import payload: folders=\(folderCount, privacy: .public), bookmarks=\(bookmarkCount, privacy: .public), with-parent=\(nodesWithParentCount, privacy: .public), reading-list=\(importedData.readingListItems.count, privacy: .public)"
                )

                let bookmarks = createBookmarksForImport(bookmarks: importedData.bookmarks,
                                                         readingListItems: importedData.readingListItems)
                let bookmarksSummary = try await bookmarkImporter.importBookmarks(bookmarks)
                let summary = createSummary(from: bookmarksSummary)

                await MainActor.run {
                    self.onImportResult(.success(summary))
                }
            } catch is CancellationError {
                Logger.general.debug("BrowserKit import request cancelled")
            } catch {
                Logger.general.error("BrowserKit import failed: \(error.localizedDescription, privacy: .public)")
                await MainActor.run {
                    self.onImportResult(.failure(error))
                }
            }
        }
    }

    private func createSummary(from bookmarksSummary: BookmarksImportSummary) -> DataImportSummary {
        [
            .bookmarks: .success(
                DataImport.DataTypeSummary(
                    successful: bookmarksSummary.successful,
                    duplicate: bookmarksSummary.duplicates,
                    failed: bookmarksSummary.failed
                )
            )
        ]
    }
}

private extension BrowserKitImportManager {

    struct ImportedData {
        var bookmarks: [BrowserKitBookmarkNode] = []
        var readingListItems: [BrowserKitReadingListNode] = []
    }

    func importSupportedData(token: UUID) async throws -> ImportedData {
        var importedData = ImportedData()
        var streamItemIndex = 0

        for try await browserData in browserDataImportManager.importBrowserData(token: token) {
            switch browserData {
            case .bookmark(let bookmark):
                importedData.bookmarks.append(bookmark)
                logRawIncomingBookmark(bookmark, at: streamItemIndex)
            case .readingListItem(let readingListItem):
                importedData.readingListItems.append(readingListItem)
                logRawIncomingReadingListItem(readingListItem, at: streamItemIndex)
            case .unsupported(let typeName):
                Logger.general.debug(
                    "Skipping unsupported BrowserKit data type: idx=\(streamItemIndex, privacy: .public), type=\(typeName, privacy: .public)"
                )
            }
            streamItemIndex += 1
        }

        return importedData
    }

    func createBookmarksForImport(bookmarks: [BrowserKitBookmarkNode],
                                  readingListItems: [BrowserKitReadingListNode]) -> [BookmarkOrFolder] {
        BrowserKitBookmarkTreeBuilder().build(bookmarks: bookmarks,
                                              readingListItems: readingListItems)
    }

    private func logRawIncomingBookmark(_ bookmark: BrowserKitBookmarkNode, at index: Int) {
#if DEBUG
        let parentIdentifier = bookmark.parentIdentifier ?? "nil"
        let urlString = bookmark.url?.absoluteString ?? "nil"
        Logger.general.debug(
            """
            BrowserKit raw bookmark: idx=\(index, privacy: .public), id=\(bookmark.identifier, privacy: .public), parent=\(parentIdentifier, privacy: .public), is-folder=\(bookmark.isFolder, privacy: .public), title=\(bookmark.title, privacy: .private), url=\(urlString, privacy: .private)
            """
        )
#endif
    }

    private func logRawIncomingReadingListItem(_ readingListItem: BrowserKitReadingListNode, at index: Int) {
#if DEBUG
        Logger.general.debug(
            """
            BrowserKit raw reading-list: idx=\(index, privacy: .public), title=\(readingListItem.title, privacy: .private), url=\(readingListItem.url.absoluteString, privacy: .private)
            """
        )
#endif
    }
}
