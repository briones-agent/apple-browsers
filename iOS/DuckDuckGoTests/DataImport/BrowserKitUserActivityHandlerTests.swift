//
//  BrowserKitUserActivityHandlerTests.swift
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
import BrowserKit
@testable import DuckDuckGo

final class BrowserKitUserActivityHandlerTests: XCTestCase {

    func testWhenActivityTypeDoesNotMatchThenHandleReturnsFalseAndDoesNotImport() {
        let importManager = MockBrowserKitImportManager()
        let sut = BrowserKitUserActivityHandler(browserKitImportManager: importManager)
        let activity = NSUserActivity(activityType: "com.duckduckgo.test.unrelated")

        let handled = sut.handle(activity)

        XCTAssertFalse(handled)
        XCTAssertEqual(importManager.receivedTokens, [])
    }

    func testWhenBrowserKitActivityHasNoImportTokenThenHandleReturnsFalse() {
        let importManager = MockBrowserKitImportManager()
        let sut = BrowserKitUserActivityHandler(browserKitImportManager: importManager)
        let activity = NSUserActivity(activityType: BrowserKitUserActivityHandler.activityType)

        let handled = sut.handle(activity)

        XCTAssertFalse(handled)
        XCTAssertEqual(importManager.receivedTokens, [])
    }

    func testWhenBrowserKitActivityHasImportTokenThenImportStarts() throws {
#if compiler(>=6.3)
        guard #available(iOS 26.4, *) else {
            throw XCTSkip("BrowserKit import token extraction requires iOS 26.4")
        }

        let importManager = MockBrowserKitImportManager()
        let sut = BrowserKitUserActivityHandler(browserKitImportManager: importManager)
        let token = UUID()
        let activity = makeBrowserKitActivity(with: token)

        let handled = sut.handle(activity)

        XCTAssertTrue(handled)
        XCTAssertEqual(importManager.receivedTokens, [token])
#else
        throw XCTSkip("Requires compiler 6.3")
#endif
    }

    func testWhenBrowserKitActivityIsDuplicateThenSecondRequestIsIgnored() throws {
#if compiler(>=6.3)
        guard #available(iOS 26.4, *) else {
            throw XCTSkip("BrowserKit import token extraction requires iOS 26.4")
        }

        let importManager = MockBrowserKitImportManager()
        let sut = BrowserKitUserActivityHandler(browserKitImportManager: importManager)
        let token = UUID()
        let activity = makeBrowserKitActivity(with: token)

        let firstHandled = sut.handle(activity)
        let secondHandled = sut.handle(activity)

        XCTAssertTrue(firstHandled)
        XCTAssertTrue(secondHandled)
        XCTAssertEqual(importManager.receivedTokens, [token])
#else
        throw XCTSkip("Requires compiler 6.3")
#endif
    }

    private func makeBrowserKitActivity(with token: UUID) -> NSUserActivity {
        let activity = NSUserActivity(activityType: BrowserKitUserActivityHandler.activityType)
#if compiler(>=6.3)
        if #available(iOS 26.4, *) {
            activity.userInfo = [BEBrowserDataImportManager.importTokenUserInfoKey: token]
        }
#endif
        return activity
    }
}

private final class MockBrowserKitImportManager: BrowserKitImportManaging {

    private(set) var receivedTokens: [UUID] = []

    func handleImportRequest(with token: UUID) {
        receivedTokens.append(token)
    }
}
