{{/* vim: set filetype=mustache: */}}

{{/* Same algorithm as the subchart's "redis-ha.name" / "redis-ha.fullname". */}}
{{- define "redis-ha-secure.redisName" -}}
{{- $sub := index .Values "redis-ha" -}}
{{- default "redis-ha" $sub.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "redis-ha-secure.redisFullname" -}}
{{- $sub := index .Values "redis-ha" -}}
{{- if $sub.fullnameOverride -}}
{{- $sub.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default "redis-ha" $sub.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/* Prefix for resources owned by this wrapper. */}}
{{- define "redis-ha-secure.fullname" -}}
{{- include "redis-ha-secure.redisFullname" . | trunc 52 | trimSuffix "-" -}}
{{- end -}}

{{- define "redis-ha-secure.masterGroupName" -}}
{{- $sub := index .Values "redis-ha" -}}
{{- tpl ($sub.redis.masterGroupName | default "mymaster") . -}}
{{- end -}}

{{/* ServiceAccount used by the redis StatefulSet (mirrors subchart logic). */}}
{{- define "redis-ha-secure.redisServiceAccount" -}}
{{- $sub := index .Values "redis-ha" -}}
{{- if $sub.serviceAccount.create -}}
{{- default (include "redis-ha-secure.redisFullname" .) $sub.serviceAccount.name -}}
{{- else -}}
{{- default "default" $sub.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{- define "redis-ha-secure.haproxyServiceAccount" -}}
{{- $sub := index .Values "redis-ha" -}}
{{- if $sub.haproxy.serviceAccount.create -}}
{{- printf "%s-haproxy" (include "redis-ha-secure.redisServiceAccount" .) -}}
{{- else -}}
{{- $sub.haproxy.serviceAccountName -}}
{{- end -}}
{{- end -}}

{{- define "redis-ha-secure.opsServiceAccount" -}}
{{- printf "%s-acl-ops" (include "redis-ha-secure.fullname" .) -}}
{{- end -}}

{{- define "redis-ha-secure.buildServiceAccount" -}}
{{- printf "%s-acl-build" (include "redis-ha-secure.fullname" .) -}}
{{- end -}}

{{- define "redis-ha-secure.migrationServiceAccount" -}}
{{- printf "%s-migration" (include "redis-ha-secure.fullname" .) -}}
{{- end -}}

{{- define "redis-ha-secure.drBackupServiceAccount" -}}
{{- printf "%s-dr-backup" (include "redis-ha-secure.fullname" .) -}}
{{- end -}}

{{- define "redis-ha-secure.labels" -}}
app.kubernetes.io/name: redis-ha-secure
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end -}}

{{/* Selector labels of the redis-ha server pods (set by the subchart). */}}
{{- define "redis-ha-secure.redisSelector" -}}
app: {{ include "redis-ha-secure.redisName" . }}
release: {{ .Release.Name }}
{{- end -}}

{{- define "redis-ha-secure.haproxySelector" -}}
app: {{ include "redis-ha-secure.redisName" . }}-haproxy
release: {{ .Release.Name }}
component: haproxy
{{- end -}}

{{/* Label that marks this release's own Job pods as Redis clients (NetworkPolicy). */}}
{{- define "redis-ha-secure.jobClientLabels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
redis-ha-secure/redis-client: "true"
{{- end -}}

{{- define "redis-ha-secure.username" -}}
{{- printf "%s.%s.%s" .prefix .namespace .serviceAccount -}}
{{- end -}}

{{- define "redis-ha-secure.credentialsSecret" -}}
{{- default (printf "redis-acl-%s" .serviceAccount) .credentialsSecret -}}
{{- end -}}

{{/*
Render the Redis ACL rules (without "user <name> reset on #<hash>") of one catalog entry.
Rules:
  keys:     read+write -> ~p   read -> %R~p   write -> %W~p     (p = keyPrefix + "*")
  channels: resetchannels &pattern ...
  commands: +@connection [+@read] [+@write] [+publish] [+subscribe +psubscribe +unsubscribe +punsubscribe]
            [+@scripting -script|flush -function|load|delete|flush|restore]
            -@dangerous -@admin -flushall -flushdb -swapdb -keys [-@scripting] <extra>
*/}}
{{- define "redis-ha-secure.appRedisRules" -}}
{{- $u := .user -}}
{{- $keys := list -}}
{{- $channels := list -}}
{{- $read := false -}}{{- $write := false -}}{{- $pub := false -}}{{- $sub := false -}}
{{- range $u.redis -}}
  {{- if .keyPrefix -}}
    {{- $r := has "read" .access -}}{{- $w := has "write" .access -}}
    {{- if and $r $w -}}{{- $keys = append $keys (printf "~%s*" .keyPrefix) -}}
    {{- else if $r -}}{{- $keys = append $keys (printf "%%R~%s*" .keyPrefix) -}}
    {{- else if $w -}}{{- $keys = append $keys (printf "%%W~%s*" .keyPrefix) -}}
    {{- end -}}
    {{- if $r -}}{{- $read = true -}}{{- end -}}
    {{- if $w -}}{{- $write = true -}}{{- end -}}
  {{- else if .channel -}}
    {{- $channels = append $channels (printf "&%s" .channel) -}}
    {{- if has "publish" .access -}}{{- $pub = true -}}{{- end -}}
    {{- if has "subscribe" .access -}}{{- $sub = true -}}{{- end -}}
  {{- end -}}
{{- end -}}
{{- $out := list "resetkeys" -}}
{{- $out = concat $out $keys (list "resetchannels") $channels (list "-@all" "+@connection") -}}
{{- if $read -}}{{- $out = append $out "+@read" -}}{{- end -}}
{{- if $write -}}{{- $out = append $out "+@write" -}}{{- end -}}
{{- if $pub -}}{{- $out = append $out "+publish" -}}{{- end -}}
{{- if $sub -}}{{- $out = concat $out (list "+subscribe" "+psubscribe" "+unsubscribe" "+punsubscribe") -}}{{- end -}}
{{- /* scripting: true grants Lua/functions *execution* (still key-restricted) but never the
       cross-tenant management commands. The base is -@all, so it must be granted explicitly. */ -}}
{{- if $u.scripting -}}{{- $out = concat $out (list "+@scripting" "-script|flush" "-function|load" "-function|delete" "-function|flush" "-function|restore") -}}{{- end -}}
{{- $out = concat $out (list "-@dangerous" "-@admin" "-flushall" "-flushdb" "-swapdb" "-keys") -}}
{{- if not $u.scripting -}}{{- $out = append $out "-@scripting" -}}{{- end -}}
{{- $out = concat $out (.extra | default list) ($u.extraRules | default list) -}}
{{- join " " $out -}}
{{- end -}}

{{/* Collapse YAML folded strings into single-spaced rule strings. */}}
{{- define "redis-ha-secure.oneLine" -}}
{{- regexReplaceAll "\\s+" (. | trim) " " -}}
{{- end -}}

{{/*
catalog.tsv consumed by files/acl-build.sh. TAB separated, one line per ACL user.
  infra <TAB> target(redis|sentinel) <TAB> username <TAB> infraKey <TAB> rules
  app   <TAB> username <TAB> namespace <TAB> credentialsSecret <TAB> pwSecret <TAB> pwKey <TAB> redisRules <TAB> sentinelRules
*/}}
{{- define "redis-ha-secure.catalog" -}}
{{- $k := .Values.infraCredentials.keys -}}
{{- $r := .Values.acl.infraRules -}}
{{- $phase := int .Values.acl.phase -}}
{{- $demote := and (eq $phase 2) .Values.acl.phase2.demoteDefault -}}
{{- $haproxy := (index .Values "redis-ha").haproxy.enabled -}}
{{- $sentinelClients := eq (include "redis-ha-secure.sentinelClientAccess" .) "true" -}}
{{- $tab := "\t" -}}
{{- /* ---- Redis ---- */ -}}
{{- if $demote }}
{{ printf "infra%sredis%sdefault%s%s%s%s" $tab $tab $tab $k.default $tab (include "redis-ha-secure.oneLine" $r.redisDefaultPhase2) }}
{{- else }}
{{ printf "infra%sredis%sdefault%s%s%s%s" $tab $tab $tab $k.default $tab (include "redis-ha-secure.oneLine" $r.redisDefaultPhase1) }}
{{- end }}
{{ printf "infra%sredis%sacl-admin%s%s%s%s" $tab $tab $tab $k.aclAdmin $tab (include "redis-ha-secure.oneLine" $r.aclAdmin) }}
{{ printf "infra%sredis%sexporter-user%s%s%s%s" $tab $tab $tab $k.exporter $tab (include "redis-ha-secure.oneLine" $r.exporterUser) }}
{{- if $haproxy }}
{{ printf "infra%sredis%shaproxy-user%s%s%s%s" $tab $tab $tab $k.default $tab (include "redis-ha-secure.oneLine" $r.haproxyUser) }}
{{- end }}
{{- if eq $phase 2 }}
{{ printf "infra%sredis%sreplica-user%s%s%s%s" $tab $tab $tab $k.replica $tab (include "redis-ha-secure.oneLine" $r.replicaUser) }}
{{ printf "infra%sredis%ssentinel-user%s%s%s%s" $tab $tab $tab $k.sentinelUser $tab (include "redis-ha-secure.oneLine" $r.sentinelUser) }}
{{- end }}
{{- if .Values.migration.enabled }}
{{ printf "infra%sredis%smigration-user%s%s%s%s" $tab $tab $tab $k.migration $tab (include "redis-ha-secure.oneLine" $r.migrationUser) }}
{{- end }}
{{- if .Values.dr.backup.enabled }}
{{ printf "infra%sredis%sbackup-user%s%s%s%s" $tab $tab $tab $k.backup $tab (include "redis-ha-secure.oneLine" $r.backupUser) }}
{{- end }}
{{- /* ---- Sentinel ---- */ -}}
{{- if $demote }}
{{ printf "infra%ssentinel%sdefault%s%s%s%s" $tab $tab $tab $k.sentinelDefault $tab (include "redis-ha-secure.oneLine" $r.sentinelDefaultPhase2) }}
{{- else }}
{{ printf "infra%ssentinel%sdefault%s%s%s%s" $tab $tab $tab $k.sentinelDefault $tab (include "redis-ha-secure.oneLine" $r.sentinelDefaultPhase1) }}
{{- end }}
{{ printf "infra%ssentinel%sacl-admin%s%s%s%s" $tab $tab $tab $k.aclAdmin $tab (include "redis-ha-secure.oneLine" $r.sentinelAclAdmin) }}
{{- if $haproxy }}
{{ printf "infra%ssentinel%shaproxy-user%s%s%s%s" $tab $tab $tab $k.default $tab (include "redis-ha-secure.oneLine" $r.sentinelHaproxy) }}
{{- end }}
{{- if eq $phase 2 }}
{{ printf "infra%ssentinel%ssentinel-peer%s%s%s%s" $tab $tab $tab $k.sentinelPeer $tab (include "redis-ha-secure.oneLine" $r.sentinelPeer) }}
{{- end }}
{{- /* ---- Apps ---- */ -}}
{{- $root := . -}}
{{- range .Values.aclUsers }}
{{- $name := include "redis-ha-secure.username" (dict "prefix" $root.Values.acl.usernamePrefix "namespace" .namespace "serviceAccount" .serviceAccount) }}
{{- $cred := include "redis-ha-secure.credentialsSecret" . }}
{{- $pwName := "" }}{{- $pwKey := "password" }}
{{- if .passwordSecret }}{{- $pwName = .passwordSecret.name }}{{- $pwKey = .passwordSecret.key | default "password" }}{{- end }}
{{- $rules := include "redis-ha-secure.appRedisRules" (dict "user" . "extra" $root.Values.acl.appUserExtraRules) }}
{{- $srules := "-" }}
{{- if $sentinelClients }}{{- $srules = include "redis-ha-secure.oneLine" $root.Values.acl.sentinelClientRules }}{{- end }}
{{ printf "app%s%s%s%s%s%s%s%s%s%s%s%s%s%s" $tab $name $tab .namespace $tab $cred $tab (default "-" $pwName) $tab $pwKey $tab $rules $tab $srules }}
{{- end }}
{{- end -}}

{{/* "true" when catalog users are created on the Sentinels (acl.sentinelClientAccess). */}}
{{- define "redis-ha-secure.sentinelClientAccess" -}}
{{- $v := toString .Values.acl.sentinelClientAccess -}}
{{- if eq $v "auto" -}}
{{- (not (index .Values "redis-ha").haproxy.enabled) | toString -}}
{{- else -}}
{{- (eq $v "true") | toString -}}
{{- end -}}
{{- end -}}

{{/* Infra secret keys required for the selected phase. */}}
{{- define "redis-ha-secure.requiredInfraKeys" -}}
{{- $k := .Values.infraCredentials.keys -}}
{{- $keys := list $k.default $k.sentinelDefault $k.aclAdmin $k.exporter -}}
{{- if eq (int .Values.acl.phase) 2 -}}
{{- $keys = concat $keys (list $k.replica $k.sentinelUser $k.sentinelPeer) -}}
{{- end -}}
{{- if .Values.migration.enabled -}}
{{- $keys = append $keys $k.migration -}}
{{- end -}}
{{- if .Values.dr.backup.enabled -}}
{{- $keys = append $keys $k.backup -}}
{{- end -}}
{{- join "\n" $keys -}}
{{- end -}}

{{/* Unique sorted client namespaces derived from the catalog (+ extra). */}}
{{- define "redis-ha-secure.clientNamespaces" -}}
{{- $ns := list -}}
{{- range .Values.aclUsers }}{{- $ns = append $ns .namespace -}}{{- end -}}
{{- range .Values.networkPolicy.extraClientNamespaces }}{{- $ns = append $ns . -}}{{- end -}}
{{- $ns | uniq | sortAlpha | toJson -}}
{{- end -}}

{{/*
maxmemory for redis.conf. Called from the subchart's tpl'd customConfig, so "." is the
SUBCHART context (.Values = redis-ha values, .Values.global shared).
*/}}
{{- define "redis-ha-secure.maxmemory" -}}
{{- $v := toString (index .Values.redis.config "maxmemory") -}}
{{- if ne $v "auto" -}}
{{- $v -}}
{{- else -}}
{{- $limit := required "redis-ha.redis.resources.limits.memory is required when redis.config.maxmemory is auto" ((.Values.redis.resources).limits).memory -}}
{{- $mib := include "redis-ha-secure.toMiB" $limit | float64 -}}
{{- $pct := float64 (((.Values.global).redisSecure).maxmemoryPercent | default 70) -}}
{{- $mb := floor (divf (mulf $mib $pct) 100.0) -}}
{{- if ge $mb 1000.0 -}}{{- $mb = mulf (floor (divf $mb 100.0)) 100.0 -}}{{- end -}}
{{- printf "%dmb" (int64 $mb) -}}
{{- end -}}
{{- end -}}

{{/* Kubernetes quantity -> MiB (float, as string). */}}
{{- define "redis-ha-secure.toMiB" -}}
{{- $q := toString . -}}
{{- $m := regexFind "^[0-9.]+" $q -}}
{{- $unit := trimPrefix $m $q -}}
{{- $n := float64 $m -}}
{{- $f := dict "Ki" (divf 1.0 1024.0) "Mi" 1.0 "Gi" 1024.0 "Ti" 1048576.0 "k" (divf 1000.0 1048576.0) "M" (divf 1000000.0 1048576.0) "G" (divf 1000000000.0 1048576.0) "T" (divf 1000000000000.0 1048576.0) "" (divf 1.0 1048576.0) -}}
{{- if not (hasKey $f $unit) -}}{{- fail (printf "unsupported memory quantity %q" $q) -}}{{- end -}}
{{- mulf $n (get $f $unit) -}}
{{- end -}}

{{/* =========================== Validation =========================== */}}
{{- define "redis-ha-secure.validate" -}}
{{- $sub := index .Values "redis-ha" -}}
{{- $phase := int .Values.acl.phase -}}
{{- if not (has $phase (list 1 2)) -}}{{- fail "acl.phase must be 1 or 2" -}}{{- end -}}

{{- /* chart auth wiring must point at the infra Secret */ -}}
{{- if not $sub.auth -}}{{- fail "redis-ha.auth must be true (default user password = infra Secret)" -}}{{- end -}}
{{- if not $sub.sentinel.auth -}}{{- fail "redis-ha.sentinel.auth must be true (protects Sentinel's default user)" -}}{{- end -}}
{{- if ne (tpl (toString $sub.existingSecret) .) .Values.infraCredentials.secretName -}}{{- fail "redis-ha.existingSecret must equal infraCredentials.secretName" -}}{{- end -}}
{{- if ne (tpl (toString $sub.sentinel.existingSecret) .) .Values.infraCredentials.secretName -}}{{- fail "redis-ha.sentinel.existingSecret must equal infraCredentials.secretName" -}}{{- end -}}
{{- if ne $sub.authKey .Values.infraCredentials.keys.default -}}{{- fail "redis-ha.authKey must equal infraCredentials.keys.default" -}}{{- end -}}
{{- if ne $sub.sentinel.authKey .Values.infraCredentials.keys.sentinelDefault -}}{{- fail "redis-ha.sentinel.authKey must equal infraCredentials.keys.sentinelDefault" -}}{{- end -}}

{{- /* ACL / include wiring in the custom configs */ -}}
{{- $rc := toString $sub.redis.customConfig -}}
{{- $sc := toString $sub.sentinel.customConfig -}}
{{- if not (contains (printf "aclfile %s/users.acl" .Values.acl.redisMountPath) $rc) -}}{{- fail (printf "redis-ha.redis.customConfig must contain 'aclfile %s/users.acl'" .Values.acl.redisMountPath) -}}{{- end -}}
{{- if not (contains (printf "include %s/redis-infra.conf" .Values.acl.redisMountPath) $rc) -}}{{- fail (printf "redis-ha.redis.customConfig must contain 'include %s/redis-infra.conf'" .Values.acl.redisMountPath) -}}{{- end -}}
{{- if not (contains (printf "aclfile %s/sentinel-users.acl" .Values.acl.sentinelMountPath) $sc) -}}{{- fail (printf "redis-ha.sentinel.customConfig must contain 'aclfile %s/sentinel-users.acl'" .Values.acl.sentinelMountPath) -}}{{- end -}}
{{- if not (contains (printf "include %s/sentinel-infra.conf" .Values.acl.sentinelMountPath) $sc) -}}{{- fail (printf "redis-ha.sentinel.customConfig must contain 'include %s/sentinel-infra.conf'" .Values.acl.sentinelMountPath) -}}{{- end -}}
{{- if regexMatch "(?m)^\\s*(requirepass|masterauth|masteruser)\\s" $rc -}}{{- fail "redis-ha.redis.customConfig must not set requirepass/masterauth/masteruser (aclfile + redis-infra.conf own them)" -}}{{- end -}}

{{- /* Secret volumes: directory mounts of the ACL Secret, never subPath */ -}}
{{- $aclVols := list -}}
{{- range $sub.extraVolumes -}}{{- if and .secret (eq (toString .secret.secretName) $.Values.acl.secretName) -}}{{- $aclVols = append $aclVols .name -}}{{- end -}}{{- end -}}
{{- if lt (len $aclVols) 1 -}}{{- fail (printf "redis-ha.extraVolumes must mount Secret %q (acl.secretName)" .Values.acl.secretName) -}}{{- end -}}
{{- range (concat ($sub.redis.extraVolumeMounts | default list) ($sub.sentinel.extraVolumeMounts | default list)) -}}
{{- if and (has .name $aclVols) .subPath -}}{{- fail "ACL Secret volumes must not be mounted with subPath (subPath mounts never receive updates)" -}}{{- end -}}
{{- end -}}

{{- /* rename-command must never hit what Sentinel / probes / reload need */ -}}
{{- $protected := list "CONFIG" "SLAVEOF" "REPLICAOF" "CLIENT" "INFO" "PING" "ROLE" "PUBLISH" "SUBSCRIBE" "MULTI" "EXEC" "SCRIPT" "ACL" "SHUTDOWN" "PSYNC" "REPLCONF" "AUTH" -}}
{{- range $sub.redis.disableCommands -}}
{{- if has (upper .) $protected -}}{{- fail (printf "redis-ha.redis.disableCommands must not rename %s (needed by Sentinel/replication/probes/ACL reload). Use ACLs instead." .) -}}{{- end -}}
{{- end -}}

{{- /* memory: requests == limits */ -}}
{{- $res := $sub.redis.resources | default dict -}}
{{- $req := (($res.requests).memory) -}}{{- $lim := (($res.limits).memory) -}}
{{- if or (not $req) (not $lim) -}}{{- fail "redis-ha.redis.resources.requests.memory and limits.memory are required" -}}{{- end -}}
{{- if ne (include "redis-ha-secure.toMiB" $req) (include "redis-ha-secure.toMiB" $lim) -}}{{- fail "redis-ha.redis.resources: memory requests must equal limits" -}}{{- end -}}

{{- /* Sentinel quorum must be a majority */ -}}
{{- $replicas := int $sub.replicas -}}
{{- if or (lt (int $sub.sentinel.quorum) (add1 (div $replicas 2))) (gt (int $sub.sentinel.quorum) $replicas) -}}{{- fail "redis-ha.sentinel.quorum must be a majority of redis-ha.replicas" -}}{{- end -}}

{{- /* Linkerd injection must match the policy resources */ -}}
{{- if .Values.linkerd.enabled -}}
{{- $pa := $sub.redis.podAnnotations | default dict -}}
{{- if ne (toString (index $pa "linkerd.io/inject")) "enabled" -}}{{- fail "linkerd.enabled requires redis-ha.redis.podAnnotations[linkerd.io/inject]=enabled" -}}{{- end -}}
{{- $op := splitList "," (toString (index $pa "config.linkerd.io/opaque-ports")) -}}
{{- if not (and (has (toString $sub.redis.port) $op) (has (toString $sub.sentinel.port) $op)) -}}{{- fail "config.linkerd.io/opaque-ports must list BOTH the redis and sentinel ports (the annotation replaces the default list)" -}}{{- end -}}
{{- end -}}

{{- /* HAProxy: built-in config authenticates as default -> require the hardened custom config */ -}}
{{- if $sub.haproxy.enabled -}}
{{- $hc := toString $sub.haproxy.customConfig -}}
{{- range (list "haproxy-user" "on-marked-down shutdown-sessions" "init-state down") -}}
{{- if not (contains . $hc) -}}{{- fail (printf "redis-ha.haproxy.enabled requires the hardened haproxy.customConfig from values.yaml (missing %q)" .) -}}{{- end -}}
{{- end -}}
{{- if ne (toString $sub.haproxy.service.type) "ClusterIP" -}}{{- fail "HAProxy must not be exposed outside the cluster (service.type ClusterIP)" -}}{{- end -}}
{{- if $sub.haproxy.tls.enabled -}}{{- fail "redis-ha.haproxy.tls is not supported by this wrapper (Linkerd provides mTLS)" -}}{{- end -}}
{{- $hs := ((.Values.global).redisSecure).haproxy | default dict -}}
{{- $maxclients := int (index $sub.redis.config "maxclients" | default 10000) -}}
{{- $need := add (mul (int $sub.haproxy.replicas) (int ($hs.maxconn | default 3000))) 500 -}}
{{- if gt $need $maxclients -}}{{- fail (printf "redis maxclients (%d) must be >= haproxy.replicas * global.redisSecure.haproxy.maxconn + 500 (= %d): every HAProxy may open maxconn connections to the master" $maxclients $need) -}}{{- end -}}
{{- if lt (int $sub.haproxy.checkFall) 2 -}}{{- fail "redis-ha.haproxy.checkFall must be >= 2 (with on-marked-down shutdown-sessions a single slow check would drop every client connection)" -}}{{- end -}}
{{- if .Values.linkerd.enabled -}}
{{- $hpa := $sub.haproxy.podAnnotations | default dict -}}
{{- if ne (toString (index $hpa "linkerd.io/inject")) "enabled" -}}{{- fail "linkerd.enabled requires redis-ha.haproxy.podAnnotations[linkerd.io/inject]=enabled" -}}{{- end -}}
{{- if not (has (toString $sub.haproxy.containerPort) (splitList "," (toString (index $hpa "config.linkerd.io/opaque-ports")))) -}}{{- fail "redis-ha.haproxy.podAnnotations[config.linkerd.io/opaque-ports] must list haproxy.containerPort" -}}{{- end -}}
{{- end -}}
{{- end -}}

{{- /* Migration */ -}}
{{- if .Values.migration.enabled -}}
{{- if not $sub.haproxy.enabled -}}{{- fail "migration.enabled requires HAProxy mode (RedisShake writes through the HAProxy Service)" -}}{{- end -}}
{{- if not .Values.migration.source.address -}}{{- fail "migration.source.address is required (old cluster's HAProxy host:port)" -}}{{- end -}}
{{- if not .Values.migration.source.passwordSecret.name -}}{{- fail "migration.source.passwordSecret.name is required (pre-created Secret in the release namespace)" -}}{{- end -}}
{{- if not (has (toString .Values.migration.restoreBehavior) (list "panic" "rewrite" "skip")) -}}{{- fail "migration.restoreBehavior must be panic, rewrite or skip" -}}{{- end -}}
{{- end -}}
{{- if not (has (toString .Values.acl.sentinelClientAccess) (list "auto" "true" "false")) -}}{{- fail "acl.sentinelClientAccess must be auto, true or false" -}}{{- end -}}

{{- /* Disaster recovery */ -}}
{{- $dr := .Values.dr -}}
{{- if or $dr.backup.enabled $dr.restore.enabled -}}
{{- if not $dr.storage.remote -}}{{- fail "dr.storage.remote is required (rclone remote:path, e.g. s3:bucket/redis/prod)" -}}{{- end -}}
{{- if not $dr.storage.existingSecret -}}{{- fail "dr.storage.existingSecret is required (pre-created Secret with RCLONE_CONFIG_<REMOTE>_* env vars)" -}}{{- end -}}
{{- end -}}
{{- if $dr.backup.enabled -}}
{{- if not (has (toString $dr.backup.source) (list "replica" "any")) -}}{{- fail "dr.backup.source must be replica or any" -}}{{- end -}}
{{- if lt (int $dr.backup.retention.keepLast) 1 -}}{{- fail "dr.backup.retention.keepLast must be >= 1" -}}{{- end -}}
{{- end -}}
{{- $drInit := list -}}
{{- range ($sub.extraInitContainers | default list) -}}
{{- if hasPrefix "dr-restore-" (toString .name) -}}
{{- $drInit = append $drInit .name -}}
{{- $cmRef := false -}}
{{- range (.envFrom | default list) -}}{{- if and .configMapRef (eq (toString .configMapRef.name) $dr.restore.configMapName) -}}{{- $cmRef = true -}}{{- end -}}{{- end -}}
{{- if not $cmRef -}}{{- fail (printf "redis-ha.extraInitContainers[%s] must use envFrom configMapRef %q (dr.restore.configMapName)" .name $dr.restore.configMapName) -}}{{- end -}}
{{- if and (eq (toString .name) "dr-restore-install") (ne (toString .image) (printf "%s:%s" $sub.image.repository $sub.image.tag)) -}}{{- fail (printf "dr-restore-install image must equal redis-ha.image (%s:%s)" $sub.image.repository $sub.image.tag) -}}{{- end -}}
{{- if eq (toString .name) "dr-restore-fetch" -}}
{{- $secRef := false -}}
{{- range (.envFrom | default list) -}}{{- if and .secretRef (eq (toString .secretRef.name) $dr.storage.existingSecret) -}}{{- $secRef = true -}}{{- end -}}{{- end -}}
{{- if not $secRef -}}{{- fail (printf "dr-restore-fetch must use envFrom secretRef %q (dr.storage.existingSecret)" $dr.storage.existingSecret) -}}{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if $dr.restore.enabled -}}
{{- if not (regexMatch "^[0-9]{8}T[0-9]{6}Z$" (toString $dr.restore.backupId)) -}}{{- fail "dr.restore.backupId must be an explicit backup id like 20261111T101500Z (see <remote>/LATEST). 'latest' is not allowed: every pod must restore the same backup" -}}{{- end -}}
{{- if not (and (has "dr-restore-fetch" $drInit) (has "dr-restore-install" $drInit)) -}}{{- fail "dr.restore.enabled requires the dr-restore-fetch and dr-restore-install init containers (use values-dr-restore.yaml)" -}}{{- end -}}
{{- else if $drInit -}}
{{- fail "redis-ha.extraInitContainers contains dr-restore-* init containers but dr.restore.enabled is false (their ConfigMap would not exist)" -}}
{{- end -}}

{{- /* Catalog */ -}}
{{- $seen := dict -}}
{{- range $i, $u := .Values.aclUsers -}}
{{- if not (and $u.namespace $u.serviceAccount) -}}{{- fail (printf "aclUsers[%d]: namespace and serviceAccount are required" $i) -}}{{- end -}}
{{- if contains "*" $u.namespace -}}{{- fail (printf "aclUsers[%d]: wildcard namespace %q cannot be expressed in Redis ACLs. List every concrete namespace instead (see README 'Wildcard namespaces')" $i $u.namespace) -}}{{- end -}}
{{- if not (regexMatch "^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$" $u.namespace) -}}{{- fail (printf "aclUsers[%d]: invalid namespace %q" $i $u.namespace) -}}{{- end -}}
{{- if not (regexMatch "^[a-z0-9]([-a-z0-9.]{0,251}[a-z0-9])?$" $u.serviceAccount) -}}{{- fail (printf "aclUsers[%d]: invalid serviceAccount %q" $i $u.serviceAccount) -}}{{- end -}}
{{- $key := printf "%s/%s" $u.namespace $u.serviceAccount -}}
{{- if hasKey $seen $key -}}{{- fail (printf "aclUsers: duplicate entry %s" $key) -}}{{- end -}}
{{- $_ := set $seen $key true -}}
{{- if not $u.redis -}}{{- fail (printf "aclUsers[%d] (%s): at least one redis rule is required" $i $key) -}}{{- end -}}
{{- if $u.passwordSecret -}}{{- if not $u.passwordSecret.name -}}{{- fail (printf "aclUsers[%d]: passwordSecret.name is required" $i) -}}{{- end -}}{{- end -}}
{{- range $u.redis -}}
  {{- if and .keyPrefix .channel -}}{{- fail (printf "%s: a rule has either keyPrefix or channel, not both" $key) -}}{{- end -}}
  {{- if not .access -}}{{- fail (printf "%s: access is required on every rule" $key) -}}{{- end -}}
  {{- if .keyPrefix -}}
    {{- if not (regexMatch "^[A-Za-z0-9][A-Za-z0-9:._{}/@-]*$" .keyPrefix) -}}{{- fail (printf "%s: invalid keyPrefix %q (no glob characters, whitespace or '|')" $key .keyPrefix) -}}{{- end -}}
    {{- range .access -}}{{- if not (has . (list "read" "write")) -}}{{- fail (printf "%s: keyPrefix access must be read/write, got %q" $key .) -}}{{- end -}}{{- end -}}
  {{- else if .channel -}}
    {{- if not (regexMatch "^[A-Za-z0-9][A-Za-z0-9:._{}/@*-]*$" .channel) -}}{{- fail (printf "%s: invalid channel %q (must start with a letter/digit, so it can never match __sentinel__:hello)" $key .channel) -}}{{- end -}}
    {{- range .access -}}{{- if not (has . (list "publish" "subscribe")) -}}{{- fail (printf "%s: channel access must be publish/subscribe, got %q" $key .) -}}{{- end -}}{{- end -}}
  {{- else -}}
    {{- fail (printf "%s: every redis rule needs keyPrefix or channel" $key) -}}
  {{- end -}}
{{- end -}}
{{- range $u.extraRules -}}{{- if regexMatch "\\s|\\t" . -}}{{- fail (printf "%s: extraRules entries must be single ACL tokens" $key) -}}{{- end -}}{{- end -}}
{{- end -}}
{{- end -}}
