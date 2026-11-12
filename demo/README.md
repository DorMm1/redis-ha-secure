# redis-ha-secure: interactive demo

One command deploys a complete, working showcase into namespace `redis-demo`:

| Component | What it shows |
|---|---|
| **Redis HA** (`redis-ha-secure` as a dependency) | 3 Redis + 3 Sentinels, HAProxy front door, phase-2 ACLs (no `default` user for apps), Linkerd mTLS + per-ServiceAccount authorization, hourly-style DR backups |
| **orders-api** | Writes ~5 orders/s through HAProxy as `system.serviceaccount.redis-demo.orders-api` (rw `orders:*`, publish `orders.events.*`) |
| **report-reader** | Reads orders and writes `reports:*` as its own ACL user, and keeps trying to tamper with `orders:*` (always `NOPERM`) |
| **intruder** | A workload with **no** catalog entry. Linkerd refuses its identity before Redis sees a byte |
| **redis-demo-store** | In-cluster S3 (`rclone serve s3`) standing in for an off-cluster bucket |
| **dashboard** | Live topology, traffic, backups, and buttons for failover, chaos, backup, an ACL playground, and a logical disaster |

![flow](https://img.shields.io/badge/flow-install%20%E2%86%92%20ACL%20%E2%86%92%20failover%20%E2%86%92%20backup%20%E2%86%92%20disaster%20%E2%86%92%20restore-5b9dff)

## Prerequisites
- A Kubernetes cluster with **Linkerd** installed (Docker Desktop works: single node, about 3 GB free memory).
- `kubectl`, `helm`, `curl`, `python`. On Windows, run the script from Git Bash.

## Run it

```bash
demo/run-demo.sh up          # helm dependency build + install (about 5 min the first time) + port-forward
# open http://localhost:8088
demo/run-demo.sh tour        # guided walkthrough in a second terminal, [Enter] between scenes
```

`AUTO=1 demo/run-demo.sh tour` runs all scenes without pauses and exits non-zero if any check
fails, so it doubles as an end-to-end test. Env: `KUBE_CONTEXT`, `DEMO_PORT` (8088), `DEMO_VALUES`.

Plain Helm instead of the script:
```bash
helm dependency build charts/redis-ha-demo
helm upgrade --install demo charts/redis-ha-demo -n redis-demo --create-namespace --wait --timeout 20m
kubectl -n redis-demo port-forward svc/redis-demo-dashboard 8088:8080
```

## The scenes

1. **Topology.** Every node is read directly as `acl-admin`: one master, two replicas, all Sentinels agree,
   and the **ACL digest is identical on every node** (one `users.acl` Secret, `ACL LOAD` everywhere).
2. **Least privilege.** In the ACL playground (or the tour), `FLUSHALL`, `KEYS *` and `CONFIG` are `NOPERM` for
   orders-api; report-reader cannot write `orders:*` or run Lua; the `default` user is probe-only (`NOPERM`); a
   wrong password is `WRONGPASS`; no AUTH is `NOAUTH`. The intruder panel shows Linkerd dropping its connections.
3. **Failover under load.** *Sentinel failover* or *Kill master pod*. A new master takes over within seconds. The
   writer reports a short outage (about 8 s on Docker Desktop) and continues, and ACLs stay identical on the new master.
4. **Backup.** *Backup now* runs a Job from the backup CronJob: snapshot of a **replica** as `backup-user`,
   `redis-check-rdb`, SHA256SUMS, upload, `LATEST`. The backup appears in the list with its key count.
5. **Disaster.** *Rogue deploy* deletes every `orders:*` key with orders-api's legitimate credentials.
   Replication copies the damage to **every** node within milliseconds. High availability is not a backup.
6. **Restore.** `demo/run-demo.sh restore [backup-id]` (the dashboard shows the command):
   Redis is stopped and **every PVC deleted**, then `helm upgrade -f charts/redis-ha-demo/values-restore.yaml`
   adds the `dr-restore-*` init containers. Each pod downloads the backup, verifies it, and installs it as
   the AOF base. The cluster comes back with the data as of the backup, the overlay is removed again
   (rolling restart), and the apps keep working with the same credentials (ACLs come from the catalog, not
   the backup). Writes made after the backup are lost; that is the RPO.

## Clean up
```bash
demo/run-demo.sh down        # helm uninstall + delete namespace redis-demo (PVCs, generated Secrets)
```

## Notes
- **Demo only:** the dashboard holds the `acl-admin` password and the apps' credentials, and the "off-cluster"
  store runs in the same namespace. Production keeps backups in another failure domain (see the main README,
  "Disaster recovery").
- The dashboard reaches Redis/Sentinel directly through `linkerd.extraIntraClients` and HAProxy through
  `linkerd.extraClients`. Its Kubernetes RBAC is limited to deleting the 3 Redis pods, reading the backup
  CronJob and creating Jobs.
- `SHUTDOWN`, `DEBUG`, `MONITOR` and `SUBSCRIBE` are disabled in the playground.
- All demo code is standard-library Python ([charts/redis-ha-demo/files](../charts/redis-ha-demo/files)) on the stock
  `python:3.13-alpine` image, delivered by ConfigMap. Every container is non-root, read-only, drops all
  capabilities, and has limits.
