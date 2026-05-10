<!-- Generated: 2026-05-10 | Updated: 2026-05-10 -->

# harness-opencode

## Purpose
Hardened, distroless container image for the [opencode](https://opencode.ai)
headless AI coding agent server, plus the GitHub Actions pipeline that
builds, scans, attests, and publishes it to GHCR. The image runs
`opencode serve` on `gcr.io/distroless/cc-debian12:nonroot` with a
SHA-256-pinned binary, fixed nonroot UID (65532), and no shell or
package manager.

## Key Files

| File | Description |
|------|-------------|
| `Dockerfile` | Multi-stage, multi-arch (amd64+arm64) build of the distroless image. Verifies the per-arch opencode tarball SHA-256, copies the binary into a distroless/cc runtime stage, pre-creates the nonroot home tree to dodge a Docker Desktop / macOS arm64 EACCES quirk. |
| `.dockerignore` | Allowlist (`!Dockerfile`, `!.dockerignore`) — everything else excluded from build context. |
| `smoke-test.sh` | 6-check local validation: builds image, runs container on `127.0.0.1:14096`, asserts `/global/health` JSON, OpenAPI 3.1 `/doc`, nonroot uid, server-listening log, unsecured-warning log. Knobs: `SKIP_BUILD`, `KEEP_IMAGE`, `HOST_PORT`. |
| `README.md` | Runtime contract, security defaults, transport (TLS), build-arg + multi-arch buildx commands, supply-chain provenance, k8s probe snippet, CI section. |
| `.gitignore` | Standard editor / OS / OMC state ignores; `*.tgz` to skip downloaded tarballs. |

## Subdirectories

| Directory | Purpose |
|-----------|---------|
| `.github/` | GitHub Actions workflows (see `.github/AGENTS.md`). |
| `.omc/` | Agent session state (autopilot specs, plans, learned skills). Not code; deliberately excluded from the AGENTS.md hierarchy. |

## For AI Agents

### Working in this directory
- The image is **distroless** — no shell, no curl. Do not add `RUN` instructions, `HEALTHCHECK`, or shell-form `ENTRYPOINT`/`CMD` to the runtime stage. Anything dynamic must be re-architected.
- The opencode binary is **dynamically linked glibc**; runtime base is `gcr.io/distroless/cc-debian12:nonroot` (NOT `static`). Reverting to `/static` breaks — the dynamic loader is missing. ELF analysis lives in `.omc/autopilot/spec.md`.
- Both arches are baked in: `OPENCODE_TARBALL_SHA256_AMD64` and `_ARM64`. Bumping `OPENCODE_VERSION` requires recomputing both:
  ```sh
  curl -fsSL "https://registry.npmjs.org/opencode-linux-x64/-/opencode-linux-x64-${VERSION}.tgz"   | sha256sum
  curl -fsSL "https://registry.npmjs.org/opencode-linux-arm64/-/opencode-linux-arm64-${VERSION}.tgz" | sha256sum
  ```
- `OPENCODE_SERVER_PASSWORD` must be set before exposing the container off-host. The unsecured server is RCE-equivalent. Always front with a TLS-terminating reverse proxy in production.
- The pre-created `/home/nonroot/{...}` tree in the builder stage is a workaround for `EACCES` on Docker Desktop / macOS arm64 emulating linux/amd64. Do not delete that block.
- Default branch is `master`, not `main`. CI `push: branches:` and PR base must reflect that.

### Testing requirements
- Local: `./smoke-test.sh` — full round-trip on amd64.
- CI: `pull_request` + `merge_group` runs validate the build (amd64 only, no push). Push to `master` and `v*.*.*` tags publish the multi-arch image with provenance + SBOM attestations.
- Verify a published image: `gh attestation verify oci://ghcr.io/<owner>/<repo>:<tag> --owner <owner>`.

### Common patterns
- Multi-stage Dockerfiles: builder stage is full Debian (apt + curl + sha256sum + tar), runtime is distroless. Nothing from the builder reaches runtime except the verified binary and the pre-created home tree.
- Supply-chain trust chain: per-arch SHA-256 pin in the Dockerfile + GitHub-native `attest-build-provenance` + `attest-sbom` on every published digest.
- Branch model: feature branch → PR → squash-merge to `master`.

## Dependencies

### External
- `gcr.io/distroless/cc-debian12:nonroot` — runtime base (glibc + libgcc + libstdc++).
- `debian:bookworm-slim` — builder stage.
- npm registry tarballs `opencode-linux-x64` / `opencode-linux-arm64` — verified by SHA-256.
- GHCR (`ghcr.io/<owner>/<repo>`) — image publication target.

<!-- MANUAL: -->
