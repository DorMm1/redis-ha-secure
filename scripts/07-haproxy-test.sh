#!/usr/bin/env bash
# 7. HAProxy front door (HAPROXY=1):
#   a) every HAProxy pod: exactly one master UP, the agreed master seen by all Sentinels,
#      health checks authenticated as haproxy-user (never `default`)
#   b) persistent-connection failover: a client holding ONE connection while writing
#      every 100ms. On SENTINEL FAILOVER HAProxy must close it (on-marked-down
#      shutdown-sessions). The client reconnects to the new master. READONLY errors are
#      bounded to the detection window (stock config: until the client reconnects)
#   c) quorum routing: with < 2 Sentinels answering HAProxy, NEW connections are refused
#      (no guessing), existing ones keep working. Restored by ACL LOAD (no restarts)
#   d) readiness gating: an upgrade whose HAProxy cannot health-check never becomes
#      Ready, the rollout stalls, and the old pods keep serving. Then repaired.
#   e) no HAProxy / Redis restarts throughout
source "$(dirname "$0")/lib.sh"
[ "$HAPROXY" = 1 ] || { info "HAPROXY=1 required"; exit 0; }
CLIENT_IMAGE=${CLIENT_IMAGE:-public.ecr.aws/docker/library/redis:8.8.4-alpine}
mapfile -t VALUES < <(helm_values)
HSEL="app=redis-ha-haproxy,release=$RELEASE"

hap_pods() { kubectl -n "$NS" get pods -l "$HSEL" --field-selector=status.phase=Running -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'; }
metric() { # <pod> <metric> <proxy> -> sum of values
  kubectl -n "$NS" exec "$1" -c haproxy -- wget -qO- http://127.0.0.1:9101/metrics 2>/dev/null \
    | awk -v m="$2" -v p="proxy=\"$3\"" 'index($0, m"{")==1 && index($0, p) {s+=$NF} END {print s+0}'
}
restarts() { kubectl -n "$NS" get pods -l "app in (redis-ha,redis-ha-haproxy),release=$RELEASE" \
  -o jsonpath='{range .items[*]}{.metadata.name}={.metadata.uid}:{range .status.containerStatuses[*]}{.restartCount},{end}{"\n"}{end}' | sort; }

# The quorum test revokes haproxy-user rights on Sentinels at runtime. Always put the
# file's ACLs back (also at start, in case an earlier run was interrupted).
restore_sentinel_acls() { local i; for i in $(seq 0 $((REPLICAS - 1))); do admin_sentinel "$i" ACL LOAD >/dev/null 2>&1 || true; done; }
trap restore_sentinel_acls EXIT
restore_sentinel_acls
settled() { local p; for p in $(hap_pods); do [ "$(metric "$p" haproxy_backend_active_servers "check_if_redis_is_master_$(master_index)")" = 3 ] || return 1; done; }
wait_for 60 "HAProxy settled (all Sentinels agree on the master)" settled

info "a) HAProxy state"
pods=$(hap_pods)
[ "$(wc -w <<<"$pods")" -eq "$(kubectl -n "$NS" get deploy "${FULL}-haproxy" -o jsonpath='{.spec.replicas}')" ] && ok "HAProxy pods running: $(wc -w <<<"$pods")" || bad "HAProxy pods: $pods"
m=$(master_index)
for p in $pods; do
  [ "$(metric "$p" haproxy_backend_active_servers bk_redis_master)" = 1 ] && ok "$p: bk_redis_master has exactly 1 UP server" || bad "$p: bk_redis_master active=$(metric "$p" haproxy_backend_active_servers bk_redis_master)"
  [ "$(metric "$p" haproxy_backend_active_servers "check_if_redis_is_master_$m")" = 3 ] && ok "$p: all 3 Sentinels agree master is R$m" || bad "$p: sentinels agreeing on R$m: $(metric "$p" haproxy_backend_active_servers "check_if_redis_is_master_$m")"
  kubectl -n "$NS" get pod "$p" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' | grep -qx True && ok "$p: Ready (gated on having seen a master)" || bad "$p not Ready"
done
# Recent ACL LOG entries only (the log is cumulative across ACL LOADs).
recent_denials() { # <redis|sentinel> <i> <user>: entries younger than 120s for <user>
  local out
  if [ "$1" = redis ]; then out=$(admin_redis "$2" ACL LOG 100); else out=$(admin_sentinel "$2" ACL LOG 100); fi
  tr -d '\r' <<<"$out" | awk -v u="$3" '
    /^username$/ {getline; user=$0}
    /^age-seconds$/ {getline; age=$0}
    /^client-info$/ {if (user == u && age + 0 < 120) n++}
    END {print n + 0}'
}
d=0
for i in $(seq 0 $((REPLICAS - 1))); do d=$((d + $(recent_denials redis "$i" haproxy-user) + $(recent_denials sentinel "$i" haproxy-user))); done
[ "$d" -eq 0 ] && ok "no recent ACL LOG denials for haproxy-user on any Redis node or Sentinel" || bad "$d recent ACL LOG denials for haproxy-user"
before_restarts=$(restarts)

info "b) persistent-connection failover"
kubectl -n orders delete pod hap-writer --ignore-not-found --wait=true >/dev/null
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: { name: hap-writer, namespace: orders, annotations: { linkerd.io/inject: ${MESH_INJECT:-disabled} } }
spec:
  serviceAccountName: orders-api
  automountServiceAccountToken: false
  securityContext: { runAsNonRoot: true, runAsUser: 1000, seccompProfile: { type: RuntimeDefault } }
  containers:
    - name: writer
      image: $CLIENT_IMAGE
      command: ["sh", "-c"]
      args:
        - |
          U=\$(cat /creds/username); export REDISCLI_AUTH=\$(cat /creds/password); A=\$(cat /creds/redis-address)
          while true; do
            echo "CONNECT \$(date +%s)"
            redis-cli --no-auth-warning --user "\$U" -h "\${A%:*}" -p "\${A##*:}" -r -1 -i 0.1 INCR orders:hap:counter 2>&1 \
              | while IFS= read -r l; do echo "\$(date +%s) \$l"; done
            echo "CLOSED \$(date +%s)"
            sleep 0.2
          done
      resources: { limits: { cpu: 200m, memory: 32Mi } }
      securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: [ALL] } }
      volumeMounts: [{ name: creds, mountPath: /creds, readOnly: true }]
  volumes: [{ name: creds, secret: { secretName: redis-acl-orders-api } }]
EOF
kubectl -n orders wait --for=condition=Ready pod/hap-writer --timeout=180s >/dev/null && ok "writer pod running (one persistent connection, INCR every 100ms)"
sleep 5
wlog() { kubectl -n orders logs hap-writer -c writer; }
[ "$(wlog | grep -c '^CONNECT')" -eq 1 ] && ok "writer is on its first connection" || bad "writer reconnected before the failover"
t0=$(date +%s)
admin_sentinel 0 SENTINEL FAILOVER "$MASTER_GROUP" | tr -d '\r' | grep -qx OK && ok "SENTINEL FAILOVER issued at $t0" || bad "SENTINEL FAILOVER"
new_master() { local i; i=$(master_index) && [ "$i" != "$m" ]; }
wait_for 90 "new master elected" new_master
second_conn() { [ "$(wlog | grep -c '^CONNECT')" -ge 2 ]; }
wait_for 60 "HAProxy closed the old connection, writer reconnected" second_conn
sleep 5
L=$(wlog)
closed_at=$(grep -m1 '^CLOSED' <<<"$L" | awk '{print $2}' || true)
ro=$(grep -c 'READONLY' <<<"$L" || true)
ro_first=$(grep -m1 'READONLY' <<<"$L" | awk '{print $1}' || true)
ro_last=$(grep 'READONLY' <<<"$L" | tail -n1 | awk '{print $1}' || true)
info "failover at $t0, old connection closed at ${closed_at:-never} ($((${closed_at:-0} - t0))s), READONLY replies: $ro ${ro_first:+(${ro_first}..${ro_last})}"
[ -n "$closed_at" ] && [ $((closed_at - t0)) -le 30 ] && ok "persistent connection closed by HAProxy $((closed_at - t0))s after the failover (shutdown-sessions)" || bad "connection not closed within 30s"
if [ "$ro" -eq 0 ]; then ok "no READONLY errors"; else
  [ $((ro_last - ro_first)) -le 5 ] && ok "READONLY window bounded to $((ro_last - ro_first + 1))s (fall=2 x inter=1s)" || bad "READONLY errors for $((ro_last - ro_first + 1))s"
fi
last_ok=$(tail -n 3 <<<"$L" | grep -E '^[0-9]+ [0-9]+$' | tail -n1 | awk '{print $2}' || true)
# Acknowledged-but-lost writes: highest counter acknowledged on the old connection vs
# the first value on the new master (Sentinel async-replication window).
max_old=$(awk '/^CLOSED/{exit} /^[0-9]+ [0-9]+$/{print $2}' <<<"$L" | sort -n | tail -n1)
first_new=$(awk 'c==2 && /^[0-9]+ [0-9]+$/{print $2; exit} /^CONNECT/{c++}' <<<"$L")
nore=$(grep -c 'NOREPLICAS' <<<"$L" || true)
lost=$(( max_old - first_new + 1 )); [ "$lost" -lt 0 ] && lost=0
info "acknowledged writes lost in the failover: $lost (~$((lost * 100))ms of writes); refused with NOREPLICAS (min-replicas-to-write, not lost): $nore"
[ "$lost" -le 20 ] && ok "acknowledged-write loss bounded to <= 2s of writes ($lost)" || bad "lost $lost acknowledged writes"
[ -n "$last_ok" ] && ok "writes succeed on the new connection (counter=$last_ok)" || bad "writer not writing after reconnect: $(tail -n 3 <<<"$L" | tr '\n' '|')"
m=$(master_index)

info "c) quorum routing (2 of 3 Sentinels stop answering HAProxy)"
for i in 1 2; do admin_sentinel $(( (m + i) % REPLICAS )) ACL SETUSER haproxy-user -sentinel\|get-master-addr-by-name >/dev/null; done
no_quorum() { local p; for p in $pods; do [ "$(metric "$p" haproxy_backend_active_servers "check_if_redis_is_master_$m")" -lt 2 ] || return 1; done; }
pods=$(hap_pods)
wait_for 30 "HAProxy sees < 2 Sentinels agreeing" no_quorum
r=$(client orders PING 2>&1 | tr -d '\r' || true)
grep -qE 'PONG' <<<"$r" && bad "new connection accepted without Sentinel quorum" || ok "new client connection refused without Sentinel quorum ($(head -c 60 <<<"$r"))"
before_conn=$(wlog | grep -c '^CONNECT')
sleep 3
[ "$(wlog | grep -c '^CONNECT')" -eq "$before_conn" ] && tail -n1 <<<"$(wlog)" | grep -qE '^[0-9]+ [0-9]+$' && ok "existing connection keeps working (no forced disconnect on quorum loss)" || bad "existing connection disturbed"
for i in 0 1 2; do admin_sentinel "$i" ACL LOAD >/dev/null; done
quorum_back() { local p; for p in $pods; do [ "$(metric "$p" haproxy_backend_active_servers "check_if_redis_is_master_$m")" -eq 3 ] || return 1; done; }
wait_for 30 "quorum restored by ACL LOAD from the mounted file" quorum_back
[ "$(client orders PING 2>/dev/null | tr -d '\r' || true)" = PONG ] && ok "new connections accepted again" || bad "connections still refused"

info "d) readiness gating of a broken HAProxy rollout (typo in the health-check user -> WRONGPASS)"
kubectl -n orders delete pod hap-writer --ignore-not-found --wait=false >/dev/null
BAD="$(mktmpd)/bad-haproxy.cfg"
PY=$(command -v python3 || command -v python)
"$PY" -c 'import sys, yaml; v = yaml.safe_load(open(sys.argv[1], encoding="utf-8")); open(sys.argv[2], "w", newline="\n").write(v["redis-ha"]["haproxy"]["customConfig"].replace("AUTH {{ $user }}", "AUTH {{ $user }}-typo"))' "$CHART/values.yaml" "$BAD"
grep -q 'AUTH {{ $user }}-typo' "$BAD" && ok "prepared a broken HAProxy config" || bad "could not prepare broken config"
s=$(date +%s)
if helm upgrade "$RELEASE" "$CHART" -n "$NS" "${VALUES[@]}" --set-file "redis-ha.haproxy.customConfig=$BAD" --wait --timeout 100s >/dev/null 2>&1; then
  bad "broken HAProxy config became Ready (rollout was not gated)"
else
  ok "broken HAProxy rollout did not become Ready ($(($(date +%s) - s))s, release marked failed)"
fi
ready=$(kubectl -n "$NS" get pods -l "$HSEL" -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' | grep -c True)
[ "$ready" -ge 2 ] && ok "$ready old HAProxy pods still Ready and serving during the stalled rollout" || bad "only $ready HAProxy pods Ready"
[ "$(client orders SET orders:during-bad-rollout 1 | tr -d '\r')" = OK ] && ok "clients unaffected during the stalled rollout" || bad "client write failed during stalled rollout"
s=$(date +%s)
helm upgrade "$RELEASE" "$CHART" -n "$NS" "${VALUES[@]}" --wait --timeout 10m >/dev/null && ok "repaired by a good upgrade ($(($(date +%s) - s))s)" || bad "repair upgrade failed"
[ "$(client orders GET orders:during-bad-rollout | tr -d '\r')" = 1 ] && ok "data intact after the repair" || bad "data check after repair"

info "e) restarts"
kubectl -n "$NS" rollout status deploy "${FULL}-haproxy" --timeout=180s >/dev/null && ok "HAProxy rollout complete"
gone() { [ "$(kubectl -n "$NS" get pods -l "$HSEL" --no-headers | wc -l)" -eq "$(kubectl -n "$NS" get deploy "${FULL}-haproxy" -o jsonpath='{.spec.replicas}')" ]; }
wait_for 120 "broken HAProxy pod gone" gone
after=$(restarts)
# HAProxy pods were replaced by the repair rollout (new UIDs); only compare Redis pods + restart counts.
diff <(grep -- '-server-' <<<"$before_restarts") <(grep -- '-server-' <<<"$after") >/dev/null && ok "Redis pods: same UIDs, no restarts" || bad "Redis pods restarted: $(diff <(grep -- '-server-' <<<"$before_restarts") <(grep -- '-server-' <<<"$after") | tr '\n' ' ')"
# Restarts that happened DURING this test only: pods that existed before keep their
# counts; pods created by the test (repair rollout) must have none.
hap_bad=""
while IFS= read -r line; do
  uid=${line#*=}; uid=${uid%%:*}
  prev=$(grep -F "=$uid:" <<<"$before_restarts" || true)
  if [ -n "$prev" ]; then [ "$prev" = "$line" ] || hap_bad="$hap_bad $line"
  else grep -qE ':(0,)+$' <<<"$line" || hap_bad="$hap_bad $line"; fi
done < <(grep -- '-haproxy-' <<<"$after")
[ -z "$hap_bad" ] && ok "HAProxy: no container restarts during the test" || bad "HAProxy restarted during the test:$hap_bad"
summary
