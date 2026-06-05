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
import Combine
import DesignResourcesKit
import DesignResourcesKitIcons
import DuckUI
import VPN
import Subscription

struct VPNOnboardingActivationView: View {

    @StateObject private var viewModel: VPNOnboardingActivationViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var presentedURL: URL?

    private let onNext: () -> Void

    init(viewModel: VPNOnboardingActivationViewModel = VPNOnboardingActivationViewModel(),
         onNext: @escaping () -> Void = {}) {
        _viewModel = StateObject(wrappedValue: viewModel)
        self.onNext = onNext
    }

    var body: some View {
        Group {
            if let presentedURL {
                OnboardingWebSheet(urlString: presentedURL.absoluteString) {
                    self.presentedURL = nil
                }
            } else {
                onboardingContent
            }
        }
        .task {
            await viewModel.fetchRealIPLocation()
        }
    }

    private var onboardingContent: some View {
        SubscriptionOnboardingPage(
            title: Text("Step 1 of 4")
                .font(Font(UIFont.daxSubheadSemibold()))
                .foregroundColor(Color(designSystemColor: .textSecondary)),
            primaryButton: .init(title: viewModel.isConnected ? "Next" : "Turn on VPN") {
                if viewModel.isConnected {
                    onNext()
                } else {
                    Task { await viewModel.turnOnVPN() }
                }
            },
            onClose: { dismiss() }
        ) {
            VStack(spacing: 24) {
                SettingsDescriptionView(content: headerContent)
                contentCards
            }
            .animation(.easeInOut, value: viewModel.isConnected)
        }
        .environment(\.openURL, OpenURLAction { url in
            presentedURL = url
            return .handled
        })
    }

    private var headerContent: SettingsDescription {
        let explanation = viewModel.isConnected
            ? "All device internet traffic is being secured through the VPN. [Learn More](https://duckduckgo.com/pro)"
            : "Connect to secure all of your device's internet traffic. [Learn More](https://duckduckgo.com/pro)"
        return SettingsDescription(
            image: viewModel.isConnected
                ? DesignSystemImages.Color.Size128.networkProtectionVPN
                : DesignSystemImages.Color.Size128.networkProtectionVPNDisabled,
            title: viewModel.isConnected ? "DuckDuckGo VPN is On" : "DuckDuckGo VPN is Off",
            status: nil,
            explanation: explanation
        )
    }

    @ViewBuilder
    private var contentCards: some View {
        VStack(spacing: 16) {
            if viewModel.isConnected {
                groupedContainer {
                    VPNOnboardingIPCard(title: "Your IP Address is Hidden",
                                        ipAddress: viewModel.realIP ?? "—",
                                        location: viewModel.realLocation ?? "—",
                                        style: .hidden)
                }

                groupedContainer {
                    VPNOnboardingIPCard(title: "Your New IP Address",
                                        ipAddress: viewModel.vpnIP ?? "—",
                                        location: viewModel.vpnLocation ?? "—",
                                        style: .new,
                                        isNearest: viewModel.isNearest)
                }

                caption("When the VPN is on, sites and apps see your new IP instead, helping keep your activity anonymous.")
            } else {
                groupedContainer {
                    VPNOnboardingIPCard(title: "Your IP Address",
                                        ipAddress: viewModel.realIP ?? "—",
                                        location: viewModel.realLocation ?? "—",
                                        style: .active)
                }

                caption("When the VPN is off, sites and apps can see this info and use it to connect your activity across sessions.")
            }

            VStack(spacing: 8) {
                VPNOnboardingFeatureRow(text: "Shielding your online activity", isActive: viewModel.isConnected)
                VPNOnboardingFeatureRow(text: "Hiding your location & IP address", isActive: viewModel.isConnected)
                VPNOnboardingFeatureRow(text: "Blocking harmful sites", isActive: viewModel.isConnected)
            }
        }
    }

    private func groupedContainer<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(designSystemColor: .background))
            .clipShape(RoundedRectangle(cornerRadius: 24))
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .daxFootnoteRegular()
            .foregroundColor(Color(designSystemColor: .textPrimary))
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
    var isNearest: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(uiImage: style == .new
                  ? DesignSystemImages.Color.Size24.vpn
                  : DesignSystemImages.Color.Size24.vpnGrayscale)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .daxFootnoteSemibold()
                    .foregroundColor(Color(designSystemColor: .textPrimary))

                Text(ipAddress)
                    .daxHeadline()
                    .foregroundColor(Color(designSystemColor: .textPrimary))

                HStack(spacing: 4) {
                    Text(location)
                        .daxFootnoteRegular()
                        .foregroundColor(Color(designSystemColor: .textPrimary))

                    if isNearest {
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
            Image(uiImage: isActive
                  ? DesignSystemImages.Glyphs.Size20.checkSolid
                  : DesignSystemImages.Glyphs.Size20.closeSolid)
                .renderingMode(.template)
                .foregroundColor(Color(designSystemColor: isActive ? .alertGreen : .icons))

            Text(text)
                .daxSubheadRegular()
                .foregroundColor(Color(designSystemColor: .textPrimary))

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(designSystemColor: .background))
        .clipShape(Capsule())
    }
}

final class VPNOnboardingActivationViewModel: ObservableObject {

    @Published private(set) var isConnected: Bool
    @Published private(set) var realIP: String?
    @Published private(set) var realLocation: String?
    @Published private(set) var vpnIP: String?
    @Published private(set) var vpnLocation: String?

    let isNearest: Bool

    private let statusModel: NetworkProtectionStatusViewModel?
    private let statusObserver: ConnectionStatusObserver?
    private let serverInfoObserver: ConnectionServerInfoObserver?

    convenience init() {
        let provider = AppDependencyProvider.shared
        let serverInfo = provider.serverInfoObserver.recentValue
        let statusModel = NetworkProtectionStatusViewModel(
            tunnelController: provider.networkProtectionTunnelController,
            settings: provider.vpnSettings,
            statusObserver: provider.connectionObserver,
            serverInfoObserver: provider.serverInfoObserver,
            locationListRepository: NetworkProtectionLocationListCompositeRepository(),
            enablesUnifiedFeedbackForm: provider.subscriptionManager.isUserAuthenticated)
        self.init(statusModel: statusModel,
                  statusObserver: provider.connectionObserver,
                  serverInfoObserver: provider.serverInfoObserver,
                  isNearest: provider.vpnSettings.selectedLocation == .nearest,
                  isConnected: provider.connectionObserver.recentValue.isConnected,
                  vpnIP: serverInfo.serverAddress,
                  vpnLocation: serverInfo.serverLocation.map(Self.formattedLocation))
        bindObservers()
    }

    init(statusModel: NetworkProtectionStatusViewModel? = nil,
         statusObserver: ConnectionStatusObserver? = nil,
         serverInfoObserver: ConnectionServerInfoObserver? = nil,
         isNearest: Bool = false,
         isConnected: Bool = false,
         realIP: String? = nil,
         realLocation: String? = nil,
         vpnIP: String? = nil,
         vpnLocation: String? = nil) {
        self.statusModel = statusModel
        self.statusObserver = statusObserver
        self.serverInfoObserver = serverInfoObserver
        self.isNearest = isNearest
        self.isConnected = isConnected
        self.realIP = realIP
        self.realLocation = realLocation
        self.vpnIP = vpnIP
        self.vpnLocation = vpnLocation
    }

    private func bindObservers() {
        statusObserver?.publisher
            .receive(on: DispatchQueue.main)
            .map(\.isConnected)
            .assign(to: &$isConnected)

        serverInfoObserver?.publisher
            .receive(on: DispatchQueue.main)
            .map(\.serverAddress)
            .assign(to: &$vpnIP)

        serverInfoObserver?.publisher
            .receive(on: DispatchQueue.main)
            .map { $0.serverLocation.map(Self.formattedLocation) }
            .assign(to: &$vpnLocation)
    }

    @MainActor
    func turnOnVPN() async {
        await statusModel?.didToggleNetP(to: true)
    }

    @MainActor
    func fetchRealIPLocation() async {
        // Only fetch on the live path. On the preview/injected path (no observers) we keep
        // the injected values so the canvas never displays the developer's real IP.
        guard statusObserver != nil else { return }
        guard let result = try? await RealIPLocationFetcher.fetch() else { return }
        realIP = result.ip
        realLocation = result.location
    }

    private static func formattedLocation(_ attributes: NetworkProtectionServerInfo.ServerAttributes) -> String {
        NetworkProtectionLocationStatusModel.formattedLocation(city: attributes.city, country: attributes.country)
    }
}

enum RealIPLocationFetcher {

    private struct IPResponse: Decodable {
        let ip: String
    }

    private struct CountryResponse: Decodable {
        let country: String
    }

    struct Result {
        let ip: String
        let location: String
    }

    static func fetch() async throws -> Result {
        async let ipResult = fetchIP()
        async let countryResult = fetchCountry()
        let (ip, country) = try await (ipResult, countryResult)
        let labels = NetworkProtectionVPNCountryLabelsModel(country: country, useFullCountryName: true)
        return Result(ip: ip, location: "\(labels.emoji) \(labels.title)")
    }

    private static func fetchIP() async throws -> String {
        let url = URL(string: "http://leakcheck.netp.duckduckgo.com/")!
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode(IPResponse.self, from: data).ip
    }

    private static func fetchCountry() async throws -> String {
        let url = URL(string: "https://duckduckgo.com/country.json")!
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode(CountryResponse.self, from: data).country
    }
}

private extension ConnectionStatus {
    var isConnected: Bool {
        if case .connected = self {
            return true
        }
        return false
    }
}

struct SubscriptionOnboardingDebugView: View {

    @State private var isVPNOnboardingPresented = false
    @State private var isDuckAIOnboardingPresented = false

    var body: some View {
        List {
            Section {
                Button("VPN") {
                    isVPNOnboardingPresented = true
                }
                Button("Duck.ai") {
                    isDuckAIOnboardingPresented = true
                }
            } footer: {
                Text("These buttons do nothing with your actual subscription status. They only open the post-subscription onboarding views for preview.")
            }
        }
        .navigationTitle("Subscription Onboarding")
        .sheet(isPresented: $isVPNOnboardingPresented) {
            VPNOnboardingActivationView()
        }
        .sheet(isPresented: $isDuckAIOnboardingPresented) {
            DuckAIOnboardingActivationView()
        }
    }
}

#Preview("VPN Off") {
    VPNOnboardingActivationView(viewModel: VPNOnboardingActivationViewModel(
        isConnected: false,
        realIP: "31.120.130.50",
        realLocation: "🇪🇸 Madrid, Spain"))
}

#Preview("VPN On") {
    VPNOnboardingActivationView(viewModel: VPNOnboardingActivationViewModel(
        isNearest: true,
        isConnected: true,
        realIP: "31.120.130.50",
        realLocation: "🇪🇸 Madrid, Spain",
        vpnIP: "165.225.94.30",
        vpnLocation: "🇪🇸 Valencia, Spain"))
}
