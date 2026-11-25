{{- define "weather.labels" -}}
app.kubernetes.io/name: weather
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/* Selector labels for one component: frontend | backend | collector | migrate */}}
{{- define "weather.selector" -}}
app.kubernetes.io/name: weather
app.kubernetes.io/component: {{ . }}
{{- end }}

{{/* Pod-level hardening. Matches Pod Security Standard "restricted". */}}
{{- define "weather.podSecurity" -}}
runAsNonRoot: true
runAsUser: {{ . }}
runAsGroup: {{ . }}
seccompProfile:
  type: RuntimeDefault
{{- end }}

{{/* Container-level hardening. */}}
{{- define "weather.containerSecurity" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop: ["ALL"]
{{- end }}

{{/* DB connection env for a workload. Usage: include "weather.dbEnv" (dict "root" $ "who" "backend") */}}
{{- define "weather.dbEnv" -}}
{{- $db := .root.Values.db }}
- { name: DB_HOST, value: {{ required "db.host is required" $db.host | quote }} }
- { name: DB_PORT, value: {{ $db.port | quote }} }
- { name: DB_NAME, value: {{ $db.name | quote }} }
- { name: DB_USER, value: {{ index $db.users .who | quote }} }
- { name: DB_SSLMODE, value: {{ $db.sslMode | quote }} }
{{- with $db.sslRootCert }}
- { name: DB_SSLROOTCERT, value: {{ . | quote }} }
{{- end }}
{{- if eq $db.auth "iam" }}
- { name: DB_IAM_AUTH, value: "true" }
- { name: AWS_REGION, value: {{ required "db.awsRegion is required for iam auth" $db.awsRegion | quote }} }
{{- else }}
- name: DB_PASSWORD
  valueFrom:
    secretKeyRef: { name: {{ index $db.passwordSecrets .who }}, key: password }
{{- end }}
{{- end }}

{{/* Spread replicas across nodes and zones so one failure does not take the service down. */}}
{{- define "weather.spread" -}}
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: kubernetes.io/hostname
    whenUnsatisfiable: ScheduleAnyway
    labelSelector: { matchLabels: { app.kubernetes.io/component: {{ . }} } }
  - maxSkew: 1
    topologyKey: topology.kubernetes.io/zone
    whenUnsatisfiable: ScheduleAnyway
    labelSelector: { matchLabels: { app.kubernetes.io/component: {{ . }} } }
{{- end }}
