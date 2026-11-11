#!/bin/sh
# =============================================================================
# acl-reload.sh - post-install / post-upgrade hook (image: redis alpine)
#
# Precondition (init container wait-for-mount.sh): kubelet has already propagated the
# new ACL Secret into EVERY Redis pod, so ACL LOAD can only ever load the new file.
#
#  1. Preflight: load the new files into throw-away local redis-server / redis-sentinel
#     (syntax), ACL DRYRUN the infra identities, compute the expected ACL LIST.
#  2. Stage the identities the target phase authenticates with (ACL SETUSER), switch
#     runtime auth (CONFIG SET masteruser/masterauth, SENTINEL SET auth-user/auth-pass,
#     SENTINEL CONFIG SET sentinel-user/sentinel-pass) and prove via CLIENT LIST that
#     replication + Sentinel links use them. Nothing is demoted before that is proven.
#  3. ACL LOAD on every Redis node and Sentinel through the headless service.
#  4. Verify ACL LIST is identical on every node AND equal to the expected file.
#  5. CONFIG REWRITE (persist runtime auth), CKQUORUM, replication health.
# No pod is restarted, so no failover is caused.
# =============================================================================
set -eu
LOG_TAG=acl-reload
. /scripts/acl-lib.sh
: "${PHASE:?}" "${DEMOTE_DEFAULT:?}" "${TIMEOUT_SECONDS:=600}"
: "${KEY_DEFAULT:?}" "${KEY_REPLICA:?}" "${KEY_SENTINEL_USER:?}" "${KEY_SENTINEL_PEER:?}"
DEADLINE=$(($(date +%s) + TIMEOUT_SECONDS))

retry() { # <description> <cmd...>
  _d=$1; shift
  while :; do
    if "$@" >/dev/null 2>&1; then return 0; fi
    [ "$(date +%s)" -lt "$DEADLINE" ] || die "timeout: ${_d}"
    sleep 3
  done
}

EXP_R=$(rev_of "$ACL_DIR/users.acl")
EXP_S=$(rev_of "$ACL_DIR/sentinel-users.acl")
[ -n "$EXP_R" ] && [ -n "$EXP_S" ] || die "mounted ACL Secret has no revision marker"
log "target revision redis=$(echo "$EXP_R" | cut -c1-12) sentinel=$(echo "$EXP_S" | cut -c1-12) phase=${PHASE} demoteDefault=${DEMOTE_DEFAULT}"

# ---------------------------------------------------------------- 1. preflight
trap local_stop EXIT
local_start
preflight_dryrun
log "expected ACL LIST digest redis=$(echo "$EXPECTED_REDIS_DIGEST" | cut -c1-12) sentinel=$(echo "$EXPECTED_SENTINEL_DIGEST" | cut -c1-12)"
if [ -f /shared/no-pods ]; then
  log "done: preflight OK, no Redis pod exists (scaled to 0). Pods load this revision at start."
  exit 0
fi

# --------------------------------------------------------------- reachability
for i in $(node_ids); do
  h=$(node_host "$i")
  retry "redis ${h}:${REDIS_PORT} reachable as acl-admin" rcli "$h" "$REDIS_PORT" PING
  retry "sentinel ${h}:${SENTINEL_PORT} reachable as acl-admin" rcli "$h" "$SENTINEL_PORT" PING
done
log "all ${REPLICAS} redis nodes and sentinels reachable through the headless service"

# --------------------------------------------- 2. target runtime authentication
if [ "$PHASE" = "2" ]; then
  WANT_MU=replica-user; WANT_MA=$(cat "$INFRA_DIR/$KEY_REPLICA")
  WANT_SU=sentinel-user; WANT_SP=$(cat "$INFRA_DIR/$KEY_SENTINEL_USER")
  WANT_PU=sentinel-peer; WANT_PP=$(cat "$INFRA_DIR/$KEY_SENTINEL_PEER")
  STAGE_REDIS="replica-user sentinel-user"; STAGE_SENTINEL="sentinel-peer"
else
  WANT_MU=""; WANT_MA=$(cat "$INFRA_DIR/$KEY_DEFAULT")
  WANT_SU=""; WANT_SP=$WANT_MA
  WANT_PU=""; WANT_PP=""
  STAGE_REDIS="default"; STAGE_SENTINEL="default"
fi
EXPECT_REPL=${WANT_MU:-default}
EXPECT_SENT=${WANT_SU:-default}
EXPECT_PEER=${WANT_PU:-default}

stage() { # <aclfile> <port> <users>
  for i in $(node_ids); do
    for u in $3; do
      line=$(grep "^user $u " "$ACL_DIR/$1") || die "user $u missing from $1"
      rules=${line#"user $u "}
      set -f
      # shellcheck disable=SC2086
      rcli "$(node_host "$i")" "$2" ACL SETUSER "$u" $rules >/dev/null || { set +f; die "ACL SETUSER $u failed on node $i"; }
      set +f
    done
  done
}
stage users.acl "$REDIS_PORT" "$STAGE_REDIS"
stage sentinel-users.acl "$SENTINEL_PORT" "$STAGE_SENTINEL"
log "staged identities: redis[${STAGE_REDIS}] sentinel[${STAGE_SENTINEL}]"

link_up() { rcli "$1" "$REDIS_PORT" INFO replication | grep -q '^master_link_status:up'; }

for i in $(node_ids); do
  h=$(node_host "$i")
  cur_mu=$(rcli "$h" "$REDIS_PORT" CONFIG GET masteruser | sed -n 2p | tr -d '\r')
  cur_ma=$(rcli "$h" "$REDIS_PORT" CONFIG GET masterauth | sed -n 2p | tr -d '\r')
  rcli "$h" "$REDIS_PORT" CONFIG SET masteruser "$WANT_MU" >/dev/null || die "CONFIG SET masteruser on node $i"
  rcli "$h" "$REDIS_PORT" CONFIG SET masterauth "$WANT_MA" >/dev/null || die "CONFIG SET masterauth on node $i"
  role=$(rcli "$h" "$REDIS_PORT" ROLE | head -n1)
  if [ "$role" = "slave" ] && { [ "$cur_mu" != "$WANT_MU" ] || [ "$cur_ma" != "$WANT_MA" ]; }; then
    # Re-authenticate the replication link now (partial resync), one replica at a time.
    rcli "$h" "$REDIS_PORT" CLIENT KILL TYPE master >/dev/null || true
    sleep 1
    retry "replica node $i re-linked as ${EXPECT_REPL}" link_up "$h"
    log "node $i: replication link re-authenticated as ${EXPECT_REPL}"
  fi
done

for i in $(node_ids); do
  h=$(node_host "$i")
  rcli "$h" "$SENTINEL_PORT" SENTINEL SET "$MASTER_GROUP" auth-user "$WANT_SU" auth-pass "$WANT_SP" >/dev/null \
    || die "SENTINEL SET auth on sentinel $i"
  rcli "$h" "$SENTINEL_PORT" SENTINEL CONFIG SET sentinel-user "$WANT_PU" sentinel-pass "$WANT_PP" >/dev/null \
    || die "SENTINEL CONFIG SET sentinel-user on sentinel $i"
done
unset WANT_MA WANT_SP WANT_PP
log "runtime auth: masteruser=${EXPECT_REPL} sentinel auth-user=${EXPECT_SENT} sentinel-user=${EXPECT_PEER}"

all_are() { # <expected> : every line on stdin equals <expected>, at least one line
  awk -v e="$1" 'BEGIN{n=0; bad=0} NF{n++; if ($0 != e) bad++} END{exit (n == 0 || bad > 0)}'
}
infra_links_ok() {
  for i in $(node_ids); do
    h=$(node_host "$i")
    client_users "$h" "$REDIS_PORT" sentinel- | all_are "$EXPECT_SENT" || return 1
    client_users "$h" "$SENTINEL_PORT" sentinel- | all_are "$EXPECT_PEER" || return 1
    if [ "$(rcli "$h" "$REDIS_PORT" ROLE | head -n1)" = "master" ]; then
      client_users "$h" "$REDIS_PORT" "" TYPE replica | all_are "$EXPECT_REPL" || return 1
      [ "$(client_users "$h" "$REDIS_PORT" "" TYPE replica | grep -c .)" -eq $((REPLICAS - 1)) ] || return 1
    fi
  done
}
retry "Sentinel/replication links authenticated as ${EXPECT_SENT}/${EXPECT_PEER}/${EXPECT_REPL}" infra_links_ok
log "verified (CLIENT LIST): sentinel->redis=${EXPECT_SENT}, sentinel->sentinel=${EXPECT_PEER}, replica->master=${EXPECT_REPL}"

# ------------------------------------------------------------------ 3. ACL LOAD
load_and_check() { # <host> <port> <rev>
  rcli "$1" "$2" ACL LOAD >/dev/null || return 1
  rcli "$1" "$2" ACL LIST | grep -q "^user acl-revision .*#$3"
}
for i in $(node_ids); do
  h=$(node_host "$i")
  retry "ACL LOAD redis node $i" load_and_check "$h" "$REDIS_PORT" "$EXP_R"
  retry "ACL LOAD sentinel $i" load_and_check "$h" "$SENTINEL_PORT" "$EXP_S"
  log "node $i: ACL LOAD ok (redis + sentinel)"
done

# ------------------------------------------------------------------ 4. verify
for i in $(node_ids); do
  h=$(node_host "$i")
  d=$(acl_digest "$h" "$REDIS_PORT") || die "ACL LIST redis node $i"
  [ "$d" = "$EXPECTED_REDIS_DIGEST" ] || die "redis node $i ACL LIST differs from the expected file"
  d=$(acl_digest "$h" "$SENTINEL_PORT") || die "ACL LIST sentinel $i"
  [ "$d" = "$EXPECTED_SENTINEL_DIGEST" ] || die "sentinel $i ACL LIST differs from the expected file"
done
log "verified: ACL LIST identical on all ${REPLICAS} redis nodes and all ${REPLICAS} sentinels (= expected file)"

# ------------------------------------------------------------- 5. persist + health
ckquorum_ok() { rcli "$1" "$SENTINEL_PORT" SENTINEL CKQUORUM "$MASTER_GROUP" | grep -q '^OK'; }
masters=0
for i in $(node_ids); do
  h=$(node_host "$i")
  rcli "$h" "$REDIS_PORT" CONFIG REWRITE >/dev/null || die "CONFIG REWRITE node $i"
  case "$(rcli "$h" "$REDIS_PORT" ROLE | head -n1)" in
  master) masters=$((masters + 1)) ;;
  slave) retry "replica node $i link up" link_up "$h" ;;
  esac
  retry "SENTINEL CKQUORUM on sentinel $i" ckquorum_ok "$h"
done
[ "$masters" -eq 1 ] || die "expected exactly one master, found ${masters}"
retry "infra links still healthy after ACL LOAD" infra_links_ok
log "done: phase ${PHASE} applied without restarts. 1 master, $((REPLICAS - 1)) replicas linked, quorum OK on all sentinels."
