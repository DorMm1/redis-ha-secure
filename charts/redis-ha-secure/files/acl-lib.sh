#!/bin/sh
# =============================================================================
# acl-lib.sh - shared helpers for acl-reload.sh / acl-drift.sh (image: redis alpine)
# Never echoes secret material: passwords are passed to redis-cli via REDISCLI_AUTH.
# =============================================================================
: "${NAMESPACE:?}" "${FULLNAME:?}" "${REPLICAS:?}" "${MASTER_GROUP:?}" "${REDIS_PORT:?}" "${SENTINEL_PORT:?}"
ACL_DIR=${ACL_DIR:-/acl}
INFRA_DIR=${INFRA_DIR:-/infra}
KEY_ACL_ADMIN=${KEY_ACL_ADMIN:-acl-admin-password}
PF=/tmp/preflight
PF_REDIS_PORT=16379
PF_SENTINEL_PORT=26390

log() { printf '%s [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${LOG_TAG:-acl}" "$*"; }
die() { log "ERROR: $*"; exit 1; }

node_host() { echo "${FULLNAME}-server-$1.${FULLNAME}.${NAMESPACE}.svc"; }
node_ids() { i=0; while [ "$i" -lt "$REPLICAS" ]; do echo "$i"; i=$((i + 1)); done; }

# rev_of <aclfile>: revision hash stored in the acl-revision marker (first line).
rev_of() { sed -n '1s/^user acl-revision .*#\([0-9a-f]\{64\}\).*$/\1/p' "$1"; }

_cli() { # <password-file> <host> <port> args...
  _pwf=$1 _h=$2 _p=$3; shift 3
  REDISCLI_AUTH="$(cat "$_pwf")" timeout 15 redis-cli --no-auth-warning --user acl-admin -h "$_h" -p "$_p" "$@" 2>&1
}

# rcli <host> <port> args... : runs as acl-admin (current password, then -previous).
# Prints the reply. Returns 1 on connection failure or error reply.
rcli() {
  _out=$(_cli "$INFRA_DIR/$KEY_ACL_ADMIN" "$@"); _rc=$?
  case "$_out" in
  *WRONGPASS*|*NOAUTH*)
    if [ -s "$INFRA_DIR/${KEY_ACL_ADMIN}-previous" ]; then
      _out=$(_cli "$INFRA_DIR/${KEY_ACL_ADMIN}-previous" "$@"); _rc=$?
    fi ;;
  esac
  printf '%s\n' "$_out"
  [ "$_rc" -eq 0 ] || return 1
  case "$_out" in
  ERR*|NOPERM*|WRONGPASS*|NOAUTH*|*"Could not connect"*|*"Connection refused"*|LOADING*|*"AUTH failed"*|*"Name does not resolve"*|*"Temporary failure"*) return 1 ;;
  esac
  return 0
}

# acl_digest <host> <port>: sha256 of ACL LIST (identical file -> identical output).
acl_digest() { _l=$(rcli "$1" "$2" ACL LIST) || return 1; printf '%s\n' "$_l" | sha256sum | cut -c1-64; }

# client_users <host> <port> <name-prefix> [TYPE <t>]: "user" field of matching clients
client_users() {
  _h=$1 _p=$2 _pref=$3; shift 3
  rcli "$_h" "$_p" CLIENT LIST "$@" | awk -v pref="$_pref" '{
      n=""; u="";
      for (i = 1; i <= NF; i++) { split($i, kv, "="); if (kv[1] == "name") n = kv[2]; if (kv[1] == "user") u = kv[2]; }
      if (pref == "" || index(n, pref) == 1) print u
    }'
}

# -----------------------------------------------------------------------------
# Local throw-away instances loaded from the mounted files:
#  * prove the files parse (a bad file would crash-loop pods on their next restart)
#  * give the EXPECTED normalised ACL LIST to compare every node against
#  * host the ACL DRYRUN preflight of the infra identities
# -----------------------------------------------------------------------------
local_start() {
  rm -rf "$PF"; mkdir -p "$PF/r" "$PF/s"
  redis-server --port "$PF_REDIS_PORT" --bind 127.0.0.1 --dir "$PF/r" --save "" --appendonly no \
    --aclfile "$ACL_DIR/users.acl" --include "$ACL_DIR/redis-infra.conf" >"$PF/redis.log" 2>&1 &
  PF_RPID=$!
  _n=0
  until rcli 127.0.0.1 "$PF_REDIS_PORT" PING >/dev/null 2>&1; do
    _n=$((_n + 1))
    if ! kill -0 "$PF_RPID" 2>/dev/null || [ "$_n" -gt 30 ]; then
      grep -viE 'masterauth|auth-pass|sentinel-pass|requirepass|#[0-9a-f]{64}' "$PF/redis.log" | tail -n 20
      die "users.acl / redis-infra.conf rejected by redis-server (see above). Nothing was applied."
    fi
    sleep 0.5
  done
  cat >"$PF/s/sentinel.conf" <<EOF
port $PF_SENTINEL_PORT
bind 127.0.0.1
dir "$PF/s"
aclfile $ACL_DIR/sentinel-users.acl
sentinel monitor $MASTER_GROUP 127.0.0.1 $PF_REDIS_PORT 1
include $ACL_DIR/sentinel-infra.conf
EOF
  redis-sentinel "$PF/s/sentinel.conf" >"$PF/sentinel.log" 2>&1 &
  PF_SPID=$!
  _n=0
  until rcli 127.0.0.1 "$PF_SENTINEL_PORT" PING >/dev/null 2>&1; do
    _n=$((_n + 1))
    if ! kill -0 "$PF_SPID" 2>/dev/null || [ "$_n" -gt 30 ]; then
      grep -viE 'masterauth|auth-pass|sentinel-pass|requirepass|#[0-9a-f]{64}' "$PF/sentinel.log" | tail -n 20
      die "sentinel-users.acl / sentinel-infra.conf rejected by redis-sentinel (see above). Nothing was applied."
    fi
    sleep 0.5
  done
  EXPECTED_REDIS_DIGEST=$(acl_digest 127.0.0.1 "$PF_REDIS_PORT") || die "local ACL LIST failed"
  EXPECTED_SENTINEL_DIGEST=$(acl_digest 127.0.0.1 "$PF_SENTINEL_PORT") || die "local sentinel ACL LIST failed"
}

local_stop() {
  kill "${PF_SPID:-0}" "${PF_RPID:-0}" 2>/dev/null || true
  wait 2>/dev/null || true
  rm -rf "$PF"
}

# dry <redis|sentinel> <allow|deny> <user> <command...>
dry() {
  _t=$1 _want=$2 _u=$3; shift 3
  if [ "$_t" = redis ]; then _port=$PF_REDIS_PORT; else _port=$PF_SENTINEL_PORT; fi
  _r=$(_cli "$INFRA_DIR/$KEY_ACL_ADMIN" 127.0.0.1 "$_port" ACL DRYRUN "$_u" "$@")
  if [ "$_want" = allow ] && [ "$_r" != "OK" ]; then die "preflight: ${_t} user '${_u}' must be allowed '$*' -> ${_r}"; fi
  if [ "$_want" = deny ] && [ "$_r" = "OK" ]; then die "preflight: ${_t} user '${_u}' must NOT be allowed '$*'"; fi
  return 0
}

has_user() { grep -q "^user $2 " "$ACL_DIR/$1"; }

# Infra identities must keep every command Sentinel/replication/probes use
# (silent failover breakage, redis/redis#9772).
preflight_dryrun() {
  set -f # rules and commands contain glob characters
  _demoted=false
  if [ "${PHASE}" = "2" ] && [ "${DEMOTE_DEFAULT}" = "true" ]; then _demoted=true; fi
  if [ "${PHASE}" = "2" ]; then
    _su=sentinel-user _ru=replica-user _pu=sentinel-peer
  else
    _su=default _ru=default _pu=default
  fi
  for c in "PING" "INFO" "ROLE" "MULTI" "EXEC" "SLAVEOF NO ONE" "SLAVEOF 10.0.0.1 6379" "CONFIG REWRITE" \
    "CLIENT SETNAME sentinel-x-cmd" "CLIENT KILL TYPE normal" "SCRIPT KILL" "PUBLISH __sentinel__:hello x" \
    "SUBSCRIBE __sentinel__:hello"; do
    # shellcheck disable=SC2086
    dry redis allow "$_su" $c
  done
  for c in "PING" "PSYNC ? -1" "REPLCONF capa eof"; do
    # shellcheck disable=SC2086
    dry redis allow "$_ru" $c
  done
  # chart probes / preStop / split-brain-fix use `default`
  for c in "PING" "ROLE" "INFO" "SHUTDOWN"; do
    # shellcheck disable=SC2086
    dry redis allow default $c
  done
  if [ "$_demoted" = true ]; then
    for c in "GET k" "SET k v" "CONFIG GET maxmemory" "ACL LIST" "KEYS *" "FLUSHALL" "PUBLISH __sentinel__:hello x" "SLAVEOF NO ONE"; do
      # shellcheck disable=SC2086
      dry redis deny default $c
    done
    for c in "SENTINEL MASTERS" "SENTINEL SET $MASTER_GROUP quorum 1" "ACL LIST" "SENTINEL CONFIG GET *"; do
      # shellcheck disable=SC2086
      dry sentinel deny default $c
    done
  fi
  for c in "PING" "INFO" "CONFIG GET maxmemory" "CLIENT LIST" "SLOWLOG GET 10" "LATENCY LATEST"; do
    # shellcheck disable=SC2086
    dry redis allow exporter-user $c
  done
  for c in "ACL LOAD" "ACL LIST" "CONFIG SET masteruser x" "CONFIG REWRITE" "CLIENT KILL TYPE master" "ROLE"; do
    # shellcheck disable=SC2086
    dry redis allow acl-admin $c
  done
  if has_user users.acl haproxy-user; then
    for c in "PING" "INFO replication" "ROLE"; do
      # shellcheck disable=SC2086
      dry redis allow haproxy-user $c
    done
    dry sentinel allow haproxy-user SENTINEL GET-MASTER-ADDR-BY-NAME "$MASTER_GROUP"
  fi
  # Sentinel side
  for c in "PING" "SENTINEL GET-MASTER-ADDR-BY-NAME $MASTER_GROUP" "SENTINEL FAILOVER $MASTER_GROUP" "SENTINEL RESET $MASTER_GROUP"; do
    # shellcheck disable=SC2086
    dry sentinel allow default $c
  done
  for c in "PING" "PUBLISH __sentinel__:hello x" "CLIENT SETNAME sentinel-x-cmd" "SENTINEL IS-MASTER-DOWN-BY-ADDR 127.0.0.1 6379 0 *"; do
    # shellcheck disable=SC2086
    dry sentinel allow "$_pu" $c
  done
  for c in "ACL LOAD" "SENTINEL CKQUORUM $MASTER_GROUP" "SENTINEL SET $MASTER_GROUP auth-pass x" "SENTINEL CONFIG SET sentinel-pass x"; do
    # shellcheck disable=SC2086
    dry sentinel allow acl-admin $c
  done
  # Catalog users: no admin, no flush, discovery on Sentinel
  _apps=$(grep "^user ${USERNAME_PREFIX:-system.serviceaccount}\." "$ACL_DIR/users.acl" | cut -d' ' -f2)
  for _app in $_apps; do
    for c in "FLUSHALL" "CONFIG GET maxmemory" "KEYS *" "ACL LIST" "PUBLISH __sentinel__:hello x" "SUBSCRIBE __sentinel__:hello"; do
      # shellcheck disable=SC2086
      dry redis deny "$_app" $c
    done
    if has_user sentinel-users.acl "$_app"; then
      dry sentinel allow "$_app" SENTINEL GET-MASTER-ADDR-BY-NAME "$MASTER_GROUP"
      dry sentinel deny "$_app" SENTINEL FAILOVER "$MASTER_GROUP"
    fi
  done
  if has_user users.acl migration-user; then
    for c in "RESTORE k 0 x REPLACE" "SET k v" "DEL k" "SELECT 1" "PING" "MULTI" "EXEC" "EXPIRE k 10" "XADD s * f v" "HSET h f v"; do
      # shellcheck disable=SC2086
      dry redis allow migration-user $c
    done
    for c in "FLUSHALL" "FLUSHDB" "CONFIG SET maxmemory 1" "ACL LIST" "PUBLISH __sentinel__:hello x" "EVAL return 1 0" "SLAVEOF NO ONE" "KEYS *" "SHUTDOWN"; do
      # shellcheck disable=SC2086
      dry redis deny migration-user $c
    done
  fi
  if has_user users.acl backup-user; then
    for c in "SYNC" "REPLCONF rdb-only 1" "ROLE" "INFO keyspace" "PING"; do
      # shellcheck disable=SC2086
      dry redis allow backup-user $c
    done
    for c in "GET k" "SET k v" "KEYS *" "FLUSHALL" "CONFIG GET *" "ACL LIST" "PSYNC ? -1" "SLAVEOF NO ONE" "SHUTDOWN" "DEBUG RELOAD"; do
      # shellcheck disable=SC2086
      dry redis deny backup-user $c
    done
  fi
  set +f
  log "preflight: ACL DRYRUN checks passed (phase ${PHASE}, default demoted: ${_demoted})"
}
