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
                Logger.bookmarks.debug("Received BrowserKit import request")

                let importedData = try await importSupportedData(token: token)

                let bookmarks = createBookmarksForImport(bookmarks: importedData.bookmarks,
                                                         readingListItems: importedData.readingListItems)
                let bookmarksSummary = try await bookmarkImporter.importBookmarks(bookmarks)
                let summary = createSummary(from: bookmarksSummary)

                await MainActor.run {
                    self.onImportResult(.success(summary))
                }
            } catch is CancellationError {
                Logger.bookmarks.debug("BrowserKit import request cancelled")
            } catch {
                Logger.bookmarks.error("BrowserKit import failed: \(error.localizedDescription, privacy: .public)")
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
        var streamIndex = 0
        var folderCount = 0
        var bookmarkCount = 0
        var bookmarkWithParentCount = 0
        var readingListCount = 0
        var unsupportedCount = 0

        for try await browserData in browserDataImportManager.importBrowserData(token: token) {
            switch browserData {
            case .bookmark(let bookmark):
                importedData.bookmarks.append(bookmark)
                if bookmark.isFolder {
                    folderCount += 1
                } else {
                    bookmarkCount += 1
                }
                if bookmark.parentIdentifier != nil {
                    bookmarkWithParentCount += 1
                }
                Logger.bookmarks.debug(
                    "BrowserKit raw bookmark: idx=\(streamIndex, privacy: .public), id=\(bookmark.identifier, privacy: .private), parent=\(bookmark.parentIdentifier ?? "nil", privacy: .private), is-folder=\(bookmark.isFolder, privacy: .public), title=\(bookmark.title, privacy: .private), url=\(bookmark.url?.absoluteString ?? "nil", privacy: .private)"
                )
            case .readingListItem(let readingListItem):
                importedData.readingListItems.append(readingListItem)
                readingListCount += 1
                Logger.bookmarks.debug(
                    "BrowserKit raw reading-list-item: idx=\(streamIndex, privacy: .public), title=\(readingListItem.title, privacy: .private), url=\(readingListItem.url.absoluteString, privacy: .private)"
                )
            case .unsupported(let typeName):
                unsupportedCount += 1
                Logger.bookmarks.debug("Skipping unsupported BrowserKit data type: type=\(typeName, privacy: .public)")
            }
            streamIndex += 1
        }

        Logger.bookmarks.debug(
            "BrowserKit import payload: folders=\(folderCount, privacy: .public), bookmarks=\(bookmarkCount, privacy: .public), with-parent=\(bookmarkWithParentCount, privacy: .public), reading-list=\(readingListCount, privacy: .public), unsupported=\(unsupportedCount, privacy: .public)"
        )

        return importedData
    }

    func createBookmarksForImport(bookmarks: [BrowserKitBookmarkNode],
                                  readingListItems: [BrowserKitReadingListNode]) -> [BookmarkOrFolder] {
        let tree = BrowserKitBookmarkTreeBuilder().build(bookmarks: bookmarks,
                                                         readingListItems: readingListItems)
        Logger.bookmarks.debug("BrowserKit import tree output: roots=\(tree.count, privacy: .public)")
        return tree
    }
}
