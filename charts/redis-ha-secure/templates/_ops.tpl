{{/*
Pod spec shared by the reload Job and the drift CronJob.
  init  wait-for-mount (kubectl): waits for / reports the ACL revision kubelet mounted
  main  acl-reload.sh / acl-drift.sh (redis-cli)
Call with (dict "root" $ "mode" "wait|report" "script" "acl-reload.sh|acl-drift.sh" "scripts" "<configmap>")
*/}}
{{- define "redis-ha-secure.opsPodSpec" -}}
{{- $root := .root -}}
{{- $sub := index $root.Values "redis-ha" -}}
{{- $full := include "redis-ha-secure.fullname" $root -}}
{{- $k := $root.Values.infraCredentials.keys -}}
serviceAccountName: {{ include "redis-ha-secure.opsServiceAccount" $root }}
automountServiceAccountToken: false
restartPolicy: Never
securityContext: {{- toYaml $root.Values.jobs.podSecurityContext | nindent 2 }}
{{- with $root.Values.jobs.nodeSelector }}
nodeSelector: {{- toYaml . | nindent 2 }}
{{- end }}
{{- with $root.Values.jobs.tolerations }}
tolerations: {{- toYaml . | nindent 2 }}
{{- end }}
initContainers:
  - name: wait-for-mount
    image: "{{ $root.Values.jobs.kubectlImage.repository }}:{{ $root.Values.jobs.kubectlImage.tag }}"
    imagePullPolicy: {{ $root.Values.jobs.kubectlImage.pullPolicy }}
    command: ["/bin/bash", "/scripts/wait-for-mount.sh"]
    env:
      - { name: NAMESPACE, value: {{ $root.Release.Namespace | quote }} }
      - { name: FULLNAME, value: {{ include "redis-ha-secure.redisFullname" $root | quote }} }
      - { name: REPLICAS, value: {{ $sub.replicas | toString | quote }} }
      - { name: MODE, value: {{ .mode | quote }} }
      - { name: TIMEOUT_SECONDS, value: {{ $root.Values.acl.reload.timeoutSeconds | toString | quote }} }
    resources: {{- toYaml $root.Values.jobs.resources | nindent 6 }}
    securityContext: {{- toYaml $root.Values.jobs.containerSecurityContext | nindent 6 }}
    volumeMounts:
      - { name: scripts, mountPath: /scripts, readOnly: true }
      - { name: acl, mountPath: /acl, readOnly: true }
      - { name: shared, mountPath: /shared }
      - { name: tmp, mountPath: /tmp }
      - { name: token, mountPath: /var/run/secrets/kubernetes.io/serviceaccount, readOnly: true }
containers:
  - name: {{ trimSuffix ".sh" .script }}
    image: "{{ $sub.image.repository }}:{{ $sub.image.tag }}"
    imagePullPolicy: {{ $sub.image.pullPolicy }}
    command: ["/bin/sh", "/scripts/{{ .script }}"]
    env:
      - { name: NAMESPACE, value: {{ $root.Release.Namespace | quote }} }
      - { name: FULLNAME, value: {{ include "redis-ha-secure.redisFullname" $root | quote }} }
      - { name: REPLICAS, value: {{ $sub.replicas | toString | quote }} }
      - { name: MASTER_GROUP, value: {{ include "redis-ha-secure.masterGroupName" $root | quote }} }
      - { name: REDIS_PORT, value: {{ $sub.redis.port | toString | quote }} }
      - { name: SENTINEL_PORT, value: {{ $sub.sentinel.port | toString | quote }} }
      - { name: PHASE, value: {{ $root.Values.acl.phase | toString | quote }} }
      - { name: DEMOTE_DEFAULT, value: {{ $root.Values.acl.phase2.demoteDefault | toString | quote }} }
      - { name: TIMEOUT_SECONDS, value: {{ $root.Values.acl.reload.timeoutSeconds | toString | quote }} }
      - { name: USERNAME_PREFIX, value: {{ $root.Values.acl.usernamePrefix | quote }} }
      - { name: KEY_ACL_ADMIN, value: {{ $k.aclAdmin | quote }} }
      - { name: KEY_DEFAULT, value: {{ $k.default | quote }} }
      - { name: KEY_REPLICA, value: {{ $k.replica | quote }} }
      - { name: KEY_SENTINEL_USER, value: {{ $k.sentinelUser | quote }} }
      - { name: KEY_SENTINEL_PEER, value: {{ $k.sentinelPeer | quote }} }
    resources: {{- toYaml $root.Values.jobs.resources | nindent 6 }}
    securityContext: {{- toYaml $root.Values.jobs.containerSecurityContext | nindent 6 }}
    volumeMounts:
      - { name: scripts, mountPath: /scripts, readOnly: true }
      - { name: acl, mountPath: /acl, readOnly: true }
      - { name: infra, mountPath: /infra, readOnly: true }
      - { name: shared, mountPath: /shared }
      - { name: tmp, mountPath: /tmp }
volumes:
  - name: scripts
    configMap:
      name: {{ .scripts | default (printf "%s-acl-scripts" $full) }}
  - name: acl
    secret:
      secretName: {{ $root.Values.acl.secretName }}
      defaultMode: 0440
  - name: infra
    secret:
      secretName: {{ $root.Values.infraCredentials.secretName }}
      defaultMode: 0440
  - name: shared
    emptyDir: { medium: Memory, sizeLimit: 1Mi }
  - name: tmp
    emptyDir: { sizeLimit: 64Mi }
  - name: token
    projected:
      sources:
        - serviceAccountToken: { path: token, expirationSeconds: 3600 }
        - configMap:
            name: kube-root-ca.crt
            items: [{ key: ca.crt, path: ca.crt }]
        - downwardAPI:
            items:
              - path: namespace
                fieldRef: { fieldPath: metadata.namespace }
{{- end -}}

{{- define "redis-ha-secure.opsPodMeta" -}}
labels:
  {{- include "redis-ha-secure.labels" .root | nindent 2 }}
  {{- include "redis-ha-secure.jobClientLabels" .root | nindent 2 }}
  app.kubernetes.io/component: {{ .component }}
{{- with .root.Values.jobs.podAnnotations }}
annotations: {{- toYaml . | nindent 2 }}
{{- end }}
{{- end -}}
