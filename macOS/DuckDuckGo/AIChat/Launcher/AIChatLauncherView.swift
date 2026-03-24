//
//  AIChatLauncherView.swift
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
import DesignResourcesKitIcons
import SwiftUI

struct AIChatLauncherView: View {

    @ObservedObject var viewModel: AIChatLauncherViewModel

    var body: some View {
        VStack(spacing: 0) {
            searchRow
            Divider()
            quickActionsRow
            Divider()
            chatListContent
            Divider()
            footerRow
        }
        .background(Color(designSystemColor: .surfacePrimary))
    }

    // MARK: - Search Row

    private var searchRow: some View {
        HStack(spacing: 8) {
            Image(nsImage: DesignSystemImages.Glyphs.Size16.aiChat)
                .renderingMode(.template)
                .foregroundColor(.primary)
                .frame(width: 16, height: 16)
            TextField(UserText.aiChatLauncherSearchPlaceholder, text: $viewModel.searchText)
                .textFieldStyle(.plain)
            Text("⌘K")
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Quick Actions

    private var quickActionsRow: some View {
        HStack(spacing: 6) {
            QuickActionButton(
                title: UserText.aiChatLauncherNewChat,
                nsImage: DesignSystemImages.Glyphs.Size16.aiChatAdd,
                action: { viewModel.onNewChat?() }
            )
            QuickActionButton(
                title: UserText.aiChatLauncherVoice,
                nsImage: DesignSystemImages.Glyphs.Size16.permissionMicrophone,
                action: { viewModel.onNewVoiceChat?() }
            )
            QuickActionButton(
                title: UserText.aiChatLauncherImage,
                nsImage: DesignSystemImages.Glyphs.Size16.image,
                action: { viewModel.onNewImageChat?() }
            )
            QuickActionButton(
                title: UserText.aiChatLauncherSettings,
                nsImage: DesignSystemImages.Glyphs.Size16.aiChatSettings,
                action: { viewModel.onSettings?() }
            )
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }

    // MARK: - Chat List

    @ViewBuilder
    private var chatListContent: some View {
        if viewModel.isLoading && viewModel.allChats.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
        } else if viewModel.filteredChats.isEmpty {
            Text(UserText.aiChatLauncherNoChats)
                .font(.body)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .multilineTextAlignment(.center)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if viewModel.searchText.isEmpty {
                            Text(UserText.aiChatLauncherRecentHeader)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.top, 8)
                                .padding(.bottom, 4)
                        }
                        ForEach(Array(viewModel.filteredChats.enumerated()), id: \.element.chatId) { index, chat in
                            LauncherChatRow(
                                suggestion: chat,
                                isSelected: viewModel.selectedIndex == index,
                                isSearchActive: !viewModel.searchText.isEmpty,
                                onSelected: { viewModel.onChatSelected?(chat.chatId) }
                            )
                            .id(index)
                        }
                    }
                }
                .frame(maxHeight: 240)
                .onChange(of: viewModel.selectedIndex) { newIndex in
                    if let idx = newIndex {
                        withAnimation { proxy.scrollTo(idx, anchor: .center) }
                    }
                }
            }
        }
    }

    // MARK: - Footer

    private var footerRow: some View {
        HStack(spacing: 12) {
            Text(UserText.aiChatLauncherFooterNavigate)
            Text(UserText.aiChatLauncherFooterOpen)
            Text(UserText.aiChatLauncherFooterDismiss)
        }
        .font(.caption2)
        .foregroundColor(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

// MARK: - QuickActionButton

private struct QuickActionButton: View {
    let title: String
    let nsImage: NSImage
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(nsImage: nsImage)
                    .renderingMode(.template)
                    .frame(width: 16, height: 16)
                Text(title)
                    .font(.caption)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(isHovered ? Color.controlsFillPrimary : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - LauncherChatRow

private struct LauncherChatRow: View {
    let suggestion: AIChatSuggestion
    let isSelected: Bool
    let isSearchActive: Bool
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
                if suggestion.isPinned && !isSearchActive {
                    Image(nsImage: DesignSystemImages.Glyphs.Size16.pin)
                        .renderingMode(.template)
                        .foregroundColor(.secondary)
                        .frame(width: 14, height: 14)
                        .accessibilityLabel("Pinned")
                }
                if let timestamp = suggestion.timestamp {
                    Text(timestamp, style: .relative)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isSelected ? Color.accentColor.opacity(0.15) : (isHovered ? Color.controlsFillPrimary : Color.clear))
        .onHover { isHovered = $0 }
    }
}
