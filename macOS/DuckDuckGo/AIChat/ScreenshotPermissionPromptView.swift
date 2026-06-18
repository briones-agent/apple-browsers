//
//  ScreenshotPermissionPromptView.swift
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
import DesignResourcesKitIcons
import SwiftUI

/// Mirrors the shape of the VPN onboarding's `PromptActionView`
/// (`macOS/LocalPackages/NetworkProtectionMac/.../PromptActionView.swift`).
/// Vendored here because that view is `internal` to `NetworkProtectionUI`; if it later moves
/// to a shared package this should swap to the shared component verbatim.
///
/// Shown when the user picks a screenshot capture mode and the macOS Screen Recording
/// permission is not granted. macOS only surfaces the native system prompt once per
/// declined bundle — subsequent attempts silently fail. This view guides the user to
/// System Settings and reminds them an app relaunch is required afterwards.
struct ScreenshotPermissionPromptView: View {

    struct Model {
        let icon: NSImage
        let title: String
        let descriptionFragments: [Fragment]
        let actionTitle: String
        let action: () -> Void

        struct Fragment {
            let text: String
            let isEmphasized: Bool
            init(_ text: String, emphasized: Bool = false) {
                self.text = text
                self.isEmphasized = emphasized
            }
        }
    }

    let model: Model

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(nsImage: model.icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 5) {
                    Text(model.title)
                        .font(.system(size: 13).weight(.bold))
                        .foregroundColor(.primary)
                        .fixedSize(horizontal: false, vertical: true)

                    model.descriptionFragments.reduce(Text("")) { acc, frag in
                        let next = frag.isEmphasized
                            ? Text(frag.text).fontWeight(.semibold)
                            : Text(frag.text)
                        return acc + next
                    }
                    .font(.system(size: 13))
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                    Button(model.actionTitle, action: model.action)
                        .keyboardShortcut(.defaultAction)
                        .padding(.top, 3)
                }

                Spacer(minLength: 0)
            }
            .padding(.vertical, 16)
            .padding(.horizontal, 14)
        }
        .frame(width: 360)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                )
        )
    }
}

extension ScreenshotPermissionPromptView.Model {

    /// Default factory for the "Screen Recording missing, system won't re-prompt" case.
    /// Caller supplies the action — usually opens System Settings and dismisses the popover.
    static func screenRecordingMissing(action: @escaping () -> Void) -> Self {
        // Camera glyph — topical for "screen capture", more universally readable than the
        // scissors metaphor at this size. Vector asset, so the 40pt frame in the prompt view
        // scales cleanly from the Size24 source.
        .init(
            icon: DesignSystemImages.Glyphs.Size24.camera,
            title: "Allow Duck.ai to capture your screen",
            descriptionFragments: [
                .init("To attach a screenshot, open "),
                .init("System Settings → Privacy & Security → Screen Recording", emphasized: true),
                .init(", turn DuckDuckGo on, then relaunch the app.")
            ],
            actionTitle: "Open System Settings…",
            action: action
        )
    }
}
