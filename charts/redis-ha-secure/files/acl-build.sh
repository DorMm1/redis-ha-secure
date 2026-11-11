#!/bin/bash
# =============================================================================
# acl-build.sh - pre-install / pre-upgrade hook (image: alpine/k8s)
#
#  1. Ensures the infra credentials Secret has every key the selected phase needs
#     (generates missing ones ONCE when allowed. Existing values are never changed).
#  2. Resolves every catalog user's plaintext password(s):
#       * pre-created Secret (passwordSecret)  -> read only
#       * otherwise generated ONCE into the per-consumer Secret in the workload namespace
#  3. Hashes them (SHA-256) and renders users.acl / sentinel-users.acl
#     (every line starts with `reset`) plus the include files that carry the
#     replication / Sentinel credentials.
#  4. Server-side applies the single ACL Secret.
#
# Never prints secret material. Plaintext only ever exists in Secrets and in the
# memory-backed /work emptyDir of this pod.
# =============================================================================
set -euo pipefail
umask 077

: "${NAMESPACE:?}" "${RELEASE:?}" "${ACL_SECRET:?}" "${INFRA_SECRET:?}" "${PHASE:?}"
: "${DEMOTE_DEFAULT:?}" "${GENERATE_INFRA:?}" "${MASTER_GROUP:?}" "${FULLNAME:?}"
: "${REPLICAS:?}" "${SENTINEL_PORT:?}" "${REDIS_PORT:?}" "${HAPROXY_ENABLED:?}" "${HAPROXY_PORT:?}"
: "${KEY_DEFAULT:?}" "${KEY_SENTINEL_DEFAULT:?}" "${KEY_REPLICA:?}" "${KEY_SENTINEL_USER:?}" "${KEY_SENTINEL_PEER:?}"
CATALOG=/catalog/catalog.tsv
INFRA_KEYS=/catalog/infra-keys.txt
W=/work
mkdir -p "$W/infra"
export HOME=/tmp

log() { printf '%s [acl-build] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { log "ERROR: $*"; exit 1; }

genpw() { local p; p=$(head -c 96 /dev/urandom | base64 | tr -dc 'A-Za-z0-9'); printf '%s' "${p:0:40}"; }
sha() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }
b64f() { base64 -w0 <"$1"; }
b64s() { printf '%s' "$1" | base64 -w0; }

# load_secret <ns> <name>: 0 = exists (JSON in $W/sec.json), 1 = NotFound.
# Any other error ABORTS. A transient API error must never look like "missing key",
# because that would regenerate (and overwrite) a live password.
load_secret() {
  rm -f "$W/sec.json"
  if kubectl get secret "$2" -n "$1" -o json >"$W/sec.json" 2>"$W/err"; then return 0; fi
  if grep -q 'NotFound' "$W/err"; then echo '{}' >"$W/sec.json"; return 1; fi
  die "cannot read Secret $1/$2: $(head -c 300 "$W/err")"
}
# key_of <key>: decoded value from the last load_secret (empty if absent)
key_of() { jq -r --arg k "$1" '.data[$k] // empty' "$W/sec.json" | base64 -d; }

# Quote a value for redis.conf / sentinel.conf (sdssplitargs double-quote rules).
conf_quote() { local v=$1; v=${v//\\/\\\\}; v=${v//\"/\\\"}; printf '"%s"' "$v"; }

# Server-side apply a Secret with the data files in a directory (file name = key).
apply_secret() { # ns name labels-yaml annotations-yaml datadir
  local ns=$1 name=$2 labels=$3 annotations=$4 dir=$5 f
  {
    echo "apiVersion: v1"
    echo "kind: Secret"
    echo "type: Opaque"
    echo "metadata:"
    echo "  name: $name"
    echo "  namespace: $ns"
    echo "  labels:"
    printf '%s\n' "$labels"
    echo "  annotations:"
    printf '%s\n' "$annotations"
    echo "data:"
    for f in "$dir"/*; do
      [ -f "$f" ] || continue
      printf '  %s: %s\n' "$(basename "$f")" "$(b64f "$f")"
    done
  } >"$W/apply.yaml"
  kubectl apply --server-side --field-manager=redis-ha-secure-acl-build --force-conflicts -f "$W/apply.yaml" >/dev/null
  rm -f "$W/apply.yaml"
}

LABELS="    app.kubernetes.io/managed-by: redis-ha-secure
    app.kubernetes.io/part-of: ${RELEASE}"

# -----------------------------------------------------------------------------
# 1. Infra credentials
# -----------------------------------------------------------------------------
log "phase=${PHASE} demoteDefault=${DEMOTE_DEFAULT} namespace=${NAMESPACE}"
mapfile -t REQUIRED < <(grep -v '^[[:space:]]*$' "$INFRA_KEYS")
infra_exists=true
load_secret "$NAMESPACE" "$INFRA_SECRET" || infra_exists=false
missing=()
for k in "${REQUIRED[@]}"; do
  v=$(key_of "$k")
  if [ -z "$v" ]; then missing+=("$k"); fi
done
if [ "${#missing[@]}" -gt 0 ]; then
  [ "$GENERATE_INFRA" = "true" ] || die "infra Secret ${NAMESPACE}/${INFRA_SECRET} is missing keys: ${missing[*]} (infraCredentials.generate=false: pre-create them, e.g. via External Secrets)"
  if [ "$infra_exists" = true ]; then
    # JSON merge patch that only ADDS keys (existing keys are never touched).
    { printf '{"data":{'; sep=""
      for k in "${missing[@]}"; do printf '%s"%s":"%s"' "$sep" "$k" "$(b64s "$(genpw)")"; sep=","; done
      printf '}}'; } >"$W/patch.json"
    kubectl patch secret "$INFRA_SECRET" -n "$NAMESPACE" --type merge --patch-file "$W/patch.json" >/dev/null
    rm -f "$W/patch.json"
    log "generated missing infra keys: ${missing[*]}"
  else
    mkdir -p "$W/new-infra"
    for k in "${missing[@]}"; do genpw >"$W/new-infra/$k"; done
    apply_secret "$NAMESPACE" "$INFRA_SECRET" "$LABELS" "    redis-ha-secure/generated: \"true\"" "$W/new-infra"
    rm -rf "$W/new-infra"
    log "created infra Secret ${INFRA_SECRET} with generated keys: ${missing[*]}"
  fi
  load_secret "$NAMESPACE" "$INFRA_SECRET" || die "infra Secret vanished"
fi
# Load current + previous values of every key (for hashing / include files).
for k in "${REQUIRED[@]}"; do
  key_of "$k" >"$W/infra/$k"
  [ -s "$W/infra/$k" ] || die "infra key $k still empty"
  key_of "${k}-previous" >"$W/infra/${k}-previous"
done
rm -f "$W/sec.json"
infra_pw() { cat "$W/infra/$1"; }

# "#<sha(current)> [#<sha(previous)>]" for an infra key
infra_hashes() {
  local h="#$(sha "$(infra_pw "$1")")"
  if [ -s "$W/infra/$1-previous" ]; then h="$h #$(sha "$(cat "$W/infra/$1-previous")")"; fi
  printf '%s' "$h"
}

# -----------------------------------------------------------------------------
# 2. Catalog -> ACL bodies
# -----------------------------------------------------------------------------
: >"$W/redis.body"
: >"$W/sentinel.body"
sentinel_addrs=""
for i in $(seq 0 $((REPLICAS - 1))); do
  sentinel_addrs="${sentinel_addrs:+$sentinel_addrs,}${FULLNAME}-announce-${i}.${NAMESPACE}.svc:${SENTINEL_PORT}"
done
napps=0
while IFS=$'\t' read -r kind f1 f2 f3 f4 f5 f6 f7; do
  [ -n "${kind:-}" ] || continue
  case "$kind" in
  infra)
    target=$f1 user=$f2 key=$f3 rules=$f4
    line="user ${user} reset on $(infra_hashes "$key") ${rules}"
    if [ "$target" = redis ]; then echo "$line" >>"$W/redis.body"; else echo "$line" >>"$W/sentinel.body"; fi
    ;;
  app)
    user=$f1 ns=$f2 cred=$f3 pwsec=$f4 pwkey=$f5 rrules=$f6 srules=$f7
    if [ "$pwsec" != "-" ]; then
      load_secret "$ns" "$pwsec" || die "user ${user}: pre-created Secret ${ns}/${pwsec} not found"
      cur=$(key_of "$pwkey")
      [ -n "$cur" ] || die "user ${user}: pre-created Secret ${ns}/${pwsec} key '${pwkey}' is missing or empty"
      prev=$(key_of "${pwkey}-previous")
      uname=$(key_of username)
      if [ -z "$uname" ]; then
        log "WARN user ${user}: ${ns}/${pwsec} has no 'username' key (add it, e.g. via the ExternalSecret target template)"
      elif [ "$uname" != "$user" ]; then
        die "user ${user}: ${ns}/${pwsec} username '${uname}' does not match the catalog"
      fi
    else
      load_secret "$ns" "$cred" || true
      cur=$(key_of password)
      prev=$(key_of password-previous)
      if [ -z "$cur" ]; then
        cur=$(genpw)
        log "user ${user}: generated password into ${ns}/${cred}"
      fi
      mkdir -p "$W/cred"
      printf '%s' "$user" >"$W/cred/username"
      printf '%s' "$cur" >"$W/cred/password"
      if [ "$HAPROXY_ENABLED" = "true" ]; then
        # HAProxy mode: one plain address, no Sentinel awareness needed.
        printf '%s' "${FULLNAME}-haproxy.${NAMESPACE}.svc" >"$W/cred/host"
        printf '%s' "${HAPROXY_PORT}" >"$W/cred/port"
        printf '%s' "${FULLNAME}-haproxy.${NAMESPACE}.svc:${HAPROXY_PORT}" >"$W/cred/redis-address"
      else
        printf '%s' "$MASTER_GROUP" >"$W/cred/sentinel-master-name"
        printf '%s' "$sentinel_addrs" >"$W/cred/sentinel-addresses"
      fi
      # Server-side apply: keys of the other mode are removed when the mode changes.
      apply_secret "$ns" "$cred" "$LABELS" "    redis-ha-secure/acl-username: \"${user}\"" "$W/cred"
      rm -rf "$W/cred"
    fi
    h="#$(sha "$cur")"
    [ -n "$prev" ] && h="$h #$(sha "$prev")"
    echo "user ${user} reset on ${h} ${rrules}" >>"$W/redis.body"
    if [ "$srules" != "-" ]; then
      echo "user ${user} reset on ${h} ${srules}" >>"$W/sentinel.body"
    fi
    napps=$((napps + 1))
    ;;
  *) die "unknown catalog line type '$kind'" ;;
  esac
done <"$CATALOG"

# -----------------------------------------------------------------------------
# 3. Include files (replication + Sentinel credentials)
# -----------------------------------------------------------------------------
if [ "$PHASE" = "2" ]; then
  {
    echo "masteruser replica-user"
    echo "masterauth $(conf_quote "$(infra_pw "$KEY_REPLICA")")"
  } >"$W/redis-infra.conf"
  {
    echo "sentinel auth-user ${MASTER_GROUP} sentinel-user"
    echo "sentinel auth-pass ${MASTER_GROUP} $(conf_quote "$(infra_pw "$KEY_SENTINEL_USER")")"
    echo "sentinel sentinel-user sentinel-peer"
    echo "sentinel sentinel-pass $(conf_quote "$(infra_pw "$KEY_SENTINEL_PEER")")"
  } >"$W/sentinel-infra.conf"
else
  echo "masterauth $(conf_quote "$(infra_pw "$KEY_DEFAULT")")" >"$W/redis-infra.conf"
  echo "sentinel auth-pass ${MASTER_GROUP} $(conf_quote "$(infra_pw "$KEY_DEFAULT")")" >"$W/sentinel-infra.conf"
fi

# Guard rails (redis/redis#11063): never demote `default` unless Sentinel and replicas
# authenticate with dedicated users.
if [ "$PHASE" = "2" ] && [ "$DEMOTE_DEFAULT" = "true" ]; then
  grep -q '^sentinel auth-user ' "$W/sentinel-infra.conf" || die "refusing to demote default without sentinel auth-user"
  grep -q '^sentinel auth-pass ' "$W/sentinel-infra.conf" || die "refusing to demote default without sentinel auth-pass"
  grep -q '^masteruser replica-user' "$W/redis-infra.conf" || die "refusing to demote default without masteruser"
fi
for u in default acl-admin exporter-user; do
  grep -q "^user ${u} " "$W/redis.body" || die "users.acl lacks required user ${u}"
done
for u in default acl-admin; do
  grep -q "^user ${u} " "$W/sentinel.body" || die "sentinel-users.acl lacks required user ${u}"
done
dups=$(cut -d' ' -f2 "$W/redis.body" | sort | uniq -d)
[ -z "$dups" ] || die "duplicate ACL users: ${dups}"

# -----------------------------------------------------------------------------
# 4. Revision markers + ACL Secret
#    The marker is a disabled user whose only "password hash" is the SHA-256 of the
#    file body + include file. It lets the reload / drift Jobs prove which revision
#    every node has loaded (ACL LIST) and which revision kubelet has mounted.
# -----------------------------------------------------------------------------
rev_r=$(cat "$W/redis.body" "$W/redis-infra.conf" | sha256sum | cut -d' ' -f1)
rev_s=$(cat "$W/sentinel.body" "$W/sentinel-infra.conf" | sha256sum | cut -d' ' -f1)
mkdir -p "$W/acl"
{ echo "user acl-revision reset off resetkeys resetchannels -@all #${rev_r}"; cat "$W/redis.body"; } >"$W/acl/users.acl"
{ echo "user acl-revision reset off resetkeys resetchannels -@all #${rev_s}"; cat "$W/sentinel.body"; } >"$W/acl/sentinel-users.acl"
mv "$W/redis-infra.conf" "$W/sentinel-infra.conf" "$W/acl/"

apply_secret "$NAMESPACE" "$ACL_SECRET" "$LABELS" "    redis-ha-secure/revision-redis: \"${rev_r}\"
    redis-ha-secure/revision-sentinel: \"${rev_s}\"
    redis-ha-secure/phase: \"${PHASE}\"
    redis-ha-secure/demote-default: \"${DEMOTE_DEFAULT}\"" "$W/acl"
rm -rf "$W/acl" "$W/infra" "$W"/*.body

log "ACL Secret ${ACL_SECRET} applied: $(($(wc -l <"$CATALOG"))) catalog lines, ${napps} app users, revision redis=${rev_r:0:12} sentinel=${rev_s:0:12}"
