#!/usr/bin/env bash
# rotate-password.sh - password rotation for a catalog user through the
# Secret + ACL LOAD path (no ACL SETUSER by hand, no pod restarts).
#
#   step start  <ns> <secret>   password-previous := password, password := new
#                               -> helm upgrade (build + reload hooks): BOTH accepted on every node
#                                  (equivalent of `ACL SETUSER u >new` on every node)
#   ...roll the workload so clients pick up the new password...
#   step finish <ns> <secret>   delete password-previous
#                               -> helm upgrade: old password rejected on every node
#                                  (equivalent of `ACL SETUSER u <old` on every node)
#
# For pre-created (ESO) Secrets, do the same key changes in the secret store
# (<key> and <key>-previous). For infra users use the infra Secret with keys
# <name>-password / <name>-password-previous. The reload Job then also switches
# masterauth / Sentinel auth-pass at runtime.
set -euo pipefail
export MSYS_NO_PATHCONV=1
step=${1:?start|finish} ns=${2:?namespace} sec=${3:?secret} key=${4:-password}
case "$step" in
start)
  old=$(kubectl get secret -n "$ns" "$sec" -o "jsonpath={.data.$key}")
  [ -n "$old" ] || { echo "no key $key in $ns/$sec" >&2; exit 1; }
  new=$(head -c 96 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 40 | base64 | tr -d '\n')
  kubectl patch secret -n "$ns" "$sec" --type merge -p "{\"data\":{\"${key}-previous\":\"${old}\",\"${key}\":\"${new}\"}}" >/dev/null
  unset old new
  echo "rotated $ns/$sec: '$key' is new, '${key}-previous' holds the old value. Now run helm upgrade (or re-sync), then roll the clients."
  ;;
finish)
  kubectl patch secret -n "$ns" "$sec" --type json -p "[{\"op\":\"remove\",\"path\":\"/data/${key}-previous\"}]" >/dev/null
  echo "removed '${key}-previous' from $ns/$sec. Now run helm upgrade (or re-sync) to revoke the old password on every node."
  ;;
*) echo "usage: $0 start|finish <ns> <secret> [key]" >&2; exit 2 ;;
esac
