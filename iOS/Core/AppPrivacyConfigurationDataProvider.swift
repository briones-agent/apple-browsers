//
//  AppPrivacyConfigurationDataProvider.swift
//  Core
//
//  Copyright © 2021 DuckDuckGo. All rights reserved.
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
import PrivacyConfig

final public class AppPrivacyConfigurationDataProvider: EmbeddedDataProvider {

    public struct Constants {
        public static let embeddedDataETag = "\"fdeefcd139d5d8559c4ae63aa76bfbdd4ab3ba27c6de5ca2537038bfa902d2d2\""
        public static let embeddedDataSHA = "9415d8849ec6bba2f8a08981e862df4264399513cb2c4ab011122466b3004813"
    }

    public var embeddedDataEtag: String {
        return Constants.embeddedDataETag
    }

    public var embeddedData: Data {
        return Self.loadEmbeddedAsData()
    }

    static var embeddedUrl: URL {
        if let url = Bundle.main.url(forResource: "ios-config", withExtension: "json") {
            return url
        }

        return Bundle(for: self).url(forResource: "ios-config", withExtension: "json")!
    }

    static func loadEmbeddedAsData() -> Data {
        do {
            return try Data(contentsOf: embeddedUrl)
        } catch {
            fatalError("Failed to load embedded privacy config: \(error.localizedDescription)")
        }
    }

    public init() {}
}
