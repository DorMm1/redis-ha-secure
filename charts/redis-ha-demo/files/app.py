"""Demo workloads. ROLE selects the behavior; every role exposes GET /stats (JSON) on :8080.

orders-api    : writes an order every WRITE_INTERVAL seconds through HAProxy as its own ACL user
                (INCR orders:seq, HSET orders:<id>, XADD orders:stream, PUBLISH orders.events.created)
report-reader : reads orders, writes reports:summary, and keeps trying to tamper with orders:*
                (must be denied by its ACL: read-only on orders:)
intruder      : a workload with NO catalog entry. Keeps trying to reach Redis through HAProxy.
                Linkerd rejects its identity before Redis ever sees a byte.
"""
import json
import os
import random
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from resp import Redis, RedisError, read_secret

ROLE = os.environ["ROLE"]
CREDS = "/creds"
stats = {"role": ROLE, "started": time.time(), "ok": 0, "errors": 0, "denied": 0,
         "last_ok": None, "last_error": None, "last_error_at": None, "outages": [], "extra": {}}
lock = threading.Lock()
outage_start = None


def mark_ok():
    global outage_start
    with lock:
        stats["ok"] += 1
        stats["last_ok"] = time.time()
        if outage_start is not None:
            stats["outages"] = (stats["outages"] + [{"start": outage_start, "end": time.time(),
                                                     "seconds": round(time.time() - outage_start, 1)}])[-10:]
            outage_start = None


def mark_error(e):
    global outage_start
    with lock:
        stats["errors"] += 1
        stats["last_error"] = f"{type(e).__name__}: {e}"[:200]
        stats["last_error_at"] = time.time()
        if outage_start is None:
            outage_start = time.time()


def client():
    host, port = read_secret(CREDS, "redis-address").rsplit(":", 1)
    return Redis(host, port, read_secret(CREDS, "username"), read_secret(CREDS, "password"))


def orders_api():
    r = client()
    customers = ["acme", "globex", "initech", "umbrella", "hooli", "stark"]
    interval = float(os.environ.get("WRITE_INTERVAL", "0.2"))
    while True:
        try:
            oid = r.call("INCR", "orders:seq")
            r.call("HSET", f"orders:{oid}", "customer", random.choice(customers),
                   "amount", f"{random.uniform(5, 500):.2f}", "ts", f"{time.time():.3f}")
            r.call("XADD", "orders:stream", "MAXLEN", "~", "5000", "*", "order", oid)
            r.call("PUBLISH", "orders.events.created", oid)
            mark_ok()
            with lock:
                stats["extra"]["last_order_id"] = oid
        except (RedisError, OSError, ConnectionError) as e:
            mark_error(e)
            r.close()
            time.sleep(0.5)
            continue
        time.sleep(interval)


def report_reader():
    r = client()
    while True:
        try:
            seq = r.call("GET", "orders:seq")
            xlen = r.call("XLEN", "orders:stream")
            r.call("SET", "reports:summary", json.dumps({"orders_seq": seq, "stream_len": xlen, "at": time.time()}))
            mark_ok()
            with lock:
                stats["extra"].update({"orders_seq": seq, "stream_len": xlen})
            try:  # least privilege in action: read-only on orders:*
                r.call("SET", "orders:tampered", "1")
                with lock:
                    stats["extra"]["tamper"] = "ALLOWED (should never happen)"
            except RedisError as e:
                with lock:
                    stats["denied"] += 1
                    stats["extra"]["tamper"] = str(e)[:120]
        except (RedisError, OSError, ConnectionError) as e:
            mark_error(e)
            r.close()
        time.sleep(2)


def intruder():
    target = os.environ["TARGET"]
    host, port = target.rsplit(":", 1)
    while True:
        attempt = {"at": time.time()}
        try:
            r = Redis(host, port, timeout=3)
            r.connect()
            try:
                attempt["result"] = f"connected, PING -> {r.call('PING')}"
                attempt["verdict"] = "REACHED REDIS"
            except RedisError as e:
                attempt["result"] = f"connected, but Redis said: {e}"
                attempt["verdict"] = "blocked by Redis ACL"
            except (OSError, ConnectionError) as e:
                attempt["result"] = f"connection dropped: {e}"
                attempt["verdict"] = "blocked by Linkerd (identity not authorized)"
            r.close()
        except (OSError, ConnectionError) as e:
            attempt["result"] = f"{type(e).__name__}: {e}"
            attempt["verdict"] = "blocked by Linkerd (identity not authorized)"
        with lock:
            stats["denied" if "blocked" in attempt["verdict"] else "ok"] += 1
            stats["extra"]["last_attempt"] = attempt
        time.sleep(5)


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        with lock:
            body = json.dumps(stats).encode()
        self.send_response(200 if self.path in ("/stats", "/healthz") else 404)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    target = {"orders-api": orders_api, "report-reader": report_reader, "intruder": intruder}[ROLE]
    threading.Thread(target=target, daemon=True).start()
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
