"""FastAPI shim for the primare-module-openclaw wrapper image.

Serves three endpoints alongside the upstream OpenClaw gateway process
(which runs on port 18789 under supervisord):

  /info    — module identity (version baked from WRAPPER_VERSION env var)
  /health  — delegates to upstream GET /readyz; 200 → 200, else 503
  /metrics — Prometheus text exposition with module_healthy gauge

A background asyncio task polls /readyz every POLL_INTERVAL_SECONDS and
updates the module_healthy gauge so Prometheus can scrape stale state
without waiting for an in-band request to the /health endpoint.
"""

import asyncio
import os
from contextlib import asynccontextmanager

import httpx
from fastapi import FastAPI
from fastapi.responses import PlainTextResponse, Response
from prometheus_client import CONTENT_TYPE_LATEST, Gauge, generate_latest

WRAPPER_VERSION = os.environ.get("WRAPPER_VERSION", "2026.4.14-1")
UPSTREAM_READYZ = "http://127.0.0.1:18789/readyz"
POLL_INTERVAL_SECONDS = 10
POLL_TIMEOUT_SECONDS = 2

MODULE_HEALTHY = Gauge(
    "module_healthy",
    "1 if the upstream OpenClaw gateway /readyz returns HTTP 200, 0 otherwise.",
    labelnames=["module", "version"],
)

# Pre-declare the label set so Prometheus sees it immediately after startup,
# not only after the first poll completes.
_gauge = MODULE_HEALTHY.labels(module="openclaw", version=WRAPPER_VERSION)


async def _poll_upstream() -> None:
    """Poll /readyz forever, updating the module_healthy gauge."""
    async with httpx.AsyncClient() as client:
        while True:
            try:
                resp = await client.get(UPSTREAM_READYZ, timeout=POLL_TIMEOUT_SECONDS)
                _gauge.set(1 if resp.status_code == 200 else 0)
            except Exception:
                _gauge.set(0)
            await asyncio.sleep(POLL_INTERVAL_SECONDS)


@asynccontextmanager
async def lifespan(app: FastAPI):
    task = asyncio.create_task(_poll_upstream())
    try:
        yield
    finally:
        task.cancel()
        try:
            await task
        except asyncio.CancelledError:
            pass


app = FastAPI(
    title="primare-module-openclaw shim",
    version=WRAPPER_VERSION,
    lifespan=lifespan,
)


@app.get("/info")
async def info():
    return {"version": WRAPPER_VERSION}


@app.get("/health")
async def health():
    """Proxy upstream /readyz: 200 → 200, anything else → 503.

    The upstream status code is included in the body for debuggability.
    """
    try:
        async with httpx.AsyncClient() as client:
            resp = await client.get(UPSTREAM_READYZ, timeout=POLL_TIMEOUT_SECONDS)
    except Exception as exc:
        return PlainTextResponse(f"upstream unreachable: {exc}", status_code=503)

    status = 200 if resp.status_code == 200 else 503
    return PlainTextResponse(f"upstream status: {resp.status_code}", status_code=status)


@app.get("/metrics")
async def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)
