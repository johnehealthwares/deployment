#!/usr/bin/env bash
#──────────────────────────────────────────────────────────────
# RxSoft full teardown: backup → docker compose down → terraform destroy
# Usage:
#   ./teardown.sh               # interactive — prompts at each step
#   ./teardown.sh --force       # non-interactive — runs all steps
#   ./teardown.sh --keep-s3-ecr # skip destroying S3 bucket & ECR repos
#──────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FORCE=false
KEEP_S3_ECR=false
for arg in "$@"; do
  [ "$arg" = "--force" ] && FORCE=true
  [ "$arg" = "--keep-s3-ecr" ] && KEEP_S3_ECR=true
done

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
  local default_val
  default_val=$(echo "$default" | tr '[:upper:]' '[:lower:]')
  local answer_val="${answer:-$default_val}"
  answer_val=$(echo "$answer_val" | tr '[:upper:]' '[:lower:]')
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
LOCAL_BACKUP_DIR="${SCRIPT_DIR}/backups"
if confirm "Backup databases before destroying?" "Y"; then
  mkdir -p "$LOCAL_BACKUP_DIR"
  run_step "Database backup" "BACKUP_DIR='$LOCAL_BACKUP_DIR' '$BACKUP_DIR/backup.sh'"

  # ── Step 1b: Download backup files ─────────────────────────
  IP_FILE="${SCRIPT_DIR}/.ec2-ip"
  SSH_KEY="${SCRIPT_DIR}/terraform/ssh/id_rsa"
  if [ -f "$IP_FILE" ] && [ -f "$SSH_KEY" ]; then
    EC2_IP=$(cat "$IP_FILE")
    if confirm "Download backup files from EC2 ($EC2_IP) before destroying?" "Y"; then
      run_step "Downloading backups from EC2" \
        "scp -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -i '$SSH_KEY' -r 'ubuntu@$EC2_IP:/var/backups/rxsoft/' '$LOCAL_BACKUP_DIR/' 2>/dev/null && echo 'Downloaded to $LOCAL_BACKUP_DIR' || echo 'Failed to download from EC2 (instance may already be down)'"
    else
      echo "Skipping backup download."
    fi
  fi
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
  local_desc="ALL AWS infra (EC2, EIP, SG"
  if [ "$KEEP_S3_ECR" = true ]; then
    local_desc+=", S3, ECR, IAM — keeping S3 + ECR)"
  else
    local_desc+=", S3, ECR, IAM)"
  fi
  if confirm "Destroy ${local_desc}? This is IRREVERSIBLE." "N"; then
    if [ "$KEEP_S3_ECR" = true ]; then
      TARGETS=(
        -target=aws_eip.postgres
        -target=aws_instance.postgres
        -target=aws_security_group.postgres
        -target=aws_key_pair.server
        -target=aws_iam_role_policy_attachment.ecr_pull
        -target=aws_iam_role_policy_attachment.s3
        -target=aws_iam_instance_profile.profile
        -target=aws_iam_role.ec2_role
      )
      run_step "Terraform destroy (keeping S3 + ECR)" "cd '$TF_DIR' && terraform destroy -auto-approve ${TARGETS[*]}"
    else
      run_step "Terraform destroy (full)" "cd '$TF_DIR' && terraform destroy -auto-approve"
    fi
  else
    echo "Skipping terraform destroy."
  fi
fi

# ── Step 4: Clean up cache ──────────────────────────────────
if confirm "Remove .ec2-ip cache file?" "Y"; then
  rm -f "${SCRIPT_DIR}/.ec2-ip"
  echo "  .ec2-ip removed"
fi

echo ""
echo "============================================"
echo "  Teardown complete."
echo "============================================"
