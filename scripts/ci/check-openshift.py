"""Assertions on a manifest stream rendered with values-openshift.yaml (and
--api-versions security.openshift.io/v1, so the subchart believes it runs on OpenShift).
Usage: check-openshift.py <rendered.yaml> <fullname>"""
import sys

import yaml

docs = [d for d in yaml.safe_load_all(open(sys.argv[1], encoding="utf-8")) if d]
full = sys.argv[2]
problems = []


def find(kind, name):
    return next((d for d in docs if d.get("kind") == kind and d["metadata"]["name"] == name), None)


sts = find("StatefulSet", f"{full}-server")
pod = sts["spec"]["template"]["spec"]
if pod["securityContext"].get("runAsUser") != 1000 or pod["securityContext"].get("fsGroup") != 1000:
    problems.append("Redis pod securityContext lost its fixed UID/fsGroup (adaptSecurityContext must be disabled)")
for c in pod["containers"] + pod.get("initContainers", []):
    sc = c.get("securityContext") or {}
    if not sc.get("runAsNonRoot"):
        problems.append(f"{c['name']}: runAsNonRoot not set")
    if c["name"] in ("redis-exporter", "acl-watch") and "runAsUser" in sc:
        problems.append(f"{c['name']}: container-level runAsUser (must inherit the pod UID)")

hap = find("Deployment", f"{full}-haproxy")
if hap and hap["spec"]["template"]["spec"]["securityContext"].get("runAsUser") != 99:
    problems.append("HAProxy pod lost its fixed UID")

rb = find("RoleBinding", f"{full}-scc")
if not rb:
    problems.append("SCC RoleBinding missing")
else:
    if rb["roleRef"]["name"] != "system:openshift:scc:nonroot-v2":
        problems.append(f"SCC RoleBinding roleRef {rb['roleRef']['name']}")
    subjects = {s["name"] for s in rb["subjects"]}
    for sa in (full, f"{full}-haproxy", f"{full}-acl-ops", f"{full}-dr-backup"):
        if sa not in subjects:
            problems.append(f"SA {sa} not bound to the SCC (subjects: {sorted(subjects)})")

hook_rb = find("RoleBinding", f"{full}-acl-build-scc")
if not hook_rb or "pre-install" not in (hook_rb["metadata"].get("annotations") or {}).get("helm.sh/hook", ""):
    problems.append("ACL build hook SA has no hook-scoped SCC RoleBinding")

np = find("NetworkPolicy", f"{full}-server")
dns = [r for r in np["spec"]["egress"] if any(5353 == p["port"] for p in r.get("ports", []))]
if not dns or "openshift-dns" not in yaml.safe_dump(dns[0]["to"]):
    problems.append("DNS egress to openshift-dns:5353 missing")

for p in problems:
    print(p)
sys.exit(1 if problems else 0)
