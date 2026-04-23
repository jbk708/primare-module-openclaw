"""Shared pytest fixtures for primare-module-openclaw tests."""

import pytest


@pytest.fixture(autouse=True)
def set_wrapper_version(monkeypatch):
    """Ensure WRAPPER_VERSION is set for all tests."""
    monkeypatch.setenv("WRAPPER_VERSION", "2026.4.14-1")
