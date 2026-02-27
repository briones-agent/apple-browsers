//
//  EventHubTimer.swift
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

public protocol EventHubTimer {
    func cancel()
}

public protocol EventHubTimerFactory {
    func makeTimer(delay: TimeInterval, handler: @escaping () -> Void) -> EventHubTimer
}

public final class DefaultEventHubTimerFactory: EventHubTimerFactory {
    public init() {}

    public func makeTimer(delay: TimeInterval, handler: @escaping () -> Void) -> EventHubTimer {
        DispatchSourceTimerWrapper(delay: delay, handler: handler)
    }
}

final class DispatchSourceTimerWrapper: EventHubTimer {
    private let timer: DispatchSourceTimer

    init(delay: TimeInterval, handler: @escaping () -> Void) {
        timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler(handler: handler)
        timer.resume()
    }

    func cancel() {
        timer.cancel()
    }
}
