//
//  ContentBlockingTabExtension.swift
//
//  Copyright © 2022 DuckDuckGo. All rights reserved.
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

import BrowserServicesKit
import Combine
import Common
import ContentBlocking
import Foundation
import Navigation
import PrivacyConfig
import Subscription
import TrackerRadarKit
import os.log

struct DetectedTracker {
    enum TrackerType {
        case tracker
        case trackerWithSurrogate(host: String)
        case thirdPartyRequest
    }
    let request: DetectedRequest
    let type: TrackerType
}

protocol ContentBlockingAssetsInstalling: AnyObject {
    var contentBlockingAssetsInstalled: Bool { get }
    var awaitContentBlockingAssetsInstalled: () async -> Void { get }
}
extension UserContentController: ContentBlockingAssetsInstalling {}

final class ContentBlockingTabExtension: NSObject {
    private static var idCounter: UInt64 = 0
    private let identifier: UInt64 = {
        defer { idCounter += 1 }
        return ContentBlockingTabExtension.idCounter
    }()

    private weak var userContentController: ContentBlockingAssetsInstalling?
    private let cbaTimeReporter: ContentBlockingAssetsCompilationTimeReporter?
    private let privacyConfigurationManager: PrivacyConfigurationManaging
    private let fbBlockingEnabledProvider: FbBlockingEnabledProvider
    private let tld: TLD
    private let contentBlockingManager: ContentBlockerRulesManagerProtocol
    private lazy var trackerProtectionMapper: TrackerProtectionEventMapper? = {
        let mergedTrackerData = Self.mergeTrackerData(from: contentBlockingManager.currentRules)
        guard let trackerData = mergedTrackerData else { return nil }
        let privacyConfig = privacyConfigurationManager.privacyConfig
        let resolver = TrackerResolver(tds: trackerData,
                                       unprotectedSites: privacyConfig.userUnprotectedDomains,
                                       tempList: privacyConfig.tempUnprotectedDomains,
                                       tld: tld)
        return TrackerProtectionEventMapper(tld: tld, trackerResolver: resolver, privacyConfig: privacyConfig)
    }()

    private static func mergeTrackerData(from rules: [ContentBlockerRulesManager.Rules]) -> TrackerData? {
        guard !rules.isEmpty else { return nil }
        var trackers: [String: KnownTracker] = [:]
        var entities: [String: Entity] = [:]
        var domains: [String: String] = [:]
        var cnames: [TrackerData.CnameDomain: TrackerData.TrackerDomain]?
        for rule in rules {
            trackers.merge(rule.trackerData.trackers) { (_, new) in new }
            entities.merge(rule.trackerData.entities) { (_, new) in new }
            domains.merge(rule.trackerData.domains) { (_, new) in new }
            if rule.name == DefaultContentBlockerRulesListsSource.Constants.trackerDataSetRulesListName {
                cnames = rule.trackerData.cnames
            }
        }
        return TrackerData(trackers: trackers, entities: entities, domains: domains, cnames: cnames)
    }
    private var trackersSubject = PassthroughSubject<DetectedTracker, Never>()

    private var cancellables = Set<AnyCancellable>()

#if DEBUG
    /// set this to true when Navigation-related decision making is expected to take significant time to avoid assertions
    /// used by BSK: Navigation.DistributedNavigationDelegate
    var shouldDisableLongDecisionMakingChecks: Bool = false
    func disableLongDecisionMakingChecks() { shouldDisableLongDecisionMakingChecks = true }
    func enableLongDecisionMakingChecks() { shouldDisableLongDecisionMakingChecks = false }
#else
    func disableLongDecisionMakingChecks() {}
    func enableLongDecisionMakingChecks() {}
#endif

    init(fbBlockingEnabledProvider: FbBlockingEnabledProvider,
         userContentControllerFuture: some Publisher<some ContentBlockingAssetsInstalling, Never>,
         cbaTimeReporter: ContentBlockingAssetsCompilationTimeReporter?,
         privacyConfigurationManager: PrivacyConfigurationManaging,
         trackerProtectionSubfeaturePublisher: some Publisher<TrackerProtectionSubfeature?, Never>,
         tld: TLD,
         contentBlockingManager: ContentBlockerRulesManagerProtocol) {

        self.cbaTimeReporter = cbaTimeReporter
        self.fbBlockingEnabledProvider = fbBlockingEnabledProvider
        self.privacyConfigurationManager = privacyConfigurationManager
        self.tld = tld
        self.contentBlockingManager = contentBlockingManager
        super.init()

        userContentControllerFuture.sink { [weak self] userContentController in
            self?.userContentController = userContentController
        }.store(in: &cancellables)
        trackerProtectionSubfeaturePublisher.sink { [weak self] trackerProtectionSubfeature in
            trackerProtectionSubfeature?.delegate = self
        }.store(in: &cancellables)
    }

    deinit {
        cbaTimeReporter?.tabWillClose(identifier)
    }

}

extension ContentBlockingTabExtension: NavigationResponder {

    func decidePolicy(for navigationAction: NavigationAction, preferences: inout NavigationPreferences) async -> NavigationActionPolicy? {
        if !navigationAction.url.isDuckDuckGo
            // ContentScopeUserScript needs to be loaded for https://duckduckgo.com/email/
            || navigationAction.url.absoluteString.hasPrefix(URL.duckDuckGoEmailLogin.absoluteString)
            // ContentScopeUserScript needs to be loaded for https://duckduckgo.com/subscriptions
            || navigationAction.url.absoluteString.hasPrefix(SubscriptionURL.baseURL.subscriptionURL(environment: .production).absoluteString)
            // ContentScopeUserScript needs to be loaded for https://duckduckgo.com/identity-theft-restoration
            || navigationAction.url.absoluteString.hasPrefix(SubscriptionURL.identityTheftRestoration.subscriptionURL(environment: .production).absoluteString)
            // ContentScopeUserScript needs to be loaded for Duck.ai
            || navigationAction.url.isDuckAIURL {
            await prepareForContentBlocking()
        }

        return .next
    }

    @MainActor
    private func prepareForContentBlocking() async {
        // Ensure Content Blocking Assets (WKContentRuleList&UserScripts) are installed
        if userContentController?.contentBlockingAssetsInstalled == false
            && privacyConfigurationManager.privacyConfig.isEnabled(featureKey: .contentBlocking) {
            Logger.contentBlocking.log("\(self.identifier) tabWillWaitForRulesCompilation")
            cbaTimeReporter?.tabWillWaitForRulesCompilation(identifier)

            disableLongDecisionMakingChecks()
            defer {
                enableLongDecisionMakingChecks()
            }

            await userContentController?.awaitContentBlockingAssetsInstalled()
            Logger.contentBlocking.log("\(self.identifier) Rules Compilation done")
            cbaTimeReporter?.reportWaitTimeForTabFinishedWaitingForRules(identifier)
        } else {
            cbaTimeReporter?.reportNavigationDidNotWaitForRules()
        }
    }

}

extension ContentBlockingTabExtension: TrackerProtectionSubfeatureDelegate {

    func trackerProtectionShouldProcessTrackers(_ subfeature: TrackerProtectionSubfeature) -> Bool {
        return true
    }

    func trackerProtection(_ subfeature: TrackerProtectionSubfeature,
                           didObserveResource observation: TrackerProtectionSubfeature.ResourceObservation) {
        guard let mapper = trackerProtectionMapper else { return }

        if let detected = mapper.classifyResource(observation,
                                                   adClickAttributionVendor: subfeature.currentAdClickAttributionVendor) {
            if detected.state == .blocked {
                trackersSubject.send(DetectedTracker(request: detected, type: .tracker))
                if detected.ownerName == fbBlockingEnabledProvider.fbEntity {
                    fbBlockingEnabledProvider.trackerDetected()
                }
            } else if !mapper.isSameSiteObservation(observation) {
                trackersSubject.send(DetectedTracker(request: detected, type: .thirdPartyRequest))
            }
        } else if let thirdParty = mapper.makeThirdPartyRequest(from: observation) {
            trackersSubject.send(DetectedTracker(request: thirdParty, type: .thirdPartyRequest))
        }
    }

    func trackerProtection(_ subfeature: TrackerProtectionSubfeature,
                           didInjectSurrogate surrogate: TrackerProtectionSubfeature.SurrogateInjection) {
        guard let mapper = trackerProtectionMapper,
              let detected = mapper.classifySurrogate(surrogate,
                                                      adClickAttributionVendor: subfeature.currentAdClickAttributionVendor),
              let host = mapper.surrogateHost(from: surrogate) else { return }
        trackersSubject.send(DetectedTracker(request: detected, type: .trackerWithSurrogate(host: host)))
    }
}

protocol ContentBlockingExtensionProtocol: AnyObject, NavigationResponder {
    var trackersPublisher: AnyPublisher<DetectedTracker, Never> { get }
}

extension ContentBlockingTabExtension: TabExtension, ContentBlockingExtensionProtocol {
    typealias PublicProtocol = ContentBlockingExtensionProtocol

    func getPublicProtocol() -> PublicProtocol { self }

    var trackersPublisher: AnyPublisher<DetectedTracker, Never> {
        trackersSubject.eraseToAnyPublisher()
    }
}

extension TabExtensions {
    var contentBlockingAndSurrogates: ContentBlockingExtensionProtocol? {
        resolve(ContentBlockingTabExtension.self)
    }
}

extension Tab {
    var trackersPublisher: AnyPublisher<DetectedTracker, Never> {
        self.contentBlockingAndSurrogates?.trackersPublisher ?? PassthroughSubject().eraseToAnyPublisher()
    }
}
