#!/bin/bash
# =============================================================================
# wait-for-mount.sh - init container of the reload Job and the drift CronJob
# (image: alpine/k8s). Reads the acl-watch sidecar of every Redis pod
# (`kubectl logs`, read-only) and waits until kubelet has propagated the ACL Secret
# revision this Job was started with. Only after that does the main container
# run ACL LOAD, so an old file can never be (re)loaded.
#   MODE=wait   (reload): block until every pod reports the expected revision
#   MODE=report (drift) : write the current per-pod report to /shared/mounted.txt
# =============================================================================
set -euo pipefail
: "${NAMESPACE:?}" "${FULLNAME:?}" "${REPLICAS:?}" "${MODE:=wait}" "${TIMEOUT_SECONDS:=600}"
export HOME=/tmp
rev_of() { sed -n '1s/^user acl-revision .*#\([0-9a-f]\{64\}\).*$/\1/p' "$1"; }
want="acl-revision users=$(rev_of /acl/users.acl) sentinel=$(rev_of /acl/sentinel-users.acl)"
deadline=$(($(date +%s) + TIMEOUT_SECONDS))
log() { printf '%s [wait-for-mount] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

current() {
  local l
  l=$(kubectl logs -n "$NAMESPACE" "$1" -c acl-watch --tail=5 2>/dev/null | grep '^acl-revision ' | tail -n1) || true
  printf '%s' "$l"
}

if [ "$MODE" = report ]; then
  : >/shared/mounted.txt
  for i in $(seq 0 $((REPLICAS - 1))); do
    pod="${FULLNAME}-server-${i}"
    echo "${pod} $(current "$pod")" >>/shared/mounted.txt
  done
  echo "expected ${want}" >>/shared/mounted.txt
  exit 0
fi

log "waiting for kubelet to mount: ${want}"
# No Redis pod exists at all (StatefulSet scaled to 0, or pods not created yet during an
# upgrade that also scales up): nothing to reload, every pod reads the current Secret
# when it starts. A PARTIALLY missing set still waits (and fails): that cluster is degraded.
existing=0
for i in $(seq 0 $((REPLICAS - 1))); do
  out=$(kubectl get pod -n "$NAMESPACE" "${FULLNAME}-server-${i}" -o name 2>&1) || true
  case "$out" in *NotFound*) ;; *) existing=$((existing + 1)) ;; esac
done
if [ "$existing" -eq 0 ]; then
  log "no Redis pod exists: nothing to reload (pods load the current Secret at start)"
  touch /shared/no-pods
  exit 0
fi
for i in $(seq 0 $((REPLICAS - 1))); do
  pod="${FULLNAME}-server-${i}"
  until [ "$(current "$pod")" = "$want" ]; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      log "ERROR: ${pod} still reports '$(current "$pod")'"
      exit 1
    fi
    sleep 5
  done
  log "${pod}: new ACL revision mounted"
done
