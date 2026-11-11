#!/bin/sh
# DR backup, step 1 (Redis image): take an RDB snapshot over the replication protocol
# (redis-cli --rdb = REPLCONF rdb-only + SYNC) as backup-user, preferably from the
# freshest connected REPLICA so the fork happens there and not on the master.
# Verifies the file (redis-check-rdb: structure + CRC64) and writes metadata + SHA256SUMS
# into /spool for the upload container.
set -eu
: "${NAMESPACE:?}" "${FULLNAME:?}" "${REPLICAS:?}" "${REDIS_PORT:?}" "${SOURCE:?}" "${BACKUP_PASSWORD:?}"
log() { printf '%s [dr-snapshot] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { log "ERROR: $*"; exit 1; }

export REDISCLI_AUTH="$BACKUP_PASSWORD"
cli() { _h=$1; shift; redis-cli --no-auth-warning --user backup-user -h "$_h" -p "$REDIS_PORT" "$@"; }

best=""; best_off=-1; master=""
i=0
while [ "$i" -lt "$REPLICAS" ]; do
  h="${FULLNAME}-server-${i}.${FULLNAME}.${NAMESPACE}.svc"
  role=$(cli "$h" ROLE 2>/dev/null | tr -d '\r' | tr '\n' ' ') || role=""
  # shellcheck disable=SC2086
  set -- $role
  case "${1:-}" in
    slave)
      # slave <master-host> <master-port> <state> <offset>
      if [ "${4:-}" = connected ] && [ "${5:--1}" -gt "$best_off" ]; then best=$h; best_off=$5; fi
      log "node $i: replica, link ${4:-?}, offset ${5:-?}" ;;
    master) master=$h; log "node $i: master, offset ${2:-?}" ;;
    *) log "node $i: unreachable or unexpected ROLE reply '${role}'" ;;
  esac
  i=$((i + 1))
done

src=$best; src_role=replica
if [ -z "$src" ]; then
  [ "$SOURCE" = any ] || die "no connected replica (dr.backup.source=replica). Not snapshotting the master."
  [ -n "$master" ] || die "no reachable node"
  src=$master; src_role=master
  log "WARNING: no connected replica, falling back to the master (fork on the master)"
fi
log "snapshot source: $src ($src_role)"

version=$(cli "$src" INFO server | tr -d '\r' | sed -n 's/^redis_version://p')
rm -rf /spool/* 2>/dev/null || true
timeout "${SNAPSHOT_TIMEOUT_SECONDS:-1800}" \
  redis-cli --no-auth-warning --user backup-user -h "$src" -p "$REDIS_PORT" --rdb /spool/dump.rdb \
  || die "redis-cli --rdb failed"
[ -s /spool/dump.rdb ] || die "empty snapshot"
if ! redis-check-rdb /spool/dump.rdb >/tmp/check.log 2>&1; then cat /tmp/check.log; die "redis-check-rdb failed"; fi
keyspace=$(cli "$src" INFO keyspace | tr -d '\r' | grep '^db' | tr '\n' ' ' || true)

id=$(date -u +%Y%m%dT%H%M%SZ)
cat >/spool/backup.meta <<EOF
backup_id=$id
namespace=$NAMESPACE
release_fullname=$FULLNAME
source_host=$src
source_role=$src_role
source_replication_offset=$best_off
redis_version=$version
rdb_bytes=$(wc -c </spool/dump.rdb | tr -d ' ')
keyspace_at_snapshot_approx=$keyspace
EOF
(cd /spool && sha256sum dump.rdb backup.meta >SHA256SUMS)
log "snapshot $id OK: $(wc -c </spool/dump.rdb | tr -d ' ') bytes, redis $version, $keyspace"
