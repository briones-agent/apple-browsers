//
//  SearchTokenRequestTests.swift
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

import XCTest
@testable import DuckDuckGo

final class SearchTokenRequestTests: XCTestCase {

    private let url = URL(string: "https://example.com/search-token")!

    func testSetsUserAgentHeaderAndDecodesEnvelope() async throws {
        var captured: URLRequest?
        let sut = SearchTokenRequest(tokenURL: url, httpFetch: { request in
            captured = request
            let body = #"{"envelope":"tok-xyz"}"#.data(using: .utf8)!
            return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })

        let token = try await sut.requestToken(userAgent: "UA/2.0")

        XCTAssertEqual(token, "tok-xyz")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "User-Agent"), "UA/2.0")
        XCTAssertEqual(captured?.url, url)
    }

    func testThrowsOnMalformedResponse() async {
        let sut = SearchTokenRequest(tokenURL: url, httpFetch: { request in
            ("not json".data(using: .utf8)!,
             HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })

        do {
            _ = try await sut.requestToken(userAgent: "UA")
            XCTFail("expected requestToken to throw on malformed JSON")
        } catch {
            // expected
        }
    }
}
