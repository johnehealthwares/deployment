#!/usr/bin/env bash
#──────────────────────────────────────────────────────────────
# provision-and-deploy.sh — Full from-scratch provisioning + deploy
#
# Chains: terraform apply → build images → wait for cloud-init
#         → dns-update → deploy services
#
# Usage:
#   ./provision-and-deploy.sh                         # build on spot instance
#   ./provision-and-deploy.sh --local                  # build locally
#   ./provision-and-deploy.sh --skip-build             # images already in ECR
#   ./provision-and-deploy.sh --services "svc1 svc2"   # subset of services
#──────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOCAL=false
SKIP_BUILD=false
SERVICES=(rxsoft-backend rxsoft-admin rxsoft-identity rxsoft-ehealthwares)

while [ $# -gt 0 ]; do
  case "$1" in
    --local) LOCAL=true; shift ;;
    --skip-build) SKIP_BUILD=true; shift ;;
    --services) shift; SERVICES=($1); shift ;;
    --services=*) SERVICES=(${1#--services=}); shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

echo "============================================"
echo "  RxSoft Provision & Deploy"
echo "  Local build: $LOCAL"
echo "  Skip build:  $SKIP_BUILD"
echo "  Services:    ${SERVICES[*]}"
echo "  $(date)"
echo "============================================"

# ── Phase 1: Terraform ─────────────────────────────────────
echo ""
echo "=== Phase 1: Terraform apply ==="
cd "$SCRIPT_DIR/terraform"
if [ ! -d .terraform ]; then
  echo "  Initializing terraform..."
  terraform init
fi
./terraform-apply.sh -auto-approve

cd "$SCRIPT_DIR"

# ── Phase 2: Build & Push ──────────────────────────────────
BUILD_FAILED=false
if [ "$SKIP_BUILD" = false ]; then
  echo ""
  echo "=== Phase 2: Build & push images ==="

  if [ "$LOCAL" = true ]; then
    echo "  Building locally (one at a time)..."
    for svc in "${SERVICES[@]}"; do
      echo "--- Building $svc ---"
      ./build-local-and-push.sh "$svc" || { echo "  !! Build failed for $svc, continuing..."; BUILD_FAILED=true; }
    done
  else
    echo "  Building on spot instance..."
    ./build-and-push.sh --all || { echo "  !! Build phase failed, continuing with deploy..."; BUILD_FAILED=true; }
  fi
else
  echo ""
  echo "=== Phase 2: Skipped (--skip-build) ==="
fi

# ── Phase 3: Wait for cloud-init ───────────────────────────
echo ""
echo "=== Phase 3: Wait for cloud-init on new instance ==="
IP=$(cat .ec2-ip 2>/dev/null || true)
if [ -z "$IP" ]; then
  echo "  Error: no .ec2-ip found. Terraform may have failed."
  exit 1
fi
SSH_KEY="$SCRIPT_DIR/terraform/ssh/id_rsa"
SSH_CMD="ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -i $SSH_KEY ubuntu@$IP"

echo "  Instance IP: $IP"
echo "  Waiting for SSH..."
for i in $(seq 1 30); do
  $SSH_CMD "uptime" >/dev/null 2>&1 && echo "  SSH ready after ${i}s" && break
  [ "$i" -eq 30 ] && { echo "  SSH not reachable after 30 attempts. Aborting."; exit 1; }
  sleep 5
done

echo "  Waiting for cloud-init to finish..."
$SSH_CMD "cloud-init status --wait 2>&1 | tail -1" 2>&1 || true
echo "  Cloud-init complete."

# ── Phase 4: Deploy databases ──────────────────────────────
echo ""
echo "=== Phase 4: Deploy databases ==="
cd "$SCRIPT_DIR"
./deploy_databases.sh || { echo "  !! Databases failed to start. Aborting."; exit 1; }

# ── Phase 5: Deploy services ───────────────────────────────
echo ""
echo "=== Phase 5: Deploy services ==="
for svc in "${SERVICES[@]}"; do
  echo "--- Deploying $svc ---"
  ./deploy-service.sh "$svc" --skip-build
done

# ── Phase 6: DNS Update ────────────────────────────────────
echo ""
echo "=== Phase 6: DNS update + nginx config ==="
./dns-update.sh

echo ""
echo "============================================"
echo "  Provision & deploy complete!"
echo "  IP: $IP"
echo "  Services: ${SERVICES[*]}"
echo "============================================"
