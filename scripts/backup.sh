#!/bin/sh
set -eu

TIMESTAMP=$(date +%Y%m%d_%H%M%S)

echo "=== Fetching RDS credentials from Secrets Manager ==="
SECRET_JSON=$(aws secretsmanager get-secret-value \
  --secret-id  "${RDS_SECRET_ARN}" \
  --query      SecretString \
  --output     text)
DB_USER=$(echo "${SECRET_JSON}" | jq -r .username)
PGPASSWORD=$(echo "${SECRET_JSON}" | jq -r .password)
export PGPASSWORD

echo "=== Dumping ${PANEL_DB_NAME} ==="
pg_dump \
  -h "${RDS_PRIVATE_ENDPOINT}" \
  -U "${DB_USER}" \
  -d "${PANEL_DB_NAME}" \
  -Fc \
  -f /tmp/panel_db.dump

echo "=== Dumping ${BOT_DB_NAME} ==="
pg_dump \
  -h "${RDS_PRIVATE_ENDPOINT}" \
  -U "${DB_USER}" \
  -d "${BOT_DB_NAME}" \
  -Fc \
  -f /tmp/bot_db.dump

echo "=== Uploading timestamped history copies ==="
aws s3 cp /tmp/panel_db.dump "${S3_BUCKET}/history/${TIMESTAMP}_panel.dump"
aws s3 cp /tmp/bot_db.dump   "${S3_BUCKET}/history/${TIMESTAMP}_bot.dump"

echo "=== Updating canonical restore pointers ==="
aws s3 cp /tmp/panel_db.dump "${S3_BUCKET}/panel_latest.dump"
aws s3 cp /tmp/bot_db.dump   "${S3_BUCKET}/bot_latest.dump"

echo "=== Backup complete. Task exiting. ==="
