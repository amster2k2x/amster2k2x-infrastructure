#!/bin/sh
set -euxv

echo "=== Fetching RDS credentials from Secrets Manager ==="
SECRET_JSON=$(aws secretsmanager get-secret-value \
  --secret-id  "${RDS_SECRET_ARN}" \
  --query      SecretString \
  --output     text)
DB_USER=$(echo "${SECRET_JSON}" | jq -r .username)
PGPASSWORD=$(echo "${SECRET_JSON}" | jq -r .password)
export PGPASSWORD

# ---------------------------------------------------------------------------
# First-run guard: if no backup exists yet (BOOTSTRAP.md Step 5), skip
# restore entirely rather than failing. ECS services start with empty DBs
# and the panel initialises its own schema on first boot.
# ---------------------------------------------------------------------------
echo "=== Checking for canonical backups in S3 ==="
PANEL_EXISTS=true
BOT_EXISTS=true

if ! aws s3 ls "${S3_BUCKET}/panel_latest.dump" > /dev/null 2>&1; then
  echo "WARNING: panel_latest.dump not found in ${S3_BUCKET} — skipping panel restore."
  PANEL_EXISTS=false
fi

if ! aws s3 ls "${S3_BUCKET}/bot_latest.dump" > /dev/null 2>&1; then
  echo "WARNING: bot_latest.dump not found in ${S3_BUCKET} — skipping bot restore."
  BOT_EXISTS=false
fi

if [ "${PANEL_EXISTS}" = "false" ] && [ "${BOT_EXISTS}" = "false" ]; then
  echo "No backups found. First run — starting with empty databases. See BOOTSTRAP.md Step 5."
  exit 0
fi

# ---------------------------------------------------------------------------
# Ensure logical databases exist before pg_restore tries to connect to them.
# PostgreSQL has no CREATE DATABASE IF NOT EXISTS, so check pg_database first.
# ---------------------------------------------------------------------------
ensure_db() {
  DB_NAME="$1"
  DB_EXISTS=$(psql \
    -h "${RDS_PRIVATE_ENDPOINT}" \
    -U "${DB_USER}" \
    -d postgres \
    -tc "SELECT 1 FROM pg_database WHERE datname = '${DB_NAME}'" \
    | tr -d '[:space:]')

  if [ "${DB_EXISTS}" != "1" ]; then
    echo "Creating database ${DB_NAME}..."
    psql \
      -h "${RDS_PRIVATE_ENDPOINT}" \
      -U "${DB_USER}" \
      -d postgres \
      -c "CREATE DATABASE \"${DB_NAME}\";"
  else
    echo "Database ${DB_NAME} already exists."
  fi
}

ensure_db "${PANEL_DB_NAME}"
ensure_db "${BOT_DB_NAME}"

# ---------------------------------------------------------------------------
# Restore — --no-owner prevents ownership conflicts since we restore as the
# RDS master user rather than the original dump owner.
# || true: pg_restore exits non-zero on non-fatal warnings (e.g. missing
# extensions). Real failures are visible in CloudWatch logs.
# ---------------------------------------------------------------------------
if [ "${PANEL_EXISTS}" = "true" ]; then
  echo "=== Downloading panel_latest.dump ==="
  aws s3 cp "${S3_BUCKET}/panel_latest.dump" /tmp/panel_latest.dump

  echo "=== Restoring ${PANEL_DB_NAME} ==="
  pg_restore \
    -h "${RDS_PRIVATE_ENDPOINT}" \
    -U "${DB_USER}" \
    -d "${PANEL_DB_NAME}" \
    --clean \
    --if-exists \
    --no-owner \
    /tmp/panel_latest.dump || true
fi

if [ "${BOT_EXISTS}" = "true" ]; then
  echo "=== Downloading bot_latest.dump ==="
  aws s3 cp "${S3_BUCKET}/bot_latest.dump" /tmp/bot_latest.dump

  echo "=== Restoring ${BOT_DB_NAME} ==="
  pg_restore \
    -h "${RDS_PRIVATE_ENDPOINT}" \
    -U "${DB_USER}" \
    -d "${BOT_DB_NAME}" \
    --clean \
    --if-exists \
    --no-owner \
    /tmp/bot_latest.dump || true
fi

echo "=== Restore complete. Task exiting. ==="
