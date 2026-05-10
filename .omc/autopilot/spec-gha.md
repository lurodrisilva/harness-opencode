# Spec — GitHub Actions workflow for opencode distroless image

## Goal

Build the Dockerfile in this repo and publish multi-arch images to
`ghcr.io/<owner>/<repo>` with strong supply-chain controls: SHA-pinned
actions, GitHub-native build provenance + SBOM attestations, Trivy CVE
scanning with a CRITICAL gate, and least-privilege `permissions:`.

## Constraints (from user)

- Triggers: `push` to `main`, `push` of `v*` tags, `pull_request`,
  `workflow_dispatch`.
- Trivy gate: fail the workflow only on `CRITICAL` CVEs. Upload everything
  to GitHub Security tab (SARIF) for visibility.
- Attestation: GitHub-native — `actions/attest-build-provenance` plus
  `actions/attest-sbom`. Verifiable with `gh attestation verify`.
- Multi-arch: build `linux/amd64` **and** `linux/arm64`. **Dockerfile must
  be modified** to support both arches — currently the binary URL is
  hardcoded to `opencode-linux-x64` and there's a `TARGETARCH` guard
  rejecting non-amd64.
- Single workflow file. Pinned to action commit SHAs (with version comment
  next to each pin) for supply-chain safety.

## Non-goals

- Cosign-based signing (GitHub-native attestations cover this; no need to
  manage keypairs or KMS).
- Slim/scratch base swap (already covered by the image spec).
- Image-tag rotation policy / GitHub package retention rules.
- Runtime testing of arm64 builds in CI (we'd need a self-hosted arm runner
  or QEMU-based smoke; out of scope for the first iteration).

## Dockerfile changes required

Currently:

```dockerfile
ARG OPENCODE_TARBALL_SHA256=f662a6ad...   # hardcoded amd64 sha
RUN test "${TARGETARCH:-amd64}" = "amd64" || exit 1
RUN curl ... opencode-linux-x64-${OPENCODE_VERSION}.tgz
```

After:

- Drop the amd64-only fail-fast.
- Add a per-arch `case "${TARGETARCH}"` that maps:
  - `amd64` → `opencode-linux-x64`, `OPENCODE_TARBALL_SHA256_AMD64` (default
    `f662a6ad1c6ecd6dee43e712c6b1ea814de38d27e2f983ca41e7f29b98f5f2ef`)
  - `arm64` → `opencode-linux-arm64`, `OPENCODE_TARBALL_SHA256_ARM64`
    (default `10d4ad7c8000427f137ac835dcc8b7960ce7ebda7c1fd87e594e5f4db4e9d9f7`)
  - anything else → fail fast with a useful message.
- Both binaries are dynamically linked glibc; `distroless/cc-debian12:nonroot`
  ships glibc + libgcc + libstdc++ for both arches, so the same runtime
  base works.
- Pre-create-`/home/nonroot` tree logic stays unchanged.

## Workflow structure

Single file: `.github/workflows/build-push.yml`

```yaml
name: Build, scan, attest, push

on:
  push:
    branches: [main]
    tags:    ['v*.*.*']
  pull_request:
  workflow_dispatch:
    inputs:
      opencode_version:
        description: opencode version (npm tag) to bake into the image
        required: false
      opencode_sha256_amd64:
        description: SHA-256 of opencode-linux-x64-${version}.tgz
        required: false
      opencode_sha256_arm64:
        description: SHA-256 of opencode-linux-arm64-${version}.tgz
        required: false

permissions:
  contents:        read     # checkout
  packages:        write    # push to ghcr
  id-token:        write    # OIDC for Sigstore attestations
  attestations:    write    # GitHub-native attestations
  security-events: write    # Trivy SARIF upload

jobs:
  build:
    runs-on: ubuntu-24.04
    steps:
      - checkout
      - setup-qemu                              # arm64 emulation on amd64 runner
      - setup-buildx
      - login to ghcr (skipped on PR)
      - metadata-action → tag list
      - build-push-action (push: !PR, multi-platform, sbom: false here)
      - trivy-action on built image (mode=image, severity gate)
      - upload-sarif
      - generate spdx SBOM (anchore/sbom-action)
      - attest-build-provenance (subject = pushed digest)
      - attest-sbom (subject = pushed digest, file = spdx)
```

## Detailed step contracts

### checkout
- `actions/checkout@<SHA>  # v4`
- Default: full clone of the PR head, no submodules.

### docker/setup-qemu-action
- Pinned. Configures binfmt for cross-arch builds.
- `platforms: linux/amd64,linux/arm64`.

### docker/setup-buildx-action
- Pinned.
- Use a buildkit container driver (default).

### docker/login-action — ghcr
- Conditional: `if: github.event_name != 'pull_request'`.
- `registry: ghcr.io`, `username: ${{ github.actor }}`, `password: ${{ secrets.GITHUB_TOKEN }}`.

### docker/metadata-action
- `images: ghcr.io/${{ github.repository }}`.
- Tags:
  - `type=ref,event=branch`     → `main`
  - `type=ref,event=pr`         → `pr-123`
  - `type=semver,pattern={{version}}` → `1.14.40`
  - `type=semver,pattern={{major}}.{{minor}}` → `1.14`
  - `type=raw,value=latest,enable={{ is_default_branch }}` (or restrict to tags)
  - `type=sha,prefix=sha-,format=short`
- Provides `outputs.tags`, `outputs.labels`, `outputs.annotations`.

### docker/build-push-action
- `context: .`
- `file: Dockerfile`
- `platforms: linux/amd64,linux/arm64`
- `push: ${{ github.event_name != 'pull_request' }}`
- `tags: ${{ steps.meta.outputs.tags }}`
- `labels: ${{ steps.meta.outputs.labels }}`
- `annotations: ${{ steps.meta.outputs.annotations }}`
- `cache-from: type=gha`, `cache-to: type=gha,mode=max`
- `provenance: mode=max`
- `sbom: false` — we generate SBOMs separately via anchore so we can pass
  them to `attest-sbom`. Setting `sbom: true` here embeds an in-toto SBOM
  attestation in the index but doesn't generate a separate file.
- `build-args:`
  - `OPENCODE_VERSION=${{ inputs.opencode_version || env.DEFAULT_VERSION }}`
  - `OPENCODE_TARBALL_SHA256_AMD64=…`
  - `OPENCODE_TARBALL_SHA256_ARM64=…`
- `outputs: type=image,name=target,push-by-digest=true,name-canonical=true,push=...`
  - When pushing, the action exports `imageid` and `digest` outputs we can
    feed to attest steps.

### Trivy scan
- `aquasecurity/trivy-action@<SHA>  # v0.36.0`.
- Run against the built image (use the `imageid` output from build-push, OR
  re-run `trivy image` against the digest pushed to ghcr — pulls back).
- Easier: run `mode: image`, `image-ref: <ghcr.io/...>:<tag>` from metadata,
  using the first tag.
- Two passes:
  1. `severity: CRITICAL`, `exit-code: 1` — the gate.
  2. `severity: CRITICAL,HIGH,MEDIUM,LOW`, `format: sarif`,
     `output: trivy-results.sarif`, `exit-code: 0` — for SARIF upload.

  Both runs share Trivy DB cache (workflow-level cache or step `vuln-type:
  os,library`). Cache the vulnerability DB between runs to avoid the rate-
  limited public download.
- Skip on PR? No — PRs benefit most from scanning. But: the scan runs
  against a built image. If push is disabled for PRs, Trivy runs against
  the OCI tarball or local image instead. Use the `load: true` option in
  build-push-action on PR to make the image available locally for Trivy.

### SARIF upload
- `github/codeql-action/upload-sarif@<SHA>  # v3`.
- Path: `trivy-results.sarif`.
- Category: `trivy-${{ matrix.platform || 'multiarch' }}`.

### SBOM generation
- `anchore/sbom-action@<SHA>  # v0`.
- Generate SPDX-JSON for the pushed image (`format: spdx-json`,
  `image: ghcr.io/...:<digest>`, `output-file: sbom.spdx.json`).
- Skip on PR (no pushed image to scan).

### attest-build-provenance
- `actions/attest-build-provenance@<SHA>  # v2`.
- Inputs:
  - `subject-name: ghcr.io/${{ github.repository }}`
  - `subject-digest: ${{ steps.build.outputs.digest }}`
  - `push-to-registry: true` (so consumers get the attestation alongside
    the image manifest).
- Skip on PR.

### attest-sbom
- `actions/attest-sbom@<SHA>  # v2`.
- Inputs:
  - `subject-name: ghcr.io/${{ github.repository }}`
  - `subject-digest: ${{ steps.build.outputs.digest }}`
  - `sbom-path: sbom.spdx.json`
  - `push-to-registry: true`.
- Skip on PR.

## Acceptance criteria

1. Workflow file passes `actionlint` and `yamllint` locally.
2. All third-party actions pinned to commit SHAs with version comments.
3. `permissions:` block uses minimum required scopes (no global `contents:
   write`, no `repo` blanket).
4. `pull_request` trigger builds but does **not** push, log into ghcr, sign,
   or attest.
5. `push` to `main` and `v*` tags push multi-arch images and produce
   verifiable provenance + SBOM attestations.
6. `gh attestation verify --owner <owner> ghcr.io/<owner>/<repo>:<tag>`
   should succeed against published images (this is asserted by the
   workflow design; live verification belongs to a follow-up).
7. Trivy fails the run on CRITICAL CVEs, uploads SARIF for everything else,
   does not block on HIGH/MEDIUM/LOW.
8. Dockerfile builds for both `linux/amd64` and `linux/arm64` after the
   per-arch SHA dispatch refactor.
9. Local smoke test (`smoke-test.sh`) still passes against the
   refactored Dockerfile on amd64 (existing acceptance test).

## Files produced / changed

- New: `.github/workflows/build-push.yml`
- Edit: `Dockerfile` (per-arch binary dispatch)
- Edit: `README.md` (workflow + multi-arch sections, attestation verify
  command, ghcr usage)
- New: `.omc/autopilot/spec-gha.md` (this spec)
- New: `.omc/plans/autopilot-impl-gha.md` (next phase)

## Pinned action commit SHAs (resolved 2026-05-09)

| Action                                  | Tag      | Commit SHA                                |
|-----------------------------------------|----------|-------------------------------------------|
| actions/checkout                        | v4       | 34e114876b0b11c390a56381ad16ebd13914f8d5  |
| docker/setup-qemu-action                | v3       | c7c53464625b32c7a7e944ae62b3e17d2b600130  |
| docker/setup-buildx-action              | v3       | 8d2750c68a42422c14e847fe6c8ac0403b4cbd6f  |
| docker/login-action                     | v3       | c94ce9fb468520275223c153574b00df6fe4bcc9  |
| docker/metadata-action                  | v5       | c299e40c65443455700f0fdfc63efafe5b349051  |
| docker/build-push-action                | v6       | 10e90e3645eae34f1e60eeb005ba3a3d33f178e8  |
| aquasecurity/trivy-action               | v0.36.0  | ed142fd0673e97e23eac54620cfb913e5ce36c25  |
| actions/attest-build-provenance         | v2       | e8998f949152b193b063cb0ec769d69d929409be  |
| actions/attest-sbom                     | v2       | bd218ad0dbcb3e146bd073d1d9c6d78e08aa8a0b  |
| github/codeql-action (upload-sarif)     | v3       | 7fd177fa680c9881b53cdab4d346d32574c9f7f4  |
| anchore/sbom-action                     | v0       | e22c389904149dbc22b58101806040fa8d37a610  |
