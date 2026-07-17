#!/usr/bin/env bash
#──────────────────────────────────────────────────────────────
# deploy_databases.sh — ensure postgres + mongodb are running
# and healthy on the production instance, then initiate the
# MongoDB replica set.
#
# Idempotent — safe to run repeatedly. Fails if any database
# fails to become healthy within the timeout.
#
# Usage:
#   ./deploy_databases.sh
#   ./deploy_databases.sh --dry-run
#──────────────────────────────────────────────────────────────
set -euo pipefail
cd "$(dirname "$0")"

SSH_KEY="terraform/ssh/id_rsa"
SSH_USER="ubuntu"
IP=$(cat .ec2-ip 2>/dev/null || terraform -chdir=terraform output -raw public_ip 2>/dev/null)
[ -z "$IP" ] && { echo "Error: no .ec2-ip and terraform output failed"; exit 1; }
SSH="ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -i $SSH_KEY $SSH_USER@$IP"
DOCKER_DIR="/home/ubuntu/develop/docker"

DRY_RUN=false
[ "${1:-}" = "--dry-run" ] && DRY_RUN=true

echo "=== Ensure databases are up ==="
echo "  Instance: $IP"

# Detect AWS account + region
AWS_ACCOUNT_ID=$(cd terraform && terraform output -raw aws_account_id 2>/dev/null || echo "750906968644")
AWS_REGION="eu-west-1"
ENV_VARS="AWS_ACCOUNT_ID=$AWS_ACCOUNT_ID AWS_REGION=$AWS_REGION"

if [ "$DRY_RUN" = true ]; then
  echo "  [DRY-RUN] Would start postgres + mongodb + mongo-init"
  exit 0
fi

# ── 1. Start databases ─────────────────────────────────────
echo "--- Starting postgres + mongodb ---"
$SSH "cd $DOCKER_DIR && sudo $ENV_VARS docker compose -f docker-compose.prod.yml --profile postgres --profile mongodb up -d --no-build" 2>&1 | tail -2

# ── 2. Wait for postgres healthy ───────────────────────────
echo "--- Waiting for postgres ---"
POSTGRES_OK=false
for i in $(seq 1 12); do
  STATUS=$($SSH "sudo docker ps --filter name=rxsoft-postgres --format '{{.Status}}' 2>/dev/null" 2>/dev/null || true)
  if echo "$STATUS" | grep -q "(healthy)"; then
    echo "  rxsoft-postgres ✅ healthy ($((i*5))s)"
    POSTGRES_OK=true
    break
  fi
  echo "  rxsoft-postgres ${STATUS:-starting...} ($((i*5))s)"
  sleep 5
done
if [ "$POSTGRES_OK" != true ]; then
  echo "  ❌ rxsoft-postgres failed to become healthy within 60s"
  $SSH "sudo docker logs rxsoft-postgres --tail 20" 2>/dev/null || true
  exit 1
fi

# ── 3. Wait for mongodb healthy ────────────────────────────
echo "--- Waiting for mongodb ---"
MONGO_OK=false
for i in $(seq 1 24); do
  STATUS=$($SSH "sudo docker ps --filter name=rxsoft-mongodb --format '{{.Status}}' 2>/dev/null" 2>/dev/null || true)
  if echo "$STATUS" | grep -q "(healthy)"; then
    echo "  rxsoft-mongodb ✅ healthy ($((i*5))s)"
    MONGO_OK=true
    break
  fi
  if echo "$STATUS" | grep -q "unhealthy"; then
    echo "  rxsoft-mongodb ❌ unhealthy — checking keyfile..."
    # Common fix: keyfile permissions got reset
    $SSH "sudo chown 999:999 $DOCKER_DIR/mongodb/mongo-keyfile 2>/dev/null; sudo chmod 400 $DOCKER_DIR/mongodb/mongo-keyfile 2>/dev/null; sudo docker restart rxsoft-mongodb" 2>/dev/null || true
    echo "  Restarted mongodb, waiting..."
    sleep 10
    continue
  fi
  echo "  rxsoft-mongodb ${STATUS:-starting...} ($((i*5))s)"
  sleep 5
done
if [ "$MONGO_OK" != true ]; then
  echo "  ❌ rxsoft-mongodb failed to become healthy within 120s"
  $SSH "sudo docker logs rxsoft-mongodb --tail 20" 2>/dev/null || true
  exit 1
fi

# ── 4. Start mongo-init (replica set) ──────────────────────
echo "--- Starting mongo-init (replica set) ---"
MONGO_INIT_EXISTS=$($SSH "sudo docker ps -a --filter name=rxsoft-mongo-init --format '{{.Names}}' 2>/dev/null" 2>/dev/null || true)
if [ -n "$MONGO_INIT_EXISTS" ]; then
  # Remove old container so it can run again
  $SSH "sudo docker rm -f rxsoft-mongo-init 2>/dev/null" || true
fi
$SSH "cd $DOCKER_DIR && sudo $ENV_VARS docker compose -f docker-compose.prod.yml --profile mongo-init up -d --no-build" 2>&1 | tail -2

echo "  Waiting for mongo-init to complete..."
MONGO_INIT_OK=false
for i in $(seq 1 12); do
  STATUS=$($SSH "sudo docker ps -a --filter name=rxsoft-mongo-init --format '{{.Status}}' 2>/dev/null" 2>/dev/null || true)
  if echo "$STATUS" | grep -q "Exited (0)"; then
    echo "  rxsoft-mongo-init ✅ completed"
    MONGO_INIT_OK=true
    break
  fi
  if echo "$STATUS" | grep -q "Exited"; then
    echo "  rxsoft-mongo-init ❌ failed — check logs"
    $SSH "sudo docker logs rxsoft-mongo-init --tail 10" 2>/dev/null || true
    exit 1
  fi
  echo "  rxsoft-mongo-init ${STATUS:-running...} ($((i*5))s)"
  sleep 5
done
if [ "$MONGO_INIT_OK" != true ]; then
  echo "  ❌ rxsoft-mongo-init did not complete within 60s"
  $SSH "sudo docker logs rxsoft-mongo-init --tail 20" 2>/dev/null || true
  exit 1
fi

echo ""
echo "=== Databases ready ==="
$SSH "sudo docker ps --filter name=rxsoft-postgres --filter name=rxsoft-mongodb --format 'table {{.Names}}\t{{.Status}}'" 2>/dev/null || true
