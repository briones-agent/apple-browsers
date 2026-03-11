//
//  Initializing.swift
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

import Common
import Crashes
import Foundation
import PixelKit

@MainActor
struct Initializing: InitializingHandling {

    init() {}

    func handleWillFinishLaunching() {
        let didCrashDuringCrashHandlersSetUp = UserDefaultsWrapper(key: .didCrashDuringCrashHandlersSetUp, defaultValue: false)
        if case .normal = AppVersion.runType,
           !didCrashDuringCrashHandlersSetUp.wrappedValue {
            didCrashDuringCrashHandlersSetUp.wrappedValue = true
            CrashLogMessageExtractor.setUp(swapCxaThrow: false)
            didCrashDuringCrashHandlersSetUp.wrappedValue = false
        }

        if AppVersion.runType.requiresEnvironment {
            AppDelegate.configurePixelKit()
        }
    }

    func makeLaunchingState() throws -> any LaunchingHandling {
        try Launching()
    }

}
