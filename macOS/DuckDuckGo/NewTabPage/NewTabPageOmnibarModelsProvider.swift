//
//  NewTabPageOmnibarModelsProvider.swift
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
import NewTabPage
import os.log
import Subscription

/// Fetches AI models from the duck.ai API and resolves access based on the user's local subscription tier.
final class NewTabPageOmnibarModelsProvider: NewTabPageOmnibarModelsProviding {

    private let modelsService: AIChatModelsProviding
    private let subscriptionManager: any SubscriptionManager

    init(
        modelsService: AIChatModelsProviding = AIChatModelsService(),
        subscriptionManager: any SubscriptionManager = Application.appDelegate.subscriptionManager
    ) {
        self.modelsService = modelsService
        self.subscriptionManager = subscriptionManager
    }

    func fetchAIModels() async -> [NewTabPageDataModel.AIModel] {
        do {
            let remoteModels = try await modelsService.fetchModels()
            let userTier = await resolveUserTier()
            return remoteModels.map { remoteModel in
                let hasAccess = remoteModel.accessTier.contains(userTier.rawValue)
                return NewTabPageDataModel.AIModel(
                    id: remoteModel.id,
                    name: remoteModel.name,
                    entityHasAccess: hasAccess
                )
            }
        } catch {
            Logger.aiChat.error("Failed to fetch models for NTP: \(error.localizedDescription)")
            return []
        }
    }

    private func resolveUserTier() async -> AIChatUserTier {
        do {
            let subscription = try await subscriptionManager.getSubscription(cachePolicy: .cacheFirst)
            guard subscription.isActive else { return .free }
            switch subscription.tier {
            case .plus: return .plus
            case .pro: return .pro
            case .none: return .free
            }
        } catch {
            return .free
        }
    }
}
