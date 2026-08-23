#!/usr/bin/env bash
set -euo pipefail

NGINX_CONFIG="${NGINX_CONFIG:?}"
SERVICE="${SERVICE:?}"
TARGET_SLOT="${TARGET_SLOT:?}"          # blue | green
CONTAINER_PORT="${CONTAINER_PORT:-3000}" # port inside the container (always 3000 for panel)
NGINX_CONTAINER="${NGINX_CONTAINER:-nginx}"

PREV_SLOT=$([ "$TARGET_SLOT" = "blue" ] && echo "green" || echo "blue")
ACTIVE_CONTAINER="${SERVICE}-${TARGET_SLOT}"
INACTIVE_CONTAINER="${SERVICE}-${PREV_SLOT}"

echo "🔀 Switching upstream: ${INACTIVE_CONTAINER} → ${ACTIVE_CONTAINER}:${CONTAINER_PORT}"

cp "$NGINX_CONFIG" "${NGINX_CONFIG}.bak"

sed -i \
  "s|server ${SERVICE}-blue:${CONTAINER_PORT};|server ${ACTIVE_CONTAINER}:${CONTAINER_PORT};|g; \
   s|server ${SERVICE}-green:${CONTAINER_PORT};|server ${ACTIVE_CONTAINER}:${CONTAINER_PORT};|g" \
  "$NGINX_CONFIG"

if ! docker exec "$NGINX_CONTAINER" nginx -t 2>/dev/null; then
  echo "❌ nginx -t failed — restoring backup"
  cp "${NGINX_CONFIG}.bak" "$NGINX_CONFIG"
  exit 1
fi

docker exec "$NGINX_CONTAINER" nginx -s reload
echo "✅ nginx reloaded — traffic now on ${ACTIVE_CONTAINER}:${CONTAINER_PORT}"