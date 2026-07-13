#!/usr/bin/env bash
#──────────────────────────────────────────────────────────────
# build-local-and-push.sh — build a single service Docker image
# locally on the Mac and push to ECR.
#
# Usage:
#   ./build-local-and-push.sh rxsoft-backend
#   ./build-local-and-push.sh ehealthwares
#   ./build-local-and-push.sh --list
#──────────────────────────────────────────────────────────────
set -euo pipefail
cd "$(dirname "$0")"

REGION="eu-west-1"

# ── Parse args ──────────────────────────────────────────────
SERVICE=""
for arg in "$@"; do
  case "$arg" in
    --list) echo "Services: rxsoft-backend rxsoft-identity rxsoft-admin ehealthwares rxsoft-lis-backend conversation-engine healthcare-concepts healthcare-interop"; exit 0 ;;
    *) [ -z "$SERVICE" ] && SERVICE="$arg" || { echo "Error: multiple services"; exit 1; } ;;
  esac
done
[ -z "$SERVICE" ] && { echo "Error: specify a service"; exit 1; }

# ── Service config ──────────────────────────────────────────
# Format: service|build_context|dockerfile|github_repo_name
CONFIG_MAP=(
  "rxsoft-backend|../rxsoft-backend|Dockerfile.rxsoft-backend|rxsoft-backend"
  "rxsoft-identity|../rxsoft-identity|Dockerfile.rxsoft-identity|identity"
  "rxsoft-admin|../rxsoft-admin-3|Dockerfile.rxsoft-admin|common-admin"
  "ehealthwares|../ehealthwares|Dockerfile.ehealthwares|ehealthwares"
  "rxsoft-lis-backend|../rxsoft-lis-backend|Dockerfile.rxsoft-lis-backend|rxsoft-lis-backend"
  "conversation-engine|../conversation-engine|Dockerfile.conversation-engine|conversation-engine"
  "healthcare-concepts|../healthcare-concepts|Dockerfile.healthcare-concepts|common-healthcare-resources"
  "healthcare-interop|../healthcare-interoperability-switch|Dockerfile.healthcare-interop|healthcare-interoperability-switch"
)

CONTEXT=""; DFILE=""; GH_REPO=""
for entry in "${CONFIG_MAP[@]}"; do
  s="${entry%%|*}"; [ "$s" != "$SERVICE" ] && continue
  rest="${entry#*|}"; CONTEXT="${rest%%|*}"; rest="${rest#*|}"
  DFILE="${rest%%|*}"; rest="${rest#*|}"
  GH_REPO="$rest"
  break
done
[ -z "$CONTEXT" ] && { echo "Error: unknown service '$SERVICE'"; exit 1; }

# ── ECR info ────────────────────────────────────────────────
cd "$PWD/terraform"
AWS_ACCOUNT_ID=$(terraform output -raw aws_account_id)
REGISTRY_URL=$(terraform output -raw ecr_registry_url)
cd "$OLDPWD"
TIMESTAMP=$(date +%Y%m%d-%H%M)
# Map service name to ECR repo name (may differ)
case "$SERVICE" in
  ehealthwares) REPO="rxsoft-ehealthwares" ;;
  *) REPO="$SERVICE" ;;
esac
IMAGE="$REGISTRY_URL/$REPO"
ABS_CONTEXT="$PWD/$CONTEXT"

echo "=== Build: $SERVICE ==="
echo "  Context: $ABS_CONTEXT"
echo "  Dockerfile: docker/$DFILE"
echo "  Image: $IMAGE"
echo "  Timestamp: $TIMESTAMP"

[ ! -d "$ABS_CONTEXT" ] && { echo "Error: context $ABS_CONTEXT not found"; exit 1; }
[ ! -f "docker/$DFILE" ] && { echo "Error: dockerfile docker/$DFILE not found"; exit 1; }

# ── Login to ECR ────────────────────────────────────────────
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$REGISTRY_URL"

# ── Build ───────────────────────────────────────────────────
echo "--- Building $SERVICE ---"
# NEXT_PUBLIC_* vars must be set at build time for Next.js
if [ "$SERVICE" = "ehealthwares" ]; then
  docker build -f "docker/$DFILE" -t "$IMAGE:latest" \
    --build-arg "NEXT_PUBLIC_API_URL=http://www.ehealthwares.com" \
    "$ABS_CONTEXT" 2>&1
else
  docker build -f "docker/$DFILE" -t "$IMAGE:latest" "$ABS_CONTEXT" 2>&1
fi

# ── Tag + Push ──────────────────────────────────────────────
echo "--- Tag + push ---"
docker tag "$IMAGE:latest" "$IMAGE:env-$TIMESTAMP"
docker push "$IMAGE:latest" 2>&1 | tail -1
docker push "$IMAGE:env-$TIMESTAMP" 2>&1 | tail -1

echo "=== Done: $IMAGE:latest ==="
