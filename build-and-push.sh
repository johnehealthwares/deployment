#!/usr/bin/env bash
#──────────────────────────────────────────────────────────────
# build-and-push.sh — provision t3.large spot instance,
# clone repos, build Docker images, push to ECR, terminate.
#
# Usage:
#   ./build-and-push.sh --all              # build all 8 services
#   ./build-and-push.sh rxsoft-backend     # build single service
#   ./build-and-push.sh --list
#──────────────────────────────────────────────────────────────
set -euo pipefail
cd "$(dirname "$0")"

REGION="eu-west-1"
AMI="ami-0d64bb532e0502c46"
INSTANCE_TYPE="t3.large"
SSH_KEY_PATH="terraform/ssh/id_rsa"
SG_GROUP="rxsoft-postgres"
IAM_PROFILE="rxsoft-profile"
KEY_NAME="rxsoft-key"

# ── Parse args ──────────────────────────────────────────────
SERVICE=""; MODE=""
for arg in "$@"; do
  case "$arg" in
    --all) MODE="all" ;;
    --list) echo "Services: rxsoft-backend rxsoft-identity rxsoft-admin ehealthwares rxsoft-lis-backend conversation-engine healthcare-concepts healthcare-interop"; exit 0 ;;
    *) [ -z "$SERVICE" ] && SERVICE="$arg" || { echo "Error: multiple services"; exit 1; } ;;
  esac
done

if [ -z "$MODE" ] && [ -z "$SERVICE" ]; then echo "Error: specify --all or a service name"; exit 1; fi

SERVICES=()
if [ "$MODE" = "all" ]; then
  SERVICES=(rxsoft-backend rxsoft-identity rxsoft-admin ehealthwares rxsoft-lis-backend conversation-engine healthcare-concepts healthcare-interop)
else
  SERVICES=("$SERVICE")
fi

# ── ECR info ────────────────────────────────────────────────
cd "$PWD/terraform"
AWS_ACCOUNT_ID=$(terraform output -raw aws_account_id)
REGISTRY_URL=$(terraform output -raw ecr_registry_url)
cd "$OLDPWD"
TIMESTAMP=$(date +%Y%m%d-%H%M)
echo "=== Build: ${SERVICES[*]} ==="
echo "  Registry: $REGISTRY_URL"
echo "  Timestamp: $TIMESTAMP"

# ── ECR login ──────────────────────────────────────────────
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$REGISTRY_URL"

# ── Provision ──────────────────────────────────────────────
BUILD_NAME="rxsoft-build-$(date +%s)"
echo "--- Provision $INSTANCE_TYPE spot instance: $BUILD_NAME ---"
SG_ID=$(aws ec2 describe-security-groups --region "$REGION" --filters "Name=group-name,Values=$SG_GROUP" --query 'SecurityGroups[0].GroupId' --output text)
INSTANCE_ID=$(aws ec2 run-instances --region "$REGION" \
  --image-id "$AMI" --instance-type "$INSTANCE_TYPE" --key-name "$KEY_NAME" \
  --security-group-ids "$SG_ID" --iam-instance-profile Name="$IAM_PROFILE" \
  --instance-market-options "MarketType=spot,SpotOptions={SpotInstanceType=one-time}" \
  --block-device-mappings "DeviceName=/dev/sda1,Ebs={VolumeSize=30,VolumeType=gp3,Encrypted=true}" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$BUILD_NAME}]" \
  --query 'Instances[0].InstanceId' --output text)
echo "  ID: $INSTANCE_ID"
aws ec2 wait instance-running --region "$REGION" --instance-ids "$INSTANCE_ID"
BUILD_IP=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
echo "  IP: $BUILD_IP"

SSH_CMD="ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -i $SSH_KEY_PATH ubuntu@$BUILD_IP"

# ── Wait for SSH ───────────────────────────────────────────
for i in $(seq 1 30); do $SSH_CMD "uptime" >/dev/null 2>&1 && echo "  SSH ready after ${i}s" && break; sleep 5; done

# ── Install Docker ─────────────────────────────────────────
$SSH_CMD "sudo apt update -qq && sudo apt install -y -qq docker.io docker-compose-v2 git" 2>&1 | tail -1
$SSH_CMD "sudo systemctl start docker && sudo systemctl enable docker" 2>&1

# ── ECR login on build instance ─────────────────────────────
ECR_PASS=$(aws ecr get-login-password --region "$REGION")
$SSH_CMD "echo '$ECR_PASS' | sudo docker login --username AWS --password-stdin '$REGISTRY_URL'" 2>&1

# ── Clone repos ────────────────────────────────────────────
# Map: service|github_repo|clone_dir|compose_context|symlink
REPO_MAP=(
  "rxsoft-backend|rxsoft-backend|rxsoft-backend|rxsoft-backend|"
  "rxsoft-identity|identity|identity|identity|"
  "rxsoft-admin|common-admin|common-admin|common-admin|"
  "ehealthwares|ehealthwares|ehealthwares|ehealthwares|"
  "rxsoft-lis-backend|rxsoft-lis-backend|rxsoft-lis-backend|rxsoft-lis-backend|"
  "conversation-engine|conversation-engine|conversation-engine|conversation-engine|"
  "healthcare-concepts|common-healthcare-resources|common-healthcare-resources|common-healthcare-resources|"
  "healthcare-interop|healthcare-interoperability-switch|healthcare-interoperability-switch|healthcare-interoperability-switch|"
)

clone_if_needed() {
  local gh_repo="$1" clone_dir="$2"
  $SSH_CMD "[ -d /home/ubuntu/develop/$clone_dir/.git ] && echo CLONED || echo NEED_CLONE" 2>/dev/null | grep -q CLONED && return 0
  echo "  Cloning $gh_repo -> $clone_dir"
  $SSH_CMD "cd /home/ubuntu/develop && git clone --depth 1 https://github.com/johnehealthwares/$gh_repo.git $clone_dir" 2>&1 | tail -1
}

echo "--- Clone repos ---"
$SSH_CMD "sudo mkdir -p /home/ubuntu/develop && sudo chown ubuntu:ubuntu /home/ubuntu/develop" 2>&1
for entry in "${REPO_MAP[@]}"; do
  s="${entry%%|*}"; rest="${entry#*|}"
  gh="${rest%%|*}"; rest="${rest#*|}"
  dir="${rest%%|*}"; rest="${rest#*|}"
  ctx="${rest%%|*}"; rest="${rest#*|}"

  found=false
  for svc in "${SERVICES[@]}"; do [ "$s" = "$svc" ] && found=true && break; done
  $found || continue

  clone_if_needed "$gh" "$dir"
done

# ── Clone deployment repo (contains docker config) ────────────
echo "  Cloning deployment config..."
$SSH_CMD "cd /home/ubuntu/develop && git clone --depth 1 https://github.com/johnehealthwares/deployment.git" 2>&1 | tail -1

# ── Build images ───────────────────────────────────────────
echo "--- Build images ---"
ENV_VARS="AWS_ACCOUNT_ID=$AWS_ACCOUNT_ID AWS_REGION=$REGION"
$SSH_CMD "cd /home/ubuntu/develop/deployment/docker && sudo $ENV_VARS COMPOSE_PARALLEL_LIMIT=1 docker compose -f docker-compose.prod.yml build ${SERVICES[*]}" 2>&1

# ── Tag + Push to ECR ──────────────────────────────────────
echo "--- Tag + push to ECR ---"
ENV="$REGION"
for svc in "${SERVICES[@]}"; do
  IMAGE="$REGISTRY_URL/$svc"
  echo "  $IMAGE:latest + env-$TIMESTAMP"
  $SSH_CMD "sudo docker tag '$IMAGE:latest' '$IMAGE:env-$TIMESTAMP' && sudo docker push '$IMAGE:latest' && sudo docker push '$IMAGE:env-$TIMESTAMP'" 2>&1 | tail -3
done

# ── Terminate ─────────────────────────────────────────────
echo "--- Terminate build instance ---"
aws ec2 terminate-instances --region "$REGION" --instance-ids "$INSTANCE_ID" > /dev/null
echo "  Terminated $INSTANCE_ID"
echo "=== Build complete ==="
