#!/usr/bin/env bash
# Polls TARGET_PORT/HEALTH_PATH until 200 or timeout (90s)
# Env vars: TARGET_PORT, HEALTH_PATH, HEALTH_HEADER (optional)
set -euo pipefail

TARGET_PORT="${TARGET_PORT:?}"
HEALTH_PATH="${HEALTH_PATH:-/health}"
HEALTH_HEADER="${HEALTH_HEADER:-}"
MAX_WAIT=90
INTERVAL=5

echo "⏳ Health check → http://localhost:${TARGET_PORT}${HEALTH_PATH}"

elapsed=0
while true; do
  CURL_ARGS=(-sf --max-time 5 "http://localhost:${TARGET_PORT}${HEALTH_PATH}")
  if [ -n "$HEALTH_HEADER" ]; then
    CURL_ARGS+=(-H "$HEALTH_HEADER")
  fi

  HTTP_CODE=$(curl -o /dev/null -w "%{http_code}" "${CURL_ARGS[@]}" 2>/dev/null || echo "000")

  if [ "$HTTP_CODE" = "200" ]; then
    echo "✅ Health check passed (HTTP $HTTP_CODE) after ${elapsed}s"
    exit 0
  fi

  if [ "$elapsed" -ge "$MAX_WAIT" ]; then
    echo "❌ Health check timed out after ${elapsed}s (last HTTP $HTTP_CODE)"
    exit 1
  fi

  echo "  → HTTP $HTTP_CODE — retrying in ${INTERVAL}s (${elapsed}s elapsed)"
  sleep "$INTERVAL"
  elapsed=$((elapsed + INTERVAL))
done