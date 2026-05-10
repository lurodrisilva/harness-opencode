{{/*
Common naming, labels, and selector partials.

`opencode.selectorLabels` MUST be a strict subset of `opencode.labels` and
MUST NOT contain anything that can rotate (chart version, image tag, helm.sh/
chart, etc). The Deployment selector is immutable; first install succeeds with
mutable labels but every subsequent upgrade fails on the immutability check.
*/}}

{{- define "opencode.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "opencode.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "opencode.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Full standard label set. Used on every object's metadata.labels.
*/}}
{{- define "opencode.labels" -}}
helm.sh/chart: {{ include "opencode.chart" . }}
{{ include "opencode.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: opencode
{{- end -}}

{{/*
Immutable selector subset. ONLY name + instance — never add component, version,
chart, or anything else. Adding fields here will work on install and break on
upgrade.
*/}}
{{- define "opencode.selectorLabels" -}}
app.kubernetes.io/name: {{ include "opencode.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "opencode.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "opencode.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/*
Image reference. Prefers `image.digest` (supply-chain-strict path) over `tag`.
Falls back to `.Chart.AppVersion` when `tag` is empty.
*/}}
{{- define "opencode.image" -}}
{{- if .Values.image.digest -}}
{{- printf "%s@%s" .Values.image.repository .Values.image.digest -}}
{{- else -}}
{{- $tag := default .Chart.AppVersion .Values.image.tag -}}
{{- printf "%s:%s" .Values.image.repository $tag -}}
{{- end -}}
{{- end -}}

{{- define "opencode.authSecretName" -}}
{{- if .Values.auth.existingSecret -}}
{{- .Values.auth.existingSecret -}}
{{- else -}}
{{- printf "%s-auth" (include "opencode.fullname" .) -}}
{{- end -}}
{{- end -}}

{{- define "opencode.providersSecretName" -}}
{{- if .Values.providers.existingSecret -}}
{{- .Values.providers.existingSecret -}}
{{- else -}}
{{- printf "%s-providers" (include "opencode.fullname" .) -}}
{{- end -}}
{{- end -}}

{{- define "opencode.dataPvcName" -}}
{{- printf "%s-data" (include "opencode.fullname" .) -}}
{{- end -}}

{{- define "opencode.configPvcName" -}}
{{- printf "%s-config" (include "opencode.fullname" .) -}}
{{- end -}}

{{/*
True iff this chart will render a providers Secret (rather than referencing
an existing one). Used to decide whether to emit a checksum annotation.
*/}}
{{- define "opencode.providersSecretRendered" -}}
{{- if and (not .Values.providers.existingSecret) (or .Values.providers.openaiKey .Values.providers.anthropicKey) -}}
true
{{- end -}}
{{- end -}}

{{/*
True iff this chart will render the auth Secret.
*/}}
{{- define "opencode.authSecretRendered" -}}
{{- if and .Values.auth.enabled (not .Values.auth.existingSecret) -}}
true
{{- end -}}
{{- end -}}

{{/*
True iff Copilot OAuth seeding is configured.
*/}}
{{- define "opencode.copilotEnabled" -}}
{{- if and .Values.providers.copilot .Values.providers.copilot.existingSecret -}}
true
{{- end -}}
{{- end -}}

{{/*
storageClassName field renderer. Three states:
  - empty value -> omit field entirely (use cluster default)
  - "-"          -> render `storageClassName: ""` (explicit "no class")
  - other        -> render `storageClassName: <value>`
*/}}
{{- define "opencode.storageClass" -}}
{{- $value := . -}}
{{- if $value -}}
{{- if eq $value "-" -}}
storageClassName: ""
{{- else -}}
storageClassName: {{ $value | quote }}
{{- end -}}
{{- end -}}
{{- end -}}
