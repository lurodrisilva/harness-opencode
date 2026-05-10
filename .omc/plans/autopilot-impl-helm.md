# Plan — Helm chart `opencode`

Spec: `.omc/autopilot/spec-helm.md`

## Edit order (single PR, single chart, ~14 files)

All paths relative to repo root. Group A = chart structure, Group B = templates,
Group C = test surface, Group D = repo-level integration.

### Group A — chart skeleton (sequential)

1. `charts/opencode/Chart.yaml`
   - `apiVersion: v2`, `type: application`, `name: opencode`, `version: 0.1.0`,
     `appVersion: "1.14.40"`, `kubeVersion: ">=1.27.0-0"`, `keywords`, `home`,
     `sources`, `maintainers`, `icon` omitted (no asset).

2. `charts/opencode/.helmignore`
   - Ship the Helm-ships-by-default list + `ci/`, `tests/values/`,
     `*.tgz` (dev tarballs).

3. `charts/opencode/values.yaml`
   - Per spec §5. Comments above each top-level block, not inside YAML maps
     (preserve yq-parseability). Defaults are conservative — no public-internet
     footguns.

4. `charts/opencode/values.schema.json`
   - Per spec §6. `additionalProperties: false` at root (typo guard);
     `replicaCount.maximum: 1`; image.digest pattern;
     ingress.enabled=true → tls non-empty (`if/then/else`).

### Group B — templates (sequential, parent-helpers first)

5. `charts/opencode/templates/_helpers.tpl`
   - All named templates from spec §7.1. Selector subset is the load-bearing
     piece — get it wrong and upgrade-immutable selector check trips.

6. `charts/opencode/templates/serviceaccount.yaml`
   - Always rendered when `serviceAccount.create=true`.
     `automountServiceAccountToken: false`.

7. `charts/opencode/templates/secret-auth.yaml`
   - `lookup`-then-fallback for `randAlphaNum`. Skip when
     `.Values.auth.existingSecret` is set OR when `.Values.auth.enabled=false`.
   - Use `printf "%s-auth"` consistently for both `lookup` name and `metadata.name`.

8. `charts/opencode/templates/secret-providers.yaml`
   - Skip when `.Values.providers.existingSecret` set, OR when neither
     `openaiKey` nor `anthropicKey` is set (don't render an empty Secret).
   - Only emit keys that are non-empty (`if/with`-guarded), so partial
     configs (only OpenAI, only Anthropic) work.

9. `charts/opencode/templates/pvc-data.yaml`
10. `charts/opencode/templates/pvc-config.yaml`
    - Each gated on `persistence.{data,config}.enabled`. `storageClassName: "-"`
      handling: render `storageClassName: ""` when value is `"-"` (the
      explicit-no-class signal); render the value otherwise; omit the key when
      empty (cluster default).

11. `charts/opencode/templates/deployment.yaml`
    - Per spec §7.3. Strategy: `Recreate`. Pod annotations include
      `checksum/auth-secret` and `checksum/providers-secret` ONLY when those
      Secrets are rendered by this chart (skip checksum when using
      `existingSecret` — we can't `sha256sum` something we don't render).
    - Env list: assembled in `_helpers.tpl` so it's testable as one unit.

12. `charts/opencode/templates/service.yaml`
    - ClusterIP only. `targetPort: http`.

13. `charts/opencode/templates/ingress.yaml`
    - networking.k8s.io/v1. Off by default. `pathType` defaults to `Prefix` —
      `ImplementationSpecific` is a footgun on some controllers.

14. `charts/opencode/templates/networkpolicy.yaml`
    - Off by default. When enabled: default-deny-egress + allow-from
      `ingressFrom` selectors + allow DNS egress (kube-dns) so the pod can
      resolve `api.openai.com` and `api.anthropic.com`.

15. `charts/opencode/templates/NOTES.txt`
    - Per spec §7.7. Branches on `auth.enabled` and `ingress.enabled`.

### Group C — test surface

16. `charts/opencode/templates/tests/test-health.yaml`
    - Per spec §7.6. `helm.sh/hook: test`,
      `helm.sh/hook-delete-policy: before-hook-creation,hook-succeeded`.

17. `charts/opencode/ci/default-values.yaml`
    - Empty file (exercises defaults).

18. `charts/opencode/ci/ingress-values.yaml`
    - Enables ingress + provides TLS block.

19. `charts/opencode/ci/existing-secret-values.yaml`
    - `auth.existingSecret: prebuilt-auth`,
      `providers.existingSecret: prebuilt-providers`.

20. `charts/opencode/README.md`
    - Generated-style values table + install / upgrade / uninstall examples +
      "front with TLS" reminder + how to retrieve the auto-generated password.

### Group D — repo integration

21. `charts/AGENTS.md`
    - Hierarchy parent reference + chart purpose + working-in-this-directory
      notes (helm lint commands, the lookup pattern, schema gates).

22. `AGENTS.md` (root) — append `charts/` to the subdirectories table.

23. `README.md` (repo root) — add a "Kubernetes" section pointing to
    `charts/opencode` with a one-liner install example.

## QA gates (Phase 3)

Run in order; first failure stops the cycle:

```sh
# Lint per ci matrix
helm lint charts/opencode --strict --values charts/opencode/ci/default-values.yaml
helm lint charts/opencode --strict --values charts/opencode/ci/ingress-values.yaml
helm lint charts/opencode --strict --values charts/opencode/ci/existing-secret-values.yaml

# Render + dry-run-client validate every primitive
helm template smoke charts/opencode \
  | kubectl --dry-run=client apply -f - >/dev/null

# Schema rejection tests (must FAIL with non-zero rc)
! helm template smoke charts/opencode --set replicaCount=2
! helm template smoke charts/opencode --set image.repository=""
! helm template smoke charts/opencode --set ingress.enabled=true

# yq-parse every template after rendering
helm template smoke charts/opencode | yq eval-all '.' > /dev/null
```

Optional (skip if no cluster reachable):

```sh
helm install opencode-smoke charts/opencode --namespace opencode-smoke --create-namespace --dry-run=server
```

## Phase 4 reviewer briefs

| Reviewer | Focus |
|----------|-------|
| architect | Chart shape vs. spec §3-§7. StatefulSet-vs-Deployment decision is the load-bearing call — challenge it. |
| security-reviewer | Secret handling (no plaintext outputs in NOTES; auth-secret rotation safety; SA token automount=false; readOnlyRootFilesystem implications for opencode startup writes — does `/tmp` need an `emptyDir`?). |
| code-reviewer | Helm idioms per skill §0; selector-immutability rule; `default` vs `hasKey` for boolean defaults; `nindent` placement; balanced fences in NOTES.txt. |

## Risks / open knobs

| Risk | Mitigation |
|------|-----------|
| `readOnlyRootFilesystem: true` may break opencode if it writes to `/tmp` outside `/home/nonroot` | Add `emptyDir` mount at `/tmp` in deployment.yaml; revisit in Phase 3 if smoke test fails |
| `lookup` returns nil during `--dry-run=client` (no API server reachable) → password regenerates each render | Documented: `lookup` is best-effort; rotation only happens on real `helm install`, not on `template`/`dry-run=client` |
| Two PVCs (data + config) on RWO ties pod to one node | Acceptable — single-replica workload by design; documented in NOTES + chart README |
| `auth.enabled: false` lets users ship an unsafe release | Schema cannot prevent this without breaking valid bring-your-own-proxy-auth case; NOTES.txt fires a hard warning when `auth.enabled=false` |
| Image pulled by tag falls back to `appVersion` — bumping appVersion changes pulled image | Documented in chart README; users on strict supply-chain pin via `image.digest` |

## Cleanup (Phase 5)

- `state_clear` autopilot state via /oh-my-claudecode:cancel
- Keep `.omc/autopilot/spec-helm.md` and `.omc/plans/autopilot-impl-helm.md` as
  durable design history (consistent with the GHA workflow's spec-gha.md).
