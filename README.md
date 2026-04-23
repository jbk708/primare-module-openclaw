# primare-module-openclaw

Wrapper image packaging [OpenClaw](https://github.com/openclaw/openclaw) as a
first-class primare-infra module, deployable via the generic module Ansible role
introduced in TASK-12 T12-18.

## Wrapper image pattern

This repo follows the wrapper-image module pattern documented in primare-infra
TASK-12 T12-17. The pattern:

1. Takes an upstream container image (`ghcr.io/openclaw/openclaw:<tag>`) as the
   runtime base.
2. Adds a minimal FastAPI shim (port 8000) exposing `/info`, `/health`, and
   `/metrics` so the primare-infra generic role can lifecycle-manage and scrape
   the module without knowing its internals.
3. Runs both processes under `supervisord` so Docker sees a single PID 1.
4. Ships all bespoke Ansible configuration as hook task files in a GitHub
   release, fetched and executed by the generic role at deploy time (T12-18
   hooks-from-release contract).

## Version scheme

```
v<upstream-version>-<wrapper-revision>
```

| Part | Meaning |
|------|---------|
| `upstream-version` | Tag of `ghcr.io/openclaw/openclaw` this image wraps |
| `wrapper-revision` | Monotonically increasing integer; reset to `1` when upstream bumps |

Example: `v2026.4.14-1` = OpenClaw upstream `2026.4.14`, wrapper revision `1`.

The shim's `/info` endpoint returns this string verbatim (without the leading
`v`), and the generic module role asserts it matches the registry entry's
`version` field after every deploy.

## When upstream ships a new image

1. Update the `FROM` line in `Dockerfile` to the new upstream tag.
2. Update the `ARG WRAPPER_VERSION` default to `<new-upstream-tag>-1`.
3. Open a PR; once merged, tag `v<new-upstream-tag>-1`.
4. Update `image` + `version` in `ansible/modules.yml` (primare-infra) in the
   T12-11 follow-up PR.

## Hook contract

Secrets flow via Ansible extravars at deploy time — they are never stored in
this repo or in `hooks.yml`. The generic module role asserts their presence via
the `assert-secrets.yml` pre_up hook before any other hook runs.

Required extravars (age-encrypted at rest in primare-infra under
`ansible/secrets/modules/openclaw/`):

| Extravar | Purpose |
|----------|---------|
| `openclaw_gateway_token` | OpenClaw gateway auth token |
| `openclaw_litellm_key` | LiteLLM API key for the spark-litellm provider |
| `openclaw_discord_bot_token` | Discord bot token (required even if Discord is disabled) |

See `docs/reference/credentials-checklist.md` in primare-infra for creation and
rotation instructions.

## Architecture

```
Docker container
├─ supervisord (PID 1)
│  ├─ openclaw gateway start   [port 18789]
│  └─ uvicorn primare_module_openclaw.main:app [port 8000]
│
├─ /info     → {"version": "2026.4.14-1"}
├─ /health   → proxies GET http://127.0.0.1:18789/readyz
└─ /metrics  → Prometheus exposition (module_healthy gauge)
```

The shim polls `/readyz` every 10 s and updates `module_healthy{module="openclaw"}`.
Caddy routes `{{ path_prefix }}/*` (default `/claw/*`) to port 18789 (upstream)
via the `caddy.snippet` release asset.

## Local development

```bash
uv sync --extra dev
uv run pytest                   # run unit tests
uv run ruff check .             # lint
uv run ruff format .            # format
docker compose up --build       # spin up locally (ports 18789 + 8000 exposed)
```

## Release

Tags are cut manually post-merge when T12-11 (registry entry on blevit) is
ready to consume. The `v2026.4.14-1` tag is the first planned release.

The CI `docker-build.yml` workflow fires on `v*` tags and:
- Builds and pushes `ghcr.io/jbk708/primare-module-openclaw:<tag>` (amd64 + arm64).
- Uploads `caddy.snippet`, `caddy.snippet.sha256`, `hooks.yml`, `hooks.yml.sha256`,
  and all files under `hooks/` as GitHub release assets.

## Follow-up

T12-11 in primare-infra registers this module in `ansible/modules.yml` and
performs the live cutover on blevit, retiring the dedicated `roles/openclaw/` role.
