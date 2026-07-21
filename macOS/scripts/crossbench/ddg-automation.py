#!/usr/bin/env python3
#
# ddg-automation.py — minimal client for the DuckDuckGo macOS AutomationServer.
#
# The AutomationServer is a plain HTTP server the app runs on Debug/Review builds
# only (LaunchOptionsHandler.automationPort). It binds IPv6 loopback, so the base
# URL is http://[::1]:<port>. Responses are JSON: {"message": <string>, ...},
# where for /execute `message` is the JS return value already encoded as a string
# (a bare number for a numeric result, a JSON-quoted string for a string, etc.).
#
# IMPORTANT: script text is percent-encoded with %20 for spaces, NOT '+'. The
# server percent-decodes the query but does not treat '+' as a space, so a '+'
# encoding silently corrupts the script (e.g. `return document.title` becomes
# `+document.title` => NaN). urllib.parse.quote(safe="") gets this right.
#
# Used by test-ddg.sh to drive the browser for LCP measurement. Not a general
# WebDriver client — just the few routes the perf harness needs.
#
# Usage:
#   ddg-automation.py <port> ping
#   ddg-automation.py <port> wait-ready [timeout_secs]
#   ddg-automation.py <port> navigate <url>
#   ddg-automation.py <port> execute <script>          # or script on stdin if omitted
#   ddg-automation.py <port> lcp [settle_ms]           # prints LCP in ms (or -1)
#   ddg-automation.py <port> lcp-detail [settle_ms]    # prints JSON: element/url/size/ms
#   ddg-automation.py <port> title
#   ddg-automation.py <port> shutdown
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


def base(port):
    return "http://[::1]:{}".format(port)


def _request(port, path, query="", method="GET", timeout=30):
    url = "{}{}".format(base(port), path)
    if query:
        url += "?" + query
    req = urllib.request.Request(url, method=method)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.load(resp)


def _message(port, path, query="", method="GET", timeout=30):
    return _request(port, path, query=query, method=method, timeout=timeout).get("message")


def navigate(port, url):
    q = "url=" + urllib.parse.quote(url, safe="")
    return _message(port, "/navigate", query=q, timeout=60)


def execute(port, script):
    q = "script=" + urllib.parse.quote(script, safe="")
    # Script comes from the URL query string (not the body); POST with an empty body.
    return _message(port, "/execute", query=q, method="POST", timeout=60)


def content_blocker_ready(port):
    return _message(port, "/contentBlockerReady", timeout=10)


def ping(port):
    try:
        content_blocker_ready(port)
        return True
    except (urllib.error.URLError, OSError):
        return False


def wait_ready(port, timeout_secs):
    """Block until the server answers AND the content blocker has compiled its
    rules — navigating before that skews the first measurement."""
    deadline = time.monotonic() + timeout_secs
    while time.monotonic() < deadline:
        try:
            if str(content_blocker_ready(port)).lower() == "true":
                return True
        except (urllib.error.URLError, OSError):
            pass
        time.sleep(0.5)
    return False


# LCP on WebKit: getEntriesByType("largest-contentful-paint") returns nothing
# unless an observer is live, so subscribe with buffered:true (replays entries
# recorded before subscription), take the largest startTime, and resolve after a
# short settle. Runs as an async function body via callAsyncJavaScript, so
# top-level `return await` is valid.
def _lcp_probe_js(settle_ms, detail):
    if detail:
        result = (
            "r({ms: v, element: el ? el.tagName : null, "
            "id: el ? el.id : null, url: url, size: size});"
        )
    else:
        result = "r(v);"
    return (
        "return await new Promise(function(r){"
        "var v=-1, el=null, url=null, size=0;"
        "try {"
        "new PerformanceObserver(function(list){"
        "list.getEntries().forEach(function(e){"
        "if (e.startTime > v) { v = e.startTime; el = e.element; url = e.url; size = e.size; }"
        "});"
        "}).observe({type:'largest-contentful-paint', buffered:true});"
        "} catch (err) { r(-1); return; }"
        "setTimeout(function(){" + result + "}, " + str(int(settle_ms)) + ");"
        "});"
    )


def lcp(port, settle_ms):
    return execute(port, _lcp_probe_js(settle_ms, detail=False))


def lcp_detail(port, settle_ms):
    return execute(port, _lcp_probe_js(settle_ms, detail=True))


def title(port):
    return execute(port, "return document.title;")


def main(argv):
    if len(argv) < 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    port = argv[1]
    cmd = argv[2]
    rest = argv[3:]

    try:
        if cmd == "ping":
            return 0 if ping(port) else 1
        if cmd == "wait-ready":
            timeout = float(rest[0]) if rest else 60.0
            if wait_ready(port, timeout):
                return 0
            print("automation server not ready within {}s".format(timeout), file=sys.stderr)
            return 1
        if cmd == "navigate":
            print(navigate(port, rest[0]))
            return 0
        if cmd == "execute":
            script = rest[0] if rest else sys.stdin.read()
            print(execute(port, script))
            return 0
        if cmd == "lcp":
            settle = float(rest[0]) if rest else 600
            print(lcp(port, settle))
            return 0
        if cmd == "lcp-detail":
            settle = float(rest[0]) if rest else 600
            print(lcp_detail(port, settle))
            return 0
        if cmd == "title":
            print(title(port))
            return 0
        if cmd == "shutdown":
            try:
                print(_message(port, "/shutdown", timeout=5))
            except (urllib.error.URLError, OSError):
                pass  # server tears itself down; a dropped response is expected
            return 0
    except urllib.error.HTTPError as e:
        print("HTTP {} for {}".format(e.code, cmd), file=sys.stderr)
        return 1
    except (urllib.error.URLError, OSError) as e:
        print("connection error for {}: {}".format(cmd, e), file=sys.stderr)
        return 1

    print("unknown command: {}".format(cmd), file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
