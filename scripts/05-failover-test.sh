#!/usr/bin/env bash
# 5. Forced failover: SENTINEL FAILOVER <master>, then verify
#    * a new master was elected and every Sentinel agrees
#    * the new master has IDENTICAL ACLs (ACL LIST digest equal on all nodes and equal
#      to the pre-failover digest). ACLs are not replicated, the file is the source.
#    * replication is healthy, and in phase 2 still authenticated as replica-user/sentinel-user
#    * app users still authenticate via Sentinel discovery from their own namespaces
source "$(dirname "$0")/lib.sh"

old_idx=$(master_index) || { bad "no master"; summary; exit 1; }
old_addr=$(master_addr 0)
before=$(acl_digest 0)
sbefore=$(sentinel_acl_digest 0)
info "current master: $(pod "$old_idx") ($old_addr)"

r=$(admin_sentinel 0 SENTINEL FAILOVER "$MASTER_GROUP" | tr -d '\r')
[ "$r" = OK ] && ok "SENTINEL FAILOVER $MASTER_GROUP -> OK" || { bad "SENTINEL FAILOVER: $r"; summary; exit 1; }
start=$(date +%s)
addr_changed() { [ "$(master_addr 0)" != "$old_addr" ]; }
new_master_ready() { local i; i=$(master_index) && [ "$i" != "$old_idx" ] && admin_redis "$i" INFO replication | tr -d '\r' | grep -qx connected_slaves:2; }
old_rejoined() { admin_redis "$old_idx" INFO replication | tr -d '\r' | grep -qx master_link_status:up; }
wait_for 120 "Sentinel reports a new master address" addr_changed
new_addr=$(master_addr 0)
wait_for 120 "new master has role:master and 2 online replicas" new_master_ready
new_idx=$(master_index)
ok "failover completed in $(($(date +%s) - start))s: $(pod "$old_idx") -> $(pod "$new_idx") ($new_addr)"
for i in 0 1 2; do
  [ "$(master_addr "$i")" = "$new_addr" ] && ok "sentinel $i agrees on $new_addr" || bad "sentinel $i disagrees"
done
wait_for 120 "old master re-joined as a replica (master_link_status:up)" old_rejoined

info "ACLs on the new master"
for i in $(seq 0 $((REPLICAS - 1))); do
  [ "$(acl_digest "$i")" = "$before" ] && ok "redis node $i ACL LIST identical to pre-failover" || bad "redis node $i ACL LIST changed"
  [ "$(sentinel_acl_digest "$i")" = "$sbefore" ] && ok "sentinel $i ACL LIST identical" || bad "sentinel $i ACL LIST changed"
done
if [ "$PHASE" = 2 ]; then
  reps=$(admin_redis "$new_idx" CLIENT LIST TYPE replica | tr -d '\r')
  [ "$(grep -c ' user=replica-user ' <<<"$reps")" -eq 2 ] && ok "new master: replicas authenticated as replica-user" || bad "new master replica users: $(grep -o 'user=[^ ]*' <<<"$reps" | paste -sd,)"
  grep -E 'name=sentinel-' <<<"$(admin_redis "$new_idx" CLIENT LIST | tr -d '\r')" | grep -q ' user=default ' \
    && bad "a Sentinel uses default on the new master" || ok "new master: no Sentinel link uses default"
fi

info "app users after failover ($([ "$HAPROXY" = 1 ] && echo via HAProxy || echo via Sentinel discovery) from their own namespace)"
ts=$(date +%s)
[ "$(client orders SET orders:failover "$ts")" = OK ] && ok "orders-api writes to the NEW master" || bad "orders-api write after failover"
[ "$(client reporting GET orders:failover)" = "$ts" ] && ok "report-reader reads it" || bad "report-reader read after failover"
client reporting SET orders:failover x | grep -q NOPERM && ok "report-reader still read-only on the new master" || bad "permissions differ on the new master"
summary
