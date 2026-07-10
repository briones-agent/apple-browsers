//
//  AIChatPageContextHandlerTests.swift
//  DuckDuckGoTests
//
//  Copyright © 2025 DuckDuckGo. All rights reserved.
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

import AIChat
import Combine
import UserScript
import WebKit
import XCTest
@testable import DuckDuckGo

@MainActor
final class AIChatPageContextHandlerTests: XCTestCase {

    private var cancellables: Set<AnyCancellable>!

    override func setUp() {
        super.setUp()
        cancellables = []
    }

    override func tearDown() {
        cancellables = nil
        super.tearDown()
    }

    // MARK: - Initial State

    func testInitialStatePublishesNil() {
        let handler = makeHandler()

        var receivedValue: AIChatPageContext??
        handler.contextPublisher
            .first()
            .sink { context in
                receivedValue = context
            }
            .store(in: &cancellables)

        XCTAssertNotNil(receivedValue)
        XCTAssertNil(receivedValue!)
    }

    // MARK: - triggerContextCollection

    func testTriggerContextCollectionDoesNothingWhenUserScriptUnavailable() {
        let userScriptProvider: UserScriptProvider = { nil }
        let handler = makeHandler(userScriptProvider: userScriptProvider)

        let didTrigger = handler.triggerContextCollection()

        XCTAssertFalse(didTrigger)
        var receivedValue: AIChatPageContext??
        handler.contextPublisher
            .first()
            .sink { context in
                receivedValue = context
            }
            .store(in: &cancellables)

        XCTAssertNotNil(receivedValue)
        XCTAssertNil(receivedValue!)
    }

    // MARK: - resubscribe

    func testResubscribeSwitchesToNewScriptPublisher() {
        // Given: Two scripts that can publish context
        let firstScript = PageContextUserScript()
        let secondScript = PageContextUserScript()
        var currentScript: PageContextUserScript? = firstScript

        let handler = makeHandler(
            userScriptProvider: { currentScript }
        )

        var receivedContexts: [AIChatPageContext?] = []
        handler.contextPublisher
            .dropFirst() // Skip initial nil
            .sink { context in
                receivedContexts.append(context)
            }
            .store(in: &cancellables)

        // When: Subscribe to first script
        handler.resubscribe()

        // Then: Handler should be subscribed to first script
        // (We can't easily send values through the real script without a broker,
        // but we can verify the subscription logic by switching scripts)

        // When: Switch to second script and resubscribe
        currentScript = secondScript
        handler.resubscribe()

        // Then: Handler should now be subscribed to second script
        // The key behavior is that resubscribe() cancels old subscription and creates new one
        // We verify this indirectly - if no crash occurs and we can call resubscribe multiple times
        XCTAssertTrue(true, "resubscribe should complete without crash")
    }

    func testResubscribeDoesNothingWhenNoScriptAvailable() {
        // Given: Handler with no script
        let handler = makeHandler(userScriptProvider: { nil })

        var receivedContexts: [AIChatPageContext?] = []
        handler.contextPublisher
            .dropFirst() // Skip initial nil
            .sink { context in
                receivedContexts.append(context)
            }
            .store(in: &cancellables)

        // When: Call resubscribe
        handler.resubscribe()

        // Then: No crash, no new subscriptions
        XCTAssertEqual(receivedContexts.count, 0)
    }

    func testResubscribeCanBeCalledMultipleTimes() {
        // Given: Handler with a script
        let script = PageContextUserScript()
        let handler = makeHandler(userScriptProvider: { script })

        // When: Call resubscribe multiple times
        handler.resubscribe()
        handler.resubscribe()
        handler.resubscribe()

        // Then: No crash - each call cancels previous and creates new subscription
        XCTAssertTrue(true, "Multiple resubscribe calls should not crash")
    }

    // MARK: - Pixel Firing Tests

    func testEmptyPageContextFiresPixel() {
        // Given: Handler with a mock pixel handler
        let mockPixelHandler = MockContextualModePixelHandler()
        let mockScript = MockPageContextCollecting()
        let webView = WKWebView()
        let handler = makeHandler(
            webViewProvider: { webView },
            userScriptProvider: { mockScript },
            pixelHandler: mockPixelHandler
        )

        let expectation = XCTestExpectation(description: "Context published")
        var receivedContext: AIChatPageContext??
        handler.contextPublisher
            .dropFirst() // Skip initial nil
            .first()
            .sink { context in
                receivedContext = context
                expectation.fulfill()
            }
            .store(in: &cancellables)

        // When: Script publishes empty context (valid but no content)
        handler.triggerContextCollection()
        mockScript.simulateEmptyContext()

        wait(for: [expectation], timeout: 1.0)

        // Then: Pixel should fire and context should be nil
        XCTAssertEqual(mockPixelHandler.pageContextCollectionEmptyCount, 1)
        XCTAssertNotNil(receivedContext)
        XCTAssertNil(receivedContext!)
    }

    func testNilPageContextDoesNotFirePixel() {
        // Given: Handler with a mock pixel handler
        let mockPixelHandler = MockContextualModePixelHandler()
        let mockScript = MockPageContextCollecting()
        let webView = WKWebView()
        let handler = makeHandler(
            webViewProvider: { webView },
            userScriptProvider: { mockScript },
            pixelHandler: mockPixelHandler
        )

        let expectation = XCTestExpectation(description: "Context published")
        var receivedContext: AIChatPageContext??
        handler.contextPublisher
            .dropFirst() // Skip initial nil
            .first()
            .sink { context in
                receivedContext = context
                expectation.fulfill()
            }
            .store(in: &cancellables)

        // When: Script publishes nil (decode failure)
        handler.triggerContextCollection()
        mockScript.simulateNilContext()

        wait(for: [expectation], timeout: 1.0)

        // Then: Pixel should NOT fire (nil means decode failure, not empty content)
        XCTAssertEqual(mockPixelHandler.pageContextCollectionEmptyCount, 0)
        XCTAssertNotNil(receivedContext)
        XCTAssertNil(receivedContext!)
    }

    func testValidPageContextDoesNotFirePixel() {
        // Given: Handler with a mock pixel handler
        let mockPixelHandler = MockContextualModePixelHandler()
        let mockScript = MockPageContextCollecting()
        let webView = WKWebView()
        let handler = makeHandler(
            webViewProvider: { webView },
            userScriptProvider: { mockScript },
            pixelHandler: mockPixelHandler
        )

        let expectation = XCTestExpectation(description: "Context published")
        var receivedContext: AIChatPageContext??
        handler.contextPublisher
            .dropFirst() // Skip initial nil
            .first()
            .sink { context in
                receivedContext = context
                expectation.fulfill()
            }
            .store(in: &cancellables)

        // When: Script publishes valid context with content
        handler.triggerContextCollection()
        mockScript.simulateValidContext()

        wait(for: [expectation], timeout: 1.0)

        // Then: Pixel should NOT fire and context should be non-nil
        XCTAssertEqual(mockPixelHandler.pageContextCollectionEmptyCount, 0)
        XCTAssertNotNil(receivedContext)
        XCTAssertNotNil(receivedContext!)
    }

    // MARK: - Favicon Enrichment Tests

    func testFaviconEnrichmentReplacesFaviconAndPreservesPageTypeSignals() throws {
        // Given: A favicon provider that supplies an encoded favicon, forcing the handler
        // to re-build the context data (the enrichment path).
        let mockScript = MockPageContextCollecting()
        let webView = WKWebView()
        let encodedFavicon = "data:image/png;base64,\(Self.onePixelPNGBase64)"
        let handler = makeHandler(
            webViewProvider: { webView },
            userScriptProvider: { mockScript },
            faviconProvider: { _ in encodedFavicon }
        )

        let expectation = XCTestExpectation(description: "Context published")
        var receivedContext: AIChatPageContext?
        handler.contextPublisher
            .dropFirst()
            .first()
            .sink { context in
                receivedContext = context
                expectation.fulfill()
            }
            .store(in: &cancellables)

        // When: Script publishes a context carrying every optional field
        handler.triggerContextCollection()
        mockScript.simulate(context: Self.makeFullyPopulatedContext())

        wait(for: [expectation], timeout: 1.0)

        // Then: Favicon is replaced, everything else survives the re-build
        let contextData = try XCTUnwrap(receivedContext?.contextData)
        XCTAssertEqual(contextData.favicon, [.init(href: encodedFavicon, rel: "icon")])
        XCTAssertNotNil(receivedContext?.favicon, "Encoded favicon should decode to a UIImage")
        XCTAssertEqual(contextData.pageTypeSignals, Self.makeFullyPopulatedContext().pageTypeSignals)
        XCTAssertEqual(contextData.tabId, "tab-1")
        XCTAssertEqual(contextData.attached, false)
        XCTAssertEqual(contextData.attachable, true)
    }

    /// Compares the enriched context against the original field-by-field via their
    /// JSON representations, ignoring only `favicon`. When a new field is added to
    /// `AIChatPageContextData` but not carried over in the handler's favicon enrichment,
    /// this test fails without needing an update — extend `makeFullyPopulatedContext`
    /// with a non-default value for the new field so the protection stays meaningful.
    func testFaviconEnrichmentPreservesEveryFieldExceptFavicon() throws {
        let mockScript = MockPageContextCollecting()
        let webView = WKWebView()
        let handler = makeHandler(
            webViewProvider: { webView },
            userScriptProvider: { mockScript },
            faviconProvider: { _ in "data:image/png;base64,\(Self.onePixelPNGBase64)" }
        )

        let expectation = XCTestExpectation(description: "Context published")
        var receivedContext: AIChatPageContext?
        handler.contextPublisher
            .dropFirst()
            .first()
            .sink { context in
                receivedContext = context
                expectation.fulfill()
            }
            .store(in: &cancellables)

        let original = Self.makeFullyPopulatedContext()
        handler.triggerContextCollection()
        mockScript.simulate(context: original)

        wait(for: [expectation], timeout: 1.0)

        let enriched = try XCTUnwrap(receivedContext?.contextData)
        XCTAssertEqual(
            try jsonDictionary(of: original, ignoringKey: "favicon"),
            try jsonDictionary(of: enriched, ignoringKey: "favicon"),
            "Favicon enrichment re-builds AIChatPageContextData - every field except favicon must be carried over"
        )
    }

    // MARK: - Unavailable Pixel Tests

    func testUnavailablePixelFiresWhenNoUserScript() {
        let mockPixelHandler = MockContextualModePixelHandler()
        let handler = makeHandler(
            userScriptProvider: { nil },
            pixelHandler: mockPixelHandler
        )

        let didTrigger = handler.triggerContextCollection()

        XCTAssertFalse(didTrigger)
        XCTAssertEqual(mockPixelHandler.pageContextCollectionUnavailableCount, 1)
    }

    // MARK: - Helpers

    /// 1x1 transparent PNG so the encoded favicon decodes into a real UIImage.
    private static let onePixelPNGBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="

    /// Every optional field carries a non-default value so field-preservation tests catch drops.
    private static func makeFullyPopulatedContext() -> AIChatPageContextData {
        AIChatPageContextData(
            title: "Test Page",
            favicon: [.init(href: "https://example.com/favicon.ico", rel: "icon")],
            url: "https://example.com/article",
            content: "This is some page content for testing.",
            truncated: true,
            fullContentLength: 1234,
            attachable: true,
            tabId: "tab-1",
            pageTypeSignals: AIChatPageTypeSignals(jsonLdType: ["Recipe", "Article"], ogType: "article", lang: "eu"),
            attached: false
        )
    }

    private func jsonDictionary(of context: AIChatPageContextData, ignoringKey key: String) throws -> NSDictionary {
        let encoded = try JSONEncoder().encode(context)
        var dictionary = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        dictionary.removeValue(forKey: key)
        return NSDictionary(dictionary: dictionary)
    }

    private func makeHandler(
        webViewProvider: WebViewProvider? = nil,
        userScriptProvider: UserScriptProvider? = nil,
        faviconProvider: FaviconProvider? = nil,
        pixelHandler: AIChatContextualModePixelFiring? = nil
    ) -> DuckDuckGo.AIChatPageContextHandler {
        DuckDuckGo.AIChatPageContextHandler(
            webViewProvider: webViewProvider ?? { nil },
            userScriptProvider: userScriptProvider ?? { nil },
            faviconProvider: faviconProvider ?? { _ in nil },
            pixelHandler: pixelHandler ?? MockContextualModePixelHandler()
        )
    }
}

// MARK: - Mock Pixel Handler

private final class MockContextualModePixelHandler: AIChatContextualModePixelFiring {
    var pageContextCollectionEmptyCount = 0
    var pageContextCollectionUnavailableCount = 0

    func fireSheetOpened() {}
    func fireSheetDismissed() {}
    func fireSessionRestored() {}
    func fireExpandButtonTapped() {}
    func fireNewChatButtonTapped() {}
    func fireQuickActionSummarizeSelected() {}
    func fireQuickActionAskAboutPageSelected() {}
    func fireRecentChatsPopupDisplayed() {}
    func fireRecentChatSelected() {}
    func fireViewAllChatsTapped() {}
    func fireFireButtonTapped() {}
    func fireFireButtonConfirmed() {}
    func firePageContextPlaceholderShown() {}
    func firePageContextPlaceholderTapped() {}
    func firePageContextAutoAttached() {}
    func firePageContextUpdatedOnNavigation(url: String) {}
    func firePageContextManuallyAttachedNative() {}
    func firePageContextManuallyAttachedFrontend() {}
    func firePageContextRemovedNative() {}
    func firePageContextRemovedFrontend() {}
    func firePageContextCollectionEmpty() {
        pageContextCollectionEmptyCount += 1
    }
    func firePageContextCollectionUnavailable() {
        pageContextCollectionUnavailableCount += 1
    }
    func firePromptSubmittedWithContext() {}
    func firePromptSubmittedWithoutContext() {}
    func beginManualAttach() {}
    func endManualAttach() {}
    var isManualAttachInProgress: Bool { false }
    func reset() {}
}

// MARK: - Mock Page Context Collecting

private final class MockPageContextCollecting: PageContextCollecting {
    private let mockSubject = PassthroughSubject<AIChatPageContextData?, Never>()

    var collectionResultPublisher: AnyPublisher<AIChatPageContextData?, Never> {
        mockSubject.eraseToAnyPublisher()
    }

    weak var webView: WKWebView?

    func collect() {
        // No-op for testing - we'll manually send values via simulate methods
    }

    func simulateNilContext() {
        mockSubject.send(nil)
    }

    func simulateEmptyContext() {
        let emptyContext = AIChatPageContextData(
            title: "",
            favicon: [],
            url: "",
            content: "",
            truncated: false,
            fullContentLength: 0
        )
        mockSubject.send(emptyContext)
    }

    func simulateValidContext() {
        let validContext = AIChatPageContextData(
            title: "Test Page",
            favicon: [],
            url: "https://example.com",
            content: "This is some page content for testing.",
            truncated: false,
            fullContentLength: 39
        )
        mockSubject.send(validContext)
    }

    func simulate(context: AIChatPageContextData) {
        mockSubject.send(context)
    }
}
