<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-05-10 | Updated: 2026-05-10 -->

# workflows

## Purpose
GitHub Actions workflows for building, scanning, attesting, and
publishing the opencode distroless image to `ghcr.io/<owner>/<repo>`.

## Key Files

| File | Description |
|------|-------------|
| `build-push.yml` | Sole pipeline. Builds multi-arch (amd64+arm64) on push to `master` / `v*.*.*` tags / `workflow_dispatch`; verify-only (amd64, no push) on `pull_request` + `merge_group`. Trivy two-pass (CRITICAL gate + advisory SARIF), GitHub-native build-provenance + SPDX SBOM attestations on every pushed digest. |

## For AI Agents

### Working in this directory
- **Pin every third-party action to a 40-char commit SHA**, with the human-readable version in a `# v…` trailing comment. No floating tags. Bump SHAs deliberately (Renovate or manual cross-check against upstream tags).
- **`permissions:` is least-privilege** (`contents:read`, `packages:write`, `id-token:write`, `attestations:write`, `security-events:write`). Do not widen.
- **Verify vs publish split**: `IS_VERIFY` env predicate covers both `pull_request` and `merge_group`. Verify runs build amd64 only with `load: true`, `push: false`, `provenance: false`, no cache writes, no attestations. Publish runs (push to `master`, tags, dispatch) build both arches, push, write cache, attest. Don't conflate the two.
- **`subject-name` for `attest-build-provenance` / `attest-sbom` MUST be the untagged repo ref** (`steps.img.outputs.ref`, e.g. `ghcr.io/owner/repo`). Passing the tagged form (`steps.scan_target.outputs.ref`) yields `Error: Invalid image name` — attestations attach to digests, not tags.
- **`provenance: mode=max` + `load: true` is broken** — buildx produces an OCI image index that the Docker exporter rejects with `docker exporter does not currently support exporting manifest lists`. Verify builds explicitly set `provenance: false` to dodge this. Publish runs keep `mode=max` plus the layered GitHub-native attestations.
- **Default branch is `master`**, not `main`. The `push: branches:` list must include `master` or the post-merge run silently never fires (this happened — see PR #2).
- **Trivy DB cache** is keyed by ISO year-week (`trivy-db-$(date -u +%G-%V)`) to balance freshness against the public DB's rate limit.
- **`cache-to` is gated** to non-verify runs: `cache-to: ${{ env.IS_VERIFY != 'true' && 'type=gha,mode=max' || '' }}`. Untrusted PR runs can read but not poison the cache.
- **`pull_request: paths:`** is set so doc-only PRs don't trigger 15-minute QEMU-emulated arm64 builds. Keep that allow-list narrow (`Dockerfile`, `.dockerignore`, this workflow, `smoke-test.sh`).

### Testing requirements
- `actionlint` clean (Homebrew: `brew install actionlint`).
- `yamllint` clean with rules: line-length / document-start / truthy / comments-indentation / comments disabled.
- After non-trivial changes, push to a branch and confirm the verify run goes green before merging. Multi-arch publish path can only be exercised on `master` (or via `workflow_dispatch`).

### Common patterns
- Single-job pipeline; multi-platform via `docker/setup-qemu-action` + `docker/setup-buildx-action` + `docker/build-push-action` (no matrix).
- Image name lowercased once in the `Compute lowercase image path` step (`steps.img.outputs.ref`); reused everywhere a registry-safe untagged ref is needed.
- `steps.scan_target.outputs.ref` (first metadata-action tag) is reserved for Trivy `image-ref:` only.
- Cleanly skip post-build steps when build fails: gate `Trivy SARIF (advisory)` on `steps.build.outcome == 'success'`, `Upload Trivy SARIF` on `hashFiles('trivy-results.sarif') != ''`. Avoids cascading "could not parse reference: ." errors that hide the real failure.
- Concurrency: `group: build-push-${{ github.ref }}, cancel-in-progress: true` — prevents stacking runs on rapid pushes.
- `workflow_dispatch` inputs (`opencode_version`, `opencode_sha256_amd64`, `opencode_sha256_arm64`) are validated up-front against `^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.+-]+)?$` and `^[a-f0-9]{64}$` before the build runs.

## Dependencies

### Internal
- `Dockerfile` (../../Dockerfile) — multi-arch build target.
- `smoke-test.sh` (../../smoke-test.sh) — listed in `pull_request: paths:` so changes that affect the smoke test trigger CI.

### External (pinned commit SHAs)
- `actions/checkout` v4 — `34e114876b0b11c390a56381ad16ebd13914f8d5`
- `docker/setup-qemu-action` v3 — `c7c53464625b32c7a7e944ae62b3e17d2b600130`
- `docker/setup-buildx-action` v3 — `8d2750c68a42422c14e847fe6c8ac0403b4cbd6f`
- `docker/login-action` v3 — `c94ce9fb468520275223c153574b00df6fe4bcc9`
- `docker/metadata-action` v5 — `c299e40c65443455700f0fdfc63efafe5b349051`
- `docker/build-push-action` v6 — `10e90e3645eae34f1e60eeb005ba3a3d33f178e8`
- `aquasecurity/trivy-action` v0.36.0 — `ed142fd0673e97e23eac54620cfb913e5ce36c25`
- `actions/attest-build-provenance` v2 — `e8998f949152b193b063cb0ec769d69d929409be`
- `actions/attest-sbom` v2 — `bd218ad0dbcb3e146bd073d1d9c6d78e08aa8a0b`
- `github/codeql-action/upload-sarif` v3 — `7fd177fa680c9881b53cdab4d346d32574c9f7f4`
- `anchore/sbom-action` v0 — `e22c389904149dbc22b58101806040fa8d37a610`
- `actions/cache` v4 — `0057852bfaa89a56745cba8c7296529d2fc39830`

<!-- MANUAL: -->
