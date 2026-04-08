//
//  WebTelemetryTabExtension.swift
//
//  Copyright © 2025 DuckDuckGo. All rights reserved.
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
import PixelKit

final class WebTelemetryTabExtension: WebTelemetrySubfeatureDelegate {

    private var cancellables: Set<AnyCancellable> = []

    @MainActor
    init(userScriptsPublisher: some Publisher<some UserScriptsProvider, Never>) {
        userScriptsPublisher.sink { [weak self] userScripts in
            guard let self, let userScripts = userScripts as? UserScripts else { return }
            userScripts.webTelemetrySubfeature.delegate = self
        }.store(in: &cancellables)
    }

    @MainActor
    func webTelemetryDidDetectVideoPlayback(userInteraction: Bool) {
        PixelKit.fire(GeneralPixel.webTelemetryVideoPlayback(userInteraction: userInteraction))
    }
}
