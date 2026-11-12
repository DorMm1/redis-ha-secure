{{- define "demo.redisFullname" -}}
{{- printf "%s-redis-ha" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "demo.labels" -}}
app.kubernetes.io/part-of: redis-ha-demo
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{- define "demo.podSecurityContext" -}}
runAsNonRoot: true
runAsUser: 65532
runAsGroup: 65532
fsGroup: 65532
seccompProfile: { type: RuntimeDefault }
{{- end -}}

{{- define "demo.containerSecurityContext" -}}
runAsNonRoot: true
readOnlyRootFilesystem: true
allowPrivilegeEscalation: false
capabilities: { drop: [ALL] }
seccompProfile: { type: RuntimeDefault }
{{- end -}}

{{- define "demo.validate" -}}
{{- if ne .Release.Namespace .Values.demo.namespace -}}
{{- fail (printf "install the demo into namespace %q (demo.namespace): the catalog users are bound to it" .Values.demo.namespace) -}}
{{- end -}}
{{- range (index .Values "redis-ha-secure").aclUsers -}}
{{- if ne .namespace $.Values.demo.namespace -}}{{- fail "every demo aclUsers entry must use demo.namespace" -}}{{- end -}}
{{- end -}}
{{- if ne (printf "%s-redis-ha" .Release.Name) (include "demo.redisFullname" .) -}}{{- fail "release name too long" -}}{{- end -}}
{{- end -}}
