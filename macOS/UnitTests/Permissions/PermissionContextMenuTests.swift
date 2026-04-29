//
//  PermissionContextMenuTests.swift
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

import AppKit
import FeatureFlags
import PrivacyConfig
import XCTest

@testable import DuckDuckGo_Privacy_Browser

/// Focused tests for `PermissionContextMenu`'s Fire Window suppression. The persistence
/// affordances ("Always allow", "Always deny", "Notify") must not appear in burner-tab
/// menus — showing them would invite the user to write into the global permission store
/// and break the Fire Window privacy promise.
final class PermissionContextMenuTests: XCTestCase {

    private var permissionManager: PermissionManagerMock!
    private var featureFlagger: MockFeatureFlagger!

    override func setUp() {
        super.setUp()
        permissionManager = PermissionManagerMock()
        featureFlagger = MockFeatureFlagger()
    }

    override func tearDown() {
        permissionManager = nil
        featureFlagger = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private var persistenceItemIdentifiers: Set<String> {
        ["PermissionContextMenu.alwaysAllow",
         "PermissionContextMenu.alwaysAsk",
         "PermissionContextMenu.alwaysDeny"]
    }

    private func persistenceItems(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.filter { item in
            guard let identifier = item.accessibilityIdentifier() else { return false }
            return persistenceItemIdentifiers.contains(identifier)
        }
    }

    // MARK: - Burner suppression

    /// In a Fire Window the persistence sub-menu (Always allow / Always deny / Notify)
    /// must not be added — there is nothing to "always" do because the window's state
    /// is burned on close.
    func testWhenBurnerWindowThenPersistenceItemsAreNotAdded() {
        let menu = PermissionContextMenu(
            permissionManager: permissionManager,
            permissions: [(.camera, .active)],
            domain: "example.com",
            delegate: nil,
            featureFlagger: featureFlagger,
            isBurnerWindow: true
        )

        XCTAssertTrue(persistenceItems(in: menu).isEmpty,
                      "Burner-tab menu must not show Always allow / Always deny / Notify. Items: \(menu.items.map { $0.title })")
    }

    /// Sanity: in a regular (non-burner) window the persistence items still appear, so
    /// the suppression is scoped correctly to Fire Windows.
    func testWhenNotBurnerThenPersistenceItemsAreAdded() {
        let menu = PermissionContextMenu(
            permissionManager: permissionManager,
            permissions: [(.camera, .active)],
            domain: "example.com",
            delegate: nil,
            featureFlagger: featureFlagger,
            isBurnerWindow: false
        )

        XCTAssertFalse(persistenceItems(in: menu).isEmpty,
                       "Regular menu should still offer Always allow / Always deny / Notify.")
    }

    /// Burner suppression also covers other persistence-supporting permission types
    /// (microphone, geolocation, notification). Spot-check microphone.
    func testWhenBurnerWindowThenMicrophonePersistenceItemsAreNotAdded() {
        let menu = PermissionContextMenu(
            permissionManager: permissionManager,
            permissions: [(.microphone, .active)],
            domain: "example.com",
            delegate: nil,
            featureFlagger: featureFlagger,
            isBurnerWindow: true
        )

        XCTAssertTrue(persistenceItems(in: menu).isEmpty)
    }
}
