#!/bin/sh
# DR backup, step 2 (rclone image): upload the verified snapshot to <remote>/<backup-id>/,
# verify the remote copy, update <remote>/LATEST, then apply retention.
# Retention never deletes the newest `RETENTION_KEEP_LAST` backups, so failing backups
# can never age out the last good ones.
set -eu
: "${DR_REMOTE:?}" "${RETENTION_DAYS:?}" "${RETENTION_KEEP_LAST:?}"
log() { printf '%s [dr-upload] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { log "ERROR: $*"; exit 1; }

remote=${DR_REMOTE%/}
id=$(sed -n 's/^backup_id=//p' /spool/backup.meta)
[ -n "$id" ] || die "no backup_id in /spool/backup.meta"
(cd /spool && sha256sum -c SHA256SUMS) || die "local checksum mismatch"

set -- --include dump.rdb --include backup.meta --include SHA256SUMS
rclone copy /spool "$remote/$id" "$@" --retries 3 --low-level-retries 10 --stats-one-line --stats 30s \
  || die "upload failed"
rclone check /spool "$remote/$id" "$@" --one-way || die "remote copy differs from the local snapshot"
printf '%s\n' "$id" | rclone rcat "$remote/LATEST" || die "could not update LATEST"
log "uploaded $remote/$id"

if [ "$RETENTION_DAYS" -gt 0 ]; then
  cutoff=$(date -u -d "@$(($(date +%s) - RETENTION_DAYS * 86400))" +%Y%m%d%H%M%S)
  dirs=$(rclone lsf --dirs-only "$remote" | sed 's:/$::' | grep -E '^[0-9]{8}T[0-9]{6}Z$' | sort || true)
  total=$(printf '%s\n' "$dirs" | grep -c . || true)
  pruned=0
  for d in $dirs; do
    [ $((total - pruned)) -le "$RETENTION_KEEP_LAST" ] && break
    [ "$(printf '%s' "$d" | tr -d TZ)" -lt "$cutoff" ] || break
    rclone purge "$remote/$d" || die "could not prune $d"
    pruned=$((pruned + 1))
    log "pruned $d (older than ${RETENTION_DAYS}d)"
  done
  log "retention: $((total - pruned)) backups kept (min ${RETENTION_KEEP_LAST}, ${RETENTION_DAYS}d)"
fi
