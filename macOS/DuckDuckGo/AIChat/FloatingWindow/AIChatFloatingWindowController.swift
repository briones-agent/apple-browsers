//
//  AIChatFloatingWindowController.swift
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
import Combine

@MainActor
protocol AIChatFloatingWindowControllerDelegate: AnyObject {
    /// The user closed the floating window (via close button or Escape).
    func floatingWindowDidClose(_ controller: AIChatFloatingWindowController)
    /// The user clicked the attach/dock button to reattach the sidebar.
    func floatingWindowDidRequestDock(_ controller: AIChatFloatingWindowController)
}

/// Manages a single detached AI Chat floating window for one tab.
///
/// Each instance owns one `AIChatFloatingWindow` and the
/// `AIChatSidebarViewController` that was moved out of the docked sidebar.
@MainActor
final class AIChatFloatingWindowController: NSObject {

    weak var delegate: AIChatFloatingWindowControllerDelegate?

    /// The tab this floating window is associated with.
    let tabID: TabIdentifier

    private let floatingWindow: AIChatFloatingWindow
    private var sidebarViewController: AIChatSidebarViewController?
    private var cancellables = Set<AnyCancellable>()

    var isShowing: Bool {
        floatingWindow.isVisible
    }

    init(tabID: TabIdentifier, sidebarViewController: AIChatSidebarViewController, contentRect: NSRect) {
        self.tabID = tabID
        self.sidebarViewController = sidebarViewController
        self.floatingWindow = AIChatFloatingWindow(contentRect: contentRect)
        super.init()

        embedSidebarViewController(sidebarViewController)

        NotificationCenter.default.publisher(for: NSWindow.willCloseNotification, object: floatingWindow)
            .sink { [weak self] _ in
                guard let self else { return }
                self.delegate?.floatingWindowDidClose(self)
            }
            .store(in: &cancellables)
    }

    func show() {
        floatingWindow.makeKeyAndOrderFront(nil)
    }

    func close() {
        floatingWindow.close()
    }

    /// Removes the sidebar view controller from the floating window so it can be
    /// re-embedded in the docked sidebar. Returns `nil` if already detached.
    func detachSidebarViewController() -> AIChatSidebarViewController? {
        guard let vc = sidebarViewController else { return nil }
        vc.view.removeFromSuperview()
        sidebarViewController = nil
        return vc
    }

    // MARK: - Private

    private func embedSidebarViewController(_ viewController: AIChatSidebarViewController) {
        guard let contentView = floatingWindow.contentView else { return }

        viewController.view.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(viewController.view)

        NSLayoutConstraint.activate([
            viewController.view.topAnchor.constraint(equalTo: contentView.topAnchor),
            viewController.view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            viewController.view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            viewController.view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
    }
}
