//
//  UserScriptsDebugMenu.swift
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
import PrivacyConfig

/// Debug submenu for disabling individual user scripts per-tab or globally.
/// Per-tab changes filter scripts by debug name (session-only).
/// Global changes create a local privacy config override with the feature disabled (session-only).
@MainActor
final class UserScriptsDebugMenu: NSMenu, NSMenuDelegate {

    private let privacyConfigurationManager: PrivacyConfigurationManaging

    init(privacyConfigurationManager: PrivacyConfigurationManaging) {
        self.privacyConfigurationManager = privacyConfigurationManager
        super.init(title: "Disable Individual Scripts")
        self.delegate = self
        self.autoenablesItems = false
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    // MARK: - Menu Building

    private func rebuildMenu() {
        removeAllItems()

        // Per-tab section
        let scriptNames = currentTabScriptNames()
        addSectionHeader("[Current Tab]")
        if scriptNames.isEmpty {
            let item = NSMenuItem(title: "No scripts loaded", action: nil, keyEquivalent: "")
            item.isEnabled = false
            addItem(item)
        } else {
            for name in scriptNames {
                let item = makeScriptItem(name: name,
                                          action: #selector(togglePerTab(_:)),
                                          isDisabled: currentTabUserScripts()?.perTabDisabled.contains(name) ?? false)
                addItem(item)
            }
        }

        addItem(.separator())

        // Global section — ContentScope features via remote config override
        // Checked state comes from overriddenFeatures (not from the "state" field in the config JSON,
        // which is already patched to "disabled" for overridden features).
        addSectionHeader("[Global — ContentScope features]")
        for name in contentScopeFeatureNames() {
            let item = makeScriptItem(name: name,
                                      action: #selector(toggleGlobal(_:)),
                                      isDisabled: PrivacyConfigOverrideStore.shared.overriddenFeatures.contains(name))
            addItem(item)
        }
    }

    private func addSectionHeader(_ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        addItem(item)
    }

    private func makeScriptItem(name: String, action: Selector, isDisabled: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: name, action: action, keyEquivalent: "")
        item.representedObject = name
        item.target = self
        item.state = isDisabled ? .on : .off
        item.isEnabled = true
        return item
    }

    // MARK: - Helpers

    // trackerAllowlist/autoconsent: excluded by ContentScopePrivacyConfigurationJSONGenerator
    // macOSBrowserConfig/iOSBrowserConfig: native app feature flags, handled in Feature Flags debug menu
    private static let excludedFeatureKeys: Set<String> = [
        "trackerAllowlist",
        "autoconsent",
        "macOSBrowserConfig",
        "iOSBrowserConfig",
    ]

    private func contentScopeFeatureNames() -> [String] {
        guard let json = (try? JSONSerialization.jsonObject(with: privacyConfigurationManager.currentConfig)) as? [String: Any],
              let features = json["features"] as? [String: Any] else { return [] }
        return features.keys
            .filter { !Self.excludedFeatureKeys.contains($0) }
            .sorted()
    }

    private func currentTabUserScripts() -> UserScripts? {
        let tab = Application.appDelegate.windowControllersManager.selectedTab
        return tab?.userContentController?.contentBlockingAssets?.userScripts as? UserScripts
    }

    private func currentTabScriptNames() -> [String] {
        guard let scripts = currentTabUserScripts() else { return [] }
        return scripts.userScripts
            .map { $0.debugName }
            .sorted()
    }

    // MARK: - Actions

    @objc private func togglePerTab(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let tab = Application.appDelegate.windowControllersManager.selectedTab,
              let userScripts = tab.userContentController?.contentBlockingAssets?.userScripts as? UserScripts
        else { return }

        if userScripts.perTabDisabled.contains(name) {
            userScripts.perTabDisabled.remove(name)
        } else {
            userScripts.perTabDisabled.insert(name)
        }

        Task { @MainActor in
            await tab.userContentController?.reinstallUserScripts()
            tab.reload()
        }
    }

    @objc private func toggleGlobal(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }

        let store = PrivacyConfigOverrideStore.shared
        if store.overriddenFeatures.contains(name) {
            store.enableFeature(name, in: privacyConfigurationManager)
        } else {
            store.disableFeature(name, in: privacyConfigurationManager)
        }

        let allTabs = Application.appDelegate.windowControllersManager.mainWindowControllers
            .flatMap { wc -> [Tab] in
                let vm = wc.mainViewController.tabCollectionViewModel
                let regular = vm.tabCollection.tabs
                let pinned = vm.pinnedTabsCollection?.tabs ?? []
                return regular + pinned
            }

        Task { @MainActor in
            for tab in allTabs {
                await tab.userContentController?.reinstallUserScripts()
                tab.reload()
            }
        }
    }
}
