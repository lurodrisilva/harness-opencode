# Spec — Helm chart `opencode` for k8s deploy

> **Scope** Package the existing `ghcr.io/<owner>/<repo>:<tag>` opencode-server
> distroless image as a production-ready Helm chart. Image, runtime contract,
> probes, and security defaults are inherited from `Dockerfile` + `README.md` —
> the chart only translates them into idiomatic k8s primitives.
>
> **Not in scope** Building the image (already done by GHA), TLS terminator
> deployment (out-of-band reverse proxy / ingress controller responsibility),
> multi-tenancy, HPA (single-replica stateful workload).

## 1. Inputs from existing repo

| Source | Fact |
|--------|------|
| `Dockerfile:117-118` | Entrypoint `serve --port 4096 --hostname 0.0.0.0 --print-logs` |
| `Dockerfile:106` | `USER nonroot` (uid/gid 65532) |
| `Dockerfile:110` | `VOLUME ["/home/nonroot/.local/share/opencode", "/home/nonroot/.config/opencode"]` |
| `Dockerfile:112` | `EXPOSE 4096` |
| `README.md:152-160` | Probe path `/global/health`, `httpGet` only (no shell in distroless) |
| `README.md:55-58` | Env: `OPENCODE_SERVER_PASSWORD`, `OPENCODE_SERVER_USERNAME`, `OPENAI_API_KEY`, `ANTHROPIC_API_KEY` |
| `README.md:11-25` | Hard rule: unset password → server is RCE-equivalent. Never expose to public internet. |
| `README.md:64-67` | Volumes: `~/.local/share/opencode` (sessions/state), `~/.config/opencode` (auth/config) |

## 2. Chart identity

- `name: opencode`
- `type: application`
- `version: 0.1.0` (chart SemVer; bumps independent of `appVersion`)
- `appVersion: "1.14.40"` (string-quoted — three-segment dotted strings stay strings, but we quote defensively per skill rule)
- `kubeVersion: ">=1.27.0-0"` (HPA v2, immutable PVC fields, GA-stable Pod security context)
- `home`: opencode.ai
- `sources`: GHCR repo + harness repo
- `keywords`: ai, agent, opencode, server
- `maintainers`: lurodrisilva

## 3. Workload primitive — `Deployment` not `StatefulSet`

Single-replica stateful workload with RWO volumes. Deployment + `strategy: Recreate` is the simplest correct shape:

- StatefulSet earns its complexity only with N>1 ordered pods or volumeClaimTemplates per replica. We have neither.
- Recreate strategy guarantees the old pod releases the RWO PVC before the new one binds (rolling would deadlock).
- `replicas: 1` is enforced via values schema (`maximum: 1`) — running multiple opencode pods against one PVC would corrupt session state.

## 4. Resource layout

```
charts/opencode/
├── Chart.yaml
├── values.yaml
├── values.schema.json          # Hard schema gate for replicaCount, image, auth
├── README.md                   # Generated table of values; install/upgrade examples
├── .helmignore
├── templates/
│   ├── _helpers.tpl            # Standard names, labels, selector, image ref
│   ├── NOTES.txt               # Post-install: how to retrieve generated password, port-forward, verify
│   ├── serviceaccount.yaml     # Always created; automountServiceAccountToken: false
│   ├── secret-auth.yaml        # OPENCODE_SERVER_PASSWORD (auto-gen w/ lookup-stability) — skipped if existingSecret set
│   ├── secret-providers.yaml   # OPENAI/ANTHROPIC keys — skipped if existingSecret set
│   ├── pvc-data.yaml           # ~/.local/share/opencode (sessions, history)
│   ├── pvc-config.yaml         # ~/.config/opencode (auth, config)
│   ├── deployment.yaml
│   ├── service.yaml            # ClusterIP only; ingress is the supported off-cluster path
│   ├── ingress.yaml            # Off by default; enabled only when ingress.enabled=true
│   ├── networkpolicy.yaml      # Off by default; default-deny-egress + allow-from-ingress when enabled
│   └── tests/
│       └── test-health.yaml    # helm.sh/hook: test — busybox-curl check on /global/health
└── ci/
    ├── default-values.yaml     # Lint matrix: defaults
    ├── ingress-values.yaml     # Lint matrix: ingress + TLS
    └── existing-secret-values.yaml  # Lint matrix: bring-your-own auth
```

## 5. `values.yaml` surface (high-level)

```yaml
replicaCount: 1   # locked to 1 by schema

image:
  repository: ghcr.io/lurodrisilva/harness   # placeholder; user overrides
  tag: ""                                    # default falls through to .Chart.AppVersion
  digest: ""                                 # optional; if set, image ref becomes repo@digest
  pullPolicy: IfNotPresent
  pullSecrets: []

auth:
  enabled: true                  # if false, server runs unauthenticated (must NOT be public)
  existingSecret: ""             # if set, secret-auth.yaml is skipped
  passwordKey: opencode-server-password
  username: opencode             # default
  generatedPasswordLength: 48    # randAlphaNum length when auto-generated

providers:
  existingSecret: ""             # if set, secret-providers.yaml is skipped
  openaiKey: ""                  # mapped to OPENAI_API_KEY env
  anthropicKey: ""               # mapped to ANTHROPIC_API_KEY env

persistence:
  data:
    enabled: true
    size: 5Gi
    storageClass: ""             # empty = cluster default; "-" = explicit "no class"
    accessModes: [ReadWriteOnce]
    annotations: {}
  config:
    enabled: true
    size: 256Mi
    storageClass: ""
    accessModes: [ReadWriteOnce]
    annotations: {}

service:
  type: ClusterIP
  port: 4096
  annotations: {}

ingress:
  enabled: false                 # OFF by default — opencode is plain HTTP; user must terminate TLS
  className: ""
  hosts:
    - host: opencode.example.com
      paths:
        - path: /
          pathType: Prefix
  tls: []                        # mandatory in any real deploy
  annotations: {}                # e.g., basic-auth at the proxy

networkPolicy:
  enabled: false
  ingressFrom: []                # podSelector / namespaceSelector list

resources:
  limits:    { cpu: 1000m, memory: 1Gi }
  requests:  { cpu: 250m,  memory: 512Mi }

podSecurityContext:
  runAsNonRoot: true
  runAsUser: 65532
  runAsGroup: 65532
  fsGroup: 65532
  seccompProfile:
    type: RuntimeDefault

containerSecurityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true   # distroless + writes only to /home/nonroot (PVC-backed) → safe
  capabilities:
    drop: [ALL]

probes:
  liveness:
    httpGet: { path: /global/health, port: http }
    initialDelaySeconds: 5
    periodSeconds: 10
    timeoutSeconds: 2
    failureThreshold: 3
  readiness:
    httpGet: { path: /global/health, port: http }
    initialDelaySeconds: 2
    periodSeconds: 5
    timeoutSeconds: 2
    failureThreshold: 3
  startup:
    httpGet: { path: /global/health, port: http }
    initialDelaySeconds: 2
    periodSeconds: 2
    timeoutSeconds: 2
    failureThreshold: 30        # ~60s startup budget for DB migration

serviceAccount:
  create: true
  name: ""
  annotations: {}
  automountServiceAccountToken: false   # opencode never talks to the kube API

extraEnv: []           # arbitrary env passthrough
extraEnvFrom: []       # configMapRef / secretRef passthrough
nodeSelector: {}
tolerations: []
affinity: {}
podAnnotations: {}
podLabels: {}
priorityClassName: ""
topologySpreadConstraints: []
```

## 6. `values.schema.json` (hard-fail gates)

The schema **rejects** misconfiguration at `helm install` time, before render. Hard gates:

- `replicaCount`: `integer`, `minimum: 1`, `maximum: 1` (RWO PVC + single binary instance — schema is the only thing that prevents footguns here)
- `image.repository`: `string`, `pattern` matches a registry-shaped ref
- `image.digest`: optional, but if set must match `^sha256:[a-f0-9]{64}$`
- `auth.enabled`: `boolean`
- `service.port`: `integer`, `minimum: 1`, `maximum: 65535`
- `persistence.data.accessModes` / `persistence.config.accessModes`: array of `ReadWriteOnce|ReadWriteMany|ReadOnlyMany`
- `ingress.enabled`: `boolean`; if true, `ingress.tls` must be a non-empty array (additionalProperties:false guards typos in nested keys)

## 7. Templates — substantive contracts

### 7.1 `_helpers.tpl`

Standard set per skill §7-8:

- `opencode.name` — `default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-"`
- `opencode.fullname` — `release-name + chart-name` collision-free pattern
- `opencode.chart` — `printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-"`
- `opencode.labels` — full standard label set + `helm.sh/chart`
- `opencode.selectorLabels` — `app.kubernetes.io/name` + `app.kubernetes.io/instance` ONLY (immutable subset; everything else can rotate)
- `opencode.serviceAccountName` — uses `.Values.serviceAccount.name` if set else fullname
- `opencode.image` — emits `repo:tag` OR `repo@digest` if `image.digest` set; falls back to `.Chart.AppVersion` if `tag` empty
- `opencode.authSecretName` — `.Values.auth.existingSecret` OR `{fullname}-auth`
- `opencode.providersSecretName` — `.Values.providers.existingSecret` OR `{fullname}-providers`

### 7.2 `secret-auth.yaml` — auto-gen with rotation safety

Critical correctness: a naive `randAlphaNum` regenerates on every `helm upgrade`, rotating the password and breaking every authenticated client. Use the documented `lookup`-then-fallback pattern:

```yaml
{{- if and .Values.auth.enabled (not .Values.auth.existingSecret) }}
{{- $existing := lookup "v1" "Secret" .Release.Namespace (printf "%s-auth" (include "opencode.fullname" .)) }}
{{- $password := "" }}
{{- if $existing }}
{{- $password = index $existing.data .Values.auth.passwordKey | b64dec }}
{{- else }}
{{- $password = randAlphaNum (int .Values.auth.generatedPasswordLength) }}
{{- end }}
apiVersion: v1
kind: Secret
metadata:
  name: {{ include "opencode.fullname" . }}-auth
  labels: {{- include "opencode.labels" . | nindent 4 }}
type: Opaque
stringData:
  {{ .Values.auth.passwordKey }}: {{ $password | quote }}
  username: {{ .Values.auth.username | quote }}
{{- end }}
```

This is one of the few cases where `lookup` is appropriate (pre-existing-state-aware secret generation; chart still works in `--dry-run=client` mode but skips the lookup branch — documented behavior).

### 7.3 `deployment.yaml` — the load-bearing template

- `metadata.labels`: full standard label set
- `spec.selector.matchLabels`: ONLY `selectorLabels` (immutable rule)
- `strategy: Recreate` (NOT RollingUpdate — RWO PVC deadlock)
- Pod annotations include `checksum/auth-secret` and `checksum/providers-secret` so secret rotation triggers a pod rollout
- `spec.template.spec.serviceAccountName: {{ include "opencode.serviceAccountName" . }}`
- `automountServiceAccountToken: false` (the SA only exists for PSA workload identity; opencode never calls the kube API)
- `volumes`: two PVCs (`data`, `config`) referencing the same names as PVC templates
- `containers[0]`:
  - `image`: `{{ include "opencode.image" . }}`
  - `imagePullPolicy`: from values
  - `ports`: `containerPort: 4096, name: http`
  - `env`: assembled by `_helpers.tpl` → username + password (`secretKeyRef`), provider keys (`secretKeyRef`, optional via `if`)
  - `volumeMounts`:
    - `data` → `/home/nonroot/.local/share/opencode`
    - `config` → `/home/nonroot/.config/opencode`
  - `livenessProbe`/`readinessProbe`/`startupProbe`: pure passthrough from `.Values.probes.*` via `toYaml | nindent 12`
  - `resources`: `toYaml`
  - `securityContext`: `containerSecurityContext` block

### 7.4 `service.yaml`

ClusterIP only by default; selector matches `selectorLabels`; `targetPort: http`. Ingress is the documented off-cluster path; `LoadBalancer`/`NodePort` not exposed (encourages misuse for an unauthenticated-by-default-on-LAN workload).

### 7.5 `ingress.yaml`

Standard k8s.io networking/v1 Ingress, gated on `.Values.ingress.enabled`. Schema requires `ingress.tls` non-empty when enabled — a chart that lets you ingress-publish opencode without TLS is a footgun by skill §0 rules.

### 7.6 `tests/test-health.yaml`

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: {{ include "opencode.fullname" . }}-test-health
  labels: {{- include "opencode.labels" . | nindent 4 }}
  annotations:
    "helm.sh/hook": test
    "helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded
spec:
  restartPolicy: Never
  containers:
    - name: curl
      image: curlimages/curl:8.10.1
      command: ["sh", "-c"]
      args:
        - |
          set -eu
          curl -fsS "http://{{ include "opencode.fullname" . }}:{{ .Values.service.port }}/global/health" \
            | grep -q '"healthy":true'
```

`helm test` becomes the post-install acceptance gate.

### 7.7 `NOTES.txt`

Post-install guidance:

- How to fetch the auto-generated password: `kubectl get secret … -o jsonpath='{.data.opencode-server-password}' | base64 -d`
- Port-forward smoke test: `kubectl port-forward svc/<release>-opencode 4096:4096`
- Curl with basic-auth: `curl -u opencode:$PASSWORD http://127.0.0.1:4096/global/health`
- Hard reminder if `auth.enabled=false`: warn user the release is RCE-equivalent if any pod or service exposes it
- Hard reminder if `ingress.enabled=true` and `tls` is empty (won't render, but defensive): TLS terminator required

## 8. Security stance (per skill §15)

Every container fields the full default-deny pod-hygiene set:

| Knob | Value |
|------|-------|
| `runAsNonRoot` | `true` |
| `runAsUser` / `runAsGroup` / `fsGroup` | `65532` |
| `allowPrivilegeEscalation` | `false` |
| `readOnlyRootFilesystem` | `true` |
| `capabilities.drop` | `[ALL]` |
| `seccompProfile.type` | `RuntimeDefault` |
| `automountServiceAccountToken` | `false` |
| `imagePullPolicy` | `IfNotPresent` (not `Always` — defeats digest-pinned reproducibility) |

The schema requires either `image.tag` or `image.digest` to be non-empty; a naked `image.repository` is rejected so `:latest` can never sneak in implicitly.

## 9. Helm hooks

| Hook | Use |
|------|-----|
| `helm.sh/hook: test` | `tests/test-health.yaml` only |

No pre-install / post-install hooks needed — opencode does its own DB migration on container start, surfaced via the startup probe budget. **Avoid** the anti-pattern of using a Job to "warm" the chart.

## 10. CI matrix (`charts/opencode/ci/*.yaml`)

`helm lint` runs against each `ci/*.yaml`. Three matrix points:

1. **defaults** — empty file, exercises baked defaults end-to-end
2. **ingress + TLS** — verifies the schema's `tls`-required-when-enabled gate doesn't regress
3. **bring-your-own auth** — `auth.existingSecret: my-secret` + `providers.existingSecret: my-providers` skips both Secret templates

## 11. Out-of-scope (deliberate)

- HPA: single-replica stateful workload; horizontal scaling needs a redesign (shared-nothing session backend) before HPA is meaningful.
- PodDisruptionBudget: replicas=1 + maxUnavailable=0 PDB blocks every node drain. Ship without; document tradeoff.
- ServiceMonitor / PrometheusRule: opencode does not expose a Prometheus endpoint per `/doc` — adding a monitor would be cargo-culted.
- OCI registry push from this repo: GHA already publishes the image; charts can be pushed in a follow-up workflow.

## 12. Acceptance criteria

| Phase | Gate |
|-------|------|
| Phase 2 build | `helm lint charts/opencode --strict --values charts/opencode/ci/default-values.yaml` passes (and the other two ci files) |
| Phase 2 build | `helm template charts/opencode` renders without errors and `kubectl --dry-run=client apply -f -` of the rendered yaml succeeds |
| Phase 2 build | `values.schema.json` rejects `replicaCount: 2`, missing `image.repository`, `ingress.enabled=true` with empty `tls` (schema-only test, no cluster needed) |
| Phase 3 QA  | `helm install opencode-smoke charts/opencode --namespace opencode-smoke --create-namespace --dry-run=server` succeeds against any reachable cluster (skip if no cluster) |
| Phase 3 QA  | All YAML files lint clean (`yq`-parseable, balanced fences in NOTES.txt, etc.) |
| Phase 4 review | Architect: chart fields a complete k8s primitive set, no over-engineering; Security: secrets handled correctly, no plaintext in templates, no privilege escalation paths; Code-review: idiomatic Helm per skill §0 rules. |
