#!/usr/bin/env bash
#──────────────────────────────────────────────────────────────
# RxSoft backup — PostgreSQL + MongoDB → local + S3
# Usage: ./backup.sh
#   S3_BUCKET=s3://my-bucket /opt/rxsoft-docker/backup.sh
#──────────────────────────────────────────────────────────────
set -euo pipefail

# Source centralized backup config (written by terraform on EC2)
BACKUP_ENV_FILE="$(dirname "$0")/.env.backup"
[ -f "$BACKUP_ENV_FILE" ] && source "$BACKUP_ENV_FILE"

# ── Config ──────────────────────────────────────────────────
BACKUP_DIR="${BACKUP_DIR:-/var/backups/rxsoft}"
RETENTION_DAYS="${RETENTION_DAYS:-30}"
S3_BUCKET="${S3_BUCKET:-}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
TMPDIR=$(mktemp -d)

MONGO_USER="${MONGO_USER:-admin}"
MONGO_PASS="${MONGO_PASS:-admin123}"
MONGO_AUTH_DB="${MONGO_AUTH_DB:-admin}"

PG_USER="${PG_USER:-postgres}"
PG_DBS=("rxsoft" "lis")
MONGO_DBS=("conversation_engine" "apm_campaign")
SQLITE_DBS=(
  "rxsoft-healthcare-concepts:coding-concepts.sqlite"
  "rxsoft-healthcare-interop:interop.sqlite"
)

POSTGRES_CONTAINER="rxsoft-postgres"
MONGO_CONTAINER="rxsoft-mongodb"

log()  { echo "[$(date +%H:%M:%S)] $*"; }
err()  { log "ERROR: $*"; exit 1; }
cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

# ── Checks ──────────────────────────────────────────────────
mkdir -p "$BACKUP_DIR"
command -v aws >/dev/null 2>&1 && AWS_AVAILABLE=true || AWS_AVAILABLE=false

# ── PostgreSQL dumps ────────────────────────────────────────
pg_dump_db() {
  local db=$1 out=$2
  log "  PostgreSQL: dumping $db..."
  docker exec "$POSTGRES_CONTAINER" \
    pg_dump -U "$PG_USER" -d "$db" -F c --no-owner --no-acl \
    > "$out" 2>/dev/null || err "pg_dump failed for $db"
  log "  Done: $db ($(du -sh "$out" | cut -f1))"
}

# ── SQLite dumps ────────────────────────────────────────────
container_running() {
  docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null | grep -q true
}

sqlite_dump_db() {
  local container=$1 db_file=$2 out=$3
  log "  SQLite: dumping $container:$db_file..."
  if ! container_running "$container"; then
    log "  WARNING: Container $container not running - skipping"
    return
  fi
  if docker exec "$container" sh -c "command -v sqlite3" >/dev/null 2>&1; then
    timeout 10 docker exec "$container" sqlite3 "/app/$db_file" ".backup '$TMPDIR/$out'" 2>/dev/null || true
  elif command -v sqlite3 >/dev/null 2>&1; then
    timeout 10 docker cp "$container:/app/$db_file" "$TMPDIR/${out}.tmp" 2>/dev/null || true
    if [ -f "$TMPDIR/${out}.tmp" ]; then
      sqlite3 "$TMPDIR/${out}.tmp" ".backup '$TMPDIR/$out'" 2>/dev/null
      rm -f "$TMPDIR/${out}.tmp"
    fi
  else
    timeout 10 docker cp "$container:/app/$db_file" "$TMPDIR/$out" 2>/dev/null || true
  fi
  if [ -f "$TMPDIR/$out" ]; then
    log "  Done: $db_file ($(du -sh "$TMPDIR/$out" | cut -f1))"
  else
    log "  WARNING: No SQLite db found at /app/$db_file in $container — skipping"
  fi
}

# ── MongoDB dumps ───────────────────────────────────────────
mongo_dump_db() {
  local db=$1 out=$2
  log "  MongoDB: dumping $db..."
  docker exec "$MONGO_CONTAINER" \
    mongodump --username "$MONGO_USER" --password "$MONGO_PASS" \
      --authenticationDatabase "$MONGO_AUTH_DB" \
      --db "$db" --archive 2>/dev/null \
    > "$out" || err "mongodump failed for $db"
  log "  Done: $db ($(du -sh "$out" | cut -f1))"
}

# ── Run ─────────────────────────────────────────────────────
log "=== RxSoft backup $TIMESTAMP ==="
log "Backup dir: $BACKUP_DIR"
log ""

# PostgreSQL
log "--- PostgreSQL ---"
for db in "${PG_DBS[@]}"; do
  pg_dump_db "$db" "$TMPDIR/${db}.dump"
done

# MongoDB
log "--- MongoDB ---"
for db in "${MONGO_DBS[@]}"; do
  mongo_dump_db "$db" "$TMPDIR/${db}.archive"
done

# SQLite
log "--- SQLite ---"
for entry in "${SQLITE_DBS[@]}"; do
  container="${entry%%:*}"
  db_file="${entry#*:}"
  sqlite_dump_db "$container" "$db_file" "${container}.sqlite"
done

# ── Archive ─────────────────────────────────────────────────
ARCHIVE="$BACKUP_DIR/rxsoft-$TIMESTAMP.tar.gz"
log "--- Creating archive ---"
tar -czf "$ARCHIVE" -C "$TMPDIR" .
log "Archive: $ARCHIVE ($(du -sh "$ARCHIVE" | cut -f1))"

# ── S3 upload ───────────────────────────────────────────────
if [ -n "$S3_BUCKET" ] && [ "$AWS_AVAILABLE" = true ]; then
  log "--- Uploading to S3 ---"
  S3_PATH="s3://$S3_BUCKET/rxsoft/$TIMESTAMP.tar.gz"
  aws s3 cp "$ARCHIVE" "$S3_PATH" || err "S3 upload failed"
  log "Uploaded: $S3_PATH"
elif [ -n "$S3_BUCKET" ]; then
  log "WARNING: S3_BUCKET is set but 'aws' CLI not found — skipping upload"
fi

# ── Retention ───────────────────────────────────────────────
log "--- Cleaning backups older than ${RETENTION_DAYS} days ---"
find "$BACKUP_DIR" -maxdepth 1 -name 'rxsoft-*.tar.gz' -mtime +$((RETENTION_DAYS - 1)) \
  -exec rm -v {} \;

log "=== Backup complete ($(du -sh "$ARCHIVE" | cut -f1)) ==="
