//
//  MainViewController+AIChatHistorySidebar.swift
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
import Combine
import Foundation
import AppKit

extension MainViewController {

    /// Creates the history sidebar coordinator and wires it up.
    /// Call once from viewDidLoad, after aiChatCoordinator and browserTabViewController are ready.
    func setupAIChatHistorySidebar() {
        let historySidebarVC = AIChatHistorySidebarViewController()
        browserTabViewController.embedHistorySidebarViewController(historySidebarVC)

        let privacyConfig = NSApp.delegateTyped.privacyFeatures.contentBlocking.privacyConfigurationManager
        let suggestionsReader = AIChatSuggestionsReader(
            suggestionsReader: SuggestionsReader(featureFlagger: featureFlagger, privacyConfig: privacyConfig),
            historySettings: AIChatHistorySettings(privacyConfig: privacyConfig)
        )

        aiChatHistorySidebarCoordinator = AIChatHistorySidebarCoordinator(
            sidebarHost: browserTabViewController,
            aiChatCoordinator: aiChatCoordinator,
            suggestionsReader: suggestionsReader,
            aiChatTabOpener: NSApp.delegateTyped.aiChatTabOpener,
            viewModel: historySidebarVC.viewModel
        )

        // When AI Chat sidebar opens, close history sidebar immediately
        aiChatCoordinator.sidebarPresenceDidChangePublisher
            .filter { $0.isShown }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.aiChatHistorySidebarCoordinator?.closeSidebar(animated: false)
            }
            .store(in: &historySidebarCancellables)

        // Bind toolbar button active state
        aiChatHistorySidebarCoordinator?.$isSidebarOpen
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isOpen in
                self?.navigationBarViewController.updateAIChatHistoryButtonState(isActive: isOpen)
            }
            .store(in: &historySidebarCancellables)

        // Wire toolbar button closure
        navigationBarViewController.onAIChatHistoryButtonClicked = { [weak self] in
            self?.aiChatHistorySidebarCoordinator?.toggleSidebar()
        }
    }
}
