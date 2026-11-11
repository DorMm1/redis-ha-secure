#!/usr/bin/env bash
# 4. Phase 2: confirm the `default` user is rejected.
#    * unauthenticated connections are rejected (NOAUTH) on Redis and Sentinel
#    * `default` WITH its password can only do what the chart probes need (PING/ROLE/
#      INFO/SHUTDOWN on Redis; PING/get-master-addr/failover/reset on Sentinel).
#      Everything else (data, config, ACL, replication, the Sentinel hello channel)
#      is rejected with NOPERM.
#    * NO replication or Sentinel link is authenticated as `default` (CLIENT LIST)
#    * masteruser=replica-user on every node, Sentinel auth-user is effective
source "$(dirname "$0")/lib.sh"
set -f
if [ "$PHASE" != 2 ]; then info "PHASE=$PHASE: this test applies to phase 2 only (PHASE=2 $0)"; exit 0; fi
DPW=$(secret_val "$NS" "$INFRA_SECRET" default-password)
SDPW=$(secret_val "$NS" "$INFRA_SECRET" sentinel-default-password)

noauth() { kubectl exec -n "$NS" "$(pod "$1")" -c "$2" -- redis-cli -h localhost -p "$3" "${@:4}" 2>&1 | tr -d '\r'; }

for i in $(seq 0 $((REPLICAS - 1))); do
  info "$(pod "$i")"
  for c in "GET k" "PING" "INFO" "CONFIG GET maxmemory"; do
    # shellcheck disable=SC2086
    noauth "$i" redis 6379 $c | grep -q NOAUTH && ok "redis: unauthenticated '$c' -> NOAUTH" || bad "redis: unauthenticated '$c' NOT rejected"
  done
  # shellcheck disable=SC2046
  noauth "$i" sentinel 26379 SENTINEL MASTERS | grep -q NOAUTH && ok "sentinel: unauthenticated SENTINEL MASTERS -> NOAUTH" || bad "sentinel: unauthenticated access"
  cli_as "$(pod "$i")" redis default "not-the-password" localhost 6379 PING | grep -qE 'WRONGPASS|NOAUTH' && ok "redis: default + wrong password -> rejected" || bad "redis: wrong password"

  for c in "GET k" "SET k v" "DEL k" "KEYS *" "FLUSHALL" "CONFIG GET maxmemory" "CONFIG SET maxmemory 1" "ACL LIST" "ACL WHOAMI" \
    "SLAVEOF NO ONE" "REPLICAOF NO ONE" "CLIENT LIST" "PUBLISH __sentinel__:hello forged" "SUBSCRIBE __sentinel__:hello" "EVAL return 1 0" "MONITOR" "DEBUG SLEEP 0"; do
    # shellcheck disable=SC2086
    r=$(cli_as "$(pod "$i")" redis default "$DPW" localhost 6379 $c 2>&1 | tr -d '\r' | head -n2)
    grep -qE 'NOPERM|command not allowed' <<<"$r" && ok "redis: default '$c' -> rejected ($(grep -oE 'NOPERM|command not allowed' <<<"$r" | head -n1))" || bad "redis: default '$c' -> $r"
  done
  for c in "PING" "ROLE" "INFO replication"; do
    # shellcheck disable=SC2086
    r=$(cli_as "$(pod "$i")" redis default "$DPW" localhost 6379 $c 2>&1 | tr -d '\r' | head -n1)
    grep -q NOPERM <<<"$r" && bad "redis: default '$c' (probe) denied: $r" || ok "redis: default '$c' allowed (chart probe only)"
  done
  for c in "SENTINEL MASTERS" "SENTINEL MASTER $MASTER_GROUP" "SENTINEL SET $MASTER_GROUP quorum 1" "SENTINEL CONFIG GET *" "ACL LIST" "SENTINEL REMOVE $MASTER_GROUP"; do
    # shellcheck disable=SC2086
    r=$(cli_as "$(pod "$i")" sentinel default "$SDPW" localhost 26379 $c 2>&1 | tr -d '\r' | head -n1)
    grep -q NOPERM <<<"$r" && ok "sentinel: default '$c' -> NOPERM" || bad "sentinel: default '$c' -> $r"
  done
  r=$(cli_as "$(pod "$i")" sentinel default "$SDPW" localhost 26379 SENTINEL GET-MASTER-ADDR-BY-NAME "$MASTER_GROUP" | head -n1 | tr -d '\r')
  [[ "$r" =~ ^[0-9.]+$ ]] && ok "sentinel: default get-master-addr-by-name allowed (chart scripts)" || bad "sentinel default get-master-addr: $r"

  # No infra link may use `default`
  cl=$(admin_redis "$i" CLIENT LIST | tr -d '\r')
  n_def=$(grep -E 'name=sentinel-' <<<"$cl" | grep -c ' user=default ' || true)
  n_sen=$(grep -E 'name=sentinel-' <<<"$cl" | grep -c ' user=sentinel-user ' || true)
  [ "$n_def" -eq 0 ] && [ "$n_sen" -ge 1 ] && ok "redis: $n_sen Sentinel connections as sentinel-user, 0 as default" || bad "redis: Sentinel connections default=$n_def sentinel-user=$n_sen"
  scl=$(admin_sentinel "$i" CLIENT LIST | tr -d '\r')
  n_def=$(grep -E 'name=sentinel-' <<<"$scl" | grep -c ' user=default ' || true)
  n_peer=$(grep -E 'name=sentinel-' <<<"$scl" | grep -c ' user=sentinel-peer ' || true)
  [ "$n_def" -eq 0 ] && [ "$n_peer" -ge 1 ] && ok "sentinel: $n_peer peer connections as sentinel-peer, 0 as default" || bad "sentinel peers default=$n_def sentinel-peer=$n_peer"
  [ "$(admin_redis "$i" CONFIG GET masteruser | sed -n 2p | tr -d '\r')" = replica-user ] && ok "masteruser=replica-user" || bad "masteruser not replica-user"
done
m=$(master_index)
reps=$(admin_redis "$m" CLIENT LIST TYPE replica | tr -d '\r')
[ "$(grep -c ' user=replica-user ' <<<"$reps")" -eq 2 ] && ok "master: both replication links authenticated as replica-user" || bad "replication links: $(grep -o 'user=[^ ]*' <<<"$reps" | paste -sd,)"
unset DPW SDPW
summary
