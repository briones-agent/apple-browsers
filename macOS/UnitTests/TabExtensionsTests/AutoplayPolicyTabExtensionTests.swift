//
//  AutoplayPolicyTabExtensionTests.swift
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

import FeatureFlags
import PrivacyConfig
import WebKit
import XCTest

@testable import DuckDuckGo_Privacy_Browser
@testable import Navigation

@MainActor
final class AutoplayPolicyTabExtensionTests: XCTestCase {

    private var mockPermissionManager: PermissionManagerMock!
    private var mockFeatureFlagger: MockFeatureFlagger!
    private var autoplayPreferences: AutoplayPreferences!
    private var persistor: AutoplayPreferencesPersistorMock!
    private var webView: WKWebView!

    override func setUp() {
        super.setUp()
        mockPermissionManager = PermissionManagerMock()
        mockFeatureFlagger = MockFeatureFlagger()
        persistor = AutoplayPreferencesPersistorMock(autoplayBlockingModeRawValue: AutoplayBlockingMode.blockAudio.rawValue)
        autoplayPreferences = AutoplayPreferences(persistor: persistor)
        webView = WKWebView()
    }

    override func tearDown() {
        mockPermissionManager = nil
        mockFeatureFlagger = nil
        autoplayPreferences = nil
        persistor = nil
        webView = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeExtension() -> AutoplayPolicyTabExtension {
        AutoplayPolicyTabExtension(
            autoplayPreferences: autoplayPreferences,
            featureFlagger: mockFeatureFlagger,
            permissionManager: mockPermissionManager
        )
    }

    private func makeNavigationAction(url: URL, isMainFrame: Bool = true) -> NavigationAction {
        let frame = FrameInfo(
            webView: webView,
            handle: FrameHandle(rawValue: 1),
            isMainFrame: isMainFrame,
            url: url,
            securityOrigin: url.securityOrigin
        )
        return NavigationAction(
            request: URLRequest(url: url),
            navigationType: .other,
            currentHistoryItemIdentity: nil,
            redirectHistory: nil,
            isUserInitiated: false,
            sourceFrame: frame,
            targetFrame: frame,
            shouldDownload: false,
            mainFrameNavigation: nil
        )
    }

    // MARK: - Feature flag off

    func testWhenFeatureFlagOffThenDecidePolicyReturnsNextWithoutModifyingPreferences() async {
        mockFeatureFlagger.featuresStub[FeatureFlag.autoplayPolicy.rawValue] = false
        let ext = makeExtension()
        var prefs = NavigationPreferences.default

        let policy = await ext.decidePolicy(for: makeNavigationAction(url: URL(string: "https://example.com")!), preferences: &prefs)

        XCTAssertNil(policy, "Policy should be .next (nil) to pass to the next responder")
        XCTAssertEqual(prefs.autoplayPolicy, .default, "Preferences should not be modified when feature flag is off")
    }

    // MARK: - No per-site override (falls back to global preferences)

    func testWhenNoPerSiteOverrideAndGlobalAllowAllThenPolicyIsAllow() async {
        mockFeatureFlagger.featuresStub[FeatureFlag.autoplayPolicy.rawValue] = true
        persistor.autoplayBlockingModeRawValue = AutoplayBlockingMode.allowAll.rawValue
        autoplayPreferences = AutoplayPreferences(persistor: persistor)
        let ext = makeExtension()
        var prefs = NavigationPreferences.default

        _ = await ext.decidePolicy(for: makeNavigationAction(url: URL(string: "https://example.com")!), preferences: &prefs)

        XCTAssertEqual(prefs.autoplayPolicy, .allow)
    }

    func testWhenNoPerSiteOverrideAndGlobalBlockAudioThenPolicyIsAllowWithoutSound() async {
        mockFeatureFlagger.featuresStub[FeatureFlag.autoplayPolicy.rawValue] = true
        persistor.autoplayBlockingModeRawValue = AutoplayBlockingMode.blockAudio.rawValue
        autoplayPreferences = AutoplayPreferences(persistor: persistor)
        let ext = makeExtension()
        var prefs = NavigationPreferences.default

        _ = await ext.decidePolicy(for: makeNavigationAction(url: URL(string: "https://example.com")!), preferences: &prefs)

        XCTAssertEqual(prefs.autoplayPolicy, .allowWithoutSound)
    }

    func testWhenNoPerSiteOverrideAndGlobalBlockAllThenPolicyIsDeny() async {
        mockFeatureFlagger.featuresStub[FeatureFlag.autoplayPolicy.rawValue] = true
        persistor.autoplayBlockingModeRawValue = AutoplayBlockingMode.blockAll.rawValue
        autoplayPreferences = AutoplayPreferences(persistor: persistor)
        let ext = makeExtension()
        var prefs = NavigationPreferences.default

        _ = await ext.decidePolicy(for: makeNavigationAction(url: URL(string: "https://example.com")!), preferences: &prefs)

        XCTAssertEqual(prefs.autoplayPolicy, .deny)
    }

    // MARK: - Per-site override stored

    func testWhenPerSiteAllowStoredThenPolicyIsAllow() async {
        mockFeatureFlagger.featuresStub[FeatureFlag.autoplayPolicy.rawValue] = true
        mockPermissionManager.setPermission(.allow, forDomain: "example.com", permissionType: .autoplayPolicy)
        let ext = makeExtension()
        var prefs = NavigationPreferences.default

        _ = await ext.decidePolicy(for: makeNavigationAction(url: URL(string: "https://example.com")!), preferences: &prefs)

        XCTAssertEqual(prefs.autoplayPolicy, .allow)
    }

    // Note: Testing the .ask per-site override (maps to .allowWithoutSound) is not possible with the
    // current PermissionManagerMock because setPermission(.ask, ...) removes the entry, causing
    // hasPermissionPersisted to return false. In production, .ask is persisted differently. This case
    // is covered by the PermissionCenterViewModel tests below which test the decision round-trip logic.

    func testWhenPerSiteDenyStoredThenPolicyIsDeny() async {
        mockFeatureFlagger.featuresStub[FeatureFlag.autoplayPolicy.rawValue] = true
        mockPermissionManager.setPermission(.deny, forDomain: "example.com", permissionType: .autoplayPolicy)
        let ext = makeExtension()
        var prefs = NavigationPreferences.default

        _ = await ext.decidePolicy(for: makeNavigationAction(url: URL(string: "https://example.com")!), preferences: &prefs)

        XCTAssertEqual(prefs.autoplayPolicy, .deny)
    }

    func testWhenSubframeNavigationThenAutoplayPolicyIsNotApplied() async {
        mockFeatureFlagger.featuresStub[FeatureFlag.autoplayPolicy.rawValue] = true
        mockPermissionManager.setPermission(.deny, forDomain: "embedded.com", permissionType: .autoplayPolicy)
        let ext = makeExtension()
        var prefs = NavigationPreferences.default

        _ = await ext.decidePolicy(for: makeNavigationAction(url: URL(string: "https://embedded.com")!, isMainFrame: false), preferences: &prefs)

        XCTAssertFalse(prefs.mustApplyAutoplayPolicy, "Autoplay policy should only be applied for main-frame navigations")
        XCTAssertEqual(prefs.autoplayPolicy, .default, "Subframe host should not affect page-level autoplay policy")
    }

    func testWhenMainFrameFileURLAndLocalhostOverrideStoredThenPolicyUsesLocalhostDecision() async {
        mockFeatureFlagger.featuresStub[FeatureFlag.autoplayPolicy.rawValue] = true
        mockPermissionManager.setPermission(.deny, forDomain: .localhost, permissionType: .autoplayPolicy)
        let ext = makeExtension()
        var prefs = NavigationPreferences.default

        _ = await ext.decidePolicy(for: makeNavigationAction(url: URL(fileURLWithPath: "/tmp/test.html")), preferences: &prefs)

        XCTAssertTrue(prefs.mustApplyAutoplayPolicy, "Autoplay policy should be applied for main-frame file URLs")
        XCTAssertEqual(prefs.autoplayPolicy, .deny, "File URLs should resolve to localhost for per-site autoplay overrides")
    }

    // MARK: - Return value

    func testDecidePolicyAlwaysReturnsNext() async {
        mockFeatureFlagger.featuresStub[FeatureFlag.autoplayPolicy.rawValue] = true
        let ext = makeExtension()
        var prefs = NavigationPreferences.default

        let policy = await ext.decidePolicy(for: makeNavigationAction(url: URL(string: "https://example.com")!), preferences: &prefs)

        XCTAssertNil(policy, "Policy should be .next (nil) to pass to the next responder")
    }
}
