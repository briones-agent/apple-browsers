//
//  AppSyncService.swift
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

import AIChat
import BrowserServicesKit
import Combine
import Common
import DDGSync
import FeatureFlags
import os.log
import Persistence
import PixelKit
import PrivacyConfig

final class AppSyncService {

    let syncDataProviders: SyncDataProvidersSource
    let sync: DDGSync
    let aiChatSyncCleaner: AIChatSyncCleaning
    let syncErrorHandler: SyncErrorHandler
    private let isSyncInProgressCancellable: AnyCancellable

    init(
        bookmarksDatabase: CoreDataDatabase,
        bookmarkManager: BookmarkManager,
        appearancePreferences: AppearancePreferences,
        privacyConfigurationManager: PrivacyConfigurationManaging,
        keyValueStore: ThrowingKeyValueStoring,
        featureFlagger: FeatureFlagger
    ) {
#if DEBUG
        let defaultEnvironment = ServerEnvironment.development
#else
        let defaultEnvironment = ServerEnvironment.production
#endif

        let environment: ServerEnvironment
        let buildType = StandardApplicationBuildType()
        if buildType.isDebugBuild || buildType.isReviewBuild {
            environment = ServerEnvironment(
                UserDefaultsWrapper(key: .syncEnvironment, defaultValue: defaultEnvironment.description).wrappedValue
            ) ?? defaultEnvironment
        } else {
            environment = defaultEnvironment
        }

        let syncErrorHandler = SyncErrorHandler()
        self.syncErrorHandler = syncErrorHandler

        syncDataProviders = SyncDataProvidersSource(
            bookmarksDatabase: bookmarksDatabase,
            bookmarkManager: bookmarkManager,
            appearancePreferences: appearancePreferences,
            syncErrorHandler: syncErrorHandler,
            featureFlagger: featureFlagger
        )

        sync = DDGSync(
            dataProvidersSource: syncDataProviders,
            errorEvents: SyncErrorHandler(),
            privacyConfigurationManager: privacyConfigurationManager,
            keyValueStore: keyValueStore,
            environment: environment
        )

        aiChatSyncCleaner = AIChatSyncCleaner(
            sync: sync,
            keyValueStore: keyValueStore,
            featureFlagProvider: AIChatFeatureFlagProvider(featureFlagger: featureFlagger),
            httpRequestErrorHandler: syncErrorHandler.handleAiChatsError
        )
        sync.setCustomOperations([AIChatDeleteOperation(cleaner: aiChatSyncCleaner)])

        isSyncInProgressCancellable = sync.isSyncInProgressPublisher
            .filter { $0 }
            .asVoid()
            .sink { [weak sync] in
                PixelKit.fire(GeneralPixel.syncDaily, frequency: .legacyDailyNoSuffix)
                sync?.syncDailyStats.sendStatsIfNeeded(handler: { params in
                    PixelKit.fire(GeneralPixel.syncSuccessRateDaily, withAdditionalParameters: params)
                })
            }

        sync.initializeIfNeeded()
        syncDataProviders.setUpDatabaseCleaners(syncService: sync)

        // This is also called in applicationDidBecomeActive, but we're also calling it here, since
        // syncService can be nil when applicationDidBecomeActive is called during startup, if a modal
        // alert is shown before it's instantiated.  In any case it should be safe to call this here,
        // since the scheduler debounces calls to notifyAppLifecycleEvent().
        sync.scheduler.notifyAppLifecycleEvent()
    }

}
