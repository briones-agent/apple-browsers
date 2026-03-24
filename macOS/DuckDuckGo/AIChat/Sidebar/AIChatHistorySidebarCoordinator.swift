//
//  AIChatHistorySidebarCoordinator.swift
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
final class AIChatHistorySidebarCoordinator {

    // MARK: - Constants

    private enum Constants {
        static let sidebarWidth: CGFloat = 260
        static let animationDuration: TimeInterval = 0.25
    }

    // MARK: - Public State

    @Published private(set) var isSidebarOpen: Bool = false

    // MARK: - Dependencies

    private let sidebarHost: AIChatHistorySidebarHosting
    private let suggestionsReader: AIChatSuggestionsReading
    private let aiChatTabOpener: AIChatTabOpening
    private let aiChatCoordinator: AIChatCoordinating

    // MARK: - Private State

    private let viewModel: AIChatHistorySidebarViewModel
    private var fetchTask: Task<Void, Never>?

    // MARK: - Init

    init(
        sidebarHost: AIChatHistorySidebarHosting,
        aiChatCoordinator: AIChatCoordinating,
        suggestionsReader: AIChatSuggestionsReading,
        aiChatTabOpener: AIChatTabOpening,
        viewModel: AIChatHistorySidebarViewModel
    ) {
        self.sidebarHost = sidebarHost
        self.aiChatCoordinator = aiChatCoordinator
        self.suggestionsReader = suggestionsReader
        self.aiChatTabOpener = aiChatTabOpener
        self.viewModel = viewModel

        wireClosures()
    }

    // MARK: - Public API

    func toggleSidebar() {
        if isSidebarOpen {
            closeSidebar(animated: true)
        } else {
            openSidebar()
        }
    }

    func closeSidebar(animated: Bool) {
        guard isSidebarOpen else { return }
        isSidebarOpen = false
        cancelFetch()

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Constants.animationDuration
                context.allowsImplicitAnimation = true
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                sidebarHost.historyContainerTrailingConstraint?.animator().constant = 0
            } completionHandler: { [weak self] in
                self?.clearViewModelState()
            }
        } else {
            sidebarHost.historyContainerTrailingConstraint?.constant = 0
            clearViewModelState()
        }
    }

    // MARK: - Private

    private func openSidebar() {
        // Close AI Chat sidebar if open (mutual exclusion)
        aiChatCoordinator.collapseSidebar(withAnimation: false)

        cancelFetch()
        viewModel.update(chats: [], isLoading: true)
        isSidebarOpen = true

        sidebarHost.historyContainerWidthConstraint?.constant = Constants.sidebarWidth

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Constants.animationDuration
            context.allowsImplicitAnimation = true
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            sidebarHost.historyContainerTrailingConstraint?.animator().constant = Constants.sidebarWidth
        }

        fetchTask = Task { [weak self] in
            await self?.fetchAndPublish()
        }
    }

    private func cancelFetch() {
        fetchTask?.cancel()
        fetchTask = nil
    }

    private func clearViewModelState() {
        viewModel.update(chats: [], isLoading: false)
    }

    private func fetchAndPublish() async {
        let result = await suggestionsReader.fetchSuggestions(query: nil)
        guard !Task.isCancelled else { return }

        let all = (result.pinned + result.recent).sorted {
            ($0.timestamp ?? .distantPast) > ($1.timestamp ?? .distantPast)
        }

        viewModel.update(chats: all, isLoading: false)
    }

    private func wireClosures() {
        viewModel.onClose = { [weak self] in
            self?.closeSidebar(animated: true)
        }

        viewModel.onChatSelected = { [weak self] chatId in
            self?.aiChatTabOpener.openAIChatTab(
                with: .existingChat(chatId: chatId),
                behavior: .currentTab
            )
        }

        viewModel.onNewChat = { [weak self] in
            self?.aiChatTabOpener.openAIChatTab(with: .newChat, behavior: .currentTab)
        }

        viewModel.onNewVoiceChat = { [weak self] in
            guard let self else { return }
            let url = buildModeURL(mode: AIChatURLParameters.voiceModeValue)
            aiChatTabOpener.openAIChatTab(with: .url(url), behavior: .currentTab)
        }

        viewModel.onNewImageChat = { [weak self] in
            guard let self else { return }
            let url = buildModeURL(mode: AIChatURLParameters.imageModeValue)
            aiChatTabOpener.openAIChatTab(with: .url(url), behavior: .currentTab)
        }

        viewModel.onSettings = { [weak self] in
            Application.appDelegate.windowControllersManager.showPreferencesTab(withSelectedPane: .aiChat)
        }
    }

    private func buildModeURL(mode: String) -> URL {
        let settings = AIChatRemoteSettings()
        guard var components = URLComponents(url: settings.aiChatURL, resolvingAgainstBaseURL: false) else {
            return settings.aiChatURL
        }
        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name == AIChatURLParameters.modeName }
        queryItems.append(URLQueryItem(name: AIChatURLParameters.modeName, value: mode))
        components.queryItems = queryItems
        return components.url ?? settings.aiChatURL
    }
}
