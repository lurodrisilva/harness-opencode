# opencode headless server — distroless image

Hardened Docker image that runs [`opencode serve`](https://opencode.ai/docs/server/)
on top of `gcr.io/distroless/cc-debian12:nonroot`. No shell, no package
manager, fixed nonroot UID (65532), pinned binary by SHA-256.

> ## ⚠️ Read first — security defaults
>
> The image runs `opencode serve --hostname 0.0.0.0` by default. opencode
> serves AI agent tooling that, once authenticated, can execute commands and
> use upstream provider credentials. **An exposed unauthenticated opencode
> instance is RCE-equivalent.**
>
> Hard rules:
>
> 1. Always set `OPENCODE_SERVER_PASSWORD` before exposing the container
>    off-host. Without it the server logs `Warning: OPENCODE_SERVER_PASSWORD
>    is not set; server is unsecured.` and stays open.
> 2. Never publish port 4096 directly to the public internet. Terminate TLS
>    at a reverse proxy (nginx, Caddy, Traefik, k8s ingress) — opencode
>    speaks plain HTTP, so basic-auth credentials and provider API keys
>    travel in clear without a TLS terminator in front.
> 3. For local dev, bind the published port to loopback only:
>    `-p 127.0.0.1:4096:4096`.

## Quick start (loopback / dev)

```sh
docker build -t opencode:1.14.40 .
docker run --rm -p 127.0.0.1:4096:4096 opencode:1.14.40
curl -s http://127.0.0.1:4096/global/health
# {"healthy":true,"version":"1.14.40"}
```

This binds the published port only on the host loopback so other machines on
the LAN cannot reach the unauthenticated server.

## Production-style run

```sh
docker run -d --name opencode \
  -p 127.0.0.1:4096:4096 \
  -e OPENCODE_SERVER_PASSWORD="$(openssl rand -hex 32)" \
  -e OPENAI_API_KEY="$OPENAI_API_KEY" \
  -e ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
  -v opencode-data:/home/nonroot/.local/share/opencode \
  -v opencode-config:/home/nonroot/.config/opencode \
  opencode:1.14.40
```

Then put a TLS-terminating reverse proxy in front of `127.0.0.1:4096`. See
[Transport](#transport) below.

| Env var                    | Purpose                                                          |
|----------------------------|------------------------------------------------------------------|
| `OPENCODE_SERVER_PASSWORD` | HTTP basic auth password. Leaving unset = open server (warned).  |
| `OPENCODE_SERVER_USERNAME` | HTTP basic auth username. Default `opencode`.                    |
| `OPENAI_API_KEY` etc.      | Provider creds, passed through to opencode at runtime.           |

Rotating `OPENCODE_SERVER_PASSWORD` requires restarting the container — the
new value is read once at startup. All in-flight clients will need to
re-authenticate after the restart.

| Volume                                     | What lives there                       |
|--------------------------------------------|----------------------------------------|
| `/home/nonroot/.local/share/opencode`      | Sessions, history, project state       |
| `/home/nonroot/.config/opencode`           | User config, provider auth tokens      |

## Transport

opencode serves plain HTTP. HTTP basic auth credentials and any provider API
keys passed through HTTP request bodies travel in clear. **Never expose port
4096 directly to the public internet.** Always front the container with a
TLS-terminating reverse proxy.

Examples (configure as fits your stack):

- Caddy: `reverse_proxy 127.0.0.1:4096` under an `https://` host block.
- nginx / Traefik / Envoy: standard upstream block pointing at
  `127.0.0.1:4096`.
- Kubernetes: `Service` of type `ClusterIP` + an `Ingress` with TLS.

When fronted, also configure the proxy to:

- Strip / canonicalise unknown URL paths. opencode returns HTTP 200 with an
  HTML SPA page for any unrecognised path (`/health`, `/openapi.json`, …)
  instead of HTTP 404. That's harmless on its own but defeats path-based WAF
  rules and confuses some HTTP caches; configure the proxy to allow only
  known endpoints (`/global/health`, `/doc`, `/event`, `/tui`, plus any TUI
  routes you actually use).
- Terminate basic auth at the proxy if you'd rather hide
  `OPENCODE_SERVER_PASSWORD` from clients entirely (the proxy then injects
  the correct `Authorization` header on each request).

## Build args

```sh
docker build \
  --build-arg OPENCODE_VERSION=1.14.40 \
  --build-arg OPENCODE_TARBALL_SHA256=f662a6ad1c6ecd6dee43e712c6b1ea814de38d27e2f983ca41e7f29b98f5f2ef \
  -t opencode:1.14.40 .
```

When bumping `OPENCODE_VERSION`, recompute the SHA-256:

```sh
curl -fsSL "https://registry.npmjs.org/opencode-linux-x64/-/opencode-linux-x64-${VERSION}.tgz" \
  | sha256sum
```

The SHA pin protects against tarball mutation in transit but does **not**
detect a compromised npm publish (a malicious upstream owner can republish a
new tarball with a new hash). For higher trust, additionally verify npm
provenance attestations before bumping:

```sh
npm view "opencode-linux-x64@${VERSION}" --json | jq '.dist.attestations'
npm audit signatures   # in a workspace that depends on opencode-ai
```

opencode publishes from GitHub Actions with provenance enabled, so you can
confirm the tarball came from the expected source repo at the expected
commit. Cross-check against the matching tag at
<https://github.com/sst/opencode/releases>.

## Endpoints (verified against opencode 1.14.40)

| Path             | Use                                                                  |
|------------------|----------------------------------------------------------------------|
| `/global/health` | JSON health probe → `{"healthy":true,"version":"1.14.40"}`           |
| `/doc`           | OpenAPI 3.1 spec (JSON, despite docs site claiming HTML)             |
| `/event`         | Server-sent events; first event = `server.connected`                 |
| `/tui`           | Used by IDE plugins to drive the TUI client                          |

⚠️ Unknown paths (`/health`, `/openapi.json`, …) return `200` with an HTML SPA
page instead of `404`. Status-code-only probes give false positives — assert
on `Content-Type` or response body.

## Kubernetes probe snippet

```yaml
livenessProbe:
  httpGet: { path: /global/health, port: 4096 }
  initialDelaySeconds: 5
  periodSeconds: 10
readinessProbe:
  httpGet: { path: /global/health, port: 4096 }
  initialDelaySeconds: 2
  periodSeconds: 5
```

(There is no `HEALTHCHECK` in the Dockerfile because distroless ships no
`curl` / `wget` to invoke; the orchestrator probes externally.)

## Why distroless/cc and not distroless/static

opencode 1.14.40 binaries are Bun-compiled but **dynamically linked**.
- `opencode-linux-x64` (glibc) needs `ld-linux-x86-64.so.2`, `libc.so.6`,
  `libpthread.so.0`, `libdl.so.2`, `libm.so.6`.
- `opencode-linux-x64-musl` needs `ld-musl-x86_64.so.1`, `libstdc++.so.6`,
  `libgcc_s.so.1`.

`gcr.io/distroless/static-debian12` ships **no** dynamic loader, so neither
variant runs there. `gcr.io/distroless/cc-debian12:nonroot` ships glibc plus
`libgcc` and `libstdc++` — the smallest distroless that lets the glibc binary
run unmodified.

## Smoke test

```sh
./smoke-test.sh
```

Builds the image, starts a container on host port 14096, asserts
`/global/health` returns the expected JSON, asserts `/doc` returns OpenAPI
JSON, asserts the running process is owned by uid 65532, then tears
everything down.

## Image facts

- Base: `gcr.io/distroless/cc-debian12:nonroot`
- User: `nonroot` (uid `65532`, gid `65532`)
- Exposed port: `4096`
- Entry: `/usr/local/bin/opencode`
- Default args: `serve --port 4096 --hostname 0.0.0.0 --print-logs`
- Architecture: `linux/amd64` only (build fails on other `TARGETARCH`)
