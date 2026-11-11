#!/usr/bin/env bash
# Shared helpers for the test scripts. Requires: bash, kubectl, helm (and a context
# pointing at the target cluster). Secrets are never printed. Passwords are piped
# to redis-cli through stdin (REDISCLI_AUTH) inside the pods.
set -euo pipefail
export MSYS_NO_PATHCONV=1 # Git Bash on Windows: do not rewrite /paths in arguments
export LC_ALL=C.UTF-8      # grep -P needs a UTF-8 locale
# Mixed-form paths (C:/...) work for both bash and native Windows helm/kubectl.
wp() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s\n' "$1"; fi; }
mktmpd() { wp "$(mktemp -d)"; }

ROOT=$(wp "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)")
CHART=${CHART:-$ROOT/charts/redis-ha-secure}
NS=${NS:-redis}
RELEASE=${RELEASE:-redis}
FULL=${FULL:-$RELEASE-redis-ha}
MASTER_GROUP=${MASTER_GROUP:-mymaster}
REPLICAS=${REPLICAS:-3}
INFRA_SECRET=${INFRA_SECRET:-redis-ha-infra-credentials}
EXTRA_VALUES=${EXTRA_VALUES:-$ROOT/scripts/ci/values-kind.yaml}
PHASE=${PHASE:-1}
HAPROXY=${HAPROXY:-0} # 1 = HAProxy mode (values-haproxy.yaml); clients connect via HAProxy

# KUBE_CONTEXT pins every kubectl/helm call (also in child scripts) to one cluster.
if [ -n "${KUBE_CONTEXT:-}" ]; then
  kubectl() { command kubectl --context "$KUBE_CONTEXT" "$@"; }
  helm() { command helm --kube-context "$KUBE_CONTEXT" "$@"; }
  export -f kubectl helm
fi
export NS RELEASE FULL KUBE_CONTEXT HAPROXY PHASE

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }
info() { printf '\033[36m==>\033[0m %s\n' "$*"; }
summary() {
  printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ]
}
check() { # <description> <cmd...>
  local d=$1; shift
  if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi
}

secret_val() { # <ns> <secret> <key>
  kubectl get secret -n "$1" "$2" -o "jsonpath={.data.${3//./\\.}}" | base64 -d
}

pod() { echo "${FULL}-server-$1"; }

# cli_as <pod> <container> <user> <password> <host> <port> args...
cli_as() {
  local p=$1 c=$2 u=$3 pw=$4 h=$5 port=$6; shift 6
  printf '%s' "$pw" | kubectl exec -i -n "$NS" "$p" -c "$c" -- sh -c \
    'u=$1; h=$2; port=$3; shift 3; IFS= read -r pw || true; REDISCLI_AUTH="$pw" exec redis-cli --no-auth-warning --user "$u" -h "$h" -p "$port" "$@"' \
    _ "$u" "$h" "$port" "$@"
}

ADMIN_PW=""
admin_pw() { [ -n "$ADMIN_PW" ] || ADMIN_PW=$(secret_val "$NS" "$INFRA_SECRET" acl-admin-password); printf '%s' "$ADMIN_PW"; }
# admin_redis <i> args...   (acl-admin on redis node i, via localhost)
admin_redis() { local i=$1; shift; cli_as "$(pod "$i")" redis acl-admin "$(admin_pw)" localhost 6379 "$@"; }
# admin_sentinel <i> args...
admin_sentinel() { local i=$1; shift; cli_as "$(pod "$i")" sentinel acl-admin "$(admin_pw)" localhost 26379 "$@"; }

master_index() { # index of the pod that currently has role master
  local i
  for i in $(seq 0 $((REPLICAS - 1))); do
    if [ "$(admin_redis "$i" ROLE 2>/dev/null | head -n1 | tr -d '\r')" = "master" ]; then echo "$i"; return 0; fi
  done
  return 1
}
master_addr() { admin_sentinel "${1:-0}" SENTINEL GET-MASTER-ADDR-BY-NAME "$MASTER_GROUP" | head -n1 | tr -d '\r'; }
acl_digest() { admin_redis "$1" ACL LIST | tr -d '\r' | sha256sum | cut -c1-64; }
sentinel_acl_digest() { admin_sentinel "$1" ACL LIST | tr -d '\r' | sha256sum | cut -c1-64; }

helm_values() {
  local f=("-f" "$CHART/values.yaml")
  [ "$HAPROXY" = 1 ] && f+=("-f" "$CHART/values-haproxy.yaml")
  f+=("-f" "$CHART/values-phase${PHASE}.yaml")
  local e
  for e in $EXTRA_VALUES; do f+=("-f" "$e"); done
  printf '%s\n' "${f[@]}"
}

HAP_SVC="${FULL}-haproxy.${NS}.svc"
# client <ns> args... : run a command as the pod's own catalog credentials (/creds).
#   HAProxy mode: straight to the HAProxy Service (redis-address in the Secret)
#   direct mode : Sentinel discovery first, then the master
client() {
  local n=$1; shift
  kubectl -n "$n" exec redis-client -- sh -c '
    U=$(cat /creds/username); export REDISCLI_AUTH=$(cat /creds/password)
    if [ -f /creds/redis-address ]; then
      A=$(cat /creds/redis-address); H=${A%:*}; P=${A##*:}
    else
      H=$(timeout 5 redis-cli --no-auth-warning --user "$U" -h '"${FULL}-announce-0.${NS}.svc"' -p 26379 SENTINEL GET-MASTER-ADDR-BY-NAME '"$MASTER_GROUP"' | head -n1)
      P=6379
      [ -n "$H" ] || { echo "NO-MASTER"; exit 1; }
    fi
    timeout 5 redis-cli --no-auth-warning --user "$U" -h "$H" -p "$P" "$@"' _ "$@"
}

wait_for() { # <timeout-seconds> <description> <cmd...>
  local t=$1 d=$2; shift 2
  local end=$(($(date +%s) + t))
  until "$@" >/dev/null 2>&1; do
    if [ "$(date +%s)" -ge "$end" ]; then bad "timeout: $d"; return 1; fi
    sleep 3
  done
  ok "$d"
}
