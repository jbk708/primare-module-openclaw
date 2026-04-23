#!/usr/bin/env bash
# openclaw-log-metrics.sh — Scrape docker logs for token-mismatch events and
# measure session jsonl bloat, then emit Prometheus textfile metrics.
# Deployed to /usr/local/bin/ by the openclaw Ansible role (T11-1).
# Runs every minute via openclaw-log-metrics.timer.
set -euo pipefail

# --- Env-var overrides (for testability; defaults match prod paths) ----------
OPENCLAW_CONTAINER="${OPENCLAW_CONTAINER:-openclaw}"
OPENCLAW_SESSIONS_GLOB_ROOT="${OPENCLAW_SESSIONS_GLOB_ROOT:-/opt/spark/configs/openclaw/agents}"
TEXTFILE_COLLECTOR_DIR="${TEXTFILE_COLLECTOR_DIR:-/var/lib/node_exporter/textfile_collector}"
LOOKBACK="${LOOKBACK:-2m}"

OUT_FILE="${TEXTFILE_COLLECTOR_DIR}/openclaw.prom"
TMP_FILE="${OUT_FILE}.tmp"

# --- Token-mismatch count ---------------------------------------------------
# docker logs writes to stderr; 2>&1 redirects it to stdout so grep can see it.
# Deliberate silent-failure: if the container doesn't exist or isn't running,
# docker logs exits non-zero. We catch that and emit 0 — a zero reading is
# correct (no mismatch events visible), and staleness of _last_run_timestamp
# would surface any persistent scraper breakage independently.
mismatch_count=0
if docker_output=$(docker logs "${OPENCLAW_CONTAINER}" --since "${LOOKBACK}" 2>&1); then
  mismatch_count=$(printf '%s\n' "${docker_output}" \
    | grep -cF -e 'token_mismatch' -e 'SECRETS_GATEWAY_AUTH_SURFACE' || true)
fi

# --- Largest session jsonl size ---------------------------------------------
# find exits 0 even when no files match; tail -1 of empty input is empty,
# so we default to 0 with parameter expansion.
# Use wc -c rather than find -printf '%s\n' for portability (macOS find
# lacks -printf; the target is Ubuntu/GNU find but the test runs locally).
session_max_bytes=0
if [ -d "${OPENCLAW_SESSIONS_GLOB_ROOT}" ]; then
  _raw=$(find "${OPENCLAW_SESSIONS_GLOB_ROOT}" \
    -maxdepth 3 -name '*.jsonl' 2>/dev/null \
    | while IFS= read -r f; do wc -c < "$f" 2>/dev/null || true; done \
    | sort -n | tail -1)
  session_max_bytes="${_raw:-0}"
fi

# --- Container state --------------------------------------------------------
# Container state: 1 if running, 0 otherwise. Scraper relies on docker inspect
# rather than docker logs so a crashed-and-restarted container reports
# accurately regardless of the log buffer state (post-restart log is empty).
if container_state=$(docker inspect "${OPENCLAW_CONTAINER}" --format '{{.State.Running}}' 2>/dev/null); then
    [ "${container_state}" = "true" ] && container_running=1 || container_running=0
else
    container_running=0
fi

# --- Write atomically -------------------------------------------------------
# Write to .tmp then mv so Prometheus never reads a partial file.
mkdir -p "${TEXTFILE_COLLECTOR_DIR}"
cat > "${TMP_FILE}" <<EOF
# HELP openclaw_gateway_token_mismatch_recent Count of token_mismatch / SECRETS_GATEWAY_AUTH_SURFACE log lines in the last ${LOOKBACK}
# TYPE openclaw_gateway_token_mismatch_recent gauge
openclaw_gateway_token_mismatch_recent ${mismatch_count}
# HELP openclaw_session_jsonl_max_bytes Size in bytes of the largest OpenClaw session jsonl file
# TYPE openclaw_session_jsonl_max_bytes gauge
openclaw_session_jsonl_max_bytes ${session_max_bytes}
# HELP openclaw_log_metrics_last_run_timestamp_seconds Unix epoch of last successful scraper run
# TYPE openclaw_log_metrics_last_run_timestamp_seconds gauge
openclaw_log_metrics_last_run_timestamp_seconds $(date +%s)
# HELP openclaw_container_running 1 if the openclaw container is in the Running state, 0 otherwise
# TYPE openclaw_container_running gauge
openclaw_container_running ${container_running}
EOF

mv "${TMP_FILE}" "${OUT_FILE}"
