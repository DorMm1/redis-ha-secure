# Kibana alerting rules for redis-ha-secure (Elastic EDOT)

With `values-edot.yaml`, the Prometheus Operator objects are not rendered. Create these rules
in Kibana instead (Stack Management → Rules → **Elasticsearch query** rule, query type **ES|QL**,
"alert when matches > 0"; one alert per row with *Group by row* enabled). They mirror the
PrometheusRules in `templates/monitoring/prometheus-operator.yaml`, with the same thresholds.

## Field names: check them once

The queries assume the collector config in [collector.yaml](collector.yaml) and Elastic's
OTel-native mapping (`elasticsearch` exporter, `mapping.mode: otel`):

| What | Field |
|---|---|
| metric value | `metrics.<prometheus metric name>`, for example `metrics.redis_memory_used_bytes` |
| relabeled labels (`namespace`, `pod`, `app`) and exporter labels (`role`, `err`, `proxy`) | `attributes.<label>` |
| data stream | `metrics-*.otel-*` |
| pod logs (EDOT filelog) | `logs-*.otel-*`, message in `body.text`, pod in `resource.attributes.k8s.pod.name` |

In Discover, open one document from `metrics-*.otel-*` with `attributes.namespace : "redis"` and
adjust the names if your pipeline differs (for example ECS mode, or a `k8sattributes` processor
that puts the pod name into `resource.attributes.k8s.pod.name`). Replace `"redis"` with your namespace.

Counters (`*_total`) are cumulative. "Increase over N minutes" is written as
`MAX(x) - MIN(x)` per pod over the window. That is accurate unless the pod restarted inside the
window, in which case it under-reports. That is acceptable for alerting.

## Rules

| Rule | Severity | Window / schedule | Condition |
|---|---|---|---|
| RedisDown | critical | 2m / 1m | `redis_up == 0`, or no exporter metrics for a pod (use the rule's "no data" option) |
| RedisMemoryHigh | warning | 10m / 5m | `redis_memory_used_bytes / redis_memory_max_bytes > 0.8` |
| RedisOutOfMemoryErrors | critical | 5m / 1m | increase of `redis_errors_total{err="OOM"}` > 0 |
| RedisEvictingKeys | warning | 5m / 5m | increase of `redis_evicted_keys_total` > 0 (only for evicting `maxmemory-policy`) |
| RedisRejectedConnections | warning | 5m / 5m | increase of `redis_rejected_connections_total` > 0 |
| RedisMemoryFragmentationHigh | warning | 30m / 15m | `redis_mem_fragmentation_ratio > 1.5` and `redis_memory_used_bytes > 100MB` |
| RedisFailoverOccurred | warning | 15m / 5m | more than one distinct pod had `redis_instance_info{role="master"}` |
| RedisNoOrMultipleMasters | critical | 2m / 1m | distinct pods with `role="master"` ≠ 1 |
| RedisReplicationBroken | critical | 2m / 1m | `redis_master_link_up == 0` |
| RedisMissingReplicas | warning | 5m / 5m | master's `redis_connected_slaves < 2` |
| RedisAclAuthFailures | warning | 5m / 5m | increase of `redis_acl_access_denied_auth_total` > 5 per pod |
| RedisAclPermissionDenied | info | 5m / 5m | increase of `redis_acl_access_denied_{cmd,key,channel}_total` > 0 |
| RedisRdbSaveFailed | critical | 5m / 5m | `redis_rdb_last_bgsave_status == 0` |
| RedisAofWriteFailed | critical | 5m / 5m | `redis_aof_last_write_status == 0` or `redis_aof_last_bgrewrite_status == 0` |
| HAProxyNoRedisMaster | critical | 1m / 1m | `haproxy_backend_active_servers{proxy="bk_redis_master"} == 0` |
| HAProxyMultipleRedisMasters | critical | 1m / 1m | same metric > 1 |
| HAProxyRejectingConnections | warning | 5m / 5m | increase of `haproxy_backend_requests_denied_total{proxy="bk_redis_master"}` + `haproxy_frontend_denied_connections_total{proxy="ft_redis_master"}` > 0 (quorum routing refused clients) |
| RedisBackupMissing | critical | 3h / 30m | **no** log line `[dr-upload] uploaded` from the `*-dr-backup-*` pods (log rule) |
| RedisAclDriftCheckFailed | warning | 1h / 15m | **no** log line `[acl-drift] OK:` in the window, or any `[acl-drift] DRIFT:` (log rules) |
| RedisAclReloadFailed | critical | 15m / 5m | any log line `[acl-reload] ERROR` |

Kube-state-metrics is not part of an EDOT setup, so the CronJob/Job rules are based on the
jobs' own log lines. That is also more precise: a backup counts only when it was uploaded and verified.

## ES|QL examples

Memory high:
```esql
FROM metrics-*.otel-*
| WHERE attributes.namespace == "redis" AND @timestamp > NOW() - 10 minutes
| STATS used = MAX(metrics.redis_memory_used_bytes), max = MAX(metrics.redis_memory_max_bytes) BY attributes.pod
| WHERE max > 0
| EVAL ratio = used / max
| WHERE ratio > 0.8
```

OOM errors / auth failures (counter increase):
```esql
FROM metrics-*.otel-*
| WHERE attributes.namespace == "redis" AND @timestamp > NOW() - 5 minutes
| STATS inc = MAX(metrics.redis_acl_access_denied_auth_total) - MIN(metrics.redis_acl_access_denied_auth_total) BY attributes.pod
| WHERE inc > 5
```
(For OOM: `metrics.redis_errors_total`, add `AND attributes.err == "OOM"`, threshold `> 0`.)

Exactly one master:
```esql
FROM metrics-*.otel-*
| WHERE attributes.namespace == "redis" AND @timestamp > NOW() - 2 minutes
    AND attributes.role == "master" AND metrics.redis_instance_info IS NOT NULL
| STATS masters = COUNT_DISTINCT(attributes.pod)
| WHERE masters != 1
```
This query returns nothing when there is no master at all. Pair it with the HAProxy rule, or
use the rule's "no data" alert option.

Replication broken:
```esql
FROM metrics-*.otel-*
| WHERE attributes.namespace == "redis" AND @timestamp > NOW() - 2 minutes
| STATS link = MAX(metrics.redis_master_link_up) BY attributes.pod
| WHERE link == 0
```

Backup missing (log rule; alert when the count is 0, schedule every 30m, window 3h):
```esql
FROM logs-*.otel-*
| WHERE resource.attributes.k8s.namespace.name == "redis" AND @timestamp > NOW() - 3 hours
    AND resource.attributes.k8s.pod.name LIKE "*-dr-backup-*" AND body.text LIKE "*[dr-upload] uploaded*"
| STATS uploads = COUNT(*)
| WHERE uploads == 0
```

ACL reload failed:
```esql
FROM logs-*.otel-*
| WHERE resource.attributes.k8s.namespace.name == "redis" AND @timestamp > NOW() - 15 minutes
    AND body.text LIKE "*[acl-reload] ERROR*"
| STATS errors = COUNT(*) BY resource.attributes.k8s.pod.name
```

Investigate ACL denials with `ACL LOG` (`scripts/lib.sh` `admin_redis <i> ACL LOG 20`). The
metrics only count them.
