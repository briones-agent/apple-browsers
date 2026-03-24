//
//  AIChatHistorySidebarView.swift
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
import SwiftUI
import DesignResourcesKitIcons

struct AIChatHistorySidebarView: View {

    @ObservedObject var viewModel: AIChatHistorySidebarViewModel

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()
            actionRows
            chatsSection
            Spacer(minLength: 0)
            Divider()
            footerView
        }
        .background(Color(designSystemColor: .surfacePrimary))
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            Image(nsImage: DesignSystemImages.Glyphs.Size16.aiChat)
                .renderingMode(.template)
                .foregroundColor(.primary)
                .frame(width: 20, height: 20)
            Text(UserText.aiChatHistorySidebarTitle)
                .font(.headline)
            Spacer()
            CloseButton(action: { viewModel.onClose?() })
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Action Rows

    private var actionRows: some View {
        VStack(spacing: 0) {
            HoverRow(action: { viewModel.onNewChat?() }) {
                HStack(spacing: 8) {
                    Image(nsImage: DesignSystemImages.Glyphs.Size16.aiChatAdd)
                        .renderingMode(.template)
                        .frame(width: 16, height: 16)
                    Text(UserText.aiChatHistorySidebarNewChat)
                        .font(.body)
                    Spacer()
                }
            }
            HoverRow(action: { viewModel.onNewVoiceChat?() }) {
                HStack(spacing: 8) {
                    Image(nsImage: DesignSystemImages.Glyphs.Size16.permissionMicrophone)
                        .renderingMode(.template)
                        .frame(width: 16, height: 16)
                    Text(UserText.aiChatHistorySidebarNewVoiceChat)
                        .font(.body)
                    Spacer()
                }
            }
            HoverRow(action: { viewModel.onNewImageChat?() }) {
                HStack(spacing: 8) {
                    Image(nsImage: DesignSystemImages.Glyphs.Size16.image)
                        .renderingMode(.template)
                        .frame(width: 16, height: 16)
                    Text(UserText.aiChatHistorySidebarNewImage)
                        .font(.body)
                    Spacer()
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Chats Section

    private var chatsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(UserText.aiChatHistorySidebarChatsHeader)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 4)

            chatListContent
        }
    }

    @ViewBuilder
    private var chatListContent: some View {
        if viewModel.isLoading && viewModel.chats.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.top, 24)
        } else if !viewModel.isLoading && viewModel.chats.isEmpty {
            Text(UserText.aiChatHistorySidebarNoChats)
                .font(.body)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 24)
                .multilineTextAlignment(.center)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(viewModel.chats) { suggestion in
                        ChatRow(suggestion: suggestion, onSelected: { viewModel.onChatSelected?(suggestion.chatId) })
                    }
                }
            }
        }
    }

    // MARK: - Footer

    private var footerView: some View {
        HoverRow(action: { viewModel.onSettings?() }) {
            HStack(spacing: 8) {
                Image(nsImage: DesignSystemImages.Glyphs.Size16.aiChatSettings)
                    .renderingMode(.template)
                    .frame(width: 16, height: 16)
                Text(UserText.aiChatHistorySidebarSettingsAndMore)
                    .font(.body)
                Spacer()
            }
        }
    }
}

// MARK: - Reusable Components

/// A tappable row that highlights on hover.
private struct HoverRow<Content: View>: View {
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            content()
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isHovered ? Color.controlsFillPrimary : Color.clear)
        .onHover { isHovered = $0 }
    }
}

/// A single chat history row with hover highlight.
private struct ChatRow: View {
    let suggestion: AIChatSuggestion
    let onSelected: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelected) {
            HStack(spacing: 8) {
                Text(suggestion.title)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                if suggestion.isPinned {
                    Image(nsImage: DesignSystemImages.Glyphs.Size16.pin)
                        .renderingMode(.template)
                        .foregroundColor(.secondary)
                        .frame(width: 14, height: 14)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isHovered ? Color.controlsFillPrimary : Color.clear)
        .onHover { isHovered = $0 }
    }
}

/// The header close button with a rounded hover highlight.
private struct CloseButton: View {
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .imageScale(.medium)
                .padding(5)
                .background(isHovered ? Color.controlsFillPrimary : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close")
        .onHover { isHovered = $0 }
    }
}
