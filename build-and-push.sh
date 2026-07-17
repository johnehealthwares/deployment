#!/usr/bin/env bash
#──────────────────────────────────────────────────────────────
# build-and-push.sh — provision t3.large spot instance,
# clone repos, build Docker images, push to ECR, terminate.
#
# Usage:
#   ./build-and-push.sh --all                    # build all 8 services
#   ./build-and-push.sh rxsoft-backend           # build single service
#   ./build-and-push.sh --commits              # show commits for all services
#   ./build-and-push.sh rxsoft-backend --commits # show commits for one service
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
SERVICE=""; MODE=""; NO_CACHE=""; COMMITS_ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --all) MODE="all"; shift ;;
    --no-cache) NO_CACHE="--no-cache"; shift ;;
    --commits) COMMITS_ONLY="1"; shift ;;
    --list) echo "Services: rxsoft-backend rxsoft-identity rxsoft-admin ehealthwares rxsoft-lis-backend conversation-engine healthcare-concepts healthcare-interop"; exit 0 ;;
    *) [ -z "$SERVICE" ] && SERVICE="$1" && shift || { echo "Error: multiple services"; exit 1; } ;;
  esac
done

if [ -z "$MODE" ] && [ -z "$SERVICE" ]; then
  # Default to --all if --commits is passed without a service
  [ -n "$COMMITS_ONLY" ] && MODE="all" || { echo "Error: specify --all or a service name"; exit 1; }
fi

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
# ECR repo name (may differ from compose service name, e.g. ehealthwares -> rxsoft-ehealthwares)
ecr_repo_for_service() {
  case "$1" in
    ehealthwares) echo "rxsoft-ehealthwares" ;;
    *) echo "$1" ;;
  esac
}

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

echo "--- Clone repos ---"
$SSH_CMD "sudo mkdir -p /home/ubuntu/develop && sudo chown ubuntu:ubuntu /home/ubuntu/develop" 2>&1

# Clone deployment repo first (creates /home/ubuntu/develop/deployment/ with docker/ subdir)
echo "  Cloning deployment config..."
$SSH_CMD "cd /home/ubuntu/develop && git clone --depth 1 https://github.com/johnehealthwares/deployment.git" 2>&1 | tail -1

# Then clone source repos inside deployment/ so docker compose build contexts resolve
for entry in "${REPO_MAP[@]}"; do
  s="${entry%%|*}"; rest="${entry#*|}"
  gh="${rest%%|*}"; rest="${rest#*|}"
  dir="${rest%%|*}"; rest="${rest#*|}"
  ctx="${rest%%|*}"; rest="${rest#*|}"

  found=false
  for svc in "${SERVICES[@]}"; do [ "$s" = "$svc" ] && found=true && break; done
  $found || continue

  $SSH_CMD "[ -d /home/ubuntu/develop/deployment/$dir/.git ] && echo CLONED || echo NEED_CLONE" 2>/dev/null | grep -q CLONED && continue
  echo "  Cloning $gh -> $dir"
  $SSH_CMD "cd /home/ubuntu/develop/deployment && git clone --depth 1 https://github.com/johnehealthwares/$gh.git $dir" 2>&1 | tail -1
done

# ── Show commits ────────────────────────────────────────────
echo "--- Commit info ---"
for svc in "${SERVICES[@]}"; do
  GH_DIR=""
  case "$svc" in
    rxsoft-backend) GH_DIR="rxsoft-backend" ;;
    ehealthwares) GH_DIR="ehealthwares" ;;
    rxsoft-identity) GH_DIR="identity" ;;
    rxsoft-admin) GH_DIR="common-admin" ;;
    rxsoft-lis-backend) GH_DIR="rxsoft-lis-backend" ;;
    conversation-engine) GH_DIR="conversation-engine" ;;
    healthcare-concepts) GH_DIR="common-healthcare-resources" ;;
    healthcare-interop) GH_DIR="healthcare-interoperability-switch" ;;
  esac
  COMMIT=$($SSH_CMD "git -C /home/ubuntu/develop/deployment/$GH_DIR rev-parse HEAD 2>/dev/null || echo unknown")
  MSG=$($SSH_CMD "git -C /home/ubuntu/develop/deployment/$GH_DIR log -1 --format=%s 2>/dev/null || echo unknown")
  BRANCH=$($SSH_CMD "git -C /home/ubuntu/develop/deployment/$GH_DIR rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown")
  REMOTE=$($SSH_CMD "git -C /home/ubuntu/develop/deployment/$GH_DIR remote get-url origin 2>/dev/null || echo unknown")
  echo "  $svc: ${COMMIT:0:10} ($BRANCH) — $MSG"
  echo "    remote: $REMOTE"
  echo "    hash:   $COMMIT"
done

# Exit early if --commits-only
if [ -n "$COMMITS_ONLY" ]; then
  echo "--- Commits only (--commits), skipping build ---"
  aws ec2 terminate-instances --region "$REGION" --instance-ids "$INSTANCE_ID" > /dev/null
  echo "  Terminated $INSTANCE_ID"
  exit 0
fi

# ── Fix missing build files ──────────────────────────────────
echo "--- Fix missing build files ---"
$SSH_CMD "bash -c '
  DIR=/home/ubuntu/develop/deployment/healthcare-interoperability-switch
  [ ! -d \"\$DIR\" ] && exit 0
  cd \"\$DIR\"
  [ -f nest-cli.json ] && exit 0
  cat > nest-cli.json <<\"EOF\"
{
  \"\$schema\": \"https://json.schemastore.org/nest-cli\",
  \"collection\": \"@nestjs/schematics\",
  \"sourceRoot\": \"src\",
  \"compilerOptions\": { \"deleteOutDir\": true }
}
EOF
  cat > tsconfig.build.json <<\"EOF\"
{
  \"extends\": \"./tsconfig.json\",
  \"exclude\": [\"node_modules\", \"test\", \"dist\", \"**/*spec.ts\"]
}
EOF
  echo \"Created nest-cli.json + tsconfig.build.json\"
'" 2>&1

# ── Copy nginx config into admin build context ───────────────
echo "  Copying nginx config into admin build context..."
$SSH_CMD "cp /home/ubuntu/develop/deployment/docker/nginx-default.conf /home/ubuntu/develop/deployment/common-admin/ 2>/dev/null && echo '  Done' || echo '  Skipped (no common-admin)'" 2>&1 | tail -1

# ── Helper: check if commit image exists in ECR ─────────────
commit_exists_in_ecr() {
  local repo="$1" sha="$2"
  aws ecr describe-images --region "$REGION" --repository-name "$repo" --image-ids "imageTag=commit-$sha" > /dev/null 2>&1
}

# ── Build images (one at a time, with git info + commit check) ─
echo "--- Build images ---"
ENV_VARS="AWS_ACCOUNT_ID=$AWS_ACCOUNT_ID AWS_REGION=$REGION"
BUILD_FAILED=false
BUILD_SKIPPED=""
for svc in "${SERVICES[@]}"; do
  GH_DIR=""
  case "$svc" in
    rxsoft-backend) GH_DIR="rxsoft-backend" ;;
    ehealthwares) GH_DIR="ehealthwares" ;;
    rxsoft-identity) GH_DIR="identity" ;;
    rxsoft-admin) GH_DIR="common-admin" ;;
    rxsoft-lis-backend) GH_DIR="rxsoft-lis-backend" ;;
    conversation-engine) GH_DIR="conversation-engine" ;;
    healthcare-concepts) GH_DIR="common-healthcare-resources" ;;
    healthcare-interop) GH_DIR="healthcare-interoperability-switch" ;;
  esac
  COMMIT=$($SSH_CMD "git -C /home/ubuntu/develop/deployment/$GH_DIR rev-parse HEAD 2>/dev/null || echo unknown")
  MSG=$($SSH_CMD "git -C /home/ubuntu/develop/deployment/$GH_DIR log -1 --format=%s 2>/dev/null || echo unknown")
  BRANCH=$($SSH_CMD "git -C /home/ubuntu/develop/deployment/$GH_DIR rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown")
  REMOTE=$($SSH_CMD "git -C /home/ubuntu/develop/deployment/$GH_DIR remote get-url origin 2>/dev/null || echo unknown")
  REPO=$(ecr_repo_for_service "$svc")
  printf 'GIT_COMMIT=%s\nGIT_COMMIT_MSG=%s\nGIT_BRANCH=%s\nGIT_REMOTE=%s\n' "$COMMIT" "$MSG" "$BRANCH" "$REMOTE" | $SSH_CMD "cat > /tmp/git-vars-$svc"

  # Check if this commit already exists in ECR
  if [ -z "${NO_CACHE:-}" ] && [ "$COMMIT" != "unknown" ] && commit_exists_in_ecr "$REPO" "$COMMIT"; then
    echo "  $svc commit ${COMMIT:0:10} already in ECR — skipping build"
    BUILD_SKIPPED="$BUILD_SKIPPED $svc "
    continue
  fi

  echo "  Building $svc (${COMMIT:0:10} on $BRANCH from $REMOTE — $MSG)..."
  OK=false
  for try in 1 2 3; do
    if $SSH_CMD "cd /home/ubuntu/develop/deployment/docker && while IFS='=' read -r k v; do export \"\$k\"=\"\$v\"; done < /tmp/git-vars-$svc && sudo -E $ENV_VARS COMPOSE_PARALLEL_LIMIT=1 docker compose -f docker-compose.prod.yml build $NO_CACHE $svc" 2>&1; then
      OK=true
      break
    fi
    echo "  Build attempt $try for $svc failed, retrying in 10s..."
    sleep 10
  done
  if [ "$OK" = false ]; then
    echo "  !! Build failed for $svc, continuing with remaining services..."
    BUILD_FAILED=true
  fi
done

if [ "$BUILD_FAILED" = true ]; then
  echo "  !! One or more builds failed — check logs above."
fi

# ── Tag + Push to ECR ──────────────────────────────────────
echo "--- Tag + push to ECR ---"
PUSH_FAILED=false
for svc in "${SERVICES[@]}"; do
  REPO=$(ecr_repo_for_service "$svc")
  IMAGE="$REGISTRY_URL/$REPO"
  COMMIT=$($SSH_CMD "grep '^GIT_COMMIT=' /tmp/git-vars-$svc 2>/dev/null | cut -d= -f2 || echo unknown")
  echo "  $IMAGE:latest + commit-${COMMIT:0:10} + env-$TIMESTAMP"

  # For skipped services: pull the existing commit image, then re-tag
  if [ -n "$BUILD_SKIPPED" ] && [[ "$BUILD_SKIPPED" == *" $svc "* ]]; then
    echo "  Pulling existing commit image..."
    $SSH_CMD "sudo docker pull '$IMAGE:commit-$COMMIT'" 2>&1 | tail -1
    $SSH_CMD "sudo docker tag '$IMAGE:commit-$COMMIT' '$IMAGE:latest' && sudo docker tag '$IMAGE:commit-$COMMIT' '$IMAGE:env-$TIMESTAMP'" 2>&1
    $SSH_CMD "sudo docker push '$IMAGE:latest' && sudo docker push '$IMAGE:env-$TIMESTAMP'" 2>&1 | tail -2
    continue
  fi

  # For built services: tag commit + env, push all
  if ! $SSH_CMD "sudo docker tag '$IMAGE:latest' '$IMAGE:commit-$COMMIT' && sudo docker tag '$IMAGE:latest' '$IMAGE:env-$TIMESTAMP' && sudo docker push '$IMAGE:commit-$COMMIT' && sudo docker push '$IMAGE:latest' && sudo docker push '$IMAGE:env-$TIMESTAMP'" 2>&1 | tail -5; then
    echo "  !! Push failed for $svc, continuing..."
    PUSH_FAILED=true
  fi
done

# ── Terminate ─────────────────────────────────────────────
echo "--- Terminate build instance ---"
aws ec2 terminate-instances --region "$REGION" --instance-ids "$INSTANCE_ID" > /dev/null
echo "  Terminated $INSTANCE_ID"
if [ "$BUILD_FAILED" = true ] || [ "$PUSH_FAILED" = true ]; then
  echo "=== Build complete with failures ==="
  exit 1
fi
echo "=== Build complete ==="
