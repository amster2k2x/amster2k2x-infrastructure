#!/bin/sh
set -eu

echo "Restoring golden backup s3://${BACKUP_S3_BUCKET}/${BACKUP_S3_KEY} into ${PGDATABASE}..."

aws s3 cp "s3://${BACKUP_S3_BUCKET}/${BACKUP_S3_KEY}" /tmp/dump.sql

# Golden dump is created with `pg_dump --format=plain --clean --if-exists`
# so a straight psql replay is idempotent-ish across runs.
psql -h "${PGHOST}" -U "${PGUSER}" -d "${PGDATABASE}" -f /tmp/dump.sql

echo "Restore complete."
