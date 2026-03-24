//
//  AIChatStandaloneFloatingWindowController.swift
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
import WebKit

/// Owns the standalone floating duck.ai window and its WKWebView.
/// Not tab-backed — navigates duck.ai directly via URL.
final class AIChatStandaloneFloatingWindowController: NSWindowController {

    // MARK: - Constants

    private enum Constants {
        static let defaultSize = NSSize(width: 400, height: 600)
        static let frameUserDefaultsKey = "aiChatStandaloneFloatingWindowFrame"
    }

    // MARK: - Private

    private let webView: WKWebView
    private var currentURL: URL?

    // MARK: - Init

    init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.processPool = WKProcessPool()

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.translatesAutoresizingMaskIntoConstraints = false
        self.webView = wv

        let initialRect = NSRect(origin: .zero, size: Constants.defaultSize)
        let floatingWindow = AIChatStandaloneFloatingWindow(contentRect: initialRect)

        super.init(window: floatingWindow)

        let contentVC = NSViewController()
        contentVC.view = NSView()
        contentVC.view.addSubview(wv)
        NSLayoutConstraint.activate([
            wv.topAnchor.constraint(equalTo: contentVC.view.topAnchor),
            wv.leadingAnchor.constraint(equalTo: contentVC.view.leadingAnchor),
            wv.trailingAnchor.constraint(equalTo: contentVC.view.trailingAnchor),
            wv.bottomAnchor.constraint(equalTo: contentVC.view.bottomAnchor),
        ])
        floatingWindow.contentViewController = contentVC
        floatingWindow.delegate = self

        restoreFrameOrCenter()
    }

    required init?(coder: NSCoder) { nil }

    // MARK: - Public API

    /// Brings the window to front and navigates to the given URL.
    /// If the URL is already loaded, only brings the window to front.
    func open(url: URL) {
        window?.makeKeyAndOrderFront(nil)
        if url.absoluteString != currentURL?.absoluteString {
            currentURL = url
            webView.load(URLRequest(url: url))
        }
    }

    /// Hides the window without deallocating it. Frame is persisted.
    func hide() {
        persistFrame()
        window?.orderOut(nil)
    }

    // MARK: - Frame Persistence

    private func restoreFrameOrCenter() {
        if let stored = UserDefaults.standard.string(forKey: Constants.frameUserDefaultsKey) {
            let rect = NSRectFromString(stored)
            if rect != .zero {
                window?.setFrame(rect, display: false)
                return
            }
        }
        window?.center()
    }

    private func persistFrame() {
        guard let frame = window?.frame else { return }
        UserDefaults.standard.set(NSStringFromRect(frame), forKey: Constants.frameUserDefaultsKey)
    }
}

// MARK: - NSWindowDelegate

extension AIChatStandaloneFloatingWindowController: NSWindowDelegate {

    /// Intercept close (traffic light + ⌘W): hide instead of destroy.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }

    func windowWillClose(_ notification: Notification) {
        persistFrame()
    }
}
