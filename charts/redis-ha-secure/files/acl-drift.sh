#!/bin/sh
# =============================================================================
# acl-drift.sh - CronJob (image: redis alpine). Read-only.
# Diffs ACL LIST of every Redis node / Sentinel against each other AND against the
# expected file (normalised by loading it into a local throw-away instance), checks
# the loaded revision marker and what kubelet has mounted. Exit 1 on drift so the
# Job fails (alert: RedisAclDriftCheckFailed).
# =============================================================================
set -eu
LOG_TAG=acl-drift
. /scripts/acl-lib.sh

EXP_R=$(rev_of "$ACL_DIR/users.acl")
EXP_S=$(rev_of "$ACL_DIR/sentinel-users.acl")
trap local_stop EXIT
local_start
drift=0
report() { log "DRIFT: $*"; drift=1; }

# Grace period: right after a node/cluster restart the pods may still be starting. Being
# unreachable is an availability problem (RedisDown), not ACL drift, so wait first.
READY_TIMEOUT=${READY_TIMEOUT:-120}
deadline=$(($(date +%s) + READY_TIMEOUT))
for i in $(node_ids); do
  h=$(node_host "$i")
  until rcli "$h" "$REDIS_PORT" PING >/dev/null 2>&1 && rcli "$h" "$SENTINEL_PORT" PING >/dev/null 2>&1; do
    [ "$(date +%s)" -lt "$deadline" ] || break
    sleep 5
  done
done

for i in $(node_ids); do
  h=$(node_host "$i")
  pod="${FULLNAME}-server-${i}"
  mounted=$(grep "^${pod} " /shared/mounted.txt 2>/dev/null | cut -d' ' -f2- || true)
  [ "$mounted" = "acl-revision users=${EXP_R} sentinel=${EXP_S}" ] \
    || report "${pod}: mounted ACL revision is not the Secret's (${mounted:-no report}). Kubelet propagation pending or acl-watch down."

  if d=$(acl_digest "$h" "$REDIS_PORT"); then
    [ "$d" = "$EXPECTED_REDIS_DIGEST" ] || report "${pod}: redis ACL LIST differs from the Secret's users.acl"
    rcli "$h" "$REDIS_PORT" ACL LIST | grep -q "^user acl-revision .*#${EXP_R}" \
      || report "${pod}: redis has not loaded the current revision (run the reload Job)"
  else
    report "${pod}: redis unreachable as acl-admin"
  fi
  if d=$(acl_digest "$h" "$SENTINEL_PORT"); then
    [ "$d" = "$EXPECTED_SENTINEL_DIGEST" ] || report "${pod}: sentinel ACL LIST differs from the Secret's sentinel-users.acl"
  else
    report "${pod}: sentinel unreachable as acl-admin"
  fi
  # Runtime auth must never have fallen back to the default user in phase 2.
  if [ "${PHASE}" = "2" ]; then
    client_users "$h" "$REDIS_PORT" sentinel- | grep -qx default && report "${pod}: a Sentinel is authenticated as 'default'"
    [ "$(rcli "$h" "$REDIS_PORT" CONFIG GET masteruser | sed -n 2p | tr -d '\r')" = "replica-user" ] \
      || report "${pod}: masteruser is not replica-user"
  fi
done

if [ "$drift" -eq 0 ]; then
  log "OK: ${REPLICAS} redis nodes + ${REPLICAS} sentinels match revision redis=$(echo "$EXP_R" | cut -c1-12) sentinel=$(echo "$EXP_S" | cut -c1-12)"
fi
exit "$drift"
