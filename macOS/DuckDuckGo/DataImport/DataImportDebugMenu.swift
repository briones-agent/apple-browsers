//
//  DataImportDebugMenu.swift
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

import AppKit

/// Debug-only overrides for the data import flow. Backed by UserDefaults so it persists across launches.
struct DataImportDebugSettings {

    /// When enabled, the macOS 27 data-directory access flow (the "Grant Access" folder picker) is forced for
    /// every browser regardless of the actual file permissions, so it can be exercised for testing.
    @UserDefaultsWrapper(key: .dataImportForceMacOS27PermissionsFix, defaultValue: false)
    var forcesMacOS27PermissionsFix: Bool

    init() {}
}

/// "Debug → Data Import" submenu.
final class DataImportDebugMenu: NSMenu, NSMenuDelegate {

    private var settings = DataImportDebugSettings()

    private let forcePermissionsFixMenuItem = NSMenuItem(
        title: "Force macOS 27 Permissions Fix",
        action: #selector(toggleForceMacOS27PermissionsFix)
    )

    override init(title: String) {
        super.init(title: title)
        self.delegate = self
        buildItems {
            forcePermissionsFixMenuItem.targetting(self)
        }
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        forcePermissionsFixMenuItem.state = settings.forcesMacOS27PermissionsFix ? .on : .off
    }

    @objc private func toggleForceMacOS27PermissionsFix(_ sender: NSMenuItem) {
        settings.forcesMacOS27PermissionsFix.toggle()
    }
}
