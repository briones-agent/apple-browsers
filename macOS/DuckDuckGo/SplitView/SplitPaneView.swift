//
//  SplitPaneView.swift
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

/// A container view for a single split pane.
/// Wraps a `WebViewContainerView` and draws a focus indicator when active.
final class SplitPaneView: NSView {

    let paneId: UUID
    private(set) var webViewContainer: WebViewContainerView?

    var isFocused: Bool = false {
        didSet {
            needsDisplay = true
        }
    }

    /// Called when the user clicks inside this pane.
    var onFocused: ((UUID) -> Void)?

    init(paneId: UUID) {
        self.paneId = paneId
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setWebViewContainer(_ container: WebViewContainerView) {
        webViewContainer?.removeFromSuperview()
        webViewContainer = container

        // WebViewContainerView uses autoresizing by default; switch to constraints for split layout
        container.autoresizingMask = []
        container.translatesAutoresizingMaskIntoConstraints = false
        addSubview(container)

        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: topAnchor),
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor),
            container.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    func removeWebViewContainer() {
        webViewContainer?.removeFromSuperview()
        webViewContainer = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        if isFocused {
            let borderRect = bounds.insetBy(dx: 0.5, dy: 0.5)
            let path = NSBezierPath(rect: borderRect)
            path.lineWidth = 2.0
            NSColor.controlAccentColor.withAlphaComponent(0.6).setStroke()
            path.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        onFocused?(paneId)
        super.mouseDown(with: event)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func becomeFirstResponder() -> Bool {
        onFocused?(paneId)
        return super.becomeFirstResponder()
    }
}
