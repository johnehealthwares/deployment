#!/bin/bash
#──────────────────────────────────────────────────────────────
# DEPRECATED — use docker/backup.sh instead
# This script is kept for compatibility but will not be updated.
# docker/backup.sh supports: PostgreSQL + MongoDB + SQLite, S3, retention
#──────────────────────────────────────────────────────────────
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/.env"

DATE=$(date +%Y%m%d_%H%M%S)

BACKUP_DIR=/tmp/backups

mkdir -p "$BACKUP_DIR"

CONTAINER_ID=$(docker ps -q --filter "ancestor=postgres")

docker exec "$CONTAINER_ID" \
  pg_dump \
  -U "$POSTGRES_USER" \
  -d "$POSTGRES_DB" \
  > "$BACKUP_DIR/${POSTGRES_DB}_${DATE}.sql"

aws s3 cp \
  "$BACKUP_DIR/${POSTGRES_DB}_${DATE}.sql" \
  "s3://${S3_BUCKET}/"

find "$BACKUP_DIR" -type f -mtime +7 -delete