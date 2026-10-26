"""Tripwire: dnsmasq answers every name with TRIPWIRE_IP and logs queries; this process parses the query log into
host counts, runs a catch-all HTTP sink (80), a TLS-SNI recorder (443) and the JSON API (8000).

GET /hits            -> {"host": n, ...}   DNS A-queries per host (the authoritative signal; HTTPS hosts are only visible here)
GET /hits?detail=1   -> {"dns": {...}, "http": {...}, "sni": {...}, "queries": [last 200 raw]}
DELETE /hits         -> reset
env: TRIPWIRE_IP (answer for every name; default = own first IP), TRIPWIRE_IGNORE (comma list of hosts not counted,
     default host.docker.internal), TRIPWIRE_FORWARD (comma list of domains forwarded to Docker DNS 127.0.0.11, not counted)
"""
import json, os, re, socket, subprocess, sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOCK = threading.Lock()
DNS, HTTP, SNI, RAW = {}, {}, {}, []
IGNORE = {h.strip().lower() for h in os.environ.get("TRIPWIRE_IGNORE", "host.docker.internal").split(",") if h.strip()}
FORWARD = [h.strip() for h in os.environ.get("TRIPWIRE_FORWARD", "").split(",") if h.strip()]
Q = re.compile(r"query\[(A|AAAA)\] (\S+) from (\S+)")


def own_ip():
    if os.environ.get("TRIPWIRE_IP"):
        return os.environ["TRIPWIRE_IP"]
    try:
        return socket.gethostbyname(socket.gethostname())
    except Exception:
        return "127.0.0.1"


def hit(d, host):
    host = (host or "").split(":")[0].lower().rstrip(".")
    if not host or host in IGNORE:
        return
    with LOCK:
        d[host] = d.get(host, 0) + 1


def dns_reader(proc):
    for line in proc.stdout:
        line = line.rstrip()
        m = Q.search(line)
        if m:
            qt, host, src = m.groups()
            if any(host == f or host.endswith("." + f) for f in FORWARD):
                continue
            with LOCK:
                RAW.append(line[-200:])
                del RAW[:-200]
            if qt == "A":
                hit(DNS, host)
        else:
            print(line, flush=True)


class Sink(BaseHTTPRequestHandler):
    def do_GET(self):
        hit(HTTP, self.headers.get("Host"))
        print(f"SINK {self.command} host={self.headers.get('Host')} path={self.path}", flush=True)
        b = b"tripwire sink\n"
        self.send_response(200)
        self.send_header("content-length", str(len(b)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(b)
    do_POST = do_PUT = do_DELETE = do_HEAD = do_PATCH = do_GET

    def log_message(self, *a):
        pass


class Api(BaseHTTPRequestHandler):
    def _j(self, o, code=200):
        b = json.dumps(o).encode()
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        p, _, q = self.path.partition("?")
        if p == "/hits":
            with LOCK:
                if "detail=1" in q:
                    return self._j(dict(dns=dict(DNS), http=dict(HTTP), sni=dict(SNI), queries=list(RAW)))
                return self._j(dict(DNS))
        if p == "/health":
            return self._j({"status": "ok", "ip": own_ip()})
        self._j({"error": "not found"}, 404)

    def do_DELETE(self):
        if self.path.split("?")[0] == "/hits":
            with LOCK:
                DNS.clear(); HTTP.clear(); SNI.clear(); RAW.clear()
            return self._j({"status": "cleared"})
        self._j({"error": "not found"}, 404)

    def log_message(self, *a):
        pass


def sni_of(data):
    try:
        if data[0] != 22:
            return None
        i = 43
        i += 1 + data[i]
        i += 2 + int.from_bytes(data[i:i + 2], "big")
        i += 1 + data[i]
        end = i + 2 + int.from_bytes(data[i:i + 2], "big")
        i += 2
        while i + 4 <= end:
            t, l = int.from_bytes(data[i:i + 2], "big"), int.from_bytes(data[i + 2:i + 4], "big")
            if t == 0:
                return data[i + 9:i + 4 + l].decode()
            i += 4 + l
    except Exception:
        return None


def tls_sink():
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("0.0.0.0", 443))
    s.listen(64)
    while True:
        c, _ = s.accept()
        try:
            c.settimeout(2)
            h = sni_of(c.recv(4096))
            hit(SNI, h)
            print(f"SINK tls sni={h}", flush=True)
        except Exception:
            pass
        finally:
            c.close()


def serve(port, handler):
    ThreadingHTTPServer(("0.0.0.0", port), handler).serve_forever()


def main():
    ip = own_ip()
    cmd = ["dnsmasq", "-k", "--no-resolv", "--no-hosts", "--log-queries", "--log-facility=-", "--cache-size=0", "-u", "root", f"--address=/#/{ip}"]
    for f in FORWARD:
        cmd.append(f"--server=/{f}/127.0.0.11")
    print(f"tripwire: answering every name with {ip}; ignoring {sorted(IGNORE)}", flush=True)
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    threading.Thread(target=dns_reader, args=(proc,), daemon=True).start()
    for t in (lambda: serve(80, Sink), tls_sink, lambda: serve(8000, Api)):
        threading.Thread(target=t, daemon=True).start()
    sys.exit(proc.wait())


main()
