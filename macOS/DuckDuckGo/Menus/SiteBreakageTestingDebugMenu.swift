//
//  SiteBreakageTestingDebugMenu.swift
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

import AppKit
import Common
import os.log

/// Debug-menu helper that writes a self-contained folder to the Desktop with a local server and test pages
/// exercising the site-breakage diagnostic signals. Mirrors the Sparkle update testing environment pattern.
final class SiteBreakageTestingDebugMenu: NSMenu {

    private static let folderName = "ddg-site-breakage-testing"

    init() {
        super.init(title: "")

        buildItems {
            NSMenuItem(title: "Set up site-breakage testing environment…", action: #selector(setupEnvironment))
                .targetting(self)
            NSMenuItem(title: "Open testing folder", action: #selector(openFolder))
                .targetting(self)
        }
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var testingDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop")
            .appendingPathComponent(Self.folderName)
    }

    @objc func setupEnvironment() {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: testingDir, withIntermediateDirectories: true)

            try SiteBreakageTestingResources.serverScript
                .write(to: testingDir.appendingPathComponent("serve_breakage.py"), atomically: true, encoding: .utf8)
            let readmeURL = testingDir.appendingPathComponent("README.md")
            try SiteBreakageTestingResources.readme
                .write(to: readmeURL, atomically: true, encoding: .utf8)

            NSWorkspace.shared.open(readmeURL)
        } catch {
            Logger.siteBreakage.error("Failed to set up site-breakage testing environment: \(error.localizedDescription, privacy: .public)")
            let alert = NSAlert()
            alert.messageText = "Failed to set up testing environment"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    @objc func openFolder() {
        if FileManager.default.fileExists(atPath: testingDir.path) {
            NSWorkspace.shared.open(testingDir)
        } else {
            let alert = NSAlert()
            alert.messageText = "Testing folder not found"
            alert.informativeText = "Run “Set up site-breakage testing environment…” first."
            alert.runModal()
        }
    }
}

// MARK: - Site Breakage Testing Resources

private enum SiteBreakageTestingResources {

    static let readme = """
    # Site-breakage diagnostic logging — test harness

    Local pages that exercise the site-breakage signals logged under
    `Logger.siteBreakage` (subsystem "Privacy Dashboard", category "Site Breakage").

    ## Prerequisites

    An internal build. The `siteBreakageLogging` feature flag defaults on for internal
    users — check Debug ▸ Feature Flags if you see no output.

    ## Run

        cd ~/Desktop/ddg-site-breakage-testing
        python3 serve_breakage.py

    Then open http://localhost:8444/ in DuckDuckGo.

    ## Reading the output

    1. Open a test page and let it finish loading.
    2. Click the privacy-shield button in the address bar — this is what emits the digest.
    3. Open Console.app and filter subsystem "Privacy Dashboard", category "Site Breakage".
    4. Hosts appear hashed; counts, failure classes, and flags are in cleartext.

    ## What each page covers

    - Subresource failures — resolve, unreachable, 4xx, 5xx, cert (external badssl.com),
      and an unfinished subresource (an image that never finishes loading).
    - Blocked trackers — content-block tallies. Depends on the tracker blocklist.
    - HTTPS upgrade — `madeHTTPS`. Best-effort; depends on the HTTPS-upgrade list.
    - Blank page — render-health blank detection. Milestone-dependent.

    ## Not reproducible synthetically

    - Network-connection-integrity failure — fires only from WebKit's own protection logic.
    - Storage-access quirk — fires only for domains on WebKit's hardcoded quirk list.

    Neither can be provoked by a static page or local server; they need a real fragile site.

    ## Cleanup

    Stop the server with Ctrl+C and delete this folder.
    """

    static let serverScript = #"""
    #!/usr/bin/env python3
    """Local server exercising DuckDuckGo site-breakage diagnostic logging.

    Usage:
        cd ~/Desktop/ddg-site-breakage-testing
        python3 serve_breakage.py
    Then open http://localhost:8444/ in DuckDuckGo.
    """

    import http.server
    import time

    PORT = 8444

    INDEX = """<!doctype html>
    <html><head><meta charset="utf-8"><title>DDG site-breakage test</title></head>
    <body>
    <h1>Site-breakage test pages</h1>
    <p>Open each page in DuckDuckGo, let it finish loading, then click the
    privacy-shield button in the address bar to emit the digest. View it in
    Console.app filtered to subsystem <code>Privacy Dashboard</code>,
    category <code>Site Breakage</code>.</p>
    <ul>
    <li><a href="/resource-failures">Subresource failures</a> &mdash; resolve / unreachable / 4xx / 5xx / cert / unfinished</li>
    <li><a href="/trackers">Blocked trackers</a> &mdash; content-block tallies</li>
    <li><a href="/http-upgrade">HTTPS upgrade</a> &mdash; madeHTTPS</li>
    <li><a href="/blank">Blank page</a> &mdash; render health</li>
    </ul>
    </body></html>
    """

    RESOURCE_FAILURES = """<!doctype html>
    <html><head><meta charset="utf-8"><title>Subresource failures</title></head>
    <body>
    <h1>Subresource failures</h1>
    <p>Each resource below fails in a different way.</p>
    <img src="https://nonexistent-ddg-test-host-xyz.invalid/a.png" alt="resolve">
    <img src="http://127.0.0.1:1/a.png" alt="unreachable">
    <img src="http://localhost:8444/status/404" alt="4xx">
    <img src="http://localhost:8444/status/500" alt="5xx">
    <img src="http://localhost:8444/hang" alt="unfinished subresource">
    <script src="https://expired.badssl.com/static/js/main.js"></script>
    </body></html>
    """

    TRACKERS = """<!doctype html>
    <html><head><meta charset="utf-8"><title>Blocked trackers</title></head>
    <body>
    <h1>Blocked trackers</h1>
    <p>References known trackers that DuckDuckGo blocks.</p>
    <script src="https://www.google-analytics.com/analytics.js"></script>
    <script src="https://securepubads.g.doubleclick.net/tag/js/gpt.js"></script>
    <img src="https://www.facebook.com/tr?id=000000000000000&ev=PageView" alt="fb pixel">
    </body></html>
    """

    HTTP_UPGRADE = """<!doctype html>
    <html><head><meta charset="utf-8"><title>HTTPS upgrade</title></head>
    <body>
    <h1>HTTPS upgrade</h1>
    <p>References an http:// subresource on an upgradable host (best-effort &mdash;
    depends on the HTTPS-upgrade list).</p>
    <img src="http://www.theguardian.com/favicon.ico" alt="upgrade">
    </body></html>
    """

    BLANK = "<!doctype html><html><head><title>blank</title></head><body></body></html>"


    class Handler(http.server.BaseHTTPRequestHandler):
        def _send(self, body, status=200, ctype="text/html; charset=utf-8"):
            data = body.encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            path = self.path.split("?", 1)[0]
            if path == "/":
                self._send(INDEX)
            elif path == "/resource-failures":
                self._send(RESOURCE_FAILURES)
            elif path == "/trackers":
                self._send(TRACKERS)
            elif path == "/http-upgrade":
                self._send(HTTP_UPGRADE)
            elif path == "/blank":
                self._send(BLANK)
            elif path.startswith("/status/"):
                try:
                    code = int(path.rsplit("/", 1)[1])
                except ValueError:
                    code = 400
                self._send("<h1>%d</h1>" % code, status=code)
            elif path == "/hang":
                # Never respond — keeps the subresource pending forever so the page finishes
                # loading with subresources still outstanding.
                while True:
                    time.sleep(60)
            else:
                self._send("<h1>404</h1>", status=404)

        def log_message(self, *args):
            pass


    if __name__ == "__main__":
        # Threading so a pending /hang request doesn't block the other pages.
        server = http.server.ThreadingHTTPServer(("localhost", PORT), Handler)
        print("Serving site-breakage test pages on http://localhost:%d/" % PORT)
        print("Open that URL in DuckDuckGo. Press Ctrl+C to stop.")
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            print("\nStopped")
    """#

}
