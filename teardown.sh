#!/usr/bin/env bash
#──────────────────────────────────────────────────────────────
# RxSoft full teardown: backup → docker compose down → terraform destroy
# Usage:
#   ./teardown.sh           # interactive — prompts at each step
#   ./teardown.sh --force   # non-interactive — runs all steps
#──────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FORCE=false
FORCE_FLAG="${1:-}"
[ "$FORCE_FLAG" = "--force" ] && FORCE=true

echo "============================================"
echo "  RxSoft Teardown"
echo "  $(date)"
echo "============================================"
echo ""

confirm() {
  local prompt=$1 default=$2
  [ "$FORCE" = true ] && return 0
  local hint
  if [ "$default" = "Y" ]; then hint="Y/n"; else hint="y/N"; fi
  echo -n "$prompt [$hint] "
  read -r -n 1 answer || true
  echo ""
  local default_val="${default,,}"
  local answer_val="${answer:-$default_val}"
  answer_val="${answer_val,,}"
  [ "$answer_val" = "y" ]
}

run_step() {
  local desc=$1
  shift
  echo ""
  echo "--- $desc ---"
  eval "$@"
  echo "Done."
}

# ── Step 1: Backup ─────────────────────────────────────────
BACKUP_DIR="${SCRIPT_DIR}/docker"
if confirm "Backup databases before destroying?" "Y"; then
  run_step "Database backup" "$BACKUP_DIR/backup.sh"
else
  echo "Skipping backup."
fi

# ── Step 2: Docker compose down ────────────────────────────
if confirm "Stop and remove all Docker containers?" "Y"; then
  run_step "Docker compose down" \
    docker compose -f "$BACKUP_DIR/docker-compose.prod.yml down" 2>/dev/null || \
    docker compose -f "$BACKUP_DIR/docker-compose.yml down" 2>/dev/null || \
    echo "  (no running containers or compose files found)"
else
  echo "Skipping docker compose down."
fi

# ── Step 3: Terraform destroy ──────────────────────────────
TF_DIR="${SCRIPT_DIR}/terraform"
if [ -d "$TF_DIR" ]; then
  if confirm "Destroy ALL AWS infra (EC2, EIP, SG, S3, IAM)? This is IRREVERSIBLE." "N"; then
    run_step "Terraform destroy" "cd '$TF_DIR' && terraform destroy -auto-approve"
  else
    echo "Skipping terraform destroy."
  fi
else
  echo "Terraform directory not found at $TF_DIR — skipping."
fi

echo ""
echo "============================================"
echo "  Teardown complete."
echo "============================================"
