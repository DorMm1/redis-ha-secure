#!/usr/bin/env bash
# 9. Disaster recovery, end to end (HAProxy or direct mode, any phase):
#    a) off-cluster backup: Job from the dr-backup CronJob snapshots a REPLICA as backup-user,
#       verifies it, uploads it (dump.rdb + backup.meta + SHA256SUMS) and updates LATEST
#    b) disaster: helm uninstall + every PVC deleted (= new, empty cluster)
#    c) bootstrap restore: helm install with values-dr-restore.yaml + the backup id.
#       Every pod restores the same snapshot (as the AOF base); data written AFTER the
#       backup is absent (point in time); streams/hashes/lists/TTLs/ACL users all work
#    d) idempotency: a restarted pod with data skips the restore
#    e) overlay removed (rolling restart): data kept; a new backup succeeds
# Object store: `rclone serve s3` in namespace dr-test (emptyDir), created here.
source "$(dirname "$0")/lib.sh"
EXTRA_VALUES="$EXTRA_VALUES $ROOT/scripts/ci/values-dr-test.yaml"
mapfile -t VALUES < <(helm_values)
STORE_NS=dr-test
RCLONE_IMAGE=docker.io/rclone/rclone:1.76.0
TMP=$(mktmpd)
trap 'rm -rf "$TMP"' EXIT
admin_pw >/dev/null 2>&1 || true

store() { kubectl -n "$STORE_NS" exec deploy/drstore -- "$@"; }
keyspace() { admin_redis "$1" INFO keyspace | tr -d '\r' | grep '^db0:' | sed 's/,expires.*//'; }
export STORE_NS REPLICAS MASTER_GROUP INFRA_SECRET ADMIN_PW
export -f store keyspace admin_redis admin_pw cli_as pod secret_val client master_index
run_backup() { # <job-name> -> prints the backup id
  kubectl -n "$NS" create job --from="cronjob/${FULL}-dr-backup" "$1" >/dev/null
  if ! kubectl -n "$NS" wait --for=condition=complete "job/$1" --timeout=300s >/dev/null; then
    kubectl -n "$NS" logs "job/$1" --all-containers --tail=40 >&2; return 1
  fi
  kubectl -n "$NS" logs "job/$1" -c upload | sed -n 's#.*uploaded .*/\([0-9]\{8\}T[0-9]\{6\}Z\)$#\1#p' | tail -n1
}

info "object store: rclone serve s3 in namespace $STORE_NS"
AK=dr$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n')
SK=$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')
kubectl create namespace "$STORE_NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n "$STORE_NS" create secret generic drstore-auth --from-literal=auth="$AK,$SK" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
cat >"$TMP/store.yaml" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata: { name: drstore, namespace: $STORE_NS }
spec:
  replicas: 1
  selector: { matchLabels: { app: drstore } }
  template:
    metadata: { labels: { app: drstore } }
    spec:
      securityContext: { runAsNonRoot: true, runAsUser: 65532, fsGroup: 65532, seccompProfile: { type: RuntimeDefault } }
      containers:
        - name: rclone
          image: $RCLONE_IMAGE
          command: [/bin/sh, -c, 'mkdir -p /store/redis-dr && exec rclone serve s3 /store --addr :8080 --auth-key "\$AUTH" --vfs-cache-mode writes --cache-dir /cache']
          env: [{ name: AUTH, valueFrom: { secretKeyRef: { name: drstore-auth, key: auth } } }, { name: HOME, value: /cache }]
          ports: [{ containerPort: 8080 }]
          readinessProbe: { tcpSocket: { port: 8080 }, periodSeconds: 2 }
          resources: { requests: { cpu: 50m, memory: 64Mi }, limits: { cpu: "1", memory: 256Mi } }
          securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: [ALL] } }
          volumeMounts: [{ name: store, mountPath: /store }, { name: cache, mountPath: /cache }]
      volumes: [{ name: store, emptyDir: {} }, { name: cache, emptyDir: {} }]
---
apiVersion: v1
kind: Service
metadata: { name: drstore, namespace: $STORE_NS }
spec: { selector: { app: drstore }, ports: [{ port: 8080, targetPort: 8080 }] }
EOF
kubectl apply -f "$TMP/store.yaml" >/dev/null
check "object store ready" kubectl -n "$STORE_NS" rollout status deploy/drstore --timeout=180s
kubectl -n "$NS" create secret generic redis-ha-dr-storage \
  --from-literal=RCLONE_CONFIG_S3_TYPE=s3 --from-literal=RCLONE_CONFIG_S3_PROVIDER=Other \
  --from-literal=RCLONE_CONFIG_S3_ENDPOINT="http://drstore.$STORE_NS.svc:8080" \
  --from-literal=RCLONE_CONFIG_S3_ACCESS_KEY_ID="$AK" --from-literal=RCLONE_CONFIG_S3_SECRET_ACCESS_KEY="$SK" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

info "enable dr.backup (helm upgrade)"
if helm upgrade --install "$RELEASE" "$CHART" -n "$NS" "${VALUES[@]}" --wait --timeout 15m >/dev/null; then ok "helm upgrade with dr.backup"; else bad "helm upgrade with dr.backup"; summary; exit 1; fi
wait_for 180 "client reaches the master" bash -c "[ \"\$(client orders PING 2>/dev/null | tr -d '\r')\" = PONG ]"
check "backup-user present on every node" bash -c 'for i in $(seq 0 $((REPLICAS - 1))); do admin_redis $i ACL GETUSER backup-user | grep -q sync || exit 1; done'

info "seed data (orders-api through the client path)"
client orders DEL orders:dr:str orders:dr:h orders:dr:s orders:dr:l orders:dr:z orders:dr:ttl orders:dr:after >/dev/null
client orders SET orders:dr:str "hello dr" >/dev/null
client orders HSET orders:dr:h a 1 b 2 >/dev/null
for i in 1 2 3; do client orders XADD orders:dr:s '*' n "$i" >/dev/null; done
client orders RPUSH orders:dr:l x y z >/dev/null
client orders ZADD orders:dr:z 1 one 2 two >/dev/null
client orders SET orders:dr:ttl v EX 86400 >/dev/null
for i in $(seq 1 500); do echo "SET orders:dr:bulk:$i $i"; done | kubectl -n orders exec -i redis-client -- sh -c '
  export REDISCLI_AUTH=$(cat /creds/password); A=$(cat /creds/redis-address 2>/dev/null || true)
  if [ -n "$A" ]; then H=${A%:*}; P=${A##*:}; else H='"$(pod 0).${FULL}.${NS}.svc"'; P=6379; fi
  redis-cli --no-auth-warning --user "$(cat /creds/username)" -h "$H" -p "$P" >/dev/null'
M=$(master_index)
sleep 2
BEFORE=$(keyspace "$M")
info "keyspace before backup (master $M): $BEFORE"

info "a) backup"
ID=$(run_backup "dr-backup-t1-$(date +%s)")
if [ -n "$ID" ]; then ok "backup Job completed: $ID"; else bad "backup Job failed"; summary; exit 1; fi
J=$(kubectl -n "$NS" get jobs -l app.kubernetes.io/component=dr-backup --sort-by=.metadata.creationTimestamp -o name | tail -n1)
check "snapshot taken from a REPLICA, not the master" bash -c "kubectl -n $NS logs $J -c snapshot | grep -q 'snapshot source: .*(replica)'"
check "snapshot verified by redis-check-rdb" bash -c "kubectl -n $NS logs $J -c snapshot | grep -q 'snapshot $ID OK'"
check "remote has dump.rdb + backup.meta + SHA256SUMS" bash -c "store ls /store/redis-dr/redis/$ID | sort | tr '\n' ' ' | grep -q 'SHA256SUMS backup.meta dump.rdb'"
check "remote LATEST = $ID" bash -c "[ \"\$(store cat /store/redis-dr/redis/LATEST | tr -d '\r\n')\" = $ID ]"
check "remote checksums verify" store sh -c "cd /store/redis-dr/redis/$ID && sha256sum -c SHA256SUMS"
check "no ACL denials for backup-user" bash -c 'for i in $(seq 0 $((REPLICAS - 1))); do admin_redis $i ACL LOG 100 | grep -q backup-user && exit 1; done; true'
client orders SET orders:dr:after "written after the backup" >/dev/null

info "b) disaster: uninstall + delete every PVC"
helm uninstall "$RELEASE" -n "$NS" --wait --timeout 5m >/dev/null && ok "helm uninstall" || bad "helm uninstall"
kubectl -n "$NS" delete pvc -l "app=redis-ha,release=$RELEASE" --wait=true --timeout=180s >/dev/null && ok "PVCs deleted" || bad "PVC delete"
check "no Redis pods and no PVCs left" bash -c "[ -z \"\$(kubectl -n $NS get pods,pvc -l app=redis-ha,release=$RELEASE -o name)\" ]"

info "c) bootstrap restore of $ID"
s=$(date +%s)
if helm upgrade --install "$RELEASE" "$CHART" -n "$NS" "${VALUES[@]}" -f "$CHART/values-dr-restore.yaml" \
  --set dr.restore.backupId="$ID" --wait --timeout 20m >/dev/null; then
  ok "helm install with values-dr-restore.yaml in $(($(date +%s) - s))s"
else
  bad "helm install with restore"; kubectl -n "$NS" get pods; summary; exit 1
fi
wait_for 240 "client reaches the master after restore" bash -c "[ \"\$(client orders PING 2>/dev/null | tr -d '\r')\" = PONG ]"
for i in $(seq 0 $((REPLICAS - 1))); do
  check "pod $i restored $ID (init log + marker)" bash -c "kubectl -n $NS logs $(pod "$i") -c dr-restore-install | grep -q 'installed backup $ID' && kubectl -n $NS exec $(pod "$i") -c redis -- grep -q 'backup_id=$ID' /data/.dr-restored-from"
done
wait_for 120 "every node has the backup's keyspace ($BEFORE)" bash -c 'for i in $(seq 0 $((REPLICAS - 1))); do [ "$(keyspace $i)" = "'"$BEFORE"'" ] || exit 1; done'
check "string restored" bash -c "[ \"\$(client orders GET orders:dr:str | tr -d '\r')\" = 'hello dr' ]"
check "hash restored" bash -c "[ \"\$(client orders HGET orders:dr:h b | tr -d '\r')\" = 2 ]"
check "stream restored (3 entries; RedisShake cannot do this on Redis 8)" bash -c "[ \"\$(client orders XLEN orders:dr:s | tr -d '\r')\" = 3 ]"
check "list restored" bash -c "[ \"\$(client orders LRANGE orders:dr:l 0 -1 | tr -d '\r' | paste -sd,)\" = x,y,z ]"
check "zset restored" bash -c "[ \"\$(client orders ZSCORE orders:dr:z two | tr -d '\r')\" = 2 ]"
check "TTL kept" bash -c "t=\$(client orders TTL orders:dr:ttl | tr -d '\r'); [ \"\$t\" -gt 80000 ]"
check "point in time: key written after the backup is absent" bash -c "[ \"\$(client orders EXISTS orders:dr:after | tr -d '\r')\" = 0 ]"
check "ACLs from the catalog, not from the backup: app user still NOPERM outside its prefix" bash -c "client orders SET other:x 1 2>&1 | grep -q NOPERM"
check "AOF is on and based on the restored snapshot" bash -c "kubectl -n $NS exec $(pod 0) -c redis -- sh -c 'grep -q \"type b\" /data/appendonlydir/appendonly.aof.manifest' && admin_redis 0 INFO persistence | tr -d '\r' | grep -q '^aof_enabled:1'"
check "replication healthy: master has $((REPLICAS - 1)) replicas" bash -c "admin_redis \$(master_index) INFO replication | tr -d '\r' | grep -q '^connected_slaves:$((REPLICAS - 1))'"

info "d) idempotency: restarted pod with data skips the restore"
R=$(( ($(master_index) + 1) % REPLICAS ))
kubectl -n "$NS" delete pod "$(pod "$R")" --wait=true >/dev/null
kubectl -n "$NS" wait --for=condition=Ready "pod/$(pod "$R")" --timeout=300s >/dev/null
check "pod $R: fetch skipped (data present)" bash -c "kubectl -n $NS logs $(pod "$R") -c dr-restore-fetch | grep -q 'restore skipped'"
wait_for 120 "pod $R keyspace still $BEFORE" bash -c '[ "$(keyspace '"$R"')" = "'"$BEFORE"'" ]'

info "e) remove the restore overlay; take a new backup"
if helm upgrade "$RELEASE" "$CHART" -n "$NS" "${VALUES[@]}" --wait --timeout 20m >/dev/null; then ok "helm upgrade without values-dr-restore.yaml"; else bad "helm upgrade without overlay"; fi
wait_for 300 "no dr-restore init containers left" bash -c "! kubectl -n $NS get pods -l app=redis-ha,release=$RELEASE -o jsonpath='{..initContainers[*].name}' | grep -q dr-restore"
check "restore ConfigMap removed" bash -c "! kubectl -n $NS get configmap redis-ha-dr-restore >/dev/null 2>&1"
wait_for 240 "client reaches the master" bash -c "[ \"\$(client orders XLEN orders:dr:s | tr -d '\r')\" = 3 ]"
check "data kept across the rolling restart" bash -c '[ "$(keyspace $(master_index))" = "'"$BEFORE"'" ]'
ID2=$(run_backup "dr-backup-t2-$(date +%s)")
if [ -n "$ID2" ] && [ "$ID2" != "$ID" ]; then ok "new backup after restore: $ID2"; else bad "backup after restore"; fi
check "LATEST advanced to $ID2" bash -c "[ \"\$(store cat /store/redis-dr/redis/LATEST | tr -d '\r\n')\" = '$ID2' ]"

if [ "${KEEP_STORE:-0}" != 1 ]; then
  kubectl delete namespace "$STORE_NS" --wait=false >/dev/null
  kubectl -n "$NS" delete secret redis-ha-dr-storage >/dev/null
fi
summary
