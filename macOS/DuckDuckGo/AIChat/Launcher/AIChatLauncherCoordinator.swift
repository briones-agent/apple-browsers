//
//  AIChatLauncherCoordinator.swift
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

import AIChat
import AppKit
import Combine

@MainActor
final class AIChatLauncherCoordinator: ObservableObject {

    // MARK: - Public State

    @Published private(set) var isLauncherOpen: Bool = false

    // MARK: - Dependencies

    private let floatingWindowCoordinator: AIChatStandaloneFloatingWindowCoordinator
    private let suggestionsReader: AIChatSuggestionsReading
    private let onSettingsRequested: () -> Void

    // MARK: - Private State

    private let viewModel = AIChatLauncherViewModel()
    private lazy var panel = AIChatLauncherPanel(viewModel: viewModel)

    private weak var parentWindow: NSWindow?
    private var dimView: NSView?
    private var keyEventMonitor: Any?
    private var fetchTask: Task<Void, Never>?

    // MARK: - Init

    init(
        floatingWindowCoordinator: AIChatStandaloneFloatingWindowCoordinator,
        suggestionsReader: AIChatSuggestionsReading,
        onSettingsRequested: @escaping () -> Void
    ) {
        self.floatingWindowCoordinator = floatingWindowCoordinator
        self.suggestionsReader = suggestionsReader
        self.onSettingsRequested = onSettingsRequested
        wireClosures()
    }

    // MARK: - Public API

    func toggleLauncher(from window: NSWindow) {
        if isLauncherOpen {
            closeLauncher()
        } else {
            openLauncher(from: window)
        }
    }

    func closeLauncher() {
        guard isLauncherOpen else { return }
        isLauncherOpen = false
        fetchTask?.cancel()
        fetchTask = nil
        unregisterResignKeyObserver()
        unregisterKeyMonitor()
        panel.orderOut(nil)
        removeDimOverlay()
        viewModel.reset()
    }

    /// Call when the parent browser window closes to release resources.
    func tearDown() {
        closeLauncher()
        suggestionsReader.tearDown()
    }

    // MARK: - Private: Open

    private func openLauncher(from window: NSWindow) {
        parentWindow = window
        isLauncherOpen = true
        viewModel.update(chats: [], isLoading: true)

        centerPanel(in: window)
        addDimOverlay(to: window)
        panel.makeKeyAndOrderFront(nil)

        registerResignKeyObserver()
        registerKeyMonitor()

        fetchTask = Task { [weak self] in
            await self?.fetchAndPublish()
        }
    }

    // MARK: - Private: Panel Positioning

    private func centerPanel(in window: NSWindow) {
        let panelSize = panel.frame.size
        let windowFrame = window.frame
        guard let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let screenFrame = screen.visibleFrame

        var x = windowFrame.midX - panelSize.width / 2
        var y = windowFrame.midY - panelSize.height / 2
        x = max(screenFrame.minX, min(x, screenFrame.maxX - panelSize.width))
        y = max(screenFrame.minY, min(y, screenFrame.maxY - panelSize.height))
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - Private: Dim Overlay

    private func addDimOverlay(to window: NSWindow) {
        guard let contentView = window.contentView else { return }
        let view = NSView(frame: contentView.bounds)
        view.autoresizingMask = [.width, .height]
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.3).cgColor
        view.alphaValue = 0
        contentView.addSubview(view, positioned: .above, relativeTo: nil)
        dimView = view
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            view.animator().alphaValue = 1
        }
    }

    private func removeDimOverlay() {
        guard let dim = dimView else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            dim.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            dim.removeFromSuperview()
            if self?.dimView === dim { self?.dimView = nil }
        })
    }

    // MARK: - Private: Event Monitor (⌘K)

    private func registerKeyMonitor() {
        unregisterKeyMonitor()
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // ⌘K while launcher is open: close it
            if event.charactersIgnoringModifiers == "k" &&
               event.modifierFlags.contains(.command) {
                self.closeLauncher()
                return nil
            }
            return event
        }
    }

    private func unregisterKeyMonitor() {
        if let monitor = keyEventMonitor {
            NSEvent.removeMonitor(monitor)
            keyEventMonitor = nil
        }
    }

    // MARK: - Private: Auto-Dismiss on Resign Key

    private func registerResignKeyObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(panelDidResignKey),
            name: NSWindow.didResignKeyNotification,
            object: panel
        )
    }

    private func unregisterResignKeyObserver() {
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didResignKeyNotification,
            object: panel
        )
    }

    @objc private func panelDidResignKey() {
        closeLauncher()
    }

    // MARK: - Private: Chat Fetch

    private func fetchAndPublish() async {
        let result = await suggestionsReader.fetchSuggestions(query: nil)
        guard !Task.isCancelled else { return }
        let all = (result.pinned + result.recent).sorted {
            ($0.timestamp ?? .distantPast) > ($1.timestamp ?? .distantPast)
        }
        viewModel.update(chats: all, isLoading: false)
    }

    // MARK: - Private: Closure Wiring

    private func wireClosures() {
        viewModel.onNewChat = { [weak self] in
            guard let self else { return }
            closeLauncher()
            floatingWindowCoordinator.openNewChat()
        }

        viewModel.onNewVoiceChat = { [weak self] in
            guard let self else { return }
            closeLauncher()
            floatingWindowCoordinator.openVoiceChat()
        }

        viewModel.onNewImageChat = { [weak self] in
            guard let self else { return }
            closeLauncher()
            floatingWindowCoordinator.openImageChat()
        }

        viewModel.onSettings = { [weak self] in
            guard let self else { return }
            closeLauncher()
            onSettingsRequested()
        }

        viewModel.onChatSelected = { [weak self] chatId in
            guard let self else { return }
            closeLauncher()
            floatingWindowCoordinator.openExistingChat(chatId: chatId)
        }

        viewModel.onDismiss = { [weak self] in
            self?.closeLauncher()
        }
    }
}
