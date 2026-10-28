{{/*
Workload name. Defaults to the release name: the chart is shared, so its own
name says nothing about the workload.
*/}}
{{- define "microservice.name" -}}
{{- default .Release.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Fully qualified name. <release>-<name>, collapsed to <release> when the
release name already contains the name, unless overridden.
*/}}
{{- define "microservice.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := include "microservice.name" . -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "microservice.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Standard labels (k8s recommended). The version label tracks the image tag,
not the chart: the chart version is the same for every workload.
*/}}
{{- define "microservice.labels" -}}
helm.sh/chart: {{ include "microservice.chart" . }}
{{ include "microservice.selectorLabels" . }}
{{- with .Values.image.tag }}
app.kubernetes.io/version: {{ . | trunc 63 | trimSuffix "-" | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- with .Values.partOf }}
app.kubernetes.io/part-of: {{ . }}
{{- end }}
{{- with .Values.component }}
app.kubernetes.io/component: {{ . }}
{{- end }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{- define "microservice.selectorLabels" -}}
app.kubernetes.io/name: {{ include "microservice.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Service account name to use.
*/}}
{{- define "microservice.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "microservice.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/*
Image reference: repository[:tag][@digest]. There is no appVersion to fall
back to, so at least one of tag/digest is required.
*/}}
{{- define "microservice.image" -}}
{{- $repo := required "image.repository is required" .Values.image.repository -}}
{{- if not (or .Values.image.tag .Values.image.digest) -}}
{{- fail "image.tag or image.digest is required" -}}
{{- end -}}
{{- $repo -}}
{{- with .Values.image.tag }}:{{ . }}{{ end -}}
{{- with .Values.image.digest }}@{{ . }}{{ end -}}
{{- end -}}

{{/*
Container `env` and `envFrom` blocks, built from env, extraEnv and
extraEnvFrom. Empty when none is set.

Stable: meant for containers declared in extraObjects (migration Jobs,
CronJobs) so they get exactly the configuration of the main container:
  {{- include "microservice.containerEnv" . | nindent <container indent> }}
*/}}
{{- define "microservice.containerEnv" -}}
{{- include "microservice.containerEnv.blocks" . | trim -}}
{{- end -}}

{{- define "microservice.containerEnv.blocks" }}
{{- if or .Values.env .Values.extraEnv }}
env:
  {{- /* Plain non-sensitive env, sorted for determinism */}}
  {{- range $k, $v := .Values.env }}
  - name: {{ $k }}
    value: {{ $v | quote }}
  {{- end }}
  {{- with .Values.extraEnv }}
  {{- toYaml . | nindent 2 }}
  {{- end }}
{{- end }}
{{- with .Values.extraEnvFrom }}
envFrom:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{/*
Probe body. Takes a probe values block; `spec` is used verbatim when set
(exec, grpc, tcpSocket), otherwise an httpGet probe is built from `path`.
Timing fields are emitted only when present, so 0 is preserved.
*/}}
{{- define "microservice.probe" -}}
{{- if .spec -}}
{{ toYaml .spec }}
{{- else -}}
httpGet:
  path: {{ required "probe path is required when spec is not set" .path }}
  port: {{ .port | default "http" }}
{{- range $f := list "initialDelaySeconds" "periodSeconds" "timeoutSeconds" "successThreshold" "failureThreshold" }}
{{- if hasKey $ $f }}
{{ $f }}: {{ index $ $f }}
{{- end }}
{{- end }}
{{- end -}}
{{- end -}}

{{/*
Fail early on combinations that would render broken manifests.
*/}}
{{- define "microservice.validate" -}}
{{- if and (not .Values.service.enabled) .Values.httpRoute.enabled -}}
{{- fail "httpRoute.enabled requires service.enabled" -}}
{{- end -}}
{{- if and (not .Values.service.enabled) .Values.serviceMonitor.enabled -}}
{{- fail "serviceMonitor.enabled requires service.enabled" -}}
{{- end -}}
{{- end -}}
