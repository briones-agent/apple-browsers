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
import Persistence
import WebKit

/// Owns the standalone floating duck.ai window and its WKWebView.
/// Not tab-backed — navigates duck.ai directly via URL.
@MainActor
final class AIChatStandaloneFloatingWindowController: NSWindowController {

    // MARK: - Constants

    private enum Constants {
        static let defaultSize = NSSize(width: 400, height: 600)
        static let frameUserDefaultsKey = "ai-chat.standalone-floating-window.frame"
    }

    // MARK: - Private

    private let webView: WKWebView
    private var currentURL: URL?
    private let keyValueStore: KeyValueStoring

    // MARK: - Init

    init(keyValueStore: KeyValueStoring) {
        self.keyValueStore = keyValueStore
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.processPool = WKProcessPool()

        let wv = WKWebView(frame: .zero, configuration: config)
        self.webView = wv

        let initialRect = NSRect(origin: .zero, size: Constants.defaultSize)
        let floatingWindow = AIChatStandaloneFloatingWindow(contentRect: initialRect)

        super.init(window: floatingWindow)

        floatingWindow.contentView = wv
        floatingWindow.delegate = self

        restoreFrameOrCenter()
    }

    required init?(coder: NSCoder) { nil }

    // MARK: - Public API

    /// Brings the window to front and navigates to the given URL.
    /// If the URL is already loaded, only brings the window to front.
    func open(url: URL) {
        window?.makeKeyAndOrderFront(nil)
        if url != currentURL {
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
        if let stored = (try? keyValueStore.object(forKey: Constants.frameUserDefaultsKey)) as? String {
            let rect = NSRectFromString(stored)
            if rect != .zero {
                let screen = NSScreen.main ?? NSScreen.screens.first
                if let visibleFrame = screen?.visibleFrame {
                    let w = max(1, min(rect.width, visibleFrame.width))
                    let h = max(1, min(rect.height, visibleFrame.height))
                    let x = max(visibleFrame.minX, min(rect.origin.x, visibleFrame.maxX - w))
                    let y = max(visibleFrame.minY, min(rect.origin.y, visibleFrame.maxY - h))
                    window?.setFrame(NSRect(x: x, y: y, width: w, height: h), display: false)
                } else {
                    window?.setFrame(rect, display: false)
                }
                return
            }
        }
        window?.center()
    }

    private func persistFrame() {
        guard let frame = window?.frame else { return }
        try? keyValueStore.set(NSStringFromRect(frame), forKey: Constants.frameUserDefaultsKey)
    }
}

// MARK: - NSWindowDelegate

extension AIChatStandaloneFloatingWindowController: NSWindowDelegate {

    /// Intercept close (traffic light + ⌘W): hide instead of destroy.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }

}
