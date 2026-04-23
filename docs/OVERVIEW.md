# primare-module-openclaw — Architecture Overview

## Upstream project

[OpenClaw](https://github.com/openclaw/openclaw) is a self-hosted AI agent
framework. It exposes a gateway process (port 18789) with a Control UI,
Discord channel integration, and a CLI for agent/config management.

## Why a wrapper image?

The primare-infra module platform (TASK-12) requires every module to:
- Expose `/info` (version identity), `/health` (liveness), and `/metrics`
  (Prometheus gauge) on a known port (default 8000).
- Ship all bespoke Ansible setup as hook task files in a GitHub release.

OpenClaw's upstream image does not expose these endpoints. Rather than forking
upstream or monkey-patching its entrypoint, we wrap it: a multi-stage
`Dockerfile` copies a minimal FastAPI shim venv into the upstream image and
runs both processes under `supervisord`.

## Process model

```
Docker container (supervisord PID 1)
├── [program:openclaw]  /usr/local/bin/openclaw gateway start
│     Upstream gateway — port 18789
│     Config: /opt/spark/openclaw/config/openclaw.json
│     Workspace: /opt/spark/openclaw/workspace/
│
└── [program:shim]  uvicorn primare_module_openclaw.main:app --port 8000
      FastAPI shim — port 8000
      /info    → {"version": "<WRAPPER_VERSION>"}
      /health  → proxies GET http://127.0.0.1:18789/readyz (200→200, else 503)
      /metrics → Prometheus text; module_healthy gauge updated every 10 s
```

## Hook execution order

| Phase | Hook file | What it does |
|-------|-----------|-------------|
| pre_up | `hooks/set-defaults.yml` | Establish Ansible facts for all subsequent hooks |
| pre_up | `hooks/assert-secrets.yml` | Fail loudly if extravars are missing/placeholder |
| pre_up | `hooks/persist-gateway-token.yml` | Write `OPENCLAW_GATEWAY_TOKEN` + `DISCORD_BOT_TOKEN` to compose `.env` |
| pre_up | `hooks/create-dirs.yml` | Create config + workspace dirs (UID 1000) |
| post_up | `hooks/apply-config.yml` | Batch-JSON config set: LiteLLM provider, Control UI, agent defaults |
| post_up | `hooks/create-default-agent.yml` | Add default agent if absent |
| post_up | `hooks/configure-discord.yml` | Enable Discord channel + guild whitelist (skipped if `openclaw_discord_guilds: {}`) |
| post_up | `hooks/bind-discord-agent.yml` | Bind default agent to Discord (skipped if no guilds) |
| post_up | `hooks/install-log-metrics.yml` | Install scraper + systemd units (T11-1) |
| post_up | `hooks/smoke-test.yml` | Poll `/readyz` + assert default agent in `agents list` |

## Secrets

Secrets flow via Ansible extravars (`-e openclaw_gateway_token=...`), never
via this repo. The age-encrypted source files live in primare-infra under
`ansible/secrets/modules/openclaw/`. See primare-infra's
`docs/reference/credentials-checklist.md` for mint/rotate instructions.

## Caddy routing

The `configs/caddy/module.caddy` file ships as `caddy.snippet` in each release.
The generic module role injects it into each customer's Caddy site block. The
snippet routes `{{ path_prefix }}/*` (default `/claw/*`) to
`{{ module_name }}:{{ module_port }}` (port 18789, upstream gateway).

## Log-based metrics scraper (T11-1)

`hooks/openclaw-log-metrics.sh` runs every minute via a systemd timer installed
by `install-log-metrics.yml`. It writes three gauges to the node_exporter
textfile_collector directory:
- `openclaw_gateway_token_mismatch_recent` — token-mismatch log events
- `openclaw_session_jsonl_max_bytes` — largest session file size
- `openclaw_container_running` — container liveness from `docker inspect`

Alert rules for these gauges are defined in primare-infra's
`roles/prometheus/templates/alert-rules.yml.j2` (openclaw group).
