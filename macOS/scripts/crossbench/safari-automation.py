#!/usr/bin/env python3
#
# safari-automation.py — minimal W3C WebDriver client for Safari via safaridriver.
#
# The Safari counterpart of ddg-automation.py. Where DDG exposes a custom HTTP
# AutomationServer, Safari is driven the standard way: `safaridriver -p <port>`
# runs a W3C WebDriver server on http://127.0.0.1:<port>, and this client speaks
# raw WebDriver over it with the stdlib only (no selenium dependency, matching
# the rest of this harness).
#
# WHY A "measure" COMMAND INSTEAD OF navigate/lcp SUBCOMMANDS (as in DDG):
#   WebDriver is session-stateful — navigate and the LCP read must happen inside
#   ONE session. ddg-automation.py can be stateless per-call because the browser
#   holds the state; here we keep the whole lifecycle (new session -> navigate ->
#   dwell -> observe -> delete session) in a single process invocation.
#
# LCP on WebKit: getEntriesByType("largest-contentful-paint") is empty unless an
# observer is live, so we subscribe with buffered:true and resolve after a short
# settle — identical technique to ddg-automation.py, but delivered through
# WebDriver's ASYNC script channel (the result is handed to the callback that
# WebDriver appends as the last argument), not `return await`.
#
# Routing/cert: this client does NOT configure any proxy. Safari has no
# per-instance proxy/cert knob, so test-safari.sh points the whole machine at
# tsproxy via a system SOCKS proxy and trusts WPR's cert in the System keychain.
# By the time we drive Safari, that routing is already in place.
#
# Usage:
#   safari-automation.py <driver_port> check
#       -> exit 0 if a session can be created (remote automation is enabled)
#   safari-automation.py <driver_port> measure <url> [settle_ms] [load_window_secs]
#       -> prints:  detail={...json...}
#                   lcp_ms=<number>            (-1 if no LCP / not finalized)
import json
import sys
import time
import urllib.error
import urllib.request


def base(port):
    return "http://127.0.0.1:{}".format(port)


def _request(port, method, path, body=None, timeout=60):
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(base(port) + path, data=data, method=method)
    if data is not None:
        req.add_header("Content-Type", "application/json; charset=utf-8")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.load(resp)


def new_session(port):
    # W3C nests the result under "value"; be lenient about an older top-level id.
    resp = _request(port, "POST", "/session",
                    {"capabilities": {"alwaysMatch": {"browserName": "safari"}}},
                    timeout=60)
    value = resp.get("value", resp)
    sid = value.get("sessionId") or resp.get("sessionId")
    if not sid:
        raise RuntimeError("no sessionId in new-session response: {}".format(resp))
    return sid


def delete_session(port, sid):
    try:
        _request(port, "DELETE", "/session/{}".format(sid), timeout=15)
    except (urllib.error.URLError, OSError):
        pass  # a dropped teardown response is harmless


def set_script_timeout(port, sid, ms):
    _request(port, "POST", "/session/{}/timeouts".format(sid), {"script": ms}, timeout=15)


def navigate(port, sid, url, timeout=60):
    _request(port, "POST", "/session/{}/url".format(sid), {"url": url}, timeout=timeout)


def execute_async(port, sid, script, timeout=60):
    resp = _request(port, "POST", "/session/{}/execute/async".format(sid),
                    {"script": script, "args": []}, timeout=timeout)
    return resp.get("value")


# The async LCP probe. WebDriver appends a callback as the final argument; we
# resolve it with a detail object (or -1 on failure), never `return`.
def _lcp_probe_js(settle_ms):
    return (
        "var done = arguments[arguments.length - 1];"
        "var v=-1, el=null, url=null, size=0;"
        "try {"
        "new PerformanceObserver(function(list){"
        "list.getEntries().forEach(function(e){"
        "if (e.startTime > v) { v = e.startTime; el = e.element; url = e.url; size = e.size; }"
        "});"
        "}).observe({type:'largest-contentful-paint', buffered:true});"
        "} catch (err) { done(-1); return; }"
        "setTimeout(function(){"
        "done(v < 0 ? -1 : {ms: v, element: el ? el.tagName : null,"
        " id: el ? el.id : null, url: url, size: size});"
        "}, " + str(int(settle_ms)) + ");"
    )


def check(port):
    try:
        sid = new_session(port)
    except (urllib.error.URLError, OSError) as e:
        print("safaridriver not reachable on {}: {}".format(base(port), e), file=sys.stderr)
        return 1
    except urllib.error.HTTPError as e:
        print("session creation refused (HTTP {}). Is remote automation enabled?".format(e.code),
              file=sys.stderr)
        return 1
    except Exception as e:  # noqa: BLE001 — surface any capability/handshake error
        print("session creation failed: {}".format(e), file=sys.stderr)
        return 1
    delete_session(port, sid)
    return 0


def measure(port, url, settle_ms, load_window_secs):
    sid = None
    detail = -1
    try:
        sid = new_session(port)
        set_script_timeout(port, sid, 30000)
        navigate(port, sid, url)
        # Dwell so late-arriving LCP candidates land before we read (mirrors the
        # LOAD_WINDOW sleep test-ddg.sh does between navigate and lcp).
        time.sleep(load_window_secs)
        detail = execute_async(port, sid, _lcp_probe_js(settle_ms))
    except (urllib.error.URLError, OSError, urllib.error.HTTPError) as e:
        print("measure failed for {}: {}".format(url, e), file=sys.stderr)
    finally:
        if sid:
            delete_session(port, sid)

    if isinstance(detail, dict):
        lcp = detail.get("ms", -1)
    else:
        lcp = detail if isinstance(detail, (int, float)) else -1
    print("detail={}".format(json.dumps(detail)))
    print("lcp_ms={}".format(lcp))
    return 0


USAGE = (
    "usage:\n"
    "  safari-automation.py <driver_port> check\n"
    "  safari-automation.py <driver_port> measure <url> [settle_ms] [load_window_secs]"
)


def main(argv):
    if len(argv) < 3:
        print(USAGE, file=sys.stderr)
        return 2
    port = argv[1]
    cmd = argv[2]
    rest = argv[3:]

    if cmd == "check":
        return check(port)
    if cmd == "measure":
        if not rest:
            print("measure requires a url", file=sys.stderr)
            return 2
        url = rest[0]
        settle = float(rest[1]) if len(rest) > 1 else 600.0
        window = float(rest[2]) if len(rest) > 2 else 12.0
        return measure(port, url, settle, window)

    print("unknown command: {}".format(cmd), file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
