"""Unit tests for the primare-module-openclaw FastAPI shim.

Tests cover:
  - /info returns the WRAPPER_VERSION env var
  - /metrics exposes the module_healthy gauge token
  - /health proxies upstream /readyz (200 pass-through + 503 on failure)
"""

import httpx
import pytest
from fastapi.testclient import TestClient

# Import after conftest sets WRAPPER_VERSION so the module-level constant is
# set before the app is instantiated for the first time.
from src.primare_module_openclaw.main import app


@pytest.fixture()
def client():
    with TestClient(app) as c:
        yield c


class TestInfo:
    def test_info_returns_wrapper_version(self, client):
        """GET /info returns JSON body with version == WRAPPER_VERSION."""
        resp = client.get("/info")
        assert resp.status_code == 200
        body = resp.json()
        assert "version" in body
        assert body["version"] == "2026.4.14-1"

    def test_info_content_type_is_json(self, client):
        resp = client.get("/info")
        assert "application/json" in resp.headers.get("content-type", "")


class TestMetrics:
    def test_metrics_returns_200(self, client):
        resp = client.get("/metrics")
        assert resp.status_code == 200

    def test_metrics_exposes_module_healthy_gauge(self, client):
        """Response body must contain the module_healthy metric token."""
        resp = client.get("/metrics")
        assert resp.status_code == 200
        assert "module_healthy" in resp.text

    def test_metrics_content_type_is_prometheus(self, client):
        resp = client.get("/metrics")
        ct = resp.headers.get("content-type", "")
        assert ct.startswith("text/plain")


class TestHealth:
    def _mock_upstream(self, monkeypatch, status_code=None, exc=None):
        """Monkeypatch httpx.AsyncClient.get to return a canned response or raise."""

        async def _fake_get(self_inner, url, **kwargs):
            if exc is not None:
                raise exc
            return httpx.Response(status_code)

        monkeypatch.setattr(httpx.AsyncClient, "get", _fake_get)

    def test_health_proxies_upstream_ready(self, client, monkeypatch):
        """When upstream /readyz returns 200, /health must return 200."""
        self._mock_upstream(monkeypatch, status_code=200)
        resp = client.get("/health")
        assert resp.status_code == 200

    def test_health_returns_503_when_upstream_returns_non_200(
        self, client, monkeypatch
    ):
        """When upstream /readyz returns non-200, /health must return 503."""
        self._mock_upstream(monkeypatch, status_code=503)
        resp = client.get("/health")
        assert resp.status_code == 503

    def test_health_returns_503_when_upstream_unreachable(self, client, monkeypatch):
        """When upstream /readyz raises a connection error, /health must return 503."""
        self._mock_upstream(monkeypatch, exc=httpx.ConnectError("connection refused"))
        resp = client.get("/health")
        assert resp.status_code == 503

    def test_health_body_includes_upstream_status(self, client, monkeypatch):
        """Health response body includes upstream status code for debuggability."""
        self._mock_upstream(monkeypatch, status_code=200)
        resp = client.get("/health")
        assert "200" in resp.text
