# syntax=docker/dockerfile:1

# primare-module-openclaw — Wrapper image packaging OpenClaw as a first-class
# primare-infra module.
#
# Architecture:
#   Single-stage build on top of the upstream openclaw image. Installs Python
#   3.11 + supervisor + curl, builds the FastAPI shim venv in place, and runs
#   both the upstream gateway and the shim under supervisord so Docker sees a
#   single PID 1.
#
#   A multi-stage build with a python:3.12-slim builder was attempted for
#   v2026.4.14-1/-2 but two problems emerged: the upstream image is Debian
#   bookworm (python 3.11, not 3.12), and uv's venv bakes an absolute shebang
#   (`#!/app/.venv/bin/python`) into the entry-point scripts. Copying the venv
#   across stages broke both python-version match and the shebang resolution.
#   Building in the runtime stage avoids both issues; the image size cost is
#   ~40 MB.
#
# Version scheme: <upstream-version>-<wrapper-revision>
#   e.g. 2026.4.14-1 = openclaw upstream 2026.4.14, wrapper revision 1.
#   Bump WRAPPER_VERSION ARG default + FROM tag together when upstream ships.

FROM ghcr.io/openclaw/openclaw:2026.4.14

# Upstream image sets USER=node (uid 1000); apt-get needs root. Stay as root
# for the final image — supervisord runs as root and drops privs for
# [program:openclaw] via its user=node directive (see configs/supervisord.conf).
USER root

# python3 + python3-venv: needed for the shim venv build below.
# supervisor: process-level restart policy for both upstream and shim.
# curl: required by HEALTHCHECK.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
         supervisor curl python3 python3-venv \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/shim

# Build shim venv in place — ensures Python version matches runtime and
# shebangs in bin/ scripts resolve correctly after image build.
RUN python3 -m venv /opt/shim/.venv \
    && /opt/shim/.venv/bin/pip install --no-cache-dir --upgrade pip \
    && /opt/shim/.venv/bin/pip install --no-cache-dir \
         "fastapi>=0.109.0" \
         "httpx>=0.27,<0.29" \
         "prometheus-client>=0.20,<0.22" \
         "uvicorn[standard]>=0.27,<0.35"

COPY src/primare_module_openclaw /opt/shim/primare_module_openclaw

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
