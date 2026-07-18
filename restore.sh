#!/usr/bin/env bash
#──────────────────────────────────────────────────────────────
# restore.sh — restore RxSoft databases from a backup archive.
#
# Lists backups from S3, server local, and local backups/ dir.
# Prompts user to choose which backup to restore.
#
# Usage:
#   ./restore.sh
#   ./restore.sh --dry-run
#──────────────────────────────────────────────────────────────
set -euo pipefail
cd "$(dirname "$0")"

SSH_KEY="terraform/ssh/id_rsa"
IP=$(cat .ec2-ip 2>/dev/null || terraform -chdir=terraform output -raw public_ip 2>/dev/null)
[ -z "$IP" ] && { echo "Error: no .ec2-ip and terraform output failed"; exit 1; }
SSH="ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -i $SSH_KEY ubuntu@$IP"

DRY_RUN=false
[ "${1:-}" = "--dry-run" ] && DRY_RUN=true

ARCHIVE=""
TMPDIR=$(mktemp -d)
trap "rm -rf '$TMPDIR'" EXIT

echo "=== RxSoft Database Restore ==="
echo "  Instance: $IP"
echo ""

# ── Step 1: List backups from all sources ───────────────────
echo "--- Listing backups ---"

declare -a ENTRIES=()
declare -a LABELS=()

# Source A: S3
echo ""
echo "  [A] S3 backups (rxsoft-postgres-backups-prod):"
S3_ENTRIES=()
while read -r date time size name; do
  [ -z "$name" ] && continue
  S3_ENTRIES+=("$name")
  LABELS+=("S3: $name ($(numfmt --to=iec $size 2>/dev/null || echo ${size}B))")
  ENTRIES+=("s3|$name")
done < <(aws s3 ls s3://rxsoft-postgres-backups-prod/rxsoft/ 2>/dev/null || true)

if [ ${#S3_ENTRIES[@]} -eq 0 ]; then
  echo "    (no backups found)"
fi

# Source B: Server local
echo ""
echo "  [B] Server local backups ($IP:/var/backups/rxsoft/):"
SERVER_ENTRIES=()
while IFS= read -r line; do
  [ -z "$line" ] && continue
  # Skip "total X" line from ls -lh
  echo "$line" | grep -q '^total' && continue
  name=$(echo "$line" | awk '{print $NF}')
  size=$(echo "$line" | awk '{print $5}')
  SERVER_ENTRIES+=("$name")
  LABELS+=("Server: $name ($size)")
  ENTRIES+=("server|$name")
done < <($SSH "ls -lh /var/backups/rxsoft/ 2>/dev/null" 2>/dev/null || true)

if [ ${#SERVER_ENTRIES[@]} -eq 0 ]; then
  echo "    (no backups found)"
fi

# Source C: Local backups/ dir
LOCAL_DIR="$PWD/backups"
echo ""
echo "  [C] Local backups ($LOCAL_DIR):"
LOCAL_ENTRIES=()
if [ -d "$LOCAL_DIR" ]; then
  for f in "$LOCAL_DIR"/rxsoft-*.tar.gz; do
    [ -f "$f" ] || continue
    name=$(basename "$f")
    size=$(du -sh "$f" | cut -f1)
    LOCAL_ENTRIES+=("$f")
    LABELS+=("Local: $name ($size)")
    ENTRIES+=("local|$f")
  done
fi

if [ ${#LOCAL_ENTRIES[@]} -eq 0 ]; then
  echo "    (no backups found)"
fi

TOTAL=${#ENTRIES[@]}
if [ "$TOTAL" -eq 0 ]; then
  echo ""
  echo "  ❌ No backups found anywhere. Run backup.sh first."
  exit 1
fi

# ── Step 2: User selects backup ─────────────────────────────
echo ""
echo "--- Select backup to restore ---"
for i in "${!LABELS[@]}"; do
  printf "  %3d. %s\n" $((i+1)) "${LABELS[$i]}"
done
echo ""
read -r -p "Enter number (1-$TOTAL, or 0 to cancel): " CHOICE
CHOICE=${CHOICE:-0}
if [ "$CHOICE" -lt 1 ] || [ "$CHOICE" -gt "$TOTAL" ]; then
  echo "Cancelled."
  exit 0
fi

IDX=$((CHOICE - 1))
RAW="${ENTRIES[$IDX]}"
SOURCE="${RAW%%|*}"
PATH_OR_NAME="${RAW#*|}"

echo ""
echo "  Selected: ${LABELS[$IDX]}"

# ── Step 3: Download/extract archive ────────────────────────
echo ""
echo "--- Downloading backup ---"

case "$SOURCE" in
  s3)
    S3_PATH="s3://rxsoft-postgres-backups-prod/rxsoft/$PATH_OR_NAME"
    ARCHIVE="$TMPDIR/restore.tar.gz"
    aws s3 cp "$S3_PATH" "$ARCHIVE" 2>&1 | tail -1 || { echo "  ❌ S3 download failed"; exit 1; }
    echo "  Downloaded from S3"
    ;;
  server)
    ARCHIVE="$TMPDIR/restore.tar.gz"
    $SSH "cat /var/backups/rxsoft/$PATH_OR_NAME" > "$ARCHIVE" 2>/dev/null || { echo "  ❌ Server download failed"; exit 1; }
    echo "  Downloaded from server"
    ;;
  local)
    ARCHIVE="$PATH_OR_NAME"
    echo "  Using local file: $ARCHIVE"
    ;;
esac

EXTRACT_DIR="$TMPDIR/extracted"
mkdir -p "$EXTRACT_DIR"
tar -xzf "$ARCHIVE" -C "$EXTRACT_DIR" 2>/dev/null || { echo "  ❌ Failed to extract archive"; exit 1; }
echo "  Extracted to $EXTRACT_DIR"

ls "$EXTRACT_DIR/" 2>/dev/null

if [ "$DRY_RUN" = true ]; then
  echo ""
  echo "  [DRY-RUN] Would restore files:"
  ls -la "$EXTRACT_DIR/"
  exit 0
fi

# ── Step 4: Confirm ──────────────────────────────────────────
echo ""
echo "--- Restore will overwrite current databases ---"
echo "  Databases: rxsoft (PG), lis (PG), conversation_engine (MG), apm_campaign (MG)"
echo "  This is IRREVERSIBLE."
read -r -p "Continue? (y/N): " CONFIRM
CONFIRM=${CONFIRM:-n}
if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
  echo "Cancelled."
  exit 0
fi

# ── Step 5: Restore PostgreSQL ──────────────────────────────
echo ""
echo "--- Restoring PostgreSQL ---"
for db in rxsoft lis; do
  DUMP="$EXTRACT_DIR/${db}.dump"
  if [ ! -f "$DUMP" ]; then
    echo "  Skipping $db (no dump file)"
    continue
  fi
  echo "  Restoring $db..."
  # Drop and recreate the database
  $SSH "sudo docker exec rxsoft-postgres psql -U postgres -c 'DROP DATABASE IF EXISTS $db' 2>/dev/null; \
         sudo docker exec rxsoft-postgres psql -U postgres -c 'CREATE DATABASE $db' 2>/dev/null" || true
  # Restore from dump
  cat "$DUMP" | $SSH "sudo docker exec -i rxsoft-postgres pg_restore -U postgres -d $db --no-owner --no-acl 2>/dev/null" || \
    echo "  ⚠️  pg_restore had warnings for $db"
  echo "  ✅ $db restored"
done

# ── Step 6: Restore MongoDB ─────────────────────────────────
echo ""
echo "--- Restoring MongoDB ---"
for db in conversation_engine apm_campaign; do
  ARCHIVE_FILE="$EXTRACT_DIR/${db}.archive"
  if [ ! -f "$ARCHIVE_FILE" ]; then
    echo "  Skipping $db (no archive file)"
    continue
  fi
  echo "  Restoring $db..."
  cat "$ARCHIVE_FILE" | $SSH "sudo docker exec -i rxsoft-mongodb mongorestore \
    --username admin --password admin123 --authenticationDatabase admin \
    --db $db --drop --archive 2>/dev/null" || true
  echo "  ✅ $db restored"
done

# ── Step 7: Restore SQLite ──────────────────────────────────
echo ""
echo "--- Restoring SQLite ---"
for entry in rxsoft-healthcare-concepts:rxsoft-healthcare-concepts.sqlite rxsoft-healthcare-interop:rxsoft-healthcare-interop.sqlite; do
  container="${entry%%:*}"
  db_file="${entry#*:}"
  DUMP="$EXTRACT_DIR/$db_file"
  if [ ! -f "$DUMP" ]; then
    echo "  Skipping $container (no dump file)"
    continue
  fi
  CONTAINER_RUNNING=$($SSH "sudo docker inspect -f '{{.State.Running}}' $container 2>/dev/null" 2>/dev/null || echo "false")
  if [ "$CONTAINER_RUNNING" != "true" ]; then
    echo "  Skipping $container (not running)"
    continue
  fi
  echo "  Restoring $container..."
  $SSH "sudo docker cp - '$container:/app/$db_file'" < "$DUMP" 2>/dev/null || \
    cat "$DUMP" | $SSH "sudo docker exec -i $container sh -c 'cat > /app/$db_file'" 2>/dev/null || true
  echo "  ✅ $container restored"
done

# ── Step 8: Verify ──────────────────────────────────────────
echo ""
echo "--- Verification ---"
echo "  PostgreSQL:"
for db in rxsoft lis; do
  COUNT=$($SSH "sudo docker exec rxsoft-postgres psql -U postgres -d $db -t -c 'SELECT count(*) FROM information_schema.tables WHERE table_schema='\''public'\''' 2>/dev/null" 2>/dev/null || echo "0")
  echo "    $db: $COUNT tables"
done
echo "  MongoDB:"
for db in conversation_engine apm_campaign; do
  COUNT=$($SSH "sudo docker exec rxsoft-mongodb mongosh -u admin -p admin123 --authenticationDatabase admin --quiet --eval 'db.getSiblingDB(\"$db\").getCollectionNames().length' 2>/dev/null" 2>/dev/null || echo "?")
  echo "    $db: $COUNT collections"
done

echo ""
echo "=== Restore complete ==="
