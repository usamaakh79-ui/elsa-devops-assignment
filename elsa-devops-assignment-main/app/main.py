"""quote-api: tiny HTTP service for the ELSA DevOps take-home.

Endpoints: /healthz, /readyz, /metrics (Prometheus), /api/quote.
Stdlib HTTP server + prometheus_client; no framework on purpose (small image,
small attack surface, easy to read in a live walkthrough).
"""
import json
import os
import random
import signal
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest

PORT = int(os.environ.get("PORT", "8080"))
# CPU time burned per /api/quote request (Part 6 load-test hook). 100ms by default.
CPU_WORK_SECONDS = float(os.environ.get("CPU_WORK_MS", "100")) / 1000.0

QUOTES = [
    "The secret of getting ahead is getting started.",
    "It always seems impossible until it's done.",
    "Well done is better than well said.",
    "Small deeds done are better than great deeds planned.",
    "You don't have to be great to start, but you have to start to be great.",
    "Done is better than perfect.",
    "Quality is not an act, it is a habit.",
]

KNOWN_PATHS = {"/healthz", "/readyz", "/metrics", "/api/quote"}

REQUESTS = Counter(
    "quote_api_requests_total", "HTTP requests handled", ["path", "method", "status"]
)
QUOTES_SERVED = Counter("quote_api_quotes_served_total", "Quotes returned to clients")
LATENCY = Histogram(
    "quote_api_request_duration_seconds",
    "Request latency in seconds",
    ["path"],
    buckets=(0.05, 0.1, 0.15, 0.2, 0.3, 0.5, 0.75, 1, 2, 5),
)

_ready = threading.Event()


def burn_cpu(seconds: float) -> None:
    """Spin until this *thread* has consumed `seconds` of CPU time.

    thread_time() (not wall clock) means each request really costs ~100ms of
    CPU, so latency grows under contention exactly like a CPU-bound service.
    """
    deadline = time.thread_time() + seconds
    x = 0
    while time.thread_time() < deadline:
        x = (x * 31 + 7) % 1_000_003


class Handler(BaseHTTPRequestHandler):
    server_version = "quote-api"
    sys_version = ""

    def _send(self, status: int, body: bytes, content_type: str) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _json(self, status: int, payload: dict) -> None:
        self._send(status, json.dumps(payload).encode(), "application/json")

    def do_GET(self):  # noqa: N802 (http.server naming)
        path = self.path.split("?", 1)[0]
        label = path if path in KNOWN_PATHS else "other"  # bound label cardinality
        start = time.perf_counter()
        status = 200
        try:
            if path == "/healthz":
                self._json(200, {"status": "ok"})
            elif path == "/readyz":
                status = 200 if _ready.is_set() else 503
                self._json(status, {"ready": _ready.is_set()})
            elif path == "/metrics":
                self._send(200, generate_latest(), CONTENT_TYPE_LATEST)
            elif path == "/api/quote":
                burn_cpu(CPU_WORK_SECONDS)
                QUOTES_SERVED.inc()
                self._json(200, {"quote": random.choice(QUOTES), "pod": os.environ.get("HOSTNAME", "")})
            else:
                status = 404
                self._json(404, {"error": "not found"})
        except Exception:  # never leak a stack trace to the client
            status = 500
            self._json(500, {"error": "internal error"})
            raise
        finally:
            REQUESTS.labels(label, "GET", str(status)).inc()
            LATENCY.labels(label).observe(time.perf_counter() - start)

    def log_message(self, fmt, *args):
        # Skip probe/scrape noise; keep real traffic in the logs.
        if self.path not in ("/healthz", "/readyz", "/metrics"):
            sys.stdout.write("%s %s\n" % (self.address_string(), fmt % args))


def make_server(port: int = PORT) -> ThreadingHTTPServer:
    server = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    server.daemon_threads = True
    return server


def main() -> None:
    server = make_server()

    def shutdown(signum, _frame):
        _ready.clear()  # fail readiness first so endpoints drain
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)
    _ready.set()
    print(f"quote-api listening on :{PORT}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
