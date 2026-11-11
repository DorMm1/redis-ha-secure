#!/bin/sh
# DR restore, step 1 (rclone image, init container of EVERY Redis pod).
# Only acts on an EMPTY data directory: a pod that already has data (normal restarts,
# or after the restore) is never touched. Downloads <remote>/<backup-id>/ into
# /data/.dr-restore and verifies SHA256SUMS.
set -eu
: "${DR_REMOTE:?}" "${DR_BACKUP_ID:?}"
log() { printf '%s [dr-restore-fetch] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { log "ERROR: $*"; exit 1; }

conf=/data/conf/redis.conf
getconf() { _v=$(sed -n "s/^$1[[:space:]][[:space:]]*//p" "$conf" 2>/dev/null | tail -n 1 | tr -d '"'); echo "${_v:-$2}"; }
dbfile=$(getconf dbfilename dump.rdb)
aofdir=$(getconf appenddirname appendonlydir)
if [ -e "/data/$dbfile" ] || [ -e "/data/$aofdir" ]; then
  log "data present in /data ($dbfile or $aofdir): restore skipped"
  exit 0
fi

stage=/data/.dr-restore
rm -rf "$stage"
mkdir -p "$stage"
log "fetching ${DR_REMOTE%/}/$DR_BACKUP_ID"
rclone copy "${DR_REMOTE%/}/$DR_BACKUP_ID" "$stage" \
  --include dump.rdb --include backup.meta --include SHA256SUMS --retries 5 --low-level-retries 10 \
  || die "download failed"
(cd "$stage" && sha256sum -c SHA256SUMS) || die "checksum mismatch"
touch "$stage/.fetched"
log "fetched and verified: $(tr '\n' ' ' <"$stage/backup.meta")"
