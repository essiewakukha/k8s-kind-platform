"""
shop-api: a small HTTP service built to be run on Kubernetes. Standard library only.

  GET /health        liveness: 200 as long as the process is running
  GET /ready         readiness: 200 normally, 503 after /unready (until /ready-on)
  GET /info          which pod answered, version, greeting (from ConfigMap), key present?
  GET /work?ms=N     burn CPU for N milliseconds (max 2000), used to trigger autoscaling
  GET /metrics       Prometheus text format
  GET /unready       make this pod fail readiness (demo: the pod leaves the Service)
  GET /ready-on      make this pod ready again

The API key comes from a Secret and is never returned, only whether it is set.
"""
import json
import os
import socket
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

VERSION = os.environ.get("APP_VERSION", "1.0.0")
MAX_WORK_MS = 2000

state = {"ready": True, "requests": 0, "work_ms_total": 0}
lock = threading.Lock()


def burn_cpu(ms):
    """Busy-loop for about `ms` milliseconds."""
    end = time.perf_counter() + ms / 1000.0
    n = 0
    while time.perf_counter() < end:
        n += 1
    return n


def parse_ms(query):
    """Extract ms=<int> from a query string; clamp to 0..MAX_WORK_MS."""
    for part in query.split("&"):
        if part.startswith("ms="):
            try:
                return max(0, min(int(part[3:]), MAX_WORK_MS))
            except ValueError:
                return 0
    return 100


def handle(path, environ=None, hostname=None):
    """Return (status_code, content_type, body_bytes) for a request path."""
    environ = os.environ if environ is None else environ
    hostname = hostname or socket.gethostname()
    route, _, query = path.partition("?")

    with lock:
        state["requests"] += 1

    if route == "/health":
        return 200, "application/json", b'{"status":"alive"}'

    if route == "/ready":
        with lock:
            ready = state["ready"]
        if ready:
            return 200, "application/json", b'{"status":"ready"}'
        return 503, "application/json", b'{"status":"not ready"}'

    if route == "/unready":
        with lock:
            state["ready"] = False
        return 200, "application/json", b'{"ready":false}'

    if route == "/ready-on":
        with lock:
            state["ready"] = True
        return 200, "application/json", b'{"ready":true}'

    if route == "/info":
        body = {
            "pod": hostname,
            "version": VERSION,
            "greeting": environ.get("GREETING", "hello"),
            "api_key_configured": bool(environ.get("API_KEY")),
        }
        return 200, "application/json", json.dumps(body).encode()

    if route == "/work":
        ms = parse_ms(query)
        burn_cpu(ms)
        with lock:
            state["work_ms_total"] += ms
        return 200, "application/json", json.dumps({"burned_ms": ms}).encode()

    if route == "/metrics":
        with lock:
            text = (
                "# HELP shop_api_requests_total Total HTTP requests handled.\n"
                "# TYPE shop_api_requests_total counter\n"
                f"shop_api_requests_total {state['requests']}\n"
                "# HELP shop_api_work_milliseconds_total CPU milliseconds burned by /work.\n"
                "# TYPE shop_api_work_milliseconds_total counter\n"
                f"shop_api_work_milliseconds_total {state['work_ms_total']}\n"
                "# HELP shop_api_ready 1 if the pod reports ready.\n"
                "# TYPE shop_api_ready gauge\n"
                f"shop_api_ready {1 if state['ready'] else 0}\n"
            )
        return 200, "text/plain; version=0.0.4", text.encode()

    return 404, "application/json", b'{"error":"not found"}'


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        code, ctype, body = handle(self.path)
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        print(json.dumps({"event": "request", "line": fmt % args}), flush=True)


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()