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
#   ./deploy-service.sh --all                      # deploy all services
#   ./deploy-service.sh --all --skip-build         # deploy all, skip build
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
ALL=false
DRY_RUN=false

while [ $# -gt 0 ]; do
  case "$1" in
    --local) MODE="local"; shift ;;
    --skip-build) SKIP_BUILD=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --all) ALL=true; shift ;;
    --list)
      echo "Available services:"
      for entry in "${SERVICES[@]}"; do echo "  ${entry%%|*}"; done
      exit 0
      ;;
    --help)
      sed -n '3,15p' "$0"
      exit 0
      ;;
    *)
      [ -n "$SERVICE" ] && { echo "Error: multiple services specified"; exit 1; }
      SERVICE="$1"; shift
      ;;
  esac
done

if [ "$ALL" = false ]; then
  [ -z "$SERVICE" ] && { echo "Error: specify a service or --all"; exit 1; }
  [ -z "$(get_field "$SERVICE" context)" ] && { echo "Error: unknown service '$SERVICE'"; exit 1; }
fi

DOCKER_DIR="/home/ubuntu/develop/docker"
DEPLOY_DIR="/home/ubuntu/develop/deployment"

deploy_one() {
  local svc="$1"
  echo ""
  echo "============================================"
  echo "  Deploy: $svc ($MODE)"
  echo "============================================"

  if [ "$DRY_RUN" = true ]; then
    echo "  [DRY-RUN] Would execute: build + ECR push + pull + restart for $svc"
    return 0
  fi

  # Prompt 1 — Build before deploy?
  LOCAL_PATH="$(get_field "$svc" local)"
  COMMIT=$(git -C "$PWD/$LOCAL_PATH" rev-parse HEAD 2>/dev/null || echo "unknown")
  MSG=$(git -C "$PWD/$LOCAL_PATH" log -1 --format=%s 2>/dev/null || echo "unknown")
  echo ""
  echo "  Service:   $svc"
  echo "  Mode:      $MODE"
  echo "  Commit:    ${COMMIT:0:10} — $MSG"
  if [ "$SKIP_BUILD" = false ]; then
    read -p "  Build before deploy? (Y/n): " build_ans
    case "${build_ans:-Y}" in
      [nN]) echo "  Build skipped."; SKIP_BUILD=true ;;
      *) ;;
    esac
  else
    echo "  Build: skipped (--skip-build)"
  fi

  # Prompt 2 — Update env?
  ENV_CONTEXT="$(get_field "$svc" context)"
  ENV_FILE="terraform/.env.$ENV_CONTEXT"
  read -p "  Update env? (s)cp / (g)it / (N)o: " env_ans
  case "${env_ans:-N}" in
    [sS])
      if [ -f "$ENV_FILE" ]; then
        echo "--- SCP env file for $svc ---"
        scp -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -i $SSH_KEY "$ENV_FILE" $SSH_USER@$IP:$DOCKER_DIR/.env.$svc
      else
        echo "  No env file found at $ENV_FILE (skipping)"
      fi
      ;;
    [gG])
      echo "--- Git pull deployment repo on server ---"
      $SSH "cd $DEPLOY_DIR && sudo git pull"
      echo "--- Copy env file from repo to docker dir ---"
      $SSH "sudo cp $DEPLOY_DIR/$ENV_FILE $DOCKER_DIR/.env.$svc"
      ;;
    *)
      echo "--- Skipping env update ---"
      ;;
  esac

  # Step 1 — Build + push to ECR
  if [ "$SKIP_BUILD" = true ]; then
    echo "--- Build skipped ---"
  elif [ "$MODE" = "local" ]; then
    echo "--- Step 1: Local build + push ---"
    "$PWD/build-local-and-push.sh" "$svc" 2>&1
  else
    echo "--- Step 1: Build server (git) + push ---"
    "$PWD/build-and-push.sh" "$svc" 2>&1
  fi

  # Step 2 — pull + restart on run instance
  echo ""
  echo "--- Step 2: Pull + restart on run instance ---"
  AWS_ACCOUNT_ID=$(cd terraform && terraform output -raw aws_account_id)
  $SSH "cd $DOCKER_DIR && sudo AWS_ACCOUNT_ID=$AWS_ACCOUNT_ID AWS_REGION=eu-west-1 docker compose -f docker-compose.prod.yml --profile $svc pull $svc 2>&1 | tail -1"
  $SSH "cd $DOCKER_DIR && sudo AWS_ACCOUNT_ID=$AWS_ACCOUNT_ID AWS_REGION=eu-west-1 docker compose -f docker-compose.prod.yml --profile $svc up -d --no-build --no-deps --force-recreate $svc" 2>&1

  # Step 3 — wait for healthcheck
  echo ""
  echo "--- Step 3: Wait for healthy ---"
  sleep 5
  for i in $(seq 1 12); do
    case "$svc" in rxsoft-*) CNAME="$svc" ;; *) CNAME="rxsoft-$svc" ;; esac
    STATUS=$($SSH "sudo docker ps --filter name=$CNAME --format '{{.Status}}' 2>/dev/null" 2>/dev/null || echo "checking...")
    if echo "$STATUS" | grep -q "(healthy)"; then
      echo "  ✅ $svc is healthy!"
      break
    fi
    if echo "$STATUS" | grep -q "(unhealthy)"; then
      echo "  ❌ $svc is unhealthy — check logs"
      $SSH "sudo docker logs $CNAME --tail 20" 2>/dev/null || true
      return 1
    fi
    echo "  Still starting... ($((i*5))s)"
    sleep 5
  done

  # Step 4 — show status
  echo ""
  echo "=== Final Status ==="
  $SSH "sudo docker ps --filter name='$svc' --format 'table {{.Names}}\t{{.Status}}'"
  echo "=== Done ==="
}

# ── Dispatch ────────────────────────────────────────────────
FAILED=false
if [ "$ALL" = true ]; then
  for entry in "${SERVICES[@]}"; do
    svc="${entry%%|*}"
    deploy_one "$svc" || FAILED=true
  done
else
  deploy_one "$SERVICE" || FAILED=true
fi

if [ "$FAILED" = true ]; then
  echo ""
  echo "=== One or more services failed ==="
  exit 1
fi
