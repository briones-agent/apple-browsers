//
//  DataClearingPixels.swift
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

import Foundation
import PixelKit

enum DataClearingPixels {

    // MARK: - Overall Flow Metrics

    case clearingCompletion(duration: Int, option: String, trigger: String, scope: String, source: String)
    case retriggerIn20s
    case userActionBeforeCompletion

    // MARK: - Tab Manager

    case clearTabsDuration(duration: Int, scope: String)
    case clearTabsError(Error)

    // MARK: - URL Cache

    case clearURLCacheDuration(Int)

    // MARK: - History

    case clearHistoryDuration(duration: Int, scope: String)
    case clearHistoryError(Error)

    // MARK: - AI Chat History

    case clearAIChatHistoryDuration(duration: Int, scope: String)
    case clearAIChatHistoryError(Error)
}

// MARK: - PixelKitEvent Protocol

extension DataClearingPixels: PixelKitEvent {

    var name: String {
        switch self {
        case .clearingCompletion:
            return "m_fire_clearing_completion"
        case .retriggerIn20s:
            return "m_fire_retrigger_in_20s"
        case .userActionBeforeCompletion:
            return "m_fire_user_action_before_completion"

        case .clearTabsDuration:
            return "m_data_clearing_clear_tabs_duration"
        case .clearTabsError:
            return "m_data_clearing_clear_tabs_error"

        case .clearURLCacheDuration:
            return "m_data_clearing_clear_url_cache_duration"

        case .clearHistoryDuration:
            return "m_data_clearing_clear_history_duration"
        case .clearHistoryError:
            return "m_data_clearing_clear_history_error"

        case .clearAIChatHistoryDuration:
            return "m_data_clearing_clear_ai_chat_history_duration"
        case .clearAIChatHistoryError:
            return "m_data_clearing_clear_ai_chat_history_error"
        }
    }

    var parameters: [String: String]? {
        switch self {
        case .clearingCompletion(let duration, let option, let trigger, let scope, let source):
            return [
                "duration": String(duration),
                "option": option,
                "trigger": trigger,
                "scope": scope,
                "source": source
            ]

        case .clearURLCacheDuration(let duration):
            return ["duration": String(duration)]
            
        case .clearTabsDuration(let duration, let scope),
             .clearHistoryDuration(let duration, let scope),
             .clearAIChatHistoryDuration(let duration, let scope):
            return ["duration": String(duration), "scope": scope]
            
        case .retriggerIn20s, .userActionBeforeCompletion,
             .clearTabsError, .clearHistoryError, .clearAIChatHistoryError:
            return nil
        }
    }

    var error: NSError? {
        switch self {
        case .clearTabsError(let error),
             .clearHistoryError(let error),
             .clearAIChatHistoryError(let error):
            return error as NSError
        default:
            return nil
        }
    }

    var standardParameters: [PixelKitStandardParameter]? {
        return [.pixelSource]
    }
}
