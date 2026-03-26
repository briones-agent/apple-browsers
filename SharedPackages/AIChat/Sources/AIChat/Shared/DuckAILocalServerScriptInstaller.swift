//
//  DuckAILocalServerScriptInstaller.swift
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

import WebKit

public enum DuckAILocalServerScriptInstaller {

    /// Installs all local server user scripts (port injection, migration, and DEBUG fetch bridge)
    /// onto the given `WKUserContentController`.
    ///
    /// - Parameters:
    ///   - controller: The user content controller to install scripts on.
    ///   - port: The local server port number.
    /// - Returns: On DEBUG builds, a `DuckAILocalServerFetchBridge` that must be retained
    ///   for the lifetime of the web view. On release builds, returns `nil`.
    @discardableResult
    public static func install(on controller: WKUserContentController, port: UInt16) -> AnyObject? {
        let portScript = WKUserScript(
            source: portInjectionJavaScript(port: port),
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        controller.addUserScript(portScript)

        let migrationUserScript = WKUserScript(
            source: migrationScript(port: port),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        controller.addUserScript(migrationUserScript)

        let fetchBridge = DuckAILocalServerFetchBridge()
        controller.addScriptMessageHandler(fetchBridge, contentWorld: .page, name: DuckAILocalServerFetchBridge.handlerName)
        controller.addUserScript(DuckAILocalServerFetchBridge.fetchOverrideScript)
        return fetchBridge
    }

    /// Returns the port injection JavaScript string for use with `evaluateJavaScript`.
    /// Use this on macOS where the Tab's UserContentController manages WKUserScripts
    /// and would wipe scripts added directly.
    public static func portInjectionJavaScript(port: UInt16) -> String {
        """
        (function() {
            const host = location.hostname;
            if (host !== 'duckduckgo.com' && host !== 'duck.ai') return;
            window.__duckAiNativeServer = { port: \(port) };
        })();
        """
    }

    /// Returns the migration JavaScript string for use with `evaluateJavaScript`.
    public static func migrationJavaScript(port: UInt16) -> String {
        migrationScript(port: port)
    }

    /// Registers the DEBUG fetch bridge message handler on the given webview's content controller
    /// and returns the fetch override JS to inject via `evaluateJavaScript`.
    /// The returned `AnyObject?` must be retained for the lifetime of the webview.
    /// Returns `(bridge, js)` on DEBUG builds, `(nil, nil)` on release.
    public static func installFetchBridge(on webView: WKWebView) -> (retainer: AnyObject?, javaScript: String?) {
        let bridge = DuckAILocalServerFetchBridge()
        webView.configuration.userContentController.addScriptMessageHandler(
            bridge,
            contentWorld: .page,
            name: DuckAILocalServerFetchBridge.handlerName
        )
        return (bridge, DuckAILocalServerFetchBridge.fetchOverrideScript.source)
    }

    private static func migrationScript(port: UInt16) -> String {
        """
        (async function() {
            try {
                const host = location.hostname;
                if (host !== 'duckduckgo.com' && host !== 'duck.ai') return;

                const base = 'http://127.0.0.1:\(port)';
                const origin = location.origin;

                const migResp = await fetch(base + '/migration', {
                    headers: { 'Origin': origin }
                });
                if (!migResp.ok) return;
                const migData = await migResp.json();
                if (migData.done) return;

                const settings = {};
                for (let i = 0; i < localStorage.length; i++) {
                    const key = localStorage.key(i);
                    settings[key] = localStorage.getItem(key);
                }

                const putResp = await fetch(base + '/settings', {
                    method: 'PUT',
                    headers: {
                        'Content-Type': 'application/json',
                        'Origin': origin
                    },
                    body: JSON.stringify(settings)
                });
                if (!putResp.ok) return;

                const doneResp = await fetch(base + '/migration', {
                    method: 'POST',
                    headers: { 'Origin': origin }
                });
                if (!doneResp.ok) {
                    console.error('DuckAI migration: failed to mark done');
                }
            } catch(e) {
                console.error('DuckAI migration failed:', e);
            }
        })();
        """
    }
}
