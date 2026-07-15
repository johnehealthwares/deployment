#!/usr/bin/env bash
#──────────────────────────────────────────────────────────────
# restart-service.sh — restart a service on the run instance
# Optionally update env vars via SCP before restarting.
#
# Usage:
#   ./restart-service.sh <service>
#   ./restart-service.sh --list
#──────────────────────────────────────────────────────────────
set -euo pipefail
cd "$(dirname "$0")"

SSH_KEY="terraform/ssh/id_rsa"
SSH_USER="ubuntu"
IP=$(cat .ec2-ip 2>/dev/null || terraform -chdir=terraform output -raw public_ip 2>/dev/null)
[ -z "$IP" ] && { echo "Error: no .ec2-ip and terraform output failed"; exit 1; }
SSH="ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -i $SSH_KEY $SSH_USER@$IP"

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

SERVICE=""
for arg in "$@"; do
  case "$arg" in
    --list)
      echo "Available services:"
      for entry in "${SERVICES[@]}"; do echo "  ${entry%%|*}"; done
      exit 0
      ;;
    --help)
      echo "Usage: ./restart-service.sh <service>"
      echo ""
      echo "Restart a service on the run instance."
      echo "Prompts whether to update env vars via SCP first."
      exit 0
      ;;
    *)
      [ -n "$SERVICE" ] && { echo "Error: multiple services specified"; exit 1; }
      SERVICE="$arg"
      ;;
  esac
done

[ -z "$SERVICE" ] && { echo "Error: specify a service. Use --list to see available."; exit 1; }
[ -z "$(get_field "$SERVICE" context)" ] && { echo "Error: unknown service '$SERVICE'"; exit 1; }

DOCKER_DIR="/home/ubuntu/develop/docker"
echo "=== Restart: $SERVICE ==="
echo "  Server: $IP"

# Ask about env vars
DEPLOY_DIR="/home/ubuntu/develop/deployment"
ENV_CONTEXT="$(get_field "$SERVICE" context)"
ENV_FILE="terraform/.env.$ENV_CONTEXT"
echo "Update env vars for $SERVICE?"
echo "  [s] SCP local env file to server"
echo "  [g] Git pull deployment repo on server"
echo "  [N] No, just restart"
read -p "Choice (s/g/N): " answer
case "${answer:-N}" in
  [sS])
    if [ -f "$ENV_FILE" ]; then
      echo "--- SCP env file for $SERVICE ---"
      scp -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -i $SSH_KEY "$ENV_FILE" $SSH_USER@$IP:$DOCKER_DIR/.env.$SERVICE
    else
      echo "  No env file found at $ENV_FILE (skipping)"
    fi
    ;;
  [gG])
    echo "--- Git pull deployment repo on server ---"
    $SSH "cd $DEPLOY_DIR && git pull"
    echo "--- Copy env file from repo to docker dir ---"
    $SSH "cp $DEPLOY_DIR/$ENV_FILE $DOCKER_DIR/.env.$SERVICE"
    ;;
  *)
    echo "--- Skipping env update ---"
    ;;
esac

# Pull + restart
echo "--- Pull + restart on server ---"
AWS_ACCOUNT_ID=$(cd terraform && terraform output -raw aws_account_id)
$SSH "cd $DOCKER_DIR && sudo AWS_ACCOUNT_ID=$AWS_ACCOUNT_ID AWS_REGION=eu-west-1 docker compose -f docker-compose.prod.yml --profile $SERVICE pull $SERVICE 2>&1 | tail -1"
$SSH "cd $DOCKER_DIR && sudo AWS_ACCOUNT_ID=$AWS_ACCOUNT_ID AWS_REGION=eu-west-1 docker compose -f docker-compose.prod.yml --profile $SERVICE up -d --no-build --no-deps --force-recreate $SERVICE" 2>&1

# Wait for healthcheck
echo ""
echo "--- Wait for healthy ---"
sleep 5
for i in $(seq 1 12); do
  case "$SERVICE" in rxsoft-*) CNAME="$SERVICE" ;; *) CNAME="rxsoft-$SERVICE" ;; esac
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

echo ""
echo "=== Final Status ==="
$SSH "sudo docker ps --filter name='$SERVICE' --format 'table {{.Names}}\t{{.Status}}'"
echo "=== Done ==="
