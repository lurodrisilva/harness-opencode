---
name: opencode-headless-server
description: Run opencode as standalone headless HTTP server — CLI flags, auth, endpoints, gotchas
triggers:
  - opencode serve
  - opencode headless
  - OPENCODE_SERVER_PASSWORD
  - OPENCODE_SERVER_USERNAME
  - opencode 4096
  - /global/health
  - opencode OpenAPI
  - opencode /doc
  - opencode --hostname
  - opencode mdns
---

# opencode Headless Server

## The Insight

`opencode serve` runs opencode as a **standalone HTTP server with no TUI**, exposing the same API the bundled TUI client talks to. Use it for IDE plugins, programmatic agents, remote drivers, or any non-interactive consumer.

Distinct from `opencode` (no subcommand), which spawns **both** TUI client + local server bundled together. `serve` = server only.

## CLI

```
opencode serve [--port <n>] [--hostname <h>] [--cors <origin>] [--mdns] [--mdns-domain <d>]
               [--print-logs] [--log-level DEBUG|INFO|WARN|ERROR] [--pure]
```

Verified against `opencode 1.14.40` (`opencode serve --help`).

| Flag            | Purpose                                                  | Default         |
|-----------------|----------------------------------------------------------|-----------------|
| `--port`        | Listening port (`0` = OS-picked random)                  | `0`             |
| `--hostname`    | Listening address                                        | `127.0.0.1`     |
| `--cors`        | Additional allowed browser origins (repeatable, array)   | `[]`            |
| `--mdns`        | Enable mDNS discovery (also flips `--hostname` to `0.0.0.0`) | `false`     |
| `--mdns-domain` | Custom mDNS domain                                       | `opencode.local`|
| `--print-logs`  | Stream logs to stderr (otherwise written to log file)    | `false`         |
| `--log-level`   | Log verbosity (`DEBUG`/`INFO`/`WARN`/`ERROR`)            | unset           |
| `--pure`        | Run without external plugins                             | `false`         |

Note: docs site (https://opencode.ai/docs/server/) claims `--port` default `4096` — **wrong**. Real default is `0` per `--help`. If a stable port matters (k8s Service, IDE plugin), pass `--port` explicitly.

Multiple `--cors`:
```
opencode serve --cors http://localhost:5173 --cors https://app.example.com
```

## Authentication

HTTP Basic auth, **env vars only — no CLI flag**:

- `OPENCODE_SERVER_PASSWORD` — required to enable auth (unset = open server)
- `OPENCODE_SERVER_USERNAME` — optional, defaults to `opencode`

```
OPENCODE_SERVER_PASSWORD=your-password opencode serve
```

Applies to both `opencode serve` and `opencode web`.

When unset, server logs at startup:
```
Warning: OPENCODE_SERVER_PASSWORD is not set; server is unsecured.
```
Treat that warning as a gate: never ignore in non-loopback deployments.

## Endpoints

Verified against `opencode 1.14.40`:

| Path             | Method | Purpose                                                                  |
|------------------|--------|--------------------------------------------------------------------------|
| `/global/health` | GET    | Health check → `{"healthy":true,"version":"1.14.40"}` (JSON)             |
| `/doc`           | GET    | **OpenAPI 3.1.1 spec as JSON** (not HTML — docs site is wrong). Title `opencode`, version `0.0.3`. |
| `/event`         | GET    | Server-sent events stream; first event = `server.connected`              |
| `/tui`           | —      | Drive the TUI programmatically (used by IDE plugins)                     |

⚠️ **HTML SPA fallback trap**: unknown paths (`/health`, `/openapi.json`, `/doc.json`, anything else) return HTTP 200 with an HTML `<!doctype html>` document, NOT 404. Probing for endpoints with `curl -o /dev/null -w "%{http_code}"` will give false positives — every path returns 200. Always inspect the body's `Content-Type` or first bytes to confirm a real endpoint.

## SDK / Integration

Server auto-publishes OpenAPI 3.1 spec at `/doc`. Generate clients from it; official SDKs are generated from the same spec.

## Gotchas (non-obvious, costs hours if missed)

1. **Default `--port 0` = random OS-assigned port.** Docs site lies about `4096`. Without `--port N` your service comes up on a different port every restart — k8s Services, IDE plugins, ALB target groups break. Always pin `--port` for non-interactive use. Inspect the actual port via the startup log line `opencode server listening on http://<host>:<port>`.
2. **Default `--hostname 127.0.0.1`** — loopback only. Remote consumer / Docker / k8s sidecar will silently fail to connect. Override with `--hostname 0.0.0.0` (and set `OPENCODE_SERVER_PASSWORD` first).
3. **Auth has no CLI flag** — must export env var, easy to forget in systemd unit / Dockerfile / k8s manifest. Watch for the `server is unsecured` warning at boot.
4. **No password = open server** — anyone reaching the host:port has full opencode control. Pair `--hostname 0.0.0.0` (or `--mdns`) with `OPENCODE_SERVER_PASSWORD` always.
5. **`--mdns` silently flips `--hostname` to `0.0.0.0`** — security implication: enabling mDNS LAN discovery exposes the server to the whole local network even if you didn't pass `--hostname 0.0.0.0`. If you set `OPENCODE_SERVER_PASSWORD=` deliberately empty + `--mdns`, you've published an open server on every LAN interface.
6. **`opencode` (no subcommand) ≠ `opencode serve`** — bare `opencode` starts TUI+server pair. Programmatic usage must use `serve` to get headless mode.
7. **Health path is `/global/health`**, not the conventional `/health` or `/healthz`. Probe configs (k8s livenessProbe, ELB target group) need the full path.
8. **HTML SPA fallback returns 200 for unknown paths.** `/health`, `/openapi.json`, `/doc.json`, `/anything-typoed` all serve a 200 HTML page. Status-code-only probes give false positives — assert on response body or `Content-Type: application/json`.
9. **`/doc` returns OpenAPI as JSON, not HTML.** Docs page claims HTML; the live server returns the raw JSON spec (`{"openapi":"3.1.1",...}`). Feed it directly to codegen tools.
10. **CORS is allowlist-only via `--cors`** — repeatable array, no wildcard documented. Pass each origin explicitly.
11. **`--print-logs` vs default file logging** — without `--print-logs`, server logs go to a file (not stderr). For Docker / k8s where you want logs on stdout/stderr, always pass `--print-logs`.

## Recognition Pattern

Use this skill when:
- User asks to drive opencode from script / CI / IDE plugin
- Setting up opencode in container / k8s / systemd
- Debugging "connection refused" on opencode port
- Designing remote-agent topology where opencode is one node

## Verify Before Trusting

opencode evolves fast. Before relying on flag names / endpoint paths in production:

```
opencode serve --help
curl -s http://127.0.0.1:4096/doc | grep -o '/[a-z/_-]*' | sort -u
```

Confirm against installed version, not this skill.
