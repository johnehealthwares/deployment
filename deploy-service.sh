#!/usr/bin/env bash
#──────────────────────────────────────────────────────────────
# deploy-service.sh — deploy a single service via ECR pipeline:
#   1. Build (git on build server, or local build, or skip)
#   2. Pull + restart on the production run instance
#
# Usage:
#   ./deploy-service.sh <service>                  # build (git on build server) + deploy
#   ./deploy-service.sh <service> --local          # build locally + deploy
#   ./deploy-service.sh <service> --skip-build     # just pull + restart
#   ./deploy-service.sh --list
#──────────────────────────────────────────────────────────────
set -euo pipefail
cd "$(dirname "$0")"

SSH_KEY="terraform/ssh/id_rsa"
SSH_USER="ubuntu"
IP=$(cat .ec2-ip 2>/dev/null || terraform -chdir=terraform output -raw public_ip 2>/dev/null)
[ -z "$IP" ] && { echo "Error: no .ec2-ip and terraform output failed"; exit 1; }
SSH="ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -i $SSH_KEY $SSH_USER@$IP"

# Service name tables: service|context_dir|git_remote|local_path
SERVICES=(
  "rxsoft-backend|rxsoft-backend|https://github.com/johnehealthwares/rxsoft-backend.git|../rxsoft-backend"
  "rxsoft-lis-backend|rxsoft-lis-backend|https://github.com/johnehealthwares/rxsoft-lis-backend.git|../rxsoft-lis-backend"
  "conversation-engine|conversation-engine|https://github.com/johnehealthwares/conversation-engine.git|../conversation-engine"
  "healthcare-concepts|common-healthcare-resources|https://github.com/johnehealthwares/healthcare-concepts.git|../common-healthcare-resources"
  "healthcare-interop|healthcare-interoperability-switch|https://github.com/johnehealthwares/healthcare-interoperability-switch.git|../healthcare-interoperability-switch"
  "rxsoft-admin|common-admin|https://github.com/johnehealthwares/rxsoft-admin-3.git|../rxsoft-admin-3"
  "rxsoft-identity|identity|https://github.com/johnehealthwares/identity.git|../identity"
  "ehealthwares|ehealthwares|https://github.com/johnehealthwares/ehealthwares.git|../ehealthwares"
)

get_field() {
  local svc="$1" field="$2" s c g l
  for entry in "${SERVICES[@]}"; do
    s="${entry%%|*}"; rest="${entry#*|}"
    [ "$s" != "$svc" ] && continue
    c="${rest%%|*}"; rest="${rest#*|}"
    g="${rest%%|*}"; rest="${rest#*|}"
    l="$rest"
    case "$field" in
      context) echo "$c" ;;
      remote)  echo "$g" ;;
      local)   echo "$l" ;;
    esac
    return
  done
  echo ""
}

MODE="git"
SKIP_BUILD=false
SERVICE=""

for arg in "$@"; do
  case "$arg" in
    --local) MODE="local" ;;
    --skip-build) SKIP_BUILD=true ;;
    --dry-run) DRY_RUN=true ;;
    --list)
      echo "Available services:"
      for entry in "${SERVICES[@]}"; do echo "  ${entry%%|*}"; done
      exit 0
      ;;
    --help)
      sed -n '3,14p' "$0"
      exit 0
      ;;
    *)
      [ -n "$SERVICE" ] && { echo "Error: multiple services specified"; exit 1; }
      SERVICE="$arg"
      ;;
  esac
done

[ -z "$SERVICE" ] && { echo "Error: specify a service"; exit 1; }
[ -z "$(get_field "$SERVICE" context)" ] && { echo "Error: unknown service '$SERVICE'"; exit 1; }

DOCKER_DIR="/home/ubuntu/develop/docker"
echo "=== Deploy: $SERVICE ($MODE) ==="
echo "  Server: $IP"

if [ "${DRY_RUN:-false}" = true ]; then
  echo "  [DRY-RUN] Would execute: build + ECR push + pull + restart"
  exit 0
fi

# Step 1 — Build + push to ECR
if [ "$SKIP_BUILD" = true ]; then
  echo "--- Build skipped (--skip-build) ---"
elif [ "$MODE" = "local" ]; then
  echo "--- Step 1: Local build + push ---"
  "$PWD/build-local-and-push.sh" "$SERVICE" 2>&1
else
  echo "--- Step 1: Build server (git) + push ---"
  "$PWD/build-and-push.sh" "$SERVICE" 2>&1
fi

# Step 2 — pull + restart on run instance
echo ""
echo "--- Step 2: Pull + restart on run instance ---"
AWS_ACCOUNT_ID=$(cd terraform && terraform output -raw aws_account_id)
$SSH "cd $DOCKER_DIR && sudo AWS_ACCOUNT_ID=$AWS_ACCOUNT_ID AWS_REGION=eu-west-1 docker compose pull $SERVICE 2>&1 | tail -1"
$SSH "cd $DOCKER_DIR && sudo AWS_ACCOUNT_ID=$AWS_ACCOUNT_ID AWS_REGION=eu-west-1 docker compose up -d --no-build --no-deps $SERVICE" 2>&1

# Step 3 — wait for healthcheck
echo ""
echo "--- Step 3: Wait for healthy ---"
sleep 5
for i in $(seq 1 12); do
  CNAME="rxsoft-$SERVICE"
  STATUS=$($SSH "sudo docker ps --filter name=$CNAME --format '{{.Status}}' 2>/dev/null" 2>/dev/null || echo "checking...")
  if echo "$STATUS" | grep -q "(healthy)"; then
    echo "  ✅ $SERVICE is healthy!"
    break
  fi
  if echo "$STATUS" | grep -q "(unhealthy)"; then
    echo "  ❌ $SERVICE is unhealthy — check logs"
    $SSH "sudo docker logs $CNAME --tail 20" 2>/dev/null || true
    exit 1
  fi
  echo "  Still starting... ($((i*5))s)"
  sleep 5
done

# Step 4 — show status
echo ""
echo "=== Final Status ==="
$SSH "sudo docker ps --filter name='$SERVICE' --format 'table {{.Names}}\t{{.Status}}'"
echo "=== Done ==="
