//
//  DuckAILocalServerFetchBridge.swift
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
//

import WebKit

final class DuckAILocalServerFetchBridge: NSObject, WKScriptMessageHandlerWithReply {
    static let handlerName = "duckAILocalServerFetch"

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard let body = message.body as? [String: Any],
              let urlString = body["url"] as? String,
              let url = URL(string: urlString) else {
            replyHandler(nil, "Invalid request")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = (body["method"] as? String) ?? "GET"

        if let headers = body["headers"] as? [String: String] {
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }

        if let bodyString = body["body"] as? String {
            request.httpBody = bodyString.data(using: .utf8)
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                replyHandler(nil, error.localizedDescription)
                return
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                replyHandler(nil, "Not an HTTP response")
                return
            }

            let result: [String: Any] = [
                "status": httpResponse.statusCode,
                "headers": httpResponse.allHeaderFields as? [String: String] ?? [:],
                "body": data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            ]
            replyHandler(result, nil)
        }.resume()
    }

    static var fetchOverrideScript: WKUserScript {
        let js = """
        (function() {
            const host = location.hostname;
            if (host !== 'duckduckgo.com' && host !== 'duck.ai') return;

            const originalFetch = window.fetch;
            window.fetch = async function(input, init) {
                let url, method, headers, bodyText;

                if (input instanceof Request) {
                    url = input.url;
                    method = init?.method || input.method || 'GET';
                    headers = init?.headers || input.headers;
                    bodyText = (init?.body != null) ? init.body
                             : (input.body != null) ? await input.clone().text()
                             : null;
                } else {
                    url = (typeof input === 'string') ? input : String(input);
                    method = (init && init.method) || 'GET';
                    headers = (init && init.headers) || {};
                    bodyText = (init && init.body) || null;
                }

                if (!url || !url.startsWith('http://127.0.0.1')) {
                    return originalFetch.apply(this, arguments);
                }

                const headerObj = {};
                if (headers instanceof Headers) {
                    headers.forEach((v, k) => { headerObj[k] = v; });
                } else if (typeof headers === 'object') {
                    Object.assign(headerObj, headers);
                }

                const result = await window.webkit.messageHandlers.\(handlerName).postMessage(
                    { url: url, method: method, headers: headerObj, body: bodyText }
                );
                const nullBodyStatuses = [101, 204, 205, 304];
                const responseBody = nullBodyStatuses.includes(result.status) ? null : result.body;
                return new Response(responseBody, {
                    status: result.status,
                    headers: result.headers
                });
            };
        })();
        """
        return WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }
}
