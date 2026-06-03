//
//  VPNOnboardingActivationView.swift
//  DuckDuckGo
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

import SwiftUI
import DesignResourcesKit
import DesignResourcesKitIcons
import DuckUI

enum VPNOnboardingActivationState: Equatable {
    case off
    case requestingPermission
    case on
}

struct VPNOnboardingActivationView: View {

    @State private var state: VPNOnboardingActivationState

    private let realIP = "31.120.130.50"
    private let realLocation = "🇪🇸 Madrid, Spain"
    private let vpnIP = "165.225.94.30"
    private let vpnLocation = "🇪🇸 Valencia, Spain"

    private let onNext: () -> Void

    init(initialState: VPNOnboardingActivationState = .off, onNext: @escaping () -> Void = {}) {
        _state = State(initialValue: initialState)
        self.onNext = onNext
    }

    var body: some View {
        ZStack {
            Color(designSystemColor: .background)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                stepHeader

                ScrollView {
                    VStack(spacing: 24) {
                        SettingsDescriptionView(content: headerContent)
                        contentCards
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }

                footer
            }

            if state == .requestingPermission {
                permissionModal
                    .transition(.opacity)
            }
        }
    }

    private var stepHeader: some View {
        ZStack {
            Text("Step 1 of 4")
                .daxFootnoteRegular()
                .foregroundColor(Color(designSystemColor: .textSecondary))

            HStack {
                Button("Back") {}
                    .daxBodyRegular()
                    .foregroundColor(Color(designSystemColor: .textPrimary))
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var headerContent: SettingsDescription {
        SettingsDescription(
            image: state == .on
                ? DesignSystemImages.Color.Size128.networkProtectionVPN
                : DesignSystemImages.Color.Size128.networkProtectionVPNDisabled,
            title: state == .on ? "DuckDuckGo VPN is On" : "DuckDuckGo VPN is Off",
            status: nil,
            explanation: state == .on
                ? "All device internet traffic is being secured through the VPN."
                : "Connect to secure all of your device's internet traffic."
        )
    }

    @ViewBuilder
    private var contentCards: some View {
        VStack(spacing: 16) {
            if state == .on {
                groupedContainer {
                    VPNOnboardingIPCard(title: "Your IP Address is Hidden",
                                        ipAddress: realIP,
                                        location: realLocation,
                                        style: .hidden)
                }

                groupedContainer {
                    VPNOnboardingIPCard(title: "Your New IP Address",
                                        ipAddress: vpnIP,
                                        location: vpnLocation,
                                        style: .new)
                }

                caption("When the VPN is on, sites and apps see your new IP instead, helping keep your activity anonymous.")
            } else {
                groupedContainer {
                    VPNOnboardingIPCard(title: "Your IP Address",
                                        ipAddress: realIP,
                                        location: realLocation,
                                        style: .active)
                }

                caption("When the VPN is off, sites and apps can see this info and use it to connect your activity across sessions.")
            }

            VStack(spacing: 8) {
                VPNOnboardingFeatureRow(text: "Shielding your online activity", isActive: state == .on)
                VPNOnboardingFeatureRow(text: "Hiding your location & IP address", isActive: state == .on)
                VPNOnboardingFeatureRow(text: "Blocking harmful sites", isActive: state == .on)
            }
        }
    }

    private var footer: some View {
        Button {
            switch state {
            case .off:
                withAnimation { state = .requestingPermission }
            case .requestingPermission:
                break
            case .on:
                onNext()
            }
        } label: {
            Text(state == .on ? "Next" : "Turn on VPN")
        }
        .buttonStyle(PrimaryButtonStyle())
        .padding(16)
    }

    private var permissionModal: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                VStack(spacing: 0) {
                    VStack(spacing: 6) {
                        Text("“DuckDuckGo” Would Like to Add VPN Configurations")
                            .daxHeadline()
                            .multilineTextAlignment(.center)
                            .foregroundColor(Color(designSystemColor: .textPrimary))

                        Text("All network activity on this iPhone may be filtered or monitored when using the VPN.")
                            .daxFootnoteRegular()
                            .multilineTextAlignment(.center)
                            .foregroundColor(Color(designSystemColor: .textSecondary))
                    }
                    .padding(16)

                    Divider()

                    HStack(spacing: 0) {
                        Button("Don't Allow") {
                            withAnimation { state = .off }
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)

                        Divider()
                            .frame(height: 44)

                        Button {
                            withAnimation { state = .on }
                        } label: {
                            Text("Allow")
                                .daxHeadline()
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                }
                .frame(maxWidth: 270)
                .background(Color(designSystemColor: .surface))
                .clipShape(RoundedRectangle(cornerRadius: 14))

                Text("Tap Allow")
                    .daxFootnoteRegular()
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.orange))
            }
            .padding(40)
        }
    }

    private func groupedContainer<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(designSystemColor: .surface))
            .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .daxFootnoteRegular()
            .foregroundColor(Color(designSystemColor: .textSecondary))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct VPNOnboardingIPCard: View {

    enum Style {
        case active
        case hidden
        case new
    }

    let title: String
    let ipAddress: String
    let location: String
    let style: Style

    var body: some View {
        HStack(spacing: 12) {
            Image(uiImage: DesignSystemImages.Glyphs.Size24.globe)
                .renderingMode(.template)
                .foregroundColor(Color(designSystemColor: style == .new ? .accent : .icons))
                .frame(width: 40, height: 40)
                .background(Circle().fill(Color(designSystemColor: .backgroundTertiary)))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .daxFootnoteRegular()
                    .foregroundColor(Color(designSystemColor: .textSecondary))

                Text(ipAddress)
                    .strikethrough(style == .hidden)
                    .daxHeadline()
                    .foregroundColor(Color(designSystemColor: .textPrimary))

                HStack(spacing: 4) {
                    Text(location)
                        .daxFootnoteRegular()
                        .foregroundColor(Color(designSystemColor: .textSecondary))

                    if style == .new {
                        Text("(Nearest)")
                            .daxFootnoteRegular()
                            .foregroundColor(Color(designSystemColor: .textSecondary))
                    }
                }
            }

            Spacer()
        }
        .opacity(style == .hidden ? 0.5 : 1)
    }
}

struct VPNOnboardingFeatureRow: View {

    let text: String
    let isActive: Bool

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color(designSystemColor: isActive ? .alertGreen : .icons))
                    .opacity(isActive ? 1 : 0.3)
                    .frame(width: 24, height: 24)

                Image(uiImage: isActive ? DesignSystemImages.Glyphs.Size24.check : DesignSystemImages.Glyphs.Size24.close)
                    .renderingMode(.template)
                    .resizable()
                    .frame(width: 14, height: 14)
                    .foregroundColor(.white)
            }

            Text(text)
                .daxBodyRegular()
                .foregroundColor(Color(designSystemColor: .textPrimary))

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(designSystemColor: .surface))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

#Preview("VPN Off") {
    VPNOnboardingActivationView(initialState: .off)
}

#Preview("VPN modal") {
    VPNOnboardingActivationView(initialState: .requestingPermission)
}

#Preview("VPN On") {
    VPNOnboardingActivationView(initialState: .on)
}
