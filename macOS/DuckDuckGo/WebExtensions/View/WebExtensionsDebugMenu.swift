//
//  WebExtensionsDebugMenu.swift
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
import OSLog
import WebExtensions

@available(macOS 15.4, *)
final class WebExtensionsDebugMenu: NSMenu {

    private let webExtensionManager: WebExtensionManaging

    private let installExtensionMenuItem = NSMenuItem(title: "Install web extension", action: nil)
    private let uninstallAllExtensionsMenuItem = NSMenuItem(title: "Uninstall all extensions", action: #selector(WebExtensionsDebugMenu.uninstallAllExtensions))
    private let openExtensionsFolderMenuItem = NSMenuItem(title: "Open Extensions Folder in Finder", action: #selector(WebExtensionsDebugMenu.openExtensionsFolderInFinder))

    init(webExtensionManager: WebExtensionManaging) {
        self.webExtensionManager = webExtensionManager
        super.init(title: "")

        installExtensionMenuItem.submenu = makeInstallSubmenu()
        installExtensionMenuItem.isEnabled = true
        uninstallAllExtensionsMenuItem.target = self
        uninstallAllExtensionsMenuItem.isEnabled = true
        openExtensionsFolderMenuItem.target = self
        openExtensionsFolderMenuItem.isEnabled = true

        addItems()
    }

    private func addItems() {
        removeAllItems()

        addItem(installExtensionMenuItem)
        addItem(uninstallAllExtensionsMenuItem)
        addItem(.separator())
        addItem(openExtensionsFolderMenuItem)

        if !webExtensionManager.webExtensionIdentifiers.isEmpty {
            addItem(.separator())
            for identifier in webExtensionManager.webExtensionIdentifiers {
                let name = webExtensionManager.extensionName(for: identifier)
                let version = webExtensionManager.extensionVersion(for: identifier)
                let extensionType = webExtensionManager.context(for: identifier)?.duckDuckGoWebExtensionType
                let menuItem = WebExtensionMenuItem(
                    identifier: identifier,
                    webExtensionName: name,
                    version: version,
                    extensionType: extensionType,
                    substitutionSubmenuProvider: makeSubstitutionSubmenu
                )
                self.addItem(menuItem)
            }
        }
    }

    private func makeInstallSubmenu() -> NSMenu {
        let submenu = NSMenu()

        let browseItem = NSMenuItem(title: "Other...", action: #selector(selectAndLoadWebExtension))
        browseItem.target = self
        submenu.addItem(browseItem)

        submenu.addItem(.separator())

        return submenu
    }

    private func makeSubstitutionSubmenu() -> NSMenu {
        let submenu = NSMenu()

        let catItem = NSMenuItem(title: "Change to cat", action: #selector(changeSubstitutionToCat))
        catItem.target = self
        submenu.addItem(catItem)

        let dogItem = NSMenuItem(title: "Change to dog", action: #selector(changeSubstitutionToDog))
        dogItem.target = self
        submenu.addItem(dogItem)

        return submenu
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func update() {
        super.update()

        addItems()

        installExtensionMenuItem.isEnabled = true
        uninstallAllExtensionsMenuItem.isEnabled = true
    }

    @objc func selectAndLoadWebExtension() {
        let panel = NSOpenPanel(allowedFileTypes: [.directory, .zip, .applicationExtension], directoryURL: .downloadsDirectory)
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        guard case .OK = panel.runModal(),
              let url = panel.url else { return }

        Task {
            try? await webExtensionManager.installExtension(from: url)
        }
    }

    @objc func uninstallAllExtensions() {
        webExtensionManager.uninstallAllExtensions()
    }

    @objc func openExtensionsFolderInFinder() {
        let path = webExtensionManager.extensionsDirectory.path
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    @objc func changeSubstitutionToCat() {
        swapEmojiMap(to: "emojiMap-cat.js")
    }

    @objc func changeSubstitutionToDog() {
        swapEmojiMap(to: "emojiMap-dog.js")
    }

    private func swapEmojiMap(to sourceFileName: String) {
        guard let installed = webExtensionManager.installedEmbeddedExtension(for: .substitution) else {
            Logger.webExtensions.error("Substitution extension not installed")
            return
        }

        guard let extensionPath = webExtensionManager.installedExtensionPath(for: .substitution) else {
            Logger.webExtensions.error("Substitution extension path not found")
            return
        }

        let emojiMapsFolder = extensionPath.appendingPathComponent("emoji-maps")
        let sourceFile = emojiMapsFolder.appendingPathComponent(sourceFileName)
        let destinationFile = extensionPath.appendingPathComponent("emojiMap.js")

        do {
            if FileManager.default.fileExists(atPath: destinationFile.path) {
                try FileManager.default.removeItem(at: destinationFile)
            }
            try FileManager.default.copyItem(at: sourceFile, to: destinationFile)
            Logger.webExtensions.info("Swapped emojiMap.js to \(sourceFileName)")

            Task {
                try await webExtensionManager.reloadExtension(identifier: installed.uniqueIdentifier)
                await Application.appDelegate.windowControllersManager.selectedTab?.reload()
            }
        } catch {
            Logger.webExtensions.error("Failed to swap emoji map: \(error.localizedDescription)")
        }
    }
}

@available(macOS 15.4, *)
final class WebExtensionMenuItem: NSMenuItem {

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    init(identifier: String,
         webExtensionName: String?,
         version: String?,
         extensionType: DuckDuckGoWebExtensionType?,
         substitutionSubmenuProvider: (() -> NSMenu)?) {
        let displayName = webExtensionName ?? identifier
        let title = version.map { "\(displayName) v\($0)" } ?? displayName
        super.init(title: title,
                   action: nil,
                   keyEquivalent: "")
        submenu = WebExtensionSubMenu(
            extensionIdentifier: identifier,
            extensionType: extensionType,
            substitutionSubmenuProvider: substitutionSubmenuProvider
        )
    }

}

@available(macOS 15.4, *)
final class WebExtensionSubMenu: NSMenu {

    private let extensionIdentifier: String

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    init(extensionIdentifier: String,
         extensionType: DuckDuckGoWebExtensionType?,
         substitutionSubmenuProvider: (() -> NSMenu)?) {
        self.extensionIdentifier = extensionIdentifier
        super.init(title: "")

        if extensionType == .substitution, let substitutionSubmenu = substitutionSubmenuProvider?() {
            for item in substitutionSubmenu.items {
                let itemCopy = item.copy() as! NSMenuItem
                addItem(itemCopy)
            }
            addItem(.separator())
        }

        let uninstallItem = NSMenuItem(title: "Remove the extension", action: #selector(uninstallExtension), keyEquivalent: "")
        uninstallItem.target = self
        addItem(uninstallItem)
    }

    @objc func uninstallExtension() {
        guard let webExtensionManager = NSApp.delegateTyped.webExtensionManager else {
            return
        }

        try? webExtensionManager.uninstallExtension(identifier: extensionIdentifier)
    }
}
