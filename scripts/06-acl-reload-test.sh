#!/usr/bin/env bash
# 6. ACL update through the reload Job WITHOUT pod restarts:
#    a) add a catalog user -> helm upgrade -> user present on every node + Sentinel,
#       credential Secret created, user can authenticate
#    b) rotate a password (dual-password window), then revoke the old one
#    c) remove the user -> gone everywhere
#    Throughout: pod UIDs, container restartCounts and redis/sentinel run_ids unchanged,
#    and no failover happened.
source "$(dirname "$0")/lib.sh"
mapfile -t VALUES < <(helm_values)
TMP=$(mktmpd)
trap 'rm -rf "$TMP"' EXIT

fingerprint() {
  local i out=""
  out+=$(kubectl -n "$NS" get pods -l "app=redis-ha,release=$RELEASE" \
    -o jsonpath='{range .items[*]}{.metadata.name}={.metadata.uid}:{range .status.containerStatuses[*]}{.name}/{.restartCount},{end}{"\n"}{end}')
  for i in $(seq 0 $((REPLICAS - 1))); do
    out+=$'\n'"redis$i=$(admin_redis "$i" INFO server | tr -d '\r' | grep '^run_id:')"
    out+=$'\n'"sentinel$i=$(admin_sentinel "$i" INFO server | tr -d '\r' | grep '^run_id:')"
  done
  printf '%s\n' "$out"
}
upgrade() { # <description> [extra values file]
  local extra=()
  [ -n "${2:-}" ] && extra=(-f "$2")
  local s=$(date +%s)
  if helm upgrade "$RELEASE" "$CHART" -n "$NS" "${VALUES[@]}" "${extra[@]}" --wait --timeout 15m >/dev/null; then
    ok "$1: helm upgrade + build/reload hooks in $(($(date +%s) - s))s"
  else
    bad "$1: helm upgrade failed"
    kubectl -n "$NS" logs "job/${FULL}-acl-reload" --all-containers --tail=40 || true
    summary; exit 1
  fi
}
user_everywhere() { # <user> <present|absent>
  local i t r has
  for i in $(seq 0 $((REPLICAS - 1))); do
    for t in redis sentinel; do
      # HAProxy mode: catalog users intentionally have no Sentinel account.
      [ "$t" = sentinel ] && [ "$HAPROXY" = 1 ] && continue
      if [ "$t" = redis ]; then r=$(admin_redis "$i" ACL USERS | tr -d '\r'); else r=$(admin_sentinel "$i" ACL USERS | tr -d '\r'); fi
      if grep -qx "$1" <<<"$r"; then has=present; else has=absent; fi
      [ "$has" = "$2" ] || return 1
    done
  done
}
auth_ok() { [ "$(cli_as "$(pod "$(master_index)")" redis "$1" "$2" localhost 6379 PING | tr -d '\r')" = PONG ]; }

master_before=$(master_index)
fp_before=$(fingerprint)
NEWUSER=system.serviceaccount.orders.orders-batch

info "a) add orders/orders-batch (read-only on orders:batch:)"
# Append the new user to the catalog currently deployed (JSON is valid YAML).
PY=$(command -v python3 || command -v python)
helm get values "$RELEASE" -n "$NS" -o json | "$PY" -c '
import json, sys
v = json.load(sys.stdin)
users = v.get("aclUsers", [])
users.append({"namespace": "orders", "serviceAccount": "orders-batch",
              "redis": [{"keyPrefix": "orders:batch:", "access": ["read"]}]})
print(json.dumps({"aclUsers": users}))' >"$TMP/add.yaml"
upgrade "add user" "$TMP/add.yaml"
check "$NEWUSER present on all redis nodes + sentinels" user_everywhere "$NEWUSER" present
pw=$(secret_val orders redis-acl-orders-batch password)
[ -n "$pw" ] && ok "credential Secret orders/redis-acl-orders-batch generated" || bad "credential Secret missing"
check "$NEWUSER authenticates on the master" auth_ok "$NEWUSER" "$pw"
r=$(admin_redis 0 ACL DRYRUN "$NEWUSER" SET orders:batch:x 1 | tr -d '\r')
[ "$r" != OK ] && ok "$NEWUSER is read-only (SET denied)" || bad "$NEWUSER could write"

info "b) rotate orders-batch password (dual-password window)"
"$ROOT/scripts/rotate-password.sh" start orders redis-acl-orders-batch >/dev/null
newpw=$(secret_val orders redis-acl-orders-batch password)
upgrade "rotation start" "$TMP/add.yaml"
check "old password still accepted during the window" auth_ok "$NEWUSER" "$pw"
check "new password accepted" auth_ok "$NEWUSER" "$newpw"
"$ROOT/scripts/rotate-password.sh" finish orders redis-acl-orders-batch >/dev/null
upgrade "rotation finish" "$TMP/add.yaml"
if auth_ok "$NEWUSER" "$pw"; then bad "old password still accepted after finish"; else ok "old password rejected on the master after finish"; fi
for i in $(seq 0 $((REPLICAS - 1))); do
  [ "$(cli_as "$(pod "$i")" redis "$NEWUSER" "$pw" localhost 6379 PING | tr -d '\r')" != PONG ] && ok "old password rejected on node $i" || bad "old password accepted on node $i"
done
check "new password accepted after finish" auth_ok "$NEWUSER" "$newpw"
unset pw newpw

info "c) remove the user again"
upgrade "remove user"
check "$NEWUSER absent on all redis nodes + sentinels" user_everywhere "$NEWUSER" absent

info "no restarts, no failover"
fp_after=$(fingerprint)
if [ "$fp_before" = "$fp_after" ]; then
  ok "pod UIDs, container restartCounts and redis/sentinel run_ids unchanged across 4 upgrades"
else
  bad "pods/processes changed:"; diff <(echo "$fp_before") <(echo "$fp_after") || true
fi
[ "$(master_index)" = "$master_before" ] && ok "master unchanged ($(pod "$master_before")): no failover" || bad "master changed"
kubectl -n orders delete secret redis-acl-orders-batch --ignore-not-found >/dev/null
summary
