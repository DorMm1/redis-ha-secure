#!/usr/bin/env bash
# 3. ACL DRYRUN checks per catalog user, generated from the rendered catalog:
#    allowed + denied commands / keys / channels on EVERY Redis node, discovery on
#    every Sentinel. Uses acl-admin (+acl|dryrun). Nothing is executed for real.
source "$(dirname "$0")/lib.sh"
set -f # ACL rules contain glob characters
mapfile -t VALUES < <(helm_values)
CATALOG=$(helm template "$RELEASE" "$CHART" -n "$NS" "${VALUES[@]}" --show-only templates/acl-build-hook.yaml \
  | awk '/catalog.tsv: \|/{f=1; next} /infra-keys.txt:/{f=0} f' | sed 's/^    //' | grep -P '^app\t' || true)
[ -n "$CATALOG" ] || { bad "no catalog users rendered"; summary; exit 1; }

# dry <node> <redis|sentinel> <allow|deny> <user> <cmd...>
dry() {
  local i=$1 t=$2 want=$3 u=$4; shift 4
  local r
  if [ "$t" = redis ]; then r=$(admin_redis "$i" ACL DRYRUN "$u" "$@" | tr -d '\r'); else r=$(admin_sentinel "$i" ACL DRYRUN "$u" "$@" | tr -d '\r'); fi
  if [ "$want" = allow ]; then
    [ "$r" = OK ] && ok "[$t$i] $u ALLOW  $*" || bad "[$t$i] $u should be allowed: $* -> $r"
  else
    [ "$r" != OK ] && ok "[$t$i] $u DENY   $*  ($(cut -c1-60 <<<"$r"))" || bad "[$t$i] $u should be DENIED: $*"
  fi
}

while IFS=$'\t' read -r _ user ns cred pwsec pwkey rules srules; do
  info "$user"
  scripting=true; grep -q -- '-@scripting' <<<"$rules" && scripting=false
  for i in $(seq 0 $((REPLICAS - 1))); do
    # keys
    for tok in $rules; do
      case "$tok" in
      "~"*)   p=${tok#\~}; k="${p%\*}dryrun"; dry "$i" redis allow "$user" GET "$k"; dry "$i" redis allow "$user" SET "$k" v ;;
      "%R~"*) p=${tok#%R~}; k="${p%\*}dryrun"; dry "$i" redis allow "$user" GET "$k"; dry "$i" redis deny "$user" SET "$k" v ;;
      "%W~"*) p=${tok#%W~}; k="${p%\*}dryrun"; dry "$i" redis allow "$user" SET "$k" v; dry "$i" redis deny "$user" GET "$k" ;;
      "&"*)   c=${tok#&}; c=${c//\*/dryrun}
              if grep -q -- '+publish' <<<"$rules"; then dry "$i" redis allow "$user" PUBLISH "$c" x; else dry "$i" redis deny "$user" PUBLISH "$c" x; fi
              if grep -q -- '+subscribe' <<<"$rules"; then dry "$i" redis allow "$user" SUBSCRIBE "$c"; else dry "$i" redis deny "$user" SUBSCRIBE "$c"; fi ;;
      esac
    done
    # outside the grants
    dry "$i" redis deny "$user" GET zz-not-granted:dryrun
    dry "$i" redis deny "$user" SET zz-not-granted:dryrun v
    dry "$i" redis deny "$user" PUBLISH zz-not-granted x
    dry "$i" redis deny "$user" SUBSCRIBE __sentinel__:hello
    dry "$i" redis deny "$user" PUBLISH __sentinel__:hello x
    # always-denied commands
    for c in "FLUSHALL" "FLUSHDB" "SWAPDB 0 1" "KEYS *" "CONFIG GET *" "CONFIG SET maxmemory 1" "ACL LIST" "ACL SETUSER x" \
      "SHUTDOWN" "DEBUG SLEEP 0" "MONITOR" "CLIENT KILL TYPE normal" "SLAVEOF NO ONE" "REPLICAOF NO ONE" "MODULE LIST" "SAVE" "BGREWRITEAOF"; do
      # shellcheck disable=SC2086
      dry "$i" redis deny "$user" $c
    done
    if [ "$scripting" = true ]; then
      dry "$i" redis allow "$user" EVAL "return 1" 0
      dry "$i" redis allow "$user" EVALSHA 0000000000000000000000000000000000000000 0
      dry "$i" redis deny "$user" SCRIPT FLUSH
      dry "$i" redis deny "$user" FUNCTION FLUSH
      dry "$i" redis deny "$user" FUNCTION DELETE lib
    else
      dry "$i" redis deny "$user" EVAL "return 1" 0
      dry "$i" redis deny "$user" FCALL f 0
    fi
    dry "$i" redis allow "$user" PING
    if [ "$srules" != "-" ]; then
      # Sentinel: discovery only
      dry "$i" sentinel allow "$user" SENTINEL GET-MASTER-ADDR-BY-NAME "$MASTER_GROUP"
      dry "$i" sentinel allow "$user" SENTINEL REPLICAS "$MASTER_GROUP"
      dry "$i" sentinel allow "$user" SUBSCRIBE +switch-master
      dry "$i" sentinel deny "$user" SENTINEL FAILOVER "$MASTER_GROUP"
      dry "$i" sentinel deny "$user" SENTINEL SET "$MASTER_GROUP" quorum 1
      dry "$i" sentinel deny "$user" SENTINEL RESET "*"
      dry "$i" sentinel deny "$user" ACL LIST
    else
      admin_sentinel "$i" ACL USERS | tr -d '\r' | grep -qx "$user" \
        && bad "[sentinel$i] $user exists on Sentinel (HAProxy mode: clients never talk to Sentinel)" \
        || ok "[sentinel$i] $user absent on Sentinel (HAProxy mode, least privilege)"
    fi
  done
done <<<"$CATALOG"

info "real AUTH of every catalog user on every node (credentials from their Secrets)"
while IFS=$'\t' read -r _ user ns cred pwsec pwkey rules srules; do
  if [ "$pwsec" = "-" ]; then s=$cred k=password; else s=$pwsec k=$pwkey; fi
  pw=$(secret_val "$ns" "$s" "$k")
  for i in $(seq 0 $((REPLICAS - 1))); do
    [ "$(cli_as "$(pod "$i")" redis "$user" "$pw" localhost 6379 PING | tr -d '\r')" = PONG ] \
      && ok "$user authenticates on redis node $i" || bad "$user AUTH failed on redis node $i"
    if [ "$srules" != "-" ]; then
      [ "$(cli_as "$(pod "$i")" sentinel "$user" "$pw" localhost 26379 PING | tr -d '\r')" = PONG ] \
        && ok "$user authenticates on sentinel $i" || bad "$user AUTH failed on sentinel $i"
    fi
  done
  cli_as "$(pod 0)" redis "$user" "wrong-$pw" localhost 6379 PING | grep -q -E 'WRONGPASS|NOAUTH' \
    && ok "$user with a wrong password is rejected" || bad "$user wrong password accepted?!"
  unset pw
done <<<"$CATALOG"
summary
