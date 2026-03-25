//
//  MaliciousSiteProtectionUITests.swift
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

import XCTest

@available(macOS 12.0, *)
final class MaliciousSiteProtectionUITests: UITestCase {

    private enum Predicates {
        static let alertPageHeaderPredicate = NSPredicate(format: "value CONTAINS[c] %@ OR label CONTAINS[c] %@", "warning", "risk")
        static let alertPageBodyPredicate = NSPredicate(format: "value CONTAINS[c] %@", "DuckDuckGo Scam Blocker")
        static let alertPagePredicates = NSCompoundPredicate(orPredicateWithSubpredicates: [alertPageHeaderPredicate, alertPageBodyPredicate])
    }

    private var app: XCUIApplication!
    private var addressBarTextField: XCUIElement!

    override class func setUp() {
        super.setUp()
        UITests.firstRun()
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication.setUp()
        app.enforceSingleWindow()
        addressBarTextField = app.windows.textFields["AddressBarViewController.addressBarTextField"]
    }

    override func tearDown() {
        super.tearDown()
        // Clean up any remaining windows
        app.typeKey("w", modifierFlags: [.command, .option, .shift])
    }

    // MARK: - Phishing Detection Tests

    func testPhishingNotDetected_SafeSiteLoads() throws {
        let url = URL(string: "http://privacy-test-pages.site/")!

        XCTAssertTrue(
            addressBarTextField.waitForExistence(timeout: UITests.Timeouts.elementExistence),
            "Address bar text field didn't become available in a reasonable timeframe."
        )

        addressBarTextField.typeURL(url)

        // Wait for the page to load
        XCTAssertTrue(
            app.windows.webViews.firstMatch.waitForExistence(timeout: UITests.Timeouts.elementExistence),
            "Safe site didn't load in a reasonable timeframe."
        )

        // Wait for page content to be ready
        let webView = app.windows.webViews.firstMatch
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true"),
            object: webView.children(matching: .any).firstMatch
        )
        wait(for: [expectation], timeout: UITests.Timeouts.elementExistence)

        // Verify no malicious site warning is shown
        let warningText = webView.staticTexts.containing(Predicates.alertPagePredicates).firstMatch
        XCTAssertFalse(
            warningText.exists,
            "Safe site should not show malicious site warnings"
        )

        // Focus the address bar first, then get its value
        app.typeKey("l", modifierFlags: [.command])
        // Verify address bar shows the correct URL
        let addressBarValue = addressBarTextField.value as? String ?? ""
        XCTAssertTrue(
            addressBarValue.contains("privacy-test-pages.site"),
            "Safe site should load normally with correct URL"
        )
    }

    func testPhishingDetected_SiteBlocked() throws {
        let url = URL(string: "http://privacy-test-pages.site/security/badware/phishing.html")!

        XCTAssertTrue(
            addressBarTextField.waitForExistence(timeout: UITests.Timeouts.elementExistence),
            "Address bar text field didn't become available in a reasonable timeframe."
        )

        addressBarTextField.typeURL(url)

        // Wait for either the page to load or a warning to appear
        let webView = app.windows.webViews.firstMatch
        XCTAssertTrue(
            webView.waitForExistence(timeout: UITests.Timeouts.elementExistence),
            "Web view should appear even if showing warning"
        )

        // Check for malicious site warning indicators
        let warningIndicators = [
            webView.staticTexts.containing(Predicates.alertPageHeaderPredicate).firstMatch,
            webView.staticTexts.containing(Predicates.alertPageBodyPredicate).firstMatch,
            webView.links.containing(.staticText, identifier: "Learn more").firstMatch,
            webView.buttons["Advanced..."].firstMatch,
            webView.buttons["Leave This Site"].firstMatch,
        ]

        XCTAssertTrue(
            warningIndicators.allSatisfy(\.exists),
            "Phishing site should show warning indicators"
        )

        // Focus the address bar first, then get its value
        app.typeKey("l", modifierFlags: [.command])
        // Verify the URL is related to phishing test
        let addressBarValue = addressBarTextField.value as? String ?? ""
        XCTAssertTrue(
            addressBarValue.contains("http://privacy-test-pages.site/security/badware/phishing.html"),
            "Address bar should show phishing test URL or related URL"
        )
    }

    func testPhishingDetectedThenSafeSite_WarningClears() throws {
        // First navigate to phishing site
        let phishingUrl = URL(string: "http://privacy-test-pages.site/security/badware/phishing.html")!

        XCTAssertTrue(
            addressBarTextField.waitForExistence(timeout: UITests.Timeouts.elementExistence),
            "Address bar text field didn't become available in a reasonable timeframe."
        )

        addressBarTextField.typeURL(phishingUrl)

        // Wait for web view to appear
        let webView = app.windows.webViews.firstMatch
        XCTAssertTrue(
            webView.waitForExistence(timeout: UITests.Timeouts.elementExistence),
            "Web view should appear"
        )

        // Wait for initial load to complete
        sleep(3)

        // Now navigate to safe site
        // Focus the address bar first, then get its value
        app.typeKey("l", modifierFlags: [.command])
        let safeUrl = URL(string: "http://broken.third-party.site/")!
        addressBarTextField.typeURL(safeUrl)

        // Wait for navigation to complete
        app.typeKey("l", modifierFlags: [.command])
        let navigationExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS 'broken.third-party.site'"),
            object: addressBarTextField
        )
        wait(for: [navigationExpectation], timeout: UITests.Timeouts.elementExistence)

        // Verify no warning indicators remain
        let warningText = webView.staticTexts.containing(Predicates.alertPagePredicates).firstMatch
        XCTAssertFalse(
            warningText.exists,
            "Warning should clear when navigating to safe site"
        )
    }

    func testPhishingDetectedThenDDG_WarningClears() throws {
        // First navigate to phishing site
        let phishingUrl = URL(string: "http://privacy-test-pages.site/security/badware/phishing.html")!

        XCTAssertTrue(
            addressBarTextField.waitForExistence(timeout: UITests.Timeouts.elementExistence),
            "Address bar text field didn't become available in a reasonable timeframe."
        )

        addressBarTextField.typeURL(phishingUrl)

        // Wait for web view to appear
        let webView = app.windows.webViews.firstMatch
        XCTAssertTrue(
            webView.waitForExistence(timeout: UITests.Timeouts.elementExistence),
            "Web view should appear"
        )

        // Wait for initial load to complete
        sleep(3)

        // Now navigate to safe site
        // Focus the address bar first, then get its value
        app.typeKey("l", modifierFlags: [.command])
        let ddgUrl = URL(string: "https://duckduckgo.com/")!
        addressBarTextField.typeURL(ddgUrl)

        // Wait for page finish loading
        sleep(3)

        // Wait for navigation to complete
        app.typeKey("l", modifierFlags: [.command])
        let navigationExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS 'duckduckgo.com'"),
            object: addressBarTextField
        )
        wait(for: [navigationExpectation], timeout: UITests.Timeouts.elementExistence)

        // Verify no warning indicators remain
        let warningText = webView.staticTexts.containing(Predicates.alertPagePredicates).firstMatch
        XCTAssertFalse(
            warningText.exists,
            "Warning should clear when navigating to DuckDuckGo"
        )
    }

    // MARK: - Malware Detection Tests

    func testMalwareDetected_SiteBlocked() throws {
        let url = URL(string: "http://privacy-test-pages.site/security/badware/malware.html")!

        XCTAssertTrue(
            addressBarTextField.waitForExistence(timeout: UITests.Timeouts.elementExistence),
            "Address bar text field didn't become available in a reasonable timeframe."
        )

        addressBarTextField.typeURL(url)

        // Wait for either the page to load or a warning to appear
        let webView = app.windows.webViews.firstMatch
        XCTAssertTrue(
            webView.waitForExistence(timeout: UITests.Timeouts.elementExistence),
            "Web view should appear even if showing warning"
        )

        // Check for malicious site warning indicators
        let warningIndicators = [
            webView.staticTexts.containing(Predicates.alertPageHeaderPredicate).firstMatch,
            webView.staticTexts.containing(Predicates.alertPageBodyPredicate).firstMatch,
            webView.links.containing(.staticText, identifier: "Learn more").firstMatch,
            webView.buttons["Advanced..."].firstMatch,
            webView.buttons["Leave This Site"].firstMatch,
        ]

        XCTAssertTrue(
            warningIndicators.allSatisfy(\.exists),
            "Phishing site should show warning indicators"
        )

        // Focus the address bar first, then get its value
        app.typeKey("l", modifierFlags: [.command])
        // Verify the URL is related to malware test
        let addressBarValue = addressBarTextField.value as? String ?? ""
        XCTAssertTrue(
            addressBarValue.contains("http://privacy-test-pages.site/security/badware/malware.html"),
            "Address bar should show malware test URL or related URL"
        )
    }

    func testMalwareDetectedThenSafeSite_WarningClears() throws {
        // First navigate to malware site
        let malwareUrl = URL(string: "http://privacy-test-pages.site/security/badware/malware.html")!

        XCTAssertTrue(
            addressBarTextField.waitForExistence(timeout: UITests.Timeouts.elementExistence),
            "Address bar text field didn't become available in a reasonable timeframe."
        )

        addressBarTextField.typeURL(malwareUrl)

        // Wait for web view to appear
        let webView = app.windows.webViews.firstMatch
        XCTAssertTrue(
            webView.waitForExistence(timeout: UITests.Timeouts.elementExistence),
            "Web view should appear"
        )

        // Wait for initial load to complete
        sleep(3)

        // Now navigate to safe site
        // Focus the address bar first, then get its value
        app.typeKey("l", modifierFlags: [.command])
        let safeUrl = URL(string: "http://broken.third-party.site/")!
        addressBarTextField.typeURL(safeUrl)

        // Wait for navigation to complete
        app.typeKey("l", modifierFlags: [.command])
        let navigationExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS 'broken.third-party.site'"),
            object: addressBarTextField
        )
        wait(for: [navigationExpectation], timeout: 10.0)

        // Verify no warning indicators remain
        let warningText = webView.staticTexts.containing(Predicates.alertPagePredicates).firstMatch
        XCTAssertFalse(
            warningText.exists,
            "Warning should clear when navigating to safe site"
        )
    }

    func testMalwareDetectedThenDDG_WarningClears() throws {
        // First navigate to malware site
        let malwareUrl = URL(string: "http://privacy-test-pages.site/security/badware/malware.html")!

        XCTAssertTrue(
            addressBarTextField.waitForExistence(timeout: UITests.Timeouts.elementExistence),
            "Address bar text field didn't become available in a reasonable timeframe."
        )

        addressBarTextField.typeURL(malwareUrl)

        // Wait for web view to appear
        let webView = app.windows.webViews.firstMatch
        XCTAssertTrue(
            webView.waitForExistence(timeout: UITests.Timeouts.elementExistence),
            "Web view should appear"
        )

        // Wait for initial load to complete
        sleep(3)

        // Now navigate to safe site
        // Focus the address bar first, then get its value
        app.typeKey("l", modifierFlags: [.command])
        let ddgUrl = URL(string: "https://duckduckgo.com/")!
        addressBarTextField.typeURL(ddgUrl)

        // Wait for page finish loading
        sleep(3)

        // Wait for navigation to complete
        app.typeKey("l", modifierFlags: [.command])
        let navigationExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS 'duckduckgo.com'"),
            object: addressBarTextField
        )
        wait(for: [navigationExpectation], timeout: 10.0)

        // Verify no warning indicators remain
        app.typeKey("l", modifierFlags: [.command])
        let warningText = webView.staticTexts.containing(Predicates.alertPagePredicates).firstMatch
        XCTAssertFalse(
            warningText.exists,
            "Warning should clear when navigating to DuckDuckGo"
        )
    }

    // MARK: - Scam Detection Tests

    func testScamDetected_SiteBlocked() throws {
        let url = URL(string: "http://privacy-test-pages.site/security/badware/scam.html")!

        XCTAssertTrue(
            addressBarTextField.waitForExistence(timeout: UITests.Timeouts.elementExistence),
            "Address bar text field didn't become available in a reasonable timeframe."
        )

        addressBarTextField.typeURL(url)

        // Wait for either the page to load or a warning to appear
        let webView = app.windows.webViews.firstMatch
        XCTAssertTrue(
            webView.waitForExistence(timeout: UITests.Timeouts.elementExistence),
            "Web view should appear even if showing warning"
        )

        // Check for malicious site warning indicators
        let warningIndicators = [
            webView.staticTexts.containing(Predicates.alertPageHeaderPredicate).firstMatch,
            webView.staticTexts.containing(Predicates.alertPageBodyPredicate).firstMatch,
            webView.links.containing(.staticText, identifier: "Learn more").firstMatch,
            webView.buttons["Advanced..."].firstMatch,
            webView.buttons["Leave This Site"].firstMatch,
        ]

        XCTAssertTrue(
            warningIndicators.allSatisfy(\.exists),
            "Phishing site should show warning indicators"
        )

        // Verify the URL is related to scam test
        app.typeKey("l", modifierFlags: [.command])
        let addressBarValue = addressBarTextField.value as? String ?? ""
        XCTAssertTrue(
            addressBarValue.contains("scam") || addressBarValue.contains("privacy-test-pages.site"),
            "Address bar should show scam test URL or related URL"
        )
    }

    func testScamDetectedThenSafeSite_WarningClears() throws {
        // First navigate to scam site
        let scamUrl = URL(string: "http://privacy-test-pages.site/security/badware/scam.html")!

        XCTAssertTrue(
            addressBarTextField.waitForExistence(timeout: UITests.Timeouts.elementExistence),
            "Address bar text field didn't become available in a reasonable timeframe."
        )

        addressBarTextField.typeURL(scamUrl)

        // Wait for web view to appear
        let webView = app.windows.webViews.firstMatch
        XCTAssertTrue(
            webView.waitForExistence(timeout: UITests.Timeouts.elementExistence),
            "Web view should appear"
        )

        // Wait for initial load to complete
        sleep(3)

        // Now navigate to safe site
        app.typeKey("l", modifierFlags: [.command])
        let safeUrl = URL(string: "http://broken.third-party.site/")!
        addressBarTextField.typeURL(safeUrl)

        // Wait for navigation to complete
        app.typeKey("l", modifierFlags: [.command])
        let navigationExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS 'broken.third-party.site'"),
            object: addressBarTextField
        )
        wait(for: [navigationExpectation], timeout: UITests.Timeouts.elementExistence)

        // Verify no warning indicators remain
        app.typeKey("l", modifierFlags: [.command])
        let warningText = webView.staticTexts.containing(Predicates.alertPagePredicates).firstMatch
        XCTAssertFalse(
            warningText.exists,
            "Warning should clear when navigating to safe site"
        )
    }

    // MARK: - General Protection Tests

    func testMaliciousSiteProtection_GeneralFunctionality() throws {
        // Test that the protection feature is working by visiting the main test page
        let url = URL(string: "http://privacy-test-pages.site/security/badware/")!

        XCTAssertTrue(
            addressBarTextField.waitForExistence(timeout: UITests.Timeouts.elementExistence),
            "Address bar text field didn't become available in a reasonable timeframe."
        )

        addressBarTextField.typeURL(url)

        // Wait for the page to load
        XCTAssertTrue(
            app.windows.webViews.firstMatch.waitForExistence(timeout: UITests.Timeouts.elementExistence),
            "Badware test page didn't load in a reasonable timeframe."
        )

        // Wait for page content to be ready
        let webView = app.windows.webViews.firstMatch
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true"),
            object: webView.children(matching: .any).firstMatch
        )
        wait(for: [expectation], timeout: UITests.Timeouts.elementExistence)

        // Verify page loaded successfully
        app.typeKey("l", modifierFlags: [.command])
        let finalURL = addressBarTextField.value as? String ?? ""
        XCTAssertTrue(
            finalURL.contains("privacy-test-pages.site/security/badware"),
            "Should successfully load badware test page"
        )

        // Look for test links indicating the protection feature test suite
        let testLinks = webView.links
        let hasTestLinks = testLinks.count > 0
        XCTAssertTrue(
            hasTestLinks,
            "Badware test page should contain test links"
        )
    }

}
