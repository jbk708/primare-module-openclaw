# syntax=docker/dockerfile:1

# primare-module-openclaw — Wrapper image packaging OpenClaw as a first-class
# primare-infra module.
#
# Architecture:
#   Stage 1 (builder)  — Python 3.12 slim + uv; builds the FastAPI shim venv.
#   Stage 2 (runtime)  — FROM upstream openclaw image; installs supervisor;
#                         copies shim venv in; runs both processes under
#                         supervisord so Docker sees a single PID 1.
#
# Version scheme: <upstream-version>-<wrapper-revision>
#   e.g. 2026.4.14-1 = openclaw upstream 2026.4.14, wrapper revision 1.
#   Bump WRAPPER_VERSION ARG default + FROM tag together when upstream ships.

# -----------------------------------------------------------------------------
# Stage 1 — shim builder
# -----------------------------------------------------------------------------
FROM python:3.12-slim AS builder

RUN pip install --no-cache-dir uv

WORKDIR /app

COPY pyproject.toml uv.lock ./

# Install shim dependencies into an isolated venv (no project itself needed).
RUN uv sync --frozen --no-dev --no-install-project

COPY src/ ./src/

# -----------------------------------------------------------------------------
# Stage 2 — runtime
# -----------------------------------------------------------------------------
FROM ghcr.io/openclaw/openclaw:2026.4.14

# Upstream image sets USER=node (uid 1000); apt-get needs root. Stay as root
# for the final image — supervisord runs as root and drops privs for
# [program:openclaw] via its user=node directive (see configs/supervisord.conf).
USER root

# supervisor: process-level restart policy for both upstream and shim.
# curl: required by HEALTHCHECK.
RUN apt-get update \
    && apt-get install -y --no-install-recommends supervisor curl \
    && rm -rf /var/lib/apt/lists/*

# Copy shim venv and source from builder.
COPY --from=builder /app/.venv /opt/shim/.venv
COPY --from=builder /app/src/primare_module_openclaw /opt/shim/primare_module_openclaw

# supervisord config — two [program:*] sections: openclaw + shim.
COPY configs/supervisord.conf /etc/supervisor/conf.d/primare.conf

# WRAPPER_VERSION is baked at build time and read by the shim's /info endpoint.
# When upstream ships a new image: bump FROM tag + this ARG default together,
# reset the wrapper revision suffix to -1.
ARG WRAPPER_VERSION=2026.4.14-1
ENV WRAPPER_VERSION=${WRAPPER_VERSION}

# Build provenance — populated by docker/build-push-action in CI.
ARG BUILD_GIT_SHA=unknown
ARG BUILD_TIME=unknown
ENV BUILD_GIT_SHA=${BUILD_GIT_SHA} \
    BUILD_TIME=${BUILD_TIME}

# 18789 — upstream OpenClaw gateway
# 8000  — primare shim (/info /health /metrics)
EXPOSE 18789 8000

# Health is checked via the shim so a crashed openclaw process is visible.
HEALTHCHECK --interval=30s --timeout=10s --start-period=15s --retries=3 \
    CMD curl -fsS http://localhost:8000/health || exit 1

ENTRYPOINT ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/primare.conf"]
