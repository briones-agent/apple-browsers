//
//  DataImportUserActivityHandlerTests.swift
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
final class DataImportUserActivityHandlerTests: XCTestCase {

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

    func testWhenActivityTypeIsNotBrowserKitThenHandleReturnsFalseWithoutDelegating() {
        let mockBrowserKitHandler = MockDataImportUserActivityHandler(result: true)
        let sut = makeSUT(browserKitUserActivityHandler: mockBrowserKitHandler)
        let activity = NSUserActivity(activityType: "com.duckduckgo.test.unrelated")

        let handled = sut.handle(activity)

        XCTAssertFalse(handled)
        XCTAssertEqual(mockBrowserKitHandler.handledActivityTypes, [])
    }

    func testWhenActivityTypeIsBrowserKitThenDelegatesToBrowserKitHandler() {
        let mockBrowserKitHandler = MockDataImportUserActivityHandler(result: true)
        let sut = makeSUT(browserKitUserActivityHandler: mockBrowserKitHandler)
        let activity = NSUserActivity(activityType: BrowserKitUserActivityHandler.activityType)

        let handled = sut.handle(activity)

        XCTAssertTrue(handled)
        XCTAssertEqual(mockBrowserKitHandler.handledActivityTypes, [BrowserKitUserActivityHandler.activityType])
    }

    func testWhenBrowserKitHandlerReturnsFalseThenHandleReturnsFalse() {
        let mockBrowserKitHandler = MockDataImportUserActivityHandler(result: false)
        let sut = makeSUT(browserKitUserActivityHandler: mockBrowserKitHandler)
        let activity = NSUserActivity(activityType: BrowserKitUserActivityHandler.activityType)

        let handled = sut.handle(activity)

        XCTAssertFalse(handled)
        XCTAssertEqual(mockBrowserKitHandler.handledActivityTypes, [BrowserKitUserActivityHandler.activityType])
    }

    private func makeSUT(browserKitUserActivityHandler: DataImportUserActivityHandling) -> DataImportUserActivityHandler {
        DataImportUserActivityHandler(dependencies: .init(bookmarksDatabase: database,
                                                          favoritesDisplayMode: .displayNative(.mobile)),
                                      onImportResult: { (_: Result<DataImportSummary, Error>) in },
                                      browserKitUserActivityHandler: browserKitUserActivityHandler)
    }
}

private final class MockDataImportUserActivityHandler: DataImportUserActivityHandling {

    private let result: Bool
    private(set) var handledActivityTypes: [String] = []

    init(result: Bool) {
        self.result = result
    }

    func handle(_ userActivity: NSUserActivity) -> Bool {
        handledActivityTypes.append(userActivity.activityType)
        return result
    }
}
