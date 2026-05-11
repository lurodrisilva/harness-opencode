# opencode

Headless [opencode](https://opencode.ai) AI coding agent server on Kubernetes.

| Field            | Value          |
|------------------|----------------|
| Chart version    | 0.3.0          |
| App version      | 1.14.40        |
| Min `kubeVersion`| `>=1.27.0-0`   |
| Image            | `ghcr.io/lurodrisilva/harness-opencode:<AppVersion>` (override `image.tag`/`image.digest`) |

> **Image tag note:** the default `image.tag` is empty, so the deployment
> resolves to `ghcr.io/lurodrisilva/harness-opencode:<.Chart.AppVersion>`.
> The GHA workflow only publishes that tag when a matching `v<AppVersion>`
> git tag exists. Until then, install with `--set image.tag=master` (rolling)
> or pin via `--set image.digest=sha256:…` (supply-chain-strict).

> ## ⚠️ Read first — security defaults
>
> opencode serves AI tooling that, once authenticated, can execute commands
> and use upstream provider credentials. **An exposed unauthenticated
> opencode instance is RCE-equivalent.**
>
> 1. The chart enables `auth.enabled=true` by default and auto-generates a
>    48-char password. Setting `auth.enabled=false` is supported only for
>    deployments that front opencode with a separate authenticating reverse
>    proxy.
> 2. opencode speaks plain HTTP. **Never expose the Service or NodePort
>    directly.** Set `ingress.enabled=true` with a TLS-terminating Ingress,
>    or front it with a separate in-cluster reverse proxy (Caddy, nginx,
>    Envoy, Istio).
> 3. The default Service is `ClusterIP` — there is no `LoadBalancer` /
>    `NodePort` shortcut.

## Install

```sh
# Default install (auto-generated 48-char password, ClusterIP only)
helm install opencode ./charts/opencode \
  --namespace opencode --create-namespace

# Production install (existing TLS Ingress)
helm install opencode ./charts/opencode \
  --namespace opencode --create-namespace \
  --set ingress.enabled=true \
  --set ingress.className=nginx \
  --set ingress.hosts[0].host=opencode.example.com \
  --set ingress.hosts[0].paths[0].path=/ \
  --set ingress.hosts[0].paths[0].pathType=Prefix \
  --set ingress.tls[0].hosts[0]=opencode.example.com \
  --set ingress.tls[0].secretName=opencode-tls
```

After install, fetch the auto-generated password:

```sh
kubectl --namespace opencode get secret opencode-auth \
  -o jsonpath='{.data.opencode-server-password}' | base64 -d
```

The password persists across upgrades — the chart uses `lookup`-then-fallback
so `helm upgrade` never regenerates it. To rotate, delete the Secret and run
`helm upgrade` again.

## Verify

```sh
helm test opencode --namespace opencode
```

The test runs an in-cluster `curl` against `/global/health` and asserts
`"healthy":true` plus the expected `version`.

## Upgrade

```sh
helm upgrade opencode ./charts/opencode --namespace opencode --reuse-values
```

The Deployment's pod annotations include `checksum/auth-secret` and
`checksum/providers-secret`, so changing either Secret rolls the pod.

## Uninstall

```sh
helm uninstall opencode --namespace opencode
```

The two PVCs (`opencode-data`, `opencode-config`) are annotated with
`helm.sh/resource-policy: keep` and survive uninstall — sessions and config
persist for a future re-install. Wipe them with:

```sh
kubectl --namespace opencode delete pvc opencode-data opencode-config
```

## Values

### Replication & image

| Key                            | Default                          | Notes |
|--------------------------------|----------------------------------|-------|
| `replicaCount`                 | `1`                              | Schema-locked at 1; RWO PVC + single binary instance. |
| `image.repository`             | `ghcr.io/lurodrisilva/harness`   | Override at install. |
| `image.tag`                    | `""`                             | Empty falls through to `.Chart.AppVersion`. |
| `image.digest`                 | `""`                             | Optional `sha256:…` pin; bypasses tag. **Set this for supply-chain-strict deployments** — the chart's GHA pipeline emits digest-pinned images with provenance + SBOM attestations. |
| `image.pullPolicy`             | `IfNotPresent`                   | `Always` defeats reproducibility. |
| `image.pullSecrets`            | `[]`                             | List of `{name: <secret>}`. |

### Auth

| Key                              | Default                       | Notes |
|----------------------------------|-------------------------------|-------|
| `auth.enabled`                   | `true`                        | `false` = RCE-equivalent unless fronted by an authenticating proxy. |
| `auth.existingSecret`            | `""`                          | If set, skips chart-generated Secret. The BYO Secret MUST contain a key named `auth.passwordKey` (override that value if your Secret uses a different key). |
| `auth.passwordKey`               | `opencode-server-password`    | Key inside the Secret. Applies to both chart-generated and BYO Secrets. |
| `auth.username`                  | `opencode`                    |  |
| `auth.generatedPasswordLength`   | `48`                          | 16–256, schema-validated. |

### Providers

| Key                                  | Default       | Notes |
|--------------------------------------|---------------|-------|
| `providers.existingSecret`           | `""`          | Skips chart Secret. Expected keys: `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`. |
| `providers.openaiKey`                | `""`          | Inline key (chart Secret only). |
| `providers.anthropicKey`             | `""`          | Inline key (chart Secret only). |
| `providers.copilot.existingSecret`   | `""`          | Secret holding the GitHub Copilot OAuth `auth.json`. When set, an initContainer seeds the data PVC on first start. Requires `persistence.data.enabled=true` (schema-enforced). |
| `providers.copilot.secretKey`        | `auth.json`   | Key inside the Secret. |
| `providers.copilot.initImage`        | `busybox:1.37.0` | Image for the seeding initContainer. Override for air-gapped clusters. |

> **Provider keys + Helm release storage.** Inline `openaiKey` / `anthropicKey`
> are stored in the chart-managed Secret AND in the Helm release object
> (`secrets/sh.helm.release.v1.<name>.<rev>`). Anyone with `get secrets` RBAC
> in the release namespace — including via `helm get manifest` — can recover
> them. For production, set `providers.existingSecret` and manage the Secret
> out of band (External Secrets Operator, sealed-secrets, etc.).
>
> When `existingSecret` is set, the env vars use `optional: true` so a
> partial Secret (only `OPENAI_API_KEY`, only `ANTHROPIC_API_KEY`, or
> neither) does not CrashLoopBackOff the pod.

#### GitHub Copilot (OAuth device flow)

Copilot does **not** use API keys — opencode obtains an OAuth token via
GitHub's device-code flow, which needs a browser. For a headless k8s
deployment, bootstrap locally and ship the token as a Secret:

```sh
# On your laptop, with opencode installed:
opencode auth login          # pick GitHub Copilot, complete the device flow
# Token lands at ~/.local/share/opencode/auth.json

# Wrap it as a k8s Secret:
kubectl --namespace opencode create secret generic opencode-copilot \
  --from-file=auth.json=$HOME/.local/share/opencode/auth.json

# Install / upgrade referencing the Secret:
helm upgrade --install opencode ./charts/opencode \
  --namespace opencode --create-namespace \
  --set providers.copilot.existingSecret=opencode-copilot
```

On first pod start, an initContainer copies `auth.json` from the Secret into
the data PVC at `/home/nonroot/.local/share/opencode/auth.json`. After that
opencode rotates the OAuth token in-pod; the Secret is **not** rewritten —
it serves only as the bootstrap source.

**Switching the bound GitHub account** requires both updating the Secret AND
wiping the in-PVC file before the next pod start (the initContainer skips
when `auth.json` already exists):

```sh
kubectl --namespace opencode exec deploy/opencode \
  -- rm -f /home/nonroot/.local/share/opencode/auth.json
kubectl --namespace opencode rollout restart deploy/opencode
```

> Some Copilot models require a **GitHub Copilot Pro+** subscription.

### Persistence

| Key                                    | Default          | Notes |
|----------------------------------------|------------------|-------|
| `persistence.data.enabled`             | `true`           | Sessions, history, project state. |
| `persistence.data.size`                | `5Gi`            |  |
| `persistence.data.storageClass`        | `""`             | `""`=cluster default, `"-"`=explicit no-class. |
| `persistence.data.accessModes`         | `[ReadWriteOnce]`| |
| `persistence.config.enabled`           | `true`           | Auth + config files. |
| `persistence.config.size`              | `256Mi`          | |
| `persistence.config.storageClass`      | `""`             | |
| `persistence.config.accessModes`       | `[ReadWriteOnce]`| |

### Networking

| Key                                | Default     | Notes |
|------------------------------------|-------------|-------|
| `service.type`                     | `ClusterIP` | Only ClusterIP/NodePort/LoadBalancer permitted by schema. |
| `service.port`                     | `4096`      |  |
| `ingress.enabled`                  | `false`     | Schema requires non-empty `tls` when `true`. |
| `ingress.className`                | `""`        | |
| `ingress.hosts`                    | example     | |
| `ingress.tls`                      | `[]`        | Mandatory when ingress is enabled. |
| `networkPolicy.enabled`            | `false`     | When `true`: default-deny ingress + DNS + 443 egress. |
| `networkPolicy.ingressFrom`        | `[]`        | List of NetworkPolicyPeer. |

### Security context

| Key                                       | Default            | Notes |
|-------------------------------------------|--------------------|-------|
| `podSecurityContext.runAsNonRoot`         | `true`             |  |
| `podSecurityContext.runAsUser`            | `65532`            | Matches distroless `nonroot`. |
| `podSecurityContext.fsGroup`              | `65532`            |  |
| `containerSecurityContext.readOnlyRootFilesystem` | `true`     | Safe — opencode writes only to /home/nonroot + /tmp (emptyDir). |
| `containerSecurityContext.capabilities.drop` | `[ALL]`         |  |
| `serviceAccount.automountServiceAccountToken` | `false`        | opencode never calls the kube API. |

### Probes

opencode applies HTTP basic auth to **every** route (including
`/global/health`); kubelet probes don't carry credentials. The chart works
around this by emitting `tcpSocket` probes whenever `auth.enabled=true`,
and `httpGet /global/health` probes when auth is disabled. Both modes
honour the `probes.{liveness,readiness,startup}.{initialDelaySeconds,
periodSeconds,timeoutSeconds,failureThreshold}` knobs from `values.yaml`.
The startup probe budgets ~60s for cold-start cache provisioning.

## Sizing notes

The defaults (250m/512Mi requests, 1000m/1Gi limits) are conservative.
Realistic load (single user, intermittent agent runs) sits well below
requests; tune `resources` based on observed memory/CPU.

## Why not StatefulSet?

A StatefulSet earns its complexity with N>1 ordered pods or one
`volumeClaimTemplate` per replica. This chart is single-replica with
two named PVCs — `Deployment` + `strategy: Recreate` is the simplest correct
shape. The Recreate strategy guarantees the old pod releases the RWO PVC
before the new pod tries to bind it.
