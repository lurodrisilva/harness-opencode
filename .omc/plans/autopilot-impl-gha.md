# Plan — GHA build/push workflow + Dockerfile multi-arch

Spec: `.omc/autopilot/spec-gha.md`

## Order of edits (one PR / one commit)

1. **Dockerfile** — refactor for multi-arch
   1. Drop the `TARGETARCH amd64`-only guard.
   2. Replace the single `OPENCODE_TARBALL_SHA256` ARG with two:
      `OPENCODE_TARBALL_SHA256_AMD64`, `OPENCODE_TARBALL_SHA256_ARM64`,
      both defaulted to the SHAs in the spec.
   3. In the download `RUN`, `case "${TARGETARCH}"` → pick
      `opencode-linux-x64`+amd64 SHA or `opencode-linux-arm64`+arm64 SHA.
      Fail with a clear error on any other value.
   4. Pre-create-`/home/nonroot` block and runtime stage stay untouched.

2. **`.github/workflows/build-push.yml`** — new
   - `on:` push (main, v*), pull_request, workflow_dispatch (with optional
     version + sha override inputs).
   - `permissions:` minimal (`contents:read`, `packages:write`,
     `id-token:write`, `attestations:write`, `security-events:write`).
   - Single `build` job on `ubuntu-24.04`.
   - Steps in order:
     1. `actions/checkout`
     2. `docker/setup-qemu-action`
     3. `docker/setup-buildx-action`
     4. `docker/login-action` (skip on PR)
     5. `docker/metadata-action` (semver + sha + branch + pr tags)
     6. Trivy DB cache (`actions/cache`) keyed by week-of-year — Aqua's
        public DB is rate-limited; weekly cache balances freshness vs
        rate limits.
     7. `docker/build-push-action`
        - `platforms: linux/amd64,linux/arm64`
        - `push: ${{ github.event_name != 'pull_request' }}`
        - `load: ${{ github.event_name == 'pull_request' }}` so PR builds
          can be Trivy-scanned locally.
        - Cache via `type=gha`.
        - `provenance: mode=max`, `sbom: false` (we attest separately).
        - `build-args` carry version + per-arch SHAs.
        - `outputs.imageid` and `outputs.digest` captured for downstream
          steps.
     8. Trivy gate run (CRITICAL only, `exit-code: 1`). On PR, points at
        the locally loaded image; on push, points at the digest just
        pushed.
     9. Trivy SARIF run (all severities, `exit-code: 0`). Artifact:
        `trivy-results.sarif`.
     10. `github/codeql-action/upload-sarif` to populate the Security tab.
     11. `anchore/sbom-action` to generate `sbom.spdx.json` (skip on PR).
     12. `actions/attest-build-provenance` (skip on PR).
     13. `actions/attest-sbom` (skip on PR).

3. **README.md** — append/edit
   - "Multi-arch" note: image now ships `linux/amd64` and `linux/arm64`.
   - "CI / GHA" section:
     - Brief description of the workflow.
     - How to verify a published image:
       ```sh
       gh attestation verify oci://ghcr.io/<owner>/<repo>:<tag> \
         --repo <owner>/<repo>
       ```
     - How to inspect attestations and SBOM:
       ```sh
       gh attestation list ghcr.io/<owner>/<repo>:<tag>
       cosign download attestation ghcr.io/<owner>/<repo>:<tag>
       ```
     - Note that the `--build-arg OPENCODE_TARBALL_SHA256` arg in the
       earlier README example splits into `…_AMD64` and `…_ARM64`.

## Implementation knobs / open decisions

- **Runner**: `ubuntu-24.04` (current LTS Actions runner image). Avoid
  `ubuntu-latest` — it floats and rebuilds break opaquely.
- **Trivy DB cache key**: `trivy-db-${{ env.YEAR_WEEK }}` so we miss cache
  at most once a week. Set `YEAR_WEEK` via `date -u +"%G-%V"`.
- **Tag strategy** outputs from `metadata-action`:
  - on tag `v1.14.40-1`: `1.14.40-1`, `1.14.40`, `1.14`, `latest`.
  - on push `main`: `main`, `sha-abc1234` (no `latest`, to keep
    `latest` semver-driven).
  - on PR: `pr-<num>` (used only for local load + Trivy scan; never
    pushed).
- **Trivy on PR**: requires `load: true` in build-push so the image lands
  in the local Docker daemon. Multi-arch + load is mutually exclusive in
  buildx (load only supports single-platform). Workaround: on PR run only
  `linux/amd64`, on push run both arches. Encode this with a `platforms`
  expression: `${{ github.event_name == 'pull_request' && 'linux/amd64' || 'linux/amd64,linux/arm64' }}`.

## Risks / mitigations

| Risk                                                                | Mitigation                                                                |
|---------------------------------------------------------------------|---------------------------------------------------------------------------|
| arm64 binary breaks unexpectedly (different glibc deps, etc.)       | spec.md ELF check confirms same DT_NEEDED set as amd64 → safe on /cc       |
| QEMU emulated arm64 build is very slow (>15 min)                    | gha cache + `--cache-to type=gha,mode=max` reduces incremental rebuild     |
| Trivy DB rate limits in CI                                          | Cache the DB weekly (`actions/cache` step before Trivy scan)              |
| Action SHAs drift behind upstream fixes                             | Add Renovate config (out of scope; documented in README follow-up)        |
| GitHub package visibility defaults to private                       | Documented in README; users opt in to public via repo→packages settings   |
| `gh attestation verify` requires gh ≥ 2.49                          | Documented in README                                                       |

## Acceptance signals

Phase 3 (QA):
- `actionlint` (or YAML lint) passes against the workflow.
- Local `smoke-test.sh` (amd64) still passes after Dockerfile refactor.
- Optional: `docker buildx build --platform linux/arm64 --load` (or just
  `--platform linux/arm64` with a smoke-test under QEMU) confirms the
  arm64 path actually picks the right binary and SHA.

Phase 4 (review):
- Architect: workflow is complete, multi-arch correctly handled, each
  attestation step targets the pushed digest.
- Security: minimum permissions, SHA-pinned actions, secrets scoped via
  `${{ secrets.GITHUB_TOKEN }}` only, no PR-triggered push, no privileged
  workflow.
- Code-review: YAML readable, comments where decisions are non-obvious,
  no copy-pasted boilerplate, action versions named in comments.
