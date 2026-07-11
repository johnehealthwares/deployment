#!/usr/bin/env bash
#──────────────────────────────────────────────────────────────
# RxSoft restore — restore from a local backup archive
# Usage:
#   ./restore.sh list                              # list available backups
#   ./restore.sh rxsoft-20260101_030000.tar.gz      # restore a specific backup
#   S3_BUCKET=s3://my-bucket ./restore.sh list      # list S3 backups
#   S3_BUCKET=s3://my-bucket ./restore.sh pull      # download from S3, then restore
#──────────────────────────────────────────────────────────────
set -euo pipefail

# Source centralized backup config (written by terraform on EC2)
BACKUP_ENV_FILE="$(dirname "$0")/.env.backup"
[ -f "$BACKUP_ENV_FILE" ] && source "$BACKUP_ENV_FILE"

BACKUP_DIR="${BACKUP_DIR:-/var/backups/rxsoft}"
TMPDIR=$(mktemp -d)
cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

MONGO_USER="${MONGO_USER:-admin}"
MONGO_PASS="${MONGO_PASS:-admin123}"
MONGO_AUTH_DB="${MONGO_AUTH_DB:-admin}"
PG_USER="${PG_USER:-postgres}"
POSTGRES_CONTAINER="rxsoft-postgres"
MONGO_CONTAINER="rxsoft-mongodb"
SQLITE_DBS=(
  "rxsoft-healthcare-concepts:coding-concepts.sqlite"
  "rxsoft-healthcare-interop:interop.sqlite"
)

log() { echo "[$(date +%H:%M:%S)] $*"; }
err() { log "ERROR: $*"; exit 1; }

list_backups() {
  echo "Local backups in $BACKUP_DIR:"
  ls -1tr "$BACKUP_DIR"/rxsoft-*.tar.gz 2>/dev/null | while read -r f; do
    echo "  $(basename "$f")  ($(du -sh "$f" | cut -f1))"
  done
  if [ -n "${S3_BUCKET:-}" ]; then
    echo ""
    echo "S3 backups at $S3_BUCKET:"
    aws s3 ls "$S3_BUCKET/rxsoft/" 2>/dev/null || echo "  (none or inaccessible)"
  fi
}

restore_archive() {
  local archive=$1
  [ -f "$archive" ] || err "File not found: $archive"
  log "Extracting $archive..."
  tar -xzf "$archive" -C "$TMPDIR"
  log ""

  # Restore PostgreSQL
  log "--- Restoring PostgreSQL ---"
  for f in "$TMPDIR"/*.dump; do
    local db
    db=$(basename "$f" .dump)
    log "  Restoring $db..."
    docker exec -i "$POSTGRES_CONTAINER" \
      pg_restore -U "$PG_USER" -d "$db" --clean --if-exists \
      < "$f" 2>/dev/null || err "pg_restore failed for $db"
    log "  Done: $db"
  done

  # Restore MongoDB
  log "--- Restoring MongoDB ---"
  for f in "$TMPDIR"/*.archive; do
    local db
    db=$(basename "$f" .archive)
    log "  Restoring $db..."
    docker exec -i "$MONGO_CONTAINER" \
      mongorestore --username "$MONGO_USER" --password "$MONGO_PASS" \
        --authenticationDatabase "$MONGO_AUTH_DB" \
        --drop --archive < "$f" 2>/dev/null || err "mongorestore failed for $db"
    log "  Done: $db"
  done

  # Restore SQLite
  log "--- Restoring SQLite ---"
  for entry in "${SQLITE_DBS[@]}"; do
    container="${entry%%:*}"
    db_file="${entry#*:}"
    backup_file="$TMPDIR/${container}.sqlite"
    if [ -f "$backup_file" ]; then
      log "  Restoring $db_file to $container..."
      docker cp "$backup_file" "$container:/app/$db_file" 2>/dev/null || \
        log "  WARNING: Failed to copy $db_file to $container"
      log "  Done: $db_file"
    else
      log "  No SQLite backup found for $container — skipping"
    fi
  done

  log "=== Restore complete ==="
}

# ── Main ────────────────────────────────────────────────────
cmd="${1:-list}"
shift 2>/dev/null || true

case "$cmd" in
  list)
    list_backups
    ;;
  pull)
    [ -n "${S3_BUCKET:-}" ] || err "Set S3_BUCKET env var"
    log "Downloading latest backup from S3..."
    LATEST=$(aws s3 ls "$S3_BUCKET/rxsoft/" | sort | tail -1 | awk '{print $4}')
    [ -n "$LATEST" ] || err "No backups found in S3"
    aws s3 cp "$S3_BUCKET/rxsoft/$LATEST" "$BACKUP_DIR/$LATEST"
    log "Downloaded: $BACKUP_DIR/$LATEST"
    restore_archive "$BACKUP_DIR/$LATEST"
    ;;
  *)
    if [ -f "$BACKUP_DIR/$cmd" ]; then
      restore_archive "$BACKUP_DIR/$cmd"
    else
      echo "Usage: $(basename "$0") [list | pull | <archive-name>]"
      echo ""
      echo "  list                        List available backups"
      echo "  pull                        Download latest from S3 + restore"
      echo "  rxsoft-20260101_030000.tar.gz  Restore local archive"
      echo ""
      echo "Env: S3_BUCKET=s3://bucket  BACKUP_DIR=/var/backups/rxsoft"
      exit 1
    fi
    ;;
esac
