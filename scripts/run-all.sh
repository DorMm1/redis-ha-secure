#!/usr/bin/env bash
# Full live suite on one cluster (default: Docker Desktop with Linkerd), HAProxy mode.
# Every step's output goes to $LOG; a summary line per script is appended to $SUMMARY.
#   KUBE_CONTEXT=docker-desktop scripts/run-all.sh
set -uo pipefail
cd "$(dirname "$0")/.."
here=$(pwd); command -v cygpath >/dev/null 2>&1 && here=$(cygpath -m "$here") # native helm on Windows
export KUBE_CONTEXT=${KUBE_CONTEXT:-docker-desktop}
export HAPROXY=1
export EXTRA_VALUES=${EXTRA_VALUES:-$here/scripts/ci/values-docker-desktop.yaml}
export MESH_INJECT=${MESH_INJECT:-enabled}
export LEGACY_MESH=${LEGACY_MESH:-1}
LOG=${LOG:-/tmp/run-all.log}
SUMMARY=${SUMMARY:-/tmp/run-all.summary}
: >"$LOG"; : >"$SUMMARY"
step() { # <phase> <script>   (a failed deploy step aborts the run: everything after depends on it)
  local t0=$(date +%s)
  echo "######## PHASE=$1 $2 $(date -u +%FT%TZ)" >>"$LOG"
  PHASE=$1 "./scripts/$2" >>"$LOG" 2>&1 </dev/null
  local rc=$?
  local res; res=$(grep -E "^$2: [0-9]+ passed, [0-9]+ failed" "$LOG" | tail -n1)
  printf '%s PHASE=%s %-32s rc=%s %4ss  %s\n' "$(date -u +%TZ)" "$1" "$2" "$rc" "$(( $(date +%s) - t0 ))" "${res:-no summary line}" >>"$SUMMARY"
  if [ "$2" = 02-deploy-verify.sh ] && grep -qE 'FAIL.* helm upgrade --install failed' <(tail -n 200 "$LOG"); then
    echo "ABORT: deploy failed" >>"$SUMMARY"; exit 1
  fi
}
step 1 02-deploy-verify.sh
step 1 03-acl-dryrun.sh
step 2 02-deploy-verify.sh
step 2 03-acl-dryrun.sh
step 2 04-default-user-rejected.sh
step 2 05-failover-test.sh
step 2 06-acl-reload-test.sh
step 2 07-haproxy-test.sh
step 2 08-migration-test.sh
echo "DONE $(date -u +%TZ)" >>"$SUMMARY"
