#!/bin/sh
# DR restore, step 2 (Redis image, init container of EVERY Redis pod).
# With `appendonly yes`, Redis >= 7 loads ONLY the AOF directory and, if it is missing,
# creates a new EMPTY AOF and ignores dump.rdb. The snapshot is therefore installed as
# the BASE of a new multi-part AOF (an RDB-format base is valid) plus a one-line
# manifest, and also as dump.rdb (for appendonly no). The AOF directory is moved into
# place first, atomically, so an interrupted install can never leave a dump.rdb that a
# restart would silently ignore.
set -eu
log() { printf '%s [dr-restore-install] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { log "ERROR: $*"; exit 1; }

stage=/data/.dr-restore
conf=/data/conf/redis.conf
getconf() { _v=$(sed -n "s/^$1[[:space:]][[:space:]]*//p" "$conf" 2>/dev/null | tail -n 1 | tr -d '"'); echo "${_v:-$2}"; }
dbfile=$(getconf dbfilename dump.rdb)
aofdir=$(getconf appenddirname appendonlydir)
aoffile=$(getconf appendfilename appendonly.aof)

if [ -e "/data/$dbfile" ] || [ -e "/data/$aofdir" ]; then
  rm -rf "$stage"
  log "data present: nothing to install"
  exit 0
fi
[ -f "$stage/.fetched" ] || { log "no fetched backup: nothing to install"; exit 0; }

redis-check-rdb "$stage/dump.rdb" >"$stage/check.log" 2>&1 || { cat "$stage/check.log"; die "redis-check-rdb failed"; }
mkdir "$stage/aof"
cp "$stage/dump.rdb" "$stage/aof/$aoffile.1.base.rdb"
printf 'file %s.1.base.rdb seq 1 type b\n' "$aoffile" >"$stage/aof/$aoffile.manifest"
cp "$stage/dump.rdb" "$stage/$dbfile.installing"
mv "$stage/aof" "/data/$aofdir"
mv "$stage/$dbfile.installing" "/data/$dbfile"
cp "$stage/backup.meta" /data/.dr-restored-from
rm -rf "$stage"
log "installed backup $(sed -n 's/^backup_id=//p' /data/.dr-restored-from) as /data/$aofdir/$aoffile.1.base.rdb and /data/$dbfile"
