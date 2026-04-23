# CLAUDE.md — AI Handoff

Wrapper-image module packaging `ghcr.io/openclaw/openclaw` as a first-class primare-infra module (T12-19). This file is the Claude-session contract; for full architecture see `docs/OVERVIEW.md`.

## Stack

Python 3.12+ · FastAPI · supervisord · uv · Ruff · Pytest · Docker · GitHub Actions.

## Architecture

- `src/primare_module_openclaw/main.py` — FastAPI shim exposing `/info`, `/health`, `/metrics` on port 8000.
- Upstream `openclaw` runs on port 18789 inside the same container; both processes launched by supervisord.
- `hooks.yml` + `hooks/*.yml` — Ansible task files consumed by primare-infra's generic module role (T12-18) at deploy time. Secrets flow via Ansible extravars (`openclaw_gateway_token`, `openclaw_litellm_key`, `openclaw_discord_bot_token`).
- `configs/caddy/module.caddy` — named snippet `(module_openclaw)` routing `{{ path_prefix }}/*` to the container.
- Release workflow ships image + `caddy.snippet` + `hooks.yml` + all `hooks/*` files as release assets; primare-infra fetches and sha-pins.

## Version scheme

Tag format: `v<upstream-version>-<wrapper-revision>` (e.g. `v2026.4.14-1`). Bump wrapper revision for shim/hook changes; bump upstream + reset revision to `-1` when upstream ships a new image. See `README.md`.

## Code conventions

- **Line length:** 120.
- **Indent:** 4 spaces.
- **Type hints:** required on all function signatures.
- **Docstrings:** Google format; one-liner for modules and trivial functions.
- **Naming:** `snake_case.py` files, `PascalCase` classes, `test_<module>.py` tests.

## Commit rules

- Conventional Commits, scoped to the ticket: `TASK-12-T19: …`, `fix(T12-11): …`.
- **Do NOT add `Co-Authored-By: Claude …` trailers.** Authorship belongs to the human developer; AI assistance is captured in the PR review trail, not in git history. Applies to all AI tools (Claude, Copilot, Cursor, etc.).

## Common commands

```bash
uv sync --extra dev              # install deps
uv run ruff check . && uv run ruff format .
uv run pytest -v
docker compose up                # run locally
```

## Canonical docs

| Concern | Source |
|---|---|
| Architecture, version scheme, bump procedure | `README.md`, `docs/OVERVIEW.md` |
| Hook contract (fact dict, extravars) | `hooks.yml` + T12-18 in primare-infra |
| Live-deploy cutover | primare-infra T12-11 |

Prefer reading the canonical file (`pyproject.toml`, `Dockerfile`, `configs/supervisord.conf`, `hooks/*`, `src/primare_module_openclaw/`) over the docs when the question is "what does the code actually do?"
