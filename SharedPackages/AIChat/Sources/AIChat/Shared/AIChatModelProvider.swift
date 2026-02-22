//
//  AIChatModelProvider.swift
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

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif
import DesignResourcesKitIcons

/// Represents an AI model available in the model picker.
public struct AIChatModel {
    public let id: String
    public let displayName: String
    public let shortDisplayName: String
    public let provider: ModelProvider
    public let tier: ModelTier

    public enum ModelProvider {
        case openAI
        case meta
        case anthropic
        case mistral
    }

    public enum ModelTier {
        case free
        case premium
    }

    public init(id: String, displayName: String, shortDisplayName: String, provider: ModelProvider, tier: ModelTier) {
        self.id = id
        self.displayName = displayName
        self.shortDisplayName = shortDisplayName
        self.provider = provider
        self.tier = tier
    }

    /// Returns a platform-appropriate icon for use in menu items.
    #if os(macOS)
    public var menuIcon: NSImage? {
        switch provider {
        case .openAI: return DesignSystemImages.Glyphs.Size16.aiModelOpenAI
        case .meta: return DesignSystemImages.Glyphs.Size16.aiModelLlama
        case .anthropic: return DesignSystemImages.Glyphs.Size16.aiModelClaude
        case .mistral: return DesignSystemImages.Glyphs.Size16.aiModelMistral
        }
    }
    #elseif os(iOS)
    public var menuIcon: UIImage? {
        switch provider {
        case .openAI: return DesignSystemImages.Glyphs.Size16.aiModelOpenAI
        case .meta: return DesignSystemImages.Glyphs.Size16.aiModelLlama
        case .anthropic: return DesignSystemImages.Glyphs.Size16.aiModelClaude
        case .mistral: return DesignSystemImages.Glyphs.Size16.aiModelMistral
        }
    }
    #endif
}

/// Provides mock model data for the AI model picker.
/// This will be replaced with data from the JS bridge once available.
public enum AIChatModelProvider {

    public static let defaultModel = freeModels[0]

    public static let freeModels: [AIChatModel] = [
        AIChatModel(id: "gpt-4o-mini", displayName: "GPT-4o mini", shortDisplayName: "4o mini", provider: .openAI, tier: .free),
        AIChatModel(id: "gpt-5-mini", displayName: "GPT-5 mini", shortDisplayName: "5 mini", provider: .openAI, tier: .free),
        AIChatModel(id: "openai/gpt-oss-120b", displayName: "GPT-OSS 120B", shortDisplayName: "OSS 120B", provider: .openAI, tier: .free),
        AIChatModel(id: "claude-haiku-4-5", displayName: "Claude 4.5 Haiku", shortDisplayName: "4.5 Haiku", provider: .anthropic, tier: .free),
        AIChatModel(id: "meta-llama/Llama-4-Maverick-17B-128E-Instruct-FP8", displayName: "Llama 4 Maverick", shortDisplayName: "4 Maverick", provider: .meta, tier: .free),
        AIChatModel(id: "mistralai/Mistral-Small-24B-Instruct-2501", displayName: "Mistral Small", shortDisplayName: "Small", provider: .mistral, tier: .free),
    ]

    public static let premiumModels: [AIChatModel] = [
        AIChatModel(id: "gpt-4o", displayName: "GPT-4o", shortDisplayName: "4o", provider: .openAI, tier: .premium),
        AIChatModel(id: "gpt-5.2", displayName: "GPT-5.2", shortDisplayName: "5.2", provider: .openAI, tier: .premium),
        AIChatModel(id: "claude-sonnet-4-5", displayName: "Claude 4.5 Sonnet", shortDisplayName: "4.5 Sonnet", provider: .anthropic, tier: .premium),
        AIChatModel(id: "claude-opus-4-5", displayName: "Claude Opus 4.5", shortDisplayName: "Opus 4.5", provider: .anthropic, tier: .premium),
    ]
}
