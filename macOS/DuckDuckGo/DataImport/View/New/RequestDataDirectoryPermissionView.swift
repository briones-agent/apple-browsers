//
//  RequestDataDirectoryPermissionView.swift
//
//  Copyright © 2025 DuckDuckGo. All rights reserved.
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
import BrowserServicesKit
import DesignResourcesKit
import DesignResourcesKitIcons
import SwiftUI

/// Shown on macOS 27+ when the selected browser's data directory exists but the app hasn't been granted
/// access to it (TCC restriction on `~/Library/Application Support/*`). It guides the user to grant access
/// in System Settings › Privacy & Security › Files & Folders, polls the directory until access is granted,
/// then confirms and lets the user continue with the import.
struct RequestDataDirectoryPermissionView: View {

    private enum Constants {
        static let pollingInterval: TimeInterval = 2
    }

    private let source: DataImport.Source
    private let profileURL: URL
    private let accessGranted: Bool
    private let checkAccess: (URL) -> Bool
    private let openSettings: () -> Void
    private let onAccessGranted: () -> Void
    private let onProceed: () -> Void

    // Poll the directory on the main run loop until the user grants access in System Settings.
    @State private var pollingTimer = Timer.publish(every: Constants.pollingInterval, on: .main, in: .common).autoconnect()

    init(source: DataImport.Source,
         profileURL: URL,
         accessGranted: Bool,
         checkAccess: @escaping (URL) -> Bool = RequestDataDirectoryPermissionView.hasReadAccess,
         openSettings: @escaping () -> Void = RequestDataDirectoryPermissionView.openFilesAndFoldersSettings,
         onAccessGranted: @escaping () -> Void,
         onProceed: @escaping () -> Void) {
        self.source = source
        self.profileURL = profileURL
        self.accessGranted = accessGranted
        self.checkAccess = checkAccess
        self.openSettings = openSettings
        self.onAccessGranted = onAccessGranted
        self.onProceed = onProceed
    }

    var body: some View {
        VStack(alignment: .center, spacing: 16) {
            if accessGranted {
                grantedContent
            } else {
                requestContent
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 8)
        .onAppear {
            // Access may already have been granted before reaching this screen.
            updateAccessState()
        }
        .onReceive(pollingTimer) { _ in
            updateAccessState()
        }
    }

    private func updateAccessState() {
        // Once granted, `!accessGranted` short-circuits so the directory is no longer polled.
        guard !accessGranted, checkAccess(profileURL) else { return }
        withAnimation { onAccessGranted() }
    }

    @ViewBuilder
    private var requestContent: some View {
        Image(nsImage: DesignSystemImages.Color.Size24.exclamation)
            .resizable()
            .frame(width: 48, height: 48)

        Text(UserText.importBrowserDataAccessTitle(source: source))
            .font(.system(size: 17, weight: .bold))
            .foregroundColor(Color(designSystemColor: .textPrimary))

        Text(UserText.importBrowserDataAccessInfo(source: source))
            .font(.system(size: 13))
            .foregroundColor(Color(designSystemColor: .textSecondary))

        Button {
            openSettings()
        } label: {
            Text(UserText.importBrowserDataAccessOpenSettingsButton)
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
        .padding(.top, 4)

        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(UserText.importBrowserDataAccessWaiting)
                .font(.system(size: 11))
                .foregroundColor(Color(designSystemColor: .textSecondary))
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private var grantedContent: some View {
        Image(nsImage: DesignSystemImages.Glyphs.Size24.check)
            .renderingMode(.template)
            .resizable()
            .frame(width: 48, height: 48)
            .foregroundColor(.accentColor)

        Text(UserText.importBrowserDataAccessGrantedTitle(source: source))
            .font(.system(size: 17, weight: .bold))
            .foregroundColor(Color(designSystemColor: .textPrimary))

        Text(UserText.importBrowserDataAccessGrantedInfo)
            .font(.system(size: 13))
            .foregroundColor(Color(designSystemColor: .textSecondary))

        Button {
            onProceed()
        } label: {
            Text(UserText.continue)
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
        .padding(.top, 4)
    }

    // MARK: - Defaults

    /// Attempts to read the directory contents. On macOS 27+ this throws `fileReadNoPermission` (257) until the
    /// user grants access, so a successful read means access has been granted.
    static func hasReadAccess(to url: URL) -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil
    }

    static func openFilesAndFoldersSettings() {
        NSWorkspace.shared.open(.filesAndFolders)
    }
}

#Preview {
    RequestDataDirectoryPermissionView(source: .chrome,
                                       profileURL: URL(fileURLWithPath: "/tmp"),
                                       accessGranted: false,
                                       checkAccess: { _ in false },
                                       openSettings: {},
                                       onAccessGranted: {},
                                       onProceed: {})
        .frame(width: 420)
}
