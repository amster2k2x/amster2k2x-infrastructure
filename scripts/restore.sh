#!/bin/sh
set -eu

echo "Checking for golden backup s3://${BACKUP_S3_BUCKET}/${BACKUP_S3_KEY}..."

if ! aws s3 cp "s3://${BACKUP_S3_BUCKET}/${BACKUP_S3_KEY}" /tmp/dump.sql 2>/tmp/s3-error.log; then
  if grep -qi "does not exist\|Not Found\|404" /tmp/s3-error.log; then
    echo "No golden backup found yet — this looks like a first run before any"
    echo "backup has been captured (see BOOTSTRAP.md step 5). Starting with an"
    echo "empty database instead of failing."
    exit 0
  fi
  echo "S3 download failed for a reason other than 'missing object' — treating as a real error:"
  cat /tmp/s3-error.log
  exit 1
fi

echo "Restoring golden backup into ${PGDATABASE}..."

# Golden dump is created with `pg_dump --format=plain --clean --if-exists`
# so a straight psql replay is idempotent-ish across runs.
psql -h "${PGHOST}" -U "${PGUSER}" -d "${PGDATABASE}" -f /tmp/dump.sql

echo "Restore complete."