//
//  ReleaseNotesParser.swift
//
//  Copyright © 2024 DuckDuckGo. All rights reserved.
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
import SwiftSoup

public final class ReleaseNotesParser {

    public static func parseReleaseNotes(from description: String?) -> ([String], [String]) {
        guard let description else { return ([], []) }

        do {
            let document = try SwiftSoup.parse(description)
            let standardReleaseNotes = try releaseNotes(in: document, forSectionTitled: "What's new")
            let subscriptionReleaseNotes = try releaseNotes(in: document, forSectionTitled: "For DuckDuckGo subscribers")
            return (standardReleaseNotes, subscriptionReleaseNotes)
        } catch {
            assertionFailure("Error parsing release notes HTML: \(error)")
            return ([], [])
        }
    }

    /// Returns the plain-text list items from the `<ul>` immediately following the `<h3>` with the given title.
    private static func releaseNotes(in document: Document, forSectionTitled title: String) throws -> [String] {
        guard let header = try document.select("h3").first(where: { try $0.text() == title }),
              let list = try header.nextElementSibling(), list.tagName() == "ul" else {
            return []
        }

        return try list.select("li").map { try $0.text() }
    }
}
