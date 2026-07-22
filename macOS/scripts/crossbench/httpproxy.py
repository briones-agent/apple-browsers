#!/usr/bin/env python3
# Minimal HTTP forward proxy that redirects ALL traffic to a local WPR instance,
# so Safari (pointed here via the com.apple.Safari WebKit2HTTPProxy/HTTPSProxy
# defaults) replays from WPR with NO machine-wide system proxy.
#   CONNECT host:443     -> tunnel to 127.0.0.1:WPR_HTTPS (WPR terminates TLS via SNI)
#   GET http://host/path -> rewrite to origin-form, forward to 127.0.0.1:WPR_HTTP
# The requested host is ignored for routing (always WPR); it's only logged so the
# caller can prove Safari's traffic actually traversed the proxy.
# Usage: httpproxy.py <listen_port> <wpr_http_port> <wpr_https_port>
import socket
import select
import sys
import threading

LISTEN    = int(sys.argv[1]) if len(sys.argv) > 1 else 9998
WPR_HTTP  = int(sys.argv[2]) if len(sys.argv) > 2 else 8080
WPR_HTTPS = int(sys.argv[3]) if len(sys.argv) > 3 else 8081


def log(msg):
    sys.stderr.write(msg + "\n")
    sys.stderr.flush()


def pipe(a, b):
    try:
        while True:
            r, _, _ = select.select([a, b], [], [])
            for s in r:
                data = s.recv(65536)
                if not data:
                    return
                (b if s is a else a).sendall(data)
    except OSError:
        pass
    finally:
        for s in (a, b):
            try:
                s.close()
            except OSError:
                pass


def handle(client):
    up = None
    try:
        client.settimeout(30)
        buf = b""
        while b"\r\n\r\n" not in buf:
            chunk = client.recv(4096)
            if not chunk:
                client.close()
                return
            buf += chunk
        head, _, rest = buf.partition(b"\r\n\r\n")
        lines = head.split(b"\r\n")
        parts = lines[0].split(b" ")
        if len(parts) < 3:
            client.close()
            return
        method, target, ver = parts[0], parts[1], parts[2]

        if method == b"CONNECT":
            log("CONNECT %s -> 127.0.0.1:%d" % (target.decode(errors="replace"), WPR_HTTPS))
            up = socket.create_connection(("127.0.0.1", WPR_HTTPS))
            client.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
            if rest:
                up.sendall(rest)
            pipe(client, up)
        else:
            path = target
            if target.startswith(b"http://"):
                t = target[7:]
                i = t.find(b"/")
                path = b"/" if i == -1 else t[i:]
            log("%s %s -> 127.0.0.1:%d" % (method.decode(errors="replace"),
                                           target.decode(errors="replace"), WPR_HTTP))
            up = socket.create_connection(("127.0.0.1", WPR_HTTP))
            newreq = method + b" " + path + b" " + ver + b"\r\n" + \
                b"\r\n".join(lines[1:]) + b"\r\n\r\n" + rest
            up.sendall(newreq)
            pipe(client, up)
    except OSError as e:
        log("error: %s" % e)
        try:
            client.close()
        except OSError:
            pass
        if up:
            try:
                up.close()
            except OSError:
                pass


def main():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", LISTEN))
    srv.listen(128)
    log("httpproxy listening on 127.0.0.1:%d -> WPR http=%d https=%d" % (LISTEN, WPR_HTTP, WPR_HTTPS))
    while True:
        c, _ = srv.accept()
        threading.Thread(target=handle, args=(c,), daemon=True).start()


main()
