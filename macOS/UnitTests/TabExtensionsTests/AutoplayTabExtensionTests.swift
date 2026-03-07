//
//  AutoplayTabExtensionTests.swift
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

import Combine
import WebKit
import XCTest
@testable import DuckDuckGo_Privacy_Browser

// MARK: - Spy WebView

/// A WKWebView subclass that records reload() calls.
/// `WKWebView.configuration` returns a frozen copy after WebView creation — setters are
/// silently ignored.  The correct mode is applied once in `Tab.init`.  Tests therefore
/// assert on `configuredMode` (the extension's state-tracking) and `reloadCount`.
private final class SpyWKWebView: WKWebView {
    var reloadCount = 0

    @discardableResult
    override func reload() -> WKNavigation? {
        reloadCount += 1
        return nil
    }
}

// MARK: - Tests

@MainActor
final class AutoplayTabExtensionTests: XCTestCase {

    private func makePreferences(
        globalMode: AutoplayBlockingMode = .blockAudio,
        exceptions: [String: AutoplayBlockingMode] = [:]
    ) -> AutoplayPreferences {
        let persistor = AutoplayPreferencesPersistorMock(
            autoplayBlockingModeRawValue: globalMode.rawValue,
            autoplayExceptionsRawValue: exceptions.reduce(into: [:]) { $0[$1.key] = $1.value.rawValue }
        )
        return AutoplayPreferences(persistor: persistor)
    }

    private func makeExtension(preferences: AutoplayPreferences) -> AutoplayTabExtension {
        AutoplayTabExtension(autoplayPreferences: preferences,
                             webViewPublisher: PassthroughSubject<WKWebView, Never>().eraseToAnyPublisher())
    }

    // MARK: - updateConfig(for:reload:false) — simulates didStart (navigation in progress, no reload)
    // Note: `didStart(_ navigation:)` is not directly unit-tested because constructing
    // `Navigation` objects with `isForMainFrame` set is not supported in the test target.
    // The `updateConfig(for:reload:)` method is tested exhaustively here.
    // The `isForMainFrame` guard is verified via the UI/integration test suite.

    // MARK: - No change when modes match

    func testNoConfigChangeWhenEffectiveMatchesConfigured() {
        let prefs = makePreferences(globalMode: .blockAudio)
        let ext = makeExtension(preferences: prefs)
        let spy = SpyWKWebView()
        ext.webViewDidAppear(spy)

        ext.updateConfig(for: URL(string: "https://example.com")!, reload: false)

        XCTAssertEqual(ext.configuredMode, .blockAudio)
        XCTAssertEqual(spy.reloadCount, 0)
    }

    // MARK: - Applies exception on navigation (no reload — navigation handles page load)

    func testAppliesExceptionModeWhenNavigatingToExceptionDomain() {
        let prefs = makePreferences(globalMode: .blockAudio, exceptions: ["youtube.com": .allowAll])
        let ext = makeExtension(preferences: prefs)
        let spy = SpyWKWebView()
        ext.webViewDidAppear(spy)

        ext.updateConfig(for: URL(string: "https://youtube.com/watch?v=test")!, reload: false)

        XCTAssertEqual(ext.configuredMode, .allowAll)
        XCTAssertEqual(spy.reloadCount, 0) // no reload during navigation
    }

    func testAppliesExceptionForWWWSubdomain() {
        let prefs = makePreferences(globalMode: .blockAudio, exceptions: ["youtube.com": .allowAll])
        let ext = makeExtension(preferences: prefs)
        let spy = SpyWKWebView()
        ext.webViewDidAppear(spy)

        ext.updateConfig(for: URL(string: "https://www.youtube.com")!, reload: false)

        XCTAssertEqual(ext.configuredMode, .allowAll)
        XCTAssertEqual(spy.reloadCount, 0)
    }

    func testFallsBackToGlobalForNonExceptionDomain() {
        let prefs = makePreferences(globalMode: .blockAll, exceptions: ["other.com": .allowAll])
        let ext = makeExtension(preferences: prefs)
        let spy = SpyWKWebView()
        ext.webViewDidAppear(spy)

        ext.updateConfig(for: URL(string: "https://other.com")!, reload: false)
        XCTAssertEqual(ext.configuredMode, .allowAll)

        ext.updateConfig(for: URL(string: "https://youtube.com")!, reload: false)

        XCTAssertEqual(ext.configuredMode, .blockAll)
        XCTAssertEqual(spy.reloadCount, 0) // never reloads during navigation
    }

    // MARK: - No redundant config update on second navigation to same mode

    func testNoConfigChangeOnSecondNavigationToSameURL() {
        let prefs = makePreferences(globalMode: .blockAudio, exceptions: ["youtube.com": .allowAll])
        let ext = makeExtension(preferences: prefs)
        let spy = SpyWKWebView()
        ext.webViewDidAppear(spy)

        ext.updateConfig(for: URL(string: "https://youtube.com")!, reload: false)
        XCTAssertEqual(spy.reloadCount, 0)
        XCTAssertEqual(ext.configuredMode, .allowAll)

        ext.updateConfig(for: URL(string: "https://youtube.com")!, reload: false)

        XCTAssertEqual(spy.reloadCount, 0)
        XCTAssertEqual(ext.configuredMode, .allowAll)
    }

    // MARK: - Settings change while page is displayed (Combine path — does reload)

    func testExceptionAddedWhileOnDomainTriggersReload() {
        let prefs = makePreferences(globalMode: .blockAudio) // no exception yet
        let ext = makeExtension(preferences: prefs)
        let spy = SpyWKWebView()
        ext.webViewDidAppear(spy)

        // Simulate having navigated to youtube.com (sets configuredMode = .blockAudio)
        ext.updateConfig(for: URL(string: "https://youtube.com")!, reload: false)
        ext.currentURL = URL(string: "https://youtube.com")!
        XCTAssertEqual(spy.reloadCount, 0)
        XCTAssertEqual(ext.configuredMode, .blockAudio)

        // Add exception while page is displayed — Combine sink fires with reload: true
        let exp = expectation(description: "configuredMode updated to allowAll")
        var observer: AnyCancellable? = ext.$configuredMode
            .dropFirst()
            .sink { mode in
                if mode == .allowAll { exp.fulfill() }
            }

        prefs.exceptions["youtube.com"] = .allowAll
        waitForExpectations(timeout: 1)
        observer = nil

        XCTAssertEqual(spy.reloadCount, 1)
        XCTAssertEqual(ext.configuredMode, .allowAll)
    }

    func testGlobalModeChangeWhileOnNonExceptionDomainTriggersReload() {
        let prefs = makePreferences(globalMode: .blockAudio)
        let ext = makeExtension(preferences: prefs)
        let spy = SpyWKWebView()
        ext.webViewDidAppear(spy)

        ext.updateConfig(for: URL(string: "https://example.com")!, reload: false)
        ext.currentURL = URL(string: "https://example.com")!
        XCTAssertEqual(spy.reloadCount, 0)

        let exp = expectation(description: "configuredMode updated to blockAll")
        var observer: AnyCancellable? = ext.$configuredMode
            .dropFirst()
            .sink { mode in
                if mode == .blockAll { exp.fulfill() }
            }

        prefs.autoplayBlockingMode = .blockAll
        waitForExpectations(timeout: 1)
        observer = nil

        XCTAssertEqual(spy.reloadCount, 1)
        XCTAssertEqual(ext.configuredMode, .blockAll)
    }
}
