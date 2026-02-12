//
//  DataClearingPixels.swift
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

import Foundation
import PixelKit

enum DataClearingPixels {

    // Overall Flow Metrics

    /// Fire completed
    case fireCompletion(duration: Int, option: String, domains: String, path: String, autoClear: String)

    /// Fire button retriggered within 20 seconds
    case retriggerIn20s

    // Per-Action Quality Metrics

    case clearWebCacheError(Error)
    case clearWebCacheDuration(Int)

    case clearHistoryError(Error)
    case clearHistoryDuration(entity: String, duration: Int)

    case clearChatHistoryError(Error)
    case clearChatHistoryDuration(Int)

    case clearVisitedLinksDuration(Int)

    case clearVisitsError(Error)
    case clearVisitsDuration(Int)

    case clearLastSessionStateError(Error)
    case clearLastSessionStateDuration(Int)

    case clearTabsError(Error)
    case clearTabsDuration(entity: String, duration: Int)

    case clearDownloadsError(Error)
    case clearDownloadsDuration(Int)

    case clearRecentlyClosedDuration(Int)
}

// MARK: - PixelKitEvent Protocol

extension DataClearingPixels: PixelKitEvent {

    var name: String {
        switch self {
        case .fireCompletion:
            return "m_mac_fire_completion"
        case .retriggerIn20s:
            return "m_mac_fire_retrigger_in_20s"

        case .clearWebCacheError:
            return "m_mac_data_clearing_clear_web_cache_error"
        case .clearWebCacheDuration:
            return "m_mac_data_clearing_clear_web_cache_duration"

        case .clearHistoryError:
            return "m_mac_data_clearing_clear_history_error"
        case .clearHistoryDuration:
            return "m_mac_data_clearing_clear_history_duration"

        case .clearChatHistoryError:
            return "m_mac_data_clearing_clear_chat_history_error"
        case .clearChatHistoryDuration:
            return "m_mac_data_clearing_clear_chat_history_duration"

        case .clearVisitedLinksDuration:
            return "m_mac_data_clearing_clear_visited_links_duration"

        case .clearVisitsError:
            return "m_mac_data_clearing_clear_visits_error"
        case .clearVisitsDuration:
            return "m_mac_data_clearing_clear_visits_duration"

        case .clearLastSessionStateError:
            return "m_mac_data_clearing_clear_last_session_state_error"
        case .clearLastSessionStateDuration:
            return "m_mac_data_clearing_clear_last_session_state_duration"

        case .clearTabsError:
            return "m_mac_data_clearing_clear_tabs_error"
        case .clearTabsDuration:
            return "m_mac_data_clearing_clear_tabs_duration"

        case .clearDownloadsError:
            return "m_mac_data_clearing_clear_downloads_error"
        case .clearDownloadsDuration:
            return "m_mac_data_clearing_clear_downloads_duration"

        case .clearRecentlyClosedDuration:
            return "m_mac_data_clearing_clear_recently_closed_duration"
        }
    }

    var parameters: [String: String]? {
        switch self {
        case .fireCompletion(let duration, let option, let domains, let path, let autoClear):
            return [
                "duration": String(duration),
                "clearing_option": option,
                "domains": domains,
                "path": path,
                "autoClear": autoClear
            ]

        case .clearWebCacheDuration(let duration),
             .clearChatHistoryDuration(let duration),
             .clearDownloadsDuration(let duration),
             .clearRecentlyClosedDuration(let duration),
             .clearVisitedLinksDuration(let duration),
             .clearVisitsDuration(let duration),
             .clearLastSessionStateDuration(let duration):
            return ["duration": String(duration)]

        case .clearHistoryDuration(let entity, let duration),
             .clearTabsDuration(let entity, let duration):
            return ["entity": entity, "duration": String(duration)]

        case .retriggerIn20s,
             .clearWebCacheError, .clearHistoryError, .clearChatHistoryError,
             .clearVisitsError, .clearLastSessionStateError, .clearTabsError, .clearDownloadsError:
            return nil
        }
    }

    var error: NSError? {
        switch self {
        case .clearWebCacheError(let error),
             .clearHistoryError(let error),
             .clearChatHistoryError(let error),
             .clearVisitsError(let error),
             .clearLastSessionStateError(let error),
             .clearTabsError(let error),
             .clearDownloadsError(let error):
            return error as NSError
        default:
            return nil
        }
    }

    var standardParameters: [PixelKitStandardParameter]? {
        return [.pixelSource]
    }
}
