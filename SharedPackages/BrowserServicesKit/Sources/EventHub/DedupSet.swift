//
//  DedupSet.swift
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

final class DedupSet {

    private var seen: Set<String> = []

    /// Returns `true` if the event is a duplicate (already seen). Returns `false` for the first occurrence.
    func isDuplicate(pixelName: String, paramName: String, source: String, tabId: String?) -> Bool {
        guard let tabId, !tabId.isEmpty else {
            return false
        }

        let key = "\(pixelName):\(paramName):\(source):\(tabId)"

        let (inserted, _) = seen.insert(key)
        return !inserted
    }

    func removeAll(forTabId tabId: String) {
        let suffix = ":\(tabId)"
        seen = seen.filter { !$0.hasSuffix(suffix) }
    }

    func removeAll() {
        seen.removeAll()
    }

    var count: Int {
        seen.count
    }
}
