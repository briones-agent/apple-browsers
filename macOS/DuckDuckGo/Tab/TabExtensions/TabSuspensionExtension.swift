//
//  TabSuspensionExtension.swift
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

import Combine
import Foundation
import PrivacyConfig
import WebKit

/// This protocol encapsulates checks for tab suspension eligibility performed on a web view instance.
protocol TabSuspensionWebViewChecking: AnyObject {
    var isPlayingAudio: Bool { get }
    var isCapturingAudio: Bool { get }
    var isCapturingVideo: Bool { get }
}

extension WKWebView: TabSuspensionWebViewChecking {
    var isCapturingAudio: Bool {
        microphoneState != .none
    }

    var isCapturingVideo: Bool {
        cameraState != .none
    }
}

final class TabSuspensionExtension {

    private var cancellables = Set<AnyCancellable>()

    private weak var webView: TabSuspensionWebViewChecking?
    private var tabContent: Tab.TabContent = .none
    private let isTabPinned: () -> Bool
    private let featureFlagger: FeatureFlagger
    private let privacyConfigurationManager: PrivacyConfigurationManaging
    var hasVideoInPictureInPicture: Bool = false

    var canBeSuspended: Bool {

        // feature flag on
        guard featureFlagger.isFeatureOn(.tabSuspension) else { return false }

        // only URL tab content
        guard case let .url(url, _, _) = tabContent else { return false }

        // only HTTP/HTTPS (this skips Duck Player which is duck://)
        guard url.navigationalScheme?.isHypertextScheme == true else { return false }

        // skip Duck.ai
        guard !url.isDuckAIURL else { return false }

        // domain not in exceptions list
        guard privacyConfigurationManager.privacyConfig.isFeature(.tabSuspension, enabledForDomain: url.host) else { return false }

        // not pinned
        guard !isTabPinned() else { return false }

        guard let webView else { return false }

        // not playing audio
        guard !webView.isPlayingAudio else { return false }

        // not capturing audio
        guard !webView.isCapturingAudio else { return false }

        // not capturing video
        guard !webView.isCapturingVideo else { return false }

        // not using picture in picture
        guard !hasVideoInPictureInPicture else { return false }

        return true
    }

    init(
        webViewPublisher: some Publisher<TabSuspensionWebViewChecking, Never>,
        contentPublisher: some Publisher<Tab.TabContent, Never>,
        featureFlagger: FeatureFlagger,
        privacyConfigurationManager: PrivacyConfigurationManaging,
        isTabPinned: @escaping () -> Bool
    ) {
        self.featureFlagger = featureFlagger
        self.privacyConfigurationManager = privacyConfigurationManager
        self.isTabPinned = isTabPinned

        contentPublisher.sink { [weak self] content in
            self?.tabContent = content
        }.store(in: &cancellables)

        webViewPublisher.sink { [weak self] webView in
            self?.webView = webView
        }.store(in: &cancellables)
    }
}

protocol TabSuspensionExtensionProtocol: AnyObject {
    var canBeSuspended: Bool { get }
    var hasVideoInPictureInPicture: Bool { get set }
}

extension TabSuspensionExtension: TabSuspensionExtensionProtocol, TabExtension {
    func getPublicProtocol() -> TabSuspensionExtensionProtocol { self }
}

extension TabExtensions {
    var tabSuspension: TabSuspensionExtensionProtocol? {
        resolve(TabSuspensionExtension.self)
    }
}
