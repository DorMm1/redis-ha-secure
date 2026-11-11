#!/usr/bin/env bash
# 2. Deploy (or upgrade) and verify replication (INFO replication) and Sentinel health
#    (SENTINEL MASTER / CKQUORUM), identical memory settings, ACL wiring, the reload Job,
#    credential delivery and NetworkPolicy (allowed vs. non-catalog namespace).
#   PHASE=1|2  EXTRA_VALUES=<file>  SKIP_DEPLOY=1 (verify only)
source "$(dirname "$0")/lib.sh"
CLIENT_IMAGE=${CLIENT_IMAGE:-public.ecr.aws/docker/library/redis:8.8.4-alpine}

if [ -z "${SKIP_DEPLOY:-}" ]; then
  info "namespaces + pre-created (ESO-style) password Secret for reporting/report-reader"
  for n in "$NS" orders reporting monitoring intruder; do
    kubectl create namespace "$n" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  done
  if ! kubectl get secret -n reporting reporting-redis >/dev/null 2>&1; then
    pw=$(head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32)
    kubectl create secret generic -n reporting reporting-redis \
      --from-literal=username=system.serviceaccount.reporting.report-reader \
      --from-literal=password="$pw" >/dev/null
    unset pw
  fi
  if [ "$HAPROXY" = 1 ]; then
    kubectl -n reporting patch secret reporting-redis --type merge \
      -p "{\"stringData\":{\"redis-address\":\"${HAP_SVC}:6379\"}}" >/dev/null
  fi

  info "helm upgrade --install (phase $PHASE)"
  mapfile -t VALUES < <(helm_values)
  start=$(date +%s)
  if helm upgrade --install "$RELEASE" "$CHART" -n "$NS" "${VALUES[@]}" --wait --timeout 20m; then
    ok "helm upgrade --install (phase $PHASE) in $(($(date +%s) - start))s (includes build + reload hooks)"
  else
    bad "helm upgrade --install failed"
    kubectl -n "$NS" logs "job/${FULL}-acl-build" --tail=40 2>/dev/null || true
    kubectl -n "$NS" logs "job/${FULL}-acl-reload" --all-containers --tail=60 2>/dev/null || true
    summary; exit 1
  fi
fi

info "pods / scheduling"
sts_ready() { [ "$(kubectl -n "$NS" get sts "${FULL}-server" -o jsonpath='{.status.readyReplicas}')" = 3 ]; }
wait_for 300 "StatefulSet ${FULL}-server ready (3/3)" sts_ready
nodes=$(kubectl -n "$NS" get pods -l "app=redis-ha,release=$RELEASE" -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort -u | wc -l)
schedulable=$(kubectl get nodes --no-headers | wc -l)
if [ "$schedulable" -ge 3 ]; then
  [ "$nodes" -eq 3 ] && ok "hard anti-affinity: 3 pods on 3 distinct nodes" || bad "pods share nodes ($nodes distinct)"
else
  info "single/two-node cluster ($schedulable nodes): anti-affinity check skipped (hardAntiAffinity disabled by the overlay)"
fi
kubectl -n "$NS" get pdb "${FULL}-pdb" -o jsonpath='{.spec.maxUnavailable}' | grep -qx 1 && ok "PDB maxUnavailable=1" || bad "PDB"
kubectl -n "$NS" get job "${FULL}-acl-reload" -o jsonpath='{.status.succeeded}' 2>/dev/null | grep -qx 1 \
  && ok "ACL reload Job succeeded" || bad "ACL reload Job not succeeded"

info "INFO replication"
m=$(master_index) && ok "master is $(pod "$m")" || { bad "no master"; summary; exit 1; }
repl=$(admin_redis "$m" INFO replication | tr -d '\r')
grep -qx 'connected_slaves:2' <<<"$repl" && ok "master: connected_slaves:2" || bad "master connected_slaves: $(grep connected_slaves <<<"$repl")"
[ "$(grep -c 'state=online' <<<"$repl")" -eq 2 ] && ok "master: both replicas state=online" || bad "replicas not online"
for i in $(seq 0 $((REPLICAS - 1))); do
  [ "$i" = "$m" ] && continue
  r=$(admin_redis "$i" INFO replication | tr -d '\r')
  grep -qx 'role:slave' <<<"$r" && grep -qx 'master_link_status:up' <<<"$r" \
    && ok "$(pod "$i"): role:slave, master_link_status:up" || bad "$(pod "$i") replication: $(grep -E 'role|link_status' <<<"$r" | tr '\n' ' ')"
done

info "SENTINEL MASTER / CKQUORUM (every Sentinel)"
maddr=$(master_addr 0)
for i in $(seq 0 $((REPLICAS - 1))); do
  sm=$(admin_sentinel "$i" SENTINEL MASTER "$MASTER_GROUP" | tr -d '\r')
  val() { awk -v k="$1" 'prev==k{print; exit} {prev=$0}' <<<"$sm"; }
  [ "$(val flags)" = "master" ] && [ "$(val num-slaves)" = 2 ] && [ "$(val num-other-sentinels)" = 2 ] && [ "$(val quorum)" = 2 ] && [ "$(val ip)" = "$maddr" ] \
    && ok "sentinel $i: flags=master num-slaves=2 num-other-sentinels=2 quorum=2 ip=$maddr" \
    || bad "sentinel $i: flags=$(val flags) slaves=$(val num-slaves) others=$(val num-other-sentinels) quorum=$(val quorum) ip=$(val ip)"
  admin_sentinel "$i" SENTINEL CKQUORUM "$MASTER_GROUP" | grep -q '^OK' && ok "sentinel $i: CKQUORUM OK" || bad "sentinel $i: CKQUORUM"
done

info "identical memory + ACL wiring on every node"
ref=""
for i in $(seq 0 $((REPLICAS - 1))); do
  cfg=$(admin_redis "$i" CONFIG GET maxmemory maxmemory-policy maxmemory-samples aclfile appendonly | tr -d '\r' | paste -d' ' - - | sort | paste -sd' ')
  [ -z "$ref" ] && ref=$cfg
  [ "$cfg" = "$ref" ] && ok "$(pod "$i"): $cfg" || bad "$(pod "$i") differs: $cfg"
done
d0=$(acl_digest 0)
for i in 1 2; do [ "$(acl_digest "$i")" = "$d0" ] && ok "ACL LIST node $i == node 0" || bad "ACL LIST node $i differs"; done
s0=$(sentinel_acl_digest 0)
for i in 1 2; do [ "$(sentinel_acl_digest "$i")" = "$s0" ] && ok "Sentinel ACL LIST $i == 0" || bad "Sentinel ACL LIST $i differs"; done
mounts=$(kubectl -n "$NS" get sts "${FULL}-server" -o json | grep -c '"subPath"' || true)
[ "$mounts" -eq 0 ] && ok "no subPath mounts in the StatefulSet" || bad "subPath mounts found"
kubectl -n "$NS" logs "$(pod 0)" -c acl-watch --tail=1 | grep -q "users=$(admin_redis 0 ACL LIST | tr -d '\r' | sed -n 's/^user acl-revision .*#\([0-9a-f]\{64\}\).*/\1/p')" \
  && ok "acl-watch: mounted revision == loaded revision" || bad "acl-watch revision mismatch"

info "credential delivery"
for s in orders/redis-acl-orders-api reporting/reporting-redis; do
  n=${s%%/*} sec=${s##*/}
  u=$(secret_val "$n" "$sec" username)
  [ "$u" = "system.serviceaccount.${n}.$(case $n in orders) echo orders-api;; reporting) echo report-reader;; esac)" ] \
    && ok "$n/$sec: username=$u" || bad "$n/$sec username '$u'"
done
if [ "$HAPROXY" = 1 ]; then
  [ "$(secret_val orders redis-acl-orders-api redis-address)" = "${HAP_SVC}:6379" ] && ok "orders credential Secret: redis-address=${HAP_SVC}:6379" || bad "redis-address missing/wrong"
  [ -z "$(secret_val orders redis-acl-orders-api sentinel-addresses 2>/dev/null)" ] && ok "orders credential Secret: no sentinel-addresses in HAProxy mode" || bad "sentinel-addresses present in HAProxy mode"
else
  secret_val orders redis-acl-orders-api sentinel-addresses | grep -q "${FULL}-announce-0" && ok "orders credential Secret carries sentinel-addresses" || bad "sentinel-addresses missing"
fi

info "client pods (real ServiceAccounts, Sentinel-aware flow)"
mkclient() { # <ns> <sa> <secret>
  kubectl -n "$1" create serviceaccount "$2" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: { name: redis-client, namespace: $1, labels: { app: redis-client }, annotations: { linkerd.io/inject: ${MESH_INJECT:-disabled} } }
spec:
  serviceAccountName: $2
  automountServiceAccountToken: false
  securityContext: { runAsNonRoot: true, runAsUser: 1000, seccompProfile: { type: RuntimeDefault } }
  containers:
    - name: client
      image: $CLIENT_IMAGE
      command: ["sh", "-c", "trap 'exit 0' TERM; sleep 86400 & wait"]
      resources: { limits: { cpu: 100m, memory: 32Mi } }
      securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: [ALL] } }
      volumeMounts: [{ name: creds, mountPath: /creds, readOnly: true }]
  volumes: [{ name: creds, secret: { secretName: $3 } }]
EOF
}
mkclient orders orders-api redis-acl-orders-api
mkclient reporting report-reader reporting-redis
kubectl -n intruder create secret generic redis-acl-orders-api --from-literal=username=x --from-literal=password=x --dry-run=client -o yaml | kubectl apply -f - >/dev/null
mkclient intruder default redis-acl-orders-api
for n in orders reporting intruder; do kubectl -n "$n" wait --for=condition=Ready pod/redis-client --timeout=180s >/dev/null; done
ok "client pods ready"

[ "$(client orders SET orders:smoke 1)" = OK ] && ok "orders-api: SET orders:smoke ($([ "$HAPROXY" = 1 ] && echo via HAProxy || echo via Sentinel discovery))" || bad "orders-api SET"
[ "$(client orders GET orders:smoke)" = 1 ] && ok "orders-api: GET orders:smoke" || bad "orders-api GET"
client orders SET payments:x 1 | grep -q NOPERM && ok "orders-api: SET payments:x -> NOPERM" || bad "orders-api wrote outside its prefix"
[ "$(client reporting GET orders:smoke)" = 1 ] && ok "report-reader (ESO-style Secret): GET orders:smoke" || bad "report-reader GET"
client reporting SET orders:smoke 2 | grep -q NOPERM && ok "report-reader: SET orders:smoke -> NOPERM (read-only prefix)" || bad "report-reader could write"
# reach <ns> <host> <port>: true if a TCP-level Redis conversation succeeds (any reply)
reach() { kubectl -n "$1" exec redis-client -- sh -c "timeout 5 redis-cli -h $2 -p $3 PING 2>&1" | grep -qE 'PONG|NOAUTH|WRONGPASS|NOPERM'; }
if reach intruder "${FULL}-announce-0.${NS}.svc" 6379; then bad "namespace 'intruder' (not in catalog) reached Redis 6379"; else ok "namespace 'intruder' (not in catalog) cannot reach Redis 6379"; fi
if [ "$HAPROXY" = 1 ]; then
  if reach intruder "$HAP_SVC" 6379; then bad "namespace 'intruder' reached HAProxy"; else ok "namespace 'intruder' (not in catalog) cannot reach HAProxy"; fi
  if reach orders "${FULL}-announce-0.${NS}.svc" 6379; then bad "catalog client reached Redis directly (must go through HAProxy)"; else ok "catalog client cannot bypass HAProxy (Redis 6379 blocked)"; fi
  if reach orders "${FULL}-announce-0.${NS}.svc" 26379; then bad "catalog client reached Sentinel directly"; else ok "catalog client cannot reach Sentinel 26379 (not needed in HAProxy mode)"; fi
fi
summary
