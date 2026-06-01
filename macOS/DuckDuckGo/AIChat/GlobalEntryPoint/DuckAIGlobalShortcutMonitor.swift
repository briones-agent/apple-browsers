//
//  DuckAIGlobalShortcutMonitor.swift
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

import AppKit
import HotKey

/// Registers a global Ctrl+Option+Space hot key via Carbon `RegisterEventHotKey`
/// (wrapped by `soffes/HotKey`).
///
/// Carbon's hot-key API works system-wide without the Accessibility permission
/// `NSEvent.addGlobalMonitorForEvents` would require — that's the whole reason
/// we picked this over the original M9 plan.
///
/// `start()` is idempotent; `stop()` releases the underlying registration.
@MainActor
final class DuckAIGlobalShortcutMonitor {

    var onTriggered: (() -> Void)?

    private var hotKey: HotKey?

    func start() {
        guard hotKey == nil else { return }
        let key = HotKey(key: .space, modifiers: [.control, .option])
        key.keyDownHandler = { [weak self] in
            self?.onTriggered?()
        }
        hotKey = key
    }

    func stop() {
        hotKey = nil
    }
}
