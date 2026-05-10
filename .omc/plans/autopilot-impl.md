# Implementation Plan — opencode distroless docker image

Reference: `.omc/autopilot/spec.md`

## Files to produce (4)

1. `Dockerfile` — multi-stage, distroless/cc nonroot runtime
2. `.dockerignore` — minimal build context
3. `README.md` — build / run / probe / persist
4. `smoke-test.sh` — local end-to-end build + container start + curl-based health check + teardown

## Dockerfile structure

### Stage 1 — `builder`

- `FROM debian:bookworm-slim AS builder` — needs `curl` and shell to fetch and verify
- `ARG OPENCODE_VERSION=1.14.40`
- `ARG OPENCODE_TARBALL_SHA256=f662a6ad1c6ecd6dee43e712c6b1ea814de38d27e2f983ca41e7f29b98f5f2ef`
- `RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates && rm -rf /var/lib/apt/lists/*`
- Download:
  ```
  curl -fsSL -o /tmp/opencode.tgz \
    "https://registry.npmjs.org/opencode-linux-x64/-/opencode-linux-x64-${OPENCODE_VERSION}.tgz"
  ```
- Verify SHA-256:
  ```
  echo "${OPENCODE_TARBALL_SHA256}  /tmp/opencode.tgz" | sha256sum -c -
  ```
- Extract just the binary:
  ```
  tar -xzf /tmp/opencode.tgz -C /tmp package/bin/opencode \
    && mv /tmp/package/bin/opencode /out/opencode \
    && chmod 0755 /out/opencode
  ```

### Stage 2 — runtime

- `FROM gcr.io/distroless/cc-debian12:nonroot`
- `LABEL org.opencontainers.image.title="opencode-server"`
- `LABEL org.opencontainers.image.version="${OPENCODE_VERSION}"`
- `LABEL org.opencontainers.image.source="https://opencode.ai"`
- `LABEL org.opencontainers.image.licenses="MIT"`
- `LABEL org.opencontainers.image.documentation="https://opencode.ai/docs/server/"`
- `COPY --from=builder --chown=nonroot:nonroot /out/opencode /usr/local/bin/opencode`
- `USER nonroot` (default on `:nonroot` tag, kept explicit)
- `WORKDIR /home/nonroot`
- `EXPOSE 4096`
- `VOLUME ["/home/nonroot/.local/share/opencode", "/home/nonroot/.config/opencode"]`
- `ENTRYPOINT ["/usr/local/bin/opencode"]`
- `CMD ["serve", "--port", "4096", "--hostname", "0.0.0.0", "--print-logs"]`

## .dockerignore

Trivial. Keep build context minimal:
```
.git
.omc
*.md
smoke-test.sh
```

(README/smoke-test live at repo root but don't need to be in build context — `Dockerfile` is fully self-contained, fetches the binary at build time.)

## README.md outline

- One-paragraph "what this is"
- Build: `docker build -t opencode:1.14.40 .`
- Build with version override: `docker build --build-arg OPENCODE_VERSION=1.14.40 --build-arg OPENCODE_TARBALL_SHA256=… -t opencode:1.14.40 .`
- Run (loopback / dev):
  ```
  docker run --rm -p 4096:4096 opencode:1.14.40
  ```
- Run (secured):
  ```
  docker run --rm \
    -p 4096:4096 \
    -e OPENCODE_SERVER_PASSWORD="$(openssl rand -hex 32)" \
    -e OPENAI_API_KEY="$OPENAI_API_KEY" \
    -v opencode-data:/home/nonroot/.local/share/opencode \
    -v opencode-config:/home/nonroot/.config/opencode \
    opencode:1.14.40
  ```
- Health probe: `curl -s http://localhost:4096/global/health`
- API spec: `curl -s http://localhost:4096/doc | jq .`
- Why distroless/cc not /static: short note pointing at the spec.
- Why volumes for both `~/.local/share/opencode` and `~/.config/opencode`.
- k8s probe snippet:
  ```yaml
  livenessProbe:
    httpGet: { path: /global/health, port: 4096 }
  ```

## smoke-test.sh outline

POSIX `bash`. Steps:
1. `docker build -t opencode-smoke:test .`
2. `docker run -d --name opencode-smoke -p 14096:4096 opencode-smoke:test` (host port 14096 to avoid clashing with any local 4096)
3. Wait (up to 30s) for `/global/health` to return 200 with `"healthy":true`
4. Curl `/doc`, assert response body starts with `{"openapi":"3.1.1"`
5. Verify the running PID inside the container is owned by `uid=65532` (`nonroot`)
6. `docker logs` should NOT contain `Cannot find` / `Error loading` / segfault
7. Tear down: `docker rm -f opencode-smoke && docker rmi opencode-smoke:test`
8. Exit 0 on success, non-zero with diagnostic on failure

## Risks / mitigations

| Risk                                                         | Mitigation                                              |
|--------------------------------------------------------------|---------------------------------------------------------|
| npm tarball changes (rebuilds break)                         | SHA-256 pin in ARG; build fails fast on mismatch        |
| Binary requires unexpected lib not in `/cc`                  | Smoke test catches it (Phase 3); fall back to bundling   |
| `nonroot` UID drift between distroless versions              | Image documents 65532 explicitly in README              |
| `/home/nonroot` not writeable when no volume mount           | distroless `:nonroot` ships `/home/nonroot` owned 65532 |
| Build context bloat from large repo files                    | `.dockerignore` excludes `.git` and unneeded files      |

## Out of scope (deferred)

- Multi-arch (`linux/arm64`)
- SBOM / cosign signing
- HEALTHCHECK instruction (no curl in distroless/cc — caller probes externally)
- Renovate / dependabot config for version bumps

## Approval gate (Phase 4)

Plan is approved when:
- Architect confirms Dockerfile structure matches spec
- Security-reviewer confirms nonroot, no secrets, SHA-pinned dl
- Code-reviewer confirms layer ordering + comments
