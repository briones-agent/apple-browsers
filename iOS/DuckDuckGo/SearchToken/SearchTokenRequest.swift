//
//  SearchTokenRequest.swift
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

/// Makes the network request for a search token.
protocol SearchTokenRequesting {
    /// Requests a fresh search token
    func requestToken(userAgent: String) async throws -> String
}

/// Concrete `SearchTokenRequesting`: `GET`s the token endpoint with the given `User-Agent` and decodes
/// the `envelope` from the JSON response (`{ "envelope": "<token>" }`).
struct SearchTokenRequest: SearchTokenRequesting {

    private struct Response: Decodable {
        let envelope: String
    }

    private let tokenURL: URL
    private let httpFetch: (URLRequest) async throws -> (Data, URLResponse)

    init(tokenURL: URL,
         httpFetch: @escaping (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }) {
        self.tokenURL = tokenURL
        self.httpFetch = httpFetch
    }

    func requestToken(userAgent: String) async throws -> String {
        var request = URLRequest(url: tokenURL)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await httpFetch(request)
        return try JSONDecoder().decode(Response.self, from: data).envelope
    }
}
