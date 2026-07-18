#!/usr/bin/env bash
#──────────────────────────────────────────────────────────────
# deploy_mongo_init.sh — re-run MongoDB replica set init
# on the production instance.
#
# Use when mongo-init container failed or replica set status
# was lost (e.g., after container recreation or keyfile reset).
#
# Usage:
#   ./deploy_mongo_init.sh
#──────────────────────────────────────────────────────────────
set -euo pipefail
cd "$(dirname "$0")"

SSH_KEY="terraform/ssh/id_rsa"
IP=$(cat .ec2-ip 2>/dev/null || terraform -chdir=terraform output -raw public_ip 2>/dev/null)
[ -z "$IP" ] && { echo "Error: cannot determine IP"; exit 1; }
SSH="ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -i $SSH_KEY ubuntu@$IP"

echo "=== MongoDB Replica Set Init ==="
echo "  Instance: $IP"

# ── 1. Check mongodb is healthy ─────────────────────────────
echo "--- Checking mongodb status ---"
MONGO_OK=false
for i in $(seq 1 12); do
  STATUS=$($SSH "sudo docker ps --filter name=rxsoft-mongodb --format '{{.Status}}' 2>/dev/null" 2>/dev/null || true)
  if echo "$STATUS" | grep -q "(healthy)"; then
    echo "  rxsoft-mongodb ✅ healthy"
    MONGO_OK=true
    break
  fi
  if echo "$STATUS" | grep -q "unhealthy"; then
    echo "  rxsoft-mongodb ❌ unhealthy — fix keyfile first"
    $SSH "sudo chown 999:999 /home/ubuntu/develop/docker/mongodb/mongo-keyfile 2>/dev/null; sudo chmod 400 /home/ubuntu/develop/docker/mongodb/mongo-keyfile; sudo docker restart rxsoft-mongodb" 2>/dev/null || true
    sleep 10
    continue
  fi
  echo "  ${STATUS:-waiting} ($i)"
  sleep 5
done
if [ "$MONGO_OK" != true ]; then
  echo "  ❌ Mongodb not healthy, aborting"
  exit 1
fi

# ── 2. Check if replica set already exists ──────────────────
echo "--- Checking existing replica set status ---"
RS_STATUS=$($SSH "sudo docker exec rxsoft-mongodb mongosh --quiet --eval 'rs.status().ok' 2>/dev/null" 2>/dev/null || true)
if [ "$RS_STATUS" = "1" ]; then
  echo "  Replica set already initialized ✅"
  echo ""
  $SSH "sudo docker exec rxsoft-mongodb mongosh --quiet --eval 'rs.status().members.forEach(function(m){print(m.name+\" \"+m.stateStr)})' 2>/dev/null" || true
  exit 0
fi
echo "  No replica set found — initializing..."

# ── 3. Init replica set ────────────────────────────────────
echo "--- Initializing replica set rs0 ---"
$SSH "sudo docker exec rxsoft-mongodb mongosh --quiet --eval 'rs.initiate({_id:\"rs0\",members:[{_id:0,host:\"localhost:27017\"}]})' 2>&1" || true
sleep 3

# ── 4. Create admin user if not exists ──────────────────────
echo "--- Creating admin user ---"
$SSH "sudo docker exec rxsoft-mongodb mongosh admin --quiet --eval 'if(!db.getUser(\"admin\")){db.createUser({user:\"admin\",pwd:\"admin123\",roles:[{role:\"root\",db:\"admin\"}]})}' 2>&1" || true

# ── 5. Verify ───────────────────────────────────────────────
echo "--- Verification ---"
sleep 2
RS_STATUS=$($SSH "sudo docker exec rxsoft-mongodb mongosh --quiet --eval 'rs.status().ok' 2>/dev/null" 2>/dev/null || true)
if [ "$RS_STATUS" = "1" ]; then
  echo "  ✅ Replica set rs0 initialized and running"
  $SSH "sudo docker exec rxsoft-mongodb mongosh --quiet --eval 'rs.status().members.forEach(function(m){print(\"  \"+m.name+\" \"+m.stateStr)})' 2>/dev/null" || true
else
  echo "  ❌ Failed to initialize replica set"
  $SSH "sudo docker exec rxsoft-mongodb mongosh --quiet --eval 'rs.status()' 2>/dev/null" || true
  exit 1
fi
echo "=== Done ==="
