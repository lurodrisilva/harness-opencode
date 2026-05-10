# Spec — opencode headless server distroless image

## Goal

Produce a hardened, minimal Docker image that runs `opencode serve` (the headless
HTTP server flavor of opencode) on top of a distroless static **nonroot** base.

## Constraints (from user)

- Base image: `gcr.io/distroless/cc-debian12:nonroot`
  - **Revised from original `distroless/static`**. opencode 1.14.40 binaries
    (every linux-* variant) are dynamically linked. The musl variant needs
    `ld-musl-x86_64.so.1` + `libstdc++.so.6` + `libgcc_s.so.1`; the glibc
    variant needs `ld-linux-x86-64.so.2` + `libc.so.6` + `libpthread.so.0` +
    `libdl.so.2` + `libm.so.6`. `distroless/static` ships no dynamic loader,
    so it cannot run any of them. `distroless/cc-debian12:nonroot` ships
    glibc + libgcc + libstdc++ — exactly what the glibc variant needs — and
    keeps the no-shell, no-package-manager, fixed-uid posture of distroless.
- Target arch: `linux/amd64` only
- opencode version: pin `1.14.40`
- Auth: `OPENCODE_SERVER_PASSWORD` env var (warning logged when absent)
- State: a volume-mountable directory for opencode user data
- Provider creds: `OPENAI_API_KEY` and friends passed in via env

## Non-goals

- Multi-arch images (`linux/arm64`, baseline CPU variants) — explicitly deferred
- Custom signing / SBOM generation
- Embedding LLM provider credentials in the image
- Bundling a TUI client; only `opencode serve` matters

## Technical decisions

### opencode binary source

opencode-ai npm package ships per-platform native binaries via
`optionalDependencies`. For `linux/amd64` deployment on `distroless/cc` we use
the **glibc** variant:

```
opencode-linux-x64@1.14.40
```

ELF analysis (`PT_INTERP`, `DT_NEEDED`):

| Field           | Value                                                              |
|-----------------|--------------------------------------------------------------------|
| Interpreter     | `/lib64/ld-linux-x86-64.so.2`                                      |
| DT_NEEDED       | `libc.so.6`, `ld-linux-x86-64.so.2`, `libpthread.so.0`, `libdl.so.2`, `libm.so.6` |

All five DT_NEEDED entries are present in `gcr.io/distroless/cc-debian12:nonroot`,
so the binary runs unmodified.

Download URL (npm registry tarball, pinned by SHA-256):
```
https://registry.npmjs.org/opencode-linux-x64/-/opencode-linux-x64-1.14.40.tgz
sha256: f662a6ad1c6ecd6dee43e712c6b1ea814de38d27e2f983ca41e7f29b98f5f2ef
sha512 (npm integrity): Cb+keGDsjo1wyOJ2Kf+KOZWlJUs1fD/VmjYepl9Fv3KGqWQNhSOH/4kiwj3KHWwEMWroCtw5KnAFykiOgbsz8A==
```

### Image layout

Multi-stage Dockerfile:

1. **Builder stage** (`alpine:3.20` or `debian:bookworm-slim`):
   - Download the npm tarball with `curl` (or `wget`)
   - Extract `package/bin/opencode` → `/out/opencode`
   - Verify it runs (`./opencode --version` should print `1.14.40`)
   - Optionally verify SHA256 (capture from a successful build, then pin)

2. **Runtime stage** (`gcr.io/distroless/cc-debian12:nonroot`):
   - `COPY --from=builder --chown=nonroot:nonroot /out/opencode /usr/local/bin/opencode`
   - `USER nonroot` (already default on `:nonroot`, kept explicit)
   - `WORKDIR /home/nonroot`
   - `EXPOSE 4096`
   - `VOLUME ["/home/nonroot/.local/share/opencode", "/home/nonroot/.config/opencode"]`
   - `ENTRYPOINT ["/usr/local/bin/opencode"]`
   - `CMD ["serve", "--port", "4096", "--hostname", "0.0.0.0", "--print-logs"]`

### Why these CMD flags

- `--port 4096` — pin the random-port-by-default behaviour to a known value
  (opencode default `--port 0` would pick a random port at every restart, which
  breaks `EXPOSE` and any container orchestrator).
- `--hostname 0.0.0.0` — opencode default is `127.0.0.1`, useless inside a
  container (port-forwarding can't reach it from the host).
- `--print-logs` — without this flag, opencode writes logs to a file under the
  user data dir; we want them on stderr so `docker logs` works.

### Auth + secrets

- `OPENCODE_SERVER_PASSWORD` — required for any non-loopback deployment.
  Server logs `Warning: OPENCODE_SERVER_PASSWORD is not set; server is unsecured.`
  when missing. We document but do **not** default it — defaulting a password
  is a security anti-pattern.
- `OPENCODE_SERVER_USERNAME` — optional, defaults to `opencode`.
- Provider creds (`OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, etc.) — passed via env
  by the caller. No defaults.

### Persistence

Two paths matter for opencode state under `/home/nonroot`:

| Path                                  | Purpose                              |
|---------------------------------------|--------------------------------------|
| `/home/nonroot/.local/share/opencode` | Sessions, history, project state     |
| `/home/nonroot/.config/opencode`      | User config (config.json), auth tokens |

Both declared as VOLUMEs so users can persist them across container lifecycle.

### Healthcheck

`HEALTHCHECK` instruction can't be used reliably here because `distroless/static`
ships no `curl` / `wget` / `nc` to call. Document instead:

> Health probe: `GET /global/health` from outside the container (k8s
> `httpGet` probe, ALB target group, etc.).

This is the standard distroless tradeoff.

## Files to produce

- `Dockerfile` — the image definition
- `.dockerignore` — keep build context clean
- `README.md` — how to build, run, probe, and troubleshoot
- `smoke-test.sh` — host-side smoke test that builds the image, starts a
  container, hits `/global/health` and `/doc`, then tears down.

## Acceptance criteria (for Phase 3 QA)

1. `docker build -t opencode:1.14.40 .` succeeds.
2. `docker run --rm opencode:1.14.40 --version` prints `1.14.40`.
3. Container starts, listens on `0.0.0.0:4096` as nonroot user (uid 65532).
4. `curl http://127.0.0.1:4096/global/health` returns
   `{"healthy":true,"version":"1.14.40"}`.
5. `curl http://127.0.0.1:4096/doc` returns OpenAPI 3.1.1 JSON
   starting with `{"openapi":"3.1.1"`.
6. `docker run` with `OPENCODE_SERVER_PASSWORD=…` set causes the unsecured
   warning to disappear from container logs.
7. Final image size < 60 MB (sanity check; opencode binary alone is ~50 MB).

## Acceptance criteria (for Phase 4 review)

- **Architect**: Dockerfile uses multi-stage; runtime layer minimal; CMD flags
  match spec; volumes declared correctly.
- **Security-reviewer**: nonroot enforced; no secrets baked in; tarball download
  verified (SHA256 or signature) where feasible; no `--no-verify-ssl`-style
  shortcuts; no shell in runtime image; no SUID bits.
- **Code-reviewer**: Dockerfile readable; ARGs labelled; layer ordering optimal
  for cache hit rate; comments explain non-obvious choices (volume paths, port
  pinning rationale, --print-logs).
