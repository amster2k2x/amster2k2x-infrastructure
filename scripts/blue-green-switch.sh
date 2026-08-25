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

# Write to a temp file, then cat it back into the ORIGINAL file (not sed -i).
# sed -i does a write-and-rename under the hood, which swaps in a new inode —
# that breaks Docker's single-file bind mount, since the running nginx
# container stays attached to the old (now-orphaned) inode and silently
# never sees the change. `cat > file` truncates and writes into the
# existing inode instead, which the bind mount actually tracks.
sed \
  "s|server ${SERVICE}-blue:${CONTAINER_PORT};|server ${ACTIVE_CONTAINER}:${CONTAINER_PORT};|g; \
   s|server ${SERVICE}-green:${CONTAINER_PORT};|server ${ACTIVE_CONTAINER}:${CONTAINER_PORT};|g" \
  "$NGINX_CONFIG" > "${NGINX_CONFIG}.tmp"

cat "${NGINX_CONFIG}.tmp" > "$NGINX_CONFIG"
rm "${NGINX_CONFIG}.tmp"

if ! docker exec "$NGINX_CONTAINER" nginx -t 2>/dev/null; then
  echo "❌ nginx -t failed — restoring backup"
  cat "${NGINX_CONFIG}.bak" > "$NGINX_CONFIG"
  exit 1
fi

docker exec "$NGINX_CONTAINER" nginx -s reload
echo "✅ nginx reloaded — traffic now on ${ACTIVE_CONTAINER}:${CONTAINER_PORT}"