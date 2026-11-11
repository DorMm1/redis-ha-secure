#!/usr/bin/env bash
# 1. helm lint + helm template for both phases, plus negative tests proving the guard
#    rails (wildcard namespaces, subPath, rename-command, memory requests != limits,
#    opaque ports, ...). Needs no cluster.
source "$(dirname "$0")/lib.sh"
OUT=$(mktmpd)
trap 'rm -rf "$OUT"' EXIT
CAT="$ROOT/scripts/ci/catalog-example.yaml"
PY=""
for c in python3 python; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import yaml' >/dev/null 2>&1; then PY=$c; break; fi
done
[ -n "$PY" ] || info "python+PyYAML not found: skipping the resources.limits check"

info "helm dependency build"
helm dependency build "$CHART" >/dev/null && ok "dependency redis-ha pinned ($(grep -A4 'name: redis-ha$' "$CHART/Chart.yaml" | grep -m1 'version:' | awk '{print $2}'))"

for ph in 1 2; do
  info "phase $ph"
  args=(-f "$CHART/values.yaml" -f "$CHART/values-phase$ph.yaml" -f "$CAT")
  check "helm lint --strict (phase $ph)" helm lint --strict "$CHART" "${args[@]}"
  if helm template "$RELEASE" "$CHART" -n "$NS" "${args[@]}" >"$OUT/p$ph.yaml" 2>"$OUT/err"; then
    ok "helm template (phase $ph)"
  else
    bad "helm template (phase $ph): $(cat "$OUT/err")"; continue
  fi
  y="$OUT/p$ph.yaml"
  check "redis.conf: aclfile set" grep -q 'aclfile /etc/redis-secure/acl/users.acl' "$y"
  check "redis.conf: maxmemory 2800mb for a 4Gi limit (70%)" grep -q 'maxmemory 2800mb' "$y"
  check "redis.conf: maxmemory-policy noeviction + samples 10" bash -c "grep -q 'maxmemory-policy noeviction' '$y' && grep -q 'maxmemory-samples 10' '$y'"
  check "redis.conf: AOF + RDB configured" bash -c "grep -q 'appendonly yes' '$y' && grep -q 'save 3600 1 300 100 60 10000' '$y'"
  check "redis.conf: no rename-command" bash -c "! grep -q 'rename-command' '$y'"
  check "redis.conf: no requirepass (aclfile owns users)" bash -c "! grep -qE '^\s+requirepass' <(sed -n '/redis.conf: |/,/sentinel.conf: |/p' '$y')"
  check "sentinel.conf: aclfile + include" bash -c "grep -q 'aclfile /etc/redis-secure/sentinel-acl/sentinel-users.acl' '$y' && grep -q 'include /etc/redis-secure/sentinel-acl/sentinel-infra.conf' '$y'"
  check "ACL Secret mounted without subPath" bash -c "! grep -q 'subPath' '$y'"
  check "linkerd opaque-ports lists 6379 and 26379" grep -q 'config.linkerd.io/opaque-ports: 6379,26379' "$y"
  check "no LoadBalancer/NodePort/Ingress" bash -c "! grep -qE 'type: (LoadBalancer|NodePort)|kind: Ingress' '$y'"
  check "StatefulSet: hard anti-affinity on hostname" grep -q 'requiredDuringSchedulingIgnoredDuringExecution' "$y"
  check "PDB maxUnavailable 1" grep -q 'maxUnavailable: 1' "$y"
  check "redis image is patched 8.8.4" grep -q 'redis:8.8.4-alpine' "$y"
  check "pod SA token not automounted" grep -q 'automountServiceAccountToken: false' "$y"
  check "readOnlyRootFilesystem everywhere" bash -c "[ \$(grep -c 'readOnlyRootFilesystem: true' '$y') -ge 6 ]"
  if [ -n "$PY" ]; then
    check "every container (incl. init/Jobs/exporter/sidecars) has resources.limits" "$PY" "$ROOT/scripts/ci/check-limits.py" "$y"
  fi
  if [ "$ph" = 2 ]; then
    check "phase 2 catalog: default demoted to probe-only" grep -qP 'infra\tredis\tdefault\tdefault-password\tresetkeys resetchannels -@all \+ping \+role \+info \+shutdown' "$y"
    check "phase 2 catalog: replica-user / sentinel-user / sentinel-peer" bash -c "grep -qP 'infra\tredis\treplica-user' '$y' && grep -qP 'infra\tredis\tsentinel-user' '$y' && grep -qP 'infra\tsentinel\tsentinel-peer' '$y'"
    check "phase 2 catalog: sentinel default demoted" grep -qP 'infra\tsentinel\tdefault\tsentinel-default-password\tresetkeys resetchannels -@all \+ping \+sentinel\|get-master-addr-by-name' "$y"
  else
    check "phase 1 catalog: default keeps +@all but only the hello channel" grep -qP 'infra\tredis\tdefault\tdefault-password\t~\* resetchannels &__sentinel__:hello \+@all' "$y"
    check "phase 1 catalog: no phase-2 users" bash -c "! grep -qP 'infra\tredis\treplica-user' '$y'"
  fi
  check "catalog: app user rule rendering (orders-api)" grep -qP 'app\tsystem\.serviceaccount\.orders\.orders-api\torders\tredis-acl-orders-api\t-\tpassword\tresetkeys ~orders:\* resetchannels &orders\.events\.\* -@all \+@connection \+@read \+@write \+publish \+subscribe \+psubscribe \+unsubscribe \+punsubscribe -@dangerous -@admin -flushall -flushdb -swapdb -keys -@scripting\t' "$y"
  check "catalog: read-only/write-only prefixes (%R~ / %W~), scripting granted without script/function management" grep -qP 'resetkeys %R~orders:\* %W~reports:\* resetchannels &orders\.events\.\* -@all \+@connection \+@read \+@write \+subscribe \+psubscribe \+unsubscribe \+punsubscribe \+@scripting -script\|flush -function\|load -function\|delete -function\|flush -function\|restore -@dangerous -@admin -flushall -flushdb -swapdb -keys\t' "$y"
  check "Linkerd clients derived from aclUsers" bash -c "grep -A20 'kind: MeshTLSAuthentication' '$y' | grep -q 'namespace: reporting'"
  check "NetworkPolicy allows the catalog namespaces" bash -c "grep -q 'kubernetes.io/metadata.name: orders' '$y' && grep -q 'kubernetes.io/metadata.name: reporting' '$y'"
  check "no secret material rendered (no plaintext password keys)" bash -c "! grep -qiE '^\s+(password|default-password|masterauth)\s*:\s*\S' '$y'"
done

info "negative tests (rendering must FAIL)"
neg() { # <description> <helm --set args...>
  local d=$1; shift
  if helm template "$RELEASE" "$CHART" -n "$NS" -f "$CHART/values.yaml" -f "$CAT" "$@" >/dev/null 2>"$OUT/neg"; then
    bad "$d (rendered but should fail)"
  elif grep -q 'execution error' "$OUT/neg"; then
    ok "$d -> $(grep -o 'execution error.*' "$OUT/neg" | sed 's/^[^)]*): //' | cut -c1-90)"
  else
    bad "$d (failed for an unexpected reason: $(head -c 200 "$OUT/neg"))"
  fi
}
neg "wildcard namespace rejected" --set 'aclUsers[0].namespace=project-*'
neg "subPath mount of the ACL Secret rejected" --set 'redis-ha.redis.extraVolumeMounts[0].name=redis-acl' --set 'redis-ha.redis.extraVolumeMounts[0].mountPath=/x' --set 'redis-ha.redis.extraVolumeMounts[0].subPath=users.acl'
neg "rename-command of CONFIG rejected" --set 'redis-ha.redis.disableCommands[0]=CONFIG'
neg "memory requests != limits rejected" --set 'redis-ha.redis.resources.requests.memory=1Gi'
neg "opaque-ports without 26379 rejected" --set 'redis-ha.redis.podAnnotations.config\.linkerd\.io/opaque-ports=6379'
neg "channel pattern that could match __sentinel__:hello rejected" --set 'aclUsers[0].redis[1].channel=*'
neg "invalid access verb rejected" --set 'aclUsers[0].redis[0].access[0]=admin'
neg "HAProxy with built-in (default user) config rejected" --set 'redis-ha.haproxy.enabled=true' --set 'redis-ha.haproxy.customConfig='
neg "chart auth not wired to the infra Secret rejected" --set 'redis-ha.existingSecret=other'
neg "quorum below majority rejected" --set 'redis-ha.sentinel.quorum=1'
HAPF=(-f "$CHART/values-haproxy.yaml")
neg "HAProxy checkFall 1 rejected (shutdown-sessions would drop clients on one slow check)" "${HAPF[@]}" --set redis-ha.haproxy.checkFall=1
neg "HAProxy maxconn beyond Redis maxclients rejected" "${HAPF[@]}" --set global.redisSecure.haproxy.maxconn=5000
neg "HAProxy exposed as LoadBalancer rejected" "${HAPF[@]}" --set redis-ha.haproxy.service.type=LoadBalancer
neg "HAProxy TLS termination rejected (Linkerd provides mTLS)" "${HAPF[@]}" --set redis-ha.haproxy.tls.enabled=true
neg "HAProxy opaque-ports without 6379 rejected" "${HAPF[@]}" --set 'redis-ha.haproxy.podAnnotations.config\.linkerd\.io/opaque-ports=6380'
neg "migration without HAProxy rejected" --set migration.enabled=true --set migration.source.address=x:6379 --set migration.source.passwordSecret.name=s
neg "migration without source password Secret rejected" "${HAPF[@]}" --set migration.enabled=true --set migration.source.address=x:6379

info "maxmemory computation"
mm() { helm template "$RELEASE" "$CHART" -n "$NS" -f "$CHART/values.yaml" -f "$CAT" --set "redis-ha.redis.resources.requests.memory=$1" --set "redis-ha.redis.resources.limits.memory=$1" --show-only charts/redis-ha/templates/redis-ha-configmap.yaml | grep -o 'maxmemory [0-9]*mb'; }
for pair in "4Gi:2800mb" "8Gi:5700mb" "1Gi:716mb" "512Mi:358mb" "6G:4000mb"; do
  q=${pair%%:*} want=${pair##*:}
  got=$(mm "$q" | awk '{print $2}')
  [ "$got" = "$want" ] && ok "limit $q -> maxmemory $got" || bad "limit $q -> maxmemory $got (want $want)"
done

info "HAProxy mode (values-haproxy.yaml), both phases"
for ph in 1 2; do
  if ! helm template "$RELEASE" "$CHART" -n "$NS" -f "$CHART/values.yaml" -f "$CHART/values-haproxy.yaml" -f "$CHART/values-phase$ph.yaml" -f "$CAT" \
    --set redis-ha.haproxy.readOnly.enabled=true >"$OUT/hap$ph.yaml" 2>"$OUT/err"; then
    bad "helm template HAProxy mode phase $ph: $(cat "$OUT/err")"; continue
  fi
  ok "helm template HAProxy mode (phase $ph)"
  check "helm lint --strict HAProxy mode (phase $ph)" helm lint --strict "$CHART" -f "$CHART/values.yaml" -f "$CHART/values-haproxy.yaml" -f "$CHART/values-phase$ph.yaml" -f "$CAT"
  y="$OUT/hap$ph.yaml"
  check "[p$ph] haproxy.cfg: health checks AUTH as haproxy-user" grep -q 'tcp-check send "AUTH haproxy-user ${AUTH}"' "$y"
  check "[p$ph] haproxy.cfg: never authenticates as default" bash -c "! grep -qE 'AUTH (default )?\\$\\{(AUTH|SENTINELAUTH)\\}\"' '$y'"
  check "[p$ph] haproxy.cfg: init-state down + shutdown-sessions on master servers" bash -c "[ \$(grep -c 'init-state down on-marked-down shutdown-sessions' '$y') -ge 3 ]"
  check "[p$ph] haproxy.cfg: quorum routing (reject unless 2 Sentinels agree)" grep -q 'tcp-request content reject unless { srv_is_up(bk_redis_master/R0) } { nbsrv(check_if_redis_is_master_0) ge 2 } ||' "$y"
  check "[p$ph] haproxy.cfg: readiness gated on the routing condition (master + Sentinel quorum)" grep -q 'http-request set-var(proc.master_seen) bool(true) if { srv_is_up(bk_redis_master/R0) } { nbsrv(check_if_redis_is_master_0) ge 2 }' "$y"
  check "[p$ph] haproxy.cfg: Sentinel checks never send QUIT (Sentinel: unknown command)" bash -c "[ \$(awk '/backend check_if_redis_is_master_/{f=1} /frontend ft_redis_master/{f=0} f' '$y' | grep -c 'tcp-check send QUIT') -eq 0 ] && grep -q 'backend check_if_redis_is_master_0' '$y'"
  check "[p$ph] haproxy.cfg: TCP keepalive + 12h tunnel + maxconn" bash -c "grep -q 'option clitcpka' '$y' && grep -q 'timeout tunnel 12h' '$y' && grep -q 'maxconn 3000' '$y'"
  check "[p$ph] HAProxy Deployment: preStop drain + maxUnavailable 1" bash -c "grep -q 'sleep 10' '$y' && grep -A3 'rollingUpdate:' '$y' | grep -q 'maxUnavailable: 1'"
  check "[p$ph] catalog: haproxy-user on Redis and Sentinel" bash -c "grep -qP 'infra\tredis\thaproxy-user' '$y' && grep -qP 'infra\tsentinel\thaproxy-user' '$y'"
  check "[p$ph] catalog: app users get NO Sentinel account in HAProxy mode" bash -c "grep -P '^\s+app\t' '$y' | awk -F'\t' '\$NF != \"-\"' | grep -q . && exit 1 || exit 0"
  check "[p$ph] Linkerd: Server for HAProxy 6379 + 6380 authorized for catalog SAs" bash -c "grep -q 'name: redis-redis-ha-haproxy-clients' '$y' && grep -q 'name: redis-redis-ha-haproxy-ro-clients' '$y'"
  check "[p$ph] Linkerd: Redis/Sentinel Servers have NO client authorization (HAProxy only)" bash -c "! grep -qE 'name: redis-redis-ha-(redis|sentinel)-clients' '$y'"
  check "[p$ph] NetworkPolicy: clients only to HAProxy; HAProxy egress to Redis" bash -c "grep -q 'name: redis-redis-ha-haproxy\$' '$y' && grep -A3 '# health checks + client traffic' '$y' | grep -q podSelector"
  check "[p$ph] HAProxy metrics enabled" grep -q 'prometheus-exporter' "$y"
  if [ -n "$PY" ] && command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    "$PY" "$ROOT/scripts/ci/extract-haproxy-cfg.py" "$y" "$OUT/haproxy$ph.cfg"
    hosts=(); for i in 0 1 2; do hosts+=("--add-host=redis-redis-ha-announce-$i:10.0.0.$((i + 1))"); done
    HAP_IMAGE=$(grep -A3 'name: haproxy$' "$y" | grep -m1 'image:' | awk '{print $2}')
    if out=$(MSYS_NO_PATHCONV=1 docker run --rm "${hosts[@]}" -e AUTH=x -v "$OUT:/cfg:ro" "$HAP_IMAGE" haproxy -c -f "/cfg/haproxy$ph.cfg" 2>&1); then
      grep -qiE 'WARNING|ALERT' <<<"$out" && bad "[p$ph] haproxy -c ($HAP_IMAGE) warnings: $out" || ok "[p$ph] haproxy -c with the real binary ($HAP_IMAGE): valid, no warnings"
    else
      bad "[p$ph] haproxy -c: $out"
    fi
  else
    info "docker not available: skipping 'haproxy -c'"
  fi
  if [ -n "$PY" ]; then
    check "[p$ph] HAProxy mode: every container has limits + hardened securityContext" "$PY" "$ROOT/scripts/ci/check-limits.py" "$y"
  fi
done
info "migration renders without secrets in the ConfigMap"
if helm template "$RELEASE" "$CHART" -n "$NS" -f "$CHART/values.yaml" "${HAPF[@]}" -f "$CAT" --set migration.enabled=true \
  --set migration.source.address=legacy-redis-ha-haproxy.legacy.svc:6379 --set migration.source.passwordSecret.name=src >"$OUT/mig.yaml" 2>"$OUT/err"; then
  ok "helm template with migration.enabled"
  check "shake.toml uses \${SHAKE_*_PASSWORD} env placeholders" bash -c "grep -q 'password = \"\${SHAKE_SRC_PASSWORD}\"' '$OUT/mig.yaml' && grep -q 'password = \"\${SHAKE_DST_PASSWORD}\"' '$OUT/mig.yaml'"
  check "migration-user in the catalog, PUBLISH never replayed" bash -c "grep -qP 'infra\tredis\tmigration-user' '$OUT/mig.yaml' && grep -q 'block_command = \[\"PUBLISH\", \"SPUBLISH\"\]' '$OUT/mig.yaml'"
  check "migration SA authorized on HAProxy (Linkerd)" bash -c "grep -A20 'name: redis-redis-ha-release-clients' '$OUT/mig.yaml' | grep -q 'redis-redis-ha-migration'"
  [ -n "$PY" ] && check "migration pod hardened + limits" "$PY" "$ROOT/scripts/ci/check-limits.py" "$OUT/mig.yaml"
else
  bad "helm template with migration: $(cat "$OUT/err")"
fi

info "disaster recovery (backup CronJob + bootstrap restore overlay)"
DRF=(--set dr.storage.remote=s3:bucket/redis/prod)
neg "dr.backup without dr.storage.remote rejected" --set dr.backup.enabled=true
neg "dr.backup.source other than replica/any rejected" "${DRF[@]}" --set dr.backup.enabled=true --set dr.backup.source=master
neg "dr restore without explicit backupId rejected" "${DRF[@]}" -f "$CHART/values-dr-restore.yaml"
neg "dr restore with backupId=latest rejected" "${DRF[@]}" -f "$CHART/values-dr-restore.yaml" --set dr.restore.backupId=latest
neg "dr restore without the init containers rejected" "${DRF[@]}" --set dr.restore.enabled=true --set dr.restore.backupId=20261111T101500Z
neg "dr-restore init containers left behind with restore disabled rejected" "${DRF[@]}" -f "$CHART/values-dr-restore.yaml" --set dr.restore.enabled=false
neg "dr-restore-install image != redis-ha.image rejected" "${DRF[@]}" -f "$CHART/values-dr-restore.yaml" --set dr.restore.backupId=20261111T101500Z --set redis-ha.image.tag=8.8.3-alpine
neg "dr-restore ConfigMap name mismatch rejected" "${DRF[@]}" -f "$CHART/values-dr-restore.yaml" --set dr.restore.backupId=20261111T101500Z --set dr.restore.configMapName=other
for ph in 1 2; do
  if helm template "$RELEASE" "$CHART" -n "$NS" -f "$CHART/values.yaml" -f "$CHART/values-phase$ph.yaml" "${HAPF[@]}" -f "$CAT" "${DRF[@]}" \
    --set dr.backup.enabled=true >"$OUT/dr$ph.yaml" 2>"$OUT/err"; then
    ok "[p$ph] helm template with dr.backup.enabled"
    check "[p$ph] backup-user in the catalog with SYNC-only rules" bash -c "grep -P 'infra\tredis\tbackup-user\tbackup-password\t' '$OUT/dr$ph.yaml' | grep -q -- '-@all +ping +role +info +sync +replconf\$'"
    check "[p$ph] backup-password is a required infra key" bash -c "grep -A12 'infra-keys.txt' '$OUT/dr$ph.yaml' | grep -q backup-password"
    check "[p$ph] backup CronJob: Forbid concurrency, storage creds only via envFrom Secret" bash -c "grep -q 'name: redis-redis-ha-dr-backup\$' '$OUT/dr$ph.yaml' && grep -q 'concurrencyPolicy: Forbid' '$OUT/dr$ph.yaml' && grep -B2 -A2 'secretRef:' '$OUT/dr$ph.yaml' | grep -q 'redis-ha-dr-storage'"
    check "[p$ph] backup SA authorized on the Redis port only (Linkerd)" bash -c "grep -A12 'name: redis-redis-ha-redis-dr-backup' '$OUT/dr$ph.yaml' | grep -q 'name: redis-redis-ha-redis\$' && ! grep -A12 'name: redis-redis-ha-sentinel-dr-backup' '$OUT/dr$ph.yaml' | grep -q ."
    check "[p$ph] RedisBackupMissing + persistence alerts rendered" bash -c "grep -q 'alert: RedisBackupMissing' '$OUT/dr$ph.yaml' && grep -q 'alert: RedisRdbSaveFailed' '$OUT/dr$ph.yaml' && grep -q 'alert: RedisAofWriteFailed' '$OUT/dr$ph.yaml'"
    [ -n "$PY" ] && check "[p$ph] backup Job hardened + limits" "$PY" "$ROOT/scripts/ci/check-limits.py" "$OUT/dr$ph.yaml"
  else
    bad "[p$ph] helm template with dr.backup: $(cat "$OUT/err")"
  fi
done
if helm template "$RELEASE" "$CHART" -n "$NS" -f "$CHART/values.yaml" -f "$CHART/values-phase2.yaml" -f "$CAT" "${DRF[@]}" \
  -f "$CHART/values-dr-restore.yaml" --set dr.restore.backupId=20261111T101500Z >"$OUT/drr.yaml" 2>"$OUT/err"; then
  ok "helm template with values-dr-restore.yaml"
  check "restore ConfigMap pins the backup id, holds no secret" bash -c "grep -q 'DR_BACKUP_ID: \"20261111T101500Z\"' '$OUT/drr.yaml' && ! grep -A40 'name: redis-ha-dr-restore\$' '$OUT/drr.yaml' | grep -qiE 'SECRET_ACCESS_KEY|PASSWORD:'"
  check "restore init containers run after config-init in the Redis StatefulSet" bash -c "awk '/kind: StatefulSet/,0' '$OUT/drr.yaml' | grep -oE 'name: (config-init|dr-restore-fetch|dr-restore-install)\$' | tr '\n' ' ' | grep -q 'config-init name: dr-restore-fetch name: dr-restore-install'"
  check "Redis pods may egress to the object store only while restoring" bash -c "grep -q 'DR bootstrap restore' '$OUT/drr.yaml' && ! grep -q 'DR bootstrap restore' '$OUT/dr2.yaml'"
  [ -n "$PY" ] && check "restore init containers hardened + limits" "$PY" "$ROOT/scripts/ci/check-limits.py" "$OUT/drr.yaml"
else
  bad "helm template with values-dr-restore.yaml: $(cat "$OUT/err")"
fi
summary
