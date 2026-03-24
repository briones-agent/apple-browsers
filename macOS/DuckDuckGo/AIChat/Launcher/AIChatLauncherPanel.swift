//
//  AIChatLauncherPanel.swift
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
import SwiftUI

/// Activating NSPanel that hosts AIChatLauncherView.
/// Intercepts arrow keys and Esc for keyboard navigation.
final class AIChatLauncherPanel: NSPanel {

    private enum KeyCode {
        static let returnKey: UInt16 = 36
        static let escape: UInt16 = 53
        static let upArrow: UInt16 = 126
        static let downArrow: UInt16 = 125
    }

    private enum Constants {
        static let panelSize = NSSize(width: 340, height: 420)
    }

    private var hostingController: NSHostingController<AIChatLauncherView>!
    let viewModel: AIChatLauncherViewModel

    init(viewModel: AIChatLauncherViewModel) {
        self.viewModel = viewModel
        super.init(
            contentRect: NSRect(origin: .zero, size: Constants.panelSize),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovableByWindowBackground = false
        hasShadow = true
        level = .floating
        isReleasedWhenClosed = false

        hostingController = NSHostingController(rootView: AIChatLauncherView(viewModel: viewModel))
        contentViewController = hostingController
    }

    // MARK: - Keyboard Interception

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case KeyCode.downArrow:
            viewModel.moveSelectionDown()
        case KeyCode.upArrow:
            viewModel.moveSelectionUp()
        case KeyCode.returnKey:
            // Only fires if SwiftUI's .onSubmit didn't consume the event
            viewModel.activateSelection()
        case KeyCode.escape:
            viewModel.onDismiss?()
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - ⌘W: hide via dismiss

    override func performClose(_ sender: Any?) {
        viewModel.onDismiss?()
    }
}
