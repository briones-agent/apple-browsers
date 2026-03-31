//
//  AutoplayPolicyTabExtension.swift
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

import FeatureFlags
import Navigation
import PrivacyConfig

final class AutoplayPolicyTabExtension {

    private let autoplayPreferences: AutoplayPreferences
    private let featureFlagger: FeatureFlagger
    private let permissionManager: PermissionManagerProtocol

    init(autoplayPreferences: AutoplayPreferences, featureFlagger: FeatureFlagger, permissionManager: PermissionManagerProtocol) {
        self.autoplayPreferences = autoplayPreferences
        self.featureFlagger = featureFlagger
        self.permissionManager = permissionManager
    }
}

extension AutoplayPolicyTabExtension: NavigationResponder {

    @MainActor
    func decidePolicy(for navigationAction: NavigationAction, preferences: inout NavigationPreferences) async -> NavigationActionPolicy? {
        let isAutoplayPolicyEnabled = featureFlagger.isFeatureOn(.autoplayPolicy)
        preferences.mustApplyAutoplayPolicy = isAutoplayPolicyEnabled && navigationAction.isForMainFrame

        if preferences.mustApplyAutoplayPolicy {
            let domain = autoplayDomain(for: navigationAction.url)
            preferences.autoplayPolicy = loadAutoplayPolicy(forDomain: domain)
        }

        return .next
    }
}

private extension AutoplayPolicyTabExtension {

    func autoplayDomain(for url: URL) -> String {
        (url.isFileURL ? .localhost : (url.host ?? "")).droppingWwwPrefix()
    }

    func loadAutoplayPolicy(forDomain domain: String) -> _WKWebsiteAutoplayPolicy {
        guard permissionManager.hasPermissionPersisted(forDomain: domain, permissionType: .autoplayPolicy) else {
            return .init(autoplayPreferences.autoplayBlockingMode.mediaTypesRequiringUserAction)
        }

        let decision = permissionManager.permission(forDomain: domain, permissionType: .autoplayPolicy)
        switch decision {
        case .allow:
            return .allow
        case .ask:
            return .allowWithoutSound
        case .deny:
            return .deny
        }
    }
}

protocol AutoplayPolicyTabExtensionProtocol: AnyObject, NavigationResponder {}

extension AutoplayPolicyTabExtension: TabExtension, AutoplayPolicyTabExtensionProtocol {
    typealias PublicProtocol = AutoplayPolicyTabExtensionProtocol
    func getPublicProtocol() -> PublicProtocol { self }
}

extension TabExtensions {
    var autoplayPolicy: AutoplayPolicyTabExtensionProtocol? {
        resolve(AutoplayPolicyTabExtension.self)
    }
}
