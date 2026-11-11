"""Fail if any container (including init containers, Jobs and CronJobs) in a rendered
manifest stream has no resources.limits or no securityContext hardening."""
import sys

import yaml

problems = []
for doc in yaml.safe_load_all(open(sys.argv[1], encoding="utf-8")):
    if not doc:
        continue
    spec = doc.get("spec") or {}
    if doc.get("kind") == "Pod":
        pod = spec
    elif doc.get("kind") == "CronJob":
        pod = spec["jobTemplate"]["spec"]["template"]["spec"]
    else:
        pod = (spec.get("template") or {}).get("spec")
    if not pod:
        continue
    # helm test hook pods of the upstream chart are excluded (not part of the runtime)
    if (doc.get("metadata", {}).get("annotations") or {}).get("helm.sh/hook") == "test":
        continue
    for c in pod.get("containers", []) + pod.get("initContainers", []):
        name = f'{doc["kind"]}/{doc["metadata"]["name"]}/{c["name"]}'
        if not (c.get("resources") or {}).get("limits"):
            problems.append(f"{name}: no resources.limits")
        sc = c.get("securityContext") or {}
        if sc.get("allowPrivilegeEscalation") is not False:
            problems.append(f"{name}: allowPrivilegeEscalation not false")
        if "ALL" not in ((sc.get("capabilities") or {}).get("drop") or []):
            problems.append(f"{name}: capabilities not dropped")
        if not sc.get("readOnlyRootFilesystem"):
            problems.append(f"{name}: readOnlyRootFilesystem not set")

for p in problems:
    print(p)
sys.exit(1 if problems else 0)
