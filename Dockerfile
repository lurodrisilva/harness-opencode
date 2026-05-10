# syntax=docker/dockerfile:1.7

# opencode headless server on distroless/cc nonroot.
# See README.md for runtime contract and probe paths.

ARG OPENCODE_VERSION=1.14.40
# SHA-256 of each per-platform glibc tarball published on npm. Bump in lockstep
# with OPENCODE_VERSION. Verify with:
#   curl -fsSL https://registry.npmjs.org/opencode-linux-x64/-/opencode-linux-x64-${OPENCODE_VERSION}.tgz   | sha256sum
#   curl -fsSL https://registry.npmjs.org/opencode-linux-arm64/-/opencode-linux-arm64-${OPENCODE_VERSION}.tgz | sha256sum
ARG OPENCODE_TARBALL_SHA256_AMD64=f662a6ad1c6ecd6dee43e712c6b1ea814de38d27e2f983ca41e7f29b98f5f2ef
ARG OPENCODE_TARBALL_SHA256_ARM64=10d4ad7c8000427f137ac835dcc8b7960ce7ebda7c1fd87e594e5f4db4e9d9f7

# ---- builder ----
# debian:bookworm-slim only because we need curl + sha256sum + tar to fetch
# and verify the prebuilt binary. Nothing from this stage reaches the runtime.
FROM debian:bookworm-slim AS builder

ARG OPENCODE_VERSION
ARG OPENCODE_TARBALL_SHA256_AMD64
ARG OPENCODE_TARBALL_SHA256_ARM64
ARG TARGETARCH

# linux/amd64 and linux/arm64 are both supported. Reject anything else
# *before* apt install so unexpected platforms fail in <1s rather than
# paying for the full apt-update cycle. (The download RUN below also
# guards TARGETARCH, but that runs *after* apt; this early gate exists
# only for fast-fail cost.)
RUN case "${TARGETARCH:-amd64}" in \
        amd64|arm64) ;; \
        *) echo "ERROR: unsupported TARGETARCH '${TARGETARCH}'. Only amd64 and arm64 are supported." >&2; exit 1 ;; \
    esac

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        ; \
    rm -rf /var/lib/apt/lists/*

WORKDIR /tmp/opencode

# opencode publishes per-arch glibc tarballs on npm. Pick the right one
# based on TARGETARCH (set automatically by buildx for the current target
# platform), then verify it against the per-arch SHA-256 ARG.
#   amd64 → opencode-linux-x64    (interpreter /lib64/ld-linux-x86-64.so.2)
#   arm64 → opencode-linux-arm64  (interpreter /lib/ld-linux-aarch64.so.1)
# Both binaries dynamically link only against glibc + libgcc + libstdc++,
# all of which ship in distroless/cc-debian12 for both arches.
RUN set -eux; \
    case "${TARGETARCH:-amd64}" in \
        amd64) NPM_PKG="opencode-linux-x64";    EXPECTED_SHA="${OPENCODE_TARBALL_SHA256_AMD64}" ;; \
        arm64) NPM_PKG="opencode-linux-arm64";  EXPECTED_SHA="${OPENCODE_TARBALL_SHA256_ARM64}" ;; \
        *)     echo "ERROR: unsupported TARGETARCH '${TARGETARCH}'" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o opencode.tgz \
        "https://registry.npmjs.org/${NPM_PKG}/-/${NPM_PKG}-${OPENCODE_VERSION}.tgz"; \
    echo "${EXPECTED_SHA}  opencode.tgz" | sha256sum -c -; \
    tar -xzf opencode.tgz package/bin/opencode; \
    install -D -m 0755 package/bin/opencode /out/opencode; \
    rm -rf opencode.tgz package

# opencode mkdir's ~/.local/share/opencode/log, ~/.local/state/opencode,
# ~/.cache/opencode, and ~/.config/opencode at startup. Pre-create the full
# tree owned by nonroot (uid 65532) so the runtime stage doesn't need to
# create them — distroless ships /home/nonroot as mode 0700 but in some
# host configurations (notably Docker Desktop on macOS Apple Silicon running
# linux/amd64 under emulation) recursive mkdir inside it fails with EACCES.
RUN install -d -o 65532 -g 65532 -m 0700 \
        /out/home/nonroot \
        /out/home/nonroot/.local \
        /out/home/nonroot/.local/share \
        /out/home/nonroot/.local/share/opencode \
        /out/home/nonroot/.local/share/opencode/log \
        /out/home/nonroot/.local/state \
        /out/home/nonroot/.local/state/opencode \
        /out/home/nonroot/.cache \
        /out/home/nonroot/.cache/opencode \
        /out/home/nonroot/.config \
        /out/home/nonroot/.config/opencode

# ---- runtime ----
# distroless/cc-debian12:nonroot ships glibc + libgcc + libstdc++ for both
# linux/amd64 and linux/arm64 — exactly what every dynamically-linked
# opencode binary needs:
#   amd64: PT_INTERP /lib64/ld-linux-x86-64.so.2 + libc/pthread/dl/m
#   arm64: PT_INTERP /lib/ld-linux-aarch64.so.1  + libc/pthread/dl/m
# Original spec called for distroless/static; that base lacks the dynamic
# loader and cannot run any opencode binary (every linux/* variant is
# dynamically linked). See .omc/autopilot/spec.md for the full ELF analysis.
FROM gcr.io/distroless/cc-debian12:nonroot

ARG OPENCODE_VERSION

LABEL org.opencontainers.image.title="opencode-server" \
      org.opencontainers.image.description="Headless opencode AI coding agent server (distroless/cc nonroot)" \
      org.opencontainers.image.version="${OPENCODE_VERSION}" \
      org.opencontainers.image.source="https://opencode.ai" \
      org.opencontainers.image.documentation="https://opencode.ai/docs/server/" \
      org.opencontainers.image.licenses="MIT"

COPY --from=builder --chown=nonroot:nonroot /out/opencode /usr/local/bin/opencode
COPY --from=builder --chown=nonroot:nonroot /out/home/nonroot /home/nonroot

USER nonroot
WORKDIR /home/nonroot

# Persist opencode session/auth/config across container restarts.
VOLUME ["/home/nonroot/.local/share/opencode", "/home/nonroot/.config/opencode"]

EXPOSE 4096

# Pin the port (default `0` picks a random one) and bind on all interfaces
# (default `127.0.0.1` is unreachable from outside the container).
# `--print-logs` routes server logs to stderr so `docker logs` shows them.
ENTRYPOINT ["/usr/local/bin/opencode"]
CMD ["serve", "--port", "4096", "--hostname", "0.0.0.0", "--print-logs"]
