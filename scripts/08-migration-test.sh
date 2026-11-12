#!/usr/bin/env bash
# 8. Live migration from the existing redis-ha + HAProxy ("legacy", stock chart,
#    requirepass) into this release (HAProxy mode) with RedisShake:
#    seed typed data in 2 DBs + TTLs, keep a live writer on the legacy cluster, enable
#    migration, then verify: initial copy (INFO keyspace per DB), types/values/TTL, live
#    catch-up, no ACL denials for migration-user, cutover (writer stopped, counters
#    equal), migration removed (Deployment gone, migration-user revoked everywhere).
source "$(dirname "$0")/lib.sh"
[ "$HAPROXY" = 1 ] || { info "HAPROXY=1 required (migration writes through HAProxy)"; exit 0; }
LNS=${LNS:-legacy-redis}
LREL=${LREL:-legacy}
LFULL="${LREL}-redis-ha"
LHAP="${LFULL}-haproxy.${LNS}.svc"
LEGACY_VALUES=${LEGACY_VALUES:-$ROOT/scripts/ci/values-legacy.yaml}
REDIS_IMAGE=${REDIS_IMAGE:-public.ecr.aws/docker/library/redis:8.8.4-alpine}
SEED=${SEED:-3000}
mapfile -t VALUES < <(helm_values)

info "legacy cluster (stock redis-ha $(helm show chart "$CHART/charts/redis-ha-4.39.0.tgz" | awk '/^version:/{print $2}') + HAProxy, requirepass)"
kubectl create namespace "$LNS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
if ! kubectl -n "$LNS" get secret legacy-redis-auth >/dev/null 2>&1; then
  kubectl -n "$LNS" create secret generic legacy-redis-auth --from-literal=auth="$(head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32)" >/dev/null
fi
LEGACY_EXTRA=()
[ -n "${LEGACY_MESH:-}" ] && LEGACY_EXTRA=(--set-string "redis.podAnnotations.linkerd\.io/inject=enabled" --set-string "haproxy.podAnnotations.linkerd\.io/inject=enabled" --set-string "redis.podAnnotations.config\.linkerd\.io/opaque-ports=6379\,26379")
helm upgrade --install "$LREL" "$CHART/charts/redis-ha-4.39.0.tgz" -n "$LNS" -f "$LEGACY_VALUES" "${LEGACY_EXTRA[@]}" --wait --timeout 15m >/dev/null \
  && ok "legacy release deployed" || { bad "legacy deploy failed"; summary; exit 1; }
LPW=$(secret_val "$LNS" legacy-redis-auth auth)

# lcli args... : as the legacy `default` user through the legacy HAProxy (from a legacy pod)
lcli() { printf '%s' "$LPW" | kubectl -n "$LNS" exec -i "${LFULL}-server-0" -c redis -- sh -c 'IFS= read -r p; REDISCLI_AUTH="$p" exec redis-cli --no-auth-warning -h '"$LHAP"' "$@"' _ "$@"; }

info "seed data on legacy (db0 + db1, typed, TTL)"
{
  printf '%s\n' "$LPW"
  for i in $(seq 1 "$SEED"); do printf 'SET orders:k%d v%d\n' "$i" "$i"; done
  printf 'HSET orders:h f1 a f2 b\nRPUSH orders:l a b c\nSADD orders:s x y\nZADD orders:z 1 a 2 b\n'
  printf 'SET orders:ttl alive EX 3600\nSET payments:p1 secret\nSELECT 1\n'
  for i in $(seq 1 500); do printf 'SET db1:k%d %d\n' "$i" "$i"; done
} | kubectl -n "$LNS" exec -i "${LFULL}-server-0" -c redis -- sh -c 'IFS= read -r p; REDISCLI_AUTH="$p" exec redis-cli --no-auth-warning -h '"$LHAP"' >/dev/null'
ks=$(lcli INFO keyspace | tr -d '\r')
db0=$(sed -n 's/^db0:keys=\([0-9]*\),.*/\1/p' <<<"$ks")
[ "${db0:-0}" -ge $((SEED + 6)) ] && grep -q 'db1:keys=500,' <<<"$ks" && ok "legacy seeded: $(grep '^db' <<<"$ks" | cut -d, -f1 | paste -sd' ')" || bad "seed: $ks"

info "live writer on legacy (INCR every 100ms, as old apps do: default user via legacy HAProxy)"
kubectl -n "$LNS" delete pod legacy-writer --ignore-not-found --wait=true >/dev/null
kubectl -n "$LNS" create secret generic legacy-writer-auth --from-literal=auth="$LPW" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: { name: legacy-writer, namespace: $LNS }
spec:
  automountServiceAccountToken: false
  securityContext: { runAsNonRoot: true, runAsUser: 1000, seccompProfile: { type: RuntimeDefault } }
  containers:
    - name: writer
      image: $REDIS_IMAGE
      command: ["sh", "-c", "export REDISCLI_AUTH=\$(cat /auth/auth); while true; do redis-cli --no-auth-warning -h $LHAP -r -1 -i 0.1 INCR orders:live:counter >/dev/null 2>&1; sleep 0.5; done"]
      resources: { limits: { cpu: 100m, memory: 32Mi } }
      securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: [ALL] } }
      volumeMounts: [{ name: auth, mountPath: /auth, readOnly: true }]
  volumes: [{ name: auth, secret: { secretName: legacy-writer-auth } }]
EOF
kubectl -n "$LNS" wait --for=condition=Ready pod/legacy-writer --timeout=120s >/dev/null && ok "legacy writer running"

info "enable migration on the new release"
kubectl -n "$NS" create secret generic legacy-redis-source --from-literal=auth="$LPW" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
MIG=(--set migration.enabled=true --set "migration.source.address=${LHAP}:6379" --set migration.source.passwordSecret.name=legacy-redis-source)
s=$(date +%s)
helm upgrade "$RELEASE" "$CHART" -n "$NS" "${VALUES[@]}" "${MIG[@]}" --wait --timeout 15m >/dev/null \
  && ok "helm upgrade with migration.enabled ($(($(date +%s) - s))s): migration-user loaded by the reload Job" \
  || { bad "upgrade with migration failed"; kubectl -n "$NS" logs "deploy/${FULL}-migration" --tail=30; summary; exit 1; }
for i in $(seq 0 $((REPLICAS - 1))); do
  admin_redis "$i" ACL USERS | tr -d '\r' | grep -qx migration-user || bad "migration-user missing on node $i"
done
ok "migration-user present on all nodes"

new_keys() { admin_redis "$(master_index)" INFO keyspace | tr -d '\r' | grep "^db$1:" | sed 's/^db[0-9]*:keys=\([0-9]*\),.*/\1/'; }
src_keys() { lcli INFO keyspace | tr -d '\r' | sed -n "s/^db$1:keys=\([0-9]*\),.*/\1/p"; }
# The target may already hold keys of its own (other tests / early adopters), so db0 is
# ">=" the source; db1 is only used by the legacy apps and must match exactly.
synced() { local n0; n0=$(new_keys 0); [ -n "$n0" ] && [ "$n0" -ge "$(src_keys 0)" ] && [ "$(new_keys 1)" = "$(src_keys 1)" ]; }
wait_for 300 "initial copy complete (legacy db0=$(src_keys 0) db1=$(src_keys 1); target db0 >= source, db1 equal)" synced

info "content checks on the new cluster (as orders-api through the new HAProxy)"
[ "$(client orders GET orders:k42 | tr -d '\r')" = v42 ] && ok "string orders:k42" || bad "orders:k42"
[ "$(client orders HGET orders:h f2 | tr -d '\r')" = b ] && ok "hash orders:h" || bad "orders:h"
src_l=$(lcli LRANGE orders:l 0 -1 | tr -d '\r' | paste -sd,)
[ -n "$src_l" ] && [ "$(client orders LRANGE orders:l 0 -1 | tr -d '\r' | paste -sd,)" = "$src_l" ] && ok "list orders:l identical to the source ($src_l)" || bad "orders:l differs"
[ "$(client orders ZSCORE orders:z b | tr -d '\r')" = 2 ] && ok "zset orders:z" || bad "orders:z"
# Streams are NOT seeded: RedisShake 4.7.0 cannot parse Redis 8.8's stream RDB encoding
# (type 27) and aborts the sync (README: migration limitations).
ttl=$(client orders TTL orders:ttl | tr -d '\r')
[ "$ttl" -gt 3000 ] 2>/dev/null && ok "TTL preserved (orders:ttl ttl=${ttl}s)" || bad "TTL lost: $ttl"
client orders GET payments:p1 | grep -q NOPERM && ok "payments:p1 copied but NOT readable by orders-api (ACL applies to migrated data)" || bad "payments:p1 visible to orders-api"

info "live catch-up (legacy writer -> new cluster)"
live_equal() { local a b; a=$(lcli GET orders:live:counter | tr -d '\r'); b=$(client orders GET orders:live:counter | tr -d '\r'); [ -n "$a" ] && [ "$a" -gt 0 ] && [ $((a - b)) -le 20 ]; }
wait_for 60 "new cluster follows the live legacy writer (lag <= 2s of writes)" live_equal
log=$(admin_redis "$(master_index)" ACL LOG 100 | tr -d '\r')
if grep -A1 '^username$' <<<"$log" | grep -qx migration-user; then
  bad "ACL LOG denials for migration-user: $(grep -B1 -A12 -x 'migration-user' <<<"$log" | grep -A1 '^object$' | grep -v '^object$' | sort -u | paste -sd,)"
else
  ok "no ACL LOG denials for migration-user (least-privilege rules are sufficient)"
fi

info "cutover"
kubectl -n "$LNS" delete pod legacy-writer --wait=true >/dev/null && ok "legacy writer stopped (write freeze)"
final_equal() { [ "$(lcli GET orders:live:counter | tr -d '\r')" = "$(client orders GET orders:live:counter | tr -d '\r')" ]; }
wait_for 60 "final counter identical on legacy and new ($(lcli GET orders:live:counter | tr -d '\r'))" final_equal
s=$(date +%s)
helm upgrade "$RELEASE" "$CHART" -n "$NS" "${VALUES[@]}" --wait --timeout 15m >/dev/null && ok "migration disabled ($(($(date +%s) - s))s)" || bad "upgrade without migration failed"
kubectl -n "$NS" get deploy "${FULL}-migration" >/dev/null 2>&1 && bad "migration Deployment still present" || ok "migration Deployment removed"
gone=1
for i in $(seq 0 $((REPLICAS - 1))); do admin_redis "$i" ACL USERS | tr -d '\r' | grep -qx migration-user && gone=0; done
[ "$gone" = 1 ] && ok "migration-user revoked on every node" || bad "migration-user still present"
[ "$(client orders INCR orders:live:counter | tr -d '\r')" -gt 0 ] && ok "apps write to the new cluster after cutover" || bad "post-cutover write"
kubectl -n "$NS" delete secret legacy-redis-source --ignore-not-found >/dev/null
summary
