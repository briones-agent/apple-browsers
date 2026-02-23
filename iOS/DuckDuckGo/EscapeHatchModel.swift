//
//  EscapeHatchModel.swift
//  DuckDuckGo
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

import Foundation

/// Model for the NTP "Return to..." escape hatch card that navigates to the most recently used tab.
///
/// **Most recently used tab rule:** When the current tab is the NTP (home), the tab to show in the
/// escape hatch is the one we switched away from — i.e. the tab at index `currentIndex - 1`, only
/// when `tabs.count > 1` and `currentIndex > 0`. If there is only one tab, no escape hatch is shown.
struct EscapeHatchModel: Equatable {

    /// Display title (e.g. page title or "Duck.ai" for AI tab).
    let title: String

    /// Subtitle (e.g. URL host/path for a site, or "Duck.ai" for AI tab).
    let subtitle: String

    /// When true, the card shows the Duck.ai logo; when false, it shows the site favicon.
    let isAITab: Bool

    /// Domain for favicon loading when `isAITab` is false (e.g. `link?.url.host`). Ignored when `isAITab` is true.
    let domain: String?
}
