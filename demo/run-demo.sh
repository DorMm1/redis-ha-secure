#!/usr/bin/env bash
# =============================================================================
# redis-ha-secure interactive demo.
#   demo/run-demo.sh up                 install/upgrade the demo chart, open the dashboard port-forward
#   demo/run-demo.sh tour               guided walkthrough (pauses between scenes; AUTO=1 = no pauses,
#                                       exits non-zero if any check fails, usable as an e2e test)
#   demo/run-demo.sh dashboard          only the port-forward (http://localhost:$DEMO_PORT)
#   demo/run-demo.sh restore [id]       rebuild Redis from a backup (default: LATEST), in place
#   demo/run-demo.sh down               uninstall the demo and delete its namespace
# Env: KUBE_CONTEXT, NS (redis-demo), RELEASE (demo), DEMO_PORT (8088), DEMO_VALUES (extra values file)
# Needs: kubectl, helm, curl, python (or python3). On Windows run it from Git Bash.
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)
command -v cygpath >/dev/null 2>&1 && ROOT=$(cygpath -m "$ROOT")
CHART=$ROOT/charts/redis-ha-demo
NS=${NS:-redis-demo}
RELEASE=${RELEASE:-demo}
FULL=$RELEASE-redis-ha
PORT=${DEMO_PORT:-8088}
AUTO=${AUTO:-0}
VALUES=()
[ -n "${DEMO_VALUES:-}" ] && VALUES=(-f "$DEMO_VALUES")
PY=$(command -v python3 || command -v python)
if [ -n "${KUBE_CONTEXT:-}" ]; then
  kubectl() { command kubectl --context "$KUBE_CONTEXT" "$@"; }
  helm() { command helm --kube-context "$KUBE_CONTEXT" "$@"; }
fi

PASS=0 FAIL=0 PF=""
say() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
note() { printf '   %s\n' "$*"; }
ok() { PASS=$((PASS + 1)); printf '   \033[32mPASS\033[0m %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '   \033[31mFAIL\033[0m %s\n' "$*"; }
pause() { if [ "$AUTO" = 1 ]; then sleep "${1:-2}"; else read -rp $'\n   \033[2m[Enter] next scene\033[0m ' _ </dev/tty; fi; }
cleanup() {
  [ -n "$PF" ] || return 0
  # Git Bash: `kill` does not reach the native kubectl.exe behind the MSYS pid; stop it by its Windows pid
  local w
  w=$(ps -p "$PF" 2>/dev/null | awk 'NR==2 {print $4}')
  kill "$PF" 2>/dev/null
  if [ -n "$w" ] && command -v taskkill >/dev/null 2>&1; then taskkill //F //PID "$w" >/dev/null 2>&1; fi
  return 0
}
trap cleanup EXIT

api() { curl -s -m 60 -X "${2:-GET}" -H 'Content-Type: application/json' ${3:+-d "$3"} "http://localhost:$PORT$1"; }
# jq-free JSON access: j '<python expression on d>' <<<"$json"
j() { "$PY" -c "import json,sys; d=json.load(sys.stdin); print($1)"; }
st() { api /api/state; }

port_forward() {
  if curl -s -m 2 "http://localhost:$PORT/healthz" >/dev/null 2>&1; then return 0; fi
  # the binary itself (not the kubectl() wrapper), so $! is the port-forward process
  command kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} -n "$NS" port-forward svc/redis-demo-dashboard "$PORT:8080" >/dev/null 2>&1 &
  PF=$!
  for _ in $(seq 1 30); do
    curl -s -m 2 "http://localhost:$PORT/healthz" >/dev/null 2>&1 && return 0
    sleep 1
  done
  echo "dashboard port-forward failed"; return 1
}

wait_until() { # <timeout> <description> <cmd...>
  local t=$1 d=$2; shift 2
  local end=$(($(date +%s) + t))
  until "$@" >/dev/null 2>&1; do
    [ "$(date +%s)" -ge "$end" ] && { bad "timeout: $d"; return 1; }
    sleep 2
  done
  ok "$d"
}

master_now() { st | j 'd["masters"][0] if len(d["masters"])==1 else ""'; }
master_moved() { local m; m=$(master_now); [ -n "$m" ] && [ "$m" != "$1" ]; }
writer_live() { [ "$(st | j 'int(__import__("time").time()-(d["apps"]["orders-api"]["last_ok"] or 0))')" -lt 5 ]; }
backup_done() { [ "$(st | j 'd["jobs"][0].get("state") if d["jobs"] else ""')" = succeeded ]; }
healthy() { [ "$(st | j 'len(d["masters"])==1 and d["sentinel_agree"] and d["acl_identical"] and all(n["up"] for n in d["nodes"])')" = True ]; }

topology() {
  st | j '"\n".join(["   %-22s %-8s keys=%-6s offset=%-9s acl=%s" % (n["name"], n.get("role","DOWN"), n.get("keys","-"), n.get("offset","-"), n.get("acl_digest","-")) for n in d["nodes"]] + ["   sentinels agree: %s (%s)   ACLs identical: %s" % (d["sentinel_agree"], d["sentinel_master"], d["acl_identical"])])'
}

acl() { # <identity> <expect-regex> <command...>
  local who=$1 want=$2; shift 2
  local body reply
  body=$("$PY" -c 'import json,sys; print(json.dumps({"identity": sys.argv[1], "command": " ".join(sys.argv[2:])}))' "$who" "$@")
  reply=$(api /api/acl POST "$body" | j 'str(d["reply"])[:70]')
  if printf '%s' "$reply" | grep -qE "$want"; then ok "$(printf '%-15s %-34s -> %s' "$who" "$*" "$reply")"; else bad "$(printf '%-15s %-34s -> %s (expected /%s/)' "$who" "$*" "$reply" "$want")"; fi
}

cmd_up() {
  say "Installing redis-ha-demo (release $RELEASE, namespace $NS). First install takes a few minutes."
  helm dependency build "$CHART" >/dev/null || exit 1
  helm upgrade --install "$RELEASE" "$CHART" -n "$NS" --create-namespace "${VALUES[@]}" --wait --timeout 20m || exit 1
  kubectl -n "$NS" rollout status deploy/redis-demo-dashboard --timeout=180s >/dev/null
  port_forward || exit 1
  say "Dashboard: http://localhost:$PORT"
  if [ "$AUTO" != 1 ]; then note "Port-forward running. Ctrl+C to stop (the demo keeps running)."; wait "$PF"; fi
}

cmd_restore() {
  port_forward || exit 1
  local id=${1:-}
  [ -n "$id" ] || id=$(st | j 'd["backups"]["latest"] or ""')
  [ -n "$id" ] && [ "$id" != None ] || { echo "no backup found: press 'Backup now' first"; return 1; }
  [[ "$id" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || { echo "invalid backup id '$id'"; return 1; }
  # verify the backup exists BEFORE destroying anything
  MSYS_NO_PATHCONV=1 kubectl -n "$NS" exec deploy/redis-demo-store -c s3 -- test -s "/store/${DR_PATH:-redis-dr/demo}/$id/dump.rdb" \
    || { echo "backup $id not found in the store"; return 1; }
  say "Restore from backup $id (runbook R2: in-place bootstrap restore)"
  note "1. stop Redis (StatefulSet -> 0) and delete every PVC: this is what 'all data lost' looks like"
  kubectl -n "$NS" scale sts "$FULL-server" --replicas=0 >/dev/null
  kubectl -n "$NS" wait --for=delete pod -l "app=redis-ha,release=$RELEASE" --timeout=300s >/dev/null 2>&1
  kubectl -n "$NS" delete pvc -l "app=redis-ha,release=$RELEASE" --wait=true >/dev/null
  note "2. helm upgrade with values-restore.yaml: every Redis pod gets dr-restore init containers that"
  note "   download $id, verify SHA256SUMS + redis-check-rdb, and install it as the AOF base"
  helm upgrade "$RELEASE" "$CHART" -n "$NS" "${VALUES[@]}" -f "$CHART/values-restore.yaml" \
    --set "redis-ha-secure.dr.restore.backupId=$id" --wait --timeout 20m >/dev/null || { bad "helm upgrade with restore"; return 1; }
  kubectl -n "$NS" rollout status sts "$FULL-server" --timeout=600s >/dev/null
  for i in 0 1 2; do
    kubectl -n "$NS" logs "$FULL-server-$i" -c dr-restore-install 2>/dev/null | tail -n1 | sed 's/^/   /'
  done
  wait_until 240 "cluster healthy again (1 master, Sentinels agree, ACLs identical)" healthy
  topology
  note "3. remove the restore overlay (one rolling restart, Sentinel fails over around it)"
  helm upgrade "$RELEASE" "$CHART" -n "$NS" "${VALUES[@]}" --wait --timeout 20m >/dev/null || bad "helm upgrade without overlay"
  kubectl -n "$NS" rollout status sts "$FULL-server" --timeout=600s >/dev/null
  wait_until 240 "healthy after removing the overlay" healthy
}

cmd_tour() {
  port_forward || exit 1
  say "redis-ha-secure live demo. Open http://localhost:$PORT next to this terminal."
  note "orders-api writes ~5 orders/s through HAProxy, report-reader reads them, an intruder knocks on the door."

  say "Scene 1: topology"
  wait_until 300 "cluster healthy" healthy
  topology
  note "Every node is read directly as acl-admin. The ACL digest is identical on all nodes: one users.acl Secret, ACL LOAD everywhere."
  pause

  say "Scene 2: identity = ServiceAccount = ACL user (least privilege)"
  acl orders-api '^[0-9]+$' GET orders:seq
  acl orders-api 'NOPERM' FLUSHALL
  acl orders-api 'NOPERM' CONFIG GET maxmemory
  acl orders-api 'NOPERM' KEYS '*'
  acl report-reader '^[0-9]+$' GET orders:seq
  acl report-reader 'NOPERM' SET orders:x 1
  acl report-reader '^OK$' SET reports:x 1
  acl report-reader 'NOPERM' EVAL 'return 1' 0
  acl default 'NOPERM' GET orders:seq
  acl wrong-password 'WRONGPASS' PING
  acl anonymous 'NOAUTH' PING
  local v
  v=$(st | j 'd["apps"]["intruder"].get("extra",{}).get("last_attempt",{}).get("verdict","-")')
  if printf '%s' "$v" | grep -q blocked; then ok "intruder (no catalog entry): $v"; else bad "intruder: $v"; fi
  v=$(st | j 'd["apps"]["report-reader"].get("extra",{}).get("tamper","-")')
  note "report-reader keeps trying to write orders:* -> $v"
  pause

  say "Scene 3: failover under load"
  local m0 e0 m1
  m0=$(st | j 'd["masters"][0]')
  e0=$(st | j 'd["apps"]["orders-api"]["errors"]')
  note "master: $m0. Asking Sentinel for a failover..."
  api /api/failover POST | j 'd["reply"]' | sed 's/^/   /'
  wait_until 90 "new master elected" master_moved "$m0"
  wait_until 120 "healthy: Sentinels agree, ACLs identical on the new master" healthy
  m1=$(st | j 'd["masters"][0]')
  note "new master: $m1"
  sleep 3
  st | j '"   writer: %d orders written, %d errors during the switch, last outage: %s" % (d["apps"]["orders-api"]["ok"], d["apps"]["orders-api"]["errors"]-'"$e0"', (d["apps"]["orders-api"]["outages"] or [{"seconds":0}])[-1]["seconds"])'
  wait_until 30 "writer is writing again" writer_live
  pause

  say "Scene 4: off-cluster backup"
  api /api/backup POST | j 'd["reply"]' | sed 's/^/   /'
  wait_until 300 "backup Job succeeded" backup_done
  local bid seq_at_backup
  bid=$(st | j 'd["backups"]["latest"] or ""')
  if [[ "$bid" =~ ^[0-9]{8}T[0-9]{6}Z$ ]]; then ok "backup $bid listed by the store"; else bad "backup not listed (got '$bid')"; fi
  seq_at_backup=$(api /api/acl POST '{"identity":"report-reader","command":"GET orders:seq"}' | j 'd["reply"]')
  st | j '"\n".join("   %s  %s  from %s (%s)" % (b["id"], b.get("keys",""), b.get("source",""), b.get("role","")) for b in d["backups"]["items"][:3])'
  note "backup $bid: taken from a replica, verified (redis-check-rdb + SHA256SUMS), uploaded. orders:seq ~ $seq_at_backup"
  pause

  say "Scene 5: disaster - a rogue deploy deletes every order"
  api /api/rogue-delete POST | j 'd["reply"]' | sed 's/^/   /'
  sleep 3
  topology
  local seq_after
  seq_after=$(api /api/acl POST '{"identity":"report-reader","command":"GET orders:seq"}' | j 'd["reply"]')
  if [ "${seq_after:-0}" -lt "$seq_at_backup" ] 2>/dev/null; then ok "the damage replicated to EVERY node (orders:seq restarted at $seq_after). HA cannot undo mistakes"; else bad "disaster not visible (seq $seq_after)"; fi
  pause

  say "Scene 6: restore from backup $bid"
  cmd_restore "$bid"
  local seq_restored
  seq_restored=$(api /api/acl POST '{"identity":"report-reader","command":"GET orders:seq"}' | j 'd["reply"]')
  if [ "${seq_restored:-0}" -ge "$seq_at_backup" ] 2>/dev/null; then ok "orders are back: orders:seq $seq_restored >= $seq_at_backup at backup time (writes after the backup are the RPO)"; else bad "restore: orders:seq $seq_restored < $seq_at_backup"; fi
  acl report-reader 'NOPERM' SET orders:x 1
  acl orders-api '^[0-9]+$' XLEN orders:stream
  wait_until 60 "writer is writing again" writer_live

  say "Done: $PASS checks passed, $FAIL failed"
  note "Keep exploring on the dashboard. 'demo/run-demo.sh down' removes everything."
  [ "$FAIL" -eq 0 ]
}

cmd_down() {
  helm uninstall "$RELEASE" -n "$NS" --wait >/dev/null 2>&1
  kubectl delete namespace "$NS" --wait=true --timeout=300s
}

case "${1:-}" in
  up) cmd_up ;;
  tour) cmd_tour ;;
  dashboard) port_forward && { say "Dashboard: http://localhost:$PORT (Ctrl+C to stop)"; wait "$PF"; } ;;
  restore) shift; cmd_restore "${1:-}" ;;
  down) cmd_down ;;
  *) sed -n '2,12p' "$0"; exit 2 ;;
esac
