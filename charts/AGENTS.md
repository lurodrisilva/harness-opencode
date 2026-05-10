<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-05-10 | Updated: 2026-05-10 -->

# charts

## Purpose
Helm chart packages for deploying the harness images on Kubernetes. Charts here
are the **deployment surface** for the artifacts the rest of this repo builds —
the `Dockerfile` produces the image, the GHA workflow publishes it, and the
charts here put it on a cluster.

## Subdirectories

| Directory          | Purpose                                                                                              |
|--------------------|------------------------------------------------------------------------------------------------------|
| `opencode/`        | Helm chart for the headless opencode-server. Single-replica stateful workload, hard schema, RWO PVCs. |

## For AI Agents

### Working in this directory

- The chart contract is captured in `.omc/autopilot/spec-helm.md` and
  `.omc/plans/autopilot-impl-helm.md`. Read those before changing template
  shape, default values, or schema gates.
- **Schema is load-bearing**. `values.schema.json` rejects misconfiguration
  *before* render — prefer extending the schema over adding template-level
  guards (faster, clearer error messages, no template branching).
- `replicaCount` is **schema-locked at 1**. Lifting that cap requires
  redesigning storage (RWO → RWX or shared-nothing session backend) — not a
  values change.
- The auth Secret uses the **`lookup`-then-fallback** pattern. Naive
  `randAlphaNum` regenerates on every `helm upgrade` and breaks every client.
  Don't "simplify" it.
- The selector subset (`opencode.selectorLabels` in `_helpers.tpl`) is the
  immutable shape — `app.kubernetes.io/name` + `app.kubernetes.io/instance`
  only. Adding any rotating field (chart version, image tag) breaks every
  upgrade.
- The image is distroless + read-only-root-fs. Any new write path needs an
  explicit `volumeMounts` entry and a matching `emptyDir` / PVC source.

### Testing requirements

```sh
# Lint matrix
helm lint charts/opencode --strict --values charts/opencode/ci/default-values.yaml
helm lint charts/opencode --strict --values charts/opencode/ci/ingress-values.yaml
helm lint charts/opencode --strict --values charts/opencode/ci/existing-secret-values.yaml

# Render
helm template smoke charts/opencode > /tmp/render.yaml
yq eval-all '.kind' /tmp/render.yaml | sort | uniq -c

# Schema rejection (each MUST exit non-zero)
! helm template smoke charts/opencode --set replicaCount=2
! helm template smoke charts/opencode --set image.repository=""
! helm template smoke charts/opencode --set ingress.enabled=true   # tls empty

# Live cluster acceptance (skip when no cluster)
helm install opencode-smoke charts/opencode \
  --namespace opencode-smoke --create-namespace
helm test opencode-smoke --namespace opencode-smoke
helm uninstall opencode-smoke --namespace opencode-smoke
```

### Common patterns

- **Hard schema, simple templates.** Push validation into
  `values.schema.json` (compile-time-style errors); keep templates focused on
  rendering.
- **Selector immutability.** Always re-use `opencode.selectorLabels`; never
  inline label maps in `selector.matchLabels` or `Service.spec.selector`.
- **`helm.sh/resource-policy: keep` on PVCs.** Stateful data survives
  uninstall by default; users opt out by deleting PVCs explicitly.
- **`Recreate` strategy on workloads with RWO PVCs.** RollingUpdate would
  deadlock waiting for the volume.

## Dependencies

### Internal

- `Dockerfile` — produces the image the chart deploys.
- `.github/workflows/build-push.yml` — publishes image digests to GHCR;
  chart users typically pin `image.digest` to a published value.
- `.omc/autopilot/spec-helm.md` — chart spec (design of record).
- `.omc/plans/autopilot-impl-helm.md` — implementation plan.

### External

- `helm` ≥ 3.14 (chart uses `lookup`, `get` semantics that are stable).
- `kubeVersion >= 1.27.0-0` (HPA v2 GA, immutable PVC fields, Pod Security
  Admission GA).

<!-- MANUAL: -->
