//
//  AutoplayPreferences.swift
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

enum AutoplayBlockingMode: String, CaseIterable, CustomStringConvertible {
    case allowAll
    case blockAudio
    case blockAll

    var description: String {
        switch self {
        case .allowAll: return UserText.autoplayModeAllowAll
        case .blockAudio: return UserText.autoplayModeBlockAudio
        case .blockAll: return UserText.autoplayModeBlockAll
        }
    }
}

protocol AutoplayPreferencesPersistor {
    var autoplayBlockingModeRawValue: String { get set }
}

struct AutoplayPreferencesUserDefaultsPersistor: AutoplayPreferencesPersistor {
    @UserDefaultsWrapper(key: .autoplayBlockingMode, defaultValue: AutoplayBlockingMode.blockAudio.rawValue)
    var autoplayBlockingModeRawValue: String
}

final class AutoplayPreferences: ObservableObject {

    @Published var autoplayBlockingMode: AutoplayBlockingMode {
        didSet {
            persistor.autoplayBlockingModeRawValue = autoplayBlockingMode.rawValue
            switch autoplayBlockingMode {
            case .allowAll:
                PixelKit.fire(GeneralPixel.autoplaySettingAllowAll, doNotEnforcePrefix: true)
            case .blockAudio:
                PixelKit.fire(GeneralPixel.autoplaySettingBlockAudio, doNotEnforcePrefix: true)
            case .blockAll:
                PixelKit.fire(GeneralPixel.autoplaySettingBlockAll, doNotEnforcePrefix: true)
            }
        }
    }

    init(persistor: AutoplayPreferencesPersistor = AutoplayPreferencesUserDefaultsPersistor()) {
        self.persistor = persistor
        self.autoplayBlockingMode = AutoplayBlockingMode(rawValue: persistor.autoplayBlockingModeRawValue) ?? .blockAudio
    }

    private var persistor: AutoplayPreferencesPersistor
}
