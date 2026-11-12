"""Interactive dashboard for the redis-ha-secure demo (standard library only).

Reads cluster state directly from every Redis node and Sentinel (as acl-admin), the
demo apps' /stats, the DR object store and the Kubernetes API, and offers the demo
actions: ACL playground, Sentinel failover, kill the master pod, on-demand backup, and
a "rogue deploy" that deletes every order (a logical disaster that replication copies
everywhere). Demo only: it holds the acl-admin password and the apps' credentials.
"""
import hashlib
import json
import os
import re
import shlex
import ssl
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from resp import Redis, RedisError, info, read_secret

NS = os.environ["NAMESPACE"]
FULL = os.environ["FULLNAME"]
REPLICAS = int(os.environ.get("REPLICAS", "3"))
GROUP = os.environ.get("MASTER_GROUP", "mymaster")
HAPROXY = os.environ["HAPROXY"]
STORE_HTTP = os.environ["STORE_HTTP"].rstrip("/")
DR_PREFIX = os.environ["DR_PREFIX"].strip("/")
CRONJOB = os.environ["BACKUP_CRONJOB"]
APPS = json.loads(os.environ["APPS"])
INFRA = "/infra"
ADMIN = ("acl-admin", read_secret(INFRA, "acl-admin-password"))
BLOCKED = {"SHUTDOWN", "DEBUG", "MONITOR", "SUBSCRIBE", "PSUBSCRIBE", "SSUBSCRIBE"}

events = []
ev_lock = threading.Lock()


def event(kind, msg):
    with ev_lock:
        events.insert(0, {"at": time.time(), "kind": kind, "msg": msg})
        del events[60:]


def node_host(i):
    return f"{FULL}-server-{i}.{FULL}.{NS}.svc"


def admin(i, port, *cmd, timeout=1.5):
    r = Redis(node_host(i), port, *ADMIN, timeout=timeout)
    try:
        return r.call(*cmd)
    finally:
        r.close()


# ----------------------------------------------------------------- Kubernetes API
SA = "/var/run/secrets/kubernetes.io/serviceaccount"
K8S = "https://kubernetes.default.svc"


def k8s(method, path, body=None):
    with open(f"{SA}/token", encoding="utf-8") as f:
        token = f.read().strip()
    req = urllib.request.Request(K8S + path, method=method, data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"})
    ctx = ssl.create_default_context(cafile=f"{SA}/ca.crt")
    with urllib.request.urlopen(req, context=ctx, timeout=5) as resp:
        return json.loads(resp.read() or b"{}")


# ----------------------------------------------------------------- state
def node_state(i):
    n = {"name": f"{FULL}-server-{i}", "up": False}
    try:
        repl = info(admin(i, 6379, "INFO", "replication"))
        ks = info(admin(i, 6379, "INFO", "keyspace"))
        acl = admin(i, 6379, "ACL", "LIST")
        db0 = dict(kv.split("=") for kv in ks.get("db0", "keys=0").split(","))
        n.update(up=True, role=repl.get("role"), offset=int(repl.get("master_repl_offset", 0)),
                 link=repl.get("master_link_status"), replicas=int(repl.get("connected_slaves", 0)),
                 keys=int(db0.get("keys", 0)), acl_users=len(acl),
                 acl_digest=hashlib.sha256("\n".join(acl).encode()).hexdigest()[:12])
    except (RedisError, OSError, ConnectionError, ValueError) as e:
        n["error"] = str(e)[:120]
    try:
        m = admin(i, 26379, "SENTINEL", "GET-MASTER-ADDR-BY-NAME", GROUP)
        n["sentinel_master"] = m[0] if m else None
    except (RedisError, OSError, ConnectionError) as e:
        n["sentinel_error"] = str(e)[:120]
    return n


def app_stats(url):
    try:
        with urllib.request.urlopen(url, timeout=2) as resp:
            return json.loads(resp.read())
    except (OSError, ValueError) as e:
        return {"unreachable": str(e)[:120]}


def store_get(path):
    with urllib.request.urlopen(f"{STORE_HTTP}/{path}", timeout=3) as resp:
        return resp.read().decode()


def backups():
    out = {"latest": None, "items": []}
    try:
        out["latest"] = store_get(f"{DR_PREFIX}/LATEST").strip()
    except (OSError, urllib.error.HTTPError):
        pass
    try:
        ids = sorted(set(re.findall(r'href="(\d{8}T\d{6}Z)/"', store_get(f"{DR_PREFIX}/"))), reverse=True)[:6]
        for bid in ids:
            item = {"id": bid}
            try:
                meta = dict(l.split("=", 1) for l in store_get(f"{DR_PREFIX}/{bid}/backup.meta").splitlines() if "=" in l)
                item.update(keys=meta.get("keyspace_at_snapshot_approx", "").strip(), source=meta.get("source_host", "").split(".")[0],
                            role=meta.get("source_role"), bytes=meta.get("rdb_bytes"))
            except (OSError, urllib.error.HTTPError, ValueError):
                pass
            out["items"].append(item)
    except (OSError, urllib.error.HTTPError) as e:
        out["error"] = str(e)[:120]
    return out


def backup_jobs():
    try:
        jobs = k8s("GET", f"/apis/batch/v1/namespaces/{NS}/jobs?labelSelector=app.kubernetes.io%2Fcomponent%3Ddr-backup")["items"]
    except (OSError, urllib.error.HTTPError, ValueError) as e:
        return [{"error": str(e)[:120]}]
    jobs.sort(key=lambda j: j["metadata"]["creationTimestamp"], reverse=True)
    out = []
    for j in jobs[:5]:
        s = j.get("status", {})
        state = "succeeded" if s.get("succeeded") else "failed" if s.get("failed") else "running"
        out.append({"name": j["metadata"]["name"], "state": state, "created": j["metadata"]["creationTimestamp"]})
    return out


def state():
    nodes = [None] * REPLICAS
    threads = [threading.Thread(target=lambda i=i: nodes.__setitem__(i, node_state(i))) for i in range(REPLICAS)]
    apps = {}
    threads += [threading.Thread(target=lambda k=k, u=u: apps.__setitem__(k, app_stats(u))) for k, u in APPS.items()]
    res = {}
    threads += [threading.Thread(target=lambda: res.__setitem__("backups", backups())),
                threading.Thread(target=lambda: res.__setitem__("jobs", backup_jobs()))]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    up = [n for n in nodes if n["up"]]
    masters = [n["name"] for n in up if n.get("role") == "master"]
    sentinel_view = {n.get("sentinel_master") for n in nodes if n.get("sentinel_master")}
    return {"now": time.time(), "namespace": NS, "nodes": nodes, "apps": apps, "masters": masters,
            "acl_identical": len({n.get("acl_digest") for n in up}) == 1 and len(up) == REPLICAS,
            "sentinel_agree": len(sentinel_view) == 1, "sentinel_master": next(iter(sentinel_view), None),
            "events": events[:25], **res}


# ----------------------------------------------------------------- actions
def identity(name):
    if name in ("orders-api", "report-reader"):
        return read_secret(f"/creds/{name}", "username"), read_secret(f"/creds/{name}", "password")
    if name == "wrong-password":
        return read_secret("/creds/orders-api", "username"), "guess-123456"
    if name == "default":
        return "default", read_secret(INFRA, "default-password")
    return None, None  # anonymous


def acl_try(body):
    who = body.get("identity", "anonymous")
    try:
        cmd = shlex.split(body.get("command", ""))
    except ValueError as e:
        return {"ok": False, "reply": f"parse error: {e}"}
    if not cmd:
        return {"ok": False, "reply": "empty command"}
    if cmd[0].upper() in BLOCKED:
        return {"ok": False, "reply": f"{cmd[0].upper()} is disabled in the demo playground"}
    user, pw = identity(who)
    host, port = HAPROXY.rsplit(":", 1)
    r = Redis(host, port, timeout=3)
    try:
        r.connect()
        if pw is not None:
            r.call("AUTH", user, pw)
        reply = r.call(*cmd)
        result = {"ok": True, "reply": reply}
    except RedisError as e:
        result = {"ok": False, "reply": f"(error) {e}"}
    except (OSError, ConnectionError) as e:
        result = {"ok": False, "reply": f"(connection) {e}"}
    finally:
        r.close()
    event("acl", f"{who}: {' '.join(cmd)[:60]} -> {str(result['reply'])[:80]}")
    return result


def master_index():
    for i in range(REPLICAS):
        try:
            if admin(i, 6379, "ROLE")[0] == "master":
                return i
        except (RedisError, OSError, ConnectionError):
            pass
    return None


def failover(_):
    for i in range(REPLICAS):
        try:
            admin(i, 26379, "SENTINEL", "FAILOVER", GROUP, timeout=5)
            event("failover", f"SENTINEL FAILOVER {GROUP} sent to sentinel {i}")
            return {"ok": True, "reply": f"SENTINEL FAILOVER sent via sentinel {i}. Watch the master move."}
        except (RedisError, OSError, ConnectionError) as e:
            last = str(e)
    return {"ok": False, "reply": last}


def kill_master(_):
    i = master_index()
    if i is None:
        return {"ok": False, "reply": "no master found"}
    pod = f"{FULL}-server-{i}"
    k8s("DELETE", f"/api/v1/namespaces/{NS}/pods/{pod}")
    event("chaos", f"deleted master pod {pod}")
    return {"ok": True, "reply": f"deleted pod {pod}. Sentinel promotes a replica, the pod comes back as a replica."}


def backup_now(_):
    cj = k8s("GET", f"/apis/batch/v1/namespaces/{NS}/cronjobs/{CRONJOB}")
    name = f"{CRONJOB}-manual-{int(time.time())}"[-63:].lstrip("-")
    tmpl = cj["spec"]["jobTemplate"]
    body = {"apiVersion": "batch/v1", "kind": "Job",
            "metadata": {"name": name, "labels": tmpl.get("metadata", {}).get("labels", {}),
                         "annotations": {"cronjob.kubernetes.io/instantiate": "manual"}},
            "spec": tmpl["spec"]}
    k8s("POST", f"/apis/batch/v1/namespaces/{NS}/jobs", body)
    event("backup", f"started backup Job {name}")
    return {"ok": True, "reply": f"backup Job {name} started (snapshot from a replica, then upload)."}


def rogue_delete(_):
    user, pw = identity("orders-api")
    host, port = HAPROXY.rsplit(":", 1)
    r = Redis(host, port, user, pw, timeout=10)
    deleted, cursor = 0, "0"
    try:
        while True:
            cursor, keys = r.call("SCAN", cursor, "MATCH", "orders:*", "COUNT", "1000")
            if keys:
                deleted += r.call("DEL", *keys)
            if cursor == "0":
                break
    finally:
        r.close()
    event("disaster", f"rogue deploy deleted {deleted} orders:* keys (replicated to every node)")
    return {"ok": True, "reply": f"deleted {deleted} keys as orders-api. Replication copied the damage to every replica."}


ACTIONS = {"/api/acl": acl_try, "/api/failover": failover, "/api/kill-master": kill_master,
           "/api/backup": backup_now, "/api/rogue-delete": rogue_delete}


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body, ctype="application/json"):
        data = body if isinstance(body, bytes) else json.dumps(body, default=str).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path in ("/", "/index.html"):
            with open("/app/index.html", "rb") as f:
                return self._send(200, f.read(), "text/html; charset=utf-8")
        if self.path == "/api/state":
            return self._send(200, state())
        if self.path == "/healthz":
            return self._send(200, {"ok": True})
        self._send(404, {"error": "not found"})

    def do_POST(self):
        fn = ACTIONS.get(self.path)
        if not fn:
            return self._send(404, {"error": "not found"})
        try:
            n = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(n) or b"{}")
            self._send(200, fn(body))
        except Exception as e:  # report every failure to the UI
            self._send(500, {"ok": False, "reply": f"{type(e).__name__}: {e}"})

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    event("info", "dashboard started")
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
