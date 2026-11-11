# redis-ha-secure

A production-grade, GitOps-friendly wrapper chart around
[DandyDeveloper `redis-ha`](https://github.com/DandyDeveloper/charts/tree/master/charts/redis-ha)
**4.39.0** (pinned) for Redis **8.8.4**. It runs 3 Redis nodes (1 master + 2 replicas)
and 3 Sentinels (quorum 2) on Kubernetes with Linkerd.

What this chart adds on top of the upstream chart:

- **Declarative ACL catalog.** One Redis ACL user per Kubernetes ServiceAccount
  (`system.serviceaccount.<ns>.<sa>`). The same user also exists on the Sentinels for discovery.
- **Hot ACL reload without pod restarts.** One Secret holds the ACL files and is mounted
  as a directory (no `subPath`). A hook Job runs `ACL LOAD` on every node and verifies the result.
- **Phased migration of infrastructure users.** `acl.phase` 1 → 2 is applied at runtime
  without restarts or failovers.
- **Network and mesh policy.** NetworkPolicy, plus Linkerd `Server` / `MeshTLSAuthentication` /
  `AuthorizationPolicy` resources derived from the catalog.
- **Hardening and observability.** Pod hardening, an exporter that logs in as a least-privilege
  user, PrometheusRules, and an ACL drift-check CronJob.
- **Disaster recovery.** Hourly, verified, off-cluster RDB backups taken from a replica, and a
  GitOps bootstrap restore that rebuilds an empty cluster from a pinned backup id.

The chart does not fork upstream. Everything goes through upstream's own values and extension points:
`redis.customConfig`, `sentinel.customConfig`, `extraVolumes`, `redis.extraVolumeMounts`,
`sentinel.extraVolumeMounts`, `extraContainers`, and `haproxy.customConfig`.

```
charts/redis-ha-secure/
  Chart.yaml               dependency redis-ha 4.39.0 (vendored in charts/)
  values.yaml              documented defaults (no secrets)
  values-phase1.yaml       acl.phase: 1
  values-phase2.yaml       acl.phase: 2
  values-haproxy.yaml      HAProxy mode (clients connect through HAProxy only)
  values-dr-restore.yaml   DR bootstrap restore overlay (init containers on every Redis pod)
  files/                   job scripts (build, reload, drift, lib, wait-for-mount, dr-*)
  templates/
    acl-build-hook.yaml    pre-install/pre-upgrade: RBAC + catalog + ACL build Job
    acl-ops.yaml           SA/Role for the reload + drift jobs, scripts ConfigMap
    acl-reload-job.yaml    post-install + pre-upgrade/pre-rollback: ACL LOAD on every node
    migration.yaml         RedisShake live migration from the old cluster (migration.enabled)
    dr.yaml                DR backup CronJob (dr.backup) + restore ConfigMap (dr.restore)
    acl-drift-cronjob.yaml ACL drift check
    networkpolicy.yaml     NetworkPolicy
    linkerd-policy.yaml    Server / MeshTLSAuthentication / AuthorizationPolicy
    monitoring.yaml        PodMonitor + PrometheusRule
scripts/                   test scripts 01-09, rotate-password.sh, ci/ (kind, docker-desktop, legacy values)
```

---

## 1. Architecture

```
                      workload namespaces (catalog)                         monitoring
   orders/orders-api ─┐   reporting/report-reader ─┐                         Prometheus
     Secret redis-acl-orders-api          Secret reporting-redis (ESO)            │ 9121
                      │ mTLS (Linkerd, SA identity)  │                             │
                      ▼                              ▼                             ▼
 ┌──────────────────────── namespace redis ─────────────────────────────────────────────┐
 │  NetworkPolicy: 6379/26379 only from {redis pods, ops jobs, catalog ns, monitoring}   │
 │  Linkerd Server(opaque) + AuthorizationPolicy: intra SAs + catalog SAs only           │
 │                                                                                      │
 │  pod server-0 (master)     pod server-1 (replica)      pod server-2 (replica)        │
 │  ┌─ redis  6379 ──────┐    ┌─ redis ────────────┐      ┌─ redis ────────────┐        │
 │  │ aclfile users.acl  │◄───┤ masteruser/auth    │      │ ...                │        │
 │  ├─ sentinel 26379 ───┤    ├─ sentinel ─────────┤      ├─ sentinel ─────────┤        │
 │  │ aclfile sentinel-  │◄──►│ auth-user/pass     │◄────►│ sentinel-user/pass │        │
 │  │   users.acl        │    ├─ split-brain-fix   │      ├─ ...               │        │
 │  ├─ redis_exporter (exporter-user)              │      │                    │        │
 │  ├─ acl-watch (reports mounted revision)        │      │                    │        │
 │  └─ linkerd-proxy ────┘    └────────────────────┘      └────────────────────┘        │
 │         ▲ directory mount (no subPath) of ONE Secret "redis-ha-acl":                 │
 │         │ users.acl, sentinel-users.acl, redis-infra.conf, sentinel-infra.conf       │
 │  ┌──────┴───────────┐  pre-install/upgrade        ┌───────────────────────────┐      │
 │  │ acl-build Job    │ ──────────────────────────► │ acl-reload Job (post hook)│      │
 │  │ kubectl: hashes  │  writes Secret              │ wait mount → stage →      │      │
 │  │ passwords, writes│                             │ switch auth → ACL LOAD →  │      │
 │  │ per-app Secrets  │                             │ verify ACL LIST           │      │
 │  └──────────────────┘                             └───────────────────────────┘      │
 │  acl-drift CronJob: ACL LIST of every node == each other == expected file            │
 └──────────────────────────────────────────────────────────────────────────────────────┘
```

### Topology and availability
- `replicas: 3`, `sentinel.quorum: 2` (validated: must be a majority).
- `hardAntiAffinity: true`: Redis/Sentinel pods are spread over distinct nodes
  (`requiredDuringScheduling…`, topologyKey hostname). In addition,
  `topologySpreadConstraints` spreads them over zones as a soft constraint.
- `podDisruptionBudget.maxUnavailable: 1` uses the chart's native PDB, so no duplicate wrapper template is needed.
- Image `redis:8.8.4-alpine`. This is the latest patch of the chart's 8.8 line. It fixes the Lua
  CVEs (CVE-2025-49844 "RediShell" and CVE-2025-46817/46818/46819, all fixed in ≥ 8.2.2) and
  includes 8.8.1–8.8.4 security fixes. Two of those matter directly here: the ACL key-permission
  bypass in SORT/GEORADIUS/XREAD, and MULTI/EXEC still running after ACL revocation. Redis 8.10.3
  is the newest minor, but the chart is tested against 8.8. Pin by digest in production.

### Client access modes: direct (Sentinel-aware) or HAProxy
Both modes are supported. **HAProxy mode** (`-f values-haproxy.yaml`) matches the current production setup and is fully tested.

| | Direct (default) | HAProxy mode |
|---|---|---|
| Client requirement | Sentinel-aware client | any Redis client: one address (`redis-address` in the credential Secret) |
| Who can reach Redis/Sentinel | catalog SAs (Linkerd + NetworkPolicy) | **only HAProxy, Redis pods and ops Jobs**. Clients reach HAProxy only and have no Sentinel account. |
| Per-service authorization | Linkerd: "is a catalog SA"; Redis ACL: per user | the same. Linkerd checks catalog SAs at HAProxy, and Redis ACLs apply per user through the TCP proxy. |
| Extra cost | none | +1 hop, +1 Deployment, HAProxy sees client traffic in plaintext (Linkerd mTLS ends at its sidecar) |

**Not possible: binding a ServiceAccount to its ACL user through HAProxy.** In TCP mode HAProxy can only
inspect the first command. Redis exempts `AUTH`/`HELLO` from ACL checks (they are `no-auth` commands), so a
client could re-`AUTH` as another user later on the same connection. With a stolen password, a catalog SA
could therefore act as another catalog user. This is equally true in direct mode, where Linkerd's policy is
also the union of catalog SAs. Real binding needs Redis to know the client's certificate identity
(Redis-native TLS + per-SA client certs), which is out of scope here.

**Hardened HAProxy config** (`redis-ha.haproxy.customConfig`, knobs in `global.redisSecure.haproxy`,
syntax-checked with `haproxy -c` against the real 3.3.17 binary in test 01):
- Health checks authenticate as `haproxy-user` (Redis: `+ping +info +role`; Sentinel:
  `+ping +sentinel|get-master-addr-by-name`), never as `default`. The chart only injects `$AUTH`,
  so `haproxy-user` shares the `default-password` *secret* while being a separate least-privilege *identity*.
  Sentinel checks never send `QUIT` (Redis 8 Sentinel: unknown command ? check never passes).
- `init-state down`: no traffic to a server before its first successful check. The built-in config
  briefly routes to replicas when HAProxy starts.
- `on-marked-down shutdown-sessions`: when the old master is demoted, HAProxy closes its client sessions
  so clients reconnect to the new master instead of getting `READONLY` until they reconnect.
- **Quorum routing**: new connections are refused unless a node is role:master **and** ≥ 2 Sentinels agree.
  Existing connections are not touched.
- **Readiness gate**: `/healthz` returns 503 until HAProxy could route once (the exact routing condition),
  then always 200 (failovers never fail liveness). A broken config (e.g. wrong check user) never becomes
  Ready, and the rollout (`maxSurge 1, maxUnavailable 1`) stalls while the other pods keep serving.
  Trade-off: upstream uses the same `/healthz` for liveness, so on a **cold start** (no Redis master yet)
  HAProxy restarts a few times (about 5 on docker-desktop) until Redis is up. That is harmless, but
  `global.redisSecure.haproxy.readinessRequiresMaster: false` turns the gate off if it bothers you.
- `checkFall: 2` (validated ≥ 2: with shutdown-sessions a single slow check must not drop all clients),
  TCP keepalive both sides, `timeout tunnel 12h` (idle pub/sub), `maxconn` validated against Redis
  `maxclients`, a 10 s preStop drain, built-in Prometheus exporter (PodMonitor + alerts).

**Failover through HAProxy, measured** (test 07, single persistent connection writing every 100 ms):
the old session was closed by HAProxy ~12 s after `SENTINEL FAILOVER` with **0 `READONLY` errors**.
In that window the old master answered `NOREPLICAS` (`min-replicas-to-write 1`: refused, not lost). About
**1 s of acknowledged writes was lost**: Redis's asynchronous-replication window during any Sentinel
failover, independent of HAProxy. Use `WAIT 1 <ms>` after critical writes if that is unacceptable.

### Memory
- `redis.resources.requests.memory == limits.memory` (validated, Guaranteed QoS).
- `redis.config.maxmemory: auto` computes 70 % of the limit (`global.redisSecure.maxmemoryPercent`).
  Results ≥ 1000mb are rounded down to 100mb. Examples: 4Gi → **2800mb**, 8Gi → 5700mb, 1Gi → 716mb, 512Mi → 358mb.
  The remaining 30 % covers fork copy-on-write (BGSAVE, AOF rewrite, full sync), replica and
  client output buffers (`client-output-buffer-limit replica 256mb 64mb 60` is part of it),
  and allocator fragmentation.
- `maxmemory-policy` defaults to `noeviction`, which is safe for persistent data: writes fail with OOM and
  alert `RedisOutOfMemoryErrors` fires. Other choices:
  - `allkeys-lru` / `allkeys-lfu` for a pure cache (enables `RedisEvictingKeys`).
  - `volatile-lru` for mixed use: only keys with a TTL are evicted.
  
  `maxmemory-samples 10`.
- Every node renders the same `redis.conf`, so all memory settings are identical. Test 02 asserts this on the live cluster.
  A replica therefore cannot hit OOM before its master.

### Persistence
AOF (`appendonly yes`, `appendfsync everysec`, RDB preamble) loses at most about 1 s of writes.
Periodic RDB snapshots (`save 3600 1 300 100 60 10000`) give fast restarts and backups.
`repl-diskless-sync yes` avoids an extra disk write on full syncs. `min-replicas-to-write 1`
plus `min-replicas-max-lag 10` limits write loss when the master is partitioned.
Local persistence is **not** a backup: it lives on the same PVCs, and a `FLUSHALL` or bad
deploy replicates to every node. See [Disaster recovery](#disaster-recovery).

### Pod hardening
`runAsNonRoot`, uid/gid 1000, `readOnlyRootFilesystem` (only `/data` on the PVC is written),
`allowPrivilegeEscalation: false`, `drop: [ALL]`, seccomp `RuntimeDefault` on every container
(chart containers, exporter, acl-watch, jobs). Each pod has a dedicated ServiceAccount with
`automountServiceAccountToken: false`. The chart Role is disabled (`rbac.create: false`) because nothing in the pod uses the API.
Every container has resource limits, including Sentinel, split-brain-fix, init, exporter,
acl-watch, HAProxy and the Linkerd proxy (via annotations). `scripts/ci/check-limits.py` enforces this in test 01.

### Network and mesh
- **NetworkPolicy** (`templates/networkpolicy.yaml`; the chart's own is disabled). Ingress to
  6379/26379 is allowed only from the Redis pods themselves, the release's ops Jobs, the
  namespaces derived from `aclUsers` (plus `networkPolicy.extraClientNamespaces`), and
  monitoring (9121, Linkerd 4191). Port 4143 is also allowed because Linkerd's *opaque transport* sends meshed
  opaque-port traffic to the proxy's inbound port. Egress allows DNS, Redis peers and the Linkerd control plane.
- **Linkerd.**
  - Pods are injected with `config.linkerd.io/opaque-ports: "6379,26379"`. The annotation *replaces*
    the default list, so the chart refuses to render if either port is missing.
  - `Server` resources (opaque) for 6379/26379, plus HTTP for the exporter.
  - `MeshTLSAuthentication` `-intra` (Redis SA, ops-Job SA, HAProxy SA) and `-clients` (one identity per catalog entry).
  - An `AuthorizationPolicy` per Server.
  - Jobs are meshed with native sidecars (`config.linkerd.io/proxy-enable-native-sidecar`) so they can complete.
- **Sentinel addresses and the mesh.** The chart announces the per-pod **ClusterIP services**
  (`<release>-redis-ha-announce-N`), not pod IPs (`slave-announce-ip` / `sentinel announce-ip`).
  Replication, Sentinel gossip and client connections therefore go to Service IPs that Linkerd
  resolves to the right pod with full mTLS identity. Because the inbound proxy makes connections
  appear to come from localhost, nothing in Redis/Sentinel relies on source addresses.
- No LoadBalancer, NodePort or Ingress (asserted in test 01). `protected-mode yes` is set on Redis and Sentinel.
- **Redis-native TLS is not used.** Linkerd provides mTLS with workload identity on every hop,
  including replication and Sentinel gossip, and Redis TLS would double the crypto cost. Enable
  `redis.tlsPort` only if traffic can bypass the mesh (unmeshed clients). In that case make the
  Servers `proxyProtocol: opaque` without mTLS requirements.

---

## 2. ACL design

Redis does not replicate ACLs, and Sentinel does not propagate them. One file is therefore the
single source of truth and is loaded by every node:

| Secret `redis-ha-acl` key | Used by | Contents |
|---|---|---|
| `users.acl` | `aclfile` of every Redis node | all users, `#<sha256>` hashes, every line starts with `reset` |
| `sentinel-users.acl` | `aclfile` of every Sentinel | Sentinel `default`, `acl-admin`, `sentinel-peer`, catalog users (discovery only) |
| `redis-infra.conf` | `include` in redis.conf | `masteruser` / `masterauth` |
| `sentinel-infra.conf` | `include` in sentinel.conf | `sentinel auth-user/auth-pass`, `sentinel sentinel-user/sentinel-pass` |

How the files are consumed:

- The Secret is mounted as a directory (no `subPath`), so kubelet propagates updates. The chart refuses a `subPath`.
- Because `aclfile` is set, it is the only source of users and `requirepass` is ignored.
  The file therefore always defines `default`.
- Plaintext lives only in Secrets: the infra Secret and the per-consumer Secrets. Hashes are computed by the
  build Job in a memory-backed `emptyDir` and are never in git.
- The first line of each file is a revision marker: `user acl-revision reset off … #<sha256(body+include)>`.
  It lets the Jobs prove which revision kubelet mounted (via the `acl-watch` sidecar) and which
  revision each node loaded (via `ACL LIST`).

### Catalog → rules
```yaml
aclUsers:
  - namespace: orders
    serviceAccount: orders-api
    passwordSecret: { name: redis-acl-orders-api, key: password }   # optional (ESO). Otherwise generated once
    redis:
      - keyPrefix: "orders:"
        access: [read, write]        # read -> %R~  write -> %W~  both -> ~
      - channel: "orders.events.*"
        access: [publish, subscribe]
```
renders the following line (shown by `helm template`, ConfigMap `catalog.tsv`):
```
user system.serviceaccount.orders.orders-api reset on #<sha> resetkeys ~orders:* resetchannels &orders.events.*
     -@all +@connection +@read +@write +publish +subscribe +psubscribe +unsubscribe +punsubscribe
     -@dangerous -@admin -flushall -flushdb -swapdb -keys -@scripting
```
- `scripting: true` grants `+@scripting` (EVAL/EVALSHA/FCALL, still key-restricted) but always denies
  `SCRIPT FLUSH` and `FUNCTION LOAD/DELETE/FLUSH/RESTORE` (cross-tenant). Otherwise `-@scripting` is
  added. `extraRules` / `acl.appUserExtraRules` are appended.
- Channel patterns must start with a letter or digit, so they can never match `__sentinel__:hello`
  (the Sentinel docs warn about forged hello messages).
- Wildcard namespaces (`project-*`) cannot be expressed in Redis ACLs and are **rejected** at
  render time. To serve several namespaces, list each concrete `namespace` / `serviceAccount` pair. Each pair is a separate ACL
  user, Linkerd identity and NetworkPolicy peer. If you generate values from a namespace list, do that expansion
  in the GitOps layer (for example an ApplicationSet / Kustomize generator), not in Redis.

### Credential delivery (phase 1 design)
- **Generated:** if `passwordSecret` is omitted, the build Job creates
  `redis-acl-<sa>` in the workload namespace **once**. It holds `username`, `password`, `sentinel-master-name`,
  `sentinel-addresses` and `redis-address` (HAProxy only). It is never regenerated. A transient API read error aborts the Job
  instead of being treated as "missing".
- **Pre-created / External Secrets:** `passwordSecret: {name, key}` is only read. Add a
  `username` key via the ExternalSecret `target.template` (the Job warns if it is absent).
- The build Job's ServiceAccount gets a Role in each catalog namespace, restricted to those Secret
  names (`create` cannot be name-restricted). The namespaces must exist before install.
- Credential Secrets are not deleted when a user leaves the catalog. Delete them explicitly.

**Future migration to Vault static roles.** Vault's Redis database plugin (`database/static-roles`)
can own each app user's password and rotate it. The plugin talks to **one** Redis host and
issues `ACL SETUSER` there. Because ACLs are not replicated, a rotation would only reach one node,
and a failover would expose stale ACLs. Before adopting it, validate one of the following:

1. Vault calls a fan-out endpoint. HAProxy is not suitable because it only routes to the master.
2. Vault rotates into the per-consumer Secret (Vault Secrets Operator / ESO). The existing
   build/reload pipeline then distributes the new hash. This keeps the file as the single
   source of truth and is the recommended path.

Sentinel discovery users would also need to be covered.

### Infrastructure users and phases (`acl.phase`)

| User | Phase 1 | Phase 2 |
|---|---|---|
| Redis `default` | `~* resetchannels &__sentinel__:hello +@all` (chart auth secret). Used only by Sentinel, replication and chart probes | `resetkeys resetchannels -@all +ping +role +info +shutdown`: probe-only identity |
| `replica-user` | — | `+psync +replconf +ping`. `masteruser`/`masterauth` on **every** node (any node can become a replica) |
| `sentinel-user` | — | `&__sentinel__:hello +multi +slaveof +ping +exec +subscribe +config\|rewrite +role +publish +info +client\|setname +client\|kill +script\|kill`. `sentinel auth-user/auth-pass` on **every** Sentinel |
| `sentinel-peer` (on Sentinels) | — (peers use `requirepass` = Sentinel `default`) | `&__sentinel__:hello +ping +publish +client\|setname +sentinel\|is-master-down-by-addr` via `sentinel sentinel-user/sentinel-pass` |
| Sentinel `default` | `+@all` with password (`sentinel.auth`) | `+ping +sentinel\|get-master-addr-by-name +sentinel\|failover +sentinel\|reset`: probe-only |
| `exporter-user` | redis_exporter 8.8+ rule set, minus `+eval` and wildcard `+client` | same |
| `haproxy-user` | `+ping +info +role +auth` (+ Sentinel get-master-addr) when HAProxy is enabled | same |
| `acl-admin` | `ACL LOAD/LIST/SETUSER/DRYRUN/LOG`, `CONFIG GET/SET/REWRITE`, `CLIENT LIST/KILL`, Sentinel admin subset | same |
| catalog users on Sentinels | discovery only: `+sentinel\|get-master-addr-by-name +sentinel\|master(s) +sentinel\|replicas +sentinel\|sentinels`, `SUBSCRIBE +switch-master` | same |

**Why `default` is demoted rather than switched `off` (accepted design decision).** In redis-ha 4.39.0, all built-in
scripts call `redis-cli -a "$AUTH"`, which always authenticates as `default`. That includes the
liveness/readiness/startup probes, the init container's master PING, the preStop failover hook and split-brain-fix (INFO, SHUTDOWN).
redis-cli has no environment variable for a username, and the scripts are not exposed in values. Setting `default off` would leave pods
permanently unready and put split-brain-fix into a reinit loop. Overriding the scripts would be a fork.
In phase 2, `default` is therefore a password-protected identity with **only the probe commands**. It has no keys, no
channels, and no CONFIG/ACL/SLAVEOF/PSYNC/PUBLISH. Unauthenticated connections are rejected (NOAUTH).
Sentinel's `default` is handled the same way. Test 04 proves all of this.

**Guard rails against known failure modes:**

| Failure mode | Guard |
|---|---|
| redis/redis#11063: `default` disabled without `sentinel auth-user/auth-pass` breaks failover | The build Job refuses to demote `default` unless `sentinel-infra.conf` has `auth-user` and `auth-pass` and `masteruser` is set. The reload Job switches Sentinel/replication to the new users, then **proves via `CLIENT LIST`** that every Sentinel link authenticates as `sentinel-user`/`sentinel-peer` and every replica as `replica-user`. Only after that does it run the `ACL LOAD` that demotes `default`. |
| redis/redis#9772: a Sentinel user missing a command silently breaks failover | Before touching the cluster, the reload Job loads the new files into a **throw-away local redis-server and redis-sentinel**. It aborts on syntax errors (which would otherwise crash-loop pods on their next restart) and runs `ACL DRYRUN` for every command Sentinel, replicas, probes, the exporter and the Jobs need (`SLAVEOF`, `CONFIG REWRITE`, `CLIENT KILL`, `SCRIPT KILL`, `PUBLISH/SUBSCRIBE __sentinel__:hello`, `PSYNC`, `REPLCONF`, `SENTINEL IS-MASTER-DOWN-BY-ADDR`, …). |
| `rename-command` breaking Sentinel | `disableCommands: []` (ACL denial instead). The chart refuses to rename CONFIG, SLAVEOF/REPLICAOF, CLIENT, INFO, PING, ROLE, PUBLISH, SUBSCRIBE, MULTI/EXEC, SCRIPT, ACL, SHUTDOWN, PSYNC, REPLCONF and AUTH. |

### Reload mechanism (no restarts, no failover)
`acl-reload` Job runs as **post-install** and **pre-upgrade / pre-rollback** (Argo CD: PostSync / PreSync). On upgrades it runs *before* workloads change, so new identities (`haproxy-user` when HAProxy is enabled, `migration-user`) are live before `helm --wait` waits for the pods that use them. Running it post-upgrade deadlocked in testing: HAProxy could not become Ready without `haproxy-user`. Steps:
1. Init container `wait-for-mount` reads `kubectl logs -c acl-watch` of every Redis pod (RBAC: `get` on
   `pods/log` for exactly those pod names). It waits until kubelet has mounted the new revision, so
   `ACL LOAD` can never load a stale file. A secret-volume update typically takes up to 60–90 s.
2. Preflight on throw-away local instances: parse the files, run the `ACL DRYRUN` matrix, and compute the expected normalized `ACL LIST`.
3. Stage the identities the target phase uses with `ACL SETUSER` on every node. Switch runtime auth with
   `CONFIG SET masteruser/masterauth`, `SENTINEL SET <m> auth-user/auth-pass` and
   `SENTINEL CONFIG SET sentinel-user/sentinel-pass`. Re-link changed replicas one at a time
   (`CLIENT KILL TYPE master` → partial resync), then verify via `CLIENT LIST`.
4. `ACL LOAD` on every Redis node and every Sentinel through the headless service
   (`<pod>.<release>-redis-ha.<ns>.svc`). Retry until the revision marker matches.
5. Verify `ACL LIST` is byte-identical on all nodes **and** equal to the expected file.
6. `CONFIG REWRITE` to persist runtime auth, check `CKQUORUM` on every Sentinel, and confirm replication links are up.

**Manual ACL reload** (same checks as the Job):
```bash
kubectl -n redis delete job redis-redis-ha-acl-reload --ignore-not-found
helm template redis charts/redis-ha-secure -n redis -f <same values> --show-only templates/acl-reload-job.yaml \
  | kubectl -n redis apply -f -
kubectl -n redis logs -f job/redis-redis-ha-acl-reload -c acl-reload
```
Raw equivalent, for emergencies only. Wait until every pod's `acl-watch` log shows the new revision first.
```bash
PW=$(kubectl -n redis get secret redis-ha-infra-credentials -o jsonpath='{.data.acl-admin-password}' | base64 -d)
for i in 0 1 2; do for port in 6379 26379; do
  kubectl -n redis exec redis-redis-ha-server-$i -c redis -- sh -c \
    "REDISCLI_AUTH='$PW' redis-cli --no-auth-warning --user acl-admin -p $port ACL LOAD"
done; done
for i in 0 1 2; do kubectl -n redis exec redis-redis-ha-server-$i -c redis -- sh -c \
  "REDISCLI_AUTH='$PW' redis-cli --no-auth-warning --user acl-admin ACL LIST" | sha256sum; done   # must be identical
```

**Drift check.** The `acl-drift` CronJob (every 15 min) compares the following and fails on any
difference, which raises alert `RedisAclDriftCheckFailed`:
- `ACL LIST` of every node and Sentinel against each other and against the expected file (normalized through a local instance)
- the loaded revision against the Secret's revision
- the mounted revision against the Secret's revision
- phase-2 runtime auth (`masteruser`, Sentinel connections not authenticated as `default`)

---

## 3. Operations

### Install
```bash
kubectl create namespace redis
# Namespaces listed in aclUsers must exist. Pre-create passwordSecret Secrets (ESO) if used.
# Infra credentials: generated once by the build Job (infraCredentials.generate: true), or
# pre-create Secret redis-ha-infra-credentials with keys default-password,
# sentinel-default-password, acl-admin-password, exporter-password
# (+ replica-password, sentinel-user-password, sentinel-peer-password for phase 2).
helm dependency build charts/redis-ha-secure
helm upgrade --install redis charts/redis-ha-secure -n redis \
  -f charts/redis-ha-secure/values.yaml -f charts/redis-ha-secure/values-phase1.yaml -f env/prod/catalog.yaml \
  --wait --timeout 20m
```
**Argo CD:** point an Application at `charts/redis-ha-secure` with these value files. Helm hooks
map to PreSync (build) and PostSync (reload). The ACL and credential Secrets are created by the
Job and are not part of the rendered manifests, so Argo never diffs or prunes them.

### Runbook: phase 1 → 2
1. Preconditions: test 02 is green, `SENTINEL CKQUORUM` is OK, and no client uses `default` (check `CLIENT LIST`
   for `user=default` connections other than short probe connections). Make sure **every client
   authenticates with its own catalog user**.
2. Provide the phase-2 infra keys (`replica-password`, `sentinel-user-password`,
   `sentinel-peer-password`) in the infra Secret, or let the build Job generate them.
3. Optional cautious step: deploy `values-phase2.yaml` with `--set acl.phase2.demoteDefault=false`.
   This adds the dedicated users and switches replication and Sentinel to them while `default` keeps full rights.
   Run `PHASE=2 scripts/05-failover-test.sh`.
4. Deploy `values-phase2.yaml` (`demoteDefault: true`). The reload Job stages, switches, verifies
   (`CLIENT LIST`), then demotes `default`. If any verification fails, it aborts **before** the ACL LOAD
   and `default` keeps its rights.
5. Validate with `PHASE=2 scripts/04-default-user-rejected.sh` and `PHASE=2 scripts/05-failover-test.sh`.
6. Rollback: deploy `values-phase1.yaml`. The Job restores `default` first, switches auth back, then loads.

### Runbook: migration from the existing redis-ha + HAProxy (fresh install next to it)
1. Install this chart as a **new release in a new namespace** (`values-haproxy.yaml` + `values-phase1.yaml` + catalog).
   The old cluster is untouched.
2. Put the old `requirepass` into a Secret in the new namespace. Then enable
   `migration.enabled: true`, `migration.source.address: <old-release>-redis-ha-haproxy.<old-ns>.svc:6379`,
   and `migration.source.passwordSecret`. RedisShake replicates from the old master (PSYNC: RDB, then the live stream)
   into the new cluster through HAProxy as `migration-user` (no admin/flush/pub-sub/scripting). `PUBLISH` is never replayed.
   If the old cluster has Linkerd policies or NetworkPolicies, allow the `<release>-redis-ha-migration` ServiceAccount to its HAProxy.
3. Verify: `INFO keyspace` equal per DB, spot-check values, and the live counter follows (test 08 automates this).
4. Cutover:
   - **Big-bang (recommended):** freeze writers, wait until counters match, then switch apps to their catalog credentials
     (`redis-address`, `username`, `password` from `redis-acl-<sa>`).
   - **Per app:** possible only when apps own disjoint key prefixes. Add the app's prefixes to
     `migration.filter.blockKeyPrefixes` when it switches.
5. Disable migration (`migration.enabled: false`). The Deployment is removed and `migration-user` is revoked on every node.
   Decommission the old release when ready.
- **Streams:** RedisShake 4.7.0 cannot parse the Redis 8.x stream RDB encoding (type 27). It aborts the sync and
  retries every 15 s. Before migrating, check `SCAN 0 TYPE stream` on the source. Copy stream keys by hand
  (`XRANGE` → `XADD`) after the freeze, or use a RedisShake release that supports the encoding.
- A RedisShake restart re-copies everything (`restoreBehavior: rewrite`). Keys deleted on the source between
  runs remain on the target, so compare key counts after a restart.

### Runbook: adding a user
1. Add an entry to `aclUsers` (concrete namespace, ServiceAccount, prefixes/channels) in git.
2. Sync / `helm upgrade`. The build Job creates `redis-acl-<sa>` in the workload namespace (or reads
   your ESO Secret). The reload Job loads it on every node. NetworkPolicy and Linkerd identities update automatically.
3. Mount the Secret in the workload and configure a Sentinel-aware client with `sentinel-addresses`,
   `sentinel-master-name`, `username` and `password` (the same credentials work for the Sentinels).
4. Verify with `scripts/03-acl-dryrun.sh`.

### Runbook: password rotation (dual-password window, via Secret + ACL LOAD)
| Step | Action | Redis-level equivalent |
|---|---|---|
| 1 | `scripts/rotate-password.sh start <ns> <secret>` sets `password-previous` to the old value and `password` to a new one, then `helm upgrade` / sync | `ACL SETUSER u >new` on **every** node (both hashes are in the file) |
| 2 | Roll out the workload so clients read the new `password` | — |
| 3 | `scripts/rotate-password.sh finish <ns> <secret>` deletes `password-previous`, then `helm upgrade` / sync | `ACL SETUSER u <old` on **every** node |

- ESO-managed Secrets: perform steps 1 and 3 in the secret store using `<key>` and `<key>-previous`.
- Infra users: rotate `<name>-password` with `<name>-password-previous` in the infra Secret. The reload Job also updates
  `masterauth` and Sentinel `auth-pass`/`sentinel-pass` at runtime. `acl-admin` falls back to `-previous` during the window.
- Never run `ACL SETUSER`/`ACL SAVE` by hand. The file is read-only and the next `ACL LOAD` reverts manual changes,
  and the drift check flags them.

### Failover test procedure
`scripts/05-failover-test.sh` (run it in both phases):
1. Record the master and the `ACL LIST` digest of every node.
2. `SENTINEL FAILOVER mymaster` (as `acl-admin` on a Sentinel).
3. Wait for a new master address. All 3 Sentinels must agree, the new master must show `connected_slaves:2`, and the old master must re-join as a replica.
4. The `ACL LIST` digest must be identical on all nodes and equal to the pre-failover digest (ACLs come from the file, not replication).
5. In phase 2, replicas must be linked as `replica-user` and no Sentinel link may use `default`.
6. App users perform Sentinel discovery from their own namespaces (NetworkPolicy and the Linkerd path),
   write to the new master, and still get NOPERM where expected.

### Disaster recovery

#### What protects against what

| Failure | Protection | RPO | RTO |
|---|---|---|---|
| Redis process / pod crash | AOF `everysec` on the PVC, restart | ~1 s | seconds |
| Master pod or node lost | Sentinel failover to a replica (hard anti-affinity, PDB) | ~1 s (async replication; see the failover measurements) | ~10-15 s |
| One PVC lost or corrupt | Pod restarts empty and full-syncs from the master | 0 | minutes |
| **Logical damage** (`FLUSHALL`, bad deploy, wrong key deleted) | Replicated instantly to every node, so only a **backup** helps | backup interval | restore runbook R2 |
| **All PVCs, namespace, or cluster lost** | Off-cluster backup, then bootstrap restore (R1) | backup interval (default 1 h) | install time + download (minutes) |
| Region / object store lost | Bucket replication to a 2nd region (storage-side), optional warm standby (below) | backup interval | R1 in the other region |
| Credentials lost (infra Secret, ACL catalog) | Git (catalog) + secret store (ESO). Not part of the data backup | 0 | `helm install` |

Replication and Sentinel are **high availability, not disaster recovery**. Everything below
covers the bottom four rows.

#### Backups (`dr.backup.enabled`)
A CronJob (`<release>-redis-ha-dr-backup`, hourly by default) runs two containers:
1. **snapshot** (the Redis image): picks the **connected replica with the highest replication offset**
   (`ROLE`) and runs `redis-cli --rdb` as `backup-user`. That is `REPLCONF rdb-only 1` + `SYNC`, so the fork
   happens on the replica, never on the master (`dr.backup.source: any` allows a fallback to the master).
   The file is verified with `redis-check-rdb` (structure + CRC64), then `backup.meta` (source, offset,
   Redis version, keyspace) and `SHA256SUMS` are written.
2. **upload** (rclone): copies to `<dr.storage.remote>/<backup-id>/` (id = UTC `YYYYMMDDTHHMMSSZ`),
   runs `rclone check` against the local files, updates `<remote>/LATEST`, then applies retention:
   delete backups older than `retention.days` but **always keep the newest `retention.keepLast`**, so
   failing backups never prune the last good ones.

Design choices (best practices):
- **Off-cluster, other failure domain.** Any rclone backend (S3, GCS, Azure Blob, MinIO, ...),
  configured only through `RCLONE_CONFIG_<REMOTE>_*` env vars in the pre-created Secret
  `dr.storage.existingSecret` (ESO). Use a bucket in another region/account, or enable bucket replication.
- **Immutable and encrypted.** Turn on bucket versioning + Object Lock (WORM), give the backup
  credential write-only access, and set `retention.days: 0` to let the bucket lifecycle expire objects.
  Use server-side encryption (KMS) and, optionally, an rclone `crypt` remote for client-side encryption.
  The crypt password must live in your secret store, not only in this cluster.
- **Least privilege.** `backup-user` = `-@all +ping +role +info +sync +replconf`
  (verified with ACL LOG on Redis 8.8; the reload preflight DRYRUNs it, including the denials for
  `PSYNC`, `GET`, `CONFIG`, `FLUSHALL`). `SYNC` streams the whole dataset, so treat `backup-password` like a
  read-all credential. The backup ServiceAccount is authorized by Linkerd on the Redis port **only**
  (not Sentinel, not HAProxy).
- **RDB over AOF for backups.** One compact, self-checking, point-in-time file, restorable on the same or a
  newer Redis version (RDB format 12 on 8.x cannot be read by older versions).
- **Not CSI volume snapshots.** A snapshot of a running PVC is only crash-consistent and is bound to the
  cluster/zone. Velero can still back up the Kubernetes objects, but this chart is GitOps-installed anyway.
- **Monitored.** `RedisBackupMissing` (no successful run for `backupMaxAgeSeconds`, default 3 h, or never),
  plus `RedisRdbSaveFailed` / `RedisAofWriteFailed` for local persistence.
- **Tested restores.** A backup that has never been restored is not a backup. Run test 09
  (or runbook R1 into a scratch namespace) regularly, for example monthly.

Storage Secret example (S3, created by ESO, never in git):
```bash
kubectl -n redis create secret generic redis-ha-dr-storage \
  --from-literal=RCLONE_CONFIG_S3_TYPE=s3 --from-literal=RCLONE_CONFIG_S3_PROVIDER=AWS \
  --from-literal=RCLONE_CONFIG_S3_REGION=eu-west-1 --from-literal=RCLONE_CONFIG_S3_ACCESS_KEY_ID=... \
  --from-literal=RCLONE_CONFIG_S3_SECRET_ACCESS_KEY=... --from-literal=RCLONE_CONFIG_S3_SERVER_SIDE_ENCRYPTION=aws:kms
# values: dr.storage.remote: "s3:acme-redis-backups/prod/redis", dr.backup.enabled: true
```
On-demand backup (for example before a risky deploy):
`kubectl -n redis create job --from=cronjob/redis-redis-ha-dr-backup dr-backup-manual-$(date +%s)`.

#### Restores: bootstrap an empty cluster (`values-dr-restore.yaml`)
Redis can only load a snapshot at startup, and **with `appendonly yes` Redis " + GE + " 7 loads only the AOF
directory**. When the directory is missing, it creates a new **empty** AOF and ignores `dump.rdb`, so a
naive "copy dump.rdb into /data" restore comes up healthy and empty. The overlay adds two init containers
to **every** Redis pod (after the chart's `config-init`):
1. `dr-restore-fetch` (rclone): **only if `/data` holds no `dump.rdb` and no `appendonlydir`**, downloads
   `<remote>/<backupId>/` and verifies `SHA256SUMS`.
2. `dr-restore-install` (the Redis image): `redis-check-rdb`, then installs the snapshot as the **base of a
   new multi-part AOF** (`appendonlydir/appendonly.aof.1.base.rdb` + a one-line manifest) and as `dump.rdb`.
   The AOF directory is moved into place first, atomically, so an interrupted install can never leave a
   state that a restart would load as empty. A marker `/data/.dr-restored-from` records the backup.

Every pod restores the same pinned backup, so whichever pod becomes master has the data, and replicas
full-sync from it anyway. Pods that already have data (normal restarts) skip both steps.
`backupId` must be explicit (`latest` is rejected): with GitOps, the restored point in time is reviewable,
and pods started at different times cannot pick different backups. ACL users are **not** in the backup.
They come from the catalog and the secret store as usual, so the restored cluster enforces today's ACLs.
Rendering fails if the init containers, the ConfigMap name, the storage Secret or the image do not match.

**R1: total loss / new cluster**
1. Recreate the prerequisites: namespace, infra Secret and storage Secret (ESO), client namespaces.
2. Find the backup: `rclone cat s3:acme-redis-backups/prod/redis/LATEST` (or `rclone lsf` for an older one).
3. `helm install redis charts/redis-ha-secure -n redis -f values.yaml -f values-phase2.yaml [-f values-haproxy.yaml] -f values-dr-restore.yaml --set dr.restore.backupId=<id>`
4. Verify: `kubectl logs <pod> -c dr-restore-install` on every pod, `INFO keyspace` equal on all nodes and
   matching `keyspace_at_snapshot_approx` in `backup.meta`, then application smoke tests.
5. Remove `values-dr-restore.yaml` (one rolling restart with the usual preStop failover). The
   `RedisDrRestoreStillEnabled` alert reminds you after 24 h.

**R2: logical damage on a running cluster** (`FLUSHALL`, bad migration). Downtime: everything written
since the backup is lost, so first decide between this and an application-level fix.
1. Stop writers (scale the apps down, or remove their AuthorizationPolicy).
2. Take an on-demand backup anyway (forensics), then pick the last good `backupId` from **before** the damage.
3. `helm uninstall redis -n redis`, then `kubectl -n redis delete pvc -l app=redis-ha,release=redis`.
   The infra Secret, ACL Secret and client credential Secrets are not Helm-managed, so they survive.
4. Continue with R1 step 3. Test 09 runs exactly this path.

Selective restore (a few keys): restore into a **scratch release/namespace** with R1, then copy the keys
(`DUMP`/`RESTORE`, or RedisShake with key filters) into production.

#### Optional: warm standby in a second cluster
The `migration` feature is a generic RedisShake replicator: a standby release in another cluster with
`migration.enabled` and `migration.source.address` pointing at production (reachable through Linkerd
multicluster or a private link) keeps a continuously updated copy (RPO of seconds). On failover, disable
the migration and point the clients at the standby. Limits: asynchronous, one direction, **streams are not
supported by RedisShake 4.7.0 on Redis 8**, and you pay for a second cluster. For most workloads, backups +
R1 (RTO of minutes) are enough. Add the standby only if the RTO requires it.

### Pitfalls
- `subPath` mounts never receive Secret updates, so the chart refuses them.
- ACL rules are additive. Every generated line starts with `reset`, so `ACL LOAD` gives the exact state.
- `ACL LOAD` is atomic per node, but a node reloads only when told to, and it must not load a file kubelet has
  not propagated yet. That is why the Job waits for `acl-watch` before running `ACL LOAD`.
- An invalid `aclfile` makes Redis exit at startup, so a bad rule would crash-loop pods on their next restart.
  The preflight load catches this before anything is applied.
- `requirepass` is ignored when `aclfile` is set. `masterauth`/`auth-pass` are runtime settings. CONFIG REWRITE
  persists them in `/data/conf` (the chart already stores `masterauth` there in plaintext on the PVC; protect the PVC).
- Never give any user `&*`/`allchannels` on Sentinel-monitored nodes. Forged `__sentinel__:hello` messages can redirect Sentinels.
- `+@read` includes `SCAN`/`RANDOMKEY`, which return key *names* outside the user's patterns. Add
  `acl.appUserExtraRules: ["-scan", "-randomkey"]` if tenants must not enumerate each other's key names.
- Some Sentinel-aware clients verify the master with `ROLE` or `INFO replication`. If yours does, add
  `extraRules: ["+role"]` (or `"+info"`) to that user.
- `SENTINEL SET … auth-pass` drops Sentinel's links, which reconnect within about 1 s. The reload therefore applies it on every run, which is
  harmless as long as `down-after-milliseconds` (10 s) is longer than the reconnect time.
- The redis_exporter `+arcount` grant exists only on Redis ≥ 8.8, and an unknown command makes the whole ACL file invalid.
  Re-check `acl.infraRules` when changing major/minor Redis versions (the preflight will tell you).
- The HAProxy PDB is rendered by the chart even when HAProxy is disabled. It is therefore `{}` by default.
- The Linkerd `opaque-ports` annotation replaces the default list. NetworkPolicies must also allow 4143 for meshed opaque traffic.
- `helm upgrade` of a release whose StatefulSet was scaled to 0: the pre-upgrade reload hook runs while
  no Redis pod exists. It runs the preflight and then exits (pods load the current Secret when they start).
  If only **some** pods are missing, the hook still waits and fails: that cluster is degraded, so fix it first.
- Jobs in a meshed namespace need native sidecars (Kubernetes ≥ 1.29) or they never complete.
- **Stock upstream HAProxy config without `maxconn`** (likely your current prod): HAProxy sizes maxconn
  from the file-descriptor limit (about 524k) and pre-allocates memory for it. With a small memory limit
  (64Mi), it was OOMKilled in our legacy fixture. Set `haproxy.resources` generously or set a `maxconn`, as this chart does.
- Kubernetes ≥ 1.35 refuses cgroup v1 nodes. kind on Docker Desktop with an older WSL kernel needs `kindest/node:v1.34.x`.

---

## 4. Monitoring
redis_exporter runs as an extra container (`exporter-user`), scraped by `PodMonitor`. PrometheusRules:

| Alert | Expression (abridged) |
|---|---|
| RedisMemoryHigh | `redis_memory_used_bytes / redis_memory_max_bytes > 0.8` |
| RedisOutOfMemoryErrors | `increase(redis_errors_total{err="OOM"}[5m]) > 0` |
| RedisEvictingKeys | `increase(redis_evicted_keys_total[5m]) > 0`, rendered only when the policy evicts |
| RedisRejectedConnections | `increase(redis_rejected_connections_total[5m]) > 0` |
| RedisMemoryFragmentationHigh | `redis_mem_fragmentation_ratio > 1.5` (with used memory > 100MB) |
| RedisFailoverOccurred / RedisNoOrMultipleMasters | more than one pod was master within 15m / master count ≠ 1 |
| RedisReplicationBroken / RedisMissingReplicas | `redis_master_link_up == 0` / `connected_slaves < 2` |
| RedisAclAuthFailures | `increase(redis_acl_access_denied_auth_total[5m]) > 5` (then inspect `ACL LOG`) |
| RedisAclPermissionDenied | cmd/key/channel denials > 0 |
| RedisAclDriftCheckFailed | no **successful** drift run for 1 h (`kube_cronjob_status_last_successful_time`). One transient failure, for example during a node restart, does not page |
| RedisAclReloadFailed | kube-state-metrics `kube_job_status_failed` for the reload Job |
| HAProxyNoRedisMaster / HAProxyMultipleRedisMasters | `haproxy_backend_active_servers{proxy="bk_redis_master"}` == 0 for 30 s / > 1 |
| HAProxySentinelChecksDown / HAProxyPodsDisagree | < 2 Sentinels answer / pods route to different masters |
| HAProxyConnectionsNearLimit / HAProxyRejectingConnections | sessions > 80 % of maxconn / quorum-routing refusals |
| RedisDown | `redis_up == 0` |
| RedisRdbSaveFailed / RedisAofWriteFailed | `redis_rdb_last_bgsave_status == 0` / `redis_aof_last_write_status == 0 or redis_aof_last_bgrewrite_status == 0` |
| RedisBackupMissing | no **successful** `dr-backup` run for `backupMaxAgeSeconds` (3 h), or never (`absent`). Only with `dr.backup.enabled` |
| RedisDrRestoreStillEnabled | the restore overlay has been in place for 24 h |

---

## 5. Tests
All scripts are bash. On Windows, run them from Git Bash. Secrets are never printed; passwords are piped to `redis-cli` through stdin.

| Script | What it proves |
|---|---|
| `scripts/01-lint-template.sh` | `helm lint --strict` and `helm template` for both phases. Rendered config assertions (aclfile, maxmemory, no subPath, opaque ports, limits and securityContext on every container, rule rendering). Negative tests: wildcard namespace, subPath, rename CONFIG, requests≠limits, opaque ports, unsafe channel, HAProxy default config, quorum, plus the maxmemory table. No cluster needed. |
| `scripts/ci/kind-up.sh` | Local cluster: kind (1 control plane + 3 workers, one per zone) with Calico so NetworkPolicy is enforced |
| `scripts/02-deploy-verify.sh` | Deploy and check: anti-affinity, PDB, `INFO replication`, `SENTINEL MASTER` / `CKQUORUM` on every Sentinel, identical memory config, identical ACLs, revision mounted == loaded, credential Secrets, Sentinel-aware clients from their namespaces, and that a non-catalog namespace is blocked by NetworkPolicy |
| `scripts/03-acl-dryrun.sh` | Catalog-driven `ACL DRYRUN` on every node: allowed/denied keys (`~`, `%R~`, `%W~`), channels, dangerous/admin commands, scripting, Sentinel discovery vs. admin. Real AUTH of every user on every Redis node and Sentinel |
| `scripts/04-default-user-rejected.sh` | Phase 2: unauthenticated access gets NOAUTH, `default` gets NOPERM for everything except probe commands (Redis and Sentinel), and no infra link uses `default` |
| `scripts/05-failover-test.sh` | `SENTINEL FAILOVER`, then identical ACLs on the new master, replication users, and app users still working |
| `scripts/06-acl-reload-test.sh` | Add a user, rotate its password (dual window), remove it, all through the reload Job. Pod UIDs, restart counts and process `run_id`s stay unchanged, with no failover |
| `scripts/07-haproxy-test.sh` | HAProxy mode (`HAPROXY=1`): one master UP and Sentinel agreement on every HAProxy pod, no `haproxy-user` denials, persistent-connection failover (0 READONLY, lost-write count reported), quorum routing, readiness-gated broken rollout + repair, no restarts |
| `scripts/08-migration-test.sh` | Live migration from a stock redis-ha + HAProxy (requirepass) cluster: seeded typed data in 2 DBs + TTL, live writer, RedisShake catch-up, ACL applies to migrated data, cutover, migration-user revoked |
| `scripts/09-dr-test.sh` | Disaster recovery end to end, against a throw-away S3 endpoint (`rclone serve s3`): backup Job snapshots a **replica** as `backup-user`, uploads, checks and updates LATEST. Then `helm uninstall` + every PVC deleted, and bootstrap restore with `values-dr-restore.yaml`: every pod restores the pinned backup, keyspace identical on all nodes, string/hash/**stream**/list/zset/TTL restored, post-backup write absent, ACLs enforced, AOF based on the snapshot, replication healthy. A restarted pod skips the restore, removing the overlay keeps the data, and a new backup succeeds |

```bash
scripts/01-lint-template.sh
KIND=kind scripts/ci/kind-up.sh
PHASE=1 scripts/02-deploy-verify.sh && PHASE=1 scripts/03-acl-dryrun.sh && PHASE=1 scripts/05-failover-test.sh && PHASE=1 scripts/06-acl-reload-test.sh
PHASE=2 scripts/02-deploy-verify.sh && PHASE=2 scripts/03-acl-dryrun.sh && PHASE=2 scripts/04-default-user-rejected.sh \
  && PHASE=2 scripts/05-failover-test.sh && PHASE=2 scripts/06-acl-reload-test.sh
```

### Validation record
Validated on kind (Kubernetes 1.34.11, 1 control plane + 3 workers, Calico enforcing NetworkPolicy):

| Check | Result |
|---|---|
| 01 lint/template, both phases plus negative tests | 70/70 |
| 02 phase 1 (install) | 35/35 |
| 03 phase 1 | 245/245 |
| 05 phase 1 | 17/17 (failover 13 s) |
| 06 phase 1 | 18/18 (4 upgrades, 0 restarts, same run_ids, no failover) |
| Phase 1 → 2 in **one** upgrade | reload Job staged, switched, verified via CLIENT LIST, then demoted `default` |
| 02 phase 2 | 35/35 |
| 03 phase 2 | 245/245 |
| 04 phase 2 | 109/109 |
| 05 phase 2 | 19/19 |
| 06 phase 2 | 18/18 |
| `ACL LOG` after all phase-2 tests | no denials for replica-user / sentinel-user / sentinel-peer / exporter-user / probe commands of `default` |
| Master pod deleted in phase 2 | preStop failover in 8 s (with the demoted Sentinel `default`). The pod restarted from the include files and rejoined as replica-user. Sentinel peers authenticated as sentinel-peer |
| Rollback 2 → 1 | 02 35/35, 05 17/17 |
| Drift CronJob | OK when clean. Fails on a rogue `ACL SETUSER` on one node |
| Unplanned restart of the whole cluster (Docker Desktop) in phase 2 | All pods came back on their own, with no manual action. Phase 2 runtime auth (`masteruser`, Sentinel `auth-user`/`sentinel-user`) was restored from the include files. 02 34/34, 04 109/109, drift OK. One drift run that started while the pods were still down failed ("unreachable"). This led to the drift check's 120 s readiness grace period and the "last successful run" alert. |
| HAProxy variant (phase 2) | health checks UP as haproxy-user. Client writes through HAProxy and gets NOPERM outside its prefix. Direct 6379 blocked by NetworkPolicy |
| redis_exporter as exporter-user | `redis_up 1`, no ACL denials |

**HAProxy iteration (kind, phase 2, HAProxy mode):** 01 115/115 (incl. `haproxy -c` on the real binary),
02 39/39, 03 203/203, 04 109/109, 05 19/19, 07 36/36. Bugs found and fixed by these runs:
the reload hook was post-upgrade (deadlock with new identities), Redis 8 Sentinel rejects `QUIT`
(Sentinel checks never passed; quorum routing correctly refused clients), and readiness now gates on the
full routing condition. 06 (HAProxy mode) and 08 (migration) were written, but their final runs are not yet
recorded. 06 failed once on a test bug (it expected catalog users on Sentinels), now fixed.

**Docker Desktop (Kubernetes 1.32.2, single node, Linkerd edge-26.9.1 enforcing `Server`/`AuthorizationPolicy`,
HAProxy mode, run via `scripts/run-all.sh`):** 02 phase 1 38/38, 03 phase 1 203/203, 02 phase 2 38/38,
03 phase 2 203/203, 04 109/109, 05 19/19, 06 18/18 (hot reload, no restarts), 07 35/36, 08 19/20.
- The 07 miss was HAProxy restarts left over from the cold install (the readiness/liveness trade-off above).
  The check now only counts restarts that happen after the test starts. It was not re-run.
- The 08 miss was a test bug: `RPUSH` seeding is not idempotent across re-runs. The list was identical on the source and
  the target (`a,b,c` ×3). The check now compares against the source.
- Failover through HAProxy and the mesh: 0 READONLY, about 0.7 s of acknowledged writes lost, old sessions closed after 11 s.
- Linkerd identities were enforced live: intruder namespace denied, catalog clients allowed via HAProxy, and hook Jobs completed with native sidecars.
- Not covered: NetworkPolicy (Docker Desktop does not enforce it; it was validated on kind/Calico instead).

**Disaster recovery (docker-desktop, phase 2, HAProxy mode, Linkerd enforcing):** 09 39/39
(backup from a replica, uninstall + all PVCs deleted, bootstrap restore of 3 516 keys incl. a stream on all
3 nodes, idempotent restart, overlay removal, new backup), 01 142/142 (27 DR assertions/negative tests).
- Verified by hand on Redis 8.8.4: the `backup-user` rules (ACL LOG empty), and that an RDB installed as
  the AOF base + manifest loads with `appendonly yes` and survives a restart.
- Retention verified with a local rclone remote: old backups pruned, `keepLast` floor honored, and a tampered
  snapshot refused.
- Found and fixed by these runs: the pre-upgrade reload hook waited forever when the StatefulSet was
  scaled to 0 (now: preflight, then exit), verified live in both directions.

**Not validated on a live cluster** (rendered and asserted only):
- Prometheus Operator: the `PodMonitor` / `PrometheusRule` objects (metric names were checked against the redis_exporter v1.97.0 source).
- External Secrets Operator: simulated with a pre-created Secret.
